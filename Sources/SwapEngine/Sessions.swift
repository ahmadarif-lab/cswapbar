import CryptoKit
import Foundation

/// The parts of `session.py` (and `process_detection.py`) that touch a slot's
/// `cswap run` profile. This engine never launches sessions, but it must keep
/// their credentials consistent whenever it rewrites a slot's backup.
enum Sessions {
    static let staleMarker = ".cswap-stale-credentials"

    static func slugifyEmail(_ email: String) -> String {
        var out = ""
        for scalar in email.precomposedStringWithCanonicalMapping.unicodeScalars {
            let c = Character(scalar)
            if scalar.isASCII, c.isLetter || c.isNumber || "._-".contains(c) {
                out.unicodeScalars.append(scalar)
            } else {
                out += "_"
            }
        }
        return out
    }

    static func sessionDir(backupDir: URL, num: String, email: String) -> URL {
        backupDir.appendingPathComponent("sessions").appendingPathComponent("\(num)-\(slugifyEmail(email))")
    }

    /// Claude Code hashes the raw `CLAUDE_CONFIG_DIR` value, NFC-normalized.
    static func keychainServiceName(_ configDir: String) -> String {
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(digest.prefix(8))"
    }

    /// Keychain service names that may hold a profile's credential, in
    /// lookup order. Claude hashes the exported `CLAUDE_CONFIG_DIR`
    /// verbatim, so a symlinked profile was launched under its own path or
    /// the target's; reading only the link's name serves a stale seed and
    /// freezes usage at the last pre-rotation reading.
    static func keychainServices(_ configDir: String, override: String? = nil) -> [String] {
        if let override { return [override] }
        var services = [keychainServiceName(configDir)]
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: configDir) else { return services }
        if target.hasPrefix("/") {
            services.append(keychainServiceName(target))
            return services
        }
        let parent = (configDir as NSString).deletingLastPathComponent
        let raw = (parent as NSString).appendingPathComponent(target)
        let lexical = (raw as NSString).standardizingPath
        if lexical != raw, FS.samefile(lexical, raw) { services.append(keychainServiceName(lexical)) }
        services.append(keychainServiceName(raw))
        return services
    }

    /// Written as a SIBLING of the profile dir, read from both locations.
    static func staleMarkerFor(_ sessionDir: URL) -> URL {
        sessionDir.deletingLastPathComponent().appendingPathComponent(".\(sessionDir.lastPathComponent)\(staleMarker)")
    }

    static func isSessionStale(_ sessionDir: URL) -> Bool {
        FS.exists(staleMarkerFor(sessionDir)) || FS.exists(sessionDir.appendingPathComponent(staleMarker))
    }

    @discardableResult
    static func clearSessionStale(_ sessionDir: URL) -> Bool {
        var cleared = true
        for marker in [staleMarkerFor(sessionDir), sessionDir.appendingPathComponent(staleMarker)] {
            do { try FS.unlinkIfPresent(marker) } catch { cleared = false }
        }
        return cleared
    }

    static func markSessionStale(_ sessionDir: URL) -> Bool {
        let marker = staleMarkerFor(sessionDir)
        if FS.exists(marker) {
            return utimes(marker.path, nil) == 0
        }
        return FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    static func deleteKeychainEntry(_ sessionDir: URL, keychain: MacOSKeychain) {
        try? keychain.deletePassword(service: keychainServiceName(sessionDir.path), account: keychain.accountName())
    }

    /// The credential of an arbitrary config dir: its hashed Keychain item,
    /// then its plaintext seed. `strictKeychain` refuses to fall back when
    /// the Keychain is unreadable rather than absent.
    static func readConfigDirCredentials(
        _ configDir: String,
        keychain: MacOSKeychain,
        strictKeychain: Bool = false,
        keychainService: String? = nil
    ) throws -> String? {
        let directory = URL(fileURLWithPath: configDir)
        guard FS.isDirectory(directory) else { return nil }
        for service in keychainServices(configDir, override: keychainService) {
            let attempts = strictKeychain ? 2 : 1
            for attempt in 0..<attempts {
                do {
                    let creds = try keychain.getPassword(service: service, account: keychain.accountName())
                    if let creds, !creds.isEmpty { return creds }
                    break
                } catch {
                    if attempt + 1 < attempts {
                        Thread.sleep(forTimeInterval: 0.3)
                        continue
                    }
                    if strictKeychain {
                        throw SwapError.credentialRead(
                            "Keychain entry for profile \(configDir) is unreadable (locked or busy) — unlock the keychain and retry: \(error)"
                        )
                    }
                    // Best-effort read: the plaintext seed is the next-best truth.
                    return try? FS.readText(directory.appendingPathComponent(".credentials.json"))
                }
            }
        }
        return try? FS.readText(directory.appendingPathComponent(".credentials.json"))
    }

    static func readSessionCredentials(_ sessionDir: URL, keychain: MacOSKeychain) -> String? {
        (try? readConfigDirCredentials(sessionDir.path, keychain: keychain)) ?? nil
    }

    static func readSessionIdentity(_ sessionDir: URL) -> (email: String, org: String)? {
        guard let data = try? Data(contentsOf: sessionDir.appendingPathComponent(".claude.json")),
              let config = (try? JSONValue.parse(data))?.objectValue else { return nil }
        var account = JSONObject()
        if let raw = config["oauthAccount"], raw.isTruthy {
            guard let obj = raw.objectValue else { return nil }
            account = obj
        }
        guard let email = account["emailAddress"]?.stringValue, !email.isEmpty else { return nil }
        return (email, account["organizationUuid"]?.stringValue ?? "")
    }

    static func sessionIdentityDrifted(_ sessionDir: URL, email: String, orgUuid: String) -> Bool {
        guard let identity = readSessionIdentity(sessionDir) else { return false }
        if identity.email != email { return true }
        return !identity.org.isEmpty && !orgUuid.isEmpty && identity.org != orgUuid
    }

    /// Live Claude instances for a profile (from its `sessions/<pid>.json`
    /// records), and how many records could not be read. A record is live
    /// only while its pid is alive AND still belongs to the claude that
    /// wrote it. A directory that cannot be listed counts as 1 unreadable
    /// record, never as empty; only a missing one is genuinely empty.
    static func scanLiveSessions(_ sessionDir: URL) -> (pids: [Int], unreadable: Int) {
        guard FS.exists(sessionDir) else { return ([], 0) }
        let dir = sessionDir.appendingPathComponent("sessions")
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch let error as NSError {
            let missing = error.code == NSFileReadNoSuchFileError
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
            return missing ? ([], 0) : ([], 1)
        }
        var pids: [Int] = []
        var unreadable = 0
        for name in names where name.lowercased().hasSuffix(".json") {
            let path = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: path),
                  let obj = (try? JSONValue.parse(data))?.objectValue,
                  let pidValue = obj["pid"] else {
                unreadable += 1
                continue
            }
            if case .bool = pidValue { continue }
            guard let n = pidValue.numberValue, n.isInteger, let pid = Int(n.literal), pid < Int(Int32.max) else {
                unreadable += 1
                continue
            }
            if isPidAlive(pid), pidMatchesRecord(pid, procStart: obj["procStart"]?.stringValue) {
                pids.append(pid)
            }
        }
        return (pids, unreadable)
    }

    /// Nothing runs against this profile AND every record was readable. The
    /// predicate for "safe to rewrite or remove": not knowing is not "empty".
    static func profileIsQuiescent(_ sessionDir: URL) -> Bool {
        let (pids, unreadable) = scanLiveSessions(sessionDir)
        return pids.isEmpty && unreadable == 0
    }

    /// Slack for the small clock steps that move a `ps` start time.
    static let pidReuseSlack: TimeInterval = 120
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `ps -o lstart=` as epoch seconds (`Wed Sep  2 20:35:59 2026`, under
    /// `LC_ALL=C TZ=UTC`). Parsed by hand: month names are locale-bound.
    static func lstartSeconds(_ text: String) -> Int? {
        let parts = text.split(whereSeparator: { $0 == " " })
        guard parts.count == 5, let month = months.firstIndex(of: String(parts[1])),
              let day = Int(parts[2]), let year = Int(parts[4]) else { return nil }
        let clock = parts[3].split(separator: ":").compactMap { Int($0) }
        guard clock.count == 3 else { return nil }
        var tm = tm()
        tm.tm_year = Int32(year - 1900); tm.tm_mon = Int32(month); tm.tm_mday = Int32(day)
        tm.tm_hour = Int32(clock[0]); tm.tm_min = Int32(clock[1]); tm.tm_sec = Int32(clock[2])
        return Int(timegm(&tm))
    }

    private static func ps(_ pid: Int, _ columns: [String]) -> String? {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["TZ"] = "UTC"
        guard let result = try? Subprocess.run(
            "/bin/ps", ["-o", columns.map { "\($0)=" }.joined(separator: ","), "-p", String(pid)],
            environment: env, timeout: 5
        ), result.status == 0 else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Is the live process at `pid` the one that wrote a record stamped
    /// `procStart`? A recycled pid belongs to a process that started after
    /// the recorded claude did; only that direction disqualifies, and only a
    /// stranger. Everything unknowable passes: "cannot tell" must never turn
    /// a live session into "nobody there".
    static func pidMatchesRecord(_ pid: Int, procStart: String?) -> Bool {
        guard let procStart, !procStart.isEmpty else { return true }
        // All-digit stamps are Linux /proc ticks; there is no /proc here.
        if procStart.allSatisfy(\.isNumber) { return true }
        guard let recorded = lstartSeconds(procStart),
              let text = ps(pid, ["lstart"]), let started = lstartSeconds(text),
              Double(started) > Double(recorded) + pidReuseSlack else { return true }
        guard let command = ps(pid, ["comm", "args"]) else { return true }
        return command.lowercased().contains("claude")
    }

    static func isPidAlive(_ pid: Int) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
