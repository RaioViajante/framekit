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

    /// Writes a frame into the staging folder. The file is created here, exclusively, and recorded as
    /// this run's before its first byte is written, so a write that fails part-way leaves a file that
    /// rollback knows to remove. `write` writes all of `bytes` to the open file descriptor.
    func stage(_ name: String, _ bytes: Data, write: (Int32, Data) throws -> Void) throws {
        let file = stagingFile(name)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw FileError(file) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = FileError(file)
            close(fd)
            throw error
        }
        staged[name] = FileIdentity(device: info.st_dev, inode: info.st_ino)
        do {
            try write(fd, bytes)
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw FileError(file) }
    }

    /// Moves a staged frame into the output directory with one atomic rename that never replaces an
    /// existing file (`move`), after checking that the staged file is still this run's.
    func place(_ name: String, move: (URL, URL) throws -> Void) throws {
        let source = stagingFile(name)
        guard let id = staged[name], FileIdentity(of: source) == id else {
            throw Failure(.writeFailed, "the staged frame \(source.path) was replaced or removed by another process")
        }
        let destination = url.appendingPathComponent(name)
        try move(source, destination)
        staged[name] = nil
        // Recorded only if what is there now is the file that was moved.
        if FileIdentity(of: destination) == id { placed.append((destination, id)) }
    }

    /// Removes the empty staging folder once every frame is in place. Returns false if it could not be
    /// removed (it holds something this run did not write), in which case it is left alone.
    func finish() -> Bool {
        FileIdentity(of: staging) == stagingDirectory && rmdir(staging.path) == 0
    }

    /// What rollback could not undo, for the message.
    struct Leftovers {
        /// Files of this run that could not be removed, with the reason.
        var owned: [String] = []
        /// Directories kept because they hold files another process created.
        var foreign: [String] = []

        var isEmpty: Bool { owned.isEmpty && foreign.isEmpty }
    }

    /// Undoes this run: removes its frames, finished or partial, its staging folder, and the output
    /// directory if it created it. Only what is still its own is removed (device and inode checked just
    /// before), and a directory only when empty, so anything another process created or put in place of
    /// one of this run's files stays.
    func rollback() -> Leftovers {
        var left = Leftovers()
        let files = placed + staged.map { (url: stagingFile($0.key), id: $0.value) }
        for entry in files where FileIdentity(of: entry.url) == entry.id {
            if unlink(entry.url.path) != 0 { left.owned.append("\(entry.url.path) (\(String(cString: strerror(errno))))") }
        }
        for (directory, id) in [(staging, Optional(stagingDirectory)), (url, createdDirectory)] {
            guard let id, FileIdentity(of: directory) == id, rmdir(directory.path) != 0 else { continue }
            if errno == ENOTEMPTY || errno == EEXIST { left.foreign.append(directory.path) }
            else { left.owned.append("\(directory.path) (\(String(cString: strerror(errno))))") }
        }
        return left
    }
}

extension FileIdentity {
    init(device: dev_t, inode: ino_t) {
        self.device = device
        self.inode = inode
    }
}

/// A system call that failed on a file, with the reason from `errno`.
struct FileError: Error, LocalizedError {
    let path: String
    let code: Int32

    /// The error in `errno` now, for `file`.
    init(_ file: URL, code: Int32 = errno) {
        path = file.path
        self.code = code
    }

    var errorDescription: String? { "\(path): \(String(cString: strerror(code)))" }
}
