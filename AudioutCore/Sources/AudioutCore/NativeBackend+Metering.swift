import Foundation
import AudioToolbox
import AirPlayEngine
import CastSender

extension NativeBackend {

    // MARK: MeteringControlling (T-GATE / T3) + level coalescing (D3)

    /// Record one whole-system-tap RMS sample. Runs on the tap's IOProc delivery
    /// thread, so it does exactly three things and none of them may block: no
    /// allocation, no unbounded lock, no dispatch enqueue. A contended `try()`
    /// DROPS the sample — the next buffer (~8 ms) refreshes it, and the meter
    /// reads at 25 Hz anyway, so a dropped sample is invisible.
    func noteSystemRMS(_ rms: Float) {   // IOProc delivery thread
        guard systemRMSLock.try() else { return }
        systemRMSSlot = rms
        systemRMSDirty = true
        systemRMSLock.unlock()
    }

    /// Flip the popover-visibility metering gate. Forwards to EVERY RMS
    /// source — the whole-system `captureCoordinator`, the `routeMixer`
    /// (`.device` per-app meter), the `leveledInjector` (a leveled app while the
    /// whole-system capture runs), and the `localPlaybackEngine`
    /// (`.currentDevice`, and a leveled app while it doesn't) — and drives the
    /// metering-only tap lifecycle (the
    /// `.noRedirect` per-app meter): on `true`, start a dedicated `.unmuted` tap
    /// for every currently-eligible listed app; on `false`, stop them all.
    /// `PopoverController` calls this on `surfaceDidShow`/`surfaceDidHide` via
    /// `backend as? MeteringControlling`. The `?` sub-components are `nil` in
    /// tests / the UI-only smoke path (harmless no-ops).
    public func setMeteringActive(_ active: Bool) {
        captureCoordinator?.setMeteringActive(active)
        routeMixer.setMeteringActive(active)
        leveledInjector.setMeteringActive(active)
        localPlaybackEngine?.setMeteringActive(active)
        let diff: (start: Set<String>, stop: Set<String>) = stateQueue.sync {
            self.meteringActive = active
            if active {
                // A sample stored while the popover was closed is stale — it must
                // not replay as the first frame on reopen.
                self.systemRMSLock.lock()
                self.systemRMSDirty = false
                self.systemRMSLock.unlock()
                self.scheduleSystemRMSDrainLocked()
            }
            // When inactive the drain chain stops itself on its next fire.
            return self.meteringTapDiffLocked()
        }
        applyMeteringTapDiff(diff)
    }

    // MARK: Synced local sink (T-FANOUT / "play everywhere")

    /// Attach (or detach, with `nil`) the delayed local sink used in "play
    /// everywhere" mode (T-FANOUT). The whole-system tap fans the SAME captured
    /// audio it sends the AirPlay engine to this sink, which plays a PTP-delayed
    /// copy on the Mac's own speakers phase-aligned with the receivers.
    ///
    /// CRITICAL (R2 / brief §8): the sink renders through THIS app's own
    /// `AVAudioEngine`, so the whole-system tap attributes its output to our
    /// process. We hand the coordinator our own pid (`getpid()`) as the
    /// render-process identity to EXCLUDE from the tap — otherwise the tap
    /// re-captures the delayed output and "play everywhere" becomes "play
    /// everywhere, with a delayed echo of itself." Because the tap is
    /// `.mutedWhenTapped`, excluding our process also leaves the delayed output
    /// audible while the raw system mix stays muted — exactly the intent.
    ///
    /// T-BACKEND drives WHEN this is called (the selection includes the Mac plus
    /// ≥1 AirPlay device); this method just wires the sink + self-exclude through
    /// the capture seam. No-op when no real capture coordinator is wired
    /// (tests / UI-only smoke).
    public func attachSyncedLocalSink(_ sink: SyncedLocalPCMSink?) {
        let renderProcessPID: pid_t? = (sink == nil) ? nil : getpid()
        captureCoordinator?.setSyncedLocalSink(sink, renderProcessPID: renderProcessPID)
    }

    // MARK: Metering-only tap reconcile (T3, `.noRedirect` source)

    /// Compute the metering-only tap start/stop diff and COMMIT the new target set
    /// (`meteringTapTargets`). MUST be called on `stateQueue`.
    ///
    /// Metering-only taps exist ONLY for apps in the Applications list
    /// (`lastRoutes`) that have no other capture — not `.device`-routed (level
    /// comes from the mixer), not `.currentDevice` (from local playback), not
    /// LEVELED (from the injector, or from local playback while the whole-system
    /// capture is off), not user-excluded (PRIVACY: never metered) — and ONLY
    /// while a meter is shown
    /// (`meteringActive`). When metering is off the desired set is empty, so this
    /// also STOPS every metering-only tap.
    func meteringTapDiffLocked() -> (start: Set<String>, stop: Set<String>) {
        let desired: Set<String> = meteringActive
            ? Set(lastRoutes.map(\.bundleID))
                .subtracting(routedBundleIDs)
                .subtracting(localBundleIDs)
                .subtracting(leveledBundleIDs)
                .subtracting(lastExcludedBundleIDs)
            : []
        let current = meteringTapTargets
        meteringTapTargets = desired
        return (start: desired.subtracting(current), stop: current.subtracting(desired))
    }

    /// Execute a metering-only tap diff on `captureControlQueue` (off `stateQueue`
    /// — a tap start/stop may block on Core Audio), stop-before-start. A no-op when
    /// empty. Used by `setMeteringActive`; `updateAppRoutes` inlines the same ops
    /// into its own `captureControlQueue` hop.
    private func applyMeteringTapDiff(_ diff: (start: Set<String>, stop: Set<String>)) {
        guard !diff.start.isEmpty || !diff.stop.isEmpty else { return }
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            for bundleID in diff.stop { self.meteringCapture.stop(bundleID: bundleID) }
            for bundleID in diff.start { self.meteringCapture.start(bundleID: bundleID) }
        }
    }

    // MARK: Level emission (T3 — combined per-device MAX)

    /// Whether `device` is genuinely streaming the whole-system mix right now,
    /// for METERING purposes — the fact `drainSystemRMS`/`emitCombinedLevel` need to
    /// decide whether `latestSystemRMS` belongs in this device's bar. For every
    /// AirPlay device this is exactly `Device.isSelected` (a live engine
    /// session — see `applyEngineState`/`convergeDevice`). The LOCAL device is
    /// structurally EXCLUDED from that mechanism: `setOutputSet` never adds it
    /// to `ids`/`outputIDs`/`added` (see "MARK: Current (local) output device
    /// (BUG B)" above — it has no engine session at all), so
    /// `known[localDeviceID].isSelected` never becomes true even while the
    /// synced-local sink is genuinely rendering the same mix to the Mac's own
    /// speakers (the "Mac + AirPlay" scenario) — the local row's meter was
    /// permanently silent. Its real "streaming now" fact lives in
    /// `syncedLocalSinkApplied` instead. Applied, not desired: the desired flag
    /// moves the instant the user clicks, a whole settle window before the sink
    /// physically starts or stops, so keying off it made the meter lead the audio
    /// both ways. `fireSyncedLocalSettle` flips the applied flag and emits the
    /// local device's level right there. The sink
    /// renders the identical already-captured PCM this RMS was measured from
    /// (T-FANOUT), so reusing it is exact, not an approximation. This was a
    /// pre-existing gap (the synced-local sink and per-device metering shipped
    /// in separate phases; neither retrofitted the other), not a regression
    /// from the T1-T3 dropout fixes. BLUETOOTH and CAST ids are excluded from the
    /// engine for the same structural reason (`setOutputSet`'s converge loop guards
    /// on `!device.isBluetooth`/`!device.isCast`), so `isSelected` is never true for
    /// either — asking it would leave both bars permanently dark. Each has
    /// its own "rendering now" fact: a BT row's `.connected`, which means that
    /// device's delay gate has opened (`BTDeviceSink.hasStartedRendering`) and is the
    /// same state that arms its dot — NOT `btSelectedUIDs`, which is intent and would
    /// light the bar on a selected-but-silent speaker; and `castPlaying` for a
    /// receiver that has reported PLAYING. Both sinks are handed the identical
    /// captured PCM this RMS was measured from (BT-FANOUT / CAST-FANOUT in
    /// `NativeCaptureCoordinator.deliver`), so reusing it is exact for them too.
    /// TRAP: the bar therefore shows the UNDELAYED source. A BT sync trim moves that
    /// device's own delay line, which sits DOWNSTREAM of this measurement, so
    /// changing a trim changes when the speaker sounds and never when the bar moves;
    /// one system RMS feeds every device's bar and no per-device delay can reach it.
    /// Must run on `stateQueue`, like every caller.
    func isMeterable(_ device: Device) -> Bool {
        if device.isBluetooth { return device.connectionState == .connected }
        if device.isCast { return castPlaying.contains(device.id) }
        return device.isLocalDevice ? syncedLocalSinkApplied : device.isSelected
    }

    /// Read whatever `noteSystemRMS` last stored (stream_id 0) and, if it is
    /// new, re-emit the combined `.level` for every device currently streaming it
    /// (``isMeterable``) and unmuted — its system contribution just changed.
    /// Re-arms itself, so the chain runs at `levelEmitIntervalNanos` for as long
    /// as metering is on and stops itself on the first fire after it goes off.
    /// On `stateQueue`.
    func drainSystemRMS() {   // on stateQueue
        levelDrainScheduled = false
        guard meteringActive else { return }
        systemRMSLock.lock()
        let dirty = systemRMSDirty
        let rms = systemRMSSlot
        systemRMSDirty = false
        systemRMSLock.unlock()
        if dirty {
            latestSystemRMS = rms
            for id in order {
                guard let device = known[id], isMeterable(device), !device.isMuted else { continue }
                emitCombinedLevel(forDevice: id)
            }
        }
        scheduleSystemRMSDrainLocked()
    }

    /// Arm the next drain, single-flight and only while metering is on.
    /// On `stateQueue`.
    private func scheduleSystemRMSDrainLocked() {   // on stateQueue
        guard meteringActive, !levelDrainScheduled else { return }
        levelDrainScheduled = true
        stateQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(levelEmitIntervalNanos))) { [weak self] in
            self?.drainSystemRMS()
        }
    }

    /// Record one app's PRE-volume SOURCE level and fan it out: to the app's own
    /// row (`.appLevel`), and — if the app is `.device`-routed — into the combined
    /// meter of the device it feeds (a redirect target's contribution is the
    /// loudest source routed to it; see `emitCombinedLevel`). Gated on metering.
    /// Callable from any source thread (mixer queue, tap delivery, engine); hops
    /// to `stateQueue`. The `.appLevel` rides the SAME D3 sampler the per-device
    /// `.level` does, keyed by bundle id, so an app row is rate-limited to the
    /// display cadence exactly like a device row.
    func emitAppLevel(bundleID: String, rms: Float) {
        stateQueue.async {
            guard self.meteringActive else { return }
            self.scheduleLevelEmit(key: .app(bundleID), rms: rms,
                                   now: DispatchTime.now().uptimeNanoseconds)
            self.latestAppLevel[bundleID] = rms
            // The device this app feeds tracks the loudest source routed to it, so
            // re-emit its combined `.level` now that this source level changed.
            // `routedBundleIDs` is the EFFECTIVE routed set (R5): an app whose target
            // is currently unreachable feeds the system mix, not that device, so it
            // must not animate the offline device's meter.
            for route in self.lastRoutes
            where route.bundleID == bundleID && self.routedBundleIDs.contains(bundleID) {
                // A GROUP route feeds every resolved member, so every member's
                // bar must re-emit. Keying on `.device` alone leaves a
                // group-routed app's speakers with a dead meter while audio
                // plays out of them.
                for deviceID in self.meterTargetsLocked(of: route.destination) {
                    self.emitCombinedLevel(forDevice: deviceID)
                }
            }
        }
    }

    /// The speakers a destination's audio actually reaches: the one named by a
    /// `.device` route, or every resolved member of a `.group` route. Local /
    /// no-redirect destinations reach none. THE one place the two meter sites
    /// answer that question, so they cannot drift apart. On `stateQueue`.
    private func meterTargetsLocked(of destination: AppRouteDestination) -> [String] {
        switch destination {
        case .device(let deviceID):        return [deviceID]
        case .group(let groupID):          return Array(
                                              lastGroupTargets[groupID]?.memberVolumes.keys ?? [:].keys)
        case .noRedirect, .currentDevice:  return []
        }
    }

    /// Emit `.level` for `id` as the MAX of its whole-system contribution
    /// (`latestSystemRMS`, only while ``isMeterable`` + unmuted) and its SOURCE
    /// contribution — the loudest PRE-volume level among the apps whose route
    /// reaches it, by `.device` or as a member of a routed `.group`
    /// (`latestAppLevel`). A device fed by both shows the larger. Every input
    /// is a source/program level, so no routing/output volume ever attenuates the
    /// bar. Emitted through the D3 coalescer (`scheduleLevelEmit`, ~25 Hz). On
    /// `stateQueue`.
    func emitCombinedLevel(forDevice id: String) {
        guard let device = known[id] else { return }
        let systemContribution: Float = (isMeterable(device) && !device.isMuted) ? latestSystemRMS : 0
        var sourceContribution: Float = 0
        // `routedBundleIDs` is the EFFECTIVE routed set (R5) — a route whose target
        // is unreachable right now contributes to the system mix, not to this
        // device, so it must not keep this device's bar alive while it is offline.
        for route in lastRoutes
        where routedBundleIDs.contains(route.bundleID) && !deadBundleIDs.contains(route.bundleID) {
            if meterTargetsLocked(of: route.destination).contains(id),
               let level = latestAppLevel[route.bundleID] {
                sourceContribution = max(sourceContribution, level)
            }
        }
        scheduleLevelEmit(key: .device(id), rms: max(systemContribution, sourceContribution),
                          now: DispatchTime.now().uptimeNanoseconds)
    }

    /// The event one coalescer key delivers.
    private func levelEvent(for key: LevelKey, rms: Float) -> BackendEvent {
        switch key {
        case .device(let id): return .level(id: id, rms: rms)
        case .app(let bundleID): return .appLevel(bundleID: bundleID, rms: rms)
        }
    }

    /// Leading-edge/trailing-edge sampler (D3): emits immediately if at least
    /// `levelEmitIntervalNanos` has passed since this key's last emit;
    /// otherwise remembers the latest value and lets an already-scheduled trailing
    /// flush deliver it, so a burst's final value always lands and the meter never
    /// freezes on a stale pre-quiet value. On `stateQueue`.
    private func scheduleLevelEmit(key: LevelKey, rms: Float, now: UInt64) {   // on stateQueue
        if let last = lastLevelEmitNanos[key], now - last < levelEmitIntervalNanos {
            pendingLevel[key] = rms
            guard levelFlushScheduled.insert(key).inserted else { return }
            let remaining = levelEmitIntervalNanos - (now - last)
            stateQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(remaining))) { [weak self] in
                self?.flushPendingLevel(key: key)
            }
            return
        }
        lastLevelEmitNanos[key] = now
        pendingLevel.removeValue(forKey: key)
        emit(levelEvent(for: key, rms: rms))
    }

    /// Trailing flush for `scheduleLevelEmit` — delivers whatever value arrived
    /// last during the coalescing window, if any (a leading-edge emit may have
    /// already cleared it). On `stateQueue`.
    private func flushPendingLevel(key: LevelKey) {   // on stateQueue
        levelFlushScheduled.remove(key)
        guard let rms = pendingLevel.removeValue(forKey: key) else { return }
        lastLevelEmitNanos[key] = DispatchTime.now().uptimeNanoseconds
        emit(levelEvent(for: key, rms: rms))
    }

    // MARK: Emit

    func emit(_ event: BackendEvent) {   // on stateQueue
        for continuation in continuations.values { continuation.yield(event) }
    }
}
