// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import AVFoundation
import CoreAudio
import Foundation

/// Records the Mac's BUILT-IN microphone, pinned by device id, and dates the
/// first sample on `CLOCK_MONOTONIC` — the clock every probe pts is on.
/// Never the default input: that can be a Bluetooth speaker's own mic.
final class MicArrivalRecorder {

    enum RecorderError: Error, CustomStringConvertible {
        case microphoneDenied
        case noBuiltInMicrophone

        var description: String {
            switch self {
            case .microphoneDenied:
                return "microphone access denied: allow it for this terminal in System Settings > Privacy & Security > Microphone"
            case .noBuiltInMicrophone:
                return "this Mac has no built-in microphone"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var firstSampleNanos: Int64?

    /// Asks for microphone access, then starts the tap; returns the sample rate.
    func start() throws -> Double {
        guard Self.requestAccess() else { throw RecorderError.microphoneDenied }
        guard let mic = Self.builtInMicrophoneID() else { throw RecorderError.noBuiltInMicrophone }
        try engine.inputNode.auAudioUnit.setDeviceID(mic)
        // Tap with the pinned device's own format; the node's output format
        // still reports the previous device's rate right after pinning.
        let format = engine.inputNode.inputFormat(forBus: 0)
        // One back-to-back read of both clocks; the machine does not sleep
        // during a spike, so one offset holds for the whole run.
        let offset = Self.machToMonotonicOffsetNanos()
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { [self] buffer, when in
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { return }
            let channels = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for c in 0..<channels {
                for i in 0..<frames { mono[i] += data[c][i] / Float(channels) }
            }
            lock.withLock {
                if firstSampleNanos == nil {
                    // Undated buffers are dropped, not guessed: samples[0]
                    // must sit exactly at firstSampleNanos.
                    guard when.isHostTimeValid else { return }
                    firstSampleNanos = Int64(Self.machNanos(when.hostTime)) + offset
                }
                samples.append(contentsOf: mono)
            }
        }
        engine.prepare()
        try engine.start()
        return format.sampleRate
    }

    func stop() -> (samples: [Float], firstSampleMonotonicNanos: Int64) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { (samples, firstSampleNanos ?? 0) }
    }

    // MARK: - Helpers

    private static func requestAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let answered = DispatchSemaphore(value: 0)
            let granted = Granted()
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted.value = ok
                answered.signal()
            }
            answered.wait()
            return granted.value
        default:
            return false
        }
    }

    private final class Granted: @unchecked Sendable { var value = false }

    private static func machNanos(_ hostTime: UInt64) -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return hostTime &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
    }

    private static func machToMonotonicOffsetNanos() -> Int64 {
        let mach = machNanos(mach_absolute_time())
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        let monotonic = UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
        return Int64(monotonic) &- Int64(mach)
    }

    /// The first built-in device with input channels.
    private static func builtInMicrophoneID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return nil }
        return ids.first { id in
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            var configAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var configSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &configAddress, 0, nil, &configSize) == noErr, configSize > 0
            else { return false }
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(
                id, &configAddress, 0, nil, &configSize, raw.assumingMemoryBound(to: AudioBufferList.self)) == noErr
            else { return false }
            let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
        }
    }
}
