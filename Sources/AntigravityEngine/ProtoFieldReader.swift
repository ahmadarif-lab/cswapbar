import Foundation

/// A minimal hand-rolled protobuf wire-format walker -- not SwiftProtobuf,
/// which would be overkill for reading a single string field out of one
/// vendor-internal message. Handles just enough of the wire format (varint,
/// 64-bit, length-delimited, 32-bit) to skip fields it doesn't care about
/// and descend into the ones it does.
enum ProtoFieldReader {
    struct Field {
        let number: Int
        let wireType: Int
        /// For wire type 2 (length-delimited), the payload bytes; for the
        /// others, the raw encoded bytes of the value.
        let range: Range<Int>
    }

    /// Reads a base-128 varint starting at `index`; returns the decoded
    /// value and the index just past it, or nil if the buffer ends first.
    static func readVarint(_ bytes: [UInt8], _ index: Int) -> (value: UInt64, next: Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = index
        while i < bytes.count {
            let byte = bytes[i]
            result |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 { return (result, i) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// Every top-level field in `bytes[range]`. Stops (returning whatever it
    /// found so far) at the first malformed or truncated field rather than
    /// throwing -- callers treat "field not found" as the normal failure mode.
    static func fields(in bytes: [UInt8], range: Range<Int>) -> [Field] {
        var result: [Field] = []
        var i = range.lowerBound
        while i < range.upperBound {
            guard let (tag, afterTag) = readVarint(bytes, i) else { return result }
            let number = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            i = afterTag
            switch wireType {
            case 0: // varint
                guard let (_, afterValue) = readVarint(bytes, i) else { return result }
                result.append(Field(number: number, wireType: wireType, range: i..<afterValue))
                i = afterValue
            case 1: // 64-bit (fixed64/double)
                guard i + 8 <= range.upperBound else { return result }
                result.append(Field(number: number, wireType: wireType, range: i..<(i + 8)))
                i += 8
            case 2: // length-delimited (string/bytes/submessage)
                guard let (length, afterLength) = readVarint(bytes, i) else { return result }
                let end = afterLength + Int(length)
                guard length <= UInt64(Int.max), end <= range.upperBound else { return result }
                result.append(Field(number: number, wireType: wireType, range: afterLength..<end))
                i = end
            case 5: // 32-bit (fixed32/float)
                guard i + 4 <= range.upperBound else { return result }
                result.append(Field(number: number, wireType: wireType, range: i..<(i + 4)))
                i += 4
            default: // wire types 3/4 (deprecated groups) aren't produced by proto3
                return result
            }
        }
        return result
    }

    /// Walks a path of field numbers through nested length-delimited
    /// submessages (e.g. `[6, 3]` = field 3 inside field 6) and decodes the
    /// final field as a UTF-8 string. When a field number repeats at a
    /// level, the last occurrence wins, matching protobuf's own merge rule
    /// for singular fields. Returns nil on any missing/malformed step.
    static func extractNestedString(_ data: Data, path: [Int]) -> String? {
        guard !path.isEmpty else { return nil }
        let bytes = [UInt8](data)
        var range = 0..<bytes.count
        for (index, fieldNumber) in path.enumerated() {
            guard let match = fields(in: bytes, range: range).last(where: { $0.number == fieldNumber }) else {
                return nil
            }
            if index == path.count - 1 {
                return String(bytes: bytes[match.range], encoding: .utf8)
            }
            guard match.wireType == 2 else { return nil }
            range = match.range
        }
        return nil
    }
}
