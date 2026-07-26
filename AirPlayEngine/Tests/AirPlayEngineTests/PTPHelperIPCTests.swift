// T7 (ptp-helper-design.md §6.2) — unprivileged integration test for the
// engine<->helper IPC contract: shm clock read + loopback-UDP peer
// add/remove, exercised with NO root via airptp_ports_override().
//
// This is the CI-safe proof that the contract in ptp-helper-design.md §1.4
// actually works, without any of the things that need root or a signed
// build:
//   - airptp_daemon_bind(NULL) + airptp_daemon_start(..., is_shared: true)
//     stands in for the future SMAppService helper's "master" role, bound
//     to HIGH ports via airptp_ports_override() (never 319/320 - §6.2's
//     documented CI path) so no privilege is needed.
//   - airptp_daemon_find() stands in for the engine's "client" role: it
//     mmaps the master's /airptp_shm read-only and gets back its own
//     handle - a SEPARATE struct airptp_handle* from the master's, exactly
//     as a different process's engine would (libairptp/src/airptp.c
//     airptp_daemon_find()).
//   - airptp_clock_id_get() on the CLIENT handle proves the shm clock-state
//     read works (§1.4 "publishes /airptp_shm ... clock_id").
//   - airptp_peer_add()/airptp_peer_remove() on the CLIENT handle prove the
//     loopback-UDP control path works (§1.4 "listens 127.0.0.1:320 <-
//     loopback UDP ... peer add/del").
//
// These calls are reached via PTPHelperTestSupport's ptp_test_* forwards
// rather than importing Clibairptp directly, because Clibairptp's own
// module.modulemap declares airptp.h as a `textual header` (needed so the
// vendored, byte-identical header - which uses `bool` without
// <stdbool.h> - passes Clang's modular self-containment check); a textual
// header has no Swift-visible interface. See
// Sources/PTPHelperTestSupport/include/ptp_test_support.h.
//
// Deliberately NOT covered here (needs a signed build / real root, per
// T7's instructions): SMAppService registration, an actual root bind of
// 319/320, launchd KeepAlive respawn. Those stay unverified until
// Developer-ID signing exists.
//
// Hermetic / CI-safe: high ports only (30319/30320, never 319/320), no
// root, no external network (127.0.0.1 loopback only), and every handle is
// torn down via ptp_test_end() so /airptp_shm never leaks across test runs
// (airptp_end() on the master calls daemon_stop(), which the vendored
// daemon_cleanup() path shm_unlinks - ptp-helper-design.md §2.4).
//
// NOT nested under `SerializedEngineState` (migration cookbook §22): this
// file mutates a completely different set of process-globals — libairptp's
// `airptp_event_port` / `airptp_general_port` / `airptp_shm_name` — not
// `shims/outputs.c`'s device registry. That second PTP suite has now arrived
// (`PTPHelperLifecycleTests.swift`), so as `SerializedEngineStateSuite.swift`
// anticipated, this file nests under the libairptp globals' OWN serialized
// parent, `SerializedPTPGlobals` (declared in that file) — not the unrelated
// outputs-registry lock. Do NOT add `.serialized` here; it inherits.

import Testing
import Foundation
import PTPHelperTestSupport

/// High test-only ports (ptp-helper-design.md §6.2's documented CI path).
/// NEVER 319/320 - this test must never touch the real PTP ports, root
/// or not.
private let ptpTestEventPort: UInt16 = 30319
private let ptpTestGeneralPort: UInt16 = 30320

/// Test-only shm name (never the production "/airptp_shm"). A real
/// ptp-helper daemon installed via SMAppService runs as root and owns
/// "/airptp_shm"; an unprivileged test process can't shm_unlink() a
/// root-owned segment of that name, so daemon_shm_create() would fail
/// with EACCES whenever the real daemon happens to be running. See
/// airptp_shm_name_override() (libairptp/airptp.h).
private let ptpTestShmName = "/airptp_shm_test"

/// Migration cookbook §23's documented hoist: `XCTSkipUnless`'s decision
/// moves out of the test body and onto a suite-level `ConditionTrait`,
/// evaluated once at discovery time via a real bind-attempt-then-release on
/// the high test ports (the condition genuinely doesn't depend on anything
/// built up during the test body, unlike `GroupControllerTests.swift:476`).
/// This means two bind/release cycles against the high ports instead of
/// one (a probe here, plus the test body's own real bind for its
/// assertions) — an accepted CI-safety tradeoff, not an oversight.
///
/// **Must override the ports to the high test ports BEFORE probing.**
/// `ptp_test_daemon_bind` binds whatever `airptp_event_port`/
/// `airptp_general_port` currently are, and those default to the real
/// PTP_EVENT_PORT/PTP_GENERAL_PORT (319/320) until overridden — privileged
/// ports that fail to bind without root. The original XCTest body called
/// `ptp_test_ports_override(eventPort, generalPort)` immediately before its
/// bind attempt; the hoisted gate has to do the same override itself before
/// its own probe bind, or it always "fails" against 319/320 regardless of
/// whether the high ports are actually free (verified: without this line the
/// gate reported `canBindTestPorts == false` on every run in this
/// environment, a false negative that looked like permanent port
/// contention).
enum PortBindGate {
    static let canBindTestPorts: Bool = {
        ptp_test_ports_override(ptpTestEventPort, ptpTestGeneralPort)
        guard let hdl = "127.0.0.1".withCString({ ptp_test_daemon_bind($0) }) else { return false }
        ptp_test_end(hdl)
        return true
    }()
}

extension SerializedPTPGlobals {

@Suite(.enabled(
    if: PortBindGate.canBindTestPorts,
    "Could not bind PTP test ports \(ptpTestEventPort)/\(ptpTestGeneralPort); skipping (likely port contention)"
))
final class PTPHelperIPCTests {

    deinit {
        // ptp_test_ports_override()/ptp_test_shm_name_override() mutate plain
        // C process-globals (libairptp/src/airptp.c), not per-test state -
        // restore the shipping defaults (PTP_EVENT_PORT/PTP_GENERAL_PORT =
        // 319/320, AIRPTP_SHM_NAME = "/airptp_shm") so this test can't leak
        // its overrides into any sibling test that shares the process (e.g.
        // one exercising the engine's production ptpd_setup -> daemon_find
        // path, shims/ptpd.c).
        ptp_test_ports_override(319, 320)
        "/airptp_shm".withCString { ptp_test_shm_name_override($0) }
    }

    @Test func findClockReadAndPeerAddRemoveOverLoopback() throws {
        // Every libairptp entry point in this test reads/writes process-wide
        // globals (airptp_event_port/airptp_general_port/airptp_shm_name -
        // see libairptp/src/airptp.c), so apply the overrides before the
        // master binds.
        ptp_test_ports_override(ptpTestEventPort, ptpTestGeneralPort)
        ptpTestShmName.withCString { ptp_test_shm_name_override($0) }

        // MARK: master role (stands in for the future root helper, minus
        // root - these are high ports so no privilege is required).
        // Bind explicitly to loopback rather than passing `nil` (which
        // resolves to `AI_PASSIVE`/`INADDR_ANY` — a listener on every
        // interface). This test only ever talks to itself over 127.0.0.1
        // (see the "loopback-UDP control path" note above), so nothing it
        // verifies changes — but an all-interfaces bind is exactly what
        // trips macOS's Application Firewall's "accept incoming network
        // connections?" prompt for the xctest host process on every
        // `swift test` run. A loopback-only listener is never firewalled.
        //
        // The port-contention skip that used to live here as a
        // `throw XCTSkip(...)` is now the suite-level `PortBindGate` trait
        // above (migration cookbook §23) — this bind is expected to succeed
        // whenever the suite actually ran.
        guard let masterHdl = "127.0.0.1".withCString({ ptp_test_daemon_bind($0) }) else {
            Issue.record("Could not bind PTP test ports \(ptpTestEventPort)/\(ptpTestGeneralPort) - \(String(cString: ptp_test_errmsg_get())); the suite-level PortBindGate should have caught this")
            return
        }
        defer { ptp_test_end(masterHdl) }

        let seed: UInt64 = 0xC0FFEE_FEED_BEEF
        let startRet = ptp_test_daemon_start(masterHdl, seed, /* is_shared: */ true)
        #expect(startRet == 0, "airptp_daemon_start() failed: \(String(cString: ptp_test_errmsg_get()))")
        guard startRet == 0 else { return }

        // MARK: client role (stands in for the unprivileged engine).
        // A SEPARATE handle from masterHdl - proves the find() path (shm
        // mmap read-only), not just reuse of the daemon's own struct.
        guard let clientHdl = ptp_test_daemon_find() else {
            Issue.record("airptp_daemon_find() returned NULL - \(String(cString: ptp_test_errmsg_get())); the master's /airptp_shm was not discoverable")
            return
        }
        defer { ptp_test_end(clientHdl) }

        // --- shm clock read ---
        var clockID: UInt64 = 0
        let clockRet = ptp_test_clock_id_get(&clockID, clientHdl)
        #expect(clockRet == 0, "airptp_clock_id_get() failed on the client (find()'d) handle")
        // Sanity: daemon_start() ORs the seed with the EUI-64 "non-IEEE"
        // marker bits (libairptp/src/airptp.c, 0xFFFF000000000000), so a
        // real clock_id from a running daemon is never zero.
        #expect(clockID != 0, "clock_id read via the client handle should be non-zero")

        // --- loopback-UDP peer add/remove ---
        var peerID: UInt32 = 0
        let addRet = "127.0.0.1".withCString { addr in
            ptp_test_peer_add(&peerID, addr, clientHdl)
        }
        #expect(addRet == 0, "airptp_peer_add() over loopback failed: \(String(cString: ptp_test_errmsg_get()))")
        // peer_id is a djb hash of the address string
        // (libairptp/src/airptp.c), never exactly zero for a non-empty
        // address, and proves the call actually computed/returned an id
        // rather than leaving the out-param untouched.
        #expect(peerID != 0, "peer_add should hand back a non-zero peer id")

        // --- daemon-side active peer count (airptp_peer_active_count) ---
        // The count is a daemon-side concept (it exists so an on-demand
        // helper can idle-exit and release 319/320); a client (find()'d)
        // handle has no peer table and must report -1, not 0 - "no peers"
        // and "not a daemon" are different answers.
        #expect(ptp_test_peer_active_count(clientHdl) == -1,
                "active count on a client handle should be -1 (daemon-side only)")

        // peer_add above is fire-and-forget loopback UDP, so the daemon
        // registers the peer asynchronously - poll with a timeout rather
        // than asserting immediately.
        #expect(pollActiveCount(masterHdl, until: 1),
                "master's active peer count should reach 1 after peer_add")

        // Fire-and-forget over loopback UDP (libairptp/src/ptp_msg_handle.c's
        // *_send helpers do not wait for an ack), torn down explicitly so
        // the master's peer table doesn't matter for test repeatability.
        ptp_test_peer_remove(peerID, clientHdl)

        #expect(pollActiveCount(masterHdl, until: 0),
                "master's active peer count should return to 0 after peer_remove")
    }

    /// Polls the daemon-side active peer count until it reaches `target`
    /// (true) or ~2 s elapse (false). Both peer control messages are async
    /// loopback UDP, so every count assertion needs a settle window.
    private func pollActiveCount(_ hdl: OpaquePointer, until target: Int32) -> Bool {
        for _ in 0..<100 {
            if ptp_test_peer_active_count(hdl) == target { return true }
            usleep(20_000)
        }
        return ptp_test_peer_active_count(hdl) == target
    }
}

} // extension SerializedPTPGlobals
