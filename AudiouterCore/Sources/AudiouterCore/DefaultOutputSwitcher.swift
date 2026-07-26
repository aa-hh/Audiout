// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import CoreAudio

// MARK: - Takeover switch-away (T5, PLAN-AIRPLAY-COEXISTENCE.md)

/// What a takeover attempt did to the Mac's default output device.
///
/// `notAirPlay` is the overwhelmingly common case and is a deliberate NO-OP:
/// the user's default output is only ever touched when it is an AirPlay
/// receiver holding UDP 319/320, never otherwise.
public enum DefaultOutputSwitchOutcome: Equatable, Sendable {
    /// The Mac's own default output is not AirPlay-class — nothing was touched.
    case notAirPlay
    /// The default output was moved to the built-in speakers; macOS tears its
    /// AirPlay session down and frees 319/320 ~1–3 s later (G1, measured).
    case switched
    /// The default output IS AirPlay-class but the Mac publishes no built-in
    /// output to move to (headless / aggregate-only). Nothing was touched —
    /// there is no safe destination, and picking an arbitrary other device
    /// would be a guess about where the user wants their audio.
    case noBuiltInDevice
    /// The write itself failed (unsettable or a HAL error). The connect goes
    /// ahead anyway: the helper's bind-retry loop may still win the ports.
    case writeFailed
}

/// The three Core Audio operations the switch-away needs, behind a protocol so
/// the decision logic below is unit-testable with a fake — **no test may ever
/// move the machine's real default output device.** Same reason
/// ``PTPHelperActivating`` and ``SystemVolumeControlling`` exist.
protocol SystemDefaultOutputControlling: Sendable {
    /// Whether the macOS SYSTEM default output is itself AirPlay-class.
    func defaultOutputIsAirPlayClass() -> Bool
    /// The Mac's built-in output device, or `nil` if it publishes none.
    func builtInOutputDevice() -> UInt32?
    /// Point the system default output at `device`. `false` if nothing was
    /// written.
    func setDefaultOutputDevice(_ device: UInt32) -> Bool
}

/// Moves the Mac's default output off an AirPlay receiver so macOS releases UDP
/// 319/320 for our PTP helper to bind.
///
/// ## Why this is the whole takeover mechanism
///
/// macOS binds 319/320 only while an AirPlay session is live, and releases them
/// ~1–3 s after the default output is switched AWAY from the AirPlay device
/// (G1, measured live 2026-07-26). It offers no yield signal and will not share
/// the ports even with `SO_REUSEPORT` (both separately measured — see the plan's
/// "Known asymmetry"). Switching the default output away is therefore not one
/// mitigation among several: it is the only lever that exists, and G1 proved it
/// sufficient on its own.
///
/// ## Why built-in speakers, always
///
/// Locked decision Q4=A: one predictable destination, not "the previous device"
/// and not a restore-on-disconnect dance. The user is in the middle of pointing
/// their audio at an Audiouter speaker; where the Mac's own (about to be muted
/// by the capture tap) output lands is a detail, and a remembered device could
/// itself be a second AirPlay receiver — which would hold the ports right back.
///
/// Called from `NativeBackend.convergeDevice` immediately BEFORE the T4 PTP
/// activation, so the helper's bind-retry loop races macOS's teardown rather
/// than a live session.
struct DefaultOutputSwitcher: Sendable {

    private let control: SystemDefaultOutputControlling

    init(control: SystemDefaultOutputControlling = CoreAudioDefaultOutputControl()) {
        self.control = control
    }

    /// Detect → switch. The detection guard comes FIRST and is the only thing
    /// that authorizes a write, so every path where the Mac's output is not an
    /// AirPlay receiver leaves the user's selection completely untouched.
    func switchAwayFromAirPlay() -> DefaultOutputSwitchOutcome {
        guard control.defaultOutputIsAirPlayClass() else { return .notAirPlay }
        guard let builtIn = control.builtInOutputDevice() else { return .noBuiltInDevice }
        return control.setDefaultOutputDevice(builtIn) ? .switched : .writeFailed
    }
}

/// Production ``SystemDefaultOutputControlling``. Both reads are the existing
/// ones, reused rather than re-derived: ``NativeBackend/currentDefaultOutputIsAirPlayClass()``
/// already resolves the default device and classifies its transport type, and
/// ``SystemLocalOutputResolver`` already resolves the built-in output for
/// `LocalPlaybackEngine`'s loop guard. Only the WRITE is new — the codebase had
/// no default-output-device write before T5.
struct CoreAudioDefaultOutputControl: SystemDefaultOutputControlling {

    /// House rule (AGENTS.md, `tap-follows-default-output-device`):
    /// `kAudioHardwarePropertyDefaultOutputDevice`, NEVER
    /// `…DefaultSystemOutputDevice` (the alert-sound device). Writing the wrong
    /// one here would move system beeps and leave the AirPlay session — and its
    /// port hold — exactly where it was. `OutputSelectorGuardTests` fails the
    /// build if the wrong selector ever appears in `Sources/`.
    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func defaultOutputIsAirPlayClass() -> Bool {
        NativeBackend.currentDefaultOutputIsAirPlayClass()
    }

    func builtInOutputDevice() -> UInt32? {
        SystemLocalOutputResolver().builtInOutputDevice()
    }

    /// Guarded exactly like ``SystemOutputVolume``'s writes: `AudioObjectIsPropertySettable`
    /// first, so a HAL that refuses the write no-ops instead of erroring.
    func setDefaultOutputDevice(_ device: UInt32) -> Bool {
        var address = Self.defaultOutputAddress
        let system = AudioObjectID(kAudioObjectSystemObject)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(system, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var deviceID = AudioObjectID(device)
        let err = AudioObjectSetPropertyData(
            system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &deviceID)
        if err != noErr {
            AudioDiag.log("DefaultOutputSwitcher.setDefaultOutputDevice AudioObjectSetPropertyData failed: \(err)")
        }
        return err == noErr
    }
}
