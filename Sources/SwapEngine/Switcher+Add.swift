import Foundation

extension Switcher {
    // MARK: Capture

    /// Refuse to capture bytes a degraded read produced: on macOS the
    /// plaintext fallback may be the consumed predecessor.
    private func refuseDegradedCapture() throws -> String? {
        let active = store.readActiveCredentials()
        if active.degraded {
            throw SwapError.credentialRead(
                "The macOS Keychain is unreadable right now (locked or no GUI session), so the only readable credential is a plaintext fallback that may be a superseded generation — capturing it would file a spent refresh token against this slot. Retry from a GUI terminal."
            )
        }
        return active.value
    }

    /// The credential of the profile the environment points at, resolved the
    /// way Claude Code resolves it, so a slot's email and token come from one
    /// profile.
    func readCaptureCredentials() throws -> String? {
        let secureEnv = env.envValue("CLAUDE_SECURESTORAGE_CONFIG_DIR")
        let configDir = env.nonEmptyEnv("CLAUDE_CONFIG_DIR")
        if let secureEnv {
            let creds = try Sessions.readConfigDirCredentials(
                secureEnv.isEmpty ? paths.defaultClaudeConfigHome().path : secureEnv,
                keychain: keychain,
                strictKeychain: true,
                keychainService: secureEnv.isEmpty ? KeychainService.claudeCode : nil
            )
            return (creds?.isEmpty ?? true) ? "" : creds
        }
        guard let configDir else { return try refuseDegradedCapture() }
        if let creds = try Sessions.readConfigDirCredentials(configDir, keychain: keychain, strictKeychain: true), !creds.isEmpty {
            return creds
        }
        let a = URL(fileURLWithPath: configDir).resolvingSymlinksInPath().standardizedFileURL.path
        let b = paths.defaultClaudeConfigHome().resolvingSymlinksInPath().standardizedFileURL.path
        if a == b { return try refuseDegradedCapture() }
        return (try? readJSON(paths.globalConfigPath()))?["primaryApiKey"]?.stringValue ?? ""
    }

    private func rejectLiveAPIKeyCapture(_ creds: String) throws {
        if CredentialShape.looksLikeAPIKey(creds) {
            throw SwapError.validation("Active login is an API-key account. Add it with 'cswap --add-token sk-ant-api...' instead of --add-account.")
        }
    }

    /// The stored token must be THIS account's: identity comes from
    /// `~/.claude.json`, the token from the credential store, and nothing else
    /// makes them agree. Advisory — an unresolvable lookup never blocks.
    private func rejectForeignCredentialCapture(_ creds: String, _ email: String, _ orgUuid: String, _ accountUuid: String) throws -> String {
        func unverified(_ why: String) -> String {
            warn("Notice: could not verify that the stored credential belongs to \(email) (\(why)). Registering anyway; re-run where the check can complete to confirm.")
            return creds
        }
        guard let token = OAuth.extractAccessToken(creds), !token.isEmpty else {
            return unverified("no access token to resolve")
        }
        if let data = OAuth.extractOAuthData(creds), oauth.isTokenExpired(data["expiresAt"]) {
            return unverified("the access token is expired")
        }
        guard let profile = oauth.fetchProfile(token) else {
            return unverified("the identity lookup did not resolve")
        }
        let seenUuid = profile.uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !accountUuid.isEmpty {
            if seenUuid != accountUuid {
                throw SwapError.config("The stored credential does not belong to \(email): the token resolves to account \(seenUuid), not \(accountUuid). Nothing was changed. This happens when the config names one account while the credential store still holds another's token (e.g. a renamed .claude.json over a live keychain item). Log in as \(email) in THIS environment, then re-run.")
            }
        } else {
            let seen = (profile.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.isEmpty { return unverified("the resolved identity carries no address") }
            if seen.lowercased() != email.lowercased() {
                throw SwapError.config("The stored credential does not belong to \(email): the token resolves to \(seen). Nothing was changed. This happens when the config names one account while the credential store still holds another's token (e.g. a renamed .claude.json over a live keychain item). Log in as \(email) in THIS environment, then re-run.")
            }
        }
        guard let resolvedOrg = profile.organizationUuid else { return creds }
        let seenOrg = resolvedOrg.trimmingCharacters(in: .whitespacesAndNewlines)
        if seenOrg == orgUuid { return creds }
        let seenLabel = seenOrg.isEmpty ? "personal" : seenOrg
        let orgLabel = orgUuid.isEmpty ? "personal" : orgUuid
        throw SwapError.config("The stored credential for \(email) belongs to organization \(seenLabel), not \(orgLabel). Nothing was changed. Two accounts can share an email across organizations. Log in as \(email) in the \(orgLabel) organization in THIS environment, then re-run.")
    }

    private func rejectCredentialDriftSinceVerify(_ verified: String) throws {
        // Unreadable is unverifiable, never a refusal.
        let now: String?
        do { now = try readCaptureCredentials() } catch { return }
        guard let now, !now.isEmpty else { return }
        let before = OAuth.credentialFingerprint(verified)
        let after = OAuth.credentialFingerprint(now)
        if before == nil || after == nil || before == after { return }
        throw SwapError.config("The stored credential rotated while it was being verified. Nothing was changed. Registering the pre-rotation generation would hand the slot a credential the server has already retired. Re-run when no refresh is in flight.")
    }

    private func rejectIdentityDriftSinceVerify(_ verified: (email: String, org: String, uuid: String)) throws {
        let now = getCurrentIdentityTriple()
        if let now, now == verified { return }
        let nowEmail = now?.email ?? ""
        throw SwapError.config("The active account changed while \(verified.email) was being verified (now \(nowEmail.isEmpty ? "unknown" : nowEmail)). Nothing was changed. Re-run when no other login is in flight.")
    }

    /// Live credential for the identity just read, with every guard applied.
    private func captureVerifiedCredentials(_ identity: (email: String, org: String, uuid: String)) throws -> String {
        guard let raw = try readCaptureCredentials() else {
            throw SwapError.credentialRead("Failed to read credentials for current account")
        }
        if raw.isEmpty { throw SwapError.credentialRead("No credentials found for current account") }
        try rejectLiveAPIKeyCapture(raw)
        let creds = try rejectForeignCredentialCapture(raw, identity.email, identity.org, identity.uuid)
        try rejectCredentialDriftSinceVerify(creds)
        return creds
    }

    private func readLiveConfigText() throws -> String {
        let path = paths.globalConfigPath()
        guard FS.exists(path) else { throw SwapError.config("Claude config file not found") }
        do {
            return try FS.readText(path)
        } catch {
            throw SwapError.config("Permission denied reading Claude config")
        }
    }

    // MARK: add

    /// `add_account()` as the GUIs call it: no slot, no alias. An account
    /// that is already managed has its stored login refreshed in place.
    func addAccount() throws {
        try refuseSessionShell()
        try setupDirectories()
        try initSequenceFile()
        try migrateOrgFields()

        guard let identity = getCurrentIdentityTriple() else {
            throw SwapError.config("No active Claude account found. Please log in first.")
        }

        if try accountExists(identity.email, identity.org) {
            guard var seq = try getSequenceData(), let num = Self.findAccountSlot(seq, identity.email, identity.org) else {
                throw SwapError.config("Existing account metadata for \(identity.email) is inconsistent")
            }
            let creds = try captureVerifiedCredentials(identity)
            let config = try readLiveConfigText()
            try rejectIdentityDriftSinceVerify(identity)

            try writeAccountCredentials(num, identity.email, creds)
            try writeAccountConfig(num, identity.email, config)
            try usageStore.clearDeadToken([num], [num: (identity.email, identity.org)])
            seq["activeAccountNumber"] = .int(Int(num) ?? 0)
            seq["lastUpdated"] = timestamp()
            try writeJSON(sequenceFile, seq)
            log.info("Updated credentials for account \(num): \(identity.email)")
            return
        }

        let num = String(try getNextAccountNumber())
        let creds = try captureVerifiedCredentials(identity)
        let config = try readLiveConfigText()
        let oauthAccount = (try? readJSON(paths.globalConfigPath()))?["oauthAccount"]?.objectValue
        let accountUuid = Self.str(oauthAccount, "accountUuid")
        let orgUuid = Self.str(oauthAccount, "organizationUuid")
        let orgName = Self.str(oauthAccount, "organizationName")
        try rejectIdentityDriftSinceVerify(identity)

        try writeAccountCredentials(num, identity.email, creds)
        try writeAccountConfig(num, identity.email, config)
        try usageStore.clearDeadToken([num], [num: (identity.email, orgUuid)])

        guard var data = try getSequenceData() else { throw SwapError.config("No accounts are managed yet") }
        Self.setRecord(&data, num, JSONObject([
            ("email", .string(identity.email)),
            ("uuid", .string(accountUuid)),
            ("organizationUuid", .string(orgUuid)),
            ("organizationName", .string(orgName)),
            ("added", timestamp()),
        ]))
        appendToSequence(&data, num)
        data["activeAccountNumber"] = .int(Int(num) ?? 0)
        data["lastUpdated"] = timestamp()
        try writeJSON(sequenceFile, data)
        log.info("Added account \(num): \(identity.email) (org: \(orgUuid.isEmpty ? "personal" : orgUuid))")
    }

    private func appendToSequence(_ data: inout JSONObject, _ num: String) {
        var seq = Self.sequence(data)
        guard !seq.contains(where: { Self.slotKey($0) == num }) else { return }
        seq.append(.int(Int(num) ?? 0))
        seq.sort { (Double(Self.slotKey($0)) ?? 0) < (Double(Self.slotKey($1)) ?? 0) }
        data["sequence"] = .array(seq)
    }

    private func removeFromSequence(_ data: inout JSONObject, _ num: String) {
        data["sequence"] = .array(Self.sequence(data).filter { Self.slotKey($0) != num })
    }

    // MARK: add-token

    /// Register a setup-token (or `sk-ant-api…` managed key) without a
    /// login on this machine. No Anthropic API calls are made.
    func addAccountFromToken(_ rawToken: String, email rawEmail: String?) throws {
        try refuseSessionShell()
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SwapError.validation("Token cannot be empty") }
        let isAPIKey = CredentialShape.looksLikeAPIKey(token)
        var email = rawEmail ?? ""
        if !email.isEmpty, !Self.validateEmail(email) {
            throw SwapError.validation("Invalid email format: \(email)")
        }

        try setupDirectories()
        try initSequenceFile()
        try migrateOrgFields()

        var slot: Int?
        if email.isEmpty {
            slot = try getNextAccountNumber()
            email = "\(isAPIKey ? "api-key" : "setup-token")-\(slot!)@token.local"
        }
        try rejectCrossKindCollision(email, isAPIKey)

        let credentials: String
        if isAPIKey {
            credentials = token
        } else {
            credentials = JSONValue.object(JSONObject([
                ("claudeAiOauth", .object(JSONObject([
                    ("accessToken", .string(token)),
                    ("scopes", .array(Self.setupTokenScopes.map { .string($0) })),
                ]))),
            ])).serialized()
        }
        let config = JSONValue.object(JSONObject([
            ("oauthAccount", .object(JSONObject([
                ("emailAddress", .string(email)),
                ("accountUuid", .string("")),
                ("organizationUuid", .null),
                ("organizationName", .null),
            ]))),
        ])).serialized()

        if slot == nil, try accountExists(email, "") {
            guard var seq = try getSequenceData(), let num = Self.findAccountSlot(seq, email, "") else {
                throw SwapError.config("Existing account metadata for \(email) is inconsistent")
            }
            try writeAccountCredentials(num, email, credentials)
            try writeAccountConfig(num, email, config)
            try usageStore.clearDeadToken([num], [num: (email, "")])
            seq["lastUpdated"] = timestamp()
            try writeJSON(sequenceFile, seq)
            log.info("Updated \(isAPIKey ? "API key" : "token") for account \(num): \(email)")
            return
        }

        let num: String
        var migrateFrom: String?
        if let slot {
            num = String(slot)
            let data = try getSequenceData()
            if try accountExists(email, ""), let old = Self.findAccountSlot(data, email, ""), old != num {
                migrateFrom = old
            }
            if let existing = Self.record(data, num),
               !(existing["email"] == .string(email) && (existing["organizationUuid"] ?? .string("")) == .string("")) {
                throw SwapError.config("Slot \(slot) already occupied")
            }
        } else {
            num = String(try getNextAccountNumber())
        }

        if let migrateFrom, var data = try getSequenceData() {
            let oldEmail = Self.str(Self.record(data, migrateFrom), "email")
            try deleteAccountFiles(migrateFrom, oldEmail)
            removeFromSequence(&data, migrateFrom)
            Self.setRecord(&data, migrateFrom, nil)
            try writeJSON(sequenceFile, data)
        }

        try writeAccountCredentials(num, email, credentials)
        try writeAccountConfig(num, email, config)
        try usageStore.clearDeadToken([num], [num: (email, "")])

        guard var data = try getSequenceData() else { throw SwapError.config("No accounts are managed yet") }
        var record = JSONObject([
            ("email", .string(email)),
            ("uuid", .string("")),
            ("organizationUuid", .string("")),
            ("organizationName", .string("")),
            ("added", timestamp()),
        ])
        if isAPIKey { record["kind"] = .string("api_key") }
        Self.setRecord(&data, num, record)
        appendToSequence(&data, num)
        data["lastUpdated"] = timestamp()
        try writeJSON(sequenceFile, data)
        log.info("Added account \(num) from \(isAPIKey ? "API key" : "token"): \(email)")
    }

    private func rejectCrossKindCollision(_ email: String, _ isAPIKey: Bool) throws {
        guard let data = try getSequenceData(), let slot = Self.findAccountSlot(data, email, "") else { return }
        let existing = try accountKind(slot)
        let newKind = isAPIKey ? "api_key" : "oauth"
        guard existing != newKind else { return }
        let existingLabel = existing == "api_key" ? "API-key" : "OAuth"
        let newLabel = isAPIKey ? "API-key" : "OAuth"
        throw SwapError.validation("'\(email)' already exists as an \(existingLabel) account (slot \(slot)); cannot add it as an \(newLabel) account. Pass a distinct --email.")
    }
}
