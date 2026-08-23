import Testing
import Foundation
@testable import AudioutCore

/// Security regression tests for the real (`mkfifo`-backed) ``FIFOManager``. The
/// coordinator tests use a fake; these exercise the concrete filesystem path
/// because the pipe carries the Mac's full captured audio and MUST stay private.
///
/// Locks in the fix for the world-readable-FIFO finding: the pipe is created
/// owner-only (`0o600`, never `0o644`), reuse is refused unless the existing node
/// is a FIFO we own, and an over-permissive leftover pipe is tightened on reuse.
@Suite final class FIFOManagerSecurityTests {

    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fifo-sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `#require`, not a skip: an `lstat` failure on a path this test just
    /// created is a real failure and must fail loudly (swift-testing has no
    /// mid-body dynamic-skip primitive — cookbook §9).
    private func mode(of path: String) throws -> mode_t {
        var st = stat()
        try #require(lstat(path, &st) == 0, "could not stat \(path)")
        return st.st_mode & 0o777
    }

    /// A freshly created FIFO is owner-only — no group/other bits.
    @Test func createdFIFOIsOwnerOnly() throws {
        let mgr = FIFOManager(libraryDirectory: dir.path)
        try mgr.create()
        defer { mgr.cleanup() }

        var st = stat()
        #expect(lstat(mgr.fifoPath, &st) == 0)
        #expect(st.st_mode & S_IFMT == S_IFIFO, "must be a real FIFO")
        #expect(try mode(of: mgr.fifoPath) == 0o600, "FIFO must be owner-only (no world/group read)")
        // The whole point: 'other' must have no access to the captured audio.
        #expect(st.st_mode & 0o007 == 0, "world bits must be clear")
        #expect(st.st_mode & 0o070 == 0, "group bits must be clear")
    }

    /// Reusing a pipe left behind with wide permissions tightens it back to 0o600.
    @Test func reuseTightensPermissiveLeftover() throws {
        let mgr = FIFOManager(libraryDirectory: dir.path)
        // Simulate an old-build pipe that was created world-readable.
        #expect(mgr.fifoPath.withCString { mkfifo($0, 0o644) } == 0)
        #expect(try mode(of: mgr.fifoPath) == 0o644)

        try mgr.create() // reuse path
        defer { mgr.cleanup() }
        #expect(try mode(of: mgr.fifoPath) == 0o600, "reuse must strip the world-readable bits")
    }

    /// A non-FIFO squatting at the path is refused, not overwritten or streamed to.
    @Test func refusesNonFIFOAtPath() throws {
        let mgr = FIFOManager(libraryDirectory: dir.path)
        FileManager.default.createFile(atPath: mgr.fifoPath, contents: Data("not a pipe".utf8))

        #expect(throws: CaptureCoordinatorError.self, "must refuse to reuse a regular file at the FIFO path") {
            try mgr.create()
        }
        // The squatting file is left intact (we never clobber unknown files).
        #expect(FileManager.default.fileExists(atPath: mgr.fifoPath))
    }

    /// A symlink planted at the path is not followed and not reused.
    @Test func refusesSymlinkAtPath() throws {
        let mgr = FIFOManager(libraryDirectory: dir.path)
        let target = dir.appendingPathComponent("elsewhere.fifo")
        #expect(target.path.withCString { mkfifo($0, 0o600) } == 0)
        try FileManager.default.createSymbolicLink(atPath: mgr.fifoPath, withDestinationPath: target.path)

        #expect(throws: CaptureCoordinatorError.self, "must not follow a symlink at the FIFO path") {
            try mgr.create()
        }
    }
}
