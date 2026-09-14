import Foundation

/// `credentials.ActiveCredentials`: `value` is the credential, "" when none
/// exists anywhere, nil on a plaintext-file read error. `degraded` means the
/// OAuth Keychain read failed even if a fallback answered — those bytes may be
/// a superseded generation and their refresh token must never be consumed.
struct ActiveCredentials {
    var value: String?
    var keychainUnavailable: Bool
    var degraded = false
}

enum KeychainService {
    /// Per-account backups written by cswap (and this engine).
    static let backup = "claude-swap"
    /// Claude Code's active OAuth credential.
    static let claudeCode = "Claude Code-credentials"
    /// Claude Code's active managed API key.
    static let managedKey = "Claude Code"
    /// Pre-`security` backups written through Python's `keyring`.
    static let legacyKeyring = "claude-code"
}

enum CredentialShape {
    static let sharedKeys = ["mcpOAuth", "mcpOAuthClientConfig", "mcpXaaIdp", "mcpXaaIdpConfig", "pluginSecrets"]

    /// A bare `sk-ant-api…` key, never a JSON object.
    static func looksLikeAPIKey(_ credentials: String?) -> Bool {
        guard let credentials, !credentials.isEmpty else { return false }
        let text = credentials.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("sk-ant-api") && !text.hasPrefix("{")
    }

    static func credentialObject(_ credentials: String?) -> JSONObject? {
        guard let credentials, !credentials.isEmpty, !looksLikeAPIKey(credentials) else { return nil }
        return OAuth.parseObject(credentials)
    }

    /// The machine-shared siblings of `claudeAiOauth` (MCP OAuth and the
    /// like); nil when the input is not a JSON credential object.
    static func sharedFields(_ credentials: String?) -> JSONObject? {
        guard let data = credentialObject(credentials) else { return nil }
        var out = JSONObject()
        for key in sharedKeys { if let v = data[key] { out[key] = v } }
        return out
    }

    /// The target login with the live machine's shared fields, which are
    /// wholly live-owned (absence included).
    static func mergeSharedFields(_ target: String, _ shared: JSONObject) -> String {
        guard let obj = credentialObject(target), obj.has("claudeAiOauth") else { return target }
        var composed = JSONObject()
        for entry in obj.entries where !sharedKeys.contains(entry.key) { composed[entry.key] = entry.value }
        for entry in shared.entries { composed[entry.key] = entry.value }
        return JSONValue.object(composed).serialized()
    }

    /// Claude Code's `normalizeApiKeyForConfig`: the last 20 characters.
    static func approvedForm(_ apiKey: String) -> String {
        String(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).suffix(20))
    }
}

/// `credentials.CredentialStore`: the active and per-account backup stores,
/// with cswap's per-process Keychain-vs-file routing.
final class CredentialStore {
    static let activeReadAttempts = 2
    static let activeReadRetryDelay: TimeInterval = 0.3
    static let keychainRecheckCooldown: TimeInterval = 60

    let env: EngineEnvironment
    let paths: Paths
    let keychain: MacOSKeychain
    let credentialsDir: URL
    let log: SwapLog

    private var keychainUsableCache: Bool?
    private var keychainDisabledUntil: TimeInterval = 0
    private var fileModeIsOurs = false
    private var keychainOpFailed = false
    private var activeReadFailed = false
    private var residualVerdict: Bool?
    private(set) var lastActiveCredentialsBackend: String?

    init(env: EngineEnvironment, paths: Paths, keychain: MacOSKeychain, credentialsDir: URL, log: SwapLog) {
        self.env = env
        self.paths = paths
        self.keychain = keychain
        self.credentialsDir = credentialsDir
        self.log = log
    }

    private func monotonic() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Keychain routing

    /// `_kc_call`: every Keychain op teaches the routing whether it works.
    func kc<T>(_ body: () throws -> T) throws -> T {
        do {
            let result = try body()
            keychainOpFailed = false
            if keychainUsableCache == nil { keychainUsableCache = true }
            return result
        } catch let error as KeychainError {
            keychainOpFailed = true
            keychainUsableCache = false
            keychainDisabledUntil = monotonic() + Self.keychainRecheckCooldown
            throw error
        }
    }

    func useKeychain() -> Bool {
        if keychainUsableCache == false, keychainDisabledUntil != 0, monotonic() >= keychainDisabledUntil {
            keychainUsableCache = nil
            keychainDisabledUntil = 0
        }
        return keychainUsableCache != false
    }

    private func pinFileMode(residualCleared: Bool) {
        keychainUsableCache = false
        keychainDisabledUntil = 0
        fileModeIsOurs = true
        residualVerdict = residualCleared
        if residualCleared {
            keychainOpFailed = false
            activeReadFailed = false
        }
    }

    var keychainUnreadable: Bool {
        if useKeychain() { return false }
        return keychainOpFailed
    }

    // MARK: Active credential (read)

    private func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func activeProfileIsDefault() -> Bool {
        sameDirectory(paths.claudeConfigHome(), paths.defaultClaudeConfigHome())
    }

    /// `_active_oauth_keychain_services`, in try-order.
    func activeOAuthKeychainServices() -> [String] {
        if let secure = env.envValue("CLAUDE_SECURESTORAGE_CONFIG_DIR") {
            return secure.isEmpty ? [KeychainService.claudeCode] : [Sessions.keychainServiceName(secure)]
        }
        guard let configDir = env.nonEmptyEnv("CLAUDE_CONFIG_DIR") else { return [KeychainService.claudeCode] }
        var services = [Sessions.keychainServiceName(configDir)]
        if activeProfileIsDefault() { services.append(KeychainService.claudeCode) }
        return services
    }

    func readCredentials() -> String? { readActiveCredentials().value }

    private func readActiveOAuthKeychain() -> (String?, Bool) {
        for service in activeOAuthKeychainServices() {
            let (value, failed) = readOneOAuthKeychain(service)
            if let value, !value.isEmpty { return (value, false) }
            if failed { return (nil, true) }
        }
        return (nil, false)
    }

    private func readOneOAuthKeychain(_ service: String) -> (String?, Bool) {
        var lastError: Error?
        for attempt in 0..<Self.activeReadAttempts {
            do {
                let value = try kc { try keychain.getPassword(service: service, account: keychain.accountName()) }
                return (value, false)
            } catch {
                lastError = error
                if attempt + 1 < Self.activeReadAttempts { Thread.sleep(forTimeInterval: Self.activeReadRetryDelay) }
            }
        }
        log.warning("Keychain read failed after \(Self.activeReadAttempts) attempt(s), trying file: \(lastError.map { "\($0)" } ?? "")")
        return (nil, true)
    }

    /// OAuth Keychain → `.credentials.json` → managed API key, classified.
    func readActiveCredentials() -> ActiveCredentials {
        var keychainFailed = false
        if useKeychain() {
            let (value, failed) = readActiveOAuthKeychain()
            keychainFailed = failed
            activeReadFailed = failed
            if let value, !value.isEmpty { return ActiveCredentials(value: value, keychainUnavailable: false) }
        } else if residualVerdict == false || activeReadFailed || keychainUnreadable {
            keychainFailed = true
        }

        let credFile = paths.credentialsPath()
        if FS.exists(credFile) {
            let text: String
            do {
                text = try FS.readText(credFile)
            } catch {
                log.error("Failed to read credentials file: \(error)")
                return ActiveCredentials(value: nil, keychainUnavailable: keychainFailed, degraded: keychainFailed)
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ActiveCredentials(value: text, keychainUnavailable: false, degraded: keychainFailed)
            }
        }

        let key = readManagedKey()
        if !key.isEmpty { return ActiveCredentials(value: key, keychainUnavailable: false, degraded: keychainFailed) }
        return ActiveCredentials(value: "", keychainUnavailable: keychainFailed, degraded: keychainFailed)
    }

    private func readManagedKey() -> String {
        if activeProfileIsDefault(), useKeychain() {
            var value: String?
            do {
                value = try kc { try keychain.getPassword(service: KeychainService.managedKey, account: keychain.accountName()) }
            } catch {
                log.warning("Managed-key Keychain read failed: \(error)")
            }
            if let value, !value.isEmpty { return value }
        }
        if let key = readGlobalConfig()?["primaryApiKey"]?.stringValue, !key.isEmpty { return key }
        return ""
    }

    func readGlobalConfig() -> JSONObject? {
        let path = paths.globalConfigPath()
        guard FS.exists(path) else { return nil }
        do {
            return try JSONValue.parse(Data(contentsOf: path)).objectValue
        } catch {
            log.warning("Failed to read global config: \(error)")
            return nil
        }
    }

    /// Key-scoped atomic rewrite of `~/.claude.json`; refuses to overwrite a
    /// file that exists but could not be read.
    func updateGlobalConfig(_ mutator: (inout JSONObject) -> Void) throws {
        let path = paths.globalConfigPath()
        let current = readGlobalConfig()
        if current == nil, FS.exists(path) {
            throw SwapError.credentialWrite(
                "\(path.path) exists but could not be read — refusing to overwrite it. Move or repair the file, then retry."
            )
        }
        var data = current ?? JSONObject()
        mutator(&data)
        try FS.atomicWrite(Data(JSONValue.object(data).serialized(indent: 2).utf8), to: path)
    }

    // MARK: Active credential (write)

    private func writeActiveCredentialsFile(_ credentials: String) throws {
        let dir = paths.claudeConfigHome()
        try FS.atomicWrite(Data(credentials.utf8), to: dir.appendingPathComponent(".credentials.json"))
    }

    private func deleteActiveKeychainEntry() -> Bool {
        do {
            try keychain.deletePassword(service: KeychainService.claudeCode, account: keychain.accountName())
            return true
        } catch {
            return false
        }
    }

    /// One auth axis at a time: activating OAuth clears the managed key and
    /// vice versa, mirroring Claude Code's `saveApiKey`/`removeApiKey`.
    func writeCredentials(_ credentials: String) throws {
        if CredentialShape.looksLikeAPIKey(credentials) {
            try writeManagedCredentials(credentials.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            try writeOAuthCredentials(credentials)
            clearManagedKey()
        }
    }

    private func writeManagedCredentials(_ apiKey: String) throws {
        var wroteToKeychain = false
        if useKeychain() {
            do {
                try kc { try keychain.setPassword(service: KeychainService.managedKey, account: keychain.accountName(), password: apiKey) }
                wroteToKeychain = true
            } catch {
                log.warning("Managed-key Keychain write failed, falling back to config: \(error)")
            }
        }
        let approved = CredentialShape.approvedForm(apiKey)
        do {
            try updateGlobalConfig { cfg in
                var responses = cfg["customApiKeyResponses"]?.objectValue ?? JSONObject()
                var approvedList = responses["approved"]?.arrayValue ?? []
                if !approvedList.contains(.string(approved)) { approvedList.append(.string(approved)) }
                responses["approved"] = .array(approvedList)
                if !responses.has("rejected") { responses["rejected"] = .array([]) }
                cfg["customApiKeyResponses"] = .object(responses)
                if wroteToKeychain {
                    cfg.removeValue(forKey: "primaryApiKey")
                } else {
                    cfg["primaryApiKey"] = .string(apiKey)
                }
            }
        } catch let error as SwapError {
            throw error
        } catch {
            throw SwapError.credentialWrite("Failed to write managed API key: \(error)")
        }
        clearOAuthCredential()
        if !wroteToKeychain { pinFileMode(residualCleared: false) }
        lastActiveCredentialsBackend = wroteToKeychain ? "keychain" : "file"
    }

    private func clearManagedKey() {
        try? keychain.deletePassword(service: KeychainService.managedKey, account: keychain.accountName())
        let cfg = readGlobalConfig()
        if cfg == nil, FS.exists(paths.globalConfigPath()) {
            log.warning(
                "Could not clear primaryApiKey: the global config exists but could not be read (unreadable, not absent) — leaving it in place rather than overwriting it unread"
            )
            return
        }
        if let cfg, let key = cfg["primaryApiKey"], !key.isNull {
            do {
                try updateGlobalConfig { $0.removeValue(forKey: "primaryApiKey") }
            } catch {
                log.warning("Failed to clear primaryApiKey: \(error)")
            }
        }
    }

    private func clearOAuthCredential() {
        _ = deleteActiveKeychainEntry()
        let credFile = paths.credentialsPath()
        do {
            if FS.exists(credFile) { try FS.unlinkIfPresent(credFile) }
        } catch {
            log.warning("Failed to remove credentials file: \(error)")
        }
    }

    /// Keychain when usable (then bump an existing `.credentials.json` so a
    /// running Claude Code hot-reloads); else the plaintext file plus a
    /// best-effort clear of the stale Keychain item.
    private func writeOAuthCredentials(_ credentials: String) throws {
        if useKeychain() {
            do {
                try kc { try keychain.setPassword(service: KeychainService.claudeCode, account: keychain.accountName(), password: credentials) }
                refreshStaleCredentialsFile(credentials)
                lastActiveCredentialsBackend = "keychain"
                return
            } catch {
                log.warning("Keychain write failed, falling back to file: \(error)")
            }
        }
        do {
            try writeActiveCredentialsFile(credentials)
        } catch {
            throw SwapError.credentialWrite("Failed to write credentials: \(error)")
        }
        let cleared = deleteActiveKeychainEntry()
        pinFileMode(residualCleared: cleared)
        lastActiveCredentialsBackend = "file"
    }

    private func refreshStaleCredentialsFile(_ credentials: String) {
        guard FS.exists(paths.credentialsPath()) else { return }
        do {
            try writeActiveCredentialsFile(credentials)
        } catch {
            log.warning(
                "Could not refresh .credentials.json after Keychain write (\(error)); a running session may not hot-reload until restart"
            )
        }
    }

    // MARK: Per-account backups

    func backupEncPath(_ num: String, _ email: String) -> URL {
        credentialsDir.appendingPathComponent(".creds-\(num)-\(email).enc")
    }

    private func backupUsername(_ num: String, _ email: String) -> String { "account-\(num)-\(email)" }
    private func prevBackupPath(_ num: String, _ email: String) -> URL {
        credentialsDir.appendingPathComponent(".creds-\(num)-\(email).enc.prev")
    }
    private func prevBackupUsername(_ num: String, _ email: String) -> String { backupUsername(num, email) + ".prev" }

    func kcReadBackup(_ num: String, _ email: String) throws -> String {
        try kc { try keychain.getPassword(service: KeychainService.backup, account: backupUsername(num, email)) } ?? ""
    }

    func kcWriteBackup(_ num: String, _ email: String, _ credentials: String) throws {
        try kc { try keychain.setPassword(service: KeychainService.backup, account: backupUsername(num, email), password: credentials) }
    }

    private func kcDeleteBackup(_ num: String, _ email: String) throws {
        try kc { try keychain.deletePassword(service: KeychainService.backup, account: backupUsername(num, email)) }
    }

    func deleteBackupKeychainQuiet(_ num: String, _ email: String) {
        do {
            try kcDeleteBackup(num, email)
        } catch {
            log.warning("Failed to delete credentials from Keychain: \(error)")
        }
    }

    private func atomicB64Write(_ target: URL, _ credentials: String) throws {
        try FS.mkdirs(credentialsDir)
        try FS.atomicWrite(Data(Data(credentials.utf8).base64EncodedString().utf8), to: target)
    }

    private func reconcileEncAfterKeychainWrite(_ num: String, _ email: String, _ credentials: String) throws {
        let enc = backupEncPath(num, email)
        guard FS.exists(enc) else { return }
        do {
            try FS.unlinkIfPresent(enc)
            return
        } catch {
            log.warning(
                "Could not delete .enc after Keychain backup write (\(error)); rewriting it with the fresh credentials to keep both consistent"
            )
        }
        try atomicB64Write(enc, credentials)
    }

    /// `.enc`-wins read: a fallback file beats a possibly-stale Keychain copy.
    /// `failed` reports a read that FAILED, as opposed to finding nothing.
    func readAccountCredentials(_ num: String, _ email: String, failed: inout Bool) -> String {
        let enc = backupEncPath(num, email)
        var st = stat()
        var encPresent = false
        if stat(enc.path, &st) == 0 {
            encPresent = true
        } else if errno != ENOENT {
            failed = true
            log.warning("Failed to read credentials file: \(String(cString: strerror(errno)))")
        }
        if encPresent {
            do {
                let encoded = try FS.readText(enc).trimmingCharacters(in: .whitespacesAndNewlines)
                if let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) {
                    if !decoded.isEmpty { return decoded }
                } else {
                    log.warning("Failed to read credentials file: invalid base64")
                }
            } catch {
                failed = true
                log.warning("Failed to read credentials file: \(error)")
            }
        }
        do {
            return try kcReadBackup(num, email)
        } catch {
            failed = true
            log.warning("Failed to read credentials from Keychain: \(error)")
        }
        return ""
    }

    func readAccountCredentials(_ num: String, _ email: String) -> String {
        var failed = false
        return readAccountCredentials(num, email, failed: &failed)
    }

    /// `(value, unreadable)`: unreadable is true only when the read that
    /// produced "" actually failed.
    func readAccountCredentialsEx(_ num: String, _ email: String) -> (String, Bool) {
        var failed = false
        let value = readAccountCredentials(num, email, failed: &failed)
        if !value.isEmpty { return (value, false) }
        return ("", failed)
    }

    /// Pure write, no session invalidation. Keychain when usable (then drop
    /// any `.enc` so it cannot shadow), else the `.enc` plus a best-effort
    /// delete of the stale Keychain copy. The previous generation is kept as
    /// `.prev` first.
    func writeAccountCredentials(_ num: String, _ email: String, _ credentials: String) throws {
        retainPreviousBackup(num, email, credentials)
        if useKeychain() {
            do {
                try kcWriteBackup(num, email, credentials)
                try reconcileEncAfterKeychainWrite(num, email, credentials)
                return
            } catch let error as KeychainError {
                log.warning("Keychain backup write failed, falling back to file: \(error)")
            }
        }
        do {
            try atomicB64Write(backupEncPath(num, email), credentials)
        } catch {
            log.warning("Failed to write credentials file: \(error)")
            throw error
        }
        deleteBackupKeychainQuiet(num, email)
    }

    func deleteAccountCredentials(_ num: String, _ email: String) {
        var nums = [num]
        if num != "None" { nums.append("None") }
        for n in nums {
            let enc = backupEncPath(n, email)
            do {
                if FS.exists(enc) { try FS.unlinkIfPresent(enc) }
            } catch {
                log.warning("Failed to delete credentials file: \(error)")
            }
            deleteBackupKeychainQuiet(n, email)
            deletePreviousBackup(n, email)
        }
    }

    func deletePreviousBackup(_ num: String, _ email: String) {
        let prev = prevBackupPath(num, email)
        do {
            if FS.exists(prev) { try FS.unlinkIfPresent(prev) }
        } catch {
            log.warning("Failed to delete .prev file: \(error)")
        }
        do {
            try kc { try keychain.deletePassword(service: KeychainService.backup, account: prevBackupUsername(num, email)) }
        } catch {
            log.warning("Failed to delete .prev from Keychain: \(error)")
        }
    }

    private func retainPreviousBackup(_ num: String, _ email: String, _ newCredentials: String) {
        let (current, unreadable) = readAccountCredentialsEx(num, email)
        if unreadable {
            log.warning(
                "Could not retain previous credential generation for account \(num): the current backup exists but could not be read (not absent) — no .prev recovery copy will exist for this write"
            )
            return
        }
        if current.isEmpty || current == newCredentials { return }
        do {
            if useKeychain() {
                try kc { try keychain.setPassword(service: KeychainService.backup, account: prevBackupUsername(num, email), password: current) }
            } else {
                try atomicB64Write(prevBackupPath(num, email), current)
            }
        } catch {
            log.warning("Failed to retain previous credential generation for account \(num): \(error)")
        }
    }

    // MARK: Unclaimed stash (safety copies)

    var stashManifestPath: URL { credentialsDir.appendingPathComponent(".unclaimed-manifest.json") }
    private func stashEntryPath(_ id: String) -> URL { credentialsDir.appendingPathComponent(".unclaimed-\(id).enc") }

    enum ManifestVerdict { case ok, unreadable, corrupt }

    func readStashManifestEx() -> (JSONObject, ManifestVerdict) {
        let raw: Data
        do {
            raw = try Data(contentsOf: stashManifestPath)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (JSONObject(), .ok)
        } catch {
            if (error as NSError).domain == NSPOSIXErrorDomain, (error as NSError).code == Int(ENOENT) {
                return (JSONObject(), .ok)
            }
            log.warning("Unclaimed manifest unreadable: \(error)")
            return (JSONObject(), .unreadable)
        }
        guard let parsed = try? JSONValue.parse(raw), let obj = parsed.objectValue else {
            log.warning("Failed to read unclaimed manifest")
            return (JSONObject(), .corrupt)
        }
        guard let entries = obj["entries"]?.objectValue else {
            log.warning("Unclaimed manifest parses but has no valid 'entries' member")
            return (JSONObject(), .corrupt)
        }
        return (entries, .ok)
    }

    /// Whether any stashed credential's bytes are on disk; unknowable = true.
    func stashEntryFilesExist() -> Bool {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: credentialsDir.path)
            return names.contains { $0.hasPrefix(".unclaimed-") && $0.hasSuffix(".enc") }
        } catch {
            if !FS.exists(credentialsDir) { return false }
            return true
        }
    }

    private func writeStashManifest(_ entries: JSONObject) throws {
        try FS.mkdirs(credentialsDir)
        let path = stashManifestPath
        if FS.exists(path) {
            let readable = (try? Data(contentsOf: path)).flatMap { try? JSONValue.parse($0) } != nil
            if !readable {
                let aside = credentialsDir.appendingPathComponent("\(path.lastPathComponent).corrupt-\(Int(env.epoch))")
                do {
                    try FS.rename(path, aside)
                    log.warning("Unreadable unclaimed manifest preserved as \(aside.lastPathComponent)")
                } catch {
                    log.warning("Could not preserve corrupt unclaimed manifest: \(error)")
                }
            }
        }
        try AtomicJSON.write(
            .object(JSONObject([("schemaVersion", .int(1)), ("entries", .object(entries))])),
            to: path
        )
    }

    private func mutateStashManifest(_ mutate: (inout JSONObject) -> Void) throws {
        try FS.mkdirs(credentialsDir)
        let lockPath = credentialsDir.appendingPathComponent(".unclaimed-manifest.lock")
        try FileLock(lockPath).hold {
            var (entries, verdict) = readStashManifestEx()
            if verdict == .unreadable {
                throw SwapError.credentialRead(
                    "the unclaimed manifest is unreadable; refusing to rewrite it from an empty read, which would orphan every stashed successor it maps"
                )
            }
            mutate(&entries)
            try writeStashManifest(entries)
        }
    }

    /// Stash credential bytes of unknown or unpersisted provenance. Throws on
    /// any failure: a successful stash is the licence to overwrite.
    func writeUnclaimedCredential(_ credentials: String, context: JSONObject) throws -> String {
        let now = env.now()
        let stamp: (String) -> String = { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = format
            return f.string(from: now)
        }
        let digest = String(OAuth.sha256Hex(credentials).prefix(12))
        let nonce = (0..<3).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let entryID = "\(stamp("yyyyMMdd'T'HHmmss"))-\(digest)-\(nonce)"
        try atomicB64Write(stashEntryPath(entryID), credentials)
        var row = JSONObject([("createdAt", .string(stamp("yyyy-MM-dd'T'HH:mm:ss'Z'")))])
        for entry in context.entries { row[entry.key] = entry.value }
        try mutateStashManifest { $0[entryID] = .object(row) }
        return entryID
    }

    /// `(value, unreadable)`; absent and corrupt both read as ("", false).
    func readUnclaimedCredential(_ id: String) -> (String, Bool) {
        let path = stashEntryPath(id)
        let encoded: String
        do {
            encoded = try FS.readText(path).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            if !FS.exists(path) { return ("", false) }
            log.warning("Unclaimed credential \(id) unreadable: \(error)")
            return ("", true)
        }
        guard let data = Data(base64Encoded: encoded), let s = String(data: data, encoding: .utf8) else {
            log.warning("Failed to decode unclaimed credential \(id)")
            return ("", false)
        }
        return (s, false)
    }

    func removeUnclaimedCredential(_ id: String) throws {
        do {
            try FS.unlinkIfPresent(stashEntryPath(id))
        } catch {
            log.warning("Failed to remove unclaimed credential \(id): \(error)")
        }
        try mutateStashManifest { $0.removeValue(forKey: id) }
    }
}
