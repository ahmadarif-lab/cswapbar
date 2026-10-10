import Foundation
import ProviderKit

private let logTag = "codex"

public enum CodexEngineError: LocalizedError, Equatable {
    case notSignedIn
    case apiKeyLogin
    case sessionExpired
    case warmup(String)
    case http(Int, String)
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Codex login found. Run `codex login` and sign in with ChatGPT."
        case .apiKeyLogin:
            return "Codex is signed in with an API key, which has no ChatGPT usage windows. Run `codex login` and sign in with ChatGPT."
        case .sessionExpired:
            return "Codex's ChatGPT session has expired. Run `codex` once to renew it."
        case .warmup(let message):
            return message
        case .http(401, _), .http(403, _):
            return "ChatGPT rejected the Codex session. Run `codex login` again."
        case .http(let code, let body):
            return "ChatGPT returned HTTP \(code): \(body)"
        case .network(let message):
            return "ChatGPT request failed: \(message)"
        case .decoding(let message):
            return "Could not read ChatGPT's usage response: \(message)"
        }
    }
}

/// Public façade for the Codex usage windows of a ChatGPT plan, mirroring
/// `OpenCodeGoEngine`: it reads the login the Codex CLI itself stored, so a
/// machine already signed in shows up with nothing to paste.
///
/// Usage is read over HTTP, but warm-up goes through the `codex` CLI itself.
/// The engine never renews the login. ChatGPT refresh tokens rotate on use, so a
/// renewal here that Codex didn't also see would leave the CLI signed out;
/// an expired session instead asks the user to run Codex, which renews it.
public final class CodexEngine: @unchecked Sendable {
    public static let shared = CodexEngine()

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let session: URLSession
    public let authFileURL: URL

    init(session: URLSession = .shared, authFileURL: URL = CodexCredentialReader.defaultAuthFileURL) {
        self.session = session
        self.authFileURL = authFileURL
    }

    /// The signed-in account, for the Settings page's status line. Nil when
    /// there is no usable ChatGPT login.
    public func login() -> CodexLogin? {
        guard let credential = try? CodexCredentialReader.read(from: authFileURL) else { return nil }
        return CodexLogin(email: credential.email, planType: credential.planType)
    }

    public func currentUsage() async throws -> CodexUsageSummary {
        do {
            return try await fetchUsage()
        } catch {
            DiagnosticLog.log(logTag, "usage fetch failed: \(DiagnosticLog.describe(error))")
            throw error
        }
    }

    // MARK: - Warm-up

    public var binaryPath: String? { CodexCLI.findBinary() }

    /// Sends one throwaway `codex exec` message so the plan's rolling 5-hour
    /// window starts counting now, rather than whenever the first real request
    /// happens to land. Blocking -- call off the main actor.
    public func sendWarmupMessage() throws {
        guard login() != nil else { throw CodexEngineError.notSignedIn }
        guard let binary = CodexCLI.findBinary() else {
            throw CodexEngineError.warmup("The codex CLI wasn't found -- install it to warm up Codex.")
        }
        do {
            let result = try Subprocess.run(
                binary, CodexCLI.warmupArguments,
                environment: CodexCLI.environment(),
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser,
                timeout: 180
            )
            guard result.status == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
                throw CodexEngineError.warmup("`codex exec` exited \(result.status): \(detail)")
            }
            DiagnosticLog.log(logTag, "warm-up message sent")
        } catch let error as CodexEngineError {
            DiagnosticLog.log(logTag, "warm-up failed: \(DiagnosticLog.describe(error))")
            throw error
        } catch {
            let message = "Warm-up could not run the codex CLI: \(DiagnosticLog.describe(error))"
            DiagnosticLog.log(logTag, "warm-up failed: \(message)")
            throw CodexEngineError.warmup(message)
        }
    }

    // MARK: - Usage

    private func fetchUsage() async throws -> CodexUsageSummary {
        let credential: CodexCredential
        do {
            credential = try CodexCredentialReader.read(from: authFileURL)
        } catch CodexCredentialError.missing {
            throw CodexEngineError.notSignedIn
        } catch CodexCredentialError.apiKeyLogin {
            throw CodexEngineError.apiKeyLogin
        } catch CodexCredentialError.unreadable(let message) {
            throw CodexEngineError.decoding(message)
        }
        // No point asking the server about a token it will refuse.
        if let expiry = credential.expiresAt, expiry <= Date() { throw CodexEngineError.sessionExpired }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")

        let data: Data
        let status: Int
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CodexEngineError.network("no HTTP response") }
            data = body
            status = http.statusCode
        } catch let error as CodexEngineError {
            throw error
        } catch {
            throw CodexEngineError.network(error.localizedDescription)
        }
        if status == 401 { throw CodexEngineError.sessionExpired }
        guard (200..<300).contains(status) else {
            throw CodexEngineError.http(status, String(String(decoding: data, as: UTF8.self).prefix(300)))
        }

        let decoded: CodexUsageResponse
        do {
            decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        } catch {
            throw CodexEngineError.decoding("\(error)")
        }
        return try CodexUsageParsing.summarize(decoded, fallbackPlan: credential.planType)
    }
}

public struct CodexLogin: Sendable, Equatable {
    public let email: String?
    public let planType: String?
}
