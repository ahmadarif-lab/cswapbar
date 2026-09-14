import Foundation

/// What the pre-lock identity lookup learned about the live credential.
struct Provenance {
    var live: String?
    var resolved: ResolvedIdentity?
}

extension Switcher {
    /// `switch_to(identifier)`: activate a slot, backing the outgoing
    /// login up into its own slot first.
    func switchTo(_ identifier: String) throws {
        guard FS.exists(sequenceFile) else { throw SwapError.config("No accounts are managed yet") }
        _ = try getSequenceDataMigrated()
        if !Self.isDigits(identifier) {
            let isAlias = try findAccountByAlias(identifier) != nil
            if !isAlias, !Self.validateEmail(identifier) {
                throw SwapError.validation("Invalid account identifier: \(identifier)")
            }
        }
        guard let target = try resolveAccountIdentifier(identifier) else {
            throw SwapError.accountNotFound("No account found with identifier: \(identifier)")
        }
        let data = try getSequenceData()
        guard Self.record(data, target) != nil else {
            throw SwapError.accountNotFound("Account-\(target) does not exist")
        }

        // Short-circuit a no-op before mutating: a self-switch would back the
        // live login up over the slot and read it straight back. Only when the
        // live credential matches the slot (or cannot be classified) — a
        // resolved divergence runs the full switch so it can be reconciled.
        var provenance: Provenance?
        if let identity = getCurrentAccount(), Self.findAccountSlot(data, identity.email, identity.org) == target {
            let (action, prov) = selfSwitchAction(target, identity.email)
            if action != "reconcile" { return }
            provenance = prov
        }
        try performSwitch(target, provenance: provenance)
    }

    private func liveMatchesSlotBackup(_ slot: String, _ email: String) -> Bool {
        guard let live = store.readCredentials(), !live.isEmpty else { return true }
        let backup = readAccountCredentials(slot, email)
        if backup.isEmpty { return false }
        return live == backup || OAuth.credentialFingerprint(live) == OAuth.credentialFingerprint(backup)
    }

    private func selfSwitchAction(_ slot: String, _ email: String) -> (String, Provenance?) {
        if liveMatchesSlotBackup(slot, email) { return ("noop", nil) }
        let provenance = prefetchLiveIdentity()
        if provenance.resolved == nil {
            log.info("Live credential diverges from Account-\(slot)'s stored backup and ownership could not be verified; self-switch left everything untouched (pre-fix no-op).")
            return ("noop-diverged", nil)
        }
        return ("reconcile", provenance)
    }

    /// Resolve the live credential's owner BEFORE any lock is taken — only
    /// the API can say whose token diverged bytes are.
    private func prefetchLiveIdentity() -> Provenance {
        var result = Provenance()
        let live = store.readCredentials()
        result.live = live
        guard let live, !live.isEmpty, let identity = getCurrentAccount(),
              let data = try? getSequenceData(),
              let slot = Self.findAccountSlot(data, identity.email, identity.org) else { return result }
        let backup = readAccountCredentials(slot, identity.email)
        if backup == live || OAuth.credentialFingerprint(backup) == OAuth.credentialFingerprint(live) { return result }
        guard let token = OAuth.extractAccessToken(live), !token.isEmpty else { return result }
        result.resolved = oauth.fetchProfile(token)
        return result
    }

    /// `_classify_outgoing_credential`: what the switch-time backup may do
    /// with the live bytes. See cswap for the full taxonomy.
    private func classifyOutgoing(
        _ current: String, _ currentEmail: String, _ original: String,
        _ provenance: Provenance, _ data: JSONObject
    ) -> (kind: String, foreignSlot: String?) {
        let backup = readAccountCredentials(current, currentEmail)
        if !backup.isEmpty, backup == original { return ("own-bytes", nil) }
        if !backup.isEmpty, OAuth.credentialFingerprint(backup) == OAuth.credentialFingerprint(original) {
            return ("own-family", nil)
        }
        if let liveOAuth = OAuth.extractOAuthData(original),
           liveOAuth["accessToken"]?.isTruthy != true, liveOAuth["refreshToken"]?.isTruthy != true {
            return ("wiped", nil)
        }
        guard let resolved = provenance.resolved, provenance.live == original else {
            if probeVerdicts[lineageKey(current, currentEmail, OAuth.credentialFingerprint(original) ?? "")] == false {
                return ("known-foreign", nil)
            }
            return ("unresolved", nil)
        }
        let rEmail = resolved.email ?? ""
        let rOrg = resolved.organizationUuid ?? ""
        let rUuid = resolved.uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = Self.record(data, current)
        let ownUuid = Self.str(own, "uuid").trimmingCharacters(in: .whitespacesAndNewlines)
        let ownOrg = Self.str(own, "organizationUuid")
        if !rUuid.isEmpty, !ownUuid.isEmpty, rUuid == ownUuid, rOrg.isEmpty || ownOrg.isEmpty || rOrg == ownOrg {
            return ("own-rotated", nil)
        }
        var slot = rEmail.isEmpty ? nil : Self.findAccountSlot(data, rEmail, rOrg)
        if let s = slot, !rUuid.isEmpty {
            let stored = Self.str(Self.record(data, s), "uuid").trimmingCharacters(in: .whitespacesAndNewlines)
            if !stored.isEmpty, stored != rUuid { slot = nil }
        }
        if slot == nil, !rUuid.isEmpty {
            for entry in Self.accounts(data).entries {
                let acct = entry.value.objectValue
                let uuid = Self.str(acct, "uuid")
                if !uuid.isEmpty, uuid == rUuid, Self.str(acct, "organizationUuid") == rOrg {
                    slot = entry.key
                    break
                }
            }
        }
        if slot == current { return ("own-rotated", nil) }
        guard let foreign = slot else {
            if !rEmail.isEmpty, resolved.organizationUuid != nil { return ("alien", nil) }
            return ("unresolved", nil)
        }
        let storedUuid = Self.str(Self.record(data, foreign), "uuid").trimmingCharacters(in: .whitespacesAndNewlines)
        if rUuid.isEmpty || storedUuid != rUuid { return ("alien", nil) }
        let foreignBackup = readAccountCredentials(foreign, Self.str(Self.record(data, foreign), "email"))
        if !foreignBackup.isEmpty,
           foreignBackup == original || OAuth.credentialFingerprint(foreignBackup) == OAuth.credentialFingerprint(original) {
            return ("foreign-synced", foreign)
        }
        return ("foreign", foreign)
    }

    /// Preserve an unowned live credential before it is overwritten. Throws
    /// on failure: the stash is the licence to overwrite the live store.
    private func stashLiveCredential(_ original: String, _ reason: String, _ current: String, _ resolved: ResolvedIdentity?) throws {
        var mtimeText: JSONValue = .null
        if let mtime = FS.mtime(paths.credentialsPath()) {
            mtimeText = .string(TimeFormat.timestamp(Date(timeIntervalSince1970: mtime)))
        }
        let liveOAuthAccount = (try? readJSON(paths.globalConfigPath()))?["oauthAccount"] ?? .null
        let id = try store.writeUnclaimedCredential(original, context: JSONObject([
            ("reason", .string(reason)),
            ("configSlot", .string(current)),
            ("fingerprint", OAuth.credentialFingerprint(original).map { .string($0) } ?? .null),
            ("liveOauthAccount", liveOAuthAccount),
            ("resolvedIdentity", resolved?.json ?? .null),
            ("credentialsMtime", mtimeText),
        ]))
        log.warning("Live credential does not belong to Account-\(current) (\(reason)): stashed as \(id) (credentials mtime \(mtimeText.stringValue ?? "unknown")). Something outside cswap rewrote the live login after the last switch.")
    }

    private func readTargetCredentials(_ num: String, _ email: String) throws -> String {
        let (creds, unreadable) = store.readAccountCredentialsEx(num, email)
        if !creds.isEmpty { return creds }
        if unreadable {
            throw SwapError.switchFailed("Account-\(num)'s backup is in the macOS Keychain but it is unreadable right now (locked or no GUI session). Retry from a GUI terminal; do not re-add.")
        }
        throw SwapError.switchFailed("Account-\(num) has no stored credentials. Re-add with: cswap --add-account --slot \(num)")
    }

    private func prepareForActivation(_ target: String, _ live: String?) -> String {
        guard let shared = CredentialShape.sharedFields(live) else { return target }
        return CredentialShape.mergeSharedFields(target, shared)
    }

    private func parseTargetConfig(_ num: String, _ email: String) throws -> (JSONObject, JSONValue) {
        let text = readAccountConfig(num, email)
        guard !text.isEmpty else {
            throw SwapError.switchFailed("Account-\(num) has no stored config backup. Re-add with: cswap --add-account --slot \(num)")
        }
        let data: JSONObject
        do {
            guard let obj = try JSONValue.parse(text).objectValue else { throw JSONError.syntax("not an object", offset: 0) }
            data = obj
        } catch {
            throw SwapError.switchFailed("Invalid backup config: \(error)")
        }
        guard let oauthAccount = data["oauthAccount"], oauthAccount.isTruthy else {
            throw SwapError.switchFailed("Invalid oauthAccount in backup")
        }
        return (data, oauthAccount)
    }

    /// Splice `oauthAccount` into the live config, preserving everything
    /// else; an unreadable config is salvaged before it is replaced.
    private func writeLiveConfig(_ configPath: URL, _ oauthAccount: JSONValue, fallback: JSONObject) throws {
        if FS.exists(configPath), var existing = try readJSON(configPath) {
            existing["oauthAccount"] = oauthAccount
            try writeJSON(configPath, existing)
        } else {
            if FS.exists(configPath) { try salvageUnreadable(configPath) }
            try writeJSON(configPath, fallback)
        }
    }

    /// `_perform_switch`, holding cswap's lock and Claude Code's credential
    /// and config locks for the whole mutation (no network inside).
    func performSwitch(_ target: String, provenance given: Provenance? = nil) throws {
        try refuseSessionShell()
        let preEmail = Self.str(Self.record(try getSequenceData(), target), "email")
        if !preEmail.isEmpty {
            let pids = liveSessionPids(target, preEmail)
            if !pids.isEmpty {
                warn("Account-\(target) (\(preEmail)) has a live session-mode Claude instance (PID \(pids.map(String.init).joined(separator: ", "))). Running the same account as both the default login and a session can make one copy's token go stale if the server rotates it. If the session later fails to authenticate, exit it and re-run 'cswap run \(target)'.")
            }
        }
        let provenance = given ?? prefetchLiveIdentity()

        var targetEmail = ""
        var targetOrg = ""
        try FileLock(lockFile).hold {
            try ClaudeLocks.credentialsLock(paths, log: log) {
                try ClaudeLocks.configLock(paths, log: log) {
                    guard var data = try getSequenceData(), let targetRecord = Self.record(data, target) else {
                        throw SwapError.accountNotFound("Account-\(target) does not exist")
                    }
                    targetEmail = Self.str(targetRecord, "email")
                    targetOrg = Self.str(targetRecord, "organizationUuid")
                    var current: String? = data["activeAccountNumber"].flatMap { $0.isNull ? nil : Self.slotKey($0) }
                    let currentIdentity = getCurrentAccount()
                    if let currentIdentity {
                        current = Self.findAccountSlot(data, currentIdentity.email, currentIdentity.org)
                    }
                    let configPath = paths.globalConfigPath()

                    guard let currentIdentity, let current else {
                        try activateDirectly(target, targetEmail, current: current, hasIdentity: currentIdentity != nil, data: &data, configPath: configPath)
                        return
                    }
                    try switchFromManaged(
                        target, targetEmail, current: current, currentEmail: currentIdentity.email,
                        provenance: provenance, data: &data, configPath: configPath
                    )
                }
            }
        }
        replanNewActive(target, targetEmail, targetOrg)
    }

    /// No live managed login (fresh machine, unmanaged login): activate the
    /// stored backup without backing anything up — after stashing whatever
    /// live credential it replaces.
    private func activateDirectly(
        _ target: String, _ targetEmail: String, current: String?, hasIdentity: Bool,
        data: inout JSONObject, configPath: URL
    ) throws {
        let targetCreds = try readTargetCredentials(target, targetEmail)
        let (targetConfig, targetOAuth) = try parseTargetConfig(target, targetEmail)

        guard var rollbackCreds = store.readCredentials() else {
            throw SwapError.credentialRead("Cannot snapshot live credentials before activation")
        }
        var hasRollbackCreds = true
        if !hasIdentity, rollbackCreds.isEmpty { hasRollbackCreds = false }
        var rollbackConfigText: String?
        if FS.exists(configPath) {
            do {
                rollbackConfigText = try FS.readText(configPath)
            } catch {
                throw SwapError.config("Cannot snapshot live config before activation: \(error)")
            }
        }

        if hasRollbackCreds, !rollbackCreds.isEmpty, rollbackCreds != targetCreds {
            do {
                try stashLiveCredential(rollbackCreds, "displaced-live-login", current ?? "unmanaged", nil)
            } catch {
                throw SwapError.switchFailed("Could not preserve the live credential before activation (safety-copy write failed: \(error)); aborting rather than destroying it")
            }
        }
        if !hasRollbackCreds { rollbackCreds = "" }

        var credsWritten = false
        var configWritten = false
        do {
            try store.writeCredentials(prepareForActivation(targetCreds, hasRollbackCreds ? rollbackCreds : nil))
            credsWritten = true
            try writeLiveConfig(configPath, targetOAuth, fallback: targetConfig)
            configWritten = true
            data["activeAccountNumber"] = .int(Int(target) ?? 0)
            data["lastUpdated"] = timestamp()
            try writeJSON(sequenceFile, data)
        } catch {
            if configWritten, let rollbackConfigText {
                do {
                    try FS.writeText(configPath, rollbackConfigText)
                    try FS.chmod(configPath, 0o600)
                } catch {
                    log.error("Failed to rollback config: \(error)")
                }
            }
            if credsWritten, hasRollbackCreds {
                do { try store.writeCredentials(rollbackCreds) } catch { log.error("Failed to rollback credentials: \(error)") }
            }
            throw error
        }
        log.info("Activated account \(target) (no prior live account)")
    }

    private func switchFromManaged(
        _ target: String, _ targetEmail: String, current: String, currentEmail: String,
        provenance: Provenance, data: inout JSONObject, configPath: URL
    ) throws {
        guard let originalCreds = store.readCredentials() else {
            throw SwapError.credentialRead("Failed to read current credentials")
        }
        if originalCreds.isEmpty {
            throw SwapError.credentialRead("Current account credential is empty (Keychain unreadable?); refusing to overwrite its backup")
        }
        guard FS.exists(configPath) else { throw SwapError.config("Claude config file not found") }
        let originalConfig: String
        do {
            originalConfig = try FS.readText(configPath)
        } catch {
            throw SwapError.config("Permission denied reading Claude config")
        }

        var completed: [String] = []
        do {
            let (kind, foreignSlot) = classifyOutgoing(current, currentEmail, originalCreds, provenance, data)
            switch kind {
            case "foreign", "alien", "known-foreign":
                try stashLiveCredential(originalCreds, kind, current, provenance.resolved)
                switch kind {
                case "foreign":
                    warn("Credential ownership mismatch detected. The live credential was preserved and was not written into Account-\(current). If Account-\(foreignSlot ?? "?") later cannot authenticate, log in as it and run: cswap add --slot \(foreignSlot ?? "?")")
                case "known-foreign":
                    warn("The live credential was previously identified as another account's. It was preserved and not written into Account-\(current). If the owning account later cannot authenticate, log in as it and run: cswap add")
                default:
                    warn("The live login does not match a managed account. It was preserved and not written into Account-\(current). If you need that account, log in as it and run: cswap add")
                }
            case "foreign-synced":
                warn("Credential ownership mismatch detected. The live credential already matches Account-\(foreignSlot ?? "?")'s stored backup, so nothing was written into Account-\(current).")
            case "wiped":
                try writeAccountConfig(current, currentEmail, originalConfig)
                warn("The live credential's tokens were wiped (Claude Code clears them when a refresh is rejected). Account-\(current)'s stored backup was kept. If the account cannot authenticate after switching back, log in with Claude Code and run: cswap add")
            case "unresolved":
                try writeAccountCredentials(current, currentEmail, originalCreds)
                try writeAccountConfig(current, currentEmail, originalConfig)
                log.info("Backed up account \(current) (lineage differs from the stored backup and ownership could not be verified — pre-fix backup)")
            case "own-bytes":
                try writeAccountConfig(current, currentEmail, originalConfig)
                log.info("Backed up account \(current) (config only; credentials unchanged)")
            default:
                try writeAccountCredentials(current, currentEmail, originalCreds)
                try writeAccountConfig(current, currentEmail, originalConfig)
                if kind == "own-rotated", let uuid = provenance.resolved?.uuid, !uuid.isEmpty,
                   var acct = Self.record(data, current), Self.str(acct, "uuid").isEmpty {
                    acct["uuid"] = .string(uuid)
                    Self.setRecord(&data, current, acct)
                }
                log.info("Backed up account \(current)")
            }

            let targetCreds = try readTargetCredentials(target, targetEmail)
            if readAccountConfig(target, targetEmail).isEmpty {
                throw SwapError.switchFailed("Account-\(target) has no stored config backup. Re-add with: cswap --add-account --slot \(target)")
            }

            try store.writeCredentials(prepareForActivation(targetCreds, originalCreds))
            completed.append("credentials_written")
            log.info("Wrote target credentials")

            let (targetConfig, targetOAuth) = try parseTargetConfig(target, targetEmail)
            try writeLiveConfig(configPath, targetOAuth, fallback: targetConfig)
            completed.append("config_written")
            log.info("Updated config file")

            data["activeAccountNumber"] = .int(Int(target) ?? 0)
            data["lastUpdated"] = timestamp()
            try writeJSON(sequenceFile, data)
            completed.append("sequence_updated")
            log.info("Switched from account \(current) to \(target)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            log.error("Switch failed: \(message), attempting rollback")
            guard !completed.isEmpty else { throw error }
            if rollback(completed, originalCreds: originalCreds, originalConfig: originalConfig, originalNum: current, configPath: configPath) {
                log.info("Rollback successful")
                throw SwapError.switchFailed("Switch failed and was rolled back: \(message)")
            }
            log.error("Rollback failed!")
            throw SwapError.switchFailed("Switch failed and rollback also failed: \(message). Manual recovery may be needed.")
        }
    }

    /// `SwitchTransaction.rollback`: undo completed steps in reverse.
    private func rollback(_ steps: [String], originalCreds: String, originalConfig: String, originalNum: String, configPath: URL) -> Bool {
        var success = true
        for step in steps.reversed() {
            do {
                switch step {
                case "credentials_written":
                    try store.writeCredentials(originalCreds)
                case "config_written":
                    try FS.writeText(configPath, originalConfig)
                    try FS.chmod(configPath, 0o600)
                case "sequence_updated":
                    if var data = try getSequenceData() {
                        data["activeAccountNumber"] = .int(Int(originalNum) ?? 0)
                        data["lastUpdated"] = timestamp()
                        try writeJSON(sequenceFile, data)
                    }
                default:
                    break
                }
                log.info("Rolled back step: \(step)")
            } catch {
                log.error("Failed to rollback step \(step): \(error)")
                success = false
            }
        }
        return success
    }
}
