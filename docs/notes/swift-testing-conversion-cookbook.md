# Cookbook: converting this repo's XCTest suites to swift-testing

Companion to [swift-testing-migration-brief.md](swift-testing-migration-brief.md).
Every idiom below was **compiled and run** against this repo's actual toolchain
before being written down — nothing here is recalled from memory.

## Verified environment (T1, 2026-07-26)

| Thing | Value |
| --- | --- |
| Compiler | Apple Swift 6.4 (`swiftlang-6.4.0.27.1`), Xcode 27 beta |
| Target | `arm64-apple-macos14.0`, SDK MacOSX27.0 |
| `swift-tools-version` | **5.10, unchanged**, in both `AudioutCore/Package.swift` and `AirPlayEngine/Package.swift` |
| Language mode | `-swift-version 5` (NOT Swift 6 strict concurrency) |
| Testing library | `Testing` framework version **2074**, bundled with the toolchain |

**No `swift-tools-version` bump is needed.** `import Testing` resolves in both
packages under `swift-tools-version:5.10`, needs no `Package.swift` dependency
entry, and swift-testing suites coexist in the same target as untouched
`XCTestCase` classes — verified by building the whole `AudioutCoreTests`
target with a mix of both, and by running a swift-testing suite in
`AirPlayEngineTests`. **If you hit something that seems to require a tools-version
bump, STOP and escalate — do not bump it yourself.** It would flip both packages
into Swift 6 concurrency mode and that is a human decision.

Practical notes that fall out of the above:

- `swift test --filter <Name>` works on swift-testing suites too, so per-file
  verification is unchanged.
- Output format differs (`􁁛 Test run with N tests in M suites passed`), but
  `scripts/run-tests.sh` does not parse pass/fail counts out of `swift test`
  output, so there is nothing to update there.
- Because the language mode stays Swift 5, existing `Sendable` violations remain
  **warnings**, not errors. Do not "fix" them as part of a conversion.

---

## 0. The file-level shape

```swift
// BEFORE
import XCTest
@testable import AudioutCore

final class FooTests: XCTestCase {
    func testBarDoesTheThing() { ... }
}
```

```swift
// AFTER
import Foundation      // add if the file used Foundation types via XCTest's re-export
import Testing
@testable import AudioutCore

@Suite struct FooTests {
    @Test func barDoesTheThing() { ... }
}
```

- Drop the `test` prefix from method names and lowercase the first remaining
  letter (`testBarDoesTheThing` → `barDoesTheThing`). Keep the rest of the name
  verbatim — these names are long and descriptive on purpose; do not "tidy" them.
- **`import XCTest` transitively re-exported `Foundation`.** Removing it breaks
  files that used `URL` / `FileManager` / `UUID` / `Data` / `TimeInterval`
  without importing Foundation. Add `import Foundation` whenever the file
  touches any of those. (The pilot file needed exactly this.)
- Keep the doc comments. They carry the *why* and are worth more than the code.
- Do not rename the type. `FooTests` stays `FooTests`.

### 14. Multiple `XCTestCase` classes in one file

Just make each one its own `@Suite`. There is no nesting requirement and no
shared parent; swift-testing discovers them independently.

```swift
// BEFORE
final class FooTests: XCTestCase { func testA() {} }
final class FooEdgeCaseTests: XCTestCase { func testB() {} }
```

```swift
// AFTER
@Suite struct FooTests { @Test func a() {} }
@Suite struct FooEdgeCaseTests { @Test func b() {} }
```

Private free functions and private types at file scope stay exactly where they
are. Private *helpers that were methods on the class* stay methods on the struct.

---

## 1. `XCTAssertTrue` / `XCTAssertFalse`

```swift
// BEFORE
XCTAssertTrue(sink.isEmpty, "a buffer before format is known is dropped")
XCTAssertFalse(error.isRetryable)
```

```swift
// AFTER
#expect(sink.isEmpty, "a buffer before format is known is dropped")
#expect(!error.isRetryable)
```

The trailing message is a `Comment` (`ExpressibleByStringInterpolation`), so
existing interpolated messages like `"L frame \(f)"` carry over unchanged.

`#expect(x)` requires `x` to be a real `Bool`. If a site passes something
optional-ish, spell out the comparison rather than force-unwrapping.

## 2. `XCTAssertEqual`

```swift
// BEFORE
XCTAssertEqual(reloaded, routes)
XCTAssertEqual(over.volume, 100)
XCTAssertEqual(loaded, expected, "an old-format file must decode without loss")
```

```swift
// AFTER
#expect(reloaded == routes)
#expect(over.volume == 100)
#expect(loaded == expected, "an old-format file must decode without loss")
```

`#expect` expands the operands, so a failure still prints both sides — you do
not lose the diff you got from `XCTAssertEqual`.

## 3. `XCTAssertNotEqual`

```swift
// BEFORE
XCTAssertNotEqual(before, after)
```

```swift
// AFTER
#expect(before != after)
```

## 4. `XCTAssertNil` / `XCTAssertNotNil`

```swift
// BEFORE
XCTAssertNil(try store.load(), "a future schema version must not crash")
XCTAssertNotNil(popover.contentViewController)
```

```swift
// AFTER
#expect(try store.load() == nil, "a future schema version must not crash")
#expect(popover.contentViewController != nil)
```

`try` inside `#expect(...)` is fine as long as the enclosing `@Test func` is
`throws`. Note the difference from `#require` (§6): a `#expect` on a throwing
call that *does* throw records an issue and lets the test continue.

## 4b. `XCTAssertGreaterThan` / `GreaterThanOrEqual` / `LessThan` / `LessThanOrEqual`

Direct operator translation. Watch the argument order — XCTest reads
`XCTAssertGreaterThan(a, b)` as `a > b`.

```swift
// BEFORE
XCTAssertGreaterThan(samples.count, 0)
XCTAssertGreaterThanOrEqual(delta, minimum, "must not shrink")
XCTAssertLessThan(latency, budget)
XCTAssertLessThanOrEqual(retries, 3)
```

```swift
// AFTER
#expect(samples.count > 0)
#expect(delta >= minimum, "must not shrink")
#expect(latency < budget)
#expect(retries <= 3)
```

## 5. `XCTAssertEqual(a, b, accuracy:)` — tolerance comparisons

swift-testing has **no** `accuracy:` overload, and `Double.isApproximatelyEqual`
does **not** exist in this toolchain (it lives in swift-numerics, which this repo
does not depend on — confirmed by a failed compile). Write the comparison out.

### 5a. Floating point (the overwhelming majority of sites)

```swift
// BEFORE
XCTAssertEqual(NativeBackend.engineVolume(50), 0.5, accuracy: 0.001)
XCTAssertEqual(out[f * cc], input[f * cc], accuracy: 1e-6, "L frame \(f)")
```

```swift
// AFTER
#expect(abs(NativeBackend.engineVolume(50) - 0.5) <= 0.001)
#expect(abs(out[f * cc] - input[f * cc]) <= 1e-6, "L frame \(f)")
```

Keep `<=`, not `<` — XCTest's `accuracy` is inclusive, and several sites in this
repo (e.g. `SyncedLocalFanoutTests.swift`'s `accuracy: 8` frame-count checks) sit
right on the boundary.

If a site already wraps the value in `Double(...)`, keep the conversion inside
the subtraction:

```swift
// BEFORE
XCTAssertEqual(Double(resampler.inputFramesConsumed), expected, accuracy: 4.0, "...")
// AFTER
#expect(abs(Double(resampler.inputFramesConsumed) - expected) <= 4.0, "...")
```

### 5b. Integers — DO NOT use `abs(a - b)` blindly

For integer operands `abs(a - b)` is wrong twice over:

1. On an **unsigned** type (`UInt64`, `UInt32`, `UInt`) the subtraction traps at
   runtime whenever `a < b` — turning an assertion that should merely *fail*
   into a crash that kills the whole test process.
2. `abs` isn't even available on unsigned types, and when both operands are
   literals the compiler constant-folds and rejects the file outright. This was
   observed: `#expect((a > b ? a - b : b - a) <= 30_000)` with two `UInt64`
   literals produced
   `error: arithmetic operation '500000000 - 500010000' (on type 'UInt64') results in an overflow`
   at compile time.

Use the **max-minus-min** form. It never underflows, works on signed and
unsigned alike, and is not constant-folded into an overflow:

```swift
// BEFORE (AppRouteMixerTests.swift ~line 451)
XCTAssertEqual(back.tv_nsec, 500_000_000, accuracy: 30_000) // sub-frame rounding
```

```swift
// AFTER
let expected = 500_000_000
#expect(max(back.tv_nsec, expected) - min(back.tv_nsec, expected) <= 30_000) // sub-frame rounding
```

Both operands must be the *same* type for `max`/`min`. If one side is an untyped
literal, that's automatic; if the types genuinely differ, widen explicitly first.

A second acceptable form, only when both values provably fit in the signed type:

```swift
#expect(abs(Int64(a) - Int64(b)) <= 30_000)
```

Prefer max-minus-min. Do not introduce a shared `assertApproximatelyEqual`
helper — that reintroduces the "failure is reported at the helper's line, not the
call site" problem that `#expect`'s macro expansion exists to solve.

## 6. `try XCTUnwrap(x)` → `try #require(x)`

```swift
// BEFORE
let row = try XCTUnwrap(popover.test_row(for: "homepod-1"))
XCTAssertEqual(row.title, "Kitchen")
```

```swift
// AFTER
let row = try #require(popover.test_row(for: "homepod-1"))
#expect(row.title == "Kitchen")
```

**This one changes control flow. Read this before converting any `XCTUnwrap`.**

- The enclosing `@Test func` **must be `throws`** (or `async throws`). Add it if
  the original wasn't `throws` — `XCTUnwrap` sites always were, but a helper that
  wrapped one may not have been.
- `#require` **throws on nil and stops the test right there**, exactly like
  `XCTUnwrap`. That is the whole point: the lines after it assumed a non-nil value.
- **Never downgrade a `XCTUnwrap` to `#expect(x != nil)` followed by `x!` or
  optional chaining.** `#expect` records the failure and *keeps going*, so the
  next line then force-unwraps nil and crashes the process, or silently no-ops
  through `?.` and the test reports a confusing second failure. If you find
  yourself reaching for that because making the function `throws` is awkward,
  stop and make it `throws`.
- Nested inside another expectation, hoist it to its own `let` first:

```swift
// BEFORE (PopoverControllerTests.swift ~line 708)
XCTAssertEqual(try XCTUnwrap(popover.test_cardBodyClipHeight(title: title)), fitting, accuracy: 0.5, "...")
// AFTER
let clipHeight = try #require(popover.test_cardBodyClipHeight(title: title))
#expect(abs(clipHeight - fitting) <= 0.5, "...")
```

`#require` also has a boolean form (`try #require(someCondition)`) for "stop the
test here if this precondition fails" — use it only where the original code
genuinely stopped.

## 7. `XCTAssertThrowsError`

All three forms below compile and pass in this toolchain (verified). Pick by what
the original `{ error in ... }` block was checking.

```swift
// BEFORE — only cares THAT it threw
XCTAssertThrowsError(try mgr.create(), "must refuse to reuse a regular file at the FIFO path")
// AFTER
#expect(throws: FIFOManagerError.self, "must refuse to reuse a regular file at the FIFO path") {
    try mgr.create()
}
```

```swift
// BEFORE — checks the error equals a specific case
XCTAssertThrowsError(try controller.createGroup(name: "Empty", memberIDs: [])) { error in
    XCTAssertEqual(error as? GroupController.GroupError, .emptyMembership)
}
// AFTER — the value form; the error type must be Equatable (these are)
#expect(throws: GroupController.GroupError.emptyMembership) {
    try controller.createGroup(name: "Empty", memberIDs: [])
}
```

```swift
// BEFORE — the block does real inspection, not just an equality check
XCTAssertThrowsError(try catchingObjCException { ... }) { error in
    guard let objcError = error as? ObjCExceptionError else {
        XCTFail("Expected ObjCExceptionError, got \(error)")
        return
    }
    XCTAssertEqual(objcError.name, "AUDTestException")
}
// AFTER — the closure form; return Bool, don't assert inside it
#expect {
    try catchingObjCException { ... }
} throws: { error in
    guard let objcError = error as? ObjCExceptionError else { return false }
    return objcError.name == "AUDTestException"
}
```

Notes:

- In the `throws:` closure form the closure returns `Bool`. Do not put `#expect`
  calls inside it — return the condition. (If you truly need multiple detailed
  sub-checks, `let err = try #require(...)` on a `do/catch` is clearer.)
- `#expect(throws: (any Error).self) { ... }` is accepted (verified) for the
  "don't care which error" case — note the parentheses. Prefer a concrete type
  when you can name it, since it catches a wrong-error regression.
- The **inverse** — "this must not throw" — is `#expect(throws: Never.self) { ... }`.
  You will rarely need it; a plain `try` in a `throws` test already fails the test.
- `async` bodies work in all three forms: `await #expect(throws: E.self) { try await f() }` (verified).
- **`AirPlayEngine/Tests/AirPlayEngineTests/RemoteEventStreamTests.swift` defines
  its own private `XCTAssertThrowsErrorAsync` helper** (line ~142) purely because
  XCTest had no async form. Delete the helper and use
  `await #expect(throws: (any Error).self) { try await reader.next(timeout: 1) }`
  — or a concrete error type if you can name it — at the two call sites.

## 8. `XCTFail(msg)` → `Issue.record(msg)`

```swift
// BEFORE
default:
    XCTFail("unexpected state \(state)")
```

```swift
// AFTER
default:
    Issue.record("unexpected state \(state)")
```

`Issue.record` does **not** stop the test — same as `XCTFail`. If the original
followed `XCTFail` with `return` (or `XCTFail` inside a `guard ... else`), keep
the `return`; the control flow was doing real work.

## 9. `XCTSkip` / `XCTSkipUnless` → `.disabled(if:)` / `.enabled(if:)` traits

This is the biggest *shape* change in the whole migration: the decision moves
**out of the function body and onto the annotation**. Traits are evaluated before
the test runs, so nothing inside the body can influence them.

### `XCTSkipUnless` called from a shared helper (`AudioHardwareTestGate`)

```swift
// BEFORE — the gate lives in a helper every hardware test calls
static func skipUnlessEnabled(file: StaticString = #filePath, line: UInt = #line) throws {
    try XCTSkipUnless(isEnabled, "Real Core Audio hardware test. Set ... =1 to run")
}

final class SomeHardwareTests: XCTestCase {
    func testThing() throws {
        try AudioHardwareTestGate.skipUnlessEnabled()
        ...
    }
}
```

```swift
// AFTER — the gate becomes a static Bool, applied as a SUITE-level trait
@Suite(.enabled(if: AudioHardwareTestGate.isEnabled,
                "Real Core Audio hardware test. Set AIRPLAY_AUDIO_HARDWARE_TESTS=1 to run."))
struct SomeHardwareTests {
    @Test func thing() throws { ... }   // no gate call in the body
}
```

- The `skipUnlessEnabled()` **helper function disappears**; only the
  `static var isEnabled: Bool` survives. (`AudioHardwareTestGate.swift` is
  **T2's file** — do not edit it. Downstream tasks consume `isEnabled` and delete
  their own `try ...skipUnlessEnabled()` call lines.)
- Putting it on `@Suite` preserves the original intent stated in that file's doc
  comment — *"call from the single helper ... so a new test added to a gated suite
  inherits the gate"*. A suite-level trait gives exactly that inheritance; a
  per-`@Test` trait does not. **Prefer the suite-level trait.**
- The trait condition is a plain expression evaluated at discovery time. It must
  not depend on per-test state. Reading `ProcessInfo.processInfo.environment` (as
  every gate in this repo does) is fine.
- A skipped suite reports `Suite X skipped.` and its tests `Test y() skipped:
  "<reason>"`, so the reason string still surfaces. Verified.

### Unconditional `throw XCTSkip("...")` inside a body

```swift
// BEFORE
func testFoo() throws {
    throw XCTSkip("Set AIRPLAY_LIVE_DISCOVERY=1 to run live LAN discovery scans (D7 exception).")
    ...
}
```

```swift
// AFTER
@Test(.disabled("Set AIRPLAY_LIVE_DISCOVERY=1 to run live LAN discovery scans (D7 exception)."))
func foo() throws { ... }
```

`.disabled(if:)` / `.enabled(if:)` / `.disabled("reason")` / `.enabled(if:_:)`
all compile and behave as expected (verified).

### The awkward case: a skip that depends on runtime state

Some sites skip on something only discoverable *inside* the test — e.g.
`ControlPanelWindowControllerTests.swift`'s `throw XCTSkip("no NSScreen.main in
this environment")`, `LocalOutputLatencyTests.swift`'s "no default output device"
after a probe throws, `PTPHelperIPCTests.swift`'s port-contention skip, and
`GroupControllerTests.swift:476`'s `"could not reach an empty selection on this
fleet"` (which depends on state built up earlier in the same test).

For these, hoist the condition into a `static let` on a small enum computed once,
and use it as a trait:

```swift
enum ScreenGate { static let hasMainScreen = NSScreen.main != nil }

@Suite(.enabled(if: ScreenGate.hasMainScreen, "no NSScreen.main in this environment"))
@MainActor struct ControlPanelWindowControllerTests { ... }
```

**If the condition genuinely cannot be hoisted** — it depends on values produced
partway through the test body — do NOT invent something. Leave the test converted
but flag it in your task report so a human decides between (a) restructuring the
test so the gate is computable up front, or (b) making it a `withKnownIssue`
/ early `return`. `GroupControllerTests.swift:476` is the known instance of this.

## 10. `XCTestExpectation` + `fulfillment(of:timeout:)` → `confirmation`

**The critical semantic difference: `confirmation` does not wait.** It runs its
body, then checks the confirmation was called the expected number of times. The
*waiting* has to be real `await` inside the body. XCTest's `fulfillment(of:timeout:)`
did the waiting for you.

The repo's dominant pattern — start a `Task` that drains an `AsyncStream`, fulfill
when enough events arrive, then `await fulfillment(...)` — converts like this:

```swift
// BEFORE (MockBackendTests.swift ~line 14)
private func collect(_ count: Int, from backend: MockBackend, timeout: TimeInterval = 2) async throws -> [BackendEvent] {
    let stream = backend.makeEventStream()
    let expectation = expectation(description: "received \(count) events")
    let box = EventBox()
    let task = Task {
        for await event in stream {
            if case .level = event { continue }
            if await box.append(event) >= count { expectation.fulfill(); break }
        }
    }
    backend.start()
    await fulfillment(of: [expectation], timeout: timeout)
    task.cancel()
    return await box.events
}
```

```swift
// AFTER
private func collect(_ count: Int, from backend: MockBackend, timeout: Duration = .seconds(2)) async throws -> [BackendEvent] {
    let stream = backend.makeEventStream()
    let box = EventBox()
    try await confirmation("received \(count) events") { received in
        let task = Task {
            for await event in stream {
                if case .level = event { continue }
                if await box.append(event) >= count { received(); break }
            }
        }
        defer { task.cancel() }
        backend.start()
        // The body must do the waiting itself — `confirmation` does not.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = await task.value }
            group.addTask { try await Task.sleep(for: timeout) }
            try await group.next()
            group.cancelAll()
        }
    }
    return await box.events
}
```

Points that matter:

- `confirmation(_:expectedCount:_:)` defaults to `expectedCount: 1`. An
  expectation with `expectedFulfillmentCount = N` becomes `expectedCount: N`.
- A `.isInverted` expectation ("this must NOT happen") becomes
  `expectedCount: 0` — and you still have to actually let time pass in the body
  for that to mean anything.
- `confirmation` is `async`; the enclosing test must be `async`.
- **Simpler is usually available.** Many of these waits are really "poll until a
  predicate holds". If the code under test exposes a synchronous state you can
  poll, a plain loop is clearer and less fragile than a confirmation:

  ```swift
  var deadline = 200   // 200 × 10ms = 2s
  while !predicate() && deadline > 0 { try await Task.sleep(for: .milliseconds(10)); deadline -= 1 }
  #expect(predicate(), "timed out waiting for ...")
  ```

  Use `confirmation` where the thing being asserted is genuinely *"this callback
  fired, exactly N times"* — that's what it's for and what it reports well.
- Do not silently drop the timeout. A converted wait that can hang forever will
  wedge CI. If you can't express the timeout cleanly, flag it.

## 11. `setUp` / `tearDown` / `setUpWithError` / `tearDownWithError` → `init` / `deinit`

swift-testing creates a **fresh suite instance per test** (verified), so stored
properties are per-test state exactly like `XCTestCase`'s were.

```swift
// BEFORE
final class AppSettingsTests: XCTestCase {
    override func setUp() { AppSettings.shared._resetForTesting() }
    override func tearDown() { AppSettings.shared._resetForTesting() }
    func testFoo() { ... }
}
```

```swift
// AFTER
@Suite struct AppSettingsTests {
    init() { AppSettings.shared._resetForTesting() }
    @Test func foo() { ... }
}
```

`setUpWithError()` → `init() throws` (verified). Both plain and throwing forms work.

### ⚠️ `deinit` is NOT allowed on a `struct` — this is a hard compile error

```
error: deinitializer cannot be declared in struct 'X' that conforms to 'Copyable'
```

Two verified fixes, **in order of preference**:

**(a) If teardown is only undoing global state, just do it in `init` of the next
test.** Most of this repo's `tearDown()` bodies are `Something._resetForTesting()`
— identical to the `setUp()` body. Since `init` runs before every test, a reset in
`init` alone is sufficient and the `deinit` isn't needed at all. Prefer this.

**(b) If teardown genuinely must run (owns a temp directory, an installed sink, a
bound port), make the suite a `final class`:**

```swift
// AFTER — verified: compiles, runs, deinit fires
@Suite final class FIFOManagerSecurityTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    @Test func refusesRegularFileAtPath() throws { ... }
}
```

(A `struct ...: ~Copyable` with a `deinit` also compiles and runs — verified — but
`final class` is far less surprising to the next reader. Use `final class`.)

### `deinit` cannot be `async` or `throws`

There is no workaround inside `deinit`. If teardown needs to `await` something:

1. **Preferred:** move the awaited cleanup to the end of the test body itself, or
   into a small `func` the test calls — the tests that need this are few.
2. Wrap the awaitable work in a synchronous shutdown call if the type has one
   (several of this repo's coordinators expose a synchronous `stop()`).
3. If neither is possible, flag it. Do **not** spawn a detached `Task` from
   `deinit` to do the cleanup — it will race the next test.

Also: `deinit` on a `@MainActor` class is `nonisolated`, so it cannot touch
main-actor state. If teardown needs the main actor, use option (1).

## 12. `addTeardownBlock { }`

`addTeardownBlock` exists so cleanup runs even when an assertion above it fails.
Under swift-testing a failed `#expect` does **not** unwind the function, so the
straightforward translation is fine — but a `#require` or a thrown error *does*,
so use `defer` when anything after the setup can throw.

```swift
// BEFORE (NativeCaptureCoordinatorTests.swift ~line 829)
func testStartEmitsCaptureWSTransitionTelemetry() {
    let capturedLines = TelemetryLineBox()
    Telemetry._installTestSink { capturedLines.append($0) }
    addTeardownBlock { Telemetry._installTestSink(nil) }
    ...
}
```

```swift
// AFTER — `defer` covers early exits and thrown errors alike
@Test func startEmitsCaptureWSTransitionTelemetry() {
    let capturedLines = TelemetryLineBox()
    Telemetry._installTestSink { capturedLines.append($0) }
    defer { Telemetry._installTestSink(nil) }
    ...
}
```

If several tests in the same suite install the same teardown, hoist it to
`init` + `deinit` on a `final class` suite (§11b) instead of repeating `defer`.

## 13. Naming convention

Covered in §0. Restated because it is the single most mechanical rule and the
easiest to apply inconsistently across 15 agents:

| Before | After |
| --- | --- |
| `final class FooTests: XCTestCase` | `@Suite struct FooTests` (or `final class`, §11b) |
| `func testBarBaz()` | `@Test func barBaz()` |
| `func testHTTPHeaderIsSet()` | `@Test func httpHeaderIsSet()` — lowercase only the first letter |
| `private func makeThing()` | unchanged |

Do not add a `@Test("display name")` string. The function name is the display
name and these names are already sentence-length.

## 15. `@MainActor`

`@MainActor` on the `@Suite` type works exactly as it did on the `XCTestCase`
subclass, and applies to every `@Test` in it — including `async` ones (verified:
an `async` test in a `@MainActor` suite runs on the main actor).

```swift
// BEFORE
@MainActor
final class PopoverControllerTests: XCTestCase { ... }
```

```swift
// AFTER — attribute order doesn't matter; keep it on its own line as the repo does
@MainActor
@Suite struct PopoverControllerTests { ... }
```

A single main-actor test inside an otherwise nonisolated suite also works:

```swift
@Suite struct MixedTests {
    @MainActor @Test func needsMainActor() { ... }
    @Test func doesNot() { ... }
}
```

Keep the existing doc comments explaining *why* a suite is `@MainActor` — e.g.
`MixerWindowControllerTests.swift`'s note that `MixerWindowController` is itself
`@MainActor`.

---

## Symbols the grep sweep finds that are NOT XCTest APIs

`grep -rhoE 'XCT[A-Za-z]+' .../Tests` turns up three false positives. Do not try
to "convert" them:

| Symbol | Reality |
| --- | --- |
| `XCTAssertFalseModelProbing` | `SetupModelTests.swift:114` — a **locally defined private helper** whose name merely starts with `XCTAssert`. Rename it to `expectModelIsNotProbing` and convert its body's assertions normally. |
| `XCTestNeverTouchesProductionPath` | `TelemetryTests.swift:109` — part of a **test method name** (`testDefaultUnderXCTestNeverTouchesProductionPath`). Becomes `defaultUnderXCTestNeverTouchesProductionPath`. **Keep "XCTest" in the name only if the behaviour under test really is XCTest-process detection** — it is: `HeadlessRuntime`/`Telemetry` detect an XCTest process, and that detection still holds under `swift test` because the swift-testing runner loads XCTest into the same process (verified: `HeadlessRuntimeTests` passes as a `@Suite`). |
| `XCTAssertThrowsErrorAsync` | `RemoteEventStreamTests.swift:142` — a locally defined async shim. **Delete it**; see §7. |

Also note `XCTest` / `XCTestCase` in the raw counts include occurrences inside
doc comments and string literals. Update prose that now describes the wrong
framework, but don't mangle comments that are genuinely *about* XCTest-process
detection (see the `Telemetry` row above, and `AudioutCore/AGENTS.md`'s
`HeadlessRuntime` rule).

## Full sweep coverage checklist

Every symbol from the sweep, and where it's handled:

| Count | Symbol | Section |
| ---: | --- | --- |
| 1760 | `XCTAssertEqual` | §2 (and §5 for the `accuracy:` variants) |
| 515 | `XCTAssertTrue` | §1 |
| 262 | `XCTAssertFalse` | §1 |
| 126 | `XCTAssertNil` | §4 |
| 97 | `XCTUnwrap` | §6 |
| 95 | `XCTFail` | §8 |
| 95 | `XCTAssertNotNil` | §4 |
| 84 | `XCTest` (import / prose) | §0 |
| 65 | `XCTestCase` | §0, §14 |
| 48 | `XCTAssertGreaterThan` | §4b |
| 40 | `XCTAssertGreaterThanOrEqual` | §4b |
| 35 | `XCTAssertLessThan` | §4b |
| 34 | `XCTAssertNotEqual` | §3 |
| 21 | `XCTAssertLessThanOrEqual` | §4b |
| 11 | `XCTAssertThrowsError` | §7 |
| 10 | `XCTSkip` | §9 |
| 2 | `XCTAssertThrowsErrorAsync` | false positive — local shim, §7 |
| 2 | `XCTAssertFalseModelProbing` | false positive — local helper |
| 1 | `XCTestNeverTouchesProductionPath` | false positive — method name |
| 1 | `XCTSkipUnless` | §9 |

Plus the non-`XCT*` XCTest surface: `expectation(description:)`,
`fulfillment(of:timeout:)`, `wait(for:timeout:)` (§10), and
`setUp`/`tearDown`/`setUpWithError`/`tearDownWithError`/`addTeardownBlock`
(§11–12).

## Per-file checklist

1. Swap the imports (`XCTest` → `Testing`, add `Foundation` if needed).
2. Class → `@Suite struct` (or `final class` if teardown is real). One per class
   in the file.
3. `func testX` → `@Test func x`.
4. Convert assertions, working outward from the trickiest (`XCTUnwrap`,
   `accuracy:`, `ThrowsError`, skips, expectations) so the mechanical ones don't
   hide them.
5. Add `throws` to any test that gained a `#require`; add `async` to any that
   gained a `confirmation`.
6. `grep -n 'XCT' <file>` — must return nothing except intentional prose.
7. `cd AudioutCore && swift test --filter <SuiteName>` — must show the **same
   number of tests** as before, all passing. A dropped test is the failure mode
   to watch for: a `@Test` attribute forgotten on one function makes it vanish
   silently with no error.
8. Do **not** commit. Leave the change in the worktree for the orchestrator.

## Files owned by T2 — do not edit

`IsolatedSuite.swift`, `AudioHardwareTestGate.swift`, `HeadlessRuntime.swift`.
If your file subclasses `IsolatedTestCase` or calls `AudioHardwareTestGate`,
convert everything else and follow T2's replacement API for those seams.

---

# Part II — the shared seams (T2, 2026-07-26)

Everything below was compiled and run on the same toolchain as Part I. It
covers the three cross-cutting seams that Wave-2 conversions have to consume,
plus the `HeadlessRuntime` change that makes the END STATE of this migration
safe. **Read §16–§18 before converting any file that subclasses
`IsolatedTestCase`, calls `AudioHardwareTestGate`, or touches
`Telemetry._installTestSink`.**

## 16. `IsolatedTestCase` → `IsolatedSuite`

`Tests/AudioutCoreTests/IsolatedSuite.swift` holds **two** types:

| Type | Use |
| --- | --- |
| `TestIsolation` | The mechanism (scratch dir, isolated defaults, unique names, cleanup). You normally don't touch it directly. |
| `IsolatedSuite` | **The swift-testing base class. Inherit this.** |

The two bases expose an **identical** member set over the same mechanism, so
migrating is a base-class swap and nothing else:

```swift
// BEFORE
@MainActor
final class MixerWindowControllerTests: IsolatedTestCase {
    private lazy var autosave = NSWindow.FrameAutosaveName(uniqueName("MixerWindow"))
    func testFoo() { ... }
}
```

```swift
// AFTER
@MainActor
@Suite final class MixerWindowControllerTests: IsolatedSuite {
    private lazy var autosave = NSWindow.FrameAutosaveName(uniqueName("MixerWindow"))
    @Test func foo() { ... }
}
```

- **It must be a `final class`, not a `struct`.** Structs can't inherit, and
  §11's `deinit`-on-struct compile error applies anyway. This is the one place
  in the migration where `final class` is mandatory rather than a preference.
- `scratchDir`, `isolatedDefaults`, `uniqueName(_:)` and `isolationToken` read
  exactly as before. `scratchDir` is still named after the concrete subclass
  (`Self.self` resolves to it — verified), so temp paths stay legible.
- **Verified on this toolchain**: a `@Suite final class X: <base class>` is
  discovered normally, instantiated fresh per test, and its `deinit` fires after
  each test.
- The 8 files to convert:
  `LocalOutputLatencyTests`, `MixerWindowControllerTests`,
  `NativeBackendSyncedLocalSelectionTests`, `PermissionModeTests`,
  `PhaseControllerTests`, `SyncedLocalFanoutTests`, `SyncedLocalSinkTests`,
  `TelemetryTests`. Only three actually use a member (`TelemetryTests` →
  `scratchDir`, `PermissionModeTests` → `isolatedDefaults`,
  `MixerWindowControllerTests` → `uniqueName`); the rest inherit for safety and
  convert with the base-class swap alone.
- **Done** (the T20 cleanup item): the legacy XCTest base and the file's
  `import XCTest` are deleted. `git grep IsolatedTestCase` finds nothing.

### `override func tearDown()` on a subclass → `deinit`

`TelemetryTests` is the case that matters: its `tearDown()` releases Telemetry's
grip on `scratchDir` **before** the base removes that directory, then calls
`super.tearDown()`.

```swift
// BEFORE
override func tearDown() {
    Telemetry._installTestSink(nil)
    Telemetry._resetForTesting(directory: nil)
    super.tearDown()
}
```

```swift
// AFTER
deinit {
    Telemetry._installTestSink(nil)
    Telemetry._resetForTesting(directory: nil)
    // no `super.deinit` — it doesn't exist and isn't needed
}
```

The ordering is preserved for free: Swift runs a subclass's `deinit`, then each
superclass's, and only **then** releases stored properties — so the base's
cleanup (which lives on the `TestIsolation` property) still runs last. Verified
by printing from both.

Constraints carried over from §11: `deinit` is `nonisolated` even on a
`@MainActor` class, and cannot be `async` or `throws`. If teardown needs any of
those, move it to the end of the test body.

## 17. `AudioHardwareTestGate` → a suite-level trait on ONE nested suite

`AudioHardwareTestGate` now exposes:

- `static var isEnabled: Bool` — unchanged.
- `static var trait: ConditionTrait` — **the thing you apply.**
- `static let skipReason: String` — the message, for reference.
- `static func skipUnlessEnabled()` — LEGACY, XCTest only. Delete the call from
  `LocalPlaybackEngineTests.makeStartedEngine()`; the function itself (and the
  file's `import XCTest`) goes when the last caller is gone.

**Why a nested suite and not per-test traits.** The gate's stated purpose is
that it lives at ONE choke point, so a newly added hardware test inherits it
rather than silently re-introducing hardware load. Under XCTest that choke point
was the shared `makeStartedEngine()` helper. swift-testing evaluates skip
conditions as traits **before the body runs**, so a helper can no longer gate
anything. The equivalent single choke point is a suite-level trait, because a
suite trait applies to every test in that suite (and in suites nested inside it),
whereas a `@Test`-level trait applies to exactly one function.

```swift
@Suite struct LocalPlaybackEngineTests {

    // The 3 pure/static tests (isFollowableTransport …) stay out here and
    // always run — they need no hardware.
    @Test func isFollowableTransportRejectsAirPlay() { ... }

    /// Every test that drives a real `AVAudioEngine` against the Mac's actual
    /// output. The trait IS the gate — do not add per-test `.enabled(if:)`,
    /// and do not move a hardware test out of this suite.
    @Suite(AudioHardwareTestGate.trait)
    struct RealHardware {
        // `makeStartedEngine()` moves in here with the tests that use it, and
        // its `try AudioHardwareTestGate.skipUnlessEnabled()` line is deleted.
        private func makeStartedEngine() throws -> LocalPlaybackEngine { ... }

        @Test func startedEngineProducesOutput() throws { ... }
    }
}
```

Verified end to end: with the variable unset the runner prints
`Suite RealHardware skipped: "Real Core Audio hardware test. Set
AIRPLAY_AUDIO_HARDWARE_TESTS=1 to run (…)"` **and** the same reason against each
test inside it, so the lost coverage stays as legible as it was under
`XCTSkipUnless`; with `AIRPLAY_AUDIO_HARDWARE_TESTS=1` the nested suite runs.

The trait condition is evaluated at discovery time and must not depend on
per-test state — reading the environment (all this does) is fine.

## 18. Process-global shared state → `SerializedSharedState`

**This is a real behaviour change, not a style one. Read it before converting
any of the five files listed below.**

Under XCTest, `--parallel` gave every test *method* its own process, so a test
that installed a process-global hook physically could not collide with another
one. swift-testing runs tests **concurrently inside one process**, so that
safety disappears the moment these suites are converted: two tests that both
call `Telemetry._installTestSink(_:)` overwrite each other's sink and read back
a mixture of both tests' lines.

`Tests/AudioutCoreTests/SerializedSharedStateSuite.swift` declares:

```swift
@Suite(.serialized)
struct SerializedSharedState {}
```

Plug a suite in by declaring it **inside an extension of that type**, in its own
file, exactly where it already lives:

```swift
// TelemetryTests.swift — file does not move
extension SerializedSharedState {
    @Suite final class TelemetryTests: IsolatedSuite {
        @Test func writesToTheInjectedDirectory() { ... }
    }
}
```

Why one shared parent rather than putting `.serialized` on each of the five
suites: `.serialized` orders tests **within** the suite it's applied to. Five
independently-serialized suites would each be internally ordered but would still
run *against each other* — which is the collision that matters, since the state
is global to the process. **Verified**: two child suites nested under one
`.serialized` parent via extensions ran with a measured maximum concurrent
overlap of 1; nothing from one child ever overlapped the other.

The five files (confirmed by `git grep _installTestSink` over
`Tests/AudioutCoreTests`, not from an estimate):

| File | Seam |
| --- | --- |
| `TelemetryTests.swift` | `_installTestSink` + `_resetForTesting(directory:)` |
| `NativeCaptureCoordinatorTests.swift` | `_installTestSink` |
| `PerAppCaptureCoordinatorTests.swift` | `_installTestSink` |
| `NativeBackendTests.swift` | `_installTestSink` |
| `SetupModelTests.swift` | `_installTestSink` |

Rules:

- Do **not** repeat `.serialized` on the child suite — it inherits.
- The suite's full name becomes `SerializedSharedState.TelemetryTests`, but
  `swift test --filter TelemetryTests` still matches (substring/regex on the
  full name), so the inner-loop convention in `AudioutCore/AGENTS.md` is
  unchanged. Your per-file verification step is unaffected.
- Nesting changes nothing about member lookup: the suite can still inherit
  `IsolatedSuite`, be `@MainActor`, and use the file's private helpers.
- **Serialization is not teardown.** Keep every
  `defer { Telemetry._installTestSink(nil) }` (§12). Serialized means *not at
  the same time*, not *undone afterwards* — the next test inherits whatever the
  previous one left installed.
- Don't add suites here that only need per-test temp dirs or defaults;
  `IsolatedSuite` already isolates those and they should stay parallel.
  Everything under this parent runs strictly one at a time.

## 19. `HeadlessRuntime.isActive` now detects swift-testing too

`Sources/AudioutCore/HeadlessRuntime.swift` gates every window/panel
`show*()` entry point in ~10 shipping source files. It used to detect a test run
solely by `NSClassFromString("XCTestCase") != nil`. That still works today —
`swift test` loads XCTest into the process even for a pure swift-testing target
— but the end state of this migration removes `import XCTest` from every file,
and if the check ever silently returned `false` under `swift test`, real empty
windows would flash on the developer's screen for the length of every run.

It is now:

```swift
public static var isActive: Bool {
    if ProcessInfo.processInfo.environment["AIRPLAY_HEADLESS"] == "1" { return true }
    return isXCTestLoaded || isSwiftTestingLoaded
}
```

`Testing` is a pure-Swift module with no Objective-C classes, so
`NSClassFromString` cannot see it (verified: `NSClassFromString("Testing.Test")`
and the mangled variants all return nil). It is detected instead by `dlsym`-ing
its type-descriptor symbols against `RTLD_DEFAULT`
(`$s7Testing4TestVMn` — the nominal type descriptor for `Testing.Test` — plus
`Testing.Issue` as a second candidate), computed once into a `static let`.

Proven, not assumed:

- In a throwaway SwiftPM package with **no `import XCTest` anywhere**, the
  symbol resolves under `swift test`.
- The same check in a plain `swift run` executable of that package reports
  **false** — so the real app is not misdetected as a test run.
- `HeadlessRuntimeTests.swiftTestingIsDetectedIndependentlyOfXCTest` asserts the
  swift-testing limb **directly**, so a break can't hide behind the still-linked
  XCTest while the migration is in flight.

**Nothing to do per file** — this is informational. Do not remove either limb:
mid-migration both fire, end-state the swift-testing one does, and the XCTest
one still covers any legacy or Xcode-hosted run.

## 20. Two small gotchas Part I doesn't cover

- **`#expect`'s message argument is a `Comment`, and only a string *literal*
  converts.** `#expect(x, "a " + "b")` is
  `error: cannot convert value of type 'String' to expected argument type 'Comment?'`.
  Join the text into one literal (interpolation is fine), or wrap it in
  `Comment(rawValue:)`.
- **`dlsym`'s C-string bridging fails inside a generic closure.**
  `["sym"].contains { dlsym(p, $0) != nil }` doesn't compile
  (`cannot convert value of type 'String' to expected element type
  'UnsafePointer<CChar>?'`); calling a tiny `func symbolIsLinked(_ s: String)`
  from the closure does. Only relevant if you write another symbol probe.

---

# Part III — AirPlayEngine (T3, 2026-07-26)

`AirPlayEngine` is the **lower** package — `AudioutCore` depends on it, not
the reverse — so its test target cannot `import` anything from
`AudioutCoreTests` (`TestIsolation`, `IsolatedSuite`,
`SerializedSharedState`). Everything in Part II had to be re-declared as its
own thing inside `AirPlayEngine/Tests/AirPlayEngineTests/`, following the same
*pattern*, not the same code.

## 21. Toolchain re-verified independently for this package

Part I's environment table was re-checked here rather than assumed to carry
over: `AirPlayEngine/Package.swift` is also `swift-tools-version:5.10`, no
`Package.swift` change was needed for `import Testing` to resolve, and a
throwaway probe suite (built, run via `swift test --filter`, then deleted —
see §22) compiled and ran cleanly mixed into the same `AirPlayEngineTests`
target as its 144 untouched `XCTestCase` tests, with no drop in the XCTest
count. Same result as Part I's AudioutCore-side proof, confirmed
separately rather than inferred.

## 22. `SerializedEngineState` — AirPlayEngine's `SerializedSharedState`

`Tests/AirPlayEngineTests/SerializedEngineStateSuite.swift` declares:

```swift
@Suite(.serialized)
struct SerializedEngineState {}
```

Consumers nest in exactly like §18's `SerializedSharedState`:

```swift
// OutputsDispatcherTests.swift — file does not move
extension SerializedEngineState {
    @Suite final class OutputsDispatcherTests { // or struct — file's own choice
        @Test func ... () { ... }
    }
}
```

**The reason this suite exists is narrower than AudioutCore's — a different
C registry, not `Telemetry`.** `shims/outputs.c` keeps the AirPlay
device/callback registry (`outputs_list`, the completion table —
`docs/outputs-dispatcher-contract.md`) as process-global C state, safe only
under XCTest's one-process-per-test-**method** model. The migration plan
estimated **6** files sharing this; the real count, confirmed by
`grep -rl "outputs_dispatcher_reset\|outputs_list\|outputs_engine_completion_set"
AirPlayEngine/Tests/` (T3), is **5**:

| File |
| --- |
| `AirPlayEngineAPITests.swift` |
| `OutputsDispatcherTests.swift` |
| `E1StabilityTests.swift` |
| `StateStreamTests.swift` |
| `MultiStreamWriteRoutingTests.swift` |

`PTPHelperIPCTests.swift` — the plan's 6th guess — does **not** belong here.
It mutates a *different* set of C globals entirely: `libairptp`'s
`airptp_event_port` / `airptp_general_port` / `airptp_shm_name` (via
`ptp_test_ports_override()` / `ptp_test_shm_name_override()`, restored in its
`tearDown()`), not `shims/outputs.c`'s device registry. It's the only test in
its file today, so nothing collides with it yet — but if a second PTP-IPC
test is ever added, it needs its **own** serialized parent for the
`libairptp` globals, not this one. Don't fold unrelated global-state problems
into one lock just because both are "process-global C state" — that's
needless contention between tests that were never actually racing.

Also confirmed (T3): AirPlayEngine has **no existing equivalent** of
`IsolatedTestCase`/`IsolatedSuite` or `AudioHardwareTestGate`. A grep for any
custom `XCTestCase` base class in `AirPlayEngine/Tests/` turns up nothing —
every test file there subclasses `XCTestCase` directly. Wave-3 conversions of
the 5 files above only need the base-class-swap-free `@Suite struct`/`final
class` shape (§0/§14) plus nesting into `SerializedEngineState`; there is no
`IsolatedSuite`-equivalent base to inherit.

### Proving the pattern (then deleting the proof)

Two throwaway files, `_ProbeSerializedEngineStateA.swift` /
`_ProbeSerializedEngineStateB.swift`, each nested a probe suite into
`SerializedEngineState` from a **different file** — mirroring T2's
cross-file proof, not just a single-file `.serialized` check. One shared
`final class ... : @unchecked Sendable` box tracked concurrent-entry count
across both. `swift test --filter SerializedEngineState` showed `ProbeA`
start, run a deliberately slower body, and its suite report **passed**
*before* `ProbeB`'s suite even started — i.e. zero interleaving, matching
Part II's "measured max concurrent overlap of 1" result. Both files were then
deleted; only `SerializedEngineStateSuite.swift` (declaring the empty parent,
0 tests of its own) remains for Wave 3 to nest into.

One gotcha hit while building the probes: members referenced from a
**different file** in the same target must not be `private` — Swift's
`private` is file-scoped, not target-scoped, so a `private(set) var` or
`private func` on a helper type used from a sibling probe file fails to
compile with "inaccessible due to 'private' protection level". Use
`internal` (the default) for anything a cross-file extension-nested suite
needs to reach on a shared helper.

## 23. `PTPHelperIPCTests.swift`'s `XCTSkip` — left as a documented TODO, not converted

This file's one `throw XCTSkip(...)` (a real bind-attempt failure on
high test-only PTP ports, guarding against port contention) is a case §9
explicitly calls "the awkward case that CAN be hoisted" — unlike
`GroupControllerTests.swift:476`, it doesn't depend on state built up
earlier in the test body; a bind attempt, cached once, would do.

**It was not converted.** `.enabled(if:)` / `ConditionTrait` only attach to a
swift-testing `@Suite`/`@Test` declaration, and this file is still `final
class PTPHelperIPCTests: XCTestCase` — its full conversion (the file's other
`XCTAssertEqual`/`XCTAssertNotEqual`/`XCTFail` calls) is Wave 3's `T16`, not
this task's. There is no way to attach a `Testing` trait to a class that
XCTest still owns, so converting only the skip would force a partial file
conversion — exactly the situation §9/the task brief for this seam says to
leave documented instead of contorting.

A comment was added directly above the `throw XCTSkip` (line ~92) spelling
out the exact hoisted shape for T16 to drop in:

```swift
enum PortBindGate {
    static let canBindTestPorts: Bool = {
        guard let hdl = "127.0.0.1".withCString({ ptp_test_daemon_bind($0) }) else { return false }
        ptp_test_end(hdl)
        return true
    }()
}
@Suite(.enabled(if: PortBindGate.canBindTestPorts, "Could not bind PTP test ports \(eventPort)/\(generalPort); skipping (likely port contention)"))
```

Note this changes the runtime shape slightly: the gate does its own
probe-bind-then-release once at discovery time, and the test body still does
its own real bind afterward for the actual assertions — two bind/release
cycles against the high test ports instead of one. That's an acceptable
tradeoff (CI-safety of a cached, pre-body gate) for T16 to make explicitly,
not something to slip in silently under an unrelated task.

**Verified both branches behave identically to before this change** (the
comment addition has zero runtime effect): `swift test --filter
PTPHelperIPCTests` passes normally when the high ports are free, and reports
`Test skipped - Could not bind PTP test ports 30319/30320 - ...` when another
process (external `python3` socket bound to 127.0.0.1:30319/30320 for the
duration of the run) holds them.
