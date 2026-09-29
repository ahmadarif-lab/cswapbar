import XCTest
@testable import AntigravityEngine

final class JetskiStandaloneTokenReaderTests: XCTestCase {
    func testDecodesRefreshTokenFromRealShape() throws {
        let json = """
        {
          "token": {
            "access_token": "ya29.sample",
            "token_type": "Bearer",
            "refresh_token": "1//0gSampleRefreshToken",
            "expiry": "2026-10-01T07:00:00Z"
          },
          "auth_method": "browser",
          "id_token": "eyJhbGciOiJSUzI1NiJ9.sample"
        }
        """
        let token = try JetskiStandaloneTokenReader.decodeRefreshToken(Data(json.utf8))
        XCTAssertEqual(token, "1//0gSampleRefreshToken")
    }

    func testThrowsInvalidFormatOnEmptyRefreshToken() {
        let json = #"{"token": {"access_token": "x", "refresh_token": ""}}"#
        XCTAssertThrowsError(try JetskiStandaloneTokenReader.decodeRefreshToken(Data(json.utf8))) { error in
            XCTAssertEqual(error as? JetskiTokenReaderError, .invalidFormat)
        }
    }

    func testThrowsInvalidFormatOnMalformedJSON() {
        XCTAssertThrowsError(try JetskiStandaloneTokenReader.decodeRefreshToken(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? JetskiTokenReaderError, .invalidFormat)
        }
    }

    func testThrowsInvalidFormatWhenRefreshTokenFieldIsMissing() {
        let json = #"{"token": {"access_token": "x"}}"#
        XCTAssertThrowsError(try JetskiStandaloneTokenReader.decodeRefreshToken(Data(json.utf8))) { error in
            XCTAssertEqual(error as? JetskiTokenReaderError, .invalidFormat)
        }
    }
}
