import Foundation

/// How to send one account's warm-up message without making it the active
/// login. The caller picks the `claude` environment from the case.
public enum WarmupLaunch: Equatable, Sendable {
    /// The account is the one Claude Code is already signed in as: run
    /// `claude` as it is.
    case defaultLogin
    /// Run `claude` with this OAuth access token in `CLAUDE_CODE_OAUTH_TOKEN`
    /// and a throwaway `CLAUDE_CONFIG_DIR`. Nothing is written to the default
    /// login, the Keychain or this account's stored credential.
    case token(String)
    /// Nothing to send; the reason is shown to the person.
    case skip(String)
}

/// The decision half of `Switcher.warmupLaunch`, free of I/O so it can be
/// tested on its own.
enum WarmupPlan: Equatable {
    case launch(WarmupLaunch)
    /// The stored access token has expired: renew it, then use the new one.
    case renewThenToken

    static func decide(
        isActive: Bool,
        credentials: String,
        hasLiveSession: () -> Bool,
        isExpired: (JSONValue?) -> Bool
    ) -> WarmupPlan {
        if isActive { return .launch(.defaultLogin) }
        if CredentialShape.looksLikeAPIKey(credentials) {
            return .launch(.skip("an API key has no 5-hour window to start"))
        }
        let bare = credentials.trimmingCharacters(in: .whitespacesAndNewlines)
        // A setup-token is a long-lived OAuth token, stored as the bare string.
        if !bare.hasPrefix("{"), CredentialShape.oauthTokenPrefixes.contains(where: { bare.hasPrefix($0) }) {
            return .launch(.token(bare))
        }
        guard let stored = OAuth.extractOAuthData(credentials),
              let token = stored["accessToken"]?.stringValue, !token.isEmpty else {
            return .launch(.skip("it has no stored login; sign in to it again"))
        }
        // A Claude Code session running as this account owns the newest
        // credential and is already using the account.
        if hasLiveSession() { return .launch(.skip("a Claude Code session is already running as it")) }
        return isExpired(stored["expiresAt"]) ? .renewThenToken : .launch(.token(token))
    }
}

extension Switcher {
    /// What it takes to warm `number` up while another account stays active.
    ///
    /// A stored account is warmed by handing `claude` its access token
    /// directly instead of switching logins: a token passed this way is used
    /// as-is and never refreshed or written back, so the account's refresh
    /// token is not consumed behind this engine's back. An expired token is
    /// renewed first through the same gate the usage poll uses
    /// (`consumeBackupGrant`), which persists the successor.
    func warmupLaunch(_ number: Int) throws -> WarmupLaunch {
        guard let info = try buildAccountsInfo().first(where: { $0.number == number }) else {
            return .skip("it is no longer a managed account")
        }
        let plan = WarmupPlan.decide(
            isActive: info.isActive,
            credentials: info.creds,
            hasLiveSession: { !liveSessionPids(info.key, info.email).isEmpty },
            isExpired: { oauth.isTokenExpired($0) }
        )
        guard case .renewThenToken = plan else {
            if case .launch(let launch) = plan { return launch }
            return .skip("it has no usable login")
        }

        let outcome = consumeBackupGrant(info.key, info.email, info.creds)
        if let error = outcome.error {
            return .skip("its login could not be renewed (\(error)); sign in to it again")
        }
        guard let fresh = outcome.credentials.flatMap(OAuth.extractAccessToken), !fresh.isEmpty else {
            return .skip("its login could not be renewed; sign in to it again")
        }
        return .token(fresh)
    }
}
