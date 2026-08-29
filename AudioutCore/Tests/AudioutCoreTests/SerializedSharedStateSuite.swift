import Testing

/// The one enclosing suite for every test that touches **process-global shared
/// state**, so those tests can never run concurrently with each other.
///
/// WHY THIS EXISTS. Under XCTest, `swift test --parallel` gave each test
/// **method** its own process (verified 2026-07-25 — see
/// `docs/notes/test-parallel-spawn-measurement.md`), so a test that installed a
/// process-global hook could not possibly collide with another test doing the
/// same: they were in different address spaces. That safety was **accidental**,
/// not designed.
///
/// swift-testing runs tests **concurrently inside one process**. The moment
/// these suites are converted, two tests that both call
/// `Telemetry._installTestSink(_:)` are writing the same global: one test's
/// `_installTestSink(nil)` teardown tears the other test's sink out from under
/// it mid-run, and each reads back a mixture of both tests' emissions. It fails
/// intermittently, in whichever test happens to lose the race — the worst kind
/// of flake to diagnose.
///
/// WHY ONE SHARED PARENT AND NOT FIVE `.serialized` SUITES. The `.serialized`
/// trait serializes tests **within** the suite it is applied to (and within
/// suites nested inside it). Five independently-`.serialized` suites would each
/// be internally ordered but would still run **against each other** — which is
/// exactly the collision that matters here, since the shared state is global to
/// the process, not to a suite. Putting them all under ONE `.serialized` parent
/// is what actually removes the race. Verified on this toolchain: with two
/// child suites nested under this parent, measured maximum concurrent overlap
/// was 1, i.e. nothing from one child ever ran alongside anything from another.
///
/// ## How to plug a suite in
///
/// Declare the suite **inside an extension of this type**, in its own file
/// exactly as before. Extensions may declare nested types, so no file has to
/// move and no code has to be merged together:
///
/// ```swift
/// // TelemetryTests.swift  (unchanged location)
/// extension SerializedSharedState {
///     @Suite final class TelemetryTests: IsolatedSuite {
///         @Test func writesToTheInjectedDirectory() { ... }
///     }
/// }
/// ```
///
/// Points that matter:
///  - Do **not** put `.serialized` on the child suite. It inherits it from
///    here; repeating it is noise and invites someone to "clean up" the parent.
///  - The suite's runtime name becomes `SerializedSharedState.TelemetryTests`,
///    but `swift test --filter TelemetryTests` still matches (the filter is a
///    substring/regex match on the full name), so the per-suite inner loop in
///    `AudioutCore/AGENTS.md` is unchanged.
///  - Nesting does not change member lookup: the suite can still inherit
///    `IsolatedSuite`, use `@MainActor`, and reference the file's private
///    helpers as before.
///  - Serialization is not a substitute for teardown. Each test must still
///    restore the global it touched — `defer { Telemetry._installTestSink(nil) }`
///    — because serialized only means *not at the same time*, not *undone
///    afterwards*, and the next test in line inherits whatever was left behind.
///
/// ## Which suites belong here
///
/// The five that share `Telemetry`'s process-global test seams
/// (`_installTestSink(_:)` / `_resetForTesting(directory:)`) — confirmed by
/// `git grep _installTestSink` over `Tests/AudioutCoreTests`:
///
///  - `TelemetryTests`               (also the only user of `_resetForTesting`)
///  - `NativeCaptureCoordinatorTests`
///  - `PerAppCaptureCoordinatorTests`
///  - `NativeBackendGlobalStateTests` (NOT `NativeBackendTests` — see below)
///  - `SetupModelTests`
///  - `SetupTelemetryTests`          (the setup_allow/setup_done decision-log
///                                    tests, split out of `SetupFlowModelTests`
///                                    which had been installing the sink from
///                                    OUTSIDE this parent — a live collision
///                                    caught 2026-08-11)
///
/// `NativeBackendTests` itself is deliberately NOT here: most of its tests
/// touch no process-global state, and holding them in this chain made it the
/// second-longest pole in the suite. Only the ones that do were split out into
/// `NativeBackendGlobalStateTests` — 15 for `_installTestSink`, plus 2 that
/// construct `NativeBackend` without `aggregateControl:` and so drive the REAL
/// macOS-wide aggregate device on a fixed UID, which two tests cannot share.
/// `--filter NativeBackendTests` reaches all three suites nested under this
/// parent — `NativeBackendGlobalStateTests`, `SerializedSharedState`, and
/// `NativeBackendTests` itself — 227 tests total.
///
/// Add a suite here when — and only when — it mutates state that outlives the
/// test instance and is shared process-wide. Per-test temp dirs and
/// `UserDefaults` suites are NOT that: `IsolatedSuite`
/// (`IsolatedTestCase.swift`) already gives each test its own, and those suites
/// stay parallel. Over-adding here is not free — everything under this parent
/// runs strictly one at a time.
@Suite(.serialized)
struct SerializedSharedState {}
