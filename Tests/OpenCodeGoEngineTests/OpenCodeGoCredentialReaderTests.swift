import SQLite3
import XCTest
@testable import OpenCodeGoEngine

final class OpenCodeGoCredentialReaderTests: XCTestCase {
    private var authFileURL: URL!
    private var databaseURL: URL!
    private var temporaryFiles: [URL] = []

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
        authFileURL = directory.appendingPathComponent("opencode-auth-\(UUID().uuidString).json")
        databaseURL = directory.appendingPathComponent("opencode-\(UUID().uuidString).db")
    }

    override func tearDownWithError() throws {
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles = []
        try? FileManager.default.removeItem(at: authFileURL)
        try? FileManager.default.removeItem(at: databaseURL)
    }

    private func writeAuthFile(_ json: String) throws {
        try Data(json.utf8).write(to: authFileURL)
    }

    /// Builds a database with OpenCode v2's own `credential` schema.
    @discardableResult
    private func writeDatabase(_ rows: [(integration: String, value: String, active: Int, updated: Int)]) throws -> URL {
        temporaryFiles.append(databaseURL)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }

        let create = """
        CREATE TABLE credential (
          id text PRIMARY KEY, integration_id text, label text NOT NULL, value text NOT NULL,
          connector_id text, method_id text, active integer,
          time_created integer NOT NULL, time_updated integer NOT NULL
        )
        """
        XCTAssertEqual(sqlite3_exec(db, create, nil, nil, nil), SQLITE_OK)
        for (index, row) in rows.enumerated() {
            let insert = """
            INSERT INTO credential (id, integration_id, label, value, active, time_created, time_updated)
            VALUES ('cred_\(index)', '\(row.integration)', 'Label', '\(row.value)', \(row.active), 0, \(row.updated))
            """
            XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        }
        return databaseURL
    }

    private func read() throws -> OpenCodeGoCredential? {
        try OpenCodeGoCredentialReader.read(from: authFileURL, databaseURL: databaseURL)
    }

    // MARK: - auth.json

    func testReadsAPIKeyFromAuthFile() throws {
        try writeAuthFile(#"{"opencode-go": {"type": "api", "key": "sk-abc123"}}"#)
        let credential = try XCTUnwrap(try read())
        XCTAssertEqual(credential.kind, .apiKey)
        XCTAssertEqual(credential.token, "sk-abc123")
        XCTAssertEqual(credential.entryName, "opencode-go")
        XCTAssertEqual(credential.source, .authFile)
        XCTAssertEqual(credential.kind.title, "API key")
    }

    func testFallsBackToTheZenEntry() throws {
        try writeAuthFile(#"{"opencode": {"type": "api", "key": "sk-zen"}}"#)
        XCTAssertEqual(try read()?.entryName, "opencode")
    }

    func testReadsOAuthSessionFromAuthFile() throws {
        try writeAuthFile(#"{"opencode-go": {"type": "oauth", "access": "st-xyz"}}"#)
        let credential = try XCTUnwrap(try read())
        XCTAssertEqual(credential.kind, .oauth)
        XCTAssertEqual(credential.token, "st-xyz")
    }

    func testAuthFileWithoutAnyKnownEntryIsNotConfigured() throws {
        try writeAuthFile(#"{"openai": {"type": "api", "key": "sk-x"}}"#)
        XCTAssertNil(try read())
    }

    func testMalformedAuthFileIsADecodingError() throws {
        try writeAuthFile("not json at all")
        XCTAssertThrowsError(try read()) { error in
            guard let engineError = error as? OpenCodeGoEngineError, case .decoding = engineError else {
                return XCTFail("expected a decoding error, got \(error)")
            }
        }
    }

    // MARK: - opencode.db

    func testReadsAPIKeyFromOpenCodeDatabase() throws {
        try writeDatabase([
            ("opencode", #"{"type": "api", "key": "sk-db"}"#, 1, 100),
        ])
        let credential = try XCTUnwrap(try read())
        XCTAssertEqual(credential.kind, .apiKey)
        XCTAssertEqual(credential.token, "sk-db")
        XCTAssertEqual(credential.source, .database)
    }

    func testReadsOAuthSessionFromOpenCodeDatabase() throws {
        try writeDatabase([
            ("opencode", #"{"type": "oauth", "access": "st-db", "refresh": "rt-db"}"#, 1, 100),
        ])
        let credential = try XCTUnwrap(try read())
        XCTAssertEqual(credential.kind, .oauth)
        XCTAssertEqual(credential.token, "st-db")
    }

    /// `opencode auth login` records the workspace the session belongs to, so
    /// the console route doesn't have to look it up.
    func testReadsWorkspaceIDFromMetadata() throws {
        try writeDatabase([
            ("opencode",
             #"{"type": "oauth", "access": "st-db", "metadata": {"orgID": "wrk_abc", "orgName": "Default"}}"#,
             1, 100),
        ])
        XCTAssertEqual(try read()?.workspaceID, "wrk_abc")
    }

    func testWorkspaceIDIsNilWhenNotRecorded() throws {
        try writeAuthFile(#"{"opencode-go": {"type": "api", "key": "sk-abc"}}"#)
        XCTAssertNil(try read()?.workspaceID)
    }

    /// `opencode auth switch` marks the chosen credential active; that one wins.
    func testActiveCredentialWinsOverNewerInactiveOne() throws {
        try writeDatabase([
            ("opencode", #"{"type": "api", "key": "sk-active"}"#, 1, 100),
            ("opencode", #"{"type": "api", "key": "sk-newer"}"#, 0, 200),
        ])
        XCTAssertEqual(try read()?.token, "sk-active")
    }

    func testMissingDatabaseIsNotAnError() throws {
        XCTAssertNil(try read())
    }

    /// A database that exists but has no `credential` table (an older
    /// OpenCode schema) reads as "nothing stored" rather than failing.
    func testDatabaseWithoutCredentialTableIsNotConfigured() throws {
        temporaryFiles.append(databaseURL)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE unrelated (id text)", nil, nil, nil), SQLITE_OK)
        XCTAssertNil(try read())
    }

    /// An unrelated integration in the database is ignored.
    func testDatabaseIgnoresOtherIntegrations() throws {
        try writeDatabase([
            ("deepseek", #"{"type": "key", "key": "sk-deepseek"}"#, 1, 100),
        ])
        XCTAssertNil(try read())
    }

    // MARK: - Both sources

    /// Only an API key can read the quota endpoint, so a key in the database
    /// beats an OAuth session sitting in a stale `auth.json`.
    func testAPIKeyBeatsOAuthSessionAcrossSources() throws {
        try writeAuthFile(#"{"opencode": {"type": "oauth", "access": "st-old"}}"#)
        try writeDatabase([
            ("opencode", #"{"type": "api", "key": "sk-db"}"#, 1, 100),
        ])
        let credential = try XCTUnwrap(try read())
        XCTAssertEqual(credential.token, "sk-db")
        XCTAssertEqual(credential.source, .database)
    }

    func testAuthFileKeyWinsWhenBothHoldKeys() throws {
        try writeAuthFile(#"{"opencode-go": {"type": "api", "key": "sk-file"}}"#)
        try writeDatabase([
            ("opencode", #"{"type": "api", "key": "sk-db"}"#, 1, 100),
        ])
        XCTAssertEqual(try read()?.token, "sk-file")
    }

    func testOAuthIsUsedWhenNoKeyExistsAnywhere() throws {
        try writeAuthFile(#"{"opencode": {"type": "oauth", "access": "st-file"}}"#)
        try writeDatabase([
            ("opencode", #"{"type": "oauth", "access": "st-db"}"#, 1, 100),
        ])
        XCTAssertEqual(try read()?.token, "st-file")
        XCTAssertEqual(try read()?.kind, .oauth)
    }
}
