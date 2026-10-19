// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import CoreAudio
import AudioToolbox

/// Per-device hardware volume for Bluetooth speakers, via Core Audio's
/// virtual-main-volume property. Static reads are stateless; an instance
/// owns write echo-suppression and external-change listeners.
///
/// The HAL primitives (address ladder, guarded read/write) are
/// ``SystemOutputVolume``'s; only the per-device echo state and listeners are
/// new here. `SystemOutputVolume`'s own listener machinery is hardwired to the
/// default output device and is deliberately not reused.
public final class BTHardwareVolume: @unchecked Sendable {

    /// A write we made and expect to hear back. `scalar` is what we handed the
    /// HAL, not what it stored — see ``isEcho(lastWrite:now:readBack:)``.
    struct PendingWrite {
        let scalar: Float
        let at: Date
    }

    /// The HAL may quantize a written scalar (many devices to 1/16 steps), so an
    /// exact-match comparison misses our own echo and reports it as a user
    /// gesture. The tolerance must cover the worst case of that grid — half a
    /// step, 1/32 = 0.03125 — plus float slop, or every drag's own echo on such
    /// a device reads as an external change and yanks the slider.
    static let echoTolerance: Float = 0.04

    /// After this, a matching value is somebody else's doing, not our echo.
    static let echoWindow: TimeInterval = 2

    /// A listener event is our own write's echo when it lands soon enough after
    /// that write and reads back close enough to it.
    static func isEcho(lastWrite: PendingWrite?, now: Date, readBack: Float) -> Bool {
        guard let lastWrite else { return false }
        guard now.timeIntervalSince(lastWrite.at) <= echoWindow,
              now >= lastWrite.at else { return false }
        return abs(readBack - lastWrite.scalar) <= echoTolerance
    }

    // MARK: State

    private struct Watch {
        let registrations: [(objectID: AudioObjectID, address: AudioObjectPropertyAddress)]
        let block: AudioObjectPropertyListenerBlock
    }

    /// Serial queue the HAL dispatches listener blocks onto.
    private let queue = DispatchQueue(label: "com.audiout.bt-hardware-volume")

    private let lock = NSLock()
    private var lastWrites: [String: PendingWrite] = [:]
    private var watches: [String: Watch] = [:]

    public init() {}

    deinit { unwatchAll() }

    // MARK: Static reads

    /// The volume property is present AND settable on this device. NOTE: a
    /// device can advertise settable yet not deliver (recorded trap in
    /// docs/plans/PLAN-AIRPLAY-COEXISTENCE.md:35) — callers treat a failed
    /// write as the real signal.
    public static func isControllable(_ deviceID: AudioObjectID) -> Bool {
        candidateAddresses(deviceID).contains { SystemOutputVolume.isWritable(deviceID, $0) }
    }

    /// Current hardware level on the UI's 0…100 scale; nil if unreadable.
    public static func read(_ deviceID: AudioObjectID) -> Int? {
        readScalar(deviceID).map(SystemOutputVolume.volumeInt(fromScalar:))
    }

    /// ONE ladder for read, settable check, and listener registration —
    /// `candidateAddresses` — so all three bind the same property on a device
    /// that publishes more than one.
    private static func readScalar(_ deviceID: AudioObjectID) -> Float? {
        for address in candidateAddresses(deviceID) {
            if let scalar = SystemOutputVolume.readFloat(deviceID, address) { return scalar }
        }
        return nil
    }

    private static func candidateAddresses(_ deviceID: AudioObjectID) -> [AudioObjectPropertyAddress] {
        var addresses = [
            SystemOutputVolume.virtualMainVolumeAddress,
            SystemOutputVolume.volumeAddress(element: kAudioObjectPropertyElementMain),
        ]
        for channel in SystemOutputVolume.preferredStereoChannels(deviceID)
        where channel != kAudioObjectPropertyElementMain {
            addresses.append(SystemOutputVolume.volumeAddress(element: channel))
        }
        return addresses
    }

    // MARK: Write

    /// Write a 0…100 UI level. Returns false when the HAL write fails.
    /// Records the written scalar so the device listener can suppress the echo.
    public func write(_ uiLevel: Int, to deviceID: AudioObjectID, uid: String) -> Bool {
        let clamped = uiLevel.clampedToVolume
        let scalar = SystemOutputVolume.scalar(fromVolumeInt: clamped)
        // Recorded before the write: the notification it provokes can land on
        // `queue` the instant the HAL sees it.
        lock.lock()
        lastWrites[uid] = PendingWrite(scalar: scalar, at: Date())
        lock.unlock()
        let wrote = SystemOutputVolume.writeVolume(clamped, to: deviceID)
        if !wrote {
            // Nothing reached the hardware, so nothing will echo; a stale record
            // would swallow a real change that happens to land on this value.
            lock.lock()
            lastWrites[uid] = nil
            lock.unlock()
        }
        return wrote
    }

    // MARK: Watch

    /// Watch DEVICE-side changes: onChange fires with the new 0…100 level for
    /// changes NOT caused by our own write (echo-suppressed with a small
    /// tolerance, since the HAL may quantize what we wrote). Replaces any
    /// existing watch for this uid. onChange may be called on a HAL thread.
    ///
    /// Keyed by uid, not by device id: Bluetooth `AudioObjectID`s go stale across
    /// reconnects, so a re-watch after a reconnect passes the fresh id.
    public func watch(deviceID: AudioObjectID, uid: String, onChange: @escaping @Sendable (Int) -> Void) {
        unwatch(uid: uid)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let scalar = Self.readScalar(deviceID) else { return }
            self.lock.lock()
            let pending = self.lastWrites[uid]
            self.lock.unlock()
            guard !Self.isEcho(lastWrite: pending, now: Date(), readBack: scalar) else { return }
            onChange(SystemOutputVolume.volumeInt(fromScalar: scalar))
        }

        // Register on the first address the device actually publishes: one
        // logical change fans out across the ladder, so more registrations would
        // only multiply callbacks for the same change.
        var registrations: [(objectID: AudioObjectID, address: AudioObjectPropertyAddress)] = []
        for candidate in Self.candidateAddresses(deviceID) {
            var address = candidate
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            guard AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr else { continue }
            registrations.append((deviceID, address))
            break
        }
        guard !registrations.isEmpty else { return }

        lock.lock()
        watches[uid] = Watch(registrations: registrations, block: block)
        lock.unlock()
    }

    public func unwatch(uid: String) {
        lock.lock()
        let watch = watches.removeValue(forKey: uid)
        lastWrites[uid] = nil
        lock.unlock()
        guard let watch else { return }
        remove(watch)
    }

    /// Drop every listener (deinit safety).
    public func unwatchAll() {
        lock.lock()
        let all = watches.values
        watches = [:]
        lastWrites = [:]
        lock.unlock()
        for watch in all { remove(watch) }
    }

    private func remove(_ watch: Watch) {
        for registration in watch.registrations {
            var address = registration.address
            let status = AudioObjectRemovePropertyListenerBlock(
                registration.objectID, &address, queue, watch.block)
            if status != noErr {
                AudioDiag.log("BTHardwareVolume.remove AudioObjectRemovePropertyListenerBlock failed for object \(registration.objectID): \(status)")
            }
        }
    }
}
