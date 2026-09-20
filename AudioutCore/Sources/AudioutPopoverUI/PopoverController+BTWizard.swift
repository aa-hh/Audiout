// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

extension PopoverController {

    // MARK: First-join alignment note + wizard (W3/W4)

    /// A never-aligned BT device just joined its first mix and is playing
    /// as-is (`BackendEvent.btFirstMixAlignmentPrompt`): remember the offer and
    /// mount a note under its row. No queue — every offered speaker gets its
    /// own note, and several may stand at once.
    public func offerBTAlignment(deviceID: String) {
        guard btAlignmentOfferedIDs.insert(deviceID).inserted else { return }
        reconcileBTAlignmentNotes(animated: true)
    }

    /// Whether the wizard/note target still makes sense to align: present,
    /// powered on, and part of the user's audio intent. A power-off keeps the
    /// row (greyed) but drops the sink — a wizard asking "which side?" over a
    /// silent target must die with the availability, not with the row.
    private func btAlignmentTargetIsLive(_ id: String) -> Bool {
        devicesByID[id]?.isAvailable == true && wantsAudio(id)
    }

    /// Mount/unmount the notes and the wizard sheet to match the intent state
    /// — the `reconcileDiagnosisPanels` idiom, called from the same rebuild
    /// sites. A missing row (device gone / filtered) keeps the offer parked
    /// until the row returns; a measured speaker drops its offer for good.
    func reconcileBTAlignmentNotes(animated: Bool) {
        // Wizard first: a torn-down wizard may free its target for a note in
        // this same pass.
        reconcileBTWizardLiveness()
        // A measured speaker has nothing left to offer — drop the intent, not
        // just the view, so a later re-offer for the same id cannot revive it.
        btAlignmentOfferedIDs.subtract(
            btAlignmentOfferedIDs.filter { btMeasuredLatency(for: $0) != nil })
        for (id, view) in btAlignmentNoteViews where !btAlignmentNoteShouldStand(id) {
            btAlignmentNoteViews.removeValue(forKey: id)
            panel.removeRow(view, animated: animated)
        }
        for id in btAlignmentOfferedIDs.sorted()
        where btAlignmentNoteViews[id] == nil && btAlignmentNoteShouldStand(id) {
            guard let row = deviceRowsByID[id], let device = devicesByID[id] else { continue }
            let view = BTAlignmentNoteView(deviceName: device.name)
            view.onAlign = { [weak self] in
                self?.startBTAlignmentWizard(deviceID: id, door: .note)
            }
            view.onHide = { [weak self] in self?.hideBTAlignmentNote(id) }
            btAlignmentNoteViews[id] = view
            panel.insertRow(view, after: row, animated: animated)
        }
        // Wizard sheet (its liveness ran first, above). It needs no row: the
        // wizard rides the surface as a SHEET, so a filtered or collapsed-away
        // row can no longer strand a live run — and the host can't close
        // under it either (AppKit refuses `performClose` while a sheet is
        // attached; the shell's R7 and the menu-bar click policy both already
        // honour `hasAttachedSheet`).
        if let id = btWizardDeviceID, let session = btWizardSession,
           btWizardSheet == nil, devicesByID[id] != nil {
            let view = BTAlignmentWizardView(session: session)
            view.onFinished = { [weak self] in self?.finishBTWizard() }
            view.onSetByHand = { [weak self] bestGuessMs in
                self?.btWizardSetByHand(deviceID: id, bestGuessValueMs: bestGuessMs)
            }
            view.onSelectReference = { [weak self] referenceID in
                self?.setBTWizardReference(referenceID)
            }
            // Before the mount, so the sheet measures the finished layout.
            view.referenceOptions = btWizardReferenceOptions(excluding: id)
            view.remoteInvite = remoteInviteState()
            let sheet = AlignmentWizardViewController(wizardView: view)
            view.onContentSizeChange = { [weak sheet] in sheet?.fitToContent() }
            btWizardView = view
            btWizardSheet = sheet
            sheet.fitToContent()
            // The Mixer create-sheet gate: an on-screen host means a real
            // sheet parent; headless runs (host never shown) keep the
            // reference and drive the view through the test hooks instead.
            if let host = panel.viewIfLoaded?.window, host.isVisible {
                panel.presentAsSheet(sheet)
                // No event where no invitation was drawn: a build without the
                // phone app shows no iPhone panel, so "the sheet showed an
                // invitation" never happened.
                if let state = Self.remoteInviteAnalyticsState(view.remoteInvite) {
                    Analytics.capture("remote_invite:sheet_shown", ["state": state])
                }
            }
        }
    }

    /// The wizard's target check and its picker refresh — the two things that
    /// must run whether or not the popover is on screen. An app-switch
    /// tuck-away hides the surface (sheet and all) without closing it, so a
    /// dead target has to reach the hidden run anyway, and the reference
    /// picker has to keep up with devices coming and going.
    func reconcileBTWizardLiveness() {
        if let id = btWizardDeviceID, !btAlignmentTargetIsLive(id) {
            tearDownBTWizard(targetLost: true)
        }
        if let id = btWizardDeviceID, btWizardSession != nil, let view = btWizardView {
            view.referenceOptions = btWizardReferenceOptions(excluding: id)
            view.remoteInvite = remoteInviteState()
        }
    }

    private func remoteInviteState() -> BTAlignmentWizardView.RemoteInviteState {
        remoteInviteStateProvider?() ?? .notConnected
    }

    /// `remote_invite:sheet_shown`'s `state` property, per the vocabulary doc's
    /// three allowed values — `nil` where there was no invitation to report,
    /// which keeps that list of three intact rather than adding a fourth value
    /// for an event that should simply not fire.
    private static func remoteInviteAnalyticsState(
        _ state: BTAlignmentWizardView.RemoteInviteState
    ) -> String? {
        switch state {
        case .unavailable: return nil
        case .allowOff: return "allow_off"
        case .notConnected: return "qr"
        case .connected: return "connected"
        }
    }

    /// Repaint the wizard's iPhone panel — the app layer calls this when a
    /// phone connects or leaves, or the Allow switch moves.
    public func refreshRemoteInviteState() {
        btWizardView?.remoteInvite = remoteInviteState()
    }

    /// A phone-driven measurement just started on this speaker. If the by-ear
    /// sheet is open on the same one, it closes: the Mac runs one alignment at
    /// a time, and the page's whole job was to get the phone to take over.
    public func noteCompanionAlignmentRunStarted(deviceID: String) {
        guard btWizardDeviceID == deviceID else { return }
        finishBTWizard()
    }

    /// Whether this device's note belongs on screen: it was offered, the user
    /// has not hidden it, the row is a Bluetooth speaker (never Cast), the
    /// target is still live, and nothing has been measured for it yet.
    private func btAlignmentNoteShouldStand(_ id: String) -> Bool {
        guard !btAlignmentNoteHiddenIDs.contains(id),
              btAlignmentOfferedIDs.contains(id),
              let device = devicesByID[id],
              device.isBluetooth, !device.isCast else { return false }
        return btAlignmentTargetIsLive(id) && btMeasuredLatency(for: id) == nil
    }

    /// The note's ✕: session-only. The backend offers again on the next
    /// launch while the speaker stays unmeasured; nothing is written down.
    private func hideBTAlignmentNote(_ id: String) {
        Analytics.capture("bt_sync:note_hidden")
        btAlignmentNoteHiddenIDs.insert(id)
        reconcileBTAlignmentNotes(animated: true)
    }

    /// Open the wizard for `deviceID` through one of its four doors — the
    /// untuned row chip, the first-join note, the drawer's "Align again…", or
    /// the row's "Align by ear…" menu item. Builds the session over the row's
    /// freshest trim and mounts the sheet. Refused only for a target that is
    /// GONE (unpaired, powered off) — a speaker that is merely out of the mix
    /// is put into it, see below.
    func startBTAlignmentWizard(deviceID: String, door: BTAlignmentWizardDoor) {
        guard let device = devicesByID[deviceID], device.isAvailable else { return }
        // A Cast receiver has no run to give: it plays seconds behind live, and
        // no ±500 ms bisection converges on that. Its row's own doors are
        // absent (`DeviceRowView.supportsAlignmentWizard`).
        guard !device.isCast else { return }
        tearDownBTWizard()
        // The run measures a speaker that is PLAYING, so a target outside the
        // mix has to join before it can be aligned — and clicking Align is
        // that join, not a refusal. It goes through the ONE selection owner
        // the row's own checkbox uses, so the mix, the backend and the rail
        // all follow, and a refused join speaks through `handleSelection`
        // rather than leaving a door that does nothing silently. Unlike the
        // run's REFERENCE — borrowed by `engageBTWizardReference` and handed
        // back on teardown — the target STAYS: the user asked for this speaker
        // by name. Ordered after `tearDownBTWizard()`, which may itself be
        // releasing this same device as the previous run's reference.
        if !wantsAudio(deviceID) {
            let result = groupController?.setDeviceSelected(deviceID, true) ?? .ok
            handleSelection(result, deviceID: deviceID)
            guard result.applied else { return }
        }
        let isLocalTarget = device.isLocalDevice
        // The Mac's run still measures its own sync OFFSET; a Bluetooth run now
        // measures the speaker's LATENCY (roadmap 056 Part A) and leaves the
        // user's trim alone on top of it.
        let base = isLocalTarget
            ? (btTrimsByID[deviceID] ?? localTrimProvider?() ?? 0)
            : (btMeasuredLatency(for: deviceID) ?? 0)
        let candidateRange = isLocalTarget
            ? -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs
            : (btLatencyRangeProvider?(deviceID) ?? -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)
        // SUSPEND the target's trim for the whole run. Latency and trim are the
        // same linear term in the delay (`reference − latency + trim`), so with
        // the nudge still applied alignment is reached at `trueLatency + trim`
        // and that is what gets stored and shown as "Measured latency" — and a
        // trim more negative than the hardware latency collapses the candidate
        // range onto 0 and bows the run out as `.unreachable` before it starts.
        // The latency preview path is untouched; only the trim steps aside.
        if !isLocalTarget {
            btWizardSuspendedTrimDeviceID = deviceID
            onBTWizardTrimPreview?(0, deviceID)
        }
        // The single tick source: a running manual metronome would fight the
        // wizard's own run.
        setAlignTick(nil)
        // The offer is NOT dropped here. A run stopped before it measures
        // anything leaves the speaker exactly as unaligned as the note said it
        // was, so the invitation has to survive it (decision 3 — the note
        // stands until the speaker is measured). `reconcileBTAlignmentNotes`
        // drops it on the measurement, which is the only thing that ends it.
        // Zero-click: a speaker that has been measured before opens straight on
        // the PROPOSAL at its stored value — "still right?" is one click where
        // a fresh run is a dozen. The prior behind it stays flat; this is a UI
        // shortcut, not a statistical one. Never for the Mac's own row, whose
        // trim is the user's setting rather than a measurement.
        let openingProposal: Double? =
            (!isLocalTarget && btMeasuredLatency(for: deviceID) != nil) ? base : nil
        let reference = btWizardDefaultReference(excluding: deviceID)
        if let reference { engageBTWizardReference(reference.id) }
        let session = BTAlignmentWizardSession(
            deviceID: deviceID,
            targetName: device.name,
            // The transport of each side, which is what decides whether the two
            // speakers make different SOUNDS this run (the tick's two timbres
            // are split by fan-out, never by role) and so whether the intro
            // names them.
            reference: reference.map {
                .init(id: $0.id, name: $0.name, isBluetooth: $0.isBluetooth)
            },
            targetIsBluetooth: device.isBluetooth,
            baseValueMs: base,
            candidateRangeMs: candidateRange,
            // A larger latency feeds the speaker EARLIER, so an early target
            // needs LESS of it — the mirror of a trim.
            invertsEstimate: !isLocalTarget,
            openingProposalMs: openingProposal,
            // A LOCAL target previews through the Mac's own seam; everything
            // else through the Bluetooth one. Same contract either way: never
            // persisted mid-run, restored or committed on the way out. The
            // local seam takes no half-width — its telemetry is the Mac's, and
            // this run is not what it is about.
            applyPreviewTrim: { [weak self] ms, halfWidthMs in
                self?.btWizardPreviewGeneration += 1
                self?.btWizardLastPreviewMs = ms
                if isLocalTarget {
                    self?.onLocalTrimPreview?(ms)
                } else {
                    self?.onBTWizardLatencyPreview?(ms, deviceID, halfWidthMs)
                }
            },
            endPreview: { [weak self] keepMs in
                if isLocalTarget {
                    self?.onLocalTrimEndPreview?(keepMs)
                } else {
                    self?.onBTWizardEndLatencyPreview?(deviceID, keepMs)
                }
                if let keepMs {
                    // Keep the row's display in step with the persisted result
                    // (freshest-write-wins cache, same as a manual edit). The
                    // Mac's run writes its trim; a Bluetooth run writes the
                    // measured latency and leaves the trim untouched.
                    if isLocalTarget {
                        self?.btTrimsByID[deviceID] = keepMs
                    } else {
                        self?.btLatenciesByID[deviceID] = keepMs
                        // Keep zeroes the trim too (the backend writes both), so
                        // the row's caches have to agree with the store rather
                        // than repaint the pre-run nudge.
                        self?.btTrimsByID[deviceID] = 0
                        self?.btTunedDeviceIDs.insert(deviceID)
                    }
                    // The drawer this run was very likely launched FROM is
                    // still open under the row, holding the pre-run value —
                    // and one gesture (a stepper, or the value field
                    // committing what it shows as focus leaves) writes it back
                    // over what was just measured.
                    self?.noteWizardTrimIntoOpenDrawer(
                        deviceID: deviceID, trimMs: isLocalTarget ? keepMs : 0)
                    // The panel STAYS UP on the kept screen, so the row's chip
                    // has to flip while the user is still looking at it — the
                    // live complaint was a run that "didn't update the value
                    // anywhere" because the repaint waited for the dismissal.
                    self?.refreshDeviceRows()
                    // The kept screen's own peak-end order, spoken: the ready
                    // line first, the measurement after it. VoiceOver used to
                    // hear only the number — the housekeeping — while the
                    // screen printed the win. Reuses the PRINTED string so the
                    // two can never drift.
                    self?.postAnnouncement(
                        BTAlignmentWizardView.keptReadyCopy(target: device.name)
                        + " Aligned at \(Int(keepMs.rounded())) milliseconds.")
                }
            },
            setTick: { [weak self] active in
                self?.pushBTWizardTick(active, target: isLocalTarget ? nil : deviceID)
                // The probe is staged only from the session's `requestListening`
                // callback (Start, and a measured proposal's reject that listens
                // again), never from here. The tick's `false` edge still drops a
                // running probe.
                if !active {
                    self?.btWizardMicProbe?.cancel()
                    self?.btWizardMicProbe = nil
                }
            },
            setTempo: { [weak self] bpm in self?.onBTWizardTempo?(bpm) })
        btWizardDeviceID = deviceID
        // Start asks for the mic before the run begins, and the session shows
        // the listening screen only on a grant. `proceed` switches the tick on
        // synchronously, so the probe is staged AFTER it — the sweeps need the
        // wizard feed already running. A real (undecided) ask goes quiet like
        // Setup's prompt and is brought back on the answer only while this run
        // is still the live one.
        if onStageBTMicProbe != nil {
            session.requestListening = { [weak self, weak session] proceed in
                guard let self else { return proceed(false) }
                let prompted = self.micPermissionIsUndecided()
                if prompted { self.onMicPromptInFlightChanged?(true) }
                self.ensureMicPermission { [weak self, weak session] granted in
                    if prompted { self?.onMicPromptInFlightChanged?(false) }
                    proceed(granted)
                    guard let self, let session,
                          self.btWizardSession === session else { return }
                    if prompted { self.onMicPromptAnswered?() }
                    guard granted else { return }
                    self.startBTWizardMicProbe(deviceID: deviceID)
                }
            }
        }
        btWizardSession = session
        Analytics.capture("bt_sync:wizard_started",
                          ["target": isLocalTarget ? "local" : "bluetooth",
                           "door": door.rawValue])
        reconcileBTAlignmentNotes(animated: true)
        refreshDeviceRows()
    }

    /// Run one mic-probe measurement under the wizard run just started
    /// (roadmap 064): the wizard feed plays the dual sweeps in place of the
    /// first ticks, the built-in mic records them, and the resulting Δ —
    /// corrected onto the preview in force when the sweeps started — arrives
    /// as the run's proposal to confirm by ear. A failure is not silent any
    /// more: the listening screen is on the user's screen, so every path that
    /// does not reach a proposal ends the listen and the questions begin.
    ///
    /// The Δ→proposal arithmetic is the same for both run kinds because Δ is
    /// LANE-anchored (Bluetooth-lane arrival minus engine-lane arrival): a
    /// positive Δ means the Bluetooth side is late, which a Bluetooth target
    /// fixes with MORE latency (fed earlier) and a Mac target fixes with MORE
    /// trim (held later) — in both value spaces, `applied + Δ`.
    private func startBTWizardMicProbe(deviceID: String) {
        btWizardMicProbe?.cancel()
        btWizardMicProbe = nil
        guard let stageProbe = onStageBTMicProbe,
              let session = btWizardSession,
              // One sweep per fan-out: a pair on the SAME fan-out (BT against
              // BT, or the Mac against AirPlay) would carry both sweeps to
              // both speakers and the arrivals would be unattributable.
              session.pairSoundsDiffer,
              btWizardDeviceID == deviceID, btWizardMicProbe == nil else { return }
        var generationAtSweep = -1
        var appliedMsAtSweep = 0.0
        let probe = makeMicProbe()
        btWizardMicProbe = probe
        probe.start(stage: { onStarted, onFinished in
            stageProbe({
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    generationAtSweep = self.btWizardPreviewGeneration
                    appliedMsAtSweep = self.btWizardLastPreviewMs
                    // Marking the ambient boundary a hop late is safe: air
                    // always lags the feed, never leads it.
                    onStarted()
                }
            }, onFinished)
        }, completion: { [weak self] result in
            guard let self, self.btWizardDeviceID == deviceID,
                  self.btWizardMicProbe === probe else { return }
            self.btWizardMicProbe = nil
            guard let result, generationAtSweep >= 0,
                  generationAtSweep == self.btWizardPreviewGeneration else {
                self.btWizardSession?.endListening()
                return
            }
            self.btWizardSession?.offerMeasuredProposal(
                valueMs: appliedMsAtSweep + result.deltaMs)
        })
    }

    /// Hand the wizard's committed trim to this device's OPEN sync drawer.
    /// Nothing else does: the drawer's own refresh path (`pushSyncDrawerState`)
    /// is a background model push, which by contract leaves an in-progress edit
    /// alone — and the value the run wrote is not a background change.
    private func noteWizardTrimIntoOpenDrawer(deviceID: String, trimMs: Double) {
        guard mountedSyncDrawerID == deviceID else { return }
        syncDrawer.noteExternalTrimChange(trimMs)
    }

    /// The unsettled screen's "Set it by hand": close the run and hand its best
    /// guess to the row's SYNC drawer, focused but NOT committed — the drawer
    /// emits committed gestures only, and a number nobody has agreed to is not
    /// one.
    ///
    /// The run measured a LATENCY; the drawer edits a TRIM. Their sum is what
    /// aligns the speaker, so the suggestion is the guess MINUS whatever
    /// latency is already stored — offering the raw guess would double the
    /// correction the moment the user pressed Return.
    private func btWizardSetByHand(deviceID: String, bestGuessValueMs: Double) {
        let measuresLatency = btWizardSession?.measuresLatency ?? false
        finishBTWizard()
        if expandedSyncDeviceID != deviceID {
            toggleSyncDrawer(deviceID: deviceID, animated: true)
        }
        guard mountedSyncDrawerID == deviceID else { return }
        let suggested = measuresLatency
            ? bestGuessValueMs - (btMeasuredLatency(for: deviceID) ?? 0)
            : bestGuessValueMs
        let usable = btUsableTrimRange(for: deviceID)
        syncDrawer.beginEditingSuggestedValue(
            Swift.min(Swift.max(suggested, usable.lowerBound), usable.upperBound))
    }

    /// Every other speaker the target could be compared against, in the order
    /// the rows themselves render (locals, AirPlay, Bluetooth). Unavailable
    /// devices are left out — a greyed row can't carry a tick.
    private func btWizardReferenceOptions(excluding deviceID: String)
        -> [BTAlignmentWizardView.ReferenceOption]
    {
        btWizardReferenceDevices(excluding: deviceID)
            .map { .init(id: $0.id, name: $0.name) }
    }

    private func btWizardReferenceDevices(excluding deviceID: String) -> [Device] {
        let ordered = orderedDevices().filter { $0.id != deviceID && $0.isAvailable }
        // Cast is never offered: a Cast receiver plays ~5.5 s behind live, which
        // no ±500 ms bisection can resolve against.
        return ordered.filter(\.isLocalDevice)
            + ordered.filter { !$0.isLocalDevice && !$0.isBluetooth && !$0.isCast }
            + orderedBluetoothDevices(in: ordered)
    }

    /// The speaker the run starts against. The Mac's own output first — it is
    /// always present, always in step, and needs no second speaker set up
    /// (owner's call); else the one other member the user already has audio
    /// on; else anything else that is available. `nil` means there is nothing
    /// to compare against and the wizard opens with Start disabled.
    private func btWizardDefaultReference(excluding deviceID: String) -> Device? {
        let candidates = btWizardReferenceDevices(excluding: deviceID)
        if let local = candidates.first(where: \.isLocalDevice) { return local }
        let audible = candidates.filter { wantsAudio($0.id) }
        if audible.count == 1 { return audible[0] }
        return candidates.first
    }

    /// The tick gate, always carrying BOTH participants: the target and the
    /// reference the SESSION is currently comparing it against. The reference
    /// is read live rather than captured, because the user can swap it
    /// mid-run — and a stale one would leave the backend holding the speaker
    /// the question is actually about silent.
    private func pushBTWizardTick(_ active: Bool, target: String?) {
        onBTWizardTickActive?(active, target, btWizardSession?.reference?.id)
    }

    /// Make the reference audible for the run, through the ONE selection owner
    /// (`GroupController`) — never a parallel routing path. A reference the
    /// user already had selected is left alone, and only a selection this
    /// wizard MADE is remembered, so the restore can be exact.
    private func engageBTWizardReference(_ id: String) {
        guard !wantsAudio(id) else { return }
        btWizardEngagedReferenceID = id
        groupController?.setDeviceSelected(id, true)
    }

    /// Put the user's Selected Devices set back. Called from
    /// ``tearDownBTWizard()``, which every exit path funnels through — Keep,
    /// cancel, graceful exit, ✕, popover close, target lost — because a wizard
    /// that silently leaves the group edited is worse than one that never ran.
    private func releaseBTWizardReference() {
        guard let id = btWizardEngagedReferenceID else { return }
        btWizardEngagedReferenceID = nil
        groupController?.setDeviceSelected(id, false)
        refreshDeviceRows()
    }

    /// The picker's answer: engage the new reference, release the old, and let
    /// the session restart. The answers so far were given against a DIFFERENT
    /// speaker, so they are not evidence about this one — the session drops
    /// them rather than folding them in.
    private func setBTWizardReference(_ id: String) {
        guard let session = btWizardSession, let device = devicesByID[id],
              session.reference?.id != id else { return }
        let previous = btWizardEngagedReferenceID
        btWizardEngagedReferenceID = nil
        engageBTWizardReference(id)
        if let previous, previous != id {
            groupController?.setDeviceSelected(previous, false)
        }
        session.setReference(.init(id: id, name: device.name,
                                   isBluetooth: device.isBluetooth))
        // The session restarts the questions but never re-fires the tick, so
        // the backend still has the OLD reference on its participant hold —
        // which would leave the new one silent. Re-push while the run is live.
        if case .question = session.screen, let target = btWizardDeviceID,
           devicesByID[target]?.isLocalDevice == false {
            pushBTWizardTick(true, target: target)
        }
        refreshDeviceRows()
    }

    /// The wizard's own close (Keep / Done / Stop / Esc): the session already
    /// committed or restored; drop sheet + session and repaint the row's trim
    /// display.
    private func finishBTWizard() {
        if btWizardSession != nil {
            Analytics.capture("bt_sync:wizard_finished")
        }
        tearDownBTWizard(viaFinish: true)
        refreshDeviceRows()
        reconcileBTAlignmentNotes(animated: true)
    }

    /// Cancel-and-unmount. The session's `cancel()` restores the prior trim
    /// and silences the wizard tick unless Keep already ended it — safe on
    /// every path (deinit would cancel too; explicit is clearer).
    ///
    /// `targetLost` is the one exit that may KEEP the sheet: a target that
    /// vanishes under a LIVE modal bows out in place (one line and a Done)
    /// instead of vanishing the sheet silently. The run still ends here and
    /// now — only the chrome lingers; Done re-enters this funnel through
    /// `onFinished` with the session already gone and dismisses then.
    func tearDownBTWizard(targetLost: Bool = false, viaFinish: Bool = false) {
        let hadRun = btWizardSession != nil
        btWizardMicProbe?.cancel()
        btWizardMicProbe = nil
        if hadRun && !viaFinish {
            Analytics.capture("bt_sync:wizard_abandoned", ["target_lost": targetLost ? "true" : "false"])
        }
        btWizardSession?.cancel()
        btWizardSession = nil
        btWizardDeviceID = nil
        // Put the suspended trim back from the STORE, so Keep (which wrote 0)
        // and every other exit (which left the user's value alone) both land on
        // whatever is actually saved.
        if let id = btWizardSuspendedTrimDeviceID {
            btWizardSuspendedTrimDeviceID = nil
            onBTWizardEndPreview?(id, nil)
        }
        // Last, because lowering the reference is a composition re-anchor and a
        // Keep's measurement has to be in the table before it moves. Only for a
        // run that actually existed — this funnel also runs on the way IN, to
        // clear a previous wizard.
        if hadRun { onBTWizardEndRun?() }
        if targetLost, hadRun, let sheet = btWizardSheet, sheet.isHosted,
           let view = btWizardView {
            // The bow-out keeps sheet + view standing; every reference stays
            // so a relaunch (which tears down first) or Done can clear them.
            view.showTargetLost()
        } else {
            let sheet = btWizardSheet
            btWizardSheet = nil
            btWizardView = nil
            sheet?.dismissSilently()
        }
        releaseBTWizardReference()
    }
}
