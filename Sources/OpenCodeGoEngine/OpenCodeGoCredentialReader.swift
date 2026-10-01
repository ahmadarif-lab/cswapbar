import Foundation
import ProviderKit
import SQLite3

/// The credential OpenCode Go requests are authenticated with, as found in
/// OpenCode's own stored credentials.
public struct OpenCodeGoCredential: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A static API key, the only kind the quota endpoint accepts.
        case apiKey
        /// An OAuth session token, which `opencode /connect` writes when
        /// signing in through the browser. It authenticates the console, but
        /// the Go quota (and inference) endpoints reject it.
        case oauth

        public var title: String {
            switch self {
            case .apiKey: return "API key"
            case .oauth: return "OAuth session"
            }
        }
    }

    /// Where the credential was found, so the UI can say so.
    public enum Source: Sendable, Equatable {
        /// The v1-style `auth.json` next to OpenCode's data.
        case authFile
        /// OpenCode v2's own database, where `opencode auth login` stores
        /// credentials today.
        case database

        public var title: String {
            switch self {
            case .authFile: return "auth.json"
            case .database: return "opencode.db"
            }
        }
    }

    public let kind: Kind
    public let token: String
    /// Which stored entry it came from.
    public let entryName: String
    public let source: Source
    /// The workspace the credential belongs to, when the store recorded it
    /// (`opencode auth login` does, for an OAuth session). Saves a lookup
    /// against the console's own workspace list.
    public let workspaceID: String?
}

/// Reads the credential OpenCode itself stores, so there is nothing to paste
/// into CSwapBar: the same thing `opencode auth login` fills in.
///
/// Two places are checked, because OpenCode v2 moved credentials out of the
/// v1-era `auth.json` and into its own SQLite database -- a login through
/// today's CLI lands in the database only, and the file is often stale or
/// absent.
public enum OpenCodeGoCredentialReader {
    /// Entries are tried in this order: OpenCode Go's own id first, then
    /// Zen's -- the same key can serve both.
    static let entryNames = ["opencode-go", "opencode"]

    public static var defaultAuthFileURL: URL {
        dataDirectory.appendingPathComponent("auth.json")
    }

    public static var defaultDatabaseURL: URL {
        dataDirectory.appendingPathComponent("opencode.db")
    }

    /// OpenCode's own data directory (`opencode debug paths` → `data`).
    public static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    /// `nil` when no usable credential is stored anywhere -- that's simply
    /// "not connected yet", not an error.
    public static func read(
        from authFileURL: URL = defaultAuthFileURL,
        databaseURL: URL = defaultDatabaseURL
    ) throws -> OpenCodeGoCredential? {
        var found: [OpenCodeGoCredential] = []
        if let credential = try readAuthFile(from: authFileURL) { found.append(credential) }
        if let credential = readDatabase(from: databaseURL) { found.append(credential) }
        // An API key is the only kind the quota endpoint accepts, so one is
        // preferred wherever it lives -- a workspace can easily have both an
        // OAuth session (from signing in) and a key.
        return found.first { $0.kind == .apiKey } ?? found.first
    }

    // MARK: - Sources

    private static func readAuthFile(from url: URL) throws -> OpenCodeGoCredential? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let root: [String: StoredValue]
        do {
            root = try JSONDecoder().decode([String: StoredValue].self, from: data)
        } catch {
            throw OpenCodeGoEngineError.decoding("auth.json could not be read: \(error)")
        }
        for name in entryNames {
            guard let entry = root[name] else { continue }
            if let credential = entry.credential(entryName: name, source: .authFile) { return credential }
        }
        return nil
    }

    /// Reads OpenCode v2's `credential` table directly, read-only, so a
    /// running OpenCode is never disturbed. A missing database, a database
    /// from an older schema, or a locked one all read as "nothing stored".
    private static func readDatabase(from url: URL) -> OpenCodeGoCredential? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            DiagnosticLog.log("opencode-go", "could not open OpenCode's database at \(url.path)")
            return nil
        }
        defer { sqlite3_close(db) }

        // `active` picks the credential `opencode auth switch` has selected;
        // the newest wins otherwise.
        let sql = """
        SELECT integration_id, value FROM credential
        WHERE integration_id IN ('opencode-go', 'opencode')
        ORDER BY active DESC, time_updated DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let query = statement else {
            DiagnosticLog.log("opencode-go", "OpenCode's database has no readable credential table")
            return nil
        }
        defer { sqlite3_finalize(query) }

        var candidates: [OpenCodeGoCredential] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let nameText = sqlite3_column_text(query, 0), let valueText = sqlite3_column_text(query, 1) else { continue }
            let name = String(cString: nameText)
            let raw = String(cString: valueText)
            guard let data = raw.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(StoredValue.self, from: data) else { continue }
            if let credential = entry.credential(entryName: name, source: .database) { candidates.append(credential) }
        }
        return candidates.first { $0.kind == .apiKey } ?? candidates.first
    }

    /// One stored credential: an API key (`"type": "api"`, `key`), or an
    /// OAuth session (`"type": "oauth"`, `access`).
    private struct StoredValue: Decodable {
        let type: String?
        let key: String?
        let access: String?
        let metadata: Metadata?

        struct Metadata: Decodable {
            let orgID: String?
        }

        func credential(entryName: String, source: OpenCodeGoCredential.Source) -> OpenCodeGoCredential? {
            let workspaceID = metadata?.orgID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return OpenCodeGoCredential(
                    kind: .apiKey, token: key, entryName: entryName, source: source,
                    workspaceID: workspaceID?.isEmpty == false ? workspaceID : nil
                )
            }
            if let access = access?.trimmingCharacters(in: .whitespacesAndNewlines), !access.isEmpty {
                return OpenCodeGoCredential(
                    kind: .oauth, token: access, entryName: entryName, source: source,
                    workspaceID: workspaceID?.isEmpty == false ? workspaceID : nil
                )
            }
            return nil
        }
    }
}
