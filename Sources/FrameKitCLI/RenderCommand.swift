import Foundation
import FrameKitCaptions

/// `framekit captions render`: every check first, then the frames, written so that a failure never
/// leaves frames that look like a finished render. Reference: docs/cli.md#framekit-captions-render
struct RenderCommand {
    let preset: URL
    let input: URL
    let out: URL
    /// Inclusive, as given with `--frames A..B`.
    let frames: ClosedRange<Int>?

    /// Writes one frame's PNG to a file. Replaceable so tests can make writing fail part-way.
    typealias FrameWriter = @Sendable (_ renderer: CaptionRenderer, _ index: Int, _ file: URL) throws -> Void

    static let writeFrame: FrameWriter = { renderer, index, file in
        try renderer.png(of: renderer.frame(index)).write(to: file, options: .withoutOverwriting)
    }

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            // --name value, or --name=value
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0], inline = parts.count > 1 ? parts[1] : nil
            guard ["--preset", "--input", "--out", "--frames"].contains(name) else {
                throw Failure(.usage, argument.hasPrefix("-") ? "unknown option \"\(name)\"" : "unexpected argument \"\(argument)\"")
            }
            guard values[name] == nil else { throw Failure(.usage, "\(name) is given twice") }
            if inline == nil, let next = rest.first, next.hasPrefix("-") { throw Failure(.usage, "\(name) needs a value") }
            guard let value = inline ?? rest.popFirst(), !value.isEmpty else { throw Failure(.usage, "\(name) needs a value") }
            values[name] = value
        }
        for name in ["--preset", "--input", "--out"] where values[name] == nil {
            throw Failure(.usage, "missing \(name)")
        }
        preset = URL(fileURLWithPath: values["--preset"]!)
        input = URL(fileURLWithPath: values["--input"]!)
        out = URL(fileURLWithPath: values["--out"]!)
        frames = try values["--frames"].map(Self.frameRange)
    }

    /// `A..B` with A and B frame numbers (decimal digits only) and A <= B.
    static func frameRange(_ text: String) throws -> ClosedRange<Int> {
        let parts = text.components(separatedBy: "..")
        func number(_ s: String) -> Int? {
            s.isEmpty || !s.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : Int(s)
        }
        guard parts.count == 2, let a = number(parts[0]), let b = number(parts[1]) else {
            throw Failure(.usage, "--frames \"\(text)\" is not A..B with A and B frame numbers, such as 0..47")
        }
        guard a <= b else { throw Failure(.usage, "--frames \(text): the first frame is after the last") }
        guard b < Int.max else { throw Failure(.usage, "--frames \(text): the last frame is too large") }
        return a...b
    }

    func run(_ output: Output, writer: FrameWriter = Self.writeFrame) throws -> CLI.Exit {
        // 1. Documents, alone and together. Every issue is reported before stopping.
        let presetResult = CaptionPreset.validate(try read(preset))
        let inputResult = CaptionInput.validate(try read(input))
        var errors = report(presetResult.issues, in: preset, output) + report(inputResult.issues, in: input, output)
        guard let look = presetResult.value, let captions = inputResult.value, errors == 0 else {
            throw Failure(.invalidDocument, "stopped: \(max(errors, 1)) error(s) in the documents; nothing was written")
        }
        errors = report(captions.validate(against: look), in: input, output)
        guard errors == 0 else {
            throw Failure(.invalidDocument, "stopped: the caption input does not fit preset \"\(look.presetID)\"; nothing was written")
        }
        // 2. Fonts: never substituted.
        let missing = FontAvailability.check(look)
        guard report(missing, in: preset, output) == 0 else {
            throw Failure(.fontsUnavailable, "stopped: \(missing.count) font(s) of the preset are not installed; nothing was written")
        }
        let renderer: CaptionRenderer
        do {
            renderer = try CaptionRenderer(input: captions, preset: look)
        } catch let error as CaptionRenderError {
            throw Failure(.invalidDocument, "stopped: \(error); nothing was written")
        }
        // 3. The output directory, then the frames.
        let indices = frames.map { $0.lowerBound..<($0.upperBound + 1) } ?? 0..<renderer.frameCount
        let created = try prepareOutput()
        let staging = out.appendingPathComponent(".framekit-partial-\(UUID().uuidString)")
        var moved: [URL] = []
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            for index in indices {
                try writer(renderer, index, staging.appendingPathComponent(CaptionRenderer.fileName(ofFrame: index)))
            }
            for index in indices {
                let name = CaptionRenderer.fileName(ofFrame: index)
                let destination = out.appendingPathComponent(name)
                try FileManager.default.moveItem(at: staging.appendingPathComponent(name), to: destination)
                moved.append(destination)
            }
            try FileManager.default.removeItem(at: staging)
        } catch {
            // Leave DIR as it was: no frame, no hidden folder, and no DIR if this run created it.
            for file in moved { try? FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: staging)
            if created { try? FileManager.default.removeItem(at: out) }
            switch error {
            case let error as CaptionRenderError:
                if case .fontUnavailable = error { throw Failure(.fontsUnavailable, "\(error); nothing was kept") }
                throw Failure(.renderFailed, "rendering failed: \(error); nothing was kept")
            default:
                throw Failure(.writeFailed, "could not write the frames to \(out.path): \(error.localizedDescription); nothing was kept")
            }
        }
        let range = indices.isEmpty ? "no frame shows a caption" : "frames \(indices.lowerBound)..\(indices.upperBound - 1)"
        let canvas = renderer.preset.canvas
        output.print("framekit: rendered \(indices.count) frame(s), \(range), \(canvas.width)×\(canvas.height) at \(format(canvas.fps)) fps, into \(out.path)")
        return .success
    }

    private func read(_ file: URL) throws -> Data {
        do {
            return try Data(contentsOf: file)
        } catch {
            throw Failure(.unreadable, "cannot read \(file.path): \(error.localizedDescription)")
        }
    }

    /// Prints each issue with its file, code and JSON Pointer; returns how many are errors.
    private func report(_ issues: [ValidationIssue], in file: URL, _ output: Output) -> Int {
        for issue in issues { output.error("\(file.path): \(issue)") }
        return issues.filter { $0.severity == .error }.count
    }

    /// DIR must be an empty directory or not exist (its parent must). Returns whether it was created.
    private func prepareOutput() throws -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: out.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw Failure(.outputRefused, "--out \(out.path) is a file, not a directory") }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? ["?"]
            guard contents.isEmpty else {
                throw Failure(.outputRefused, "--out \(out.path) is not empty (\(contents.count) item(s), hidden ones included); nothing is overwritten: choose a new or empty directory")
            }
            return false
        }
        let parent = out.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure(.outputRefused, "the parent of --out, \(parent.path), does not exist")
        }
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        } catch {
            throw Failure(.outputRefused, "cannot create --out \(out.path): \(error.localizedDescription)")
        }
        return true
    }

    private func format(_ fps: Double) -> String {
        fps == fps.rounded() && fps < 1e15 ? String(Int(fps)) : String(fps)
    }
}
