import XCTest
@testable import CodexEngine

final class CodexUsageParsingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func summarize(_ json: String, fallbackPlan: String? = nil) throws -> CodexUsageSummary {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
        return try CodexUsageParsing.summarize(response, fallbackPlan: fallbackPlan, now: now)
    }

    func testParsesFiveHourAndWeeklyWindows() throws {
        let summary = try summarize("""
        {"plan_type": "plus",
         "rate_limit": {"allowed": true, "limit_reached": false,
           "primary_window":   {"used_percent": 12, "limit_window_seconds": 18000,  "reset_after_seconds": 600,   "reset_at": 1800000600},
           "secondary_window": {"used_percent": 40.5, "limit_window_seconds": 604800, "reset_after_seconds": 90000, "reset_at": 1800090000}}}
        """)

        XCTAssertEqual(summary.windows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertEqual(summary.windows[0].pctUsed, 12, accuracy: 0.001)
        XCTAssertEqual(summary.windows[1].pctUsed, 40.5, accuracy: 0.001)
        XCTAssertEqual(summary.windows[0].resetsAt, Date(timeIntervalSince1970: 1_800_000_600))
        XCTAssertEqual(summary.planName, "Plus")
        XCTAssertFalse(summary.isLimitReached)
    }

    /// A plan with only a weekly window reports it in the primary slot; the
    /// length, not the slot, says what it is.
    func testClassifiesByWindowLengthNotSlot() throws {
        let summary = try summarize("""
        {"rate_limit": {"primary_window": {"used_percent": 3, "limit_window_seconds": 604800, "reset_at": 1800090000}}}
        """)
        XCTAssertEqual(summary.windows.map(\.kind), [.weekly])
    }

    func testSlotStandsInWhenLengthIsMissing() throws {
        let summary = try summarize("""
        {"rate_limit": {
          "primary_window":   {"used_percent": 1},
          "secondary_window": {"used_percent": 2}}}
        """)
        XCTAssertEqual(summary.windows.map(\.kind), [.fiveHour, .weekly])
    }

    func testOddWindowLengthKeepsItsOwnLabel() throws {
        let summary = try summarize("""
        {"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 259200}}}
        """)
        XCTAssertEqual(summary.windows.map(\.kind), [.other(seconds: 259200)])
        XCTAssertEqual(summary.windows[0].kind.label, "3-day")
    }

    func testResetFallsBackToCountdown() throws {
        let summary = try summarize("""
        {"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000, "reset_after_seconds": 120}}}
        """)
        XCTAssertEqual(summary.windows[0].resetsAt, now.addingTimeInterval(120))
    }

    func testClampsPercentAndDropsWindowWithoutNumbers() throws {
        let summary = try summarize("""
        {"rate_limit": {
          "primary_window":   {"used_percent": 140, "limit_window_seconds": 18000},
          "secondary_window": {"limit_window_seconds": 604800}}}
        """)
        XCTAssertEqual(summary.windows.count, 1)
        XCTAssertEqual(summary.windows[0].pctUsed, 100, accuracy: 0.001)
    }

    func testLimitReachedAndCredits() throws {
        let summary = try summarize("""
        {"rate_limit": {"limit_reached": true, "primary_window": {"used_percent": 100, "limit_window_seconds": 18000}},
         "credits": {"has_credits": true, "unlimited": false, "balance": "12.50"}}
        """)
        XCTAssertTrue(summary.isLimitReached)
        XCTAssertEqual(summary.creditBalance, "12.50")
    }

    func testCreditsWithoutBalanceAreOmitted() throws {
        let summary = try summarize("""
        {"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000}},
         "credits": {"has_credits": false, "unlimited": false, "balance": "0"}}
        """)
        XCTAssertNil(summary.creditBalance)
    }

    func testPlanFallsBackToTheTokensPlan() throws {
        let summary = try summarize(
            #"{"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000}}}"#,
            fallbackPlan: "pro"
        )
        XCTAssertEqual(summary.planName, "Pro")
    }

    func testNoUsableWindowsIsAnError() {
        XCTAssertThrowsError(try summarize(#"{"plan_type": "plus"}"#)) { error in
            guard case CodexEngineError.decoding = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: - Subscription

    private func subscription(_ json: String, accountID: String = "acc-1") throws -> CodexSubscription? {
        let response = try JSONDecoder().decode(CodexAccountCheckResponse.self, from: Data(json.utf8))
        return CodexUsageParsing.subscription(from: response, accountID: accountID)
    }

    func testRenewingPlanReportsTheRenewalDate() throws {
        let result = try XCTUnwrap(try subscription("""
        {"accounts": {"default": {"entitlement": {"has_active_subscription": true,
          "renews_at": "2026-11-10T12:10:09+00:00", "cancels_at": null},
          "last_active_subscription": {"will_renew": true}}}}
        """))
        XCTAssertFalse(result.isCancelled)
        XCTAssertEqual(result.date.timeIntervalSince1970, 1_794_312_609, accuracy: 0.01)
    }

    /// What a plan cancelled from Settings > Billing really looks like: the
    /// entitlement still carries `renews_at`, only `will_renew` changed.
    func testCancelledPlanIsReadFromWillRenew() throws {
        let result = try XCTUnwrap(try subscription("""
        {"accounts": {"acc-1": {"entitlement": {"has_active_subscription": true,
          "renews_at": "2026-11-10T12:10:09+00:00", "cancels_at": null, "expires_at": "2026-11-10T18:10:09+00:00"},
          "last_active_subscription": {"will_renew": false, "cancellation_outcome": "deactivate"}}}}
        """))
        XCTAssertTrue(result.isCancelled)
        XCTAssertEqual(result.date.timeIntervalSince1970, 1_794_312_609, accuracy: 0.01)
    }

    func testAnExplicitCancelDateAlsoCountsAsCancelled() throws {
        let result = try XCTUnwrap(try subscription("""
        {"accounts": {"acc-1": {"entitlement": {"has_active_subscription": true,
          "renews_at": null, "cancels_at": "2026-11-10T12:10:09.000000+00:00"}}}}
        """))
        XCTAssertTrue(result.isCancelled)
        XCTAssertEqual(result.date.timeIntervalSince1970, 1_794_312_609, accuracy: 0.01)
    }

    func testTheLoginsOwnAccountWinsOverDefault() throws {
        let result = try XCTUnwrap(try subscription("""
        {"accounts": {
          "default": {"entitlement": {"has_active_subscription": true, "renews_at": "2026-12-01T00:00:00+00:00"}},
          "acc-1": {"entitlement": {"has_active_subscription": true, "renews_at": "2026-11-10T12:10:09+00:00"}}}}
        """))
        XCTAssertEqual(result.date.timeIntervalSince1970, 1_794_312_609, accuracy: 0.01)
    }

    func testFreePlanHasNoSubscription() throws {
        XCTAssertNil(try subscription("""
        {"accounts": {"default": {"entitlement": {"has_active_subscription": false,
          "renews_at": null, "cancels_at": null}}}}
        """))
        XCTAssertNil(try subscription(#"{"accounts": {}}"#))
        XCTAssertNil(try subscription("{}"))
    }
}
