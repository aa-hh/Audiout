import Foundation
import AudioToolbox
import AirPlayEngine
import CastSender

extension NativeBackend {
    // MARK: Tone (per-device + Main Out EQ)

    /// One speaker's tone. `commit == false` is live scrub — the sound changes
    /// immediately but nothing is persisted; `commit == true` is the end of a
    /// gesture and persists. NEITHER moves the device's session: it owns its
    /// stream from connect to disconnect, so an edit is a coefficient swap.
    ///
    /// The local Mac row is REJECTED (locked scoping decision: per-device EQ
    /// covers AirPlay and Bluetooth rows only). A Bluetooth id branches to its
    /// sink — its audio never goes through an AirPlay stream at all.
    public func setEQ(_ eq: DeviceEQ, for id: String, commit: Bool) {
        guard id != Self.localDeviceID else { return }
        stateQueue.async {
            // The one line that says a curve left the editor, next to
            // everything that decides whether it can reach the audio (ticket
            // 04: no log could answer "did this speaker's curve reach the
            // sound?"). ABOVE the `known` guard on purpose: an edit for an id
            // the backend does not know is exactly the id-mismatch case this
            // instrumentation exists to catch, and the guard used to drop it
            // without a word. A drag calls this per frame, so only the FIRST
            // frame of a gesture and the commit that ends it are logged — the
            // gesture and its final value, without a line per mouse-move. Local
            // only: `Telemetry.log` never leaves the Mac, so a device id is
            // allowed.
            let firstOfGesture = commit ? false : self.eqEditGesturesLogged.insert(id).inserted
            if commit { self.eqEditGesturesLogged.remove(id) }
            let isKnown = self.known[id] != nil
            if commit || firstOfGesture {
                Telemetry.log(.airplay, "eq_edit", [
                    "device": id,
                    "commit": commit ? "true" : "false",
                    "shaped": eq.isFlat ? "false" : "true",
                    "bass": String(format: "%.1f", eq.bassDB),
                    "treble": String(format: "%.1f", eq.trebleDB),
                    "balance": String(format: "%.2f", eq.balance),
                    "loudness": eq.loudness ? "true" : "false",
                    "bands": "\(eq.bandGainsDB.filter { $0 != 0 }.count)",
                    "home": self.wholeSystemStreamByDevice[id].map { "\($0)" } ?? "none",
                    "added": self.added.contains(id) ? "true" : "false",
                    "perapp": self.streamBindings[id] != nil ? "true" : "false",
                    "known": isKnown ? "true" : "false",
                ])
            }
            guard isKnown else { return }
            self.eqByDeviceID[id] = eq
            self.applyLocal(id) { $0.eq = eq }
            if commit { self.saveEQLocked() }
            if self.known[id]?.isBluetooth == true || self.known[id]?.isWired == true {
                self.pushBTSinkEQLocked(id)
                return
            }
            // A device outside the EQ domain (not streaming whole-system, or
            // claimed by per-app routing) has no stream in the plan to change, so
            // a scrub touches no processor — the value is remembered and the
            // commit applies it. Without this, every frame of a drag on such a
            // row ran a full `reconcileEQPlan`.
            guard commit || self.wholeSystemStreamByDevice[id] != nil else { return }
            // A scrub is pure coefficients — the device's stream is already the
            // one its session is bound to. A COMMIT additionally reconciles,
            // because crossing flat↔shaped is what decides whether a device
            // sharing stream 0 is bypassed and has to say so on its row.
            if commit {
                self.reconcileEQPlan()
            } else {
                self.pushEQPlanLocked()
            }
        }
    }

    /// Main Out's tone: one stage over the whole mix, applied before every
    /// fan-out, so AirPlay, the Mac's own delayed sink and every Bluetooth sink
    /// hear the same shaped program. Never moves a speaker between streams —
    /// there is exactly one main stage no matter how many streams exist.
    public func setMainOutEQ(_ eq: DeviceEQ, commit: Bool) {
        stateQueue.async {
            self.storedMainOutEQ = eq
            if commit { self.saveEQLocked() }
            self.pushEQPlanLocked()
        }
    }

    /// Persist the current tone settings. Committed edits only — a live scrub
    /// must not write a file per slider frame. Flat entries are dropped by the
    /// store itself, so the whole table can be handed over as-is. On `stateQueue`.
    private func saveEQLocked() {   // on stateQueue
        do {
            try eqStore?.save(mainOut: storedMainOutEQ, devices: eqByDeviceID)
        } catch {
            Telemetry.log(.airplay, "eq_save_failed", ["error": "\(error)"])
        }
    }

    /// Recompute, per known device, whether its stored tone is reaching the
    /// audio — and publish the current plan.
    ///
    /// Called at every moment the plan's DEVICE SET moves: a device reaching or
    /// leaving `added`, `setOutputSet`, a per-app destination-set change, a
    /// committed `setEQ`, and `stop()`. It issues NO engine op — a device's
    /// stream is decided once, at connect (``connectTargetStreamLocked(_:)``),
    /// and never moves for a tone value. On `stateQueue`.
    func reconcileEQPlan() {   // on stateQueue
        // Say out loud, per device, whether its stored values are reaching the
        // audio — and when they aren't, WHY, because the two reasons need
        // different sentences. One sweep over everything known, so a device that
        // just left the EQ domain is cleared by the same pass that sets the
        // others. `applyLocal` emits only on a real change.
        for id in Array(known.keys) {   // snapshot: `applyLocal` writes `known`
            let isFlat = (eqByDeviceID[id] ?? .flat).isFlat
            let reason: Device.EQBypassReason?
            if streamBindings[id] != nil, !isFlat {
                // Per-app routing owns this device's session — its audio comes
                // from `AppRouteMixer` and never passes the whole-system EQ
                // stage, so a stored tone is stored only.
                reason = .perAppRouting
            } else if wholeSystemStreamByDevice[id] == 0, !isFlat {
                // It connected when the engine had no stream left, so it shares
                // the flat stream 0 and keeps its values unapplied.
                reason = .streamBudget
            } else {
                reason = nil
            }
            applyLocal(id) { $0.eqBypassReason = reason }
        }
        pushEQPlanLocked()
    }

    /// Drop `id` from the whole-system streaming set, reconciling the EQ plan on
    /// a REAL true→false edge — the departure mirror of the `added` false→true
    /// edge, and the only site that owns it.
    ///
    /// A departure takes the device's stream out of the plan, which otherwise
    /// keeps costing a per-buffer filter pass for audio no output is bound to —
    /// and, for a device the user has already deselected, releases that stream
    /// back to the budget. `setOutputSet`'s own reconcile can do neither: it runs
    /// while the teardown is still in flight, with the device still in `added`.
    ///
    /// Issues no engine op of its own, so it is safe to call from inside a
    /// converge loop. On `stateQueue`.
    /// - Returns: whether `id` was actually in the streaming set.
    @discardableResult
    func removeFromAddedLocked(_ id: String) -> Bool {   // on stateQueue
        // Released only for a device the user no longer wants. A session that
        // died under a still-DESIRED speaker is coming back — possibly through
        // the engine's own out-of-band reconnect, which re-establishes it on the
        // stream id the engine still holds — so the assignment has to outlive the
        // failure or the plan stops carrying that stream and the speaker comes
        // back silent. The mirror case, a deselect with no session to tear down,
        // releases at `setOutputSet`'s desire edge instead.
        if desiredOn[id] != true { wholeSystemStreamByDevice.removeValue(forKey: id) }
        guard added.remove(id) != nil else { return false }
        reconcileEQPlan()
        return true
    }

    /// The whole-system stream `id`'s session belongs on — allocated on first
    /// use and kept until the user deselects the speaker.
    ///
    /// Every whole-system session-establishing op reads this under `stateQueue`
    /// immediately before its engine call, so a speaker is on its own stream
    /// from connect to disconnect and a tone edit only swaps that stream's
    /// coefficients. Moving a live session costs a fresh AirPlay negotiation and
    /// throws away the receiver's ~2 s lead, which the user hears as a gap.
    ///
    /// Budget: the engine's capacity, less stream 0 itself, less every distinct
    /// per-app stream currently bound, less the speakers already holding one.
    /// Per-app ids are allocated upward from 1 and whole-system ids live in the
    /// top half of the space, so the range test tells them apart. Over budget
    /// the device gets `0` — it shares the flat stream and says so through
    /// ``Device/eqBypassReason`` — and it KEEPS `0` until it disconnects: being
    /// re-homed when a neighbour leaves would cost exactly the gap this design
    /// exists to avoid. On `stateQueue`.
    ///
    /// razor: the budget is read once, at connect. A per-app bind that takes a
    /// stream AFTER ~15 speakers are already homed can push the total past the
    /// engine's capacity, and the speaker that loses gets an engine refusal
    /// rather than a bypass sentence. Upgrade path: re-home the over-budget
    /// speakers when a per-app destination set changes — which costs each of
    /// them the rebind gap, so it is worth doing only if a real mix ever gets
    /// near the cap.
    func connectTargetStreamLocked(_ id: String) -> UInt32 {   // on stateQueue
        if let home = wholeSystemStreamByDevice[id] { return home }
        let perAppStreams = Set(streamBindings.values.filter {
            $0 >= 1 && $0 < Self.wholeSystemStreamIDBase
        })
        let owned = wholeSystemStreamByDevice.values.filter { $0 != 0 }.count
        let budget = Self.engineStreamCapacity - 1 - perAppStreams.count - owned
        guard budget > 0 else {
            wholeSystemStreamByDevice[id] = 0
            return 0
        }
        let home = nextWholeSystemStreamID
        nextWholeSystemStreamID &+= 1
        wholeSystemStreamByDevice[id] = home
        return home
    }

    /// Publish the CURRENT assignment as a plan for the capture coordinator:
    /// one stream per streaming whole-system speaker, carrying that speaker's
    /// tone, plus the flat stream 0 every shaped stream is copied from.
    ///
    /// No live stage is ever rebuilt: an unchanged one is carried over
    /// instance-and-all (see ``EQProcessorSlot``) and a changed one is
    /// retargeted in place, because a fresh `EQProcessor` starts with empty IIR
    /// delay memory — a tick on a neighbour, a crackle for the whole drag on the
    /// speaker being edited. Coefficients are built HERE, on `stateQueue`, and
    /// reach the processor through its own mailbox; its filter state stays the
    /// delivery thread's alone and is never read from here. Enqueued on
    /// `captureControlQueue` like every other coordinator call, so a coordinator
    /// callback that hops to `stateQueue` can never deadlock against this.
    /// On `stateQueue`.
    func pushEQPlanLocked() {   // on stateQueue
        var eqByStream: [UInt32: DeviceEQ] = [:]
        // The whole-system EQ domain: streaming, and not claimed by per-app
        // routing. A device sharing stream 0 (over budget) contributes nothing —
        // stream 0 is the flat program every other stream is shaped from.
        for id in added where streamBindings[id] == nil {
            guard let stream = wholeSystemStreamByDevice[id], stream != 0 else { continue }
            eqByStream[stream] = eqByDeviceID[id] ?? .flat
        }
        // A stream that left the plan takes its cached processor with it —
        // nothing will feed it again, and a reused id is a different group.
        eqSlotByStream = eqSlotByStream.filter { eqByStream[$0.key] != nil }

        var streams: [WholeSystemEQPlan.Stream] = [.init(streamID: 0, processor: nil)]
        for (stream, eq) in eqByStream.sorted(by: { $0.key < $1.key }) {
            streams.append(.init(
                streamID: stream,
                processor: Self.processor(reusing: &eqSlotByStream[stream], for: eq)))
        }
        let plan = WholeSystemEQPlan(
            main: Self.processor(reusing: &mainOutEQSlot, for: storedMainOutEQ),
            streams: streams)
        // What was actually published: which streams carry a processor, and
        // which speaker each home stream belongs to. A stored curve that never
        // reaches the audio reads here as its stream missing, or present and
        // flat (ticket 04). Logged only when that summary CHANGES — a scrub
        // republishes the plan per frame and an unchanged line per mouse-move
        // is noise. Local only (device ids).
        guard let coordinator = captureCoordinator else { return }
        let planStreams = plan.telemetryStreamSummary
        let planDevices = added.compactMap { id in
            wholeSystemStreamByDevice[id].map { "\(id)=\($0)" }
        }.sorted().joined(separator: ",")
        let planSummary = "\(plan.main == nil) \(planStreams) \(planDevices)"
        if lastEQPlanLogSummary != planSummary {
            lastEQPlanLogSummary = planSummary
            Telemetry.log(.airplay, "eq_plan", [
                "main": plan.main == nil ? "off" : "on",
                "streams": planStreams,
                "devices": planDevices,
            ])
        }
        captureControlQueue.async { coordinator.setEQPlan(plan) }
    }

    /// The processor for one tone stage, KEEPING the live instance in every case
    /// where one already exists — unchanged (return it as it stands) or changed
    /// (``EQProcessor/retarget(to:)``, which hands the new coefficients to the
    /// delivery thread and carries the delay memory across). Building a new one
    /// would zero that memory mid-signal: an audible tick on an untouched
    /// speaker, and a crackle for the whole drag on the one being edited.
    ///
    /// A flat value drops the slot and returns `nil`: flat must stay
    /// byte-identical passthrough, never a processor pass. The mirror edge —
    /// flat to shaped — has no live instance to preserve, and zero state is the
    /// right start for a stage that was not running. On `stateQueue`.
    static func processor(reusing slot: inout EQProcessorSlot?, for eq: DeviceEQ) -> EQProcessor? {
        guard !eq.isFlat else {
            slot = nil
            return nil
        }
        if let existing = slot {
            if existing.eq != eq {
                existing.processor.retarget(to: eq)
                slot = EQProcessorSlot(eq: eq, processor: existing.processor)
            }
            return existing.processor
        }
        let processor = EQProcessor(eq: eq, sampleRate: eqSampleRate)
        slot = EQProcessorSlot(eq: eq, processor: processor)
        return processor
    }

    /// Push one Bluetooth device's tone into its sink — a property swap on the
    /// running session, never a rebuild. On `stateQueue`.
    private func pushBTSinkEQLocked(_ uid: String) {   // on stateQueue
        let eq = eqByDeviceID[uid] ?? .flat
        captureControlQueue.async { [weak self] in
            self?.btSink?.setEQ(eq, forDeviceUID: uid)
        }
    }

    /// The tone per selected BT uid, snapshotted under `stateQueue` for a sink
    /// transition to apply on `captureControlQueue` — the same re-push-on-every-arm
    /// discipline the persisted trims get. On `stateQueue`.
    func btSinkEQs(forUIDs uids: [String]) -> [String: DeviceEQ] {   // on stateQueue
        Dictionary(uniqueKeysWithValues: uids.map { ($0, eqByDeviceID[$0] ?? .flat) })
    }

    /// Renders a set of device ids as `"[Name1,Name2]"` for a Telemetry field —
    /// prefers the human-readable ``Device/name`` when the id is currently known
    /// (falls back to the raw id for a vanished/unknown one), sorted for
    /// deterministic output (Q6: names in cleartext are the point — a local-only
    /// diagnostic file, not uploaded anywhere). Pure formatting over an
    /// already-captured snapshot — takes no lock of its own, so it's safe to call
    /// from inside any existing critical section.
    static func telemetryDeviceList(_ ids: Set<String>, known: [String: Device]) -> String {
        "[" + ids.sorted().map { known[$0]?.name ?? $0 }.joined(separator: ",") + "]"
    }

    public func setOutputSet(_ ids: Set<String>) {
        // T6-rev: the routing-action permission chokepoint. Deliberately BEFORE
        // `stateQueue` is taken — it must never run inside a critical section
        // this method's main-thread `sync` is already blocking on — and
        // contractually non-blocking (see `onRoutingAction`).
        onRoutingAction?()
        // Record the intent and update the per-device coalescing target under the
        // state lock, then kick a per-device converge loop for anything whose
        // desired state actually changed. Rapid toggle spam collapses here: N
        // flips for one device overwrite `desiredOn[id]` N times but issue at most
        // one op at a time (root cause 1) — intermediate flips are simply dropped.
        // STABILITY(C8): main thread blocks on the state queue for slow work — see dev/notes/stability-audit-2026-07-18.md
        let toKick: [(id: String, outputID: OutputID)] = stateQueue.sync {
            // T4: captured BEFORE the overwrite below so the Telemetry line at the
            // end of this critical section can log the actual added/removed diff.
            let previouslySelected = self.expectedSelected
            self.expectedSelected = ids
            // A deselected greyed wired row is no longer "used" — let it leave.
            self.pruneUnusedWiredLocked()
            // Seamless handoff T3.8-2: an in-app routing action IS the user asking
            // for Audiout back — don't leave `suspended` set from a prior handoff
            // release, which would connect speakers with the capture tap gated off
            // (silent, since `convergeDevice` has no `suspended` guard of its own).
            if self.handoffReleased, !ids.isEmpty {
                self.handoffReleased = false
                self.defaultLeftUsSinceRelease = true
                self.suspended = false
            }
            // Fix C: an explicit (re)selection is a fresh normal-operation context, not
            // a post-wake reconnection — so a stranding from THIS selection falls back
            // on the always-on silence delay, not the wake-restore preference.
            self.awaitingWakeReconnect = false

            // Roadmap 008 (selection-edge replay): a device flipping into or out of
            // the whole-system claim changes route-target ELIGIBILITY exactly like a
            // reachability edge does. If any route targets a flipped id (directly,
            // or through a group's membership — `routesTargetDeviceLocked`),
            // replay the (unedited) route table so `effectiveAppRoutesLocked`
            // re-resolves it — select demotes the route (the app audibly rejoins the
            // whole-system mix), deselect restores it, with no route-table edit in
            // either direction. Enqueue-only, same guard shape as
            // `rerunAppRoutesIfTargeted`: `rerunAppRoutesForReachabilityChange` is
            // documented safe to call with `stateQueue` held.
            let claimFlips = previouslySelected.symmetricDifference(ids)
            if claimFlips.contains(where: { self.routesTargetDeviceLocked($0) }) {
                self.rerunAppRoutesForReachabilityChange()
            }

            // Only ids we can actually stream to — a known discovered receiver
            // (AP1 or AP2) with an engine handle — can be desired-on. The local Mac
            // is excluded (`isLocalDevice`, and it has no `outputIDs` entry); AP1
            // receivers are NOT excluded any more (they drive through the same
            // engine surface as AP2, `supportsAirPlay2` notwithstanding).
            // `.bluetooth` ids are the OTHER side of the R-partition: they have
            // no `outputIDs` entry either, and the explicit `isBluetooth` guard
            // keeps that structural (a BT id must never reach the AirPlay
            // engine even if it ever acquired a handle) — they drive the BT
            // sink manager below instead. `.cast` ids are the THIRD partition,
            // held to the same guard discipline for the same reason.
            var kicks: [(String, OutputID)] = []
            for id in self.order {
                guard let device = self.known[id], !device.isLocalDevice,
                      !device.isBluetooth,
                      !device.isCast,
                      let outputID = self.outputIDs[id] else { continue }
                let wantOn = ids.contains(id)

                let previous = self.desiredOn[id]
                self.desiredOn[id] = wantOn

                // A genuine MEMBERSHIP EDGE clears a terminal-failure park: a
                // re-toggle to ON is an explicit retry after a NACK (root cause
                // 4: no permanent wedge), and toggling OFF deselects the device
                // (nothing left to retry). A membership-NEUTRAL call must leave
                // a parked id ALONE — this used to be an unconditional clear
                // plus an `isRetryOfFailed` re-kick, which turned EVERY routing
                // call that left the set unchanged (a This-Mac toggle, a
                // Main-Out re-pick, an unrelated selection change) into a full
                // retry of every still-desired `.failed` device, sustaining an
                // autonomous zero-backoff retry storm (live, 2026-08-06). The
                // deliberate same-membership retry ("Try again") now travels
                // its own entry point, `retryOutput(_:)`.
                if previous != wantOn { self.failedGate.remove(id) }

                // A speaker the user no longer wants, with NO session and NO
                // engine op in flight, gives its whole-system stream back here.
                // It reaches no teardown — a connect the receiver refused, a
                // receiver that vanished, a session that died out of band all
                // leave `added` false — and a converge that finds `want == isOn`
                // issues nothing and is not even requeued
                // (`releaseConvergingAndRequeueIfNeeded`), so nothing else would
                // ever release it: the stream would keep counting against the
                // budget and a stale `0` would pin the speaker to the flat stream
                // on every later reselect.
                //
                // BOTH guards are load-bearing. A converge that has already read
                // the home is inside a ~2 s negotiation: taking the stream now
                // and re-selecting before the add lands would leave the post-add
                // `added` insert with no home at all, so the plan would carry no
                // stream for a row that says connected — a speaker fed nothing
                // but idle fill, with the loop already settled at `want == isOn`.
                // A speaker with a live session releases at its teardown instead
                // (`removeFromAddedLocked`).
                if previous != wantOn, !wantOn,
                   !self.added.contains(id), !self.converging.contains(id) {
                    self.wholeSystemStreamByDevice.removeValue(forKey: id)
                }

                // Connection-status brief §1/§3 semantics: a device newly
                // desired ON goes `.connecting` immediately, before the engine
                // op resolves, so the UI spinner is immediate. This also clears a sticky `.failed` on a re-toggle
                // (the `failedGate` clear above is the routing-side twin of
                // this). A device newly desired OFF drops any in-flight/failed
                // indication back to `.off` right away — NativeBackend has no
                // "sticky failed survives deselect" behavior (its park is
                // cleared on any toggle edge, above), so the connection dot
                // follows suit and a deselect genuinely ENDS a failure episode.
                if previous != wantOn {
                    self.setConnectionState(wantOn ? .connecting : .off, for: id)
                }
                // Kick iff the desired state changed AND no loop is already
                // running for this id (a running loop re-reads `desiredOn` when
                // its op settles).
                if previous != wantOn, !self.converging.contains(id) {
                    self.converging.insert(id)
                    kicks.append((id, outputID))
                    // Connect-latency diagnosis: T0 for "click to first audio," read
                    // alongside the "connect_addoutput_*" timestamps in
                    // convergeDevice below.
                    if wantOn {
                        // F-REBIND: the USER asked for this connect, so whichever
                        // add-success site wins the race seeds the configured connect
                        // default. Deliberately only here, not in `convergeToTarget`
                        // (which flaps `desiredOn` for `applyStartBuffer`'s internal
                        // re-add) — see `userConnectSeed`.
                        self.userConnectSeed.insert(id)
                        Telemetry.log(.airplay, "connect_requested", ["device": id])
                    }
                }
            }
            // Ids that vanished from the model but were desired-on: drop their
            // stale target so a re-appearance starts clean.
            for id in Array(self.desiredOn.keys) where self.known[id] == nil {
                self.desiredOn[id] = nil
            }

            // Selection is the ONLY thing that moves the capture gate, so this is
            // its one call site. Deliberately NOT called from `applyStartBuffer`:
            // that flaps `desiredOn` internally (remove-all → set → re-add) but
            // never touches `expectedSelected`, and must not stop/restart the tap
            // mid-apply. Runs inside this critical section so the enqueued
            // start/stop order matches the decision order exactly.
            self.reconcileCaptureGate()
            // Intent changed: re-evaluate the silence watchdog. Selecting a device (or
            // activating a group) with nothing yet `.connected` arms the countdown;
            // deselecting everything (or dropping to a local-only selection) clears any
            // active fallback and cancels the countdown. (R11: a group of dead speakers
            // is exactly "non-local intent, zero connected" the moment it's activated.)
            self.reconcileSilenceWatchdog()

            // T-BACKEND: "play everywhere" is Mac + ≥1 AirPlay device. `ids` here
            // IS the AirPlay-only side of that set (`GroupController` never hands
            // the local device through); the Mac's own membership comes from
            // `selectedDevicesQuery`, wired externally (AppDelegate). Decided in
            // this SAME critical section as the capture gate above so a burst of
            // rapid selection changes settles on the LAST decision only, exactly
            // like `reconcileCaptureGate` — `nil` below means "no change," so a
            // repeat decision (e.g. Mac+AirPlay → Mac+2×AirPlay) never re-kicks
            // the attach/start work.
            let macSelected = self.selectedDevicesQuery?(Self.localDeviceID) ?? false
            let wantSyncedLocal = macSelected && !ids.isEmpty
            if wantSyncedLocal != self.syncedLocalSinkEnabled {
                self.syncedLocalSinkEnabled = wantSyncedLocal
                // T1/T2: don't run the attach/detach here — record the desired
                // state and (re)schedule a trailing-edge settle. A burst of rapid
                // on/off toggles collapses to AT MOST one real transition, killing
                // both the tap-rebuild storm and the sink re-anchor storm (both are
                // driven from `applySyncedLocalSinkTransition`).
                self.scheduleSyncedLocalSettleLocked()
                // The eager level emit moved into `fireSyncedLocalSettle`: metering keys off the
                // applied state, so a reading here would describe a transition that has not happened (and may never).
            }

            // BT-BACKEND (R-partition): the other half of the partition the
            // engine loop above skipped. Selected `.bluetooth` and `.wired` ids
            // drive the BT sink manager — enable/disable on the empty↔non-empty edge, the
            // per-device set reconciled, and the group composition (BT-REFSEL)
            // recomputed on every selection change (AirPlay joining/leaving a
            // BT-containing selection moves every BT delay to a new reference).
            // Decided here under `stateQueue` like the capture gate and applied
            // on `captureControlQueue`; unchanged decisions enqueue nothing, so
            // unrelated routing traffic never touches the running sinks.
            let btUIDs = ids.filter { self.known[$0]?.isBluetooth == true }.sorted()
            let sinkUIDs = ids.filter {
                self.known[$0]?.isBluetooth == true || self.known[$0]?.isWired == true
            }.sorted()
            let wantBT = !sinkUIDs.isEmpty
            // BT-LIFECYCLE: the row's own connect story, the twin of the engine
            // loop's eager `.connecting` above. A newly-selected AVAILABLE BT id
            // breathes until its per-device sink is genuinely audible; a
            // newly-selected UNAVAILABLE one stays `.off` (the greyed "play when
            // up" select — nothing is connecting until it comes back, which the
            // availability edge in `applyBTSnapshots` picks up). A deselect ends
            // any hold at once, but leaves a `.failed` story standing: BT rows
            // offer "Try again" regardless of membership, so the failure the
            // button explains must survive the deselect the loss edge triggers.
            for id in previouslySelected.symmetricDifference(ids)
            where self.known[id]?.isBluetooth == true || self.known[id]?.isWired == true {
                if ids.contains(id) {
                    if self.known[id]?.isAvailable == true { self.beginBTConnectingLocked(id) }
                } else {
                    self.btConnectingDeadlines[id] = nil
                    if case .failed = self.known[id]?.connectionState {} else {
                        self.setConnectionState(.off, for: id)
                    }
                }
            }
            // CAST-SYNC: the room delay is decided from the SELECTION, ahead
            // of anything launching (brief §4) — a Cast receiver contributes
            // its remembered steady lead (or the measured default) the moment
            // it is selected, so everything else takes its one delay hit now
            // rather than ten seconds into the song.
            let castIDs = ids.filter { self.known[$0]?.isCast == true }.sorted()
            let castSelectionChanged = castIDs != self.castSelectedIDs
            self.castSelectedIDs = castIDs
            let castTermMoved = self.updateCastRoomDelayLocked()

            let composition = BTGroupComposition(
                airPlayPresent: ids.contains {
                    self.known[$0].map {
                        !$0.isBluetooth && !$0.isLocalDevice && !$0.isCast && !$0.isWired
                    } == true
                },
                macLocalPresent: macSelected,
                castPresent: !castIDs.isEmpty)

            // W3 — the first-mix alignment offer. A BT id in a MIX (any other
            // member — another AirPlay/BT id, or the Mac itself) with NO saved
            // trim, at most once per device per session. The speaker connects
            // and plays as-is below, a little behind the rest; the event only
            // asks the UI to offer alignment under its row.
            let mixPresent = ids.count >= 2 || (!ids.isEmpty && macSelected)
            if wantBT, mixPresent {
                let trims = self.btTrimLock.withLock { self.btTrimsByUID }
                for uid in btUIDs
                where trims[uid] == nil && !self.btAlignmentPromptedUIDs.contains(uid) {
                    self.btAlignmentPromptedUIDs.insert(uid)
                    Telemetry.log(.localPlayback, "bt_first_mix_intercept", ["device": uid])
                    self.emit(.btFirstMixAlignmentPrompt(deviceID: uid))
                }
            }
            // Wave-4 delay agreement: a BT-presence flip, or a flip of the
            // timeline BT renders against, moves the LOCAL sink's reference too
            // (`localSinkReferenceDelayMs`), so capture whether the reference
            // input changed before overwriting. macLocalPresent never changes a
            // BT delay (BTReferenceTimeline.delayNanos doc,
            // BTSyncedSink.swift:52-55), so it is deliberately not part of this;
            // a Cast receiver IS, because it authors a presentation timeline
            // exactly as AirPlay does and BT renders against that instead of
            // the Mac's own clock the moment one joins.
            let referenceMoved = wantBT
                && composition.usesPresentationReference
                    != self.btComposition.usesPresentationReference
            let localReferenceMoved = (wantBT != self.btSinkEnabled) || referenceMoved
            if wantBT != self.btSinkEnabled || sinkUIDs != self.btSelectedUIDs
                || referenceMoved {
                self.btSinkEnabled = wantBT
                self.btSelectedUIDs = sinkUIDs
                self.reconcileAggregateSubDeviceLocked(reason: "bt_selection")
                self.btComposition = composition
                // The manager arms for BOTH domains, so the set it is handed is
                // the union — while the reference below stays a function of the
                // whole-system selection alone.
                let (armed, armedUIDs) = self.btArmingLocked()
                let gains = self.btSinkGains(forUIDs: armedUIDs)
                // Derived AFTER the new selection is committed — the reference
                // is a function of the selected devices' measured latencies.
                let referenceMs = self.updateBTReferenceBufferLocked()
                let eqs = self.btSinkEQs(forUIDs: armedUIDs)
                let reportedLatencyUIDs = self.wiredSinkUIDs(forUIDs: armedUIDs)
                self.captureControlQueue.async { [weak self] in
                    self?.applyBTSinkTransition(
                        enable: armed, uids: armedUIDs, composition: composition,
                        gains: gains, eqs: eqs, reportedLatencyUIDs: reportedLatencyUIDs,
                        referenceBufferMs: referenceMs)
                }
                // The selection decides both halves of drift tracking: which
                // speakers are measured, and whether anything is measured at
                // all. Recomputed here, where the reference the baselines are
                // built on has just been decided.
                self.refreshDriftTrackingLocked()
                if localReferenceMoved, self.syncedLocalSinkApplied {
                    // Re-anchor the already-running local sink onto the new
                    // reference. Same serial queue as its transitions, so this
                    // can't race an enable/disable for the same sink; the
                    // settle path re-samples the delay on its own when the
                    // local sink is (re)built later.
                    self.captureControlQueue.async { [weak self] in
                        self?.syncedLocalSink?.requestReanchor(cause: "bt_composition_change")
                    }
                }
            }

            // CAST-SYNC (brief §5 ordering): the new room delay reaches every
            // output that has to meet it BEFORE the receiver that set it is
            // launched below — the house is already playing on the new
            // timeline by the time the Cast device starts filling its buffer.
            if castTermMoved {
                self.roomDelayChangedLocked(cause: "cast_selection")
            } else if self._castTermMs != nil {
                // The room did not move, but who has to meet it may have: an
                // AirPlay device joining a Cast room needs the line from its
                // first buffer, and re-publishing the same depth costs nothing.
                self.publishAirPlayPreDelayLocked()
            }

            // CAST-OUT (R-partition, third arm): selected `.cast` ids drive the
            // Cast session manager — same decide-here/apply-on-`captureControlQueue`
            // split as BT, and an unchanged id list enqueues nothing. An empty
            // `castIDs` on an already-empty selection is a no-op.
            //
            // The row's connect story, twin of the BT arm's: a newly-selected
            // AVAILABLE Cast id breathes until its receiver reports PLAYING; a
            // newly-selected UNAVAILABLE one stays `.off`. A deselect ends the
            // hold but leaves a `.failed` story standing, so "Try again" keeps
            // explaining what went wrong.
            for id in previouslySelected.symmetricDifference(ids)
            where self.known[id]?.isCast == true {
                if ids.contains(id) {
                    if self.known[id]?.isAvailable == true {
                        self.setConnectionState(.connecting, for: id)
                    }
                } else {
                    self.castPlaying.remove(id)
                    if case .failed = self.known[id]?.connectionState {} else {
                        self.setConnectionState(.off, for: id)
                    }
                }
            }
            if castSelectionChanged {
                let records = castIDs.compactMap { self.castRecords[$0] }
                let levels = Dictionary(
                    uniqueKeysWithValues: castIDs.map { ($0, self.castLevel(forID: $0)) })
                self.captureControlQueue.async { [weak self] in
                    self?.applyCastTransition(
                        enable: !castIDs.isEmpty, records: records, levels: levels)
                }
            }

            // The selection just moved, so the set of devices the plan carries
            // moved with it — and, for a deselected speaker with no session and
            // no op in flight, its stream was just released above. This pass sees
            // INTENT only: devices connecting as a result of this call reconcile
            // again on their own `added` edge, and a DESELECTED device that IS
            // streaming is still in `added` here (its teardown is only being
            // scheduled) — that departure is `removeFromAddedLocked`'s to report,
            // not this
            // one's.
            self.reconcileEQPlan()

            // T4: log the selection diff + the resulting per-device convergence
            // target. Read-only over state already captured above, then a single
            // non-blocking `Telemetry.log` call (formats + hands off to its own
            // queue, never blocks/calls back) — purely additive, no new locking
            // and no change to the decisions or their order above.
            Telemetry.log(.airplay, "set_output_set", [
                "added": Self.telemetryDeviceList(ids.subtracting(previouslySelected), known: self.known),
                "removed": Self.telemetryDeviceList(previouslySelected.subtracting(ids), known: self.known),
                "desiredOn": Self.telemetryDeviceList(
                    Set(self.order.filter { self.desiredOn[$0] == true }), known: self.known),
            ])

            return kicks
        }

        // Wave 3 T5: the selection intent just changed — reconcile the public
        // aggregate's default-output ownership off it. This is the ACTIVATION SEAM
        // (Q1): the app takes the Mac's default output only when the user actually
        // routes (whole-system selection becomes non-empty), never at launch. It
        // also (re)evaluates the routing-blocked warning for the new steady state.
        // Scheduled `async` (not inside the critical section above) so the HAL
        // default-output write never extends the main-thread `sync` block; still
        // serial on `stateQueue`, so it observes the just-written `expectedSelected`.
        stateQueue.async { self.reconcileAggregateDefault() }

        // The synced-local transition is no longer enqueued here — it fires from
        // the debounced `fireSyncedLocalSettle` (scheduled inside the critical
        // section above via `scheduleSyncedLocalSettleLocked`), so a rapid burst
        // collapses to one transition instead of one per toggle (T1).

        for (id, outputID) in toKick {
            Task { [weak self] in
                guard let self else { return }
                await self.convergeDevice(id: id, outputID: outputID)
            }
        }
    }

    public func retryOutput(_ id: String) {
        // Same routing-action chokepoint discipline as `setOutputSet` (T6-rev):
        // a retry is a user routing gesture, and this must run OUTSIDE the lock.
        onRoutingAction?()
        // BT-RECONNECT: a Bluetooth row's tap-to-reconnect takes a fully
        // separate path — BT ids have no engine OutputID, and their "converge"
        // is a baseband reconnect (`BTConnectionManager`), not an RTSP session.
        if retryBTOutput(id) { return }
        // CAST-OUT: a Cast row's "Try again" re-runs the whole session recipe in
        // the manager — no engine OutputID exists for it either.
        if retryCastOutput(id) { return }
        let kick: OutputID? = stateQueue.sync {
            // Only a still-DESIRED id can be retried — intent lives in
            // `expectedSelected` (what the routing brain last asked for), and a
            // retry never invents membership. An already-`.connected` id has
            // nothing to retry.
            guard self.expectedSelected.contains(id),
                  let device = self.known[id], !device.isLocalDevice,
                  device.connectionState != .connected,
                  let outputID = self.outputIDs[id] else { return nil }
            // THE explicit un-park site for a same-membership retry: `setOutputSet`
            // only clears the park on a genuine membership edge now (storm fix,
            // 2026-08-06), so "Try again" clears it here — for THIS id only.
            self.failedGate.remove(id)
            self.desiredOn[id] = true
            // Eager `.connecting`, mirroring `setOutputSet`'s newly-desired-ON arm:
            // the spinner is immediate, and the fresh `.failed → .connecting` edge
            // is what marks a USER-initiated attempt (a new failure episode) for
            // the popover's diagnosis-panel semantics — the backend's autonomous
            // recovery paths deliberately never produce this edge.
            self.setConnectionState(.connecting, for: id)
            guard !self.converging.contains(id) else { return nil }
            self.converging.insert(id)
            // F-REBIND: the USER asked for this connect, same as a fresh toggle.
            self.userConnectSeed.insert(id)
            Telemetry.log(.airplay, "connect_requested", ["device": id, "trigger": "retry"])
            return outputID
        }
        guard let kick else { return }
        Task { [weak self] in await self?.convergeDevice(id: id, outputID: kick) }
    }

    /// BT-RECONNECT (Wave 4): handle `retryOutput` for a `.bluetooth` id.
    /// Returns `false` for non-BT ids (the AirPlay path below runs instead).
    /// Unlike the AirPlay arm, membership is NOT required — Section D's
    /// tap-to-reconnect applies to any paired row, and a selected id that comes
    /// back re-enters the sink set via the reapply below.
    func retryBTOutput(_ id: String) -> Bool {
        var address: String?
        let isBT: Bool = stateQueue.sync {
            guard let device = self.known[id], device.isBluetooth else { return false }
            // "Not paired" tier (device-tier decision 2): the id survives in app
            // data but the OS pairing record is gone — the enumerator's merged
            // list is the pairedness truth, so fail FAST here, before any
            // baseband attempt that could only time out ~15 s later. The
            // `.connecting` blip first makes each deliberate click a fresh
            // failure episode for the popover's diagnosis-panel semantics.
            if let paired = self.btPairedIDs, !paired.contains(id) {
                self.setConnectionState(.connecting, for: id)
                self.setConnectionState(.failed(ConnectionFailure(
                    cause: .notPaired, detail: "id absent from the OS paired list")), for: id)
                Telemetry.log(.localPlayback, "bt_connect_not_paired", ["device": id])
                return true
            }
            guard self.btConnectionManager != nil,
                  device.connectionState != .connecting,
                  let mac = BTConnectionManager.macAddress(fromUID: id) else { return true }
            // Eager `.connecting`, mirroring the AirPlay arm: immediate spinner,
            // and the `.failed → .connecting` edge marks a fresh user-initiated
            // attempt for the row's failure-episode semantics.
            self.setConnectionState(.connecting, for: id)
            Telemetry.log(.localPlayback, "bt_connect_requested", ["device": id, "trigger": "retry"])
            address = mac
            return true
        }
        guard isBT else { return false }
        // The enumerator no longer asks for the Bluetooth grant at backend start
        // (setup's own step owns the prompt), so a user reaching for a Bluetooth
        // row is the fallback asker — otherwise someone who skipped that step
        // has no in-app path to the prompt at all, and every attempt below is a
        // silent `.unauthorized`. Once-only, and inert once decided.
        btEnumerator?.requestAuthorizationForUserAction()
        guard let address, let manager = btConnectionManager else { return true }
        Task { [weak self] in
            let outcome = await manager.connect(address: address)
            self?.finishBTReconnect(id: id, outcome: outcome)
        }
        return true
    }

    /// CAST-OUT: handle `retryOutput` for a `.cast` id. Returns `false` for
    /// non-Cast ids (the AirPlay path runs instead). Unlike the BT arm,
    /// membership IS required — nothing streams to an unselected receiver, so a
    /// retry there could only open a session with no audio behind it.
    private func retryCastOutput(_ id: String) -> Bool {
        stateQueue.sync {
            guard self.known[id]?.isCast == true else { return false }
            if self.expectedSelected.contains(id) {
                // Eager `.connecting`, mirroring both arms above: immediate
                // spinner, and the `.failed → .connecting` edge marks a fresh
                // user-initiated attempt for the row's failure-episode semantics.
                self.setConnectionState(.connecting, for: id)
                Telemetry.log(.cast, "cast_connect_requested", ["device": id, "trigger": "retry"])
                self.captureControlQueue.async { [weak self] in
                    self?.castOutputManager?.retry(deviceID: id)
                }
            }
            return true
        }
    }

    /// Fold one `CastOutputManager` session state into the row (CAST-OUT). The
    /// manager knows nothing about rows; this is the only place a Cast session
    /// becomes a `ConnectionState`. On `stateQueue`.
    func applyCastVolumeLag(_ id: String, _ lagSeconds: Int?) {   // on stateQueue
        guard var device = known[id], device.isCast, device.castVolumeLagSeconds != lagSeconds else { return }
        device.castVolumeLagSeconds = lagSeconds
        commitKnownDevice(id, device)
        Telemetry.log(.cast, "cast_volume_lag", [
            "device": id, "lag": lagSeconds.map(String.init) ?? "nil",
        ])
    }

    func applyCastSessionState(_ id: String, _ state: CastSessionState) {   // on stateQueue
        guard known[id]?.isCast == true else { return }
        let before = known[id]?.connectionState
        defer {
            // `cast_row_state` on a REAL row change only: a teardown `.idle`, or
            // a late state a "still desired" guard dropped, moves nothing.
            if let device = known[id], device.connectionState != before { logCastRowState(device) }
        }
        switch state {
        case .connecting:
            // Only while still desired: a late `.connecting` from a session
            // being torn down must not resurrect a spinner on a deselected row.
            if expectedSelected.contains(id) { setConnectionState(.connecting, for: id) }
        case .playing:
            // Same "only while still desired" test as `.connecting`: a receiver's
            // first PLAYING can land after a deselect has already written `.off`,
            // and an unguarded write would show a deselected row as connected.
            guard expectedSelected.contains(id) else { break }
            castPlaying.insert(id)
            setConnectionState(.connected, for: id)
        case .failed(let failure):
            castPlaying.remove(id)
            let cause: ConnectionFailure.Cause
            let detail: String?
            switch failure {
            case .timedOut:
                cause = .timedOut
                detail = nil
            case .appUnavailable(let reason):
                cause = .castAppUnavailable
                detail = reason
            case .connectionFailed(let message):
                cause = .castConnectionFailed
                detail = message
            case .dropped(let message):
                cause = .droppedMidStream
                detail = message
            case .noLocalAddress:
                cause = .castConnectionFailed
                detail = "no local IPv4 address"
            }
            setConnectionState(.failed(ConnectionFailure(cause: cause, detail: detail)), for: id)
        case .idle:
            // Teardown acknowledgement only — the row's `.off` was already set
            // by whichever gesture caused the teardown.
            castPlaying.remove(id)
        }
        // CAST-SYNC: a receiver that failed stops holding the room back, and
        // one that came back starts again — both are `R` moving.
        if updateCastRoomDelayLocked() { roomDelayChangedLocked(cause: "cast_session_state") }
    }

    /// CAST-SYNC: recompute which Cast receivers contribute a room-delay term
    /// — every SELECTED one whose session has not failed. Returns whether `R`
    /// moved. On `stateQueue`; the only writer of the policy's receiver set.
    @discardableResult
    func updateCastRoomDelayLocked() -> Bool {   // on stateQueue
        let contributing = castSelectedIDs.filter { id in
            if case .failed = known[id]?.connectionState { return false }
            return true
        }
        return castRoomDelay.setReceivers(contributing)
    }

    /// CAST-SYNC (brief §4): one lead measurement the session manager judged
    /// trustworthy. Most change nothing — the policy only speaks up when a
    /// receiver settles. On `stateQueue`.
    func applyCastLeadSample(_ id: String, _ leadMs: Int) {   // on stateQueue
        guard let settlement = castRoomDelay.ingest(leadMs: leadMs, forID: id) else { return }
        Telemetry.log(.cast, "cast_lead_settled", [
            "device": id,
            "lead_ms": String(settlement.leadMs),
            "refused": settlement.refused ? "1" : "0",
            "term_ms": _castTermMs.map(String.init) ?? "nil",
        ])
        guard settlement.termMoved else {
            // The term stayed put, so the ROOM did not move — but this
            // receiver's share of it just did, and it is the only output that
            // needs telling. Pushing the whole room fan-out here would
            // re-anchor every Bluetooth and local sink for a change none of
            // them can see.
            pushCastFeedDelaysLocked()
            return
        }
        roomDelayChangedLocked(cause: "cast_lead")
    }

    /// CAST-SYNC: hand every settled receiver the part of the room delay it
    /// does not already produce by itself. On `stateQueue`.
    ///
    /// Called on BOTH edges that can change a receiver's share: the room delay
    /// moving, and a receiver settling. The second one is easy to miss — a
    /// receiver that settles BELOW the current term leaves `R` alone, so
    /// nothing about the room changed, but that receiver's own share just went
    /// UP by the difference. Live 2026-08-29: a reselect restored a remembered
    /// term of 5916 ms while the receiver settled at 5462, and with this
    /// keyed off the room alone the 454 ms never got inserted — the Cast leg
    /// ran that much ahead of everything else, which is plainly audible.
    private func pushCastFeedDelaysLocked() {   // on stateQueue
        // The per-receiver Cast feed lines are the fourth leg of this fan-out.
        // Each receiver's feed is held back by `room − settledLeadMs`, the part
        // of the room delay it does not already produce by itself. For the
        // furthest-behind receiver — the one that SET the term — that remainder
        // is a few tens of ms; for a SECOND, faster receiver it is seconds, and
        // it is the whole reason this leg exists.
        //
        // Three receivers are deliberately skipped, and in every case the point
        // is that no delay line gets allocated: one still settling has no
        // trustworthy lead to subtract, one refused for exceeding `R_max` plays
        // unsynced by policy, and one whose remainder is zero already meets the
        // room. `setCastRoomDelayMs` hops to the manager's own queue, so this
        // stays a plain call from `stateQueue`.
        let room = roomDelayLocked()
        let refusedIDs = castRoomDelay.refusedIDs
        for id in castSelectedIDs where !refusedIDs.contains(id) {
            guard let settled = castRoomDelay.settledLeadMs(forID: id) else { continue }
            let remainder = room - settled
            guard remainder > 0 else { continue }
            castOutputManager?.setCastRoomDelayMs(remainder, forDeviceID: id)
        }
    }

    /// CAST-SYNC (brief §3): the room delay moved — hand `R` to every output
    /// that has to delay itself to it. On `stateQueue`.
    ///
    /// The Bluetooth sinks and the Mac's own sink read `R` live and re-sample
    /// it whenever they re-anchor, so a nudge is all they need. The AirPlay
    /// feed has no such loop and is held back explicitly, by a line in FRONT
    /// of the engine: the sender reads its start buffer once, at session
    /// creation, and clamps it to 5 s, so it cannot carry seconds of room
    /// delay however it is set.
    ///
    /// A Cast join also flips the BT composition, so those sinks can take this
    /// re-anchor on top of that transition's rebuild — the same hold restarted
    /// a queue hop later, not a second gap.
    func roomDelayChangedLocked(cause: String) {   // on stateQueue
        let airPlayPreDelayMs = publishAirPlayPreDelayLocked()
        let btRides = btSinkEnabled
        let macRides = syncedLocalSinkApplied
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            if btRides { self.btSink?.reanchorAll(cause: "room_delay_change") }
            if macRides { self.syncedLocalSink?.requestReanchor(cause: "room_delay_change") }
        }
        pushCastFeedDelaysLocked()
        Telemetry.log(.cast, "room_delay_changed", [
            "cause": cause,
            "room_ms": String(roomDelayLocked()),
            "cast_term_ms": _castTermMs.map(String.init) ?? "nil",
            "airplay_pre_ms": String(airPlayPreDelayMs),
        ])
    }

    /// Hold the AirPlay feed back by the part of the room delay the sender does
    /// not already provide, and return what was published. Idempotent — the
    /// same depth twice is one word written on the control thread — so it is
    /// also what a selection change calls when the room did not move but the
    /// devices meeting it did. On `stateQueue`.
    @discardableResult
    private func publishAirPlayPreDelayLocked() -> Int {   // on stateQueue
        // No AirPlay device, no line: nothing would read it, and it is a
        // megabyte and a memcpy per buffer. An output also cannot be delayed by
        // less than nothing — and `0` publishes NO line rather than an empty
        // one, which is the whole bypass: a room that leaves Cast is back to
        // today's exact bytes on the very next buffer.
        //
        // Read from the SELECTION, never from `btComposition`: that memo is
        // only refreshed when the Bluetooth side moves, so in an AirPlay+Cast
        // room with no Bluetooth in it it never becomes true at all.
        let airPlayPresent = expectedSelected.contains { id in
            known[id].map { !$0.isBluetooth && !$0.isLocalDevice && !$0.isCast && !$0.isWired } == true
        }
        let ms = airPlayPresent ? Swift.max(0, roomDelayLocked() - _startBufferMs) : 0
        captureControlQueue.async { [weak self] in
            self?.captureCoordinator?.setAirPlayPreDelay(ms: ms)
        }
        return ms
    }

    /// Fold one `BTConnectionManager.connect` outcome into the row's
    /// connection state (and, on success, the sink set). Availability itself
    /// still arrives via the enumerator refresh the connect notification fires —
    /// this is the row's lifecycle answer, not a parallel availability source.
    func finishBTReconnect(id: String, outcome: BTConnectOutcome) {
        stateQueue.async {
            switch outcome {
            case .connected:
                // The one place this process learns a Bluetooth baseband link
                // came up for a NAMED device. `BTConnectionManager
                // .onConnectionsChanged` fires on every connect/disconnect
                // edge but carries neither an address nor a direction, so it
                // cannot attribute a link-up to a UID and is not a second feed
                // for this. A reconnect restarts the settling window and moves
                // the row onto last time's number.
                self.btSpeakerTiming.noteConnected(uid: id)
                // BT-LIFECYCLE: a baseband connect is not yet audio. A SELECTED
                // id keeps breathing until its sink renders; an UNSELECTED one
                // goes straight to `.off` — nothing will flow to it by design,
                // so a hold there could only spin forever.
                if self.expectedSelected.contains(id) {
                    self.beginBTConnectingLocked(id)
                } else {
                    self.setConnectionState(.off, for: id)
                }
                // Wave-3 known gap, closed: a SELECTED id that just came back
                // re-enters the per-device sink set now, not at the next
                // selection change.
                self.reapplyBTSinkLocked()
                // Each reconnect lands 20–90 ms from last time
                // (`bt-latency-stability-research-2026-09-05.md`), so this is
                // one of the moments worth listening at (spec decision 2).
                self.noteDriftTrigger(.reconnect(uid: id))
            case .unauthorized:
                self.setConnectionState(.failed(ConnectionFailure(
                    cause: .unknown, detail: "Bluetooth permission not granted")), for: id)
            case .failed(let elapsed, let reason):
                // Live-measured classification (bt-spike-findings-2026-08-07):
                // a powered-off speaker holds the OS attempt ~15.4 s (both
                // brands) or hits our 20 s ceiling; a speaker another host
                // holds refuses fast. The slow case reads `.unknown` — headline
                // "Couldn't connect", matching AirPlay's generic failure
                // (owner's call, 2026-08-07) — rather than the
                // AirPlay-flavored `.timedOut`.
                let cause: ConnectionFailure.Cause =
                    (reason == "timeout" || elapsed >= 10) ? .unknown : .connectedElsewhere
                self.setConnectionState(.failed(ConnectionFailure(
                    cause: cause,
                    detail: "\(reason) after \(String(format: "%.1f", elapsed))s")), for: id)
            }
        }
    }

}
