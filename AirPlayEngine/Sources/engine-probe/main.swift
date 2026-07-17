// engine-probe — the gated multi-device AirPlay session probe (T-API-1 artifact,
// extended for multi-room by T-ENG-MULTIROOM-CLI-1).
//
// PURPOSE. This CLI WOULD drive one or more real AirPlay 2 sessions end-to-end,
// in sync: start the engine, feed each device's discovery descriptor
// (discovery-in), addOutput each (await the RTSP/PTP setup completion), set
// volume, pump ONE shared PCM file to all of them off a single advancing pts,
// then stop. It is the artifact a human (Alec) runs LATER, in a GATED session —
// it is NOT run by the T-API-1 / T-ENG-MULTIROOM-CLI-1 build tasks.
//
// WHY GATED. A live run needs ALL of:
//   1. One or more real AirPlay 2 receivers on the LAN (Sonos / HomePod /
//      Apple TV / a test receiver — see docs/receiver-harness-guide.md).
//   2. OwnTone (or any other AirPlay sender / PTP daemon) STOPPED — the AirPlay 2
//      PTP clock binds UDP 319/320, and a running OwnTone/dev instance contends
//      for those ports (build-notes; SPEC PTP notes).
//   3. A human present to confirm audio actually comes out of the speaker(s)
//      and to stop the run.
//
// So the actual session is refused unless the explicit flag
//   --i-have-a-receiver-and-owntone-is-stopped
// is passed. Without it, the CLI parses args, prints the plan for however many
// devices were given, and exits 0 — which is all `swift build` / CI ever
// exercise. NEVER add a default that opens a socket.
//
// ARG PARSING lives in the EngineProbeParsing library target (unit-tested by
// Tests/AirPlayEngineTests/EngineProbeParsingTests.swift) after the first
// gated multi-room run (2026-07-17) was burned by an untested parser footgun
// — see the header of Sources/EngineProbeParsing/ProbeArgParsing.swift. A
// malformed argv (a device committed without its --device-id, trailing
// per-device flags, an unknown flag) prints the plan PLUS the problems and
// exits 2 without opening a socket — dry-run included, so the exact command
// line for a gated session can (and should) be validated un-gated first.

import Foundation
import AirPlayEngine
import EngineProbeParsing

// MARK: - Main

let args = parseProbeArgs(Array(CommandLine.arguments.dropFirst()))

if args.wantsHelp {
    print(usage())
    exit(0)
}

print("engine-probe plan: \(args.devices.count) device(s)")
if args.devices.isEmpty {
    print("  <no devices specified — pass --address/--device-id at least once>")
} else {
    for (idx, d) in args.devices.enumerated() {
        let addr = d.address.isEmpty ? "<MISSING --address>" : d.address
        print("  [\(idx)] \(d.deviceName) @ \(addr):\(d.port) (\(d.ipv6 ? "IPv6" : "IPv4"))")
        print("       deviceid : \(d.deviceID.isEmpty ? "<MISSING --device-id>" : d.deviceID)")
    }
}
print("  pcm      : \(args.pcmPath.isEmpty ? "<missing>" : args.pcmPath)")
print("  gated    : \(args.gated)")

// Parse problems are fatal in EVERY mode, dry-run included: the whole point
// of the un-gated dry run is to validate the exact command line a later
// gated session will spend real receivers on. (2026-07-17: a silently
// misparsed plan split one device into two and burned the first gated
// multi-room run.)
if !args.problems.isEmpty {
    fflush(stdout)  // keep the plan above the problems when both hit a terminal
    let report = args.problems.map { "  ! \($0)" }.joined(separator: "\n")
    FileHandle.standardError.write(Data("""

    engine-probe: the argument list does not describe an unambiguous plan:
    \(report)
    No session was opened. See --help for how flags group into devices.

    """.utf8))
    exit(2)
}

guard args.gated else {
    print("""

    NOT running a live session: the \
    --i-have-a-receiver-and-owntone-is-stopped flag was not passed.
    This is expected during build/CI. Pass the flag (with real receiver(s) and \
    OwnTone stopped) to actually stream. Exiting 0.
    """)
    exit(0)
}

// ---- Beyond this point ONLY runs in a real gated session (flag present). ----
// This block is intentionally the ONLY code that opens a real network session.
// Per-device completeness (--address + --device-id on every device) is already
// guaranteed: an incomplete device is a parse problem, which exited 2 above.

guard !args.devices.isEmpty else {
    FileHandle.standardError.write(Data("Gated run needs at least one --address/--device-id pair.\n".utf8))
    exit(2)
}
guard !args.pcmPath.isEmpty else {
    FileHandle.standardError.write(Data("Gated run needs --pcm.\n".utf8))
    exit(2)
}

func runLiveSession(_ args: ProbeArgs) async {
    let engine = AirPlayEngine(config: EngineConfig(
        clientName: "AirPlayEngine Probe",
        bindAddress: nil,
        enableIPv6: args.devices.contains { $0.ipv6 }
    ))

    do {
        print("[probe] starting engine (airplay_init: timing/control services + ptpd)...")
        try await engine.start()

        var ids: [OutputID] = []
        for d in args.devices {
            var txt: [String: String] = [
                "deviceid": d.deviceID,
                "features": d.features,
                "model": d.model,
            ]
            if let pw = d.password { txt["pw"] = "true"; _ = pw }

            let descriptor = DeviceDescriptor(
                name: d.deviceName,
                hostname: d.address,
                address: d.address,
                family: d.ipv6 ? .ipv6 : .ipv4,
                port: d.port,
                txtRecord: txt
            )

            print("[probe] feeding discovery descriptor for \(d.deviceName)...")
            let id = try await engine.updateDiscovery(descriptor)

            print("[probe] addOutput \(d.deviceName) (awaiting RTSP/PTP setup completion)...")
            try await engine.addOutput(id)

            print("[probe] setVolume 0.4 on \(d.deviceName)...")
            try await engine.setVolume(id, 0.4)

            ids.append(id)
        }

        // Pump the raw PCM file in 352-sample (AirPlay frame) chunks. ONE
        // shared, monotonically advancing pts drives every output — engine.write
        // fans the same buffer out to all currently-added outputs, so playback
        // stays in sync across the room the same way OwnTone's player does.
        let pcm = try Data(contentsOf: URL(fileURLWithPath: args.pcmPath))
        let bytesPerFrame = 2 /*ch*/ * 2 /*S16*/
        let samplesPerChunk = 352
        let chunkBytes = samplesPerChunk * bytesPerFrame
        let sampleRate = 44100.0
        print("[probe] streaming \(pcm.count) bytes of PCM in \(chunkBytes)-byte frames to \(ids.count) output(s)...")

        // The pts MUST advance with the audio: airplay.c's timestamp_set()
        // stores it as "the player clock ... normally now" and the periodic
        // sync packets tell the receiver what rtptime should be audible at
        // that instant. A frozen pts makes every re-sync claim an advancing
        // position plays at a time receding into the past -> the receiver
        // keeps the session but schedules nothing (gated first-light
        // 2026-07-16: Sonos light green, never white, no audio). OwnTone's
        // player passes a CALCULATED clock (samples/rate since start), which
        // timestamp_set explicitly prefers over the actual clock — do the same.
        var startTS = timespec()
        clock_gettime(CLOCK_MONOTONIC, &startTS)
        let t0 = Double(startTS.tv_sec) + Double(startTS.tv_nsec) / 1e9

        var offset = 0
        var chunkIndex = 0
        while offset < pcm.count {
            let end = min(offset + chunkBytes, pcm.count)
            let elapsed = Double(chunkIndex) * Double(samplesPerChunk) / sampleRate
            let t = t0 + elapsed
            let sec = Int(t)
            let pts = timespec(tv_sec: sec, tv_nsec: Int((t - Double(sec)) * 1e9))
            // One PCM source, one pts, fanned to every added output by the engine.
            engine.write(pcm: pcm.subdata(in: offset..<end), pts: pts)
            offset = end
            chunkIndex += 1

            // Absolute-deadline pacing against the same calculated timeline,
            // so cumulative sleep jitter can't drift the cadence away from
            // the pts we are claiming.
            let target = t0 + Double(chunkIndex) * Double(samplesPerChunk) / sampleRate
            var nowTS = timespec()
            clock_gettime(CLOCK_MONOTONIC, &nowTS)
            let now = Double(nowTS.tv_sec) + Double(nowTS.tv_nsec) / 1e9
            if target > now {
                try await Task.sleep(nanoseconds: UInt64((target - now) * 1e9))
            }
        }

        // Let the receivers' ~2s buffer drain before tearing down, or the
        // tail of the tone gets cut off with the session.
        print("[probe] done streaming; letting the buffered tail play out (3s)...")
        try await Task.sleep(nanoseconds: 3_000_000_000)

        print("[probe] stopping...")
        await engine.stop()
        print("[probe] stopped cleanly.")
    } catch {
        FileHandle.standardError.write(Data("[probe] error: \(error)\n".utf8))
        await engine.stop()
        exit(1)
    }
}

await runLiveSession(args)
