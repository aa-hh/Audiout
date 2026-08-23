// SPDX-License-Identifier: GPL-2.0-or-later
//
// popover-harness — programmatic verification for the popover (SPEC §9 2026-07-14b
// — SoundSource-inspired Main Out model).
//
// The popover isn't visible to an agent shell, so this instantiates the real
// `PopoverController` with a MockBackend-backed `GroupController`, drives the same
// code paths the row-view actions call (via the `test_*` hooks), and asserts:
// a Main Out selector with two sections (Selected Devices + groups); selecting a
// group routes (backend output set = members); toggles compose the Selected
// Devices set without routing when the target is a group; selecting Selected
// Devices applies the toggled set; the local-device auto-swap + mix block; the
// Main Out master = the current target's master; and (T-9) the Applications
// card: present and rendered LAST, collapsed-by-default with zero routes,
// expanded after seeding a route + a reopen-style rebuild, correct row
// count/config, the destination popup's exact two sections, the ± footer's
// add (picker hook mounts a row) and remove paths, and removing the last
// route resets the card back to empty. Prints PASS/FAIL; exits
// nonzero on failure so it can gate CI alongside `swift test`.

import AppKit
import AudiouterCore
import AudiouterPopoverUI

final class Checks {
    private(set) var failures = 0
    private(set) var total = 0
    func expect(_ condition: Bool, _ message: String) {
        total += 1
        if condition { print("  PASS  \(message)") }
        else { failures += 1; print("  FAIL  \(message)") }
    }
    func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
        expect(a == b, "\(message) (got \(a), expected \(b))")
    }
}

@MainActor
func waitForFleet(_ backend: MockBackend, count: Int, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while backend.devices.count < count && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return backend.devices.count >= count
}

@MainActor
func drain(_ interval: TimeInterval = 0.2) {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
}

// MARK: - Card-order introspection (T-9)
//
// `PopoverController` exposes the assembled panel view via `test_panelView`
// but no direct "list of card titles in order" hook. The cards live in the
// panel's top-level vertical `NSStackView`; each card's own header row carries
// an `NSTextField` whose `stringValue` is the section title (e.g.
// "Applications"). Walking the view tree this way stays entirely within the
// already-public `test_panelView` surface — no PopoverController/panel
// changes needed for T-9.

/// Every label-ish string found anywhere under `view` (depth-first, in
/// visual/subview order) — `NSTextField.stringValue` (card/section titles) and
/// `NSButton.title` (the borderless "Add application…" row, which is a
/// titled button rather than a text field).
func allLabelStrings(under view: NSView) -> [String] {
    var result: [String] = []
    if let field = view as? NSTextField { result.append(field.stringValue) }
    if let button = view as? NSButton, !button.title.isEmpty { result.append(button.title) }
    for sub in view.subviews { result.append(contentsOf: allLabelStrings(under: sub)) }
    return result
}

/// The top-level card containers directly under `panelView`: the CARD stack's
/// arranged subviews (one per `beginCard` call), in the order they were added
/// — i.e. rendering top-to-bottom.
///
/// Matched by class name (`RailStackView`, the panel's card stack) rather
/// than "first `NSStackView` found": since U3 the header strip contains its
/// own stack views (the switcher's tab row), and a first-stack walk finds one
/// of those instead — the type is internal to `AudiouterPopoverUI`, and the
/// name check keeps this tool on the public `test_panelView` surface.
func topLevelCards(panelView: NSView) -> [NSView] {
    func cardStack(under view: NSView) -> NSStackView? {
        if let stack = view as? NSStackView,
           String(describing: type(of: stack)) == "RailStackView" { return stack }
        for sub in view.subviews {
            if let found = cardStack(under: sub) { return found }
        }
        return nil
    }
    guard let stack = cardStack(under: panelView) else { return [] }
    return stack.arrangedSubviews
}

/// The index of the card whose header title is `title` among `topLevelCards`,
/// found by checking each card's own labels for a case-insensitive match — the
/// section header now DISPLAYS uppercased (Warm Signal §5.1 silkscreen) while
/// the lookup title is title-case. `nil` if no card carries that title.
func cardIndex(titled title: String, in cards: [NSView]) -> Int? {
    cards.firstIndex { card in
        allLabelStrings(under: card).contains { $0.caseInsensitiveCompare(title) == .orderedSame }
    }
}

@MainActor
func run() -> Int32 {
    // Never show a real window on the developer's screen while this
    // headless tool runs (`HeadlessRuntime` in AudiouterCore) — set BEFORE
    // touching AppKit.
    setenv("AIRPLAY_HEADLESS", "1", 1)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let checks = Checks()

    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend, store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    // Construct PopoverController with AppRoutingController backed by a temp-directory
    // AppRouteStore (T-11), so the harness never touches real Application Support.
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    let popover = PopoverController(appRouting: appRouting)
    // A closed popover deliberately never rebuilds on `update(devices:)`
    // (audit B8); the harness has no real open, so opt into the shown-repaint
    // path via the designated headless hook.
    popover.test_isShownOverride = true

    backend.start()
    guard waitForFleet(backend, count: 7) else {
        print("SETUP FAIL: fleet did not fully discover"); return 2
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()          // default: current device selected
    popover.update(devices: backend.devices)

    // --- 1. Baseline: Main Out row present; device rows for all 7; default passthrough.
    print("\n[1] Baseline — Main Out row + Selected Devices section + default passthrough")
    checks.expectEqual(popover.test_deviceSectionRowCount, 7, "all 7 devices get a row")
    checks.expect(controller.isSpeakerSelected("local-mac"), "default: current device selected")
    checks.expect(controller.isPassthrough, "default state is passthrough (set == {local})")
    checks.expectEqual(controller.groups.count, 0, "no groups yet")

    // --- 2. Main Out selector: two sections (Selected Devices + groups after save).
    print("\n[2] Main Out selector sections")
    checks.expect(popover.test_mainOutRow.test_selectableTargets.contains(.selectedDevices),
                  "selector offers Selected Devices")
    // Decision m: the entry title is clean — no live "(n)" count.
    checks.expect(popover.test_mainOutRow.test_optionTitles.contains("Selected Devices"),
                  "selector has a Selected Devices entry")

    // --- 3. Auto-swap: toggling an AirPlay device ON while local is sole member drops local.
    print("\n[3] Auto-swap (AirPlay ON while current device is sole member)")
    let swap = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
    drain()
    checks.expect(swap.autoSwappedCurrentDevice, "auto-swap fired")
    checks.expect(!controller.isSpeakerSelected("local-mac"), "current device auto-untoggled")
    checks.expect(controller.isSpeakerSelected("office"), "AirPlay device now selected")
    checks.expect(!controller.isPassthrough, "no longer passthrough")

    // --- 4. Auto-swap does NOT fire when local is not the sole member.
    print("\n[4] Auto-swap does not fire otherwise")
    let noSwap = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
    drain()
    checks.expect(!noSwap.autoSwappedCurrentDevice, "no auto-swap (local wasn't a member)")
    checks.expect(controller.isSpeakerSelected("office") && controller.isSpeakerSelected("homepod-bed"),
                  "both AirPlay devices selected")

    // --- 5. T-GROUPCTL (Q5): re-adding the current device into a mixed set is now allowed.
    print("\n[5] Local may join a mixed set")
    checks.expect(controller.canSelectLocalSpeaker("local-mac"),
                  "local can now join the mixed set")
    let rejoin = popover.test_toggleDeviceEnabled(deviceID: "local-mac", on: true)
    drain()
    checks.expect(rejoin.applied, "adding local to a mixed set is allowed")
    checks.expect(rejoin.refusalReason == nil, "no refusal")
    checks.expect(controller.isSpeakerSelected("local-mac"), "local joined")
    checks.expect(controller.isSpeakerSelected("office") && controller.isSpeakerSelected("homepod-bed"),
                  "AirPlay members stay — nothing dropped")

    // --- 6. Toggles compose the set WITHOUT routing when target is a group.
    print("\n[6] Toggles compose without routing when Main Out targets a group")
    // Save the current Selected Devices as a group, point Main Out at it.
    popover.test_saveCurrentSetup(); drain()
    checks.expectEqual(controller.groups.count, 1, "one group saved from Selected Devices")
    let group = controller.groups[0]
    popover.test_selectMainOut(.group(id: group.id)); drain()
    let outputBefore = Set(backend.devices.filter(\.isSelected).map(\.id))
    // Toggle a new device into Selected Devices — must NOT change the routed set.
    _ = popover.test_toggleDeviceEnabled(deviceID: "sonos-move-2", on: true); drain()
    let outputAfter = Set(backend.devices.filter(\.isSelected).map(\.id))
    checks.expectEqual(outputBefore, outputAfter,
                       "composing the set didn't re-route (target is a group)")
    checks.expect(controller.isSpeakerSelected("sonos-move-2"), "but the set was composed")

    // --- 7. Selecting a group routes: backend output set == members.
    print("\n[7] Selecting a group routes to its members")
    // The local Mac is never part of the BACKEND output set (AudiouterCore/AGENTS.md
    // — it is filtered out of `setOutputSet`; the synced local sink carries it
    // instead). Section 5 put `local-mac` into the set this group was saved from, so
    // the routed set is the group's AirPlay members, not its whole membership.
    let expectedGroupRouted = Set(group.memberIDs.filter { id in
        backend.devices.first { $0.id == id }?.isLocalDevice == false
    })
    checks.expectEqual(Set(backend.devices.filter(\.isSelected).map(\.id)), expectedGroupRouted,
                       "output set equals the group's AirPlay members")
    checks.expectEqual(controller.activeGroupID, group.id, "group is the active target")

    // --- 8. Selecting Selected Devices applies the composed set.
    print("\n[8] Selecting Selected Devices applies the composed set")
    popover.test_selectMainOut(.selectedDevices); drain()
    let routed = Set(backend.devices.filter(\.isSelected).map(\.id))
    // Local device is never a backend output; expected routed = AirPlay members of the set.
    let expectedRouted = Set(controller.selectedDeviceIDs.filter { id in
        backend.devices.first { $0.id == id }?.isLocalDevice == false
    })
    checks.expectEqual(routed, expectedRouted, "Selected Devices routes its AirPlay members")

    // --- 9. Main Out master is a GAIN, independent of every member's own level.
    print("\n[9] Main Out master gain is independent of member volumes")
    checks.expectEqual(popover.test_mainOutRow.test_masterValue, controller.mainOutMasterVolume,
                       "Main Out slider shows the current master gain")
    // Move Main Out and confirm members do NOT follow. Main used to be a
    // proportional master that rewrote every member's volume from a ratio
    // snapshot; it is now a stored gain multiplied in at the write boundary, so a
    // member's own level must survive a master move untouched. That independence
    // is the entire point of the refactor, so assert it directly.
    let members = Array(controller.selectedDeviceIDs).filter { id in
        backend.devices.first { $0.id == id }?.isLocalDevice == false
    }
    if members.count >= 1 {
        backend.setVolume(40, for: members[0]); drain()
        popover.test_dragMainOutMaster(to: 80); drain()
        checks.expectEqual(backend.devices.first { $0.id == members[0] }?.volume ?? 0, 40,
                           "member's own volume is unchanged by a Main Out master move")
        checks.expectEqual(controller.mainOutMasterVolume, 80,
                           "Main Out master gain equals the value it was set to")
    }

    // --- 10. Mute (secondary) drives volume to 0 and restores.
    print("\n[10] Mute (secondary)")
    let target = group.memberIDs.first { id in
        backend.devices.first { $0.id == id }?.isLocalDevice == false
    } ?? group.memberIDs[0]
    let volBefore = backend.devices.first { $0.id == target }?.volume ?? -1
    if volBefore > 0 {
        popover.test_toggleMute(deviceID: target, muted: true); drain()
        checks.expectEqual(backend.devices.first { $0.id == target }?.volume, 0, "mute → volume 0")
        popover.test_toggleMute(deviceID: target, muted: false); drain()
        checks.expectEqual(backend.devices.first { $0.id == target }?.volume, volBefore, "unmute restores")
    }

    // --- 11. Toolbar-era panel: the switcher moved to the surface window's
    // native toolbar (live-review D1), so the panel is pure content — its
    // stack starts at the resting inset until a surface seats it.
    print("\n[11] Panel content inset (toolbar-era header)")
    checks.expectEqual(popover.test_panelContentTopInset, 0,
                       "unclaimed panel carries no surface chrome inset")

    // --- 12. A Selected-Devices row shows its on/off toggle. "airport-mixer" is
    // discovered but never grouped here.
    print("\n[12] Selected-Devices row shows its toggle")
    if let selRow = popover.test_deviceRow(for: "airport-mixer") {
        checks.expect(selRow.test_showsToggle, "a Selected-Devices row shows its toggle")
    } else {
        checks.expect(false, "the Selected-Devices row for airport-mixer exists")
    }

    // --- 13. Main Out named dropdown reflects the current target's title (task B).
    print("\n[13] Main Out named dropdown")
    popover.test_selectMainOut(.selectedDevices); drain()
    // Decision m: the title is clean — no live "(n)" count.
    checks.expectEqual(popover.test_mainOutRow.test_selectedTitle, "Selected Devices",
                       "the Main Out dropdown shows the current target's name")
    popover.test_selectMainOut(.group(id: group.id)); drain()
    checks.expectEqual(popover.test_mainOutRow.test_selectedTitle, group.name,
                       "selecting a group updates the named dropdown to the group name")

    // --- 14. Applications card: present, last, collapsed with zero routes.
    print("\n[14] Applications card — present + last + collapsed by default")
    checks.expect(popover.test_isCardCollapsed(title: "App Exceptions") != nil,
                  "Applications card exists")
    checks.expectEqual(popover.test_isCardCollapsed(title: "App Exceptions"), true,
                       "Applications card is collapsed with zero routes")
    checks.expectEqual(popover.test_appRowCount, 0, "no app rows with zero routes")
    let cardsBeforeRoute = topLevelCards(panelView: popover.test_panelView)
    checks.expectEqual(cardIndex(titled: "App Exceptions", in: cardsBeforeRoute),
                       cardsBeforeRoute.count - 1,
                       "Applications card renders LAST")

    // --- 15. Seeding a route + reopen-style rebuild expands the card.
    print("\n[15] Seeding a route expands the card on reopen")
    let musicBundleID = "com.apple.Music"
    // One role per speaker: a device already in Main Out is NOT offered as a
    // redirect target, and a route pointing at one is cleared by
    // `AppRoutingController.clearRoutes(toDevices:)` the moment it's selected
    // (AppDelegate wires that; the harness doesn't stand up AppDelegate). Sections
    // 5-8 left `office` in Main Out, so seeding a route to it would build a state
    // the real app resolves away — and the row would honestly render "no redirect"
    // because its target is missing from its own menu. Redirect to a speaker that
    // is NOT in Main Out, which is the only state this row can actually be in.
    let musicDestinationID = "appletv-lr"
    appRouting.addRoute(bundleID: musicBundleID, displayName: "Music")
    appRouting.setDestination(.device(id: musicDestinationID), for: musicBundleID)
    popover.test_simulateOpen()   // reopen-style rebuild (T-5 recomputes defaults)
    checks.expectEqual(popover.test_isCardCollapsed(title: "App Exceptions"), false,
                       "Applications card is expanded once a route is redirected")
    checks.expectEqual(popover.test_appRowCount, 1, "one app row mounted for the seeded route")

    // --- 16. The app row's config: destination + slider state.
    print("\n[16] Seeded app row config")
    checks.expectEqual(popover.test_appRowBundleIDs(), [musicBundleID],
                       "row order matches appRoutes order")
    checks.expectEqual(popover.test_appRowSelectedDestinationID(for: musicBundleID), musicDestinationID,
                       "row shows the redirected destination")
    checks.expectEqual(popover.test_appRowSliderDimmed(for: musicBundleID), false,
                       "slider is live (not dimmed) while redirected to an AirPlay device")
    if let row = popover.test_appRow(for: musicBundleID) {
        checks.expectEqual(row.test_volume, 100, "seeded route's default volume is 100")
    } else {
        checks.expect(false, "the seeded app row exists")
    }

    // --- 17. Destination menu has exactly the two sections.
    print("\n[17] Destination menu sections")
    if let titles = popover.test_appRowDestinationTitles(for: musicBundleID) {
        checks.expect(titles.contains("Current Device"), "menu has a Current Device section")
        checks.expect(titles.contains("AirPlay Devices"), "menu has an AirPlay Devices section")
        // Headers are sentence-case now (One Case rule), so an all-caps scan
        // can't spot a leaked section — name the one that must not appear.
        checks.expect(!titles.contains { $0.localizedCaseInsensitiveContains("group") },
                      "no extra section headers (e.g. a Groups section) leaked in")
    } else {
        checks.expect(false, "the seeded app row's destination menu exists")
    }

    // --- 18. ± footer present; picking an app via the picker hook adds a row.
    print("\n[18] Applications ± footer present; picker hook adds a row")
    checks.expect(!popover.test_applicationsFooterRemoveEnabled,
                  "the − segment starts disabled with nothing selected")
    let safariBundleID = "com.apple.Safari"
    let runningApps = [RunningAppInfo(bundleID: safariBundleID, displayName: "Safari", icon: nil)]
    let pickerPopover = PopoverController(appRouting: appRouting, runningAppsProvider: { runningApps })
    pickerPopover.configure(groupController: controller)
    pickerPopover.update(devices: backend.devices)
    pickerPopover.test_pickApp(bundleID: safariBundleID)
    checks.expectEqual(pickerPopover.test_appRowCount, 2, "picking an app mounts a second row")
    checks.expect(pickerPopover.test_appRow(for: safariBundleID) != nil,
                  "the picked app's row is mounted under its bundle id")

    // --- 19. Selecting a row enables the − segment; the ± footer's "−" removes
    // the selected app and advances selection to the neighbor.
    print("\n[19] Row selection + ± footer remove")
    checks.expectEqual(pickerPopover.test_selectedAppBundleID, nil, "nothing selected initially")
    pickerPopover.test_selectAppRow(bundleID: musicBundleID)
    checks.expectEqual(pickerPopover.test_selectedAppBundleID, musicBundleID,
                       "selecting a row records it as the host's selection")
    checks.expect(pickerPopover.test_applicationsFooterRemoveEnabled,
                  "the − segment is enabled once a row is selected")
    pickerPopover.test_tapApplicationsFooterRemove()
    checks.expectEqual(pickerPopover.test_appRowCount, 1, "the − segment removed the selected app")
    checks.expect(pickerPopover.test_appRow(for: musicBundleID) == nil, "Music's row is gone")
    checks.expectEqual(pickerPopover.test_selectedAppBundleID, safariBundleID,
                       "selection advanced to the remaining neighbor")

    // --- 20. Removing a route (via a row's own remove path) resets the card.
    print("\n[20] Removing a route resets the card")
    if let safariRow = pickerPopover.test_appRow(for: safariBundleID) {
        safariRow.test_remove()
    }
    checks.expectEqual(pickerPopover.test_appRowCount, 0, "removing Safari leaves the card empty")
    appRouting.removeRoute(bundleID: musicBundleID)
    popover.test_simulateOpen()
    checks.expectEqual(popover.test_appRowCount, 0, "removing the last route empties the card")
    checks.expectEqual(popover.test_isCardCollapsed(title: "App Exceptions"), true,
                       "the card collapses again once no app is redirected")

    // --- 21. Membership bus (Warm Signal v3 §4, S-BUS): the origin stub on the
    // Audio Out row, node fill ↦ membership, the distinct blocked node, one
    // fixed node column with zero layout shift across toggles (R7), the single
    // terminating node, and the dormant de-emphasis under a group target.
    print("\n[21] Membership bus — origin + nodes + fixed column + terminator")
    // Section 13 left Main Out on the saved group while section 6 had toggled
    // sonos-move-2 into the checked set — checked ≠ group members, so the card
    // is GENUINELY DIVERGED (spec §4.7 FINAL, S5) and the bus renders dormant.
    checks.expect(popover.test_mainOutRow.test_busOriginDimmed,
                  "the bus origin stub dims while the checked set diverges from the group target")
    popover.test_selectMainOut(.selectedDevices); drain()
    checks.expectEqual(popover.test_mainOutRow.test_busOriginNode, .origin,
                       "the Audio Out row launches the bus out of its dropdown column")
    checks.expect(!popover.test_mainOutRow.test_busOriginDimmed,
                  "the origin recovers full ink under Selected Devices")
    checks.expectEqual(popover.test_deviceRow(for: "office")?.test_busNode, .member,
                       "a tapped-in device's node is FILLED on the line")
    checks.expectEqual(popover.test_deviceRow(for: "airport-mixer")?.test_busNode, .nonMember,
                       "an untapped device's node is HOLLOW — the line detours it")
    // T-UI-ALLOW / T-GROUPCTL Q5 retired the Phase-1 local-mix block: the Mac may
    // join a mixed set (the synced local sink carries it), so `PopoverController`
    // never passes `blocked:` to a row and the §4.6 greyed node is unreachable
    // here. The Mac now sits on the spine as an ordinary member like any speaker.
    checks.expectEqual(popover.test_deviceRow(for: "local-mac")?.test_busNode, .member,
                       "the Mac joined the mix and renders an ordinary member node (T-UI-ALLOW)")
    let officeX = popover.test_deviceRow(for: "office")?.test_busNodeCenterX() ?? -1
    let mixerX = popover.test_deviceRow(for: "airport-mixer")?.test_busNodeCenterX() ?? -2
    checks.expect(abs(officeX - mixerX) < 0.5, "every node sits at one fixed column x")
    _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false); drain()
    checks.expectEqual(popover.test_deviceRow(for: "office")?.test_busNode, .nonMember,
                       "toggling out hollows the node")
    let officeXAfter = popover.test_deviceRow(for: "office")?.test_busNodeCenterX() ?? -3
    checks.expect(abs(officeXAfter - officeX) < 0.001,
                  "…with zero layout shift — only fill and line path changed (R7)")
    let nodes = backend.devices.compactMap {
        popover.test_deviceRow(for: $0.id)?.test_busNode
    }
    checks.expectEqual(nodes.count, backend.devices.count,
                       "every device row carries a bus node")
    // The channel spans the FULL band — every device row is a stop on it — while
    // the SIGNAL inside it stops at the lowest member, and nothing below that is
    // a member.
    if let plan = popover.test_railPlan() {
        checks.expectEqual(plan.stops.count, nodes.count,
                           "every device node is a stop on the full-band rail")
        if let terminus = plan.signalTerminusIndex {
            checks.expectEqual(plan.stops[terminus].node, .member,
                               "the signal ends ON a member node")
            checks.expect(!plan.stops.dropFirst(terminus + 1).contains { $0.node == .member },
                          "nothing below the signal's end is a member (spec v4 §Call-1)")
        } else {
            checks.expect(false, "with devices in the mix the signal must reach one")
        }
    } else {
        checks.expect(false, "the rail resolves a plan from the laid-out popover")
    }

    // --- 22. Connection-status flow (brief §7.3), on a scripted MockBackend:
    // fail → membership KEPT (R12) + warning + auto-expanded panel; sticky
    // warning survives the cleanup setOutputSet; "Try again" → connected + panel
    // gone.
    print("\n[22] Connection-status flow (scripted MockBackend)")
    runConnectionStatusChecks(checks)

    // --- 23. FEED column (Warm Signal v4.1 item 3): the multi-source
    // composite, the manual-vs-group wording, the failure-red override, and
    // that the sublabel carries no words on a bus row anymore.
    print("\n[23] FEED column")
    runFeedColumnChecks(checks)

    print("\n----------------------------------------")
    if checks.failures == 0 {
        print("PASS: all \(checks.total) popover-structure checks passed")
        return 0
    } else {
        print("FAIL: \(checks.failures)/\(checks.total) popover-structure checks failed")
        return 1
    }
}

/// Drive the full §7.3 failure → retry flow against a fresh popover whose
/// MockBackend scripts `office` to fail once (not responding, with a raw
/// detail line) and connect on the second attempt. The harness stands in for
/// AppDelegate's event loop by pushing `backend.devices` snapshots into
/// `popover.update` after each choreography step.
@MainActor
func runConnectionStatusChecks(_ checks: Checks) {
    let backend = MockBackend(
        fleet: .demoFleet, staggerDiscovery: false,
        emitsLevels: false, simulatesDropouts: false,
        connectScripts: [
            "office": ConnectScript(attempts: [
                .fail(after: 0.2, ConnectionFailure(cause: .notResponding, detail: "raw engine log line")),
                .connect(after: 0.2),
            ]),
        ])
    let controller = GroupController(backend: backend, store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let popover = PopoverController()
    // A closed popover deliberately never rebuilds on `update(devices:)`
    // (audit B8); the harness has no real open, so opt into the shown-repaint
    // path via the designated headless hook.
    popover.test_isShownOverride = true

    backend.start()
    guard waitForFleet(backend, count: 7) else {
        checks.expect(false, "scripted fleet discovered"); return
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()
    popover.update(devices: backend.devices)

    /// Poll `office`'s connection state until `predicate` holds (bounded).
    func waitForOffice(_ what: String, timeout: TimeInterval = 3,
                       _ predicate: (ConnectionState) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let device = backend.devices.first(where: { $0.id == "office" }),
               predicate(device.connectionState) { return true }
            drain(0.02)
        }
        checks.expect(false, "office reached \(what) in time")
        return false
    }
    func officeIsFailed(_ state: ConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    // Enable → scripted first attempt fails.
    _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
    checks.expect(controller.isSpeakerSelected("office"), "toggle composed membership")
    guard waitForOffice(".failed", officeIsFailed) else { return }
    popover.update(devices: backend.devices)

    // R12 (AudiouterPopoverUI/AGENTS.md, W2-T3 — "keep intent, always"): a failure
    // no longer drops the device from Selected Devices. The user asked for this
    // speaker, and it stays asked-for — the failure is REPORTED (ring + diagnosis
    // panel below) while the backend keeps auto-reconnecting. So membership and the
    // switch both hold their ON state; only the status rendering changes.
    checks.expect(controller.isSpeakerSelected("office"),
                  "failure kept the membership the user asked for (R12)")
    checks.expect(popover.test_deviceRow(for: "office")?.test_isEnabledOn == true,
                  "row switch stays ON through the failure (R12)")
    checks.expect(popover.test_deviceRow(for: "office")?.test_statusKind == .failed,
                  "the failed halo ring is shown")
    let panel = popover.test_diagnosisPanel(for: "office")
    checks.expect(panel != nil, "diagnosis panel auto-expanded on failure")
    checks.expectEqual(panel?.test_headlineText ?? "", "Didn't respond",
                       "panel renders the failure headline")
    checks.expect(panel?.test_copyDetailsEnabled == true,
                  "Copy details enabled (detail present)")

    // Sticky warning: the failure episode's cleanup setOutputSet runs without the
    // id; the backend keeps .failed and the popover keeps the warning + panel.
    drain(0.3)
    popover.update(devices: backend.devices)
    checks.expect(officeIsFailed(backend.devices.first { $0.id == "office" }?.connectionState ?? .off),
                  "backend kept .failed sticky through the cleanup setOutputSet")
    checks.expect(popover.test_deviceRow(for: "office")?.test_statusKind == .failed,
                  "the failed ring survived the cleanup setOutputSet")
    checks.expect(popover.test_diagnosisPanel(for: "office") != nil,
                  "panel survived the cleanup setOutputSet")

    // "Try again" → second scripted attempt connects.
    popover.test_tapRetry(for: "office")
    checks.expect(controller.isSpeakerSelected("office"), "retry re-added membership")
    guard waitForOffice(".connected", { $0 == .connected }) else { return }
    popover.update(devices: backend.devices)

    checks.expect(popover.test_deviceRow(for: "office")?.test_statusKind == .connected,
                  "retry succeeded: the connected ring is shown")
    checks.expect(popover.test_deviceRow(for: "office")?.test_isEnabledOn == true,
                  "the honest toggle now rests ON")
    checks.expect(popover.test_diagnosisPanel(for: "office") == nil,
                  "connected cleared the diagnosis panel")
}

/// Drive the FEED column (Warm Signal v4.1 item 3) against a fresh, fully
/// isolated popover — the existing numbered checks above interleave Main Out
/// target/membership state too tightly to reuse for this without disturbing
/// their own assertions, so this stands up its own backend/controller exactly
/// like `runConnectionStatusChecks` does for the connection-status flow.
@MainActor
func runFeedColumnChecks(_ checks: Checks) {
    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend, store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let appRouting = AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                         loadPersisted: false)
    let musicBundleID = "com.apple.Music"
    appRouting.addRoute(bundleID: musicBundleID, displayName: "Music")
    appRouting.setDestination(.device(id: "office"), for: musicBundleID)

    let popover = PopoverController(appRouting: appRouting)
    popover.test_isShownOverride = true
    backend.start()
    guard waitForFleet(backend, count: 7) else {
        checks.expect(false, "FEED-check fleet discovered"); return
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()

    // Manual membership + one app redirect → "System · Music".
    _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
    popover.update(devices: backend.devices)
    checks.expectEqual(popover.test_deviceRow(for: "office")?.test_feedText, "System · Music",
                       "a manual member with a redirect shows the multi-source composite")
    checks.expect(popover.test_deviceRow(for: "office")?.test_statusText == nil,
                  "the sublabel carries no words — the feed moved to its own column")

    // App-only redirect, device NOT in the mix → bare app name, no "System".
    checks.expectEqual(popover.test_deviceRow(for: "homepod-bed")?.test_feedText, nil,
                       "an uninvolved device shows nothing in its FEED column")

    // Group target: the neutral segment's WORD switches to the group's name.
    _ = popover.test_saveCurrentSetup()
    guard let group = controller.groups.first else {
        checks.expect(false, "FEED-check group saved"); return
    }
    popover.test_selectMainOut(.group(id: group.id))
    popover.update(devices: backend.devices)
    checks.expectEqual(popover.test_deviceRow(for: "office")?.test_feedText, "\(group.name) · Music",
                       "a group-target member shows the GROUP NAME instead of System")

    // Failure overrides the composite entirely.
    var devices = backend.devices
    if let idx = devices.firstIndex(where: { $0.id == "office" }) {
        devices[idx].connectionState = .failed(.init(cause: .notResponding))
    }
    popover.update(devices: devices)
    checks.expectEqual(popover.test_deviceRow(for: "office")?.test_feedText, "Didn't respond",
                       "a failed device's FEED column shows the failure-red headline override, not the composite")
}

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("popover-harness-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

exit(MainActor.assumeIsolated { run() })
