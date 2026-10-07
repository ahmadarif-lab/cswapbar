import XCTest
@testable import KiroEngine

final class KiroUsageParsingTests: XCTestCase {
    private func summarize(_ text: String) throws -> KiroUsageSummary {
        try KiroUsageParsing.summarize(text)
    }

    /// The real production report, verbatim.
    func testParsesRealReport() throws {
        let summary = try summarize("""
        Estimated Usage | resets on 2026-11-01 | KIRO PRO
        Credits (160.89 of 1000 covered in plan), 16.1%
        Your plan is managed by your organization's administrator.
        """)

        XCTAssertEqual(summary.planName, "KIRO PRO")
        XCTAssertEqual(summary.unit, "Credits")
        XCTAssertEqual(summary.pctUsed, 16.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.used), 160.89, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.limit), 1000, accuracy: 0.001)

        let reset = try XCTUnwrap(summary.resetsAt)
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: reset)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 11)
        XCTAssertEqual(components.day, 1)
    }

    /// A report that names its pool something else still reads: only the
    /// percentage is mandatory.
    func testParsesAlternateUnit() throws {
        let summary = try summarize("""
        Estimated Usage | resets on 2026-12-01 | KIRO FREE
        Requests (4 of 50 covered in plan), 8%
        """)

        XCTAssertEqual(summary.unit, "Requests")
        XCTAssertEqual(try XCTUnwrap(summary.used), 4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.limit), 50, accuracy: 0.001)
        XCTAssertEqual(summary.pctUsed, 8, accuracy: 0.001)
        XCTAssertEqual(summary.planName, "KIRO FREE")
    }

    /// Thousands separators are the report's own, not the locale's.
    func testParsesThousandsSeparators() throws {
        let summary = try summarize("""
        Estimated Usage | resets on 2026-11-01 | KIRO PRO
        Credits (1,234.5 of 10,000 covered in plan), 12.3%
        """)

        XCTAssertEqual(try XCTUnwrap(summary.used), 1234.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.limit), 10000, accuracy: 0.001)
        XCTAssertEqual(summary.pctUsed, 12.3, accuracy: 0.001)
    }

    /// A reworded amounts line still yields its percentage, which is the one
    /// value a bar can't be drawn without -- the amounts just go missing.
    func testPercentSurvivesARewordedAmountsLine() throws {
        let summary = try summarize("""
        Estimated Usage | resets on 2026-11-01 | KIRO PRO
        Usage is at 42.5% for this cycle.
        """)

        XCTAssertEqual(summary.pctUsed, 42.5, accuracy: 0.001)
        XCTAssertNil(summary.used)
        XCTAssertNil(summary.limit)
        XCTAssertNil(summary.unit)
    }

    /// No percentage anywhere is an error, not a report of 0% -- a bar drawn
    /// from a guess would be worse than saying nothing.
    func testMissingPercentIsAnError() {
        XCTAssertThrowsError(try summarize("""
        Estimated Usage | resets on 2026-11-01 | KIRO PRO
        Your plan is managed by your organization's administrator.
        """))
    }

    func testEmptyReportIsAnError() {
        XCTAssertThrowsError(try KiroUsageParsing.summarize(""))
    }

    /// A percent outside 0-100 would break the bar's geometry.
    func testOutOfRangePercentIsClamped() throws {
        let summary = try summarize("""
        Estimated Usage | resets on 2026-11-01 | KIRO PRO
        Credits (1500 of 1000 covered in plan), 150%
        """)
        XCTAssertEqual(summary.pctUsed, 100, accuracy: 0.001)
    }

    /// A header without a plan name, and an unparseable reset date, each drop
    /// on their own rather than failing the report.
    func testHeaderPiecesAreOptional() throws {
        let summary = try summarize("""
        Estimated Usage | resets on someday
        Credits (10 of 100 covered in plan), 10%
        """)
        XCTAssertNil(summary.planName)
        XCTAssertNil(summary.resetsAt)
        XCTAssertEqual(summary.pctUsed, 10, accuracy: 0.001)
    }

    /// No header at all: the amounts line alone is enough.
    func testAmountsLineAloneIsEnough() throws {
        let summary = try summarize("Credits (10 of 100 covered in plan), 10%")
        XCTAssertEqual(summary.pctUsed, 10, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.limit), 100, accuracy: 0.001)
        XCTAssertNil(summary.planName)
    }
}
