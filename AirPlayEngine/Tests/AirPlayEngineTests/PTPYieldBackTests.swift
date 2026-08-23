// PLAN-AIRPLAY-COEXISTENCE.md T7 — yield-back verification: when an Audiout
// session ends, do our PTP peers really go away, so the on-demand helper's
// idle-exit fires and UDP 319/320 come back to macOS?
//
// Two links in that chain are verified by READING, not by a test here,
// because they need either a live RTSP session against a real receiver or a
// full app-quit lifecycle — neither is reachable from this package's
// hermetic suite:
//   - sender/airplay.c: `struct airplay_session.ptpd_slave_id` is
//     calloc-zeroed and only ever set (`handle_timingpeerinfo`) after a real
//     SETUP reply hands back a timing-peer address; `session_free()` calls
//     `ptpd_slave_remove()` whenever it is non-zero. Every teardown route —
//     the clean path (`session_cleanup`), every `AIRPLAY_SEQ_ABORT` (all of
//     which route through `session_failure`/`start_failure`/`start_retry` to
//     `session_cleanup`/`session_free`), and `airplay_deinit`'s own direct
//     walk of `airplay_sessions` — converges on `session_free`. There is no
//     early-return path that skips it.
//   - `airplay_deinit()` frees every session (and so removes every
//     registered PTP peer) BEFORE calling `ptpd_deinit()`, matching its own
//     "After freeing sessions, since that's where the active ptp peers get
//     removed" comment — confirmed by reading, no early return above the
//     loop.
//   - The app-quit path (`AppDelegate.applicationShouldTerminate` ->
//     `backend.stopAndWait(timeout: .seconds(2))` -> `NativeBackend.stop()`'s
//     stored `engineStopTask` -> `AirPlayEngine.stop()`'s
//     `engineThread.run { output_airplay.deinit(); ptpd_deinit() }`) reaches
//     the same `session_free`/`ptpd_slave_remove` chain, but
//     `stopAndWait`'s own doc comment is explicit that the 2 s budget bounds
//     only how long the CALLER waits, not whether teardown finishes: "the
//     detached teardown Task keeps running regardless; this only bounds how
//     long the caller waits on it." If the engine thread's closure hasn't
//     run by the time AppKit actually exits the process (e.g. a vendored
//     callback wedged in a blocking call — the same failure mode
//     `EngineThread.stop()`'s own deadline exists to survive, one step
//     earlier in the same teardown), `ptpd_slave_remove` never fires for
//     that quit. This is exactly why the belt-and-braces below exists, and
//     is not a gap introduced here to fix — see the T7 report for the full
//     writeup.
//
// What THIS file proves, empirically: the belt-and-braces net for exactly
// that "peer left behind" case actually works. `daemon.c`'s
// `active_peers_publish()` recomputes the published count from each peer's
// `last_seen + AIRPTP_STALE_SECS` on every peer-table mutation AND on the 5 s
// shm heartbeat (`shm_update_cb`) — so a peer nobody ever explicitly removed
// still ages out on its own, and the running helper's idle-exit loop
// (`ptp_helper_wait_until_idle_or_signal`, main.c) — which only ever reads
// that one published count — exits exactly as it would for an explicitly
// removed peer. `PTPHelperLifecycleTests.swift` already proves the
// explicit-removal half of this contract; this file proves the half that
// matters when removal never happens.
//
// `AIRPTP_STALE_SECS` (15 s) is a compile-time constant in
// `airptp_internal.h` with no test override — `ptp_test_support.c` is a
// pass-through only, by design (see PTPHelperIPCTests.swift's header), and
// this constant is upstream MIT code, not touched. So this test genuinely
// waits out the real staleness window plus the real 5 s heartbeat lag — the
// honest cost of testing the actual constant rather than a stand-in — bounded
// generously for a loaded CI machine.

import Testing
import Foundation
import PTPHelperTestSupport

// Nests under the same `SerializedLibairptpState` parent as
// PTPHelperIPCTests.swift/PTPHelperLifecycleTests.swift (SerializedEngineStateSuite's
// counterpart for libairptp's process-globals) and reuses `PortBindGate` from
// PTPHelperIPCTests.swift and `HelperRun`/`ptpHelperBinaryURL`/the port+shm
// constants from PTPHelperLifecycleTests.swift — all serialized, so sharing
// the same fixed high ports/shm name across files is safe (never
// concurrent). Do NOT add `.serialized` here; it inherits from the parent.
extension SerializedLibairptpState {

@Suite(.enabled(
    if: PortBindGate.canBindTestPorts,
    "Could not bind PTP test ports \(ptpLifecycleEventPort)/\(ptpLifecycleGeneralPort); skipping (likely port contention)"
))
final class PTPYieldBackTests {

    deinit {
        // Same restore-the-globals discipline as the sibling suites — see
        // their deinits for why.
        ptp_test_ports_override(319, 320)
        "/airptp_shm".withCString { ptp_test_shm_name_override($0) }
    }

    /// The belt-and-braces case: a peer is added and then NEVER explicitly
    /// removed — standing in for any teardown path that fails to reach
    /// `ptpd_slave_remove` (a wedged engine thread on quit, a crashed
    /// engine process, a bug in some future teardown path). Proves the
    /// daemon forgets it anyway, and the running helper still idle-exits.
    @Test func forgottenPeerAgesOutAndHelperStillIdleExitsWithoutExplicitRemoval() throws {
        guard let binary = ptpHelperBinaryURL else {
            Issue.record("ptp-helper binary not found next to the test bundle; set AUDIOUT_PTP_HELPER_BINARY to point at it")
            return
        }

        // Short idle window: it only starts mattering once the real 15 s
        // staleness decay finally zeroes the published count. Grace is moot
        // once a peer registers at all (`saw_peer` latches, see main.c).
        let run = try HelperRun(binary: binary, idleSecs: 2, graceSecs: 2)
        defer { run.cleanUp() }

        ptpLifecycleShmName.withCString { ptp_test_shm_name_override($0) }

        guard let clientHdl = findHelperDaemon(within: 6) else {
            Issue.record("the helper never published a findable clock record:\n\(run.log)")
            return
        }
        defer { ptp_test_end(clientHdl) }

        // Deliberately NOT "127.0.0.1" (what the sibling suites use for a
        // peer they intend to remove): `utils_net_address_is_same()`
        // (libairptp/src/utils.c) compares the IP only, never the port, so a
        // peer registered at the daemon's OWN loopback address keeps getting
        // `last_seen` refreshed forever by the daemon's own self-directed
        // Sync/Follow-Up/Announce sends looping back onto its own listening
        // socket (confirmed empirically — an earlier version of this test
        // using 127.0.0.1 never went stale and timed out). 192.0.2.1 is
        // RFC 5737 TEST-NET-1 — reserved for documentation, guaranteed
        // non-routable/non-existent, so the daemon's periodic sends to it
        // elicit no reply and `last_seen` is set once, at add time, and never
        // refreshed — genuinely reproducing "a peer nobody talks to again".
        var peerID: UInt32 = 0
        let addRet = "192.0.2.1".withCString { ptp_test_peer_add(&peerID, $0, clientHdl) }
        #expect(addRet == 0, "airptp_peer_add() failed: \(String(cString: ptp_test_errmsg_get()))")

        // Deliberately no ptp_test_peer_remove() call anywhere in this test —
        // that omission IS the scenario under test.

        // Comfortably before AIRPTP_STALE_SECS (15 s): the helper must still
        // be alive here, or it exited for the wrong reason (a bug that would
        // make legitimate playback stutter roughly every 15 s).
        Thread.sleep(forTimeInterval: 5)
        #expect(run.process.isRunning, "helper exited well before the forgotten peer could have gone stale:\n\(run.log)")

        // 15 s staleness + up to 5 s heartbeat lag + the 2 s idle window is
        // ~22 s of real wall-clock time even on a quiet machine; this repo's
        // dev box routinely runs several other worktrees' test suites
        // concurrently (documented flakiness — see the memory-leak/CPU-storm
        // notes), which can stretch every one of those real-time waits well
        // past their quiet-machine figure. Bounded generously so contention
        // slows this test down rather than failing it.
        let status = run.waitForExit(timeout: 90)
        #expect(status == 0, "helper should have idle-exited with status 0 once the forgotten peer aged out on its own, got \(String(describing: status)):\n\(run.log)")
    }

    /// Polls `airptp_daemon_find()` until the subprocess has published its
    /// clock record, same as `PTPHelperLifecycleTests`'s helper.
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
