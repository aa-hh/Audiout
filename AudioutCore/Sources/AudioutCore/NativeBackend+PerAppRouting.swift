import Foundation
import AudioToolbox
import AirPlayEngine
import CastSender

extension NativeBackend {
    // MARK: Per-app routing (T6 — ADDITIVE to the Selected Devices path above)

    /// Whether a `.device(id:)` route pointed at `id` can actually carry audio
    /// RIGHT NOW: the device is in our discovered snapshot, reports itself
    /// reachable, and has somewhere to stream through — an engine output handle,
    /// or, for a Bluetooth speaker, its own delay-line sink, which the manager
    /// feeds by UID and which therefore never holds an `outputIDs` entry. On
    /// `stateQueue`.
    ///
    /// The second arm tests the POSITIVE kind (`isBluetooth`), never `!isCast`
    /// or `supportsAirPlay2`: Cast is the third R-partition arm with no per-app
    /// delivery path at all, and AP1 receivers share `supportsAirPlay2: false`
    /// with Bluetooth while being engine-driven.
    ///
    /// This is the whole basis of the effective route table below (R5). A route
    /// aimed at an unreachable receiver is intent, not a live redirect: honouring
    /// it would pull the app out of the whole-system tap and hand its audio to a
    /// stream that goes nowhere, i.e. silence the app. An UNKNOWN id counts as
    /// unreachable, which is also what makes launch safe — persisted routes are
    /// pushed in before discovery has found anything, and each one engages as its
    /// device shows up.
    private func isRouteTargetReachableLocked(_ id: String) -> Bool {   // on stateQueue
        guard let device = known[id], device.isAvailable else { return false }
        return outputIDs[id] != nil || device.isBluetooth
    }

    /// Whether whole-system routing CLAIMS `id` at the DECISION layer —
    /// pure selection intent (`expectedSelected`), set atomically in one place
    /// (`setOutputSet`; `activateGroup` funnels through it) and stable across
    /// `applyStartBuffer`'s internal `desiredOn` flap. Roadmap 008 mechanism 1
    /// (demote-at-decision): whole-system always wins a contested device, and the
    /// losing `.device` route reads as effective-`.noRedirect` so the app audibly
    /// rejoins the whole-system mix — the exact semantics R5 already gives an
    /// unreachable target. On `stateQueue`.
    private func isWholeSystemClaimedLocked(_ id: String) -> Bool {   // on stateQueue
        expectedSelected.contains(id)
    }

    /// Whether whole-system routing OPERATIONALLY claims `id` at the EXECUTION
    /// layer: desired on, mid-converge, or holding a live whole-system session
    /// (`added`). The fire-time gates (roadmap 008 mechanism 2) key on this — not
    /// on intent alone — because their job is precisely the in-flight window
    /// intent cannot see: a deselected device whose teardown `removeOutput` is
    /// still in flight is still whole-system-owned at the engine. On `stateQueue`.
    private func isWholeSystemOperationallyClaimedLocked(_ id: String) -> Bool {   // on stateQueue
        desiredOn[id] == true || converging.contains(id) || added.contains(id)
    }

    /// Reachable AND not whole-system-claimed — the full eligibility test a
    /// `.device` route target must pass to be honored (R5 + roadmap 008). The
    /// reachability helper above stays pure on purpose. On `stateQueue`.
    func isRouteTargetEligibleLocked(_ id: String) -> Bool {   // on stateQueue
        isRouteTargetReachableLocked(id) && !isWholeSystemClaimedLocked(id)
    }

    /// Whether any per-app route currently AIMS at `id` — a `.device` route
    /// naming it, or a `.group` route whose resolved membership contains it.
    /// The two eligibility replays below (R5's reachability edge, roadmap 008's
    /// selection edge) both key on this, and both used to match `.device` only:
    /// a group-routed app whose member went briefly unreachable — or was
    /// released by Main Out — was then never re-resolved, so it stayed excluded
    /// from the whole-system mix with its stream bound to a speaker that had
    /// gone away. Routed in the UI, silent at every speaker, and unrecoverable
    /// short of re-picking the destination by hand. On `stateQueue`.
    func routesTargetDeviceLocked(_ id: String) -> Bool {   // on stateQueue
        lastRoutes.contains { route in
            switch route.destination {
            case .device(let deviceID):        return deviceID == id
            case .group(let groupID):          return lastGroupTargets[groupID]?.memberVolumes[id] != nil
            case .noRedirect, .currentDevice:  return false
            }
        }
    }

    /// `routes` with every `.device` route whose target is unreachable right now
    /// demoted to `.noRedirect` — the EFFECTIVE table, which is what all of the
    /// per-app machinery keys off (R5). On `stateQueue`.
    ///
    /// Demoting to `.noRedirect` (rather than dropping the route) is what makes the
    /// app rejoin the system mix: `.noRedirect` is exclusion-equivalent to having no
    /// route at all, so the bundle ID leaves `routedBundleIDs`, its per-app tap
    /// stops, and the whole-system tap stops excluding it — it plays through
    /// whatever the user's current top-level selection outputs to. Deliberately NOT
    /// `.currentDevice`, which would open a private local stream and pin the app to
    /// the Mac instead of following the system.
    ///
    /// The USER's table (`lastRoutes`, and the persisted store above it) is never
    /// rewritten by this — that is the difference between R5 and the old
    /// reset-on-unavailable behavior, and it is what lets
    /// `rerunAppRoutesForReachabilityChange` restore the redirect with no
    /// route-table edit and no user action.
    /// What one resolve produced: the effective route table (a route with no
    /// eligible speaker left demoted to `.noRedirect`) and, for every route that
    /// kept at least one, the speakers it actually feeds with the gain to feed
    /// them at.
    struct EffectiveAppRoutes {
        let routes: [AppRoute]
        let routedApps: [AppRouteMixer.RoutedApp]
    }

    func effectiveAppRoutesLocked(_ routes: [AppRoute]) -> EffectiveAppRoutes {   // on stateQueue
        // Roadmap 008: demotion now keys on ELIGIBILITY (reachable AND not
        // whole-system-claimed), not bare reachability — a route whose target is a
        // Selected Device is demoted exactly like an unreachable one, so the app
        // rejoins the whole-system mix (which includes the contested device)
        // instead of streaming into the void. Claim demotions additionally keep an
        // edge-triggered, queryable conflict record (loud loser).
        //
        // A GROUP route runs the same per-device test over each resolved member
        // and keeps whatever survives — the app plays on the group's remaining
        // speakers rather than losing the whole route to one contested member.
        // Only an EMPTY survivor set demotes it, which is the same "nowhere to
        // stream" condition a single unreachable target already means.
        var claimDemotions: [String: [String]] = [:]   // device id → demoted bundle ids
        var routedApps: [AppRouteMixer.RoutedApp] = []
        let mapped = routes.map { route -> AppRoute in
            let candidates: [String: Int]
            switch route.destination {
            case .noRedirect, .currentDevice:
                return route
            case .device(let id):
                candidates = [id: 100]
            case .group(let id):
                candidates = lastGroupTargets[id]?.memberVolumes ?? [:]
            }
            var gains: [String: Int] = [:]
            for (deviceID, memberVolume) in candidates {
                if isWholeSystemClaimedLocked(deviceID) {
                    claimDemotions[deviceID, default: []].append(route.bundleID)
                    continue
                }
                guard isRouteTargetReachableLocked(deviceID) else { continue }
                gains[deviceID] = AppRouteMixer.composedGain(
                    routeVolume: route.volume, memberVolume: memberVolume)
            }
            guard !gains.isEmpty else {
                var demoted = route
                demoted.destination = .noRedirect
                return demoted
            }
            routedApps.append(AppRouteMixer.RoutedApp(bundleID: route.bundleID, deviceGains: gains))
            return route
        }
        reconcileScopeConflictsLocked(claimDemotions)
        return EffectiveAppRoutes(routes: mapped, routedApps: routedApps)
    }

    /// Edge-triggered bookkeeping for demote-at-decision (roadmap 008): diff the
    /// whole-system-claim demotions this resolve produced against the active
    /// conflict records, emitting `scope_conflict` telemetry only when a
    /// (device, routes) conflict engages, changes shape, or disengages — repeated
    /// resolves of an unchanged table are silent, so the single-domain op traces
    /// stay byte-identical. On `stateQueue`.
    private func reconcileScopeConflictsLocked(_ demotions: [String: [String]]) {   // on stateQueue
        for (deviceID, bundleIDs) in demotions {
            let sorted = bundleIDs.sorted()
            if lastScopeConflicts[deviceID]?.bundleIDs == sorted { continue }
            lastScopeConflicts[deviceID] = ScopeConflict(
                bundleIDs: sorted, stream: streamBindings[deviceID], date: Date())
            Telemetry.log(.airplay, "scope_conflict", [
                "device": deviceID, "winner": "wholeSystem", "stage": "routeDemoted",
                "bundleIDs": "[" + sorted.joined(separator: ",") + "]",
                "stream": streamBindings[deviceID].map(String.init) ?? "-",
            ])
        }
        for deviceID in lastScopeConflicts.keys where demotions[deviceID] == nil {
            lastScopeConflicts.removeValue(forKey: deviceID)
            Telemetry.log(.airplay, "scope_conflict", [
                "device": deviceID, "winner": "wholeSystem", "stage": "routeRestored",
            ])
        }
    }

    /// Re-push the CURRENT (unedited) route table so `effectiveAppRoutesLocked`
    /// re-resolves it — the recovery half of R5. A redirect target becoming
    /// reachable again must restart that app's per-app tap and put it back in the
    /// whole-system tap's exclusion set with no route-table mutation and no user
    /// action; a target becoming unreachable must do the reverse.
    ///
    /// Safe to call WITH `stateQueue` held (every caller does) because the work is
    /// only ENQUEUED here: `updateAppRoutes` takes `stateQueue` synchronously itself,
    /// so running it inline would deadlock. `captureControlQueue` is the same serial
    /// queue the capture gate uses, which keeps this ordered against the tap
    /// start/stops it causes. Reading the table at EXECUTION time (not capture time)
    /// means a genuine route edit landing in between wins instead of being clobbered
    /// by a stale snapshot.
    func rerunAppRoutesForReachabilityChange() {
        captureControlQueue.async { [weak self] in
            guard let self else { return }
            let (routes, excluded, groupTargets) = self.stateQueue.sync {
                (self.lastRoutes, self.lastExcludedBundleIDs, self.lastGroupTargets)
            }
            guard !routes.isEmpty else { return }
            self.updateAppRoutes(routes, excludedBundleIDs: excluded, groupTargets: groupTargets)
        }
    }

    /// Feed the current per-app routing table in. The single external entry point
    /// for per-app redirect (T7 calls this whenever `AppRoutingController.appRoutes`
    /// changes, passing the Settings excluded-apps denylist as `excludedBundleIDs`).
    ///
    /// This is ADDITIVE: it never touches `expectedSelected` / `added` / the capture
    /// gate — the whole-system "Selected Speakers" path (stream_id 0) keeps working
    /// exactly as before. On call it:
    ///  1. Recomputes the mixer topology (`routeMixer.updateRoutes`), which fires
    ///     `onDestinationSetsChanged` synchronously iff the distinct app-sets changed
    ///     — that handler binds each destination device to its stream_id and emits
    ///     `.routedApps`.
    ///  2. Starts a per-app capture for each newly-captured bundle ID (routed to a
    ///     `.device` OR to `.currentDevice`) and stops the capture for each app that
    ///     dropped out of BOTH (back to `.noRedirect` / removed). The tap is
    ///     destination-agnostic, so its lifecycle keys on the UNION of the two sets.
    ///  3. For `.currentDevice` apps (Bug T2): renders each on the Mac's built-in
    ///     speakers via ``localPlaybackEngine`` as an independent stream, and adds
    ///     them to the whole-system tap's exclusion set so they don't ALSO play in
    ///     the AirPlay mix.
    ///  4. Syncs the whole-system tap's exclusion set (T4) so individually-routed
    ///     (`.device`) AND `.currentDevice` apps don't double up into the system mix.
    ///
    /// Every one of those four steps reads the EFFECTIVE table
    /// (``effectiveAppRoutesLocked(_:)``), not the raw one it was handed: a `.device`
    /// route whose target is unreachable right now is treated exactly as
    /// `.noRedirect` for the duration (R5), so the app keeps playing in the system
    /// mix instead of being excluded in favour of a stream that goes nowhere. Only
    /// `lastRoutes` (the user's intent, replayed by
    /// ``rerunAppRoutesForReachabilityChange()``) and the display-name map keep the
    /// raw table. Re-calling this with an unchanged table is therefore MEANINGFUL,
    /// not a no-op — it is how a reachability change is applied.
    ///
    /// Concurrency: the routed-bundle-ID diff and the display-name refresh happen
    /// under `stateQueue` (serialized against concurrent calls). Everything that can
    /// BLOCK — `perAppCapture.start`/`stop` (Core Audio tap create/teardown), the
    /// `localPlaybackEngine` graph mutations, and the mixer's own queue hop — runs
    /// OUTSIDE `stateQueue`, the same discipline the capture gate keeps for
    /// `captureControlQueue`.
    public func updateAppRoutes(
        _ routes: [AppRoute], excludedBundleIDs: Set<String> = [],
        groupTargets: [String: GroupRouteTarget] = [:]
    ) {
        // T6-rev: the other routing-action permission chokepoint. Same placement
        // and same non-blocking contract as `setOutputSet`'s — see `onRoutingAction`.
        onRoutingAction?()
        let plan: UpdateRoutesPlan = stateQueue.sync {
            self.lastRoutes = routes
            // A `.group` route is a live reference: this snapshot is what it
            // resolves against, so a group edit re-pushing an unchanged route
            // table still moves the audio.
            self.lastGroupTargets = groupTargets
            // A cleared route or a group edit/delete can drop a greyed wired
            // row's only remaining reference — both re-push through here.
            self.pruneUnusedWiredLocked()
            // Retained so the metering-only target set can subtract it and so a
            // denylist change alone re-reconciles the metering taps (T3, PRIVACY).
            self.lastExcludedBundleIDs = excludedBundleIDs
            self.routeDisplayNames = Dictionary(
                routes.map { ($0.bundleID, $0.displayName) }, uniquingKeysWith: { _, new in new })
            // R5: everything below keys off the EFFECTIVE table — a `.device` route
            // whose target is unreachable right now reads as `.noRedirect`, so the
            // app stays in the whole-system mix rather than being excluded in favour
            // of a stream that can't reach anything.
            let resolved = self.effectiveAppRoutesLocked(routes)
            let effective = resolved.routes
            let newRouted = Set(resolved.routedApps.map(\.bundleID))
            // Bug T2: apps deliberately pinned to the local Mac ("This Mac").
            let newLocal = Set(effective.compactMap { route -> String? in
                route.destination == .currentDevice ? route.bundleID : nil
            })
            // LEVELED apps: un-redirected, but pulled below 100 on the row's
            // slider. Read off the RAW table on purpose — a `.device` route the
            // effective pass just demoted must rejoin the system mix at FULL
            // volume, so a demotion never levels (see `leveledBundleIDs`).
            // Excluded apps are never leveled: the privacy denylist means "never
            // captured", which outranks a volume the user set earlier.
            //
            // STICKY: entering is immediate, and an app NEVER leaves the leveled
            // set on volume alone. Once turned down it stays intercepted for the
            // session, injected at unity when the slider is back at 100 —
            // `scaledStereoSamples` is exact identity at 100, so what it
            // contributes is sample-for-sample what the whole-system tap would
            // have carried.
            //
            // Why sticky rather than a timed exit: leaving costs a Core Audio
            // teardown either way — the app's muted tap is destroyed and the
            // whole-system tap rebuilds because its exclusion set changed. While
            // that tap is down the Mac's own speakers are unmuted, so the app is
            // briefly heard on the Mac before the speaker takes over again (live
            // 2026-08-29, on the deliberate return to 100). Delaying the exit
            // only moves that blip; removing the exit removes it.
            //
            // The previous set IS the memory — no extra state to keep in sync,
            // and it self-clears exactly when it should: leaving `.noRedirect`,
            // being excluded, or dropping out of the route table all fail the
            // guards below and drop the app from the set.
            //
            // razor: session-scoped, and the bit survives a quit+relaunch, so a
            // once-leveled app sitting at 100 is re-tapped at unity when it comes
            // back. Harmless (identical samples) and it keeps the relaunch
            // glitch-free too. If it ever needs to expire, prune it where the
            // other per-bundle bookkeeping is dropped in `handleAppTerminated`.
            let newLeveled = Set(routes.compactMap { route -> String? in
                guard route.destination == .noRedirect,
                      !excludedBundleIDs.contains(route.bundleID) else { return nil }
                guard route.volume < 100 || self.leveledBundleIDs.contains(route.bundleID)
                else { return nil }
                return route.bundleID
            })
            let previousRouted = self.routedBundleIDs
            let previousLocal = self.localBundleIDs
            let previousLeveled = self.leveledBundleIDs
            let captureRunning = self.captureRunning
            self.routedBundleIDs = newRouted
            self.localBundleIDs = newLocal
            self.leveledBundleIDs = newLeveled

            // T8: a bundle ID that isn't in the route table at all any more (fully
            // de-routed or its app-route removed) forgets any dead/retry tracking —
            // a fresh route later starts clean, not still "dead" from a stale
            // failure against a previous route.
            let stillPresent = Set(routes.map(\.bundleID))
            for bundleID in self.deadBundleIDs where !stillPresent.contains(bundleID) {
                self.deadBundleIDs.remove(bundleID)
            }
            for bundleID in self.retryCounts.keys where !stillPresent.contains(bundleID) {
                self.retryCounts.removeValue(forKey: bundleID)
            }
            for bundleID in self.pendingRetries.keys where !stillPresent.contains(bundleID) {
                self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
            }
            // Bookkeeping-hygiene fix: unlike dead/retry tracking above,
            // `everCapturedBundleIDs` must ALSO forget a bundle that merely
            // drops OUT OF ROUTING while staying `stillPresent` in the table —
            // e.g. a `.device` -> `.noRedirect` -> `.device` toggle (same route
            // row, capture genuinely stops via `captureToStop` below and later
            // restarts fresh). Otherwise the later restart's `.capturing` misreads
            // as a RE-capture (see `everCapturedBundleIDs`'s doc comment) and fires
            // an unneeded `resetAirPlaySessionForRoutedApp`. `newRouted`/`newLocal`
            // are both subsets of `stillPresent`, so "not in either" is a strict
            // superset of the old `!stillPresent` condition — every bundle the old
            // check cleared is still cleared here, plus the toggle case. A LEVELED
            // bundle is still wanted for the same reason (its tap keeps running),
            // so it counts as present here too.
            for bundleID in self.everCapturedBundleIDs
            where !newRouted.contains(bundleID) && !newLocal.contains(bundleID)
                && !newLeveled.contains(bundleID) {
                self.everCapturedBundleIDs.remove(bundleID)
            }

            // T8: the mixer only ever sees routes for bundle IDs that are actually
            // capturing — a `deadBundleIDs` entry (quit mid-stream, or a per-app tap
            // that's `.failed`) is excluded here so `.routedApps` / the engine stream
            // binding never claim a silent app is streaming.
            let mixerRoutes = resolved.routedApps.filter { !self.deadBundleIDs.contains($0.bundleID) }

            // The per-app tap is destination-agnostic — one tap serves whichever
            // destination the app currently routes to — so its start/stop keys on
            // the UNION of device- and local-routed apps. An app that merely SWITCHES
            // between `.device` and `.currentDevice` stays in both unions and keeps
            // its tap running (only the downstream consumer changes). A LEVELED app
            // joins the same union: it needs the identical `.mutedWhenTapped` tap,
            // and only what consumes its buffers differs.
            let previousUnion = previousRouted.union(previousLocal).union(previousLeveled)
            let newUnion = newRouted.union(newLocal).union(newLeveled)
            // R5: a bundle ID leaving the capture union must ALSO lose any pending
            // `.processNotYetAudible` retry. The T8 cleanup above keys on the RAW
            // table, which a demoted route is still in — so without this, a timer
            // armed while the route was live would fire later and re-`start` the
            // per-app tap for an app that is now supposed to be in the system mix.
            // That tap is `.mutedWhenTapped`: it would silence the app's normal
            // output while feeding a stream nothing is bound to. Re-engaging the
            // route restarts the tap through `captureToStart`, so nothing is lost.
            for bundleID in previousUnion.subtracting(newUnion) {
                self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
                self.retryCounts.removeValue(forKey: bundleID)
            }
            // T3: re-reconcile the metering-only taps against the new route/excluded
            // table (routed/local/excluded were all just updated above). Empty when
            // metering is inactive. NEVER touches the primary `perAppCapture` taps.
            let meteringDiff = self.meteringTapDiffLocked()
            return UpdateRoutesPlan(
                effectiveRoutes: effective,
                mixerRoutes: mixerRoutes,
                captureToStart: newUnion.subtracting(previousUnion),
                captureToStop: previousUnion.subtracting(newUnion),
                localRemoved: previousLocal.subtracting(newLocal),
                localRoutes: effective.filter { $0.destination == .currentDevice },
                localExcluded: newLocal,
                leveled: newLeveled,
                leveledRoutes: routes.filter {
                    newLeveled.contains($0.bundleID) && !self.deadBundleIDs.contains($0.bundleID)
                },
                // A leveled app renders locally ONLY while the whole-system
                // capture is off; while it runs, its audio goes into the program
                // through the injector instead and a local player would double it.
                leveledLocalRoutes: captureRunning
                    ? []
                    : routes.filter { newLeveled.contains($0.bundleID) },
                leveledLocalRemoved: previousLeveled.subtracting(newLeveled),
                leveledActive: captureRunning,
                meteringToStart: meteringDiff.start,
                meteringToStop: meteringDiff.stop)
        }

        // Topology recompute — synchronously fires `onDestinationSetsChanged`
        // (→ `handleDestinationSetsChanged`) if the distinct app-sets changed. Off
        // `stateQueue`: the mixer owns its own serial queue, and the handler re-enters
        // `stateQueue` on its own (we are not holding it here). Kept SYNCHRONOUS: it's
        // pure in-memory topology math (no Core Audio), and it drives the engine
        // stream binding (via async `bindTail` Tasks), so the redirect still starts
        // connecting immediately.
        routeMixer.updateRoutes(plan.mixerRoutes)

        // Everything below BLOCKS on Core Audio / AVAudioEngine (per-app tap
        // create+`AudioDeviceStart`, the AVAudioEngine graph mutation, the
        // whole-system tap recreate). `updateAppRoutes` is called on the MAIN THREAD
        // (a popover destination pick → `onRoutesDidChange`, or an `NSWorkspace`
        // launch/terminate notification), so running these inline froze the UI for
        // the duration of `AudioDeviceStart`'s HAL round-trip. Hand them to the
        // serial `captureControlQueue` (the same queue the whole-system capture gate
        // uses) so they run OFF the main thread and stay ordered against each other
        // and against the gate. `perAppCapture` / `localPlaybackEngine` are each
        // independently thread-safe; `start`/`stop`/`addApp` are idempotent.
        captureControlQueue.async { [weak self] in
            guard let self else { return }

            // Per-app capture lifecycle. `start`/`stop` are idempotent per bundle ID.
            for bundleID in plan.captureToStart { self.perAppCapture.start(bundleID: bundleID) }
            for bundleID in plan.captureToStop { self.perAppCapture.stop(bundleID: bundleID) }

            // Metering-only taps (T3): a SEPARATE coordinator from `perAppCapture`.
            // Stop apps that became routed/local/excluded (or when metering turned
            // off — the diff is empty then), start newly-listed uncaptured apps.
            // Stop-before-start; idempotent per bundle ID.
            for bundleID in plan.meteringToStop { self.meteringCapture.stop(bundleID: bundleID) }
            for bundleID in plan.meteringToStart { self.meteringCapture.start(bundleID: bundleID) }

            // Local playback (Bug T2), plus the leveled apps that currently have
            // nowhere else to play (whole-system capture off — see
            // `plan.leveledLocalRoutes`):
            //  - Drop players for apps that left `.currentDevice` or the leveled set.
            //  - (Re)add + re-level every current `.currentDevice` app whose tap is
            //    ALREADY capturing — this covers a `.device`→`.currentDevice` switch,
            //    where the tap keeps running so no fresh `.capturing` transition fires
            //    `handleLocalCaptureStateChange`. `addApp` is idempotent, so overlapping
            //    with that handler (for apps whose tap starts fresh) is harmless.
            for bundleID in plan.localRemoved { self.localPlaybackEngine?.removeApp(bundleID: bundleID) }
            for bundleID in plan.leveledLocalRemoved {
                self.localPlaybackEngine?.removeApp(bundleID: bundleID)
            }
            for route in plan.localRoutes + plan.leveledLocalRoutes {
                if case .capturing(let format) = self.perAppCapture.state(for: route.bundleID) {
                    do {
                        try self.localPlaybackEngine?.start()
                        try self.localPlaybackEngine?.addApp(
                            bundleID: route.bundleID, tapFormat: format,
                            volume: Float(route.volume) / 100.0)
                    } catch {
                        Telemetry.fail(.localPlayback, "local_playback:start_failed",
                                       local: ["error": "\(error)"], shared: ["site": "app_routes"])
                    }
                }
                self.localPlaybackEngine?.setVolume(Float(route.volume) / 100.0, for: route.bundleID)
            }

            // The leveled intercept: who is leveled, at what volume, and whether
            // it should be accumulating at all (it must not while the
            // whole-system capture is off — those apps render locally instead).
            self.leveledInjector.updateLeveled(
                plan.leveledRoutes.map { (bundleID: $0.bundleID, volume: $0.volume) })
            self.leveledInjector.setActive(plan.leveledActive)

            // Keep the whole-system tap excluding individually-routed (`.device`) apps,
            // `.currentDevice` apps (Bug T2 — they play via `localPlaybackEngine`, not
            // the AirPlay mix), and user-excluded apps (T4). No-op when no real capture
            // coordinator is wired (tests/UI-smoke).
            //
            // R5: the EFFECTIVE table, so an app whose target is unreachable is NOT
            // excluded — that omission is exactly what puts it back in the system mix.
            //
            // OUR OWN render process needs no staging here: the coordinator's
            // exclusion resolve unconditionally self-excludes `getpid()` (the
            // generalized echo guard in `resolveExcludedObjectIDsLoggingAttribution`),
            // which covers `localPlaybackEngine`'s `.currentDevice` render and the
            // synced-local sink alike. An earlier version of this call also handed the
            // coordinator a `.currentDevice`-conditional render pid; with the
            // unconditional guard in place that only bought an extra tap rebuild whose
            // exclusion set was byte-identical to the one already in force.
            //
            // LEVELED apps are excluded on the same footing: their audio comes
            // back through the injector already scaled, so leaving them in the
            // system tap would play them twice — once at full volume.
            self.captureCoordinator?.updateRouting(
                appRoutes: plan.effectiveRoutes,
                excludedBundleIDs: excludedBundleIDs
                    .union(plan.localExcluded)
                    .union(plan.leveled))
        }
    }

    /// The off-`stateQueue` work `updateAppRoutes` computes under the lock and then
    /// executes without it — a named struct so the (now six-field) hand-off stays
    /// readable.
    struct UpdateRoutesPlan {
        /// The route table as it is being ACTED on: the caller's table with every
        /// `.device` route whose target is currently unreachable demoted to
        /// `.noRedirect` (R5). This — not the raw table — is what the whole-system
        /// tap's exclusion set is computed from.
        let effectiveRoutes: [AppRoute]
        let mixerRoutes: [AppRouteMixer.RoutedApp]
        let captureToStart: Set<String>
        let captureToStop: Set<String>
        let localRemoved: Set<String>
        let localRoutes: [AppRoute]
        let localExcluded: Set<String>
        /// The leveled set itself — what the whole-system tap must ALSO exclude
        /// (a leveled app's audio re-enters through the injector, so leaving it in
        /// the system tap would play it twice, once unattenuated).
        let leveled: Set<String>
        /// The RAW routes of the leveled, non-dead apps — bundle id + volume for
        /// ``LeveledAppInjector/updateLeveled(_:)``.
        let leveledRoutes: [AppRoute]
        /// The leveled routes that need a LOCAL player right now (empty while the
        /// whole-system capture is running).
        let leveledLocalRoutes: [AppRoute]
        /// Bundle IDs that left the leveled set, whose local player must go.
        let leveledLocalRemoved: Set<String>
        /// Whether the injector should be accumulating — the capture gate's own
        /// `captureRunning`, read in the same critical section as the sets above.
        let leveledActive: Bool
        /// Metering-only tap reconcile (T3): bundle IDs to start/stop a dedicated
        /// `.unmuted` meter tap for (listed, uncaptured, unexcluded apps). Empty
        /// while metering is inactive.
        let meteringToStart: Set<String>
        let meteringToStop: Set<String>
    }

    /// React to a per-app capture's state transition for LOCAL (`.currentDevice`)
    /// playback (Bug T2). A no-op unless `bundleID` is currently a `.currentDevice`
    /// route. On `.capturing` (the tap's real `TapFormat` is now known) it starts
    /// the local engine and adds the app's player at its route volume; on any
    /// non-capturing terminal/transitional state it drops the player. Runs off
    /// `stateQueue` (callback context); hops on only to read `localBundleIDs` /
    /// `lastRoutes`. Distinct from `handlePerAppCaptureHealthChange`, which owns the
    /// `.device`/mixer side's dead-bundle tracking.
    func handleLocalCaptureStateChange(
        bundleID: String, state: PerAppCaptureCoordinator.State
    ) {
        switch state {
        case .capturing(let format):
            let volume: Float? = stateQueue.sync {
                // A LEVELED app takes this path too, but ONLY while the
                // whole-system capture is off: while it runs, the app's audio
                // goes into the program through `leveledInjector` and a local
                // player would render it a second time.
                let wantsLocal = self.localBundleIDs.contains(bundleID)
                    || (self.leveledBundleIDs.contains(bundleID) && !self.captureRunning)
                guard wantsLocal else { return nil }
                let vol = self.lastRoutes.first { $0.bundleID == bundleID }?.volume ?? 100
                return Float(vol) / 100.0
            }
            guard let volume else { return }
            do {
                try localPlaybackEngine?.start()
                try localPlaybackEngine?.addApp(bundleID: bundleID, tapFormat: format, volume: volume)
            } catch {
                Telemetry.fail(.localPlayback, "local_playback:start_failed",
                               local: ["error": "\(error)"], shared: ["site": "capture_state"])
            }
        case .idle, .stopping, .failed:
            // Capture stopped/failed. Only pull the player while the app is STILL a
            // local route (a capture failure/hiccup, not a de-route): a de-route
            // already removed it from `localBundleIDs` and `updateAppRoutes` dropped
            // the player explicitly, so this skips then — no double-remove, and
            // `removeApp` is idempotent regardless.
            let isLocal = stateQueue.sync {
                self.localBundleIDs.contains(bundleID) || self.leveledBundleIDs.contains(bundleID)
            }
            guard isLocal else { return }
            localPlaybackEngine?.removeApp(bundleID: bundleID)
        case .resolvingProcess, .creatingTap:
            // Tap is still starting up — nothing to render yet, nothing to drop.
            break
        }
    }

    /// Set the volume of an app rendered from its own capture — a `.currentDevice`
    /// route's LOCAL playback (Bug T2) or a LEVELED one's intercept. The
    /// low-latency path the popover slider drives directly (mirroring how a
    /// `.device` app's volume rides the route table into the mixer); the same value
    /// also arrives via `updateAppRoutes` from the persisted route edit. Maps the
    /// UI's 0–100 int onto the player node's 0.0…1.0 contract.
    public func setLocalPlaybackVolume(volume: Int, bundleID: String) {
        localPlaybackEngine?.setVolume(Float(volume.clampedToVolume) / 100.0, for: bundleID)
        // A LEVELED app's slider drives the same low-latency path — its audio is
        // scaled inside the injector rather than by a local player whenever the
        // whole-system capture is running. Both calls no-op for a bundle the
        // consumer doesn't know, so forwarding unconditionally is correct.
        leveledInjector.setVolume(volume.clampedToVolume, for: bundleID)
    }

    /// React to a per-app capture's state transition (T8, edge case 3: a
    /// per-process tap fails — most commonly `.processNotYetAudible`, routed
    /// before the app started playing audio — or a previously-dead bundle ID
    /// recovers). Runs off `stateQueue` (callback context from
    /// `PerAppCaptureCoordinator.onStateChange`); hops on only for the mutation.
    ///
    /// `.capturing` FIRST checks `bundleID` is still actually wanted (present in
    /// `routedBundleIDs` OR `localBundleIDs`) before accepting it — see the
    /// `isOrphan` branch below for why an orphaned capture can land here at all
    /// (a `.processNotYetAudible` retry racing a de-route) and why it must be
    /// stopped rather than accepted. Once accepted, it clears
    /// `deadBundleIDs`/`retryCounts`/`pendingRetries` for the bundle ID and, if it
    /// had been dead, re-includes it in the mixer topology.
    /// `.failed` marks it dead (excluding it from `.routedApps` / the engine stream
    /// binding so a silent app is never claimed as streaming) and, ONLY for
    /// `.processNotYetAudible`, schedules an INDEFINITE capped-exponential-backoff
    /// retry that continues as long as the route is still desired — a paused app is
    /// re-probed forever and its `deadBundleIDs` exclusion is temporary (cleared on
    /// the eventual `.capturing`), never a permanent give-up. Every other failure
    /// needs the user to act (grant permission, update macOS), so nothing else is
    /// retried blindly.
    func handlePerAppCaptureHealthChange(
        bundleID: String, state: PerAppCaptureCoordinator.State
    ) {
        switch state {
        case .capturing:
            let (recovered, isRecapture, isOrphan): (Bool, Bool, Bool) = stateQueue.sync {
                // A capture can land here for a bundle ID nobody wants any more: a
                // `.processNotYetAudible` retry (`scheduleProcessNotYetAudibleRetry`)
                // scheduled BEFORE a de-route can fire AFTER it and SUCCEED — the app
                // started playing audio in the meantime, so `perAppCapture.start`
                // does NOT fail fast the way the retry's doc comment used to
                // (incorrectly) assume. That builds a brand-new coordinator slot
                // that nothing in `updateAppRoutes`'s route-table diff will ever
                // see again. Refuse it here rather than accept it.
                guard self.wantsPerAppCaptureLocked(bundleID) else {
                    return (false, false, true)
                }
                let wasDead = self.deadBundleIDs.remove(bundleID) != nil
                self.retryCounts.removeValue(forKey: bundleID)
                self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
                // First-ever capture inserts (isRecapture=false); a later capture
                // (tap rebuilt) is already present (isRecapture=true).
                let isRecapture = !self.everCapturedBundleIDs.insert(bundleID).inserted
                return (wasDead, isRecapture, false)
            }
            if isOrphan {
                // Nothing wants this tap any more — stop it rather than leave a
                // live (muted, per `TapMuteBehavior.mutedWhenTapped`) Core Audio
                // tap + private aggregate device + IOProc running in coreaudiod
                // forever for a bundle ID that is neither routed nor local.
                //
                // MUST be dispatched, never called inline: the `onStateChange`
                // callback that reached us fires SYNCHRONOUSLY from inside
                // `PerAppCaptureCoordinator`'s own private serial `queue`
                // (`transition(_:bundleID:to:)`, itself invoked from a
                // `queue.sync { … }` in `beginStart`/`handleDeviceChange`).
                // `PerAppCaptureCoordinator.stop(bundleID:)` ALSO does
                // `queue.sync { … }` on that SAME queue — calling it inline here
                // would recursively `sync` onto a serial queue we are already
                // executing on and deadlock the coordinator (and every per-app
                // capture app-wide) the very first time this race occurs.
                // `captureControlQueue` is the existing convention for
                // Core-Audio-touching work triggered by a route/state change (see
                // the comment above `updateAppRoutes`'s own hand-off to this same
                // queue, a few hundred lines up).
                captureControlQueue.async { [weak self] in
                    self?.perAppCapture.stop(bundleID: bundleID)
                }
                return
            }
            if recovered {
                // Was excluded from the topology while dead; re-adding it rebinds
                // the device anyway, so no separate session reset is needed.
                republishMixerTopology()
            } else if isRecapture {
                // The tap was rebuilt with no death in between (a sample-rate
                // change). The topology is unchanged, so the AirPlay session keeps
                // its now-desynced RTP anchor unless we explicitly reset it.
                resetAirPlaySessionForRoutedApp(bundleID: bundleID)
            }
            // W1-T7 (Gap 2, R9): the moment a routed-and-therefore-excluded app
            // becomes audible, its per-app tap reaches `.capturing` here. Until
            // this instant its pid could NOT be translated to a Core Audio
            // process object, so the whole-system tap's exclusion list did not
            // actually exclude it — its audio was double-sent (to its own device
            // AND into the system mix). The system tap doesn't re-resolve on its
            // own for this case (the app's PID set is unchanged, so Gap 1's
            // membership diff correctly finds no change — only the pid's
            // TRANSLATABILITY changed). Force the exclusion re-resolve now, reusing
            // W1-T5's relaunch mechanism: it no-ops unless `bundleID` is actually
            // excluded/routed-away, so it's cheap for a bundle that turns out not
            // to be excluded (a `.currentDevice` app, or metering-only capture).
            captureCoordinator?.refreshExcludedProcessSet(forRelaunchedBundleID: bundleID)

        case .failed(let error):
            let (justDied, shouldRetry, attempt): (Bool, Bool, Int) = stateQueue.sync {
                let justDied = self.deadBundleIDs.insert(bundleID).inserted
                guard self.routedBundleIDs.contains(bundleID),
                      case .processNotYetAudible = error
                else {
                    // Bookkeeping-hygiene fix: no retry is being scheduled from
                    // here (either the bundle isn't routed any more, or this is a
                    // NON-retryable failure while it still is) — a `pendingRetries`
                    // entry left over from the retry attempt that just landed here
                    // (or any earlier one) is now stale and must not linger as a
                    // dangling `DispatchWorkItem` reference.
                    self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
                    return (justDied, false, 0)
                }
                // Indefinite retry: as long as the route is still desired (guard
                // above), a paused app is re-probed forever. `retryCounts` is kept
                // ONLY to grow the backoff delay, never as a give-up ceiling — so a
                // routed app is never permanently marked dead for `.processNotYetAudible`.
                let attempt = (self.retryCounts[bundleID] ?? 0) + 1
                self.retryCounts[bundleID] = attempt
                return (justDied, true, attempt)
            }
            if justDied { republishMixerTopology() }
            if shouldRetry {
                scheduleProcessNotYetAudibleRetry(bundleID: bundleID, attempt: attempt)
            }

        case .idle, .resolvingProcess, .creatingTap, .stopping:
            break
        }
    }

    /// Whether the per-app tap layer currently wants a tap for `bundleID` — the
    /// union `updateAppRoutes` starts/stops captures for: `.device` routes,
    /// `.currentDevice` routes, and LEVELED (`.noRedirect`, volume < 100) routes.
    /// Every "is this capture still wanted" question goes through this one
    /// predicate: a bundle missing from it has its landing `.capturing` refused as
    /// an orphan and its tap stopped, which for a leveled app would silently undo
    /// the intercept. On `stateQueue`.
    private func wantsPerAppCaptureLocked(_ bundleID: String) -> Bool {   // on stateQueue
        routedBundleIDs.contains(bundleID)
            || localBundleIDs.contains(bundleID)
            || leveledBundleIDs.contains(bundleID)
    }

    /// Re-run the mixer over the current route table minus dead bundle IDs (T8).
    /// Called whenever `deadBundleIDs` changes OUTSIDE of `updateAppRoutes` itself
    /// (a capture health transition), so the topology — and therefore `.routedApps`
    /// / the engine stream bindings — stays in sync with what's actually capturing.
    private func republishMixerTopology() {
        routeMixer.updateRoutes(effectiveMixerRoutes())
    }

    /// Reset the AirPlay RTP session for every device on `bundleID`'s stream by
    /// rebinding it (removeOutput → addOutput = a fresh RTSP/RTP session with a
    /// clean timeline anchor). Called when a routed app's per-app tap was rebuilt
    /// (a sample-rate/device change), which leaves the receiver desynced and
    /// permanently silent even though real PCM keeps flowing. `streamIDs(for:)`
    /// reads the mixer's own queue, so it's fetched BEFORE taking `stateQueue`.
    func resetAirPlaySessionForRoutedApp(bundleID: String) {
        let streams = Set(routeMixer.streamIDs(for: bundleID).map(UInt32.init))
        guard !streams.isEmpty else { return }
        stateQueue.sync {
            for (deviceID, bound) in self.streamBindings where streams.contains(bound) {
                if let outputID = self.outputIDs[deviceID] {
                    // Fresh reset → bump the generation (supersedes + cancels any
                    // in-flight recovery for this device) and start attempt 1.
                    let gen = (self.rebindRecoveryGen[deviceID] ?? 0) + 1
                    self.rebindRecoveryGen[deviceID] = gen
                    self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                    self.emit(.streamHealth(id: deviceID, recovering: true))
                    // T4: the trigger + generation bump for the rebind-recovery
                    // chain `enqueueRebindRecovery` is about to start (attempt 1)
                    // for this device. `scope` is the routed app whose per-app tap
                    // rebuild caused this — the one fact the attempt trail below
                    // can't otherwise carry.
                    Telemetry.log(.airplay, "session_reset", [
                        "device": deviceID,
                        "scope": bundleID,
                        "stream": "\(bound)",
                        "gen": "\(gen)",
                        "trigger": "recapture",
                    ])
                    self.enqueueRebindRecovery(
                        deviceID: deviceID, outputID: outputID, scope: .perApp(stream: bound),
                        gen: gen, attempt: 1)
                }
            }
        }
    }

    /// Reset the WHOLE-SYSTEM AirPlay RTP session for every currently
    /// streaming Selected Device by rebinding it (removeOutput → addOutput = a fresh
    /// RTSP/RTP session with a clean timeline anchor) — the whole-system analogue of
    /// `resetAirPlaySessionForRoutedApp` (T2). Called when the whole-system tap was
    /// rebuilt (a nominal-sample-rate renegotiation), which leaves every receiver on
    /// the whole-system mix desynced and permanently silent even though real PCM
    /// keeps flowing. Iterates `added` (the devices actually streaming the mix),
    /// not `expectedSelected`/`desiredOn` — only a device with a live engine session
    /// has a session to reset. Runs on `stateQueue`.
    ///
    /// Single-flight: bumps each device's `rebindRecoveryGen` (shared per-deviceID
    /// with the per-app path — a device is either whole-system or per-app, never
    /// both, so one recovery chain per device is exactly right) and cancels any
    /// pending backoff before enqueuing attempt 1. A rapid rate bounce
    /// (44.1→48→44.1) fires this again; the second bump supersedes the first
    /// chain's bookkeeping, so recovery never thrashes.
    func resetAirPlaySessionForWholeSystem() {
        stateQueue.sync {
            for deviceID in self.added {
                guard let outputID = self.outputIDs[deviceID] else { continue }
                // Finding 1: claim the SAME `converging` slot `convergeDevice`
                // claims for a user-driven select/deselect (see `setOutputSet`'s
                // `!self.converging.contains(id)` gate) so the recovery's
                // removeOutput→addOutput can never interleave with a concurrent
                // convergeDevice op for this device — the two used to be
                // independent serialization domains touching the same OutputID,
                // which could leave the engine streaming a device the backend
                // had already deselected (or silent on a device just selected).
                // If a real convergeDevice is already running for this device,
                // bow out: that loop owns the engine ops right now and will
                // settle the device into whatever state is currently desired —
                // the next topology change re-binds/re-syncs it idempotently.
                guard !self.converging.contains(deviceID) else {
                    Telemetry.log(.airplay, "whole_system_rebind_skipped", [
                        "device": deviceID, "reason": "already_converging",
                    ])
                    continue
                }
                self.converging.insert(deviceID)
                self.rebindConverging.insert(deviceID)
                let gen = (self.rebindRecoveryGen[deviceID] ?? 0) + 1
                self.rebindRecoveryGen[deviceID] = gen
                self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                // The stream the recovery will re-add onto — `performRebindRecovery`
                // reads the same home for the same device.
                let home = self.connectTargetStreamLocked(deviceID)
                Telemetry.log(.airplay, "session_reset", [
                    "device": deviceID,
                    "scope": "wholeSystem",
                    "stream": "\(home)",
                    "gen": "\(gen)",
                    "trigger": "recapture",
                    "recovery": "flush_first",
                ])
                self.emit(.streamHealth(id: deviceID, recovering: true))
                self.enqueueRebindRecovery(
                    deviceID: deviceID, outputID: outputID, scope: .wholeSystem,
                    gen: gen, attempt: 1)
            }
        }
    }

    /// Which AirPlay session a rebind-recovery chain is restoring (T2/T4). Both
    /// kinds share `rebindRecoveryGen`/`pendingRebindRecoveries` (keyed by deviceID,
    /// so one device never runs two chains at once) but differ in the engine op they
    /// issue and the "do we still own this device?" ownership check they use to bow
    /// out the moment the device is de-routed/deselected.
    enum RebindScope: Equatable {
        /// A per-app redirect's dedicated stream (≥ 1). Ownership:
        /// `streamBindings[deviceID] == stream`. Re-added via `addOutput(_:streamId:)`.
        case perApp(stream: UInt32)
        /// The whole-system "Selected Speakers" output set. Ownership:
        /// `added.contains(deviceID)`. Re-added onto the device's home stream
        /// (``connectTargetStreamLocked(_:)``) through `bindOutput` — the exact
        /// op `convergeDevice` used to bind it.
        case wholeSystem
    }

    /// Whether `deviceID` still owns the session `scope` describes — the guard both
    /// the completion handler and the backoff re-check use to bow out the moment a
    /// device is de-routed (per-app) or deselected (whole-system). Must hold
    /// `stateQueue`.
    func stillOwnsRebind(deviceID: String, scope: RebindScope) -> Bool {
        switch scope {
        case .perApp(let stream):
            // Roadmap 008: the WS-claim conjunct. A `.perApp` recovery firing in
            // the demotion-latency window (claim landed, eviction not yet
            // propagated through the mixer topology) still sees its
            // `streamBindings` slot set — without this conjunct it would
            // removeOutput→addOutput(N) and tear down the user's fresh
            // whole-system session. The `.wholeSystem` arm is NOT gated on the
            // claim: it IS the whole-system domain and holds the `converging` slot.
            return self.streamBindings[deviceID] == stream
                && !self.isWholeSystemOperationallyClaimedLocked(deviceID)
        case .wholeSystem:        return self.added.contains(deviceID)
        }
    }

    /// A short label for `scope` used in the recovery diagnostics.
    private static func rebindScopeLabel(_ scope: RebindScope) -> String {
        switch scope {
        case .perApp(let stream): return "stream=\(stream)"
        case .wholeSystem:        return "whole-system"
        }
    }

    /// Perform ONE rebind (removeOutput → addOutput) for a routed device's AirPlay
    /// session and — UNLIKE the fire-and-forget `enqueueBindOps` — OBSERVE whether
    /// the engine's `addOutput` threw (T4). Chains onto `bindTail` so it stays
    /// serialized against every other per-device engine op (a topology change's
    /// bind/rebind/unbind for the same device never overlaps this). On failure it
    /// reschedules with a small capped-doubling backoff up to
    /// `maxRebindRecoveryAttempts`, then gives up LOUDLY (a `"gave_up"` Telemetry
    /// outcome below) and
    /// leaves the device unbound-in-engine — a receiver that keeps refusing the
    /// rebind is genuinely gone, and infinite removeOutput/addOutput would thrash a
    /// real device; the next topology change re-binds it idempotently anyway.
    ///
    /// Single-flighted per device via `rebindRecoveryGen`: a newer reset bumps the
    /// gen, so this chain — checking its captured `gen` still matches on completion
    /// — bows out the moment it is superseded, or the device stops owning the
    /// session `scope` describes (per-app: `streamBindings[deviceID] != stream`;
    /// whole-system: `!added.contains(deviceID)`, i.e. deselected). Called on
    /// `stateQueue` (the async body hops back onto `stateQueue` only for the
    /// bookkeeping mutation, never holding it across the engine op).
    ///
    /// `verifyFirst` (roadmap 008, whole-system scope only) selects the settle
    /// flavor `performBindOp`'s four-case unbind arm uses: read
    /// `engine.boundStreamId` and rebind ≥ 1 → 0, with ZERO engine ops when the
    /// session is already on 0 — instead of the teardown+re-add.
    func enqueueRebindRecovery(
        deviceID: String, outputID: OutputID, scope: RebindScope, gen: Int, attempt: Int,
        verifyFirst: Bool = false
    ) {   // on stateQueue
        // T4: every call into this function — attempt 1 from
        // `resetAirPlaySessionForRoutedApp`, or a later attempt recursing from the
        // backoff `DispatchWorkItem` below — traces back to a tap-rebuild
        // recapture (the only call site today, so `trigger` is hardcoded rather
        // than threaded as a parameter — keeps this purely additive). Both call
        // sites already hold `stateQueue` (see their own `// on stateQueue`
        // markers), so this is just a format + non-blocking hand-off, same as the
        // other `Telemetry.log` calls already in this chain — no new locking, no
        // new await, no reordering of what follows.
        Telemetry.log(.airplay, "rebind", [
            "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
            "trigger": "recapture", "outcome": "scheduled",
        ])
        let prev = self.bindTail
        self.bindTail = Task { [weak self] in
            await prev.value
            guard let self else { return }
            // Roadmap 008 pre-op gate: the same gen + ownership guard the
            // completion below runs, re-checked BEFORE the engine op. These chain
            // ops execute `performRebindRecovery` directly on `bindTail` — they
            // never pass through `performBindOp`'s fire-time gate — so without
            // this a superseded/ownership-lost chain would still issue its
            // remove/add pair and only THEN notice. On failure, skip the op and
            // fall through with `ok = false`: the completion's own guard takes
            // the terminal `superseded` exit (telemetry + slot release) exactly
            // as it always has. Uncontested chains pass both checks and their op
            // traces are unchanged.
            let preflightOK: Bool = self.stateQueue.sync {
                self.rebindRecoveryGen[deviceID] == gen
                    && self.stillOwnsRebind(deviceID: deviceID, scope: scope)
            }
            let ok = preflightOK
                ? await self.performRebindRecovery(outputID: outputID, scope: scope, verifyFirst: verifyFirst)
                : false
            // Finding 1: for whole-system scope, every TERMINAL exit of this chain
            // (bailed-because-superseded/deselected, succeeded, or gave-up) must
            // release the `converging` slot claimed in
            // `resetAirPlaySessionForWholeSystem` — and, mirroring
            // `convergeDevice`'s own defer, immediately re-kick a real
            // `convergeDevice` if the desired state moved while the slot was
            // held (e.g. the user re-selected/deselected mid-recovery). The
            // in-flight backoff-retry path deliberately does NOT release the
            // slot — the recovery chain is still in progress, and releasing
            // early would let a concurrent convergeDevice op interleave with
            // the next attempt's removeOutput/addOutput, reopening the race.
            let action: ConvergeReleaseAction = self.stateQueue.sync {
                // Superseded by a newer reset, or the device stopped owning this
                // session (per-app unbind/teardown cleared the binding, or a
                // whole-system deselect dropped it from `added`): we no longer own it.
                guard self.rebindRecoveryGen[deviceID] == gen,
                      self.stillOwnsRebind(deviceID: deviceID, scope: scope) else {
                    // T4: which guard failed — a newer reset already bumped (or an
                    // unbind/deselect cleared) `gen`, or ownership of this device's
                    // session moved elsewhere (a topology change, or — for
                    // whole-system scope — a concurrent convergeDevice claimed it).
                    // Read-only over state already under this `stateQueue.sync`; no
                    // extra locking.
                    let reason = self.rebindRecoveryGen[deviceID] != gen ? "gen_superseded" : "ownership_changed"
                    Telemetry.log(.airplay, "rebind", [
                        "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
                        "trigger": "recapture", "outcome": "superseded", "reason": reason,
                    ])
                    if case .wholeSystem = scope {
                        return self.releaseRebindConverging(id: deviceID)
                    }
                    return .none
                }
                if ok {
                    Telemetry.log(.airplay, "rebind", [
                        "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
                        "trigger": "recapture", "outcome": "succeeded",
                    ])
                    self.rebindRecoveryGen.removeValue(forKey: deviceID)
                    self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                    self.emit(.streamHealth(id: deviceID, recovering: false))
                    if case .wholeSystem = scope {
                        return self.releaseRebindConverging(id: deviceID)
                    }
                    return .none
                }
                guard attempt < self.maxRebindRecoveryAttempts else {
                    Telemetry.log(.airplay, "rebind", [
                        "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
                        "trigger": "recapture", "outcome": "gave_up",
                    ])
                    self.rebindRecoveryGen.removeValue(forKey: deviceID)
                    self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                    if case .wholeSystem = scope {
                        return self.releaseRebindConverging(id: deviceID)
                    }
                    return .none
                }
                let delay = self.rebindRecoveryRetryDelay * pow(2.0, Double(attempt - 1))
                // T4: an explicit 5th outcome beyond the task's four named ones
                // (scheduled/succeeded/gave-up/superseded) — this attempt failed
                // but hasn't hit the ceiling, so a backed-off retry is queued.
                // Without it the trail would jump straight from this attempt's
                // `scheduled` line to the next attempt's, with no record that this
                // one failed or why the next is delayed.
                Telemetry.log(.airplay, "rebind", [
                    "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt)",
                    "trigger": "recapture", "outcome": "retry_scheduled",
                    "delayMs": "\(Int(delay * 1000))",
                ])
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let action: ConvergeReleaseAction = self.stateQueue.sync {
                        // Superseded while waiting out the delay: a newer chain now
                        // owns this device's bookkeeping AND — for whole-system scope —
                        // its `converging` slot, so touch neither. Releasing or
                        // clearing here would pull the newer recovery's state out from
                        // under it.
                        guard self.rebindRecoveryGen[deviceID] == gen else {
                            // T4: the backed-off retry for `attempt + 1` never got
                            // to run. Without this line the trail goes silent after
                            // `retry_scheduled` with no explanation.
                            Telemetry.log(.airplay, "rebind", [
                                "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt + 1)",
                                "trigger": "recapture", "outcome": "superseded",
                                "reason": "gen_superseded_before_retry_fired",
                            ])
                            return .none
                        }
                        // Still the reigning chain, but the device no longer owns this
                        // session (or went away): a TERMINAL exit. The scheduling
                        // attempt deliberately kept the whole-system `converging` slot
                        // held ("still in progress") and nothing else will ever release
                        // it, so release it here like every other terminal exit does.
                        // Skipping this leaked the slot and permanently wedged the
                        // device (see `releaseRebindConverging`); the commonest way in
                        // is a sleep landing during the backoff, which clears `added`
                        // and so fails the ownership re-check below.
                        guard self.stillOwnsRebind(deviceID: deviceID, scope: scope),
                              let out = self.outputIDs[deviceID] else {
                            Telemetry.log(.airplay, "rebind", [
                                "device": deviceID, "gen": "\(gen)", "attempt": "\(attempt + 1)",
                                "trigger": "recapture", "outcome": "superseded",
                                "reason": "state_changed_before_retry_fired",
                            ])
                            self.rebindRecoveryGen.removeValue(forKey: deviceID)
                            self.pendingRebindRecoveries.removeValue(forKey: deviceID)
                            self.emit(.streamHealth(id: deviceID, recovering: false))
                            if case .wholeSystem = scope {
                                return self.releaseRebindConverging(id: deviceID)
                            }
                            return .none
                        }
                        self.enqueueRebindRecovery(
                            deviceID: deviceID, outputID: out, scope: scope,
                            gen: gen, attempt: attempt + 1, verifyFirst: verifyFirst)
                        return .none
                    }
                    if action.redrivePerApp { self.replayPendingPerAppBindings(trigger: "ws_release") }
                    if let requeue = action.requeue {
                        Task { [weak self] in
                            await self?.convergeDevice(id: deviceID, outputID: requeue)
                        }
                    }
                }
                self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                self.pendingRebindRecoveries[deviceID] = work
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
                return .none // still in progress — keep the `converging` slot held
            }
            if action.redrivePerApp { self.replayPendingPerAppBindings(trigger: "ws_release") }
            if let requeue = action.requeue {
                Task { [weak self] in await self?.convergeDevice(id: deviceID, outputID: requeue) }
            }
        }
    }

    /// The observable rebind: stop the device's session then re-add it on the stream
    /// `scope` selects, returning whether the re-add SUCCEEDED (T4). The
    /// `removeOutput` throw is tolerated (the device may not currently be added — a
    /// no-op teardown is fine); only the `addOutput` result determines success, since
    /// that is what actually re-establishes the RTP session with a clean timeline
    /// anchor. Whole-system re-adds onto the device's home stream through
    /// `bindOutput` (the exact op `convergeDevice` used); per-app uses
    /// `addOutput(_:streamId:)`.
    func performRebindRecovery(
        outputID: OutputID, scope: RebindScope, verifyFirst: Bool = false
    ) async -> Bool {
        let label = Self.rebindScopeLabel(scope)
        Telemetry.log(.airplay, "rebind_recover_starting", ["output": "\(outputID)", "scope": label])

        // Roadmap 008 verify-first settle (whole-system only; see `performBindOp`'s
        // four-case unbind arm): arbitrate on ENGINE truth read AFTER the racing op
        // completed. Already on 0 (or no live session at all) → success with ZERO
        // engine ops; astray on a per-app stream (≥ 1, the silent-`.alreadyBound`
        // corruption) → one serialized `rebindOutput` to 0. No PTP gate here: an
        // astray session is a LIVE session, so the clock is already up (the same
        // reasoning the F-REANCHOR flush documents below). A throw feeds this
        // chain's normal backoff/give-up.
        if verifyFirst, case .wholeSystem = scope {
            let device = deviceID(for: outputID) ?? "\(outputID)"
            let home = wholeSystemHomeStream(for: outputID)
            let live = await engine.boundStreamId(for: outputID)
            guard let live, live != home else {
                Telemetry.log(.airplay, "unbind_downgraded", ["device": device, "settled": "noop"])
                return true
            }
            do {
                try await engine.rebindOutput(outputID, toStreamId: home)
                Telemetry.log(.airplay, "unbind_downgraded", ["device": device, "settled": "rebound"])
                return true
            } catch {
                Telemetry.log(.airplay, "rebind_recover_failed", [
                    "output": "\(outputID)", "scope": label, "error": "\(error)",
                ])
                return false
            }
        }

        // F-REANCHOR (2026-07-26): a tap rebuild's recovery used to be a full
        // removeOutput→addOutput (fresh RTSP/RTP session = the audible Sonos drop the
        // user hears on every headphone mode-change). For whole-system scope, try an
        // RTSP FLUSH re-anchor FIRST instead: it keeps the session alive and only
        // re-syncs the receiver's timeline. Observed to hold on the tested Sonos; not
        // yet proven across receiver models, so this is defended two ways: a flush
        // that DIDN'T issue (returns false — device not streaming / session gone) or
        // that throws falls through to the teardown+rebuild below, and the silence
        // watchdog remains the backstop if an issued flush fails to re-anchor on some
        // receiver. A flush can therefore never silently leave the device dead.
        // razor: whole-system only (that's the reported bug); per-app rebinds keep
        // the teardown path — per-app has no delivery gate for a two-tap overlap.
        if case .wholeSystem = scope {
            do {
                if try await engine.flushOutput(outputID) {
                    // A flush was ACTUALLY issued (re-anchored in place) — done.
                    Telemetry.log(.airplay, "rebind_recover_flush", [
                        "output": "\(outputID)", "scope": label, "outcome": "issued",
                    ])
                    return true
                }
                // flushOutput returned false: the vendored flush no-op'd (device not
                // STREAMING / session gone), so nothing re-anchored. Do NOT report
                // success — fall through to the teardown+re-add, which re-establishes
                // the session. Treating a no-op as success here was a silent-forever
                // regression an adversarial review caught.
                Telemetry.log(.airplay, "rebind_recover_flush", [
                    "output": "\(outputID)", "scope": label, "outcome": "noop_fallback",
                ])
            } catch {
                Telemetry.log(.airplay, "rebind_recover_flush", [
                    "output": "\(outputID)", "scope": label, "outcome": "failed_fallback",
                    "error": "\(error)",
                ])
                // fall through to teardown+rebuild
            }
        }

        // T5+T4 takeover gate, the same one every session-establishing engine op
        // runs behind — and DELIBERATELY only in front of the teardown+re-add
        // below, never the F-REANCHOR flush above it. The flush re-anchors the
        // session that is already up; it establishes nothing, needs no clock, and
        // gating it would have made the cheap in-place recovery inherit the gate's
        // real side effects — a default-output switch-away, the "taking over" strip
        // and a bounded activation wait — on a path whose entire point is to avoid
        // the audible drop a fresh session costs. A re-add is a different animal: a
        // clockless one re-establishes a session that plays silence, so it stays
        // gated. Practically instant mid-session (the clock is already up); on a
        // genuine refusal the `false` return feeds this chain's backoff/give-up.
        guard await ensurePTPTakeover(telemetryDeviceID: deviceID(for: outputID) ?? "\(outputID)") else {
            Telemetry.log(.airplay, "rebind_recover_failed", [
                "output": "\(outputID)", "scope": label, "error": "timingUnavailable",
            ])
            return false
        }

        try? await engine.removeOutput(outputID)
        do {
            switch scope {
            case .perApp(let stream): try await engine.addOutput(outputID, streamId: stream)
            // The device's home stream, read under the lock right before the op —
            // the same one `convergeDevice` binds to, so a recovery can never land
            // the speaker on a different stream from the one the plan is shaped
            // for. `bindOutput` owns the stream-0-vs-stream-N entry-point switch.
            case .wholeSystem:        try await bindOutput(
                outputID, toStream: wholeSystemHomeStream(for: outputID))
            }
            return true
        } catch {
            Telemetry.log(.airplay, "rebind_recover_failed", [
                "output": "\(outputID)", "scope": label, "error": "\(error)",
            ])
            return false
        }
    }

    /// The whole-system stream `outputID`'s device is homed on, read under
    /// `stateQueue` — `0` for an output no known device claims, which is the flat
    /// stream and the safe answer for a session nobody owns. Call from OUTSIDE
    /// `stateQueue`.
    private func wholeSystemHomeStream(for outputID: OutputID) -> UInt32 {
        guard let id = deviceID(for: outputID) else { return 0 }
        return stateQueue.sync { self.connectTargetStreamLocked(id) }
    }

    /// `lastRoutes` resolved for the mixer: unreachable-target `.device` routes
    /// demoted (R5, ``effectiveAppRoutesLocked(_:)``), then any bundle ID currently
    /// in `deadBundleIDs` dropped (T8). Acquires `stateQueue` itself — call only
    /// from OUTSIDE any existing `stateQueue.sync` block (e.g. not from
    /// `updateAppRoutes`'s own critical section, which computes the equivalent
    /// inline to avoid a same-queue deadlock).
    func effectiveMixerRoutes() -> [AppRouteMixer.RoutedApp] {
        stateQueue.sync {
            self.effectiveAppRoutesLocked(self.lastRoutes).routedApps
                .filter { !self.deadBundleIDs.contains($0.bundleID) }
        }
    }

    /// Schedule the next `.processNotYetAudible` retry with capped-exponential
    /// backoff (T8, edge case 3) — self-heals a route made just before the app
    /// started playing audio, and keeps re-probing an app that stays paused,
    /// without the user touching the UI again. The delay is
    /// `retryDelay × 2^(attempt-1)`, capped at `processNotYetAudibleMaxBackoff`
    /// (e.g. 2 → 4 → 8 → 10 → 10 … forever). Single-flighted: replaces any retry
    /// already pending for this bundle ID (so N `.failed` events never stack N
    /// timers).
    ///
    /// CORRECTED: this was previously documented as best-effort-safe on the
    /// assumption that "if the route is gone by the time the timer fires,
    /// `perAppCapture.start` fails fast (`.appNotRunning` or similar)". That is
    /// FALSE whenever the app has started playing audio by the time this fires —
    /// `start` then SUCCEEDS (lands `.capturing`) even though the route is long
    /// gone, because this closure captures only `bundleID`, never re-checks
    /// `routedBundleIDs`/`localBundleIDs`, and `PerAppCaptureCoordinator.start`
    /// happily builds a brand-new slot from `.idle`. The guard against that
    /// resurrected/orphaned capture lives at the OTHER end instead, where the
    /// outcome is actually known: the `.capturing` case in
    /// `handlePerAppCaptureHealthChange` checks route/local membership before
    /// accepting a capture, and stops (rather than accepts) an orphaned one. This
    /// timer is deliberately left unguarded on the route table.
    func scheduleProcessNotYetAudibleRetry(bundleID: String, attempt: Int) {
        let delay = min(
            processNotYetAudibleRetryDelay * pow(2.0, Double(attempt - 1)),
            processNotYetAudibleMaxBackoff)
        let work = DispatchWorkItem { [weak self] in
            self?.perAppCapture.start(bundleID: bundleID)
        }
        stateQueue.sync {
            self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
            self.pendingRetries[bundleID] = work
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + delay, execute: work)
    }

    /// React to the WHOLE-SYSTEM tap's state transition (T16, E10). Before this,
    /// `captureCoordinator.onStateChange` was never wired at all — a `.failed`
    /// tap (TCC lost mid-session, the aggregate device torn out from under it, a
    /// bad ASBD read) stayed dead forever unless the user happened to toggle a
    /// Selected Device afterward (the only other path that re-invokes
    /// `reconcileCaptureGate`, and only because toggling changes `want`). Runs
    /// off `stateQueue` (callback context from
    /// `NativeCaptureCoordinator.onStateChange`, wired in `start()`); hops on
    /// only for the mutation, mirroring `handlePerAppCaptureHealthChange`.
    ///
    /// `.capturing` cancels any pending retry and resets the attempt counter —
    /// recovered. `.failed` schedules an indefinite capped-exponential-backoff
    /// retry (mirrors T8's `.processNotYetAudible` retry exactly) ONLY when BOTH:
    ///   - the error is retryable (`NativeCaptureError.isRetryable` — excludes
    ///     `.osUnsupported`, which no retry can ever fix), and
    ///   - capture is still actually desired (`captureRunning`, the gate's own
    ///     "should the tap be running" intent).
    /// The second guard has no per-app equivalent to reach for: a per-app
    /// capture's stray `.capturing` for a route nobody wants any more is caught
    /// CHEAPLY at that landing site (stopped as an orphan). But there is only
    /// ONE whole-system tap, and it is `.mutedWhenTapped` — blindly restarting
    /// it while `captureRunning` is false (nothing selected, or the user just
    /// deselected everything) would silence the Mac's speakers with the audio
    /// going nowhere, exactly the bug `reconcileCaptureGate`'s own doc comment
    /// describes. So the desired-ness check has to happen before EVER calling
    /// `start()` again, not after.
    func handleCaptureCoordinatorStateChange(_ state: NativeCaptureCoordinator.State) {
        switch state {
        case .capturing:
            stateQueue.sync {
                self.pendingCaptureRetry?.cancel()
                self.pendingCaptureRetry = nil
                self.captureRetryCount = 0
                if self.captureFailureNoteActive {
                    self.captureFailureNoteActive = false
                    self.emit(.captureFailed(message: nil, retrying: false))
                }
            }

        case .failed(let error):
            let (shouldRetry, attempt, noted): (Bool, Int, Bool) = stateQueue.sync {
                let running = self.captureRunning
                let retryable = error.isRetryable
                if running {
                    // The tap is dead while audio is still wanted: every selected
                    // speaker has gone silent behind a row that still reads
                    // "Connected", and no per-device state can say so. A failure
                    // while capture isn't desired is noise — nobody is listening.
                    self.captureFailureNoteActive = true
                    self.emit(.captureFailed(message: error.userMessage, retrying: retryable))
                }
                guard running, retryable else {
                    // Bookkeeping-hygiene fix (mirrors `handlePerAppCaptureHealthChange`):
                    // no retry is being scheduled from here — either capture
                    // isn't desired any more or this is a non-retryable failure
                    // — so a `pendingCaptureRetry` left over from an earlier
                    // attempt is now stale and must not linger as a dangling
                    // `DispatchWorkItem` reference.
                    self.pendingCaptureRetry?.cancel()
                    self.pendingCaptureRetry = nil
                    return (false, 0, running)
                }
                let attempt = self.captureRetryCount + 1
                self.captureRetryCount = attempt
                return (true, attempt, running)
            }
            // Only when capture was actually wanted — the same test the note
            // above uses. A failure with nothing selected is bookkeeping, not
            // a user hearing silence. `kind` is the bare case name; the raw
            // Core Audio `reason` string stays local.
            if noted {
                Telemetry.fail(.captureWS, "capture:whole_system_failed",
                               local: ["reason": String(describing: error)],
                               shared: [
                                   "kind": error.kind,
                                   "retrying": error.isRetryable ? "true" : "false",
                               ])
            }
            if shouldRetry {
                scheduleCaptureRetry(attempt: attempt)
            }

        case .idle, .creatingTap, .stopping:
            break
        }
    }

    /// Schedule the next whole-system-tap retry with capped-exponential backoff
    /// (T16, E10) — mirrors `scheduleProcessNotYetAudibleRetry`'s exact shape
    /// (`retryDelay × 2^(attempt-1)`, capped at `captureRetryMaxBackoff`, e.g.
    /// 2 → 4 → 8 → 10 → 10 … forever) and its single-flighting (replaces any
    /// retry already pending so N `.failed` events in a row never stack N
    /// timers, and a `stop()`/deselect can cancel it via `pendingCaptureRetry`).
    ///
    /// UNLIKE that retry — which is deliberately left unguarded on the route
    /// table because a resurrected/orphaned per-app capture is caught cheaply
    /// at its OWN `.capturing` landing site — this one RE-CHECKS
    /// `captureRunning` at FIRE time, right before calling `coordinator.start()`.
    /// There is only one whole-system tap, and it is `.mutedWhenTapped`: if
    /// capture was deselected during the backoff wait, blindly starting it here
    /// would mute the Mac's speakers with nowhere for the captured audio to go
    /// — the exact bug `reconcileCaptureGate` exists to prevent, and worse than
    /// an orphaned per-app tap (which only affects one app's exclusion
    /// bookkeeping, not the user's actual listening experience).
    /// `reconcileCaptureGate`'s own `coordinator.stop()` branch already cancels
    /// this timer proactively on a deselect, so this re-check is a defensive
    /// backstop against the (intentionally tolerated, D4-style) race where the
    /// timer is already past that check when the cancel lands.
    func scheduleCaptureRetry(attempt: Int) {
        let delay = min(
            captureRetryDelay * pow(2.0, Double(attempt - 1)),
            captureRetryMaxBackoff)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let stillWanted: Bool = self.stateQueue.sync { self.captureRunning }
            guard stillWanted, let coordinator = self.captureCoordinator else { return }
            self.captureControlQueue.async { coordinator.start() }
        }
        stateQueue.sync {
            self.pendingCaptureRetry?.cancel()
            self.pendingCaptureRetry = work
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + delay, execute: work)
    }

    /// Forward an app-quit notification from the AppKit boundary (T8, edge case 1:
    /// a routed app's process quits mid-stream; Bug 2: a `.currentDevice`-routed
    /// app's process quits mid-stream). `AppDelegate` observes
    /// `NSWorkspace.didTerminateApplicationNotification` and calls this with the
    /// terminated app's bundle ID — Core can't observe AppKit notifications itself,
    /// mirroring the `processResolver` injection.
    ///
    /// A no-op unless `bundleID` currently has an active `.device(id:)` route OR is
    /// routed `.currentDevice` (Bug 2 fix — was `.device`-only, which meant a
    /// "play on this Mac" app's per-app Core Audio tap was NEVER stopped on quit:
    /// `AppRoutingController.resetDeviceRoute` deliberately never touches
    /// `.currentDevice` — see its doc comment — so no route-table change ever
    /// re-drove `updateAppRoutes` for it either, leaving the tap registered against
    /// a dead pid in coreaudiod forever). Either way the PERSISTED route survives
    /// the quit (the silent-fallback-to-`.noRedirect` behavior is reserved for a
    /// lost DEVICE, not a quit app — the user may relaunch the app and expect its
    /// route/pick to still apply). The per-app capture is stopped, it's marked dead
    /// so the mixer topology drops it immediately (a no-op for a `.currentDevice`
    /// bundle — it was never in the mixer topology to begin with), and any pending
    /// `.processNotYetAudible` retry is cancelled (retrying a tap for a pid that no
    /// longer exists is pointless).
    public func handleAppTerminated(bundleID: String) {
        let wasCaptured: Bool = stateQueue.sync {
            self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
            self.retryCounts.removeValue(forKey: bundleID)
            return self.wantsPerAppCaptureLocked(bundleID)
        }
        guard wasCaptured else { return }
        perAppCapture.stop(bundleID: bundleID)
        let justDied: Bool = stateQueue.sync {
            // Bookkeeping-hygiene fix: the capture just stopped for real (a
            // quit, not a tap rebuild) — forget the "ever captured" bit so a
            // later relaunch's fresh `.capturing` (`handleAppLaunched`) is
            // recognised as a first capture, not a stale recapture. (In
            // practice `resetAirPlaySessionForRoutedApp` is ALSO a guaranteed
            // no-op for this exact call path today — `handleAppLaunched` calls
            // `perAppCapture.start` synchronously-to-completion BEFORE its own
            // `republishMixerTopology()` runs, so `routeMixer.streamIDs(for:)`
            // is still nil when `.capturing` lands — but this keeps the
            // invariant this field documents true regardless of that other
            // function's current implementation, and keeps it in sync with
            // `deadBundleIDs`/`retryCounts`/`pendingRetries`, all cleared at
            // this same capture-stop point.)
            self.everCapturedBundleIDs.remove(bundleID)
            return self.deadBundleIDs.insert(bundleID).inserted
        }
        if justDied { republishMixerTopology() }
        // Notify the UI that this routed app is no longer running so it can
        // show an offline indicator on the row (T4). The route itself persists
        // (PLAN §C) — only the live streaming state changes.
        stateQueue.async { self.emit(.routedAppRunning(bundleID: bundleID, isRunning: false)) }
    }

    /// React to an app-launch notification forwarded from the AppKit boundary
    /// (T4, bug fix: relaunching a routed app did not restart its capture; Bug 2:
    /// same fix extended to a relaunched `.currentDevice`-routed app). `AppDelegate`
    /// observes `NSWorkspace.didLaunchApplicationNotification` and calls this; Core
    /// can't observe AppKit notifications itself, mirroring the
    /// `handleAppTerminated` / `processResolver` injection pattern.
    ///
    /// Only acts when `bundleID` currently has an active `.device(id:)` route OR is
    /// routed `.currentDevice` (Bug 2 fix — was `.device`-only, so a "play on this
    /// Mac" app's capture never restarted after `handleAppTerminated` stopped it) —
    /// a non-routed, non-local app launch is silently ignored. On a match it:
    ///  - Clears any dead/retry tracking left over from a prior quit
    ///  - Restarts the per-app Core Audio capture tap (the previous one was
    ///    torn down by `handleAppTerminated` when the process exited)
    ///  - Republishes the mixer topology so `.routedApps` and the engine stream
    ///    binding reflect the restarted app (a no-op for a `.currentDevice`
    ///    bundle — see `resetAirPlaySessionForRoutedApp`'s doc comment; the
    ///    relaunched local player itself comes back through
    ///    `handleLocalCaptureStateChange`'s `.capturing` case once the capture
    ///    below reaches it, not through this republish)
    ///  - Emits `.routedAppRunning(bundleID:isRunning:true)` so the UI can
    ///    clear any offline indicator it had shown for this app
    public func handleAppLaunched(bundleID: String) {
        // R14: refresh the whole-system tap's exclusion pids for this bundle ID
        // unconditionally, BEFORE the routed-only early-return below — this is
        // what fixes an EXCLUDED (not routed) app relaunching and leaking back
        // into the system mix, since that case has no route to restart and
        // would otherwise hit `guard hasRoute else { return }` and never touch
        // capture at all. Also covers the ROUTED-app-relaunch half of R14
        // (avoids doubling into the system mix): a `.device`-routed bundle ID
        // is unioned into the same `currentExcludedBundleIDs` set inside
        // `NativeCaptureCoordinator`, so one call handles both cases. The
        // coordinator itself no-ops unless `bundleID` is actually in that set,
        // so this is cheap to call for every app launch, routed or not.
        captureCoordinator?.refreshExcludedProcessSet(forRelaunchedBundleID: bundleID)

        // `localBundleIDs` is ours (synced-local): an app routed to the Mac itself
        // still has a capture slot to revive on relaunch, so it takes this path too.
        let hasRoute: Bool = stateQueue.sync {
            guard self.wantsPerAppCaptureLocked(bundleID) else { return false }
            // Clear any dead/retry state from a prior quit (edge case 1 cleanup).
            self.deadBundleIDs.remove(bundleID)
            self.retryCounts.removeValue(forKey: bundleID)
            self.pendingRetries.removeValue(forKey: bundleID)?.cancel()
            return true
        }
        guard hasRoute else { return }
        // Restart the per-app capture tap for the relaunched process. This is
        // the same call `updateAppRoutes` issues for newly-routed apps; calling
        // it here means a relaunch self-heals without any route-table change.
        perAppCapture.start(bundleID: bundleID)
        // Republish the topology now that the bundle is no longer dead — the
        // mixer will include it in the next `.routedApps` and engine-bind pass.
        republishMixerTopology()
        // Tell the UI the app is live again so it can remove the offline badge.
        stateQueue.async { self.emit(.routedAppRunning(bundleID: bundleID, isRunning: true)) }
    }

    /// One per-app engine binding transition, computed under `stateQueue` and run on
    /// the `bindTail` FIFO. A device moving between streams is a plain stop→re-add
    /// (`.rebind`) — ahh has accepted the brief (~1 s) audible gap, so there is no
    /// gap-hiding machinery here on purpose.
    enum StreamBindOp {
        case bind(OutputID, UInt32)      // device newly bound to a per-app stream
        case rebind(OutputID, UInt32)    // device moved streams: stop, then re-add
        case unbind(OutputID)            // device left per-app routing: stop
    }

    /// React to a change in the mixer's destination-set topology (T6). Runs on the
    /// mixer's serial queue; hops to `stateQueue` for the whole diff so the binding
    /// state, the `.routedApps` diff, and the `bindTail` submission order are all
    /// serialized against every other `stateQueue` mutation.
    /// Max absolute Float32 sample across a captured buffer's first channel
    /// (diagnostic only; taps deliver Float32). ~0 while an app is audibly
    /// playing is the documented silent-buffer condition.
    static func diagFloatPeak(_ buffer: CapturedBuffer) -> String {
        guard let data = buffer.channelData.first, data.count >= 4 else { return "n/a" }
        var peak: Float = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float.self)
            for f in floats { let a = abs(f); if a > peak { peak = a } }
        }
        return String(format: "%.4f", peak)
    }

    /// Max absolute Int16 sample (0…32767) across interleaved S16LE PCM
    /// (diagnostic only) — what the AirPlay engine actually receives per stream.
    static func diagS16Peak(_ pcm: Data) -> Int {
        guard pcm.count >= 2 else { return 0 }
        var peak: Int16 = 0
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let ints = raw.bindMemory(to: Int16.self)
            for v in ints { let a = v == Int16.min ? Int16.max : abs(v); if a > peak { peak = a } }
        }
        return Int(peak)
    }

    /// How many mixed buffers between write-backlog samples. At ~44.1 kHz with
    /// typical buffer sizes this is a handful of seconds — frequent enough to
    /// catch a backlog trend, rare enough that neither the snapshot read (which
    /// takes the guard's own lock) nor a Telemetry write ever lands at buffer
    /// cadence on this RT-adjacent queue.
    static let backlogSampleInterval = 500

    /// Sample the engine's write-backpressure guard every `backlogSampleInterval`
    /// buffers and emit a Telemetry line ONLY when the cumulative dropped-write
    /// count actually moves. Counters are confined to the mixer's callback queue
    /// (this is the sole caller, and `onMixedBuffer` is serialized on that queue),
    /// so no additional lock is needed.
    ///
    /// `dropped > 0` is the definitive signal that audio is being discarded by
    /// backpressure rather than interrupted by a rebuild/reset — the distinction
    /// the routing telemetry cannot make. `maxInFlightSeconds` climbing toward the
    /// cap across samples means the engine thread is draining slower than capture
    /// produces (clock drift / a stalled receiver), which is the underlying
    /// condition the drop is merely the symptom of.
    func sampleWriteBacklogIfDue() {
        backlogSampleCounter &+= 1
        guard backlogSampleCounter % Self.backlogSampleInterval == 0 else { return }
        let snap = engine.writeBacklogSnapshot()
        guard snap.droppedWrites != lastReportedDroppedWrites else { return }
        let delta = snap.droppedWrites &- lastReportedDroppedWrites
        lastReportedDroppedWrites = snap.droppedWrites
        Telemetry.log(.airplay, "write_backlog_drop", [
            "droppedTotal": String(snap.droppedWrites),
            "droppedDelta": String(delta),
            "maxInFlightSeconds": String(format: "%.3f", snap.maxInFlightSeconds),
            "streamsTracked": String(snap.streamsTracked),
        ])
    }

    /// Sample the engine's write-CADENCE deficit/overrun counters
    /// (T-ENG-CADENCE-1, whole-system-dropout investigation) on the identical
    /// throttled/delta-gated shape as `sampleWriteBacklogIfDue()` above (own
    /// counter, own last-reported baseline, same `backlogSampleInterval` —
    /// reused rather than duplicated as a second constant, since the
    /// instruction behind this sampler is explicitly to reuse that cadence,
    /// not invent a new one). Emits a NEW event, `write_cadence_drift`, only
    /// when the cumulative deficit OR overrun has grown since the last sample
    /// — `writeCadenceSnapshot()` was previously referenced nowhere in
    /// `AudioutCore`, so this is the first time it is ever read outside the
    /// engine's own package.
    ///
    /// `writeCadenceSnapshot()` is engine-wide (fed by every `write` call —
    /// the whole-system streams AND per-app streams alike, see
    /// `AirPlayEngine.write(streams:pts:)`), but this sampler's own TRIGGER is
    /// the per-app mixer's buffer arrivals (`onMixedBuffer`, the only
    /// per-buffer-adjacent hook available inside `NativeBackend.swift` — the
    /// whole-system tap writes straight to `EngineSink` in
    /// `NativeCaptureCoordinator.swift`). So a session with no active
    /// `.device` route never fires THIS sampler — the same shape of blind
    /// spot `write_backlog_drop` had for the whole-system path before
    /// `9965bd9` closed it there. `EngineSink.write` (that file) now mirrors
    /// this exact sampler for the whole-system feed, tagged `path: "perApp"` here vs.
    /// `path: "wholeSystem"` there so the two call sites of the same event
    /// stay distinguishable — the discriminator `write_backlog_drop` itself
    /// never got, added here for both so they're symmetrical and greppable.
    func sampleWriteCadenceIfDue() {
        cadenceSampleCounter &+= 1
        guard cadenceSampleCounter % Self.backlogSampleInterval == 0 else { return }
        let snap = engine.writeCadenceSnapshot()
        guard snap.deficitSeconds != lastReportedCadenceDeficitSeconds
            || snap.overrunSeconds != lastReportedCadenceOverrunSeconds else { return }
        let deficitDelta = snap.deficitSeconds - lastReportedCadenceDeficitSeconds
        let overrunDelta = snap.overrunSeconds - lastReportedCadenceOverrunSeconds
        lastReportedCadenceDeficitSeconds = snap.deficitSeconds
        lastReportedCadenceOverrunSeconds = snap.overrunSeconds
        Telemetry.log(.airplay, "write_cadence_drift", [
            "path": "perApp",
            "writeCount": String(snap.writeCount),
            // THE drift number — deficit and overrun are one-sided sums that
            // both inflate under ordinary jitter; only their difference is real.
            "netDriftTotalSeconds": String(format: "%.3f", snap.netDriftSeconds),
            "netDriftDeltaSeconds": String(format: "%.3f", deficitDelta - overrunDelta),
            "deficitTotalSeconds": String(format: "%.3f", snap.deficitSeconds),
            "deficitDeltaSeconds": String(format: "%.3f", deficitDelta),
            "overrunTotalSeconds": String(format: "%.3f", snap.overrunSeconds),
            "overrunDeltaSeconds": String(format: "%.3f", overrunDelta),
            "lastGapSeconds": String(format: "%.4f", snap.lastGapSeconds),
            // Pauses, sleeps and tap rebuilds — kept out of the drift totals.
            "stalledTotalSeconds": String(format: "%.3f", snap.stalledSeconds),
            "stallCount": String(snap.stallCount),
            // How much of the deficit is the ENGINE's own drop site (writes the
            // backpressure guard refused) rather than a slow producer.
            "refusedWrites": String(snap.refusedWrites),
            "refusedTotalSeconds": String(format: "%.3f", snap.refusedSeconds),
        ])
    }

    func handleDestinationSetsChanged(_ sets: [AppRouteMixer.DestinationSet]) {
        stateQueue.sync {
            // Remember the topology so a LATER device discovery can re-drive this
            // binding pass for a target that wasn't discovered yet (see
            // `addOrUpdate`'s per-app re-drive).
            self.lastDestinationSets = sets
            // --- .routedApps diff (UI signal; independent of device discovery) ---
            var newAppNames: [String: [String]] = [:]
            for set in sets {
                let names = set.bundleIDs
                    .map { self.routeDisplayNames[$0] ?? $0 }
                    .sorted()
                for deviceID in set.deviceIDs { newAppNames[deviceID] = names }
            }
            for (deviceID, names) in newAppNames where self.routedAppNames[deviceID] != names {
                self.emit(.routedApps(deviceID: deviceID, appNames: names))
            }
            for deviceID in self.routedAppNames.keys where newAppNames[deviceID] == nil {
                self.emit(.routedApps(deviceID: deviceID, appNames: []))   // mapping cleared
            }
            self.routedAppNames = newAppNames

            // --- stream binding diff (engine ops; only for discovered devices) ---
            // `outputIDs[deviceID] != nil` is the guard that does the work here: it
            // is populated in exactly one place, the AirPlay discovery path, so it
            // structurally keeps Bluetooth and Cast ids out of this bind path
            // (neither kind's rows ever receive an entry — they're routed through
            // their own sink managers, never the engine) regardless of what the UI
            // hands down. It also defers, rather than drops, a target this backend
            // hasn't discovered YET: `addOrUpdate` re-drives this same binding pass
            // once the device shows up, so a route picked slightly ahead of
            // discovery still resolves once discovery catches up.
            var newBindings: [String: UInt32] = [:]
            for set in sets {
                let stream = UInt32(set.streamID)
                for deviceID in set.deviceIDs
                where self.outputIDs[deviceID] != nil {
                    newBindings[deviceID] = stream
                }
            }
            var ops: [StreamBindOp] = []
            for (deviceID, stream) in newBindings {
                let outputID = self.outputIDs[deviceID]!
                if let old = self.streamBindings[deviceID] {
                    if old != stream {
                        ops.append(.rebind(outputID, stream))
                        // Bookkeeping-hygiene fix: this topology-driven rebind
                        // supersedes any pending (explicit-reset) rebind-recovery
                        // retry for the SAME device, exactly like the `.unbind`
                        // loop below already does for a device leaving routing
                        // entirely — otherwise a stale backed-off recovery attempt
                        // can fire later against a device that has already moved
                        // on to a different stream.
                        self.rebindRecoveryGen.removeValue(forKey: deviceID)
                        self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
                    }
                } else {
                    ops.append(.bind(outputID, stream))
                }
            }
            var unboundDevices: [String] = []
            for (deviceID, _) in self.streamBindings where newBindings[deviceID] == nil {
                if let outputID = self.outputIDs[deviceID] { ops.append(.unbind(outputID)) }
                unboundDevices.append(deviceID)
                // T4: the device is leaving per-app routing — abandon any pending
                // rebind recovery for it. Bumping the gen also makes any in-flight
                // recovery chain bow out on completion (its captured gen no longer
                // matches), and the unbind op below tears the session down anyway.
                self.rebindRecoveryGen.removeValue(forKey: deviceID)
                self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
            }
            self.streamBindings = newBindings
            self.enqueueBindOps(ops)
            // The per-app domain just took (or gave back) stream ids, which is
            // exactly what the stream budget is computed from, and a device it
            // claimed or released changes whether its tone is reaching the audio.
            self.reconcileEQPlan()
            // T3: a device that just lost its per-app stream gets a final combined
            // `.level` (now with a zero stream contribution, so its meter drops to
            // its system contribution — 0 if unselected) so a torn-down stream can't
            // leave a stuck bar. Unconditional (not metering-gated): this is a
            // one-shot CLEAR, exactly what prevents a stale value surviving into a
            // reopened popover.
            for deviceID in unboundDevices { self.emitCombinedLevel(forDevice: deviceID) }
            // D4 (adversarial review): this is the sole `streamBindings` writer, and
            // the handoff watcher's `shouldRun` condition reads `streamBindings` —
            // without this, a per-app-only user (no whole-system selection) never
            // arms the watcher, and the watcher never stops when the last route
            // drops (`reconcileAggregateDefault`'s tail call is unreached with an
            // empty `expectedSelected`).
            self.reconcileHandoffWatcherLocked()

            // BT-BACKEND (R-partition): the per-app half of what the binding
            // loop above structurally skipped. A Bluetooth speaker a route names
            // is fed by UID through the sink manager, so the manager has to be
            // armed for it even with nothing selected whole-system — and armed
            // WITHOUT joining `btSelectedUIDs`, which is the only input the
            // room's timing has.
            //
            // razor: a per-app GROUP route spanning an AirPlay receiver and a BT
            // speaker will not agree — `airPlayPresent` is computed from the
            // whole-system selection alone, so the BT sink schedules against the
            // Mac's own clock while the receiver plays on its presentation
            // timeline. The upgrade is folding per-app AirPlay destinations into
            // `BTGroupComposition`; not taken because it re-anchors every BT
            // sink and the Mac's own sink for the sake of one app's route.
            let perAppBTUIDs = Set(sets.flatMap(\.deviceIDs))
                .filter { self.known[$0]?.isBluetooth == true }
                .sorted()
            if perAppBTUIDs != self.btPerAppClaimedUIDs {
                self.btPerAppClaimedUIDs = perAppBTUIDs
                let (armed, armedUIDs) = self.btArmingLocked()
                let composition = self.btComposition
                let gains = self.btSinkGains(forUIDs: armedUIDs)
                let eqs = self.btSinkEQs(forUIDs: armedUIDs)
                // The reference ALREADY IN FORCE, never a fresh derivation: a
                // per-app claim reads the room's timeline and must not move it.
                let referenceMs = self.btReferenceBufferMs
                let claimed = Set(perAppBTUIDs)
                self.captureControlQueue.async { [weak self] in
                    self?.applyBTSinkTransition(
                        enable: armed, uids: armedUIDs, composition: composition,
                        gains: gains, eqs: eqs, referenceBufferMs: referenceMs)
                    // What the whole-system fan-out must now skip, so a speaker
                    // this topology feeds never also hears the system mix.
                    self?.btSink?.setPerAppClaimedUIDs(claimed)
                }
            }
            self.rebuildBTPerAppFeedsLocked(sets)
        }
    }

    /// Rebuild the per-app Bluetooth delivery map from the current topology —
    /// one entry per stream that has at least one Bluetooth device on it, none
    /// for a stream that has none. The adapter and its resampler are built HERE,
    /// once per stream, never per buffer. On `stateQueue`.
    func rebuildBTPerAppFeedsLocked(_ sets: [AppRouteMixer.DestinationSet]) {   // on stateQueue
        let renderSampleRate = btSinkRefLock.withLock { btSink }?.renderSampleRate
            ?? Double(PCMFormat.airplay.sampleRate)
        var feeds: [Int: BTPerAppStreamFeed] = [:]
        for set in sets {
            let uids = set.deviceIDs.filter { known[$0]?.isBluetooth == true }.sorted()
            guard !uids.isEmpty else { continue }
            feeds[set.streamID] = BTPerAppStreamFeed(
                uids: uids,
                feedsEngine: set.deviceIDs.contains { outputIDs[$0] != nil },
                renderSampleRate: renderSampleRate,
                manager: { [weak self] in self?.btSinkRefLock.withLock { self?.btSink } })
        }
        btPerAppFeedsLock.withLock { btPerAppFeeds = feeds }
    }

    /// Chain `ops` onto the `bindTail` FIFO in the given order (on `stateQueue`).
    /// Each op awaits its predecessor, so per-app engine ops never overlap — a
    /// device's stop→re-add on a stream change always completes before any later
    /// change's op for the same device begins.
    func enqueueBindOps(_ ops: [StreamBindOp]) {   // on stateQueue
        guard !ops.isEmpty else { return }
        for op in ops {
            let prev = self.bindTail
            self.bindTail = Task { [weak self] in
                await prev.value
                await self?.performBindOp(op)
            }
        }
    }

    /// Execute one per-app binding op against the engine. Best-effort (D4): a failed
    /// op is NOT silently retried here — the binding is idempotently re-established on
    /// the next topology change — but a bind/rebind failure is no longer swallowed
    /// blind: `handleBindFailure` walks the `.routedApps` claim back to empty so the
    /// UI stops asserting a stream that never actually established (dot-truthfulness
    /// fix; deliberately does NOT touch `Device.connectionState` — out of scope here).
    /// The engine's `addOutput(_:streamId:)` binds the device's session to the given
    /// master stream (T2).
    func performBindOp(_ op: StreamBindOp) async {
        switch op {
        case .bind(let outputID, let stream):
            // The same T5+T4 takeover gate `convergeDevice` runs — a per-app
            // stream is a real AirPlay session and is just as silent without a
            // clock (the ROOT of the redirect-order bug: redirect-first binds
            // used to skip this entirely). `clearBinding` on failure is what
            // lets the clock-recovery replay / discovery re-drive re-issue
            // this op without a topology change.
            guard await ensurePTPTakeover(telemetryDeviceID: deviceID(for: outputID) ?? "\(outputID)") else {
                handleBindFailure(
                    outputID: outputID, stream: stream, op: "bind",
                    error: PTPClockUnavailableError(), clearBinding: true)
                return
            }
            // Roadmap 008 fire-time gate — AFTER the PTP wait (the widest window
            // in the file; a gate before it would re-open the whole window it
            // exists to close), immediately before the engine call.
            guard perAppOpMayFire(outputID: outputID, op: "bind", stream: stream) else { return }
            Telemetry.log(.airplay, "engine_bind", ["output": "\(outputID)", "stream": "\(stream)"])
            do {
                try await bindOutput(outputID, toStream: stream)
            } catch {
                handleBindFailure(outputID: outputID, stream: stream, op: "bind", error: error)
            }
        case .rebind(let outputID, let stream):
            guard await ensurePTPTakeover(telemetryDeviceID: deviceID(for: outputID) ?? "\(outputID)") else {
                handleBindFailure(
                    outputID: outputID, stream: stream, op: "rebind",
                    error: PTPClockUnavailableError(), clearBinding: true)
                return
            }
            guard perAppOpMayFire(outputID: outputID, op: "rebind", stream: stream) else { return }
            Telemetry.log(.airplay, "engine_rebind", ["output": "\(outputID)", "stream": "\(stream)"])
            do {
                try await bindOutput(outputID, toStream: stream, tearDownWhenBindingUnknown: true)
            } catch {
                handleBindFailure(outputID: outputID, stream: stream, op: "rebind", error: error)
            }
        case .unbind(let outputID):
            // Roadmap 008 four-case unbind arm (mechanism 2). A blanket
            // removeOutput under a whole-system claim is the I4 bug (it kills the
            // whole-system session the user just asked for, while `added` still
            // claims it); a blanket SKIP has two provable failure modes of its
            // own (a stranded astray session after the engine's silent
            // `.alreadyBound` no-op, and a zombie per-app session leaked when the
            // converge parked). Classification runs under `stateQueue`:
            //   1. no operational claim            → removeOutput (today's op);
            //   2. `desiredOn`-only claim (parked) → removeOutput (today's op —
            //      correct teardown of the per-app session; whole-system re-adds
            //      fresh via retry/re-toggle);
            //   3. a converge op is in flight      → defer (`pendingScopeSettles`;
            //      the release side re-drives this exact op);
            //   4. settled whole-system session    → claim the `converging` slot
            //      Finding-1 style and enqueue a VERIFY-FIRST whole-system
            //      recovery: read engine truth after the racing op completed,
            //      rebind an astray session onto the device's home stream, zero
            //      engine ops when it is already there.
            enum UnbindAction { case remove, deferred, settled }
            let action: UnbindAction = stateQueue.sync {
                guard let id = self.outputIDs.first(where: { $0.value == outputID })?.key else {
                    return .remove   // vanished device: proceed as today (engine tolerates)
                }
                if self.converging.contains(id) {
                    Telemetry.log(.airplay, "unbind_deferred", ["device": id])
                    self.pendingScopeSettles.insert(id)
                    return .deferred
                }
                if self.added.contains(id) {
                    // Case 4 — this IS `resetAirPlaySessionForWholeSystem`'s own
                    // claim shape, reused: slot + gen bump + the shared recovery
                    // chain (its backoff / terminal-exit / slot-release
                    // discipline applies unchanged), with the verify-first
                    // flavor instead of a teardown.
                    self.converging.insert(id)
                    self.rebindConverging.insert(id)
                    let gen = (self.rebindRecoveryGen[id] ?? 0) + 1
                    self.rebindRecoveryGen[id] = gen
                    self.pendingRebindRecoveries.removeValue(forKey: id)?.cancel()
                    Telemetry.log(.airplay, "unbind_downgraded", ["device": id, "settled": "pending"])
                    self.emit(.streamHealth(id: id, recovering: true))
                    self.enqueueRebindRecovery(
                        deviceID: id, outputID: outputID, scope: .wholeSystem,
                        gen: gen, attempt: 1, verifyFirst: true)
                    return .settled
                }
                return .remove   // cases 1 and 2 — byte-identical to today
            }
            guard case .remove = action else { return }
            Telemetry.log(.airplay, "engine_unbind", ["output": "\(outputID)"])
            try? await engine.removeOutput(outputID)
        }
    }

    /// Roadmap 008 fire-time gate for `.bind`/`.rebind`: re-check the whole-system
    /// claim under `stateQueue` immediately before the engine call and BOW OUT
    /// loudly if whole-system operationally owns the device — under a claim,
    /// per-app ops only ever bow out (never move a session), which is what makes
    /// the trailing `.unbind`/settle the deterministic last word. Clearing
    /// `streamBindings` is what lets the re-drives re-issue the op later (the
    /// `handleBindFailure(clearBinding: true)` precedent: both replay paths key on
    /// `streamBindings[id] == nil`). A vanished device (no reverse entry) proceeds
    /// as today. Deliberately NO topology-supersession check here, so the
    /// per-app-only op trace stays byte-identical (within-FIFO ordering already
    /// handles supersession).
    func perAppOpMayFire(outputID: OutputID, op: String, stream: UInt32) -> Bool {
        stateQueue.sync {
            guard let id = self.outputIDs.first(where: { $0.value == outputID })?.key else { return true }
            guard self.isWholeSystemOperationallyClaimedLocked(id) else { return true }
            let reason = self.converging.contains(id) ? "ws_in_flight" : "ws_claimed"
            Telemetry.log(.airplay, "bind_superseded", [
                "device": id, "op": op, "stream": "\(stream)", "reason": reason,
            ])
            self.streamBindings.removeValue(forKey: id)
            return false
        }
    }

    /// The `Device.id` currently mapped to `outputID`, if any (reverse lookup
    /// of `outputIDs`). Takes `stateQueue` itself — call only off it.
    func deviceID(for outputID: OutputID) -> String? {
        stateQueue.sync { self.outputIDs.first(where: { $0.value == outputID })?.key }
    }

    /// A per-app bind was refused because no PTP clock is available (the T4
    /// gate said not-ready). Distinct from an engine throw only so telemetry
    /// reads the actual cause.
    struct PTPClockUnavailableError: Error, CustomStringConvertible {
        var description: String { "timingUnavailable" }
    }

    /// THE single call site that puts a device's engine session onto a stream —
    /// shared by the whole-system converge (`convergeDevice`, the device's own
    /// home stream, serialized by `converging`) and the per-app binding pass
    /// (`performBindOp`, stream ≥ 1, serialized by `bindTail`). T7 / architecture
    /// review defect B.
    ///
    /// Those two Swift-side FIFOs are separate and neither knows the other exists,
    /// so a device changing SCOPE — whole-system → per-app, or per-app →
    /// whole-system — crosses the seam between them. The old failure was silent:
    /// `addOutput` no-ops on an already-live session rather than moving it, so the
    /// device kept streaming its old stream while Swift bookkeeping recorded the
    /// new one and audio was written where the device had never joined. `added`
    /// and `streamBindings` never cross-invalidate, so nothing noticed.
    ///
    /// The fix arbitrates on the ENGINE's own answer instead of on either FIFO's
    /// bookkeeping: ask which stream the live session is really on, and if that is
    /// not the stream we want, move it with `rebindOutput` — one op that holds the
    /// engine's per-`OutputID` `opsInFlight` slot across both the stop and the
    /// re-add. That makes the transition atomic from the engine's perspective with
    /// NO new Swift-level lock (a second lock spanning `converging` and `bindTail`
    /// would be a deadlock surface for no extra safety; the engine's per-output
    /// slot is already the one place both paths necessarily meet).
    ///
    /// A live session already on `streamId` needs no engine call at all — that is
    /// the redundant-op window closed rather than merely narrowed.
    ///
    /// `tearDownWhenBindingUnknown` covers the one case the query can't answer: a
    /// `.rebind` against an engine that reports no live binding (or a conformer
    /// that predates the query). Then we keep the historical unconditional
    /// stop-then-re-add, whose tolerated `removeOutput` throw is fine because the
    /// device may simply not be added.
    ///
    /// The accepted ~1 s audible gap on a real move is deliberately kept — there
    /// is no crossfade/pre-buffer machinery here, by decision.
    func bindOutput(
        _ outputID: OutputID, toStream streamId: UInt32, tearDownWhenBindingUnknown: Bool = false
    ) async throws {
        if let live = await engine.boundStreamId(for: outputID) {
            guard live != streamId else { return }   // engine already owns the stream we want
            Telemetry.log(.airplay, "engine_scope_rebind", [
                "output": "\(outputID)", "from": "\(live)", "to": "\(streamId)",
            ])
            try await engine.rebindOutput(outputID, toStreamId: streamId)
            return
        }
        if tearDownWhenBindingUnknown { try? await engine.removeOutput(outputID) }
        // Stream 0 keeps using the legacy single-stream entry point — it is the
        // flat stream, and the only one a whole-system device lands on when the
        // engine had no stream left for it. Every other id (per-app from 1 up,
        // whole-system homes in the top half) goes through the stream seam (see
        // `EngineControlling.write(pcm:streamId:pts:)`).
        if streamId == 0 {
            try await engine.addOutput(outputID)
        } else {
            try await engine.addOutput(outputID, streamId: streamId)
        }
    }

    /// A per-app bind/rebind that never actually established an AirPlay session must
    /// not leave the device claiming it streams one — `handleDestinationSetsChanged`
    /// already emitted `.routedApps` with the intended app names purely from mixer
    /// TOPOLOGY, ahead of (and independent of) whether the engine op below it would
    /// succeed. Mirrors exactly the "device just lost its stream" clear that function
    /// emits (`.routedApps(deviceID:, appNames: [])`, then drops the device from
    /// `routedAppNames` so a later successful topology change is free to re-publish it
    /// from scratch) — so a genuinely failed session falls back to the same
    /// truthful, intent-only rendering instead of the teal dot + sublabel lying about
    /// audio that never flowed. Runs on `stateQueue` to serialize against the same
    /// `.routedApps` bookkeeping `handleDestinationSetsChanged` mutates.
    /// `clearBinding` additionally drops the device's recorded `streamBindings`
    /// slot — used ONLY for the PTP-gate refusal, where no engine op ran at
    /// all: clearing it makes the device eligible for the clock-recovery
    /// replay and `addOrUpdate`'s discovery re-drive (both key on
    /// `streamBindings[id] == nil`). An engine-op failure keeps the slot
    /// (default `false`), preserving the existing "next topology change
    /// re-binds idempotently" best-effort semantics.
    func handleBindFailure(
        outputID: OutputID, stream: UInt32, op: String, error: Error, clearBinding: Bool = false
    ) {
        stateQueue.sync {
            guard let deviceID = self.outputIDs.first(where: { $0.value == outputID })?.key else { return }
            Telemetry.log(.airplay, "bind_failed", [
                "device": deviceID, "op": op, "stream": "\(stream)", "error": "\(error)",
            ])
            if clearBinding { self.streamBindings.removeValue(forKey: deviceID) }
            guard self.routedAppNames[deviceID] != nil else { return }
            self.routedAppNames.removeValue(forKey: deviceID)
            self.emit(.routedApps(deviceID: deviceID, appNames: []))
        }
    }

}
