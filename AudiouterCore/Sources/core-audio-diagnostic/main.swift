// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import AppKit
import Darwin

#if canImport(AudioToolbox)
import AudioToolbox
#endif

private func getParentPID(_ pid: pid_t) -> pid_t? {
    let PROC_PIDTBSDINFO: Int32 = 3
    var buffer = [UInt8](repeating: 0, count: 256)

    let result = buffer.withUnsafeMutableBytes { buf in
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buf.baseAddress!, Int32(buf.count))
    }

    guard result > 0 else {
        return nil
    }

    let ppid = buffer.withUnsafeBytes { buf in
        buf.baseAddress!.advanced(by: 24).assumingMemoryBound(to: pid_t.self).pointee
    }

    return ppid > 1 ? ppid : nil
}

private func resolveResponsibleProcess(_ pid: pid_t) -> (resPID: pid_t?, resBundleID: String?) {
    var currentPID = pid
    let maxHops = 5

    for _ in 0..<maxHops {
        guard let ppid = getParentPID(currentPID), ppid > 1 else {
            break
        }

        if let app = NSRunningApplication(processIdentifier: ppid),
           let bundleID = app.bundleIdentifier,
           !bundleID.isEmpty {
            return (ppid, bundleID)
        }

        currentPID = ppid
    }

    return (nil, nil)
}

func main() -> Int32 {
    guard getenv("AUDIOUTER_CORE_AUDIO_DIAGNOSTIC") != nil else {
        print("core-audio-diagnostic: env gate AUDIOUTER_CORE_AUDIO_DIAGNOSTIC not set; aborting.")
        print("Usage: AUDIOUTER_CORE_AUDIO_DIAGNOSTIC=1 swift run core-audio-diagnostic")
        return 1
    }

    #if canImport(AudioToolbox)
    guard #available(macOS 14.2, *) else {
        print("core-audio-diagnostic: requires macOS 14.2+")
        return 1
    }

    do {
        try diagnoseProcessObjects()
        return 0
    } catch {
        print("core-audio-diagnostic: \(error)")
        return 2
    }
    #else
    print("core-audio-diagnostic: AudioToolbox not available on this platform")
    return 1
    #endif
}

#if canImport(AudioToolbox)
@available(macOS 14.2, *)
private func diagnoseProcessObjects() throws {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    var size: UInt32 = 0
    var err = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    guard err == noErr else {
        throw DiagnosticError("AudioObjectGetPropertyDataSize failed: \(err)")
    }

    let processCount = Int(size) / MemoryLayout<AudioObjectID>.size
    guard processCount > 0 else {
        print("No Core Audio process objects found.")
        return
    }

    var processIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: processCount)
    err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        0, nil, &size, &processIDs)
    guard err == noErr else {
        throw DiagnosticError("AudioObjectGetPropertyData failed: \(err)")
    }

    print("Core Audio Process Objects (T7 diagnosis)")
    print(String(repeating: "=", count: 100))
    print("ObjectID     PID      BundleID                   ResPID   ResponsibleBundleID")
    print(String(repeating: "-", count: 100))

    var successCount = 0
    var failureCount = 0

    for processID in processIDs {
        guard processID != kAudioObjectUnknown else { continue }

        do {
            let pid = try readProcessPID(processID)
            let bundleID = readProcessBundleID(processID)

            let resPID: pid_t?
            let resBundleID: String?

            let isNilBundle = bundleID == nil || (bundleID?.isEmpty ?? false)
            if isNilBundle {
                (resPID, resBundleID) = resolveResponsibleProcess(pid)
            } else {
                resPID = nil
                resBundleID = nil
            }

            let pidStr = String(pid)
            let objIDHex = String(processID, radix: 16)
            let bundleStr = isNilBundle ? "<nil>" : bundleID!
            let resPidStr = resPID.map(String.init) ?? "—"
            let resBundleStr = resBundleID ?? "—"

            print("0x\(objIDHex)     \(pidStr)     \(bundleStr)     \(resPidStr)     \(resBundleStr)")
            successCount += 1
        } catch {
            failureCount += 1
            let objIDHex = String(processID, radix: 16)
            print("0x\(objIDHex) ERROR: \(error.localizedDescription)")
        }
    }

    print(String(repeating: "-", count: 100))
    print("Summary: \(processCount) total process object(s), \(successCount) read successfully, \(failureCount) read failed")
    print("")
    print("Note: ResPID/ResponsibleBundleID resolves via ppid-walk for nil-bundle-ID processes.")
    print("For Firefox audio routing test: look for Firefox child processes (nil BundleID) whose ResPID is Firefox's main PID.")
}

@available(macOS 14.2, *)
private func readProcessPID(_ processID: AudioObjectID) throws -> pid_t {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    var pid: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    let err = AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &pid)
    guard err == noErr else {
        throw DiagnosticError("read kAudioProcessPropertyPID failed: \(err)")
    }
    return pid
}

@available(macOS 14.2, *)
private func readProcessBundleID(_ processID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    var size: UInt32 = 0
    let sizeErr = AudioObjectGetPropertyDataSize(processID, &address, 0, nil, &size)
    guard sizeErr == noErr, size > 0 else {
        return nil
    }

    var bundleIDCFString: CFString? = nil
    let err = withUnsafeMutablePointer(to: &bundleIDCFString) { ptr -> OSStatus in
        AudioObjectGetPropertyData(processID, &address, 0, nil, &size, ptr)
    }
    guard err == noErr else {
        return nil
    }

    guard let bundleID = bundleIDCFString else {
        return nil
    }

    return bundleID as String
}

struct DiagnosticError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String {
        message
    }
}

#endif

exit(main())
