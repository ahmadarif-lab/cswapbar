import Foundation

/// Talks to the local `agy` hub's Connect-RPC API -- the same one the
/// Antigravity CLI's own UI and its VS Code extensions use, and the API
/// CodexBar's "cli" source reads. Confirmed against a real running hub.
enum AntigravityHubClient {
    static func retrieveQuotaSummaryJSON(endpoint: AntigravityHubEndpoint) async throws -> Any {
        guard let url = URL(string: "http://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else {
            throw AntigravityEngineError.network("invalid local hub URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AntigravityEngineError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AntigravityEngineError.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(String(decoding: data, as: UTF8.self).prefix(300)))
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AntigravityEngineError.decoding("\(error)")
        }
    }
}
