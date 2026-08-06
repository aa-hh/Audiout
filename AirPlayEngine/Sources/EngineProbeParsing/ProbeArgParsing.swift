// EngineProbeParsing — the argument grammar for the gated engine-probe CLI,
// split into its own (tiny) library target so the test target can import it
// (code living in an executable's main.swift can't be cleanly unit-tested).
// This parser is exactly the kind of code that MUST be tested offline: a
// misparse here doesn't fail a build — it silently rewrites the device plan
// of a GATED live run, the one context where a human, real receivers, and a
// quiet PTP network are all being spent at once.
//
// WHY THIS EXISTS (2026-07-17, first gated multi-room run — burned). The
// previous parser committed the in-progress device slot whenever a
// per-device flag arrived while the slot already had an --address. That made
// the natural single-device ordering
//     --address X --port Y --device-id Z
// silently split into TWO devices: --port committed {X, default port, NO id}
// and Z landed in a ghost second slot (which stole the id, or was dropped).
// README.md's own example used exactly that ordering. The grammar below
// fixes the ordering footgun and turns every REMAINING ambiguity into a loud
// entry in ProbeArgs.problems instead of a silent misparse.
//
// THE GRAMMAR (amend-until-complete):
//   * A device slot is COMPLETE once it has BOTH --address and --device-id.
//   * Per-device flags AMEND the slot being described — in any order, before
//     or after its --address — until the slot is complete.
//   * Once a slot is complete, the next per-device flag commits it and
//     starts the next device. This is what makes the prefix style of the
//     usage() multi-room example work:
//       --name Kitchen --address ip1 --device-id id1 \
//       --name "Living Room" --address ip2 --device-id id2
//   * A second --address (or --device-id) before the slot is complete also
//     commits — two addresses can never be one device — but committing an
//     incomplete slot records a problem naming the missing flag.
//   * Per-device options BEFORE the first --address set the DEFAULTS every
//     later slot starts from (what usage() has always claimed; the old
//     parser only applied them to device 0). --device-id is never a default.
//   * ProbeArgs.problems is the loud channel: non-empty means the argv does
//     NOT describe an unambiguous plan. main.swift prints the plan WITH the
//     problems and exits 2 — dry-run included, so a bad command line is
//     caught by the un-gated dry run BEFORE a gated session is spent on it.

import Foundation

/// One output device, as described by the command line. See the grammar
/// note at the top of this file for how flags group into slots.
public struct ProbeDevice: Equatable {
    public var deviceName: String = "Test Speaker"
    public var address: String = ""
    public var port: Int = 7000
    public var deviceID: String = ""       // colon-hex MAC, e.g. AA:BB:CC:DD:EE:FF
    public var features: String = "0x445F8A00,0x1C340"
    public var model: String = "AudioAccessory5,1"
    public var ipv6: Bool = false
    public var password: String?
    /// Target this device over AirPlay 1 / RAOP (`output_raop`) instead of
    /// AirPlay 2 (`output_airplay`). Per-device, like `ipv6` — mirrors the
    /// AGENTS.md "two sender backends share one registry" rule. See
    /// main.swift's device loop for how this changes descriptor/TXT shape
    /// (no `features`/`model` — a real `_raop._tcp` TXT record has neither).
    public var raop: Bool = false

    public init() {}

    /// Complete = both identifying flags given. Only a complete slot lets
    /// the next per-device flag mean "start a new device".
    public var isComplete: Bool { !address.isEmpty && !deviceID.isEmpty }
}

public struct ProbeArgs: Equatable {
    public var devices: [ProbeDevice] = []
    public var pcmPath: String = ""        // interleaved S16LE 44100/2 raw PCM, shared by all outputs
    public var gated: Bool = false         // the explicit live-run flag
    public var wantsHelp: Bool = false     // -h/--help — caller prints usage() and exits 0

    /// Parse-time problems. Non-empty means the argv does NOT describe an
    /// unambiguous device plan; the CLI prints these after the plan and
    /// exits 2 (dry-run included) rather than letting a gated session run
    /// on a silently-misparsed plan.
    public var problems: [String] = []

    public init() {}
}

public func usage() -> String {
    """
    engine-probe — gated multi-device AirPlay session probe

    USAGE (single device — per-device flags in any order):
      engine-probe --address <ip> --port <n> --device-id <AA:BB:..> --pcm <file.raw> \\
                   --i-have-a-receiver-and-owntone-is-stopped

    USAGE (multi-room — each device's flags grouped together):
      engine-probe --pcm <file.raw> \\
                   --name "Kitchen" --address <ip1> --device-id <hex1> \\
                   --name "Living Room" --address <ip2> --device-id <hex2> \\
                   --i-have-a-receiver-and-owntone-is-stopped

    USAGE (AirPlay 1 / RAOP device — classic AirPort Express / AirTunes v2):
      engine-probe --raop --address <ip> --port 5000 --device-id <AA:BB:..> \\
                   --pcm <file.raw> --i-have-a-receiver-and-owntone-is-stopped
      (--raop routes this device to output_raop instead of output_airplay;
      it feeds a genuinely RAOP-shaped descriptor — no features/model TXT,
      no AP2 gate — see --raop below. Classic RAOP receivers usually listen
      on port 5000, not AirPlay 2's 7000.)

    HOW FLAGS GROUP INTO DEVICES: a device is complete once it has BOTH
    --address and --device-id. Per-device flags amend the device being
    described — in any order — until it is complete; the next per-device
    flag after that starts the next device. Anything ambiguous (a device
    committed without its --device-id, trailing per-device flags that never
    got an --address) is a loud parse problem: the probe prints the plan,
    the problems, and exits 2 without opening a session — dry runs included.
    ALWAYS dry-run the exact command line (without the gate flag) first.

    REQUIRED (for a live run):
      --address <ip>          Resolved receiver IP (v4 unless --ipv6). Repeatable:
                               each occurrence after a complete device starts a
                               new output device.
      --device-id <hex>       Colon-hex device id from the TXT record, for the
                               device being described.
      --pcm <path>            Raw interleaved S16LE PCM, 44100 Hz, 2ch. Shared
                               by every output — one source, fanned out.

    PER-DEVICE OPTIONS (amend the device being described; set before the
    first --address to change the default for every device):
      --name <str>            mDNS instance name          (default "Test Speaker")
      --port <n>              RTSP port                   (default 7000)
      --features <str>        TXT features string         (default AP2 audio)
      --model <str>           TXT model                   (default HomePod-like)
      --ipv6                  Treat this device's --address as IPv6
      --password <str>        RTSP password, if required
      --raop                  Target this device over AirPlay 1 / RAOP
                               (output_raop) instead of AirPlay 2
                               (output_airplay). Ignores --features/--model
                               (a real _raop._tcp TXT record has neither);
                               --device-id is still required (used for the
                               engine's own OutputID bookkeeping, and encoded
                               into the mDNS-style instance name raop_device_cb
                               parses its id back out of — see main.swift).

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

public func parseProbeArgs(_ argv: [String]) -> ProbeArgs {
    var parsed = ProbeArgs()
    var defaults = ProbeDevice()   // edited by per-device options before the first --address
    var current = ProbeDevice()
    var currentTouched = false     // a per-device flag landed in `current` since the last commit
    var defaultsTouched = false    // some per-device option arrived before any --address
    var seenFirstAddress = false
    var i = 0

    // Fetch the value for a flag that takes one; running off the end of argv
    // is a problem, not a silent empty string.
    func value(for flag: String) -> String? {
        i += 1
        if i < argv.count { return argv[i] }
        parsed.problems.append("\(flag) is missing its value")
        return nil
    }

    // Append the in-progress slot because `reason` starts (or ends) the next
    // one. Committing an INCOMPLETE slot is the shape that split one device
    // into two on the 2026-07-17 gated run — the slot is still appended (so
    // the printed plan shows exactly what was parsed) but it records a loud
    // problem instead of misparsing silently.
    func commit(because reason: String) {
        if current.address.isEmpty {
            parsed.problems.append(
                "device[\(parsed.devices.count)] (\"\(current.deviceName)\") has no --address "
                + "(committed by \(reason))")
        }
        if current.deviceID.isEmpty {
            parsed.problems.append(
                "device[\(parsed.devices.count)] (\"\(current.deviceName)\" @ \(current.address)) "
                + "has no --device-id (committed by \(reason)) — per-device flags amend the "
                + "device being described until BOTH --address and --device-id are given")
        }
        parsed.devices.append(current)
        current = defaults
        currentTouched = false
    }

    // A per-device option (--name/--port/--features/--model/--ipv6/--password).
    // Before the first --address it edits the DEFAULTS every slot starts from;
    // after that it amends the in-progress slot, committing first only if
    // that slot is already complete.
    func applyPerDeviceOption(_ flag: String, _ apply: (inout ProbeDevice) -> Void) {
        if !seenFirstAddress {
            apply(&defaults)
            apply(&current)        // current mirrors defaults until the first --address
            defaultsTouched = true
        } else {
            if current.isComplete { commit(because: flag) }
            apply(&current)
            currentTouched = true
        }
    }

    while i < argv.count {
        switch argv[i] {
        case "--address":
            if let v = value(for: "--address") {
                // A second --address can never amend the same slot — two
                // addresses are two devices (commit() flags the missing
                // --device-id if the first slot never got one).
                if !current.address.isEmpty { commit(because: "--address \(v)") }
                current.address = v
                currentTouched = true
                seenFirstAddress = true
            }
        case "--device-id":
            if let v = value(for: "--device-id") {
                // Likewise two --device-id are two devices (id-first style:
                // --device-id id1 --address ip1 --device-id id2 --address ip2).
                if !current.deviceID.isEmpty { commit(because: "--device-id \(v)") }
                current.deviceID = v
                currentTouched = true
            }
        case "--name":
            if let v = value(for: "--name") {
                applyPerDeviceOption("--name \(v)") { $0.deviceName = v }
            }
        case "--port":
            if let v = value(for: "--port") {
                if let p = Int(v), (1...65535).contains(p) {
                    applyPerDeviceOption("--port \(v)") { $0.port = p }
                } else {
                    parsed.problems.append("--port \(v) is not a valid port number")
                }
            }
        case "--features":
            if let v = value(for: "--features") {
                applyPerDeviceOption("--features \(v)") { $0.features = v }
            }
        case "--model":
            if let v = value(for: "--model") {
                applyPerDeviceOption("--model \(v)") { $0.model = v }
            }
        case "--ipv6":
            applyPerDeviceOption("--ipv6") { $0.ipv6 = true }
        case "--raop":
            applyPerDeviceOption("--raop") { $0.raop = true }
        case "--password":
            if let v = value(for: "--password") {
                applyPerDeviceOption("--password") { $0.password = v }
            }
        case "--pcm":
            if let v = value(for: "--pcm") { parsed.pcmPath = v }
        case "--i-have-a-receiver-and-owntone-is-stopped":
            parsed.gated = true
        case "-h", "--help":
            parsed.wantsHelp = true
        default:
            parsed.problems.append("unknown argument: \(argv[i])")
        }
        i += 1
    }

    // Final slot: anything holding an --address or --device-id is a device
    // (completeness-checked by commit); per-device flags that never attached
    // to one are a problem, not a silent drop.
    if !current.address.isEmpty || !current.deviceID.isEmpty {
        commit(because: "end of arguments")
    } else if currentTouched {
        parsed.problems.append(
            "trailing per-device flags never got an --address/--device-id — per-device "
            + "flags apply to the device being described; give them before the flag "
            + "that completes it")
    } else if defaultsTouched && parsed.devices.isEmpty {
        parsed.problems.append("per-device flags were given but no --address ever arrived")
    }
    return parsed
}
