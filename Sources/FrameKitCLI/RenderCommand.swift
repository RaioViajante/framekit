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

    /// Moves a finished frame into the output directory, refusing an existing destination. Replaceable so
    /// tests can make the last step fail.
    typealias FrameMover = @Sendable (_ from: URL, _ to: URL) throws -> Void

    static let moveFrame: FrameMover = { from, to in try FileManager.default.moveItem(at: from, to: to) }

    /// The most frames one run renders: an hour at 240 fps is 864,000 frames, and a million frames of
    /// 1080×1916 are tens of gigabytes of PNG and hours of rendering. A larger request is almost always a
    /// mistake (a cue in the wrong unit, a range with a digit too many); longer videos render in parts.
    static let maxFrames = 1_000_000

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
            // A value starting with "-" must be given as --name=value: as a separate argument it is taken
            // for a forgotten value followed by the next option.
            if inline == nil, let next = rest.first, next.hasPrefix("-") {
                throw Failure(.usage, "\(name) needs a value (write \(name)=\(next) for a value starting with \"-\")")
            }
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
        guard b - a < maxFrames else {
            throw Failure(.usage, "--frames \(text) is \(b - a + 1) frames; at most \(maxFrames) are rendered in one run: render a longer video in parts")
        }
        return a...b
    }

    func run(_ output: Output, interruption: Interruption = Interruption(), writer: FrameWriter = Self.writeFrame,
             mover: FrameMover = Self.moveFrame) throws -> CLI.Exit {
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
        let indices = frames.map { $0.lowerBound..<($0.upperBound + 1) } ?? 0..<renderer.frameCount
        guard indices.count <= Self.maxFrames else {
            throw Failure(.invalidDocument, "stopped: the captions run for \(indices.count) frames; at most \(Self.maxFrames) are rendered in one run: render the video in parts with --frames; nothing was written")
        }
        try stopIfInterrupted(interruption)
        // 3. The output directory, then the frames.
        let directory = try OutputDirectory(preparing: out)
        do {
            for index in indices {
                try interruption.check()
                let name = CaptionRenderer.fileName(ofFrame: index)
                try writer(renderer, index, directory.stagingFile(name))
                try directory.didStage(name)
            }
            for index in indices {
                try interruption.check()
                try directory.place(CaptionRenderer.fileName(ofFrame: index), move: mover)
            }
        } catch {
            let left = directory.rollback()
            let kept = left.isEmpty ? "everything framekit wrote was removed"
                : "framekit removed its frames; left in place: \(left.joined(separator: ", "))"
            switch error {
            case let interrupted as Interrupted:
                throw Failure(.signalled(interrupted.signal), "interrupted by signal \(interrupted.signal); \(kept)")
            case let error as CaptionRenderError:
                if case .fontUnavailable = error { throw Failure(.fontsUnavailable, "\(error); \(kept)") }
                throw Failure(.renderFailed, "rendering failed: \(error); \(kept)")
            default:
                throw Failure(.writeFailed, "could not write the frames to \(out.path): \(error.localizedDescription); \(kept)")
            }
        }
        if !directory.finish() {
            output.error("framekit: warning: left \(directory.staging.path): it holds files framekit did not write")
        }
        let range = indices.isEmpty ? "no frame shows a caption" : "frames \(indices.lowerBound)..\(indices.upperBound - 1)"
        let canvas = renderer.preset.canvas
        // The frames are the result: a summary that cannot be written does not change the exit status.
        output.print("framekit: rendered \(indices.count) frame(s), \(range), \(canvas.width)×\(canvas.height) at \(format(canvas.fps)) fps, into \(out.path)")
        return .success
    }

    private func stopIfInterrupted(_ interruption: Interruption) throws {
        do {
            try interruption.check()
        } catch let interrupted as Interrupted {
            throw Failure(.signalled(interrupted.signal), "interrupted by signal \(interrupted.signal); nothing was written")
        }
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

    private func format(_ fps: Double) -> String {
        fps == fps.rounded() && fps < 1e15 ? String(Int(fps)) : String(fps)
    }
}
