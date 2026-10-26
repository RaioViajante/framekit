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
        (["--preset", "--input", "i", "--out", "o"], "--preset needs a value (write --preset=--input for a value starting with \"-\")"),
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
        let failing: RenderCommand.FrameRenderer = { renderer, index in
            if index == 3 { throw CocoaError(.fileWriteOutOfSpace) }
            return try RenderCommand.renderFrame(renderer, index)
        }
        let quiet = Output(print: { _ in true }, error: { _ in true })
        // A directory this run creates is removed again.
        let created = dir.appendingPathComponent("created")
        var command = try RenderCommand(arguments: ["--preset", Self.preset, "--input", Self.sample, "--out", created.path, "--frames", "0..9"])
        #expect { try command.run(quiet, render: failing) } throws: { ($0 as? Failure)?.status == .writeFailed }
        #expect(!FileManager.default.fileExists(atPath: created.path))
        // A directory that existed empty stays, empty.
        let existing = dir.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        command = try RenderCommand(arguments: ["--preset", Self.preset, "--input", Self.sample, "--out", existing.path, "--frames", "0..9"])
        #expect { try command.run(quiet, render: failing) } throws: { ($0 as? Failure)?.status == .writeFailed }
        #expect(FileManager.default.fileExists(atPath: existing.path) && Self.files(existing).isEmpty)
        // A rendering error is reported as such.
        let broken: RenderCommand.FrameRenderer = { _, _ in throw CaptionRenderError.imageFailed("draw") }
        #expect { try command.run(quiet, render: broken) } throws: { ($0 as? Failure)?.status == .renderFailed }
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

    // MARK: hardening (review of #40)

    static let quiet = Output(print: { _ in true }, error: { _ in true })

    static func command(_ out: URL, frames: String = "0..9") throws -> RenderCommand {
        try RenderCommand(arguments: ["--preset", preset, "--input", sample, "--out", out.path, "--frames", frames])
    }

    /// F1: a closed standard output, or a reader that went away, loses the text and nothing else.
    @Test func closedOrBrokenStandardStreamsNeverAbort() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let render = ["captions", "render", "--preset", Self.preset, "--input", Self.sample, "--frames", "0..2", "--out"]
        // Closed: the frames are the result, so the render succeeds; help and version are the result, so
        // not being able to write them fails, with status 74.
        var r = try framekit(render + [dir.appendingPathComponent("closed").path], shell: "exec \"$0\" \"$@\" >&-")
        #expect(r.status == 0 && r.err.isEmpty, "\(r)")
        #expect(Self.files(dir.appendingPathComponent("closed")) == ["0000.png", "0001.png", "0002.png"])
        #expect(try framekit("--version", shell: "exec \"$0\" \"$@\" >&-")
                == .init(status: 74, out: "", err: "framekit: cannot write to standard output\n"))
        #expect(try framekit("--help", shell: "exec \"$0\" \"$@\" >&-").status == 74)
        // Broken pipe: the reader (true) has exited long before the summary is written.
        r = try framekit(render + [dir.appendingPathComponent("piped").path], shell: "\"$0\" \"$@\" | true; exit ${PIPESTATUS[0]}")
        #expect(r.status == 0, "\(r)")
        #expect(Self.files(dir.appendingPathComponent("piped")) == ["0000.png", "0001.png", "0002.png"])
        // Closed standard error: the diagnostic is lost, the status is still right.
        #expect(try framekit("captions", "render", "--bogus", shell: "exec \"$0\" \"$@\" 2>&-").status == 64)
        // And the frames written while standard output was closed are exactly the library's.
        let library = try CaptionRenderer(input: CaptionInput.load(contentsOf: URL(fileURLWithPath: Self.sample)),
                                          preset: CaptionPreset.load(contentsOf: URL(fileURLWithPath: Self.preset)))
        for index in 0...2 {
            let file = dir.appendingPathComponent("closed").appendingPathComponent(CaptionRenderer.fileName(ofFrame: index))
            #expect(try Data(contentsOf: file) == library.png(of: library.frame(index)))
        }
    }

    /// F3: files another process puts in the output directory during a render are never removed, and the
    /// directory is not removed while it holds them. The other process is simulated at a fixed point.
    @Test(arguments: [false, true])
    func rollbackNeverRemovesFilesFramekitDidNotWrite(directoryExisted: Bool) throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        if directoryExisted { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false) }
        let foreign: RenderCommand.FrameRenderer = { renderer, index in
            if index == 3 {
                try Data("theirs".utf8).write(to: out.appendingPathComponent("notes.txt"))
                try Data("theirs".utf8).write(to: out.appendingPathComponent("0007.png"))  // collides with frame 7
            }
            return try RenderCommand.renderFrame(renderer, index)
        }
        // Moving frame 7 fails (a real failure: the destination exists), so frames 0 to 6, already in
        // place, are rolled back.
        #expect { try Self.command(out).run(Self.quiet, render: foreign) } throws: { error in
            guard let failure = error as? Failure else { return false }
            let message = directoryExisted ? "everything framekit wrote was removed"  // the directory is not framekit's
                : "framekit removed everything it wrote; kept \(out.path): it holds files framekit did not write, which were not touched"
            return failure.status == .writeFailed && failure.message.hasSuffix(message)
        }
        #expect(Self.files(out) == ["0007.png", "notes.txt"])
        for name in ["0007.png", "notes.txt"] {
            #expect(try String(contentsOf: out.appendingPathComponent(name), encoding: .utf8) == "theirs")
        }
    }

    /// F3: a frame of ours that another process replaced is theirs now, and stays.
    @Test func aReplacedFrameIsNotRemoved() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        let mover: RenderCommand.FrameMover = { from, to in
            if to.lastPathComponent == "0003.png" {
                let ours = out.appendingPathComponent("0001.png")
                try FileManager.default.removeItem(at: ours)
                try Data("theirs".utf8).write(to: ours)
                throw CocoaError(.fileWriteVolumeReadOnly)
            }
            try RenderCommand.moveFrame(from, to)
        }
        #expect { try Self.command(out).run(Self.quiet, mover: mover) } throws: { ($0 as? Failure)?.status == .writeFailed }
        #expect(Self.files(out) == ["0001.png"])
        #expect(try String(contentsOf: out.appendingPathComponent("0001.png"), encoding: .utf8) == "theirs")
    }

    /// F5: a failure while moving finished frames into place undoes the moves and reports the failure.
    @Test(arguments: [false, true])
    func aFailureWhileMovingFramesIntoPlaceIsUndone(directoryExisted: Bool) throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        if directoryExisted { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false) }
        let unrelated = dir.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        let moves = Counter()
        let mover: RenderCommand.FrameMover = { from, to in
            if moves.next() == 3 { throw CocoaError(.fileWriteOutOfSpace) }
            try RenderCommand.moveFrame(from, to)
        }
        let printed = Counter()
        let output = Output(print: { _ in _ = printed.next(); return true }, error: { _ in true })
        #expect { try Self.command(out).run(output, mover: mover) } throws: { error in
            guard let failure = error as? Failure else { return false }
            return failure.status == .writeFailed && failure.message.hasSuffix("everything framekit wrote was removed")
        }
        #expect(moves.value == 3)  // two frames were in place when the third move failed
        #expect(printed.value == 0)  // no success line
        #expect(FileManager.default.fileExists(atPath: out.path) == directoryExisted)
        #expect(Self.files(out).isEmpty)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep")
    }

    /// F2: Ctrl-C and SIGTERM stop the render and clean up; only SIGKILL cannot (see the test above).
    @Test(arguments: [(SIGINT, Int32(130), false), (SIGTERM, Int32(143), true), (SIGHUP, Int32(129), false)])
    func anInterruptedRenderCleansUp(signal: Int32, status: Int32, directoryExisted: Bool) throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        if directoryExisted { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false) }
        let process = try launch(["captions", "render", "--preset", Self.preset, "--input", Self.sample, "--out", out.path, "--frames", "0..100000"])
        let deadline = Date().addingTimeInterval(60)
        func staged() -> Int {
            Self.files(out).filter { $0.hasPrefix(".framekit-partial-") }
                .reduce(0) { $0 + Self.files(out.appendingPathComponent($1)).count }
        }
        while staged() < 3 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        kill(process.processIdentifier, signal)
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == status)
        #expect(FileManager.default.fileExists(atPath: out.path) == directoryExisted)
        #expect(Self.files(out).isEmpty)
    }

    /// F4: at most a million frames per run, whatever their numbers.
    @Test func impracticallyLargeRendersAreRefused() throws {
        #expect(try RenderCommand.frameRange("0..999999").count == RenderCommand.maxFrames)
        #expect(try RenderCommand.frameRange("5000000..5999999").count == RenderCommand.maxFrames)
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        var r = try framekit(["captions", "render", "--preset", Self.preset, "--input", Self.sample, "--out", out.path, "--frames", "0..1000000"],
                             timeLimit: 30)
        #expect(r.status == 64 && r.err.hasPrefix("framekit: --frames 0..1000000 is 1000001 frames; at most 1000000 are rendered in one run"))
        #expect(!FileManager.default.fileExists(atPath: out.path))
        // Large frame numbers are fine.
        r = try framekit("captions", "render", "--preset", Self.preset, "--input", Self.sample, "--out", out.path, "--frames", "2000000..2000001")
        #expect(r.status == 0 && Self.files(out) == ["2000000.png", "2000001.png"])
        // So is a cue late in the video, but not one whose frames would exceed the limit by default.
        let late = dir.appendingPathComponent("late.input.json")
        try Data("""
            {"schema_version": 1, "language": "en", "words": [{"id": "a", "text": "Late", "start": 50000, "end": 50001}],
             "cues": [{"id": "c1", "lines": [["a"]]}]}
            """.utf8).write(to: late)
        let lateOut = dir.appendingPathComponent("late")
        r = try framekit(["captions", "render", "--preset", Self.preset, "--input", late.path, "--out", lateOut.path], timeLimit: 30)
        #expect(r.status == 65 && r.err.contains("the captions run for 1200029 frames; at most 1000000"), "\(r.err)")
        #expect(!FileManager.default.fileExists(atPath: lateOut.path))
        r = try framekit("captions", "render", "--preset", Self.preset, "--input", late.path, "--out", lateOut.path, "--frames", "1200000..1200001")
        #expect(r.status == 0 && Self.files(lateOut) == ["1200000.png", "1200001.png"])
    }

    /// F6: a value starting with "-" is taken only when joined with "=".
    @Test func valuesStartingWithAHyphenNeedEquals() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let render = ["captions", "render", "--preset", Self.preset, "--input", Self.sample, "--frames", "0..0"]
        var r = try framekit(render + ["--out", "-x"], in: dir)
        #expect(r.status == 64 && r.err.hasPrefix("framekit: --out needs a value (write --out=-x for a value starting with \"-\")"))
        #expect(Self.files(dir).isEmpty)
        r = try framekit(render + ["--out=-x"], in: dir)
        #expect(r.status == 0, "\(r)")
        #expect(Self.files(dir.appendingPathComponent("-x")) == ["0000.png"])
    }

    // MARK: final safety fixes (second review of #40)

    /// M1: a frame whose bytes were only partly written is framekit's and is removed, with the staging
    /// folder and a directory this run created; the directory can then be rendered into again.
    @Test(arguments: [false, true])
    func aPartlyWrittenFrameIsRemoved(directoryExisted: Bool) throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        if directoryExisted { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false) }
        let partial: RenderCommand.BytesWriter = { fd, bytes in
            if bytes.isEmpty { return }
            let half = bytes.prefix(bytes.count / 2)
            try RenderCommand.writeBytes(fd, Data(half))
            if Self.files(out).first(where: { $0.hasPrefix(".framekit-partial-") }).map({ Self.files(out.appendingPathComponent($0)).count }) == 4 {
                throw CocoaError(.fileWriteOutOfSpace)  // the fourth frame is half written
            }
            try RenderCommand.writeBytes(fd, Data(bytes.dropFirst(half.count)))
        }
        #expect { try Self.command(out).run(Self.quiet, write: partial) } throws: { error in
            guard let failure = error as? Failure else { return false }
            return failure.status == .writeFailed && failure.message.hasSuffix("everything framekit wrote was removed")
        }
        #expect(FileManager.default.fileExists(atPath: out.path) == directoryExisted)
        #expect(Self.files(out).isEmpty)
        // Clean enough to render into again.
        #expect(try Self.command(out).run(Self.quiet) == .success)
        #expect(Self.files(out) == (0...9).map(CaptionRenderer.fileName(ofFrame:)))
    }

    /// M1, with a real partial write: a file-size limit stops the first frame part-way (EFBIG).
    @Test func aRealPartialWriteIsCleanedUp() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        let render = ["captions", "render", "--preset", Self.preset, "--input", Self.sample, "--frames", "0..2", "--out", out.path]
        // 20 KiB per file; every frame of this canvas is larger.
        var r = try framekit(render, shell: "trap '' XFSZ; ulimit -f 20; exec \"$0\" \"$@\"")
        #expect(r.status == 74 && r.err.contains("File too large") && r.err.hasSuffix("everything framekit wrote was removed\n"), "\(r)")
        #expect(!FileManager.default.fileExists(atPath: out.path))
        r = try framekit(render)
        #expect(r.status == 0 && Self.files(out) == ["0000.png", "0001.png", "0002.png"])
    }

    /// M2: a destination that appears after the frames were prepared and before the move is never
    /// overwritten: the atomic rename refuses it, and only this run's frames are rolled back.
    @Test func aDestinationThatAppearsAtTheLastMomentIsNotOverwritten() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        let racing: RenderCommand.FrameMover = { from, to in
            if to.lastPathComponent == "0004.png" { try Data("theirs".utf8).write(to: to) }  // another process, just in time
            try RenderCommand.moveFrame(from, to)
        }
        #expect { try Self.command(out).run(Self.quiet, mover: racing) } throws: { error in
            guard let failure = error as? Failure else { return false }
            return failure.status == .writeFailed && failure.message.contains("0004.png: File exists")
                && failure.message.hasSuffix("kept \(out.path): it holds files framekit did not write, which were not touched")
        }
        #expect(Self.files(out) == ["0004.png"])
        #expect(try String(contentsOf: out.appendingPathComponent("0004.png"), encoding: .utf8) == "theirs")
    }

    @Test func theFinalMoveNeverReplacesAFile() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let from = dir.appendingPathComponent("ours"), to = dir.appendingPathComponent("theirs")
        try Data("ours".utf8).write(to: from)
        try Data("theirs".utf8).write(to: to)
        #expect(throws: FileError.self) { try RenderCommand.moveFrame(from, to) }
        #expect(try String(contentsOf: to, encoding: .utf8) == "theirs")
        #expect(try String(contentsOf: from, encoding: .utf8) == "ours")
        try FileManager.default.removeItem(at: to)
        try RenderCommand.moveFrame(from, to)  // and moves when the destination is free
        #expect(try String(contentsOf: to, encoding: .utf8) == "ours" && !FileManager.default.fileExists(atPath: from.path))
    }

    /// M2, under a real race: another thread creates the destination exclusively at the same time as the
    /// move. Exactly one of them may win; both succeeding would mean their file was overwritten. This holds
    /// in every round for an atomic no-replace rename, so the test cannot fail by chance; a check-then-
    /// rename (FileManager.moveItem) loses most rounds.
    @Test func theFinalMoveAndAConcurrentCreatorNeverBothWin() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var bothWon = 0
        for round in 0..<300 {
            let from = dir.appendingPathComponent("ours-\(round)"), to = dir.appendingPathComponent("frame-\(round)")
            try Data("ours".utf8).write(to: from)
            let start = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let theirs = Counter()
            Thread.detachNewThread {
                start.wait()
                let fd = open(to.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                if fd >= 0 { _ = theirs.next(); close(fd) }
                done.signal()
            }
            start.signal()
            let oursWon = (try? RenderCommand.moveFrame(from, to)) != nil
            done.wait()
            if oursWon && theirs.value == 1 { bothWon += 1 }
        }
        #expect(bothWon == 0, "in \(bothWon) of 300 rounds the move replaced a file created at the same time")
    }

    /// M3: the frame limit is enforced before anything is drawn, without rendering huge ranges.
    @Test func theFrameLimitIsCheckedBeforeRendering() throws {
        let limit = RenderCommand.maxFrames
        #expect(try RenderCommand.plannedFrames(nil, frameCount: limit) == 0..<limit)
        #expect(try RenderCommand.plannedFrames(7...(7 + limit - 1), frameCount: 3).count == limit)
        #expect { try RenderCommand.plannedFrames(nil, frameCount: limit + 1) } throws: { ($0 as? Failure)?.status == .invalidDocument }
        #expect { try RenderCommand.plannedFrames(0...limit, frameCount: 3) } throws: { ($0 as? Failure)?.status == .usage }
        #expect { try RenderCommand.frameRange("0..\(limit)") } throws: { ($0 as? Failure)?.status == .usage }
    }

    /// M3: interrupted while finished frames are being moved into place: undone like any failure.
    @Test(arguments: [false, true])
    func anInterruptionWhileMovingFramesIntoPlaceIsUndone(directoryExisted: Bool) throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("frames")
        if directoryExisted { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false) }
        let interruption = Interruption()
        let moves = Counter()
        let mover: RenderCommand.FrameMover = { from, to in
            try RenderCommand.moveFrame(from, to)
            if moves.next() == 2 { interruption.receive(SIGINT) }  // Ctrl-C after the second frame is in place
        }
        #expect { try Self.command(out).run(Self.quiet, interruption: interruption, mover: mover) } throws: { error in
            guard let failure = error as? Failure else { return false }
            return failure.status == .interrupted && failure.message == "interrupted by signal 2; everything framekit wrote was removed"
        }
        #expect(moves.value == 2)
        #expect(FileManager.default.fileExists(atPath: out.path) == directoryExisted)
        #expect(Self.files(out).isEmpty)
    }

    /// M3: a standard stream closed at start is held by /dev/null, so a file opened later cannot take its
    /// number and receive text meant for it.
    @Test func aStreamClosedAtStartIsNotReusedByAFile() async {
        await #expect(processExitsWith: .success) {
            close(STDOUT_FILENO)
            let output = Output.standard()
            let path = NSTemporaryDirectory() + "framekit-fd-\(getpid())"
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            defer { unlink(path) }
            guard fd >= 0, fd != STDOUT_FILENO else { exit(2) }
            guard !output.print("meant for standard output") else { exit(3) }
            close(fd)
            guard let data = FileManager.default.contents(atPath: path), data.isEmpty else { exit(4) }
        }
    }
}

/// Counts calls from a `@Sendable` closure.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
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

func framekit(_ arguments: String..., shell: String? = nil) throws -> Run { try framekit(arguments, shell: shell) }

struct TimedOut: Error, CustomStringConvertible {
    let arguments: [String]
    var description: String { "framekit \(arguments.joined(separator: " ")) was still running after its time limit and was killed" }
}

/// Runs `framekit` with `arguments`, from `directory` if given, or through a bash `shell` line in which
/// `$0` is the binary and `$@` the arguments (to close or redirect its streams).
func framekit(_ arguments: [String], in directory: URL? = nil, shell: String? = nil, timeLimit: TimeInterval = 120) throws -> Run {
    let process = Process()
    if let shell {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", shell, framekitBinary.path] + arguments
    } else {
        process.executableURL = framekitBinary
        process.arguments = arguments
    }
    process.currentDirectoryURL = directory
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
    // A regression that makes a command run away (say, a lost frame limit) fails the test instead of
    // stalling the suite.
    let deadline = Date().addingTimeInterval(timeLimit)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        throw TimedOut(arguments: arguments)
    }
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
