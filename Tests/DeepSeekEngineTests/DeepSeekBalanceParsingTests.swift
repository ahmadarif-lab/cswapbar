import XCTest
@testable import DeepSeekEngine

final class DeepSeekBalanceParsingTests: XCTestCase {
    private func decode(_ json: String) throws -> DeepSeekBalanceSummary {
        let response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: Data(json.utf8))
        return try DeepSeekBalanceParsing.summarize(response)
    }

    /// Shaped like DeepSeek's documented `/user/balance` response.
    func testParsesSingleCurrency() throws {
        let summary = try decode("""
        {"is_available": true, "balance_infos": [
          {"currency": "USD", "total_balance": "50.00", "granted_balance": "10.00", "topped_up_balance": "40.00"}
        ]}
        """)
        XCTAssertTrue(summary.isAvailable)
        XCTAssertEqual(summary.currency, "USD")
        XCTAssertEqual(summary.total, 50)
        XCTAssertEqual(summary.granted, 10)
        XCTAssertEqual(summary.toppedUp, 40)
        XCTAssertEqual(summary.format(summary.total), "$50.00")
    }

    func testPrefersUSDOverOtherCurrencies() throws {
        let summary = try decode("""
        {"is_available": true, "balance_infos": [
          {"currency": "CNY", "total_balance": "110.00", "granted_balance": "0.00", "topped_up_balance": "110.00"},
          {"currency": "USD", "total_balance": "3.21", "granted_balance": "0.00", "topped_up_balance": "3.21"}
        ]}
        """)
        XCTAssertEqual(summary.currency, "USD")
        XCTAssertEqual(summary.total, 3.21, accuracy: 0.0001)
    }

    func testUsesYuanSymbolForCNY() throws {
        let summary = try decode("""
        {"is_available": false, "balance_infos": [
          {"currency": "CNY", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00"}
        ]}
        """)
        XCTAssertFalse(summary.isAvailable)
        XCTAssertEqual(summary.format(12.5), "¥12.50")
    }

    func testEmptyBalanceListIsAnError() {
        XCTAssertThrowsError(try decode(#"{"is_available": false, "balance_infos": []}"#))
    }
}
