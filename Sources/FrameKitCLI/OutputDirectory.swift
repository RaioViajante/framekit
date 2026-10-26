import Foundation

/// A file or directory, by device and inode: what this run created, as opposed to something another
/// process put at the same path.
struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    /// The identity of what is at `url` now (not following a symbolic link), or nil if nothing is.
    init?(of url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

/// The output directory of one render and everything this run put in it. Frames are written into a
/// hidden staging folder inside it and moved into place only once all are done. Rollback removes only
/// what this run created and still finds in place, identified by device and inode just before removal,
/// so a file or folder another process created, or put in place of one of ours, is never removed; a
/// directory is only removed when empty. Reference: docs/cli.md#output
final class OutputDirectory {
    let url: URL
    let staging: URL
    /// The output directory, when this run created it.
    private let createdDirectory: FileIdentity?
    private let stagingDirectory: FileIdentity
    /// Frames written into the staging folder and not yet moved, by file name.
    private var staged: [String: FileIdentity] = [:]
    private var placed: [(url: URL, id: FileIdentity)] = []

    /// `url` must be an empty directory or not exist (its parent must); it is created in the second case.
    init(preparing url: URL) throws {
        self.url = url
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw Failure(.outputRefused, "--out \(url.path) is a file, not a directory") }
            let contents: [String]
            do {
                contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
            } catch {
                throw Failure(.outputRefused, "cannot list --out \(url.path): \(error.localizedDescription)")
            }
            guard contents.isEmpty else {
                throw Failure(.outputRefused, "--out \(url.path) is not empty (\(contents.count) item(s), hidden ones included); nothing is overwritten: choose a new or empty directory")
            }
            createdDirectory = nil
        } else {
            let parent = url.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Failure(.outputRefused, "the parent of --out, \(parent.path), does not exist")
            }
            guard mkdir(url.path, 0o777) == 0, let id = FileIdentity(of: url) else {
                throw Failure(.outputRefused, "cannot create --out \(url.path): \(String(cString: strerror(errno)))")
            }
            createdDirectory = id
        }
        staging = url.appendingPathComponent(".framekit-partial-\(UUID().uuidString)")
        guard mkdir(staging.path, 0o777) == 0, let id = FileIdentity(of: staging) else {
            let reason = String(cString: strerror(errno))
            if let created = createdDirectory, FileIdentity(of: url) == created { rmdir(url.path) }
            throw Failure(.writeFailed, "cannot write into --out \(url.path): \(reason)")
        }
        stagingDirectory = id
    }

    /// The staging path of a frame file.
    func stagingFile(_ name: String) -> URL { staging.appendingPathComponent(name) }

    /// Records a file this run has just written into the staging folder.
    func didStage(_ name: String) throws {
        let file = stagingFile(name)
        guard let id = FileIdentity(of: file) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: file.path]) }
        staged[name] = id
    }

    /// Moves a staged file into the output directory. `move` must refuse an existing destination.
    func place(_ name: String, move: (URL, URL) throws -> Void) throws {
        guard let id = staged[name] else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: stagingFile(name).path]) }
        let destination = url.appendingPathComponent(name)
        try move(stagingFile(name), destination)
        staged[name] = nil
        // Recorded only if what is there now is the file that was moved.
        if FileIdentity(of: destination) == id { placed.append((destination, id)) }
    }

    /// Removes the empty staging folder once every frame is in place. Returns false if it could not be
    /// removed (it holds something this run did not write), in which case it is left alone.
    func finish() -> Bool {
        FileIdentity(of: staging) == stagingDirectory && rmdir(staging.path) == 0
    }

    /// Undoes this run: removes its frames, its staging folder and the output directory if it created
    /// it, but only what is still its own, and directories only when empty. Returns what it had to
    /// leave, for the message.
    func rollback() -> [String] {
        var left: [String] = []
        let files = placed + staged.map { (url: stagingFile($0.key), id: $0.value) }
        for entry in files where FileIdentity(of: entry.url) == entry.id {
            if unlink(entry.url.path) != 0 { left.append(entry.url.path) }
        }
        if FileIdentity(of: staging) == stagingDirectory, rmdir(staging.path) != 0 {
            left.append("\(staging.path) (it holds files framekit did not write)")
        }
        if let created = createdDirectory, FileIdentity(of: url) == created, rmdir(url.path) != 0 {
            left.append("\(url.path) (it holds files framekit did not write)")
        }
        return left
    }
}
