// SPDX-License-Identifier: GPL-2.0-or-later
//
// Diagnostic spike for roadmap 034 (volume-key interception). NOT shipped.
//
// Answers the one question binary analysis could not: when you press a volume
// control while an aggregate device is the default output, does the OS emit
// ANY event a CGEventTap can catch — and at which layer? It installs TWO taps,
// one at the session level (where our app tapped) and one at the HID level (the
// earliest point), logs everything either one sees, and prints the current
// default output device's UID so we can also confirm our ownership gate would
// even fire.
//
// Deliberately observe-only (.listenOnly): it swallows nothing, so running it
// can't make your Mac's volume worse than it already is.

import Cocoa
import CoreAudio
import CoreGraphics
import ApplicationServices

// MARK: - Core Audio: what is the default output, really?

func defaultOutputDeviceID() -> AudioObjectID? {
    var id = AudioObjectID(0)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return status == noErr ? id : nil
}

func cfStringProperty(_ objID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(objID, &addr, 0, nil, &size, $0)
    }
    guard status == noErr else { return nil }
    return value as String?
}

func hasSettableVolume(_ objID: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var settable: DarwinBoolean = false
    let status = AudioObjectIsPropertySettable(objID, &addr, &settable)
    return status == noErr && settable.boolValue
}

func printDefaultOutput() {
    guard let id = defaultOutputDeviceID() else {
        print("• default output: <unreadable>")
        return
    }
    let uid = cfStringProperty(id, kAudioDevicePropertyDeviceUID) ?? "<?>"
    let name = cfStringProperty(id, kAudioObjectPropertyName) ?? "<?>"
    let ours = uid == "com.audiout.Audiout.aggregate"
    print("• default output: \"\(name)\"")
    print("    UID:  \(uid)   \(ours ? "← this IS our aggregate" : "← NOT our aggregate")")
    print("    volume scalar settable by CoreAudio: \(hasSettableVolume(id))")
}

// MARK: - The taps

var sessionTap: CFMachPort?
var hidTap: CFMachPort?

func describe(_ label: String, _ type: CGEventType, _ event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        print("[\(label)] tap DISABLED by system (\(type.rawValue)) — re-enabling")
        if let t = (label == "SESSION" ? sessionTap : hidTap) {
            CGEvent.tapEnable(tap: t, enable: true)
        }
        return
    }
    // Function-row keys (brightness, and on some layouts volume) arrive as plain
    // keyDown, not systemDefined — log their key code so nothing is missed.
    if type == .keyDown || type == .keyUp {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        print("[\(label)] \(type == .keyDown ? "keyDown" : "keyUp  ")  keyCode=\(code)")
        return
    }
    guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined else {
        print("[\(label)] type=\(type.rawValue)")
        return
    }
    let sub = ns.subtype.rawValue
    let d1 = ns.data1
    let keyCode = (d1 & 0xFFFF_0000) >> 16
    let state = (d1 & 0x0000_FF00) >> 8
    // This Mac emits an ambient heartbeat with no input (subtype 7, keyCode 0,
    // data1 0x1) — suppress exactly that so real presses stand out. Any real
    // volume/mute press carries a nonzero keyCode, so nothing real is hidden.
    if sub == 7 && d1 == 0x1 { return }
    print("[\(label)] systemDefined  subtype=\(sub)  keyCode=\(keyCode)  state=0x\(String(state, radix: 16))  data1=0x\(String(d1, radix: 16))")
}

let sessionCallback: CGEventTapCallBack = { _, type, event, _ in
    describe("SESSION", type, event)
    return Unmanaged.passUnretained(event)
}
let hidCallback: CGEventTapCallBack = { _, type, event, _ in
    describe("HID", type, event)
    return Unmanaged.passUnretained(event)
}

// keyDown(10) keyUp(11) flagsChanged(12) systemDefined(14) — plus the disabled
// notifications, which arrive regardless of mask.
let mask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue) |
    (1 << CGEventType.keyUp.rawValue) |
    (1 << CGEventType.flagsChanged.rawValue) |
    (1 << 14)

func makeTap(_ location: CGEventTapLocation, _ cb: @escaping CGEventTapCallBack) -> CFMachPort? {
    guard let tap = CGEvent.tapCreate(
        tap: location, place: .headInsertEventTap, options: .listenOnly,
        eventsOfInterest: mask, callback: cb, userInfo: nil
    ) else { return nil }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return tap
}

// MARK: - main

// Unbuffered stdout, so every line appears the instant you press a key — a
// pipe/file otherwise block-buffers and the tool looks dead while you press.
setbuf(stdout, nil)

print("=== volume-key-tap probe ===\n")
printDefaultOutput()
print("")

let trusted = AXIsProcessTrusted()
print("• Accessibility trusted for this process: \(trusted)")
if !trusted {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    print("  → prompted. Grant it (to whichever app is asking — likely Terminal),")
    print("    then re-run this probe. Taps below will be nil until granted.")
}

sessionTap = makeTap(.cgSessionEventTap, sessionCallback)
hidTap = makeTap(.cghidEventTap, hidCallback)
print("• SESSION tap installed: \(sessionTap != nil)")
print("• HID tap installed:     \(hidTap != nil)")

print("""

Now press, one at a time, watching for lines above:
  1. Touch Bar volume DOWN, then UP  (the grayed buttons)
  2. Touch Bar mute
  3. If you have an external keyboard with volume keys, press those too
  4. As a sanity check that the tap works at all: press the fn-row / any media key

If pressing the grayed Touch Bar buttons prints NOTHING on either tap, the OS
emits no catchable event for them and interception cannot work — we pivot.
If a physical key prints but the Touch Bar doesn't, same conclusion.
Ctrl-C to quit.

""")

CFRunLoopRun()
