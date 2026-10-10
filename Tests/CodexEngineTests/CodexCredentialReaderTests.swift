import XCTest
@testable import CodexEngine

final class CodexCredentialReaderTests: XCTestCase {
    /// An unsigned JWT with the given payload -- the reader never verifies it.
    private func jwt(_ payload: [String: Any]) -> String {
        func b64(_ object: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(["alg": "none"])).\(b64(payload)).sig"
    }

    private func authFile(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testReadsAccountPlanEmailAndExpiry() throws {
        let access = jwt([
            "exp": 1_800_000_000,
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"],
        ])
        let id = jwt(["email": "me@example.com"])
        let credential = try CodexCredentialReader.parse(authFile([
            "auth_mode": "chatgpt",
            "tokens": ["access_token": access, "id_token": id, "refresh_token": "r", "account_id": "acct-1"],
        ]))

        XCTAssertEqual(credential.accountID, "acct-1")
        XCTAssertEqual(credential.planType, "plus")
        XCTAssertEqual(credential.email, "me@example.com")
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(credential.accessToken, access)
    }

    func testAccountIDFallsBackToTheTokenClaim() throws {
        let access = jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct-from-claim"]])
        let credential = try CodexCredentialReader.parse(authFile(["tokens": ["access_token": access]]))
        XCTAssertEqual(credential.accountID, "acct-from-claim")
    }

    func testAPIKeyLoginIsNamed() throws {
        XCTAssertThrowsError(try CodexCredentialReader.parse(authFile(["OPENAI_API_KEY": "sk-test"]))) {
            XCTAssertEqual($0 as? CodexCredentialError, .apiKeyLogin)
        }
    }

    func testLoggedOutFileIsMissing() throws {
        XCTAssertThrowsError(try CodexCredentialReader.parse(authFile(["OPENAI_API_KEY": NSNull()]))) {
            XCTAssertEqual($0 as? CodexCredentialError, .missing)
        }
    }

    func testMissingFileIsMissing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("no-such-codex-\(UUID()).json")
        XCTAssertThrowsError(try CodexCredentialReader.read(from: url)) {
            XCTAssertEqual($0 as? CodexCredentialError, .missing)
        }
    }
}
