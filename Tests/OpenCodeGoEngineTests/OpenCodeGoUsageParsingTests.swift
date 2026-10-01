import XCTest
@testable import OpenCodeGoEngine

final class OpenCodeGoUsageParsingTests: XCTestCase {
    private func summarize(_ json: String) throws -> OpenCodeGoUsageSummary {
        let response = try JSONDecoder().decode(OpenCodeGoUsageResponse.self, from: Data(json.utf8))
        return try OpenCodeGoUsageParsing.summarize(response)
    }

    /// The real production payload: `{ "usage": { rolling, weekly, monthly } }`,
    /// each window a `status` + `percent` (used, 0-100) + ISO `resetsAt`.
    func testParsesDocumentedResponse() throws {
        let summary = try summarize("""
        {"usage": {
          "rolling": {"status": "ok", "percent": 4,  "resetsAt": "2026-08-13T16:27:38.287Z"},
          "weekly":  {"status": "ok", "percent": 3,  "resetsAt": "2026-08-17T00:00:00.287Z"},
          "monthly": {"status": "ok", "percent": 1,  "resetsAt": "2026-09-13T06:06:01.287Z"}
        }}
        """)

        XCTAssertEqual(summary.windows.map(\.kind), [.rolling, .weekly, .monthly])
        XCTAssertEqual(summary.windows[0].pctUsed, 4, accuracy: 0.001)
        XCTAssertEqual(summary.windows[1].pctUsed, 3, accuracy: 0.001)
        XCTAssertEqual(summary.windows[2].pctUsed, 1, accuracy: 0.001)
        XCTAssertEqual(summary.windows[0].kind.label, "5-hour")
        XCTAssertFalse(summary.windows[0].isRateLimited)

        // The ISO timestamp keeps its fractional seconds.
        let reset = try XCTUnwrap(summary.windows[0].resetsAt)
        XCTAssertEqual(reset.timeIntervalSince1970, 1786638458.287, accuracy: 0.01)
    }

    /// A window the server has already cut off reports `rate-limited` and 100%.
    func testRateLimitedWindow() throws {
        let summary = try summarize("""
        {"usage": {"rolling": {"status": "rate-limited", "percent": 100, "resetsAt": "2026-08-13T16:27:38.287Z"}}}
        """)
        XCTAssertEqual(summary.windows.count, 1)
        XCTAssertTrue(summary.windows[0].isRateLimited)
        XCTAssertEqual(summary.windows[0].pctUsed, 100, accuracy: 0.001)
    }

    /// Some readers have seen the windows at the top level instead of under
    /// `usage`; both shapes decode.
    func testAcceptsBareWindowsWithoutUsageWrapper() throws {
        let summary = try summarize("""
        {"rolling": {"status": "ok", "percent": 12, "resetsAt": "2026-08-13T16:27:38.287Z"}}
        """)
        XCTAssertEqual(summary.windows.map(\.kind), [.rolling])
        XCTAssertEqual(summary.windows[0].pctUsed, 12, accuracy: 0.001)
    }

    /// An unrecognized `status` is read as "ok" rather than failing the report.
    func testUnknownStatusIsTreatedAsOK() throws {
        let summary = try summarize("""
        {"usage": {"rolling": {"status": "something-new", "percent": 7, "resetsAt": "2026-08-13T16:27:38.287Z"}}}
        """)
        XCTAssertEqual(summary.windows.count, 1)
        XCTAssertFalse(summary.windows[0].isRateLimited)
    }

    /// A missing `percent` drops just that window -- the others still render.
    func testWindowWithoutPercentIsSkipped() throws {
        let summary = try summarize("""
        {"usage": {
          "rolling": {"status": "ok", "resetsAt": "2026-08-13T16:27:38.287Z"},
          "weekly":  {"status": "ok", "percent": 30, "resetsAt": "2026-08-17T00:00:00.287Z"}
        }}
        """)
        XCTAssertEqual(summary.windows.map(\.kind), [.weekly])
    }

    /// A percent outside 0-100 is clamped, so the bar's geometry stays sane.
    func testOutOfRangePercentIsClamped() throws {
        let summary = try summarize("""
        {"usage": {"monthly": {"status": "ok", "percent": 140, "resetsAt": "2026-09-13T06:06:01.287Z"}}}
        """)
        XCTAssertEqual(summary.windows[0].pctUsed, 100, accuracy: 0.001)
    }

    /// No usable window at all is an error, not an empty report.
    func testEmptyUsageIsAnError() {
        XCTAssertThrowsError(try summarize(#"{"usage": {}}"#))
    }

    /// A reset countdown is accepted in place of the ISO timestamp.
    func testAcceptsResetsInSeconds() throws {
        let now = Date()
        let response = try JSONDecoder().decode(
            OpenCodeGoUsageResponse.self,
            from: Data(#"{"usage": {"rolling": {"status": "ok", "percent": 1, "resetsInSeconds": 600}}}"#.utf8)
        )
        let summary = try OpenCodeGoUsageParsing.summarize(response, now: now)
        let reset = try XCTUnwrap(summary.windows[0].resetsAt)
        XCTAssertEqual(reset.timeIntervalSince(now), 600, accuracy: 1)
    }

    /// A malformed `resetsAt` leaves the window's percent intact.
    func testMalformedResetTimeIsDropped() throws {
        let summary = try summarize("""
        {"usage": {"rolling": {"status": "ok", "percent": 9, "resetsAt": "not-a-date"}}}
        """)
        XCTAssertEqual(summary.windows[0].pctUsed, 9, accuracy: 0.001)
        XCTAssertNil(summary.windows[0].resetsAt)
    }
}
