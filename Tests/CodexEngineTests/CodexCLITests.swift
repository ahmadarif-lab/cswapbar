import XCTest
@testable import CodexEngine

final class CodexCLITests: XCTestCase {
    /// The warm-up must never leave a session behind or let the model touch
    /// the machine -- it exists only to start the usage window.
    func testWarmupIsEphemeralAndReadOnly() {
        let args = CodexCLI.warmupArguments
        XCTAssertEqual(args.first, "exec")
        XCTAssertTrue(args.contains("--ephemeral"))
        XCTAssertTrue(args.contains("--skip-git-repo-check"))
        let sandbox = args.firstIndex(of: "-s").map { args[$0 + 1] }
        XCTAssertEqual(sandbox, "read-only")
    }

    /// A Finder-launched app has a bare PATH; the Homebrew dir has to be on it.
    func testEnvironmentAddsHomebrewToPath() throws {
        let path = try XCTUnwrap(CodexCLI.environment()["PATH"])
        XCTAssertTrue(path.split(separator: ":").contains("/opt/homebrew/bin"))
    }
}
