import Foundation
import ProviderKit

private let logTag = "deepseek"

public enum DeepSeekEngineError: LocalizedError, Equatable {
    case notConfigured
    case http(Int, String)
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "No DeepSeek API key configured."
        case .http(401, _): return "DeepSeek rejected the API key (HTTP 401)."
        case .http(let code, let body): return "DeepSeek returned HTTP \(code): \(body)"
        case .network(let message): return "DeepSeek request failed: \(message)"
        case .decoding(let message): return "Could not read DeepSeek's response: \(message)"
        }
    }
}

/// Public façade for the DeepSeek API balance, mirroring `ZAIEngine` -- a
/// single API key in the Keychain, refreshed on demand. DeepSeek is pay-as-
/// you-go, so there's no usage window to warm up, only prepaid credit.
public final class DeepSeekEngine: @unchecked Sendable {
    public static let shared = DeepSeekEngine()

    private static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    private let keychain = DeepSeekKeychainStore()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    public func hasStoredCredential() -> Bool {
        (try? keychain.getAPIKey())?.isEmpty == false
    }

    public func setAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeepSeekEngineError.notConfigured }
        try keychain.setAPIKey(trimmed)
    }

    public func removeStoredCredential() throws {
        try keychain.deleteAPIKey()
    }

    public func currentBalance() async throws -> DeepSeekBalanceSummary {
        guard let apiKey = try keychain.getAPIKey(), !apiKey.isEmpty else {
            throw DeepSeekEngineError.notConfigured
        }
        do {
            return try await fetchBalance(apiKey: apiKey)
        } catch {
            DiagnosticLog.log(logTag, "balance fetch failed: \(DiagnosticLog.describe(error))")
            throw error
        }
    }

    private func fetchBalance(apiKey: String) async throws -> DeepSeekBalanceSummary {
        var request = URLRequest(url: Self.balanceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DeepSeekEngineError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekEngineError.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self).prefix(300)
            throw DeepSeekEngineError.http(http.statusCode, String(body))
        }

        let decoded: DeepSeekBalanceResponse
        do {
            decoded = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        } catch {
            throw DeepSeekEngineError.decoding("\(error)")
        }
        return try DeepSeekBalanceParsing.summarize(decoded)
    }
}
