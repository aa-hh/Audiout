// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The one "may this device be a per-app routing target?" rule, shared by
/// the popover's device-destination list and the saved-group resolver
/// (`AppRoutingController.resolveGroupTargets`). A KIND question only — it
/// never reads `isAvailable`, because `resolveGroupTargets` deliberately
/// keeps unreachable group members (an unreachable or main-out-claimed
/// member survives that resolve and is subtracted later inside the
/// backend's own effective-route pass); callers that need a reachability
/// filter add `isAvailable` themselves at the call site.
///
/// Every kind that has a per-app delivery path qualifies as a device target:
/// an AirPlay 2 receiver and an AirPlay 1 receiver both stream through the
/// shared engine, a Bluetooth speaker is fed by UID through the sink manager
/// (`BTSyncedSink.enqueue(…forDeviceUIDs:)`), and a Cast receiver is fed by id
/// through `CastOutputManager.writePerApp`, which addresses one ring while
/// `setDevices(_:sources:)` names the ring's owner.
///
/// razor: a saved group is the one refusal left for Cast
/// (`canBePerAppGroupMember()`): per-group cross-transport timing is a
/// separate track. The invariant that a per-app-only receiver never enters
/// `castSelectedIDs` (which feeds the room delay, and a Cast lead is whole
/// seconds) lives in `reconcileCastSessionsLocked`.
public extension Device {
    func canBePerAppRouteTarget() -> Bool {
        if isLocalDevice || kind == .localMac { return false }
        return true
    }

    /// The group rule: the device rule minus Cast.
    func canBePerAppGroupMember() -> Bool { canBePerAppRouteTarget() && !isCast }
}
