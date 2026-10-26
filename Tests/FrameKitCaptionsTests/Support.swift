import Foundation
import Testing
@testable import FrameKitCaptions

/// Paths inside this repository, found from this file so the tests run from any working directory.
enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    static func json(_ path: String) throws -> JSONValue {
        try #require(JSONValue.parse(Data(contentsOf: url(path))), "\(path) is not JSON")
    }

    static let presets = url("captions/presets")
}

/// Literals, so tests can write documents inline.
extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}

extension JSONValue {
    /// A copy with the value at a dotted path (`text.size`, `words.0.end`) replaced, or removed when
    /// `value` is nil. Intermediate objects and arrays must exist.
    func setting(_ path: String, _ value: JSONValue?) -> JSONValue {
        setting(path.split(separator: ".").map(String.init)[...], value)
    }

    private func setting(_ path: ArraySlice<String>, _ value: JSONValue?) -> JSONValue {
        guard let key = path.first else { return value ?? .null }
        let rest = path.dropFirst()
        switch self {
        case .object(var fields):
            if rest.isEmpty && value == nil { fields[key] = nil }
            else { fields[key] = (fields[key] ?? .null).setting(rest, value) }
            return .object(fields)
        case .array(var items):
            let i = Int(key)!
            if rest.isEmpty && value == nil { items.remove(at: i) }
            else { items[i] = items[i].setting(rest, value) }
            return .array(items)
        default:
            preconditionFailure("cannot descend into \(self) at \(key)")
        }
    }
}

/// Code and pointer of each issue, which is what the contract tests assert on.
func summary(_ issues: [ValidationIssue]) -> [String] {
    issues.map { "\($0.code.rawValue) \($0.pointer)" }
}

/// Rows of the Markdown table under `heading` in docs/caption-configuration.md: the first column's code
/// span, and the whole row.
func docTableRows(under heading: String) throws -> [(key: String, row: String)] {
    let doc = try String(contentsOf: Repo.url("docs/caption-configuration.md"), encoding: .utf8)
    let start = try #require(doc.range(of: "\n" + heading + "\n"), "no heading \(heading)")
    let section = String(doc[start.upperBound...]).components(separatedBy: "\n#")[0]
    return section.split(separator: "\n").compactMap { line in
        guard line.hasPrefix("| `") else { return nil }
        return (String(line.dropFirst(3).prefix { $0 != "`" }), String(line))
    }
}

func docTableKeys(under heading: String) throws -> [String] {
    try docTableRows(under: heading).map(\.key)
}
