import SQLite3
import XCTest
@testable import OpenCodeGoEngine

final class OpenCodeGoTokenRefresherTests: XCTestCase {
    private var databaseURL: URL!
    private var authFileURL: URL!

    private static let storedValue = """
    {"type":"oauth","methodID":"device","refresh":"rt_old","access":"st_old","expires":1000,\
    "metadata":{"server":"https://opencode.ai/console","email":"a@b.c","orgID":"wrk_1","orgName":"Default"}}
    """

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
        databaseURL = directory.appendingPathComponent("opencode-refresh-\(UUID().uuidString).db")
        authFileURL = directory.appendingPathComponent("opencode-refresh-auth-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
        try? FileManager.default.removeItem(at: authFileURL)
    }

    private func makeDatabase(value: String = storedValue) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE credential (
          id text PRIMARY KEY, integration_id text, label text NOT NULL, value text NOT NULL,
          connector_id text, method_id text, active integer,
          time_created integer NOT NULL, time_updated integer NOT NULL
        )
        """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
        INSERT INTO credential (id, integration_id, label, value, active, time_created, time_updated)
        VALUES ('cred_1', 'opencode', 'Label', '\(value)', 1, 0, 5)
        """, nil, nil, nil), SQLITE_OK)
    }

    private func tokens(orgID: String? = nil) -> OpenCodeGoTokenRefresher.Tokens {
        .init(access: "st_new", refresh: "rt_new", expiresAt: Date(timeIntervalSince1970: 2_000_000), orgID: orgID)
    }

    // MARK: - Reading

    func testReaderKeepsRefreshTokenExpiryServerAndRow() throws {
        try makeDatabase()
        let credential = try XCTUnwrap(
            try OpenCodeGoCredentialReader.read(from: authFileURL, databaseURL: databaseURL)
        )
        XCTAssertEqual(credential.refreshToken, "rt_old")
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(credential.server, "https://opencode.ai/console")
        XCTAssertEqual(credential.rowID, "cred_1")
        XCTAssertTrue(credential.isExpired())
    }

    func testExpiryHasLeewayAndIgnoresApiKeys() {
        let now = Date(timeIntervalSince1970: 1_000)
        func oauth(expires: TimeInterval?) -> OpenCodeGoCredential {
            OpenCodeGoCredential(
                kind: .oauth, token: "t", entryName: "opencode", source: .database, workspaceID: nil,
                expiresAt: expires.map { Date(timeIntervalSince1970: $0) }
            )
        }
        XCTAssertTrue(oauth(expires: 1_030).isExpired(now: now))
        XCTAssertFalse(oauth(expires: 1_200).isExpired(now: now))
        XCTAssertFalse(oauth(expires: nil).isExpired(now: now))
        let key = OpenCodeGoCredential(
            kind: .apiKey, token: "k", entryName: "opencode", source: .database, workspaceID: nil,
            expiresAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertFalse(key.isExpired(now: now))
    }

    // MARK: - Persisting

    func testPersistRewritesTokensAndKeepsEverythingElse() throws {
        try makeDatabase()
        let credential = try XCTUnwrap(
            try OpenCodeGoCredentialReader.read(from: authFileURL, databaseURL: databaseURL)
        )
        XCTAssertTrue(OpenCodeGoTokenRefresher.persist(
            tokens(), for: credential, authFileURL: authFileURL, databaseURL: databaseURL,
            now: Date(timeIntervalSince1970: 3_000)
        ))

        let reread = try XCTUnwrap(
            try OpenCodeGoCredentialReader.read(from: authFileURL, databaseURL: databaseURL)
        )
        XCTAssertEqual(reread.token, "st_new")
        XCTAssertEqual(reread.refreshToken, "rt_new")
        XCTAssertEqual(reread.expiresAt, Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(reread.workspaceID, "wrk_1")
        XCTAssertFalse(reread.isExpired(now: Date(timeIntervalSince1970: 1_000)))

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(db, "SELECT value, time_updated FROM credential", -1, &statement, nil), SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(String(cString: sqlite3_column_text(statement, 0)).utf8))
                as? [String: Any]
        )
        XCTAssertEqual(object["methodID"] as? String, "device")
        XCTAssertEqual((object["metadata"] as? [String: Any])?["email"] as? String, "a@b.c")
        XCTAssertEqual(sqlite3_column_int64(statement, 1), 3_000_000)
    }

    func testPersistTakesANewOrgID() throws {
        try makeDatabase()
        let credential = try XCTUnwrap(
            try OpenCodeGoCredentialReader.read(from: authFileURL, databaseURL: databaseURL)
        )
        XCTAssertTrue(OpenCodeGoTokenRefresher.persist(
            tokens(orgID: "wrk_2"), for: credential, authFileURL: authFileURL, databaseURL: databaseURL
        ))
        XCTAssertEqual(
            try OpenCodeGoCredentialReader.read(from: authFileURL, databaseURL: databaseURL)?.workspaceID, "wrk_2"
        )
    }

    func testPersistToAuthFileKeepsOtherEntries() throws {
        try Data("""
        {"openai": {"type": "api", "key": "sk-1"},
         "opencode": {"type": "oauth", "access": "st_old", "refresh": "rt_old", "expires": 1000}}
        """.utf8).write(to: authFileURL)
        let credential = try XCTUnwrap(
            try OpenCodeGoCredentialReader.read(from: authFileURL, databaseURL: databaseURL)
        )
        XCTAssertEqual(credential.source, .authFile)
        XCTAssertTrue(OpenCodeGoTokenRefresher.persist(
            tokens(), for: credential, authFileURL: authFileURL, databaseURL: databaseURL
        ))
        let reread = try XCTUnwrap(
            try OpenCodeGoCredentialReader.read(from: authFileURL, databaseURL: databaseURL)
        )
        XCTAssertEqual(reread.token, "st_new")
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: authFileURL)) as? [String: Any]
        )
        XCTAssertEqual((root["openai"] as? [String: Any])?["key"] as? String, "sk-1")
    }

    func testPersistReportsFailureWithoutARow() {
        let credential = OpenCodeGoCredential(
            kind: .oauth, token: "t", entryName: "opencode", source: .database, workspaceID: nil
        )
        XCTAssertFalse(OpenCodeGoTokenRefresher.persist(
            tokens(), for: credential, authFileURL: authFileURL, databaseURL: databaseURL
        ))
    }

    // MARK: - URL

    func testRefreshURL() {
        XCTAssertEqual(
            OpenCodeGoTokenRefresher.refreshURL(server: nil)?.absoluteString,
            "https://opencode.ai/console/auth/device/token"
        )
        XCTAssertEqual(
            OpenCodeGoTokenRefresher.refreshURL(server: "https://console.opencode.ai/")?.absoluteString,
            "https://opencode.ai/console/auth/device/token"
        )
        XCTAssertEqual(
            OpenCodeGoTokenRefresher.refreshURL(server: "https://self.example/console/")?.absoluteString,
            "https://self.example/console/auth/device/token"
        )
    }
}
