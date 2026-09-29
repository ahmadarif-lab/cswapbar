import XCTest
@testable import AntigravityEngine

final class ProtoFieldReaderTests: XCTestCase {
    /// Builds a length-delimited field: tag byte + varint length + payload.
    private func lengthDelimitedField(number: Int, payload: [UInt8]) -> [UInt8] {
        let tag = UInt8((number << 3) | 2)
        return [tag] + varint(UInt64(payload.count)) + payload
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v != 0
        return bytes
    }

    func testExtractsStringAtNestedPath() throws {
        let token = "1//0gABCDEF-sample-refresh-token"
        let field3 = lengthDelimitedField(number: 3, payload: Array(token.utf8))
        let field6 = lengthDelimitedField(number: 6, payload: field3)

        let extracted = ProtoFieldReader.extractNestedString(Data(field6), path: [6, 3])
        XCTAssertEqual(extracted, token)
    }

    func testSkipsUnrelatedFieldsAtEachLevel() throws {
        let token = "refresh-token-value"
        let field3 = lengthDelimitedField(number: 3, payload: Array(token.utf8))
        // Unrelated varint field 1, unrelated length-delimited field 2, then field 6 holding field3.
        let varintField1: [UInt8] = [UInt8((1 << 3) | 0)] + varint(42)
        let junkField2 = lengthDelimitedField(number: 2, payload: [0xDE, 0xAD, 0xBE, 0xEF])
        let field6 = lengthDelimitedField(number: 6, payload: junkField2 + field3)
        let message = varintField1 + field6 + lengthDelimitedField(number: 9, payload: [0x01])

        let extracted = ProtoFieldReader.extractNestedString(Data(message), path: [6, 3])
        XCTAssertEqual(extracted, token)
    }

    func testLastOccurrenceWinsWhenFieldRepeats() throws {
        let first = lengthDelimitedField(number: 3, payload: Array("stale".utf8))
        let second = lengthDelimitedField(number: 3, payload: Array("fresh".utf8))
        let field6 = lengthDelimitedField(number: 6, payload: first + second)

        let extracted = ProtoFieldReader.extractNestedString(Data(field6), path: [6, 3])
        XCTAssertEqual(extracted, "fresh")
    }

    func testReturnsNilWhenPathFieldIsMissing() throws {
        let field3 = lengthDelimitedField(number: 3, payload: Array("value".utf8))
        // Field 3 lives at the top level, not nested inside field 6.
        XCTAssertNil(ProtoFieldReader.extractNestedString(Data(field3), path: [6, 3]))
    }

    func testReturnsNilOnTruncatedInput() throws {
        // A length-delimited tag claiming more bytes than actually follow.
        let truncated: [UInt8] = [UInt8((6 << 3) | 2), 0x10, 0x01, 0x02]
        XCTAssertNil(ProtoFieldReader.extractNestedString(Data(truncated), path: [6, 3]))
    }
}
