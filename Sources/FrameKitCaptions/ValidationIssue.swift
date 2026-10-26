import Foundation

/// Stable codes for every problem the validators report. A code is never reused for a different rule;
/// the list is documented in docs/caption-configuration.md#error-codes and a test keeps the two in sync.
public enum ValidationCode: String, CaseIterable, Sendable {
    // Any document
    case jsonMalformed = "json.malformed"
    case typeMismatch = "type.mismatch"
    case fieldMissing = "field.missing"
    case fieldUnknown = "field.unknown"
    case valueOutOfRange = "value.out_of_range"
    case valueInvalid = "value.invalid"
    case optionUnsupported = "option.unsupported"
    case schemaUnsupportedVersion = "schema.unsupported_version"
    case arrayEmpty = "array.empty"
    case idDuplicate = "id.duplicate"
    // Preset
    case fontUndeclared = "font.undeclared"
    case fontUnused = "font.unused"
    case fontUnavailable = "font.unavailable"
    case presetNotFound = "preset.not_found"
    case presetIDMismatch = "preset.id_mismatch"
    case presetInvalid = "preset.invalid"
    // Caption input
    case timingInvalid = "timing.invalid"
    case timingOutOfOrder = "timing.out_of_order"
    case textNotNormalized = "text.not_normalized"
    case textContainsWhitespace = "text.contains_whitespace"
    case textContainsControl = "text.contains_control"
    case wordUnknown = "word.unknown"
    case wordReused = "word.reused"
    case wordUnused = "word.unused"
    case cueTooManyLines = "cue.too_many_lines"
    case emphasisWordNotInCue = "emphasis.word_not_in_cue"
    case emphasisUnknownStyle = "emphasis.unknown_style"
}

public enum Severity: String, Sendable {
    /// The document must not be rendered.
    case error
    /// Worth a look; rendering may go ahead.
    case warning
}

/// One problem in a document: a stable code, where it is (a JSON Pointer, RFC 6901), a message for a
/// person and a severity.
public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public let code: ValidationCode
    public let pointer: String
    public let message: String
    public let severity: Severity

    public init(_ code: ValidationCode, at pointer: String, _ message: String, severity: Severity = .error) {
        self.code = code
        self.pointer = pointer
        self.message = message
        self.severity = severity
    }

    public var description: String {
        "\(severity.rawValue) \(code.rawValue) at \(pointer.isEmpty ? "(document)" : pointer): \(message)"
    }
}

/// What validating a document produced: the value when there are no errors, and every issue found in a
/// deterministic order (the same input always gives the same list).
public struct ValidationResult<Value: Sendable>: Sendable {
    public let value: Value?
    public let issues: [ValidationIssue]

    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }
}

/// A JSON Pointer under construction.
struct JSONPointer: CustomStringConvertible {
    private var tokens: [String] = []

    static let root = JSONPointer()

    func appending(_ key: String) -> JSONPointer {
        var p = self
        p.tokens.append(key)
        return p
    }

    func appending(_ index: Int) -> JSONPointer { appending(String(index)) }

    var description: String {
        tokens.map { "/" + $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined()
    }
}
