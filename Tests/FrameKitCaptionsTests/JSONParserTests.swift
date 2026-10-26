import Foundation
import Testing
@testable import FrameKitCaptions

/// The contract's JSON is strict RFC 8259. Foundation's parser also accepts trailing commas, so the
/// library has its own parser; these tests pin what it accepts and refuses.
@Suite struct StrictJSON {
    func parse(_ text: String) -> JSONValue? { JSONValue.parse(Data(text.utf8)) }

    @Test(arguments: [
        ("{}", JSONValue.object([:])), ("[]", .array([])), ("0", .number(0)), ("-0.5e-3", .number(-0.0005)), ("1E+2", .number(100)),
        ("true", .bool(true)), ("null", .null), (" \t\n\r[ 1 , 2 ]\n", .array([.number(1), .number(2)])),
        (#"{"a":[1,{"b":null}],"c":"x"}"#, .object(["a": .array([.number(1), .object(["b": .null])]), "c": .string("x")])),
        // Commas and brackets inside strings are text, not syntax.
        (#"{"a":"x,}","b":"],"}"#, .object(["a": .string("x,}"), "b": .string("],")])),
        (#""\"\\\/\b\f\n\r\t""#, .string("\"\\/\u{8}\u{C}\n\r\t")),
        (#""\u00e9\u0301\ud83d\ude00""#, .string("\u{E9}\u{301}\u{1F600}")),
        ("\"caf\u{E9} \u{2026}\"", .string("caf\u{E9} \u{2026}")),
        ("\u{FEFF}[1]", .array([.number(1)])),  // a leading byte order mark is skipped, as check-jsonschema does
        ("[0.1, 0.30000000000000004, 1e400]", .array([.number(0.1), .number(0.30000000000000004), .number(.infinity)])),
    ] as [(String, JSONValue)])
    func accepts(text: String, expected: JSONValue) {
        #expect(parse(text) == expected, "\(text)")
    }

    @Test(arguments: [
        "{\"a\":1,}", "[1,2,]", "[[1,],2]", "{\"a\":{\"b\":1,},\"c\":2}", "[,]", "[1,,2]", "{,}",
        "[01]", "[-01]", "[+1]", "[.5]", "[1.]", "[1e]", "[1e+]", "[-]", "[NaN]", "[Infinity]", "[-Infinity]",
        "['a']", "{a:1}", "[1 /* c */]", "[1] // c", "[\"a\nb\"]", "[\"\u{1}\"]", "[\"\\x\"]", "[\"\\u12\"]", "[\"\\u12G4\"]",
        "[\"\\ud800\"]", "[\"\\udc00\"]", "[\"\\ud800\\u0041\"]", "{} {}", "[1] x", "", " ", "[", "{\"a\"", "{\"a\":}", "{\"a\" 1}",
        "[true false]", "tru", "nul", "\"open",
    ])
    func refuses(text: String) {
        #expect(parse(text) == nil, "\(text)")
    }

    /// U+FEFF inside a string is text and is kept, also at the start of a string or key (only a byte
    /// order mark before the whole document is skipped).
    @Test func zeroWidthNoBreakSpaceIsKept() {
        #expect(parse("\"\u{FEFF}abc\"") == .string("\u{FEFF}abc"))
        #expect(JSONValue.parse(Data([0x22, 0xEF, 0xBB, 0xBF, 0x61, 0x22])) == .string("\u{FEFF}a"))
        #expect(parse("{\"\u{FEFF}\":1}") == .object(["\u{FEFF}": .number(1)]))
        #expect(parse(#""\ufeffabc""#) == .string("\u{FEFF}abc"))
        #expect(parse("\u{FEFF}\"\u{FEFF}a\"") == .string("\u{FEFF}a"))  // document BOM skipped, string's kept
    }

    @Test func aKeyStartingWithUFEFFIsNotTheFieldItLooksLike() throws {
        let doc = try String(contentsOf: Repo.url("captions/examples/two-cues.input.json"), encoding: .utf8)
            .replacingOccurrences(of: "\"language\"", with: "\"\u{FEFF}language\"")
        #expect(summary(CaptionInput.validate(Data(doc.utf8)).issues) == ["field.unknown /\u{FEFF}language", "field.missing /language"])
    }

    @Test func invalidUTF8IsRefused() {
        #expect(JSONValue.parse(Data([0x22, 0xC3, 0x28, 0x22])) == nil)  // a broken two-byte sequence in a string
        #expect(JSONValue.parse(Data([0x22, 0xED, 0xA0, 0x80, 0x22])) == nil)  // a surrogate encoded as UTF-8
    }

    @Test func deepNestingIsRefusedNotACrash() {
        #expect(parse(String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)) == nil)
        let ok = String(repeating: "[", count: JSONParser.maxDepth) + String(repeating: "]", count: JSONParser.maxDepth)
        #expect(parse(ok) != nil)
    }

    /// Documented limitation (#7): a repeated key, or two canonically equivalent keys, keep the last value.
    @Test func repeatedKeysKeepTheLastValue() {
        #expect(parse(#"{"a":1,"a":2}"#) == .object(["a": .number(2)]))
        #expect(parse("{\"\u{E9}\":1,\"e\u{301}\":2}") == .object(["\u{E9}": .number(2)]))
    }

    @Test func malformedDocumentsSayWhyAndWhere() {
        let preset = CaptionPreset.validate(Data("{\"schema_version\": 1,}".utf8)).issues
        #expect(summary(preset) == ["json.malformed "])
        #expect(preset.first?.message == "not valid JSON: expected a string key at byte 21")
        let input = CaptionInput.validate(Data("{\"cues\": [1,]}".utf8)).issues
        #expect(input.first?.message == "not valid JSON: unexpected character at byte 12")
    }

    @Test(arguments: ["captions/presets/kinetic-minimal.json", "captions/examples/one-cue.input.json",
                      "captions/examples/two-cues.input.json", "captions/schemas/conformance.json",
                      "captions/schemas/caption-preset.v1.schema.json", "captions/schemas/caption-input.v1.schema.json"])
    func repositoryDocumentsParseTheSameAsFoundation(path: String) throws {
        // Where Foundation is right (no trailing commas), both parsers agree value for value.
        let data = try Data(contentsOf: Repo.url(path))
        let foundation = try JSONSerialization.jsonObject(with: data)
        #expect(JSONValue.parse(data)?.foundationObject as? NSObject == foundation as? NSObject)
    }
}
