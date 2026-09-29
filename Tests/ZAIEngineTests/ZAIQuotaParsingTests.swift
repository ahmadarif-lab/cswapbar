import XCTest
@testable import ZAIEngine

final class ZAIQuotaParsingTests: XCTestCase {
    private func nowPlus(_ seconds: TimeInterval) -> Int64 {
        Int64((Date().timeIntervalSince1970 + seconds) * 1000)
    }

    /// Shaped like a real GLM Coding Plan account: a 5-hour token window
    /// plus a separate MCP (tool-call) allowance with a per-tool breakdown.
    private func sampleResponse(fiveHourResetIn seconds: TimeInterval = 55 * 60) -> ZAIQuotaResponse {
        ZAIQuotaResponse(
            success: true, code: 200,
            data: ZAIQuotaData(
                limits: [
                    ZAILimit(
                        type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 1,
                        usage: nil, currentValue: nil, remaining: nil,
                        nextResetTime: nowPlus(seconds), usageDetails: nil
                    ),
                    ZAILimit(
                        type: "TIME_LIMIT", unit: 1, number: 1, percentage: 7,
                        usage: 100, currentValue: nil, remaining: 93,
                        nextResetTime: nowPlus(4 * 86400 + 23 * 3600), usageDetails: [
                            ZAIUsageDetail(modelCode: "search-prime", usage: 7),
                            ZAIUsageDetail(modelCode: "web-reader", usage: 0),
                            ZAIUsageDetail(modelCode: "zread", usage: 0),
                        ]
                    ),
                ],
                planName: "Lite", plan: nil, packageName: nil, level: nil, planType: nil
            )
        )
    }

    func testMatchesRealAccountShape() throws {
        let summary = try ZAIQuotaParsing.summarize(sampleResponse())

        XCTAssertEqual(summary.planName, "Lite")
        XCTAssertEqual(summary.pools.count, 2) // no secondary window on this account -- just 5-hour + MCP

        let primary = try XCTUnwrap(summary.pools.first { $0.kind == .primary })
        XCTAssertEqual(primary.label, "5-hour")
        XCTAssertEqual(primary.pctUsed!, 1, accuracy: 0.001)
        XCTAssertNotNil(primary.resetsAt)

        let mcp = try XCTUnwrap(summary.pools.first { $0.kind == .mcp })
        XCTAssertEqual(mcp.label, "MCP")
        XCTAssertEqual(mcp.pctUsed!, 7, accuracy: 0.001) // (100-93)/100

        XCTAssertTrue(summary.detailRows.contains { $0.label == "Token quota" && $0.value == "1% used" })
        let mcpRow = try XCTUnwrap(summary.detailRows.first { $0.label == "MCP quota" })
        XCTAssertEqual(mcpRow.value, "7% used")
        XCTAssertEqual(mcpRow.secondaryValue, "100 limit · 93 remaining")

        XCTAssertTrue(summary.detailRows.contains { $0.label == "search-prime" && $0.value == "7" })
        XCTAssertTrue(summary.detailRows.contains { $0.label == "web-reader" && $0.value == "0" })
        XCTAssertTrue(summary.detailRows.contains { $0.label == "zread" && $0.value == "0" })
    }

    func testMCPBarOmittedWithoutAnyTokenLimit() throws {
        // Only a TIME_LIMIT entry, no TOKENS_LIMIT/CREDIT_LIMIT at all --
        // zai.js only adds the MCP bar when a token limit also exists.
        let response = ZAIQuotaResponse(
            success: true, code: 200,
            data: ZAIQuotaData(
                limits: [
                    ZAILimit(type: "TIME_LIMIT", unit: 1, number: 1, percentage: 7, usage: 100, currentValue: nil, remaining: 93, nextResetTime: nowPlus(3600), usageDetails: nil),
                ],
                planName: nil, plan: nil, packageName: nil, level: nil, planType: nil
            )
        )
        let summary = try ZAIQuotaParsing.summarize(response)
        // Falls back to the time limit itself as the sole "primary" pool --
        // there's no token limit to pair it with for a separate MCP bar.
        XCTAssertEqual(summary.pools.count, 1)
        XCTAssertEqual(summary.pools[0].kind, .primary)
        XCTAssertEqual(summary.pools[0].label, "MCP")
        // The MCP quota *row* isn't gated on a token limit existing (only
        // the bar is, per zai.js's own `if (tokenLimit && timeLimit)` vs.
        // its unconditional `if (timeLimit)` for the detail row).
        XCTAssertTrue(summary.detailRows.contains { $0.label == "MCP quota" })
    }

    func testSecondaryWindowAppearsWithTwoTokenLimits() throws {
        let response = ZAIQuotaResponse(
            success: true, code: 200,
            data: ZAIQuotaData(
                limits: [
                    ZAILimit(type: "TOKENS_LIMIT", unit: 3, number: 5, percentage: 20, usage: nil, currentValue: nil, remaining: nil, nextResetTime: nowPlus(1800), usageDetails: nil),
                    ZAILimit(type: "TOKENS_LIMIT", unit: 6, number: 1, percentage: 40, usage: nil, currentValue: nil, remaining: nil, nextResetTime: nowPlus(86400), usageDetails: nil),
                ],
                planName: nil, plan: nil, packageName: nil, level: nil, planType: nil
            )
        )
        let summary = try ZAIQuotaParsing.summarize(response)
        XCTAssertEqual(summary.pools.map(\.kind), [.primary, .secondary])
        XCTAssertEqual(summary.pools[0].label, "5-hour")
        XCTAssertEqual(summary.pools[1].label, "1 week window")
        XCTAssertTrue(summary.detailRows.contains { $0.label == "Session token quota" })
    }

    func testCreditLimitTypeUsesCreditWording() throws {
        let response = ZAIQuotaResponse(
            success: true, code: 200,
            data: ZAIQuotaData(
                limits: [
                    ZAILimit(type: "CREDIT_LIMIT", unit: 3, number: 5, percentage: 10, usage: nil, currentValue: nil, remaining: nil, nextResetTime: nil, usageDetails: nil),
                ],
                planName: nil, plan: nil, packageName: nil, level: nil, planType: nil
            )
        )
        let summary = try ZAIQuotaParsing.summarize(response)
        XCTAssertTrue(summary.detailRows.contains { $0.label == "Credit quota" })
    }

    func testUnrecognizedLimitTypeIsSkipped() throws {
        let response = ZAIQuotaResponse(
            success: true, code: 200,
            data: ZAIQuotaData(
                limits: [
                    ZAILimit(type: "SOME_FUTURE_LIMIT", unit: 3, number: 5, percentage: 10, usage: nil, currentValue: nil, remaining: nil, nextResetTime: nil, usageDetails: nil),
                ],
                planName: nil, plan: nil, packageName: nil, level: nil, planType: nil
            )
        )
        let summary = try ZAIQuotaParsing.summarize(response)
        XCTAssertTrue(summary.pools.isEmpty)
        XCTAssertTrue(summary.detailRows.isEmpty)
    }

    func testImplausibleFiveHourResetIsDropped() throws {
        // A "5-hour" window claiming its reset is 10 hours away can't be
        // real -- the reset time should be omitted rather than shown wrong.
        let response = sampleResponse(fiveHourResetIn: 10 * 3600)
        let summary = try ZAIQuotaParsing.summarize(response)
        let primary = try XCTUnwrap(summary.pools.first { $0.kind == .primary })
        XCTAssertNil(primary.resetsAt)
    }

    func testSummarizeThrowsOnUnsuccessfulResponse() {
        let response = ZAIQuotaResponse(success: false, code: 500, data: nil)
        XCTAssertThrowsError(try ZAIQuotaParsing.summarize(response))
    }
}
