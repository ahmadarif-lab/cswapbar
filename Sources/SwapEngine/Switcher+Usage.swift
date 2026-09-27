import Foundation

extension Switcher {
    static let demotingStashReasons: Set<String> = [
        "consume-gate-persist-failed",
        "consume-gate-persist-lock-failed",
        "consume-gate-unpersisted",
        "consume-gate-store-unreadable",
    ]

    var activeReadDegraded: Bool { activeVerdict?.degraded ?? false }
    var activeKeychainUnavailable: Bool { activeVerdict?.keychainUnavailable ?? false }
    var activeReadUnreadable: Bool { activeVerdict.map { $0.value == nil } ?? false }

    // MARK: Accounts

    func buildAccountsInfo() throws -> [AccountInfo] {
        let data = try getSequenceDataMigrated() ?? JSONObject()
        var activeNum: String?
        if let current = getCurrentAccount() {
            activeNum = Self.findAccountSlot(data, current.email, current.org)
        }
        activeVerdict = nil
        var out: [AccountInfo] = []
        for numValue in Self.sequence(data) {
            let key = Self.slotKey(numValue)
            let account = Self.record(data, key) ?? JSONObject()
            let email = account.has("email") ? Self.str(account, "email") : "unknown"
            let isActive = key == activeNum
            let creds: String
            if isActive {
                let active = store.readActiveCredentials()
                creds = active.value ?? ""
                activeVerdict = active
            } else {
                creds = readAccountCredentials(key, email)
            }
            out.append(AccountInfo(
                key: key,
                number: Int(key) ?? 0,
                email: email,
                orgName: Self.str(account, "organizationName"),
                orgUuid: Self.str(account, "organizationUuid"),
                isActive: isActive,
                creds: creds,
                alias: Self.str(account, "alias")
            ))
        }
        return out
    }

    // MARK: Collect

    private func staticUsageSentinel(_ info: AccountInfo) -> String? {
        if CredentialShape.looksLikeAPIKey(info.creds) { return UsageSentinel.apiKey }
        if info.creds.isEmpty || (OAuth.extractAccessToken(info.creds) ?? "").isEmpty {
            if info.isActive, activeKeychainUnavailable || activeReadUnreadable {
                return UsageSentinel.keychainUnavailable
            }
            if !info.isActive, store.readAccountCredentialsEx(info.key, info.email).1 {
                return UsageSentinel.keychainUnavailable
            }
            return UsageSentinel.noCredentials
        }
        return nil
    }

    /// Strike against EVERY stored source: the active slot's recovery path
    /// can bind a strike to its backup as well as to the live credential.
    private func entryTokenDead(_ entry: UsageEntry, _ info: AccountInfo) -> Bool {
        if entry.tokenDead(storedFp: OAuth.credentialFingerprint(info.creds)) { return true }
        if !info.isActive { return false }
        let (backup, unreadable) = store.readAccountCredentialsEx(info.key, info.email)
        if unreadable { return entry.tokenDead() }
        return !backup.isEmpty && entry.tokenDead(storedFp: OAuth.credentialFingerprint(backup))
    }

    /// `_collect_usage_entries(fetch=None)`: every stale account is a
    /// candidate, eligibility decided atomically by the shared store.
    func collectUsageEntries(_ infos: [AccountInfo]) throws -> [String: UsageEntry] {
        var identities: [String: UsageStore.Identity] = [:]
        for info in infos { identities[info.key] = (info.email, info.orgUuid) }
        let models = pollPolicyInputs().models

        var sentinels: [String: String] = [:]
        for info in infos {
            if let s = staticUsageSentinel(info) { sentinels[info.key] = s }
        }

        var entries = usageStore.entries(identities, models: models)
        for info in infos where sentinels[info.key] == nil {
            let entry = entries[info.key] ?? UsageEntry()
            if entryTokenDead(entry, info) {
                sentinels[info.key] = UsageSentinel.reloginRequired
            } else if entry.authDeadStrikes > 0, entry.tokenDead() {
                try usageStore.clearDeadToken([info.key], [info.key: identities[info.key]!])
                entries = usageStore.entries(identities, models: models)
            }
        }

        let requested = infos.map(\.key).filter { sentinels[$0] == nil }
        let claims = try usageStore.reserve(requested, identities, respectPlans: true, repairOverslept: true)

        for info in infos where sentinels[info.key] == nil && info.isActive && claims[info.key] == nil {
            if let activeOAuth = OAuth.extractOAuthData(info.creds), oauth.isTokenExpired(activeOAuth["expiresAt"]) {
                sentinels[info.key] = UsageSentinel.tokenExpired
            }
        }

        if !claims.isEmpty {
            let pre = entries
            let claimed = infos.filter { claims[$0.key] != nil }
            var records: [String: FetchRecord] = [:]
            for (idx, info) in claimed.enumerated() {
                if idx > 0 { Thread.sleep(forTimeInterval: Self.fetchStagger) }
                records[info.key] = fetchAccountUsage(info)
            }
            let plans = plansAfterFetch(records, pre, infos)
            let accepted = try usageStore.record(records, identities, claims: claims, plans: plans)
            for key in accepted {
                if let sentinel = records[key]?.sentinel { sentinels[key] = sentinel }
            }
            entries = usageStore.entries(identities, models: models)
            for info in infos where accepted.contains(info.key) {
                if entryTokenDead(entries[info.key] ?? UsageEntry(), info) {
                    sentinels[info.key] = UsageSentinel.reloginRequired
                }
            }
        }

        var out: [String: UsageEntry] = [:]
        for info in infos {
            var entry = entries[info.key] ?? UsageEntry()
            if let s = sentinels[info.key] { entry.sentinel = s }
            out[info.key] = entry
        }
        return out
    }

    private func plansAfterFetch(
        _ records: [String: FetchRecord],
        _ pre: [String: UsageEntry],
        _ infos: [AccountInfo]
    ) -> [String: (Double?, Double?)] {
        let now = env.epoch
        let (threshold, models) = pollPolicyInputs()
        var plans: [String: (Double?, Double?)] = [:]
        for info in infos {
            guard let rec = records[info.key], rec.sentinel == nil, rec.error == nil else { continue }
            let before = pre[info.key]
            let plan = PollPolicy.planAfterFetch(
                prevInterval: before?.pollIntervalS,
                prevUsage: before?.lastGood,
                newUsage: rec.usage,
                isActive: info.isActive,
                threshold: threshold,
                models: models,
                recent429: before?.recent429(now) ?? false,
                now: now
            )
            plans[info.key] = (plan.nextPollAt, plan.interval)
        }
        return plans
    }

    /// Pull a just-activated account's poll plan to the active floor.
    func replanNewActive(_ num: String, _ email: String, _ orgUuid: String) {
        let identities = [num: (email: email, org: orgUuid)]
        let now = env.epoch
        guard let entry = usageStore.entries(identities)[num], let fetchedAt = entry.fetchedAt else { return }
        let nextPoll = max(now, fetchedAt + PollPolicy.minInterval)
        if let planned = entry.nextPollAt, planned <= nextPoll { return }
        do {
            try usageStore.setPollPlan([num: (nextPoll, PollPolicy.minInterval)], identities)
        } catch {
            log.warning("Post-switch poll re-plan failed (switch itself succeeded): \(error)")
        }
    }

    // MARK: Fetch

    /// One network fetch for one account. Never throws.
    private func fetchAccountUsage(_ info: AccountInfo) -> FetchRecord {
        if info.isActive { return fetchActiveUsage(info.key, info.email, info.creds, info.orgUuid) }

        var hasLiveSession = !liveSessionPids(info.key, info.email).isEmpty
        let dir = sessionDir(info.key, info.email)
        var sessionCreds = Sessions.readSessionCredentials(dir, keychain: keychain)
        if sessionCreds != nil, Sessions.sessionIdentityDrifted(dir, email: info.email, orgUuid: info.orgUuid) {
            sessionCreds = nil
            hasLiveSession = false
        }
        if let sessionCreds, !sessionCreds.isEmpty,
           let sessionOAuth = OAuth.extractOAuthData(sessionCreds),
           let token = sessionOAuth["accessToken"]?.stringValue, !token.isEmpty {
            if !oauth.isTokenExpired(sessionOAuth["expiresAt"]) {
                let outcome = oauth.tryFetchUsageForAccount(accountNum: info.key, email: info.email, credentials: sessionCreds, isActive: true)
                return FetchRecord(usage: outcome.usage, error: outcome.error, retryAfter: outcome.retryAfter)
            }
            if hasLiveSession { return FetchRecord(sentinel: UsageSentinel.tokenExpired) }
        }

        let outcome = oauth.tryFetchUsageForAccount(
            accountNum: info.key,
            email: info.email,
            credentials: info.creds,
            isActive: hasLiveSession,
            refreshVia: hasLiveSession ? nil : { [unowned self] num, email, snapshot in
                self.consumeBackupGrant(num, email, snapshot)
            }
        )
        return FetchRecord(usage: outcome.usage, error: outcome.error, retryAfter: outcome.retryAfter, struckFp: outcome.struckFp)
    }

    /// `_fetch_active_usage`: usage for the live account, refreshing an
    /// expired token under Claude Code's own lock protocol. A live credential
    /// is only consumed or written into the slot backup when its lineage is
    /// attributed to the slot, and a consumed generation is never discarded.
    private func fetchActiveUsage(_ num: String, _ email: String, _ creds: String, _ orgUuid: String) -> FetchRecord {
        guard let oauthData = OAuth.extractOAuthData(creds),
              let token = oauthData["accessToken"], token.isTruthy else {
            return FetchRecord(sentinel: UsageSentinel.noCredentials)
        }
        func deferred(_ record: FetchRecord?) -> FetchRecord {
            record ?? FetchRecord(sentinel: UsageSentinel.tokenExpired)
        }

        var forceRefresh: FetchRecord?
        if !oauth.isTokenExpired(oauthData["expiresAt"]) {
            let outcome = oauth.tryFetchUsageForAccount(accountNum: num, email: email, credentials: creds, isActive: true)
            if outcome.error != "http-401" {
                if outcome.usage != nil {
                    if !activeReadDegraded {
                        resyncRotatedBackup(num, email, orgUuid, creds)
                    }
                    if !probeVerdicts.isEmpty,
                       probeVerdicts[lineageKey(num, email, OAuth.credentialFingerprint(creds) ?? "")] == false {
                        return FetchRecord(sentinel: UsageSentinel.foreignCredential)
                    }
                }
                return FetchRecord(usage: outcome.usage, error: outcome.error, retryAfter: outcome.retryAfter)
            }
            forceRefresh = FetchRecord(error: outcome.error, retryAfter: outcome.retryAfter)
        }

        if activeReadDegraded {
            return deferred(forceRefresh ?? FetchRecord(sentinel: UsageSentinel.keychainUnavailable))
        }
        if env.nonEmptyEnv("CLAUDE_SECURESTORAGE_CONFIG_DIR") != nil {
            log.warning("CLAUDE_SECURESTORAGE_CONFIG_DIR is set; cswap mirrors it when capturing a credential but not when refreshing one, so refusing to refresh account \(num)'s active credential (unset the variable or run from a normal shell).")
            return FetchRecord(error: "store-unmirrored")
        }

        let backup = readAccountCredentials(num, email)
        let backupFp = OAuth.credentialFingerprint(backup)
        let backupOAuth = OAuth.extractOAuthData(backup)
        let backupUsable = backupOAuth?["accessToken"]?.isTruthy == true && backupOAuth?["refreshToken"]?.isTruthy == true
        let attributable = creds == backup || OAuth.credentialFingerprint(creds) == backupFp
        let unattributableKey = "\(num)|\(email)|unattributable"
        if !attributable, !backupUsable {
            if !provenanceWarned.contains(unattributableKey) {
                provenanceWarned.insert(unattributableKey)
                log.warning("Active credential does not match Account-\(num)'s stored backup and the backup is unusable; cannot refresh (provenance unknown).")
            }
            return deferred(forceRefresh)
        }
        provenanceWarned.remove(unattributableKey)

        var working = creds
        do {
            let result: FetchRecord? = try FileLock(credentialsDir.appendingPathComponent(".consume-\(num).lock")).hold {
                try FileLock(lockFile).hold {
                    try ClaudeLocks.credentialsLock(paths, log: log) {
                        try refreshActiveLocked(
                            num: num, email: email, orgUuid: orgUuid, creds: creds,
                            backup: backup, backupFp: backupFp, backupOAuth: backupOAuth,
                            backupUsable: backupUsable, forceRefresh: forceRefresh, working: &working
                        )
                    }
                }
            }
            if let result { return result }
        } catch let error as SwapError where error.isLockError {
            log.info("Credential locks held elsewhere; deferring the active-token refresh for account \(num) to the next pass.")
            return deferred(forceRefresh)
        } catch {
            log.warning("Active-token refresh for account \(num) failed unexpectedly; deferring to the next pass. \(error)")
            return deferred(forceRefresh)
        }

        let outcome = oauth.tryFetchUsageForAccount(accountNum: num, email: email, credentials: working, isActive: true)
        return FetchRecord(usage: outcome.usage, error: outcome.error, retryAfter: outcome.retryAfter)
    }

    /// The locked body of `_fetch_active_usage`. Returns a record to report
    /// immediately, or nil after `working` has been made the live credential.
    private func refreshActiveLocked(
        num: String, email: String, orgUuid: String, creds: String,
        backup: String, backupFp: String?, backupOAuth: JSONObject?, backupUsable: Bool,
        forceRefresh: FetchRecord?, working: inout String
    ) throws -> FetchRecord? {
        func deferred(_ record: FetchRecord?) -> FetchRecord {
            record ?? FetchRecord(sentinel: UsageSentinel.tokenExpired)
        }
        guard let live = store.readCredentials() else { return deferred(forceRefresh) }
        let liveOAuth = live.isEmpty ? nil : OAuth.extractOAuthData(live)
        if !liveIdentityMatches(email, orgUuid) { return deferred(forceRefresh) }

        if let liveOAuth, live != creds,
           liveOAuth["accessToken"]?.isTruthy == true, liveOAuth["refreshToken"]?.isTruthy == true,
           !oauth.isTokenExpired(liveOAuth["expiresAt"]) {
            // A live Claude Code already rotated it: adopt, consume nothing.
            let liveVerdict = probeVerdicts[lineageKey(num, email, OAuth.credentialFingerprint(live) ?? "")]
            if liveVerdict == false { return FetchRecord(sentinel: UsageSentinel.foreignCredential) }
            working = live
            if liveVerdict == true || OAuth.credentialFingerprint(live) == backupFp {
                do {
                    try writeAccountCredentials(num, email, live)
                } catch {
                    log.warning("Backup resync after adopting a rotated credential failed for account \(num); the next expiry may refuse to refresh until a switch resyncs it.")
                }
            }
            return nil
        }

        let refreshInput: String
        if liveOAuth != nil, OAuth.credentialFingerprint(live) == backupFp {
            refreshInput = liveOAuth?["refreshToken"]?.isTruthy == true ? live : (backupUsable ? backup : creds)
        } else if live.isEmpty {
            refreshInput = backupUsable ? backup : creds
        } else if live == creds {
            let liveExp = liveOAuth?["expiresAt"]?.numberValue?.doubleValue ?? 0
            let backupExp = backupOAuth?["expiresAt"]?.numberValue?.doubleValue ?? 0
            if liveOAuth?["refreshToken"]?.isTruthy == true, liveExp > backupExp {
                if probeVerdicts[lineageKey(num, email, OAuth.credentialFingerprint(live) ?? "")] == true {
                    refreshInput = live
                } else {
                    let key = "\(num)|\(email)|expiry-unattributed"
                    if !provenanceWarned.contains(key) {
                        provenanceWarned.insert(key)
                        log.warning("Live credential is newer than Account-\(num)'s backup but its ownership is unverified; refresh deferred to Claude Code's next use.")
                    }
                    return deferred(forceRefresh)
                }
            } else {
                refreshInput = backupUsable ? backup : creds
            }
        } else {
            return deferred(forceRefresh)
        }

        let inputOAuth = OAuth.extractOAuthData(refreshInput)
        var restored = false
        if refreshInput == backup, backupUsable, forceRefresh == nil, inputOAuth != nil,
           !oauth.isTokenExpired(inputOAuth?["expiresAt"]) {
            // The backup already holds a live generation a prior refresh
            // persisted while the live write failed: restore, no POST.
            restored = true
            working = backup
        } else {
            let result = oauth.tryRefresh(refreshInput, timeout: 6)
            if result.error == "invalid_grant" || result.error == "no_refresh_token"
                || (result.error == nil && result.credentials == nil) {
                let sourceNow = refreshInput == backup ? readAccountCredentials(num, email) : (store.readCredentials() ?? "")
                let moved = !sourceNow.isEmpty
                    && OAuth.credentialFingerprint(sourceNow) != OAuth.credentialFingerprint(refreshInput)
                if moved { return FetchRecord(error: "refresh-failed") }
                return FetchRecord(error: result.error ?? "invalid_grant", struckFp: OAuth.credentialFingerprint(refreshInput))
            }
            guard result.error == nil, let fresh = result.credentials else { return FetchRecord(error: "refresh-failed") }
            working = fresh
            probeVerdicts[lineageKey(num, email, OAuth.credentialFingerprint(fresh) ?? "")] = true
            provenanceWarned.remove("\(num)|\(email)|expiry-unattributed")
        }

        var backupOK = true
        if !restored {
            do {
                try writeAccountCredentials(num, email, working)
            } catch {
                backupOK = false
                log.warning("Backup write failed after a consumed refresh for account \(num); attempting the active store.")
            }
        }
        do {
            let toWrite = working
            try ClaudeLocks.configLock(paths, log: log) { try store.writeCredentials(toWrite) }
        } catch {
            log.warning("Active-store write failed after a \(restored ? "backup restore" : "consumed refresh") for account \(num)\(backupOK ? "" : "; the rotated credential was NOT persisted anywhere — re-login may be required").")
            return FetchRecord(sentinel: UsageSentinel.tokenExpired)
        }
        return nil
    }

    /// Resync the slot backup after a rotation that completed elsewhere, once
    /// the profile oracle attributes the drifted lineage to the slot.
    private func resyncRotatedBackup(_ num: String, _ email: String, _ orgUuid: String, _ creds: String) {
        guard let credsOAuth = OAuth.extractOAuthData(creds),
              credsOAuth["accessToken"]?.isTruthy == true, credsOAuth["refreshToken"]?.isTruthy == true else { return }
        let backup = readAccountCredentials(num, email)
        if !backup.isEmpty, OAuth.credentialFingerprint(creds) == OAuth.credentialFingerprint(backup) { return }
        let fp = OAuth.credentialFingerprint(creds) ?? ""
        let verdict = probeVerdicts[lineageKey(num, email, fp)]
        if verdict == false { return }
        if verdict != true {
            guard let resolved = oauth.fetchProfile(OAuth.extractAccessToken(creds) ?? "") else { return }
            guard let match = resolvedMatchesSlotIdentity(num, resolved) else { return }
            probeVerdicts[lineageKey(num, email, fp)] = match
            let key = "\(num)|\(email)|resync"
            if !match {
                if !provenanceWarned.contains(key) {
                    provenanceWarned.insert(key)
                    log.warning("Live credential resolves to a different account than Account-\(num)'s identity; backup left untouched (foreign credential under a stale config).")
                }
                return
            }
            provenanceWarned.remove(key)
        }
        do {
            try FileLock(lockFile).hold {
                try ClaudeLocks.credentialsLock(paths, log: log) {
                    guard liveIdentityMatches(email, orgUuid) else { return }
                    guard probeVerdicts[lineageKey(num, email, fp)] == true else { return }
                    guard let live = store.readCredentials(), !live.isEmpty,
                          let liveOAuth = OAuth.extractOAuthData(live),
                          liveOAuth["accessToken"]?.isTruthy == true, liveOAuth["refreshToken"]?.isTruthy == true,
                          OAuth.credentialFingerprint(live) == OAuth.credentialFingerprint(creds) else { return }
                    try writeAccountCredentials(num, email, live)
                    log.info("Resynced account \(num)'s backup to the rotated live credential (rotation completed outside a collect pass).")
                }
            }
        } catch let error as SwapError where error.isLockError {
            return
        } catch {
            log.warning("Backup resync for account \(num) failed; the recovery branch's newer-generation check still guards the next expiry. \(error)")
        }
    }

    // MARK: Consume gate

    /// The gate through which a backup refresh token is consumed: re-read the
    /// freshest copy under the slot lock, POST outside it, then CAS on the
    /// refresh-token fingerprint and persist — or stash the successor so a
    /// consumed generation is never lost.
    func consumeBackupGrant(_ num: String, _ email: String, _ snapshot: String) -> RefreshOutcome {
        if env.nonEmptyEnv("CLAUDE_SECURESTORAGE_CONFIG_DIR") != nil {
            log.warning("CLAUDE_SECURESTORAGE_CONFIG_DIR is set; cswap mirrors it when capturing a credential but not when consuming one, so refusing to consume account \(num)'s refresh token (unset the variable or run from a normal shell).")
            return RefreshOutcome(error: "store-unmirrored")
        }
        let consumeLock = FileLock(credentialsDir.appendingPathComponent(".consume-\(num).lock"))
        guard consumeLock.acquire() else {
            log.info("Another consume is in flight for account \(num); deferring to the next pass.")
            return RefreshOutcome(error: "consume-busy")
        }
        defer { consumeLock.release() }
        return consumeBackupGrantLocked(num, email, snapshot)
    }

    private func consumeBackupGrantLocked(_ num: String, _ email: String, _ snapshot: String) -> RefreshOutcome {
        var refreshInput = ""
        var inputOAuth: JSONObject?
        var consumedFp: String?
        do {
            let early: RefreshOutcome? = try FileLock(lockFile).hold {
                var (current, unreadable) = store.readAccountCredentialsEx(num, email)
                if unreadable {
                    log.info("Backup for account \(num) unreadable (keychain); deferring the refresh.")
                    return RefreshOutcome(error: "transient")
                }
                do {
                    if let adopted = try adoptStashedSuccessor(num, email, current) { current = adopted }
                } catch let error as SwapError {
                    guard case .credentialRead = error else { throw error }
                    log.info("Account \(num)'s stashed successor is unreadable; deferring the refresh.")
                    return RefreshOutcome(error: "stash-unreadable")
                }
                if current.isEmpty {
                    log.info("Account \(num)'s stored credential is gone; deferring the refresh rather than consuming a grant for a slot that no longer exists.")
                    return RefreshOutcome(error: "transient")
                }
                refreshInput = current
                inputOAuth = OAuth.extractOAuthData(refreshInput)
                let orgUuid = Self.str(Self.record(try getSequenceData(), num), "organizationUuid")
                if liveSessionPids(num, email).isEmpty {
                    let dir = sessionDir(num, email)
                    if let profile = Sessions.readSessionCredentials(dir, keychain: keychain), !profile.isEmpty,
                       !Sessions.isSessionStale(dir),
                       !Sessions.sessionIdentityDrifted(dir, email: email, orgUuid: orgUuid),
                       let profOAuth = OAuth.extractOAuthData(profile),
                       profOAuth["accessToken"]?.isTruthy == true, profOAuth["refreshToken"]?.isTruthy == true,
                       OAuth.credentialFingerprint(profile) != OAuth.credentialFingerprint(refreshInput),
                       (profOAuth["expiresAt"]?.numberValue?.doubleValue ?? 0) > (inputOAuth?["expiresAt"]?.numberValue?.doubleValue ?? 0) {
                        try writeAccountCredentials(num, email, profile)
                        refreshInput = profile
                        inputOAuth = profOAuth
                    }
                }
                consumedFp = OAuth.credentialFingerprint(refreshInput)
                return nil
            }
            if let early { return early }
        } catch let error as SwapError where error.isLockError {
            log.info("Slot lock held elsewhere; deferring account \(num)'s backup refresh to the next pass.")
            return RefreshOutcome(error: "transient")
        } catch {
            log.warning("Pre-consume window failed for account \(num); deferring. \(error)")
            return RefreshOutcome(error: "transient")
        }

        let snapToken = OAuth.extractOAuthData(snapshot)?["accessToken"]
        if let inputToken = inputOAuth?["accessToken"], inputToken.isTruthy,
           let snapToken, snapToken.isTruthy, inputToken != snapToken,
           !oauth.isTokenExpired(inputOAuth?["expiresAt"]) {
            // The world already moved past the caller's snapshot and the
            // current generation is fresh: adopt it, consume nothing.
            return RefreshOutcome(credentials: refreshInput, error: nil, consumedFp: consumedFp)
        }

        var result = oauth.tryRefresh(refreshInput)
        guard result.error == nil, let successor = result.credentials else {
            result.consumedFp = consumedFp
            return result
        }

        var stashedReason = ""
        func stashSuccessor(_ reason: String, _ note: String) throws {
            _ = try store.writeUnclaimedCredential(successor, context: JSONObject([
                ("reason", .string(reason)),
                ("configSlot", .string(num)),
                ("consumedFp", consumedFp.map { .string($0) } ?? .null),
                ("fingerprint", OAuth.credentialFingerprint(successor).map { .string($0) } ?? .null),
            ]))
            stashedReason = reason
            log.warning(note)
        }

        var outcomeCreds = successor
        do {
            do {
                try FileLock(lockFile).hold {
                    let (storeNow, storeUnreadable) = store.readAccountCredentialsEx(num, email)
                    if storeUnreadable {
                        try stashSuccessor("consume-gate-store-unreadable", "Account \(num)'s stored credential was unreadable (keychain) after a refresh POST; successor stashed, nothing rewritten.")
                    } else if storeNow.isEmpty {
                        try stashSuccessor("consume-gate-slot-removed", "Account \(num)'s stored credential disappeared during a refresh POST; successor stashed, nothing rewritten.")
                    } else if OAuth.credentialFingerprint(storeNow) != consumedFp {
                        try stashSuccessor("consume-gate-cas-conflict", "Backup lineage for account \(num) moved during a refresh POST; successor stashed, adopting the newer store credential.")
                        outcomeCreds = storeNow
                    } else {
                        try writeAccountCredentials(num, email, successor)
                    }
                }
            } catch let error as SwapError where error.isLockError {
                try stashSuccessor("consume-gate-persist-lock-failed", "Slot lock unavailable after consuming account \(num)'s grant; successor stashed for the next pass.")
            }
        } catch {
            log.warning("Persisting account \(num)'s refreshed credential failed; stashing instead. \(error)")
            do {
                try stashSuccessor("consume-gate-persist-failed", "Persist failed after consuming account \(num)'s grant; successor stashed for the next pass.")
            } catch {
                stashedReason = "consume-gate-unpersisted"
                log.error("Account \(num)'s consumed successor could not be persisted or stashed — it survives only for this pass. Fix the storage failure, then re-login and `cswap add` if the slot strikes. \(error)")
            }
        }
        if Self.demotingStashReasons.contains(stashedReason) {
            return RefreshOutcome(
                credentials: outcomeCreds, error: "transient", tokenAccount: result.tokenAccount,
                consumedFp: consumedFp, stashed: stashedReason != "consume-gate-unpersisted"
            )
        }
        return RefreshOutcome(credentials: outcomeCreds, error: nil, tokenAccount: result.tokenAccount, consumedFp: consumedFp)
    }

    private func retireStashEntry(_ id: String, _ num: String) {
        do {
            try store.removeUnclaimedCredential(id)
        } catch {
            log.warning("Could not retire account \(num)'s stash entry \(id); leaving it for the next pass (`cswap unclaimed --purge` drops it by hand). \(error)")
        }
    }

    /// Complete a prior gate's failed persist from the unclaimed stash.
    /// Caller holds the slot lock.
    private func adoptStashedSuccessor(_ num: String, _ email: String, _ current: String) throws -> String? {
        guard let curFp = OAuth.credentialFingerprint(current) else { return nil }
        var deferredEntry: String?
        let (manifest, verdict) = store.readStashManifestEx()
        if verdict == .unreadable || (verdict == .corrupt && store.stashEntryFilesExist()) {
            throw SwapError.credentialRead("the unclaimed manifest is \(verdict) and stashed entry files exist; deferring account \(num)'s adoption rather than POSTing a generation a stashed successor may already have superseded (`cswap unclaimed` lists them, `--purge` drops one)")
        }
        for entry in manifest.entries {
            guard let meta = entry.value.objectValue, meta["configSlot"] == .string(num) else { continue }
            if meta["consumedFp"] != .string(curFp) {
                if meta["reason"] == .string("consume-gate-cas-conflict") {
                    retireStashEntry(entry.key, num)
                    log.info("Retired account \(num)'s CAS-conflict stash entry: its generation was superseded by the writer that won the race, so no pass can ever adopt it.")
                } else {
                    let (bytes, unreadable) = store.readUnclaimedCredential(entry.key)
                    if bytes.isEmpty, !unreadable {
                        retireStashEntry(entry.key, num)
                        log.info("Retired account \(num)'s byte-less stash entry: its credential is gone and its generation has passed, so no pass could ever adopt it.")
                    }
                }
                continue
            }
            let (creds, unreadable) = store.readUnclaimedCredential(entry.key)
            if unreadable {
                if deferredEntry == nil { deferredEntry = entry.key }
                continue
            }
            if creds.isEmpty {
                retireStashEntry(entry.key, num)
                log.info("Retired account \(num)'s unreadable-bytes stash entry: its generation is gone, so no pass could ever adopt it.")
                continue
            }
            try writeAccountCredentials(num, email, creds)
            retireStashEntry(entry.key, num)
            log.info("Adopted account \(num)'s stashed successor (\(meta["reason"]?.stringValue ?? "unknown")): the stored generation was already consumed by the gate pass that stashed it.")
            return creds
        }
        if let deferredEntry {
            throw SwapError.credentialRead("stash entry \(deferredEntry) for account \(num) is unreadable; deferring adoption rather than discarding its generation")
        }
        return nil
    }

    // MARK: List

    /// `list_accounts(json_output=True)`.
    func listAccounts() throws -> ListResponse {
        guard FS.exists(sequenceFile) else {
            return ListResponse(schemaVersion: 1, activeAccountNumber: nil, accounts: [])
        }
        let infos = try buildAccountsInfo()
        let entries = try collectUsageEntries(infos)
        let seqData = try getSequenceData()
        var activeNum: Int?
        var accounts: [Account] = []
        for info in infos {
            if info.isActive { activeNum = info.number }
            let entry = entries[info.key] ?? UsageEntry()
            accounts.append(accountRow(info, entry, disabled: Self.disabledFromData(seqData, info.key)))
        }
        return ListResponse(schemaVersion: 1, activeAccountNumber: activeNum, accounts: accounts)
    }

    private func accountRow(_ info: AccountInfo, _ entry: UsageEntry, disabled: Bool) -> Account {
        let status: String
        var usage: Usage?
        switch entry.decisionValue() {
        case .usage(let value):
            status = "ok"
            usage = usageToModel(value, fetchedAt: entry.fetchedAt)
        case .sentinel(let s):
            switch s {
            case UsageSentinel.tokenExpired: status = "token_expired"
            case UsageSentinel.apiKey: status = "api_key"
            case UsageSentinel.keychainUnavailable: status = "keychain_unavailable"
            case UsageSentinel.reloginRequired: status = "relogin_required"
            case UsageSentinel.foreignCredential: status = "foreign_credential"
            default: status = "no_credentials"
            }
        case .unknown:
            status = "unavailable"
        }
        var fetchedAtText: String?
        var ageS: Double?
        if usage != nil, let fetchedAt = entry.fetchedAt {
            fetchedAtText = TimeFormat.isoSecondsZ(fetchedAt)
            ageS = entry.ageS.map(Self.pyRound1)
        }
        var lastGood: Usage?
        var lastGoodAtText: String?
        var lastGoodAgeS: Double?
        if usage == nil, let value = entry.lastGood, value.objectValue != nil, let fetchedAt = entry.fetchedAt {
            lastGood = usageToModel(value, fetchedAt: fetchedAt)
            lastGoodAtText = TimeFormat.isoSecondsZ(fetchedAt)
            lastGoodAgeS = entry.ageS.map(Self.pyRound1)
        }
        return Account(
            number: info.number,
            email: info.email,
            organizationName: info.orgName,
            organizationUuid: info.orgUuid,
            isOrganization: !info.orgUuid.isEmpty,
            active: info.isActive,
            usageStatus: status,
            usage: usage,
            usageFetchedAt: fetchedAtText,
            usageAgeSeconds: ageS,
            lastGoodUsage: lastGood,
            lastGoodFetchedAt: lastGoodAtText,
            lastGoodAgeSeconds: lastGoodAgeS,
            disabled: disabled ? true : nil,
            alias: info.alias.isEmpty ? nil : info.alias
        )
    }

    /// Python's `round(x, 1)`: correctly rounded, ties to even.
    static func pyRound1(_ x: Double) -> Double {
        Double(String(format: "%.1f", x)) ?? x
    }

    private func usageToModel(_ usage: JSONValue, fetchedAt: Double?) -> Usage {
        let u = usage.objectValue
        return Usage(
            fiveHour: u?["five_hour"]?.objectValue.map { windowToModel($0, fetchedAt: nil) },
            sevenDay: u?["seven_day"]?.objectValue.map { windowToModel($0, fetchedAt: fetchedAt) }
        )
    }

    /// `_window_to_json`, plus the weekly pace fields when `fetchedAt` is set.
    private func windowToModel(_ w: JSONObject, fetchedAt: Double?) -> UsageWindow {
        let cell = oauth.freshResetStrings(w)
        var expected: Double?, ahead: Bool?, exhaustion: String?, willLast: Bool?
        if let fetchedAt, let pace = Pace.compute(w, fetchedAt: fetchedAt) {
            expected = Self.pyRound1(pace.expectedPct)
            ahead = pace.ahead
            exhaustion = Pace.projectedExhaustion(pace, fetchedAt: fetchedAt).map(TimeFormat.isoSecondsZ)
            willLast = Pace.willLastToReset(pace)
        }
        return UsageWindow(
            pct: w["pct"]?.numberValue?.doubleValue,
            resetsAt: w["resets_at"]?.stringValue,
            countdown: cell?.countdown,
            clock: cell?.clock,
            expectedPct: expected,
            aheadOfPace: ahead,
            projectedExhaustionAt: exhaustion,
            willLastToReset: willLast
        )
    }
}
