// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

// T7 (PLAN-FIREFOX-ROUTING-LEAK.md, Q5): a SILENT, NO-AUDIO diagnostic that
// dumps every live Core Audio process object on the system, so Alec can
// visually confirm — on his own Mac, with a real multi-process browser
// actually playing audio — whether that browser's audio comes from a
// process distinct from the one `NSRunningApplication` resolves for its
// bundle ID. This tool plays NOTHING and captures NOTHING; it only reads
// object/property metadata already exposed by the HAL (the same
// `kAudioHardwarePropertyProcessObjectList` the per-app/whole-system tap
// coordinators already enumerate — see `AudioProcessResolver.swift`'s
// `liveAudioProcessObjects` and `NativeCaptureCoordinator.swift`'s
// `translateExcludedProcessObjects` for the sibling reads this mirrors).
//
// Run: `swift run process-audio-dump` (from AudiouterCore/), while the
// browser in question is actively playing audio (a real audio STREAM is
// what registers a process object — a silent/paused tab may not appear).
//
// Output is a plain table: for every process object's PID, its command
// name + parent PID (via `ps`, since Core Audio's own process-object
// properties expose no bundle-ID/parent relationship as of this SDK), and
// whether that exact PID independently resolves via `NSRunningApplication`
// (revealing whether it's a top-level app the user launched, or a
// child/helper process spawned by one). The theory under test: a
// multi-process browser's actual audio producer is a child process that
// does NOT itself appear as an `NSRunningApplication`, while the app's
// main process — the ONLY pid `NSRunningApplication.runningApplications
// (withBundleIdentifier:)` ever returns — may not appear in this list at
// all (never opened an audio stream).

import AppKit
import AudioToolbox
import Foundation

func processObjectList() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let sizeErr = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    guard sizeErr == noErr, size > 0 else {
        print("Could not read kAudioHardwarePropertyProcessObjectList size (\(sizeErr))")
        return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var list = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
    let dataErr = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &list)
    guard dataErr == noErr else {
        print("Could not read kAudioHardwarePropertyProcessObjectList data (\(dataErr))")
        return []
    }
    return list
}

/// The PID a Core Audio process object represents. `kAudioProcessPropertyPID`
/// is the documented, stable read for this (distinct from
/// `kAudioHardwarePropertyTranslatePIDToProcessObject`, which goes the OTHER
/// direction — pid to object). Returns nil on a failed read rather than
/// crashing the whole dump over one uncooperative object.
func pid(ofProcessObject objectID: AudioObjectID) -> pid_t? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var pid: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
    guard err == noErr else { return nil }
    return pid
}

/// Whether this process object's audio is currently running (has an active
/// I/O stream) — a paused/silent tab's process object may still be enumerated
/// (it opened a stream at some point) but report false here.
func isRunning(processObject objectID: AudioObjectID) -> Bool? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunning,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let err = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &running)
    guard err == noErr else { return nil }
    return running != 0
}

struct ProcessLineage {
    let comm: String
    let ppid: pid_t
    let parentComm: String
}

/// Shells out to `ps` for a pid's command name + parent pid + parent's
/// command name — the only reliable, documented way to learn a process's
/// ancestry from outside it; Core Audio's process-object properties expose
/// no parent/bundle-ID relationship. Best-effort: returns nil for a pid that
/// has already exited between enumeration and this read (real race, harmless
/// — just skip it in the table).
func lineage(for targetPID: pid_t) -> ProcessLineage? {
    guard let selfLine = psLine(pid: targetPID) else { return nil }
    let ppid = selfLine.ppid
    let parentComm = psLine(pid: ppid)?.comm ?? "(exited)"
    return ProcessLineage(comm: selfLine.comm, ppid: ppid, parentComm: parentComm)
}

private func psLine(pid: pid_t) -> (comm: String, ppid: pid_t)? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-o", "ppid=,comm=", "-p", String(pid)]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        return nil
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstSpace = trimmed.firstIndex(of: " ") else { return nil }
    let ppidString = trimmed[trimmed.startIndex..<firstSpace]
    let comm = trimmed[trimmed.index(after: firstSpace)...].trimmingCharacters(in: .whitespaces)
    guard let ppid = pid_t(ppidString) else { return nil }
    return (comm, ppid)
}

// MARK: - Main

/// Pads `text` to at least `width` characters (never truncates — a long
/// value just pushes later columns right rather than losing information).
func padded(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
}

print("T7 diagnostic — live Core Audio process objects (no audio played or captured)")
print(String(repeating: "=", count: 100))

let objects = processObjectList()
guard !objects.isEmpty else {
    print("No process objects found (or the property read failed above). Nothing to report.")
    exit(0)
}

print("\(objects.count) process object(s) currently registered with the HAL.\n")
print(padded("OBJID", 7) + padded("PID", 8) + padded("COMM", 24) + padded("PPID", 8)
    + padded("PARENT COMM", 24) + padded("RUNNING", 9) + padded("NSRunningApp?", 15) + "BUNDLE ID")

for objectID in objects {
    guard let objectPID = pid(ofProcessObject: objectID) else {
        print(padded(String(objectID), 7) + "(pid read failed)")
        continue
    }
    let running = isRunning(processObject: objectID)
    let runningStr = running.map { $0 ? "yes" : "no" } ?? "?"
    let lineageInfo = lineage(for: objectPID)
    let comm = lineageInfo?.comm ?? "(exited?)"
    let ppid = lineageInfo?.ppid ?? -1
    let parentComm = lineageInfo?.parentComm ?? "?"

    // Does THIS exact pid independently resolve as a top-level running
    // application (the thing NSRunningApplication.runningApplications
    // (withBundleIdentifier:) would find)? A child/helper process spawned
    // by an app is NEVER itself an NSRunningApplication — this is the
    // direct test of the theory.
    let runningApp = NSRunningApplication(processIdentifier: objectPID)
    let isTopLevelApp = runningApp != nil
    let bundleID = runningApp?.bundleIdentifier ?? "-"

    print(padded(String(objectID), 7) + padded(String(objectPID), 8) + padded(comm, 24)
        + padded(String(ppid), 8) + padded(parentComm, 24) + padded(runningStr, 9)
        + padded(isTopLevelApp ? "YES" : "no", 15) + bundleID)
}

print("\n" + String(repeating: "=", count: 100))
print("""
How to read this: for the browser you're testing (e.g. Firefox), look for a
row whose COMM is something like "firefox"/a content-process/GPU-process
helper name, whose PARENT COMM traces back to the real browser, and whose
"NSRunningApplication?" column says "no" — that's a process object producing
real audio that our current single-PID resolver (NSRunningApplication.
runningApplications(withBundleIdentifier:)) can never find, because that
lookup only ever returns the ONE row where NSRunningApplication? is YES.
If Firefox's main process (the YES row) does NOT appear in this list at all,
that independently confirms it never opened an audio stream — exactly the
"whole-system tap excludes the wrong pid" / "per-app tap targets a silent
pid" failure mode the plan describes.
""")
