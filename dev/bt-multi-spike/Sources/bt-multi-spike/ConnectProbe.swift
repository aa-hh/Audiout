import AudioToolbox
import CoreBluetooth
import Foundation
import IOBluetooth

// ============================================================================
// ConnectProbe — BT-SPIKE-CONNECT harness (docs/plans/PLAN-UNIVERSAL-SYNC.md §G).
//
// Answers, on real paired hardware: does IOBluetoothDevice.openConnection()
// reliably restore the baseband link AND re-expose the speaker as a Core
// Audio output device (proof A2DP actually came back), and how long does each
// stage take? Also round-trips via closeConnection() so one live session can
// repeat connect/disconnect cycles per device.
//
// TCC: classic IOBluetooth access is gated by kTCCServiceBluetoothAlways
// (~macOS 14+). For a bare CLI the grant is attributed to the RESPONSIBLE
// process (the hosting terminal), which may never show a prompt — the API
// then fails SILENTLY (empty paired list, no error). CBManager.authorization
// reads the current attribution's status WITHOUT triggering a prompt, so the
// probe can diagnose that case instead of mis-reporting "nothing paired".
// The .app wrapper (make-spike-app.sh) is the fallback attribution path.
// ============================================================================

enum ConnectProbe {

    /// How long we wait on the blocking openConnection() call before declaring
    /// it hung. The baseband page timeout is typically shorter; 20s also
    /// covers speakers waking from deep standby.
    private static let openTimeoutSeconds = 20.0
    /// How long we poll Core Audio for the output device to appear/vanish
    /// after the baseband stage. BT audio endpoints usually publish within a
    /// few seconds; the cap marks "never" without hanging the run.
    private static let coreAudioPollTimeoutSeconds = 30.0
    private static let coreAudioPollIntervalSeconds = 0.5

    static func run(_ rawArgs: [String]) -> Int32 {
        // TCC can KILL this process mid-probe (verified live 2026-08-07: a bare
        // CLI whose responsible process lacks NSBluetoothAlwaysUsageDescription
        // dies with SIGABRT on its first Bluetooth access — no prompt, no
        // error, just __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__ on a background
        // thread). Unbuffer stdout so every diagnostic printed BEFORE that
        // abort actually reaches the operator instead of dying in the buffer.
        setvbuf(stdout, nil, _IONBF, 0)

        var query: String?
        var wantDisconnect = false
        for arg in rawArgs {
            if arg == "--disconnect" {
                wantDisconnect = true
            } else if query == nil {
                query = arg
            } else {
                elog("connect-probe: unexpected argument '\(arg)' (usage: --connect-probe [name-or-address] [--disconnect])")
                return 2
            }
        }

        if Bundle.main.bundleIdentifier == nil {
            print("connect-probe: WARNING — running as a bare binary (no bundle). If this process's TCC attribution lacks NSBluetoothAlwaysUsageDescription, macOS will KILL the process on the next line (SIGABRT, no prompt). If that happens, build the wrapper (bash make-spike-app.sh) and launch it via `open`.")
        }

        let auth = printAuthorizationStatus()

        let listElapsed = Stopwatch()
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        print(String(format: "connect-probe: IOBluetoothDevice.pairedDevices() -> %d device(s) in %.2fs", paired.count, listElapsed.elapsedSeconds))

        guard !paired.isEmpty else {
            diagnoseEmptyPairedList(auth)
            return auth == .allowedAlways ? 0 : 1
        }

        print("connect-probe: paired devices:")
        for (i, device) in paired.enumerated() {
            let name = device.name ?? "<unnamed>"
            let addr = device.addressString ?? "<no-address>"
            let connected = device.isConnected() ? "yes" : "no"
            print("  \(i + 1). \"\(name)\"  addr=\(addr)  connected=\(connected)  audio=\(audioServiceTag(device))")
        }

        guard let target = selectTarget(query: query, from: paired) else {
            // Listing-only run (no argument + no terminal, or empty prompt reply)
            // exits clean; a query that matched nothing already logged why.
            return query == nil ? 0 : 1
        }
        let targetName = target.name ?? target.addressString ?? "<device>"
        print("connect-probe: target = \"\(targetName)\"")

        if wantDisconnect {
            return runDisconnect(target, name: targetName)
        }
        return runConnect(target, name: targetName)
    }

    // MARK: - Connect / disconnect stages

    private static func runConnect(_ target: IOBluetoothDevice, name: String) -> Int32 {
        guard !target.isConnected() else {
            let endpoint = findCoreAudioDevice(matching: target)
            print("connect-probe: already connected (baseband). Core Audio output: "
                + (endpoint.map { "present (id=\($0.id) uid=\($0.uid))" }
                    ?? "ABSENT — baseband up but no audio endpoint (A2DP not established?)"))
            print("connect-probe: round-trip with --disconnect first to probe a fresh connect")
            return 0
        }

        // Stage A: baseband. openConnection() BLOCKS until the link is up or
        // the stack gives up, so run it on a worker thread and time-box it
        // ourselves. On timeout the thread stays blocked — acceptable for a
        // probe process that exits right after.
        print("connect-probe: stage A — openConnection() (timeout \(Int(openTimeoutSeconds))s)...")
        let stageA = Stopwatch()
        var openResult: IOReturn = 0
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            openResult = target.openConnection()
            done.signal()
        }
        guard done.wait(timeout: .now() + openTimeoutSeconds) == .success else {
            print(String(format: "connect-probe: stage A TIMED OUT after %.1fs — openConnection() still blocked (page timeout pending?). Result unknown; check System Settings > Bluetooth.", stageA.elapsedSeconds))
            return 1
        }
        let stageASeconds = stageA.elapsedSeconds
        guard openResult == 0 else { // 0 == kIOReturnSuccess
            print(String(format: "connect-probe: stage A FAILED in %.2fs — openConnection() -> %@", stageASeconds, ioReturnString(openResult)))
            return 1
        }
        print(String(format: "connect-probe: stage A OK in %.2fs — baseband link up (isConnected=%@)", stageASeconds, target.isConnected() ? "yes" : "no"))

        // Stage B: does the speaker come back as a Core Audio output device
        // (i.e. did A2DP actually re-establish, not just the baseband link)?
        print("connect-probe: stage B — polling Core Audio for the output device (timeout \(Int(coreAudioPollTimeoutSeconds))s)...")
        let stageB = Stopwatch()
        if let found = pollCoreAudio(matching: target, untilPresent: true) {
            print(String(format: "connect-probe: stage B OK in %.1fs — output device appeared: id=%d name=\"%@\" uid=%@", stageB.elapsedSeconds, found.id, found.name, found.uid))
            print(String(format: "connect-probe: TOTAL connect -> audio-endpoint time: %.1fs", stageASeconds + stageB.elapsedSeconds))
            return 0
        }
        print(String(format: "connect-probe: stage B FAILED — baseband connected but NO Core Audio output appeared within %.0fs (A2DP did not re-establish; the deep-link fallback would be needed here)", coreAudioPollTimeoutSeconds))
        return 1
    }

    private static func runDisconnect(_ target: IOBluetoothDevice, name: String) -> Int32 {
        guard target.isConnected() else {
            print("connect-probe: \"\(name)\" is already disconnected")
            return 0
        }
        let stageA = Stopwatch()
        let result = target.closeConnection()
        print(String(format: "connect-probe: closeConnection() -> %@ in %.2fs", ioReturnString(result), stageA.elapsedSeconds))
        guard result == 0 else { return 1 }

        print("connect-probe: polling Core Audio for the output device to vanish (timeout \(Int(coreAudioPollTimeoutSeconds))s)...")
        let stageB = Stopwatch()
        if pollCoreAudio(matching: target, untilPresent: false) == nil, findCoreAudioDevice(matching: target) == nil {
            print(String(format: "connect-probe: output device gone after %.1fs — round-trip ready (re-run without --disconnect)", stageB.elapsedSeconds))
            return 0
        }
        // pollCoreAudio(untilPresent: false) returns the device while it is
        // still present at timeout; nil means it vanished (or never re-read) —
        // re-checked above so a stale nil can't mask "still there".
        print(String(format: "connect-probe: output device STILL PRESENT after %.0fs — Core Audio kept the endpoint despite closeConnection()", coreAudioPollTimeoutSeconds))
        return 1
    }

    /// Does this device advertise audio? Strong signal: a cached SDP record
    /// for the A2DP AudioSink service class (UUID16 0x110B). Weaker fallback:
    /// Class-of-Device major class 0x04 (Audio/Video) recorded at pairing —
    /// present even when no SDP cache survives for a long-disconnected device.
    private static func audioServiceTag(_ device: IOBluetoothDevice) -> String {
        if device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x110B)) != nil {
            return "A2DP-sink"
        }
        if device.deviceClassMajor == 0x04 {
            return "audio-class(no cached A2DP SDP record)"
        }
        return "none-advertised"
    }

    // MARK: - Selection / matching

    private static func selectTarget(query: String?, from paired: [IOBluetoothDevice]) -> IOBluetoothDevice? {
        if let query {
            let matches = paired.filter { matches($0, query: query) }
            switch matches.count {
            case 1:
                return matches[0]
            case 0:
                elog("connect-probe: no paired device matches '\(query)' (match by name, case-insensitive, or address)")
                return nil
            default:
                elog("connect-probe: '\(query)' is ambiguous (\(matches.count) matches) — use the full name or the address")
                return nil
            }
        }
        // Interactive pick — only when a human is on the other end. Launched
        // via `open` there is no usable stdin, so listing-only is the result.
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        print("enter device # to connect-probe (Enter = just list): ", terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces),
              let n = Int(line), n >= 1, n <= paired.count else { return nil }
        return paired[n - 1]
    }

    private static func matches(_ device: IOBluetoothDevice, query: String) -> Bool {
        if let name = device.name, name.lowercased() == query.lowercased() { return true }
        let queryHex = normalizedHex(query)
        if !queryHex.isEmpty, queryHex.count >= 12, // full 6-byte address only — avoid accidental partial-hex matches
           normalizedHex(device.addressString ?? "") == queryHex { return true }
        // Loose fallback: unambiguous case-insensitive substring of the name.
        if let name = device.name, name.lowercased().contains(query.lowercased()) { return true }
        return false
    }

    /// Uppercased hex characters only — collapses "aa:bb-cc" formatting
    /// differences between IOBluetooth address strings, Core Audio UIDs, and
    /// whatever the user typed.
    private static func normalizedHex(_ s: String) -> String {
        String(s.uppercased().unicodeScalars.filter { CharacterSet(charactersIn: "0123456789ABCDEF").contains($0) })
    }

    // MARK: - Core Audio side (reuses BTDeviceEnumerator)

    private static func findCoreAudioDevice(matching target: IOBluetoothDevice) -> BTOutputDevice? {
        let addrHex = normalizedHex(target.addressString ?? "")
        let targetName = (target.name ?? "").lowercased()
        return BTDeviceEnumerator.listBluetoothOutputDevices()
            .filter { !$0.isAggregate }
            .first { candidate in
                if !addrHex.isEmpty, normalizedHex(candidate.uid).contains(addrHex) { return true }
                return !targetName.isEmpty && candidate.name.lowercased() == targetName
            }
    }

    /// Polls until the matching Core Audio output device is present (or, with
    /// `untilPresent: false`, absent). Returns the device on a successful
    /// "present" wait; nil on timeout or on a successful "absent" wait.
    private static func pollCoreAudio(matching target: IOBluetoothDevice, untilPresent: Bool) -> BTOutputDevice? {
        let stopwatch = Stopwatch()
        while stopwatch.elapsedSeconds < coreAudioPollTimeoutSeconds {
            let found = findCoreAudioDevice(matching: target)
            if untilPresent, let found { return found }
            if !untilPresent, found == nil { return nil }
            Thread.sleep(forTimeInterval: coreAudioPollIntervalSeconds)
        }
        return untilPresent ? nil : findCoreAudioDevice(matching: target)
    }

    // MARK: - TCC diagnosis

    @discardableResult
    private static func printAuthorizationStatus() -> CBManagerAuthorization {
        // Reading CBManager.authorization does NOT trigger a prompt (a prompt
        // only fires on actual Bluetooth use) — safe to always print first.
        let auth = CBManager.authorization
        let label: String
        switch auth {
        case .allowedAlways: label = "allowed"
        case .denied: label = "DENIED"
        case .restricted: label = "restricted"
        case .notDetermined: label = "not determined (no prompt has been answered yet)"
        @unknown default: label = "unknown (rawValue=\(auth.rawValue))"
        }
        print("connect-probe: Bluetooth TCC status for this process's attribution: \(label)")
        print("connect-probe:   (for a bare CLI this is the hosting terminal's grant, not this binary's — see make-spike-app.sh for the .app attribution path)")
        return auth
    }

    private static func diagnoseEmptyPairedList(_ auth: CBManagerAuthorization) {
        switch auth {
        case .allowedAlways:
            print("connect-probe: empty list with Bluetooth ALLOWED — genuinely nothing is paired. Pair a speaker in System Settings > Bluetooth first.")
        case .denied:
            print("connect-probe: DIAGNOSIS: Bluetooth permission is DENIED for this attribution — IOBluetooth fails silently (empty list, no error). Grant it in System Settings > Privacy & Security > Bluetooth, or use the .app wrapper (make-spike-app.sh) for a fresh prompt.")
        case .restricted:
            print("connect-probe: DIAGNOSIS: Bluetooth access is RESTRICTED (MDM/parental policy) — IOBluetooth cannot work in this attribution.")
        case .notDetermined:
            print("connect-probe: DIAGNOSIS: no Bluetooth TCC decision exists yet AND the list came back empty — a bare CLI often gets no prompt at all (silent failure). Build the wrapper with make-spike-app.sh and launch it via `open` to force a proper prompt.")
        @unknown default:
            print("connect-probe: empty paired list; TCC status unrecognized (rawValue=\(auth.rawValue))")
        }
    }

    // MARK: - Small helpers

    private static func ioReturnString(_ result: IOReturn) -> String {
        result == 0 ? "success" : String(format: "0x%08x", result)
    }
}

/// Minimal elapsed-time reader on the uptime clock (probe stages only care
/// about deltas, never wall time).
struct Stopwatch {
    private let startNanos = DispatchTime.now().uptimeNanoseconds
    var elapsedSeconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000_000.0
    }
}
