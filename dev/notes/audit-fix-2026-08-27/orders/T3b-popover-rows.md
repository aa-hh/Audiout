# T3b — Popover row components + diagnosis panel

## Header

**Branch:** `claude/fix-popover-rows`, forked from `7886f98d` (repo HEAD, working tree clean — no uncommitted work to carry).
```bash
cd "/Users/alechenderson/Projects/AirPlay Controller"
git worktree add .claude/worktrees/fix-popover-rows -b claude/fix-popover-rows
cd .claude/worktrees/fix-popover-rows
git config core.hooksPath .githooks
git push -u origin claude/fix-popover-rows
```
Read `AGENTS.md`, `AudioutCore/AGENTS.md`, `AudioutCore/Sources/AudioutSharedUI/AGENTS.md`, `AudioutCore/Sources/AudioutPopoverUI/AGENTS.md` before editing.

**BINDING BUILD/TEST RULE:** every compile is `bash scripts/build.sh`; every test run is `bash scripts/run-tests.sh --filter <Suites>` (full suite only for the final check). Invoking the Swift toolchain's own test/build commands directly is FORBIDDEN — the wrappers route to the remote test mule, the machine-wide concurrency cap, and the sources cache; the bare commands opt out of all three and pin work to the machine running many parallel agents. `AUDIOUT_BUILD_LOCAL=1` only if the mule is unreachable, and say so. Never pipe `run-tests.sh` into `tail` (it eats the exit code — read full output or redirect to a file and check `$?`). Never kill or abandon an in-flight remote test run (orphaned legs pin the build lock).

**Owned files** (all under `AudioutCore/`):
- `Sources/AudioutSharedUI/DeviceRowView.swift`
- `Sources/AudioutSharedUI/AppRowView.swift`
- `Sources/AudioutSharedUI/FeedPillView.swift`
- `Sources/AudioutSharedUI/MembershipBusView.swift` (only the `.blocked` node-case deletion, edit 1)
- `Sources/AudioutSharedUI/BusRailOverlayView.swift` (one switch arm + its doc comment, edit 1)
- `Sources/AudioutSharedUI/VolumePercent.swift` (NEW, edit 10)
- `Sources/AudioutSharedUI/AGENTS.md` (doc lines that edits 1 and 7 falsify)
- `Sources/AudioutPopoverUI/GroupRowView.swift`
- `Sources/AudioutPopoverUI/ConnectionDiagnosisView.swift`
- `Sources/AudioutPopoverUI/MainOutRowView.swift` — ONLY the percent call sites (edit 10) and the two `accessibilityDescription` strings (edit 11). Nothing else in this file.
- `Sources/popover-snapshot/main.swift` — ONLY the `snapshotLocalMixBlocked` doc comment + blocked-click block (edit 1; the hook it calls lives in a file we delete from, so leaving it breaks the build).
- `Tests/AudioutCoreTests/` — the test files named in each edit.

**Do not touch:**
- `PopoverController.swift`, `PopoverPanelViewController.swift`, `SilenceFallbackBannerView.swift`, `SystemAirPlayNoteBannerView.swift`, `SurfaceToolbar.swift`, `AppSurfaceController.swift` — T3a's files. T3a deletes the blocked-path PRODUCER (`PopoverController:2215-2220` comment, `:3765-3773` method, `GroupController.localMixRefusalReason`); you delete only the consumer half listed in edit 1.
- `Tokens.swift` — T9. **Collision note:** T9 separately swaps two `Tokens.Color.tertiaryLabel` uses inside `DeviceRowView.swift`; leave these two lines byte-identical: the `showSublabel("Unavailable", color: Tokens.Color.tertiaryLabel)` line in `resolveLegacySublabel()` (currently :972) and the `isUntuned ? Tokens.Color.tertiaryLabel : Tokens.Color.hairline` line in `SyncChipCell.borderColor` (currently :3086).
- `EQEditorView.swift` — its percent site (`:744`) is deliberately NOT converted (not this track's).
- `dev/notes/popover-snapshots/*.png` — never regenerate goldens.
- No row-reuse refactor of `rebuild()` (perf P2-14 is another track). No changes to `configureAccessibility`'s composed label/value/checkbox-label structure beyond the exact deletions in edit 1 — the audit calls the VoiceOver composition exemplary; regressions there are unacceptable.
- `AppRowView` `volumeChanged` drag flag (`:683-687`) and `GroupRowView` `masterChanged` drag flag (`:286-298`) keep their `STABILITY(D4)` markers — the P1-9 fix is scoped to `DeviceRowView` only.
- Every existing `test_*` hook stays unless an edit below explicitly deletes it.

---

## Verified facts

- `DeviceRowView` ALREADY has `resetCursorRects` covering the name label and armed icon (`DeviceRowView.swift:2669-2679`, marker "C3") — the audit's "no cursor rects in DeviceRowView" claim is stale for the NAME half. Only the GUTTER half of P1-2 is still open. `MainOutRowView.swift:796-800` and `AppRowView.swift:973-978` are the sibling patterns.
- The gutter hit rect is `enableCheckbox.frame` via `gutterHitRect` (`DeviceRowView.swift:2625-2627`); the checkbox is sized to `busHitTargetWidth` × row height (`:1611-1613`). `enableCheckbox.toolTip` is currently set only on the blocked branch (`:550`).
- Blocked-machinery consumer sites, all verified live: `DeviceRowView.swift:136-144` (`isToggleBlocked`, `blockReasonText`), `:443-444` + `:501-556` (`blocked:`/`blockReason:` apply params and their uses), `:772-773` (`.blocked` node), `:1998-2011` (`nameClicked` blocked branch), `:2116-2124` (`test_clickName` blocked branch), `:2569-2571` (`test_simulateBlockedBodyClick`), `:2641-2661` (`mouseDown` override + `handleBodyMouseDown`), `:2920-2924` + `:2966-2974` (AX help), `:3092-3101` (Delegate requirement `deviceRowDidRequestBlockedExplanation` at `:58-62` + default impl `:3101`). No production caller passes `blocked:` — only tests do (grep verified; `PopoverController:2218` comment confirms the producer already stopped).
- `.blocked` also appears in `MembershipBusView.swift:26,62,172-176,207,252` and `BusRailOverlayView.swift:393-397`, and in tests: `MembershipBusTests.swift:47-52,222-228`, `MembershipRailTests.swift:67,134` (comments only), `NoTintOnRingsOrMetersGuardTests.swift:202`, `DeviceRowConnectionStateTests.swift:358-360,391-408,582-618`, `AccessibilitySignalSweepTests.swift:138-148`, `BTRowsUITests.swift:27`.
- `popover-snapshot/main.swift:876-954` (`snapshotLocalMixBlocked`) calls `localRow.test_simulateBlockedBodyClick()` at `:917` — the ONLY caller of that hook.
- `ap1FeedTag = "AP1"` at `DeviceRowView.swift:1060`, applied at `:1126`; hook `test_feedHasAP1Tag` (`:2282`) reads the constant, so it survives a value change. `FeedColumnTests.swift:140` asserts the literal `"AP1 System"`. `feedColumnWidth` = 136pt (`PopoverColumnGrid.swift:208,215`); "Older AirPlay" as the micro-tag prefix + "System" fits (~100pt incl. 2×4pt pill padding).
- `feedAccessibilityClause` (`DeviceRowView.swift:2988-2997`) builds `"feeding " + names` from `mainMixSourceName` + `feedAppNames`, nil on failed/unavailable/empty. The FEED stack (`feedStack`) has no tooltip anywhere.
- `FeedPillView.configure(attributedText:isError:)` currently ignores `isError` visually (`FeedPillView.swift:73-76`); error pills differ by red text only. Pills are freshly constructed on every render (`renderFeedPills`, `DeviceRowView.swift:1275-1284`), so `configure` runs once per instance.
- `FeedPillView` observes `viewDidChangeEffectiveAppearance` only (`:89-92`); its doc (`:78-82`) requires an Increase-Contrast re-stamp it never registered for. The sibling shape to copy: `LevelMeterView.swift:126-135` (selector-based `NSWorkspace.shared.notificationCenter` observer → re-stamp; no deinit removal needed, macOS auto-unregisters).
- `ConnectionDiagnosisView.swift`: dismiss ✕ = 9.5pt bold `xmark`, `tertiaryLabel` tint, no size constraint (`:192-208`); no keyEquivalents anywhere; `copyDetailsButton.isEnabled = failure.detail != nil` (`:102`); suggestion font `systemFont(ofSize: 11)` (`:126`). Hooks `test_copyDetailsEnabled`, `test_hasDismissButton` exist (`:292,297`) and are asserted in `ConnectionDiagnosisViewTests` + `PopoverControllerTests:514` — keep `isEnabled` behavior so those stay green.
- Drag flag: `DeviceRowView.volumeChanged` (`:1969-1983`) sets `isDraggingSlider = true` on ANY change (keyboard/scroll included) and clears only on the `.leftMouseUp` coincidence. `MainOutRowView.masterChanged` (`:590-606`) already uses the event-type-switch shape — model for the "never set on keyboard" half, but it still cannot clear a cancelled drag; the monitor below can.
- Mouse-moved monitors: `DeviceRowView.swift:2741-2751` (+ property `:357-366`, install/remove from `viewDidMoveToWindow` `:2729-2739`, `deinit :2760`), `AppRowView.swift:786-805` (`hoverMoveMonitor`, `:227`), `GroupRowView.swift:341-368` (`mouseMovedMonitor`, `:64`). Nothing in the repo sets `acceptsMouseMovedEvents` (grep: zero hits), so these monitors NEVER fire today — deleting them removes cost without removing any working coverage. Tracking-area fact (parent-verified, state relied upon): an `NSTrackingArea` with `.mouseMoved` in its options makes AppKit deliver `mouseMoved(with:)` to the area's OWNER while the pointer is inside the area, WITHOUT the window opting into `acceptsMouseMovedEvents` — AppKit enables mouse-moved generation automatically while such an area exists.
- `AudioutSharedUI/AGENTS.md` line 13 documents the monitor pattern ("reconciled via an app-local `.mouseMoved` monitor") — falsified by edit 7; line 27 mentions "never on a `.blocked` node", line 41 "hint = the blocked-row refusal reason", map line 69 lists `blocked` in the node vocabulary — falsified by edit 1. Docs land with code.
- `draw(_:)` mutates `nameLabel.textColor` at `DeviceRowView.swift:2789`; `rowTextColor` (`:2035-2039`) reads menu-highlight, `device.isAvailable`, `isSelectedInSet`. `isSelectedInSet` is assigned ONLY in `apply` (`:522`); the menu-highlight input changes only via menu redraws, so the draw-time assignment must survive for the `isInMenu` branch only.
- Percent sites (all verified): `MainOutRowView.swift:302,605` (`"\(…)%"`), `:616` (`"… percent"`); `DeviceRowView.swift:691,1982` (`%`), `:2907` (`"volume \(device.volume) percent"` — same pattern, not in the hardening list; converted too, see decision D2); `AppRowView.swift:263,688` (`%`), `:1023` (`percent`); `GroupRowView.swift:408` (`percent`). `GroupRowView:294` prints a bare number, no `%` — leave it. Reference pattern: `AudioSettingsViewController.swift:376-384` (cached locale-aware `NumberFormatter` — reference only, do not edit that file). No test asserts any of these strings (grep verified).
- Coordinator addition: `MainOutRowView.swift:340` `accessibilityDescription: "Main Out"` and `:386` `accessibilityDescription: "Mute Audio Out"` — both shadowed by explicit labels (`:616-627`: "Main Audio, master volume …", "Mute Main Audio"/"Unmute Main Audio"), i.e. latent drift; canonical name is "Main Audio".
- Baseline (pre-change, both via `scripts/run-tests.sh`, observed green in this session):
  - `--filter "ConnectionDiagnosisViewTests|DeviceRowConnectionStateTests|MembershipBusTests|MembershipRailTests|AccessibilitySignalSweepTests|DeviceRowAirPlay1LiveTests|FeedColumnTests|AppRowViewTests|GroupRowViewTests|NoTintOnRingsOrMetersGuardTests|RemovalUndoTests"` → **261 tests in 11 suites passed**.
  - `--filter "PopoverControllerTests|MainOutRowMenuDispatchTests|MainOutRowRingTests|BTRowsUITests|EnergizeTests"` → **185 tests in 7 suites passed**.

---

## Edits

### 1. Delete the dead local-mix "blocked" consumer half (popover P2-7, T-UI-ALLOW finish)
The producer never fires any of this (verified above). Delete, in `DeviceRowView.swift`:
- Properties `isToggleBlocked` (`:138`) and `blockReasonText` (`:144`) with their doc comments; fix the doc at `:132` that names the old `apply(_:selected:blocked:blockReason:)` signature.
- `apply` parameters `blocked: Bool = false` and `blockReason: String? = nil` (`:504-505`) and every use inside `apply` (`:523,:525,:549-550` — the checkbox `isEnabled` term `&& !blocked` and the blocked tooltip line; edit 2 replaces the tooltip line). Fix the param docs at `:443-444` and the stale signature mentions in comments at `:1327` and `:2305`.
- The `.blocked` branch in `updateBus()` (`:772-773`) — the `if isToggleBlocked` arm goes; the BT-reconnect arm becomes the first branch. Update the function's doc comment (`:759-760` "membership / blocked / availability…").
- The blocked branches in `nameClicked(_:)` (`:2008-2011`) and `test_clickName()` (`:2121-2124`), and their doc-comment sentences about blocked rows (`:1998-2006`, `:2116-2119`).
- `test_simulateBlockedBodyClick()` (`:2569-2571`), the `mouseDown(with:)` override (`:2649-2652`) and `handleBodyMouseDown()` (`:2654-2661`) — the override exists only for the blocked branch. Also the "V12 blocked-name branch" sentence in `test_nameColor`'s doc just below `:2571`, the blocked sentences in `rowTextColor`'s doc (`:2030-2034`) and `setGutterHovered`'s doc (`:2690-2692`), and the "(a blocked row's disabled checkbox…)" clause in the constraint comment at `:1604-1610`.
- AX: the `setAccessibilityHelp(isToggleBlocked ? blockReasonText : nil)` line (`:2924`) with its comment (`:2920-2923`) — delete the line entirely (rows are re-created; no stale help to clear); in the nameLabel hint block (`:2966-2974`) keep ONLY the else-branch body (the two "Click to add/remove…" hints), deleting the `isToggleBlocked` branch and the blocked sentence in the comment above.
- Delegate: the protocol requirement `deviceRowDidRequestBlockedExplanation` (`:58-62` incl. doc) and its default impl + doc (`:3098-3101`).

In `MembershipBusView.swift`: delete `case blocked` (`:62`), the `.blocked` arm in the fill/tint resolution (`:207`), the `node != .blocked` terms in the hover-ring guard (`:176`) and `test_drawsHoverRing` (`:252` — becomes just `hovered`), and the `.blocked` mentions in the docs (`:26`, `:172-174`).

In `BusRailOverlayView.swift`: `onSpine` (`:394-398`) — remove `.blocked` from the `.nonMember` arm and "and the blocked local node" from its doc comment.

In `Sources/popover-snapshot/main.swift`: the scenario keeps its name and PNG filenames (do NOT regenerate PNGs). Delete the blocked-click block (`:912-923`: the comment, the `guard let localRow` guard, the `test_simulateBlockedBodyClick()` call, and the `drain(0.1)` that only settled the note mount). Rewrite the doc comment (`:876-886`) to describe what the scenario actually renders now: Office checked, and "Bedroom HomePod" hovered via `test_setHovered(true)` — the neutral hover-wash fixture; drop every sentence about the blocked node/refusal note.

Tests:
- `MembershipBusTests.swift`: delete `blockedLocalMixRendersBlockedNode` (`:47-52`) and `blockedRowNeverInvitesTheClick` (`:222-228`); in `unavailableRendersHollowTintedNode`, trim the "Distinct from blocked (R5)" comment so it no longer references `.blocked`.
- `DeviceRowConnectionStateTests.swift`: in `RecordingDelegate`, delete `blockedExplanationRequests` and the `deviceRowDidRequestBlockedExplanation` stub (`:351,:358-360`); delete `clickingNameOnBlockedRowRequestsRefusalExplanation` (`:391-408`) and `blockedRowAccessibilityHintCarriesRefusalReason` (`:606-618`); in `blockedRowKeepsNormalTextDistinctFromUnavailable` (`:582-603`) keep only the unavailable half — rename it `unavailableRowDimsTextAndCarriesSublabel`, drop the blocked row, its two expects and the blocked sentences of the comment.
- `AccessibilitySignalSweepTests.swift`: delete `blockedRowSpeaksTheRefusalReasonAsItsHint` (`:138-148`).
- `NoTintOnRingsOrMetersGuardTests.swift:202`: remove `.blocked` from the node array.
- `MembershipRailTests.swift`: update the two comments (`:67`, `:134-136`) that explain behavior by reference to `.blocked` — the assertions themselves stand.
- `BTRowsUITests.swift:27`: delete the stub conformance line.

Docs: `AudioutSharedUI/AGENTS.md` — line 27: drop ", never on a `.blocked` node" (the guard is now checkbox-enablement only); line 41: the hint-channel clause ("hint = the blocked-row refusal reason") is rewritten — the row itself no longer sets an AX hint; the name label's click hint remains; map line 69: remove `blocked` from the node list.

### 2. Gutter cursor + membership tooltip (popover P1-2 — remaining half; name-cursor half ALREADY FIXED, do not re-do)
`DeviceRowView.swift`:
- In `resetCursorRects()` (`:2669-2679`), after the existing name/icon rects: when `busActive && enableCheckbox.isEnabled`, `addCursorRect(gutterHitRect, cursor: .pointingHand)` (`gutterHitRect` is already in row coordinates). The enabled gate mirrors `setGutterHovered`'s "never invite a click it would refuse".
- In `apply(...)`, replace the deleted blocked-tooltip line (old `:550`) with the membership tooltip, set only on gutter rows: when `busActive && showsToggle`, `enableCheckbox.toolTip` = exactly `"Remove \(device.name) from the mix"` if `selected`, else `"Add \(device.name) to the mix"`; `nil` otherwise.
- New hook beside the other checkbox hooks: `public var test_membershipTooltip: String? { enableCheckbox.toolTip }`.
Test (in `MembershipBusTests.swift`, headless-safe, no window): a bus row applied `selected: false` has tooltip `"Add <name> to the mix"`; re-applied `selected: true, controllable: true` has `"Remove <name> from the mix"`; a non-bus row (`DeviceRowView(device:)` default host) has `nil`.

### 3. "AP1" → plain speech + FEED-stack tooltip (popover P1-5)
`DeviceRowView.swift`:
- Change the constant VALUE only: `ap1FeedTag = "Older AirPlay"` (`:1060`); keep the constant name and the `test_feedHasAP1Tag` hook name (public API). Update the doc comment above it.
- Extract the spoken-names list: give `feedAccessibilityClause` (`:2988-2997`) a private helper (e.g. `feedNames: [String]` — `mainMixSourceName` then `feedAppNames`) and reuse it for the tooltip so the two can never diverge.
- Set `feedStack.toolTip` from `updateFeedText()` (once, after the pills are resolved, covering every return path): build up to two lines joined with `"\n"` — line A (only when `feedNames` is non-empty AND the state is not failed/unavailable): `"Feeding " + feedNames.joined(separator: ", ")` (uncapped — the "+N" cap is screen-only); line B (only when `!device.supportsAirPlay2` and not failed/unavailable): exactly `"Older AirPlay — can't route single apps"`. `nil` when both lines are absent (failed/unavailable pills and the empty case mirror the clause's own nil cases).
- New hook: `public var test_feedTooltip: String? { feedStack.toolTip }`.
No new interactive control; `FeedPillView.hitTest` stays `nil`; the spoken composition is untouched (the clause never spoke AP1 before and still doesn't — see Out of scope).
Tests (`FeedColumnTests.swift`): update `:140` to `"Older AirPlay System"`; add asserts — an AP1 member row's `test_feedTooltip` contains both the "Feeding System" line and the exact Older-AirPlay line; an AP2 row with overflow (the `:78` fixture) has a tooltip listing ALL app names with NO "+"; a failed row's tooltip is `nil`.

### 4. Error pills get a shape, not just a colour (popover P2-6)
`FeedPillView.swift`: honour the `isError` flag `configure` already receives. Add a small leading `NSImageView` showing `exclamationmark.triangle` (SF Symbol, `SymbolConfiguration(pointSize: 9, weight: .semibold)`, `accessibilityDescription: nil` — decorative; the row's spoken state clause already says "couldn't connect"), `contentTintColor = Tokens.Color.failure` (dynamic NSColor — re-resolves on appearance change by itself; do NOT bake a resolved CGColor). Layout: when `isError`, the glyph sits at the pill's leading padding and the label's leading anchor attaches to the glyph's trailing + 3pt; otherwise the existing label-to-pill-leading constraint holds. Pills are rebuilt per render (verified), so `configure` may install the error layout once without needing to undo it. `hitTest` stays `nil`.
`DeviceRowView.swift`: new hook `public var test_feedErrorPillHasGlyph: Bool` reading the first pill's glyph state (add an internal `test_hasErrorGlyph` on `FeedPillView`; same-module access is fine).
Tests (`FeedColumnTests.swift`): failed row → `test_feedErrorPillHasGlyph == true`; unavailable row → `true`; ordinary member row → `false`.

### 5. Diagnosis panel: dismiss ✕, default button, Copy Details, type size (popover P1-6 + P3-1 + P3-2)
`ConnectionDiagnosisView.swift`:
- `configureDismissButton()` (`:192-208`): symbol config → `pointSize: 12, weight: .bold`; tint → `Tokens.Color.secondaryLabel`; `dismissButton.keyEquivalent = "\u{1b}"`; add constraints `widthAnchor >= 24`, `heightAnchor >= 24`. Update the doc comment (it currently justifies the tertiary 9.5pt look).
- After `configureSmallButton` for retry: `retryButton.keyEquivalent = "\r"` — "Try Again" becomes the default button (stock `.rounded` bezel renders the default treatment itself).
- `apply(failure:deviceName:)` (`:102`): keep the `isEnabled` line, add `copyDetailsButton.isHidden = failure.detail == nil` (P3-1: hide, don't permanently-disable; keeping `isEnabled` preserves the existing test contract incl. `PopoverControllerTests:514`).
- `:126`: `suggestionLabel.font = .systemFont(ofSize: NSFont.systemFontSize)` (13pt). Headline stays 11 bold.
- New hooks: `test_copyDetailsHidden: Bool`, `test_retryKeyEquivalent: String`, `test_dismissKeyEquivalent: String`.
Tests (`ConnectionDiagnosisViewTests.swift`): add `copyDetailsHiddenExactlyWhenNoDetail` (hidden with `detail: nil`, visible after re-apply with detail, hidden again after re-apply without — mirrors `copyDetailsEnablementFollowsReappliedFailure`); add `keyboardEquivalents` asserting retry `"\r"` and dismiss `"\u{1b}"`. Existing enablement tests stay untouched and must stay green.

### 6. Drag flag clears from a real gesture end (popover P1-9, row half — DeviceRowView ONLY)
`DeviceRowView.swift`, replace `volumeChanged(_:)`'s flag logic (`:1969-1979`) and remove the `STABILITY(D4)` marker at `:1970`. Exact shape (mandated):
```swift
@objc private func volumeChanged(_ sender: NSSlider) {
    // Only a genuine mouse drag suppresses model pushes; keyboard/scroll/AX
    // changes arrive as single events with no drag in flight.
    switch NSApp?.currentEvent?.type {
    case .leftMouseDown, .leftMouseDragged:
        isDraggingSlider = true
        installSliderDragEndMonitor()
    case .leftMouseUp:
        endSliderDrag()
    default:
        break
    }
    readoutLabel.stringValue = VolumePercent.label(sender.integerValue)   // edit 10
    delegate?.deviceRow(self, didSetVolume: sender.integerValue, for: device.id)
}

private var sliderDragEndMonitor: Any?

private func installSliderDragEndMonitor() {
    guard sliderDragEndMonitor == nil else { return }
    sliderDragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
        self?.endSliderDrag()   // real gesture end — fires even for a drag whose
        return event            // final change callback never coincided with mouse-up
    }
}

private func endSliderDrag() {
    isDraggingSlider = false
    if let monitor = sliderDragEndMonitor {
        NSEvent.removeMonitor(monitor)
        sliderDragEndMonitor = nil
    }
}
```
Also call `endSliderDrag()` in `viewDidMoveToWindow()` when `window == nil` (a row detached mid-drag must not keep a monitor or a stuck flag) and in `deinit`. Keep `NSApp?.` optional chaining — never bare `NSApp.` (AGENTS.md rule).
Test (`DeviceRowConnectionStateTests.swift`, same file style): after `test_fireSliderAction(settingValueTo: 30)` (fires the real target/action with a nil `currentEvent` — the keyboard-shaped path), a subsequent `apply` with `volume: 55` must show `test_sliderValue == 55` — pinning that a non-mouse change no longer wedges `isDraggingSlider`. (Today this would fail; it passes after the fix. Headless-safe: no window needed.)

### 7. Per-row app-wide `.mouseMoved` monitors → tracking-area `.mouseMoved` (perf P2-15 / popover P2-1)
Fact to rely on (see Verified facts): `.mouseMoved` in an `NSTrackingArea`'s options delivers `mouseMoved(with:)` to the area's owner without any `acceptsMouseMovedEvents` opt-in. The monitors being deleted never fire today, so this strictly adds live coverage while deleting N app-wide closures churned per rebuild.

`DeviceRowView.swift`:
- `updateTrackingAreas()` (`:2600-2604`): bounds-area options become `[.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect]`. The gutter area (`:2612-2617`) stays as-is (`refreshHoverFromPointer` reconciles the gutter too).
- Add: `public override func mouseMoved(with event: NSEvent) { refreshHoverFromPointer() }`.
- Delete `mouseMovedMonitor` property + its doc (`:357-366`), `installMouseMovedMonitor()`/`removeMouseMovedMonitor()` (`:2741-2758` incl. the `STABILITY(D4)` marker), the install/remove calls in `viewDidMoveToWindow()` (`:2734-2738`; keep the hover resets + add edit 6's `endSliderDrag()`), and the `removeMouseMovedMonitor()` in `deinit` (`:2760` — deinit now only ends the drag monitor). Update the comments that referenced the monitor: `:146-150` (`isHovered` doc), `:530-531` (apply comment), `:2596-2598` (re-tracking comment), `:2706-2712` (`refreshHoverFromPointer` doc — now driven by the tracking area's own mouse-moved stream), `:2724-2728` (`viewDidMoveToWindow` doc).
`AppRowView.swift`: same treatment — add `.mouseMoved` to the options at `:779`; add a `mouseMoved(with:)` override whose body is the current monitor closure's reconcile (convert `window.mouseLocationOutsideOfEventStream`, `isHovered = bounds.contains(point)`); delete `hoverMoveMonitor` (`:227`), the monitor block in `viewDidMoveToWindow` (`:786-801` — keep `isHovered = false`; the `guard window != nil` and everything after it goes) incl. the `STABILITY(D4)` marker at `:794`, and the `deinit` (`:803-805`).
`GroupRowView.swift`: same — add `.mouseMoved` at `:308`; add `public override func mouseMoved(with event: NSEvent) { refreshHoverFromPointer() }`; delete `mouseMovedMonitor` (`:64`), `installMouseMovedMonitor`/`removeMouseMovedMonitor` (`:352-366` incl. the marker at `:354`), their calls in `viewDidMoveToWindow` (`:345-349` — keep the hover reset), and `deinit` (`:368`); update the doc comments at `:331-340`.
Docs: `AudioutSharedUI/AGENTS.md` line 13 — rewrite: hover is reconciled against the true pointer position from the row's OWN tracking area's `.mouseMoved` events (plus enter/exit), cleared on every `apply`; no app-wide monitor exists any more.
No new tests (hover is pointer-driven; existing `test_setHovered` paths are untouched and the monitors were inert). All existing suites must stay green.

### 8. `nameLabel.textColor` out of `draw(_:)` (perf P3-11 / popover P2-2)
`DeviceRowView.swift`: in `apply(...)`, stamp `nameLabel.textColor = rowTextColor` once the inputs are set (beside `resolveSublabel()`/`updateFeedText()` at `:683-684`). In `draw(_:)` (`:2789`), keep the assignment ONLY inside the `isInMenu` branch (menu highlight is the one input that changes without an `apply`; a menu redraw is its only signal) — move the line into the `if isInMenu { … }` block; the menu-less path no longer touches it. `isSelectedInSet` changes only via `apply` (verified), hover does not feed `rowTextColor`, so no other setter needs it.
Existing color assertions (`DeviceRowConnectionStateTests:568,577`, `test_nameColor` uses) must stay green.

### 9. `FeedPillView` Increase-Contrast observer (design P2-5)
`FeedPillView.swift`: in `init`, after `updateAppearance()`, register exactly the `LevelMeterView.swift:126-135` shape — `NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityDisplayOptionsDidChange), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)` with `@objc private func accessibilityDisplayOptionsDidChange() { updateAppearance() }`. Update the `updateAppearance` doc comment (`:78-82`) — it currently documents the requirement as unmet. No deinit removal (selector-based observers auto-unregister; matches the siblings). No test (the live IC flag can't be forced headlessly; the siblings have none either).

### 10. Locale-aware percent helper (hardening P3, percent rows)
New file `AudioutCore/Sources/AudioutSharedUI/VolumePercent.swift` (SPDX header line matching the sibling files): `public enum VolumePercent` with two cached static `NumberFormatter`s, following the `AudioSettingsViewController.swift:376-384` pattern (reference only — do NOT edit that file):
- `public static func label(_ value: Int) -> String` — formatter `numberStyle = .percent`, `multiplier = 1`, `maximumFractionDigits = 0`; fallback `"\(value)%"` if the formatter returns nil. (`multiplier = 1` so 64 → "64%", with locale digit substitution and percent placement.)
- `public static func spoken(_ value: Int) -> String` — decimal-style digits + `" percent"` (the spoken word stays English; the app ships English copy — this fixes digit rendering only).
Call sites (mechanical swaps, nothing else on those lines changes):
- `label(_:)`: `MainOutRowView.swift:302,605`; `DeviceRowView.swift:691` and the line in edit 6's `volumeChanged`; `AppRowView.swift:263,688`.
- `spoken(_:)`: `MainOutRowView.swift:616` (`"Main Audio, master volume \(VolumePercent.spoken(slider.integerValue))"`), `DeviceRowView.swift:2907` (`"volume \(VolumePercent.spoken(device.volume))…"`), `AppRowView.swift:1023`, `GroupRowView.swift:408`.
`GroupRowView:294` (bare-number readout) and `EQEditorView.swift:744` stay untouched. No new tests (exact output is locale-dependent; no existing test asserts these strings — verified).

### 11. MainOutRowView stray accessibility descriptions (coordinator addition — canonical name "Main Audio")
`MainOutRowView.swift:340`: `accessibilityDescription: "Main Out"` → `"Main Audio"`. `:386`: `accessibilityDescription: "Mute Audio Out"` → `"Mute Main Audio"` (agrees with the explicit label at `:626`). Nothing else in this file beyond edit 10's lines.

---

## Tests & verification

All runs through the wrappers (binding rule in the header). Inner loop — scope to what you touched:
```bash
bash scripts/run-tests.sh --filter "ConnectionDiagnosisViewTests|DeviceRowConnectionStateTests|MembershipBusTests|MembershipRailTests|AccessibilitySignalSweepTests|DeviceRowAirPlay1LiveTests|FeedColumnTests|AppRowViewTests|GroupRowViewTests|NoTintOnRingsOrMetersGuardTests|RemovalUndoTests"
bash scripts/run-tests.sh --filter "PopoverControllerTests|MainOutRowMenuDispatchTests|MainOutRowRingTests|BTRowsUITests|EnergizeTests"
```
Baselines observed pre-change: 261 tests/11 suites and 185 tests/7 suites, all green — any failure you see is yours.

Final checks, in order:
1. `bash scripts/build.sh` → exit 0 (this also proves `popover-snapshot` and every tool target still compile after the hook deletion).
2. The two filtered runs above → all pass (test count will shift: ~6 tests deleted, ~7 added; report the new counts).
3. `bash scripts/run-tests.sh` (full suite) → all pass. The full suite can be flaky under machine load — an unrelated-looking failure gets ONE re-run before you treat it as yours; a remote-infrastructure error ("cannot reach / cannot sync") is never a test failure.
4. Commit on the branch (Guard 4/6 re-run suites; Guard 7 requires the self-review — let it run, don't surface its chatter), push to `origin/claude/fix-popover-rows`. Do NOT merge — merges need Alec's explicit go-ahead.

**Tests stay invisible (Guard 8 rule):** no new test may order a real window on screen; follow the existing suites' headless patterns. `view.window != nil` is NOT a headless check. Every new test above works on unmounted views.

## Acceptance checklist
- [ ] `git grep -n "isToggleBlocked\|blockReasonText\|deviceRowDidRequestBlockedExplanation\|simulateBlockedBodyClick"` over `AudioutCore/Sources` and `Tests` returns nothing; `git grep -n "\.blocked" AudioutCore/Sources/AudioutSharedUI` returns nothing (node case gone).
- [ ] `git grep -n "addLocalMonitorForEvents(matching: \[.mouseMoved\])"` over `Sources/` returns nothing; `DeviceRowView`/`AppRowView`/`GroupRowView` each have `.mouseMoved` in their bounds tracking-area options and a `mouseMoved(with:)` override.
- [ ] The four resolved `STABILITY(D4)` markers are gone (`DeviceRowView` ×2, `AppRowView:794`, `GroupRowView:354`); the two drag-flag markers at `AppRowView:683` and `GroupRowView:286` remain.
- [ ] `DeviceRowView.draw(_:)` no longer assigns `nameLabel.textColor` on the menu-less path.
- [ ] Gutter tooltip + cursor: bus row shows the pointing hand over the gutter only while the checkbox is enabled; tooltips read exactly "Add <name> to the mix" / "Remove <name> from the mix".
- [ ] FEED: AP1 rows read "Older AirPlay …"; feed-stack tooltip carries the Feeding line and the exact "Older AirPlay — can't route single apps" line; error pills carry the triangle glyph.
- [ ] Diagnosis panel: Esc dismisses (keyEquivalent set), Return = Try Again, Copy Details hidden iff `detail == nil` (still `isEnabled`-tracked), dismiss ≥24×24 at `secondaryLabel` tint, suggestion at 13pt.
- [ ] No remaining `"\(…)%"` / `"… percent"` interpolations in the four row files (except `GroupRowView:294`'s bare number).
- [ ] `MainOutRowView` symbol descriptions read "Main Audio" / "Mute Main Audio".
- [ ] `AudioutSharedUI/AGENTS.md` lines 13/27/41/map updated to match the code.
- [ ] The two `tertiaryLabel` lines reserved for T9 are byte-identical (`resolveLegacySublabel` "Unavailable"; `SyncChipCell.borderColor`).
- [ ] Full-suite run green; build green; branch pushed. NOT merged.

## Open decisions (made — flag only if reality contradicts)
- **D1 — AP1 form:** tag-text swap to "Older AirPlay" (not a sublabel); consequence copy rides the feed tooltip. Width verified against `feedColumnWidth` = 136pt.
- **D2 — spoken-percent scope:** `DeviceRowView:2907` is converted although the hardening list missed it (same pattern, same file, same helper). The spoken word "percent" stays English.
- **D3 — `.blocked` deletion blast radius:** `MembershipBusView.swift`, `BusRailOverlayView.swift` (one arm) and `popover-snapshot/main.swift` (doc + call block) are included in this track even though outside the headline owned set — no other track claims them, and the build breaks without the snapshot edit. If you find any OTHER live blocked-machinery consumer not listed in edit 1, STOP and report instead of deleting it.
- **D4 — dismiss sizing:** `xmark` at 12pt bold + ≥24×24 constraints + `secondaryLabel` tint is the "standard small close" rendering for this panel.
- **D5 — Copy Details:** hidden AND enabled-tracked (both properties set) so the existing `test_copyDetailsEnabled` contract survives.
- **D6 — drag-end mechanism:** the scoped `.leftMouseUp` local monitor (not an `NSSliderCell.stopTracking` override — `WarmFaderCell` is contractually drawing-only).

## Executor rules (verbatim)
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
