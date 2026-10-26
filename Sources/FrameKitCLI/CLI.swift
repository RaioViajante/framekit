import Foundation
import FrameKitCaptions

/// The `framekit` command line: argument parsing, help, and the commands. Hand-written on purpose
/// (docs/decisions/0001-caption-configuration.md, decision 3). Reference: docs/cli.md
public enum CLI {
    public static let version = "0.1.0-dev"

    /// Exit statuses, from sysexits(3). docs/cli.md#exit-status lists them.
    public enum Exit: Int32, Sendable {
        case success = 0
        /// Unknown command or option, missing or repeated option, malformed frame range.
        case usage = 64
        /// A preset or caption input with errors, alone or together.
        case invalidDocument = 65
        /// A file named on the command line cannot be read.
        case unreadable = 66
        /// A font of the preset is not installed; fonts are never substituted.
        case fontsUnavailable = 69
        /// Rendering failed after every check passed.
        case renderFailed = 70
        /// The output directory is not empty, is a file, or its parent does not exist.
        case outputRefused = 73
        /// Writing the frames failed.
        case writeFailed = 74
    }

    /// Runs the command line `arguments` (without the program name) and returns the exit status.
    public static func run(_ arguments: [String], output: Output = .standard) -> Int32 {
        do {
            return try dispatch(arguments, output).rawValue
        } catch let failure as Failure {
            output.error("framekit: \(failure.message)")
            if failure.status == .usage { output.error("Run \"\(failure.helpCommand) --help\" for usage.") }
            return failure.status.rawValue
        } catch {
            output.error("framekit: \(error)")
            return Exit.renderFailed.rawValue
        }
    }

    private static func dispatch(_ arguments: [String], _ output: Output) throws -> Exit {
        guard let first = arguments.first else {
            output.error(Help.main)
            return .usage
        }
        switch first {
        case "-h", "--help":
            output.print(Help.main)
            return .success
        case "--version":
            guard arguments.count == 1 else { throw Failure(.usage, "--version takes no arguments", help: "framekit") }
            output.print("framekit \(version)")
            return .success
        case "captions":
            return try captions(Array(arguments.dropFirst()), output)
        default:
            throw Failure(.usage, first.hasPrefix("-") ? "unknown option \"\(first)\"" : "unknown command \"\(first)\"", help: "framekit")
        }
    }

    private static func captions(_ arguments: [String], _ output: Output) throws -> Exit {
        guard let first = arguments.first else {
            output.error(Help.captions)
            return .usage
        }
        switch first {
        case "-h", "--help":
            output.print(Help.captions)
            return .success
        case "render":
            let rest = Array(arguments.dropFirst())
            if rest.contains("-h") || rest.contains("--help") {
                output.print(Help.render)
                return .success
            }
            return try RenderCommand(arguments: rest).run(output)
        default:
            throw Failure(.usage, first.hasPrefix("-") ? "unknown option \"\(first)\"" : "unknown command \"captions \(first)\"",
                          help: "framekit captions")
        }
    }
}

/// Where the command line writes: standard output for results and help, standard error for diagnostics.
public struct Output: Sendable {
    public let print: @Sendable (String) -> Void
    public let error: @Sendable (String) -> Void

    public init(print: @escaping @Sendable (String) -> Void, error: @escaping @Sendable (String) -> Void) {
        self.print = print
        self.error = error
    }

    public static let standard = Output(
        print: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        error: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
}

/// A command that cannot go on: the exit status and what to tell the user.
struct Failure: Error {
    let status: CLI.Exit
    let message: String
    /// The command whose help explains the usage (for usage errors).
    let helpCommand: String

    init(_ status: CLI.Exit, _ message: String, help: String = "framekit captions render") {
        self.status = status
        self.message = message
        self.helpCommand = help
    }
}

enum Help {
    static let main = """
        framekit \(CLI.version): small tools for making things move.

        Usage: framekit <command> [options]

        Commands:
          captions    render caption frames

        Options:
          -h, --help  show this help
          --version   show the version

        Run "framekit captions --help" for the caption commands.
        """

    static let captions = """
        Usage: framekit captions <command> [options]

        Commands:
          render      render caption frames as transparent PNG images

        Options:
          -h, --help  show this help

        Run "framekit captions render --help" for its options.
        """

    static let render = """
        Usage: framekit captions render --preset FILE --input FILE --out DIR [--frames A..B]

        Renders the captions of a caption input with a preset: one transparent 8-bit RGBA PNG
        per video frame, named after the frame index (0000.png, 0001.png, ...). Frame i shows
        the instant (i + 0.5) / fps of the video.

        Options:
          --preset FILE   caption preset (JSON), such as captions/presets/kinetic-minimal.json
          --input FILE    caption input (JSON): the words with their times, and the cues
          --out DIR       where the frames go. DIR must not exist or must be empty, and its
                          parent must exist. Nothing is overwritten.
          --frames A..B   only frames A to B, both included (A and B are frame numbers, A <= B).
                          Default: from frame 0 to the last frame that shows a caption.
          -h, --help      show this help

        Both documents are checked, alone and together, and every font of the preset must be
        installed, before anything is written. Frames are rendered into a hidden folder inside
        DIR and moved into DIR only when all of them are done; after a failure DIR is left as
        it was.

        Exit status: 0 done; 64 usage error; 65 invalid document; 66 file cannot be read;
        69 font not installed; 70 rendering failed; 73 output directory refused; 74 write error.
        """
}
