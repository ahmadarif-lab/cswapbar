import Foundation

/// Calls against Google Cloud Code's internal (undocumented) backend that
/// the Antigravity IDE itself uses -- reverse engineered from the
/// already-installed CodexBar app's binary strings, cross-checked against
/// the `codavidgarcia.antigravity-pulse` and `wusimpl.antigravity-quota-watcher`
/// VS Code extensions. Endpoint paths, required headers, or the response
/// shape could change without notice since none of this is published.
enum AntigravityQuotaClient {
    static let base = URL(string: "https://cloudcode-pa.googleapis.com")!

    private struct LoadCodeAssistResponse: Decodable {
        let cloudaicompanionProject: String?
    }

    private static func post(_ path: String, accessToken: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AntigravityEngineError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityEngineError.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AntigravityEngineError.http(http.statusCode, String(String(decoding: data, as: UTF8.self).prefix(300)))
        }
        return data
    }

    /// Resolves the Cloud Code project backing this account's Antigravity
    /// usage, required before the quota call.
    static func loadCodeAssistProject(accessToken: String) async throws -> String {
        let data = try await post(
            "v1internal:loadCodeAssist", accessToken: accessToken,
            body: ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]
        )
        let decoded: LoadCodeAssistResponse
        do {
            decoded = try JSONDecoder().decode(LoadCodeAssistResponse.self, from: data)
        } catch {
            throw AntigravityEngineError.decoding("\(error)")
        }
        guard let project = decoded.cloudaicompanionProject, !project.isEmpty else {
            throw AntigravityEngineError.decoding("this account has no Cloud Code project")
        }
        return project
    }

    /// The raw parsed JSON body, handed to `AntigravityQuotaParsing` rather
    /// than a strict `Decodable` type: the exact envelope nesting (flat
    /// `buckets` vs. `groups` wrapping `buckets`) isn't confirmed from
    /// reverse engineering, so parsing stays lenient about where in the tree
    /// the quota buckets actually sit.
    static func retrieveQuotaSummaryJSON(accessToken: String, project: String) async throws -> Any {
        let data = try await post(
            "v1internal:retrieveUserQuotaSummary", accessToken: accessToken, body: ["project": project]
        )
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AntigravityEngineError.decoding("\(error)")
        }
    }
}
