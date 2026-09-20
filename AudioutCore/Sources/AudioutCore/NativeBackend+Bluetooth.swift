import Foundation
import AudioToolbox
import AirPlayEngine
import CastSender

extension NativeBackend {
    // MARK: Bluetooth hardware volume decisions (BT-HW-VOL)

    /// UID → live `AudioObjectID` at USE time, never cached: BT object ids go
    /// stale across a disconnect/rejoin while UIDs don't (see
    /// ``btDeviceIDForUID``). On `stateQueue`.
    private func liveBTDeviceIDLocked(_ uid: String) -> AudioObjectID? {
        btDeviceIDForUID?(uid) ?? aggregateControl.resolveDeviceID(forUID: uid)
    }

    /// (Re)decide whether `uid`'s slider writes hardware volume, on any input
    /// change: connect/disconnect, the detail-pane toggle, a failed write, or
    /// a just-returned SDP verdict. Entering control adopts the SPEAKER's
    /// current level — a read, never a write, so a stored level cannot blast
    /// a loud speaker on connect — and starts the device-side watch; leaving
    /// control returns the device term to the software product.
    ///
    /// Capability now requires the cached AVRCP SDP record's category-2 claim
    /// (``BTAbsoluteVolumeSDP``) IN ADDITION TO the property being settable —
    /// settable alone doesn't distinguish a real fader from a driver's
    /// software-shim volume. A missing SDP verdict (`nil`: no grant, no
    /// record yet) falls back to the settable-only gate rather than blocking
    /// on it, so the interim window before a probe returns still admits
    /// control. On `stateQueue`.
    func reevaluateBTHardwareControlLocked(_ uid: String) {
        guard let control = btHardwareVolumeControl else { return }
        let connected = known[uid]?.isBluetooth == true && known[uid]?.isAvailable == true
        // Capability is decided independently of the toggle, so a speaker that
        // cannot deliver reads `false` even while opted out — it is what hides
        // the detail pane's toggle. Only decidable while connected; a
        // disconnect keeps the last verdict rather than resetting to unknown.
        var capableDeviceID: AudioObjectID?
        if connected, let deviceID = liveBTDeviceIDLocked(uid) {
            let sdpAllows = btSDPClaimByUID[uid] ?? true
            let capable = sdpAllows && control.isControllable(deviceID) && !btHardwareFailedUIDs.contains(uid)
            capableDeviceID = capable ? deviceID : nil
            if known[uid]?.btHardwareVolumeCapable != capable {
                applyLocal(uid) { $0.btHardwareVolumeCapable = capable }
            }
            if let claim = btAbsoluteVolumeClaim, btSDPClaimByUID[uid] == nil,
               btSDPProbedUIDs.insert(uid).inserted {
                btSDPQueue.async { [weak self] in
                    guard let verdict = claim(uid) else { return }
                    self?.stateQueue.async {
                        guard let self else { return }
                        self.btSDPClaimByUID[uid] = verdict
                        self.reevaluateBTHardwareControlLocked(uid)
                    }
                }
            }
        }
        if !connected {
            // Not connected: drop the probed marker so the next connect
            // retries a device whose SDP cache wasn't populated yet.
            btSDPProbedUIDs.remove(uid)
        }
        guard let deviceID = capableDeviceID,
              btHardwareVolumeStore?.isEnabled(uid: uid) ?? true else {
            if btHardwareControlledUIDs.remove(uid) != nil {
                control.unwatch(uid: uid)
                pushBTSinkGainLocked(uid)
            }
            return
        }
        guard btHardwareControlledUIDs.insert(uid).inserted else { return }
        if let level = control.read(deviceID) {
            if muted.contains(uid) {
                stashedVolume[uid] = level.clampedToVolume
            } else {
                applyLocal(uid) { $0.volume = level.clampedToVolume }
            }
        }
        pushBTSinkGainLocked(uid)
        control.watch(deviceID: deviceID, uid: uid) { [weak self] level in
            guard let self else { return }
            self.stateQueue.async { self.noteBTHardwareVolumeChangedLocked(uid, level: level) }
        }
    }

    /// A DEVICE-side change (the speaker's own buttons): the same knob as the
    /// slider, so it lands exactly where a drag would — the row's level, or
    /// the mute stash while the software 0 covers it. The `applyLocal` emit is
    /// all the propagation a drag gets too: saved-group member levels are
    /// snapshots of `Device.volume` taken at save time. On `stateQueue`.
    private func noteBTHardwareVolumeChangedLocked(_ uid: String, level: Int) {
        guard btHardwareControlledUIDs.contains(uid) else { return }
        if muted.contains(uid) {
            stashedVolume[uid] = level.clampedToVolume
        } else {
            applyLocal(uid) { $0.volume = level.clampedToVolume }
        }
    }

    /// Write one uid's level to the speaker itself, off `stateQueue` (a slow
    /// coreaudiod must not stall backend mutations — same discipline as the
    /// local row's system-volume writes). A failed write is the real
    /// "advertised but does not deliver" signal the settable check can't give:
    /// the uid falls back to software gain for the session, and the re-push
    /// carries the level the drag was owed. On `stateQueue`.
    func pushBTHardwareVolumeLocked(_ uid: String, level: Int) {
        guard let control = btHardwareVolumeControl,
              let deviceID = liveBTDeviceIDLocked(uid) else { return }
        btHardwareWriteQueue.async { [weak self] in
            guard !control.write(level, to: deviceID, uid: uid) else { return }
            self?.stateQueue.async { self?.noteBTHardwareWriteFailedLocked(uid) }
        }
    }

    /// On `stateQueue`.
    private func noteBTHardwareWriteFailedLocked(_ uid: String) {
        guard btHardwareControlledUIDs.contains(uid),
              btHardwareFailedUIDs.insert(uid).inserted else { return }
        Telemetry.fail(.localPlayback, "bt_volume:hardware_write_failed",
                       local: ["uid": uid], shared: [:])
        reevaluateBTHardwareControlLocked(uid)
    }

    /// One Cast receiver's composed level: `Main × Group × Device` as 0.0…1.0,
    /// the same product `btSinkGain(forUID:)` forms, forced to 0 while muted.
    /// ONE product, one writer — a Cast receiver's mute IS level 0, never the
    /// protocol's `SET_VOLUME muted` flag, so nothing else can fight over the
    /// knob and no receiver-side mute can outlive the session. On `stateQueue`.
    func castLevel(forID id: String) -> Double {   // on stateQueue
        if let companionTickParticipants, !companionTickParticipants.contains(id) { return 0 }
        if muted.contains(id) { return 0 }
        return masterGainFraction * Double((known[id]?.volume ?? 100).clampedToVolume) / 100.0
    }

    /// Push one Cast id's composed level to the session manager (a no-op before
    /// the channel is live — the manager stores it and sends it on connect).
    /// Reads on `stateQueue`, then hops to `captureControlQueue`, which owns the
    /// manager's transitions. On `stateQueue`.
    /// `completion` fires on `captureControlQueue` once the level has reached
    /// the manager — see ``pushBTSinkGainLocked(_:completion:)`` for why the
    /// audition's preparation waits for it.
    func pushCastLevelLocked(_ id: String,
                                     completion: (@Sendable () -> Void)? = nil) {   // on stateQueue
        let level = castLevel(forID: id)
        captureControlQueue.async { [weak self] in
            self?.castOutputManager?.setLevel(level, forDevice: id)
            completion?()
        }
    }

}

extension NativeBackend {
    // MARK: BT-only reference timeline (roadmap 056 Part A)

    /// How far past the slowest known speaker the BT-only reference sits. A
    /// speaker can only be fed EARLY by shortening its delay, so the reference
    /// has to be at least its latency; the margin leaves room for the user's
    /// trim on top of a freshly measured device.
    static let btReferenceHeadroomMs = 100
    /// The reference a Bluetooth-target wizard run pins the timeline to. The
    /// latency it is about to measure is unknown by definition, so the search
    /// needs room to reach any plausible A2DP/DSP latency instead of pinning
    /// against a 500 ms floor and bowing out "unreachable".
    ///
    /// 2 s, not the 1.5 s it was: ``btWizardLatencyRangeMs`` now stops one
    /// default BT-only buffer SHORT of the reference (a candidate at the
    /// reference itself is a delay of 0 — the ring seeked dry, silent for the
    /// rest of the session), so the reference has to carry that buffer on top
    /// for the reachable latency span to stay the ~1.5 s the search needs.
    static let btWizardReferenceBufferMs = 2_000

    /// The BT-only reference for a selection: never below the
    /// ``BTSyncedSink/defaultBTOnlyBufferMs`` floor, and always far enough
    /// ahead of the slowest MEASURED latency among the selected devices that
    /// its delay does not hit `SyncTiming.totalDelayNanos`'s ≥ 0 clamp. Devices
    /// with no measurement contribute nothing — an unknown latency is treated
    /// as within the floor until the wizard says otherwise.
    static func btOnlyReferenceMs(latencies: [String: Double], uids: [String]) -> Int {
        let slowest = uids.compactMap { latencies[$0] }.max() ?? 0
        return Swift.max(BTSyncedSink.defaultBTOnlyBufferMs,
                         Int(slowest.rounded()) + btReferenceHeadroomMs)
    }

    /// Recompute the BT-only reference and, if it moved, push it to the sink
    /// manager and re-anchor the Mac's own sink (which rides the same reference
    /// in this composition). Returns the value now in force, so the caller can
    /// hand it straight to ``applyBTSinkTransition(...)``. On `stateQueue`.
    @discardableResult
    func updateBTReferenceBufferLocked() -> Int {   // on stateQueue
        let latencies = btTrimLock.withLock { btLatencyMsByUID }
        let desired = btWizardReferenceRaised
            ? Self.btWizardReferenceBufferMs
            : Self.btOnlyReferenceMs(latencies: latencies, uids: btSelectedUIDs)
        guard desired != btReferenceBufferMs else { return desired }
        btReferenceBufferMs = desired
        let localRides =
            btSinkEnabled && !btComposition.usesPresentationReference && syncedLocalSinkApplied
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            self.btSink?.setBTOnlyBufferMs(desired)
            // Wave-4 delay agreement: with no AirPlay in the group the Mac's
            // own sink schedules against this same buffer, so a move of the
            // reference is a move for it too.
            if localRides { self.syncedLocalSink?.requestReanchor(cause: "bt_composition_change") }
        }
        return desired
    }

    /// Whether the sink manager must be armed and for which UIDs: the two
    /// domains that can claim a Bluetooth speaker — the whole-system selection
    /// and the per-app topology — deduped and sorted. The single answer every
    /// ``applyBTSinkTransition(enable:uids:composition:gains:eqs:referenceBufferMs:)``
    /// call outside `stop()`'s explicit teardown asks.
    ///
    /// `btSinkEnabled` deliberately keeps its narrower whole-system-only
    /// meaning: it is what ``roomDelayLocked()`` branches on, and widening it
    /// would put a per-app destination in charge of the room's timing. On
    /// `stateQueue`.
    func btArmingLocked() -> (enable: Bool, uids: [String]) {   // on stateQueue
        (btSinkEnabled || !btPerAppClaimedUIDs.isEmpty,
         Set(btSelectedUIDs).union(btPerAppClaimedUIDs).sorted())
    }

    /// Wave-4 reconnect-reapply: re-run the CURRENT BT sink decision so a
    /// selected device that just (re)appeared resolves a live `AudioObjectID`
    /// and re-enters the per-device set (and one that vanished drops out). The
    /// decision itself is unchanged — only the UID→device resolution is redone,
    /// which `applyBTSinkTransition` performs fresh on every apply. On
    /// `stateQueue`.
    func reapplyBTSinkLocked() {
        let (armed, uids) = btArmingLocked()
        guard armed else { return }
        let composition = btComposition
        let gains = btSinkGains(forUIDs: uids)
        let referenceMs = updateBTReferenceBufferLocked()
        let eqs = btSinkEQs(forUIDs: uids)
        captureControlQueue.async { [weak self] in
            self?.applyBTSinkTransition(
                enable: true, uids: uids, composition: composition, gains: gains,
                eqs: eqs, referenceBufferMs: referenceMs)
        }
    }

    /// Execute the "play everywhere" enable/disable transition decided by
    /// `setOutputSet` above (T-BACKEND). Must run on `captureControlQueue`.
    ///
    /// Enable order (plan T-BACKEND): construct-if-needed → attach (wires the
    /// fan-out + tap self-exclude, T-FANOUT) → start → observe lifecycle events
    /// (T-LIFECYCLE then picks up default-device changes / sleep / wake).
    /// Disable is the mirror image — stop → stop observing → detach — so the
    /// sink is fully quiesced before its self-exclude is lifted. Either way, the
    /// whole-system tap's `.mutedWhenTapped` mode (`NativeCaptureCoordinator`'s
    /// default) is what actually keeps the Mac's raw output muted whenever ≥1
    /// AirPlay device is selected (`reconcileCaptureGate`'s `captureRunning`) —
    /// that mechanism is entirely independent of this sink's own on/off state,
    /// so disabling "play everywhere" while AirPlay devices stay selected
    /// correctly leaves the raw system mix muted.
    ///
    /// `gain` is the `group × Mac's-own-fader` product captured in the SAME
    /// `stateQueue` critical section that decided this transition — applied here so a
    /// trim made while "play everywhere" was off (or before the sink was ever built)
    /// is in force from the first rendered buffer instead of starting at unity.
    func applySyncedLocalSinkTransition(enable: Bool, gain: Float) {
        if enable {
            let sink: SyncedLocalSinkControlling
            if let existing = syncedLocalSink {
                sink = existing
            } else if let factory = syncedLocalSinkFactory {
                sink = factory()
                syncedLocalSink = sink
            } else {
                return   // no factory wired (tests / UI-only smoke) — inert
            }
            sink.setGain(gain)
            attachSyncedLocalSink(sink)
            do {
                try sink.start()
            } catch {
                Telemetry.fail(.localPlayback, "local_playback:start_failed",
                               local: ["error": "\(error)"], shared: ["site": "synced_local"])
            }
            sink.startObservingLifecycleEvents()
        } else {
            guard let sink = syncedLocalSink else { return }
            sink.stop()
            sink.stopObservingLifecycleEvents()
            attachSyncedLocalSink(nil)
        }
    }

    /// T1: record another coalesced synced-local toggle and (re)schedule the
    /// trailing-edge settle. Mirrors `armWakeWatchdog`'s idiom exactly — cancel
    /// the pending `DispatchWorkItem` and re-arm it on `stateQueue`, so the body
    /// runs serialized with every other state mutation and a supersede simply
    /// drops the older one. MUST hold `stateQueue`.
    func scheduleSyncedLocalSettleLocked() {   // on stateQueue
        self.syncedLocalCoalescedCount += 1
        self.pendingSyncedLocalSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireSyncedLocalSettle() }
        self.pendingSyncedLocalSettle = work
        // Scheduled ON `stateQueue`, so a newer toggle's cancel (above) before this
        // fires simply drops it — no double-firing, no stale work after a newer
        // decision landed.
        self.stateQueue.asyncAfter(
            deadline: .now() + self.syncedLocalSettleWindow, execute: work)
    }

    /// T1/T2: the quiet window elapsed — run AT MOST one real transition for the
    /// whole coalesced burst, and re-establish the receiver session exactly once
    /// IFF the burst genuinely churned. On `stateQueue` (scheduled there).
    func fireSyncedLocalSettle() {   // on stateQueue (scheduled there)
        self.pendingSyncedLocalSettle = nil
        let coalesced = self.syncedLocalCoalescedCount
        self.syncedLocalCoalescedCount = 0
        let desired = self.syncedLocalSinkEnabled
        let gain = self.syncedLocalGain

        // Net no-op: a burst that collapsed back to the currently-applied state
        // (e.g. on→off→on while already on, or on→off while already off) never
        // tore the tap/sink down, so there is NOTHING to apply — and, critically,
        // NOTHING to re-sync. Bailing here keeps the T2 reset off this path.
        guard desired != self.syncedLocalSinkApplied else { return }
        self.syncedLocalSinkApplied = desired

        // The local row's meter tracks the applied state (`isMeterable`), so its
        // clear or first reading belongs here, the instant the transition lands.
        // Runs on `stateQueue`, which is `emitCombinedLevel`'s requirement.
        self.emitCombinedLevel(forDevice: Self.localDeviceID)

        // Record the real transition and count how many landed inside the rolling
        // horizon. Monotonic clock, so a wall-clock jump can neither fabricate nor
        // hide churn.
        let now = DispatchTime.now().uptimeNanoseconds
        let horizonNanos = UInt64(self.syncedLocalTransitionHorizon * 1_000_000_000)
        self.syncedLocalTransitionTimes.removeAll { now &- $0 > horizonNanos }
        self.syncedLocalTransitionTimes.append(now)
        let recentTransitions = self.syncedLocalTransitionTimes.count

        // Churn = the settle absorbed ≥2 distinct toggle decisions (rapid
        // clicking). A NORMAL single toggle coalesces exactly one decision and
        // MUST NEVER take the reset branch — that redundant RTP re-establish on
        // every ordinary connect is the exact bug a prior fix removed
        // (`dev/notes/synced-local-mixed-selection-dropout-fix.md`). This is the
        // sharpest correctness constraint in the fix.
        // Either detector arms the reset: `coalesced >= 2` (two or more decisions
        // in THIS settle) or `recentTransitions >= 2` (two or more transitions
        // really applied inside the horizon, the cadence-independent path that
        // recovers a click cadence slower than the window, where `coalesced` is
        // always 1). A normal single toggle satisfies neither: one decision, and
        // its own transition alone in the horizon. Two unhurried toggles further
        // apart than the horizon likewise pay nothing.
        let churned = coalesced >= 2 || recentTransitions >= 2

        // Runs on `captureControlQueue` — the same serial queue the capture gate's
        // start/stop is enqueued on — so a tap recreate triggered by
        // `attachSyncedLocalSink` (self-exclude pid change, T-FANOUT) never races a
        // capture-gate start/stop for the same tap.
        self.captureControlQueue.async { [weak self] in
            guard let self else { return }
            self.applySyncedLocalSinkTransition(enable: desired, gain: gain)
            if churned {
                // Rapid toggling drove many tap rebuilds with NO receiver-session
                // reset (an `.exclusionChange` rebuild deliberately skips it),
                // desyncing/corrupting the receiver even while the Mac-side capture
                // reports healthy — the permanent-silence bug. Now that the tap has
                // settled into `desired`, re-establish the session ONCE.
                // `resetAirPlaySessionForWholeSystem` is already single-flighted
                // (per-device `converging` claim + `rebindRecoveryGen`) and
                // ownership-guarded (`stillOwnsRebind`), so this can't fight a
                // concurrent converge or thrash a healthy session. That is also
                // why a sustained storm needs no second rate limiter here: a
                // device still recovering from the previous re-sync is
                // `converging` and the next reset call skips it.
                Telemetry.log(.airplay, "synced_local_churn_resync", [
                    "coalesced": "\(coalesced)",
                    "recentTransitions": "\(recentTransitions)",
                    "desired": "\(desired)",
                ])
                self.resetAirPlaySessionForWholeSystem()
            }
        }
    }

    // MARK: Bluetooth sink transitions (BT-BACKEND)

    /// Execute the BT enable/disable/reconcile `setOutputSet` decided. Must run
    /// on `captureControlQueue` — serial with the capture gate's start/stop and
    /// the synced-local transitions, so nothing here can race a tap rebuild.
    ///
    /// Enable order: composition first (a fresh sink's one-time anchor samples
    /// its delay provider, so the reference must already be right), then the
    /// device set (the manager reconciles and starts new per-device sinks while
    /// armed), then the fan-out attach, then `start()` (idempotent). Disable
    /// mirrors it: stop → drop the per-device sinks (releases their
    /// `AVAudioEngine`s; offsets/trims live in the manager's own tables and
    /// survive) → detach the fan-out.
    ///
    /// No settle debounce, unlike the synced-local transition: attaching the BT
    /// fan-out never rebuilds the tap (`setBTSink` is compare-before-rebuild
    /// and the render pid is our own already-excluded process), so the storm
    /// that debounce exists for cannot start here.
    func applyBTSinkTransition(
        enable: Bool, uids: [String], composition: BTGroupComposition,
        gains: [String: Float] = [:], eqs: [String: DeviceEQ] = [:],
        referenceBufferMs: Int? = nil
    ) {
        if enable {
            let sink: BTSyncedSinkControlling
            if let existing = btSink {
                sink = existing
            } else if let factory = btSyncedSinkFactory {
                sink = factory()
                btSinkRefLock.withLock { btSink = sink }
            } else {
                return   // no factory wired (tests / UI-only smoke) — inert
            }
            sink.setComposition(composition)
            // The BT-only reference this selection needs (roadmap 056 Part A):
            // pushed with the composition, BEFORE `setDevices` builds any sink,
            // so a fresh sink anchors against the right timeline first time.
            if let referenceBufferMs { sink.setBTOnlyBufferMs(referenceBufferMs) }
            // Persisted SYNC trims (BT-OFFSET-UI), re-pushed on every enable so
            // a sink built after launch — or rebuilt after a reconnect — starts
            // from the saved values. Idempotent: the sink ignores a same-value
            // write, so this never forces a rebuild on its own.
            let (trims, latencies) = btTrimLock.withLock { (btTrimsByUID, btLatencyMsByUID) }
            for (uid, ms) in trims {
                sink.setTrimMs(ms, forDeviceUID: uid)
            }
            // Measured latencies (roadmap 056 Part A), re-pushed for the same
            // reason as the trims: a sink built after launch must start from
            // what the wizard already learned about this speaker, not from 0.
            for (uid, ms) in latencies {
                sink.setOffsetMs(Int(ms.rounded()), forDeviceUID: uid)
            }
            // Silence keep-alive (roadmap 085 ticket 04), re-read from settings
            // on every enable so a changed preference lands on the next connect
            // — the connect-volume precedent, no live push mid-session.
            sink.setKeepAliveWindow(
                nanos: Int64(AppSettings().btKeepAliveMinutes) * 60 * 1_000_000_000)
            // Composed gains (`btSinkGain`: user volume × masters, 0 while
            // held/muted) land BEFORE the device set, so a sink created by
            // `setDevices` below starts at the user's level — or already muted
            // for a W3 hold (the manager remembers per-UID gains for exactly
            // this ordering), never at a hardcoded 1 or 0.
            for uid in uids {
                sink.setGain(gains[uid] ?? 1, forDeviceUID: uid)
            }
            // Tone, on the same re-push-on-every-arm footing as the trims above:
            // the manager remembers it per uid, so a sink created by `setDevices`
            // below starts already shaped instead of playing a few flat buffers.
            for uid in uids {
                sink.setEQ(eqs[uid] ?? .flat, forDeviceUID: uid)
            }
            // UID → live AudioObjectID, resolved fresh per apply. A uid that no
            // longer resolves (the speaker dropped between selection and apply)
            // contributes no sink; it re-resolves on the next selection change
            // (reconnect-driven re-application is BT-RECONNECT's, Wave 4).
            sink.setDevices(uids.compactMap { uid in
                let deviceID = btDeviceIDForUID?(uid) ?? aggregateControl.resolveDeviceID(forUID: uid)
                return deviceID.map { BTSyncedSink.DeviceSpec(deviceID: $0, uid: uid) }
            })
            attachBTSink(sink)
            sink.start()
        } else {
            guard let sink = btSink else { return }
            sink.stop()
            sink.setDevices([])
            attachBTSink(nil)
        }
    }

    /// Apply one Cast selection decision (CAST-OUT). On `captureControlQueue`,
    /// like ``applyBTSinkTransition(enable:uids:composition:gains:)``, so a Cast
    /// transition can never race a tap start/stop or a BT transition.
    ///
    /// The fan-out slot is attached exactly once per armed stretch — the pid is
    /// our own already-tap-excluded process, so attaching costs no tap rebuild,
    /// but re-attaching on every selection change would still churn the
    /// snapshot for nothing.
    func applyCastTransition(
        enable: Bool, records: [CastDeviceRecord], levels: [String: Double]
    ) {   // on captureControlQueue
        guard let manager = castOutputManager else { return }
        if enable {
            if !castFeedAttached {
                captureCoordinator?.setCastSink(manager.feed, renderProcessPID: getpid())
                castFeedAttached = true
            }
            manager.setDevices(records)
            // Composed levels land after the device set: a session that has not
            // reached its receiver yet stores the level and pushes it as soon
            // as the channel is live.
            for (id, level) in levels {
                manager.setLevel(level, forDevice: id)
            }
            // CAST-SYNC: an arm re-states every receiver's stored by-ear offset,
            // so reselecting one brings its offset back rather than leaving the
            // delay line at whatever the last armed stretch left there.
            pushStoredCastUserOffsets(forDeviceIDs: records.map(\.id))
        } else {
            manager.setDevices([])
            if castFeedAttached {
                captureCoordinator?.setCastSink(nil, renderProcessPID: nil)
                castFeedAttached = false
            }
        }
    }

    // MARK: Bluetooth connect lifecycle (BT-LIFECYCLE)

    /// Start a selected BT id breathing and arm the watch that ends the hold.
    ///
    /// A BT id has no engine session, so no AirPlay-lifecycle transition can
    /// ever move it off `.off` — this is the ONLY road to `.connected` for a
    /// Bluetooth row, and `.connected` is what lights its armed dot and mounts
    /// its meter. The hold ends on the device's own delay gate opening, not on
    /// its engine starting: the engine is up long before a note comes out, so
    /// promoting on "sink running" would put the dot ahead of the music.
    ///
    /// Callers own the precondition that a connect is even plausible — a
    /// selected-but-unavailable row stays `.off` (nothing is connecting), while
    /// a just-succeeded baseband connect arms regardless of whether the
    /// enumerator snapshot has caught up yet. On `stateQueue`.
    func beginBTConnectingLocked(_ id: String) {   // on stateQueue
        guard expectedSelected.contains(id), known[id]?.isBluetooth == true else { return }
        setConnectionState(.connecting, for: id)
        btConnectingDeadlines[id] = Date().addingTimeInterval(btRenderStartTimeout)
        scheduleBTRenderPollLocked()
    }

    /// Arm the poll unless one is already in flight (or nothing is breathing).
    /// On `stateQueue`.
    private func scheduleBTRenderPollLocked() {   // on stateQueue
        guard btRenderPollWork == nil, !btConnectingDeadlines.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.pollBTRenderStart() }
        btRenderPollWork = work
        stateQueue.asyncAfter(deadline: .now() + Self.btRenderPollInterval, execute: work)
    }

    /// Read the rendering set off `captureControlQueue` (which owns `btSink`)
    /// and fold it back in on `stateQueue`. On `stateQueue` (scheduled there).
    private func pollBTRenderStart() {   // on stateQueue
        btRenderPollWork = nil
        guard !btConnectingDeadlines.isEmpty else { return }
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            let rendering = self.btSink?.renderingDeviceUIDs() ?? []
            let anchored = self.btSink?.anchoredDeviceUIDs()
            self.stateQueue.async { self.applyBTRenderStart(rendering, anchored: anchored) }
        }
    }

    /// End every hold that has an answer — rendering wins first, then the
    /// ceiling — and re-arm the poll for whatever is still breathing. A row
    /// deselected mid-hold just drops out: the deselect edge already wrote its
    /// own `.off`. On `stateQueue`.
    ///
    /// The ceiling only means FAILURE for a device that was handed audio and
    /// still never started playing it. A device that was handed nothing is
    /// idle, not broken: with the Mac silent the capture fan-out never calls
    /// `enqueue`, so no sink can anchor and none can ever render. Failing on
    /// the ceiling alone reported "no audio started" for a perfectly healthy
    /// speaker selected while paused — the link is up, and it will play the
    /// moment there is anything to play. Whether sound is actually moving is
    /// what the armed dot and the meter are for; the connection state must not
    /// try to answer it too.
    private func applyBTRenderStart(
        _ rendering: Set<String>, anchored: Set<String>?
    ) {   // on stateQueue
        let now = Date()
        for (id, deadline) in btConnectingDeadlines {
            guard expectedSelected.contains(id) else {
                btConnectingDeadlines[id] = nil
                continue
            }
            if rendering.contains(id) {
                btConnectingDeadlines[id] = nil
                setConnectionState(.connected, for: id)
            } else if now >= deadline {
                btConnectingDeadlines[id] = nil
                guard anchored?.contains(id) ?? true else {
                    setConnectionState(.connected, for: id)
                    Telemetry.log(.localPlayback, "bt_render_start_idle", ["device": id])
                    continue
                }
                setConnectionState(.failed(ConnectionFailure(
                    cause: .unknown, detail: "no audio started")), for: id)
                Telemetry.log(.localPlayback, "bt_render_start_timeout", ["device": id])
            }
        }
        scheduleBTRenderPollLocked()
    }

    /// Mirror of `attachSyncedLocalSink` for the BT fan-out: same render-process
    /// identity (the per-device sinks are in-process `AVAudioEngine`s, so their
    /// output is attributed to us), same echo-prevention contract (R-echo).
    private func attachBTSink(_ sink: SyncedLocalPCMSink?) {
        let renderProcessPID: pid_t? = (sink == nil) ? nil : getpid()
        captureCoordinator?.setBTSink(sink, renderProcessPID: renderProcessPID)
    }

}

extension NativeBackend {
    // MARK: Bluetooth outputs → deviceAdded/deviceUpdated (BT-ENUM)

    /// The ``btLastUsed`` stash — the ``BTOutputControlling`` read the popover's
    /// Bluetooth-subsection sort uses (ghost pairings sink to the bottom by
    /// recency; sort-only in v1).
    ///
    /// This is on the popover's OPEN path (`deviceSections()` →
    /// `orderedBluetoothDevices`), so it must never wait on `stateQueue`, which
    /// can be seconds deep behind a converge. Its own lock instead — the same
    /// pattern `btSyncTrim(forDevice:)` and the cached system volume use.
    public func lastUsedDatesForBTDevices() -> [String: Date] {
        btLastUsedLock.withLock { btLastUsed }
    }

    /// Fold a full BT enumeration into the model, through the same
    /// `known`/`order`/`emit` flow AirPlay discovery uses. A BT device that
    /// leaves the merged list entirely (unpaired mid-session) goes unavailable
    /// but keeps its row — same greyed-not-vanished contract as
    /// ``markDisappeared``. On `stateQueue`.
    func applyBTSnapshots(_ snapshots: [BTDeviceSnapshot]) {
        var seen: Set<String> = []
        var desiredAvailabilityMoved = false
        btPairedIDs = Set(snapshots.map(\.id))
        for snapshot in snapshots {
            let id = snapshot.id
            seen.insert(id)
            btLastUsedLock.withLock {
                btLastUsed[id] = snapshot.lastUsed
                if let minor = snapshot.deviceClassMinor { btDeviceClassMinorByUID[id] = minor }
            }
            if let existing = known[id] {
                var updated = existing
                updated.name = snapshot.name
                updated.isAvailable = snapshot.isConnected
                // The row glyph follows the pairing's device class, so a class
                // that only becomes readable later (the Bluetooth grant arrives
                // mid-session and the paired list finally loads) still reaches
                // the row. A snapshot WITHOUT one keeps the last known class
                // instead of clearing it: `merge` carries `nil` for a
                // connected output with no paired record, and for every device
                // while the grant is absent (`refreshLocked` passes `[]`), so
                // clearing would drop a pair of headphones back to the neutral
                // speaker glyph mid-session, while it is still connected.
                if let minor = snapshot.deviceClassMinor {
                    updated.bluetoothDeviceClassMinor = minor
                }
                if updated != existing {
                    let availabilityMoved = updated.isAvailable != existing.isAvailable
                    if availabilityMoved, expectedSelected.contains(id) {
                        desiredAvailabilityMoved = true
                    }
                    commitKnownDevice(id, updated)
                    // BT-RECONNECT: the row's lifecycle follows the baseband
                    // fact. A loss while SELECTED is DESELECTED — off =
                    // unselected, truthfully (the owner's call, replacing the
                    // old power-off park): the popover reacts to this exact
                    // availability edge (`PopoverController.update(devices:)`)
                    // and routes it through `GroupController.setDeviceSelected`,
                    // the one selection owner. A return while STILL selected
                    // therefore IS deliberate intent (the greyed-row "play
                    // when up" select) and resumes below.
                    // Sticky-failed: a `.failed` story from a user-initiated
                    // attempt survives a loss until retry or return.
                    if availabilityMoved {
                        if updated.isAvailable {
                            // The link came up. Most of the time nobody in this
                            // process asked for it — a speaker power-cycled and
                            // the OS relinked it — so `finishBTReconnect` (the
                            // manual tap's own outcome) never sees it and this
                            // is the only place the timing store could learn
                            // the speaker renegotiated its buffering.
                            // A manual reconnect reaches both, and the store
                            // collapses the two reports into one link-up.
                            btSpeakerTiming.noteConnected(uid: id)
                            // BT-LIFECYCLE: the endpoint existing is not yet
                            // audio — a selected row breathes until its sink
                            // renders, exactly like a fresh select.
                            if expectedSelected.contains(id) {
                                beginBTConnectingLocked(id)
                            } else {
                                setConnectionState(.off, for: id)
                            }
                        } else {
                            btSpeakerTiming.noteDisconnected(uid: id)
                            btConnectingDeadlines[id] = nil
                            if case .failed = existing.connectionState {
                                // keep the failure story
                            } else {
                                setConnectionState(.off, for: id)
                            }
                        }
                        // Availability is an input to the hardware-volume
                        // decision (BT-HW-VOL): a link-up re-enters control
                        // with a fresh device id, a link-down drops the watch.
                        reevaluateBTHardwareControlLocked(id)
                    }
                }
            } else {
                let device = Device(
                    id: id,
                    name: snapshot.name,
                    kind: .bluetooth,
                    isAvailable: snapshot.isConnected,
                    supportsAirPlay2: false,
                    // Same as the AirPlay row (`mapDiscovered`): the stored tone
                    // shows from the moment the row appears. A BT device's sink
                    // gets the value re-pushed on every arm, so the snapshot and
                    // what is audible agree.
                    eq: eqByDeviceID[id] ?? .flat,
                    bluetoothDeviceClassMinor: snapshot.deviceClassMinor)
                // The first time this process lists a connected Bluetooth
                // device is the only link-up it will ever see for it: a first
                // pairing, or a speaker already up when the app launched. Both
                // start a settle window (owner's call, 2026-09-04); neither
                // asks anything of the user, because a stored offset survives a
                // reconnect and is applied again (`BTSpeakerTiming.status`).
                if snapshot.isConnected { btSpeakerTiming.noteConnected(uid: id) }
                known[id] = device
                order.append(id)
                emit(.deviceAdded(device))
                if snapshot.isConnected { reevaluateBTHardwareControlLocked(id) }
            }
        }
        for id in order where known[id]?.kind == .bluetooth && !seen.contains(id) {
            guard var device = known[id], device.isAvailable else { continue }
            device.isAvailable = false
            btSpeakerTiming.noteDisconnected(uid: id)
            if expectedSelected.contains(id) { desiredAvailabilityMoved = true }
            commitKnownDevice(id, device)
            reevaluateBTHardwareControlLocked(id)
        }
        // BT-BACKEND: a SELECTED BT id's availability is its audible fact for
        // the silence fallback (`desiredDeviceAudibleLocked` — BT ids never
        // reach `.connected`), and this is the only place that fact changes.
        // AirPlay ids get this re-evaluation from their connection-state
        // transitions; without this call a BT speaker powering off mid-play
        // would never arm the fallback, and one reconnecting would never
        // clear it.
        // The reapply (Wave 4) is the other half: a selected id that just
        // (re)appeared resolves a live device and re-enters the sink set
        // without waiting for a selection change — and a vanished one drops.
        if desiredAvailabilityMoved {
            reconcileSilenceWatchdog()
            reapplyBTSinkLocked()
        }
    }

}

/// Optional backend capability for the Bluetooth device-row UI (BT-UI /
/// BT-OFFSET-UI) — the same `backend as? Capability` pattern as
/// ``MeteringControlling``/``AppRouteConfiguring``: `NativeBackend` is the only
/// conformer; on `MockBackend` the cast is `nil` and the popover's Bluetooth
/// affordances degrade gracefully.
public protocol BTOutputControlling: AnyObject {
    /// When macOS last used each known BT pairing, keyed by `Device.id` — the
    /// popover's ghost-pairing sort input (stale pairings to the bottom).
    func lastUsedDatesForBTDevices() -> [String: Date]
    /// Set a device's SYNC trim (ms, snapped to `BTSyncTrim.resolutionMs` and
    /// clamped to ±`BTSyncTrim.rangeMs`): applied live to its `BTSyncedSink`
    /// delay, and written to disk only when `persist` is true.
    ///
    /// `persist: false` is the drawer's live SCRUB (D6): the ruler emits a new
    /// value many times a second while the user drags, and every one of those
    /// must reach the audio path — but writing the JSON store at that rate
    /// would be absurd. The drag's END (and every discrete gesture: a stepper
    /// click, a typed commit, Revert) arrives separately with `persist: true`.
    func setBTSyncTrim(_ ms: Double, forDevice id: String, persist: Bool)
    /// The saved SYNC trim for a device (0 when none) — what a disconnected
    /// row shows read-only, and what the drawer starts from.
    func btSyncTrim(forDevice id: String) -> Double
    /// Whether this device has a trim ENTRY at all — the honest answer to
    /// D10's "tuned or never tuned?", which a value alone cannot give: a
    /// device deliberately tuned to exactly 0.0 ms is tuned, and must not
    /// read "Not set".
    func btHasSyncTrim(forDevice id: String) -> Bool
    /// Delete this device's stored alignment — its measured latency AND its
    /// trim — and put the live sink back on unaligned scheduling (roadmap 056:
    /// the drawer's "Reset alignment"). The entries are REMOVED, never written
    /// as 0: ``btHasSyncTrim(forDevice:)`` answers by existence, so a stored 0
    /// would leave the row reading "0 ms" rather than "Not set".
    func resetBTAlignment(forDevice id: String)
    /// Start/stop the align-by-ear tick in the captured feed (auto-limits to
    /// ~30 s of ticks on its own).
    func setBTAlignTickActive(_ active: Bool)

    // MARK: Alignment wizard (W2)

    /// Push a CANDIDATE trim live to the device's sink — clamped like
    /// ``setBTSyncTrim(_:forDevice:persist:)`` but NEVER persisted and never
    /// entering the stored trim table, so cancel can restore by re-pushing the
    /// store. (A selection change mid-wizard re-pushes stored trims over the
    /// preview; the wizard session re-applies on its next answer, so the stomp
    /// is a beat, not a loss.)
    func setBTWizardTrimPreview(_ ms: Double, forDevice id: String)
    /// End a preview: `keepMs` non-nil persists it (the wizard's Keep, via the
    /// ordinary ``setBTSyncTrim(_:forDevice:persist:)`` path); `nil` restores
    /// the stored trim to the live sink (cancel / Try again / graceful exit).
    func endBTWizardTrimPreview(forDevice id: String, keepMs: Double?)
    /// The wizard's continuous tick run — distinct from the row button's ~30 s
    /// ``setBTAlignTickActive(_:)``. The run OPENS on the keep-alive bed alone
    /// and the backend arms the ticks once every participating sink has
    /// actually released (roadmap 056 Part B) — that is what stops the Mac
    /// ticking on its own while a Bluetooth engine is still coming up.
    ///
    /// `btTargetDeviceID` names the Bluetooth device being measured, or `nil`
    /// for a Mac-target run. A Bluetooth target additionally pins the BT-only
    /// reference wide open (its latency is the unknown the run exists to find);
    /// the `false` edge does NOT lower it again — ``endBTWizardRun()`` does, so
    /// the receipt the user is judging plays on the same timeline the trials
    /// did.
    ///
    /// `btReferenceDeviceID` names the speaker the target is being compared
    /// AGAINST. A run is a two-speaker comparison, so every OTHER selected
    /// Bluetooth speaker is held silent for its duration — one at its own trim
    /// is simply the loudest thing in the room and gets judged instead of the
    /// target (live run 2026-08-22). Pass it whether or not it is a Bluetooth
    /// device; a Mac reference is not in the held set anyway.
    ///
    /// IDEMPOTENT for the tick itself: a redundant edge does nothing at all.
    /// Both edges re-anchor every sink, and the panel's Done button issues a
    /// second `false` after a terminal screen already stopped the tick. The
    /// participant hold is the exception — it is recomputed on every call, so a
    /// reference swapped mid-run comes back off the hold without a tick edge.
    func setBTWizardTickActive(_ active: Bool, btTargetDeviceID: String?,
                               btReferenceDeviceID: String?)
    /// The wizard panel is going away for good — Keep, Discard, Done, ✕,
    /// popover close, target lost. Lowers a Bluetooth run's raised reference
    /// back onto `max(floor, slowest measured latency + headroom)`, by which
    /// point a Keep's own measurement is already in the table, so the move is
    /// ONE composition re-anchor with nothing left to clamp. Idempotent.
    func endBTWizardRun()
    /// The wizard's beat interval, in BPM — the estimator's coarse search ticks
    /// far slower than its stimulus blocks so an unknown latency cannot alias
    /// into an apparent lead.
    func setBTWizardTickTempo(bpm: Double)

    // MARK: Measured latency (roadmap 056 Part A)

    /// A device's measured output latency in ms, or `nil` when the wizard has
    /// never run against it. The Mac is the zero this is measured from.
    func btMeasuredLatencyMs(forDevice id: String) -> Double?
    /// The latency values a wizard run may actually present for this device.
    /// The ceiling stops one default BT-only buffer SHORT of the reference — at
    /// the reference itself the delay is 0, which seeks the ring dry and takes
    /// the speaker silent for the rest of the session. The floor is NEGATIVE
    /// (`−BTSyncTrim.rangeMs`) even though a latency below 0 is not a physical
    /// quantity: without it a fresh speaker (base 0) dead-ends on its first
    /// "target first" answer. Nothing below 0 is ever persisted. Derived
    /// against the reference IN FORCE DURING A RUN (the raised wizard buffer,
    /// or the live AirPlay presentation delay), so it can be asked before the
    /// run starts.
    func btWizardLatencyRangeMs(forDevice id: String) -> ClosedRange<Double>
    /// Push a CANDIDATE latency live to the device's sink — never persisted,
    /// the exact twin of ``setBTWizardTrimPreview(_:forDevice:)`` and equally
    /// rebuild-free.
    func setBTWizardLatencyPreview(_ ms: Double, forDevice id: String, halfWidthMs: Double?)
    /// End a latency preview: `keepMs` non-nil persists it as the device's
    /// measured latency AND zeroes the device's trim (the run suspended it, and
    /// the nudge was a manual stand-in for the latency just measured); `nil`
    /// restores the stored latency and leaves the trim to
    /// ``endBTWizardTrimPreview(forDevice:keepMs:)``.
    func endBTWizardLatencyPreview(forDevice id: String, keepMs: Double?)

    // MARK: Mic probe (roadmap 064)

    /// Stage the one-shot mic-probe sweeps on the live wizard feed: DOWN sweep
    /// to the engine/AirPlay/Mac fan-out, UP sweep to the Bluetooth fan-out.
    /// Call after the wizard tick has been activated
    /// (``setBTWizardTickActive(_:btTargetDeviceID:btReferenceDeviceID:)``);
    /// the existing arm gate then starts the sweeps instead of the first tick,
    /// and the tick grid arms itself when they finish. `onStarted` fires at
    /// the gate opening, `onFinished` when the last sweep frame has entered
    /// the feed; a run torn down early fires neither — the mic session's
    /// timeout is the recovery. Default: no-op (mock/dev backends have no
    /// wizard feed to stage on).
    func stageBTMicProbe(onStarted: @escaping () -> Void, onFinished: @escaping () -> Void)

    /// The usable trim range for a device (D11/T3) — the drawer's ruler and
    /// numeric field hard-stop here instead of at the nominal ±`BTSyncTrim
    /// .rangeMs`, because past this bound `SyncTiming.totalDelayNanos`'s ≥ 0
    /// clamp already eats the change and the readout would be lying.
    ///
    /// LIVE QUERY — the range moves whenever an AirPlay device joins or
    /// leaves the group (the reference term swaps between the fixed BT-only
    /// buffer and the live AirPlay presentation delay), so a conformer must
    /// answer fresh on every call, never from a value cached at some earlier
    /// point (e.g. drawer-open time). The default implementation below
    /// (full ±range) keeps mock/dev builds — which have no BT sink to ask —
    /// working unchanged.
    func btUsableTrimRangeMs(forDevice id: String) -> ClosedRange<Double>

    // MARK: Phone-driven sync calibration

    /// Fired when what the Mac would publish about a Bluetooth device's
    /// timing moved — a reconnect, an alignment landing, a tuning cleared — so
    /// the wiring can rebuild and rebroadcast the companion snapshot. Default
    /// get-nil / set-noop, so a conformer with no timing to report compiles
    /// unchanged.
    var onBTAlignmentChanged: (@Sendable () -> Void)? { get set }

    /// What the Mac publishes about this device's timing, for the snapshot's
    /// `DeviceState.alignment`. `nil` (the default) means this backend reports
    /// no alignment at all and the phone shows none.
    func btAlignmentReport(forDevice id: String) -> BTSpeakerTimingReport?

    /// Stage and play a sync-calibration run for `targetID`, measured against
    /// `referenceID` — the reference the SNAPSHOT published, passed in rather
    /// than recomputed, so what the phone's CTA was gated on and what the Mac
    /// actually plays can never be two different speakers.
    ///
    /// Returns a refusal reason for the preconditions only this layer can
    /// answer (the target has no live Bluetooth sink; a run, fine-tune session
    /// or Mac wizard is already up), or `nil` once staged. `onStarted` fires
    /// when the sweeps enter the feed, `onFinished` when the last sweep frame
    /// does; a run torn down early fires neither, and the phone recovers by
    /// timeout. Nothing about the device's tuning changes until a measurement
    /// is reported back.
    func startCompanionAlignmentProbe(targetID: String, referenceID: String,
                                      onStarted: @escaping () -> Void,
                                      onFinished: @escaping () -> Void) -> String?

    /// Stand a run, fine-tune session or A/B demo for `targetID` down now —
    /// the phone's Cancel, and the path a vanished client takes. Idempotent,
    /// and a no-op for a device with nothing in flight.
    func cancelCompanionAlignmentProbe(targetID: String)

    /// Apply the phone's raw measurement: the target's currently applied
    /// latency plus the reported offset, less whatever stagger the staging
    /// used. Persisted through the same path the Mac wizard's Keep takes
    /// (measured latency written, trim zeroed). The success case carries the
    /// two numbers the phone cannot derive — the de-staggered measurement and
    /// how far the stored latency actually moved.
    func applyCompanionAlignmentMeasurement(targetID: String,
                                            offsetMs: Double,
                                            confidence: Double) -> CompanionAlignmentApplyResult

    /// Start/stop the by-ear fine-tune metronome for `targetID`. The `true`
    /// edge records the trim to revert to; the `false` edge persists whatever
    /// the nudges reached.
    func setCompanionAlignmentTick(targetID: String, active: Bool) -> String?

    /// Start the speaker clicks for `targetID` against `referenceID`.
    ///
    /// Two callbacks, deliberately separate. `completion` is this REQUEST's
    /// one-shot reply — nil for a start that took, a sentence for one that did
    /// not. `onReleased` is the lifetime signal: it fires once, on main, after
    /// this Mac's reservation is actually gone, whether that came from a real
    /// drain, from backend teardown, or from a start that was refused before it
    /// claimed anything. A stop that refuses on its four-second timeout does
    /// NOT consume it, because the reservation is still held at that point.
    func startCompanionAlignmentAudition(
        targetID: String, referenceID: String,
        onReleased: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (String?) -> Void)
    func endCompanionAlignmentAudition(
        targetID: String,
        completion: @escaping @Sendable (String?) -> Void)

    /// Move `targetID`'s trim by `deltaMs`, live and immediately — never
    /// coalesced, because a dropped detent is a nudge the user made and did
    /// not get.
    func nudgeCompanionAlignmentTrim(targetID: String, deltaMs: Double) -> String?

    /// Put `targetID`'s trim back to what it was when the fine-tune session
    /// started.
    func revertCompanionAlignmentNudge(targetID: String) -> String?

    /// Delete `targetID`'s stored alignment outright — the row goes back to
    /// "Timing not set".
    func clearCompanionAlignmentTuning(targetID: String)

    /// Play the A/B receipt for `targetID`: the alignment tick at the value in
    /// force before the last measurement, then at the current one, on the
    /// target and `referenceID` alone. With no pre-measurement value recorded
    /// there is nothing to swap to, so it plays the current value throughout.
    func playCompanionAlignmentDemo(targetID: String, referenceID: String?) -> String?
}

extension BTOutputControlling {
    public func btUsableTrimRangeMs(forDevice id: String) -> ClosedRange<Double> {
        -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs
    }

    public func stageBTMicProbe(onStarted: @escaping () -> Void,
                                onFinished: @escaping () -> Void) {}

    /// Defaults for the whole phone-driven family: a backend with no Bluetooth
    /// sink of its own reports no alignment and refuses every action, which is
    /// what a mock/dev build should do.
    public var onBTAlignmentChanged: (@Sendable () -> Void)? {
        get { nil }
        set { }
    }
    public func btAlignmentReport(forDevice id: String) -> BTSpeakerTimingReport? { nil }
    public func startCompanionAlignmentProbe(targetID: String, referenceID: String,
                                             onStarted: @escaping () -> Void,
                                             onFinished: @escaping () -> Void) -> String? {
        "This Mac can't measure speaker timing right now. Reconnect the speaker and try again."
    }
    public func cancelCompanionAlignmentProbe(targetID: String) {}
    public func applyCompanionAlignmentMeasurement(targetID: String,
                                                   offsetMs: Double,
                                                   confidence: Double) -> CompanionAlignmentApplyResult {
        .refused("This Mac can't measure speaker timing right now. Reconnect the speaker and try again.")
    }
    public func setCompanionAlignmentTick(targetID: String, active: Bool) -> String? {
        "This Mac can't measure speaker timing right now. Reconnect the speaker and try again."
    }
    /// For callers with no interest in the lifetime signal.
    public func startCompanionAlignmentAudition(
        targetID: String, referenceID: String,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        startCompanionAlignmentAudition(targetID: targetID, referenceID: referenceID,
                                        onReleased: {}, completion: completion)
    }
    public func startCompanionAlignmentAudition(
        targetID: String, referenceID: String,
        onReleased: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        DispatchQueue.main.async {
            completion("This Mac can't play speaker clicks right now. Reconnect the speaker and try again.")
            onReleased()
        }
    }
    public func endCompanionAlignmentAudition(
        targetID: String, completion: @escaping @Sendable (String?) -> Void
    ) { DispatchQueue.main.async { completion(nil) } }
    public func nudgeCompanionAlignmentTrim(targetID: String, deltaMs: Double) -> String? {
        "This Mac can't measure speaker timing right now. Reconnect the speaker and try again."
    }
    public func revertCompanionAlignmentNudge(targetID: String) -> String? {
        "This Mac can't measure speaker timing right now. Reconnect the speaker and try again."
    }
    public func clearCompanionAlignmentTuning(targetID: String) {}
    public func playCompanionAlignmentDemo(targetID: String, referenceID: String?) -> String? {
        "This Mac can't measure speaker timing right now. Reconnect the speaker and try again."
    }
}

// MARK: - Passive drift tracking (roadmap 085 ticket 05)

extension NativeBackend {

    /// A playback gap starts once nothing has rendered real program audio for
    /// this long — see ``DriftCorrectionApplier/gapAfterSilentSeconds``.
    private static let driftGapNanos =
        Int64(DriftCorrectionApplier.gapAfterSilentSeconds * 1_000_000_000)

    /// Wire the microphone-side drift tracker onto the retained program audio
    /// it correlates against. `makeBackend` calls this once, before
    /// ``start()``: the ring belongs to the capture coordinator, so only the
    /// place that builds the coordinator can hand it over.
    ///
    /// Nothing is sampled until a selection gives it a calibrated Bluetooth
    /// speaker to measure, and nothing is recorded until a window is actually
    /// being taken — the ring stays disarmed the rest of the time.
    func attachPassiveDriftTracking(ring: ReferenceAudioRing) {
        let applier = DriftCorrectionApplier(
            isBluetooth: { [weak self] uid in
                guard let self else { return false }
                return self.stateQueue.sync { self.known[uid]?.isBluetooth == true }
            },
            currentLatencyMs: { [weak self] uid in self?.btMeasuredLatencyMs(forDevice: uid) ?? 0 },
            writeLatencyMs: { [weak self] ms, uid, persist in
                self?.writeBTDriftLatency(ms, forDevice: uid, persist: persist)
            },
            markCalibrationStale: { [weak self] uid in
                self?.btSpeakerTiming.noteDriftCorrected(uid: uid)
            },
            programIsSilent: { [weak self] in self?.btProgramIsSilent() ?? false },
            // The tracker is built below, so the backend is what the closure
            // can hold on to.
            scheduleVerify: { [weak self] _ in self?.driftTracker?.trigger(.verify) })
        let tracker = PassiveDriftTracker(
            ring: ring,
            programIsSilent: { [weak self] in self?.btProgramIsSilent() ?? false }
        ) { [weak applier] observations in
            applier?.handle(observations)
        }
        driftApplier = applier
        driftTracker = tracker
        stateQueue.async { self.refreshDriftTrackingLocked() }
    }

    /// A moment the bench data says Bluetooth alignment jumps (spec decision
    /// 2). Nothing happens unless a tracker is wired and already sampling.
    func noteDriftTrigger(_ trigger: PassiveDriftTracker.Trigger) {
        driftTracker?.trigger(trigger)
    }

    /// The last drift correction this speaker was big enough to be told about
    /// (``DriftCorrectionPolicy/surfaceAtOrAboveMs``), in signed milliseconds —
    /// the state a surface renders; `nil` when there is nothing to say.
    public func btDriftCorrectionNoticeMs(forDevice id: String) -> Double? {
        driftApplier?.surfacedCorrectionMs(forDevice: id)
    }

    /// The user has seen this speaker's drift notice.
    public func clearBTDriftCorrectionNotice(forDevice id: String) {
        driftApplier?.clearSurfacedCorrection(forDevice: id)
    }

    /// The microphone has stopped hearing the speakers — lid shut, wrong room
    /// (spec decision 9). Tracking is quietly off until a fresh calibration or
    /// selection re-arms it.
    public var btDriftTrackingIsBlind: Bool {
        driftTracker?.isBlind ?? false
    }

    /// The Bluetooth half of the drift baselines: one per selected speaker that
    /// has a MEASURED latency on file.
    ///
    /// A speaker carrying only a by-ear trim is left out on purpose. The
    /// baseline `room + trim` presumes a measured latency the sink subtracts;
    /// on a trim-only speaker the trim is a stand-in for exactly that unmeasured
    /// latency, so the speaker really arrives a whole true latency away from
    /// that baseline. Inside the sampler's search width the first window would
    /// "correct" a speaker nobody ever measured — writing a latency while the
    /// stand-in trim stays, the double compensation the wizard's Keep zeroes
    /// the trim to avoid — and outside it, it is a baseline no peak ever
    /// matches, which nearest-peak attribution can hand another speaker's jump.
    static func btDriftBaselines(uids: [String], latencies: [String: Double],
                                 trims: [String: Double],
                                 roomMs: Double) -> [PassiveDriftSampler.Baseline] {
        uids.filter { latencies[$0] != nil }.map {
            PassiveDriftSampler.Baseline(deviceUID: $0, kind: .bluetooth,
                                         expectedDelayMs: roomMs + (trims[$0] ?? 0))
        }
    }

    /// Whether a set of baselines gives passive tracking anything it can act on.
    ///
    /// One Bluetooth speaker with no anchor beside it is the case that cannot:
    /// a window's whole evidence is that one peak moved, which is equally the
    /// speaker drifting and the microphone moving, and the sampler's
    /// shared-shift guard (decision 8) needs a second speaker to tell them
    /// apart. Correcting on that guess is also self-cancelling whenever the
    /// speaker's own latency sets the BT-only reference floor
    /// (``btOnlyReferenceMs(latencies:uids:)``): raising the latency raises the
    /// floor by the same amount, the hold `reference − latency + trim` does not
    /// move, the error survives, and the next window corrects it again — the
    /// latency and the buffer marching up together for as long as the music
    /// plays. So with nothing to align against, tracking stays off.
    static func driftTrackingRuns(bluetoothCount: Int, anchorCount: Int) -> Bool {
        bluetoothCount > 1 || (bluetoothCount == 1 && anchorCount > 0)
    }

    /// On `stateQueue`. Hand the tracker the delays it should hear each
    /// selected output at, and run it only while there is something to track:
    /// a Bluetooth speaker whose latency a wizard run has MEASURED, and either
    /// a second such speaker or an anchor beside it, so a peak off baseline
    /// means the speaker moved rather than that nobody ever measured it or that
    /// the microphone did the moving.
    ///
    /// The expected delay is the room delay every output schedules against plus
    /// this device's own trim — the device's measured latency cancels, because
    /// the sink subtracts exactly what the speaker then adds. How far the sound
    /// travels to the microphone is the one unknown left, and the sampler is
    /// what establishes it.
    ///
    /// That cancellation is also why this may be rebuilt as often as the
    /// selection changes without disturbing a correction in flight: a drift
    /// correction moves the MEASURED LATENCY, which is the half of the delay
    /// term this expression does not contain, so the number it recomputes is
    /// the same one before and after. Correcting through the trim instead would
    /// make every rebuild move the baseline along with the speaker, and the
    /// next window would read the correction back as fresh error.
    func refreshDriftTrackingLocked() {   // on stateQueue
        guard let tracker = driftTracker else { return }
        let (trims, latencies) = btTrimLock.withLock { (btTrimsByUID, btLatencyMsByUID) }
        let room = Double(roomDelayLocked())
        var baselines = Self.btDriftBaselines(uids: btSelectedUIDs, latencies: latencies,
                                              trims: trims, roomMs: room)
        let bluetoothCount = baselines.count
        // Every AirPlay receiver in the selection is an anchor (spec decision
        // 13): it plays on the room reference clock and does not drift, so an
        // arrival of one off its baseline measures the MICROPHONE. Cast is
        // deliberately absent — its receivers carry an unreported output
        // residue the user's own offset stands in for, which would read as
        // microphone movement.
        for id in expectedSelected.sorted() {
            guard let device = known[id], !device.isBluetooth, !device.isCast,
                  !device.isLocalDevice else { continue }
            baselines.append(PassiveDriftSampler.Baseline(
                deviceUID: id, kind: device.kind, expectedDelayMs: room))
        }
        let runs = Self.driftTrackingRuns(bluetoothCount: bluetoothCount,
                                          anchorCount: baselines.count - bluetoothCount)
        Telemetry.log(.localPlayback, "drift_tracking_state", [
            "running": runs ? "true" : "false",
            "selectedBluetooth": String(btSelectedUIDs.count),
            "measuredBluetooth": String(bluetoothCount),
            "anchors": String(baselines.count - bluetoothCount),
            "roomMs": String(format: "%.0f", room),
            "baselines": baselines.map { "\($0.deviceUID)=\(String(format: "%.1f", $0.expectedDelayMs))" }
                .joined(separator: ","),
        ])
        guard runs else {
            tracker.setBaselines([])
            tracker.stop()
            return
        }
        tracker.setBaselines(baselines)
        tracker.start()
    }

    /// A drift correction's write: the same stored measured latency the
    /// wizard's Keep writes, and the same live splice on the sink
    /// (`setOffsetMs`), so a corrected speaker never goes silent mid-song.
    ///
    /// Not the trim, on purpose — see ``DriftCorrectionApplier``. The trim is
    /// half of what ``refreshDriftTrackingLocked`` builds the baselines from,
    /// so correcting through it would move each baseline along with the speaker
    /// and the next window would read the same error all over again.
    ///
    /// `persist` false is the in-flight slew step: in memory and on the sink,
    /// but not on disk, the same scrub-then-commit the drawer's trim makes. The
    /// in-memory map moves either way, because the applier reads it back to
    /// compute the next step and the row renders it.
    func writeBTDriftLatency(_ ms: Double, forDevice id: String, persist: Bool) {
        // A latency is a physical delay: whole milliseconds and never negative,
        // the same shape the wizard's Keep and the loader both store.
        let value = Swift.max(0, BTSyncTrim.snap(ms))
        let all: [String: Double] = btTrimLock.withLock {
            btLatencyMsByUID[id] = value
            return btLatencyMsByUID
        }
        if persist {
            do { try btTrimStore?.saveLatencies(all) } catch { StoreRecovery.noteWriteFailure(error) }
        }
        // The reference floor is a function of the slowest known latency, so a
        // correction can move it — and it must move FIRST, exactly as at the
        // wizard's Keep: pushing a latency past the reference drives the delay
        // onto `SyncTiming.totalDelayNanos`'s ≥ 0 clamp for as long as the two
        // disagree. Both hops are enqueued from `stateQueue`, so
        // `captureControlQueue` replays them in that order.
        //
        // ONLY on a committed write. A slew's steps arrive twice a second with
        // `persist` false, and moving the floor on each of them is anything but
        // inaudible: a floor move rebuilds every Bluetooth sink
        // (`BTSyncedSink.setBTOnlyBufferMs`) and re-anchors the Mac's own sink,
        // both of them a full-delay silence, inside a move whose whole purpose
        // is to be unhearable. The final step of every slew persists, so the
        // floor still lands on the corrected value — once.
        // razor: the floor lags the in-flight steps by up to the size of the
        // correction. The reference's 100 ms headroom (`btReferenceHeadroomMs`)
        // absorbs corrections under it; the sampler's 120 ms search half-width
        // means a 100–120 ms correction IS reportable, and on the floor-pinning
        // speaker its last ~20 ms of steps then ride `totalDelayNanos`'s ≥ 0
        // clamp and do nothing until the commit moves the floor — a bounded
        // transient the commit plus the next window's re-baseline recover.
        // Upgrade path if that transient ever matters: raise the floor to the
        // slew's TARGET when the slew starts rather than when it lands.
        stateQueue.async {
            if persist { self.updateBTReferenceBufferLocked() }
            self.captureControlQueue.async { [weak self] in
                self?.btSink?.setOffsetMs(Int(value), forDeviceUID: id)
            }
        }
    }

    /// Whether the program has gone quiet on the Bluetooth fan-out — the gap a
    /// correction can land in whole. "Can't tell" (no sink, nothing ever
    /// rendered) reads as music playing, so a correction slews rather than
    /// snapping on a guess.
    private func btProgramIsSilent() -> Bool {
        guard let sink = btSinkRefLock.withLock({ btSink }),
              let lastAudible = sink.lastAudibleRenderNanos() else { return false }
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        return SyncTiming.monotonicNanos(now) - lastAudible > Self.driftGapNanos
    }
}

extension NativeBackend: BTOutputControlling {

    public func setBTSyncTrim(_ ms: Double, forDevice id: String, persist: Bool) {
        // Quantise, not merely clamp (T7 §7): the ruler resolves 0.1 ms, so
        // snapping here is what keeps the readout, the ruler and the persisted
        // value from ever disagreeing about what "22.4" means.
        let value = BTSyncTrim.quantise(ms)
        let all: [String: Double] = btTrimLock.withLock {
            btTrimsByUID[id] = value
            return btTrimsByUID
        }
        // The in-memory map updates on a scrub too — only the DISK write is
        // skipped. `btSyncTrim`/`btHasSyncTrim` are read-back seams, and a
        // reader mid-drag should see what the user is hearing.
        if persist {
            do { try btTrimStore?.save(all) } catch { StoreRecovery.noteWriteFailure(error) }
            // A persisted nudge is an alignment, wherever it came from: the
            // Mac's ruler, the wizard's trim Keep, or the phone's fine-tune.
            btSpeakerTiming.noteAligned(uid: id)
            // The user moved this speaker on purpose, so the delay the drift
            // tracker expects to hear it at moved with it. A drift correction
            // never comes through here — it moves the MEASURED LATENCY, which
            // the baselines do not contain, so it leaves them alone.
            stateQueue.async { self.refreshDriftTrackingLocked() }
        }
        captureControlQueue.async { [weak self] in
            self?.btSink?.setTrimMs(value, forDeviceUID: id)
        }
    }

    public func btSyncTrim(forDevice id: String) -> Double {
        btTrimLock.withLock { btTrimsByUID[id] ?? 0 }
    }

    public func btHasSyncTrim(forDevice id: String) -> Bool {
        btTrimLock.withLock { btTrimsByUID[id] != nil }
    }

    public func resetBTAlignment(forDevice id: String) {
        btTrimLock.withLock {
            btLatencyMsByUID.removeValue(forKey: id)
            btTrimsByUID.removeValue(forKey: id)
        }
        // ONE read-modify-write of the file for both maps — and a genuine
        // delete, which `save`/`saveLatencies` (whole-map overwrites) could
        // only express by round-tripping the maps back out again.
        do { try btTrimStore?.clearAlignment(deviceUID: id) } catch { StoreRecovery.noteWriteFailure(error) }
        btSpeakerTiming.clearAligned(uid: id)
        // The reference floor is a function of the slowest KNOWN latency, so
        // dropping one can move it — same ordering as the wizard's Keep: the
        // reference first, then the sink's own two terms, both hops enqueued
        // from `stateQueue` so `captureControlQueue` replays them in order.
        stateQueue.async {
            self.updateBTReferenceBufferLocked()
            self.captureControlQueue.async { [weak self] in
                self?.btSink?.setOffsetMs(0, forDeviceUID: id)
                self?.btSink?.setTrimMs(0, forDeviceUID: id)
            }
        }
    }

    public func setBTAlignTickActive(_ active: Bool) {
        captureCoordinator?.setAlignTick(active)
    }

    public func setBTWizardTrimPreview(_ ms: Double, forDevice id: String) {
        let clamped = BTSyncTrim.clamp(ms)
        captureControlQueue.async { [weak self] in
            self?.btSink?.setTrimMs(clamped, forDeviceUID: id)
        }
    }

    public func endBTWizardTrimPreview(forDevice id: String, keepMs: Double?) {
        if let keepMs {
            setBTSyncTrim(keepMs, forDevice: id, persist: true)
        } else {
            let stored = btSyncTrim(forDevice: id)
            captureControlQueue.async { [weak self] in
                self?.btSink?.setTrimMs(stored, forDeviceUID: id)
            }
        }
    }

    public func setBTWizardTickActive(_ active: Bool, btTargetDeviceID: String?,
                                      btReferenceDeviceID: String?) {
        // NOT edge-guarded, unlike everything below: the host re-pushes a `true`
        // when the user swaps the reference mid-run, and the new reference has
        // to come back off the hold that the old one was exempt from.
        updateBTWizardParticipantHold(
            active: active, targetUID: btTargetDeviceID, referenceUID: btReferenceDeviceID)
        // Idempotent (see the protocol): everything below is an EDGE cost — a
        // tick-mode swap, an arm gate, and a re-anchor of every FIFO sink — so
        // a `false` against an already-stopped tick must be nothing at all.
        let isEdge = btTrimLock.withLock { () -> Bool in
            guard btWizardTickActive != active else { return false }
            btWizardTickActive = active
            return true
        }
        guard isEdge else { return }
        captureCoordinator?.setAlignTickMode(active ? .wizard : .off)
        // The run opens on the search stage's slow beat; the session moves it
        // on when the estimator reaches its blocks.
        if active { captureCoordinator?.setWizardTempo(bpm: AlignmentTickInjector.wizardSearchBPM) }
        // A Bluetooth target's latency is the unknown the run measures, so the
        // reference goes wide open. Only RAISED here: the tick stops at the
        // receipt, and lowering it there would drop the result the user is
        // judging onto a timeline that clamps it. `endBTWizardRun()` owns the
        // way back down.
        if active, btTargetDeviceID != nil {
            stateQueue.async {
                guard !self.btWizardReferenceRaised else { return }
                self.btWizardReferenceRaised = true
                self.updateBTReferenceBufferLocked()
            }
        }
        // The arm gate: bed only until every participating sink is playing.
        let expected = stateQueue.sync { self.btSinkEnabled ? Set(self.btSelectedUIDs) : [] }
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            if active {
                self.beginWizardArmGate(expecting: expected)
            } else {
                self.cancelWizardArmGate()
            }
        }
        // BOTH edges re-anchor every FIFO sink. The wizard swaps the producer of
        // the shared feed, which breaks frame continuity for sinks that anchor
        // once and then run as FIFOs — and after any paused stretch (the case the
        // wizard exists for) their rings have drained anyway, so their idea of
        // where a pts lands is already untrustworthy. Re-anchoring is what makes
        // the measurement, and the playback that follows it, pts-true.
        // `wizard_feed` is deliberately NOT `config_change`: this IS a new
        // timeline context, so Part 3a's anchor carry must not engage.
        captureControlQueue.async { [weak self] in
            self?.syncedLocalSink?.requestReanchor(cause: "wizard_feed")
            self?.btSink?.reanchorAll(cause: "wizard_feed")
        }
    }

    /// Hold every selected Bluetooth speaker that is NOT part of the comparison
    /// silent for the run, and let them all back in when it ends.
    ///
    /// The reference is exempt only when it is itself a Bluetooth device — a
    /// Mac reference renders through a different sink entirely and is not in
    /// this set to begin with, so passing its id costs nothing. Applied through
    /// the ordinary composed-gain seam: no rebuild, no gap, and the wizard's
    /// arm gate (which keys off `hasStartedRendering`) is unaffected because a
    /// gain of 0 is still a released, rendering sink.
    private func updateBTWizardParticipantHold(
        active: Bool, targetUID: String?, referenceUID: String?
    ) {
        stateQueue.async {
            var want: Set<String> = []
            if active, let targetUID {
                want = Set(self.btSelectedUIDs)
                    .subtracting([targetUID, referenceUID].compactMap { $0 })
            }
            let changed = want.symmetricDifference(self.btWizardHeldUIDs)
            guard !changed.isEmpty else { return }
            self.btWizardHeldUIDs = want
            for uid in changed { self.pushBTSinkGainLocked(uid) }
        }
    }

    public func stageBTMicProbe(onStarted: @escaping () -> Void,
                                onFinished: @escaping () -> Void) {
        captureCoordinator?.stageWizardMicProbe(onStarted: onStarted, onFinished: onFinished)
    }

    // MARK: Phone-driven sync calibration

    /// Each leg of the A/B receipt: the tick plays this long at
    /// the value in force before the measurement, then this long at the value
    /// it landed on. With no "before" recorded it is one four-second stretch
    /// at the current value and no swap.
    private static let companionDemoLegSeconds: TimeInterval = 2

    /// How long a stood-down run waits for the phone's measurement before
    /// giving up and putting the suspended trim back. The timer starts at audio
    /// stand-down — the pipeline tail after the last sweep frame — and the
    /// phone measures at that same tail, reports, then waits its own 20 s
    /// (`AlignmentRunController.applyTimeoutSeconds`) for the Mac's answer. So
    /// both sides give up about 20 s past the tail, and neither is left holding
    /// a run the other has abandoned.
    private static let companionReportTimeoutSeconds: TimeInterval = 20

    public var onBTAlignmentChanged: (@Sendable () -> Void)? {
        get { btSpeakerTiming.onChange }
        set { btSpeakerTiming.onChange = newValue }
    }

    public func btAlignmentReport(forDevice id: String) -> BTSpeakerTimingReport? {
        btSpeakerTiming.report(uid: id)
    }

    /// The offset this speaker has stored, which is both halves of what
    /// ``BTSpeakerTiming`` asks the store: whether the row is tuned at all, and
    /// what a reported measurement is compared against.
    ///
    /// "Tuned" is decided by whether an entry EXISTS — a speaker deliberately
    /// aligned to exactly 0 is aligned (`BTTrimStore.clearAlignment`'s whole
    /// point). Either half counts: a measured latency, or a trim standing in
    /// for one on a speaker no run has measured yet.
    func btStoredAlignmentOffsetMs(forDevice id: String) -> Double? {
        btTrimLock.withLock { btLatencyMsByUID[id] ?? btTrimsByUID[id] }
    }

    /// What names this speaker in the release analytics event: its
    /// ``btSpeakerIndexByUID`` entry, minted here the first time this install
    /// is asked about the UID and written to the same file the trims live in.
    /// Highest index plus one rather than a count, so a map that ever loses an
    /// entry cannot hand a second speaker the first one's number.
    func btSpeakerKey(forDevice id: String) -> String {
        let (index, all) = btTrimLock.withLock { () -> (Int, [String: Int]?) in
            if let existing = btSpeakerIndexByUID[id] { return (existing, nil) }
            let minted = (btSpeakerIndexByUID.values.max() ?? 0) + 1
            btSpeakerIndexByUID[id] = minted
            return (minted, btSpeakerIndexByUID)
        }
        if let all {
            do { try btTrimStore?.saveSpeakerIndex(all) } catch { StoreRecovery.noteWriteFailure(error) }
        }
        return String(index)
    }

    /// The pairing's device class, from the stash ``applyBTSnapshots(_:)``
    /// keeps — `known` is `stateQueue`-confined and this is read from three
    /// other queues.
    func btDeviceClassMinor(forDevice id: String) -> UInt32? {
        btLastUsedLock.withLock { btDeviceClassMinorByUID[id] }
    }

    /// Whether the Bluetooth manager renders at the feed's own rate — the same
    /// question `NativeCaptureCoordinator` asks its base resampler
    /// (`SyncedLocalBaseResampler.isIdentity`), from the one input that decides
    /// it. A staggered run needs this: only at the feed rate can the fan-out
    /// write two different blocks into two different delay lines.
    private var btSinkRendersAtFeedRate: Bool {
        let rate = btSinkRefLock.withLock { btSink }?.renderSampleRate
            ?? Double(PCMFormat.airplay.sampleRate)
        return abs(rate - Double(PCMFormat.airplay.sampleRate)) < 1e-12
    }

    public func startCompanionAlignmentProbe(targetID: String, referenceID: String,
                                             onStarted: @escaping () -> Void,
                                             onFinished: @escaping () -> Void) -> String? {
        guard let coordinator = captureCoordinator else {
            return "This Mac can't measure speaker timing right now. Reconnect the speaker and try again."
        }
        // Only this layer knows whether the target has a delay line to measure
        // and how many other Bluetooth speakers are in the room. The
        // audible-target / usable-reference half of the preconditions is answered by
        // the wiring layer, off the same rule the snapshot publishes.
        let (targetIsLive, otherBTAudible, referenceIsBluetooth, targetName) = stateQueue.sync {
            (self.btSinkEnabled && self.btSelectedUIDs.contains(targetID),
             self.btSelectedUIDs.contains { $0 != targetID },
             self.known[referenceID]?.isBluetooth == true,
             self.known[targetID]?.name)
        }
        guard targetIsLive else {
            if let targetName {
                return "\u{201C}\(targetName)\u{201D} isn't playing right now, so there's nothing to measure."
            }
            return "That speaker isn't playing right now, so there's nothing to measure."
        }
        // Two Bluetooth speakers cannot be measured from one recording unless
        // their sweeps are separated in time — see `AlignmentTickInjector
        // .ProbeShape.staggered`.
        let staggered = referenceIsBluetooth || otherBTAudible
        // The staggered shape rests on the fan-out writing the sweep-carrying
        // block into one delay line and the sweep-free block into every other,
        // which `NativeCaptureCoordinator.deliver` can only do while the
        // Bluetooth manager renders at the feed's own rate. Off that rate it
        // falls back to one feed for everybody and BOTH speakers play BOTH
        // sweeps — a confident number attributable to neither speaker, which is
        // worse than no number at all.
        if staggered, !btSinkRendersAtFeedRate {
            return "Can't tell these two speakers apart right now. Try again in a moment."
        }
        let runID = btTrimLock.withLock { () -> UUID? in
            guard companionAlignmentRun == nil, companionDemoTargetUID == nil,
                  btWizardTickActive == false else { return nil }
            let run = CompanionAlignmentRun(
                targetUID: targetID,
                phase: .probe,
                staggerMs: staggered ? AlignmentTickInjector.probeStaggerSeconds * 1_000 : 0,
                // SUSPEND the user's trim for the run, exactly as the Mac's own
                // wizard does: latency and trim are the same linear term in the
                // delay, so sweeps judged with the nudge still applied measure
                // `trueLatency + trim` and that is what would get stored. Put
                // back by `abandonCompanionProbe` on every exit but a
                // measurement, whose Keep writes both terms itself.
                trimAtSessionStartMs: btTrimsByUID[targetID] ?? 0,
                liveTrimMs: 0)
            companionAlignmentRun = run
            return run.id
        }
        guard let runID else {
            return "This Mac is already measuring a speaker. Finish that first."
        }
        setBTWizardTrimPreview(0, forDevice: targetID)
        // Reuse the wizard's whole staging: the participant hold (every other
        // Bluetooth speaker silent for the run), the raised Bluetooth-only
        // reference, the arm gate that waits for every sink to release, and
        // the re-anchor both edges do.
        setBTWizardTickActive(true, btTargetDeviceID: targetID, btReferenceDeviceID: referenceID)
        coordinator.stageCompanionMicProbe(
            staggered: staggered,
            referenceOnEngine: !referenceIsBluetooth,
            downWindowUID: referenceIsBluetooth ? referenceID : nil,
            upWindowUID: targetID,
            onStarted: onStarted,
            onFinished: { [weak self] in
                onFinished()
                // The air lags the feed by the sinks' pipeline delay, so the
                // AUDIO stands down a tail's worth after the last sweep FRAME —
                // the same figure the mic session waits out (`MicProbeSession
                // .pipelineTailSeconds`). The RUN outlives it: the phone waits
                // its own tail after being told the sweeps finished, then
                // transforms the recording, and only then reports.
                self?.captureControlQueue.asyncAfter(
                    deadline: .now() + MicProbeSession.pipelineTailSeconds
                ) { [weak self] in
                    self?.standDownCompanionProbeAudio(runID: runID, targetID: targetID)
                }
            })
        return nil
    }

    public func cancelCompanionAlignmentProbe(targetID: String) {
        if let audition = btTrimLock.withLock({ companionAudition }),
           audition.targetID == targetID {
            endCompanionAlignmentAudition(targetID: targetID, completion: { _ in })
            return
        }
        if let run = takeCompanionProbeRun({ $0.targetUID == targetID }) {
            abandonCompanionProbe(run)
        }
        endCompanionDemo(targetID: targetID)
        // A fine-tune session cancelled rather than ended keeps what the user
        // nudged: this is the same commit the phone's own stop sends.
        endCompanionTickSession(targetID: targetID, persist: true)
    }

    /// Silence the sweeps and put the room back — holds released, tick mode
    /// off, the raised Bluetooth reference lowered — while KEEPING the run
    /// record, which the phone's measurement still has to find. Arms the
    /// report timeout, the last of the four ways an awaiting run ends.
    ///
    /// Keyed by run id, so a timer armed by one run can never stand down its
    /// successor.
    private func standDownCompanionProbeAudio(runID: UUID, targetID: String) {
        let moved = btTrimLock.withLock { () -> Bool in
            guard var run = companionAlignmentRun,
                  run.id == runID, run.phase == .probe else { return false }
            run.phase = .awaitingReport
            companionAlignmentRun = run
            return true
        }
        guard moved else { return }
        setBTWizardTickActive(false, btTargetDeviceID: targetID, btReferenceDeviceID: nil)
        endBTWizardRun()
        captureControlQueue.asyncAfter(
            deadline: .now() + Self.companionReportTimeoutSeconds
        ) { [weak self] in
            guard let self, let run = self.takeCompanionProbeRun({ $0.id == runID }) else { return }
            self.abandonCompanionProbe(run)
        }
    }

    /// Take the probe run (playing or awaiting its report) that `match`
    /// accepts out of the slot, leaving a fine-tune session alone. The caller
    /// then puts the room back.
    private func takeCompanionProbeRun(
        _ match: (CompanionAlignmentRun) -> Bool
    ) -> CompanionAlignmentRun? {
        btTrimLock.withLock { () -> CompanionAlignmentRun? in
            guard let run = companionAlignmentRun, run.phase != .tick, match(run) else { return nil }
            companionAlignmentRun = nil
            return run
        }
    }

    /// Put the room back after a run that produced no measurement — the
    /// phone's Cancel, a client that vanished, or a report that never came.
    /// The sweeps are silenced only if they were still playing, and the trim
    /// the staging suspended goes back on the sink whichever it was.
    private func abandonCompanionProbe(_ run: CompanionAlignmentRun) {
        if run.phase == .probe {
            setBTWizardTickActive(false, btTargetDeviceID: run.targetUID, btReferenceDeviceID: nil)
            endBTWizardRun()
        }
        setBTWizardTrimPreview(run.trimAtSessionStartMs, forDevice: run.targetUID)
    }

    public func applyCompanionAlignmentMeasurement(targetID: String,
                                                   offsetMs: Double,
                                                   confidence: Double) -> CompanionAlignmentApplyResult {
        guard let run = takeCompanionProbeRun({ $0.targetUID == targetID }) else {
            return .refused("That measurement isn't running any more. Start it again.")
        }
        // A phone quick enough to report before the tail elapsed leaves the
        // sweeps still playing; silence them here rather than letting the
        // stand-down find a run that has already been taken.
        if run.phase == .probe {
            setBTWizardTickActive(false, btTargetDeviceID: targetID, btReferenceDeviceID: nil)
        }
        // The phone reports RAW: what its microphone heard, with no sign
        // convention or trim arithmetic on the wire. Trim semantics are the
        // Mac's, and so is the stagger — the phone never knew the sweeps were
        // separated, so the separation comes out here.
        let applied = btMeasuredLatencyMs(forDevice: targetID) ?? 0
        let range = btWizardLatencyRangeMs(forDevice: targetID)
        let corrected = BTSyncTrim.snap(applied + (offsetMs - run.staggerMs))
        let value = Swift.min(Swift.max(corrected, range.lowerBound), range.upperBound)
        // A re-check after a measurement made while the clock was still
        // settling: how far the early number was off, and how much the clock
        // stepped in between. Gathered from real use, never acted on. Read
        // BEFORE the record below, which puts this measurement over the mark.
        if let jumpSumMs = btSpeakerTiming.earlyAlignmentJumpSumMs(uid: targetID) {
            Telemetry.log(.localPlayback, "bt_align_recheck_after_early", [
                "uid": targetID,
                "earlyMs": String(Int(applied)),
                "jumpSumMs": String(format: "%.1f", jumpSumMs),
                "recheckMs": String(format: "%.1f", offsetMs - run.staggerMs),
            ])
        }
        // ADR 0001: a measurement that lands within `AlignmentThresholds
        // .replaceMs` of what is stored leaves the stored number alone, so a
        // re-check that agrees never moves the speaker, and the phone reads
        // `correctedMs == 0` as "the number stood". This call also records the
        // alignment — as the microphone's, not the ear's — which is why the
        // Keep below records none.
        let decision = btSpeakerTiming.recordMeasurement(uid: targetID, correctedMs: value)
        let keptMs = decision == .replace ? value : applied
        // Every measurement, whether the run offered a re-check or not: what
        // the microphone heard (`rawOffsetMs`) with the phone's own confidence
        // (a peak-to-sidelobe ratio: ~1 is noise, a clean arrival runs to the
        // hundreds), what it became after the stagger and the stored latency
        // (`correctedMs`), and what the speaker was left on (`keptMs`) — the
        // measurement clamped to the sink's reachable range when it replaced
        // the stored number, the stored number itself when it did not
        // (`replaced=0`). A `keptMs` pinned to a range edge with `clamped=1`
        // is a measurement the range could not express — the scatter to chase
        // separately from a low confidence, which is a recording the room or
        // the levels spoiled. Diagnostic while the one-shot measurement is
        // proven on hardware; drop it once it is.
        Telemetry.log(.localPlayback, "bt_align_measurement", [
            "uid": targetID,
            "confidence": String(format: "%.1f", confidence),
            "rawOffsetMs": String(format: "%.1f", offsetMs),
            "staggerMs": String(format: "%.1f", run.staggerMs),
            "priorLatencyMs": String(Int(applied)),
            "correctedMs": String(format: "%.1f", corrected),
            "keptMs": String(format: "%.1f", keptMs),
            "replaced": decision == .replace ? "1" : "0",
            "clamped": value == corrected ? "0" : "1",
            "rangeLoMs": String(Int(range.lowerBound)),
            "rangeHiMs": String(Int(range.upperBound)),
            "clockState": btAlignmentReport(forDevice: targetID)?.clockState.rawValue ?? "nil",
        ])
        btTrimLock.withLock { companionPreMeasurementLatencyMsByUID[targetID] = applied }
        // The Mac wizard's Keep, exactly: the kept latency written, trim
        // zeroed (it was a manual stand-in for the latency just measured).
        endBTWizardLatencyPreview(forDevice: targetID, keepMs: keptMs, recordsAlignment: false)
        // Lowers the raised Bluetooth reference and releases the holds. A run
        // already stood down did both at the tail, and both are idempotent.
        endBTWizardRun()
        return .applied(measuredMs: offsetMs - run.staggerMs,
                        correctedMs: Swift.max(0, keptMs) - applied)
    }

    public func startCompanionAlignmentAudition(
        targetID: String, referenceID: String,
        onReleased: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion("This Mac can't play speaker clicks right now.")
                onReleased()
                return
            }
            let now = Date()
            let claimed = self.btTrimLock.withLock { () -> (UUID?, String?) in
                if var current = self.companionAudition {
                    guard current.targetID == targetID, current.referenceID == referenceID else {
                        return (nil, "This Mac is already measuring a speaker. Finish that first.")
                    }
                    switch current.phase {
                    case .preparing:
                        current.startCompletions.append(completion)
                        // A joined start is answered by the audition it joined,
                        // and retired with it.
                        current.releaseCallbacks.append(onReleased)
                        self.companionAudition = current
                        return (nil, nil)
                    case .active:
                        current.releaseCallbacks.append(onReleased)
                        self.companionAudition = current
                        return (nil, "")
                    case .cleaning:
                        return (nil, "This Mac is restoring the speaker levels. Try again shortly.")
                    }
                }
                guard self.companionAlignmentRun == nil, self.companionDemoTargetUID == nil,
                      !self.btWizardTickActive else {
                    return (nil, "This Mac is already measuring a speaker. Finish that first.")
                }
                let trim = self.btTrimsByUID[targetID] ?? 0
                let run = CompanionAlignmentRun(targetUID: targetID, phase: .tick,
                                                staggerMs: 0, trimAtSessionStartMs: trim,
                                                liveTrimMs: trim)
                self.companionAlignmentRun = run
                self.companionProgramSuppressed = true
                var lifecycle = CompanionAuditionLifecycle(
                    id: run.id, targetID: targetID, referenceID: referenceID,
                    preparationDeadline: now.addingTimeInterval(self.companionAuditionPreparationSeconds),
                    leaseDeadline: now.addingTimeInterval(self.companionAuditionLeaseSeconds),
                    startCompletions: [completion])
                lifecycle.releaseCallbacks = [onReleased]
                self.companionAudition = lifecycle
                return (run.id, nil)
            }
            guard let id = claimed.0 else {
                if let reason = claimed.1 {
                    let refused = !reason.isEmpty
                    completion(refused ? reason : nil)
                    // Refused before any reservation was claimed, so there is
                    // nothing to wait for: retire this request right behind its
                    // own reply. A start that JOINED an existing audition took
                    // the other branch and is retired with that audition.
                    if refused { onReleased() }
                }
                return
            }
            let preparationSeconds = self.companionAuditionPreparationSeconds
            DispatchQueue.main.asyncAfter(deadline: .now() + preparationSeconds) { [weak self] in
                self?.failCompanionAuditionPreparation(id: id,
                    reason: "Starting the speaker clicks took too long. Try again.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.companionAuditionLeaseSeconds) {
                [weak self] in self?.beginCompanionAuditionCleanup(id: id,
                    reason: "The speaker click session ended.")
            }
            self.stateQueue.async {
                self.companionTickParticipants = [targetID, referenceID]
                let btUIDs = Array(self.btSelectedUIDs)
                let castIDs = Array(self.castSelectedIDs)
                let holds = self.outputIDs.filter {
                    self.added.contains($0.key) && $0.key != targetID && $0.key != referenceID
                }
                // Name every hold BEFORE any of them can answer. The Bluetooth
                // and Cast writes belong here as much as the engine ones do:
                // they reach their sinks on `captureControlQueue`, so clicks
                // starting on an engine-only count began while another speaker
                // was still at its old gain.
                var required = Set(holds.keys)
                required.insert(Self.localDeviceID)
                required.formUnion(btUIDs)
                required.formUnion(castIDs)
                let preparing = self.btTrimLock.withLock { () -> Bool in
                    guard var audition = self.companionAudition, audition.id == id,
                          audition.phase == .preparing else { return false }
                    audition.preparationPending = required
                    self.companionAudition = audition
                    return true
                }
                guard preparing else { return }
                for uid in btUIDs {
                    self.pushBTSinkGainLocked(uid) { [weak self] in
                        self?.noteCompanionAuditionPreparation(id: id, success: true, output: uid)
                    }
                }
                for castID in castIDs {
                    self.pushCastLevelLocked(castID) { [weak self] in
                        self?.noteCompanionAuditionPreparation(id: id, success: true, output: castID)
                    }
                }
                self.pushSyncedLocalGain()
                for (outputID, engineID) in holds.map({ ($0.value, $0.key) }) {
                    self.pushVolume(outputID, id: engineID,
                                    engineValue: self.engineVolume(forID: engineID,
                                        uiVolume: self.known[engineID]?.volume ?? 0),
                                    uiLevel: nil) { [weak self] success in
                        self?.noteCompanionAuditionPreparation(id: id, success: success,
                                                                 output: engineID)
                    }
                }
                if let local = self.localPlaybackEngine {
                    local.setOutputSuppressed(true) { [weak self] in
                        self?.noteCompanionAuditionPreparation(id: id, success: true,
                                                                 output: Self.localDeviceID)
                    }
                } else {
                    self.noteCompanionAuditionPreparation(id: id, success: true,
                                                           output: Self.localDeviceID)
                }
            }
        }
    }

    /// One hold has answered.
    ///
    /// Idempotent per output — the key comes out of ``CompanionAuditionLifecycle
    /// /preparationPending`` exactly once, so a repeat acknowledgement stands in
    /// for nothing. A failure is recorded AND the audition revoked to
    /// `.cleaning` in the same lock turn, which is what makes a failure that
    /// lands before activation win: every later success finds a phase that is
    /// no longer `.preparing`. The cleanup itself is scheduled once, outside
    /// the lock.
    /// The engine value `id` is owed RIGHT NOW. On `stateQueue`, and only
    /// meaningful once ``companionTickParticipants`` has been cleared.
    ///
    /// A muted speaker is owed silence, not the level in ``stashedVolume`` —
    /// the stash is what an UNMUTE would restore, so pushing it at cleanup
    /// turned a muted speaker back on. Reads state, writes none: the mute and
    /// the stored fader both stay exactly as the user left them.
    private func currentCompanionRestoreValue(forID id: String) -> Double {   // on stateQueue
        if muted.contains(id) {
            return known[id]?.supportsAirPlay2 == false ? -1.0 : Self.engineVolume(fraction: 0)
        }
        return engineVolume(forID: id, uiVolume: stashedVolume[id] ?? known[id]?.volume ?? 0)
    }

    /// Claim the audition's single trim persistence and hand back what to
    /// write, or `nil` when it is already claimed or the nudges never moved.
    ///
    /// MUST be called with `btTrimLock` held, and the caller MUST write outside
    /// it — ``setBTSyncTrim(_:forDevice:persist:)`` takes the same lock.
    func claimCompanionAuditionTrimLocked(
        id: UUID
    ) -> (targetID: String, ms: Double)? {   // btTrimLock held
        guard var audition = companionAudition, audition.id == id,
              !audition.trimPersistenceClaimed else { return nil }
        audition.trimPersistenceClaimed = true
        companionAudition = audition
        guard let run = companionAlignmentRun, run.id == id, run.phase == .tick,
              run.liveTrimMs != run.trimAtSessionStartMs else { return nil }
        return (run.targetUID, run.liveTrimMs)
    }

    private func noteCompanionAuditionPreparation(id: UUID, success: Bool, output: String) {
        enum Next { case ignore, refuse, activate }
        let next = btTrimLock.withLock { () -> Next in
            guard var audition = companionAudition, audition.id == id,
                  audition.phase == .preparing,
                  audition.preparationPending.remove(output) != nil else { return .ignore }
            if !success {
                audition.preparationFailure = output
                audition.phase = .cleaning
                companionAudition = audition
                return .refuse
            }
            companionAudition = audition
            return audition.preparationPending.isEmpty ? .activate : .ignore
        }
        switch next {
        case .ignore:
            break
        case .refuse:
            DispatchQueue.main.async { [weak self] in
                self?.beginCompanionAuditionCleanup(id: id, reason: nil)
            }
        case .activate:
            DispatchQueue.main.async { [weak self] in self?.activateCompanionAudition(id: id) }
        }
    }

    private func failCompanionAuditionPreparation(id: UUID, reason: String) {
        let preparing = btTrimLock.withLock {
            companionAudition?.id == id && companionAudition?.phase == .preparing
        }
        if preparing { beginCompanionAuditionCleanup(id: id, reason: reason) }
    }

    private func companionAuditionPairIsLive(targetID: String, referenceID: String) -> Bool {
        stateQueue.sync {
            func live(_ id: String) -> Bool {
                guard let device = known[id], device.isAvailable else { return false }
                if id == Self.localDeviceID { return selectedDevicesQuery?(id) ?? false }
                if device.isBluetooth { return btSelectedUIDs.contains(id) }
                if device.isCast { return castSelectedIDs.contains(id) }
                return expectedSelected.contains(id) && added.contains(id)
            }
            return targetID != referenceID && live(targetID) && live(referenceID)
        }
    }

    private func activateCompanionAudition(id: UUID) {
        guard let current = btTrimLock.withLock({ companionAudition }),
              current.id == id, current.phase == .preparing else { return }
        // The live-pair read waits on `stateQueue`; no lock is held across it.
        guard Date() < current.preparationDeadline,
              companionAuditionPairIsLive(targetID: current.targetID,
                                          referenceID: current.referenceID) else {
            failCompanionAuditionPreparation(id: id,
                reason: "The speaker pair changed before clicks could start.")
            return
        }
        // Claim `.active` BEFORE the synchronous pacer start, re-reading the
        // same state and the ORIGINAL deadline. A hold failure that landed
        // while the pair read was waiting has already moved this audition to
        // `.cleaning`, and it must win: otherwise clicks start over a speaker
        // that was never quieted, and the refusal arrives too late to stop it.
        enum Claim { case claimed([@Sendable (String?) -> Void]), expired, gone }
        let claim = btTrimLock.withLock { () -> Claim in
            guard var audition = companionAudition, audition.id == id,
                  audition.phase == .preparing, audition.preparationFailure == nil,
                  audition.preparationPending.isEmpty else { return .gone }
            guard Date() < audition.preparationDeadline else { return .expired }
            audition.phase = .active
            let callbacks = audition.startCompletions
            audition.startCompletions = []
            companionAudition = audition
            return .claimed(callbacks)
        }
        switch claim {
        case .gone:
            return
        case .expired:
            failCompanionAuditionPreparation(id: id,
                reason: "Starting the speaker clicks took too long. Try again.")
        case .claimed(let callbacks):
            setBTWizardTickActive(true, btTargetDeviceID: nil, btReferenceDeviceID: nil)
            callbacks.forEach { $0(nil) }
            monitorCompanionAuditionPair(id: id)
        }
    }

    private func monitorCompanionAuditionPair(id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let audition = self.btTrimLock.withLock({ self.companionAudition }),
                  audition.id == id, audition.phase == .active else { return }
            if !self.companionAuditionPairIsLive(targetID: audition.targetID,
                                                 referenceID: audition.referenceID) {
                self.beginCompanionAuditionCleanup(id: id,
                    reason: "The speaker pair changed during the clicks.")
            } else {
                self.monitorCompanionAuditionPair(id: id)
            }
        }
    }

    public func endCompanionAlignmentAudition(
        targetID: String, completion: @escaping @Sendable (String?) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { completion(nil); return }
            let outcome = self.btTrimLock.withLock { () -> (UUID?, String?) in
                guard var audition = self.companionAudition else { return (nil, nil) }
                guard audition.targetID == targetID else {
                    return (nil, "A different speaker click session is running.")
                }
                if let deadline = audition.cleanupDeadline, Date() >= deadline {
                    return (nil, "Restoring the speaker levels took too long. Try again shortly.")
                }
                audition.stopCompletions.append(completion)
                self.companionAudition = audition
                return (audition.id, nil)
            }
            if let id = outcome.0 { self.beginCompanionAuditionCleanup(id: id, reason: nil) }
            else { completion(outcome.1) }
        }
    }

    /// Put the room back and retire the audition. Runs exactly ONCE per
    /// audition, gated on ``CompanionAuditionLifecycle/cleanupStarted`` rather
    /// than on the phase: a failed preparation has already marked `.cleaning`
    /// under the lock, and its cleanup still has to run.
    func beginCompanionAuditionCleanup(id: UUID, reason: String?) {
        let started = btTrimLock.withLock { () -> ([@Sendable (String?) -> Void], String?)? in
            guard var audition = companionAudition, audition.id == id,
                  !audition.cleanupStarted else { return nil }
            audition.cleanupStarted = true
            audition.phase = .cleaning
            audition.cleanupDeadline = Date().addingTimeInterval(companionAuditionStopSeconds)
            let callbacks = audition.startCompletions
            audition.startCompletions = []
            companionAudition = audition
            // A recorded hold failure names the refusal, whichever caller got
            // here first — a stop arriving in the same turn must not relabel it.
            let refusal = audition.preparationFailure
                .map { "Couldn't quiet \($0) for the speaker clicks." } ?? reason
            return (callbacks, refusal)
        }
        guard let startCallbacks = started?.0 else { return }
        let refusal = started?.1
        startCallbacks.forEach { $0(refusal ?? "The speaker clicks were stopped.") }
        setBTWizardTickActive(false, btTargetDeviceID: nil, btReferenceDeviceID: nil)
        endBTWizardRun()
        btTrimLock.withLock { companionProgramSuppressed = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + companionAuditionStopSeconds) { [weak self] in
            self?.timeoutCompanionAuditionStop(id: id)
        }
        stateQueue.async {
            self.companionTickParticipants = nil
            for uid in self.btSelectedUIDs { self.pushBTSinkGainLocked(uid) }
            for castID in self.castSelectedIDs { self.pushCastLevelLocked(castID) }
            self.pushSyncedLocalGain()
            let outputs = self.outputIDs.filter { self.added.contains($0.key) }
            self.btTrimLock.withLock {
                guard self.companionAudition?.id == id else { return }
                self.companionAudition?.restoreOutputs = Dictionary(
                    uniqueKeysWithValues: outputs.map { ($0.value, $0.key) })
            }
            for (engineID, outputID) in outputs {
                self.pushCompanionAuditionRestore(id: id, outputID: outputID, engineID: engineID)
            }
            self.btTrimLock.withLock {
                guard self.companionAudition?.id == id else { return }
                self.companionAudition?.cleanupPrepared = true
            }
            self.checkCompanionAuditionDrainLocked()
        }
        if let local = localPlaybackEngine {
            local.setOutputSuppressed(false) { [weak self] in
                self?.stateQueue.async {
                    self?.btTrimLock.withLock {
                        guard self?.companionAudition?.id == id else { return }
                        self?.companionAudition?.localRestored = true
                    }
                    self?.checkCompanionAuditionDrainLocked()
                }
            }
        } else {
            stateQueue.async {
                self.btTrimLock.withLock {
                    guard self.companionAudition?.id == id else { return }
                    self.companionAudition?.localRestored = true
                }
                self.checkCompanionAuditionDrainLocked()
            }
        }
    }

    /// Issue one restoration write and record what it actually completes at.
    /// On `stateQueue`.
    private func pushCompanionAuditionRestore(id: UUID, outputID: OutputID,
                                              engineID: String) {   // on stateQueue
        let value = currentCompanionRestoreValue(forID: engineID)
        pushVolume(outputID, id: engineID, engineValue: value, uiLevel: nil) { [weak self] ok in
            self?.noteCompanionAuditionRestoreCompleted(id: id, outputID: outputID,
                                                        value: value, ok: ok)
        }
    }

    /// Record a restoration write's real outcome. Both call sites are on
    /// `stateQueue`: `pushVolume`'s supersede branch and `issueVolumePush`'s
    /// completion.
    ///
    /// A superseded push is answered `false` while the newer write is already
    /// sitting in ``volumePending``, which is how the two are told apart — and
    /// why a superseded answer records nothing and the drain keeps waiting,
    /// instead of reading it as this value having reached the speaker.
    private func noteCompanionAuditionRestoreCompleted(id: UUID, outputID: OutputID,
                                                       value: Double, ok: Bool) { // stateQueue
        guard volumePending[outputID] == nil else { return }
        btTrimLock.withLock {
            guard var audition = companionAudition, audition.id == id else { return }
            audition.restoreCompleted[outputID] = CompanionRestoreCompletion(value: value, ok: ok)
            companionAudition = audition
        }
    }

    /// The audition is retired here and nowhere else: every restoration write
    /// has completed, so no late write can reach a new engine session.
    ///
    /// The whole sequence stays on `stateQueue` — check the writes, claim and
    /// persist the trim, then remove the run and reservation. No queue wait and
    /// no main hop happens inside it, so a user volume edit already queued on
    /// this queue runs BEFORE the check and an edit made after it is an
    /// ordinary new write against a released backend. `setBTSyncTrim` is called
    /// with the lock RELEASED, because it takes the same lock.
    func checkCompanionAuditionDrainLocked() { // stateQueue
        guard let audition = btTrimLock.withLock({ companionAudition }),
              audition.phase == .cleaning, audition.cleanupPrepared, audition.localRestored,
              audition.restoreOutputs.keys.allSatisfy({ !volumeInFlight.contains($0) &&
                                                        volumePending[$0] == nil }) else { return }
        // Nothing is in flight, so what each speaker is owed can be compared
        // against what it actually got. A user edit made during cleanup, a
        // mute, or a superseded restore all show up as a mismatch here — and
        // `lastVolumeOutcome` is deliberately not consulted: it carries the
        // outcome of whatever wrote last, including the user's own edit, which
        // is not evidence about the restoration at all.
        var reissued = false
        for (outputID, engineID) in audition.restoreOutputs {
            let want = currentCompanionRestoreValue(forID: engineID)
            guard audition.restoreCompleted[outputID]?.value != want else { continue }
            pushCompanionAuditionRestore(id: audition.id, outputID: outputID, engineID: engineID)
            reissued = true
        }
        // A value that completed and still differs cannot happen (it is a pure
        // function of state), so this terminates; a value that FAILED at the
        // level it is owed is reported below rather than retried forever.
        guard !reissued else { return }
        let failure = audition.restoreOutputs.first {
            audition.restoreCompleted[$0.key]?.ok == false
        }?.value
        if let persist = btTrimLock.withLock({ claimCompanionAuditionTrimLocked(id: audition.id) }) {
            setBTSyncTrim(persist.ms, forDevice: persist.targetID, persist: true)
        }
        let retired = btTrimLock.withLock { () -> ([@Sendable (String?) -> Void],
                                                   [@Sendable () -> Void])? in
            guard let current = companionAudition, current.id == audition.id,
                  current.phase == .cleaning else { return nil }
            companionAudition = nil
            if companionAlignmentRun?.id == audition.id { companionAlignmentRun = nil }
            return (current.stopCompletions, current.releaseCallbacks)
        }
        guard let retired else { return }
        if let failure {
            Telemetry.log(.localPlayback, "companion_audition_restore_failed", ["output": failure])
        }
        DispatchQueue.main.async {
            retired.0.forEach { $0(failure.map { "Couldn't restore \($0)'s level." }) }
            // After the reservation is gone, never before — this is the signal
            // the executable retires its owner on.
            retired.1.forEach { $0() }
        }
    }

    private func timeoutCompanionAuditionStop(id: UUID) {
        let timedOut = btTrimLock.withLock { () -> ([@Sendable (String?) -> Void],
                                              [OutputID: String], Bool) in
            guard var audition = companionAudition, audition.id == id,
                  audition.phase == .cleaning else { return ([], [:], true) }
            let callbacks = audition.stopCompletions
            audition.stopCompletions = []
            companionAudition = audition
            return (callbacks, audition.restoreOutputs, audition.localRestored)
        }
        guard !timedOut.0.isEmpty else { return }
        stateQueue.async {
            let affected: String
            if !timedOut.2 {
                affected = self.known[Self.localDeviceID]?.name ?? "This Mac"
            } else {
                affected = timedOut.1.first {
                    self.volumeInFlight.contains($0.key) || self.volumePending[$0.key] != nil
                }?.value ?? timedOut.1.first {
                    self.lastVolumeOutcome[$0.key] == false
                }?.value ?? "a speaker"
            }
            DispatchQueue.main.async {
                timedOut.0.forEach {
                    $0("Restoring \(affected)'s level took too long. Try again shortly.")
                }
            }
        }
    }

    public func setCompanionAlignmentTick(targetID: String, active: Bool) -> String? {
        if btTrimLock.withLock({ companionAudition != nil }) {
            return "This Mac is already playing or restoring speaker clicks. Finish that first."
        }
        if active {
            // A user who walked out of the A/B demo straight into fine-tune
            // ends it here rather than being refused for it. The demo's two
            // pending blocks are left to fire: the 2 s one re-pushes the
            // stored latency, the 4 s one finds the demo already over.
            endCompanionDemo(targetID: targetID)
            let claimed = btTrimLock.withLock { () -> Bool in
                if let run = companionAlignmentRun {
                    // Already ticking for this device: idempotent.
                    return run.targetUID == targetID && run.phase == .tick
                }
                guard companionDemoTargetUID == nil, btWizardTickActive == false else { return false }
                let trim = btTrimsByUID[targetID] ?? 0
                companionAlignmentRun = CompanionAlignmentRun(
                    targetUID: targetID, phase: .tick,
                    staggerMs: 0, trimAtSessionStartMs: trim, liveTrimMs: trim)
                return true
            }
            guard claimed else {
                return "This Mac is already measuring a speaker. Finish that first."
            }
            // The companion budget is ~10 min, long enough that a by-ear
            // session is never cut off mid-tune. The real switch-off is the
            // session's own exits — tick-off, cancel, a client that vanished —
            // and the budget only bounds a phone that walked away.
            captureCoordinator?.setAlignTickMode(.companion)
        } else {
            endCompanionTickSession(targetID: targetID, persist: true)
        }
        return nil
    }

    /// End a fine-tune session for `targetID`, if one is up.
    ///
    /// `persist` writes down whatever the nudges reached — the trim persists
    /// when the session ends — which is every ordinary way out:
    /// the phone leaving the sheet, a cancel, a client that vanished. Clear is
    /// the one exception (`clearCompanionAlignmentTuning`): it discards the
    /// live value instead, so a tick-off arriving after it cannot recreate the
    /// entry Clear just deleted. A device with no session left is a no-op
    /// either way, whichever order the phone sends the two in.
    ///
    /// A session whose trim never moved writes nothing at all, so merely
    /// opening and closing the ticks cannot mint an alignment entry for a
    /// device that had none.
    private func endCompanionTickSession(targetID: String, persist: Bool) {
        let ended = btTrimLock.withLock { () -> CompanionAlignmentRun? in
            guard companionAudition == nil else { return nil }
            guard let run = companionAlignmentRun,
                  run.targetUID == targetID, run.phase == .tick else { return nil }
            companionAlignmentRun = nil
            return run
        }
        guard let ended else { return }
        setBTAlignTickActive(false)
        guard persist, ended.liveTrimMs != ended.trimAtSessionStartMs else { return }
        // The session's nudges were live-only until here; ending it is what
        // writes them down.
        setBTSyncTrim(ended.liveTrimMs, forDevice: targetID, persist: true)
        btSpeakerTiming.noteAligned(uid: targetID)
    }

    public func nudgeCompanionAlignmentTrim(targetID: String, deltaMs: Double) -> String? {
        let next = btTrimLock.withLock { () -> Double? in
            if let audition = companionAudition,
               (audition.targetID != targetID || audition.phase != .active) { return nil }
            guard var run = companionAlignmentRun,
                  run.targetUID == targetID, run.phase == .tick else { return nil }
            run.liveTrimMs = BTSyncTrim.clamp(run.liveTrimMs + deltaMs)
            companionAlignmentRun = run
            return run.liveTrimMs
        }
        guard let next else {
            return "Start the fine-tune before nudging it."
        }
        setBTWizardTrimPreview(next, forDevice: targetID)
        return nil
    }

    public func revertCompanionAlignmentNudge(targetID: String) -> String? {
        let restored = btTrimLock.withLock { () -> Double? in
            if let audition = companionAudition,
               (audition.targetID != targetID || audition.phase != .active) { return nil }
            guard var run = companionAlignmentRun,
                  run.targetUID == targetID, run.phase == .tick else { return nil }
            run.liveTrimMs = run.trimAtSessionStartMs
            companionAlignmentRun = run
            return run.liveTrimMs
        }
        guard let restored else {
            return "There's no fine-tune to undo."
        }
        setBTWizardTrimPreview(restored, forDevice: targetID)
        return nil
    }

    public func clearCompanionAlignmentTuning(targetID: String) {
        let owned = btTrimLock.withLock { () -> Bool in
            guard var audition = companionAudition, audition.targetID == targetID else { return false }
            // Clear WINS over the audition's own persistence as well as over a
            // fine-tune session: taking the one claim here is what stops the
            // drain writing the nudge back and recreating the entry this call
            // is about to delete.
            audition.trimPersistenceClaimed = true
            companionAudition = audition
            return true
        }
        if owned {
            endCompanionAlignmentAudition(targetID: targetID, completion: { _ in })
        }
        // Clear WINS over a fine-tune that is still up. Ending the session
        // FIRST, and without persisting, is what makes that true: a session
        // left standing would write its live value back the moment the phone
        // left the sheet, recreating the entry this call just deleted and
        // putting the row back to "tuned" a second after it read "Timing not
        // set". Discarding here also means the order the phone sends the two
        // commands in cannot change the outcome.
        endCompanionTickSession(targetID: targetID, persist: false)
        resetBTAlignment(forDevice: targetID)
        btTrimLock.withLock { _ = companionPreMeasurementLatencyMsByUID.removeValue(forKey: targetID) }
        btSpeakerTiming.clearAligned(uid: targetID)
    }

    public func playCompanionAlignmentDemo(targetID: String, referenceID: String?) -> String? {
        let (previous, claimed) = btTrimLock.withLock { () -> (Double?, Bool) in
            guard companionAlignmentRun == nil, companionDemoTargetUID == nil,
                  btWizardTickActive == false else { return (nil, false) }
            companionDemoTargetUID = targetID
            return (companionPreMeasurementLatencyMsByUID[targetID], true)
        }
        guard claimed else {
            return "This Mac is already measuring a speaker. Finish that first."
        }
        let current = btMeasuredLatencyMs(forDevice: targetID) ?? 0
        // A comparison between two speakers, so every OTHER Bluetooth speaker
        // is held silent for its duration — the same hold a wizard run takes,
        // and released the same way.
        updateBTWizardParticipantHold(active: true, targetUID: targetID, referenceUID: referenceID)
        setBTAlignTickActive(true)
        // The live, rebuild-free latency write — the sink's own splice, not
        // `setBTWizardLatencyPreview`, whose per-trial bookkeeping and
        // telemetry belong to a wizard run and would be a lie here.
        if let previous {
            pushCompanionDemoLatency(previous, forDevice: targetID)
            captureControlQueue.asyncAfter(deadline: .now() + Self.companionDemoLegSeconds) {
                [weak self] in
                self?.pushCompanionDemoLatency(current, forDevice: targetID)
            }
        }
        captureControlQueue.asyncAfter(deadline: .now() + 2 * Self.companionDemoLegSeconds) {
            [weak self] in
            self?.endCompanionDemo(targetID: targetID)
        }
        // razor: the receipt is the alignment tick, not a music passage — the
        // pacer already replaces the program with it and nothing here has to
        // source, license or loop audio. Upgrade path if the tick turns out to
        // be too thin a thing to judge a speaker on: feed the demo a short
        // bundled music passage through the same replaced-program feed.
        return nil
    }

    /// The demo's live latency push: the same splice `setOffsetMs` performs
    /// for every other alignment write, so the speaker never goes silent
    /// mid-receipt.
    private func pushCompanionDemoLatency(_ ms: Double, forDevice id: String) {
        captureControlQueue.async { [weak self] in
            self?.btSink?.setOffsetMs(Int(ms.rounded()), forDeviceUID: id)
        }
    }

    /// Put the room back after a receipt: tick off, the stored value back on
    /// the sink, every held speaker audible again. Idempotent — the timed end
    /// and a cancel both land here, and only the first does anything. Keyed by
    /// DEVICE, so a cancel aimed at another speaker cannot end this receipt
    /// and leave its target sitting at the "before" value for good.
    private func endCompanionDemo(targetID: String) {
        let wasActive = btTrimLock.withLock { () -> Bool in
            guard companionDemoTargetUID == targetID else { return false }
            companionDemoTargetUID = nil
            return true
        }
        guard wasActive else { return }
        setBTAlignTickActive(false)
        pushCompanionDemoLatency(btMeasuredLatencyMs(forDevice: targetID) ?? 0, forDevice: targetID)
        updateBTWizardParticipantHold(active: false, targetUID: nil, referenceUID: nil)
    }

    public func endBTWizardRun() {
        // Belt and braces for the hold: the tick's `false` edge already dropped
        // it, but a run that ends is a run whose participants must all be
        // audible again, whatever route it took to get here.
        updateBTWizardParticipantHold(active: false, targetUID: nil, referenceUID: nil)
        btTrimLock.withLock {
            btWizardLastPreviewMsByUID.removeAll()
            btWizardTickBPM = nil
        }
        stateQueue.async {
            guard self.btWizardReferenceRaised else { return }
            self.btWizardReferenceRaised = false
            self.updateBTReferenceBufferLocked()
        }
    }

    /// The sync drawer asks for this on its own open path, so it must not wait
    /// on `captureControlQueue` — a tap rebuild parked there runs for hundreds
    /// of milliseconds. Only the `btSink` REFERENCE is queue-confined state, so
    /// it is read under ``btSinkRefLock`` and the sink is then asked directly:
    /// the sink synchronizes its own tables, so the call is safe off-queue.
    /// The answer stays a LIVE query per the sink's contract — nothing is
    /// cached here, because the range moves the instant an AirPlay device joins
    /// or leaves the composition.
    public func btUsableTrimRangeMs(forDevice id: String) -> ClosedRange<Double> {
        let sink = btSinkRefLock.withLock { btSink }
        return sink?.usableTrimRangeMs(forDeviceUID: id) ?? (-BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)
    }

    public func setBTWizardTickTempo(bpm: Double) {
        // Stashed as well as pushed: it is the one signal down here that says
        // which estimator stage a trial belongs to (`setBTWizardLatencyPreview`).
        btTrimLock.withLock { btWizardTickBPM = bpm }
        captureCoordinator?.setWizardTempo(bpm: bpm)
    }

    // MARK: Measured latency (roadmap 056 Part A)

    public func btMeasuredLatencyMs(forDevice id: String) -> Double? {
        btTrimLock.withLock { btLatencyMsByUID[id] }
    }

    public func btWizardLatencyRangeMs(forDevice id: String) -> ClosedRange<Double> {
        // Solve the sink's own delay formula (`reference − latency + trim`) for
        // the latencies a trial can actually be judged at. The run SUSPENDS the
        // trim to 0 for its whole duration, so the trim term is gone here too —
        // leaving it in both polluted the measurement (a candidate would be
        // judged at `L + trim`) and, for a trim more negative than the hardware
        // latency, collapsed the range onto 0 and bowed the run out as
        // `.unreachable`.
        //
        // The CEILING is the reference less one default BT-only buffer, not the
        // reference itself: at `latency == reference` the delay is 0, the ring
        // is seeked completely dry, and the speaker is silent for the rest of
        // the session with no way back. Leaving a buffer's worth of content
        // ahead of the read pointer is what keeps every reachable candidate
        // playable.
        //
        // The FLOOR is negative on purpose. A latency below 0 is not a physical
        // quantity and never gets persisted (`endBTWizardLatencyPreview` floors
        // it, as does the session's Keep) — but a run that cannot go below 0
        // dead-ends on the very first answer of a fresh speaker, whose base is
        // 0: "target first" means the latency must come DOWN, the candidate
        // clamps to the same 0, the identical question repeats, and two clicks
        // in the run bows out. The staircase has to be able to REVERSE out of a
        // wrong early answer, so the range gives it somewhere to go.
        let reference = stateQueue.sync { () -> Int in
            btComposition.usesPresentationReference
                ? _startBufferMs : Self.btWizardReferenceBufferMs
        }
        let lower = -BTSyncTrim.rangeMs
        let upper = Double(reference) - Double(BTSyncedSink.defaultBTOnlyBufferMs)
        return lower...Swift.max(lower, upper)
    }

    public func setBTWizardLatencyPreview(_ ms: Double, forDevice id: String,
                                          halfWidthMs: Double? = nil) {
        // NOT floored at 0: see `btWizardLatencyRangeMs` — the run needs to be
        // able to reverse below the base. Keep is where the floor belongs.
        let value = Int(ms.rounded())
        let (previous, bpm) = btTrimLock.withLock { () -> (Int?, Double?) in
            let previous = btWizardLastPreviewMsByUID[id]
            btWizardLastPreviewMsByUID[id] = value
            return (previous, btWizardTickBPM)
        }
        // One line per trial — the run's only record of what the user was
        // actually asked to judge. `captureControlQueue`/`stateQueue` callers
        // only; nothing here runs on the render or tap thread.
        var fields = [
            "uid": id,
            "candidateMs": String(value),
            "deltaMs": String(value - (previous ?? value)),
            // How wide the run is casting, read off the tempo it drives: an
            // uncertain run ticks far slower than one closing in.
            "stage": (bpm ?? BTAlignmentWizardSession.searchTickBPM)
                <= BTAlignmentWizardSession.searchTickBPM ? "search" : "blocks",
        ]
        // How sure the estimator was when it chose this level. Absent rather
        // than zero for a caller that has no posterior behind it.
        if let halfWidthMs { fields["halfWidthMs"] = String(format: "%.1f", halfWidthMs) }
        Telemetry.log(.localPlayback, "wizard_latency_preview", fields)
        captureControlQueue.async { [weak self] in
            self?.btSink?.setOffsetMs(value, forDeviceUID: id)
        }
    }

    public func endBTWizardLatencyPreview(forDevice id: String, keepMs: Double?) {
        endBTWizardLatencyPreview(forDevice: id, keepMs: keepMs, recordsAlignment: true)
    }

    /// `recordsAlignment` is false for the one caller that has recorded this
    /// alignment already — the phone's apply, whose number a microphone found
    /// (``applyCompanionAlignmentMeasurement``). Recording again here would
    /// file the microphone's measurement under
    /// ``BTSpeakerTiming/Source/byEar`` and rebroadcast the snapshot twice.
    private func endBTWizardLatencyPreview(forDevice id: String, keepMs: Double?,
                                           recordsAlignment: Bool) {
        if let keepMs {
            let value = Swift.max(0, keepMs.rounded())
            // Keep writes BOTH halves of the delay term. The trim goes to 0
            // because it was a manual stand-in for exactly the latency this run
            // has now measured — carrying it over would double the correction,
            // and the run was judged with it suspended anyway. The nudge starts
            // fresh from the measurement.
            let (latencies, trims): ([String: Double], [String: Double]) = btTrimLock.withLock {
                btLatencyMsByUID[id] = value
                btTrimsByUID[id] = 0
                return (btLatencyMsByUID, btTrimsByUID)
            }
            do {
                try btTrimStore?.saveLatencies(latencies)
                try btTrimStore?.save(trims)
            } catch {
                StoreRecovery.noteWriteFailure(error)
            }
            // A Keep is an alignment wherever it came from, so the row and
            // the sheet read it as one, and the store marks it early if the
            // clock was still settling.
            if recordsAlignment { btSpeakerTiming.noteAligned(uid: id) }
            // Both halves are written and the sink push is enqueued below, so
            // the row's number is this one from here — measured, first pass or
            // by ear, whichever the record above left it as.
            btSpeakerTiming.noteOffsetApplied(uid: id)
            // The run's receipt, in one line: what was measured and what the
            // nudge was left at — the two halves of the delay term Keep writes,
            // so a live report never has to infer one from the other — plus
            // the Mac's verdict on the clock it was made against. UI-thread call
            // site (the popover's Keep), never the render or tap thread.
            Telemetry.log(.localPlayback, "wizard_keep", [
                "uid": id,
                "latencyMs": String(Int(value)),
                "trimMs": "0",
                "clockState": btAlignmentReport(forDevice: id)?.clockState.rawValue ?? "nil",
            ])
            // The reference floor is a function of the slowest known latency, so
            // a new measurement can move it — and it must move FIRST: pushing a
            // 640 ms latency against a 500 ms reference drives the delay onto
            // its ≥ 0 clamp for as long as the two disagree. Both hops are
            // enqueued from `stateQueue`, so `captureControlQueue` runs them in
            // that order rather than whichever thread got there first. The
            // reference itself comes back down only at ``endBTWizardRun()``,
            // one hop later, with this measurement already in the table.
            stateQueue.async {
                self.updateBTReferenceBufferLocked()
                // A measured speaker is one the drift tracker can now watch,
                // and the reference it just moved is what the baselines are
                // built on (live test 2026-09-13: without this, the second
                // speaker's Keep left tracking off until the next trim nudge).
                self.refreshDriftTrackingLocked()
                self.captureControlQueue.async { [weak self] in
                    self?.btSink?.setOffsetMs(Int(value), forDeviceUID: id)
                    self?.btSink?.setTrimMs(0, forDeviceUID: id)
                }
            }
        } else {
            let stored = Int((btMeasuredLatencyMs(forDevice: id) ?? 0).rounded())
            captureControlQueue.async { [weak self] in
                self?.btSink?.setOffsetMs(stored, forDeviceUID: id)
            }
        }
    }

    // MARK: The wizard's first-tick ARM gate (roadmap 056 Part B)

    /// Start polling for "everyone is playing". Ticks stay off until every
    /// participating sink has opened its delay gate — or the ceiling expires —
    /// so the FIRST audible tick is a true pair on every speaker instead of the
    /// Mac ticking alone while a Bluetooth engine is still coming up (the
    /// engine needs longer than the old fixed 3 s preamble allowed for).
    /// `captureControlQueue`.
    private func beginWizardArmGate(expecting uids: Set<String>) {   // captureControlQueue
        cancelWizardArmGate()
        scheduleWizardArmPoll(started: Date(), expecting: uids)
    }

    /// `captureControlQueue`. Idempotent.
    private func cancelWizardArmGate() {   // captureControlQueue
        wizardArmPollWork?.cancel()
        wizardArmPollWork = nil
    }

    private func scheduleWizardArmPoll(started: Date, expecting uids: Set<String>) {
        let work = DispatchWorkItem { [weak self] in
            self?.pollWizardArmGate(started: started, expecting: uids)
        }
        wizardArmPollWork = work
        captureControlQueue.asyncAfter(
            deadline: .now() + wizardArmPollInterval, execute: work)
    }

    /// One arm-gate poll. `captureControlQueue`, which owns both sinks — and is
    /// not a render or tap thread, so the one telemetry line at the end is
    /// emitted where it belongs.
    private func pollWizardArmGate(started: Date, expecting uids: Set<String>) {
        wizardArmPollWork = nil
        let waited = Date().timeIntervalSince(started)
        let rendering = btSink?.renderingDeviceUIDs() ?? []
        // `true` when there is no local sink at all: nothing to wait for.
        let localReleased = syncedLocalSink?.hasStartedRendering ?? true
        let everyoneReleased = uids.isSubset(of: rendering) && localReleased
        // A minimum stretch of bed regardless (the Sonos Move power-gates its
        // amplifier and swallows the first transients after silence), and a
        // ceiling so a speaker that never releases cannot stall the run.
        let ready = everyoneReleased && waited >= wizardArmMinimumBedSeconds
        guard ready || waited >= wizardArmCeilingSeconds else {
            scheduleWizardArmPoll(started: started, expecting: uids)
            return
        }
        captureCoordinator?.armWizardTicks()
        Telemetry.log(.localPlayback, "wizard_ticks_armed", [
            "waitedMs": String(Int((waited * 1_000).rounded())),
            "released": rendering.sorted().joined(separator: " "),
            "localReleased": localReleased ? "1" : "0",
            "timedOut": ready ? "0" : "1",
        ])
    }
}
