import Foundation

/// `migrations.py`, macOS half: the one-time move of per-account backups from
/// Python `keyring`'s service to the `security`-managed one. Tracked in
/// `<backup>/.migrations.json` exactly like cswap, so neither tool repeats it.
enum Migrations {
    static let stateFilename = ".migrations.json"
    static let keyringToSecurity = "macos_keyring_to_security"

    static func run(_ s: Switcher) {
        guard FS.exists(s.backupDir) else { return }
        let applied = loadApplied(s)
        guard applied[keyringToSecurity] == nil else { return }
        do {
            if try migrateKeyringToSecurity(s) {
                try markApplied(s, keyringToSecurity)
            }
        } catch {
            s.log.warning("Migration \(keyringToSecurity) did not complete (will retry): \(error)")
        }
    }

    private static func statePath(_ s: Switcher) -> URL { s.backupDir.appendingPathComponent(stateFilename) }

    static func loadApplied(_ s: Switcher) -> JSONObject {
        guard let data = try? Data(contentsOf: statePath(s)),
              let obj = (try? JSONValue.parse(data))?.objectValue,
              let applied = obj["applied"]?.objectValue else { return JSONObject() }
        return applied
    }

    private static func markApplied(_ s: Switcher, _ id: String) throws {
        var applied = loadApplied(s)
        applied[id] = s.timestamp()
        let content = JSONValue.object(JSONObject([("version", .int(1)), ("applied", .object(applied))])).serialized(indent: 2)
        try FS.atomicWrite(Data(content.utf8), to: statePath(s))
    }

    /// True when every account's backup is in the `claude-swap` service.
    /// Legacy items are read through `security` (the path cswap takes when
    /// `keyring` is unavailable) and left in place, since deleting an item
    /// another binary created can prompt a second time.
    private static func migrateKeyringToSecurity(_ s: Switcher) throws -> Bool {
        guard FS.exists(s.sequenceFile) else { return false }
        guard let data = try s.getSequenceData() else { return false }
        let accounts = Switcher.accounts(data)
        if accounts.isEmpty { return true }

        var pending: [(String, String)] = []
        for entry in accounts.entries {
            let email = Switcher.str(entry.value.objectValue, "email")
            do {
                if try s.store.kcReadBackup(entry.key, email).isEmpty { pending.append((entry.key, email)) }
            } catch {
                throw SwapError.config("Keychain unavailable, deferring macOS keyring migration: \(error)")
            }
        }
        if pending.isEmpty { return true }

        var emailCounts: [String: Int] = [:]
        for entry in accounts.entries {
            emailCounts[Switcher.str(entry.value.objectValue, "email"), default: 0] += 1
        }

        var migrated = 0
        var failed = 0
        for (num, email) in pending {
            func readOld(_ username: String) throws -> String {
                try s.keychain.getPassword(service: KeychainService.legacyKeyring, account: username) ?? ""
            }
            var creds: String
            do {
                creds = try readOld("account-\(num)-\(email)")
                if creds.isEmpty, num != "None", emailCounts[email] == 1 {
                    creds = try readOld("account-None-\(email)")
                }
            } catch {
                s.log.warning("macos_keyring_to_security: read of account-\(num)-\(email) failed: \(error)")
                failed += 1
                continue
            }
            if creds.isEmpty { continue }
            do {
                try s.store.kcWriteBackup(num, email, creds)
                let readback = try s.store.kcReadBackup(num, email)
                guard readback == creds else {
                    s.log.warning("macos_keyring_to_security: read-back mismatch for account-\(num)-\(email); discarding the security item and leaving the keyring entry in place")
                    s.store.deleteBackupKeychainQuiet(num, email)
                    failed += 1
                    continue
                }
            } catch {
                s.log.warning("macos_keyring_to_security: write/read-back for account-\(num)-\(email) failed: \(error)")
                s.store.deleteBackupKeychainQuiet(num, email)
                failed += 1
                continue
            }
            migrated += 1
        }
        if migrated > 0 {
            s.log.info("claude-swap: migrated \(migrated) macOS credential(s) from the keyring into the Keychain via security")
        }
        if failed > 0 {
            throw SwapError.config("\(failed) account(s) could not be migrated to the security service; will retry on next run")
        }
        return true
    }
}
