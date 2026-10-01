import Foundation
import ProviderKit

private let logTag = "opencode-go"

public enum OpenCodeGoEngineError: LocalizedError, Equatable {
    case notConfigured
    case sessionExpired
    case noSubscription
    case warmup(String)
    case http(Int, String)
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No OpenCode credential stored. Run `opencode auth login opencode` and connect it."
        case .sessionExpired:
            return "OpenCode rejected the stored session (HTTP 401). Sign in again with `opencode auth login opencode`."
        case .noSubscription:
            return "No active OpenCode Go subscription on this workspace."
        case .warmup(let message):
            return message
        case .http(401, _):
            return "OpenCode rejected the API key (HTTP 401)."
        case .http(403, _):
            return "This credential has no OpenCode Go subscription (HTTP 403)."
        case .http(let code, let body):
            return "OpenCode returned HTTP \(code): \(body)"
        case .network(let message):
            return "OpenCode request failed: \(message)"
        case .decoding(let message):
            return "Could not read OpenCode's response: \(message)"
        }
    }
}

/// Public façade for the OpenCode Go subscription quota, mirroring
/// `ZAIEngine` -- but instead of a pasted key it reads whatever OpenCode
/// itself stored, so a workspace already signed in through the CLI shows up on
/// its own.
///
/// Which endpoint it reads depends on the credential:
///
/// - An **OAuth session** (what `opencode auth login opencode` stores by
///   default) reads the console's own `/console/api/go/status`, the same
///   payload the Go page in the console renders. That route only accepts a
///   session, and reports real money per window.
/// - An **API key** reads the public `/zen/go/v1/usage`, which reports
///   percents only. That route rejects an OAuth session outright, which is
///   why the console route exists here at all.
public final class OpenCodeGoEngine: @unchecked Sendable {
    public static let shared = OpenCodeGoEngine()

    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private static let consoleStatusURL = URL(string: "https://opencode.ai/console/api/go/status")!
    private static let consoleWorkspacesURL = URL(string: "https://opencode.ai/console/api/orgs")!

    private let session: URLSession
    public let authFileURL: URL
    public let databaseURL: URL

    /// Reading the credential means hitting OpenCode's (multi-megabyte)
    /// database, so it's cached here instead of re-read on every view
    /// update; `reloadCredential()` drops the cache when a refresh happens.
    private let credentialLock = NSLock()
    private var cachedCredential: OpenCodeGoCredential?
    private var credentialLoaded = false

    init(
        session: URLSession = .shared,
        authFileURL: URL = OpenCodeGoCredentialReader.defaultAuthFileURL,
        databaseURL: URL = OpenCodeGoCredentialReader.defaultDatabaseURL
    ) {
        self.session = session
        self.authFileURL = authFileURL
        self.databaseURL = databaseURL
    }

    public func credential() -> OpenCodeGoCredential? {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        if !credentialLoaded {
            cachedCredential = loadCredential()
            credentialLoaded = true
        }
        return cachedCredential
    }

    /// Re-reads the stored credential, picking up one connected since the
    /// last look (e.g. `opencode auth login` run while CSwapBar was open).
    public func reloadCredential() {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        cachedCredential = loadCredential()
        credentialLoaded = true
    }

    public func hasStoredCredential() -> Bool {
        credential() != nil
    }

    /// Where the resolved credential actually lives, for "reveal in Finder".
    public var credentialFileURL: URL {
        credential()?.source == .authFile ? authFileURL : databaseURL
    }

    public func currentUsage() async throws -> OpenCodeGoUsageSummary {
        guard let credential = credential() else {
            throw OpenCodeGoEngineError.notConfigured
        }
        do {
            switch credential.kind {
            case .oauth: return try await fetchConsoleUsage(credential: credential)
            case .apiKey: return try await fetchAPIKeyUsage(credential: credential)
            }
        } catch {
            DiagnosticLog.log(logTag, "usage fetch failed: \(DiagnosticLog.describe(error))")
            throw error
        }
    }

    private func loadCredential() -> OpenCodeGoCredential? {
        do {
            return try OpenCodeGoCredentialReader.read(from: authFileURL, databaseURL: databaseURL)
        } catch {
            DiagnosticLog.log(logTag, "reading stored credentials failed: \(DiagnosticLog.describe(error))")
            return nil
        }
    }

    // MARK: - Warm-up

    /// Sends one throwaway `opencode run` message so the plan's rolling
    /// 5-hour window starts counting now, rather than whenever the first real
    /// request happens to land. Blocking -- call off the main actor.
    public func sendWarmupMessage() throws {
        guard hasStoredCredential() else { throw OpenCodeGoEngineError.notConfigured }
        guard let binary = OpenCodeGoCLI.findBinary() else {
            throw OpenCodeGoEngineError.warmup("The opencode CLI wasn't found -- install it to warm up OpenCode Go.")
        }
        let env = OpenCodeGoCLI.environment()
        let home = FileManager.default.homeDirectoryForCurrentUser

        do {
            let listing = try Subprocess.run(binary, ["models"], environment: env, currentDirectory: home, timeout: 30)
            guard let model = OpenCodeGoCLI.warmupModel(fromListing: listing.stdout) else {
                throw OpenCodeGoEngineError.warmup("`opencode models` listed no OpenCode Go models to warm up.")
            }
            let result = try Subprocess.run(
                binary,
                [
                    "run",
                    "--title", "CSwapBar warm-up",
                    "--model", "\(OpenCodeGoCLI.providerPrefix)\(model)",
                    "Reply with the single word: ok.",
                ],
                environment: env, currentDirectory: home, timeout: 180
            )
            guard result.status == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
                throw OpenCodeGoEngineError.warmup("`opencode run` exited \(result.status): \(detail)")
            }
            DiagnosticLog.log(logTag, "warm-up message sent (model \(model))")
        } catch let error as OpenCodeGoEngineError {
            DiagnosticLog.log(logTag, "warm-up failed: \(DiagnosticLog.describe(error))")
            throw error
        } catch {
            let message = "Warm-up could not run the opencode CLI: \(DiagnosticLog.describe(error))"
            DiagnosticLog.log(logTag, "warm-up failed: \(message)")
            throw OpenCodeGoEngineError.warmup(message)
        }
    }

    // MARK: - Console route (OAuth session)

    private func fetchConsoleUsage(credential: OpenCodeGoCredential) async throws -> OpenCodeGoUsageSummary {
        let workspaceID = try await workspaceID(for: credential)

        var request = URLRequest(url: Self.consoleStatusURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let workspaceID { request.setValue(workspaceID, forHTTPHeaderField: "x-org-id") }

        let (data, status) = try await get(request)
        switch status {
        case 401: throw OpenCodeGoEngineError.sessionExpired
        case 404: throw OpenCodeGoEngineError.noSubscription
        case 200..<300: break
        default: throw OpenCodeGoEngineError.http(status, body(of: data))
        }

        // A body of `null` (rather than an object) is how the console says
        // "this workspace has no Go subscription".
        let decoded: OpenCodeGoConsoleStatus?
        do {
            decoded = try JSONDecoder().decode(OpenCodeGoConsoleStatus?.self, from: data)
        } catch {
            throw OpenCodeGoEngineError.decoding("\(error)")
        }
        guard let decoded else { throw OpenCodeGoEngineError.noSubscription }
        return try OpenCodeGoUsageParsing.summarizeConsole(decoded)
    }

    /// The workspace the credential belongs to. `opencode auth login` records
    /// it, so this normally needs no request at all; otherwise the console's
    /// own workspace list supplies the first entry, and a failure just leaves
    /// the header off (the endpoint answers without it).
    private func workspaceID(for credential: OpenCodeGoCredential) async throws -> String? {
        if let workspaceID = credential.workspaceID { return workspaceID }

        var request = URLRequest(url: Self.consoleWorkspacesURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, status) = try await get(request)
        if status == 401 { throw OpenCodeGoEngineError.sessionExpired }
        guard (200..<300).contains(status) else {
            DiagnosticLog.log(logTag, "workspace list failed with HTTP \(status)")
            return nil
        }
        return (try? JSONDecoder().decode([OpenCodeGoWorkspace].self, from: data))?.first?.id
    }

    // MARK: - API-key route

    private func fetchAPIKeyUsage(credential: OpenCodeGoCredential) async throws -> OpenCodeGoUsageSummary {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, status) = try await get(request)
        guard (200..<300).contains(status) else {
            throw OpenCodeGoEngineError.http(status, body(of: data))
        }

        let decoded: OpenCodeGoUsageResponse
        do {
            decoded = try JSONDecoder().decode(OpenCodeGoUsageResponse.self, from: data)
        } catch {
            throw OpenCodeGoEngineError.decoding("\(error)")
        }
        return try OpenCodeGoUsageParsing.summarize(decoded)
    }

    // MARK: - Transport

    private func get(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenCodeGoEngineError.network("no HTTP response")
            }
            return (data, http.statusCode)
        } catch let error as OpenCodeGoEngineError {
            throw error
        } catch {
            throw OpenCodeGoEngineError.network(error.localizedDescription)
        }
    }

    private func body(of data: Data) -> String {
        String(String(decoding: data, as: UTF8.self).prefix(300))
    }
}
