// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import AudioToolbox
import Foundation

/// AudioToolbox's built-in Opus encoder: Float32 interleaved 48 kHz stereo in,
/// one raw Opus packet out per call. Not thread-safe; one owner calls it.
public final class CastOpusEncoder {

    public let framesPerPacket: Int
    private let converter: AudioConverterRef
    private let input: Input
    private var output = [UInt8](repeating: 0, count: 1_500)

    /// The buffer the input callback hands over exactly once per `encode`.
    /// Owned memory, because the converter reads it after the callback returns.
    private final class Input {
        let samples: UnsafeMutableBufferPointer<Float>
        var handedOver = false
        init(count: Int) {
            samples = .allocate(capacity: count)
            samples.initialize(repeating: 0)
        }
        deinit { samples.deallocate() }
    }

    public init(framesPerPacket: Int, bitRate: Int) throws {
        var inFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var outFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var made: AudioConverterRef?
        let status = AudioConverterNew(&inFormat, &outFormat, &made)
        guard status == noErr, let made else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        var rate = UInt32(bitRate)
        let rateStatus = AudioConverterSetProperty(made, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
        guard rateStatus == noErr else {
            AudioConverterDispose(made)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(rateStatus))
        }
        self.framesPerPacket = framesPerPacket
        self.converter = made
        self.input = Input(count: framesPerPacket * 2)
    }

    deinit { AudioConverterDispose(converter) }

    /// `pcm` is exactly `framesPerPacket × 2` interleaved samples; nil when
    /// the converter produced no packet.
    public func encode(_ pcm: [Float]) -> Data? {
        precondition(pcm.count == framesPerPacket * 2, "one frame of interleaved stereo")
        _ = input.samples.update(fromContentsOf: pcm)
        input.handedOver = false
        var packets: UInt32 = 1
        var description = AudioStreamPacketDescription()
        let capacity = UInt32(output.count)
        let callback: AudioConverterComplexInputDataProc = { _, count, data, _, userData in
            let input = Unmanaged<Input>.fromOpaque(userData!).takeUnretainedValue()
            // A second ask inside one call means "more input": there is none.
            guard !input.handedOver else { count.pointee = 0; return 1 }
            input.handedOver = true
            data.pointee.mNumberBuffers = 1
            data.pointee.mBuffers.mNumberChannels = 2
            data.pointee.mBuffers.mDataByteSize = UInt32(input.samples.count * MemoryLayout<Float>.size)
            data.pointee.mBuffers.mData = UnsafeMutableRawPointer(input.samples.baseAddress)
            count.pointee = UInt32(input.samples.count / 2)
            return noErr
        }
        let produced: UInt32? = output.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: capacity, mData: UnsafeMutableRawPointer(buffer.baseAddress)))
            let status = AudioConverterFillComplexBuffer(
                converter, callback, Unmanaged.passUnretained(input).toOpaque(), &packets, &list, &description)
            guard status == noErr || status == 1, packets == 1 else { return nil }
            return list.mBuffers.mDataByteSize
        }
        guard let produced, produced > 0 else { return nil }
        return Data(output[0..<Int(produced)])
    }
}
