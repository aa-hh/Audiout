// SPDX-License-Identifier: GPL-2.0-or-later
//
// why this exists: settles exactly one question. Once an Audiout aggregate is
// the system default output and audio is flowing through it, does the Mac's
// own built-in speaker still respond to its hardware volume knob
// (kAudioDevicePropertyVolumeScalar on the built-in sub-device), or has the
// aggregate turned that knob into a dead letter? Read-only for every device
// on the system except the one write/read-back/restore cycle it runs on the
// resolved target. See PROTOCOL.md in this directory for how to run it.
//
// Usage:
//   volprobe [<target-UID>]        interactive test (defaults to the built-in
//                                  output device if no UID is given)
//   volprobe <target-UID> <scalar> restore mode: write <scalar> (0.0-1.0) to
//                                  <target-UID> and exit — no pause, no
//                                  auto-restore. This is the exact recovery
//                                  command an interrupted interactive run
//                                  prints for itself.

import Foundation
import CoreAudio

// MARK: - Core Audio helpers
// Every read is guarded with AudioObjectHasProperty, every write with
// AudioObjectIsPropertySettable; no force-unwrapped HAL results.

func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &addr) else { return nil }
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
    }
    return status == noErr ? value as String? : nil
}

func transportType(_ id: AudioObjectID) -> UInt32? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &addr) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func hasOutputChannels(_ id: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &addr) else { return false }
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return false }
    let list = buf.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
}

func allDevices() -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(system, &addr) else {
        print("The system audio object will not list its devices at all.")
        return []
    }
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func defaultOutputDeviceID() -> AudioObjectID? {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(system, &addr) else { return nil }
    var id = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    return AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr ? id : nil
}

func deviceID(forUID uid: String) -> AudioObjectID? {
    allDevices().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
}

/// The aggregate UID is not a constant — `AggregateOutputDevice.productUID(forBundleID:)`
/// derives it from whatever bundle id built the aggregate — so match by shape
/// instead: every Audiout aggregate's UID begins "com.audiout." and ends
/// ".aggregate" (shipping, side-build, and the old spike leftover alike).
func isAudioutAggregateShape(_ uid: String) -> Bool {
    uid.hasPrefix("com.audiout.") && uid.hasSuffix(".aggregate")
}

func volumeAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
}

func isVolumeSettable(_ id: AudioObjectID) -> Bool {
    var addr = volumeAddress()
    guard AudioObjectHasProperty(id, &addr) else {
        print("This device does not expose a volume-scalar property to the HAL at all.")
        return false
    }
    var settable: DarwinBoolean = false
    let status = AudioObjectIsPropertySettable(id, &addr, &settable)
    guard status == noErr else {
        print("Could not ask the HAL whether the volume knob is writable (OSStatus \(status)).")
        return false
    }
    return settable.boolValue
}

func readVolumeScalar(_ id: AudioObjectID) -> Float? {
    var addr = volumeAddress()
    guard AudioObjectHasProperty(id, &addr) else {
        print("This device has no readable volume level.")
        return nil
    }
    var value: Float = 0
    var size = UInt32(MemoryLayout<Float>.size)
    let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
    guard status == noErr else {
        print("Could not read the current volume level (OSStatus \(status)).")
        return nil
    }
    return value
}

func writeVolumeScalar(_ id: AudioObjectID, _ value: Float) -> Bool {
    var addr = volumeAddress()
    var settable: DarwinBoolean = false
    let settableStatus = AudioObjectIsPropertySettable(id, &addr, &settable)
    guard settableStatus == noErr, settable.boolValue else {
        print("The HAL will not let this process write the volume knob — refusing to write.")
        return false
    }
    var newValue = value
    let size = UInt32(MemoryLayout<Float>.size)
    let status = AudioObjectSetPropertyData(id, &addr, 0, nil, size, &newValue)
    guard status == noErr else {
        print("Writing the new volume level failed (OSStatus \(status)).")
        return false
    }
    return true
}

func percent(_ scalar: Float) -> Int { Int((scalar * 100).rounded()) }

// MARK: - Restore mode: `volprobe <target-UID> <scalar>`

func runRestoreMode(uid: String, scalarText: String) {
    guard let scalar = Float(scalarText), (0...1).contains(scalar) else {
        print("The scalar to write must be a number between 0.0 and 1.0 — got \"\(scalarText)\".")
        exit(1)
    }
    guard let id = deviceID(forUID: uid) else {
        print("No currently enumerated device has UID \"\(uid)\" — nothing to restore.")
        exit(1)
    }
    let name = stringProperty(id, kAudioObjectPropertyName) ?? "<unnamed device>"
    print("Restore mode: writing \(percent(scalar))% to \"\(name)\" (\(uid))...")
    if writeVolumeScalar(id, scalar) {
        print("Done — wrote \(percent(scalar))% to \"\(name)\" (\(uid)).")
        exit(0)
    } else {
        print("Restore FAILED — the volume was not written. See the reason above.")
        exit(1)
    }
}

// MARK: - Interactive test: `volprobe [<target-UID>]`

func runInteractiveTest(explicitTargetUID: String?, invocation: String) {
    print("=== aggregate sub-device volume probe ===\n")

    guard let defaultID = defaultOutputDeviceID() else {
        print("Could not read the current default output device at all — stopping.")
        exit(1)
    }
    guard let defaultUID = stringProperty(defaultID, kAudioDevicePropertyDeviceUID) else {
        print("The current default output device has no readable UID — stopping.")
        exit(1)
    }
    let defaultName = stringProperty(defaultID, kAudioObjectPropertyName) ?? "<unnamed>"
    print("Current default output:")
    print("  name: \(defaultName)")
    print("  UID:  \(defaultUID)")
    print("  is an Audiout aggregate: \(isAudioutAggregateShape(defaultUID) ? "yes" : "no")")

    let devices = allDevices()
    let shapedMatches: [(uid: String, name: String)] = devices.compactMap { id in
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), isAudioutAggregateShape(uid) else { return nil }
        return (uid, stringProperty(id, kAudioObjectPropertyName) ?? "<unnamed>")
    }
    print("")
    if shapedMatches.isEmpty {
        print("No Audiout-shaped aggregate (\"com.audiout.*.aggregate\") is currently enumerated.")
    } else {
        print("Audiout-shaped aggregate(s) currently enumerated (\(shapedMatches.count)):")
        for m in shapedMatches {
            var notes: [String] = []
            if m.uid == defaultUID { notes.append("current default") }
            if m.uid == "com.audiout.spike.aggregate" { notes.append("known leftover from an earlier spike, not this run's build") }
            let suffix = notes.isEmpty ? "" : "  — \(notes.joined(separator: "; "))"
            print("  \"\(m.name)\"  uid=\(m.uid)\(suffix)")
        }
    }

    let targetID: AudioObjectID
    let targetUID: String
    if let explicit = explicitTargetUID {
        guard let id = deviceID(forUID: explicit) else {
            print("\nNo currently enumerated device has UID \"\(explicit)\" — stopping.")
            exit(1)
        }
        targetID = id
        targetUID = explicit
    } else {
        guard let found = devices.first(where: { hasOutputChannels($0) && transportType($0) == kAudioDeviceTransportTypeBuiltIn }) else {
            print("\nNo built-in output device is enumerated on this Mac — stopping.")
            exit(1)
        }
        guard let uid = stringProperty(found, kAudioDevicePropertyDeviceUID) else {
            print("\nThe built-in output device has no readable UID — stopping.")
            exit(1)
        }
        targetID = found
        targetUID = uid
    }
    let targetName = stringProperty(targetID, kAudioObjectPropertyName) ?? "<unnamed>"
    print("\nTarget device:")
    print("  name: \(targetName)")
    print("  UID:  \(targetUID)")

    if targetUID == defaultUID {
        print("\n*** THIS RUN DOES NOT TEST THE QUESTION: the target is already the current default output. ***")
        print("Select an AirPlay speaker (or any other output) as the default so the built-in speakers are a silent bystander, then re-run.")
        exit(1)
    }

    print("")
    let settable = isVolumeSettable(targetID)
    print(settable ? "The HAL says this knob CAN be written." : "The HAL says this knob CANNOT be written.")

    guard let original = readVolumeScalar(targetID) else { exit(1) }
    print("Current volume: \(percent(original))%")

    let newScalar: Float = original < 0.50 ? 0.90 : 0.15
    let direction = newScalar > original ? "up" : "down"
    // Printed BEFORE the write, not after: a kill in between would otherwise
    // leave the speakers at the probe's value with no recovery line on screen.
    let restoreLine = "\(invocation) \(targetUID) \(original)"
    print("\nIf this run is interrupted before it restores the original value, put it back by hand with:")
    print("  \(restoreLine)")
    print("\nWriting the volume \(direction), from \(percent(original))% to \(percent(newScalar))%...")
    guard writeVolumeScalar(targetID, newScalar) else {
        print("Nothing on the Mac's speakers should have changed.")
        exit(1)
    }

    if let readBack = readVolumeScalar(targetID) {
        let matches = percent(readBack) == percent(newScalar)
        print("Read back: \(percent(readBack))% — \(matches ? "matches what was written." : "does NOT match what was written.")")
    } else {
        print("Wrote successfully but could not read the value back to confirm.")
    }

    print("""

    Listen to the Mac's own built-in speakers now — not the AirPlay speaker. \
    One of these two sentences will be true once you have also heard the restore below:

    Knob still applies:
    "The music coming out of the Mac's own speakers got clearly louder or quieter the moment the probe changed the number, and went back when it restored it."

    Knob does not apply:
    "The music coming out of the Mac's own speakers stayed at exactly the same loudness the whole time, even though the probe reported that it wrote the new number and read it back."

    Press Return to restore the original volume.
    """)
    _ = readLine()

    print("\nRestoring original volume (\(percent(original))%)...")
    if writeVolumeScalar(targetID, original) {
        print("Restored to \(percent(original))%.")
        exit(0)
    } else {
        print("RESTORE FAILED. Run this by hand: \(restoreLine)")
        exit(1)
    }
}

// MARK: - main

let args = CommandLine.arguments
// Absolutised against the working directory, so the recovery command it prints
// still runs after the operator has moved elsewhere in the shell.
let invocation = URL(fileURLWithPath: args[0],
                     relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    .standardizedFileURL.path

switch args.count {
case 3:
    runRestoreMode(uid: args[1], scalarText: args[2])
case 1, 2:
    runInteractiveTest(explicitTargetUID: args.count == 2 ? args[1] : nil, invocation: invocation)
default:
    print("Usage:")
    print("  \(invocation) [<target-UID>]")
    print("  \(invocation) <target-UID> <scalar>   (restore mode)")
    exit(1)
}
