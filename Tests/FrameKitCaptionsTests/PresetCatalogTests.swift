import Foundation
import Testing
@testable import FrameKitCaptions

@Suite struct PresetSelection {
    let catalog = PresetCatalog(directory: Repo.presets)

    @Test func selectsKineticMinimalByID() throws {
        #expect(try catalog.presetIDs().contains("kinetic-minimal"))
        let result = catalog.preset(id: "kinetic-minimal")
        #expect(result.issues.isEmpty)
        #expect(result.value?.presetID == "kinetic-minimal")
    }

    @Test func everyShippedPresetIsValidAndNamedAfterItsID() throws {
        for id in try catalog.presetIDs() {
            let result = catalog.preset(id: id)
            #expect(result.issues.isEmpty, "\(id): \(result.issues)")
        }
    }

    @Test func unknownIDsAreNotFound() {
        #expect(summary(catalog.preset(id: "kinetic-maximal").issues) == ["preset.not_found "])
        #expect(catalog.preset(id: "kinetic-maximal").issues[0].message.contains("\"kinetic-minimal\""))
        // An id is a name, never a path.
        #expect(summary(catalog.preset(id: "../presets/kinetic-minimal").issues) == ["preset.not_found "])
        #expect(summary(catalog.preset(id: "").issues) == ["preset.not_found "])
    }

    @Test func aNewPresetIsAFileNotCode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A future preset: same contract, different look.
        let future = try Repo.json("captions/presets/kinetic-minimal.json")
            .setting("preset_id", "future-example")
            .setting("text.font", "Helvetica")
            .setting("required_fonts", ["Helvetica", "Palatino-Italic"])
            .setting("placement.baseline_y", 1600)
        try write(future, to: dir.appendingPathComponent("future-example.json"))
        try FileManager.default.copyItem(at: Repo.presets.appendingPathComponent("kinetic-minimal.json"),
                                         to: dir.appendingPathComponent("kinetic-minimal.json"))

        let local = PresetCatalog(directory: dir)
        #expect(try local.presetIDs() == ["future-example", "kinetic-minimal"])
        let selected = try #require(local.preset(id: "future-example").value)
        #expect(selected.text.font == "Helvetica" && selected.placement.baselineY == 1600)
        #expect(local.preset(id: "kinetic-minimal").value?.text.font == "AvenirNext-Medium")
    }

    @Test func fileNameMustMatchPresetID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: Repo.presets.appendingPathComponent("kinetic-minimal.json"),
                                         to: dir.appendingPathComponent("renamed.json"))
        let result = PresetCatalog(directory: dir).preset(id: "renamed")
        #expect(summary(result.issues) == ["preset.id_mismatch /preset_id"])
        #expect(result.value == nil)
    }

    private func write(_ value: JSONValue, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value.foundationObject, options: [.sortedKeys]).write(to: url)
    }
}

extension JSONValue {
    var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.map(\.foundationObject)
        case .object(let o): o.mapValues(\.foundationObject)
        }
    }
}
