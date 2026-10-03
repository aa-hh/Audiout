import Foundation
import AudioToolbox
import AirPlayEngine
import CastSender

extension NativeBackend {
    // MARK: Public aggregate default-output ownership + routing-blocked warning (Wave 3, T5)

    /// Reconcile the public aggregate's default-output ownership off the current
    /// selection intent, then (re)evaluate the routing-blocked warning. Called
    /// whenever `expectedSelected` changes (the activation seam, Q1).
    ///
    /// AMBIGUITY FLAGGED (Q1): "actively routing" here is defined as
    /// `!expectedSelected.isEmpty` — i.e. WHOLE-SYSTEM routing (≥1 AirPlay output
    /// selected). That is the only path whose audio depends on the aggregate being
    /// the Mac's default: the whole-system tap follows
    /// `kAudioHardwarePropertyDefaultOutputDevice`, so it captures nothing unless
    /// the default is our aggregate. Per-app `.device` redirects tap the app's
    /// PROCESS directly (independent of the default output), so they deliberately
    /// do NOT arm the aggregate takeover or the warning.
    ///
    /// Decides on `stateQueue`; the default-output reads and the set-default write
    /// run on `captureControlQueue`, because `stateQueue` never makes a Core Audio
    /// call (an unanswering coreaudiod would otherwise hold every main-thread
    /// `stateQueue.sync` behind it).
    func reconcileAggregateDefault() {   // on stateQueue
        let wantTakeover = !expectedSelected.isEmpty
        // Seamless handoff T3.6: `expectedSelected` just settled — re-decide
        // whether the blocked-attempt watcher should be running.
        reconcileHandoffWatcherLocked()
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            if wantTakeover {
                self.takeOverDefaultAndReflect()
            } else {
                // Not routing: never take the Mac's default output (Q1) — and hand it
                // back whenever it IS our aggregate, however it got there, or the Mac
                // keeps playing through a device that swallows every volume write. The
                // slider and the hardware volume keys then move nothing the user can hear.
                let current = self.currentDefaultOutputUIDProvider()
                self.restoreDefaultFromAggregate(current: current)
                // The warning is off by definition.
                self.stateQueue.sync { self.evaluateRoutingBlocked(currentDefaultUID: current) }
            }
        }
    }

    /// Take the Mac's default output for the aggregate and reflect the resulting
    /// steady state of the routing-blocked warning. Shared by the activation seam
    /// and the user's ``reselectAggregateAsDefault()``.
    ///
    /// On a SUCCESSFUL set-default write we reflect the intended state
    /// (`blocked = false`) OPTIMISTICALLY rather than reading the default straight
    /// back: the HAL default-device change lands asynchronously, so an immediate
    /// read can still return the PRE-write device and emit a transient `true` that
    /// the echo-guard would then leave stuck. The optimistic reflect happens only
    /// while the echo guard is still armed for the aggregate: once the listener has
    /// handled a change it has cleared the guard and already decided the warning
    /// (our own echo reflects `false` there; a user's switch-away evaluates it), so
    /// the commit leaves it alone. When no write was issued (aggregate already
    /// default, or unresolvable) we read the default again and evaluate normally.
    /// On `captureControlQueue`: it reads the default output (a Core Audio call)
    /// here and commits the warning through `stateQueue.sync`.
    private func takeOverDefaultAndReflect() {   // on captureControlQueue
        let current = currentDefaultOutputUIDProvider()
        if pointDefaultAtAggregate(current: current) {
            stateQueue.sync {
                guard expectedDefaultWriteUID == AggregateOutputDevice.productUID else { return }
                setRoutingBlocked(false)
            }
        } else {
            let now = currentDefaultOutputUIDProvider()
            stateQueue.sync { evaluateRoutingBlocked(currentDefaultUID: now) }
        }
    }

    /// Point the Mac's default output at the public aggregate, capturing the prior
    /// default ONCE (for the quit-time restore) the first time we take over.
    /// Returns `true` iff it issued a SUCCESSFUL set-default write THIS call;
    /// `false` when the aggregate is already the default, can't be resolved, or the
    /// backend has stopped. The guard is armed before the write, and the caller's
    /// commit defers to the listener when the guard is already gone. The guard is
    /// ``expectedDefaultWriteUID``, cleared again if the write is refused, so a
    /// refused write can't leave a stale guard. Used by both the activation seam
    /// and the user's re-select — both legitimate (app routing vs. the user's own
    /// click); neither is Q2's forbidden PROGRAMMATIC re-select
    /// ("re-select without the user asking").
    ///
    /// On `captureControlQueue`: the resolve and the write are Core Audio calls and
    /// `stateQueue` never makes one. Backend state is read and written through
    /// `stateQueue.sync`. The guard is armed BEFORE the write is issued, because the
    /// listener's echo hops onto `stateQueue` on its own and can now land before a
    /// commit made after the write returns.
    private func pointDefaultAtAggregate(current: String?) -> Bool {   // on captureControlQueue
        guard let aggregateID = aggregateControl.resolveDeviceID(forUID: AggregateOutputDevice.productUID) else { return false }
        let running: Bool = stateQueue.sync {
            // stop() can run between the hop and the write.
            guard started else { return false }
            if !aggregateDefaultActive {
                // Capture what the user had so `stop()` can restore it. Never remember
                // the aggregate itself as the "prior" (we're about to destroy it).
                if let current, current != AggregateOutputDevice.productUID {
                    priorDefaultUID = current
                }
                aggregateDefaultActive = true
            }
            if current != AggregateOutputDevice.productUID {
                expectedDefaultWriteUID = AggregateOutputDevice.productUID
            }
            return true
        }
        guard running else { return false }
        guard current != AggregateOutputDevice.productUID else { return false }   // already ours
        guard aggregateControl.setDefaultOutputDevice(aggregateID) else {
            stateQueue.sync {
                if expectedDefaultWriteUID == AggregateOutputDevice.productUID {
                    expectedDefaultWriteUID = nil
                }
            }
            return false
        }
        return true
    }

    /// First UID in `uids` (nils dropped, order preserved) that `control` can
    /// resolve to a live device id right now.
    ///
    /// Callable from any queue, but EXPENSIVE — `resolveDeviceID(forUID:)` may
    /// enumerate the HAL, and `builtInOutputDeviceUID()` certainly does — so never
    /// run it on the main queue or a fader-drag thread.
    ///
    /// `static` so a resolver closure built from it holds no reference to the
    /// backend and cannot keep it alive.
    static func firstResolvableDevice(
        uids: [String?], using control: AggregateDeviceControlling
    ) -> (uid: String, id: AudioObjectID)? {
        uids.compactMap { $0 }.lazy.compactMap { uid in
            control.resolveDeviceID(forUID: uid).map { (uid: uid, id: $0) }
        }.first
    }

    /// Give the Mac's default output back to a real device once whole-system
    /// routing goes empty (the user deselected their last AirPlay speaker), leaving
    /// the aggregate itself ALIVE — unlike `stop()`, which restores and then
    /// destroys it. It has to stay: it is the app's entry in Sound settings, and a
    /// re-select takes it over again.
    ///
    /// The ONLY entry condition is that the default output IS our aggregate.
    /// Deliberately NOT also `aggregateDefaultActive`,
    /// the way `stop()`'s restore is: that flag is process-local while the
    /// aggregate's default-ness is system-wide and survives a relaunch, so a
    /// default this process never wrote — left by a previous session, auto-picked
    /// by macOS when the device appeared, or chosen by the user in Sound settings
    /// — would never be handed back, and Mac-only through the aggregate is pure
    /// passthrough with dead volume control. Best-effort like `stop()`'s: nothing
    /// resolvable to restore to leaves the default exactly where it is.
    ///
    /// `priorDefaultUID` is deliberately KEPT (`stop()` clears it). The HAL's
    /// default-device change lands asynchronously, so a fast re-select can still
    /// read the aggregate as the current default and skip
    /// ``pointDefaultAtAggregate(current:)``'s prior-capture — the standing value is
    /// then the only good prior left.
    ///
    /// On `captureControlQueue`: `current` is the default output the caller already
    /// read, the target resolve and the write are Core Audio calls, and backend
    /// state goes through `stateQueue.sync`. The echo guard is armed before the
    /// write for the same reason as in ``pointDefaultAtAggregate(current:)``.
    private func restoreDefaultFromAggregate(current: String?, attempt: Int = 1) {   // on captureControlQueue
        guard current == AggregateOutputDevice.productUID else { return }
        // stop() can run between the hop and the write.
        let (running, storedPrior) = stateQueue.sync { (started, priorDefaultUID) }
        guard running else { return }
        // What the user had, else the Mac's built-in output — the same sub-device
        // the aggregate itself wraps, so it is the one target that is still there
        // when the prior device was unplugged mid-session.
        let prior = storedPrior.flatMap { $0 == AggregateOutputDevice.productUID ? nil : $0 }
        guard let target = Self.firstResolvableDevice(
            uids: [prior, aggregateControl.builtInOutputDeviceUID()], using: aggregateControl) else {
            Telemetry.log(.airplay, "aggregate_default_restore", [
                "outcome": "no_target", "prior": prior ?? "none", "attempt": "\(attempt)"])
            return
        }
        stateQueue.sync { expectedDefaultWriteUID = target.uid }
        let wrote = aggregateControl.setDefaultOutputDevice(target.id)
        stateQueue.sync { restoreWriteReturned(wrote, target: target, attempt: attempt) }
    }

    /// VOLUME CONTINUITY: bring the device we just handed the default back to up
    /// to Main, or the Mac jumps to whatever level that hardware was left at.
    ///
    /// The Main mirror (``builtInOutputTargetResolver()``) keeps only the BUILT-IN
    /// output in step during a session, so a prior default that was anything else
    /// — AirPods, a USB DAC, external speakers — has been sitting untouched at its
    /// pre-session level the whole time. Addressed by the device id already
    /// resolved here rather than by "whatever is default", because the HAL's switch
    /// lands asynchronously and a resolve-the-default write would still hit the
    /// aggregate, which takes every volume write and applies none. On `stateQueue`.
    private func pushMainToRestoredDevice(_ target: (uid: String, id: AudioObjectID)) {   // on stateQueue
        let main = mainOutGain
        let id = target.id
        // Memoise only on a confirmed write, as `setMasterGain` does — same
        // readable-but-unwritable-output trap.
        systemVolume.setVolume(main, resolvingTarget: { id }) { [weak self] wrote in
            guard let self, wrote else { return }
            self.stateQueue.async { self.lastSeenSystemVolume = main }
        }
    }

    /// How long to wait before reading back whether the restore write actually
    /// moved the default. Not a sleep and not a guess at HAL latency: a write the
    /// HAL ACCEPTS AND IGNORES raises no change notification at all, so there is no
    /// event to wait on and a scheduled read-back is the only way to tell it apart
    /// from one still in flight (the same reason the takeover reflects
    /// optimistically instead of reading straight back).
    private static let restoreLandingCheckDelay: TimeInterval = 0.5

    /// The restore write came back. `true` only means the HAL accepted it — the
    /// documented failure mode in this area is acceptance without effect (root
    /// AGENTS.md: a destroy of the current system output returns `noErr` and does
    /// nothing), so schedule a read-back rather than believing it. On `stateQueue`.
    private func restoreWriteReturned(_ wrote: Bool, target: (uid: String, id: AudioObjectID),
                                      attempt: Int) {   // on stateQueue
        Telemetry.log(.airplay, "aggregate_default_restore", [
            "outcome": wrote ? "wrote" : "write_refused",
            "target": target.uid, "attempt": "\(attempt)"])
        guard wrote else {
            if expectedDefaultWriteUID == target.uid { expectedDefaultWriteUID = nil }
            return
        }
        aggregateDefaultActive = false
        pushMainToRestoredDevice(target)
        captureControlQueue.asyncAfter(deadline: .now() + Self.restoreLandingCheckDelay) { [weak self] in
            self?.verifyRestoreLanded(target: target, attempt: attempt)
        }
    }

    /// Read the default back: did the write we were told succeeded actually move
    /// it? On `captureControlQueue`: the read-back is a Core Audio call, and the
    /// flags are written through `stateQueue.sync`.
    ///
    /// razor: exactly ONE retry. A write ignored twice is a HAL state this app
    /// cannot argue with, and a loop here would fight the user; the telemetry line
    /// is what a live session is meant to leave behind. Upgrade path if the log
    /// ever shows a second attempt landing: schedule off the capture-stopped edge
    /// instead of a fixed delay.
    private func verifyRestoreLanded(target: (uid: String, id: AudioObjectID), attempt: Int) {   // on captureControlQueue
        let current = currentDefaultOutputUIDProvider()
        let retry: Bool = stateQueue.sync {
            // stop() can run between the hop and the write.
            guard started else { return false }
            guard current == AggregateOutputDevice.productUID else {
                Telemetry.log(.airplay, "aggregate_default_restore", [
                    "outcome": "landed", "default": current ?? "unreadable", "attempt": "\(attempt)"])
                return false
            }
            Telemetry.log(.airplay, "aggregate_default_restore", [
                "outcome": "did_not_land", "target": target.uid, "attempt": "\(attempt)"])
            // The aggregate is still the Mac's default, so we still hold it whatever
            // the write reported.
            aggregateDefaultActive = true
            expectedDefaultWriteUID = nil
            // A re-select in the meantime is the user asking for the aggregate back —
            // never fight it.
            return attempt == 1 && expectedSelected.isEmpty
        }
        if retry {
            restoreDefaultFromAggregate(current: current, attempt: 2)
        }
    }

    /// Compute the routing-blocked steady state — actively routing AND the current
    /// default output is not our aggregate — and push it. Reuses the pure
    /// ``AggregateOutputDevice/classifyOffSwitch(newDefaultUID:)`` decision. On
    /// `stateQueue`. `currentDefaultUID` is the default output the caller already
    /// read off `stateQueue`, so this makes no Core Audio call.
    func evaluateRoutingBlocked(currentDefaultUID: String?) {   // on stateQueue
        let blocked: Bool
        if !expectedSelected.isEmpty {
            let outcome = publicAggregate.classifyOffSwitch(newDefaultUID: currentDefaultUID)
            blocked = outcome != .stillOurs
        } else {
            blocked = false
        }
        setRoutingBlocked(blocked)
    }

    /// Edge-triggered emit of the routing-blocked warning: a repeat of the current
    /// state is a no-op, so it can never thrash the event stream. On `stateQueue`.
    func setRoutingBlocked(_ blocked: Bool) {   // on stateQueue
        guard blocked != routingBlockedEmitted else { return }
        routingBlockedEmitted = blocked
        emit(.routingBlockedNeedsDefault(blocked))
    }

    /// USER-INITIATED re-select of the aggregate as the Mac's default output — the
    /// popover's "Use Audiout" warning button (Q6). The user's own click IS their
    /// intent, so this is the one sanctioned re-select and does NOT violate Q2's
    /// "never programmatically re-select." Flips the warning off through the same
    /// echo-guarded path as activation. Public so `AppDelegate` can wire
    /// `PopoverController.onReselectAudiout` to it.
    ///
    /// Seamless handoff T3.7: this is also the resume button — if a handoff release
    /// is in force, put EVERYTHING back (whole-system AND per-app redirects).
    public func reselectAggregateAsDefault() {
        captureControlQueue.async {
            self.takeOverDefaultAndReflect()
            self.stateQueue.async {
                let (kicks, teardown) = self.resumeFromHandoffLocked()
                for (id, outputID) in kicks {
                    Task { [weak self] in
                        // D2 (adversarial review): await the release's own teardown
                        // before converging — otherwise a stale `removeOutput` is
                        // unordered against the engine actor relative to this resumed
                        // `addOutput` and could land after it, killing the fresh session.
                        await teardown?.value
                        await self?.convergeDevice(id: id, outputID: outputID)
                    }
                }
            }
        }
    }

    /// Put every session a handoff release tore down back: mirrors
    /// `handleSystemDidWake()`'s re-converge critical section minus the wake-specific
    /// bits (no `awaitingWakeReconnect` — this isn't a wake), plus Option B: also
    /// re-issues every still-recorded per-app stream binding, since a handoff release
    /// tears per-app sessions down too (D3) but leaves `streamBindings` itself
    /// untouched as the record of user intent. On `stateQueue`.
    ///
    /// Returns the release's own teardown task (D2) alongside the kicks so every
    /// caller can await it before converging — see the doc on `handoffTeardown`.
    func resumeFromHandoffLocked() -> (kicks: [(String, OutputID)], teardown: Task<Void, Never>?) {   // on stateQueue
        guard self.started, self.handoffReleased else { return ([], nil) }
        self.handoffReleased = false
        self.defaultLeftUsSinceRelease = true
        self.suspended = false
        self.clearSilenceOverride()
        let teardown = self.handoffTeardown
        self.handoffTeardown = nil

        var kicks: [(String, OutputID)] = []
        let desiredIDs = self.order.filter { self.desiredOn[$0] == true }
        for id in desiredIDs {
            guard let outputID = self.outputIDs[id] else { continue }
            self.failedGate.remove(id)
            self.setConnectionState(.connecting, for: id)
            if !self.converging.contains(id) {
                self.converging.insert(id)
                kicks.append((id, outputID))
            }
        }

        // Option B: re-issue every per-app redirect too. `streamBindings` still
        // records the user's per-app intent (a handoff release never clears it,
        // only `stop()` does) — reuse the same `.bind` op / `enqueueBindOps` FIFO
        // `performBindOp` normally issues from topology changes.
        var bindOps: [StreamBindOp] = []
        for (deviceID, stream) in self.streamBindings {
            if let outputID = self.outputIDs[deviceID] {
                bindOps.append(.bind(outputID, stream))
            }
        }
        // Re-verify D2 (per-app half): the release folded these same per-app
        // outputs into `handoffTeardown`, and `enqueueBindOps` chains onto
        // `bindTail` with no knowledge of it — a re-bind landing before the old
        // teardown's `removeOutput` would be killed by it moments later. Splice
        // the teardown into the bind FIFO as a barrier so every re-bind runs
        // strictly after the teardown completes (same ordering the whole-system
        // kicks get by awaiting `teardown` directly).
        if !bindOps.isEmpty, let teardown {
            self.bindTail = Task { [prev = self.bindTail] in
                await prev.value
                await teardown.value
            }
        }
        self.enqueueBindOps(bindOps)

        self.reconcileCaptureGate()
        self.reconcileSilenceWatchdog()
        self.reconcileHandoffWatcherLocked()

        Telemetry.log(.airplay, "handoff_resume", ["kicked": String(kicks.count)])
        return (kicks, teardown)
    }

}
