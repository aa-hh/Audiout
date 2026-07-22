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

import XCTest
import PTPHelperTestSupport

final class PTPHelperIPCTests: XCTestCase {

    /// High test-only ports (ptp-helper-design.md §6.2's documented CI path).
    /// NEVER 319/320 - this test must never touch the real PTP ports, root
    /// or not.
    private static let eventPort: UInt16 = 30319
    private static let generalPort: UInt16 = 30320

    func testFindClockReadAndPeerAddRemoveOverLoopback() throws {
        // Every libairptp entry point in this test reads/writes process-wide
        // globals (airptp_event_port/airptp_general_port - see
        // libairptp/src/airptp.c), so apply the override before the master
        // binds.
        ptp_test_ports_override(Self.eventPort, Self.generalPort)

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
        guard let masterHdl = "127.0.0.1".withCString({ ptp_test_daemon_bind($0) }) else {
            // Guard against CI flakiness if something else already holds
            // these high ports; skip rather than fail the suite.
            throw XCTSkip("Could not bind PTP test ports \(Self.eventPort)/\(Self.generalPort) - \(String(cString: ptp_test_errmsg_get())); skipping (likely port contention)")
        }
        defer { ptp_test_end(masterHdl) }

        let seed: UInt64 = 0xC0FFEE_FEED_BEEF
        let startRet = ptp_test_daemon_start(masterHdl, seed, /* is_shared: */ true)
        XCTAssertEqual(startRet, 0, "airptp_daemon_start() failed: \(String(cString: ptp_test_errmsg_get()))")
        guard startRet == 0 else { return }

        // MARK: client role (stands in for the unprivileged engine).
        // A SEPARATE handle from masterHdl - proves the find() path (shm
        // mmap read-only), not just reuse of the daemon's own struct.
        guard let clientHdl = ptp_test_daemon_find() else {
            return XCTFail("airptp_daemon_find() returned NULL - \(String(cString: ptp_test_errmsg_get())); the master's /airptp_shm was not discoverable")
        }
        defer { ptp_test_end(clientHdl) }

        // --- shm clock read ---
        var clockID: UInt64 = 0
        let clockRet = ptp_test_clock_id_get(&clockID, clientHdl)
        XCTAssertEqual(clockRet, 0, "airptp_clock_id_get() failed on the client (find()'d) handle")
        // Sanity: daemon_start() ORs the seed with the EUI-64 "non-IEEE"
        // marker bits (libairptp/src/airptp.c, 0xFFFF000000000000), so a
        // real clock_id from a running daemon is never zero.
        XCTAssertNotEqual(clockID, 0, "clock_id read via the client handle should be non-zero")

        // --- loopback-UDP peer add/remove ---
        var peerID: UInt32 = 0
        let addRet = "127.0.0.1".withCString { addr in
            ptp_test_peer_add(&peerID, addr, clientHdl)
        }
        XCTAssertEqual(addRet, 0, "airptp_peer_add() over loopback failed: \(String(cString: ptp_test_errmsg_get()))")
        // peer_id is a djb hash of the address string
        // (libairptp/src/airptp.c), never exactly zero for a non-empty
        // address, and proves the call actually computed/returned an id
        // rather than leaving the out-param untouched.
        XCTAssertNotEqual(peerID, 0, "peer_add should hand back a non-zero peer id")

        // Fire-and-forget over loopback UDP (libairptp/src/ptp_msg_handle.c's
        // *_send helpers do not wait for an ack) - nothing further to
        // assert beyond a clean, non-crashing call, torn down explicitly so
        // the master's peer table doesn't matter for test repeatability.
        ptp_test_peer_remove(peerID, clientHdl)
    }
}
