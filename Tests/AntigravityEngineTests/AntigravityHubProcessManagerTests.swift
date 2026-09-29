import XCTest
@testable import AntigravityEngine

final class AntigravityHubProcessManagerTests: XCTestCase {
    func testFindAgyBinaryReturnsExecutablePathWhenInstalled() {
        if let path = AntigravityHubProcessManager.findAgyBinary() {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
            XCTAssertTrue(AntigravityHubProcessManager.isAgyAvailable)
        }
    }

    func testEnsureRunningHubAndFetchQuota() async throws {
        guard AntigravityHubProcessManager.isAgyAvailable else { return }
        let summary = try await AntigravityEngine.shared.currentAccount()
        XCTAssertFalse(summary.pools.isEmpty)
        for pool in summary.pools {
            XCTAssertFalse(pool.poolName.isEmpty)
            XCTAssertFalse(pool.windowLabel.isEmpty)
        }
    }
}
