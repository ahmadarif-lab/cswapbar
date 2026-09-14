import Foundation

/// Order-preserving JSON that serializes byte-for-byte like Python's
/// `json.dumps` (ensure_ascii, `", "` / `": "` separators, `indent=2`), so a
/// file written here is indistinguishable from one cswap wrote.
enum JSONValue: Equatable {
    case object(JSONObject)
    case array([JSONValue])
    case string(String)
    case number(JSONNumber)
    case bool(Bool)
    case null

    static func int(_ value: Int) -> JSONValue { .number(JSONNumber(value)) }
    static func int64(_ value: Int64) -> JSONValue { .number(JSONNumber(value)) }
    static func double(_ value: Double) -> JSONValue { .number(JSONNumber(value)) }

    var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: JSONNumber? {
        if case .number(let n) = self { return n }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Python truthiness of the decoded value.
    var isTruthy: Bool {
        switch self {
        case .object(let o): return !o.isEmpty
        case .array(let a): return !a.isEmpty
        case .string(let s): return !s.isEmpty
        case .number(let n): return n.doubleValue != 0
        case .bool(let b): return b
        case .null: return false
        }
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

struct JSONObject: Equatable {
    struct Entry: Equatable {
        var key: String
        var value: JSONValue
    }

    private(set) var entries: [Entry] = []

    init() {}

    init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }
    var keys: [String] { entries.map(\.key) }

    func has(_ key: String) -> Bool { entries.contains { $0.key == key } }

    /// Assigning an existing key keeps its position and a new key appends,
    /// like a Python dict; assigning nil removes it.
    subscript(key: String) -> JSONValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let idx = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[idx].value = newValue } else { entries.remove(at: idx) }
            } else if let newValue {
                entries.append(Entry(key: key, value: newValue))
            }
        }
    }

    @discardableResult
    mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let idx = entries.firstIndex(where: { $0.key == key }) else { return nil }
        return entries.remove(at: idx).value
    }
}

/// A JSON number as Python holds it after `json.loads`: an integer literal
/// stays exact (arbitrary size), anything else becomes a float and renders
/// like `repr(float)` — so a load/dump round trip matches cswap's output.
struct JSONNumber: Equatable {
    let literal: String

    init(literal: String) {
        let isInt = !literal.contains(".") && !literal.contains("e") && !literal.contains("E")
            && !["NaN", "Infinity", "-Infinity"].contains(literal)
        if isInt {
            self.literal = literal == "-0" ? "0" : literal
        } else if let d = Double(literal) {
            self.literal = Self.pythonRepr(d)
        } else {
            self.literal = literal
        }
    }

    init(_ value: Int) { literal = String(value) }
    init(_ value: Int64) { literal = String(value) }
    init(_ value: Double) { literal = Self.pythonRepr(value) }

    /// `repr(float)`: shortest round-trip digits, fixed notation while the
    /// decimal exponent is in (-4, 16], always with a fractional part.
    static func pythonRepr(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        var text = "\(value)"
        var sign = ""
        if text.hasPrefix("-") { sign = "-"; text.removeFirst() }
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let fracPart = parts.count > 1 ? String(parts[1]) : ""
        var digits = Array(intPart + fracPart)
        var decpt = intPart.count + exponent
        while let first = digits.first, first == "0" { digits.removeFirst(); decpt -= 1 }
        while let last = digits.last, last == "0" { digits.removeLast() }
        if digits.isEmpty { return sign + "0.0" }
        let d = String(digits)
        if decpt > -4 && decpt <= 16 {
            if decpt <= 0 { return sign + "0." + String(repeating: "0", count: -decpt) + d }
            if decpt >= d.count { return sign + d + String(repeating: "0", count: decpt - d.count) + ".0" }
            let idx = d.index(d.startIndex, offsetBy: decpt)
            return sign + d[..<idx] + "." + d[idx...]
        }
        let mantissa = digits.count > 1 ? "\(digits[0]).\(String(digits.dropFirst()))" : String(digits[0])
        let e = decpt - 1
        return sign + mantissa + "e" + (e < 0 ? "-" : "+") + String(format: "%02d", abs(e))
    }

    /// Python's `json.loads` makes an int only from a literal with no
    /// fraction or exponent.
    var isInteger: Bool {
        !literal.contains(".") && !literal.contains("e") && !literal.contains("E")
            && literal != "NaN" && literal != "Infinity" && literal != "-Infinity"
    }

    var doubleValue: Double {
        switch literal {
        case "NaN": return .nan
        case "Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: return Double(literal) ?? 0
        }
    }

    /// Python `int(x)`: truncates a float toward zero.
    var truncatedInt64: Int64? {
        if isInteger { return Int64(literal) ?? Int64(exactly: doubleValue.rounded(.towardZero)) }
        let d = doubleValue
        guard d.isFinite, let i = Int64(exactly: d.rounded(.towardZero)) else { return nil }
        return i
    }
}

enum JSONError: Error, CustomStringConvertible {
    case syntax(String, offset: Int)

    var description: String {
        switch self {
        case .syntax(let msg, let offset): return "\(msg) at byte \(offset)"
        }
    }
}

// MARK: - Parsing

extension JSONValue {
    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var pos = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        // UTF-8 BOM, which Python's json.loads rejects on str input but is
        // harmless to skip here.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { pos = 3 }
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard pos == bytes.count else { throw JSONError.syntax("Extra data", offset: pos) }
        return value
    }

    mutating func skipWhitespace() {
        while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) { pos += 1 }
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < 1000 else { throw JSONError.syntax("Nesting too deep", offset: pos) }
        guard pos < bytes.count else { throw JSONError.syntax("Expecting value", offset: pos) }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "N"): try expectLiteral("NaN"); return .number(JSONNumber(literal: "NaN"))
        case UInt8(ascii: "I"): try expectLiteral("Infinity"); return .number(JSONNumber(literal: "Infinity"))
        default: return .number(try parseNumber())
        }
    }

    mutating func expectLiteral(_ literal: String) throws {
        let lit = Array(literal.utf8)
        guard pos + lit.count <= bytes.count, Array(bytes[pos..<pos + lit.count]) == lit else {
            throw JSONError.syntax("Expecting value", offset: pos)
        }
        pos += lit.count
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        pos += 1
        var obj = JSONObject()
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(obj) }
        while true {
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else {
                throw JSONError.syntax("Expecting property name enclosed in double quotes", offset: pos)
            }
            let key = try parseString()
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else {
                throw JSONError.syntax("Expecting ':' delimiter", offset: pos)
            }
            pos += 1
            skipWhitespace()
            obj[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard pos < bytes.count else { throw JSONError.syntax("Expecting ',' delimiter", offset: pos) }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(obj) }
            throw JSONError.syntax("Expecting ',' delimiter", offset: pos)
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        pos += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard pos < bytes.count else { throw JSONError.syntax("Expecting ',' delimiter", offset: pos) }
            if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
            throw JSONError.syntax("Expecting ',' delimiter", offset: pos)
        }
    }

    mutating func parseNumber() throws -> JSONNumber {
        let start = pos
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "-") {
            pos += 1
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "I") {
                try expectLiteral("Infinity")
                return JSONNumber(literal: "-Infinity")
            }
        }
        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        guard pos < bytes.count, isDigit(bytes[pos]) else { throw JSONError.syntax("Expecting value", offset: start) }
        if bytes[pos] == UInt8(ascii: "0") {
            pos += 1
        } else {
            while pos < bytes.count, isDigit(bytes[pos]) { pos += 1 }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "."), pos + 1 < bytes.count, isDigit(bytes[pos + 1]) {
            pos += 1
            while pos < bytes.count, isDigit(bytes[pos]) { pos += 1 }
        }
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
            var look = pos + 1
            if look < bytes.count, bytes[look] == UInt8(ascii: "+") || bytes[look] == UInt8(ascii: "-") { look += 1 }
            if look < bytes.count, isDigit(bytes[look]) {
                pos = look
                while pos < bytes.count, isDigit(bytes[pos]) { pos += 1 }
            }
        }
        return JSONNumber(literal: String(decoding: bytes[start..<pos], as: UTF8.self))
    }

    mutating func parseHex4() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw JSONError.syntax("Invalid \\uXXXX escape", offset: pos) }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let b = bytes[pos]
            let digit: UInt32
            switch b {
            case 0x30...0x39: digit = UInt32(b - 0x30)
            case 0x41...0x46: digit = UInt32(b - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(b - 0x61 + 10)
            default: throw JSONError.syntax("Invalid \\uXXXX escape", offset: pos)
            }
            value = value * 16 + digit
            pos += 1
        }
        return value
    }

    mutating func parseString() throws -> String {
        pos += 1
        var scalars = String.UnicodeScalarView()
        var runStart = pos
        func flushRun(_ end: Int) {
            if end > runStart {
                scalars.append(contentsOf: String(decoding: bytes[runStart..<end], as: UTF8.self).unicodeScalars)
            }
        }
        while true {
            guard pos < bytes.count else { throw JSONError.syntax("Unterminated string", offset: pos) }
            let b = bytes[pos]
            if b == UInt8(ascii: "\"") {
                flushRun(pos)
                pos += 1
                return String(scalars)
            }
            if b < 0x20 { throw JSONError.syntax("Invalid control character", offset: pos) }
            if b != UInt8(ascii: "\\") { pos += 1; continue }
            flushRun(pos)
            pos += 1
            guard pos < bytes.count else { throw JSONError.syntax("Unterminated string", offset: pos) }
            let esc = bytes[pos]
            pos += 1
            switch esc {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                var code = try parseHex4()
                if (0xD800...0xDBFF).contains(code), pos + 6 <= bytes.count,
                   bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                    let save = pos
                    pos += 2
                    let low = try parseHex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        pos = save
                    }
                }
                scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            default:
                throw JSONError.syntax("Invalid \\escape", offset: pos - 1)
            }
            runStart = pos
        }
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Python `json.dumps(value)` when `indent` is nil, `json.dumps(value,
    /// indent=N)` otherwise.
    func serialized(indent: Int? = nil) -> String {
        var out = ""
        write(to: &out, indent: indent, level: 0)
        return out
    }

    private func write(to out: inout String, indent: Int?, level: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n.literal
        case .string(let s): JSONValue.writeString(s, to: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += indent == nil ? ", " : "," }
                if let indent { out += "\n" + String(repeating: " ", count: indent * (level + 1)) }
                item.write(to: &out, indent: indent, level: level + 1)
            }
            if let indent { out += "\n" + String(repeating: " ", count: indent * level) }
            out += "]"
        case .object(let obj):
            if obj.isEmpty { out += "{}"; return }
            out += "{"
            for (i, entry) in obj.entries.enumerated() {
                if i > 0 { out += indent == nil ? ", " : "," }
                if let indent { out += "\n" + String(repeating: " ", count: indent * (level + 1)) }
                JSONValue.writeString(entry.key, to: &out)
                out += ": "
                entry.value.write(to: &out, indent: indent, level: level + 1)
            }
            if let indent { out += "\n" + String(repeating: " ", count: indent * level) }
            out += "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                let v = scalar.value
                if v >= 0x20 && v <= 0x7E {
                    out.unicodeScalars.append(scalar)
                } else if v <= 0xFFFF {
                    out += String(format: "\\u%04x", v)
                } else {
                    let u = v - 0x10000
                    out += String(format: "\\u%04x\\u%04x", 0xD800 + (u >> 10), 0xDC00 + (u & 0x3FF))
                }
            }
        }
        out += "\""
    }
}
