import XCTest
@testable import AntigravityEngine

final class AntigravityHubLocatorTests: XCTestCase {
    func testParsesPortAndCsrfTokenFromRealPsLine() {
        let psOutput = """
        /usr/bin/some-other-process --flag=value
        /Users/ahmadarif/.gemini/bin/agy --hub --hub-port=50947 --app_data_dir=antigravity --csrf_token=5b59b728-863a-4454-b5c0-bfe7e3c64670 --add-dir=/Users/ahmadarif/projects/cswapbar
        /bin/zsh -c something
        """
        let endpoint = AntigravityHubLocator.parse(psOutput)
        XCTAssertEqual(endpoint?.port, 50947)
        XCTAssertEqual(endpoint?.csrfToken, "5b59b728-863a-4454-b5c0-bfe7e3c64670")
    }

    func testPicksFirstHubWhenMultipleAreRunning() {
        let psOutput = """
        /Users/x/.gemini/bin/agy --hub --hub-port=61791 --csrf_token=aaaa-1111 --add-dir=/one
        /Users/x/.gemini/bin/agy --hub --hub-port=62798 --csrf_token=bbbb-2222 --add-dir=/two
        """
        let endpoint = AntigravityHubLocator.parse(psOutput)
        XCTAssertEqual(endpoint?.port, 61791)
        XCTAssertEqual(endpoint?.csrfToken, "aaaa-1111")
    }

    func testIgnoresAgyProcessesThatArentHubs() {
        let psOutput = """
        /Users/x/.gemini/bin/agy --print "hello" --model=gemini
        /Users/x/.gemini/bin/agy mcp list
        """
        XCTAssertNil(AntigravityHubLocator.parse(psOutput))
    }

    func testReturnsNilWhenNoHubIsRunning() {
        let psOutput = """
        /usr/sbin/some-daemon
        /Applications/CSwapBar.app/Contents/MacOS/CSwapBar
        """
        XCTAssertNil(AntigravityHubLocator.parse(psOutput))
    }

    func testReturnsNilWhenPortOrTokenIsMissing() {
        let missingToken = "/Users/x/.gemini/bin/agy --hub --hub-port=50947 --add-dir=/x"
        XCTAssertNil(AntigravityHubLocator.parse(missingToken))

        let missingPort = "/Users/x/.gemini/bin/agy --hub --csrf_token=aaaa-1111 --add-dir=/x"
        XCTAssertNil(AntigravityHubLocator.parse(missingPort))
    }
}
