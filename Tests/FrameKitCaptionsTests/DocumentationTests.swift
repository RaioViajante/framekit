import Foundation
import Testing
@testable import FrameKitCaptions

/// The field tables and the error-code table in docs/caption-configuration.md are part of the contract;
/// these tests fail when they and the code diverge.
@Suite struct ContractDocumentation {
    let doc: String

    init() throws {
        doc = try String(contentsOf: Repo.url("docs/caption-configuration.md"), encoding: .utf8)
    }

    /// The first-column code spans of the table under `heading`.
    func tableKeys(under heading: String) throws -> [String] {
        let start = try #require(doc.range(of: "\n" + heading + "\n"), "no heading \(heading)")
        let section = String(doc[start.upperBound...]).components(separatedBy: "\n#")[0]
        return section.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("| `") else { return nil }
            return String(line.dropFirst(3).prefix { $0 != "`" })
        }
    }

    /// Leaf field paths of a document: arrays of objects become `[]`, colours are leaves, and maps whose
    /// keys are chosen by the author become a placeholder.
    func fieldPaths(_ value: JSONValue, _ path: String = "", maps: [String: String]) -> Set<String> {
        switch value {
        case .object(let o) where o.keys.sorted() == ["srgb"]:
            return [path]
        case .object(let o):
            if let placeholder = maps[path] {
                return o.values.reduce(into: Set()) { $0.formUnion(fieldPaths($1, path + "." + placeholder, maps: maps)) }
            }
            return o.reduce(into: Set()) { $0.formUnion(fieldPaths($1.value, path.isEmpty ? $1.key : path + "." + $1.key, maps: maps)) }
        case .array(let items) where items.contains(where: { if case .object = $0 { true } else { false } }):
            return items.reduce(into: Set()) { $0.formUnion(fieldPaths($1, path + "[]", maps: maps)) }
        default:
            return [path]
        }
    }

    @Test func presetFieldTableMatchesTheContract() throws {
        // The shipped preset uses every field (all are required but `description`, which it has).
        let preset = try Repo.json("captions/presets/kinetic-minimal.json")
        let documented = try tableKeys(under: "### Preset fields")
        #expect(Set(documented).count == documented.count)
        #expect(Set(documented) == fieldPaths(preset, maps: ["emphasis_styles": "<style>"]))
    }

    @Test func inputFieldTableMatchesTheContract() throws {
        // The two-cue example uses every optional field.
        let example = try Repo.json("captions/examples/two-cues.input.json")
        let documented = try tableKeys(under: "### Input fields")
        #expect(Set(documented).count == documented.count)
        #expect(Set(documented) == fieldPaths(example, maps: ["cues[].emphasis": "<word id>"]))
    }

    @Test func everyErrorCodeIsDocumented() throws {
        let documented = try tableKeys(under: "### Error codes")
        #expect(documented == ValidationCode.allCases.map(\.rawValue))
    }

    @Test func documentedPresetValuesMatchTheFile() throws {
        // Spot-check the human table against the file for the values most likely to be retyped.
        for fragment in ["`AvenirNext-Medium` 54 px", "`[0.9255, 0.9059, 0.8784]`", "`[0.07, 0.035, 0.12]`, alpha 0.92",
                         "offset 0, -3", "`Palatino-Italic` 58 px", "`[0.7647, 0.702, 0.8784]`", "first baseline 330"] {
            #expect(doc.contains(fragment), "\(fragment)")
        }
    }
}
