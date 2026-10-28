import Foundation

/// Session-profile credential adoption (`_session_profile_ahead` and
/// `_adopt_session_credential`). Claude Code rotates the token family inside
/// a `cswap run` profile and the backup never follows, so after any session
/// that refreshed, the backup holds a consumed generation: activated, its
/// first refresh gets `invalid_grant` and the login is wiped.
extension Switcher {
    /// The profile's credential when it is a newer generation of this slot's
    /// family than the stored backup, else nil. Nil for a profile an
    /// in-session /login re-pointed at another account, one flagged stale,
    /// and anything unreadable (a read error is not evidence of drift).
    func sessionProfileAhead(_ num: String, _ email: String, _ orgUuid: String) -> String? {
        let dir = sessionDir(num, email)
        if Sessions.isSessionStale(dir) { return nil }
        guard let profile = Sessions.readSessionCredentials(dir, keychain: keychain), !profile.isEmpty,
              !Sessions.sessionIdentityDrifted(dir, email: email, orgUuid: orgUuid) else { return nil }
        let (backup, unreadable) = store.readAccountCredentialsEx(num, email)
        if unreadable { return nil }
        if OAuth.credentialFingerprint(profile) == OAuth.credentialFingerprint(backup) { return nil }
        let issued = OAuth.extractOAuthData(profile)?["expiresAt"]?.numberValue?.doubleValue ?? 0
        let stored = OAuth.extractOAuthData(backup)?["expiresAt"]?.numberValue?.doubleValue ?? 0
        return issued > stored ? profile : nil
    }

    /// Capture a quiescent profile's credential into the slot backup.
    /// Tri-state: true = backup advanced; false = profile is not ahead (the
    /// backup is the truth); nil = undecidable and nothing was written (a
    /// claude is live against it, a record or the profile identity could not
    /// be read). Decided and written under cswap's own lock; the store write
    /// is the pure one, since `writeAccountCredentials` would invalidate the
    /// very profile just captured.
    func adoptSessionCredential(_ num: String, _ email: String, _ orgUuid: String) throws -> Bool? {
        let dir = sessionDir(num, email)
        let adopted: Bool? = try FileLock(lockFile).hold {
            guard Sessions.profileIsQuiescent(dir) else { return nil }
            guard let profile = sessionProfileAhead(num, email, orgUuid) else { return false }
            // This is a WRITE: it needs positive evidence of whose profile it is.
            guard Sessions.readSessionIdentity(dir) != nil else { return nil }
            try store.writeAccountCredentials(num, email, profile)
            return true
        }
        if adopted == true {
            log.info("Adopted account \(num)'s session profile credential into its backup")
        }
        return adopted
    }

    /// The switch-time guard: refuse to activate a consumed generation, warn
    /// about the two-copies hazard, and adopt an exited session's credential
    /// first so the switch activates the live generation.
    func guardSessionDrift(onSwitchTo target: String, email: String, orgUuid: String) throws {
        let (pids, unreadable) = Sessions.scanLiveSessions(sessionDir(target, email))
        if !pids.isEmpty || unreadable > 0 {
            if sessionProfileAhead(target, email, orgUuid) != nil {
                let who = pids.isEmpty
                    ? "\(unreadable) session record(s) that could not be read"
                    : "a live session-mode Claude instance (PID \(pids.map(String.init).joined(separator: ", ")))"
                throw SwapError.switchFailed("Account-\(target) (\(email)) has \(who), and its session profile's credential has rotated past the stored backup: the backup is a consumed generation, and activating it would fail with invalid_grant on its first refresh. Exit the session (its credential is adopted into the backup once nothing runs against it), or switch to another account.")
            }
            if !pids.isEmpty {
                warn("Account-\(target) (\(email)) has a live session-mode Claude instance (PID \(pids.map(String.init).joined(separator: ", "))). Running the same account as both the default login and a session can make one copy's token go stale if the server rotates it. If the session later fails to authenticate, exit it and re-run 'cswap run \(target)'.")
            }
            return
        }
        let adopted = try adoptSessionCredential(target, email, orgUuid)
        if adopted == nil, sessionProfileAhead(target, email, orgUuid) != nil {
            throw SwapError.switchFailed("Account-\(target) (\(email)) has a session profile whose credential has rotated past the stored backup, and it could not be adopted into the backup: the profile's identity file (.claude.json) could not be read, or a Claude instance started against it just now. The backup is a consumed generation, and activating it would fail with invalid_grant on its first refresh. Re-login inside the profile ('cswap run \(target)', then /login) so its identity is rewritten, or switch to another account.")
        }
    }
}
