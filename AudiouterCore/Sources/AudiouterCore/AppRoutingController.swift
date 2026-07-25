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

    /// `bundleID` → the `.device(id:)` target `resetDeviceRoute(bundleID:)` most
    /// recently cleared it FROM (an app-quit-triggered reset, not a deliberate
    /// user pick). IN-MEMORY ONLY, never persisted through `store` — no
    /// `AppRouteStore` schema change — so it is forgotten for free when
    /// Audiouter itself quits, same as any other plain property. Lets the
    /// popover offer a one-click "Resume → <device>" pick when the app
    /// relaunches (`PopoverController.appDestinations(devices:keeping:bundleID:)`)
    /// instead of forcing a manual re-pick, without reversing the 2026-07-22
    /// decision that a redirect itself does not survive the app's quit. Cleared
    /// the moment it's consumed or made moot — see `setDestination(_:for:)` and
    /// `removeRoute(bundleID:)`.
    private var clearedDeviceRouteMemory: [String: String] = [:]

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
    ///
    /// ANY resolvable pick — the "Resume → <device>" offer, the same device
    /// picked again, or a completely different destination — consumes
    /// `clearedDeviceRouteMemory`'s entry for `bundleID` unconditionally, even
    /// when the destination itself turns out to be a no-op: once the user has
    /// touched this row's popup, the remembered target is stale/moot either
    /// way, and there is no separate "Resume" mutation to special-case.
    public func setDestination(_ destination: AppRouteDestination, for bundleID: String) {
        guard let i = index(of: bundleID) else { return }
        clearedDeviceRouteMemory.removeValue(forKey: bundleID)
        guard appRoutes[i].destination != destination else { return }
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

    /// Remove a route entirely. No-op if `bundleID` isn't present. Also drops any
    /// `clearedDeviceRouteMemory` entry for `bundleID` — a removed route has
    /// nothing left to resume.
    public func removeRoute(bundleID: String) {
        guard let i = index(of: bundleID) else { return }
        appRoutes.remove(at: i)
        clearedDeviceRouteMemory.removeValue(forKey: bundleID)
        persist()
    }

    /// Revert a route that currently redirects to a specific AirPlay DEVICE back
    /// to `.noRedirect` — used when the routed app QUITS, so a redirect no longer
    /// silently persists across the app's own quit/relaunch (product decision
    /// 2026-07-22): relaunching the app won't auto-resume streaming to a speaker;
    /// the user re-picks it deliberately. No-op for a `.noRedirect`/`.currentDevice`
    /// route (only an involuntary device redirect is reset — a "play on this Mac"
    /// pick is left alone) or a bundle with no route, so it's safe to call on
    /// every app termination. Mirrors ``handleDeviceDisappeared(id:)``'s
    /// involuntary reset-to-`.noRedirect`, and reuses the same un-route path a
    /// manual change takes (persist → `onRoutesDidChange`).
    ///
    /// Also records the cleared target in `clearedDeviceRouteMemory` (in-memory
    /// only) so a relaunch can offer a one-click way back — this does NOT
    /// reverse the quit-clears-the-route decision above; it only remembers what
    /// was cleared, kept entirely off disk.
    public func resetDeviceRoute(bundleID: String) {
        guard let i = index(of: bundleID),
              case .device(let deviceID) = appRoutes[i].destination else { return }
        clearedDeviceRouteMemory[bundleID] = deviceID
        appRoutes[i].destination = .noRedirect
        persist()
    }

    /// The device id `resetDeviceRoute(bundleID:)` most recently cleared
    /// `bundleID`'s route from, if any and if not yet consumed — `nil` once
    /// the user picks any destination (`setDestination`) or removes the route
    /// (`removeRoute`). `PopoverController` reads this to decide whether to
    /// offer a "Resume → <device>" destination entry.
    public func clearedDeviceRouteTarget(for bundleID: String) -> String? {
        clearedDeviceRouteMemory[bundleID]
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

    /// PLAN decision 7 (silent fallback), narrowed by R5: any route targeting the
    /// device `id` — which has DISAPPEARED from the discovered fleet entirely —
    /// resets to `.noRedirect`, NOT `.currentDevice`. A device disappearing out
    /// from under a route isn't a deliberate choice to switch to "play on this
    /// Mac" — `.currentDevice` is now a genuine user pick (menu decision), and an
    /// involuntary reset shouldn't masquerade as one. `.noRedirect` is the
    /// neutral/unset state this route effectively reverts to. Persists only if
    /// something actually changed.
    ///
    /// GONE means gone from the snapshot, NOT merely `isAvailable == false`
    /// (R5). A still-discovered receiver that reports itself unreachable (a
    /// sticky-AP2 speaker powered off, a Wi-Fi blip) KEEPS its route: the user's
    /// intent survives, the backend un-excludes the app so it rejoins the
    /// whole-system mix meanwhile (`NativeBackend`'s effective route table), and
    /// the redirect re-engages by itself when the device is reachable again. Only
    /// the caller that observes an outright disappearance may call this — see
    /// `PopoverController.update(devices:)`.
    public func handleDeviceDisappeared(id: String) {
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
