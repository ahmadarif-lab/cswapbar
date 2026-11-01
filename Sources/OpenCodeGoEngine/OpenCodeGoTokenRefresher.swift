import Foundation
import ProviderKit
import SQLite3

/// Renews an OpenCode console OAuth session.
///
/// The access token OpenCode stores lives for a day or so; OpenCode itself
/// renews it the next time it runs. CSwapBar polls without OpenCode running,
/// so it has to do the same, or the quota goes stale the moment the token
/// lapses. The refresh token **rotates** -- each exchange invalidates the old
/// one -- so the new pair is written straight back to where OpenCode keeps
/// it. Without that, refreshing here would log OpenCode itself out.
enum OpenCodeGoTokenRefresher {
    static let defaultServer = "https://opencode.ai/console"
    static let clientID = "opencode-cli"

    struct Tokens: Equatable {
        let access: String
        let refresh: String
        let expiresAt: Date
        let orgID: String?
    }

    private struct Response: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let org_id: String?
    }

    static func refreshURL(server: String?) -> URL? {
        var base = (server ?? defaultServer).trimmingCharacters(in: .whitespacesAndNewlines)
        // OpenCode normalises the old `console.opencode.ai` host the same way.
        if base.hasPrefix("https://console.opencode.ai") { base = defaultServer }
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/auth/device/token")
    }

    /// Exchanges the refresh token. `invalid_grant` -- a revoked or already
    /// rotated token -- is `sessionExpired`: only a new sign-in helps.
    static func refresh(
        _ credential: OpenCodeGoCredential, session: URLSession, now: Date = Date()
    ) async throws -> Tokens {
        guard let refreshToken = credential.refreshToken else { throw OpenCodeGoEngineError.sessionExpired }
        guard let url = refreshURL(server: credential.server) else {
            throw OpenCodeGoEngineError.network("invalid OpenCode server URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])

        let data: Data
        let status: Int
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenCodeGoEngineError.network("no HTTP response")
            }
            data = body
            status = http.statusCode
        } catch let error as OpenCodeGoEngineError {
            throw error
        } catch {
            throw OpenCodeGoEngineError.network(error.localizedDescription)
        }

        switch status {
        case 200..<300: break
        case 400, 401: throw OpenCodeGoEngineError.sessionExpired
        default: throw OpenCodeGoEngineError.http(status, String(String(decoding: data, as: UTF8.self).prefix(300)))
        }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return Tokens(
                access: decoded.access_token,
                refresh: decoded.refresh_token,
                expiresAt: now.addingTimeInterval(decoded.expires_in),
                orgID: decoded.org_id
            )
        } catch {
            throw OpenCodeGoEngineError.decoding("token refresh: \(error)")
        }
    }

    /// The credential as it looks after a refresh.
    static func applying(_ tokens: Tokens, to credential: OpenCodeGoCredential) -> OpenCodeGoCredential {
        OpenCodeGoCredential(
            kind: credential.kind, token: tokens.access, entryName: credential.entryName,
            source: credential.source, workspaceID: tokens.orgID ?? credential.workspaceID,
            refreshToken: tokens.refresh, expiresAt: tokens.expiresAt,
            server: credential.server, rowID: credential.rowID
        )
    }

    // MARK: - Persisting

    /// Writes the new tokens back, keeping every other field of the stored
    /// value (`methodID`, `metadata`, ...) as it was. Returns `false` when it
    /// could not -- the caller still has the tokens in memory, but OpenCode
    /// will need a fresh sign-in, which is worth a log line.
    @discardableResult
    static func persist(
        _ tokens: Tokens, for credential: OpenCodeGoCredential, authFileURL: URL, databaseURL: URL,
        now: Date = Date()
    ) -> Bool {
        switch credential.source {
        case .authFile: return persistToAuthFile(tokens, credential: credential, url: authFileURL)
        case .database: return persistToDatabase(tokens, credential: credential, url: databaseURL, now: now)
        }
    }

    /// `value` with the tokens swapped in; everything else untouched.
    static func updatedValue(_ value: [String: Any], with tokens: Tokens) -> [String: Any] {
        var updated = value
        updated["access"] = tokens.access
        updated["refresh"] = tokens.refresh
        updated["expires"] = Int64(tokens.expiresAt.timeIntervalSince1970 * 1000)
        if let orgID = tokens.orgID {
            var metadata = (updated["metadata"] as? [String: Any]) ?? [:]
            if metadata["orgID"] as? String != orgID { metadata["orgID"] = orgID }
            updated["metadata"] = metadata
        }
        return updated
    }

    private static func persistToDatabase(
        _ tokens: Tokens, credential: OpenCodeGoCredential, url: URL, now: Date
    ) -> Bool {
        guard let rowID = credential.rowID else { return false }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            DiagnosticLog.log("opencode-go", "could not open OpenCode's database for writing")
            return false
        }
        defer { sqlite3_close(db) }
        // OpenCode may be running and holding the write lock for a moment.
        sqlite3_busy_timeout(db, 5000)

        // Read and write inside one transaction so a concurrent refresh by
        // OpenCode itself can't be overwritten with a stale value.
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            DiagnosticLog.log("opencode-go", "OpenCode's database is locked; token not saved")
            return false
        }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }

        var select: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM credential WHERE id = ?", -1, &select, nil) == SQLITE_OK,
              let selectStatement = select else { return false }
        defer { sqlite3_finalize(selectStatement) }
        sqlite3_bind_text(selectStatement, 1, rowID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(selectStatement) == SQLITE_ROW, let text = sqlite3_column_text(selectStatement, 0),
              let object = try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any]
        else { return false }

        let updated = updatedValue(object, with: tokens)
        guard let data = try? JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return false }

        var update: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "UPDATE credential SET value = ?, time_updated = ? WHERE id = ?", -1, &update, nil
        ) == SQLITE_OK, let updateStatement = update else { return false }
        defer { sqlite3_finalize(updateStatement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(updateStatement, 1, json, -1, transient)
        sqlite3_bind_int64(updateStatement, 2, Int64(now.timeIntervalSince1970 * 1000))
        sqlite3_bind_text(updateStatement, 3, rowID, -1, transient)
        guard sqlite3_step(updateStatement) == SQLITE_DONE else { return false }

        committed = sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
        return committed
    }

    private static func persistToAuthFile(_ tokens: Tokens, credential: OpenCodeGoCredential, url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[credential.entryName] as? [String: Any] else { return false }
        root[credential.entryName] = updatedValue(entry, with: tokens)
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        do {
            try out.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
