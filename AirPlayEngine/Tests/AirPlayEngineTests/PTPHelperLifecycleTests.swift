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
// AUDIOUTER_PTP_MACH_SERVICE check-in. `xpc_connection_create_mach_service`
// with the LISTENER flag only works for a name launchd has actually vended to
// the process from its plist's MachServices dictionary, which an
// unprivileged test cannot arrange. The env var is left unset here, which is
// exactly the "no check-in" path the helper must keep supporting.

import Testing
import Foundation
import PTPHelperTestSupport

/// Serialized parent for every suite that drives `libairptp`'s **process
/// globals** — `airptp_event_port` / `airptp_general_port` /
/// `airptp_shm_name`, written by `ptp_test_ports_override()`,
/// `ptp_test_shm_name_override()` and (less obviously) by
/// `airptp_daemon_find()`, which copies the found daemon's ports into the
/// port globals.
///
/// `SerializedEngineStateSuite.swift` predicted this file: it exists for
/// `shims/outputs.c`'s device registry and explicitly records that a *second*
/// PTP test "will need its OWN serialized parent for the `libairptp` globals
/// rather than piggybacking on this one — the two registries are unrelated".
/// This is that parent. `.serialized` on each suite independently would not
/// do: that only orders tests *within* a suite, and the collision that
/// matters is between the two files (this suite's `find()` rewriting the port
/// globals out from under `PTPHelperIPCTests`' `peer_add`, and vice versa).
///
/// Do NOT repeat `.serialized` on a child suite — it inherits from here.
@Suite(.serialized) struct SerializedPTPGlobals {}

/// High test-only ports, as in `PTPHelperIPCTests.swift`. NEVER 319/320.
private let ptpLifecycleEventPort: UInt16 = 30319
private let ptpLifecycleGeneralPort: UInt16 = 30320

/// Test-only shm name — never the production "/airptp_shm" (see the header).
private let ptpLifecycleShmName = "/airptp_shm_lifecycle_test"

extension SerializedPTPGlobals {

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
            Issue.record("ptp-helper binary not found next to the test bundle; set AUDIOUTER_PTP_HELPER_BINARY to point at it")
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
            Issue.record("ptp-helper binary not found next to the test bundle; set AUDIOUTER_PTP_HELPER_BINARY to point at it")
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

} // extension SerializedPTPGlobals

// MARK: - Locating the built helper

/// `.build/<config>/AirPlayEngineTests.xctest` sits next to
/// `.build/<config>/ptp-helper` (`swift build --build-tests` builds the
/// executable products too), so the test bundle's own directory is the
/// lookup. `AUDIOUTER_PTP_HELPER_BINARY` overrides it for anyone running the
/// suite against a bundled/installed copy.
private let ptpHelperBinaryURL: URL? = {
    let env = ProcessInfo.processInfo.environment["AUDIOUTER_PTP_HELPER_BINARY"]
    if let env, !env.isEmpty { return URL(fileURLWithPath: env) }

    let candidate = Bundle(for: SerializedPTPGlobals.PTPHelperLifecycleTests.self)
        .bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("ptp-helper")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}()

// MARK: - Subprocess wrapper

/// One `ptp-helper` subprocess, launched with the T2 timing knobs turned
/// down to test scale.
private final class HelperRun {
    let process = Process()
    private let logURL: URL

    /// stderr goes to a file rather than a `Pipe`: the helper's libairptp
    /// callbacks log freely, and an undrained pipe buffer would deadlock the
    /// subprocess mid-test. A file also survives to be quoted in a failure
    /// message.
    init(binary: URL, idleSecs: Int, graceSecs: Int) throws {
        logURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptp-helper-lifecycle-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        process.executableURL = binary
        // A wholesale environment, so AUDIOUTER_PTP_MACH_SERVICE is
        // definitively unset (the "no launchd, no check-in" path) whatever the
        // test runner inherited.
        process.environment = [
            "AUDIOUTER_PTP_PORTS": "\(ptpLifecycleEventPort),\(ptpLifecycleGeneralPort)",
            "AUDIOUTER_PTP_SHM_NAME": ptpLifecycleShmName,
            "AUDIOUTER_PTP_IDLE_SECS": "\(idleSecs)",
            "AUDIOUTER_PTP_IDLE_GRACE_SECS": "\(graceSecs)",
            // The suite gate already proved the ports are free, so don't burn
            // the shipping 10 s budget before reporting a surprise.
            "AUDIOUTER_PTP_BIND_RETRY_SECS": "2",
        ]
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
