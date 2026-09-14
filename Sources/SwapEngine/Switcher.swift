import Foundation

/// One row of `_build_accounts_info`: the account plus the credential its
/// usage is read with (live for the active slot, backup otherwise).
struct AccountInfo {
    let key: String
    let number: Int
    let email: String
    let orgName: String
    let orgUuid: String
    let isActive: Bool
    let creds: String
    let alias: String
}

enum UsageSentinel {
    static let noCredentials = "no credentials"
    static let tokenExpired = "token expired"
    static let apiKey = "api key"
    static let keychainUnavailable = "keychain unavailable"
    static let reloginRequired = "re-login needed"
    static let foreignCredential = "foreign credential"
}

/// `switcher.ClaudeAccountSwitcher`, limited to what CSwapBar drives:
/// list, switch, add, add-token, enable/disable and remove. Every read and
/// write goes to the same files, Keychain items and locks as cswap, so the two
/// can be used side by side. One instance per operation, like one cswap run.
final class Switcher {
    static let fetchStagger: TimeInterval = 0.25
    static let setupTokenScopes = ["user:inference"]

    let env: EngineEnvironment
    let paths: Paths
    let keychain: MacOSKeychain
    let backupDir: URL
    let sequenceFile: URL
    let configsDir: URL
    let credentialsDir: URL
    let lockFile: URL
    let log: SwapLog
    let usageStore: UsageStore
    let store: CredentialStore
    let oauth: OAuth

    /// Active-read verdict of the last `buildAccountsInfo`.
    var activeVerdict: ActiveCredentials?
    var provenanceWarned = Set<String>()
    /// Ownership verdicts per credential lineage (`_probe_verdicts`).
    var probeVerdicts: [String: Bool] = [:]
    /// Human-facing notes a cswap run would have printed as warnings.
    private(set) var warnings: [String] = []

    init(env: EngineEnvironment) {
        self.env = env
        paths = Paths(env: env)
        keychain = MacOSKeychain(keychainFile: env.keychainFile, env: env)
        backupDir = paths.backupRoot()
        sequenceFile = backupDir.appendingPathComponent("sequence.json")
        configsDir = backupDir.appendingPathComponent("configs")
        credentialsDir = backupDir.appendingPathComponent("credentials")
        lockFile = backupDir.appendingPathComponent(".lock")
        log = SwapLog(dir: backupDir, now: env.now)
        usageStore = UsageStore(cacheDir: backupDir.appendingPathComponent("cache"), clock: { env.epoch })
        store = CredentialStore(env: env, paths: paths, keychain: keychain, credentialsDir: credentialsDir, log: log)
        oauth = OAuth(env: env, log: log)
        Migrations.run(self)
    }

    func warn(_ message: String) {
        warnings.append(message)
    }

    func timestamp() -> JSONValue { .string(TimeFormat.timestamp(env.now())) }

    // MARK: JSON files

    /// `_read_json`: nil when ABSENT. `strict` throws when the file is there
    /// but unreadable, so a torn file is never overwritten unread.
    func readJSON(_ path: URL, strict: Bool = false) throws -> JSONObject? {
        guard FS.exists(path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            log.warning("Could not read \(path.path): \(error)")
            if strict {
                throw SwapError.config("\(path.path) exists but could not be read (\(error)). Fix what is blocking the read, then retry.")
            }
            return nil
        }
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(data)
        } catch {
            log.warning("Invalid JSON in \(path.path)")
            if strict {
                throw SwapError.config("\(path.path) exists but could not be parsed (\(error)). Repair or move it, then retry — refusing to overwrite it unread.")
            }
            return nil
        }
        guard let obj = parsed.objectValue else {
            log.warning("\(path.path) holds \(Self.pyTypeName(parsed)), not a JSON object")
            if strict {
                throw SwapError.config("\(path.path) holds \(Self.pyTypeName(parsed)), not a JSON object. Repair or move it, then retry.")
            }
            return nil
        }
        return obj
    }

    static func pyTypeName(_ v: JSONValue) -> String {
        switch v {
        case .object: return "dict"
        case .array: return "list"
        case .string: return "str"
        case .number(let n): return n.isInteger ? "int" : "float"
        case .bool: return "bool"
        case .null: return "NoneType"
        }
    }

    /// `Path.with_suffix`, for the `_write_json` temp name.
    static func withSuffix(_ url: URL, _ suffix: String) -> URL {
        let name = url.lastPathComponent
        var stem = name
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
        }
        return url.deletingLastPathComponent().appendingPathComponent(stem + suffix)
    }

    /// `_write_json`: temp file, validated, 0600, then renamed into place.
    func writeJSON(_ path: URL, _ data: JSONObject) throws {
        let content = JSONValue.object(data).serialized(indent: 2)
        let temp = Self.withSuffix(path, ".\(getpid()).tmp")
        try FS.writeText(temp, content)
        guard (try? JSONValue.parse(FS.readText(temp))) != nil else {
            try? FS.unlinkIfPresent(temp)
            throw SwapError.config("Generated invalid JSON")
        }
        try FS.chmod(temp, 0o600)
        try FS.rename(temp, path)
    }

    /// Copy an unreadable file aside (0600, never clobbering an earlier copy)
    /// before it is replaced.
    func salvageUnreadable(_ path: URL) throws {
        let stem = "\(path.lastPathComponent).unreadable-\(Int(env.epoch))"
        var salvage = path.deletingLastPathComponent().appendingPathComponent(stem)
        var n = 1
        while FS.exists(salvage) {
            salvage = path.deletingLastPathComponent().appendingPathComponent("\(stem).\(n)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: path, to: salvage)
            try FS.chmod(salvage, 0o600)
        } catch {
            throw SwapError.switchFailed("\(path.path) could not be parsed and the salvage copy failed (\(error)); aborting rather than destroying it")
        }
        let msg = "\(path.lastPathComponent) could not be parsed — a copy was kept at \(salvage.lastPathComponent)"
        log.warning("\(path.path) could not be parsed; a copy was kept at \(salvage.path) before it was replaced")
        warn(msg)
    }

    func setupDirectories() throws {
        for dir in [backupDir, configsDir, credentialsDir] {
            try FS.mkdirs(dir)
            try FS.chmod(dir, 0o700)
        }
    }

    // MARK: Roster (sequence.json)

    func initSequenceFile() throws {
        guard !FS.exists(sequenceFile) else { return }
        try writeJSON(sequenceFile, JSONObject([
            ("activeAccountNumber", .null),
            ("lastUpdated", timestamp()),
            ("sequence", .array([])),
            ("accounts", .object(JSONObject())),
        ]))
    }

    /// nil ONLY when the roster does not exist yet; a torn one throws.
    func getSequenceData() throws -> JSONObject? {
        try readJSON(sequenceFile, strict: true)
    }

    static func accounts(_ data: JSONObject?) -> JSONObject {
        data?["accounts"]?.objectValue ?? JSONObject()
    }

    static func record(_ data: JSONObject?, _ num: String) -> JSONObject? {
        accounts(data)[num]?.objectValue
    }

    static func setRecord(_ data: inout JSONObject, _ num: String, _ record: JSONObject?) {
        var accts = accounts(data)
        accts[num] = record.map { .object($0) }
        data["accounts"] = .object(accts)
    }

    /// `str(n)` for a `sequence` element.
    static func slotKey(_ v: JSONValue) -> String {
        switch v {
        case .number(let n): return n.literal
        case .string(let s): return s
        default: return v.serialized()
        }
    }

    static func sequence(_ data: JSONObject?) -> [JSONValue] {
        data?["sequence"]?.arrayValue ?? []
    }

    /// `x.get(key, "") or ""` for a string field.
    static func str(_ obj: JSONObject?, _ key: String, default fallback: String = "") -> String {
        guard let v = obj?[key] else { return fallback }
        return v.stringValue ?? ""
    }

    func getNextAccountNumber() throws -> Int {
        guard let data = try getSequenceData() else { return 1 }
        let accts = Self.accounts(data)
        if accts.isEmpty { return 1 }
        return (accts.keys.compactMap { Int($0) }.max() ?? 0) + 1
    }

    /// `(email, org_uuid, account_uuid)` from one read of `~/.claude.json`.
    func getCurrentIdentityTriple() -> (email: String, org: String, uuid: String)? {
        let path = paths.globalConfigPath()
        guard FS.exists(path), let data = try? readJSON(path), !data.isEmpty else { return nil }
        let account = data["oauthAccount"]?.objectValue ?? JSONObject()
        let email = Self.str(account, "emailAddress")
        guard !email.isEmpty else { return nil }
        return (email, Self.str(account, "organizationUuid"), Self.str(account, "accountUuid"))
    }

    func getCurrentAccount() -> (email: String, org: String)? {
        getCurrentIdentityTriple().map { ($0.email, $0.org) }
    }

    func liveIdentityMatches(_ email: String, _ orgUuid: String) -> Bool {
        guard let current = getCurrentAccount() else { return false }
        return current.email == email && current.org == orgUuid
    }

    static func findAccountSlot(_ data: JSONObject?, _ email: String, _ orgUuid: String) -> String? {
        for entry in accounts(data).entries {
            guard let acct = entry.value.objectValue else { continue }
            if acct["email"] == .string(email), (acct["organizationUuid"] ?? .string("")) == .string(orgUuid) {
                return entry.key
            }
        }
        return nil
    }

    func accountExists(_ email: String, _ orgUuid: String) throws -> Bool {
        guard let data = try getSequenceData() else { return false }
        return Self.findAccountSlot(data, email, orgUuid) != nil
    }

    func accountKind(_ num: String?) throws -> String {
        guard let num else { return "oauth" }
        return Self.record(try getSequenceData(), num)?["kind"] == .string("api_key") ? "api_key" : "oauth"
    }

    func findAccountByAlias(_ alias: String) throws -> String? {
        guard !alias.isEmpty, let data = try getSequenceData() else { return nil }
        let wanted = alias.lowercased()
        for entry in Self.accounts(data).entries where Self.str(entry.value.objectValue, "alias").lowercased() == wanted {
            return entry.key
        }
        return nil
    }

    static func isDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isNumber) }

    /// Number → alias → email; an email shared by several accounts is an error.
    func resolveAccountIdentifier(_ identifier: String) throws -> String? {
        if Self.isDigits(identifier) { return identifier }
        guard let data = try getSequenceData() else { return nil }
        if let alias = try findAccountByAlias(identifier) { return alias }
        let matches = Self.accounts(data).entries.filter { $0.value.objectValue?["email"] == .string(identifier) }.map(\.key)
        if matches.isEmpty { return nil }
        if matches.count == 1 { return matches[0] }
        let details = matches.map { num -> String in
            let org = Self.str(Self.record(data, num), "organizationName")
            return "\(num) [\(org.isEmpty ? "personal" : org)]"
        }.joined(separator: ", ")
        throw SwapError.config("Email '\(identifier)' is ambiguous — matches accounts: \(details). Use account number instead (e.g., cswap --switch-to 1).")
    }

    func resolveAccount(_ identifier: String) throws -> (num: String, email: String, org: String) {
        _ = try getSequenceDataMigrated()
        guard let num = try resolveAccountIdentifier(identifier) else {
            throw SwapError.accountNotFound("No account found with identifier: \(identifier)")
        }
        guard let record = Self.record(try getSequenceData(), num) else {
            throw SwapError.accountNotFound("Account-\(num) does not exist")
        }
        return (num, Self.str(record, "email"), Self.str(record, "organizationUuid"))
    }

    func getSequenceDataMigrated() throws -> JSONObject? {
        guard let data = try getSequenceData() else { return nil }
        let needs = Self.accounts(data).entries.contains { !($0.value.objectValue?.has("organizationUuid") ?? true) }
        if needs {
            try migrateOrgFields()
            return try getSequenceData()
        }
        return data
    }

    /// Backfill org fields for accounts added before org support.
    func migrateOrgFields() throws {
        guard var data = try getSequenceData() else { return }
        var liveEmail = "", liveOrgUuid = "", liveOrgName = ""
        if let config = try? readJSON(paths.globalConfigPath()), let oauthAccount = config["oauthAccount"]?.objectValue {
            liveEmail = Self.str(oauthAccount, "emailAddress")
            liveOrgUuid = Self.str(oauthAccount, "organizationUuid")
            liveOrgName = Self.str(oauthAccount, "organizationName")
        }
        var updated = false
        for entry in Self.accounts(data).entries {
            guard var account = entry.value.objectValue, !account.has("organizationUuid") else { continue }
            let email = Self.str(account, "email")
            if !liveEmail.isEmpty, email == liveEmail {
                account["organizationUuid"] = .string(liveOrgUuid)
                account["organizationName"] = .string(liveOrgName)
            } else {
                let configText = readAccountConfig(entry.key, email)
                if !configText.isEmpty, let cfg = OAuth.parseObject(configText) {
                    let oauthAccount = cfg["oauthAccount"]?.objectValue
                    account["organizationUuid"] = .string(Self.str(oauthAccount, "organizationUuid"))
                    account["organizationName"] = .string(Self.str(oauthAccount, "organizationName"))
                } else {
                    account["organizationUuid"] = .string("")
                    account["organizationName"] = .string("")
                }
            }
            Self.setRecord(&data, entry.key, account)
            updated = true
        }
        if updated {
            data["lastUpdated"] = timestamp()
            try writeJSON(sequenceFile, data)
        }
    }

    static func disabledFromData(_ data: JSONObject?, _ num: String) -> Bool {
        record(data, num)?["disabled"]?.isTruthy ?? false
    }

    // MARK: Per-slot backups

    func configPath(_ num: String, _ email: String) -> URL {
        configsDir.appendingPathComponent(".claude-config-\(num)-\(email).json")
    }

    func readAccountConfig(_ num: String, _ email: String) -> String {
        (try? FS.readText(configPath(num, email))) ?? ""
    }

    func writeAccountConfig(_ num: String, _ email: String, _ config: String) throws {
        let path = configPath(num, email)
        try FS.writeText(path, config)
        try FS.chmod(path, 0o600)
    }

    func readAccountCredentials(_ num: String, _ email: String) -> String {
        store.readAccountCredentials(num, email)
    }

    func accountIsSwitchable(_ num: String) throws -> Bool {
        guard let record = Self.record(try getSequenceData(), num) else { return false }
        let email = Self.str(record, "email")
        return !readAccountCredentials(num, email).isEmpty && !readAccountConfig(num, email).isEmpty
    }

    /// Store write, then session invalidation. Past the store write nothing
    /// may throw: the slot already holds the new credential.
    func writeAccountCredentials(_ num: String, _ email: String, _ credentials: String) throws {
        try store.writeAccountCredentials(num, email, credentials)
        do {
            try postBackupWrite(num, email)
        } catch {
            if Sessions.markSessionStale(sessionDir(num, email)) {
                log.warning("Stored account \(num)'s credential but could not invalidate its session profile; marked it stale so the next run re-bootstraps.")
            } else {
                log.error("Stored account \(num)'s credential but could NOT invalidate its session profile OR mark it stale; the profile may keep serving the superseded generation until its token expires.")
            }
        }
    }

    private func postBackupWrite(_ num: String, _ email: String) throws {
        if !liveSessionPids(num, email).isEmpty {
            if !Sessions.markSessionStale(sessionDir(num, email)) {
                log.error("Account \(num)'s backup credentials changed but its live session profile could not be marked stale; it may keep serving the superseded generation once it exits.")
            }
        } else {
            try invalidateSessionCredentials(num, email)
        }
    }

    /// The single chokepoint that removes or displaces a slot.
    func deleteAccountFiles(_ num: String, _ email: String) throws {
        try ensureNoLiveSession(num, email, action: "the operation")
        store.deleteAccountCredentials(num, email)
        let cfg = configPath(num, email)
        if FS.exists(cfg) { try FS.unlinkIfPresent(cfg) }
        deleteSessionProfile(num, email)
    }

    func pruneMappings(_ email: String, _ orgUuid: String) {
        let path = backupDir.appendingPathComponent("mappings.json")
        guard FS.exists(path), let data = try? readJSON(path), var mappings = data["mappings"]?.objectValue else { return }
        let doomed = mappings.entries.filter {
            $0.value.objectValue?["email"] == .string(email) && Self.str($0.value.objectValue, "organizationUuid") == orgUuid
        }.map(\.key)
        guard !doomed.isEmpty else { return }
        for key in doomed { mappings.removeValue(forKey: key) }
        do {
            try FS.chmod(backupDir, 0o700)
            try FS.atomicWrite(
                Data(JSONValue.object(JSONObject([("schemaVersion", .int(1)), ("mappings", .object(mappings))])).serialized(indent: 2).utf8),
                to: path,
                prefix: ".mappings-"
            )
        } catch {
            log.warning("Failed to prune directory mappings: \(error)")
        }
    }

    // MARK: Session profiles

    func sessionDir(_ num: String, _ email: String) -> URL {
        Sessions.sessionDir(backupDir: backupDir, num: num, email: email)
    }

    func liveSessionPids(_ num: String, _ email: String) -> [Int] {
        Sessions.scanLiveSessions(sessionDir(num, email)).pids
    }

    func ensureNoLiveSession(_ num: String, _ email: String, action: String) throws {
        let dir = sessionDir(num, email)
        let (pids, unreadable) = Sessions.scanLiveSessions(dir)
        if !pids.isEmpty {
            throw SwapError.session("Account-\(num) (\(email)) has a live session-mode Claude instance (PID \(pids.map(String.init).joined(separator: ", "))). Exit it first, then retry \(action).")
        }
        if unreadable > 0 {
            throw SwapError.session("Account-\(num) (\(email)) has \(unreadable) session record(s) that could not be read, so whether a Claude instance is live cannot be determined. Inspect \(dir.appendingPathComponent("sessions").path) and remove or repair them, then retry \(action).")
        }
    }

    private func invalidateSessionCredentials(_ num: String, _ email: String) throws {
        let dir = sessionDir(num, email)
        guard FS.exists(dir) else { return }
        Sessions.deleteKeychainEntry(dir, keychain: keychain)
        try FS.unlinkIfPresent(dir.appendingPathComponent(".credentials.json"))
        Sessions.clearSessionStale(dir)
        log.info("Invalidated session credentials for account \(num)")
    }

    func deleteSessionProfile(_ num: String, _ email: String) {
        let dir = sessionDir(num, email)
        if FS.exists(dir) {
            Sessions.deleteKeychainEntry(dir, keychain: keychain)
            try? FileManager.default.removeItem(at: dir)
        }
        let cleared = Sessions.clearSessionStale(dir)
        if FS.exists(dir) || !cleared {
            log.warning("Could not fully remove account \(num)'s session profile at \(dir.path); credentials are gone but the profile dir and/or its stale marker survive (check permissions on it and its parent).")
            return
        }
        log.info("Removed session profile for account \(num) at \(dir.path)")
    }

    /// Refuse to mutate from inside a `cswap run` shell.
    func refuseSessionShell() throws {
        guard let cfg = env.nonEmptyEnv("CLAUDE_CONFIG_DIR") else { return }
        let resolved = URL(fileURLWithPath: cfg).resolvingSymlinksInPath().standardizedFileURL.path
        let sessions = backupDir.appendingPathComponent("sessions").resolvingSymlinksInPath().standardizedFileURL.path
        if resolved == sessions || resolved.hasPrefix(sessions + "/") {
            throw SwapError.switchFailed("This shell is inside a cswap run session profile (CLAUDE_CONFIG_DIR points at it). Mutating accounts here would operate on the wrong live store — unset CLAUDE_CONFIG_DIR or run from a normal shell.")
        }
    }

    // MARK: Identity helpers

    func accountIdentity(_ num: String) -> (email: String, org: String, uuid: String) {
        let acct = Self.record(try? getSequenceData(), num)
        return (Self.str(acct, "email"), Self.str(acct, "organizationUuid"), Self.str(acct, "uuid").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Fill an empty slot uuid (add-token placeholders) — never rewrite one.
    func backfillAccountUUID(_ num: String, _ uuid: String, expectedEmail: String?, expectedOrg: String?) {
        guard !uuid.isEmpty else { return }
        try? FileLock(lockFile).hold {
            guard var data = try getSequenceData(), var acct = Self.record(data, num) else { return }
            guard Self.str(acct, "uuid").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let expectedEmail, acct["email"] != .string(expectedEmail) { return }
            if let expectedOrg, Self.str(acct, "organizationUuid") != expectedOrg { return }
            acct["uuid"] = .string(uuid)
            Self.setRecord(&data, num, acct)
            data["lastUpdated"] = timestamp()
            try writeJSON(sequenceFile, data)
        }
    }

    /// Tri-state: true = this slot's account, false = definitively another,
    /// nil = unverifiable (never cached).
    func resolvedMatchesSlotIdentity(_ num: String, _ resolved: ResolvedIdentity) -> Bool? {
        let own = accountIdentity(num)
        let rUuid = resolved.uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rUuid.isEmpty, !own.uuid.isEmpty {
            let orgOK = (resolved.organizationUuid ?? "").isEmpty || own.org.isEmpty || resolved.organizationUuid == own.org
            return rUuid == own.uuid && orgOK
        }
        if let rEmail = resolved.email, !rEmail.isEmpty, rEmail == own.email {
            guard let rOrg = resolved.organizationUuid else { return nil }
            if rOrg == own.org {
                backfillAccountUUID(num, rUuid, expectedEmail: rEmail, expectedOrg: rOrg)
                return true
            }
            return false
        }
        if let rEmail = resolved.email, !rEmail.isEmpty, resolved.organizationUuid != nil { return false }
        return nil
    }

    /// `_lineage_key`: bound to the slot's full stored identity.
    func lineageKey(_ num: String, _ email: String, _ fingerprint: String) -> String {
        let own = accountIdentity(num)
        return [num, email, own.email, own.org, own.uuid, fingerprint].joined(separator: "\u{1F}")
    }

    // MARK: Enable / disable / remove

    func setAccountDisabled(_ identifier: String, _ disabled: Bool) throws {
        guard FS.exists(sequenceFile) else { throw SwapError.config("No accounts are managed yet") }
        let (num, email, _) = try resolveAccount(identifier)
        guard var data = try getSequenceData(), var record = Self.record(data, num) else {
            throw SwapError.accountNotFound("Account-\(num) does not exist")
        }
        let verb = disabled ? "disabled" : "enabled"
        if (record["disabled"]?.isTruthy ?? false) == disabled { return }
        if disabled {
            record["disabled"] = .bool(true)
        } else {
            record.removeValue(forKey: "disabled")
        }
        Self.setRecord(&data, num, record)
        data["lastUpdated"] = timestamp()
        try writeJSON(sequenceFile, data)
        log.info("\(verb.prefix(1).uppercased() + verb.dropFirst()) account \(num): \(email)")
    }

    func removeAccount(_ identifier: String) throws {
        try refuseSessionShell()
        guard FS.exists(sequenceFile) else { throw SwapError.config("No accounts are managed yet") }
        _ = try getSequenceDataMigrated()
        if !Self.isDigits(identifier) {
            let isAlias = try findAccountByAlias(identifier) != nil
            if !isAlias, !Self.validateEmail(identifier) {
                throw SwapError.validation("Invalid account identifier: \(identifier)")
            }
        }
        guard let num = try resolveAccountIdentifier(identifier) else {
            throw SwapError.accountNotFound("No account found with identifier: \(identifier)")
        }
        guard var data = try getSequenceData(), let info = Self.record(data, num) else {
            throw SwapError.accountNotFound("Account-\(num) does not exist")
        }
        let email = Self.str(info, "email")
        try ensureNoLiveSession(num, email, action: "--remove-account")
        try deleteAccountFiles(num, email)
        Self.setRecord(&data, num, nil)
        data["sequence"] = .array(Self.sequence(data).filter { Self.slotKey($0) != num })
        data["lastUpdated"] = timestamp()
        try writeJSON(sequenceFile, data)
        log.info("Removed account \(num): \(email)")
        pruneMappings(email, Self.str(info, "organizationUuid"))
    }

    static func validateEmail(_ email: String) -> Bool {
        email.range(of: #"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"#, options: .regularExpression) != nil
    }

    // MARK: Settings

    /// `(threshold, models)` from `settings.json`'s autoswitch section.
    func pollPolicyInputs() -> (threshold: Double, models: [String]) {
        let path = backupDir.appendingPathComponent("settings.json")
        let section = (try? readJSON(path))?["autoswitch"]?.objectValue
        var threshold = 90.0
        if let n = section?["threshold"]?.numberValue {
            threshold = min(max(n.doubleValue, 50.0), 99.9)
        }
        var models: [String] = []
        if let model = section?["model"]?.stringValue, !model.isEmpty {
            var seen = Set<String>()
            for part in model.split(separator: ",") {
                let name = part.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !seen.contains(name.lowercased()) {
                    seen.insert(name.lowercased())
                    models.append(name)
                }
            }
        }
        return (threshold, models)
    }
}
