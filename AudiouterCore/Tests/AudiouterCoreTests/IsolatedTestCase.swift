import XCTest

/// Base class that gives every test its own isolated, auto-cleaned scratch
/// state so the suite stays green under `swift test --parallel`.
///
/// WHY THIS EXISTS: `swift test --parallel` runs each test **method** in its
/// own process, concurrently (corrected 2026-07-25 — verified by watching live
/// `ps` output: distinct methods of the SAME class run as distinct concurrent
/// processes; see `docs/notes/test-parallel-spawn-measurement.md`). Processes
/// don't share memory, so in-process `static` counters are safe — but they DO
/// share anything that lives outside the
/// process: `UserDefaults.standard` (one on-disk plist for the whole app
/// domain) and a fixed filesystem path (a bare
/// `FileManager.default.temporaryDirectory` + a shared filename). Two suites
/// that write the same defaults key or the same temp file race each other and
/// flake intermittently — which is exactly how the window-frame suite failed
/// when `--parallel` was first switched on.
///
/// Subclass this instead of `XCTestCase` and use the members below rather than
/// reaching for the shared globals directly. New tests then get isolation for
/// free, and the safe pattern is the default one. `.githooks/pre-commit`
/// (Guard 3) warns when a newly added test line reaches `UserDefaults.standard`
/// or a bare `temporaryDirectory` and points back here.
///
///  - `scratchDir`     — a unique per-test temp directory, created lazily and
///                       removed in `tearDown`. Use for on-disk stores
///                       (`GroupStore`, icon stores, FIFOs, …).
///  - `isolatedDefaults` — a `UserDefaults` backed by a unique suite name,
///                       whose domain is wiped in `tearDown`. Use instead of
///                       `UserDefaults.standard`.
///  - `uniqueName(_:)` — a collision-proof name for APIs that always write a
///                       global store regardless of what you pass (AppKit's
///                       `NSWindow.setFrameAutosaveName` always persists into
///                       `UserDefaults.standard`, so a per-test *name* is the
///                       only way to isolate it).
///
/// The isolation is derived from `isolationToken`, a per-instance UUID — stable
/// for one test's lifetime, unique across every test and every process.
///
/// `@MainActor`: the primary consumers are the AppKit/UI suites (which are
/// themselves `@MainActor`), and a subclass inherits its superclass's isolation
/// — a nonisolated base would make every `@MainActor` suite that adopts it a
/// hard error under Swift 6. Test bodies running on the main actor matches how
/// XCTest already behaves for these suites; a purely off-main backend suite can
/// still subclass this and call the isolation members on the main actor.
@MainActor
open class IsolatedTestCase: XCTestCase {

    /// Per-instance identity: same for the life of one test, unique everywhere
    /// else. All isolation below is namespaced by it.
    public private(set) lazy var isolationToken: String = UUID().uuidString

    private var _scratchDir: URL?
    private var _isolatedDefaults: UserDefaults?
    private var _suiteName: String?

    /// A unique, already-created temp directory owned by this test. Prefer this
    /// over `FileManager.default.temporaryDirectory` + a shared filename.
    public var scratchDir: URL {
        if let existing = _scratchDir { return existing }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.self)-\(isolationToken)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _scratchDir = dir
        return dir
    }

    /// A `UserDefaults` isolated from `.standard` and from every other test.
    /// Prefer this over `UserDefaults.standard`.
    public var isolatedDefaults: UserDefaults {
        if let existing = _isolatedDefaults { return existing }
        let suite = "AudiouterTests.\(Self.self).\(isolationToken)"
        // suiteName can only be nil for the reserved global/registration
        // domains, which this never is — force-unwrap is the documented usage.
        let defaults = UserDefaults(suiteName: suite)!
        _suiteName = suite
        _isolatedDefaults = defaults
        return defaults
    }

    /// A collision-proof variant of `base`, for APIs that persist to a global
    /// store no matter what (e.g. `NSWindow.setFrameAutosaveName`).
    public func uniqueName(_ base: String) -> String {
        "\(base)-\(isolationToken)"
    }

    open override func tearDown() {
        if let dir = _scratchDir {
            try? FileManager.default.removeItem(at: dir)
        }
        if let suite = _suiteName {
            _isolatedDefaults?.removePersistentDomain(forName: suite)
        }
        _scratchDir = nil
        _isolatedDefaults = nil
        _suiteName = nil
        super.tearDown()
    }
}
