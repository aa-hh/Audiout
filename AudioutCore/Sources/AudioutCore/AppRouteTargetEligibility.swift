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
/// Every kind that has a per-app delivery path now qualifies: an AirPlay 2
/// receiver and an AirPlay 1 receiver both stream through the shared engine,
/// and a Bluetooth speaker is fed by UID through the sink manager
/// (`BTSyncedSink.enqueue(…forDeviceUIDs:)`).
///
/// razor: Cast is the one refusal left. `CastFanOut.write` fans one buffer to
/// every `CastFeedRing` it holds with no per-destination addressing, so a
/// route to a Cast id has nowhere to be delivered — it would be silently
/// demoted and look like it did nothing. Lifting it needs per-ring addressing,
/// a per-app arming set, and the hard invariant that a per-app-only receiver
/// never enters `castSelectedIDs`: that list feeds `updateCastRoomDelayLocked`,
/// and a Cast receiver's lead is measured in whole seconds, so a leak would
/// drag every AirPlay speaker, the Mac and every Bluetooth sink back with it.
public extension Device {
    func canBePerAppRouteTarget() -> Bool {
        if isLocalDevice || kind == .localMac { return false }
        if isCast { return false }
        return true
    }
}
