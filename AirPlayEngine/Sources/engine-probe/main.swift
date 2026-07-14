// engine-probe — the gated one-device AirPlay session probe (T-API-1 artifact).
//
// PURPOSE. This CLI WOULD drive a single real AirPlay 2 session end-to-end:
// start the engine, feed one device descriptor (discovery-in), addOutput (await
// the RTSP/PTP setup completion), set volume, pump a PCM file, then stop. It is
// the artifact a human (Alec) runs LATER, in a GATED session — it is NOT run by
// the T-API-1 build task.
//
// WHY GATED. A live run needs ALL of:
//   1. A real AirPlay 2 receiver on the LAN (Sonos / HomePod / Apple TV / a
//      test receiver — see docs/receiver-harness-guide.md).
//   2. OwnTone (or any other AirPlay sender / PTP daemon) STOPPED — the AirPlay 2
//      PTP clock binds UDP 319/320, and a running OwnTone/dev instance contends
//      for those ports (build-notes; SPEC PTP notes).
//   3. A human present to confirm audio actually comes out of the speaker and to
//      stop the run.
//
// So the actual session is refused unless the explicit flag
//   --i-have-a-receiver-and-owntone-is-stopped
// is passed. Without it, the CLI parses args, prints the plan, and exits 0 —
// which is all `swift build` / CI ever exercise. NEVER add a default that opens
// a socket.

import Foundation
import AirPlayEngine

// MARK: - Arg parsing

struct ProbeArgs {
    var deviceName: String = "Test Speaker"
    var address: String = ""
    var port: Int = 7000
    var deviceID: String = ""              // colon-hex MAC, e.g. AA:BB:CC:DD:EE:FF
    var features: String = "0x445F8A00,0x1C340"
    var model: String = "AudioAccessory5,1"
    var ipv6: Bool = false
    var pcmPath: String = ""               // interleaved S16LE 44100/2 raw PCM
    var gated: Bool = false                // the explicit live-run flag
    var password: String?
}

func usage() -> String {
    """
    engine-probe — gated one-device AirPlay session probe

    USAGE:
      engine-probe --address <ip> --device-id <AA:BB:..> --pcm <file.raw> [options] \\
                   --i-have-a-receiver-and-owntone-is-stopped

    REQUIRED (for a live run):
      --address <ip>          Resolved receiver IP (v4 unless --ipv6)
      --device-id <hex>       Colon-hex device id from the TXT record
      --pcm <path>            Raw interleaved S16LE PCM, 44100 Hz, 2ch

    OPTIONS:
      --name <str>            mDNS instance name          (default "Test Speaker")
      --port <n>              RTSP port                   (default 7000)
      --features <str>        TXT features string         (default AP2 audio)
      --model <str>           TXT model                   (default HomePod-like)
      --ipv6                  Treat --address as IPv6
      --password <str>        RTSP password, if required

    GATE (required to actually open a session):
      --i-have-a-receiver-and-owntone-is-stopped
                              Confirms a real receiver is present AND OwnTone/any
                              PTP daemon is stopped (UDP 319/320 free) AND a human
                              is watching. Without this flag the probe only prints
                              its plan and exits — it opens NO sockets.

    This CLI is built green by `swift build` but is NEVER run as part of T-API-1.
    """
}

func parseArgs(_ argv: [String]) -> ProbeArgs {
    var a = ProbeArgs()
    var i = 0
    func next() -> String { i += 1; return i < argv.count ? argv[i] : "" }
    while i < argv.count {
        switch argv[i] {
        case "--name": a.deviceName = next()
        case "--address": a.address = next()
        case "--port": a.port = Int(next()) ?? a.port
        case "--device-id": a.deviceID = next()
        case "--features": a.features = next()
        case "--model": a.model = next()
        case "--ipv6": a.ipv6 = true
        case "--pcm": a.pcmPath = next()
        case "--password": a.password = next()
        case "--i-have-a-receiver-and-owntone-is-stopped": a.gated = true
        case "-h", "--help": print(usage()); exit(0)
        default: FileHandle.standardError.write(Data("Unknown arg: \(argv[i])\n".utf8))
        }
        i += 1
    }
    return a
}

// MARK: - Main

let args = parseArgs(Array(CommandLine.arguments.dropFirst()))

print("engine-probe plan:")
print("  device   : \(args.deviceName) @ \(args.address):\(args.port) (\(args.ipv6 ? "IPv6" : "IPv4"))")
print("  deviceid : \(args.deviceID.isEmpty ? "<missing>" : args.deviceID)")
print("  pcm      : \(args.pcmPath.isEmpty ? "<missing>" : args.pcmPath)")
print("  gated    : \(args.gated)")

guard args.gated else {
    print("""

    NOT running a live session: the \
    --i-have-a-receiver-and-owntone-is-stopped flag was not passed.
    This is expected during build/CI. Pass the flag (with a real receiver and \
    OwnTone stopped) to actually stream. Exiting 0.
    """)
    exit(0)
}

// ---- Beyond this point ONLY runs in a real gated session (flag present). ----
// This block is intentionally the ONLY code that opens a real network session.

guard !args.address.isEmpty, !args.deviceID.isEmpty, !args.pcmPath.isEmpty else {
    FileHandle.standardError.write(Data("Gated run needs --address, --device-id and --pcm.\n".utf8))
    exit(2)
}

func runLiveSession(_ args: ProbeArgs) async {
    let engine = AirPlayEngine(config: EngineConfig(
        clientName: "AirPlayEngine Probe",
        bindAddress: nil,
        enableIPv6: args.ipv6
    ))

    do {
        print("[probe] starting engine (airplay_init: timing/control services + ptpd)...")
        try await engine.start()

        var txt: [String: String] = [
            "deviceid": args.deviceID,
            "features": args.features,
            "model": args.model,
        ]
        if let pw = args.password { txt["pw"] = "true"; _ = pw }

        let descriptor = DeviceDescriptor(
            name: args.deviceName,
            hostname: args.address,
            address: args.address,
            family: args.ipv6 ? .ipv6 : .ipv4,
            port: args.port,
            txtRecord: txt
        )

        print("[probe] feeding discovery descriptor...")
        let id = try await engine.updateDiscovery(descriptor)

        print("[probe] addOutput (awaiting RTSP/PTP setup completion)...")
        try await engine.addOutput(id)

        print("[probe] setVolume 0.4 ...")
        try await engine.setVolume(id, 0.4)

        // Pump the raw PCM file in 352-sample (AirPlay frame) chunks.
        let pcm = try Data(contentsOf: URL(fileURLWithPath: args.pcmPath))
        let bytesPerFrame = 2 /*ch*/ * 2 /*S16*/
        let samplesPerChunk = 352
        let chunkBytes = samplesPerChunk * bytesPerFrame
        print("[probe] streaming \(pcm.count) bytes of PCM in \(chunkBytes)-byte frames...")

        var offset = 0
        var pts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &pts)
        while offset < pcm.count {
            let end = min(offset + chunkBytes, pcm.count)
            engine.write(pcm: pcm.subdata(in: offset..<end), pts: pts)
            offset = end
            // ~8ms per 352-sample frame at 44100 Hz.
            try await Task.sleep(nanoseconds: 7_982_000)
        }

        print("[probe] done streaming; stopping...")
        await engine.stop()
        print("[probe] stopped cleanly.")
    } catch {
        FileHandle.standardError.write(Data("[probe] error: \(error)\n".utf8))
        await engine.stop()
        exit(1)
    }
}

await runLiveSession(args)
