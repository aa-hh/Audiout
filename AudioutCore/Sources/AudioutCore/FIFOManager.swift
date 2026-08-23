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

    /// FIFO permission bits: owner read/write only. The pipe carries the Mac's
    /// full captured audio, so it MUST NOT be readable by other users/processes —
    /// a world-readable pipe (the old `0o644`) let any local process `cat` the
    /// live stream. OwnTone reads this pipe as the same user, so owner-only is
    /// sufficient. (If OwnTone is ever run as a different user, widen to `0o660`
    /// with a shared group — never add world bits.)
    private static let fifoMode: mode_t = 0o600

    func create() throws {
        let fm = FileManager.default
        // Inspect the path WITHOUT following symlinks (`lstat`, not `stat`): an
        // attacker who can write the library dir must not be able to redirect our
        // captured audio through a symlink, nor have us reuse a pipe they own.
        var st = stat()
        if lstat(fifoPath, &st) == 0 {
            // Something already exists here. Only reuse it if it is a real FIFO we
            // own — otherwise refuse rather than stream audio into a foreign file,
            // socket, symlink, or a pipe planted by another user.
            guard (st.st_mode & S_IFMT) == S_IFIFO else {
                throw CaptureCoordinatorError.fifoCreationFailed(
                    path: fifoPath, reason: "path exists but is not a FIFO (won't follow a symlink or reuse a foreign file)")
            }
            guard st.st_uid == getuid() else {
                throw CaptureCoordinatorError.fifoCreationFailed(
                    path: fifoPath, reason: "existing FIFO is owned by uid \(st.st_uid), not us — refusing to reuse")
            }
            // Self-heal permissions: a pipe left behind by an older build (or
            // widened by tampering) gets tightened back to owner-only here.
            if (st.st_mode & 0o777) != Self.fifoMode {
                guard chmod(fifoPath, Self.fifoMode) == 0 else {
                    throw CaptureCoordinatorError.fifoCreationFailed(
                        path: fifoPath, reason: "existing FIFO has too-permissive mode and could not be restricted (errno \(errno))")
                }
            }
            return // safe to reuse
        }
        // Ensure the parent dir exists.
        let parent = (fifoPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            throw CaptureCoordinatorError.fifoCreationFailed(
                path: fifoPath, reason: "library directory does not exist: \(parent)")
        }
        // `mkfifo` is atomic and does NOT follow symlinks — it fails EEXIST if
        // anything (including a symlink planted in a create-time race) is already
        // at the path, so there is no TOCTOU window between the check above and
        // this call.
        let result = fifoPath.withCString { mkfifo($0, Self.fifoMode) }
        guard result == 0 else {
            throw CaptureCoordinatorError.fifoCreationFailed(
                path: fifoPath, reason: "mkfifo failed (errno \(errno): \(String(cString: strerror(errno))))")
        }
        // mkfifo's mode is masked by the process umask, so the on-disk mode can be
        // narrower (never wider) than requested. Verify we created a FIFO we own
        // and pin the exact mode, defeating any umask that stripped the owner
        // write bit (which would block audiocap from writing).
        var created = stat()
        guard lstat(fifoPath, &created) == 0,
              (created.st_mode & S_IFMT) == S_IFIFO,
              created.st_uid == getuid()
        else {
            try? fm.removeItem(atPath: fifoPath)
            throw CaptureCoordinatorError.fifoCreationFailed(
                path: fifoPath, reason: "FIFO verification failed immediately after creation")
        }
        if (created.st_mode & 0o777) != Self.fifoMode {
            _ = chmod(fifoPath, Self.fifoMode)
        }
    }

    func cleanup() {
        // Best-effort: only remove if it's a FIFO we own (lstat — never traverse a
        // symlink someone swapped in).
        guard isOwnedFIFO(fifoPath) else { return }
        try? FileManager.default.removeItem(atPath: fifoPath)
    }

    private func isOwnedFIFO(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFIFO && st.st_uid == getuid()
    }
}
