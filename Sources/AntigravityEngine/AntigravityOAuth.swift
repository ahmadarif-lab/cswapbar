import Foundation

struct AntigravityTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

/// Google OAuth 2.0 token refresh for Antigravity's installed-app client.
enum AntigravityOAuth {
    /// The installed-app OAuth client Antigravity's own IDE, its
    /// quota-watcher VS Code extension, opencode, and CodexBar all already
    /// use to refresh this exact kind of token. Google documents
    /// installed-app client secrets as not confidential -- they can't be
    /// kept secret inside a distributed binary, so the client relies on the
    /// user's own consent/refresh-token instead.
    static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecret = "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"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    static func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, expiresAt: Date) {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

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
        let decoded: AntigravityTokenResponse
        do {
            decoded = try JSONDecoder().decode(AntigravityTokenResponse.self, from: data)
        } catch {
            throw AntigravityEngineError.decoding("\(error)")
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(decoded.expiresIn ?? 3600))
        return (decoded.accessToken, expiresAt)
    }
}
