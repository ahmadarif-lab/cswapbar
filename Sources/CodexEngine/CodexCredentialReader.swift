import Foundation

/// The ChatGPT login the Codex CLI keeps in `auth.json`.
public struct CodexCredential: Sendable, Equatable {
    public let accessToken: String
    public let accountID: String
    public let email: String?
    /// The plan the login belongs to ("plus", "pro", "team"...), as recorded
    /// in the token itself.
    public let planType: String?
    /// When the access token stops being accepted. Codex renews it itself the
    /// next time it runs.
    public let expiresAt: Date?
}

enum CodexCredentialError: Error, Equatable {
    case missing
    /// `auth.json` exists but holds an API key, which has no ChatGPT plan
    /// (and so no Codex usage windows) to read.
    case apiKeyLogin
    case unreadable(String)
}

/// Reads the credential Codex itself stores, so there is nothing to paste into
/// CSwapBar: the same thing `codex login` fills in. Read-only on purpose --
/// refresh tokens rotate on use, so renewing one here without Codex knowing
/// would sign the CLI out.
enum CodexCredentialReader {
    /// Codex honors `CODEX_HOME` and otherwise keeps everything in `~/.codex`.
    static var defaultAuthFileURL: URL {
        let base: URL
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            base = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        return base.appendingPathComponent("auth.json")
    }

    static func read(from url: URL) throws -> CodexCredential {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CodexCredentialError.missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodexCredentialError.unreadable(error.localizedDescription)
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> CodexCredential {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CodexCredentialError.unreadable("auth.json is not a JSON object")
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let access = (tokens["access_token"] as? String), !access.isEmpty
        else {
            // No ChatGPT tokens at all: either an API-key login or a logged-out file.
            if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty { throw CodexCredentialError.apiKeyLogin }
            throw CodexCredentialError.missing
        }

        let accessClaims = claims(of: access)
        let idClaims = (tokens["id_token"] as? String).flatMap(claims(of:))
        let accessAuth = accessClaims?["https://api.openai.com/auth"] as? [String: Any]
        let idAuth = idClaims?["https://api.openai.com/auth"] as? [String: Any]

        // The account id is stored beside the tokens; the token's own claim is
        // the fallback for a file written without it.
        let accountID = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? accessAuth?["chatgpt_account_id"] as? String
            ?? idAuth?["chatgpt_account_id"] as? String
        guard let accountID else { throw CodexCredentialError.unreadable("auth.json has no account id") }

        let profile = accessClaims?["https://api.openai.com/profile"] as? [String: Any]
        return CodexCredential(
            accessToken: access,
            accountID: accountID,
            email: idClaims?["email"] as? String ?? profile?["email"] as? String,
            planType: accessAuth?["chatgpt_plan_type"] as? String ?? idAuth?["chatgpt_plan_type"] as? String,
            expiresAt: (accessClaims?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// The payload of a JWT. Only read, never verified -- the server does
    /// that; this is just for the plan, the email and the expiry.
    static func claims(of jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
