import Foundation

enum JetskiTokenReaderError: Error, LocalizedError, Equatable {
    case notFound
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .notFound: return "Antigravity CLI's local login file wasn't found."
        case .invalidFormat: return "Antigravity CLI's local login file wasn't in the expected format."
        }
    }
}

/// Reads the refresh token the Antigravity CLI (`agy`) stores in a plain
/// JSON file after signing in -- `~/.gemini/jetski-standalone-oauth-token`,
/// shaped `{"token": {"access_token", "refresh_token", "expiry", ...}}`.
/// Far simpler than the desktop IDE's vscdb-embedded-protobuf storage (see
/// `VSCDBReader`), and the primary credential source for CLI-only installs.
enum JetskiStandaloneTokenReader {
    private struct TokenFile: Decodable {
        struct Token: Decodable {
            let refreshToken: String
            enum CodingKeys: String, CodingKey {
                case refreshToken = "refresh_token"
            }
        }
        let token: Token
    }

    static func path() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
    }

    static func readRefreshToken() throws -> String {
        let url = path()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw JetskiTokenReaderError.notFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw JetskiTokenReaderError.notFound
        }
        return try decodeRefreshToken(data)
    }

    /// Pure decode step, isolated from the filesystem so it's unit-testable
    /// against sample JSON.
    static func decodeRefreshToken(_ data: Data) throws -> String {
        let decoded: TokenFile
        do {
            decoded = try JSONDecoder().decode(TokenFile.self, from: data)
        } catch {
            throw JetskiTokenReaderError.invalidFormat
        }
        guard !decoded.token.refreshToken.isEmpty else { throw JetskiTokenReaderError.invalidFormat }
        return decoded.token.refreshToken
    }
}
