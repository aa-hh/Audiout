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

import Foundation
import AirPlayEngine

// MARK: - Per-device args

/// One `--address`/`--device-id` (plus the other per-device flags that
/// preceded it) describes one output. Flags are consumed in the order given
/// on the command line: each `--address` starts a new device slot, and any
/// per-device flag before the first `--address` seeds the defaults for
/// devices that don't override it.
struct ProbeDevice {
    var deviceName: String = "Test Speaker"
    var address: String = ""
    var port: Int = 7000
    var deviceID: String = ""              // colon-hex MAC, e.g. AA:BB:CC:DD:EE:FF
    var features: String = "0x445F8A00,0x1C340"
    var model: String = "AudioAccessory5,1"
    var ipv6: Bool = false
    var password: String?
}

struct ProbeArgs {
    var devices: [ProbeDevice] = []
    var pcmPath: String = ""               // interleaved S16LE 44100/2 raw PCM, shared by all outputs
    var gated: Bool = false                // the explicit live-run flag
}

func usage() -> String {
    """
    engine-probe — gated multi-device AirPlay session probe

    USAGE (single device):
      engine-probe --address <ip> --device-id <AA:BB:..> --pcm <file.raw> [options] \\
                   --i-have-a-receiver-and-owntone-is-stopped

    USAGE (multi-room — repeat the per-device flags before each --address):
      engine-probe --pcm <file.raw> \\
                   --name "Kitchen" --address <ip1> --device-id <hex1> \\
                   --name "Living Room" --address <ip2> --device-id <hex2> \\
                   --i-have-a-receiver-and-owntone-is-stopped

    REQUIRED (for a live run):
      --address <ip>          Resolved receiver IP (v4 unless --ipv6). Repeatable:
                               each occurrence starts a new output device.
      --device-id <hex>       Colon-hex device id from the TXT record, for the
                               device slot most recently opened by --address.
      --pcm <path>            Raw interleaved S16LE PCM, 44100 Hz, 2ch. Shared
                               by every output — one source, fanned out.

    PER-DEVICE OPTIONS (apply to the device slot they precede/follow; set
    before the first --address to change the default for all devices):
      --name <str>            mDNS instance name          (default "Test Speaker")
      --port <n>              RTSP port                   (default 7000)
      --features <str>        TXT features string         (default AP2 audio)
      --model <str>           TXT model                   (default HomePod-like)
      --ipv6                  Treat this device's --address as IPv6
      --password <str>        RTSP password, if required

    GATE (required to actually open a session):
      --i-have-a-receiver-and-owntone-is-stopped
                              Confirms real receiver(s) are present AND OwnTone/any
                              PTP daemon is stopped (UDP 319/320 free) AND a human
                              is watching. Without this flag the probe only prints
                              its plan and exits — it opens NO sockets.

    This CLI is built green by `swift build` but is NEVER run as part of
    T-API-1 / T-ENG-MULTIROOM-CLI-1.
    """
}

func parseArgs(_ argv: [String]) -> ProbeArgs {
    var a = ProbeArgs()
    var current = ProbeDevice()
    var haveDevice = false
    var i = 0
    func next() -> String { i += 1; return i < argv.count ? argv[i] : "" }
    // Once the in-progress slot already has an address, ANY per-device flag
    // (--name/--port/--features/--model/--ipv6/--password) that arrives
    // before the NEXT --address is describing a new device, not amending the
    // one just committed by its own --device-id — so it must commit the
    // in-progress slot first. This keeps
    //   --name Kitchen --address ip1 --device-id id1 \
    //   --name "Living Room" --address ip2 --device-id id2
    // from clobbering Kitchen's name in place before it's committed.
    func commitIfStartingNewDevice() {
        if haveDevice && !current.address.isEmpty {
            a.devices.append(current)
            current = ProbeDevice()
            haveDevice = false
        }
    }
    while i < argv.count {
        switch argv[i] {
        case "--name":
            commitIfStartingNewDevice()
            current.deviceName = next()
        case "--address":
            // A bare second --address with no intervening per-device flag
            // also starts a fresh device slot.
            commitIfStartingNewDevice()
            current.address = next()
            haveDevice = true
        case "--port":
            commitIfStartingNewDevice()
            current.port = Int(next()) ?? current.port
        case "--device-id": current.deviceID = next()
        case "--features":
            commitIfStartingNewDevice()
            current.features = next()
        case "--model":
            commitIfStartingNewDevice()
            current.model = next()
        case "--ipv6":
            commitIfStartingNewDevice()
            current.ipv6 = true
        case "--pcm": a.pcmPath = next()
        case "--password":
            commitIfStartingNewDevice()
            current.password = next()
        case "--i-have-a-receiver-and-owntone-is-stopped": a.gated = true
        case "-h", "--help": print(usage()); exit(0)
        default: FileHandle.standardError.write(Data("Unknown arg: \(argv[i])\n".utf8))
        }
        i += 1
    }
    if haveDevice {
        a.devices.append(current)
    }
    return a
}

// MARK: - Main

let args = parseArgs(Array(CommandLine.arguments.dropFirst()))

print("engine-probe plan: \(args.devices.count) device(s)")
if args.devices.isEmpty {
    print("  <no devices specified — pass --address/--device-id at least once>")
} else {
    for (idx, d) in args.devices.enumerated() {
        print("  [\(idx)] \(d.deviceName) @ \(d.address):\(d.port) (\(d.ipv6 ? "IPv6" : "IPv4"))")
        print("       deviceid : \(d.deviceID.isEmpty ? "<missing>" : d.deviceID)")
    }
}
print("  pcm      : \(args.pcmPath.isEmpty ? "<missing>" : args.pcmPath)")
print("  gated    : \(args.gated)")

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

guard !args.devices.isEmpty else {
    FileHandle.standardError.write(Data("Gated run needs at least one --address/--device-id pair.\n".utf8))
    exit(2)
}
for d in args.devices {
    guard !d.address.isEmpty, !d.deviceID.isEmpty else {
        FileHandle.standardError.write(Data("Gated run needs --address and --device-id for every device.\n".utf8))
        exit(2)
    }
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
