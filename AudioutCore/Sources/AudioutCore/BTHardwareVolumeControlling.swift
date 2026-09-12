// SPDX-License-Identifier: GPL-2.0-or-later

import CoreAudio

/// The backend's seam onto a Bluetooth speaker's own volume (BT-HW-VOL):
/// instance-shaped so tests can script controllability, reads, write
/// failures, and device-side changes with no HAL in the loop.
protocol BTHardwareVolumeControlling: AnyObject, Sendable {
    /// The volume property is present AND settable on this device. A device
    /// can advertise settable yet not deliver (PLAN-AIRPLAY-COEXISTENCE.md
    /// trap) — a failed `write` is the real signal, this is only the gate.
    func isControllable(_ deviceID: AudioObjectID) -> Bool
    /// Current hardware level on the UI's 0…100 scale; nil if unreadable.
    func read(_ deviceID: AudioObjectID) -> Int?
    /// Write a 0…100 level; false when the HAL write fails.
    func write(_ uiLevel: Int, to deviceID: AudioObjectID, uid: String) -> Bool
    /// Watch DEVICE-side changes (echo-suppressed). Replaces any existing
    /// watch for this uid; `onChange` may arrive on a HAL thread.
    func watch(deviceID: AudioObjectID, uid: String, onChange: @escaping @Sendable (Int) -> Void)
    func unwatch(uid: String)
}

extension BTHardwareVolume: BTHardwareVolumeControlling {
    func isControllable(_ deviceID: AudioObjectID) -> Bool { Self.isControllable(deviceID) }
    func read(_ deviceID: AudioObjectID) -> Int? { Self.read(deviceID) }
}
