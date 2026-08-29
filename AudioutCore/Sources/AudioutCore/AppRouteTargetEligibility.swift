// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Temporary staging flag for the per-app routing device-kind rollout.
/// Callers combine it with `Device.canBePerAppRouteTarget(allOutputs:)` to
/// decide whether a device may be a per-app route target. Ships off:
/// Bluetooth and Cast have no per-app delivery path yet, so per-app mixed
/// audio reaches only the AirPlay engine, and routing to a Bluetooth or Cast
/// id would be silently demoted, since those ids never hold an `outputIDs`
/// entry (`NativeBackend.swift`). The flag exists so the shared predicate
/// can be exercised and extended without offering destinations that would
/// appear to do nothing.
///
/// Read once from the environment, the `AUDIOUTER_DEBUG_TICK_SWAP` idiom
/// (`AlignmentTickInjector.swift`). Public because `AudioutPopoverUI` is a
/// separate module that only depends on `AudioutCore` and must read this too.
public enum PerAppRouting {
    public static let allOutputsEnabled: Bool =
        ProcessInfo.processInfo.environment["AUDIOUT_PER_APP_ALL_OUTPUTS"] == "1"
}

/// The one "may this device be a per-app routing target?" rule, shared by
/// the popover's device-destination list and the saved-group resolver
/// (`AppRoutingController.resolveGroupTargets`). A KIND question only — it
/// never reads `isAvailable`, because `resolveGroupTargets` deliberately
/// keeps unreachable group members (an unreachable or main-out-claimed
/// member survives that resolve and is subtracted later inside the
/// backend's own effective-route pass); callers that need a reachability
/// filter add `isAvailable` themselves at the call site.
///
/// razor: Bluetooth and Cast stay excluded even with `allOutputs: true`
/// because neither has a per-app delivery path yet — routing an app to one
/// would be silently demoted and look like it did nothing. Lifting this
/// needs a per-destination feed path for non-engine outputs, and a way to
/// arm those sinks independently of the whole-system selection. Once no
/// destination kind is gated, the `allOutputs` parameter and
/// `PerAppRouting.allOutputsEnabled` both go away.
public extension Device {
    func canBePerAppRouteTarget(allOutputs: Bool) -> Bool {
        if isLocalDevice || kind == .localMac { return false }
        if isBluetooth { return false }
        if isCast { return false }
        return allOutputs || supportsAirPlay2
    }
}
