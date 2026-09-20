// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

extension PopoverController {

    // MARK: Applications card ± footer (T3, LOCKED DECISION)

    /// The footer's "−" segment: remove the currently selected app (no-op if
    /// nothing is selected — the segment is disabled in that state, but this
    /// guard keeps `test_tapRemove` safe to call unconditionally too).
    func removeSelectedApp() {
        guard let bundleID = selectedAppBundleID else { return }
        removeApp(bundleID: bundleID)
    }

    /// Remove `bundleID`'s route via the SAME path all three removal
    /// affordances funnel through (± footer "−", context-menu "Remove from
    /// list", Delete/Backspace — `AppRowView.Delegate.appRow(_:didRemoveFor:)`
    /// calls this too). If the removed app was selected, selection advances to
    /// its neighbor in `appRoutes` order (LOCKED DECISION) — preferring the
    /// row that slides into the removed row's old position (the next route),
    /// falling back to the previous one, and clearing selection entirely when
    /// the list becomes empty.
    private func removeApp(bundleID: String) {
        if selectedAppBundleID == bundleID {
            selectedAppBundleID = neighborBundleID(of: bundleID)
        }
        appRouting.removeRoute(bundleID: bundleID)
        rebuild()
    }

    /// The bundle id that should become selected after `bundleID` is removed:
    /// the route immediately after it in `appRoutes` order, else the one
    /// immediately before, else `nil` (the list is now empty).
    private func neighborBundleID(of bundleID: String) -> String? {
        let routes = appRouting.appRoutes
        guard let index = routes.firstIndex(where: { $0.bundleID == bundleID }) else { return nil }
        if index + 1 < routes.count { return routes[index + 1].bundleID }
        if index - 1 >= 0 { return routes[index - 1].bundleID }
        return nil
    }

    // MARK: Applications card rows (T-8, PLAN §C decisions 3/4/6/8)

    /// Build one `AppRowView` for `route` against the discovered device `devices`.
    /// The destination popup leads with the standalone "Follows main output"
    /// entry (the default/neutral state), then mirrors `refreshMainOutRow`'s split — a
    /// "This Mac" entry (local, now an explicit pick) then the available
    /// (present + reachable) non-local AirPlay devices, plus this route's own
    /// target if it is currently unreachable (R5). The selected id is
    /// derived from `route.destination`, and the slider dims while local
    /// (decision 3, driven inside `AppRowView` by the selected entry's `isLocal`
    /// — true for both "Follows main output" and "This Mac").
    func makeAppRow(_ route: AppRoute, devices: [Device]) -> AppRowView {
        let row = AppRowView(showsMeter: true)
        row.delegate = self
        row.apply(AppRowView.Configuration(
            appID: route.bundleID,
            name: route.displayName,
            icon: appIcon(for: route.bundleID),
            volume: route.volume,
            selectedDestinationID: destinationID(for: route.destination),
            destinations: appDestinations(devices: devices, keeping: route.destination,
                                         bundleID: route.bundleID),
            isRunning: !offlineBundleIDs.contains(route.bundleID)),
                  isSelected: route.bundleID == selectedAppBundleID)
        appRowsByBundleID[route.bundleID] = row
        return row
    }

    /// The destination entries for ONE row's popup, in display order: a
    /// "Resume → <device>" entry when one is offerable (see below), then the
    /// standalone unrouted entry — titled with the Warm Signal bridge phrase
    /// **"Follows main output"** (§5.1, decision 3), supplied by the HOST per the
    /// host-supplies-copy doctrine — then the
    /// "This Mac" entry (decision 8, now an explicit pick), then every
    /// AVAILABLE non-local device (`availableAirPlayDestinations`).
    /// Plain values only — `AppRowView` is isolated from Core's `AppRoute` (T-6).
    ///
    /// `keeping` is this row's CURRENT destination, and it earns an entry even when
    /// it isn't offerable any more (R5). A route whose target went
    /// `isAvailable == false` is now kept rather than reset, and without this the
    /// row's `selectedDestinationID` would match nothing in the menu — which
    /// `AppRowView.apply` reads as "Follows main output" (its `?? true` fallback), rendering
    /// a dimmed slider and an unset-looking row for a route that is perfectly
    /// intact. The injected entry names the device and says what is actually
    /// happening to its audio meanwhile. Same inclusion rule
    /// `GroupEditorViewController` uses for its membership list ("available OR
    /// already a member"): what the user chose stays visible even when it has gone
    /// quiet.
    ///
    /// `bundleID` is this row's app identity, used ONLY to look up
    /// `AppRoutingController.clearedDeviceRouteTarget(for:)` — the device an
    /// app-quit `resetDeviceRoute` most recently cleared this app FROM, if any
    /// and if not yet consumed. When that remembered target is also in
    /// `available` (present + reachable now), a "Resume → <device name>" entry
    /// is prepended ahead of every other entry — the one-click way back to
    /// where this app was playing before it quit, without reversing the
    /// 2026-07-22 decision that the redirect itself doesn't survive the quit.
    /// Its id carries `resumeDestinationIDPrefix` rather than the plain device
    /// id so it never collides with that same device's own plain entry further
    /// down this same list; `destination(forID:)` strips the prefix back off,
    /// so picking "Resume" reaches `setDestination(.device(id:), for:)` through
    /// the exact same call site an ordinary device pick does.
    func appDestinations(devices: [Device], keeping current: AppRouteDestination,
                                bundleID: String) -> [AppRowView.Destination] {
        let available = availableAirPlayDestinations(devices: devices)
        var entries: [AppRowView.Destination] = []
        if let resume = resumeEntry(for: bundleID, available: available) {
            entries.append(resume)
        }
        entries.append(contentsOf: [
            .init(id: Self.noRedirectDestinationID,
                  title: "Follows main output",
                  isLocal: true,
                  symbolName: nil,
                  isStandalone: true,
                  subtitle: "Plays in the main mix"),
            .init(id: Self.currentDeviceDestinationID,
                  title: currentDeviceTitle(devices: devices),
                  isLocal: true,
                  symbolName: Device.Kind.localMac.symbolName,
                  subtitle: "Plays locally with its own volume"),
        ])
        entries.append(contentsOf: groupDestinations(devices: devices, bundleID: bundleID))
        for device in available {
            // One role per speaker: a device currently in Main Out (Selected
            // Devices, or the active group's members) is carrying the
            // whole-system mix, and a receiver holds ONE AirPlay session — it
            // can't ALSO carry a private per-app redirect. So it's simply not
            // offered as a redirect target; which other device kinds are
            // offered at all is decided by `availableAirPlayDestinations`
            // (`Device.canBePerAppRouteTarget()`). The reverse conflict —
            // selecting a speaker that already has a redirect — is resolved by
            // `AppRoutingController.clearRoutes(toDevices:)` (selection wins), so
            // by the time this renders, no kept route targets a Main Out member.
            // Deliberately NOT filtered inside `availableAirPlayDestinations`:
            // that set also drives R5 disappearance tracking, where a Main Out
            // member must still count as present.
            if groupController?.isMainOutMember(device.id) == true { continue }
            // R3 stopgap: a device already carrying a DIFFERENT app's redirect
            // gets an honest heads-up rather than a silent quality regression —
            // two independently-captured streams mixed onto one speaker warble
            // (`AppRouteMixer`'s multi-contributor path re-grids onto a wall-clock
            // frame index with no fractional interpolation; see the mixer's own
            // comments). Compares by bundleID (not `routedAppNames`' display
            // names) so two apps that happen to share a display name can't hide
            // this row's own route from itself. No engine/routing change — copy
            // only.
            let othersAlreadyRoutedHere = appRouting.appRoutes.contains { other in
                if case .device(let otherID) = other.destination, otherID == device.id,
                   other.bundleID != bundleID { return true }
                return false
            }
            entries.append(.init(id: device.id, title: device.name, isLocal: false,
                                 symbolName: device.symbolName,
                                 subtitle: othersAlreadyRoutedHere ? Self.sameSpeakerQualitySubtitle : nil))
        }
        if case .device(let id) = current,
           !available.contains(where: { $0.id == id }),
           let device = devices.first(where: { $0.id == id && !$0.isLocalDevice }) {
            entries.append(.init(id: device.id, title: device.name, isLocal: false,
                                 symbolName: device.symbolName,
                                 subtitle: Self.offlineDestinationSubtitle))
        }
        return entries
    }

    /// The "Resume → <target>" entry, when this row has one to offer: the
    /// destination an app-quit `resetDeviceRoute` cleared, still pickable now.
    /// A remembered DEVICE has to be available again; a remembered GROUP has to
    /// still exist and still have a speaker free — a group deleted (or emptied)
    /// while the app was away is simply not offered, rather than offered and
    /// then silently doing nothing.
    private func resumeEntry(
        for bundleID: String, available: [Device]
    ) -> AppRowView.Destination? {
        switch appRouting.clearedRouteDestination(for: bundleID) {
        case .device(let deviceID):
            guard let device = available.first(where: { $0.id == deviceID }) else { return nil }
            return .init(id: Self.resumeDestinationID(forDeviceID: device.id),
                         title: "Resume → \(device.name)",
                         isLocal: false,
                         // The DEVICE's resolved glyph, not its kind's: a
                         // pairing that reports headphones must be headphones
                         // here too. `appRowDestinationsDrawTheDevicesResolvedGlyph`
                         // is the guard.
                         symbolName: device.symbolName,
                         isStandalone: true,
                         subtitle: "Return to where this app was playing")
        case .group(let groupID):
            guard let group = groupController?.groups.first(where: { $0.id == groupID }),
                  !usableGroupMemberIDs(group, available: available).isEmpty
            else { return nil }
            return .init(id: Self.resumeDestinationIDPrefix + Self.groupDestinationID(forGroupID: groupID),
                         title: "Resume → \(group.name)",
                         isLocal: false,
                         symbolName: DeviceIcon.resolve(group.iconSymbolName,
                                                        default: Group.defaultIconSymbolName),
                         isStandalone: true,
                         subtitle: "Return to where this app was playing")
        case .noRedirect, .currentDevice, .none:
            return nil
        }
    }

    /// The "Scenes" section of one row's destination popup: EVERY saved
    /// group, each disclosing what picking it would actually do right now.
    /// Mirrors Main Out's own group list (same header, same "→ <name>"
    /// collapsed title). PLAN-POPOVER-ROUTING decision 4, which kept groups out
    /// of this menu, is reversed.
    ///
    /// Unfiltered on purpose. A group the user saved must never look deleted
    /// (`emptyGroupDestinationSubtitle`), so one with nothing free to play on
    /// is listed greyed rather than dropped — and a group with no members at
    /// all can't exist anyway (`GroupController.createGroup`/`saveGroup` both
    /// throw `GroupError.emptyMembership`), so filtering empties out only ever
    /// hid groups that were fine. That filter was the live "my new group isn't
    /// in the per-app menu" report's prime suspect; the actual cause was the
    /// surface not rebuilding on a group change (see `groupsDidChange()`).
    private func groupDestinations(
        devices: [Device], bundleID: String
    ) -> [AppRowView.Destination] {
        guard let controller = groupController else { return [] }
        let available = availableAirPlayDestinations(devices: devices)
        return controller.groups
            .map { group in
                let usable = usableGroupMemberIDs(group, available: available)
                return .init(id: Self.groupDestinationID(forGroupID: group.id),
                             title: group.name,
                             isLocal: false,
                             symbolName: DeviceIcon.resolve(group.iconSymbolName,
                                                            default: Group.defaultIconSymbolName),
                             subtitle: groupDestinationSubtitle(
                                group, usable: usable, bundleID: bundleID),
                             isGroup: true,
                             isEnabled: !usable.isEmpty,
                             buttonTitle: "→ \(group.name)")
            }
    }

    /// The members of `group` that could carry this app's own stream right now:
    /// discovered, reachable, and eligible per
    /// `Device.canBePerAppRouteTarget()` (`available` is already
    /// filtered to that), and not already claimed by the main output (one role
    /// per speaker — the main mix is the senior claim, and the app plays on
    /// whatever is left).
    private func usableGroupMemberIDs(_ group: Group, available: [Device]) -> [String] {
        let availableIDs = Set(available.map(\.id))
        return group.memberIDs.filter {
            availableIDs.contains($0) && groupController?.isMainOutMember($0) != true
        }
    }

    /// A group entry's secondary line — what the user gets if they pick it, in
    /// the order that matters most: nothing to play on, then the main mix having
    /// taken some of it, then speakers being away, then the shared-speaker
    /// quality warning, and otherwise plain size.
    private func groupDestinationSubtitle(
        _ group: Group, usable: [String], bundleID: String
    ) -> String {
        let total = group.memberIDs.count
        guard !usable.isEmpty else { return Self.emptyGroupDestinationSubtitle }
        let claimedByMainOut = group.memberIDs.contains { groupController?.isMainOutMember($0) == true }
        if claimedByMainOut {
            return "Plays on \(usable.count) of \(total), the rest are in the main mix"
        }
        if usable.count < total { return Self.offlineGroupDestinationSubtitle }
        let usableIDs = Set(usable)
        let sharedWithAnotherApp = appRouting.appRoutes.contains { other in
            guard other.bundleID != bundleID else { return false }
            switch other.destination {
            case .device(let id):     return usableIDs.contains(id)
            case .group(let id):      return id == group.id
            default:                  return false
            }
        }
        if sharedWithAnotherApp { return Self.sameSpeakerQualitySubtitle }
        return total == 1 ? "1 speaker" : "\(total) speakers"
    }

    /// The secondary line on a group entry with nothing left to play on — every
    /// member away or already carrying the main mix. The entry stays visible
    /// (greyed) rather than vanishing: a group the user saved should not look
    /// like it was deleted.
    static let emptyGroupDestinationSubtitle = "No speakers available right now"

    /// The secondary line on a group some of whose speakers aren't reachable —
    /// the app will play on the rest.
    static let offlineGroupDestinationSubtitle = "Some speakers are offline"

    /// The secondary line on a kept-but-unreachable redirect target's menu entry
    /// (R5). It has to state the AUDIBLE consequence, not just the device's state:
    /// while the target is unreachable the app is no longer excluded from the
    /// whole-system capture tap, so it plays wherever the Mac's current top-level
    /// selection points — and the redirect resumes on its own once the device is
    /// back, with nothing for the user to re-pick.
    static let offlineDestinationSubtitle = "Offline, playing with system audio"

    /// The secondary line on an AirPlay device entry that already carries a
    /// DIFFERENT app's redirect (R3 stopgap). The real fix — resampling
    /// contributors onto one shared capture clock instead of a wall-clock frame
    /// grid — is a separate, larger follow-up; this is the honest heads-up in the
    /// meantime, not a claim the quality issue is solved.
    static let sameSpeakerQualitySubtitle = "Already in use, may reduce quality"

    /// The available per-app route targets: reachable (`isAvailable`) devices
    /// whose KIND may carry a per-app stream, in the same stable order as the
    /// Selected Devices card. The kind rule lives in
    /// `Device.canBePerAppRouteTarget()`, shared with
    /// `AppRoutingController.resolveGroupTargets(_:devices:)` — this function
    /// adds the reachability filter on top, which the shared predicate
    /// deliberately omits (`resolveGroupTargets` needs an unreachable group
    /// member to survive its own resolve).
    ///
    /// This is what a row may newly be POINTED at; it is not the same question as
    /// what a row may keep SHOWING — a route whose target drops out of this set is
    /// kept and gets an injected offline entry (`appDestinations(devices:keeping:bundleID:)`),
    /// and only an outright disappearance resets it (R5, `update(devices:)`).
    ///
    /// Readers: `appDestinations(devices:keeping:bundleID:)`,
    /// `usableGroupMemberIDs(_:available:)`, `appRow(_:didSelectDestination:for:)`'s
    /// group-analytics count, and `update(devices:)`'s R5 tracking. Widening the
    /// shared predicate therefore also widens which group members an app can
    /// play on, via `usableGroupMemberIDs`.
    func availableAirPlayDestinations(devices: [Device]) -> [Device] {
        devices.filter { $0.isAvailable && $0.canBePerAppRouteTarget() }
    }

    /// Title for the "This Mac" entry — the local device's own name when the
    /// fleet includes it, else a generic fallback so the entry always reads
    /// sensibly (decision 8 — the app plays on this Mac).
    private func currentDeviceTitle(devices: [Device]) -> String {
        devices.first(where: \.isLocalDevice)?.name ?? "This Mac"
    }

    /// Map an `AppRoute.destination` onto the plain-string id `AppRowView` selects
    /// by: one of the two local sentinels for `.noRedirect`/`.currentDevice`, or
    /// the device id for `.device(id:)`.
    func destinationID(for destination: AppRouteDestination) -> String {
        switch destination {
        case .noRedirect:          return Self.noRedirectDestinationID
        case .currentDevice:       return Self.currentDeviceDestinationID
        case .device(let id):      return id
        case .group(let id):       return Self.groupDestinationID(forGroupID: id)
        }
    }

    /// Inverse of `destinationID(for:)`: either local sentinel maps back to its
    /// own case; a "Resume → <device>" id has its prefix stripped back down to
    /// the plain device id it named all along; any other id is already a plain
    /// device id, mapping straight to `.device(id:)`. Picking the "Resume" entry
    /// therefore reaches the exact same `.device(id:)` case — and the exact
    /// same `setDestination` call site — an ordinary device pick does.
    func destination(forID id: String) -> AppRouteDestination {
        if id == Self.noRedirectDestinationID { return .noRedirect }
        if id == Self.currentDeviceDestinationID { return .currentDevice }
        if id.hasPrefix(Self.resumeDestinationIDPrefix) {
            return destination(forID: String(id.dropFirst(Self.resumeDestinationIDPrefix.count)))
        }
        if id.hasPrefix(Self.groupDestinationIDPrefix) {
            return .group(id: String(id.dropFirst(Self.groupDestinationIDPrefix.count)))
        }
        return .device(id: id)
    }

    /// Resolve a routed app's icon lazily (T-8): the injected `runningAppsProvider`
    /// first — the test/harness seam (`popover-harness`/`popover-snapshot` inject
    /// fake apps there; a live lookup ahead of it would put headless runs on the
    /// real workspace) — then `AppIconCache`, which resolves a routed-but-quit
    /// app's real icon from disk/`NSWorkspace` instead of falling straight to the
    /// placeholder below. Only an app `AppIconCache` truly can't find (never
    /// installed, or an invalid bundle id) reaches the generic placeholder. This
    private func appIcon(for bundleID: String) -> NSImage? {
        if let running = runningAppsProvider().first(where: { $0.bundleID == bundleID }),
           let icon = running.icon {
            return icon
        }
        if let cached = AppIconCache.icon(forBundleID: bundleID) {
            return cached
        }
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        return NSImage(systemSymbolName: Self.missingAppIconSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // MARK: Actions

    /// "Save Selected Speakers as scene" is enabled iff there's a controller, the
    /// Selected Devices set is non-empty, and it doesn't already equal a saved
    /// group (SPEC §9 dedup).
    var canSaveCurrentSetup: Bool {
        guard let controller = groupController else { return false }
        guard !controller.selectedDeviceIDs.isEmpty else { return false }
        return controller.group(matchingMemberSet: controller.selectedDeviceIDs) == nil
    }

    /// Save the Selected Devices set as a fresh group, REPORTING a persistence
    /// failure instead of swallowing it (the same "UI never lies" contract
    /// `GroupEditorViewController.saveOrReport` established). The rebuild runs
    /// either way, so on a failure the card goes back to showing the true —
    /// unsaved — state rather than a group that isn't there.
    func saveCurrentSetup() {
        guard let controller = groupController else { return }
        let name = controller.nextDefaultGroupName()
        do {
            _ = try controller.saveCurrentSetupAsGroup(name: name)
            test_saveGroupFailureReported = false
            Analytics.capture("scene:created", ["source": "mixer"])
        } catch {
            test_saveGroupFailureReported = true
            presentSaveGroupFailureAlert()
        }
        rebuild()
    }

    /// A sheet when a window hosts the panel, skipped entirely headless (every
    /// test run — the `test_` flag above observes the failure instead).
    private func presentSaveGroupFailureAlert() {
        guard let window = panel.view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn\u{2019}t save the scene."
        alert.informativeText = "The scene\u{2019}s saved settings couldn\u{2019}t be written."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Try again")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.saveCurrentSetup()
        }
    }

    // MARK: Running-app picker (T-7, PLAN decision 6)

    /// The default `runningAppsProvider`: real `.regular`-activation-policy apps
    /// (Dock-visible, not background/accessory agents) with a non-nil bundle id,
    /// mapped to the plain-value `RunningAppInfo` this controller works with.
    /// `static` (not a stored closure) so it can serve as the init's default
    /// parameter.
    public nonisolated static func defaultRunningAppsProvider() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return RunningAppInfo(bundleID: bundleID,
                                      displayName: app.localizedName ?? bundleID,
                                      icon: app.icon)
            }
    }

    /// The picker's candidate list (PLAN decision 6): every running app from
    /// `runningAppsProvider`, EXCLUDING ones that already have a route (adding a
    /// second route for the same bundle id would collide with `AppRoute`'s
    /// bundle-id identity — `AppRoutingController.addRoute` already no-ops on a
    /// duplicate, but filtering here keeps the menu from offering a dead choice).
    func availableAppsForPicker() -> [RunningAppInfo] {
        let routed = Set(appRouting.appRoutes.map(\.bundleID))
        // Also drop excluded apps (Settings › Audio, "never captured") — routing
        // an app the user has excluded would contradict the exclusion.
        return runningAppsProvider().filter { !routed.contains($0.bundleID) && !isAppExcluded($0.bundleID) }
    }

    /// Add a route for `bundleID`/`displayName` (defaults to `.noRedirect` —
    /// the new neutral/unset state for a newly-added app) and rebuild,
    /// preserving this open's transient collapse state (a plain `rebuild()`,
    /// not `rebuildForOpen()`).
    func pickApp(bundleID: String, displayName: String) {
        Analytics.capture("app_routing:app_added")
        appRouting.addRoute(bundleID: bundleID, displayName: displayName)
        rebuild()
    }

    /// Build and pop up the "+ Add application…" menu at `view` (PLAN decision
    /// 6): one item per available app, icon + `localizedName`-equivalent title.
    /// Already-routed apps are excluded entirely (`availableAppsForPicker`), so
    /// there's nothing to additionally disable. Choosing an item calls
    /// `pickApp`.
    func presentAddApplicationPicker(relativeTo view: NSView) {
        guard !HeadlessRuntime.isActive else { return }
        makeAddApplicationMenu().popUp(positioning: nil,
                                       at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    /// Build the "+ Add application…" menu (C6): one selectable item per available
    /// app, or — when none are available — a single DISABLED "No applications
    /// available" item so the menu is never blank.
    func makeAddApplicationMenu() -> NSMenu {
        let menu = NSMenu()
        let available = availableAppsForPicker()
        guard !available.isEmpty else {
            let item = NSMenuItem(title: "No applications available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }
        for app in available {
            let item = NSMenuItem(title: app.displayName, action: #selector(addApplicationMenuItemSelected(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.image = app.icon
            item.representedObject = app
            menu.addItem(item)
        }
        return menu
    }

    @objc private func addApplicationMenuItemSelected(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? RunningAppInfo else { return }
        pickApp(bundleID: app.bundleID, displayName: app.displayName)
    }

    // MARK: Local-mix block presentation
    //
    // The current-device toggle is disabled (greyed + tooltip) whenever it can't
    // currently be turned ON — so the block is presented BEFORE the click. If a
    // refusal still comes back from the model (belt-and-suspenders), we surface
    // the reason and repaint the row so the switch bounces back.

    func handleSelection(_ result: GroupController.SelectionResult, deviceID: String) {
        if let reason = result.refusalReason {
            test_lastRefusalReason = reason
            presentRefusal(reason)
        } else {
            test_lastRefusalReason = nil
        }
        // Repaint device rows (auto-swap may have flipped the local row; a refusal
        // must bounce the switch back to its real state). Under a group target a
        // membership toggle can also flip the card between the derived-equal and
        // diverging dormant states (S5), which mounts/unmounts the "Inactive"
        // note — the reconciling repaint escalates to a rebuild exactly then.
        refreshDeviceRowsReconcilingCardNote()
        // A deselect may have taken the alignment wizard's target out of the
        // user's audio intent — tear it down now, not on the next snapshot.
        reconcileBTAlignmentNotes(animated: true)
        // An auto-swap does NOT flash the Mac's row (owner's call, live, 2026-09-05:
        // "it quickly flashes on the MacBook before going to the device I just
        // clicked on … same thing when it goes backwards"). The A4 attention
        // pulse is `Tokens.Color.gold`, which everywhere else on this panel
        // means signal — in the mix, carrying audio — so a half-second gold
        // wash over the whole Mac row at the exact moment its membership
        // changes reads as "the Mac just took the audio", the opposite of what
        // happened, in BOTH directions of the swap (`setDeviceSelected` raises
        // `autoSwappedCurrentDevice` for the AirPlay-takes-over case and for
        // the current-device floor that hands the audio back). The checkbox,
        // the node dot and the row's own wash all moved synchronously in the
        // repaint above, so nothing is left unsaid without it.
    }

    private func presentRefusal(_ reason: String) {
        // A lightweight, non-blocking surface: the tooltip already carries the
        // reason on the disabled control; when a refusal reaches here (manual
        // gesture), we log it so the app layer can show it. Kept minimal so the
        // headless harness/tests can assert `test_lastRefusalReason`.
        FileHandle.standardError.write(Data("[Audiout] \(reason)\n".utf8))
    }
}

// MARK: - AppRowView.Delegate (T-8, PLAN §C decisions 3/4/6/8)
//
// Each callback drives the corresponding `AppRoutingController` mutation, then
// the SAME state-preserving `rebuild()` the running-app picker uses (a plain
// `rebuild()`, NOT `rebuildForOpen()`, so this open's transient collapse state
// survives). The panel stays a pure function of controller state — no in-place
// row mutation.

extension PopoverController: AppRowView.Delegate {

    public func appRow(_ row: AppRowView, didSetVolume volume: Int, for appID: String) {
        if volumeAdjustedControls.insert("app").inserted {
            Analytics.capture("mixer:volume_adjusted", ["control": "app"])
        }
        noteSliderGesture()
        // Drive the app's own renderer immediately (low-latency path): a
        // `.currentDevice` local stream, or the leveled intercept.
        // `appRouting.setVolume` fires `onRoutesDidChange` which re-pushes volumes
        // to the mixer/engine — no rebuild needed here; a rebuild would replace
        // the AppRowView mid-drag and break the NSSlider tracking loop.
        onSetLocalPlaybackVolume?(volume, appID)
        appRouting.setVolume(volume, for: appID)
    }

    public func appRow(_ row: AppRowView, didSelectDestination destinationID: String, for appID: String) {
        let mapped = destination(forID: destinationID)
        let destProp: String
        switch mapped {
        case .noRedirect: destProp = "no_redirect"
        case .currentDevice: destProp = "current_device"
        case .device: destProp = "device"
        case .group: destProp = "group"
        }
        appRouting.setDestination(mapped, for: appID)
        // Captured AFTER the mutation: the event means the route was applied,
        // not that a menu item was clicked.
        Analytics.capture("app_routing:destination_selected", ["destination": destProp])
        if case .group(let groupID) = mapped,
           let group = groupController?.groups.first(where: { $0.id == groupID }) {
            // Counts only — never a group or speaker name (PRODUCT.md "Data
            // Collection"). `dropped` is how many of the group's speakers this
            // app does NOT get right now: away, or carrying the main mix.
            let usable = usableGroupMemberIDs(
                group, available: availableAirPlayDestinations(devices: Array(devicesByID.values)))
            Analytics.capture("app_routing:group_selected", [
                "members": String(group.memberIDs.count),
                "dropped": String(group.memberIDs.count - usable.count),
            ])
        }
        rebuild()
    }

    public func appRow(_ row: AppRowView, didRemoveFor appID: String) {
        Analytics.capture("app_routing:app_removed")
        removeApp(bundleID: appID)
    }

    /// T1/T3 selection seam: the row's body (or a right-click) was clicked,
    /// requesting single-selection. The HOST owns `selectedAppBundleID` — set
    /// it and rebuild so `isSelected` is re-pushed into every row (including
    /// the newly-deselected previous selection) and the footer's "−" segment
    /// enables.
    public func appRow(_ row: AppRowView, didRequestSelect appID: String) {
        guard selectedAppBundleID != appID else { return }
        selectedAppBundleID = appID
        rebuild()
    }

    /// V14 host half: ↑/↓ from the selected app row moves the selection to the
    /// previous/next route in `appRoutes` order, clamped at the ends (no wrap).
    /// The move is relative to `appID` (the first responder that fired the key),
    /// so it works even if that's not `selectedAppBundleID`. Repaints via the
    /// same state-preserving `rebuild()` all app-row callbacks use, then promotes
    /// the newly-selected (freshly-recreated) row to first responder so
    /// Delete/↑/↓ keep working — done AFTER the rebuild so it targets the live
    /// row instance. The footer's remove-enabled stays true (selection moved to
    /// another existing route).
    public func appRow(_ row: AppRowView, didRequestMoveSelection direction: AppRowView.MoveDirection,
                       for appID: String) {
        let routes = appRouting.appRoutes
        guard let index = routes.firstIndex(where: { $0.bundleID == appID }) else { return }
        let targetIndex: Int
        switch direction {
        case .up:   targetIndex = index - 1
        case .down: targetIndex = index + 1
        }
        guard routes.indices.contains(targetIndex) else { return }   // clamp at ends
        let newSelection = routes[targetIndex].bundleID
        guard newSelection != selectedAppBundleID else { return }
        selectedAppBundleID = newSelection
        rebuild()   // re-pushes isSelected into every row and syncs the ± footer
        promoteFirstResponder(toAppRow: newSelection)
    }

    /// Make `bundleID`'s (freshly rebuilt) app row the window's first responder so
    /// keyboard removal/movement continues on it. No-op headless (`window == nil`)
    /// or if the row is missing.
    private func promoteFirstResponder(toAppRow bundleID: String) {
        guard let row = appRowsByBundleID[bundleID], let window = row.window else { return }
        window.makeFirstResponder(row)
    }

    // MARK: - App-row selection lifecycle (deselect discipline)
    //
    // App-row selection is TRANSIENT to a single open session and exists only
    // to target the ± footer's "−" (and Delete/Backspace). Two rules keep it
    // from feeling like a permanent, un-clearable state:
    //   1. It resets when the popover closes, so a fresh open never shows a
    //      selection carried over from a previous session.
    //   2. A mouse-down anywhere OUTSIDE an `AppRowView` or the ± footer clears
    //      it — empty space, a device row, the header, etc. all deselect, like
    //      clicking away from a table row.

    /// The host just put the panel on screen. Records visibility (so every
    /// skip-work-while-hidden gate opens), arms the deselect monitor, and turns
    /// the backend's RMS computation on.
    func surfaceDidShow() {
        volumeAdjustedControls.removeAll()
        hostIsShown = true
        installDeselectMonitor()
        onMeteringActiveChange?(true)
    }

    /// **The surface must never close out from under someone typing.**
    ///
    /// Pressing Return in the sync drawer's value field was dismissing the
    /// whole surface and losing the edit (live-reported, repeatedly). Two
    /// separate investigations failed to reproduce it: the field editor
    /// demonstrably consumes Return (proven with real synthesized events in
    /// `SyncValueFieldLiveKeyTests`), nothing in the view tree claims Return as
    /// a key equivalent, and no host window closes on it in a test. The one
    /// thing those tests CANNOT exercise is AppKit's real window/popover key
    /// handling, because the house rule bars putting a window on screen during
    /// `swift test` — so the mechanism lives precisely in the gap the tests
    /// can't reach.
    ///
    /// Rather than keep guessing at it, this closes the hole from the other
    /// end: the host asks before dismissing, and is refused while the field
    /// owns an editing session. Typing a number and pressing Return is the
    /// single most predictable thing a user does with a text box, and it must
    /// never dismiss the surface.
    ///
    /// This cannot strand the user. The edit is committed and first responder
    /// released, so the session ends with the value APPLIED — the refusal is
    /// one-shot by construction, and the very next dismiss request finds no
    /// edit in flight and proceeds. A click OUTSIDE the surface ends editing on
    /// its own before the dismiss is even evaluated, so the ordinary
    /// click-away gesture is untouched.
    ///
    /// Returns `true` when the host may proceed with the dismissal.
    public func surfaceShouldHide() -> Bool {
        guard syncDrawer.isEditingValue else { return true }
        syncDrawer.commitAndEndEditing()
        return false
    }

    /// The host just took the panel off screen. The mirror of
    /// ``surfaceDidShow()``, plus the two things that must not survive a
    /// session: the transient app-row selection, and every meter's last
    /// reading (a reopen must never show a stale bar).
    func surfaceDidHide() {
        hostIsShown = false
        removeDeselectMonitor()
        selectedAppBundleID = nil
        // The live-removal offer never outlives the surface it was made on.
        clearRemovalUndo()
        // Nor does the Cast feed-gain pending fill.
        for timer in castVolumePendingTimers.values { timer.invalidate() }
        castVolumePendingTimers.removeAll()
        castVolumePendingIDs.removeAll()
        for row in deviceRowsByID.values { row.resetLevel() }
        mainOutRow.resetLevel()
        for row in appRowsByBundleID.values { row.resetLevel() }
        onMeteringActiveChange?(false)
        // The align-by-ear tick never outlives the surface that started it
        // (BT-OFFSET-UI click-away). Collapsing the drawer stops the tick on
        // its own; the bare call after it covers a tick with no drawer left.
        closeSyncDrawerIntent()
        unmountSyncDrawer(animated: false)
        setAlignTick(nil)
        // NOT the wizard (W4): its own window is the surface its tick must not
        // outlive, and that window is still on screen. A popover close leaves
        // the run alone. The first-mix CARD's intent survives the close too —
        // the backend's hold does, so the offer remounts on the next open.
        // "+"-menu connect attempts are session-scoped (BT-LIST): `.failed` is
        // sticky and never clears for a paired device, so keeping these would
        // leave a permanent dead row on the next open.
        btConnectAttemptIDs.removeAll()
        // The search grace belongs to an open, like everything else here.
        cancelSpeakerSearchGrace()
        // So does a raised one-time trial banner: it is spent, the host wrote
        // that down when it went up, and the next open must not re-show it.
        raisedTrialBanner = nil
    }

    // MARK: - Live level dispatch (task T5)
    //
    // Fed by the host's per-tick RMS callback, NOT by `update(devices:)` — a
    // level push must never trigger `rebuild()`/`ensureDefaultSelection`, it
    // only forwards to the already-built row views.

    /// Push a live RMS reading for device `id` into its row's meter, and into
    /// the Main Out master meter when `id` is currently selected (Main Out
    /// shares the same level feed as its member device rows, task T4a).
    /// Early-returns while the panel isn't shown — metering only matters
    /// while a user can see it.
    public func updateLevel(_ rms: Float, for id: String) {
        guard isEffectivelyShown else { return }
        dispatchLevel(rms, for: id)
    }

    /// Same dispatch as ``updateLevel(_:for:)`` but WITHOUT the visibility
    /// gate — headless snapshots/tests never actually show the panel.
    public func test_pushLevel(_ rms: Float, for id: String) {
        dispatchLevel(rms, for: id)
    }

    private func dispatchLevel(_ rms: Float, for id: String) {
        deviceRowsByID[id]?.setLevel(rms)
        if groupController?.isSpeakerSelected(id) == true {
            mainOutRow.setLevel(rms)
        }
    }

    /// Push a live RMS reading for the app with `bundleID` into its
    /// Applications-row meter (task T5). Unlike device levels, an app level
    /// never feeds Main Out — Main Out mirrors the SELECTED DEVICE's level,
    /// not any one app's contribution. Early-returns while the panel isn't
    /// shown, mirroring ``updateLevel(_:for:)``.
    public func updateAppLevel(_ rms: Float, for bundleID: String) {
        guard isEffectivelyShown else { return }
        dispatchAppLevel(rms, for: bundleID)
    }

    /// Same dispatch as ``updateAppLevel(_:for:)`` but WITHOUT the visibility
    /// gate — headless snapshots/tests never actually show the panel.
    public func test_pushAppLevel(_ rms: Float, for bundleID: String) {
        dispatchAppLevel(rms, for: bundleID)
    }

    private func dispatchAppLevel(_ rms: Float, for bundleID: String) {
        appRowsByBundleID[bundleID]?.setLevel(rms)
    }

    private func installDeselectMonitor() {
        removeDeselectMonitor()
        deselectClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.deselectIfClickOutsideSelectedRow(event)
            return event
        }
    }

    private func removeDeselectMonitor() {
        if let monitor = deselectClickMonitor {
            NSEvent.removeMonitor(monitor)
            deselectClickMonitor = nil
        }
    }

    /// Clears the app-row selection when `event` is a click that is neither on
    /// an `AppRowView` (which selects it) nor on the ± footer (whose "−"/"+"
    /// must see the selection intact). The rebuild is deferred to the next
    /// runloop tick so the click still reaches its target view first — a
    /// synchronous rebuild here would destroy the very view being clicked.
    private func deselectIfClickOutsideSelectedRow(_ event: NSEvent) {
        guard selectedAppBundleID != nil,
              let window = panel.view.window,
              event.window === window else { return }
        let hit = window.contentView?.hitTest(event.locationInWindow)
        if let hit,
           enclosingView(of: hit, ofType: AppRowView.self) != nil
               || enclosingView(of: hit, ofType: CardFooterView.self) === applicationsFooter {
            return
        }
        selectedAppBundleID = nil
        DispatchQueue.main.async { [weak self] in self?.rebuild() }
    }

    private func enclosingView<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        var current: NSView? = view
        while let node = current {
            if let match = node as? T { return match }
            current = node.superview
        }
        return nil
    }

    /// Test hook: clear the app-row selection as an outside click would.
    public func test_deselectApp() {
        selectedAppBundleID = nil
        rebuild()
    }

    /// The set of bundle IDs currently tracked as offline (T4). Lets tests assert
    /// that `applyRoutedAppRunning` updated the tracking set correctly.
    public var test_offlineBundleIDs: Set<String> { offlineBundleIDs }

    /// Whether `bundleID`'s row is currently showing the offline badge (T4).
    /// `nil` if no such row exists in the Applications card.
    public func test_isAppRowOffline(bundleID: String) -> Bool? {
        appRowsByBundleID[bundleID]?.test_isOfflineBadgeVisible
    }
}
