import Foundation

/// A parsed JSON document. The validators read this instead of decoding straight into the models, so that
/// they can reject unknown fields, report every problem at once and point at each one.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses `data` as strict JSON (RFC 8259); `nil` when it is not JSON.
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONParser.parse(data)
    }

    /// The JSON type name used in messages.
    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

/// Why a text is not JSON, and where (byte offset).
struct JSONSyntaxError: Error, CustomStringConvertible {
    let reason: String
    let offset: Int

    var description: String { "\(reason) at byte \(offset)" }
}

/// A strict RFC 8259 parser. Foundation's parser also accepts trailing commas, which are not JSON, so
/// the contract does not use it. Leniencies kept on purpose: a leading UTF-8 byte order mark is
/// skipped (as `check-jsonschema` does); a number too large for a Double becomes infinity, which the
/// validators refuse as out of range. Known limitation: when an object repeats a key, or has two keys
/// that are canonically equivalent Unicode, the last value is kept without a report.
struct JSONParser {
    private let bytes: [UInt8]
    private var i = 0
    /// Deeper nesting is refused instead of overflowing the stack. Caption documents nest at most 4
    /// levels; 64 leaves ample room and keeps the recursion far below the 512 KB stack of a secondary
    /// thread (at 512 levels a debug build crashed on one).
    static let maxDepth = 64

    static func parse(_ data: Data) throws -> JSONValue {
        var p = JSONParser(bytes: Array(data))
        if p.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { p.i = 3 }
        p.skipWhitespace()
        let value = try p.value(depth: 0)
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw p.error("unexpected text after the value") }
        return value
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private func error(_ reason: String) -> JSONSyntaxError {
        JSONSyntaxError(reason: reason, offset: i)
    }

    private var current: UInt8? { i < bytes.count ? bytes[i] : nil }

    private mutating func skipWhitespace() {
        while let b = current, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { i += 1 }
    }

    private mutating func expect(_ literal: String) throws {
        for b in literal.utf8 {
            guard current == b else { throw error("expected \"\(literal)\"") }
            i += 1
        }
    }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth < Self.maxDepth else { throw error("nested more than \(Self.maxDepth) levels") }
        switch current {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case let b? where b == UInt8(ascii: "-") || UInt8(ascii: "0")...UInt8(ascii: "9") ~= b: return .number(try number())
        case nil: throw error("unexpected end of text")
        default: throw error("unexpected character")
        }
    }

    private mutating func object(depth: Int) throws -> JSONValue {
        i += 1
        var fields: [String: JSONValue] = [:]
        skipWhitespace()
        if current == UInt8(ascii: "}") { i += 1; return .object(fields) }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else { throw error("expected a string key") }
            let key = try string()
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { throw error("expected \":\"") }
            i += 1
            skipWhitespace()
            fields[key] = try value(depth: depth + 1)
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): i += 1
            case UInt8(ascii: "}"): i += 1; return .object(fields)
            default: throw error("expected \",\" or \"}\"")
            }
        }
    }

    private mutating func array(depth: Int) throws -> JSONValue {
        i += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try value(depth: depth + 1))
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): i += 1
            case UInt8(ascii: "]"): i += 1; return .array(items)
            default: throw error("expected \",\" or \"]\"")
            }
        }
    }

    /// A string: unescaped bytes are copied as UTF-8 (and checked as UTF-8 at the end), escapes are
    /// decoded, and `\u` surrogates must come in pairs.
    private mutating func string() throws -> String {
        let start = i
        i += 1
        var utf8: [UInt8] = []
        while true {
            guard let b = current else { throw error("unterminated string") }
            switch b {
            case UInt8(ascii: "\""):
                i += 1
                // Not String(bytes:encoding:): Foundation drops a leading U+FEFF there, which would
                // silently change keys and text. Decoding repairs invalid UTF-8, so a repaired string
                // no longer has the same bytes and is refused.
                let s = String(decoding: utf8, as: UTF8.self)
                guard s.utf8.elementsEqual(utf8) else {
                    throw JSONSyntaxError(reason: "string is not valid UTF-8", offset: start)
                }
                return s
            case UInt8(ascii: "\\"):
                i += 1
                guard let e = current else { throw error("unterminated escape") }
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(e)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard current == UInt8(ascii: "\\"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "u") else {
                            throw error("unpaired surrogate")
                        }
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("unpaired surrogate") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw error("unpaired surrogate")
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw error("invalid \\u escape") }
                    utf8.append(contentsOf: String(u).utf8)
                default:
                    throw error("invalid escape")
                }
            case 0x00...0x1F:
                throw error("control character in a string must be escaped")
            default:
                utf8.append(b)
                i += 1
            }
        }
    }

    private mutating func hex4() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 {
            let d: UInt8
            switch current {
            case let b? where UInt8(ascii: "0")...UInt8(ascii: "9") ~= b: d = b - UInt8(ascii: "0")
            case let b? where UInt8(ascii: "a")...UInt8(ascii: "f") ~= b: d = b - UInt8(ascii: "a") + 10
            case let b? where UInt8(ascii: "A")...UInt8(ascii: "F") ~= b: d = b - UInt8(ascii: "A") + 10
            default: throw error("\\u needs four hexadecimal digits")
            }
            v = v * 16 + UInt32(d)
            i += 1
        }
        return v
    }

    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, converted with correct rounding.
    private mutating func number() throws -> Double {
        let start = i
        func digits() -> Int {
            let s = i
            while let b = current, UInt8(ascii: "0")...UInt8(ascii: "9") ~= b { i += 1 }
            return i - s
        }
        if current == UInt8(ascii: "-") { i += 1 }
        if current == UInt8(ascii: "0") {
            i += 1
        } else {
            guard digits() > 0 else { throw error("expected a digit") }
        }
        if current == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw error("expected a digit after \".\"") }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            i += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw error("expected a digit in the exponent") }
        }
        guard let value = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else {
            throw JSONSyntaxError(reason: "invalid number", offset: start)
        }
        return value
    }
}
