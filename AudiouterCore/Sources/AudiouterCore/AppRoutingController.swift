// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// UI-agnostic model backing the popover's "Applications" card
/// (PLAN-POPOVER-ROUTING.md decision 2: a SEPARATE controller from
/// `GroupController`, persisted independently via its own ``AppRouteStore``).
/// Mirrors `GroupController`'s persistence-injection idiom, scaled down to
/// this card's much smaller surface: add/remove routes, change a route's
/// destination or volume, and fall back silently when a routed device
/// disappears (decision 7).
public final class AppRoutingController {

    private let store: AppRouteStore

    /// Routes in stable insertion order (`bundleID` is identity — PLAN
    /// decision 2 / `AppRouteStore` doc). The UI renders rows in this order.
    private(set) public var appRoutes: [AppRoute]

    /// Fired AFTER any mutation that actually changes `appRoutes` (add / remove /
    /// destination / volume / silent device-unavailable fallback), immediately
    /// after the change is persisted (T7). The coordinating layer hooks this to
    /// push the new table into the audio backend
    /// (`AppRouteConfiguring.updateAppRoutes`). No-op mutations don't fire it
    /// (they return before `persist()`), so a spurious "nothing changed" callback
    /// never reaches the backend. Not called during init's persisted-load.
    public var onRoutesDidChange: (() -> Void)?

    /// - Parameters:
    ///   - store: persistence for saved routes. Defaults to the on-disk store
    ///     at ``AppRouteStore``'s default directory; tests inject one pointed
    ///     at a temp directory.
    ///   - loadPersisted: load `store`'s saved routes immediately. Tests that
    ///     don't care about persistence can skip the disk hit.
    public init(store: AppRouteStore = AppRouteStore(), loadPersisted: Bool = true) {
        self.store = store
        self.appRoutes = loadPersisted ? ((try? store.load()) ?? []) : []
    }

    // STABILITY(D4): UI-thread stalls and stuck-drag state — see dev/notes/stability-audit-2026-07-18.md
    /// Persist the current table AND notify observers. Called on the change edge
    /// only (every caller guards on an actual mutation first), so `onRoutesDidChange`
    /// fires exactly when the table changed.
    private func persist() {
        try? store.save(appRoutes)
        onRoutesDidChange?()
    }

    private func index(of bundleID: String) -> Int? {
        appRoutes.firstIndex { $0.bundleID == bundleID }
    }

    // MARK: Mutations

    /// Add a new route for `bundleID`, defaulting to `.noRedirect` at
    /// volume 100 (the neutral/unset state for a newly-added app — no
    /// deliberate choice has been made yet; `AppRoute.init`'s own default).
    /// No-op if `bundleID` is already present (house invariant: no-op
    /// mutations must not persist or change state).
    public func addRoute(bundleID: String, displayName: String) {
        guard index(of: bundleID) == nil else { return }
        appRoutes.append(AppRoute(bundleID: bundleID, displayName: displayName))
        persist()
    }

    /// Change a route's redirect target. No-op (no persist, no state change)
    /// if the route is missing or already targets `destination`.
    public func setDestination(_ destination: AppRouteDestination, for bundleID: String) {
        guard let i = index(of: bundleID), appRoutes[i].destination != destination else { return }
        appRoutes[i].destination = destination
        persist()
    }

    /// Set a route's volume, clamped to 0–100 (`Int.clampedToVolume`). No-op
    /// if the route is missing or the clamped value equals the current one.
    public func setVolume(_ volume: Int, for bundleID: String) {
        guard let i = index(of: bundleID) else { return }
        let clamped = volume.clampedToVolume
        guard appRoutes[i].volume != clamped else { return }
        appRoutes[i].volume = clamped
        persist()
    }

    /// Remove a route entirely. No-op if `bundleID` isn't present.
    public func removeRoute(bundleID: String) {
        guard let i = index(of: bundleID) else { return }
        appRoutes.remove(at: i)
        persist()
    }

    // MARK: Derived state

    /// Count of routes redirected away to a specific AirPlay device (PLAN §B —
    /// drives the Applications-section collapse default: collapsed unless
    /// this is > 0). Uses `isDeviceRoute` (positive match on `.device`) rather
    /// than `!= .currentDevice` — the latter would incorrectly count
    /// `.noRedirect` routes as "routed."
    public var routedAppCount: Int {
        appRoutes.reduce(0) { $0 + ($1.destination.isDeviceRoute ? 1 : 0) }
    }

    /// App display names whose route destination is this device (bypassed to
    /// it), in stable route order. Excludes both `.noRedirect` and
    /// `.currentDevice` (local / no redirect) — those apps aren't routed to
    /// any AirPlay device. Backs the device row's routing sublabel
    /// (`DeviceRowView.apply(routedAppNames:)`) in both host controllers
    /// (popover + window).
    public func routedAppNames(for deviceID: String) -> [String] {
        appRoutes.compactMap { route in
            if case .device(let id) = route.destination, id == deviceID { return route.displayName }
            return nil
        }
    }

    /// PLAN decision 7 (silent fallback): any route targeting the now-gone
    /// device `id` resets to `.noRedirect`, NOT `.currentDevice`. A device
    /// disappearing out from under a route isn't a deliberate choice to
    /// switch to "play on this Mac" — `.currentDevice` is now a genuine user
    /// pick (menu decision), and an involuntary reset shouldn't masquerade as
    /// one. `.noRedirect` is the neutral/unset state this route effectively
    /// reverts to. Persists only if something actually changed.
    public func handleDeviceUnavailable(id: String) {
        var changed = false
        for i in appRoutes.indices {
            if case .device(let deviceID) = appRoutes[i].destination, deviceID == id {
                appRoutes[i].destination = .noRedirect
                changed = true
            }
        }
        guard changed else { return }
        persist()
    }
}
