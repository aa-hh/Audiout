// SPDX-License-Identifier: GPL-2.0-or-later
//
// Why does the public "Audiout" aggregate not appear at launch? Walks the same
// steps `AggregateOutputDevice.adoptOrCreate()` takes and prints where the chain
// breaks: resolve-existing, find the built-in output, read its UID, create.
// Read-only up to the create, and the create is undone immediately.

import Foundation
import CoreAudio

let productUID = "com.audiout.Audiout.aggregate"

func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let err = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
    }
    return err == noErr ? value as String? : nil
}

func allDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func transportType(_ id: AudioObjectID) -> UInt32? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func hasOutput(_ id: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return false }
    let list = buf.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
}

func fourCC(_ v: UInt32) -> String {
    String(bytes: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                   UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)], encoding: .ascii) ?? "?"
}

print("=== aggregate creation probe ===\n")

print("STEP 1 — does our aggregate already exist?")
var existing: AudioObjectID?
for id in allDevices() where stringProperty(id, kAudioDevicePropertyDeviceUID) == productUID {
    existing = id
}
print(existing.map { "  YES (id \($0)) — nothing to create" } ?? "  no — must create it")

print("\nSTEP 2 — output devices and their transport types")
var builtIn: AudioObjectID?
for id in allDevices() where hasOutput(id) {
    let name = stringProperty(id, kAudioObjectPropertyName) ?? "?"
    let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "?"
    let tt = transportType(id)
    let isBuiltIn = tt == kAudioDeviceTransportTypeBuiltIn
    if isBuiltIn, builtIn == nil { builtIn = id }
    print("  \(isBuiltIn ? "→" : " ") \(name)  [\(tt.map(fourCC) ?? "?")]  uid=\(uid)")
}

guard let builtIn else {
    print("\n  FAIL: no built-in output device found — adoptOrCreate() returns nil here.")
    exit(1)
}
guard let subUID = stringProperty(builtIn, kAudioDevicePropertyDeviceUID) else {
    print("\n  FAIL: built-in output has no readable UID — adoptOrCreate() returns nil here.")
    exit(1)
}
print("\nSTEP 3 — sub-device UID: \(subUID)")

if existing != nil { print("\nAlready exists; not creating."); exit(0) }

print("\nSTEP 4 — creating the aggregate the same way the app does")
let desc: [String: Any] = [
    kAudioAggregateDeviceUIDKey as String: productUID,
    kAudioAggregateDeviceNameKey as String: "Audiout",
    kAudioAggregateDeviceIsPrivateKey as String: false,
    kAudioAggregateDeviceSubDeviceListKey as String: [
        [kAudioSubDeviceUIDKey as String: subUID]
    ],
]
var created = AudioObjectID(0)
let err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &created)
if err == noErr, created != 0 {
    print("  CREATED ok (id \(created)) — so the HAL allows it; the app's path is what differs")
    let destroyErr = AudioHardwareDestroyAggregateDevice(created)
    print("  cleaned up (destroy err \(destroyErr))")
} else {
    print("  FAIL: AudioHardwareCreateAggregateDevice err=\(err) (\(fourCC(UInt32(bitPattern: err))))")
}
