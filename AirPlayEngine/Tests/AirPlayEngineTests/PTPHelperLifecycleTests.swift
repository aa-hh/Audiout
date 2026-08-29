// PLAN-AIRPLAY-COEXISTENCE.md T2 — the ptp-helper's on-demand lifecycle,
// exercised against the REAL built binary as a subprocess.
//
// T2 turns the helper from a RunAtLoad+KeepAlive daemon that owns UDP 319/320
// forever into a demand-started process that gives the ports back: it retries
// the bind while macOS is still letting go of them, and it exits by itself
// once no PTP peer has been active for a while, so launchd releases the ports
// to macOS's own AirPlay. Neither half is observable from inside the test
// process — "did it exit, and with what status?" is a process-level question —
// so these tests launch `.build/<config>/ptp-helper` and watch it.
//
// Unprivileged and hermetic, following PTPHelperIPCTests.swift's conventions:
//   - high test ports only (30319/30320, NEVER 319/320 — no root in tests),
//   - a test-only shm name, so the subprocess never has to shm_unlink() the
//     real root daemon's root-owned /airptp_shm (which would fail, and take
//     the test with it, on any machine where the shipped daemon is
//     installed),
//   - the peer is added over 127.0.0.1 loopback only (firewall rule: an
//     all-interfaces listener is what triggers macOS's "accept incoming
//     connections?" prompt on every `swift test`).
//
// Deliberately NOT covered (needs launchd + a signed build): the
// AUDIOUT_PTP_MACH_SERVICE check-in. `xpc_connection_create_mach_service`
// with the LISTENER flag only works for a name launchd has actually vended to
// the process from its plist's MachServices dictionary, which an
// unprivileged test cannot arrange. The env var is left unset here, which is
// exactly the "no check-in" path the helper must keep supporting.

import Testing
import Foundation
import PTPHelperTestSupport

// Nests under `SerializedLibairptpState` (SerializedLibairptpStateSuite.swift),
// the shared `.serialized` parent for everything that drives `libairptp`'s
// process globals — `airptp_event_port` / `airptp_general_port` /
// `airptp_shm_name`, written by `ptp_test_ports_override()`,
// `ptp_test_shm_name_override()` and (less obviously) by
// `airptp_daemon_find()`, which copies the found daemon's ports into the port
// globals. `.serialized` on this suite alone would NOT do: that only orders
// tests *within* a suite, and the collision that matters is between files —
// this suite's `find()` rewriting the port globals out from under
// `PTPHelperIPCTests`' `peer_add`, and vice versa. Do NOT repeat
// `.serialized` below; it inherits from the parent.

/// High test-only ports, as in `PTPHelperIPCTests.swift`. NEVER 319/320.
/// Not `private`: `PTPYieldBackTests.swift` (T7) reuses these alongside
/// `HelperRun`/`ptpHelperBinaryURL` below to drive the same real subprocess,
/// serialized under the same `SerializedLibairptpState` parent so reusing the
/// fixed high ports/shm name across files is safe (never concurrent).
let ptpLifecycleEventPort: UInt16 = 30319
let ptpLifecycleGeneralPort: UInt16 = 30320

/// Test-only shm name — never the production "/airptp_shm" (see the header).
let ptpLifecycleShmName = "/airptp_shm_lifecycle_test"

extension SerializedLibairptpState {

@Suite(.enabled(
    if: PortBindGate.canBindTestPorts,
    "Could not bind PTP test ports \(ptpLifecycleEventPort)/\(ptpLifecycleGeneralPort); skipping (likely port contention)"
))
final class PTPHelperLifecycleTests {

    deinit {
        // `ptp_test_shm_name_override()` and `airptp_daemon_find()` both write
        // plain C process-globals (libairptp/src/airptp.c) — restore the
        // shipping defaults so nothing leaks into a sibling suite.
        ptp_test_ports_override(319, 320)
        "/airptp_shm".withCString { ptp_test_shm_name_override($0) }
    }

    /// (i) Demand-started, never used: the helper must not sit on the PTP
    /// ports. With no peer ever registering, the startup grace expires, the
    /// idle window elapses, and it exits **0** — status 0 matters as much as
    /// the exit itself, because the launchd plist runs
    /// `KeepAlive={SuccessfulExit:false}` and a non-zero exit here would be a
    /// respawn storm that never gives the ports back.
    @Test func idleExitsOnItsOwnWhenNoPeerEverAppears() throws {
        guard let binary = ptpHelperBinaryURL else {
            Issue.record("ptp-helper binary not found next to the test bundle; set AUDIOUT_PTP_HELPER_BINARY to point at it")
            return
        }

        let run = try HelperRun(binary: binary, idleSecs: 2, graceSecs: 2)
        defer { run.cleanUp() }

        let status = run.waitForExit(timeout: 15)
        #expect(status == 0, "helper should have idle-exited with status 0, got \(String(describing: status)):\n\(run.log)")
    }

    /// (ii) The idle window must never fire under a live session. A peer added
    /// over loopback stays fresh for `AIRPTP_STALE_SECS` (15 s) without any
    /// refresh, so the helper has to keep running well past the point the
    /// idle window would otherwise have fired — and then exit promptly, 0,
    /// once that peer is removed.
    @Test func staysAliveWhileAPeerIsActiveAndExitsAfterItIsRemoved() throws {
        guard let binary = ptpHelperBinaryURL else {
            Issue.record("ptp-helper binary not found next to the test bundle; set AUDIOUT_PTP_HELPER_BINARY to point at it")
            return
        }

        // A generous grace here is not laziness: it decouples the assertion
        // from how long the subprocess takes to publish its shm on a loaded
        // machine. Once the peer registers, `saw_peer` latches and the grace
        // stops mattering — the 2 s idle window is what the test measures.
        let run = try HelperRun(binary: binary, idleSecs: 2, graceSecs: 8)
        defer { run.cleanUp() }

        ptpLifecycleShmName.withCString { ptp_test_shm_name_override($0) }

        guard let clientHdl = findHelperDaemon(within: 6) else {
            Issue.record("the helper never published a findable clock record:\n\(run.log)")
            return
        }
        defer { ptp_test_end(clientHdl) }

        var peerID: UInt32 = 0
        let addRet = "127.0.0.1".withCString { ptp_test_peer_add(&peerID, $0, clientHdl) }
        #expect(addRet == 0, "airptp_peer_add() over loopback failed: \(String(cString: ptp_test_errmsg_get()))")

        // Comfortably longer than the 2 s idle window: a helper that ignored
        // the live peer would already be gone by now.
        Thread.sleep(forTimeInterval: 4)
        #expect(run.process.isRunning, "helper exited while a peer was still active:\n\(run.log)")

        ptp_test_peer_remove(peerID, clientHdl)

        let status = run.waitForExit(timeout: 10)
        #expect(status == 0, "helper should have idle-exited with status 0 after the peer went away, got \(String(describing: status)):\n\(run.log)")
    }

    /// (iii) T9a — the dead-man's watchdog must not mistake ordinary quiet
    /// operation for a wedge. A watchdog threshold comfortably longer than
    /// the idle+grace window below still lets idle exit fire first; if the
    /// watchdog's heartbeat were somehow not kept fresh by a live (not
    /// wedged) service loop, this would hard-exit 1 instead of idle-exiting
    /// 0. Actually inducing a genuine wedge to prove the watchdog fires isn't
    /// expressible here: the PTP master loop that could wedge lives inside
    /// vendored libairptp on its own thread, out of an unprivileged test's
    /// reach without a test-only hook into the root-daemon binary.
    @Test func watchdogDoesNotMisfireDuringNormalIdleOperation() throws {
        guard let binary = ptpHelperBinaryURL else {
            Issue.record("ptp-helper binary not found next to the test bundle; set AUDIOUT_PTP_HELPER_BINARY to point at it")
            return
        }

        let run = try HelperRun(binary: binary, idleSecs: 2, graceSecs: 2, watchdogSecs: 8)
        defer { run.cleanUp() }

        let status = run.waitForExit(timeout: 15)
        #expect(status == 0, "helper should have idle-exited with status 0 (not a watchdog hard-exit 1), got \(String(describing: status)):\n\(run.log)")
    }

    /// Polls `airptp_daemon_find()` until the subprocess has published its
    /// clock record. The helper binds, starts and publishes asynchronously
    /// relative to `Process.run()`, so there is nothing to synchronize on but
    /// the shm itself.
    private func findHelperDaemon(within seconds: TimeInterval) -> OpaquePointer? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let hdl = ptp_test_daemon_find() { return hdl }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return ptp_test_daemon_find()
    }
}

} // extension SerializedLibairptpState

// MARK: - Locating the built helper

/// `.build/<config>/AirPlayEngineTests.xctest` sits next to
/// `.build/<config>/ptp-helper` (`swift build --build-tests` builds the
/// executable products too), so the test bundle's own directory is the
/// lookup. `AUDIOUT_PTP_HELPER_BINARY` overrides it for anyone running the
/// suite against a bundled/installed copy. Not `private` — `PTPYieldBackTests`
/// (T7) reuses this lookup; see the reuse note on `ptpLifecycleEventPort`.
let ptpHelperBinaryURL: URL? = {
    let env = ProcessInfo.processInfo.environment["AUDIOUT_PTP_HELPER_BINARY"]
    if let env, !env.isEmpty { return URL(fileURLWithPath: env) }

    let candidate = Bundle(for: SerializedLibairptpState.PTPHelperLifecycleTests.self)
        .bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("ptp-helper")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}()

// MARK: - Subprocess wrapper

/// One `ptp-helper` subprocess, launched with the T2 timing knobs turned
/// down to test scale. Not `private` — `PTPYieldBackTests` (T7) reuses this
/// wrapper rather than duplicating a second subprocess harness; see the reuse
/// note on `ptpLifecycleEventPort`.
final class HelperRun {
    let process = Process()
    private let logURL: URL

    /// stderr goes to a file rather than a `Pipe`: the helper's libairptp
    /// callbacks log freely, and an undrained pipe buffer would deadlock the
    /// subprocess mid-test. A file also survives to be quoted in a failure
    /// message.
    /// `watchdogSecs` is nil by default (AUDIOUT_PTP_WATCHDOG_SECS unset,
    /// so main.c's own default applies) - only PTPHelperLifecycleTests'
    /// T9a watchdog test needs to turn the threshold down to test scale.
    init(binary: URL, idleSecs: Int, graceSecs: Int, watchdogSecs: Int? = nil) throws {
        logURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptp-helper-lifecycle-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        process.executableURL = binary
        // A wholesale environment, so AUDIOUT_PTP_MACH_SERVICE is
        // definitively unset (the "no launchd, no check-in" path) whatever the
        // test runner inherited.
        var environment = [
            "AUDIOUT_PTP_PORTS": "\(ptpLifecycleEventPort),\(ptpLifecycleGeneralPort)",
            "AUDIOUT_PTP_SHM_NAME": ptpLifecycleShmName,
            "AUDIOUT_PTP_IDLE_SECS": "\(idleSecs)",
            "AUDIOUT_PTP_IDLE_GRACE_SECS": "\(graceSecs)",
            // The suite gate already proved the ports are free, so don't burn
            // the shipping 10 s budget before reporting a surprise.
            "AUDIOUT_PTP_BIND_RETRY_SECS": "2",
        ]
        if let watchdogSecs {
            environment["AUDIOUT_PTP_WATCHDOG_SECS"] = "\(watchdogSecs)"
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: logURL)

        try process.run()
    }

    var log: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "<no helper log>" }

    /// Waits up to `timeout` for the subprocess to exit on its own. Returns
    /// its status, or `nil` if it was still running when the timeout expired —
    /// "did not exit" is a distinct failure from "exited non-zero".
    func waitForExit(timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard !process.isRunning else { return nil }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func cleanUp() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: logURL)
    }
}
