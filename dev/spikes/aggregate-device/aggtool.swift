// aggtool — G2b spike CLI: can a programmatically-created PUBLIC aggregate
// device stand in for the G2 HAL-driver virtual device?
//
// Creates/inspects/destroys a non-private aggregate named "Audiouter"
// (UID com.audiouter.spike.aggregate) wrapping the built-in speakers.
//
// SAFE subcommands (no machine-state change beyond the spike aggregate itself):
//   create     create the public aggregate (persists across process exit)
//   status     enumerate devices; dump the aggregate's + built-in's properties
//   destroy    destroy the aggregate by UID
//   nest-test  try to build a NativeCaptureCoordinator-shaped PRIVATE aggregate
//              whose sub-device is the PUBLIC aggregate (what the tap path would
//              do if the aggregate were the default output). Cleans up after.
//   watch      print default-output-device changes for 60s (listener proof)
//
// HUMAN-ONLY subcommands (change the machine's default output — never run
// these from an agent; see SPIKE-REPORT.md checklist):
//   set-default   save current default UID to build/.previous-default-uid,
//                 then make the aggregate the default output
//   restore       restore the saved default
//
// Deliberately zero TCC surface: no process tap is ever created (that would
// prompt for the audio-capture grant). The nest-test therefore proves the
// aggregate-in-aggregate question only; the tap half rides on it.

import AudioToolbox  // kAudioHardwareServiceDeviceProperty_VirtualMainVolume
import CoreAudio
import Foundation

let kSpikeName = "Audiouter"
let kSpikeUID = "com.audiouter.spike.aggregate"
let kSavedDefaultPath = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().appendingPathComponent(".previous-default-uid")

// MARK: - Property helpers

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func getUInt32(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
    var a = addr
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func getDouble(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Double? {
    var a = addr
    var v: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func getString(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
    var a = addr
    var cf: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let err = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, ptr)
    }
    guard err == noErr, let cf else { return nil }
    return cf as String
}

func hasProperty(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
    var a = addr
    return AudioObjectHasProperty(id, &a)
}

func fourCC(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                 UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(v)
}

func allDevices() -> [AudioObjectID] {
    var a = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceUID(_ id: AudioObjectID) -> String? {
    getString(id, address(kAudioDevicePropertyDeviceUID))
}

func deviceName(_ id: AudioObjectID) -> String? {
    getString(id, address(kAudioObjectPropertyName))
}

func outputChannelCount(_ id: AudioObjectID) -> Int {
    var a = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func deviceByUID(_ uid: String) -> AudioObjectID? {
    var a = address(kAudioHardwarePropertyTranslateUIDToDevice)
    var cfUID: CFString? = uid as CFString
    var id: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = withUnsafePointer(to: &cfUID) { qual -> OSStatus in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
                                   UInt32(MemoryLayout<CFString?>.size), qual, &size, &id)
    }
    guard err == noErr, id != kAudioObjectUnknown else { return nil }
    return id
}

func defaultOutputID() -> AudioObjectID? {
    var a = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &a, 0, nil, &size, &id) == noErr,
          id != kAudioObjectUnknown else { return nil }
    return id
}

func builtInSpeakers() -> AudioObjectID? {
    allDevices().first { id in
        getUInt32(id, address(kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeBuiltIn
            && outputChannelCount(id) > 0
    }
}

// MARK: - Inspection

func dump(_ id: AudioObjectID, label: String) {
    print("--- \(label) (AudioObjectID \(id)) ---")
    print("  name:                 \(deviceName(id) ?? "?")")
    print("  uid:                  \(deviceUID(id) ?? "?")")
    if let t = getUInt32(id, address(kAudioDevicePropertyTransportType)) {
        print("  transport:            '\(fourCC(t))'")
    }
    print("  outputChannels:       \(outputChannelCount(id))")
    if let r = getDouble(id, address(kAudioDevicePropertyNominalSampleRate)) {
        print("  nominalSampleRate:    \(r)")
    }
    if let v = getUInt32(id, address(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioDevicePropertyScopeOutput)) {
        print("  canBeDefaultDevice:   \(v)")
    }
    if let v = getUInt32(id, address(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioDevicePropertyScopeOutput)) {
        print("  canBeDefaultSystem:   \(v)")
    }
    if let v = getUInt32(id, address(kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput)) {
        print("  latency(out frames):  \(v)")
    }
    if let v = getUInt32(id, address(kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput)) {
        print("  safetyOffset(out):    \(v)")
    }
    if let v = getUInt32(id, address(kAudioDevicePropertyIsHidden)) {
        print("  isHidden:             \(v)")
    }
    // Volume / mute surface — what Sound settings' slider and the volume keys need.
    let vmvc = hasProperty(id, address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput))
    let volMain = hasProperty(id, address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput))
    let volCh1 = hasProperty(id, address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 1))
    let muteMain = hasProperty(id, address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput))
    print("  volume: vmvc=\(vmvc) scalarMain=\(volMain) scalarCh1=\(volCh1) muteMain=\(muteMain)")
    if vmvc, let v = getDouble(id, address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)) {
        print("  virtualMainVolume:    \(v)")
    }
    // Cosmetics: does the device publish an icon, and are icon/name settable?
    var iconAddr = address(kAudioDevicePropertyIcon)
    var nameAddr = address(kAudioObjectPropertyName)
    var iconSettable = DarwinBoolean(false)
    var nameSettable = DarwinBoolean(false)
    AudioObjectIsPropertySettable(id, &iconAddr, &iconSettable)
    AudioObjectIsPropertySettable(id, &nameAddr, &nameSettable)
    print("  icon: present=\(hasProperty(id, address(kAudioDevicePropertyIcon))) settable=\(iconSettable.boolValue)  nameSettable=\(nameSettable.boolValue)")
}

// MARK: - Aggregate lifecycle

func spikeAggregateID() -> AudioObjectID? { deviceByUID(kSpikeUID) }

@discardableResult
func createSpikeAggregate() -> AudioObjectID? {
    if let existing = spikeAggregateID() {
        print("aggregate already exists (adopted), id \(existing)")
        return existing
    }
    guard let speakers = builtInSpeakers(), let speakersUID = deviceUID(speakers) else {
        print("FAIL: built-in speakers not found")
        return nil
    }
    print("wrapping sub-device: \(deviceName(speakers) ?? "?") (\(speakersUID))")
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey as String:          kSpikeName,
        kAudioAggregateDeviceUIDKey as String:           kSpikeUID,
        kAudioAggregateDeviceMainSubDeviceKey as String: speakersUID,
        kAudioAggregateDeviceIsPrivateKey as String:     false,   // PUBLIC — the product question
        kAudioAggregateDeviceIsStackedKey as String:     false,
        kAudioAggregateDeviceSubDeviceListKey as String: [
            [kAudioSubDeviceUIDKey as String: speakersUID]
        ],
    ]
    var newID: AudioObjectID = kAudioObjectUnknown
    let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
    guard err == noErr else {
        print("FAIL: AudioHardwareCreateAggregateDevice -> \(err) ('\(fourCC(UInt32(bitPattern: err)))')")
        return nil
    }
    print("created aggregate, id \(newID)")
    return newID
}

func destroySpikeAggregate() {
    guard let id = spikeAggregateID() else {
        print("no spike aggregate present (uid \(kSpikeUID))")
        return
    }
    let err = AudioHardwareDestroyAggregateDevice(id)
    print(err == noErr ? "destroyed aggregate id \(id)"
                       : "FAIL: AudioHardwareDestroyAggregateDevice -> \(err)")
}

// MARK: - Subcommands

func cmdStatus() {
    print("== device enumeration (kAudioHardwarePropertyDevices) ==")
    for id in allDevices() {
        let t = getUInt32(id, address(kAudioDevicePropertyTransportType)).map(fourCC) ?? "????"
        print(String(format: "  %4d  '%@'  out:%d  %@", id, t, outputChannelCount(id), deviceName(id) ?? "?"))
    }
    if let def = defaultOutputID() {
        print("\ndefault output: \(deviceName(def) ?? "?") (\(deviceUID(def) ?? "?"))")
    }
    print("")
    if let id = spikeAggregateID() {
        dump(id, label: "spike aggregate PRESENT")
    } else {
        print("spike aggregate NOT present (uid \(kSpikeUID))")
    }
    if let speakers = builtInSpeakers() {
        print("")
        dump(speakers, label: "built-in speakers (for comparison)")
    }
}

func cmdNestTest() {
    guard let outer = spikeAggregateID(), let outerUID = deviceUID(outer) else {
        print("run 'create' first — nest-test needs the public aggregate present")
        exit(1)
    }
    print("attempting a NativeCaptureCoordinator-shaped PRIVATE aggregate whose")
    print("main/sub-device is the PUBLIC aggregate (\(outerUID))...")
    // Mirrors NativeCaptureCoordinator.createAggregate() minus the tap list
    // (a real CATap would trigger the TCC audio-capture prompt; see header).
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey as String:          "Tap-NestTest",
        kAudioAggregateDeviceUIDKey as String:           UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey as String: outerUID,
        kAudioAggregateDeviceIsPrivateKey as String:     true,
        kAudioAggregateDeviceIsStackedKey as String:     false,
        kAudioAggregateDeviceSubDeviceListKey as String: [
            [kAudioSubDeviceUIDKey as String: outerUID]
        ],
    ]
    var nested: AudioObjectID = kAudioObjectUnknown
    let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &nested)
    guard err == noErr else {
        print("RESULT: creation FAILED -> \(err) ('\(fourCC(UInt32(bitPattern: err)))')")
        print("aggregate-in-aggregate is refused; the tap path would need to resolve")
        print("through to the aggregate's sub-device before pinning.")
        return
    }
    print("RESULT: creation SUCCEEDED, id \(nested)")
    dump(nested, label: "nested private aggregate")
    // The composite is only useful if it actually publishes output streams + a rate.
    let ch = outputChannelCount(nested)
    let rate = getDouble(nested, address(kAudioDevicePropertyNominalSampleRate)) ?? 0
    print("USABLE: outputChannels=\(ch) nominalRate=\(rate) -> \(ch > 0 && rate > 0 ? "yes" : "NO")")
    let derr = AudioHardwareDestroyAggregateDevice(nested)
    print(derr == noErr ? "nested aggregate destroyed" : "cleanup FAILED -> \(derr)")
}

func cmdWatch() {
    print("watching kAudioHardwarePropertyDefaultOutputDevice for 60s —")
    print("flip the output device in System Settings > Sound and watch here...")
    var a = address(kAudioHardwarePropertyDefaultOutputDevice)
    let queue = DispatchQueue(label: "com.audiouter.spike.aggregate.watch")
    let block: AudioObjectPropertyListenerBlock = { _, _ in
        if let def = defaultOutputID() {
            print("  -> default output changed: \(deviceName(def) ?? "?") (\(deviceUID(def) ?? "?"))")
        } else {
            print("  -> default output changed: <unresolvable>")
        }
    }
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
    Thread.sleep(forTimeInterval: 60)
    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
    print("done.")
}

func setDefaultOutput(_ id: AudioObjectID) -> OSStatus {
    var a = address(kAudioHardwarePropertyDefaultOutputDevice)
    var v = id
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
                                      UInt32(MemoryLayout<AudioObjectID>.size), &v)
}

func cmdSetDefault() {
    print("*** HUMAN-ONLY: this changes the Mac's default output device. ***")
    guard let current = defaultOutputID(), let currentUID = deviceUID(current) else {
        print("FAIL: cannot read current default output"); exit(1)
    }
    guard let agg = createSpikeAggregate() else { exit(1) }
    try? currentUID.write(to: kSavedDefaultPath, atomically: true, encoding: .utf8)
    print("saved previous default (\(currentUID)) -> \(kSavedDefaultPath.path)")
    let err = setDefaultOutput(agg)
    guard err == noErr else { print("FAIL: set default -> \(err)"); exit(1) }
    print("default output is now '\(kSpikeName)'. Check System Settings > Sound,")
    print("try the volume keys, then run: aggtool restore")
}

func cmdRestore() {
    guard let uid = try? String(contentsOf: kSavedDefaultPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !uid.isEmpty else {
        print("no saved default at \(kSavedDefaultPath.path) — set one in Sound settings by hand")
        exit(1)
    }
    guard let id = deviceByUID(uid) else {
        print("saved device (\(uid)) not found — pick one in Sound settings by hand")
        exit(1)
    }
    let err = setDefaultOutput(id)
    guard err == noErr else { print("FAIL: restore default -> \(err)"); exit(1) }
    print("default output restored to \(deviceName(id) ?? uid)")
    try? FileManager.default.removeItem(at: kSavedDefaultPath)
    destroySpikeAggregate()
}

// MARK: - Entry

switch CommandLine.arguments.dropFirst().first {
case "create":      _ = createSpikeAggregate()
case "status":      cmdStatus()
case "destroy":     destroySpikeAggregate()
case "nest-test":   cmdNestTest()
case "watch":       cmdWatch()
case "set-default": cmdSetDefault()
case "restore":     cmdRestore()
default:
    print("usage: aggtool create|status|destroy|nest-test|watch|set-default|restore")
    print("       (set-default/restore are HUMAN-ONLY — they change the default output)")
    exit(64)
}
