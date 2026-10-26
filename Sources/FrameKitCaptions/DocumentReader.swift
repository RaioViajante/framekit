import Foundation

/// The fields of one JSON object and where the object is.
struct Fields {
    let values: [String: JSONValue]
    let pointer: JSONPointer
}

/// An allowed numeric range, with the wording used in messages.
struct NumberRange {
    var min: Double?
    var minExclusive = false
    var max: Double?
    var text: String

    static let any = NumberRange(text: "any number")
    static let nonNegative = NumberRange(min: 0, text: "0 or more")
    static let positive = NumberRange(min: 0, minExclusive: true, text: "greater than 0")
    static let unit = NumberRange(min: 0, max: 1, text: "between 0 and 1")

    func contains(_ x: Double) -> Bool {
        if let min, minExclusive ? x <= min : x < min { return false }
        if let max, x > max { return false }
        return true
    }
}

/// Reads a document while collecting issues. Every accessor reports what is wrong with the value it was
/// asked for and returns nil, so a validator reads the whole document and reports everything at once.
/// Issues come out in reading order, and unknown fields in sorted order, so the list is deterministic.
final class DocumentReader {
    private(set) var issues: [ValidationIssue] = []

    var hasErrors: Bool { issues.contains { $0.severity == .error } }

    func error(_ code: ValidationCode, _ pointer: JSONPointer, _ message: String) {
        issues.append(ValidationIssue(code, at: pointer.description, message))
    }

    func warning(_ code: ValidationCode, _ pointer: JSONPointer, _ message: String) {
        issues.append(ValidationIssue(code, at: pointer.description, message, severity: .warning))
    }

    private func mismatch(_ value: JSONValue, expected: String, _ pointer: JSONPointer) {
        error(.typeMismatch, pointer, "expected \(expected), found \(value.typeName)")
    }

    // MARK: Values

    /// The fields of an object. A field that is not in `allowed` is reported as unknown.
    func object(_ value: JSONValue, _ pointer: JSONPointer, allowed: [String]) -> Fields? {
        guard case .object(let values) = value else { mismatch(value, expected: "object", pointer); return nil }
        for key in values.keys.sorted() where !allowed.contains(key) {
            error(.fieldUnknown, pointer.appending(key), "unknown field \"\(key)\"")
        }
        return Fields(values: values, pointer: pointer)
    }

    /// The entries of an object used as a map (keys chosen by the author, such as style names).
    func map(_ value: JSONValue, _ pointer: JSONPointer) -> [(key: String, value: JSONValue)]? {
        guard case .object(let values) = value else { mismatch(value, expected: "object", pointer); return nil }
        return values.sorted { $0.key < $1.key }
    }

    func array(_ value: JSONValue, _ pointer: JSONPointer, nonEmpty: Bool = false) -> [JSONValue]? {
        guard case .array(let items) = value else { mismatch(value, expected: "array", pointer); return nil }
        if nonEmpty && items.isEmpty { error(.arrayEmpty, pointer, "must contain at least one item"); return nil }
        return items
    }

    func number(_ value: JSONValue, _ pointer: JSONPointer, _ range: NumberRange) -> Double? {
        guard case .number(let x) = value else { mismatch(value, expected: "number", pointer); return nil }
        // JSON has no NaN or infinity, but a value changed in code and checked again can.
        guard x.isFinite else { error(.valueOutOfRange, pointer, "\(x) is not a finite number"); return nil }
        guard range.contains(x) else { error(.valueOutOfRange, pointer, "\(x) is out of range (\(range.text))"); return nil }
        return x
    }

    /// The largest integer that every JSON implementation reads exactly: 2^53 - 1 (I-JSON, RFC 7493
    /// section 2.2). Integer fields without a smaller natural limit stop here, as their schemas do.
    static let maxExactInteger = 9_007_199_254_740_991

    /// An integer in `range` (whose bounds are within plus or minus `maxExactInteger`). A fractional
    /// number is a type mismatch; a whole number outside the range, however large, is out of range.
    func integer(_ value: JSONValue, _ pointer: JSONPointer, _ range: ClosedRange<Int>) -> Int? {
        guard case .number(let x) = value else { mismatch(value, expected: "integer", pointer); return nil }
        guard x.isFinite else { error(.valueOutOfRange, pointer, "\(x) is not a finite number"); return nil }
        guard x == x.rounded() else { mismatch(value, expected: "integer", pointer); return nil }
        guard let n = Int(exactly: x), range.contains(n) else {
            let shown = Int(exactly: x).map(String.init) ?? "\(x)"
            error(.valueOutOfRange, pointer, "\(shown) is out of range (\(range.lowerBound) to \(range.upperBound))"); return nil
        }
        return n
    }

    func string(_ value: JSONValue, _ pointer: JSONPointer, pattern: String? = nil, patternText: String = "") -> String? {
        guard case .string(let s) = value else { mismatch(value, expected: "string", pointer); return nil }
        if s.isEmpty { error(.valueInvalid, pointer, "must not be empty"); return nil }
        if let pattern, s.range(of: pattern, options: .regularExpression) == nil {
            error(.valueInvalid, pointer, "\"\(s)\" is not \(patternText)"); return nil
        }
        return s
    }

    /// One of the values this version supports. Values listed in `unsupported` are recognised but refused
    /// with `option.unsupported`, so that a reserved option is not mistaken for a typo.
    func choice<E: RawRepresentable & CaseIterable>(_ value: JSONValue, _ pointer: JSONPointer, _: E.Type,
                                                    unsupported: [String] = []) -> E? where E.RawValue == String {
        guard case .string(let s) = value else { mismatch(value, expected: "string", pointer); return nil }
        if let e = E(rawValue: s) { return e }
        let supported = E.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        if unsupported.contains(s) {
            error(.optionUnsupported, pointer, "\"\(s)\" is not supported in this version (supported: \(supported))")
        } else {
            error(.valueInvalid, pointer, "\"\(s)\" is not one of \(supported)")
        }
        return nil
    }

    /// `"#rrggbb"` or `{"srgb": [r, g, b]}` with components between 0 and 1. The float form keeps exact
    /// values; the hex form is converted as component / 255.
    func color(_ value: JSONValue, _ pointer: JSONPointer) -> RGBColor? {
        if case .string(let s) = value {
            guard s.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
                  let v = UInt32(s.dropFirst(), radix: 16) else {
                error(.valueInvalid, pointer, "\"\(s)\" is not a #rrggbb colour"); return nil
            }
            return RGBColor(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
        }
        guard case .object = value else { mismatch(value, expected: "#rrggbb string or {\"srgb\": [r, g, b]}", pointer); return nil }
        guard let f = object(value, pointer, allowed: ["srgb"]), let raw = field(f, "srgb") else { return nil }
        let p = pointer.appending("srgb")
        guard let items = array(raw, p) else { return nil }
        guard items.count == 3 else { error(.valueInvalid, p, "must have exactly 3 components, found \(items.count)"); return nil }
        let c = items.enumerated().map { number($0.element, p.appending($0.offset), .unit) }
        guard let r = c[0], let g = c[1], let b = c[2] else { return nil }
        return RGBColor(red: r, green: g, blue: b)
    }

    // MARK: Fields

    /// The value of a field; a missing field is reported when it is required.
    func field(_ f: Fields, _ key: String, required: Bool = true) -> JSONValue? {
        if let v = f.values[key] { return v }
        if required { error(.fieldMissing, f.pointer.appending(key), "required field \"\(key)\" is missing") }
        return nil
    }

    func object(_ f: Fields, _ key: String, allowed: [String]) -> Fields? {
        field(f, key).flatMap { object($0, f.pointer.appending(key), allowed: allowed) }
    }

    func number(_ f: Fields, _ key: String, _ range: NumberRange, required: Bool = true) -> Double? {
        field(f, key, required: required).flatMap { number($0, f.pointer.appending(key), range) }
    }

    func integer(_ f: Fields, _ key: String, _ range: ClosedRange<Int>) -> Int? {
        field(f, key).flatMap { integer($0, f.pointer.appending(key), range) }
    }

    func string(_ f: Fields, _ key: String, required: Bool = true, pattern: String? = nil, patternText: String = "") -> String? {
        field(f, key, required: required).flatMap { string($0, f.pointer.appending(key), pattern: pattern, patternText: patternText) }
    }

    func choice<E: RawRepresentable & CaseIterable>(_ f: Fields, _ key: String, _ type: E.Type, required: Bool = true,
                                                    unsupported: [String] = []) -> E? where E.RawValue == String {
        field(f, key, required: required).flatMap { choice($0, f.pointer.appending(key), type, unsupported: unsupported) }
    }

    func color(_ f: Fields, _ key: String) -> RGBColor? {
        field(f, key).flatMap { color($0, f.pointer.appending(key)) }
    }

    /// Reads `schema_version`. A newer version than this library understands is reported as such rather
    /// than as a list of unknown fields.
    func schemaVersion(_ f: Fields, supported: Int) -> Int? {
        guard let v = integer(f, "schema_version", 1...DocumentReader.maxExactInteger) else { return nil }
        if v > supported {
            error(.schemaUnsupportedVersion, f.pointer.appending("schema_version"),
                  "schema_version \(v) is newer than the supported version \(supported)")
            return nil
        }
        return v
    }
}
