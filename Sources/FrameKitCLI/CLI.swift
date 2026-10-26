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
        /// Writing the frames failed, or help or version could not be written to standard output.
        case writeFailed = 74
        /// Stopped by SIGHUP, SIGINT or SIGTERM (128 + the signal), after cleaning up.
        case hangup = 129
        case interrupted = 130
        case terminated = 143

        static func signalled(_ signal: Int32) -> Exit {
            switch signal {
            case SIGHUP: .hangup
            case SIGTERM: .terminated
            default: .interrupted
            }
        }
    }

    /// The `framekit` program: standard streams made safe to write, signals caught, then `run`.
    public static func main(_ arguments: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)  // a reader that went away is a write error, not the end of the process
        return run(arguments, output: .standard(), interruption: .install())
    }

    /// Runs the command line `arguments` (without the program name) and returns the exit status.
    public static func run(_ arguments: [String], output: Output, interruption: Interruption = Interruption()) -> Int32 {
        do {
            return try dispatch(arguments, output, interruption).rawValue
        } catch let failure as Failure {
            output.error("framekit: \(failure.message)")
            if failure.status == .usage { output.error("Run \"\(failure.helpCommand) --help\" for usage.") }
            return failure.status.rawValue
        } catch {
            output.error("framekit: \(error)")
            return Exit.renderFailed.rawValue
        }
    }

    private static func dispatch(_ arguments: [String], _ output: Output, _ interruption: Interruption) throws -> Exit {
        guard let first = arguments.first else {
            output.error(Help.main)
            return .usage
        }
        switch first {
        case "-h", "--help":
            return try show(Help.main, output)
        case "--version":
            guard arguments.count == 1 else { throw Failure(.usage, "--version takes no arguments", help: "framekit") }
            return try show("framekit \(version)", output)
        case "captions":
            return try captions(Array(arguments.dropFirst()), output, interruption)
        default:
            throw Failure(.usage, first.hasPrefix("-") ? "unknown option \"\(first)\"" : "unknown command \"\(first)\"", help: "framekit")
        }
    }

    /// Help and version are the result itself: not being able to write them is a failure.
    private static func show(_ text: String, _ output: Output) throws -> Exit {
        guard output.print(text) else { throw Failure(.writeFailed, "cannot write to standard output") }
        return .success
    }

    private static func captions(_ arguments: [String], _ output: Output, _ interruption: Interruption) throws -> Exit {
        guard let first = arguments.first else {
            output.error(Help.captions)
            return .usage
        }
        switch first {
        case "-h", "--help":
            return try show(Help.captions, output)
        case "render":
            let rest = Array(arguments.dropFirst())
            if rest.contains("-h") || rest.contains("--help") { return try show(Help.render, output) }
            return try RenderCommand(arguments: rest).run(output, interruption: interruption)
        default:
            throw Failure(.usage, first.hasPrefix("-") ? "unknown option \"\(first)\"" : "unknown command \"captions \(first)\"",
                          help: "framekit captions")
        }
    }
}

/// Where the command line writes: standard output for results and help, standard error for
/// diagnostics. Each write says whether it worked; a stream that is closed, or whose reader has gone,
/// loses the text but never ends the process.
public struct Output: Sendable {
    private let writeOut: @Sendable (String) -> Bool
    private let writeErr: @Sendable (String) -> Bool

    public init(print: @escaping @Sendable (String) -> Bool, error: @escaping @Sendable (String) -> Bool) {
        writeOut = print
        writeErr = error
    }

    @discardableResult public func print(_ line: String) -> Bool { writeOut(line) }
    @discardableResult public func error(_ line: String) -> Bool { writeErr(line) }

    /// The process's standard output and error. A stream that was closed when the program started is
    /// pointed at /dev/null first, so that no file the program opens later can take its number and
    /// receive its text; writing to it then counts as failed.
    public static func standard() -> Output {
        let closed = [STDOUT_FILENO, STDERR_FILENO].filter { fd in
            guard fcntl(fd, F_GETFD) == -1 else { return false }
            let null = open("/dev/null", O_WRONLY)
            if null != fd && null >= 0 { dup2(null, fd); close(null) }
            return true
        }
        func writer(_ fd: Int32) -> @Sendable (String) -> Bool {
            let isClosed = closed.contains(fd)
            return { line in
                guard !isClosed else { return false }
                do {
                    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: Data((line + "\n").utf8))
                    return true
                } catch {
                    return false
                }
            }
        }
        return Output(print: writer(STDOUT_FILENO), error: writer(STDERR_FILENO))
    }
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
          --frames A..B   only frames A to B, both included (A and B are frame numbers, A <= B,
                          at most 1000000 frames). Default: from frame 0 to the last frame
                          within a caption's time.
          -h, --help      show this help

        A value may follow its option or be joined to it with "="; a value starting with "-"
        must be joined: --out=-x.

        Both documents are checked, alone and together, and every font of the preset must be
        installed, before anything is written. Frames are rendered into a hidden folder inside
        DIR and moved into DIR only when all of them are done. If framekit stops with an error,
        or is interrupted (Ctrl-C, SIGTERM, SIGHUP), it removes what it wrote and leaves DIR as
        it was; files it did not write are never removed. SIGKILL and power loss cannot be
        handled: see docs/cli.md.

        Exit status: 0 done; 64 usage error; 65 invalid document; 66 file cannot be read;
        69 font not installed; 70 rendering failed; 73 output directory refused; 74 write error;
        129, 130, 143 interrupted by SIGHUP, SIGINT, SIGTERM.
        """
}
