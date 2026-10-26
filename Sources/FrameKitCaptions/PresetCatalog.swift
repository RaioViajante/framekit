import Foundation

/// Selects presets by id from a directory of `<preset_id>.json` files. The directory is always given
/// explicitly; adding a preset means adding a file, with no code change.
/// See docs/caption-configuration.md#adding-a-preset
public struct PresetCatalog: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The ids of the presets in the directory, sorted.
    public func presetIDs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Loads and validates the preset `id`. Its file must exist and its `preset_id` must equal `id`.
    public func preset(id: String) -> ValidationResult<CaptionPreset> {
        guard id.range(of: CaptionPreset.idPattern, options: .regularExpression) != nil,
              let data = try? Data(contentsOf: directory.appendingPathComponent(id + ".json")) else {
            let known = ((try? presetIDs()) ?? []).map { "\"\($0)\"" }.joined(separator: ", ")
            return ValidationResult(value: nil, issues: [
                ValidationIssue(.presetNotFound, at: "", "no preset \"\(id)\" (available: \(known.isEmpty ? "none" : known))"),
            ])
        }
        let result = CaptionPreset.validate(data)
        if let preset = result.value, preset.presetID != id {
            return ValidationResult(value: nil, issues: result.issues + [
                ValidationIssue(.presetIDMismatch, at: "/preset_id", "file \(id).json declares preset_id \"\(preset.presetID)\""),
            ])
        }
        return result
    }
}
