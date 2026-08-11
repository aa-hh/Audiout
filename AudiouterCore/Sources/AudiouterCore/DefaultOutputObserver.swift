import CoreAudio
import Foundation

/// Lightweight Core Audio observer that tracks the macOS default audio output
/// device name (e.g. "MacBook Pro Speakers", "AirPods Pro"). Thread-safe via a
/// private serial queue; never crashes — falls back to "Mac" if a query fails.
public final class DefaultOutputObserver: @unchecked Sendable {

    // MARK: - Public API

    // STABILITY(D6): narrow verified races — see dev/notes/stability-audit-2026-07-18.md
    /// Called on the observer's private queue when the default output device changes.
    /// The argument is the new device name.
    public var onChange: ((String) -> Void)?

    // STABILITY(D6): narrow verified races — see dev/notes/stability-audit-2026-07-18.md
    /// The current default output device name. Readable from any thread (the
    /// backing store is only mutated on `queue`).
    public private(set) var currentDeviceName: String = "Mac"

    // MARK: - Private state

    private let queue = DispatchQueue(label: "com.audiouter.defaultoutput")

    /// The property address we listen on — stored so add/remove use the same value.
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The listener block reference. Must be the exact same object passed to
    /// add and remove.
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private var isListening = false

    // MARK: - Lifecycle

    deinit {
        // Remove listener synchronously — safe because `queue` is not the
        // current queue at deinit (callers don't call deinit from our queue).
        stopListening()
    }

    // MARK: - Start / Stop

    public func start() {
        queue.sync { [self] in
            guard !isListening else { return }

            currentDeviceName = Self.queryDefaultOutputDeviceName()

            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let name = Self.queryDefaultOutputDeviceName()
                self.currentDeviceName = name
                self.onChange?(name)
            }
            listenerBlock = block

            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultDeviceAddress,
                queue,
                block
            )
            if status == noErr {
                isListening = true
            }
        }
    }

    public func stop() {
        queue.sync { [self] in
            stopListening()
        }
    }

    // MARK: - Private helpers

    /// Remove the listener if one is installed. Must be called on `queue` or
    /// when no concurrent access is possible (deinit).
    private func stopListening() {
        guard isListening, let block = listenerBlock else { return }
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            queue,
            block
        )
        if status != noErr {
            AudioDiag.log("DefaultOutputObserver.stopListening AudioObjectRemovePropertyListenerBlock failed: \(status)")
        }
        listenerBlock = nil
        isListening = false
    }

    // MARK: - Core Audio queries

    /// Returns the name of the current default output device, or "Mac" on any failure.
    private static func queryDefaultOutputDeviceName() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let idStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard idStatus == noErr, deviceID != kAudioObjectUnknown else {
            return "Mac"
        }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let nameStatus = AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0,
            nil,
            &nameSize,
            &name
        )
        guard nameStatus == noErr else {
            return "Mac"
        }

        let result = name as String
        return result.isEmpty ? "Mac" : result
    }
}
