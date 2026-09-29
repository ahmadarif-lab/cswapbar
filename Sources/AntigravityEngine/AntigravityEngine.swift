import Foundation
import ProviderKit

/// Public façade for Antigravity (Gemini + Claude/GPT) quota, mirroring the
/// shape of `SwapEngine.AccountEngine` and `ZAIEngine.ZAIEngine`: a single
/// owned credential, refreshed on demand.
public final class AntigravityEngine: @unchecked Sendable {
    public static let shared = AntigravityEngine()

    private let keychain = ProviderKeychain(service: "cswapbar-antigravity")

    public func hasStoredCredential() -> Bool {
        (try? keychain.getPassword())?.isEmpty == false
    }

    /// Whether a quota fetch has any hope of succeeding right now: either a
    /// CLI session's local hub is currently running (the common, no-setup
    /// case), or a stored OAuth credential exists as a fallback.
    public func canFetchRightNow() -> Bool {
        AntigravityHubLocator.findRunningHub() != nil || hasStoredCredential()
    }

    public func removeStoredCredential() throws {
        try keychain.deletePassword()
    }

    /// Reads the refresh token straight out of Antigravity's own local login
    /// state -- the `agy` CLI's plain-JSON token file first (the common case:
    /// most Antigravity installs are CLI-only), the desktop IDE's
    /// vscdb-embedded-protobuf storage as a fallback -- confirms it actually
    /// works with one refresh call, then stores it under this app's own
    /// Keychain service. No separate sign-in required either way.
    public func autoDetectAndStore() async throws {
        let refreshToken = try detectRefreshToken()
        _ = try await AntigravityOAuth.refreshAccessToken(refreshToken: refreshToken)
        try keychain.setPassword(refreshToken)
    }

    private func detectRefreshToken() throws -> String {
        if let token = try? JetskiStandaloneTokenReader.readRefreshToken(), !token.isEmpty {
            return token
        }
        do {
            return try VSCDBReader.readRefreshToken()
        } catch {
            let cliReason = (try? JetskiStandaloneTokenReader.readRefreshToken()) == nil
                ? JetskiTokenReaderError.notFound.errorDescription ?? ""
                : ""
            let ideReason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            let combined = [cliReason, ideReason].filter { !$0.isEmpty }.joined(separator: " ")
            throw AntigravityEngineError.autoDetect(combined.isEmpty ? "Auto-detect failed." : combined)
        }
    }

    /// Advanced/fallback path: store a refresh token pasted in by hand
    /// (extracted by the user from wherever they keep it), for when
    /// auto-detect can't find or parse Antigravity's local login state.
    public func storeManualRefreshToken(_ token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AntigravityEngineError.notConfigured }
        _ = try await AntigravityOAuth.refreshAccessToken(refreshToken: trimmed)
        try keychain.setPassword(trimmed)
    }

    /// Tries the locally running CLI hub first -- no credential needed, and
    /// it's what actually works for accounts without a paid GCP Gemini Code
    /// Assist license (see `AntigravityHubLocator`). Falls back to the
    /// stored OAuth credential's cloud path only when no hub is found (or
    /// the hub call itself fails, e.g. a stale/rotated CSRF token).
    public func currentAccount() async throws -> AntigravityAccountSummary {
        if let hub = AntigravityHubLocator.findRunningHub(), let json = try? await AntigravityHubClient.retrieveQuotaSummaryJSON(endpoint: hub) {
            return AntigravityQuotaParsing.summarize(json)
        }

        guard let refreshToken = try keychain.getPassword(), !refreshToken.isEmpty else {
            throw AntigravityEngineError.notConfigured
        }
        let (accessToken, _) = try await AntigravityOAuth.refreshAccessToken(refreshToken: refreshToken)
        let project = try await AntigravityQuotaClient.loadCodeAssistProject(accessToken: accessToken)
        let json = try await AntigravityQuotaClient.retrieveQuotaSummaryJSON(accessToken: accessToken, project: project)
        return AntigravityQuotaParsing.summarize(json)
    }
}
