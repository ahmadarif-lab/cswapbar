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
        let attempts = strictKeychain ? 2 : 1
        for attempt in 0..<attempts {
            do {
                let creds = try keychain.getPassword(
                    service: keychainService ?? keychainServiceName(configDir),
                    account: keychain.accountName()
                )
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
                break
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
    /// records), and how many records could not be read.
    static func scanLiveSessions(_ sessionDir: URL) -> (pids: [Int], unreadable: Int) {
        guard FS.exists(sessionDir) else { return ([], 0) }
        let dir = sessionDir.appendingPathComponent("sessions")
        guard FS.isDirectory(dir),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return ([], 0) }
        var pids: [Int] = []
        var unreadable = 0
        for name in names where name.hasSuffix(".json") {
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
            if isPidAlive(pid) { pids.append(pid) }
        }
        return (pids, unreadable)
    }

    static func isPidAlive(_ pid: Int) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
