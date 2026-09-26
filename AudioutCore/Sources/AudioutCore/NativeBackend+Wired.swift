import Foundation

extension NativeBackend {
    // MARK: Wired outputs → deviceAdded/deviceUpdated/deviceRemoved

    /// Fold one ``WiredOutputEnumerator`` snapshot into `known`/`order`, the
    /// same shape `applyCastSnapshots` uses. On `stateQueue`.
    ///
    /// An unplugged output's row is kept greyed (`isAvailable == false`)
    /// while it is USED — selected, app-routed, or a saved-group member — and
    /// is removed only once it is not used (owner ruling 2026-09-26): a
    /// removed row would take a saved group's or an app route's reference to
    /// it with it. The availability edge, both ways, goes through
    /// `commitKnownDevice` so a replug reaches a kept row the same way an
    /// unplug demoted it.
    ///
    /// A selected or app-claimed row's availability edge also re-runs the sink
    /// decision, as `applyBTSnapshots` does: an unplugged UID no longer
    /// resolves, so its sink drops out before the HAL can reuse the
    /// `AudioObjectID` it was pinned to; a replugged one re-enters the sink set
    /// and, when selected, breathes `.connecting` until it renders.
    func applyWiredSnapshots(_ snapshots: [WiredOutputSnapshot]) {   // on stateQueue
        var desiredAvailabilityMoved = false
        for snapshot in snapshots {
            if var device = known[snapshot.id] {
                let replugged = device.isAvailable == false
                device.name = snapshot.name
                device.wiredTransport = snapshot.transport
                device.isAvailable = true
                if device != known[snapshot.id] { commitKnownDevice(snapshot.id, device) }
                if replugged,
                   expectedSelected.contains(snapshot.id) || btPerAppClaimedUIDs.contains(snapshot.id) {
                    desiredAvailabilityMoved = true
                    beginBTConnectingLocked(snapshot.id)
                }
            } else {
                let device = Device(
                    id: snapshot.id, name: snapshot.name, kind: .wired,
                    isAvailable: true, supportsAirPlay2: false,
                    eq: eqByDeviceID[snapshot.id] ?? .flat,
                    wiredTransport: snapshot.transport)
                known[snapshot.id] = device
                order.append(snapshot.id)
                emit(.deviceAdded(device))
            }
        }
        let present = Set(snapshots.map(\.id))
        let unplugged = order.filter { known[$0]?.kind == .wired && !present.contains($0) }
        for id in unplugged {
            guard var device = known[id] else { continue }
            if device.isAvailable == false { continue }
            if expectedSelected.contains(id) || btPerAppClaimedUIDs.contains(id) {
                desiredAvailabilityMoved = true
            }
            device.isAvailable = false
            btConnectingDeadlines[id] = nil
            // Mirror the Bluetooth deselect arm (`NativeBackend+Tone.swift`):
            // a `.failed` story survives so a "Try again" affordance still
            // has something to explain; every other unplug clears to `.off`.
            if case .failed = device.connectionState {} else {
                device.connectionState = .off
            }
            commitKnownDevice(id, device)
        }
        if desiredAvailabilityMoved {
            reconcileSilenceWatchdog()
            reapplyBTSinkLocked()
        }
        pruneUnusedWiredLocked()
    }

    /// Is wired row `id` still referenced by anything that would lose state
    /// if the row disappeared? Selection, an app `.device` route naming it,
    /// or membership of any saved group's resolved targets. On `stateQueue`.
    ///
    /// Deliberately NOT `btPerAppClaimedUIDs`-style per-app eligibility: that
    /// set is POST-eligibility (it already excludes an unavailable device),
    /// so once this row goes unavailable it always reads empty there — using
    /// it would prune a still-referenced row instead of keeping it.
    func wiredRowIsUsedLocked(_ id: String) -> Bool {   // on stateQueue
        expectedSelected.contains(id)
            || routesTargetDeviceLocked(id)
            || lastGroupTargets.values.contains { $0.memberVolumes[id] != nil }
    }

    /// Remove every wired row that is unavailable and no longer used. Called
    /// on every edge that can change "used" — a snapshot (this file), a
    /// selection write (`setOutputSet`), and a route/group push
    /// (`updateAppRoutes`) — so a row is dropped the moment it stops being
    /// referenced, not just on its next unplug. On `stateQueue`.
    func pruneUnusedWiredLocked() {   // on stateQueue
        let toRemove = order.filter {
            known[$0]?.kind == .wired && known[$0]?.isAvailable == false && !wiredRowIsUsedLocked($0)
        }
        for id in toRemove {
            known[id] = nil
            order.removeAll { $0 == id }
            emit(.deviceRemoved(id: id))
        }
    }
}
