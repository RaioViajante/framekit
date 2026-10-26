import Foundation

/// SIGINT, SIGTERM and SIGHUP, turned into a flag that a render checks before each frame and each move,
/// so that an interrupted render cleans up like a failed one. SIGKILL cannot be caught.
/// Reference: docs/cli.md#interruptions-and-their-limits
public final class Interruption: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int32?
    private var sources: [DispatchSourceSignal] = []

    public init() {}

    /// Catches the signals from now on, for the rest of the process.
    public static func install() -> Interruption {
        let interruption = Interruption()
        for number in [SIGINT, SIGTERM, SIGHUP] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { interruption.receive(number) }
            source.resume()
            interruption.sources.append(source)
            // Only now: from here on the signal reaches the source instead of ending the process. One
            // that arrives before this line still ends it, before anything has been written.
            signal(number, SIG_IGN)
        }
        return interruption
    }

    func receive(_ number: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if received == nil { received = number }
    }

    /// Throws `Interrupted` once a signal has arrived.
    func check() throws {
        lock.lock()
        let number = received
        lock.unlock()
        if let number { throw Interrupted(signal: number) }
    }
}

struct Interrupted: Error {
    let signal: Int32
}
