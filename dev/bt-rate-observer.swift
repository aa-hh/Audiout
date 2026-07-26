#!/usr/bin/env swift
//
// Dev-only diagnostic, NOT part of the app build (no SwiftPM target, not
// referenced by scripts/make-app.sh). Run: swift dev/bt-rate-observer.swift
//
// For PLAN-WHOLE-SYSTEM-AUDIO-DROPOUT-JUDDER-INVESTIGATION.md Wave 1 (D1): a
// Sony WH-1000XM3's nominal rate flaps 16000 (HFP/mic) <-> 44100 (A2DP/play)
// ~once/sec after connecting. Watches the system default output device from
// OUTSIDE Audiouter.app, to see if that happens with the app not running at
// all — see the run-book appended to that doc. Input-stream count is the HFP
// tell: non-zero only while the mic profile is active. Self-contained (no
// AudiouterCore import); property-address boilerplate mirrors
// NativeCaptureCoordinator.swift / DefaultOutputDeviceMonitor.swift.

import CoreAudio
import Foundation

// Line-buffer stdout even when redirected to a file (the run-book has you
// do this): unbuffered-by-default-on-a-TTY is fine, but full block-buffering
// on a file means a Ctrl-C (default SIGINT disposition skips atexit flush)
// can silently drop whatever's still sitting in the buffer.
setvbuf(stdout, nil, _IOLBF, 0)

let bootTime = ProcessInfo.processInfo.systemUptime
let clockFormatter = DateFormatter()
clockFormatter.dateFormat = "HH:mm:ss.SSS"
clockFormatter.timeZone = TimeZone(secondsFromGMT: 0) // UTC, to match telemetry.jsonl's "ts" field

func timestamp() -> String {
    let elapsed = ProcessInfo.processInfo.systemUptime - bootTime
    return String(format: "+%8.3fs %@", elapsed, clockFormatter.string(from: Date()))
}

func addr(
    _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func defaultOutputDeviceID() -> AudioObjectID? {
    var address = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard err == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

func deviceName(_ deviceID: AudioObjectID) -> String {
    var address = addr(kAudioObjectPropertyName)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var name: CFString?
    let err = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0) }
    return (err == noErr ? name as String? : nil) ?? "<unreadable>"
}

func nominalSampleRate(_ deviceID: AudioObjectID) -> Double {
    var address = addr(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
    return err == noErr ? rate : -1
}

// kAudioDevicePropertyTransportType, rendered so Bluetooth reads unambiguously
// next to AirPlay/USB/BuiltIn without enumerating every HAL constant.
func transportLabel(_ deviceID: AudioObjectID) -> String {
    var address = addr(kAudioDevicePropertyTransportType)
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return "unknown" }
    switch transport {
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "BluetoothLE"
    case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeAggregate: return "Aggregate"
    default: return "0x" + String(transport, radix: 16)
    }
}

// kAudioDevicePropertyStreams count for one scope. Input count is the HFP tell.
func streamCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var address = addr(kAudioDevicePropertyStreams, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return -1 }
    return Int(size) / MemoryLayout<AudioObjectID>.size
}

func logCurrentState(reason: String) {
    guard let deviceID = defaultOutputDeviceID() else {
        print("\(timestamp()) [\(reason)] no default output device")
        return
    }
    let inputs = streamCount(deviceID, scope: kAudioObjectPropertyScopeInput)
    let outputs = streamCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
    let rate = String(format: "%.0f", nominalSampleRate(deviceID))
    print("\(timestamp()) [\(reason)] device=\(deviceID) name=\"\(deviceName(deviceID))\" " +
          "transport=\(transportLabel(deviceID)) rateHz=\(rate) inputStreams=\(inputs) outputStreams=\(outputs)")
}

// Listener wiring: default-device identity, plus a rate listener re-targeted
// to whichever device is currently default (the rate property lives on the
// device itself, so a device swap needs its own remove-old/add-new step).
let listenerQueue = DispatchQueue(label: "bt-rate-observer")
var rateListenerDeviceID: AudioObjectID?
var rateListenerBlock: AudioObjectPropertyListenerBlock?

func retargetRateListener() {
    if let oldID = rateListenerDeviceID, let block = rateListenerBlock {
        var oldAddress = addr(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(oldID, &oldAddress, listenerQueue, block)
        rateListenerDeviceID = nil
        rateListenerBlock = nil
    }
    guard let deviceID = defaultOutputDeviceID() else { return }
    let block: AudioObjectPropertyListenerBlock = { _, _ in logCurrentState(reason: "rate") }
    var address = addr(kAudioDevicePropertyNominalSampleRate)
    guard AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, block) == noErr else {
        print("\(timestamp()) [error] could not add rate listener on device \(deviceID)")
        return
    }
    rateListenerDeviceID = deviceID
    rateListenerBlock = block
}

var defaultDeviceAddress = addr(kAudioHardwarePropertyDefaultOutputDevice)
let defaultDeviceBlock: AudioObjectPropertyListenerBlock = { _, _ in
    logCurrentState(reason: "default-device")
    retargetRateListener()
}
guard AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, listenerQueue, defaultDeviceBlock
) == noErr else {
    print("fatal: could not add default-output-device listener")
    exit(1)
}

logCurrentState(reason: "baseline")
retargetRateListener()
print("Watching default output device + nominal sample rate. Ctrl-C to stop.")
dispatchMain()
