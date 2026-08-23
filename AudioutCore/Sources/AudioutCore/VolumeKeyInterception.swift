// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// The pure decision core behind the volume-key interceptor
// (`docs/plans/PLAN-VOLUME-KEY-INTERCEPTION.md`, W1 + W2). Everything here is a
// value-in/value-out function so the whole feature is testable without a
// `CGEventTap`, an Accessibility grant, or a real aggregate device. The tap that
// will call these belongs in the app target and stays a thin shell — none of the
// decisions below may migrate into it.
//
// WHY THIS EXISTS AT ALL: when our public "Audiout" aggregate is the Mac's
// default output, macOS refuses to move the system volume — the hardware volume
// keys show the crossed-out HUD and do nothing. Without interception the only
// way to change volume while the app routes is to open the app.
//
// This folder never imports AppKit (see AGENTS.md), so the event is decoded from
// its raw `data1` / modifier-flag integers rather than from `NSEvent`. That is
// deliberate, not a workaround: the bit-twiddling is exactly where the traps
// live, so it belongs on the tested side of the seam.

// MARK: - The mode

/// Whether *we* own the volume right now, i.e. macOS cannot move the system
/// volume so the app must take the wheel.
///
/// This one predicate gates BOTH halves of the feature — intercepting the keys
/// (input) and folding Main into the local sink's gain (output). They are not
/// two features; they are the two directions of the same condition. Do not add
/// a second gate for either half.
public enum VolumeOwnership {

    /// - Parameters:
    ///   - defaultOutputUID: the UID of the Mac's current default output device.
    ///   - systemOutputVolume: ``OutputBackend/systemOutputVolume`` — `nil` when
    ///     the default output publishes no readable volume at all.
    ///
    /// **Identity, never capability.** The aggregate LIES about what it can do:
    /// `aggtool status` reports `vmvc=true scalarMain=true muteMain=true` while
    /// every write silently no-ops, so it reads as a perfectly settable device
    /// and slips straight through a capability probe — the takeover would never
    /// fire and volume would just stay dead with no error anywhere. We create the
    /// aggregate, so we own its UID, and a string match is exact where a
    /// behavioural test is fragile.
    ///
    /// The second arm keeps genuinely unreadable outputs (real HDMI) working —
    /// a pre-existing gap, not scope creep, and it shares this exact condition.
    ///
    /// ORDERING REQUIREMENT: `systemOutputVolume` is a cached read, so it is also
    /// `nil` before the backend's first read completes. Callers must evaluate
    /// this only once the backend is started, or a launch-time transient reads as
    /// "we own volume" on a perfectly normal output. The identity arm is immune.
    public static func weOwnVolume(defaultOutputUID: String?, systemOutputVolume: Int?) -> Bool {
        if defaultOutputUID == AggregateOutputDevice.productUID { return true }
        return systemOutputVolume == nil
    }
}

// MARK: - Decoding an aux key press

/// One decoded press of a macOS aux ("NX") media key — the systemDefined/
/// subtype-8 event shape that both a hardware volume key and the Touch Bar's
/// discrete volume buttons produce.
///
/// The Touch Bar detail matters and is easy to get wrong: `ControlStrip.app`
/// drives its *discrete* Volume Up/Down buttons through
/// `DFRFoundationPostHIDUsage`, which posts a real Consumer-page HID usage, so
/// they arrive here indistinguishable from a hardware key. Its volume *slider*
/// instead calls `AudioObjectSetPropertyData` on the device directly and greys
/// itself out from `AudioObjectIsPropertySettable` — that half emits no event
/// and can never be intercepted by anyone.
public struct AuxKeyPress: Equatable, Sendable {

    /// The aux key codes we act on, from `IOKit/hidsystem/ev_keymap.h`.
    /// Deliberately only the volume subset — ``MediaKeyController/AuxKey`` in the
    /// app target owns the transport subset it *posts*, and the two must not be
    /// merged: this one is read from the wire, that one is written to it.
    public enum Key: Int32, Sendable {
        case soundUp = 0    // NX_KEYTYPE_SOUND_UP
        case soundDown = 1  // NX_KEYTYPE_SOUND_DOWN
        case mute = 7       // NX_KEYTYPE_MUTE
    }

    public let key: Key
    /// `true` for the down transition (`0xA`), `false` for up (`0xB`).
    public let isDown: Bool
    /// `true` when this is an auto-repeat from a held key.
    public let isRepeat: Bool

    /// Pull a volume aux key out of a systemDefined event's `data1`, or `nil` if
    /// this is any other systemDefined event (they are common — screen changes,
    /// power notifications — so a `nil` here is the ordinary case, not an error).
    ///
    /// Layout: key code in the high 16 bits, key state in the next byte
    /// (`0xA` down / `0xB` up), auto-repeat in the low bit. Same encoding
    /// ``MediaKeyController`` writes when it posts transport keys.
    public static func decode(data1: Int) -> AuxKeyPress? {
        let keyCode = Int32(truncatingIfNeeded: (data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8

        guard let key = Key(rawValue: keyCode) else { return nil }
        guard keyState == 0xA || keyState == 0xB else { return nil }

        return AuxKeyPress(key: key, isDown: keyState == 0xA, isRepeat: (keyFlags & 0x1) == 1)
    }
}

// MARK: - Modifier flags

/// The `⇧⌥` quarter-step modifier, read from a systemDefined event's raw
/// modifier flags.
///
/// THE TRAP: the aux-key encoding mirrors the key state into the low bits of the
/// same flags field (`0xA00` / `0xB00`), so testing the raw value directly gives
/// wrong answers. Mask to the device-independent bits first — that is what
/// `NSEvent.ModifierFlags.deviceIndependentFlagsMask` does, restated here as a
/// constant because this folder never imports AppKit.
enum AuxModifierFlags {
    /// `NSEvent.ModifierFlags.deviceIndependentFlagsMask`
    static let deviceIndependentMask: UInt = 0xFFFF_0000
    /// `NSEvent.ModifierFlags.shift`
    static let shift: UInt = 1 << 17
    /// `NSEvent.ModifierFlags.option`
    static let option: UInt = 1 << 19

    /// macOS moves volume in quarter steps while `⇧⌥` is held.
    static func isFineStep(_ rawFlags: UInt) -> Bool {
        let flags = rawFlags & deviceIndependentMask
        return (flags & shift) != 0 && (flags & option) != 0
    }
}

// MARK: - Step math

/// Moves a 0–100 volume the way macOS does: sixteen detents across the range,
/// quarter-detents while `⇧⌥` is held.
public enum VolumeStep {

    /// Detents across the full range for a normal press. macOS uses 16.
    static let coarseDetents = 16.0
    /// Detents for a `⇧⌥` quarter step — a quarter of each coarse detent.
    static let fineDetents = 64.0

    /// The volume one key press away from `current`.
    ///
    /// Snaps to the detent grid rather than adding a fixed delta, which is what
    /// makes repeated presses land on macOS's own stops and stay reversible in
    /// integer space: 0 → 6 → 13 → 19 going up lands back on 13 → 6 → 0 coming
    /// down. A plain `current ± 6` drifts instead.
    public static func next(from current: Int, up: Bool, fineStep: Bool) -> Int {
        let detents = fineStep ? fineDetents : coarseDetents
        let stepSize = 100.0 / detents

        let index = (Double(current) / stepSize).rounded()
        let moved = min(max(index + (up ? 1 : -1), 0), detents)

        return Int((moved * stepSize).rounded())
    }
}

// MARK: - The decision

/// What the interceptor should do about one event it saw.
public enum VolumeKeyOutcome: Equatable, Sendable {
    /// Hand the event straight back to macOS untouched. Everything that is not a
    /// volume key while we own volume takes this path.
    case passThrough
    /// Swallow the event so macOS never sees it (this is what suppresses the
    /// crossed-out HUD), and perform `action` — or nothing at all, for the key-up
    /// half of a press we already acted on.
    case consume(VolumeKeyAction?)
}

/// The app-level effect of an intercepted volume key. Deliberately expressed in
/// the app's own terms, not Core Audio's — nothing here writes hardware, because
/// the whole point is that the default output cannot take a volume write.
public enum VolumeKeyAction: Equatable, Sendable {
    /// Drive Main Out to this level via
    /// ``GroupController/applyExternalSystemVolume(_:)``.
    case setMainVolume(Int)
    /// Flip ``GroupController/isMainOutMuted``.
    case toggleMainMute
}

/// The whole interceptor decision, as one pure function.
public enum VolumeKeyDecision {

    /// - Parameters:
    ///   - data1: the systemDefined event's `data1`.
    ///   - modifierFlags: its raw modifier flags.
    ///   - weOwnVolume: ``VolumeOwnership/weOwnVolume(defaultOutputUID:systemOutputVolume:)``.
    ///   - currentMainVolume: ``GroupController/mainOutMasterVolume``.
    ///
    /// When `weOwnVolume` is false this ALWAYS passes through. That is not a
    /// nicety: on a normal output macOS moves the system volume itself and the
    /// existing `SystemOutputVolume` listener already carries the change into
    /// Main. Acting here too would move Main twice per press.
    public static func decide(
        data1: Int,
        modifierFlags: UInt,
        weOwnVolume: Bool,
        currentMainVolume: Int
    ) -> VolumeKeyOutcome {
        guard weOwnVolume, let press = AuxKeyPress.decode(data1: data1) else {
            return .passThrough
        }

        // Consume both halves of a press. Passing the up through after swallowing
        // the down would leave downstream listeners seeing an unpaired release.
        guard press.isDown else { return .consume(nil) }

        switch press.key {
        case .mute:
            // Auto-repeat on mute would flap it on and off while held.
            return .consume(press.isRepeat ? nil : .toggleMainMute)
        case .soundUp, .soundDown:
            let target = VolumeStep.next(
                from: currentMainVolume,
                up: press.key == .soundUp,
                fineStep: AuxModifierFlags.isFineStep(modifierFlags)
            )
            // Already at an end stop — still consume (macOS would show the
            // crossed-out HUD), but don't churn a no-op write down the chain.
            return .consume(target == currentMainVolume ? nil : .setMainVolume(target))
        }
    }
}
