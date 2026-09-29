import Foundation

struct AntigravityTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

/// Google OAuth 2.0 token refresh for Antigravity's installed-app clients.
enum AntigravityOAuth {
    struct OAuthClient {
        let id: String
        let secret: String
    }

    /// The `agy` binary embeds at least two installed-app OAuth clients --
    /// confirmed by reading the actual embedded strings from two different
    /// machines' `agy` installs (1.2.13 had both; an older/different build
    /// only exercised the first). Which one issued a given stored refresh
    /// token depends on which login flow that install went through, so
    /// refresh tries each in turn rather than assuming one. Google
    /// documents installed-app client secrets as not confidential -- they
    /// can't be kept secret inside a distributed binary, so the client
    /// relies on the user's own consent/refresh-token instead.
    static let clients: [OAuthClient] = [
        OAuthClient(
            id: "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
            secret: "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"
        ),
        OAuthClient(
            id: "884354919052-36trc1jjb3tguiac32ov6cod268c5blh.apps.googleusercontent.com",
            secret: "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"
        ),
    ]

    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    static func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, expiresAt: Date) {
        var lastError: Error = AntigravityEngineError.decoding("no OAuth client configured")
        for client in clients {
            do {
                return try await refreshAccessToken(refreshToken: refreshToken, client: client)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func refreshAccessToken(refreshToken: String, client: OAuthClient) async throws -> (accessToken: String, expiresAt: Date) {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": client.id,
            "client_secret": client.secret,
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
