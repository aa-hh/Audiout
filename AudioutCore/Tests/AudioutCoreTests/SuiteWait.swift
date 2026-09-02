import Foundation
import Testing

/// The one way a test waits for something to become true.
///
/// WHY THIS EXISTS. Before this, every suite hand-rolled its own `waitFor` /
/// `pollUntil` / `waitForState` / `waitForCompletion`, and by 2026-08-29 there
/// were **37 of them across 29 files**, with deadlines of 2, 3, 5, 8 and 10
/// seconds chosen by whoever wrote that file. Three problems came out of that,
/// and this type exists to fix all three at once.
///
/// **1. The deadlines were sized against the operation, not against the
/// machine.** Every one of these waits is scaffolding: the thing under test is
/// a STATE that should arrive, and the clock is only there so a broken test
/// cannot hang forever. But a fixed wall-clock deadline does not measure the
/// code under test, it measures how promptly this machine's scheduler gets
/// round to the poll — and this repo runs several suites at once, on a machine
/// that also carries agents, an editor and sometimes a live app under test.
/// Measured on 2026-08-29: pristine `main` failed 11 tests at one such deadline,
/// twice in a row; raising that single file's deadline from 3s to 30s took the
/// same tree to 3121/3121 green, three independent times. The deadline was
/// never the bug's cause, it was the bug's *reporter*.
///
/// **2. Raising an individual number does not hold.** Two files had already had
/// that treatment before this audit and failed again anyway —
/// `TCCProbeRunnerTests` carried a 10-second deadline and a comment from
/// whoever raised it, and `BTConnectionManagerTests` had been widened from a
/// `< 5` assertion to `< 60` and was then seen to blow through at 65.8s. A
/// number that is generous today is a number somebody has to raise again the
/// next time the machine gets busier, which is why the fix is one shared
/// deadline with a written rationale rather than sixty private ones.
///
/// **3. Most of them failed OPEN, which is a correctness bug, not a flake.**
/// 52 of the ~55 waits simply `return`ed when the deadline passed, recording
/// nothing. A starved wait therefore reported itself as a failure of whatever
/// assertion came NEXT — the `TCCProbeRunnerTests` starvation surfaced as
/// "Confirmation was confirmed 0 times", pointing at the confirmation instead
/// of at the wait that had actually expired. Worse, a wait that gives up
/// silently can let a test pass vacuously: if nothing after it asserts on the
/// state it was waiting for, expiry is indistinguishable from success. Every
/// wait here fails CLOSED, and reports at the CALL SITE via the forwarded
/// `sourceLocation` rather than at a line inside this file.
///
/// ## Sizing
///
/// ``timeout`` is deliberately far larger than any operation these tests
/// perform. That is the point: it is a hang-catcher, not a performance
/// assertion, so the only cost of generosity is paid by a test that was going
/// to fail anyway. It costs nothing on the happy path, because every wait here
/// returns on the first satisfied poll — measured 2026-08-29, the green run of
/// a suite whose deadlines had been raised took 149s against the red run's
/// 127s and 162s. A red run is not the faster one: a starved test burns its
/// FULL deadline before recording.
///
/// The number is sized against machine contention, and the contention is
/// configurable — `scripts/run-tests.sh` runs up to `AUDIOUT_TEST_SLOTS`
/// suites at once, a cap that was raised from 2 to 4 on 2026-08-29 (947458ae)
/// on the correct observation that the suite is wait-bound and so overlaps
/// almost for free on CPU. It does NOT overlap for free on wall clock: being
/// wait-bound is exactly why these deadlines starve, because what they wait on
/// is scheduler latency. **If that cap rises again, this number is the thing to
/// revisit** — and revisiting one constant here is the whole reason not to
/// have sixty of them.
///
/// ## Use
///
/// ```swift
/// await SuiteWait.until("the coordinator reaches .running") { coord.state == .running }
/// SuiteWait.untilOnRunLoop("the row appears") { controller.rows.count == 1 }
/// ```
///
/// A suite that already has its own `waitFor` should make that method a thin
/// forwarder to one of these (passing `sourceLocation` straight through) rather
/// than keeping a second implementation — call sites then need no edit at all.
enum SuiteWait {

    /// The one deadline. See "Sizing" above before changing it.
    static let timeout: TimeInterval = 30

    /// ## Why `timeout` is optional, and what passing one MEANS
    ///
    /// Leaving `timeout` nil says **"this must happen"**: you get ``timeout``
    /// and a recorded failure if it doesn't. Passing an explicit value says
    /// **"I meant this expiry"** — a negative check ("confirm the fallback does
    /// NOT fire within 0.5s") or a settle — and expiry is then silent, because
    /// it is the success path.
    ///
    /// This distinction is not decoration: a blanket fail-closed breaks every
    /// negative and settle in the suite (proven immediately — the first version
    /// of this type failed three of them), and a blanket fail-open is what hid
    /// the starvation this type exists to fix. Encoding it in the signature
    /// means neither can be chosen by accident.
    ///
    /// **KNOWN GAP — do not read an explicit timeout as an audited decision.**
    /// The migration that introduced this type converted the helpers whose
    /// deadline was a DEFAULT. It did not audit the call sites that pass an
    /// explicit one, and most of those are not negatives at all: of 88
    /// `pollUntil(timeout:)` sites in `NativeBackendTests` alone, 87 carry a
    /// real positive condition — `{ tap.isArmed }`, `{ activator.holding }` —
    /// on a 3s or 5s deadline. Those still fail OPEN, and still misattribute
    /// their starvation to whatever assertion follows. They are unconverted
    /// work, not deliberate choices. Before treating any explicit timeout as
    /// intentional, read its condition: if it is positive, it belongs on the
    /// nil-timeout path and nobody has moved it yet.
    ///
    /// For an unconditional pause, prefer ``settle(_:)`` — it says so outright.

    /// Poll `condition` from an async context until it holds.
    ///
    /// `description` is what the reader needs in the failure message: name the
    /// state being waited FOR, not the act of waiting ("the coordinator reaches
    /// .running", not "waiting for state").
    static func until(
        _ description: @autoclosure () -> String = "condition to hold",
        timeout: TimeInterval? = nil,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        let limit = timeout ?? Self.timeout
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard timeout == nil else { return }   // explicit deadline: expiry is the point
        // Fail CLOSED, at the caller. A silent return here is what let a
        // starved wait masquerade as the next assertion's failure.
        Issue.record(
            "timed out after \(limit)s waiting for \(description())",
            sourceLocation: sourceLocation
        )
    }

    /// Pump the main run loop for a fixed period, unconditionally.
    ///
    /// The honest spelling of `waitFor(timeout: 0.3) { false }` — a condition
    /// that can never be true is a sleep wearing a wait's clothes, and reads at
    /// the call site as though something is being awaited. Use this to let a
    /// thing that should NOT happen have its chance to happen.
    /// The loop is NOT decoration, and a single `RunLoop.run(until:)` is not a
    /// substitute for it: that call returns IMMEDIATELY when the run loop has no
    /// input sources attached, which is the normal state in these tests. Written
    /// the obvious way, this method waited zero seconds and every negative
    /// assertion after it passed vacuously — measured, not theorised: a suite
    /// carrying 5.1s of settles ran in 1.207s instead of 6.331s. Only the
    /// wall-clock `while` actually spends the time.
    ///
    /// **MAIN-THREAD ONLY.** Even with the loop, this only settles where the
    /// run loop has something to pump. Measured: a 0.3s settle returns in
    /// 0.003s on a secondary thread and 0.00002s on a cooperative-pool thread,
    /// against 0.302s on main. Every current caller is a `@MainActor` sync
    /// test, which is why it works — but called from an `async` or detached
    /// context it silently does nothing and the negative check after it passes
    /// vacuously. If you need to settle off the main thread, sleep on the
    /// clock instead; do not reach for this.
    static func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// Poll `condition` while pumping the main run loop, for tests whose state
    /// only advances when AppKit or a main-queue callback gets to run.
    ///
    /// Separate from ``until(_:timeout:sourceLocation:_:)`` because the two are
    /// not interchangeable: an `await` yields the thread, which does NOT let a
    /// main-run-loop source fire, and pumping the run loop from an async
    /// context re-enters it. Pick the one that matches how the state arrives.
    static func untilOnRunLoop(
        _ description: @autoclosure () -> String = "condition to hold",
        timeout: TimeInterval? = nil,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) {
        let limit = timeout ?? Self.timeout
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        guard timeout == nil else { return }   // explicit deadline: expiry is the point
        Issue.record(
            "timed out after \(limit)s waiting for \(description())",
            sourceLocation: sourceLocation
        )
    }
}
