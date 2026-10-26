import Foundation
import Testing
@testable import FrameKitCaptions

/// The JSON Schemas, the documentation and the Swift validator describe one contract. The schemas'
/// own verdicts on the shared cases are checked with `check-jsonschema` (captions/tests/test_schemas.py);
/// here the validator is held to the same cases, and to every constraint the schemas state.
@Suite struct SchemaParity {
    static let schemas = ["preset": "captions/schemas/caption-preset.v1.schema.json",
                          "input": "captions/schemas/caption-input.v1.schema.json"]
    static let bases = ["preset": "captions/presets/kinetic-minimal.json",
                        "input": "captions/examples/two-cues.input.json"]
    /// Objects whose keys the author chooses: the placeholder the documentation uses, and a key the base
    /// document has.
    static let maps = ["emphasis_styles": ("<style>", "soft"), "cues[].emphasis": ("<word id>", "w6")]
    /// Codes that describe the structure, which the schemas express.
    static let structural: Set<ValidationCode> = [.typeMismatch, .fieldMissing, .fieldUnknown, .valueOutOfRange,
                                                  .valueInvalid, .optionUnsupported, .arrayEmpty, .schemaUnsupportedVersion]

    let preset: CaptionPreset

    init() throws {
        preset = try CaptionPreset.load(contentsOf: Repo.url(Self.bases["preset"]!))
    }

    func issues(_ document: String, _ doc: JSONValue, againstPreset: Bool = false) -> [ValidationIssue] {
        if document == "preset" { return CaptionPreset.validate(doc).issues }
        let result = CaptionInput.validate(doc)
        return result.issues + (againstPreset ? result.value?.validate(against: preset) ?? [] : [])
    }

    // MARK: Shared cases

    struct Case {
        let name: String, document: String, doc: JSONValue, schema: Bool, validator: [String], againstPreset: Bool
    }

    static func cases() throws -> [Case] {
        guard case .object(let file) = try Repo.json("captions/schemas/conformance.json"),
              case .array(let items)? = file["cases"] else { throw CocoaError(.fileReadCorruptFile) }
        return try items.map { item in
            guard case .object(let c) = item, case .string(let name)? = c["name"], case .string(let document)? = c["document"],
                  case .bool(let schema)? = c["schema"], case .array(let codes)? = c["validator"] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var doc = try Repo.json(bases[document]!)
            if case .object(let set)? = c["set"] { for (path, value) in set.sorted(by: { $0.key < $1.key }) { doc = doc.setting(path, value) } }
            if case .array(let remove)? = c["remove"] { for case .string(let path) in remove { doc = doc.setting(path, nil) } }
            let validator = codes.compactMap { if case .string(let s) = $0 { s } else { nil } }
            return Case(name: name, document: document, doc: doc, schema: schema, validator: validator,
                        againstPreset: c["against_preset"] == .bool(true))
        }
    }

    @Test func theValidatorGivesTheExpectedIssuesForEverySharedCase() throws {
        let cases = try Self.cases()
        #expect(cases.count >= 50)
        for c in cases {
            let found = issues(c.document, c.doc, againstPreset: c.againstPreset)
            #expect(summary(found) == c.validator, "\(c.name)")
            // Whatever the schema rejects, the validator rejects too.
            if !c.schema { #expect(found.contains { $0.severity == .error }, "\(c.name)") }
        }
    }

    @Test func validatorOnlyRulesAreDocumentedAndCovered() throws {
        let documented = Set(try docTableKeys(under: "### Validator-only rules"))
        let accepted = try Self.cases().filter(\.schema)
        let codes = Set(accepted.flatMap { $0.validator.map { String($0.prefix { $0 != " " }) } })
        #expect(codes == documented)
    }

    // MARK: Every constraint of the schemas

    struct Field {
        let docPath: String
        let path: String
        let pointer: String
        let schema: [String: JSONValue]
        let required: Bool
        let optional: Bool
        let leaf: Bool
    }

    static func resolve(_ node: JSONValue, _ root: JSONValue) -> [String: JSONValue] {
        guard case .object(var o) = node else { return [:] }
        if case .string(let ref)? = o["$ref"], ref.hasPrefix("#/$defs/"), case .object(let r) = root,
           case .object(let defs)? = r["$defs"], let target = defs[String(ref.dropFirst(8))] {
            o = resolve(target, root)
        }
        return o
    }

    /// Every property the schema describes, with where it is in the base document.
    static func fields(_ document: String) throws -> (fields: [Field], objects: [(path: String, pointer: String)]) {
        let root = try Repo.json(schemas[document]!)
        var fields: [Field] = [], objects: [(String, String)] = []
        func walk(_ node: JSONValue, doc: String, path: [String], optional: Bool) {
            let s = resolve(node, root)
            let pointer = path.map { "/" + $0 }.joined()
            if case .object(let props)? = s["properties"] {
                if s["additionalProperties"] == .bool(false) { objects.append((path.joined(separator: "."), pointer)) }
                var required: Set<String> = []
                if case .array(let r)? = s["required"] { for case .string(let k) in r { required.insert(k) } }
                for (key, sub) in props.sorted(by: { $0.key < $1.key }) {
                    let d = doc.isEmpty ? key : doc + "." + key
                    let sub = resolve(sub, root)
                    let isLeaf = sub["properties"] == nil && !isMap(sub) && !isArrayOfObjects(sub, root)
                    fields.append(Field(docPath: d, path: (path + [key]).joined(separator: "."), pointer: pointer + "/" + key,
                                        schema: sub, required: required.contains(key), optional: optional || !required.contains(key), leaf: isLeaf))
                    walk(.object(sub), doc: d, path: path + [key], optional: optional || !required.contains(key))
                }
            } else if isMap(s), let (placeholder, key) = maps[doc], case let value? = s["additionalProperties"] {
                let sub = resolve(value, root)
                let d = doc + "." + placeholder
                if sub["properties"] == nil {
                    fields.append(Field(docPath: d, path: (path + [key]).joined(separator: "."), pointer: pointer + "/" + key,
                                        schema: sub, required: false, optional: optional, leaf: true))
                }
                walk(.object(sub), doc: d, path: path + [key], optional: optional)
            } else if isArrayOfObjects(s, root), let items = s["items"] {
                walk(items, doc: doc + "[]", path: path + ["0"], optional: optional)
            }
        }
        walk(root, doc: "", path: [], optional: false)
        return (fields, objects)
    }

    static func isMap(_ s: [String: JSONValue]) -> Bool {
        if case .object? = s["additionalProperties"] { s["properties"] == nil } else { false }
    }

    static func isArrayOfObjects(_ s: [String: JSONValue], _ root: JSONValue) -> Bool {
        guard s["type"] == .string("array"), let items = s["items"] else { return false }
        return resolve(items, root)["properties"] != nil
    }

    /// Issues at exactly `pointer` with a structural code.
    func structuralIssues(_ document: String, _ doc: JSONValue, at pointer: String) -> [ValidationIssue] {
        issues(document, doc).filter { $0.pointer == pointer && Self.structural.contains($0.code) }
    }

    @Test(arguments: ["preset", "input"])
    func theValidatorEnforcesEveryConstraintOfTheSchema(document: String) throws {
        let base = try Repo.json(Self.bases[document]!)
        #expect(issues(document, base).filter { $0.severity == .error }.isEmpty)
        let (fields, objects) = try Self.fields(document)
        let known: Set<String> = ["type", "minimum", "maximum", "exclusiveMinimum", "minLength", "minItems", "maxItems",
                                  "uniqueItems", "pattern", "enum", "const", "items", "oneOf", "properties",
                                  "required", "additionalProperties", "propertyNames"]

        func rejects(_ path: String, _ value: JSONValue?, _ pointer: String, _ code: ValidationCode? = nil, _ why: String) {
            let found = structuralIssues(document, base.setting(path, value), at: pointer)
            if let code { #expect(found.map(\.code) == [code], "\(path): \(why)") }
            else { #expect(!found.isEmpty, "\(path): \(why)") }
        }
        func accepts(_ path: String, _ value: JSONValue?, _ pointer: String, _ why: String) {
            #expect(structuralIssues(document, base.setting(path, value), at: pointer).isEmpty, "\(path): \(why)")
        }

        for (path, pointer) in objects {
            let p = path.isEmpty ? "zz_unknown" : path + ".zz_unknown"
            rejects(p, 1, pointer + "/zz_unknown", .fieldUnknown, "additionalProperties false")
        }
        for f in fields {
            #expect(Set(f.schema.keys).isSubset(of: known), "\(f.docPath) uses a keyword these tests do not check")
            if f.required { rejects(f.path, nil, f.pointer, .fieldMissing, "required") }
            else if !f.docPath.contains("<") { accepts(f.path, nil, f.pointer, "optional") }
            guard f.leaf else { continue }
            let s = f.schema
            switch s["type"] {
            case .string("number")?, .string("integer")?: rejects(f.path, "1", f.pointer, .typeMismatch, "type")
            case .string("string")?: rejects(f.path, 1, f.pointer, .typeMismatch, "type")
            case .string("array")?: rejects(f.path, .object([:]), f.pointer, .typeMismatch, "type")
            default: rejects(f.path, true, f.pointer, .typeMismatch, "type")  // colours, enums, const: never a boolean
            }
            if s["type"] == .string("integer") { rejects(f.path, 1.5, f.pointer, .typeMismatch, "integer") }
            if case .number(let m)? = s["minimum"] {
                rejects(f.path, .number(m - 1), f.pointer, .valueOutOfRange, "minimum")
                accepts(f.path, .number(m), f.pointer, "minimum")
            }
            if case .number(let m)? = s["exclusiveMinimum"] {
                rejects(f.path, .number(m), f.pointer, .valueOutOfRange, "exclusiveMinimum")
                accepts(f.path, .number(m + 0.5), f.pointer, "exclusiveMinimum")
            }
            if case .number(let m)? = s["maximum"] {
                rejects(f.path, .number(m + 1), f.pointer, .valueOutOfRange, "maximum")
                accepts(f.path, .number(m), f.pointer, "maximum")
            }
            if case .number(let n)? = s["minLength"], n == 1 { rejects(f.path, "", f.pointer, .valueInvalid, "minLength") }
            if s["pattern"] != nil { rejects(f.path, "Not Valid!", f.pointer, .valueInvalid, "pattern") }
            if case .number(let n)? = s["minItems"], n == 1 { rejects(f.path, [], f.pointer, .arrayEmpty, "minItems") }
            if s["uniqueItems"] == .bool(true), case .array(let items)? = base.value(at: f.path), let first = items.first {
                let found = summary(issues(document, base.setting(f.path, .array(items + [first]))))
                #expect(found.contains("id.duplicate \(f.pointer)/\(items.count)"), "\(f.path): uniqueItems")
            }
            if case .array(let values)? = s["enum"] {
                rejects(f.path, "not-an-option", f.pointer, .valueInvalid, "enum")
                for v in values { accepts(f.path, v, f.pointer, "enum value \(v)") }
            }
            if case .number(let c)? = s["const"] {
                accepts(f.path, .number(c), f.pointer, "const")
                rejects(f.path, .number(c + 1), f.pointer, nil, "const")
            }
        }
    }

    // MARK: Documentation and Swift types

    @Test(arguments: [("preset", "### Preset fields"), ("input", "### Input fields")])
    func documentedFieldsAreTheSchemasFields(document: String, heading: String) throws {
        let rows = try docTableRows(under: heading)
        let leaves = try Self.fields(document).fields.filter(\.leaf)
        #expect(Set(rows.map(\.key)) == Set(leaves.map(\.docPath)))
        // A field is optional in the documentation exactly when the schema does not require it.
        let documentedOptional = Set(rows.filter { $0.row.contains("optional") }.map(\.key))
        #expect(documentedOptional == Set(leaves.filter(\.optional).map(\.docPath)))
    }

    @Test func schemaEnumsAreTheSwiftEnums() throws {
        func enumValues(_ document: String, _ docPath: String) throws -> [String] {
            let f = try #require(try Self.fields(document).fields.first { $0.docPath == docPath }, "\(docPath)")
            guard case .array(let values)? = f.schema["enum"] else { return [] }
            return values.compactMap { if case .string(let s) = $0 { s } else { nil } }
        }
        #expect(try enumValues("preset", "text.align") == CaptionPreset.Alignment.allCases.map(\.rawValue))
        #expect(try enumValues("preset", "placement.mode") == CaptionPreset.PlacementMode.allCases.map(\.rawValue))
        for path in ["animation.fade_in.easing", "animation.fade_out.easing", "emphasis_styles.<style>.transition.easing"] {
            #expect(try enumValues("preset", path) == Easing.allCases.map(\.rawValue))
        }
        for path in ["emphasis_styles.<style>.font_from", "emphasis_styles.<style>.size_from"] {
            #expect(try enumValues("preset", path) == CaptionPreset.SwitchPoint.allCases.map(\.rawValue))
        }
        #expect(try enumValues("input", "timing_source") == CaptionInput.TimingSource.allCases.map(\.rawValue))
    }

    @Test(arguments: ["preset", "input"])
    func schemaIdentity(document: String) throws {
        let path = Self.schemas[document]!
        guard case .object(let s) = try Repo.json(path) else { Issue.record("not an object"); return }
        #expect(s["$schema"] == .string("https://json-schema.org/draft/2020-12/schema"))
        // $id: the raw URL of the file on main; the version is in the file name.
        #expect(s["$id"] == .string("https://raw.githubusercontent.com/RaioViajante/framekit/main/" + path))
        #expect(path.hasSuffix(".v\(document == "preset" ? CaptionPreset.schemaVersion : CaptionInput.schemaVersion).schema.json"))
        #expect(s["additionalProperties"] == .bool(false))
    }
}

extension JSONValue {
    /// The value at a dotted path, if there is one.
    func value(at path: String) -> JSONValue? {
        path.split(separator: ".").reduce(Optional(self)) { node, key in
            switch node {
            case .object(let o)?: o[String(key)]
            case .array(let a)?: Int(key).flatMap { $0 < a.count ? a[$0] : nil }
            default: nil
            }
        }
    }
}
