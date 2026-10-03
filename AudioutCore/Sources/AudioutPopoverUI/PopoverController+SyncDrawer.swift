// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

extension PopoverController {

    // MARK: Bluetooth Sync drawer (PLAN-BT-SYNC-DRAWER T7)
    //
    // An accordion under its own row: at most one open at a time (D2),
    // inserted directly after the row it belongs to and pushing the rows below
    // down (D1 — sync is a comparison AGAINST those rows, so a floating panel
    // covering them would defeat the exercise). Mount/unmount ride
    // `insertRow`/`removeRow`, which already own the animated
    // `preferredContentSize` republish AND the Reduce Motion gate — so nothing
    // here re-fits the popover itself (folder rule: callers must never add
    // their own `panelContentDidChangeHeight`).

    /// Open the drawer under `id`, or close it if it is already the open one.
    /// Either way any OTHER open drawer closes first (D2).
    func toggleSyncDrawer(deviceID id: String, animated: Bool) {
        let closingThisOne = expandedSyncDeviceID == id
        closeSyncDrawerIntent()
        if !closingThisOne {
            expandedSyncDeviceID = id
            expandedSyncDeviceWasSelected = groupController?.isSpeakerSelected(id) ?? false
        }
        reconcileSyncDrawer(animated: animated)
        // Both chips repaint: the one losing its drawer drops back to its
        // resting form, the one gaining it reads engaged.
        refreshDeviceRows()
    }

    /// Retract the open-drawer INTENT, taking the align-by-ear tick with it —
    /// a metronome ticking with no visible control to stop it is a bug. The
    /// view itself is torn down by the next `reconcileSyncDrawer`.
    func closeSyncDrawerIntent() {
        guard let id = expandedSyncDeviceID else { return }
        expandedSyncDeviceID = nil
        expandedSyncDeviceWasSelected = false
        if alignTickDeviceID == id { setAlignTick(nil) }
    }

    /// Make the mounted drawer match `expandedSyncDeviceID`, first pruning the
    /// intent against the three reasons a drawer must auto-collapse: its
    /// device left the snapshot, stopped being an available Bluetooth row, or
    /// was dropped out of the mix.
    ///
    /// Called from `rebuild()` (freshly built rows) and from
    /// `update(devices:)`'s in-place repaint, so an open drawer re-reads its
    /// device's usable range on EVERY snapshot — T3's trap: that range moves
    /// whenever AirPlay joins or leaves the group, and a range captured at
    /// open time would let the ruler run past a floor that had crept upward.
    func reconcileSyncDrawer(animated: Bool) {
        if let id = expandedSyncDeviceID {
            let selected = groupController?.isSpeakerSelected(id) ?? false
            let rowIsLive = devicesByID[id]
                .map { isTrimmable($0) && $0.isAvailable } == true
                && deviceRowsByID[id] != nil
            if !rowIsLive || (expandedSyncDeviceWasSelected && !selected) {
                closeSyncDrawerIntent()
            } else {
                expandedSyncDeviceWasSelected = selected
            }
        }
        guard let id = expandedSyncDeviceID,
              let device = devicesByID[id],
              let row = deviceRowsByID[id]
        else {
            unmountSyncDrawer(animated: animated)
            return
        }
        if mountedSyncDrawerID != id {
            // Un-animated on purpose when the drawer MOVES between rows: an
            // animated removal fades the view and defers its detach, and this
            // single reused instance is about to be re-parented — two
            // animation groups would then fight over one view's `isHidden`.
            // The insert below carries the visible transition instead.
            unmountSyncDrawer(animated: false)
            mountedSyncDrawerID = id
            panel.insertRow(syncDrawer, after: row, animated: animated)
        }
        pushSyncDrawerState(device)
        if syncDrawerWasEditing {
            syncDrawerWasEditing = false
            // Give the field its editing session back — see the detach site
            // in `rebuild()`.
            syncDrawer.focusValueField()
        }
    }

    /// Push one device's live sync state into the mounted drawer. Split out of
    /// `reconcileSyncDrawer` so the align tick's own repaints (notably its
    /// ~30 s auto-stop) can un-light the drawer's button without dragging a
    /// whole mount/unmount reconcile behind them.
    func pushSyncDrawerState(_ device: Device) {
        syncDrawer.configure(deviceName: device.name,
                             trimMs: btSyncTrim(for: device),
                             isSet: btSyncTrimIsSet(for: device),
                             usableRangeMs: btUsableTrimRange(for: device.id),
                             alignTickActive: alignTickDeviceID == device.id,
                             canReset: canResetAlignment(for: device),
                             canAlignAgain: !device.isCast,
                             offsetSource: btOffsetSourceProvider?(device.id),
                             movedSinceLastTimeMs: btMovedNoticeMsByID[device.id])
    }

    /// Record that a re-measurement moved this speaker's stored offset far
    /// enough to say so. Shows on the drawer's caption line and in the chip's
    /// tooltip until the drawer next closes.
    public func noteAlignmentMovedSinceLastTime(deviceID: String, byMs: Double) {
        btMovedNoticeMsByID[deviceID] = byMs
        refreshDeviceRows()
        if mountedSyncDrawerID == deviceID, let device = devicesByID[deviceID] {
            pushSyncDrawerState(device)
        }
    }

    /// Whether this device has anything STORED for Reset to clear: a trim entry
    /// (the Mac's `AppSettings` offset, or a Bluetooth device's), or — Bluetooth
    /// only — a measured latency from an alignment run.
    private func canResetAlignment(for device: Device) -> Bool {
        if btSyncTrimIsSet(for: device) { return true }
        // Only a wizard run leaves a measured latency, and only Bluetooth rows
        // get one — the Mac's is the zero it is measured from, and Cast has no
        // run at all.
        guard !device.isLocalDevice, !device.isCast else { return false }
        return btMeasuredLatency(for: device.id) != nil
    }

    func unmountSyncDrawer(animated: Bool) {
        guard let closing = mountedSyncDrawerID else { return }
        mountedSyncDrawerID = nil
        // The notice stands until the drawer next CLOSES (ADR 0001) — this is
        // that moment, and it is the only thing that ends it.
        btMovedNoticeMsByID.removeValue(forKey: closing)
        panel.removeRow(syncDrawer, animated: animated)
    }

    /// The drawer's hard stops (D11). Queried FRESH every time — never cached;
    /// see `btTrimRangeProvider`.
    func btUsableTrimRange(for id: String) -> ClosedRange<Double> {
        // The Mac's own sink has no per-device zero clamp to solve against —
        // its delay floor sits well below −500 ms — so the full ±range is
        // usable and the BT provider (which knows nothing about this id) is
        // not consulted.
        if devicesByID[id]?.isLocalDevice == true {
            return -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs
        }
        // A Cast receiver's own buffer is measured and removed on the wire, so
        // this control is left with the residue AFTER its media clock — the
        // output stage, the DAC, and a TV's HDMI → soundbar chain, which alone
        // can pass 400 ms. Its whole range is usable: there is no per-device
        // zero clamp to solve against, so the BT provider is not consulted.
        if devicesByID[id]?.isCast == true {
            return -BTSyncTrim.castRangeMs...BTSyncTrim.castRangeMs
        }
        return btTrimRangeProvider?(id) ?? (-BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)
    }

    /// Apply one trim edit from the drawer. `persist == false` is one tick of
    /// a held stepper or arrow key: the audio path takes it, the JSON store does not. The
    /// session cache updates either way, so the row's chip tracks the scrub
    /// digit by digit.
    private func applyBTTrim(_ ms: Double, deviceID id: String, persist: Bool) {
        let isCast = devicesByID[id]?.isCast == true
        let value = BTSyncTrim.quantise(
            ms, rangeMs: isCast ? BTSyncTrim.castRangeMs : BTSyncTrim.rangeMs)
        btTrimsByID[id] = value
        // Editing a device IS tuning it — a scrub that passes through exactly
        // 0.0 must read "0.0 ms", never flip the chip back to "Not set".
        btTunedDeviceIDs.insert(id)
        if devicesByID[id]?.isLocalDevice == true {
            // No `persist` distinction locally: the one closure both stores the
            // value and triggers the live apply, so a held stepper's live ticks
            // store too. Only the analytics below wait for the commit.
            onSetLocalTrim?(value)
        } else if isCast {
            // Same posture as the local closure, and for the same reason.
            onSetCastOffset?(value, id)
        } else {
            onSetBTTrim?(value, id, persist)
        }
        if persist {
            Analytics.capture(isCast ? "cast_sync:offset_committed" : "bt_sync:trim_committed")
        }
        // Repaint just this one row's chip. A scrub arrives dozens of times a
        // second and `refreshDeviceRows()` would drag the rail extents and
        // every other row through each one of them.
        if let row = deviceRowsByID[id], let device = devicesByID[id] {
            applySelectionState(to: row, device: device)
        }
    }

    func refreshDeviceRows() {
        // Item 9: prune the energize pending beat off any member that has left
        // `.off` (started connecting / resolved) BEFORE re-applying rows, so the
        // repaint reflects the current beat, and fire the one-shot settle
        // announcement when the switch finishes moving.
        reconcileEnergize()
        for (id, row) in deviceRowsByID {
            guard let device = devicesByID[id] else { continue }
            applySelectionState(to: row, device: device)
        }
        // The rail's dormancy and its far end both track state a mid-open toggle
        // can change (v4 §Call-1), so re-point it on every in-place repaint too.
        updateRailRows()
        refreshCardHeaderLiveness()
    }

    /// Re-point the membership rail at the mounted device rows (Warm Signal v4
    /// §Call-1). The rail's two ends are the overlay's to derive: the recessed
    /// channel spans the whole device band, and the gold signal inside it reaches
    /// the LOWEST member. What the host still owns is WHICH rows exist, WHERE the
    /// rail is cut, and whether the whole path is dormant.
    ///
    /// The rail runs to the LOWEST device the rail reaches
    /// (`BusRailOverlayView.railReaches`) in the FULL order (`deviceSections()`),
    /// hidden or not. When that device sits inside a collapsed subsection, the
    /// rail is cut at that subsection's header with a dot, exactly as a collapsed
    /// CARD cuts at its own. Otherwise there is no cut: the overlay already ends
    /// the rail at the lowest reached mounted row. A collapsed subsection hiding
    /// only devices the rail does not reach never cuts. A hidden device has no
    /// row, so its node comes from `DeviceRowView.busNode`, the same function the
    /// rows use. A device the BT-LIST filter never listed is not in
    /// `deviceSections()` at all, so it never decides the cut.
    func updateRailRows() {
        let sections = deviceSections()
        let fullOrder = sections.flatMap(\.devices)
        // Only MOUNTED rows go to the overlay — a collapsed subsection's rows are
        // already out of the model; the cut below speaks for them.
        let railRows = fullOrder.compactMap { deviceRowsByID[$0.id] }
        let lowestReachedID = fullOrder.last { device in
            BusRailOverlayView.railReaches(railNode(for: device))
        }?.id
        let cutSubsectionTitle = lowestReachedID.flatMap { id in
            sections.first {
                isSubsectionCollapsed($0.title) && $0.devices.contains { $0.id == id }
            }?.title
        }
        // Feed the continuous rail overlay the Main Audio row + device rows in
        // display order so it can draw the spine as one line through the gutter.
        panel.setRailRows(mainOut: mainOutRow, deviceRows: railRows,
                          originCardTitle: Self.mainAudioCardTitle,
                          deviceCardTitle: Self.outputDevicesCardTitle,
                          cutSubsectionTitle: cutSubsectionTitle,
                          dormant: devicesCardDivergence() != nil)
        // Whether there is a rail at all, decided ONCE here and read by both
        // ends of it: the wire resolves the same rule against the stops it
        // draws (`RailPlan.isLive`), the Main Audio ring takes it from this
        // push. A room hidden inside a collapsed subsection still counts — the
        // rail cuts to that fold's dot rather than vanishing.
        mainOutRow.setRailLive(lowestReachedID != nil)
    }

    /// A device's rail node: the mounted row's own, or — for a device hidden in a
    /// collapsed subsection — the same derivation from the values
    /// `applySelectionState` would push to its row.
    private func railNode(for device: Device) -> MembershipBusView.Node {
        if let node = deviceRowsByID[device.id]?.railNode { return node }
        return DeviceRowView.busNode(
            device: device,
            selected: groupController?.isSpeakerSelected(device.id) ?? false,
            energizePending: energizePendingIDs.contains(device.id),
            reduceMotion: reduceMotionActive,
            localFallbackOutput: localFallbackActive && device.isLocalDevice)
    }
}

// MARK: - BTSyncDrawerViewDelegate (T7)

extension PopoverController: BTSyncDrawerViewDelegate {

    public func syncDrawer(_ d: BTSyncDrawerView, didChangeTrimMs ms: Double, committed: Bool) {
        guard let id = expandedSyncDeviceID else { return }
        applyBTTrim(ms, deviceID: id, persist: committed)
    }

    public func syncDrawer(_ d: BTSyncDrawerView, didToggleAlignTick active: Bool) {
        setAlignTick(active ? expandedSyncDeviceID : nil)
    }

    /// Escape inside the drawer — the same "close me" the chip performs.
    public func syncDrawerDidRequestClose(_ d: BTSyncDrawerView) {
        closeSyncDrawerIntent()
        reconcileSyncDrawer(animated: true)
        refreshDeviceRows()
    }

    /// "Align again…" in the drawer (W4 relaunch): the guided wizard for the
    /// device whose drawer is open, opening on its last result.
    public func syncDrawerDidRequestAlignmentWizard(_ d: BTSyncDrawerView) {
        guard let id = expandedSyncDeviceID else { return }
        startBTAlignmentWizard(deviceID: id, door: .drawer)
    }

    /// "Reset alignment": drop this device's stored alignment everywhere it is
    /// remembered — the backend's store (which also re-pushes the live sink, so
    /// a playing speaker reverts audibly) and the session caches the rows read
    /// from. The caches are REMOVED rather than zeroed: the next read re-seeds
    /// them from the providers, which now answer "nothing stored", and that is
    /// what puts the chip back on "Not set" instead of a tuned "0 ms". The
    /// drawer has already moved its own display — its gesture, its readout.
    public func syncDrawerDidRequestResetAlignment(_ d: BTSyncDrawerView) {
        guard let id = expandedSyncDeviceID else { return }
        if devicesByID[id]?.isLocalDevice == true {
            onResetLocalTrim?()
        } else if devicesByID[id]?.isCast == true {
            onResetCastOffset?(id)
            Analytics.capture("cast_sync:offset_reset")
        } else {
            onResetBTAlignment?(id)
        }
        btTrimsByID.removeValue(forKey: id)
        btLatenciesByID.removeValue(forKey: id)
        btTunedDeviceIDs.remove(id)
        // A cleared BLUETOOTH row's chip becomes the wizard's door, so it can
        // no longer close the drawer it opened — leaving one open with no way
        // to dismiss it. Collapse it here instead.
        if devicesByID[id]?.isBluetooth == true, devicesByID[id]?.isCast == false {
            closeSyncDrawerIntent()
            reconcileSyncDrawer(animated: true)
        }
        refreshDeviceRows()
    }
}
