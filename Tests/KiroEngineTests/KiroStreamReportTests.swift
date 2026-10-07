import XCTest
@testable import KiroEngine

final class KiroStreamReportTests: XCTestCase {
    /// The real `--output-format stream-json` stdout of a `/usage` run,
    /// trimmed to the events that matter: `metadata` carries the session id,
    /// `runFinished` the whole report as `finalText`.
    func testReadsFinalTextAndSessionID() {
        let report = KiroStreamReport(stdout: """
        {"type":"runStarted","data":{"payloadSchema":"acp","acpProtocolVersion":1,"engine":"v2"}}
        {"type":"metadata","data":{"sessionId":"7f29425d-57ce-4da5-817b-39bb8001935e","contextUsagePercentage":3.58}}
        {"type":"sessionUpdate","data":{"sessionId":"7f29425d-57ce-4da5-817b-39bb8001935e","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Estimated Usage | resets on 2026-11-01 | KIRO PRO\\n"}}}}
        {"type":"runFinished","data":{"sessionId":"7f29425d-57ce-4da5-817b-39bb8001935e","status":"success","stopReason":"end_turn","finalText":"Estimated Usage | resets on 2026-11-01 | KIRO PRO\\nCredits (160.89 of 1000 covered in plan), 16.1%\\n","finalTextTruncated":false}}
        """)

        XCTAssertEqual(report.sessionID, "7f29425d-57ce-4da5-817b-39bb8001935e")
        XCTAssertEqual(report.text, "Estimated Usage | resets on 2026-11-01 | KIRO PRO\nCredits (160.89 of 1000 covered in plan), 16.1%\n")
    }

    /// Without a `runFinished` the streamed chunks are stitched back together.
    func testFallsBackToStreamedChunks() {
        let report = KiroStreamReport(stdout: """
        {"type":"metadata","data":{"sessionId":"abc"}}
        {"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"60 of 100"}}}}
        {"type":"sessionUpdate","data":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":" covered, 60%"}}}}
        """)

        XCTAssertEqual(report.sessionID, "abc")
        XCTAssertEqual(report.text, "60 of 100 covered, 60%")
    }

    /// Non-JSON output (a Kiro version that ignores the flag, a CLI error on
    /// stderr's twin on stdout) leaves nothing to read rather than throwing.
    func testNonJSONOutputReadsAsNothing() {
        let report = KiroStreamReport(stdout: "error: not a terminal\n")
        XCTAssertNil(report.text)
        XCTAssertNil(report.sessionID)
    }

    /// One malformed line doesn't discard the good ones around it.
    func testMalformedLineIsSkipped() {
        let report = KiroStreamReport(stdout: """
        {"type":"metadata","data":{"sessionId":"abc"}}
        not json at all
        {"type":"runFinished","data":{"finalText":"hello"}}
        """)

        XCTAssertEqual(report.sessionID, "abc")
        XCTAssertEqual(report.text, "hello")
    }

    /// Any event carrying a session id can supply it -- not just `metadata`.
    func testSessionIDFromAnyEvent() {
        let report = KiroStreamReport(stdout: """
        {"type":"runFinished","data":{"sessionId":"from-finish","finalText":"x"}}
        """)
        XCTAssertEqual(report.sessionID, "from-finish")
    }
}
