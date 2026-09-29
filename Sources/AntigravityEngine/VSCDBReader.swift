import Foundation
import ProviderKit

enum VSCDBReaderError: Error, LocalizedError, Equatable {
    case notFound
    case queryFailed(String)
    case notBase64
    case fieldNotFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Antigravity's local login data wasn't found. Make sure Antigravity is installed and you've signed in at least once."
        case .queryFailed(let message):
            return "Could not read Antigravity's local login data: \(message)"
        case .notBase64:
            return "Antigravity's local login data wasn't in the expected format."
        case .fieldNotFound:
            return "Couldn't find a login token in Antigravity's local data. Try signing in to Antigravity again, then retry."
        }
    }
}

/// Reads the Google OAuth refresh token the Antigravity IDE keeps in its own
/// local SQLite store, so CSwapBar can show the same account's quota without
/// a separate sign-in -- the same credential CodexBar and opencode's own
/// Antigravity integration already read this way. Undocumented, reverse
/// engineered storage: every failure here is expected to be user-visible and
/// recoverable via the manual-token fallback, never a crash.
enum VSCDBReader {
    private static let stateKey = "jetskiStateSync.agentManagerInitState"
    /// `refresh_token` sits at this protobuf field path inside the decoded value.
    private static let refreshTokenPath = [6, 3]
    private static let queryTimeout: TimeInterval = 5

    static func statePath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
    }

    static func readRefreshToken() throws -> String {
        let path = statePath()
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw VSCDBReaderError.notFound
        }

        let sql = "SELECT value FROM ItemTable WHERE key='\(stateKey)';"
        let result: SubprocessResult
        do {
            result = try Subprocess.run("/usr/bin/sqlite3", ["-readonly", "-batch", "-noheader", path.path, sql], timeout: queryTimeout)
        } catch {
            throw VSCDBReaderError.queryFailed("\(error)")
        }
        guard result.status == 0 else {
            throw VSCDBReaderError.queryFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let encoded = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encoded.isEmpty else { throw VSCDBReaderError.fieldNotFound }
        guard let data = Data(base64Encoded: encoded) else { throw VSCDBReaderError.notBase64 }
        guard let token = ProtoFieldReader.extractNestedString(data, path: refreshTokenPath), !token.isEmpty else {
            throw VSCDBReaderError.fieldNotFound
        }
        return token
    }
}
