import Foundation
import XCTest

/// Per-test isolated, auto-cleaned scratch state, so the suite stays green
/// under `swift test --parallel` and under swift-testing's in-process
/// concurrency.
///
/// WHY THIS EXISTS: `swift test --parallel` runs each test **method** in its
/// own process, concurrently (corrected 2026-07-25 — verified by watching live
/// `ps` output: distinct methods of the SAME class run as distinct concurrent
/// processes; see `docs/notes/test-parallel-spawn-measurement.md`). Under
/// XCTest, processes didn't share memory, so in-process `static` counters,
/// process-global C variables and installed-once hooks were safe **by
/// accident** — but even then the parallel processes DID share anything living
/// outside the process: `UserDefaults.standard` (one on-disk plist for the
/// whole app domain) and a fixed filesystem path (a bare
/// `FileManager.default.temporaryDirectory` + a shared filename). Two suites
/// that write the same defaults key or the same temp file race each other and
/// flake intermittently — which is exactly how the window-frame suite failed
/// when `--parallel` was first switched on.
///
/// **That accidental in-memory safety is GONE under swift-testing**, which runs
/// tests concurrently *inside one process*: the out-of-process hazards above
/// still apply (this file's job), and on top of them any `static var`,
/// file-scope global, process-wide singleton or C global is now genuinely
/// shared between concurrently-running tests. This file does **not** solve
/// that half — `SerializedSharedStateSuite.swift` does, and a suite touching
/// such state must nest into `SerializedSharedState` regardless of whether it
/// also inherits `IsolatedSuite`.
///
/// This file holds three things:
///
///  1. `TestIsolation` — the actual mechanism, framework-agnostic.
///  2. `IsolatedSuite` — the **swift-testing** base class. New and converted
///     suites inherit this.
///  3. `IsolatedTestCase` — the **legacy XCTest** base class, unchanged in
///     behaviour, kept only until the last XCTest subclass is migrated.
///
/// Both bases expose the identical member set (`scratchDir`,
/// `isolatedDefaults`, `uniqueName(_:)`, `isolationToken`) over the same
/// `TestIsolation` object, so migrating a suite is a base-class swap and
/// nothing else.
///
/// `.githooks/pre-commit` (Guard 3) warns when a newly added test line reaches
/// `UserDefaults.standard` or a bare `temporaryDirectory` and points back here.

// MARK: - The mechanism

/// The isolation mechanism itself, owned by whichever test base class is in
/// play. Keeping it out of the base classes is what lets the XCTest and
/// swift-testing bases coexist during the migration without duplicating logic
/// (a class can only have one superclass, so the two bases cannot share code by
/// inheritance).
///
/// Cleanup runs from this object's own `deinit`. For a swift-testing suite that
/// is exactly right: the suite instance is released after each test, releasing
/// this, and — critically — Swift releases a class's stored properties only
/// *after* running the whole `deinit` chain, so a subclass's `deinit` (the old
/// `override func tearDown()`) still runs BEFORE this cleanup, preserving the
/// old `super.tearDown()`-last ordering. `cleanUp()` is also exposed and
/// idempotent so the XCTest base can drive it from `tearDown()` deterministically.
public final class TestIsolation {

    /// Per-instance identity: same for the life of one test, unique everywhere
    /// else. All isolation below is namespaced by it.
    public let isolationToken = UUID().uuidString

    /// Human-readable owner, used only to make scratch paths legible when
    /// debugging. Callers pass `"\(Self.self)"`.
    private let owner: String

    private var _scratchDir: URL?
    private var _isolatedDefaults: UserDefaults?

    public init(owner: String) {
        self.owner = owner
    }

    /// A unique, already-created temp directory owned by this test. Prefer this
    /// over `FileManager.default.temporaryDirectory` + a shared filename.
    public var scratchDir: URL {
        if let existing = _scratchDir { return existing }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(owner)-\(isolationToken)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _scratchDir = dir
        return dir
    }

    /// A `UserDefaults` isolated from `.standard` and from every other test,
    /// and backed by memory rather than a `~/Library/Preferences` plist (see
    /// `InMemoryDefaults`). Prefer this over `UserDefaults.standard`.
    public var isolatedDefaults: UserDefaults {
        if let existing = _isolatedDefaults { return existing }
        let defaults = makeDefaults()
        _isolatedDefaults = defaults
        return defaults
    }

    /// A brand-new store, distinct from `isolatedDefaults` and from every other
    /// one this test asks for. For a fixture helper called several times in one
    /// test, each call wanting an empty store — where sharing one would let the
    /// first fixture's writes leak into the second's reads.
    public func makeDefaults() -> UserDefaults { InMemoryDefaults() }

    /// A collision-proof variant of `base`, for APIs that persist to a global
    /// store no matter what (e.g. `NSWindow.setFrameAutosaveName`).
    public func uniqueName(_ base: String) -> String {
        "\(base)-\(isolationToken)"
    }

    /// Remove everything this test created. Idempotent.
    public func cleanUp() {
        if let dir = _scratchDir {
            try? FileManager.default.removeItem(at: dir)
        }
        _scratchDir = nil
        _isolatedDefaults = nil
    }

    deinit { cleanUp() }
}

/// A `UserDefaults` that keeps everything in memory and never touches disk.
///
/// **Never reach for `UserDefaults(suiteName:)` in a test.** A suite IS a real
/// `~/Library/Preferences/<name>.plist`, so a per-test suite name leaves a new
/// file behind on every test, forever — this Mac measured 48,769 of them,
/// ~200 MB, 98% of that directory, which `cfprefsd` and every `defaults`
/// lookup walks past. There is no in-process way to take one back, and both
/// halves of the obvious cleanup measure as failing: `removePersistentDomain
/// (forName:)` empties the domain but leaves the file, and `cfprefsd` writes an
/// empty plist back for any domain it still has cached AFTER the client process
/// exits, so unlinking the file from the test that made it loses the race.
///
/// `object`/`set`/`removeObject` are `UserDefaults`' primitive methods — every
/// typed accessor (`bool`, `integer`, `double`, `string`, …) and every typed
/// setter is built on them, so overriding these three is the whole job.
private final class InMemoryDefaults: UserDefaults {
    // A test may hand its settings object to code that writes from a background
    // queue, and `UserDefaults` itself is thread-safe — so this has to be too,
    // or the substitution introduces a data race the real thing never had.
    private let lock = NSLock()
    private var store: [String: Any] = [:]

    override func object(forKey key: String) -> Any? {
        lock.withLock { store[key] }
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { store[key] = value }
    }

    override func removeObject(forKey key: String) {
        lock.withLock { store[key] = nil }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { store }
    }
}

// MARK: - swift-testing base

/// Base class for **swift-testing** suites that need isolated scratch state.
///
/// swift-testing suites may be classes, and a `@Suite final class` inheriting
/// from this works exactly as `XCTestCase` subclassing did — verified on this
/// toolchain: the suite instance is created fresh per test, `Self.self`
/// resolves to the concrete subclass, and `deinit` fires after each test
/// (subclass `deinit` first, then the base's, then stored properties release).
/// A `struct` suite cannot inherit this: `deinit` is a hard compile error on a
/// struct, and there is no `tearDown` hook to fall back on. A struct suite
/// instead holds `TestIsolation` as a stored property and reaches its members
/// through it — the class is released when the per-test struct instance is,
/// so its `deinit` cleans up on exactly the same schedule.
///
/// ```swift
/// @MainActor
/// @Suite final class MixerWindowControllerTests: IsolatedSuite {
///     @Test func somethingUsingScratchDir() { ... }
/// }
/// ```
///
/// Members:
///  - `scratchDir`       — a unique per-test temp directory, created lazily and
///                         removed after the test. Use for on-disk stores
///                         (`GroupStore`, icon stores, FIFOs, …).
///  - `isolatedDefaults` — a `UserDefaults` backed by a unique suite name,
///                         whose domain is wiped after the test. Use instead of
///                         `UserDefaults.standard`.
///  - `uniqueName(_:)`   — a collision-proof name for APIs that always write a
///                         global store regardless of what you pass (AppKit's
///                         `NSWindow.setFrameAutosaveName` always persists into
///                         `UserDefaults.standard`, so a per-test *name* is the
///                         only way to isolate it).
///
/// TEARDOWN: a subclass that had `override func tearDown() { …; super.tearDown() }`
/// becomes a plain `deinit { … }` on the subclass. Swift runs it before the
/// base's cleanup automatically — there is no `super.deinit` to call and none
/// is needed. `deinit` is `nonisolated` even on a `@MainActor` class, so
/// teardown must not touch main-actor-isolated state; if it must, do that work
/// at the end of the test body instead.
///
/// `@MainActor`: the primary consumers are the AppKit/UI suites (which are
/// themselves `@MainActor`), and a subclass inherits its superclass's isolation
/// — a nonisolated base would make every `@MainActor` suite that adopts it a
/// hard error under Swift 6. A purely off-main backend suite can still inherit
/// this and touch the isolation members on the main actor.
@MainActor
open class IsolatedSuite {

    /// Owns and cleans up this test's scratch state. `private` on purpose —
    /// suites use the forwarding members below, which read the same as the old
    /// `XCTestCase` ones.
    private lazy var isolation = TestIsolation(owner: "\(Self.self)")

    public init() {}

    /// Per-instance identity: same for the life of one test, unique everywhere else.
    public var isolationToken: String { isolation.isolationToken }

    /// A unique, already-created temp directory owned by this test.
    public var scratchDir: URL { isolation.scratchDir }

    /// A `UserDefaults` isolated from `.standard` and from every other test.
    public var isolatedDefaults: UserDefaults { isolation.isolatedDefaults }

    /// A fresh, empty, memory-backed defaults store per call.
    public func makeDefaults() -> UserDefaults { isolation.makeDefaults() }

    /// A collision-proof variant of `base`, for APIs that persist globally.
    public func uniqueName(_ base: String) -> String { isolation.uniqueName(base) }
}

// MARK: - Legacy XCTest base

/// The XCTest-era base class. **Deprecated by `IsolatedSuite`** — do not add
/// new subclasses. It stays only so the not-yet-converted XCTest suites keep
/// compiling and running while the migration is in flight; delete it (and this
/// file's `import XCTest`) once `git grep IsolatedTestCase` finds nothing but
/// this declaration.
///
/// Behaviour is unchanged from before the migration: same members, cleanup in
/// `tearDown()`, `super.tearDown()` last.
@MainActor
open class IsolatedTestCase: XCTestCase {

    private lazy var isolation = TestIsolation(owner: "\(Self.self)")

    public private(set) lazy var isolationToken: String = isolation.isolationToken

    public var scratchDir: URL { isolation.scratchDir }

    public var isolatedDefaults: UserDefaults { isolation.isolatedDefaults }

    public func makeDefaults() -> UserDefaults { isolation.makeDefaults() }

    public func uniqueName(_ base: String) -> String { isolation.uniqueName(base) }

    open override func tearDown() {
        isolation.cleanUp()
        super.tearDown()
    }
}
