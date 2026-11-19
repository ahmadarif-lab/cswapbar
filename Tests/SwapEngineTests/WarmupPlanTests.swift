import XCTest
@testable import SwapEngine

final class WarmupPlanTests: XCTestCase {
    private func oauth(access: String = "at-live", expiresAt: Int = 9_999_999_999_999) -> String {
        #"{"claudeAiOauth": {"accessToken": "\#(access)", "refreshToken": "rt", "expiresAt": \#(expiresAt)}}"#
    }

    private func decide(
        active: Bool = false, _ creds: String, live: Bool = false, expired: Bool = false
    ) -> WarmupPlan {
        WarmupPlan.decide(isActive: active, credentials: creds, hasLiveSession: { live }, isExpired: { _ in expired })
    }

    func testActiveAccountRunsAsTheDefaultLogin() {
        // Whatever it holds, even nothing: the signed-in account needs no token.
        XCTAssertEqual(decide(active: true, ""), .launch(.defaultLogin))
        XCTAssertEqual(decide(active: true, oauth(), expired: true), .launch(.defaultLogin))
    }

    func testStoredAccountUsesItsOwnAccessToken() {
        XCTAssertEqual(decide(oauth(access: "at-2")), .launch(.token("at-2")))
    }

    func testExpiredTokenAsksForARenewalFirst() {
        XCTAssertEqual(decide(oauth(), expired: true), .renewThenToken)
    }

    func testSetupTokenIsUsedAsIsEvenWhenTheClockSaysExpired() {
        XCTAssertEqual(decide("sk-ant-oat01-abc\n", expired: true), .launch(.token("sk-ant-oat01-abc")))
    }

    func testAPIKeyIsSkipped() {
        guard case .launch(.skip) = decide("sk-ant-api03-abc") else { return XCTFail("API key must be skipped") }
    }

    func testEmptyOrLoginlessCredentialIsSkipped() {
        for creds in ["", #"{"mcpOAuth": {}}"#, #"{"claudeAiOauth": {"accessToken": ""}}"#, "not json"] {
            guard case .launch(.skip) = decide(creds) else { return XCTFail("\(creds) must be skipped") }
        }
    }

    func testAccountWithARunningSessionIsLeftAlone() {
        guard case .launch(.skip) = decide(oauth(), live: true) else { return XCTFail("live session must be skipped") }
        guard case .launch(.skip) = decide(oauth(), live: true, expired: true) else { return XCTFail("live session must beat renewal") }
    }

    func testLiveSessionIsNotConsultedForTheActiveAccount() {
        let plan = WarmupPlan.decide(
            isActive: true, credentials: oauth(),
            hasLiveSession: { XCTFail("active account must not scan sessions"); return true },
            isExpired: { _ in false }
        )
        XCTAssertEqual(plan, .launch(.defaultLogin))
    }
}
