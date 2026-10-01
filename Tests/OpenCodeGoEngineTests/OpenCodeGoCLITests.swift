import XCTest
@testable import OpenCodeGoEngine

final class OpenCodeGoCLITests: XCTestCase {
    /// `opencode models` output: one `<provider>/<model>` per line, with
    /// other providers mixed in.
    private let listing = """
    anthropic/claude-sonnet-4-6
    opencode-go/deepseek-v4-pro
    opencode-go/deepseek-v4.1-flash
    opencode-go/glm-5.3
    opencode-go/grok-4.7
    opencode-go/kimi-k3
    opencode-go/longcat-2.5-preview-free
    opencode-go/space-bunny-free
    openai/gpt-5.4
    """

    func testPicksTheCheapestFlashModel() throws {
        XCTAssertEqual(OpenCodeGoCLI.warmupModel(fromListing: listing), "deepseek-v4.1-flash")
    }

    func testPrefersDeepSeekV4FlashWhenPresent() throws {
        let withFlash = listing.replacingOccurrences(
            of: "opencode-go/deepseek-v4-pro",
            with: "opencode-go/deepseek-v4-flash"
        )
        XCTAssertEqual(OpenCodeGoCLI.warmupModel(fromListing: withFlash), "deepseek-v4-flash")
    }

    /// Free models are unlimited and don't draw on the plan's windows, so a
    /// warm-up on one wouldn't start anything.
    func testSkipsFreeModels() throws {
        let freeOnly = """
        opencode-go/space-bunny-free
        opencode-go/longcat-2.5-preview-free
        """
        XCTAssertNil(OpenCodeGoCLI.warmupModel(fromListing: freeOnly))
    }

    func testSkipsVisionModels() throws {
        let visionFirst = """
        opencode-go/deepseek-v4-flash-vision-exp
        opencode-go/glm-5.3-flash
        """
        XCTAssertEqual(OpenCodeGoCLI.warmupModel(fromListing: visionFirst), "glm-5.3-flash")
    }

    /// With no flash model at all, any paid one beats nothing.
    func testFallsBackToAnyPaidModel() throws {
        let noFlash = """
        opencode-go/kimi-k3
        opencode-go/space-bunny-free
        """
        XCTAssertEqual(OpenCodeGoCLI.warmupModel(fromListing: noFlash), "kimi-k3")
    }

    func testIgnoresOtherProviders() throws {
        let otherOnly = """
        anthropic/claude-sonnet-4-6
        openai/gpt-5.4
        """
        XCTAssertNil(OpenCodeGoCLI.warmupModel(fromListing: otherOnly))
    }

    func testEmptyListingHasNoModel() throws {
        XCTAssertNil(OpenCodeGoCLI.warmupModel(fromListing: ""))
    }
}
