import Foundation
import XCTest
@testable import SwapEngine

final class ParityTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swap-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testEmptyLegacyConfigLosesToGlobal() throws {
        let dir = try tempDir()
        let legacy = dir.appendingPathComponent(".config.json")
        let global = dir.appendingPathComponent(".claude.json")
        FileManager.default.createFile(atPath: legacy.path, contents: Data())
        // Empty + writable, but .claude.json exists: the global file wins.
        FileManager.default.createFile(atPath: global.path, contents: Data("{}".utf8))
        XCTAssertEqual(Paths.pickGlobalConfig(legacy: legacy, global: global), global)
        // Empty + writable with no .claude.json: legacy still wins.
        try FileManager.default.removeItem(at: global)
        XCTAssertEqual(Paths.pickGlobalConfig(legacy: legacy, global: global), legacy)
        // Non-empty always wins.
        try Data("{}".utf8).write(to: legacy)
        FileManager.default.createFile(atPath: global.path, contents: Data("{}".utf8))
        XCTAssertEqual(Paths.pickGlobalConfig(legacy: legacy, global: global), legacy)
        // Missing legacy: global.
        try FileManager.default.removeItem(at: legacy)
        XCTAssertEqual(Paths.pickGlobalConfig(legacy: legacy, global: global), global)
    }

    func testAPIKeyFamilies() {
        XCTAssertTrue(CredentialShape.looksLikeAPIKey("sk-ant-api03-abc"))
        XCTAssertTrue(CredentialShape.looksLikeAPIKey("sk-ant-usr-abc\n"))
        XCTAssertFalse(CredentialShape.looksLikeAPIKey("sk-ant-oat01-abc"))
        XCTAssertFalse(CredentialShape.looksLikeAPIKey("sk-ant-ort01-abc"))
        XCTAssertFalse(CredentialShape.looksLikeAPIKey("{\"claudeAiOauth\":{}}"))
        XCTAssertFalse(CredentialShape.looksLikeAPIKey(nil))
    }

    func testAtomicWriteGoesThroughSymlinkAndIsPrivate() throws {
        let dir = try tempDir()
        let real = dir.appendingPathComponent("real.json")
        let link = dir.appendingPathComponent("link.json")
        try Data("old".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try FS.atomicWrite("new", to: link)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "new")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "link must survive")
        var st = stat()
        XCTAssertEqual(stat(real.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testStaleLockTakeoverRechecksInside() throws {
        let dir = try tempDir()
        let lock = dir.appendingPathComponent("x.lock")
        // Fresh lock: not removed.
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        XCTAssertFalse(ClaudeLocks.removeIfStillStale(lock, staleness: 60))
        XCTAssertTrue(FS.exists(lock))
        // Stale lock: removed, takeover dir cleaned up.
        let old = Date().addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lock.path)
        XCTAssertTrue(ClaudeLocks.removeIfStillStale(lock, staleness: 60))
        XCTAssertFalse(FS.exists(lock))
        XCTAssertFalse(FS.exists(dir.appendingPathComponent("x.lock.takeover")))
        // Another waiter mid-takeover: back off.
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lock.path)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("x.lock.takeover"), withIntermediateDirectories: false)
        XCTAssertFalse(ClaudeLocks.removeIfStillStale(lock, staleness: 60))
        XCTAssertTrue(FS.exists(lock))
    }

    func testLstartParsingAndPidReuse() {
        XCTAssertEqual(Sessions.lstartSeconds("Wed Sep  2 20:35:59 2026"), 1788381359)
        XCTAssertNil(Sessions.lstartSeconds("garbage"))
        // Unknowable stamps never disqualify a live pid.
        XCTAssertTrue(Sessions.pidMatchesRecord(Int(getpid()), procStart: nil))
        XCTAssertTrue(Sessions.pidMatchesRecord(Int(getpid()), procStart: "12345"))
        XCTAssertTrue(Sessions.pidMatchesRecord(Int(getpid()), procStart: "not a date"))
        // A record stamped long before this process started names a stranger
        // (the test runner is not a claude).
        XCTAssertFalse(Sessions.pidMatchesRecord(Int(getpid()), procStart: "Mon Jan  1 00:00:00 2024"))
    }

    func testUnlistableSessionsDirIsUnknownNotEmpty() throws {
        let dir = try tempDir()
        XCTAssertEqual(Sessions.scanLiveSessions(dir).unreadable, 0)
        let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sessions.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessions.path) }
        XCTAssertEqual(Sessions.scanLiveSessions(dir).unreadable, 1)
        XCTAssertFalse(Sessions.profileIsQuiescent(dir))
    }

    func testSymlinkedProfileTriesTargetKeychainService() throws {
        let dir = try tempDir()
        let target = dir.appendingPathComponent("space")
        let link = dir.appendingPathComponent("sessions-1")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let services = Sessions.keychainServices(link.path)
        XCTAssertEqual(services, [Sessions.keychainServiceName(link.path), Sessions.keychainServiceName(target.path)])
        XCTAssertEqual(Sessions.keychainServices(target.path).count, 1)
    }
}
