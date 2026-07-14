import Foundation

/// Owns the named FIFO's filesystem lifecycle (0f-pipe-brief.md "FIFO location":
/// the pipe MUST live inside a configured OwnTone library directory so the
/// library scan can index it as a `data_kind: pipe` track). Injectable so the
/// coordinator's state machine is testable without touching the real filesystem
/// or OwnTone's media dir.
protocol FIFOManaging: Sendable {
    /// Absolute path of the FIFO this manager owns (inside OwnTone's library dir).
    var fifoPath: String { get }

    /// Create the FIFO (`mkfifo`) if it doesn't already exist. Idempotent — an
    /// existing FIFO from a prior run is reused (0f-pipe-brief.md left `spike.fifo`
    /// in place deliberately to avoid a needless mkfifo+rescan). Throws if the
    /// path exists as a non-FIFO, or `mkfifo` fails.
    func create() throws

    /// Remove the FIFO on teardown. Best-effort; never throws.
    func cleanup()
}

/// Real `mkfifo`-backed FIFO manager. The FIFO is created inside OwnTone's
/// library directory (passed in — dev default is `dev/owntone/media/`).
final class FIFOManager: FIFOManaging, @unchecked Sendable {

    let fifoPath: String

    /// - Parameters:
    ///   - libraryDirectory: OwnTone's library dir (`GET`-able from
    ///     `owntone.conf`'s `library { directories = { … } }`; dev value is
    ///     `dev/owntone/media`). The FIFO is created inside it so a rescan indexes
    ///     it. **This is the config-follows-tap contract's first half**: the pipe
    ///     lives where OwnTone can see it.
    ///   - fifoName: the FIFO's basename (default `airplay.fifo`).
    init(libraryDirectory: String, fifoName: String = "airplay.fifo") {
        self.fifoPath = (libraryDirectory as NSString).appendingPathComponent(fifoName)
    }

    func create() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: fifoPath, isDirectory: &isDir) {
            if isDir.boolValue {
                throw CaptureCoordinatorError.fifoCreationFailed(
                    path: fifoPath, reason: "path exists and is a directory")
            }
            // Verify it's actually a FIFO; if it's a regular file, refuse rather
            // than feed OwnTone a non-pipe.
            let attrs = try? fm.attributesOfItem(atPath: fifoPath)
            if let type = attrs?[.type] as? FileAttributeType, type != .typeSocket, !isFIFO(fifoPath) {
                throw CaptureCoordinatorError.fifoCreationFailed(
                    path: fifoPath, reason: "path exists but is not a FIFO")
            }
            return // reuse the existing FIFO
        }
        // Ensure the parent dir exists.
        let parent = (fifoPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            throw CaptureCoordinatorError.fifoCreationFailed(
                path: fifoPath, reason: "library directory does not exist: \(parent)")
        }
        let result = fifoPath.withCString { mkfifo($0, 0o644) }
        guard result == 0 else {
            throw CaptureCoordinatorError.fifoCreationFailed(
                path: fifoPath, reason: "mkfifo failed (errno \(errno): \(String(cString: strerror(errno))))")
        }
    }

    func cleanup() {
        // Best-effort: only remove if it's a FIFO we own.
        guard isFIFO(fifoPath) else { return }
        try? FileManager.default.removeItem(atPath: fifoPath)
    }

    private func isFIFO(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFIFO
    }
}
