import AudioToolbox
import AVFoundation
import Foundation

/// What the tap captures.
enum TapMode {
    /// Whole-system stereo mixdown, excluding the given process object IDs (may be empty).
    case globalExcluding([AudioObjectID])
    /// Stereo mixdown of only the given process object IDs (single-app / few-app capture).
    case processes([AudioObjectID])
}

/// Owns the full lifecycle of a global system-audio process tap:
///   create tap -> read ASBD -> create aggregate device -> register IOProc ->
///   start -> (capture) -> teardown in the brief's documented order.
final class TapEngine {

    // Live Core Audio object handles. kAudioObjectUnknown == "not created".
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    private(set) var asbd = AudioStreamBasicDescription()
    private let ring: RingBuffer
    private let name: String

    // Diagnostics counters (written by the IOProc via plain pointers; read at
    // teardown only). Not in a hot log path — just integer bumps.
    let callbackCountPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    let inputBytesSeenPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    let ringWriteOKPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    let ringWriteFailPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    let nilDataPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    /// - Parameters:
    ///   - ring: destination for captured raw PCM bytes (drained by a writer thread).
    ///   - ringCapacityBytes: sized by the caller from the ASBD-derived byte rate.
    init(name: String, ring: RingBuffer) {
        self.name = name
        self.ring = ring
        callbackCountPtr.initialize(to: 0)
        inputBytesSeenPtr.initialize(to: 0)
        ringWriteOKPtr.initialize(to: 0)
        ringWriteFailPtr.initialize(to: 0)
        nilDataPtr.initialize(to: 0)
    }

    // MARK: Setup

    /// Creates the tap (global or per-process, per `mode`) and reads its real ASBD.
    /// This is the call that lazily triggers the TCC permission dialog on first run.
    func createTapAndReadFormat(mode: TapMode, muteBehavior: CATapMuteBehavior) throws {
        let desc: CATapDescription
        switch mode {
        case .globalExcluding(let excluded):
            // Whole-system stereo mixdown, optionally excluding processes (brief §1).
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        case .processes(let ids):
            // Stereo mixdown of just these processes (brief §2). This is the
            // per-app path (spec §9 routing).
            desc = CATapDescription(stereoMixdownOfProcesses: ids)
        }
        desc.uuid = UUID()                 // ties tap -> aggregate sub-tap (brief §3c)
        desc.muteBehavior = muteBehavior   // brief §6
        self.tapDescription = desc

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let err = AudioHardwareCreateProcessTap(desc, &newTapID)
        if err != noErr {
            // Most-likely cause on first run: TCC not yet granted.
            throw CAError(
                "AudioHardwareCreateProcessTap failed — this usually means the "
                + "system-audio-capture permission has not been granted yet. Approve "
                + "the dialog (or System Settings > Privacy & Security > Screen & "
                + "System Audio Recording), then re-run.",
                status: err)
        }
        self.tapID = newTapID

        // Read the ACTUAL format — never assume 48k/2ch (brief §0, §3b).
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var readASBD = AudioStreamBasicDescription()
        let fErr = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &readASBD)
        try checkStatus(fErr, "read kAudioTapPropertyFormat")
        self.asbd = readASBD
    }

    private var tapDescription: CATapDescription?

    /// Creates the private aggregate device that pins the tap to the current
    /// default system output device (brief §3c). Must run AFTER the ASBD read.
    func createAggregate() throws {
        guard let desc = tapDescription else {
            throw CAError("createAggregate called before createTapAndReadFormat")
        }
        let outputID = try defaultSystemOutputDeviceID()
        let outputUID = try readDeviceUID(outputID)
        let aggregateUID = UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String:          "Tap-\(name)",
            kAudioAggregateDeviceUIDKey as String:           aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String:     true,
            kAudioAggregateDeviceIsStackedKey as String:     false,
            kAudioAggregateDeviceTapAutoStartKey as String:  true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [ kAudioSubDeviceUIDKey as String: outputUID ]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    // MUST equal the CATapDescription's uuid string (brief §3c).
                    kAudioSubTapUIDKey as String: desc.uuid.uuidString
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        let err = AudioHardwareCreateAggregateDevice(
            description as CFDictionary, &newAggregateID)
        try checkStatus(err, "AudioHardwareCreateAggregateDevice")
        self.aggregateID = newAggregateID
    }

    /// Registers the realtime IOProc and starts the device.
    func startCapture() throws {
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let channels = Int(asbd.mChannelsPerFrame)
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        // Bytes per sample-frame across ALL channels, used to size the output stream.
        // For non-interleaved Float32 the buffer list has `channels` buffers each of
        // mBytesPerFrame; for interleaved it is one buffer of mBytesPerFrame*channels.
        let interleavedFrameBytes = nonInterleaved
            ? bytesPerFrame * channels
            : bytesPerFrame

        let ring = self.ring
        // Scratch buffer for interleaving is preallocated OUTSIDE the block. The
        // block itself must not allocate. We size it generously (frames * frameBytes).
        // 8192 frames is far above a typical HAL slice (~512-1024).
        let maxFrames = 8192
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: maxFrames * max(1, interleavedFrameBytes), alignment: 16)
        self.scratchBuffer = scratch
        let bytesPerChannelSample = bytesPerFrame // for non-interleaved, per-channel frame bytes

        var newProcID: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "com.audiouter.audiocap.capture",
                                  qos: .userInitiated)
        let cbCount = self.callbackCountPtr
        let inBytes = self.inputBytesSeenPtr
        let wOK = self.ringWriteOKPtr
        let wFail = self.ringWriteFailPtr
        let nilData = self.nilDataPtr

        let err = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, queue
        ) { _, inInputData, _, _, _ in
            // ---- REALTIME THREAD: no allocation, no locks, no logging. ----
            cbCount.pointee &+= 1
            // Index the flexible AudioBuffer array via the ORIGINAL pointer. Do NOT
            // copy inInputData.pointee first — the mBuffers[0] inline element copies
            // fine but mBuffers[1..] and any pointer taken from the copy are invalid.
            // UnsafeMutableAudioBufferListPointer walks the real trailing array.
            let mutablePtr = UnsafeMutablePointer(mutating: inInputData)
            let listPtr = UnsafeMutableAudioBufferListPointer(mutablePtr)
            let bufCount = listPtr.count
            if bufCount == 0 { return }
            inBytes.pointee &+= UInt64(listPtr[0].mDataByteSize)

            let buffers = listPtr

            if bufCount == 1 {
                // Interleaved (or single-buffer) — enqueue bytes directly.
                let b = buffers[0]
                guard let data = b.mData else { nilData.pointee &+= 1; return }
                if ring.write(data, Int(b.mDataByteSize)) { wOK.pointee &+= 1 }
                else { wFail.pointee &+= 1 }
            } else {
                // Non-interleaved: N planar buffers of Float32. Interleave into
                // scratch so the output stream is standard interleaved PCM, which is
                // what a raw .pcm consumer / ffplay expects.
                let frames = Int(buffers[0].mDataByteSize) / bytesPerChannelSample
                let n = min(frames, maxFrames)
                let ch = min(bufCount, channels)
                let out = scratch.assumingMemoryBound(to: Float32.self)
                for c in 0..<ch {
                    guard let src = buffers[c].mData else { continue }
                    let sp = src.assumingMemoryBound(to: Float32.self)
                    var f = 0
                    while f < n {
                        out[f * ch + c] = sp[f]
                        f += 1
                    }
                }
                _ = ring.write(scratch, n * ch * MemoryLayout<Float32>.size)
            }
        }
        try checkStatus(err, "AudioDeviceCreateIOProcIDWithBlock")
        self.ioProcID = newProcID

        let startErr = AudioDeviceStart(aggregateID, ioProcID)
        try checkStatus(startErr, "AudioDeviceStart")
    }

    private var scratchBuffer: UnsafeMutableRawPointer?

    /// The ASBD of the bytes actually written to the ring/output. For the
    /// non-interleaved planar tap we interleave, so channel layout is interleaved
    /// Float32 at the tap's sample rate; sample rate / channel count are unchanged.
    var outputASBD: AudioStreamBasicDescription {
        var out = asbd
        let channels = asbd.mChannelsPerFrame
        // Output is always interleaved Float32 regardless of tap interleaving.
        out.mFormatFlags = asbd.mFormatFlags & ~kAudioFormatFlagIsNonInterleaved
        let bytesPerSample = UInt32(MemoryLayout<Float32>.size)
        out.mBytesPerFrame = bytesPerSample * channels
        out.mBytesPerPacket = out.mBytesPerFrame
        out.mFramesPerPacket = 1
        return out
    }

    // MARK: Teardown (order matters — brief §3f)

    /// Stop -> DestroyIOProcID -> DestroyAggregateDevice -> DestroyProcessTap.
    /// Each step is guarded and logs (does not throw) so teardown always completes.
    func teardown() {
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            let e = AudioDeviceStop(aggregateID, proc)
            if e != noErr { elog("teardown: AudioDeviceStop -> \(osStatusString(e))") }
        }
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            let e = AudioDeviceDestroyIOProcID(aggregateID, proc)
            if e != noErr { elog("teardown: AudioDeviceDestroyIOProcID -> \(osStatusString(e))") }
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            let e = AudioHardwareDestroyAggregateDevice(aggregateID)
            if e != noErr { elog("teardown: AudioHardwareDestroyAggregateDevice -> \(osStatusString(e))") }
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            let e = AudioHardwareDestroyProcessTap(tapID)
            if e != noErr { elog("teardown: AudioHardwareDestroyProcessTap -> \(osStatusString(e))") }
            tapID = kAudioObjectUnknown
        }
        if let scratch = scratchBuffer {
            scratch.deallocate()
            scratchBuffer = nil
        }
    }

    var callbackCount: UInt64 { callbackCountPtr.pointee }
    var inputBytesSeen: UInt64 { inputBytesSeenPtr.pointee }
    var ringWriteOK: UInt64 { ringWriteOKPtr.pointee }
    var ringWriteFail: UInt64 { ringWriteFailPtr.pointee }
    var nilDataCount: UInt64 { nilDataPtr.pointee }

    deinit {
        callbackCountPtr.deallocate()
        inputBytesSeenPtr.deallocate()
        ringWriteOKPtr.deallocate()
        ringWriteFailPtr.deallocate()
        nilDataPtr.deallocate()
    }
}
