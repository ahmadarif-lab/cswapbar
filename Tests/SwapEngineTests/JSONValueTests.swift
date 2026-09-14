import XCTest
@testable import SwapEngine

/// Expected strings are real `json.dumps` output (Python 3.12), so files this
/// engine writes stay byte-identical to cswap's.
final class JSONValueTests: XCTestCase {
    /// Python's ensure_ascii spelling of `café 😀 "q" /` plus a newline,
    /// assembled here so the source holds no escape sequences.
    private let escapedValue: String = {
        let bs = String(UnicodeScalar(UInt8(92)))
        return "caf" + bs + "u00e9 " + bs + "ud83d" + bs + "ude00 " + bs + "\"q" + bs + "\" /" + bs + "n"
    }()

    func testCompactAndIndentedMatchPythonDumps() throws {
        let value = try JSONValue.parse(#"{"b": 1, "a": [1, 2.5, true, null], "c": {}, "d": [], "e": "café 😀 \"q\" /\n"}"#)
        XCTAssertEqual(
            value.serialized(),
            #"{"b": 1, "a": [1, 2.5, true, null], "c": {}, "d": [], "e": ""# + escapedValue + #""}"#
        )
        XCTAssertEqual(value.serialized(indent: 2), #"""
        {
          "b": 1,
          "a": [
            1,
            2.5,
            true,
            null
          ],
          "c": {},
          "d": [],
          "e": "
        """# + escapedValue + "\"\n}")
    }

    func testNumbersFollowPythonLoadsThenDumps() throws {
        let value = try JSONValue.parse(#"{"x": {"y": [1, {"z": []}], "w": {}}, "n": -0.0, "big": 12345678901234567890, "exp": 1e5, "f": 1757834567.123456}"#)
        XCTAssertEqual(
            value.serialized(),
            #"{"x": {"y": [1, {"z": []}], "w": {}}, "n": -0.0, "big": 12345678901234567890, "exp": 100000.0, "f": 1757834567.123456}"#
        )
    }

    func testFloatReprMatchesPython() {
        let cases: [(Double, String)] = [
            (34.0, "34.0"), (1757834567.1234567, "1757834567.1234567"), (1e-05, "1e-05"),
            (1e16, "1e+16"), (1e15, "1000000000000000.0"), (0.0001, "0.0001"), (-0.0, "-0.0"),
            (0.1 + 0.2, "0.30000000000000004"), (9999999999999998.0, "9999999999999998.0"),
            (123456789012345680.0, "1.2345678901234568e+17"), (5e-324, "5e-324"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(JSONNumber.pythonRepr(value), expected, "\(value)")
        }
    }

    func testObjectKeepsInsertionOrderLikeADict() throws {
        var obj = try XCTUnwrap(JSONValue.parse(#"{"a": 1, "b": 2}"#).objectValue)
        obj["a"] = .int(3)
        obj["c"] = .int(4)
        obj.removeValue(forKey: "b")
        XCTAssertEqual(JSONValue.object(obj).serialized(), #"{"a": 3, "c": 4}"#)
    }

    func testRejectsTrailingGarbage() {
        XCTAssertThrowsError(try JSONValue.parse(#"{"a": 1} x"#))
        XCTAssertThrowsError(try JSONValue.parse(#"{"a": 1,"#))
    }
}
