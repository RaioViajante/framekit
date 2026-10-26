import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FrameKitCLI
import FrameKitCaptions

/// The `framekit` executable, run as a separate process the way a person runs it.
@Suite struct FramekitCommand {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let preset = repo.appendingPathComponent("captions/presets/kinetic-minimal.json").path
    static let sample = repo.appendingPathComponent("captions/examples/overlapping-cues.input.json").path

    /// A fresh directory for one test, removed afterwards by the caller.
    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("framekit-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }

    static func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// kinetic-minimal with fields changed, written to `dir` as `<name>.json`.
    static func preset(_ changes: [(String, String)], in dir: URL, name: String = "changed") throws -> String {
        var text = try String(contentsOfFile: preset, encoding: .utf8)
        for (old, new) in changes {
            try #require(text.contains(old), "kinetic-minimal.json has no \(old)")
            text = text.replacingOccurrences(of: old, with: new)
        }
        let file = dir.appendingPathComponent("\(name).json")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    // MARK: help and version

    @Test func versionAndHelp() throws {
        #expect(try framekit("--version") == .init(status: 0, out: "framekit \(CLI.version)\n", err: ""))
        for args in [["--help"], ["-h"]] {
            let r = try framekit(args)
            #expect(r.status == 0 && r.out.contains("Usage: framekit <command>") && r.out.contains("captions") && r.err.isEmpty)
        }
        let captions = try framekit("captions", "--help")
        #expect(captions.status == 0 && captions.out.contains("Usage: framekit captions <command>") && captions.out.contains("render"))
        let render = try framekit("captions", "render", "--help")
        #expect(render.status == 0 && render.err.isEmpty)
        for option in ["--preset FILE", "--input FILE", "--out DIR", "--frames A..B", "Exit status"] { #expect(render.out.contains(option)) }
        // Help wins over everything else on the render line.
        #expect(try framekit("captions", "render", "--out", "x", "--help").status == 0)
    }

    @Test func missingAndUnknownCommandsAreUsageErrors() throws {
        let bare = try framekit([])
        #expect(bare.status == 64 && bare.out.isEmpty && bare.err.contains("Usage: framekit <command>"))
        let group = try framekit("captions")
        #expect(group.status == 64 && group.err.contains("Usage: framekit captions <command>"))
        #expect(try framekit("render") == .init(status: 64, out: "", err: "framekit: unknown command \"render\"\nRun \"framekit --help\" for usage.\n"))
        #expect(try framekit("--bogus").err.hasPrefix("framekit: unknown option \"--bogus\""))
        #expect(try framekit("captions", "draw") == .init(status: 64, out: "",
                                                          err: "framekit: unknown command \"captions draw\"\nRun \"framekit captions --help\" for usage.\n"))
        #expect(try framekit("--version", "now").status == 64)
    }

    @Test(arguments: [
        (["--preset", "p", "--input", "i", "--out", "o", "--bogus"], "unknown option \"--bogus\""),
        (["--preset", "p", "--input", "i", "--out", "o", "--bogus=1"], "unknown option \"--bogus\""),
        (["--preset", "p", "--input", "i", "--out", "o", "extra"], "unexpected argument \"extra\""),
        (["--preset", "p", "--preset", "q", "--input", "i", "--out", "o"], "--preset is given twice"),
        (["--preset", "--input", "i", "--out", "o"], "--preset needs a value"),
        (["--preset=", "--input", "i", "--out", "o"], "--preset needs a value"),
        (["--input", "i", "--out", "o", "--preset"], "--preset needs a value"),
        (["--input", "i", "--out", "o"], "missing --preset"),
        (["--preset", "p", "--out", "o"], "missing --input"),
        (["--preset", "p", "--input", "i"], "missing --out"),
    ])
    func malformedRenderLinesAreUsageErrors(arguments: [String], message: String) throws {
        let r = try framekit(["captions", "render"] + arguments)
        #expect(r == .init(status: 64, out: "", err: "framekit: \(message)\nRun \"framekit captions render --help\" for usage.\n"))
    }

    // MARK: rendering

    @Test func rendersTheSampleIntoTransparentFramesOfTheCanvasSize() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        let r = try framekit("captions", "render", "--preset", Self.preset, "--input", Self.sample, "--out", out.path)
        let library = try CaptionRenderer(input: CaptionInput.load(contentsOf: URL(fileURLWithPath: Self.sample)),
                                          preset: CaptionPreset.load(contentsOf: URL(fileURLWithPath: Self.preset)))
        let count = library.frameCount
        #expect(r == .init(status: 0, out: "framekit: rendered \(count) frame(s), frames 0..\(count - 1), 1080×1916 at 24 fps, into \(out.path)\n", err: ""))
        // Every frame up to the last one inside a cue's window, named as the library names them, and nothing else.
        #expect(Self.files(out) == (0..<count).map(CaptionRenderer.fileName(ofFrame:)))
        for index in [0, 10, 30, count - 1] {
            let data = try Data(contentsOf: out.appendingPathComponent(CaptionRenderer.fileName(ofFrame: index)))
            #expect(data == (try library.png(of: library.frame(index))), "frame \(index) differs from the library's")
            let image = try Image(png: data)
            #expect(image.width == 1080 && image.height == 1916 && image.isRGBA)
            #expect(image.hasInk == library.frame(index).items.contains { $0.alpha > 0.002 }, "frame \(index)")
        }
        #expect(try !Image(png: Data(contentsOf: out.appendingPathComponent("0000.png"))).hasInk)  // before the first cue
    }

    @Test func framesAreAnInclusiveRange() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        func render(_ range: String) throws -> [String] {
            let out = dir.appendingPathComponent("r\(range)")
            let r = try framekit("captions", "render", "--preset", Self.preset, "--input", Self.sample, "--out", out.path, "--frames", range)
            #expect(r.status == 0, "\(r.err)")
            return Self.files(out)
        }
        #expect(try render("5..7") == ["0005.png", "0006.png", "0007.png"])
        #expect(try render("12..12") == ["0012.png"])
        #expect(try render("0..1") == ["0000.png", "0001.png"])
        // Past the last caption: transparent frames, still written (to fill a longer video).
        #expect(try render("500..501") == ["0500.png", "0501.png"])
        #expect(try !Image(png: Data(contentsOf: dir.appendingPathComponent("r500..501/0501.png"))).hasInk)
        // --frames=A..B works too.
        let eq = try framekit("captions", "render", "--preset", Self.preset, "--input", Self.sample,
                              "--out", dir.appendingPathComponent("eq").path, "--frames=3..4")
        #expect(eq.status == 0 && Self.files(dir.appendingPathComponent("eq")) == ["0003.png", "0004.png"])
    }

    @Test(arguments: ["7..5", "a..b", "5", "-1..3", "1..", "..3", "1...3", "1..2..3", "+1..3", "1 ..3", "１..3",
                      "99999999999999999999..99999999999999999999", "0..9223372036854775807", ""])
    func malformedFrameRangesAreRefusedBeforeAnythingIsWritten(range: String) throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        let r = try framekit("captions", "render", "--preset", Self.preset, "--input", Self.sample, "--out", out.path, "--frames=\(range)")
        #expect(r.status == 64 && r.out.isEmpty && r.err.hasPrefix("framekit: --frames"), "\(r.err)")
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func otherCanvasSizesAndFrameRates() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = try Self.preset([("\"width\": 1080", "\"width\": 640"), ("\"height\": 1916", "\"height\": 360"), ("\"fps\": 24", "\"fps\": 30"),
                                     ("\"x\": 540", "\"x\": 320"), ("\"baseline_y\": 330", "\"baseline_y\": 200")], in: dir)
        let out = dir.appendingPathComponent("frames")
        let r = try framekit("captions", "render", "--preset", small, "--input", Self.sample, "--out", out.path)
        let library = try CaptionRenderer(input: CaptionInput.load(contentsOf: URL(fileURLWithPath: Self.sample)),
                                          preset: CaptionPreset.load(contentsOf: URL(fileURLWithPath: small)))
        #expect(r.status == 0 && r.out.contains("640×360 at 30 fps"))
        #expect(library.frameCount > 107 && Self.files(out).count == library.frameCount)  // more frames at 30 fps than at 24
        let image = try Image(png: Data(contentsOf: out.appendingPathComponent("0040.png")))
        #expect(image.width == 640 && image.height == 360 && image.hasInk)
    }

    // MARK: documents and fonts

    @Test func invalidDocumentsStopBeforeAnythingIsWritten() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        let badPreset = try Self.preset([("\"size\": 54", "\"size\": -54")], in: dir, name: "bad")
        var r = try framekit("captions", "render", "--preset", badPreset, "--input", Self.sample, "--out", out.path)
        #expect(r == .init(status: 65, out: "", err: """
            \(badPreset): error value.out_of_range at /text/size: -54.0 is out of range (greater than 0)
            framekit: stopped: 1 error(s) in the documents; nothing was written

            """))
        let badInput = dir.appendingPathComponent("bad.input.json")
        try Data("{\"schema_version\": 1, \"language\": \"en\", \"words\": [], \"cues\": [],}".utf8).write(to: badInput)
        r = try framekit("captions", "render", "--preset", Self.preset, "--input", badInput.path, "--out", out.path)
        #expect(r.status == 65 && r.err.hasPrefix("\(badInput.path): error json.malformed at (document): not valid JSON"))
        // Valid alone, but three lines where kinetic-minimal allows two; and an unused word is only a warning.
        try Data("""
            {"schema_version": 1, "language": "en",
             "words": [{"id": "a", "text": "One", "start": 1, "end": 1.2}, {"id": "b", "text": "two", "start": 1.3, "end": 1.5},
                       {"id": "c", "text": "three", "start": 1.6, "end": 1.8}, {"id": "d", "text": "four", "start": 2, "end": 2.2}],
             "cues": [{"id": "c1", "lines": [["a"], ["b"], ["c"]]}]}
            """.utf8).write(to: badInput)
        r = try framekit("captions", "render", "--preset", Self.preset, "--input", badInput.path, "--out", out.path)
        #expect(r == .init(status: 65, out: "", err: """
            \(badInput.path): warning word.unused at /words/3: word "d" is not in any cue and will not be shown
            \(badInput.path): error cue.too_many_lines at /cues/0/lines: cue "c1" has 3 lines; preset "kinetic-minimal" allows 2
            framekit: stopped: the caption input does not fit preset "kinetic-minimal"; nothing was written

            """))
        r = try framekit("captions", "render", "--preset", dir.appendingPathComponent("none.json").path, "--input", Self.sample, "--out", out.path)
        #expect(r.status == 66 && r.err.hasPrefix("framekit: cannot read \(dir.appendingPathComponent("none.json").path)"))
        r = try framekit("captions", "render", "--preset", Self.preset, "--input", dir.path, "--out", out.path)  // a directory
        #expect(r.status == 66)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func missingFontsStopBeforeAnythingIsWritten() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = "FrameKitTestMissingFont-Regular"
        let preset = try Self.preset([("\"AvenirNext-Medium\"", "\"\(missing)\"")], in: dir)
        let out = dir.appendingPathComponent("frames")
        let r = try framekit("captions", "render", "--preset", preset, "--input", Self.sample, "--out", out.path)
        #expect(r == .init(status: 69, out: "", err: """
            \(preset): error font.unavailable at /required_fonts/0: font "\(missing)" is not installed; install it or choose another font in the preset
            framekit: stopped: 1 font(s) of the preset are not installed; nothing was written

            """))
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: output safety

    @Test func nothingIsOverwritten() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        func render(_ out: URL) throws -> Run {
            try framekit("captions", "render", "--preset", Self.preset, "--input", Self.sample, "--out", out.path, "--frames", "0..1")
        }
        // Not empty, even with one hidden file: refused, contents untouched.
        let used = dir.appendingPathComponent("used")
        try FileManager.default.createDirectory(at: used, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: used.appendingPathComponent(".keep"))
        var r = try render(used)
        #expect(r.status == 73 && r.err.contains("is not empty (1 item(s), hidden ones included)"))
        #expect(Self.files(used) == [".keep"] && (try? String(contentsOf: used.appendingPathComponent(".keep"), encoding: .utf8)) == "keep")
        // A second render into a finished output is refused too.
        let done = dir.appendingPathComponent("done")
        #expect(try render(done).status == 0)
        let before = try Data(contentsOf: done.appendingPathComponent("0000.png"))
        #expect(try render(done).status == 73)
        #expect(try Data(contentsOf: done.appendingPathComponent("0000.png")) == before)
        // A file, or a missing parent: refused, nothing created.
        let file = dir.appendingPathComponent("file")
        try Data().write(to: file)
        r = try render(file)
        #expect(r.status == 73 && r.err.contains("is a file"))
        r = try render(dir.appendingPathComponent("no/such/place"))
        #expect(r.status == 73 && r.err.contains("does not exist"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("no").path))
        // An existing empty directory is used, and stays.
        let empty = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        #expect(try render(empty).status == 0 && Self.files(empty) == ["0000.png", "0001.png"])
    }

    @Test func aFailurePartWayLeavesTheOutputAsItWas() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let failing: RenderCommand.FrameWriter = { renderer, index, file in
            if index == 3 { throw CocoaError(.fileWriteOutOfSpace) }
            try RenderCommand.writeFrame(renderer, index, file)
        }
        let quiet = Output(print: { _ in }, error: { _ in })
        // A directory this run creates is removed again.
        let created = dir.appendingPathComponent("created")
        var command = try RenderCommand(arguments: ["--preset", Self.preset, "--input", Self.sample, "--out", created.path, "--frames", "0..9"])
        #expect { try command.run(quiet, writer: failing) } throws: { ($0 as? Failure)?.status == .writeFailed }
        #expect(!FileManager.default.fileExists(atPath: created.path))
        // A directory that existed empty stays, empty.
        let existing = dir.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        command = try RenderCommand(arguments: ["--preset", Self.preset, "--input", Self.sample, "--out", existing.path, "--frames", "0..9"])
        #expect { try command.run(quiet, writer: failing) } throws: { ($0 as? Failure)?.status == .writeFailed }
        #expect(FileManager.default.fileExists(atPath: existing.path) && Self.files(existing).isEmpty)
        // A rendering error is reported as such.
        let broken: RenderCommand.FrameWriter = { _, _, _ in throw CaptionRenderError.imageFailed("draw") }
        #expect { try command.run(quiet, writer: broken) } throws: { ($0 as? Failure)?.status == .renderFailed }
        #expect(Self.files(existing).isEmpty)
    }

    @Test func aKilledRenderLeavesNoFrameInTheOutput() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        let process = try launch(["captions", "render", "--preset", Self.preset, "--input", Self.sample, "--out", out.path, "--frames", "0..100000"])
        // Wait until frames are being written, then kill it.
        let deadline = Date().addingTimeInterval(60)
        func staged() -> Int {
            Self.files(out).filter { $0.hasPrefix(".framekit-partial-") }
                .reduce(0) { $0 + Self.files(out.appendingPathComponent($1)).count }
        }
        while staged() < 3 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        // Only the hidden work folder is there: no frame that could pass for a finished render.
        let left = Self.files(out)
        #expect(left.count == 1 && left[0].hasPrefix(".framekit-partial-"), "\(left)")
        #expect(!left.contains { $0.hasSuffix(".png") })
    }
}

// MARK: running the executable

struct Run: Equatable {
    let status: Int32
    let out: String
    let err: String
}

/// The `framekit` binary built next to this test bundle.
let framekitBinary: URL = {
    var info = Dl_info()
    dladdr(#dsohandle, &info)
    var url = URL(fileURLWithPath: String(cString: info.dli_fname))
    while url.pathExtension != "xctest" && url.path != "/" { url.deleteLastPathComponent() }
    return url.deletingLastPathComponent().appendingPathComponent("framekit")
}()

func launch(_ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = framekitBinary
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

func framekit(_ arguments: String...) throws -> Run { try framekit(arguments) }

func framekit(_ arguments: [String]) throws -> Run {
    let process = Process()
    process.executableURL = framekitBinary
    process.arguments = arguments
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("framekit-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    // Files, not pipes: a child that writes a lot can never block on a full pipe.
    let out = dir.appendingPathComponent("out"), err = dir.appendingPathComponent("err")
    FileManager.default.createFile(atPath: out.path, contents: nil)
    FileManager.default.createFile(atPath: err.path, contents: nil)
    process.standardOutput = try FileHandle(forWritingTo: out)
    process.standardError = try FileHandle(forWritingTo: err)
    try process.run()
    process.waitUntilExit()
    return Run(status: process.terminationStatus, out: try String(contentsOf: out, encoding: .utf8), err: try String(contentsOf: err, encoding: .utf8))
}

/// A decoded PNG, as stored.
struct Image {
    let width: Int
    let height: Int
    let isRGBA: Bool
    let hasInk: Bool

    init(png: Data) throws {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        width = image.width
        height = image.height
        isRGBA = image.bitsPerComponent == 8 && image.bitsPerPixel == 32 && image.alphaInfo == .last
        let data = try #require(image.dataProvider?.data) as Data
        hasInk = stride(from: 3, to: data.count, by: 4).contains { data[$0] != 0 }
    }
}
