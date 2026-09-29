import XCTest
@testable import AntigravityEngine

final class AntigravityWarmupModelsTests: XCTestCase {
    func testPicksLowFlashAndFirstClaudeFromRealListing() {
        let listing = """
        Fetching available models...
        gemini-3.8-flash-high\tGemini 3.8 Flash (High)
        gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)
        gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
        gemini-3.1-pro-high\tGemini 3.1 Pro (High)
        claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)
        claude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)
        gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
        """
        XCTAssertEqual(AntigravityEngine.warmupModels(fromListing: listing), ["gemini-3.8-flash-low", "claude-sonnet-4-6"])
    }

    func testFallsBackToGptWhenNoClaude() {
        let listing = "gemini-3.1-pro-low\tGemini 3.1 Pro (Low)\ngpt-oss-120b-medium\tGPT-OSS 120B"
        XCTAssertEqual(AntigravityEngine.warmupModels(fromListing: listing), ["gemini-3.1-pro-low", "gpt-oss-120b-medium"])
    }

    func testEmptyListing() {
        XCTAssertEqual(AntigravityEngine.warmupModels(fromListing: "Fetching available models...\n"), [])
    }
}
