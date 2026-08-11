import Foundation
// `AudioObject*` (AudioHardware.h) lives in CoreAudio; the
// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` ('vmvc') selector
// lives in AudioToolbox (AudioHardwareService.h). Both are used here, so both
// are imported explicitly rather than leaning on AudioToolbox's transitive
// re-export of CoreAudio (which is what NativeBackend.swift relies on).
import CoreAudio
import AudioToolbox

/// Read/write the volume + mute of whatever the user's **system default output
/// device** currently is, and report changes made outside this app.
///
/// This is the seam behind the "current device" row (`Device.isLocalDevice`,
/// id `NativeBackend.localDeviceID`). That row is not an engine output — the Mac
/// itself is the thing *sending* audio — so `NativeBackend.setVolume` has no
/// `outputIDs[id]` entry for it and no-ops. Driving the Core Audio default output
/// device directly is what makes that row's slider and mute do something.
///
/// A protocol (rather than a concrete type) so the row's control logic can be
/// unit-tested against a fake with no audio hardware in the loop — the same
/// reason `ConnectionDiagnosing` exists.
public protocol SystemVolumeControlling: Sendable {
    /// Current output volume as 0–100, or `nil` when the device exposes no
    /// readable volume control (many aggregate + digital/HDMI outputs).
    func currentVolume() -> Int?

    /// Current mute state, or `nil` when the device exposes no readable mute
    /// control.
    func currentMuted() -> Bool?

    /// Set the output volume (0–100, clamped). No-ops when the device has no
    /// settable volume control.
    ///
    /// `didWrite` reports whether anything actually reached the hardware, because
    /// "no settable control" is invisible otherwise and callers memoise the value
    /// they *asked* for. A readable-but-UNWRITABLE output (some USB DACs) accepts
    /// the call, changes nothing, and leaves a caller believing the system sits at
    /// a level it never reached — so a later genuine external change back *to* that
    /// level compares equal to the stale memo and is silently dropped. Fires on the
    /// implementation's own queue, before any notification that write provoked.
    func setVolume(_ volume: Int, didWrite: (@Sendable (Bool) -> Void)?)

    /// Set the mute state. Silently no-ops when the device has no settable mute
    /// control.
    func setMuted(_ muted: Bool)

    /// Fired when volume/mute changed **outside this app** (the user hit the
    /// media keys, moved the Sound menu slider, …) or when the default output
    /// device itself switched (speakers → AirPods), which usually means a
    /// wholly different volume/mute pair is now in force.
    ///
    /// Both values are fresh reads of the *current* default device; either is
    /// `nil` when that control is unreadable (see ``currentVolume()``). Echoes of
    /// this object's own ``setVolume(_:)``/``setMuted(_:)`` writes are suppressed,
    /// so a UI can drive the slider from this without a feedback loop.
    ///
    /// `defaultDeviceChanged` separates the two reasons above, and a caller that
    /// acts on the *value* rather than just displaying it MUST NOT conflate them:
    ///
    /// - `false` — the user made a volume/mute gesture on the device that was
    ///   already the default. A real intent about the level.
    /// - `true` — the default output device itself switched. The reported pair is
    ///   a *different device's* pre-existing state; nobody expressed any intent
    ///   about a level. Only the fact that the device changed is news.
    ///
    /// The volume-key path (``BackendEvent/systemVolumeChanged(volume:)`` →
    /// `GroupController.applyExternalSystemVolume(_:)`) acts only on the first:
    /// treating a headphone plug as a gesture would slam every AirPlay speaker to
    /// whatever the headphones happened to be set to. Displaying the row can and
    /// does use both.
    ///
    /// Called on a private serial queue, **not** the main queue — hop yourself.
    var onExternalChange: (@Sendable (_ volume: Int?, _ muted: Bool?, _ defaultDeviceChanged: Bool) -> Void)? { get set }

    /// Begin observing. Idempotent.
    func start()

    /// Stop observing and remove every listener. Idempotent.
    func stop()
}

public extension SystemVolumeControlling {
    /// Fire-and-forget write, for the callers that have nothing to memoise and so
    /// don't care whether the hardware took it.
    func setVolume(_ volume: Int) { setVolume(volume, didWrite: nil) }
}

/// ``SystemVolumeControlling`` over Core Audio's default output device.
///
/// ## Why this can't just talk to one device id
///
/// The default output device is a moving target: `kAudioHardwarePropertyDefaultOutputDevice`
/// changes whenever the user picks a different output. So this type listens on
/// *two* levels — the system object (for "the default device changed") and the
/// current device (for "its volume/mute changed") — and **re-targets** the second
/// set whenever the first fires. Add/remove symmetry across that re-target is the
/// whole ballgame; see ``retarget(to:)``.
///
/// ## Every write is guarded
///
/// Not every output has every control. Aggregate devices, many HDMI/digital
/// outputs, and some USB DACs expose no main volume, no per-channel volume, or no
/// mute at all. Every read is guarded by `AudioObjectHasProperty` and every write
/// additionally by `AudioObjectIsPropertySettable`, so an unsupported output
/// no-ops instead of trapping. Reads return `nil` rather than a fabricated 0 —
/// "unreadable" and "silent" are different facts, and the UI renders them
/// differently.
///
/// ## Concurrency
///
/// Mutable state (listener registrations, the last-known volume/mute) is touched only
/// on the private serial ``queue``; `@unchecked Sendable` is honest because of
/// that discipline, not a workaround — the same contract `MockBackend`/
/// `NativeBackend` keep. Listener blocks are dispatched *by the HAL onto that same
/// queue*, so callbacks are already serialized against writes and never run on a
/// HAL-internal thread (AudioHardware.h: blocks are dispatched asynchronously
/// except from the IO context, which none of these selectors are).
///
/// ``currentVolume()``/``currentMuted()`` are lock-free: they resolve the default
/// device themselves and hit the HAL directly, so they can't deadlock against an
/// in-flight write and are safe to call from the main queue during a layout pass.
public final class SystemOutputVolume: SystemVolumeControlling, @unchecked Sendable {

    // MARK: Pure conversions (unit-testable, no hardware)

    /// Core Audio scalar (0.0–1.0) → 0–100.
    ///
    /// Guards non-finite input: a misbehaving driver can hand back NaN, and
    /// `Int(Float.nan)` **traps** in Swift. This type must never crash whatever
    /// the hardware, so NaN/±inf floor to 0.
    static func volumeInt(fromScalar scalar: Float) -> Int {
        guard scalar.isFinite else { return 0 }
        let bounded = Swift.min(1, Swift.max(0, scalar))
        return Int((bounded * 100).rounded()).clampedToVolume
    }

    /// 0–100 → Core Audio scalar (0.0–1.0). Input is clamped via the same
    /// `Int.clampedToVolume` every other volume path uses (Device.swift).
    static func scalar(fromVolumeInt volume: Int) -> Float {
        Float(volume.clampedToVolume) / 100
    }

    // MARK: State

    /// Serial queue owning every mutable field below, and the queue the HAL
    /// dispatches listener blocks onto.
    private let queue = DispatchQueue(label: "com.audiouter.system-output-volume")

    /// One registration we made and must symmetrically undo. Storing the exact
    /// `(object, address)` we passed to `AudioObjectAddPropertyListenerBlock` —
    /// rather than recomputing candidates at removal time — is what makes
    /// add/remove symmetry structural instead of a thing to get right twice.
    private struct Registration {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
    }

    private var isStarted = false

    /// Registrations on the *current* default device (volume + mute, however many
    /// addresses that took), and the single block they all share.
    private var deviceRegistrations: [Registration] = []
    private var deviceBlock: AudioObjectPropertyListenerBlock?

    /// Registration on the system object for "default output device changed".
    private var defaultDeviceRegistration: Registration?
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?

    /// The volume/mute this object believes are already in force *and already
    /// known to the caller* — updated both when we write and when we report.
    /// A notification matching these is not news and is dropped. See
    /// ``handleDeviceChangeLocked()``.
    private var lastKnownVolume: Int?
    private var lastKnownMuted: Bool?

    /// `onExternalChange` is guarded by its own lock rather than ``queue``:
    /// listener blocks run *on* `queue`, so a `queue.sync` getter would deadlock
    /// the moment a callback tried to read it.
    private let callbackLock = NSLock()
    private var _onExternalChange: (@Sendable (Int?, Bool?, Bool) -> Void)?

    public var onExternalChange: (@Sendable (Int?, Bool?, Bool) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _onExternalChange
        }
        set {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            _onExternalChange = newValue
        }
    }

    public init() {}

    deinit {
        // Best-effort teardown for a caller who dropped us without `stop()`.
        // Deliberately NOT `queue.sync` — if the last reference were released on
        // `queue` itself that would deadlock. Touching the fields directly is safe
        // here precisely because every listener block captures `self` weakly: a
        // block that is mid-flight holds a strong reference, so `deinit` cannot be
        // running concurrently with one, and a block that fires afterwards sees a
        // nil weak reference and no-ops.
        removeDeviceListenersLocked()
        removeDefaultDeviceListenerLocked()
    }

    // MARK: Property addresses

    private static let defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
    }

    private static func muteAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
    }

    /// The 'vmvc' virtual-main-volume selector. Its *functions*
    /// (`AudioHardwareServiceGetPropertyData`) are long deprecated, but the
    /// selector is not — the modern spelling is to hand it straight to
    /// `AudioObjectGetPropertyData` on the device, which the HAL serves. It's the
    /// last-resort fallback because it's the most forgiving: on a device with only
    /// per-channel controls it drives them as a set *and preserves their relative
    /// balance* (AudioHardwareService.h), which raw per-channel writes do not.
    private static let virtualMainVolumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    // MARK: Device resolution

    /// The system default output device, or `kAudioObjectUnknown`.
    ///
    /// Resolved fresh on every call rather than cached: it's a single cheap HAL
    /// property read (the same one `NativeBackend.currentOutputDeviceName()`
    /// does), and resolving on demand keeps the public reads
    /// lock-free and correct even before ``start()``.
    private static func currentDefaultOutputDevice() -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultOutputDeviceAddress
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard err == noErr else { return AudioObjectID(kAudioObjectUnknown) }
        return deviceID
    }

    /// The device's preferred stereo pair, used for the per-channel fallback.
    /// Defaults to channels 1/2, which is what virtually every stereo output uses.
    private static func preferredStereoChannels(_ deviceID: AudioObjectID) -> [AudioObjectPropertyElement] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var channels: (UInt32, UInt32) = (1, 2)
        var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        guard AudioObjectHasProperty(deviceID, &address) else { return [1, 2] }
        let err = withUnsafeMutablePointer(to: &channels) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { return [1, 2] }
        return [channels.0, channels.1]
    }

    // MARK: Primitive get/set (every one guarded)

    private static func readFloat(_ deviceID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float? {
        var address = address
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard err == noErr else { return nil }
        return value
    }

    private static func readUInt32(_ deviceID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard err == noErr else { return nil }
        return value
    }

    /// `true` only if the property exists *and* the HAL says it's settable.
    /// Checking both is the difference between a no-op and a `kAudioHardwareUnknownPropertyError`
    /// (or worse) on outputs that publish a read-only volume — e.g. HDMI/digital
    /// outs that report a level they won't let you change.
    private static func isWritable(_ deviceID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        let err = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        guard err == noErr else { return false }
        return settable.boolValue
    }

    @discardableResult
    private static func writeFloat(_ deviceID: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: Float) -> Bool {
        guard isWritable(deviceID, address) else { return false }
        var address = address
        var value: Float32 = value
        let err = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        return err == noErr
    }

    @discardableResult
    private static func writeUInt32(_ deviceID: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: UInt32) -> Bool {
        guard isWritable(deviceID, address) else { return false }
        var address = address
        var value: UInt32 = value
        let err = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        return err == noErr
    }

    // MARK: Reads

    public func currentVolume() -> Int? {
        let deviceID = Self.currentDefaultOutputDevice()
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return Self.readVolume(deviceID)
    }

    public func currentMuted() -> Bool? {
        let deviceID = Self.currentDefaultOutputDevice()
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return Self.readMuted(deviceID)
    }

    /// Read order (mirrored exactly by ``writeVolume(_:to:)``): main element →
    /// per-channel average → virtual main. Main element is the common case;
    /// per-channel catches devices that only publish per-channel controls;
    /// 'vmvc' catches the rest.
    private static func readVolume(_ deviceID: AudioObjectID) -> Int? {
        if let scalar = readFloat(deviceID, volumeAddress(element: kAudioObjectPropertyElementMain)) {
            return volumeInt(fromScalar: scalar)
        }
        let channelScalars = preferredStereoChannels(deviceID).compactMap {
            readFloat(deviceID, volumeAddress(element: $0))
        }
        if !channelScalars.isEmpty {
            // Average the pair so a balance-shifted device reports one sane number.
            let mean = channelScalars.reduce(0, +) / Float(channelScalars.count)
            return volumeInt(fromScalar: mean)
        }
        if let scalar = readFloat(deviceID, virtualMainVolumeAddress) {
            return volumeInt(fromScalar: scalar)
        }
        return nil
    }

    private static func readMuted(_ deviceID: AudioObjectID) -> Bool? {
        if let value = readUInt32(deviceID, muteAddress(element: kAudioObjectPropertyElementMain)) {
            return value != 0
        }
        // Some outputs publish mute only per-channel; treat "any channel muted" as
        // muted, matching how the per-channel volume fallback reads as one control.
        let channelValues = preferredStereoChannels(deviceID).compactMap {
            readUInt32(deviceID, muteAddress(element: $0))
        }
        guard !channelValues.isEmpty else { return nil }
        return channelValues.contains { $0 != 0 }
    }

    // MARK: Writes (serialized on `queue`)

    public func setVolume(_ volume: Int, didWrite: (@Sendable (Bool) -> Void)?) {
        let clamped = volume.clampedToVolume
        queue.async {
            let deviceID = Self.currentDefaultOutputDevice()
            guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
                didWrite?(false)
                return
            }
            // Record the intended value before writing: the notifications this
            // write provokes are dispatched to this same serial queue, so they
            // cannot be observed before `lastKnownVolume` is in place.
            self.lastKnownVolume = clamped
            let wrote = Self.writeVolume(clamped, to: deviceID)
            if !wrote {
                // Nothing was written (read-only/absent control), so the system is
                // NOT at `clamped`. Re-seed from the hardware — leaving the wishful
                // value here would make us mistake a later genuine external change
                // *to that value* for an echo and swallow it.
                self.lastKnownVolume = Self.readVolume(deviceID)
            }
            // Still on `queue`, so this lands before any notification the write
            // provoked — a caller memoising on success can't be overtaken by the
            // echo of the very write it's waiting on.
            didWrite?(wrote)
        }
    }

    public func setMuted(_ muted: Bool) {
        queue.async {
            let deviceID = Self.currentDefaultOutputDevice()
            guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
            self.lastKnownMuted = muted
            if !Self.writeMuted(muted, to: deviceID) {
                self.lastKnownMuted = Self.readMuted(deviceID)
            }
        }
    }

    /// Returns `true` if *something* was actually written.
    private static func writeVolume(_ volume: Int, to deviceID: AudioObjectID) -> Bool {
        let scalar = scalar(fromVolumeInt: volume)
        if writeFloat(deviceID, volumeAddress(element: kAudioObjectPropertyElementMain), scalar) {
            return true
        }
        // Per-channel: write the pair to the same level. This flattens any custom
        // balance — the documented trade-off of this tier. ('vmvc' below would
        // preserve balance, but it's the weaker fallback: it isn't published by
        // every device, so it can't be tried first.)
        var wroteAnyChannel = false
        for channel in preferredStereoChannels(deviceID) {
            if writeFloat(deviceID, volumeAddress(element: channel), scalar) {
                wroteAnyChannel = true
            }
        }
        if wroteAnyChannel { return true }
        return writeFloat(deviceID, virtualMainVolumeAddress, scalar)
    }

    private static func writeMuted(_ muted: Bool, to deviceID: AudioObjectID) -> Bool {
        let value: UInt32 = muted ? 1 : 0
        if writeUInt32(deviceID, muteAddress(element: kAudioObjectPropertyElementMain), value) {
            return true
        }
        var wroteAnyChannel = false
        for channel in preferredStereoChannels(deviceID) {
            if writeUInt32(deviceID, muteAddress(element: channel), value) {
                wroteAnyChannel = true
            }
        }
        return wroteAnyChannel
    }

    // MARK: Listener lifecycle

    public func start() {
        queue.sync {
            guard !isStarted else { return }   // no double-add
            isStarted = true
            installDefaultDeviceListenerLocked()
            // `report: false` — starting up is not a change; the caller reads the
            // initial state with `currentVolume()`/`currentMuted()`.
            retargetLocked(to: Self.currentDefaultOutputDevice(), report: false)
        }
    }

    public func stop() {
        queue.sync {
            guard isStarted else { return }
            isStarted = false
            removeDeviceListenersLocked()
            removeDefaultDeviceListenerLocked()
            lastKnownVolume = nil
            lastKnownMuted = nil
        }
    }

    /// Point the volume/mute listeners at `deviceID`, tearing down whatever the
    /// previous device had. The single funnel for re-targeting — `start()` and the
    /// default-device notification both go through here, so there is exactly one
    /// place where add/remove symmetry has to hold.
    ///
    /// `report: true` fires ``onExternalChange`` unconditionally, even if the new
    /// device's numbers happen to equal the old one's: the device *itself* changing
    /// is the news, and the caller needs the fresh pair regardless.
    ///
    /// Every fire from here carries `defaultDeviceChanged: true`, and that is exact
    /// rather than approximate: the only caller that passes `report: true` is the
    /// default-device listener, so a report from here always IS a device switch
    /// (`start()`, the other caller, passes `report: false` — coming up is not a
    /// change). That is what lets a caller act on a volume gesture without also
    /// acting on a headphone plug; see ``onExternalChange``.
    private func retargetLocked(to deviceID: AudioObjectID, report: Bool) {
        removeDeviceListenersLocked()
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            lastKnownVolume = nil
            lastKnownMuted = nil
            if report { fire(volume: nil, muted: nil, defaultDeviceChanged: true) }
            return
        }
        addDeviceListenersLocked(deviceID)
        // Seed from the new device before any of its notifications can land, so the
        // first genuine change is measured against *its* state and not the old
        // device's.
        lastKnownVolume = Self.readVolume(deviceID)
        lastKnownMuted = Self.readMuted(deviceID)
        if report { fire(volume: lastKnownVolume, muted: lastKnownMuted, defaultDeviceChanged: true) }
    }

    private func addDeviceListenersLocked(_ deviceID: AudioObjectID) {
        // Belt and braces. Every caller funnels through `retargetLocked`, which
        // already removed — so this is a no-op on the expected path. It is here
        // rather than a `precondition` because Swift preconditions are live in
        // release builds, and a menu-bar app should repair a bookkeeping slip
        // (leaked registrations that would otherwise never be removed), not die
        // over one.
        removeDeviceListenersLocked()

        // One block for every address. It deliberately ignores *which* address
        // fired and just re-reads both controls: a single logical change fans out
        // across the addresses below (writing the main element propagates to the
        // channel elements and to 'vmvc'), so the selector carries far less signal
        // than a fresh read of the actual state does.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Already on `queue` — the HAL dispatches here (see the type's
            // concurrency note), so no hop and no `sync` (which would deadlock).
            self?.handleDeviceChangeLocked()
        }
        deviceBlock = block

        // Only register where the property actually exists: registering on an
        // absent property errors, and a registration that never took must not end
        // up in `deviceRegistrations` or removal would go asymmetric.
        var candidates: [AudioObjectPropertyAddress] = [
            Self.volumeAddress(element: kAudioObjectPropertyElementMain),
            Self.muteAddress(element: kAudioObjectPropertyElementMain),
            Self.virtualMainVolumeAddress,
        ]
        for channel in Self.preferredStereoChannels(deviceID) {
            candidates.append(Self.volumeAddress(element: channel))
            candidates.append(Self.muteAddress(element: channel))
        }

        var seen = Set<AddressKey>()
        for address in candidates {
            // Dedupe: `preferredStereoChannels` can legitimately report the main
            // element, which would otherwise double-add the same registration.
            guard seen.insert(AddressKey(address)).inserted else { continue }
            var address = address
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            let err = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
            guard err == noErr else { continue }
            deviceRegistrations.append(Registration(objectID: deviceID, address: address))
        }
    }

    private func removeDeviceListenersLocked() {
        guard let block = deviceBlock else { return }
        for registration in deviceRegistrations {
            var address = registration.address
            let status = AudioObjectRemovePropertyListenerBlock(registration.objectID, &address, queue, block)
            if status != noErr {
                AudioDiag.log("SystemOutputVolume.removeDeviceListenersLocked AudioObjectRemovePropertyListenerBlock failed for object \(registration.objectID): \(status)")
            }
        }
        deviceRegistrations = []
        deviceBlock = nil
    }

    private func installDefaultDeviceListenerLocked() {
        guard defaultDeviceBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isStarted else { return }
            // A different device is in force now — re-point the volume/mute
            // listeners at it and report its state (`report: true`).
            self.retargetLocked(to: Self.currentDefaultOutputDevice(), report: true)
        }
        var address = Self.defaultOutputDeviceAddress
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        guard err == noErr else { return }
        defaultDeviceBlock = block
        defaultDeviceRegistration = Registration(
            objectID: AudioObjectID(kAudioObjectSystemObject), address: address)
    }

    private func removeDefaultDeviceListenerLocked() {
        guard let block = defaultDeviceBlock, let registration = defaultDeviceRegistration else { return }
        var address = registration.address
        let status = AudioObjectRemovePropertyListenerBlock(registration.objectID, &address, queue, block)
        if status != noErr {
            AudioDiag.log("SystemOutputVolume.removeDefaultDeviceListenerLocked AudioObjectRemovePropertyListenerBlock failed: \(status)")
        }
        defaultDeviceBlock = nil
        defaultDeviceRegistration = nil
    }

    // MARK: Change handling

    /// Decide whether a device notification is news, and report it if so.
    ///
    /// Echo suppression is **state-based, not event-based**: a notification is
    /// reported only when the freshly-read state differs from ``lastKnownVolume``/
    /// ``lastKnownMuted``, which both our own writes and our own reports keep up to
    /// date. This is the same "no-op changes must not emit" contract `MockBackend`
    /// keeps (`MockBackend.mutate`), applied to the hardware.
    ///
    /// It has to work this way. An event-based token (arm on write, consume on the
    /// next notification) does not survive contact with the HAL: one logical change
    /// fans out into a *burst* of notifications, because we listen on the main
    /// element, both channel elements and 'vmvc', and a change to any one of them
    /// propagates to the others. Measured: a single `setVolume` produced 16
    /// callbacks. A consume-once token is eaten by the first, and the other 15 then
    /// look external. Comparing against state is immune to the burst — every
    /// notification in it reads the same value, so the first reports and the rest
    /// are silent.
    ///
    /// The apparent hole — an external change *to* the value we last wrote is
    /// indistinguishable from our echo — is not reachable. If the system already
    /// sits at that value, setting it again changes nothing and the HAL sends no
    /// notification, so there is nothing to miss. Any real external change must
    /// move the value away from `lastKnown`, which mismatches and reports.
    ///
    /// Fires with `defaultDeviceChanged: false`: reaching here means a property on
    /// the device that was ALREADY the default moved, i.e. somebody made a gesture.
    /// A switch of the default device itself never lands here — it lands on the
    /// system-object listener and goes through ``retargetLocked(to:report:)``.
    private func handleDeviceChangeLocked() {
        let volume = currentVolume()
        let muted = currentMuted()
        guard volume != lastKnownVolume || muted != lastKnownMuted else { return }
        lastKnownVolume = volume
        lastKnownMuted = muted
        fire(volume: volume, muted: muted, defaultDeviceChanged: false)
    }

    /// Snapshot the callback under the lock but invoke it *outside* — a handler
    /// that re-entered `onExternalChange`'s setter would otherwise deadlock.
    private func fire(volume: Int?, muted: Bool?, defaultDeviceChanged: Bool) {
        callbackLock.lock()
        let handler = _onExternalChange
        callbackLock.unlock()
        handler?(volume, muted, defaultDeviceChanged)
    }
}

/// `AudioObjectPropertyAddress` is a C struct and not `Hashable`; this is just
/// enough of a key to dedupe a registration candidate list.
private struct AddressKey: Hashable {
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement

    init(_ address: AudioObjectPropertyAddress) {
        self.selector = address.mSelector
        self.scope = address.mScope
        self.element = address.mElement
    }
}
