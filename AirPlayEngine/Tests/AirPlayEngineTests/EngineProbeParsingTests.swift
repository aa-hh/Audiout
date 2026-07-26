// Parser regression net for the gated engine-probe CLI (EngineProbeParsing).
//
// WHY: the first gated multi-room run (2026-07-17) was burned by an argv
// footgun — the old parser committed the in-progress device slot whenever a
// per-device flag arrived after that slot's --address, so the natural
// ordering
//   --address X --port Y --device-id Z
// silently became TWO devices (the first id-less, the second stealing the
// id). These tests pin the amend-until-complete grammar (see
// Sources/EngineProbeParsing/ProbeArgParsing.swift) across flag orderings,
// and pin that every remaining ambiguity surfaces in ProbeArgs.problems
// instead of misparsing silently. NO engine, NO sockets — pure parsing.

import Testing
import EngineProbeParsing

@Suite struct EngineProbeParsingTests {

    // MARK: - Single device: the identifying flags in every ordering

    /// THE footgun that burned the gated run: address, then port, then id
    /// must stay ONE device — --port amends the slot, it does not commit it.
    @Test func addressThenPortThenID() {
        let a = parseProbeArgs(["--address", "192.168.1.50", "--port", "7100",
                                "--device-id", "AA:BB:CC:DD:EE:FF"])
        #expect(a.problems == [])
        #expect(a.devices.count == 1)
        #expect(a.devices[0].address == "192.168.1.50")
        #expect(a.devices[0].port == 7100)
        #expect(a.devices[0].deviceID == "AA:BB:CC:DD:EE:FF")
    }

    @Test func portThenAddressThenID() {
        let a = parseProbeArgs(["--port", "7100", "--address", "192.168.1.50",
                                "--device-id", "AA:BB:CC:DD:EE:FF"])
        #expect(a.problems == [])
        #expect(a.devices.count == 1)
        #expect(a.devices[0].port == 7100)
        #expect(a.devices[0].deviceID == "AA:BB:CC:DD:EE:FF")
    }

    /// Prefix style: all options first, then --address, then --device-id
    /// immediately after it (the usage() multi-room shape, single device).
    @Test func idImmediatelyAfterAddress() {
        let a = parseProbeArgs(["--name", "Kitchen", "--port", "7100",
                                "--address", "192.168.1.50",
                                "--device-id", "AA:BB:CC:DD:EE:FF"])
        #expect(a.problems == [])
        #expect(a.devices.count == 1)
        #expect(a.devices[0].deviceName == "Kitchen")
        #expect(a.devices[0].port == 7100)
        #expect(a.devices[0].deviceID == "AA:BB:CC:DD:EE:FF")
    }

    /// Id dead last, after every other per-device flag has amended the slot.
    @Test func idLast() {
        let a = parseProbeArgs(["--address", "192.168.1.50", "--name", "Kitchen",
                                "--port", "7100", "--features", "0x1", "--model", "Sonos",
                                "--password", "hunter2",
                                "--device-id", "AA:BB:CC:DD:EE:FF"])
        #expect(a.problems == [])
        #expect(a.devices.count == 1)
        let d = a.devices[0]
        #expect(d.deviceName == "Kitchen")
        #expect(d.port == 7100)
        #expect(d.features == "0x1")
        #expect(d.model == "Sonos")
        #expect(d.password == "hunter2")
        #expect(d.deviceID == "AA:BB:CC:DD:EE:FF")
    }

    /// Id BEFORE the address is also unambiguous — the slot completes at
    /// --address instead of at --device-id.
    @Test func idBeforeAddress() {
        let a = parseProbeArgs(["--device-id", "AA:BB:CC:DD:EE:FF",
                                "--address", "192.168.1.50"])
        #expect(a.problems == [])
        #expect(a.devices.count == 1)
        #expect(a.devices[0].address == "192.168.1.50")
        #expect(a.devices[0].deviceID == "AA:BB:CC:DD:EE:FF")
    }

    /// README.md's documented invocation (whose address→port→…→id ordering
    /// the old parser misparsed into two devices) must parse as one gated
    /// single-device plan.
    @Test func readmeExampleOrdering() {
        let a = parseProbeArgs(["--address", "192.168.1.50", "--port", "7000",
                                "--features", "0x445F8A00,0x1C340",
                                "--model", "AudioAccessory5,1",
                                "--device-id", "AA:BB:CC:DD:EE:FF",
                                "--pcm", "/tmp/audio.raw",
                                "--i-have-a-receiver-and-owntone-is-stopped"])
        #expect(a.problems == [])
        #expect(a.devices.count == 1)
        #expect(a.devices[0].deviceID == "AA:BB:CC:DD:EE:FF")
        #expect(a.devices[0].features == "0x445F8A00,0x1C340")
        #expect(a.devices[0].model == "AudioAccessory5,1")
        #expect(a.pcmPath == "/tmp/audio.raw")
        #expect(a.gated)
    }

    // MARK: - Multi-room

    /// The usage() multi-room example (prefix style).
    @Test func twoDevicesPrefixStyle() {
        let a = parseProbeArgs(["--pcm", "/tmp/audio.raw",
                                "--name", "Kitchen", "--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--name", "Living Room", "--address", "10.0.0.2", "--device-id", "BB:BB"])
        #expect(a.problems == [])
        #expect(a.devices.count == 2)
        #expect(a.devices[0].deviceName == "Kitchen")
        #expect(a.devices[0].address == "10.0.0.1")
        #expect(a.devices[0].deviceID == "AA:AA")
        #expect(a.devices[1].deviceName == "Living Room")
        #expect(a.devices[1].address == "10.0.0.2")
        #expect(a.devices[1].deviceID == "BB:BB")
    }

    /// The exact shape that burned the 2026-07-17 run: per-device options
    /// interleaved between each device's --address and --device-id. Each
    /// device must keep its OWN port and id — nothing split, nothing stolen.
    @Test func twoDevicesNaturalOrdering() {
        let a = parseProbeArgs(["--name", "Kitchen", "--address", "10.0.0.1",
                                "--port", "7001", "--device-id", "AA:AA",
                                "--name", "Living Room", "--address", "10.0.0.2",
                                "--port", "7002", "--device-id", "BB:BB"])
        #expect(a.problems == [])
        #expect(a.devices.count == 2)
        #expect(a.devices[0].deviceName == "Kitchen")
        #expect(a.devices[0].port == 7001)
        #expect(a.devices[0].deviceID == "AA:AA")
        #expect(a.devices[1].deviceName == "Living Room")
        #expect(a.devices[1].port == 7002)
        #expect(a.devices[1].deviceID == "BB:BB")
    }

    /// Back-to-back complete devices with no options between them: the
    /// second --address starts device 2.
    @Test func bareSecondAddressStartsSecondDevice() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--address", "10.0.0.2", "--device-id", "BB:BB"])
        #expect(a.problems == [])
        #expect(a.devices.count == 2)
        #expect(a.devices[0].deviceID == "AA:AA")
        #expect(a.devices[1].deviceID == "BB:BB")
    }

    /// Id-first style for every device also groups correctly (the second
    /// --device-id starts device 2 because device 1 is complete).
    @Test func idFirstStyleMultiRoom() {
        let a = parseProbeArgs(["--device-id", "AA:AA", "--address", "10.0.0.1",
                                "--device-id", "BB:BB", "--address", "10.0.0.2"])
        #expect(a.problems == [])
        #expect(a.devices.count == 2)
        #expect(a.devices[0].deviceID == "AA:AA")
        #expect(a.devices[1].address == "10.0.0.2")
    }

    /// Options before the first --address are the defaults for EVERY device
    /// (what usage() promises; the old parser applied them to device 0 only),
    /// and a device can still override them.
    @Test func defaultsBeforeFirstAddressApplyToAllDevices() {
        let a = parseProbeArgs(["--port", "7100", "--model", "Sonos",
                                "--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--address", "10.0.0.2", "--port", "7200", "--device-id", "BB:BB"])
        #expect(a.problems == [])
        #expect(a.devices.count == 2)
        #expect(a.devices[0].port == 7100)
        #expect(a.devices[0].model == "Sonos")
        #expect(a.devices[1].port == 7200)   // per-device override
        #expect(a.devices[1].model == "Sonos") // inherited default
    }

    /// --device-id is identity, never a default: an id given before the
    /// first --address belongs to device 0 alone.
    @Test func deviceIDIsNeverADefault() {
        let a = parseProbeArgs(["--device-id", "AA:AA", "--address", "10.0.0.1",
                                "--name", "Two", "--address", "10.0.0.2", "--device-id", "BB:BB"])
        #expect(a.problems == [])
        #expect(a.devices.count == 2)
        #expect(a.devices[0].deviceID == "AA:AA")
        #expect(a.devices[1].deviceID == "BB:BB")
    }

    /// --ipv6 is per-device: only the slot it amends goes v6.
    @Test func ipv6IsPerDevice() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--ipv6", "--address", "fe80::1", "--device-id", "BB:BB"])
        #expect(a.problems == [])
        #expect(a.devices.count == 2)
        #expect(!a.devices[0].ipv6)
        #expect(a.devices[1].ipv6)
    }

    /// Global flags (--pcm, the gate) are orthogonal to slot grouping and
    /// must not split a device even when interleaved with its flags.
    @Test func globalFlagsDoNotSplitADevice() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--pcm", "/tmp/a.raw",
                                "--i-have-a-receiver-and-owntone-is-stopped",
                                "--device-id", "AA:AA"])
        #expect(a.problems == [])
        #expect(a.devices.count == 1)
        #expect(a.devices[0].deviceID == "AA:AA")
        #expect(a.pcmPath == "/tmp/a.raw")
        #expect(a.gated)
    }

    // MARK: - Ambiguity is LOUD (problems), never a silent misparse

    /// A second --address while the first device has no --device-id yet:
    /// the id-less commit must be reported at parse time, not discovered
    /// mid-gated-run.
    @Test func secondAddressWithoutIDIsAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1",
                                "--address", "10.0.0.2", "--device-id", "BB:BB"])
        #expect(a.devices.count == 2)  // still parsed, so the plan can show it
        #expect(a.devices[0].deviceID.isEmpty)
        #expect(a.problems.count == 1)
        #expect(a.problems[0].contains("--device-id"), "problem should name the missing flag: \(a.problems)")
        #expect(a.problems[0].contains("device[0]"), "problem should name the slot: \(a.problems)")
    }

    /// A device that never gets its id before the args run out is the same
    /// problem, at end-of-arguments.
    @Test func missingIDAtEndOfArgsIsAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--port", "7100"])
        #expect(a.devices.count == 1)
        #expect(a.devices[0].port == 7100)
        #expect(a.problems.count == 1)
        #expect(a.problems[0].contains("--device-id"))
    }

    /// Per-device flags after a COMPLETE device start a new slot; if no
    /// --address ever follows, that's a dangling fragment — loud, because
    /// the user probably meant to amend the previous device.
    @Test func trailingFlagsAfterCompleteDeviceAreAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--port", "7100"])
        #expect(a.devices.count == 1)
        #expect(a.devices[0].port == 7000)  // NOT amended — the device was complete
        #expect(a.problems.count == 1)
        #expect(a.problems[0].contains("trailing"), "unexpected problem text: \(a.problems)")
    }

    /// Two --device-id without an --address between them = a device with an
    /// id but no address. Committed for display, flagged as a problem.
    @Test func secondDeviceIDWithoutAddressIsAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--device-id", "BB:BB"])
        #expect(a.devices.count == 2)
        #expect(a.devices[1].deviceID == "BB:BB")
        #expect(a.devices[1].address.isEmpty)
        #expect(a.problems.count == 1)
        #expect(a.problems[0].contains("--address"))
    }

    @Test func perDeviceFlagsWithNoAddressAtAllAreAProblem() {
        let a = parseProbeArgs(["--name", "Kitchen", "--pcm", "/tmp/a.raw"])
        #expect(a.devices.count == 0)
        #expect(a.problems.count == 1)
        #expect(a.problems[0].contains("no --address"))
    }

    /// A typo'd flag must not be skipped quietly (--device_id burned wanting
    /// to be --device-id would otherwise misparse the whole plan).
    @Test func unknownArgumentIsAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device_id", "AA:AA"])
        #expect(a.problems.contains { $0.contains("unknown argument: --device_id") },
                      "unexpected problems: \(a.problems)")
    }

    @Test func nonNumericPortIsAProblem() {
        let a = parseProbeArgs(["--port", "banana", "--address", "10.0.0.1",
                                "--device-id", "AA:AA"])
        #expect(a.devices.count == 1)
        #expect(a.devices[0].port == 7000)  // untouched, not "?? default" silently
        #expect(a.problems.count == 1)
        #expect(a.problems[0].contains("--port banana"))
    }

    @Test func missingValueAtEndIsAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--pcm"])
        #expect(a.devices.count == 1)
        #expect(a.pcmPath == "")
        #expect(a.problems.count == 1)
        #expect(a.problems[0].contains("--pcm is missing its value"))
    }

    // MARK: - --raop (AirPlay 1 / RAOP target mode)

    /// --raop is per-device, exactly like --ipv6: only the slot it amends
    /// targets output_raop.
    @Test func raopIsPerDevice() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--raop", "--address", "10.0.0.2", "--device-id", "BB:BB"])
        #expect(a.problems == [])
        #expect(a.devices.count == 2)
        #expect(!a.devices[0].raop)
        #expect(a.devices[1].raop)
    }

    /// --raop before the first --address sets the default for every later
    /// device, same as any other per-device option (grammar note in
    /// ProbeArgParsing.swift).
    @Test func raopBeforeFirstAddressIsADefault() {
        let a = parseProbeArgs(["--raop", "--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--name", "Two", "--address", "10.0.0.2", "--device-id", "BB:BB"])
        #expect(a.problems == [])
        #expect(a.devices.count == 2)
        #expect(a.devices[0].raop)
        #expect(a.devices[1].raop)
    }

    // MARK: - Trivia

    @Test func emptyArgvIsCleanAndDeviceless() {
        let a = parseProbeArgs([])
        #expect(a.devices.count == 0)
        #expect(a.problems == [])
        #expect(!a.gated)
        #expect(!a.wantsHelp)
    }

    @Test func helpFlagIsRecordedNotFatal() {
        let a = parseProbeArgs(["--help"])
        #expect(a.wantsHelp)
        #expect(a.problems == [])
    }
}
