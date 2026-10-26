import Foundation
import Testing
@testable import FrameKitCaptions

/// The reusable parts (library, presets, examples, contract documentation) stay independent of any
/// production and of any machine.
@Suite struct Hygiene {
    static let scanned = ["Sources", "captions/presets", "captions/examples", "docs/caption-configuration.md"]

    /// Lowercased fragments that would tie the reusable parts to the reference production or to a
    /// machine. The reference fixtures and their tests are outside the scanned paths on purpose.
    static let forbidden = ["ep001", "raioviajando", "eu tenho um problema", "/users/", "mobile documents",
                            "clouddocs", "icloud", "~/", "file://"]

    func files() throws -> [URL] {
        try Self.scanned.flatMap { path -> [URL] in
            let url = Repo.url(path)
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), "\(path) is missing")
            guard isDir.boolValue else { return [url] }
            let walker = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
            return walker.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }
        }
    }

    @Test func noProductionReferencesOrMachinePaths() throws {
        let files = try files()
        #expect(files.count >= 10)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            for fragment in Self.forbidden {
                #expect(!text.contains(fragment), "\(file.lastPathComponent) contains \"\(fragment)\"")
            }
        }
    }

    @Test func presetsAndExamplesContainNoPaths() throws {
        for file in try files() where file.pathExtension == "json" {
            for string in strings(in: try Repo.json(String(file.path.dropFirst(Repo.root.path.count + 1)))) {
                #expect(!string.hasPrefix("/") && !string.contains(":\\") && !string.contains("../"), "\(file.lastPathComponent): \(string)")
            }
        }
    }

    private func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let s): [s]
        case .array(let a): a.flatMap(strings)
        case .object(let o): o.keys.map { $0 } + o.values.flatMap(strings)
        default: []
        }
    }
}
