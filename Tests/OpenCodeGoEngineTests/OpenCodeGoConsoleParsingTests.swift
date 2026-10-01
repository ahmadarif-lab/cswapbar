import XCTest
@testable import OpenCodeGoEngine

final class OpenCodeGoConsoleParsingTests: XCTestCase {
    /// The real `GET /console/api/go/status` payload, captured from a live Go
    /// workspace. Amounts are micro-cents (1e-8 of a dollar) as strings, and
    /// the month meter carries no reset of its own.
    private let liveStatus = """
    {
      "subscriberUserId": "acc_01KES24P4CBBWZ9HS4T4HPPG0V",
      "product": "go",
      "renewalProduct": "go",
      "renewalCurrency": "usd",
      "useBalance": false,
      "cancelAtPeriodEnd": false,
      "access": {
        "startsAt": "2026-10-01T12:30:09.000Z",
        "endsAt": "2026-11-01T12:30:09.000Z",
        "cancelAtPeriodEnd": false,
        "meters": {
          "fiveHour": {
            "startsAt": "2026-10-01T14:39:03.465Z",
            "resetsAt": "2026-10-01T19:39:03.465Z",
            "limitMicroCents": "1200000000",
            "usedMicroCents": "19114398"
          },
          "week": {
            "startsAt": "2026-09-28T00:00:00.000Z",
            "resetsAt": "2026-10-05T00:00:00.000Z",
            "limitMicroCents": "3000000000",
            "usedMicroCents": "19114398"
          },
          "month": {
            "resetsAt": "2026-11-01T12:30:09.000Z",
            "limitMicroCents": "6000000000",
            "usedMicroCents": "19114398"
          }
        }
      }
    }
    """

    private func summarize(_ json: String) throws -> OpenCodeGoUsageSummary {
        let status = try JSONDecoder().decode(OpenCodeGoConsoleStatus.self, from: Data(json.utf8))
        return try OpenCodeGoUsageParsing.summarizeConsole(status)
    }

    func testParsesLiveConsolePayload() throws {
        let summary = try summarize(liveStatus)

        XCTAssertEqual(summary.planName, "Go")
        XCTAssertEqual(summary.windows.map(\.kind), [.rolling, .weekly, .monthly])

        let rolling = summary.windows[0]
        // 19114398 / 1200000000 = $0.191 of $12.00
        XCTAssertEqual(rolling.pctUsed, 1.5928665, accuracy: 0.0001)
        XCTAssertEqual(rolling.usedUSD!, 0.19114398, accuracy: 0.0000001)
        XCTAssertEqual(rolling.limitUSD!, 12, accuracy: 0.0001)
        XCTAssertFalse(rolling.isRateLimited)
        XCTAssertEqual(rolling.resetsAt?.timeIntervalSince1970 ?? 0, 1790883543.465, accuracy: 0.01)

        let weekly = summary.windows[1]
        XCTAssertEqual(weekly.pctUsed, 0.6371466, accuracy: 0.0001)
        XCTAssertEqual(weekly.limitUSD!, 30, accuracy: 0.0001)

        let monthly = summary.windows[2]
        XCTAssertEqual(monthly.pctUsed, 0.3185733, accuracy: 0.0001)
        XCTAssertEqual(monthly.limitUSD!, 60, accuracy: 0.0001)

        // The billing period end is the subscription's renewal.
        XCTAssertEqual(summary.renewsAt?.timeIntervalSince1970 ?? 0, 1793536209, accuracy: 0.01)
    }

    /// The month meter has no `resetsAt` of its own; the billing period end
    /// stands in for it.
    func testMonthlyResetFallsBackToBillingPeriodEnd() throws {
        let json = """
        {"product": "go", "access": {"endsAt": "2026-11-01T12:30:09.000Z", "meters": {
          "fiveHour": {"limitMicroCents": "1200000000", "usedMicroCents": "0"},
          "month": {"limitMicroCents": "6000000000", "usedMicroCents": "100000000"}
        }}}
        """
        let summary = try summarize(json)
        let monthly = try XCTUnwrap(summary.windows.first { $0.kind == .monthly })
        XCTAssertEqual(monthly.resetsAt, summary.renewsAt)
        XCTAssertEqual(monthly.resetsAt?.timeIntervalSince1970 ?? 0, 1793536209, accuracy: 0.01)
    }

    func testWeeklyAndMonthlyAreOptional() throws {
        let json = """
        {"product": "go", "access": {"meters": {
          "fiveHour": {"limitMicroCents": "1200000000", "usedMicroCents": "600000000"}
        }}}
        """
        let summary = try summarize(json)
        XCTAssertEqual(summary.windows.map(\.kind), [.rolling])
        XCTAssertEqual(summary.windows[0].pctUsed, 50, accuracy: 0.0001)
        XCTAssertNil(summary.renewsAt)
    }

    /// An exhausted meter is reported as rate-limited, and the percent never
    /// runs past 100 even if the spend does.
    func testExhaustedMeterIsRateLimitedAndClamped() throws {
        let json = """
        {"product": "go", "access": {"meters": {
          "fiveHour": {"limitMicroCents": "1200000000", "usedMicroCents": "1500000000"}
        }}}
        """
        let summary = try summarize(json)
        XCTAssertTrue(summary.windows[0].isRateLimited)
        XCTAssertEqual(summary.windows[0].pctUsed, 100, accuracy: 0.0001)
    }

    func testGoPlusPlanName() throws {
        let json = """
        {"product": "goplus", "access": {"meters": {
          "fiveHour": {"limitMicroCents": "100", "usedMicroCents": "1"}
        }}}
        """
        XCTAssertEqual(try summarize(json).planName, "Go Plus")
    }

    /// A meter with no limit (or a zero one) is dropped rather than dividing
    /// by zero -- the rest of the report still renders.
    func testMeterWithoutLimitIsSkipped() throws {
        let json = """
        {"product": "go", "access": {"meters": {
          "fiveHour": {"limitMicroCents": "0", "usedMicroCents": "5"},
          "week": {"limitMicroCents": "3000000000", "usedMicroCents": "150000000"}
        }}}
        """
        let summary = try summarize(json)
        XCTAssertEqual(summary.windows.map(\.kind), [.weekly])
    }

    /// No `access` object at all is how the console reports a workspace
    /// without a Go subscription.
    func testMissingAccessIsNoSubscription() throws {
        let status = try JSONDecoder().decode(OpenCodeGoConsoleStatus.self, from: Data(#"{"product": null}"#.utf8))
        XCTAssertThrowsError(try OpenCodeGoUsageParsing.summarizeConsole(status)) { error in
            XCTAssertEqual(error as? OpenCodeGoEngineError, .noSubscription)
        }
    }

    /// The console answers `null` (not an object) for a workspace with no Go
    /// subscription, so the engine decodes it as an optional.
    func testNullBodyDecodesToNil() throws {
        let decoded = try JSONDecoder().decode(OpenCodeGoConsoleStatus?.self, from: Data("null".utf8))
        XCTAssertNil(decoded)
    }

    /// Amounts have also been seen as plain numbers; both decode.
    func testNumericMicroCentsDecode() throws {
        let json = """
        {"product": "go", "access": {"meters": {
          "fiveHour": {"limitMicroCents": 1200000000, "usedMicroCents": 600000000}
        }}}
        """
        let summary = try summarize(json)
        XCTAssertEqual(summary.windows[0].pctUsed, 50, accuracy: 0.0001)
        XCTAssertEqual(summary.windows[0].usedUSD!, 6, accuracy: 0.0001)
    }
}
