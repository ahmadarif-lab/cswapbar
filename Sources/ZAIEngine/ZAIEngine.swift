import Foundation
import ProviderKit

private let logTag = "zai"

public enum ZAIEngineError: LocalizedError, Equatable {
    case notConfigured
    case http(Int, String)
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "No z.ai API key configured."
        case .http(let code, let body): return "z.ai returned HTTP \(code): \(body)"
        case .network(let message): return "z.ai request failed: \(message)"
        case .decoding(let message): return "Could not read z.ai's response: \(message)"
        }
    }
}

/// Public façade for z.ai (GLM Coding Plan) quota, mirroring the shape of
/// `SwapEngine.AccountEngine` -- a single owned credential, refreshed on
/// demand rather than kept as long-lived state.
public final class ZAIEngine: @unchecked Sendable {
    public static let shared = ZAIEngine()

    private static let regionDefaultsKey = "cswapbar.zai.region"

    private let keychain = ZAIKeychainStore()
    private let session: URLSession
    private let defaults: UserDefaults

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    public var region: ZAIRegion {
        ZAIRegion(rawValue: defaults.string(forKey: Self.regionDefaultsKey) ?? "") ?? .global
    }

    public func hasStoredCredential() -> Bool {
        (try? keychain.getAPIKey())?.isEmpty == false
    }

    public func setAPIKey(_ apiKey: String, region: ZAIRegion) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ZAIEngineError.notConfigured }
        try keychain.setAPIKey(trimmed)
        defaults.set(region.rawValue, forKey: Self.regionDefaultsKey)
    }

    public func removeStoredCredential() throws {
        try keychain.deleteAPIKey()
    }

    public func currentAccount() async throws -> ZAIAccountSummary {
        guard let apiKey = try keychain.getAPIKey(), !apiKey.isEmpty else {
            throw ZAIEngineError.notConfigured
        }
        do {
            return try await fetchAccount(apiKey: apiKey)
        } catch {
            DiagnosticLog.log(logTag, "quota fetch failed: \(DiagnosticLog.describe(error))")
            throw error
        }
    }

    /// Sends one tiny chat message on the Coding Plan endpoint so the plan's
    /// 5-hour window starts counting now. The model is picked from the
    /// endpoint's own model list (preferring a light "air" model) rather
    /// than hard-coded, since GLM model names churn between releases.
    public func sendWarmupMessage() async throws {
        guard let apiKey = try keychain.getAPIKey(), !apiKey.isEmpty else {
            throw ZAIEngineError.notConfigured
        }
        let model = await warmupModel(apiKey: apiKey)
        var request = URLRequest(url: region.baseURL.appendingPathComponent("api/coding/paas/v4/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "halo"]],
            "max_tokens": 16,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(request)
        DiagnosticLog.log(logTag, "warm-up message sent (model \(model))")
    }

    private func warmupModel(apiKey: String) async -> String {
        let fallback = "glm-4.5-air"
        var request = URLRequest(url: region.baseURL.appendingPathComponent("api/coding/paas/v4/models"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let data = try? await send(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return fallback }
        let ids = list.compactMap { $0["id"] as? String }
        return ids.first { $0.lowercased().contains("air") } ?? ids.first ?? fallback
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ZAIEngineError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ZAIEngineError.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self).prefix(300)
            throw ZAIEngineError.http(http.statusCode, String(body))
        }
        return data
    }

    private func fetchAccount(apiKey: String) async throws -> ZAIAccountSummary {
        var request = URLRequest(url: region.baseURL.appendingPathComponent("api/monitor/usage/quota/limit"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)

        let decoded: ZAIQuotaResponse
        do {
            decoded = try JSONDecoder().decode(ZAIQuotaResponse.self, from: data)
        } catch {
            throw ZAIEngineError.decoding("\(error)")
        }
        return try ZAIQuotaParsing.summarize(decoded)
    }
}
