import XCTest
@testable import AntigravityEngine

final class AntigravityQuotaParsingTests: XCTestCase {
    private func bucket(id: String, fiveHourLeft: Double, weeklyLeft: Double) -> [String: Any] {
        [
            "bucketId": id,
            "five_hour_usage_left_rate": fiveHourLeft,
            "five_hour_usage_reset_time": "2026-10-01T14:39:00Z",
            "weekly_usage_left_rate": weeklyLeft,
            "weekly_usage_reset_time": "2026-10-04T18:59:00Z",
        ]
    }

    func testFindsBucketsRegardlessOfEnvelopeNesting() {
        // Nested: groups -> buckets.
        let nested: [String: Any] = [
            "groups": [
                ["groupId": "g1", "buckets": [bucket(id: "antigravity-quota-summary-gemini-weekly", fiveHourLeft: 1.0, weeklyLeft: 0.92)]],
            ],
        ]
        XCTAssertEqual(AntigravityQuotaParsing.findBuckets(nested).count, 1)

        // Flat: buckets directly at the top level.
        let flat: [String: Any] = ["buckets": [bucket(id: "antigravity-quota-summary-3p-weekly", fiveHourLeft: 1.0, weeklyLeft: 0.3)]]
        XCTAssertEqual(AntigravityQuotaParsing.findBuckets(flat).count, 1)
    }

    func testSummarizeMapsGeminiAndThirdPartyBucketsToNamedPools() {
        let json: [String: Any] = [
            "groups": [
                [
                    "buckets": [
                        bucket(id: "antigravity-quota-summary-gemini-weekly", fiveHourLeft: 1.0, weeklyLeft: 0.92),
                        bucket(id: "antigravity-quota-summary-3p-weekly", fiveHourLeft: 1.0, weeklyLeft: 0.30),
                    ],
                ],
            ],
        ]

        let summary = AntigravityQuotaParsing.summarize(json)
        XCTAssertEqual(summary.pools.count, 4)

        let gemini = summary.pools.filter { $0.poolName == "Gemini" }
        let thirdParty = summary.pools.filter { $0.poolName == "Claude/GPT" }
        XCTAssertEqual(gemini.count, 2)
        XCTAssertEqual(thirdParty.count, 2)

        let geminiWeekly = try! XCTUnwrap(gemini.first { $0.windowLabel == "Weekly" })
        XCTAssertEqual(geminiWeekly.pctUsed!, 8, accuracy: 0.001) // 100 - 92% left
        XCTAssertNotNil(geminiWeekly.resetsAt)

        let thirdPartyWeekly = try! XCTUnwrap(thirdParty.first { $0.windowLabel == "Weekly" })
        XCTAssertEqual(thirdPartyWeekly.pctUsed!, 70, accuracy: 0.001) // 100 - 30% left
    }

    func testUnrecognizedBucketKindIsSkippedRatherThanGuessed() {
        let json: [String: Any] = ["buckets": [bucket(id: "antigravity-quota-summary-mystery-weekly", fiveHourLeft: 1.0, weeklyLeft: 0.5)]]
        XCTAssertTrue(AntigravityQuotaParsing.summarize(json).pools.isEmpty)
    }

    func testMissingRateFieldsProduceNoPoolsWithoutCrashing() {
        let json: [String: Any] = ["buckets": [["bucketId": "antigravity-quota-summary-gemini-weekly"]]]
        XCTAssertTrue(AntigravityQuotaParsing.summarize(json).pools.isEmpty)
    }

    // MARK: - Local hub shape (confirmed against a real running `agy --hub`)

    /// Structurally identical to a real `RetrieveUserQuotaSummary` response
    /// captured from a live hub, with only the numbers/timestamps changed.
    func testSummarizesRealHubResponseShape() throws {
        let json = try JSONSerialization.jsonObject(with: Data("""
        {
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {"bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "remainingFraction": 0.6774553, "resetTime": "2026-10-03T11:37:33Z"},
                  {"bucketId": "gemini-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "remainingFraction": 1, "resetTime": "2026-09-29T12:33:17Z"}
                ]
              },
              {
                "displayName": "Claude and GPT models",
                "buckets": [
                  {"bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "remainingFraction": 0.6636327, "resetTime": "2026-10-03T15:14:52Z"},
                  {"bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "remainingFraction": 1, "resetTime": "2026-09-29T12:33:17Z"}
                ]
              }
            ]
          }
        }
        """.utf8))

        let summary = AntigravityQuotaParsing.summarize(json)
        XCTAssertEqual(summary.pools.count, 4)

        let geminiWeekly = try XCTUnwrap(summary.pools.first { $0.poolName == "Gemini" && $0.windowLabel == "Weekly" })
        XCTAssertEqual(geminiWeekly.pctUsed!, 32.25447, accuracy: 0.001) // 100 - 67.74553% remaining
        XCTAssertNotNil(geminiWeekly.resetsAt)

        let geminiFiveHour = try XCTUnwrap(summary.pools.first { $0.poolName == "Gemini" && $0.windowLabel == "Session (5h)" })
        XCTAssertEqual(geminiFiveHour.pctUsed!, 0, accuracy: 0.001) // fully available

        let thirdPartyWeekly = try XCTUnwrap(summary.pools.first { $0.poolName == "Claude/GPT" && $0.windowLabel == "Weekly" })
        XCTAssertEqual(thirdPartyWeekly.pctUsed!, 33.63673, accuracy: 0.001)
    }
}
