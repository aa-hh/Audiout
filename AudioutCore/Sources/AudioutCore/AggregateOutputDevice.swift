// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import CoreAudio

// MARK: - Public aggregate device (Wave 3, T1)
//
// Lifecycle owner for a PUBLIC (system-visible, `kAudioAggregateDeviceIsPrivateKey:
// false`) aggregate device named "Audiout" that appears in System Settings ›
// Sound so the app can be selected as a normal-looking output. This is
// DELIBERATELY DISTINCT from the PRIVATE tap-capture aggregate
// ``NativeCaptureCoordinator/createAggregate()`` builds per whole-system tap —
// that one is never enumerated by the user and exists only to host a process
// tap. Do not conflate the two; they have different UIDs, different
// `IsPrivateKey` values, and different lifetimes.
//
// Validated against the spike (`dev/spikes/aggregate-device/SPIKE-REPORT.md` +
// `aggtool.swift`, worktree `agent-ae99ad2727f8097a1`): create/adopt/destroy/
// enumerate all measured live, `AudioObjectID` proven UNSTABLE across resolves
// (id 146 at create, 107 on every later resolve of the same UID) — hence the
// "never cache the id" rule below.
//
// Scope (razor): this file is JUST the owner type + pure decision core + shell
// + orphan sweep. It does NOT set the aggregate as default output, does NOT
// wire into `NativeBackend`/`AppDelegate`, does NOT touch the capture path
// (that's A1 in the spike report — resolving THROUGH the aggregate to its
// real sub-device before a tap pins to it) or UI. Those are separate tasks.
// razor: no volume/mute surface here — the aggregate publishes none (spike
// §6, A2, unfixable at this layer); a future volume-key interceptor will gate
// on `AggregateOutputDevice.productUID`, not duplicate this file.

/// What a new system default-output UID (or its absence) means for our
/// aggregate's "off switch" — i.e. did the user turn Audiout off, or did its
/// underlying device disappear? Consumed by the (separate) task that wires
/// this into `SystemOutputVolume`'s existing default-device-changed listener
/// (spike §5: that listener already fires for any default-output change,
/// including ours).
enum AggregateOffSwitchOutcome: Equatable, Sendable {
    /// The new default output IS still our aggregate — nothing changed.
    case stillOurs
    /// The new default output resolves to some other real device — the user
    /// picked something else in Sound settings.
    case userDeselected
    /// The new default output is unreadable/unknown (`nil` UID) — its device
    /// vanished (e.g. unplugged) rather than being deliberately deselected.
    case deviceVanished
}

/// The Core Audio operations ``AggregateOutputDevice``'s decision core needs,
/// behind a protocol so adopt-vs-create/off-switch classification/orphan-sweep
/// are unit-testable with a fake — same reason `SystemDefaultOutputControlling`
/// and `SystemVolumeControlling` exist. **No fake may ever touch the real HAL.**
protocol AggregateDeviceControlling: Sendable {
    /// Resolve `uid` to its CURRENT `AudioObjectID`, or `nil` if no such device
    /// is enumerated right now. Callers must call this fresh every time — never
    /// cache the result (measured unstable across creator-process exit).
    func resolveDeviceID(forUID uid: String) -> AudioObjectID?
    /// Create a new PUBLIC aggregate named `name`/UID `uid` wrapping
    /// `subDeviceUID` as its sole (and therefore main/clock) sub-device.
    /// Returns the new device's id, or `nil` on failure.
    func createAggregate(uid: String, name: String, subDeviceUID: String) -> AudioObjectID?
    /// Destroy the aggregate device with this id. `true` on `noErr`.
    func destroyAggregate(_ deviceID: AudioObjectID) -> Bool
    /// UIDs of every aggregate-class device the HAL currently enumerates
    /// (public and private) — the enumeration half of the orphan sweep.
    func aggregateDeviceUIDs() -> [String]
    /// Read a device's own persistent UID string, or `nil` if unreadable.
    func deviceUID(_ deviceID: AudioObjectID) -> String?
    /// The Mac's built-in output device's UID (the sub-device our aggregate
    /// wraps), or `nil` if the Mac publishes none.
    func builtInOutputDeviceUID() -> String?
    /// Point the system default output at `deviceID`. `false` if nothing was
    /// written.
    func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool
}

/// Owns the lifecycle (adopt-or-create, off-switch classification, orphan
/// cleanup) of the public "Audiout" aggregate device. Pure decision logic;
/// all actual Core Audio calls go through the injected ``AggregateDeviceControlling``
/// seam, defaulting to ``CoreAudioAggregateDeviceControl`` in production.
public struct AggregateOutputDevice: Sendable {

    /// The shipping build's bundle id, and the aggregate UID derived from it.
    /// LOCKED FOREVER for that build — coreaudiod keys its persisted entry (the
    /// on-disk `com.apple.audio.SystemSettings.plist` `MetaDevice.<uid>` block,
    /// spike §1) by this UID, so changing it orphans every previously-created
    /// entry on every machine that has ever run this app (spike A5).
    static let shippingBundleID = "com.audiout.Audiout"
    static let shippingUID = "com.audiout.Audiout.aggregate"

    /// The UID this COPY of the app owns, derived from its bundle id.
    ///
    /// A side-by-side test build carries its own bundle id (house rule: every
    /// build handed over for testing gets a fresh one, so macOS issues it clean
    /// TCC grants). The aggregate has to follow, because ``sweepOrphans()``
    /// destroys BY UID and runs on teardown: with one hardcoded UID, quitting
    /// any copy tore the system's "Audiout" output device out from under
    /// every other running copy — the device simply vanished from Sound
    /// settings while an app was still open (live-found). Deriving it means two
    /// copies own two devices and neither can sweep the other's.
    ///
    /// The shipping bundle id keeps ``shippingUID`` byte-for-byte, so the
    /// installed app adopts its existing persisted entry exactly as before.
    public static var productUID: String { productUID(forBundleID: Bundle.main.bundleIdentifier) }

    /// The pure derivation behind ``productUID``. A `nil` bundle id (a bare
    /// `swift run` of the executable, or a test host) is treated as the
    /// shipping app: it IS the same app, just unbundled.
    static func productUID(forBundleID bundleID: String?) -> String {
        let id = bundleID ?? shippingBundleID
        return id == shippingBundleID ? shippingUID : "\(id).aggregate"
    }

    /// Rendered name of the public aggregate in Sound settings, Audio MIDI
    /// Setup, and `system_profiler` (spike §1, §6 — both read the same
    /// `kAudioObjectPropertyName`). A side build takes its own display name so
    /// two entries in Sound settings are tellable apart; the shipping build
    /// stays "Audiout".
    public static var productName: String {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleIdentifier != shippingBundleID
        else { return "Audiout" }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Audiout"
    }

    /// The spike tool's own aggregate UID (`dev/spikes/aggregate-device/aggtool.swift`).
    /// Alec ran that tool directly on his machines during the spike, so a
    /// lingering `com.audiout.spike.aggregate` entry is a real, not
    /// hypothetical, orphan risk — `sweepOrphans()` destroys it too.
    /// razor: drop this line once the first shipped build has cycled through
    /// Alec's machines (it can only ever match a leftover from the spike, not
    /// anything this app itself creates).
    static let priorSpikeUID = "com.audiout.spike.aggregate"

    private let control: AggregateDeviceControlling

    init(control: AggregateDeviceControlling = CoreAudioAggregateDeviceControl()) {
        self.control = control
    }

    /// Adopt-vs-create (spike §1, §4): resolve `productUID` fresh — a hit
    /// means adopt (reuse the existing device, whatever its current id is,
    /// e.g. surviving a previous launch or a crash); a miss means create a
    /// fresh one wrapping the Mac's current built-in output. Never caches the
    /// returned id past this call's caller — resolve by UID again next time.
    func adoptOrCreate() -> AudioObjectID? {
        if let existing = control.resolveDeviceID(forUID: Self.productUID) {
            return existing
        }
        guard let subDeviceUID = control.builtInOutputDeviceUID() else { return nil }
        return control.createAggregate(uid: Self.productUID, name: Self.productName,
                                        subDeviceUID: subDeviceUID)
    }

    /// Off-switch classification (spike §5): given the new system default
    /// output's UID (`nil` if unresolvable), decide whether the user turned
    /// Audiout off in favor of a real device, or its underlying device just
    /// vanished. Pure string comparison — no HAL access.
    func classifyOffSwitch(newDefaultUID: String?) -> AggregateOffSwitchOutcome {
        guard let newDefaultUID, !newDefaultUID.isEmpty else { return .deviceVanished }
        return newDefaultUID == Self.productUID ? .stillOurs : .userDeselected
    }

    /// Idempotent, race-safe: destroy any currently-enumerated aggregate whose
    /// UID matches `productUID` or `priorSpikeUID`. A destroy-by-UID that finds
    /// nothing (already gone, or a resolve/enumerate race) is a clean no-op —
    /// safe to call repeatedly, e.g. once at every launch. Returns the count
    /// actually destroyed (test/diagnostic visibility only).
    @discardableResult
    func sweepOrphans() -> Int {
        let knownUIDs: Set<String> = [Self.productUID, Self.priorSpikeUID]
        var destroyedCount = 0
        for uid in control.aggregateDeviceUIDs() where knownUIDs.contains(uid) {
            guard let id = control.resolveDeviceID(forUID: uid) else { continue }
            if control.destroyAggregate(id) { destroyedCount += 1 }
        }
        return destroyedCount
    }
}

/// Production ``AggregateDeviceControlling``. Reuses existing helpers rather
/// than re-deriving them: the built-in-output lookup is
/// ``SystemLocalOutputResolver`` (already used by `LocalPlaybackEngine`'s loop
/// guard and `DefaultOutputSwitcher`'s takeover switch-away), and the
/// default-output WRITE is ``CoreAudioDefaultOutputControl`` (`DefaultOutputSwitcher.swift`)
/// — house rule: `kAudioHardwarePropertyDefaultOutputDevice`, NEVER
/// `…DefaultSystemOutputDevice` (`OutputSelectorGuardTests` fails the build on
/// the wrong selector). Only the aggregate create/destroy/enumerate calls are
/// new here, mirrored from the spike's `aggtool.swift` and
/// `NativeCaptureCoordinator.createAggregate()` — same call shapes, `IsPrivateKey`
/// flipped to `false` since this device must be user-visible.
struct CoreAudioAggregateDeviceControl: AggregateDeviceControlling {

    func resolveDeviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID: CFString? = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafePointer(to: &cfUID) { qualifier -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString?>.size), qualifier, &size, &deviceID)
        }
        guard err == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    func createAggregate(uid: String, name: String, subDeviceUID: String) -> AudioObjectID? {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String:          name,
            kAudioAggregateDeviceUIDKey as String:           uid,
            kAudioAggregateDeviceMainSubDeviceKey as String: subDeviceUID,
            // PUBLIC — the whole point of this type, unlike every other
            // aggregate this app creates (all tap-capture aggregates are
            // private; see the file header).
            kAudioAggregateDeviceIsPrivateKey as String:     false,
            kAudioAggregateDeviceIsStackedKey as String:     false,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: subDeviceUID]
            ],
        ]
        var newDeviceID = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)
        guard err == noErr else {
            AudioDiag.log("CoreAudioAggregateDeviceControl.createAggregate AudioHardwareCreateAggregateDevice failed: \(err)")
            return nil
        }
        return newDeviceID
    }

    func destroyAggregate(_ deviceID: AudioObjectID) -> Bool {
        let err = AudioHardwareDestroyAggregateDevice(deviceID)
        if err != noErr {
            AudioDiag.log("CoreAudioAggregateDeviceControl.destroyAggregate AudioHardwareDestroyAggregateDevice failed: \(err)")
        }
        return err == noErr
    }

    func aggregateDeviceUIDs() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> String? in
            guard transportType(deviceID) == kAudioDeviceTransportTypeAggregate else { return nil }
            return deviceUID(deviceID)
        }
    }

    func deviceUID(_ deviceID: AudioObjectID) -> String? {
        // Not reused from `CoreAudioSystemTap.readDeviceUID` (same read, same
        // shape): that type is gated `@available(macOS 14.2, *)` for its tap
        // machinery, which would drag an unrelated availability floor onto
        // this file. This is the same three lines the guarded helper does.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let err = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let uid else { return nil }
        return uid as String
    }

    func builtInOutputDeviceUID() -> String? {
        guard let builtIn = SystemLocalOutputResolver().builtInOutputDevice() else { return nil }
        return deviceUID(AudioObjectID(builtIn))
    }

    func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool {
        CoreAudioDefaultOutputControl().setDefaultOutputDevice(UInt32(deviceID))
    }

    private func transportType(_ deviceID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
