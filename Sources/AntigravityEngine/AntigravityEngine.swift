import Foundation
import ProviderKit

private let logTag = "antigravity"

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
    /// CLI session's local hub is running, agy CLI is installed to spawn one,
    /// or a stored OAuth credential exists as a fallback.
    public func canFetchRightNow() -> Bool {
        AntigravityHubLocator.findRunningHub() != nil ||
        AntigravityHubProcessManager.isAgyAvailable ||
        hasStoredCredential()
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
            DiagnosticLog.log(logTag, "auto-detect: found a refresh token via the agy CLI's local token file")
            return token
        }
        do {
            let token = try VSCDBReader.readRefreshToken()
            DiagnosticLog.log(logTag, "auto-detect: found a refresh token via the Antigravity IDE's vscdb (agy CLI token file wasn't found or was empty)")
            return token
        } catch {
            let cliReason = (try? JetskiStandaloneTokenReader.readRefreshToken()) == nil
                ? JetskiTokenReaderError.notFound.errorDescription ?? ""
                : ""
            let ideReason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            let combined = [cliReason, ideReason].filter { !$0.isEmpty }.joined(separator: " ")
            DiagnosticLog.log(logTag, "auto-detect: no source found a token -- \(combined)")
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

    /// Tries a local CLI hub first -- either an already running one (e.g. from
    /// VS Code / active CLI session) or one auto-spawned by CSwapBar via the
    /// installed `agy` binary. This Connect-RPC path provides live, complete
    /// quota data with no GCP Gemini Code Assist license required.
    /// Falls back to the stored OAuth credential's cloud path only when no hub
    /// can be found or spawned.
    public func currentAccount() async throws -> AntigravityAccountSummary {
        if let hub = await AntigravityHubProcessManager.shared.ensureRunningHub() {
            if let json = try? await AntigravityHubClient.retrieveQuotaSummaryJSON(endpoint: hub) {
                return AntigravityQuotaParsing.summarize(json)
            }
            DiagnosticLog.log(logTag, "local hub found/spawned but its quota call failed -- falling back to the stored OAuth credential")
        }

        guard let refreshToken = try keychain.getPassword(), !refreshToken.isEmpty else {
            throw AntigravityEngineError.notConfigured
        }
        let (accessToken, _) = try await AntigravityOAuth.refreshAccessToken(refreshToken: refreshToken)
        let project = try await AntigravityQuotaClient.loadCodeAssistProject(accessToken: accessToken)
        let json = try await AntigravityQuotaClient.retrieveQuotaSummaryJSON(accessToken: accessToken, project: project)
        return AntigravityQuotaParsing.summarize(json)
    }

    /// Sends one throwaway `agy -p` prompt per quota pool (Gemini and
    /// Claude/GPT) so each pool's 5-hour window starts counting now. Model
    /// ids come from `agy models` at run time rather than being hard-coded,
    /// since they change with every Antigravity release. Blocking -- call
    /// off the main actor.
    public func sendWarmupMessages() throws {
        guard let agy = AntigravityHubProcessManager.findAgyBinary() else {
            throw AntigravityEngineError.warmup("agy CLI not found -- install it to warm up Antigravity.")
        }
        let env = AntigravityHubProcessManager.agyEnvironment()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let listing = try Subprocess.run(agy, ["models"], environment: env, currentDirectory: home, timeout: 30)
        let models = Self.warmupModels(fromListing: listing.stdout)
        guard !models.isEmpty else {
            throw AntigravityEngineError.warmup("agy models listed nothing to warm up.")
        }
        var failures: [String] = []
        for model in models {
            do {
                let result = try Subprocess.run(
                    agy, ["--model", model, "--print-timeout", "120s", "-p", "halo"],
                    environment: env, currentDirectory: home, timeout: 150
                )
                if result.status == 0 {
                    DiagnosticLog.log(logTag, "warm-up message sent (model \(model))")
                } else {
                    failures.append(model)
                    DiagnosticLog.log(logTag, "warm-up with \(model) exited \(result.status): \(result.stderr.prefix(300))")
                }
            } catch {
                failures.append(model)
                DiagnosticLog.log(logTag, "warm-up with \(model) failed: \(DiagnosticLog.describe(error))")
            }
        }
        if failures.count == models.count {
            throw AntigravityEngineError.warmup("Warm-up failed for \(failures.joined(separator: ", ")).")
        }
    }

    /// One cheap model per pool from `agy models` output (`<id>\t<name>`
    /// per line): the lowest-effort Gemini Flash, and the first Claude (or
    /// GPT) model for the shared Claude/GPT pool.
    static func warmupModels(fromListing listing: String) -> [String] {
        let ids = listing.split(separator: "\n").compactMap { line -> String? in
            let id = line.split(separator: "\t").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            guard let id, !id.isEmpty, !id.contains(" ") else { return nil }
            return id
        }
        let flash = ids.filter { $0.hasPrefix("gemini") && $0.contains("flash") }
        let gemini = flash.first { $0.hasSuffix("-low") } ?? flash.first ?? ids.first { $0.hasPrefix("gemini") }
        let other = ids.first { $0.hasPrefix("claude") } ?? ids.first { $0.hasPrefix("gpt") }
        return [gemini, other].compactMap { $0 }
    }

    /// Stops any background hub process spawned and managed by CSwapBar.
    public func stopManagedHub() {
        AntigravityHubProcessManager.shared.terminate()
    }
}
