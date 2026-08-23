// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Warm Signal v3 §5.5 — the menu-bar routing-active dot's single predicate.
///
/// The dot answers "am I still broadcasting?" at a glance: **present = ≥1 live
/// route, absent = passthrough/idle.** A route is live when either
///
/// - a device is *armed + connected* in the active Main Out target — armed is
///   `Device.isSelected` (the backend's applied output set, which
///   `GroupController.applyRouting()` keeps equal to the active target's
///   membership), connected is `ConnectionState.connected` (the enable actually
///   took; `.connecting`/`.reconnecting` are not broadcasting yet/right now,
///   and a `.failed` arm must never light the dot) — the local Mac is excluded
///   so plain passthrough (Mac speakers only) reads idle; **or**
/// - any per-app route is confirmed streaming (`BackendEvent.routedApps` with a
///   non-empty app list — the same CONFIRMED signal the device rows' routing
///   sublabel prefers, not routing *intent*).
///
/// Pure function over the same model state the popover paints from (backend
/// device snapshot + routed-apps events) — no polling, no new state machine.
public enum StatusRoutingIndicator {

    /// - Parameters:
    ///   - devices: the current backend device snapshot (`OutputBackend.devices`).
    ///   - hasLiveAppRoutes: whether any device currently has a non-empty
    ///     confirmed `.routedApps` app list.
    public static func isRoutingLive(devices: [Device], hasLiveAppRoutes: Bool) -> Bool {
        if hasLiveAppRoutes { return true }
        return devices.contains { device in
            !device.isLocalDevice && device.isSelected && device.connectionState == .connected
        }
    }
}
