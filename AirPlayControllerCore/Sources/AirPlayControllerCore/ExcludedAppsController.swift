// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import Foundation

/// UI-agnostic model backing the excluded-apps denylist (Settings › Audio),
/// persisted independently via its own ``ExcludedAppsStore``. Mirrors
/// `AppRoutingController`'s persistence-injection idiom, scaled to this list's
/// tiny surface: add, remove, and membership queries. It intentionally knows
/// nothing about routes — the "excluded ⇒ un-routable" precedence is enforced by
/// the coordinating layer (the app prunes any route for a newly-excluded app),
/// so the two stores stay independent.
public final class ExcludedAppsController {

    private let store: ExcludedAppsStore

    /// Excluded apps in stable insertion order (`bundleID` is identity). The UI
    /// renders rows in this order.
    private(set) public var excludedApps: [ExcludedApp]

    /// - Parameters:
    ///   - store: persistence for the denylist. Defaults to the on-disk store;
    ///     tests inject one pointed at a temp directory.
    ///   - loadPersisted: load saved exclusions immediately. Tests that don't
    ///     care about persistence can skip the disk hit.
    public init(store: ExcludedAppsStore = ExcludedAppsStore(), loadPersisted: Bool = true) {
        self.store = store
        self.excludedApps = loadPersisted ? ((try? store.load()) ?? []) : []
    }

    private func persist() {
        try? store.save(excludedApps)
    }

    private func index(of bundleID: String) -> Int? {
        excludedApps.firstIndex { $0.bundleID == bundleID }
    }

    // MARK: Queries

    /// Whether `bundleID` is on the denylist.
    public func isExcluded(_ bundleID: String) -> Bool {
        index(of: bundleID) != nil
    }

    /// The excluded bundle ids as a set, for O(1) filtering by callers (picker,
    /// route pruning).
    public var excludedBundleIDs: Set<String> {
        Set(excludedApps.map(\.bundleID))
    }

    // MARK: Mutations

    /// Exclude `bundleID`. No-op (no persist, no state change) if it's already
    /// excluded — matching the house invariant that no-op mutations don't persist.
    public func exclude(bundleID: String, displayName: String) {
        guard index(of: bundleID) == nil else { return }
        excludedApps.append(ExcludedApp(bundleID: bundleID, displayName: displayName))
        persist()
    }

    /// Remove `bundleID` from the denylist. No-op if it isn't present.
    public func remove(bundleID: String) {
        guard let i = index(of: bundleID) else { return }
        excludedApps.remove(at: i)
        persist()
    }
}
