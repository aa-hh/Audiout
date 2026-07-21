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

import XCTest
import EngineProbeParsing

final class EngineProbeParsingTests: XCTestCase {

    // MARK: - Single device: the identifying flags in every ordering

    /// THE footgun that burned the gated run: address, then port, then id
    /// must stay ONE device — --port amends the slot, it does not commit it.
    func testAddressThenPortThenID() {
        let a = parseProbeArgs(["--address", "192.168.1.50", "--port", "7100",
                                "--device-id", "AA:BB:CC:DD:EE:FF"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 1)
        XCTAssertEqual(a.devices[0].address, "192.168.1.50")
        XCTAssertEqual(a.devices[0].port, 7100)
        XCTAssertEqual(a.devices[0].deviceID, "AA:BB:CC:DD:EE:FF")
    }

    func testPortThenAddressThenID() {
        let a = parseProbeArgs(["--port", "7100", "--address", "192.168.1.50",
                                "--device-id", "AA:BB:CC:DD:EE:FF"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 1)
        XCTAssertEqual(a.devices[0].port, 7100)
        XCTAssertEqual(a.devices[0].deviceID, "AA:BB:CC:DD:EE:FF")
    }

    /// Prefix style: all options first, then --address, then --device-id
    /// immediately after it (the usage() multi-room shape, single device).
    func testIDImmediatelyAfterAddress() {
        let a = parseProbeArgs(["--name", "Kitchen", "--port", "7100",
                                "--address", "192.168.1.50",
                                "--device-id", "AA:BB:CC:DD:EE:FF"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 1)
        XCTAssertEqual(a.devices[0].deviceName, "Kitchen")
        XCTAssertEqual(a.devices[0].port, 7100)
        XCTAssertEqual(a.devices[0].deviceID, "AA:BB:CC:DD:EE:FF")
    }

    /// Id dead last, after every other per-device flag has amended the slot.
    func testIDLast() {
        let a = parseProbeArgs(["--address", "192.168.1.50", "--name", "Kitchen",
                                "--port", "7100", "--features", "0x1", "--model", "Sonos",
                                "--password", "hunter2",
                                "--device-id", "AA:BB:CC:DD:EE:FF"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 1)
        let d = a.devices[0]
        XCTAssertEqual(d.deviceName, "Kitchen")
        XCTAssertEqual(d.port, 7100)
        XCTAssertEqual(d.features, "0x1")
        XCTAssertEqual(d.model, "Sonos")
        XCTAssertEqual(d.password, "hunter2")
        XCTAssertEqual(d.deviceID, "AA:BB:CC:DD:EE:FF")
    }

    /// Id BEFORE the address is also unambiguous — the slot completes at
    /// --address instead of at --device-id.
    func testIDBeforeAddress() {
        let a = parseProbeArgs(["--device-id", "AA:BB:CC:DD:EE:FF",
                                "--address", "192.168.1.50"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 1)
        XCTAssertEqual(a.devices[0].address, "192.168.1.50")
        XCTAssertEqual(a.devices[0].deviceID, "AA:BB:CC:DD:EE:FF")
    }

    /// README.md's documented invocation (whose address→port→…→id ordering
    /// the old parser misparsed into two devices) must parse as one gated
    /// single-device plan.
    func testREADMEExampleOrdering() {
        let a = parseProbeArgs(["--address", "192.168.1.50", "--port", "7000",
                                "--features", "0x445F8A00,0x1C340",
                                "--model", "AudioAccessory5,1",
                                "--device-id", "AA:BB:CC:DD:EE:FF",
                                "--pcm", "/tmp/audio.raw",
                                "--i-have-a-receiver-and-owntone-is-stopped"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 1)
        XCTAssertEqual(a.devices[0].deviceID, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(a.devices[0].features, "0x445F8A00,0x1C340")
        XCTAssertEqual(a.devices[0].model, "AudioAccessory5,1")
        XCTAssertEqual(a.pcmPath, "/tmp/audio.raw")
        XCTAssertTrue(a.gated)
    }

    // MARK: - Multi-room

    /// The usage() multi-room example (prefix style).
    func testTwoDevicesPrefixStyle() {
        let a = parseProbeArgs(["--pcm", "/tmp/audio.raw",
                                "--name", "Kitchen", "--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--name", "Living Room", "--address", "10.0.0.2", "--device-id", "BB:BB"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 2)
        XCTAssertEqual(a.devices[0].deviceName, "Kitchen")
        XCTAssertEqual(a.devices[0].address, "10.0.0.1")
        XCTAssertEqual(a.devices[0].deviceID, "AA:AA")
        XCTAssertEqual(a.devices[1].deviceName, "Living Room")
        XCTAssertEqual(a.devices[1].address, "10.0.0.2")
        XCTAssertEqual(a.devices[1].deviceID, "BB:BB")
    }

    /// The exact shape that burned the 2026-07-17 run: per-device options
    /// interleaved between each device's --address and --device-id. Each
    /// device must keep its OWN port and id — nothing split, nothing stolen.
    func testTwoDevicesNaturalOrdering() {
        let a = parseProbeArgs(["--name", "Kitchen", "--address", "10.0.0.1",
                                "--port", "7001", "--device-id", "AA:AA",
                                "--name", "Living Room", "--address", "10.0.0.2",
                                "--port", "7002", "--device-id", "BB:BB"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 2)
        XCTAssertEqual(a.devices[0].deviceName, "Kitchen")
        XCTAssertEqual(a.devices[0].port, 7001)
        XCTAssertEqual(a.devices[0].deviceID, "AA:AA")
        XCTAssertEqual(a.devices[1].deviceName, "Living Room")
        XCTAssertEqual(a.devices[1].port, 7002)
        XCTAssertEqual(a.devices[1].deviceID, "BB:BB")
    }

    /// Back-to-back complete devices with no options between them: the
    /// second --address starts device 2.
    func testBareSecondAddressStartsSecondDevice() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--address", "10.0.0.2", "--device-id", "BB:BB"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 2)
        XCTAssertEqual(a.devices[0].deviceID, "AA:AA")
        XCTAssertEqual(a.devices[1].deviceID, "BB:BB")
    }

    /// Id-first style for every device also groups correctly (the second
    /// --device-id starts device 2 because device 1 is complete).
    func testIDFirstStyleMultiRoom() {
        let a = parseProbeArgs(["--device-id", "AA:AA", "--address", "10.0.0.1",
                                "--device-id", "BB:BB", "--address", "10.0.0.2"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 2)
        XCTAssertEqual(a.devices[0].deviceID, "AA:AA")
        XCTAssertEqual(a.devices[1].address, "10.0.0.2")
    }

    /// Options before the first --address are the defaults for EVERY device
    /// (what usage() promises; the old parser applied them to device 0 only),
    /// and a device can still override them.
    func testDefaultsBeforeFirstAddressApplyToAllDevices() {
        let a = parseProbeArgs(["--port", "7100", "--model", "Sonos",
                                "--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--address", "10.0.0.2", "--port", "7200", "--device-id", "BB:BB"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 2)
        XCTAssertEqual(a.devices[0].port, 7100)
        XCTAssertEqual(a.devices[0].model, "Sonos")
        XCTAssertEqual(a.devices[1].port, 7200)   // per-device override
        XCTAssertEqual(a.devices[1].model, "Sonos") // inherited default
    }

    /// --device-id is identity, never a default: an id given before the
    /// first --address belongs to device 0 alone.
    func testDeviceIDIsNeverADefault() {
        let a = parseProbeArgs(["--device-id", "AA:AA", "--address", "10.0.0.1",
                                "--name", "Two", "--address", "10.0.0.2", "--device-id", "BB:BB"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 2)
        XCTAssertEqual(a.devices[0].deviceID, "AA:AA")
        XCTAssertEqual(a.devices[1].deviceID, "BB:BB")
    }

    /// --ipv6 is per-device: only the slot it amends goes v6.
    func testIPv6IsPerDevice() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--ipv6", "--address", "fe80::1", "--device-id", "BB:BB"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 2)
        XCTAssertFalse(a.devices[0].ipv6)
        XCTAssertTrue(a.devices[1].ipv6)
    }

    /// Global flags (--pcm, the gate) are orthogonal to slot grouping and
    /// must not split a device even when interleaved with its flags.
    func testGlobalFlagsDoNotSplitADevice() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--pcm", "/tmp/a.raw",
                                "--i-have-a-receiver-and-owntone-is-stopped",
                                "--device-id", "AA:AA"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 1)
        XCTAssertEqual(a.devices[0].deviceID, "AA:AA")
        XCTAssertEqual(a.pcmPath, "/tmp/a.raw")
        XCTAssertTrue(a.gated)
    }

    // MARK: - Ambiguity is LOUD (problems), never a silent misparse

    /// A second --address while the first device has no --device-id yet:
    /// the id-less commit must be reported at parse time, not discovered
    /// mid-gated-run.
    func testSecondAddressWithoutIDIsAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1",
                                "--address", "10.0.0.2", "--device-id", "BB:BB"])
        XCTAssertEqual(a.devices.count, 2)  // still parsed, so the plan can show it
        XCTAssertTrue(a.devices[0].deviceID.isEmpty)
        XCTAssertEqual(a.problems.count, 1)
        XCTAssertTrue(a.problems[0].contains("--device-id"), "problem should name the missing flag: \(a.problems)")
        XCTAssertTrue(a.problems[0].contains("device[0]"), "problem should name the slot: \(a.problems)")
    }

    /// A device that never gets its id before the args run out is the same
    /// problem, at end-of-arguments.
    func testMissingIDAtEndOfArgsIsAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--port", "7100"])
        XCTAssertEqual(a.devices.count, 1)
        XCTAssertEqual(a.devices[0].port, 7100)
        XCTAssertEqual(a.problems.count, 1)
        XCTAssertTrue(a.problems[0].contains("--device-id"))
    }

    /// Per-device flags after a COMPLETE device start a new slot; if no
    /// --address ever follows, that's a dangling fragment — loud, because
    /// the user probably meant to amend the previous device.
    func testTrailingFlagsAfterCompleteDeviceAreAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--port", "7100"])
        XCTAssertEqual(a.devices.count, 1)
        XCTAssertEqual(a.devices[0].port, 7000)  // NOT amended — the device was complete
        XCTAssertEqual(a.problems.count, 1)
        XCTAssertTrue(a.problems[0].contains("trailing"), "unexpected problem text: \(a.problems)")
    }

    /// Two --device-id without an --address between them = a device with an
    /// id but no address. Committed for display, flagged as a problem.
    func testSecondDeviceIDWithoutAddressIsAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--device-id", "BB:BB"])
        XCTAssertEqual(a.devices.count, 2)
        XCTAssertEqual(a.devices[1].deviceID, "BB:BB")
        XCTAssertTrue(a.devices[1].address.isEmpty)
        XCTAssertEqual(a.problems.count, 1)
        XCTAssertTrue(a.problems[0].contains("--address"))
    }

    func testPerDeviceFlagsWithNoAddressAtAllAreAProblem() {
        let a = parseProbeArgs(["--name", "Kitchen", "--pcm", "/tmp/a.raw"])
        XCTAssertEqual(a.devices.count, 0)
        XCTAssertEqual(a.problems.count, 1)
        XCTAssertTrue(a.problems[0].contains("no --address"))
    }

    /// A typo'd flag must not be skipped quietly (--device_id burned wanting
    /// to be --device-id would otherwise misparse the whole plan).
    func testUnknownArgumentIsAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device_id", "AA:AA"])
        XCTAssertTrue(a.problems.contains { $0.contains("unknown argument: --device_id") },
                      "unexpected problems: \(a.problems)")
    }

    func testNonNumericPortIsAProblem() {
        let a = parseProbeArgs(["--port", "banana", "--address", "10.0.0.1",
                                "--device-id", "AA:AA"])
        XCTAssertEqual(a.devices.count, 1)
        XCTAssertEqual(a.devices[0].port, 7000)  // untouched, not "?? default" silently
        XCTAssertEqual(a.problems.count, 1)
        XCTAssertTrue(a.problems[0].contains("--port banana"))
    }

    func testMissingValueAtEndIsAProblem() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--pcm"])
        XCTAssertEqual(a.devices.count, 1)
        XCTAssertEqual(a.pcmPath, "")
        XCTAssertEqual(a.problems.count, 1)
        XCTAssertTrue(a.problems[0].contains("--pcm is missing its value"))
    }

    // MARK: - --raop (AirPlay 1 / RAOP target mode)

    /// --raop is per-device, exactly like --ipv6: only the slot it amends
    /// targets output_raop.
    func testRaopIsPerDevice() {
        let a = parseProbeArgs(["--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--raop", "--address", "10.0.0.2", "--device-id", "BB:BB"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 2)
        XCTAssertFalse(a.devices[0].raop)
        XCTAssertTrue(a.devices[1].raop)
    }

    /// --raop before the first --address sets the default for every later
    /// device, same as any other per-device option (grammar note in
    /// ProbeArgParsing.swift).
    func testRaopBeforeFirstAddressIsADefault() {
        let a = parseProbeArgs(["--raop", "--address", "10.0.0.1", "--device-id", "AA:AA",
                                "--name", "Two", "--address", "10.0.0.2", "--device-id", "BB:BB"])
        XCTAssertEqual(a.problems, [])
        XCTAssertEqual(a.devices.count, 2)
        XCTAssertTrue(a.devices[0].raop)
        XCTAssertTrue(a.devices[1].raop)
    }

    // MARK: - Trivia

    func testEmptyArgvIsCleanAndDeviceless() {
        let a = parseProbeArgs([])
        XCTAssertEqual(a.devices.count, 0)
        XCTAssertEqual(a.problems, [])
        XCTAssertFalse(a.gated)
        XCTAssertFalse(a.wantsHelp)
    }

    func testHelpFlagIsRecordedNotFatal() {
        let a = parseProbeArgs(["--help"])
        XCTAssertTrue(a.wantsHelp)
        XCTAssertEqual(a.problems, [])
    }
}
