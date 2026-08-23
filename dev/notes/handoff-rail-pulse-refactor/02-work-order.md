# Work order — event-driven rail connect pulse (popover)

## Goal

End the class of spurious rail connect-pulses in the macOS popover by moving the FIRING decision out of `BusRailOverlayView`'s draw-time diff (which fires whenever the on-screen row set changes — subsection collapse/expand, popover reopen, off-screen rebuilds) and into `PopoverController`, which diffs the MODEL fact "device is a connected member of the active Main Out target" on each `update(devices:)`. The overlay becomes render-only for the pulse: it keeps the bead/bloom presentation and gains one public entry point, `playConnectPulse(joinedDeviceIDs:cameToLife:)`, that the controller reaches through a thin panel forwarder. Layout-only changes then cannot fire by construction. All work happens IN THIS WORKTREE (`/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/rail-animation-bugs-89dd1a`, branch `claude/rail-animation-bugs-89dd1a`) ON TOP of the existing UNCOMMITTED changes in 4 files — do not commit, stash, or revert anything.

## Verified facts

All line numbers refer to the CURRENT uncommitted working-tree state of this worktree.

- The draw-diff machinery lives ONLY in `AudioutCore/Sources/AudioutSharedUI/BusRailOverlayView.swift`; its symbols (`EnergySignature`, `energizeSignature`, `connectPulseFires`, `reconcileEnergize(with:)`, `lastEnergy`, `lastMemberYs`, `settleBaseline`, `windowOcclusionStateDidChange`, `test_reconcileEnergize`, `RailPlan.memberYs`) are referenced by exactly two files: that file and `AudioutCore/Tests/AudioutCoreTests/RailConnectPulseTests.swift` (repo-wide `git grep`).
- TRAP — name collision: `PopoverController` has its OWN `private func reconcileEnergize()` (`AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:1662`, called at 2202). It prunes the item-9 energize pending beat and is UNRELATED to the overlay's `reconcileEnergize(with:)`. Do not touch it.
- `BusRailOverlayView` hosts: exactly TWO — `PopoverPanelViewController` (`AudioutCore/Sources/AudioutPopoverUI/PopoverPanelViewController.swift:227`, internal `let railOverlay`) and `GroupEditorViewController` (`AudioutCore/Sources/AudioutWindowUI/GroupEditorViewController.swift:59`). `MainOutDetailViewController` hosts NO overlay (grep confirmed). The editor only sets `mainOutRow`/`deviceRows`/`needsDisplay` (638–640) and calls `test_resolvePlan` (1028) — none of the removed symbols — and its `receiveRailPulse` is a no-op (`GroupEditorViewController.swift:1136`), so removing the draw-time reconcile just means the editor never pulses. That is the intended design.
- `RailNodeProviding` (declared `BusRailOverlayView.swift:1064-1071`) has exactly THREE conformers: `DeviceRowView` (`AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift:2922-2928`; has `public private(set) var device: Device` at 127), `MembershipRowView` (`AudioutCore/Sources/AudioutWindowUI/MembershipRowView.swift:483-487`; has `public private(set) var device: Device` at 62), and the test stub `StubRow` (`RailConnectPulseTests.swift:110-120`).
- `RailHookProviding` conformers: `MainOutRowView` (`AudioutCore/Sources/AudioutPopoverUI/MainOutRowView.swift:812-831`; `railHookAnchor` calls `layoutSubtreeIfNeeded()` at 820 and works headless — `PopoverControllerTests.swift:845` resolves a popover rail plan with no window), `GroupEditorViewController` (1103, `receiveRailPulse` no-op at 1136), and the test `StubHook` (`RailConnectPulseTests.swift:98-108`). No change needed to this protocol.
- `PopoverController.update(devices:)` (PopoverController.swift:672-802) runs its MODEL half unconditionally and gates only UI work behind `isEffectivelyShown` (777-794; no early return before 777). It already computes a Main-Out membership diff at 743-747 (`nowMainOutMembers` via `groupController?.isMainOutMember($0.id) == true`, stored in `lastMainOutMemberIDs` declared at 587-596, nil-until-first-snapshot pattern at 746).
- Controller stored properties survive rebuilds: `rebuildForOpen()` (1094-1099) touches only `isRebuildingForOpen` + `transientCollapsed`; `rebuild()` (1103+) clears row/view maps only; `surfaceDidShow`/`surfaceDidHide` (3979-3983, 4022+) clear transient UI state only. None resets `lastValidDestinationIDs`/`lastMainOutMemberIDs` — a sibling property will persist identically.
- The row's `.member` node predicate (`DeviceRowView.updateBus`, DeviceRowView.swift:731-787) is `isSelectedInSet && isAvailable && connectionState ∈ {.connected, .off}` — it includes `.off`, and `isSelectedInSet` is the `selected:` param = `controller.isSpeakerSelected(device.id)` (PopoverController.swift:1990, DeviceRowView.swift:511). It is NOT usable as the pulse predicate verbatim (see Step 5 rationale).
- `ConnectionState` is `off/connecting/connected/reconnecting/failed(ConnectionFailure)` (`AudioutCore/Sources/AudioutCore/ConnectionState.swift:22-28`); `Equatable`, so `$0.connectionState == .connected` compiles.
- `updateRailRows` (PopoverController.swift:2226-2246) feeds the overlay via `panel.setRailRows(...)` (PopoverPanelViewController.swift:374-396) and passes `dormant: devicesCardDivergence() != nil` (2245). `refreshDeviceRows` (2197-2210) runs it on every in-place repaint; the rebuild branch of `update(devices:)` (779-780) ends with `panel.panelContentDidChangeHeight(animated: true)`, whose measurement settles Auto Layout synchronously (`fittingSizeSettled`, PopoverPanelViewController.swift:400-404) — so by the time a `RunLoop.main.perform` block queued during `update(devices:)` runs, rows are rebuilt AND laid out.
- Pulse presentation machinery that STAYS (all in BusRailOverlayView.swift): `pulseLayer`/`pulseKey`/`beadLength`/`beadAbsorbDuration`/`arrivalBloomRadius`/`arrivalLayer` (89-106), `reduceMotion` (470-472), `length(of:)` (539-559), `fraction(atY:along:)` (561-596), `Arrival` (620-623), `runConnectPulse` (625-735; the coalesce guard `guard pulseLayer == nil` at 638, the `strokeWindow` param + `self.window` guard at 625-630, `test_lastPulseDeparture`/`test_pulsesStarted` at 639-640, the Timer-based handoff/cleanup at 711-734), `runHeaderDotBloom` (747-795), `cancelConnectPulse` (797-802), and every `test_*` hook at 804-869 (`test_resolvePlan`, `test_reduceMotionOverride`, `test_windowVisibleOverride`, `windowIsVisible`, `test_lastPulseDeparture`, `test_isConnectPulsing`, `test_isHeaderDotBlooming`, `test_headerDotBloomRuns`, `test_pulseHandoffRuns`, `test_pulsesStarted`, `test_headerDotBloomModelOpacity`, `test_pulseModelStrokeWindow`, `test_pulsePresentationStrokeEnd`).
- The RM cancel (`accessibilityDisplayOptionsDidChange`, 187-189) and accent-dial cancel (`accentStyleDidChange`, 193-196) already call `cancelConnectPulse()` directly — they do NOT call `settleBaseline` — so they survive its deletion unchanged.
- `RailPlan.memberYs` (BusRailOverlayView.swift:909-915, populated at 1053) is read nowhere outside the overlay file (grep; the only other hit is a comment in RailConnectPulseTests.swift:72). `RailPlan.Input` has no `memberYs` member, so no test constructing `Input` breaks.
- Existing controller test seams: `test_simulateOpen()` (PopoverController.swift:3061), `test_isShownOverride` (1046, ORed into `isEffectivelyShown` at 1051), `test_toggleCard(title:animated:)` (3240), `test_railPlan()` (3264, public, forwards to panel), `test_fireSubsectionHeaderClick(title:)` (3326), `test_applyExactFitSize()` (3259). Card/section titles are internal statics (`Self.mainAudioCardTitle`/`Self.outputDevicesCardTitle` used at 2242-2243; `PopoverController.airPlaySubsectionTitle` used by PopoverDeviceVisibilityTests.swift:60).
- Controller-test harness precedent: `PopoverDeviceVisibilityTests.makePopover` (`AudioutCore/Tests/AudioutCoreTests/PopoverDeviceVisibilityTests.swift:25-43`) — MockBackend + GroupController + `popover.test_isShownOverride = true`, then hand-built `popover.update(devices:)` pushes; device fixtures at 45-57.
- Pre-change baseline (run in this worktree, 2026-08-22): `bash scripts/run-tests.sh --filter 'RailConnectPulseTests|BusRailCollapseResolveTests|PopoverDeviceVisibilityTests|MembershipRailTests'` → **“Test run with 91 tests in 4 suites passed after 32.569 seconds”, exit 0.**

## Steps

Work top to bottom. Steps 1–5 keep `bash scripts/build.sh` green at every boundary; tests compile again after Step 6.

### Step 1 — `RailNodeProviding.railDeviceID` (protocol + both real conformers)
File: `AudioutCore/Sources/AudioutSharedUI/BusRailOverlayView.swift`, protocol at 1064-1071.
Add a third requirement after `railNode` (line 1066): `var railDeviceID: String? { get }`, doc comment: the device id the host uses to map a joined device to its stop for the pulse departure; `nil` for a row that represents no device. NO protocol-extension default — every conformer states it explicitly so the compiler finds them all.
- `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift` extension at 2922-2928: add `public var railDeviceID: String? { device.id }`.
- `AudioutCore/Sources/AudioutWindowUI/MembershipRowView.swift` extension at 483-487: add `public var railDeviceID: String? { device.id }`.
- `RailConnectPulseTests.swift` `StubRow` (110-120): add a `railDeviceID` stored property (optional String, default `nil`, settable or via init) so the test target compiles and Step 6 can address rows by id.

### Step 2 — Overlay: add `playConnectPulse` (additive; old machinery still present)
File: `AudioutCore/Sources/AudioutSharedUI/BusRailOverlayView.swift`, place it in the "Connect pulse" MARK section (after `reduceMotion`, line 472).
Exact signature (public — the panel calls it cross-module): `public func playConnectPulse(joinedDeviceIDs: Set<String>, cameToLife: Bool)`.
Behavior, in order — this reuses, near-verbatim, logic being deleted from `reconcileEnergize(with:)` in Step 3, so mirror those lines:
1. Defer the ENTIRE body in one `RunLoop.main.perform { [weak self] in … }` (the deleted code's own idiom, line 534, and for the same reason: a run-loop block, not `DispatchQueue.main.async`, so nested run-loop spins in tests can execute it). Deferring everything means geometry is read AFTER the current turn's rebuild/refresh + exact-fit layout have settled.
2. Inside the block, guard in this order, returning silently on any failure: `windowIsVisible` (the existing property, 822-824), `!reduceMotion`, `let plan = resolvePlan()`, `plan.gold`, `!plan.dormant`. The `gold`/`dormant` guards reproduce the retired signature's "a dormant or idle wire carries nothing" (old lines 444-448 + spec: no pulse on dormant/idle wires). `runConnectPulse`'s own window/RM/coalesce guards still apply on top.
3. Build the joined wire path exactly as the deleted lines 494-496 did: one `NSBezierPath`, appending `run.path` for every `wireRuns(for: plan)`; bail if empty.
4. Departure: if `cameToLife` → `1`. Otherwise map each id in `joinedDeviceIDs` to its row via `deviceRows.first { $0.railDeviceID == id }`, convert that row's node center the way `resolvePlan` does (line 229: `convert(row.railNodeBounds, from: row.railNodeView)`, take `.midY`), map through `Self.fraction(atY:along:)`, and take the maximum of the resolved fractions with fallback `1` (the deleted `.max() ?? 1` shape, lines 507-512 — lowest new room wins; an unmounted/unmapped id simply drops out via `compactMap`).
5. Arrival: from `plan.origin` exactly as deleted lines 519-525 — `.ring` → `Arrival.ring`; `.headerDot(y)` → `Arrival.headerDot(NSPoint(x: PopoverColumnGrid.railGutterCenterX, y: y))`.
6. Stroke window: `min(Self.beadLength / max(Self.length(of: joined), 1), 0.45)` — deleted line 533, verbatim.
7. Call `runConnectPulse(along: joined.cgPath, from: departure, strokeWindow: …, arrivingAt: …)` DIRECTLY (no second deferral).

### Step 3 — Overlay: remove the draw-diff machinery
File: `AudioutCore/Sources/AudioutSharedUI/BusRailOverlayView.swift`. Delete, with their doc comments:
- 107-111 `lastEnergy` and 112-115 `lastMemberYs` (keep 89-106: `pulseLayer` through `arrivalLayer` block).
- In `viewDidMoveToWindow` (151-168): replace the `settleBaseline()` call (153) with `cancelConnectPulse()` (a remount still kills an in-flight bead — the HaloRingView contract's remount-cancel sibling), and delete lines 154-167 (the occlusion-observer comment + remove/add). Keep the method and its `super` call; trim its doc comment (149-150 + the 154-158 prose) to the remount-cancel story.
- 170-174 `windowOcclusionStateDidChange` — whole method.
- 176-182 `settleBaseline()` — whole method.
- Line 203: the `reconcileEnergize(with: plan)` call in `draw(_:)` (keep 198-202 and the closing brace; `draw` becomes pure rendering).
- 435-448 `EnergySignature` + `energizeSignature(of:)` (docs included).
- 450-468 `connectPulseFires(previous:current:)`.
- 474-537 `reconcileEnergize(with:)` (its doc comment starts at 474).
- 871-876 `test_reconcileEnergize()` (doc at 871-872).
- `RailPlan.memberYs`: doc+decl 909-915, and the `memberYs:` argument line in `resolve` (1053).
Do NOT touch: `draw`/`drawPlan`/`wireRuns`/`appendVertical`/`fillTerminusDot`/`onSpine`, `resolvePlan` + `clipBand`/`headerTerminusY`, the `dropsHiddenRows` logic anywhere (properties 79-87, Input 944-954, resolve 1023-1050), `length`/`fraction`, `Arrival`, `runConnectPulse` (including the `guard pulseLayer == nil` coalesce at 638 and the `strokeWindow` parameter name), `runHeaderDotBloom`, `cancelConnectPulse`, the RM/accent-dial handlers (184-196), or any remaining `test_*` hook (804-869).
Also update the class doc: rewrite the "Connect pulse" paragraph (33-47) so the trigger reads as: the HOST detects the model transition (a device becoming a connected member of the active Main Out target — `PopoverController.update(devices:)`) and calls `playConnectPulse`; the overlay only renders the bead/bloom, so layout changes (open, rebuild, collapse/expand) cannot fire it. Keep the bead-shape/absorption/determinism prose (49-53) unchanged.

### Step 4 — Panel forwarder
File: `AudioutCore/Sources/AudioutPopoverUI/PopoverPanelViewController.swift`, immediately after `setRailRows` (ends line 396).
Add an internal method `playRailConnectPulse(joinedDeviceIDs: Set<String>, cameToLife: Bool)` whose whole body forwards to `railOverlay.playConnectPulse(joinedDeviceIDs:cameToLife:)`. One-sentence doc: the controller's model-event → overlay bridge; geometry keeps flowing through `setRailRows`.

### Step 5 — Controller: the member-set diff
File: `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift`.
(a) After `lastMainOutMemberIDs` (587-596), add a sibling stored property `private var lastConnectedMemberIDs: Set<String>?` — doc: the device ids that were BOTH members of the active Main Out target AND `.connected` at the last `update(devices:)`; `nil` until the first snapshot; deliberately persists across `rebuild()`/`rebuildForOpen()`/open/close (it is model state, and its persistence — plus being kept current while hidden — is exactly what makes a reopen non-firing).
(b) In `update(devices:)`, directly after `lastMainOutMemberIDs = nowMainOutMembers` (747), add the diff block:
- Compute the current set with the shape of line 743-745: `Set(devices.compactMap { groupController?.isMainOutMember($0.id) == true && $0.connectionState == .connected ? $0.id : nil })`.
- If `lastConnectedMemberIDs` is non-nil (NOT the first snapshot): `newlyJoined = current.subtracting(previous)`; if `newlyJoined` is non-empty AND `isEffectivelyShown`, call `panel.playRailConnectPulse(joinedDeviceIDs: newlyJoined, cameToLife: previous.isEmpty)`.
- Unconditionally store `current` into `lastConnectedMemberIDs` — hidden updates included, so connects that happen while the surface is hidden advance the baseline silently and the open ritual finds nothing "new".
Predicate rationale (decided here, not the executor's call): the brief's "same predicate as the `.member` node" is NOT taken literally — the node predicate includes `.off` (Verified facts), which would double-fire across the `.off → .connecting → .connected` dip, and keys off `isSpeakerSelected` rather than active-target membership, which would let a per-app-redirect connect pulse the Main-Audio wire. `isMainOutMember ∧ .connected` is the model truth for "in the live mix" (the same membership input the route-armed dot takes, 2013-2021); divergence corners are covered by the overlay's `dormant`/`gold` guards. A `.reconnecting` dip returning to `.connected` re-fires — a room genuinely rejoining, same as today.
(c) Near `test_railPlan()` (3264), add the observation seam: `public func test_railOverlay() -> BusRailOverlayView { panel.railOverlay }` — lets tests set the overlay's `test_windowVisibleOverride`/`test_reduceMotionOverride` and read `test_pulsesStarted`/`test_lastPulseDeparture` through the controller boundary. (`panel.railOverlay` is internal in the same module, PopoverPanelViewController.swift:227; `BusRailOverlayView` is public.)
Do NOT add any pulse call anywhere else — not in `rebuild`, `rebuildForOpen`, `refreshDeviceRows`, `toggleSubsection`, `surfaceDidShow`, or the energize path. `update(devices:)` is the single firing site.

### Step 6 — Rewrite `RailConnectPulseTests`
File: `AudioutCore/Tests/AudioutCoreTests/RailConnectPulseTests.swift`. Update the suite doc header to the new architecture. Per-test disposition:

DELETE (they test machinery that no longer exists; their regression intent moves to Step 7):
- `theFirstDrawNeverFires` (22), `armingFires` (28), `aNewMemberOnAnArmedSpineFires` (35), `lossAndIdleGainsStayQuiet` (42), `aDormantPlanReadsAsCarryingNothing` (57), `expandingAClippedSectionIsNotAMembershipGain` (69), plus the `Signature` typealias (20).
- `theRealDrawPathFiresThePulse` (165), `aReopenNeverDiffsAgainstTheStalePreCloseBaseline` (199), `anOffScreenRebuildDrawNeverBecomesTheReopenBaseline` (229), `theFirstReconcileOnlyStampsTheBaseline` (450), `aConnectThatArmsBeforeItsMemberLandsFiresOnce` (485).

REWRITE — same assertion intent, trigger swapped from `test_reconcileEnergize()`/`display()` sequences to a direct `playConnectPulse` call. Every rewritten test sets `scene.hook.gold = true` BEFORE playing (armed spine is now a precondition, not the transition) and keeps `drainMainQueue()` after the call (the whole body is deferred):
- `thePulsePresentationActuallyAnimates` (179) → trigger `playConnectPulse(joinedDeviceIDs: [], cameToLife: true)`; keep the `NSScreen.main` gate and ordered-front window.
- `anOrderedOutWindowNeverPulses` (270) → `test_windowVisibleOverride = nil` (real, never-ordered-in window), `playConnectPulse` → no pulse.
- `aJoiningRoomDepartsFromItsOwnNode` (297) → give the three StubRows ids; `playConnectPulse(joinedDeviceIDs: [<middle row id>], cameToLife: false)` → `0.05 < test_lastPulseDeparture < 0.95`.
- `armingDepartsFromTheTerminus` (314) → rename to the came-to-life vocabulary; `cameToLife: true` → departure `== 1`.
- NEW small test: an id with no matching row (or a row set whose ids are nil) falls back to departure `== 1` — pins the `.max() ?? 1` fallback.
- `aCompletedPulseHandsOffToTheRing` (349) and `aCancelledPulseNeverReachesTheRing` (367) → trigger swap only; keep the polling/ordered-front machinery and assertions.
- `armingMountsThePulseWithASettledModel` (459) → trigger swap; still asserts model stroke window `(0, 0)`.
- `aNewMemberSegmentFiresOnALiveWire` (471) → collapses to "a single join mounts the bead": `playConnectPulse([<id>], cameToLife: false)` → `test_isConnectPulsing`.
- `aStagedMultiRoomConnectCoalescesIntoOnePulse` (511) → two `playConnectPulse` calls (drain between) → `test_pulsesStarted == 1`; first call `cameToLife: true` with departure `== 1`.
- `reduceMotionRemovesThePulseEntirely` (538), `aMidFlightReduceMotionToggleCancelsThePulse` (549), `anAccentDialChangeCancelsThePulse` (565), `aDormantWireNeverPulses` (579) → trigger swap; the dormant test keeps `overlay.dormant = true` and now exercises Step 2's `!plan.dormant` guard. ADD the sibling: an idle wire (`hook.gold = false`) never pulses (Step 2's `plan.gold` guard).

KEEP UNCHANGED: `fractionMapsAYPositionOntoTheWire` (283), `theHeaderDotBloomMountsWithASettledModel` (339), and the five ring-bloom tests (`theRingBloomMountsWithASettledModel` 399, `reduceMotionRemovesTheRingBloom` 408, `aMidFlightReduceMotionToggleCancelsTheRingBloom` 417, `anAccentDialChangeCancelsTheRingBloom` 430, `anOffScreenRingNeverBlooms` 441), plus `makeScene`/`makeRing`/`drainMainQueue`/`polls` helpers.

### Step 7 — New controller-level regression suite
New file: `AudioutCore/Tests/AudioutCoreTests/RailConnectPulseControllerTests.swift`, `@MainActor @Suite(.serialized)`, harness copied from `PopoverDeviceVisibilityTests.makePopover` (25-43) and its device fixtures (45-57). In the harness, after `test_isShownOverride = true`, also set `popover.test_railOverlay().test_windowVisibleOverride = true` and `.test_reduceMotionOverride = false`. Observable = `popover.test_railOverlay().test_pulsesStarted` (monotonic — capture before, assert delta). After each `update(devices:)` that could fire, run `popover.test_applyExactFitSize()` then drain the main run loop (the `RunLoop.main.run(until:)` idiom) so the deferred overlay block executes against settled layout. Membership: select the AirPlay device through the `GroupController` returned by the harness before the first update. The FIRST `update(devices:)` call is the baseline-stamping one (`lastConnectedMemberIDs` nil → store, never fire) — exploit that to build already-connected fixtures without a setup pulse. Tests:
1. **A genuine connect fires exactly one pulse.** Select "office"; `update([local, office(.off)])` (baseline); `update([local, office(.connecting)])` → delta 0; `update([local, office(.connected)])` → delta 1, and `test_lastPulseDeparture == 1` (previous member set was empty → came-to-life).
2. **A second room joining an armed spine fires once, from its node.** First update already contains connected member A (baseline, no fire); select B; updates B `.connecting` (delta 0) then `.connected` → delta 1; `test_lastPulseDeparture < 1` (proves the `railDeviceID` mapping end to end).
3. **Subsection collapse/expand fires nothing** — the live bug this refactor exists for. Fixture: connected member (via the first-update baseline). `test_fireSubsectionHeaderClick(title: PopoverController.airPlaySubsectionTitle)` twice (collapse then expand), drain → delta 0.
4. **Card collapse/expand fires nothing.** Same fixture; `test_toggleCard(title:)` with the OUTPUT DEVICES card's title twice, drain → delta 0.
5. **Reopen fires nothing, even after a connect that happened while hidden.** Baseline shown; `test_isShownOverride = false`; update adding a NEW `.connected` member (hidden → no fire, baseline advances); `test_isShownOverride = true`; `test_simulateOpen()`, drain → delta 0. Then one more genuine join while shown → delta 1 (live behavior resumed).
6. **Mute and leave fire nothing.** Update flipping `isMuted` on the connected member → delta 0; update taking it to `.off`/deselected → delta 0.

### Step 8 — Docs
- `AudioutCore/Sources/AudioutPopoverUI/AGENTS.md`: add ONE bullet (near the Energize bullet) recording the new contract: the rail connect pulse fires from `update(devices:)`'s connected-member diff (`lastConnectedMemberIDs`; predicate `isMainOutMember ∧ .connected`; baseline advances while hidden, so a reopen can never fire) through `panel.playRailConnectPulse` → `BusRailOverlayView.playConnectPulse`; the overlay is render-only for the pulse, so collapse/expand/rebuild/open cannot fire it by construction; the editor host never calls it.
- The `BusRailOverlayView` class-doc rewrite is part of Step 3.

## Out of scope — do not touch

- `PopoverController.reconcileEnergize()` / `beginEnergize` / `energizePendingIDs` — the item-9 pending-beat system (name collision; unrelated).
- The settled-wire drawing and geometry: `drawPlan`, `wireRuns`, `RailPlan.resolve`'s terminus/cut logic, the `dropsHiddenRows` path, `updateRailRows`, `setRailRows`, `dropSubsectionRowModel`.
- `runConnectPulse` internals (do not rename `strokeWindow` back, do not replace the Timer handoff with `CATransaction` completions — CA completions never fire headless), `runHeaderDotBloom`, `HaloRingView`, `MainOutRowView`, `MembershipBusView`.
- `GroupEditorViewController`, `MainOutDetailViewController`, `GroupController`, any backend file, `AppDelegate`.
- `BusRailCollapseResolveTests.swift`, `PopoverDeviceVisibilityTests.swift`, `MembershipRailTests.swift`, `PopoverControllerTests.swift` — unchanged; they must pass as-is.
- No new abstractions (no protocol for the forwarder, no observer/event bus), no `DispatchQueue.main.async` anywhere in this path, no extra layout calls inside the overlay, no RM gate on the controller side (motion policy is the overlay's), no bare `swift build`/`swift test`, no `git commit`/stash/checkout — leave the worktree uncommitted exactly as found plus your edits.
- Do not "fix" adjacent things: the `.iconOnly` toolbar rule, the fold system, the surplus shield, snapshot PNGs.

## Verification

Baseline (already true before this change, recorded 2026-08-22): the filtered command below passed with **91 tests in 4 suites, exit 0**.

Run, in this worktree, in order:
1. `bash scripts/build.sh` → compiles clean.
2. `bash scripts/run-tests.sh --filter 'RailConnectPulseTests|RailConnectPulseControllerTests|BusRailCollapseResolveTests|PopoverDeviceVisibilityTests|MembershipRailTests'` → all pass (expect MORE than 91 tests now: the new controller suite adds ~6, the rewrite deletes ~11 and adds ~2).
3. `bash scripts/run-tests.sh` → FULL suite passes (last known full-suite size ~2537; the exact count printed must be all-pass, exit 0).

Done = commands 1–3 run in the executor's session with their real output pasted. A claim without the pasted output is not done.

## Execution plan

One track, SERIAL, executed IN THIS WORKTREE (`.claude/worktrees/rail-animation-bugs-89dd1a`) — the branch has UNCOMMITTED work in the exact files this refactor edits (`BusRailOverlayView.swift`, `PopoverPanelViewController.swift`, both rail test files), so a fresh isolated worktree would fork from the last commit and LOSE the current state. No parallelism is possible: every step feeds the next through the same two files.
- Track A (Steps 1–8): model **opus**, effort **medium** (multi-file surgery with a name-collision trap, but zero design decisions remain — everything is specified). Files: the 6 source/test files named above + `AudioutPopoverUI/AGENTS.md` + 1 new test file.

## Risks / watch-outs

- **`reconcileEnergize` name collision** — the controller's own (PopoverController.swift:1662) stays; only the overlay's `reconcileEnergize(with:)` dies. Grep after Step 3: `BusRailOverlayView.swift` must contain no `reconcileEnergize`, `EnergySignature`, `energizeSignature`, `connectPulseFires`, `lastEnergy`, `lastMemberYs`, `settleBaseline`, or occlusion observer; `PopoverController.swift:1662` must be untouched.
- **Deferred-block timing**: `playConnectPulse` resolves the plan inside its `RunLoop.main.perform` block. In production this runs after `update(devices:)` returns, i.e. after any rebuild + the synchronous exact-fit layout — verified above. In tests, forgetting `test_applyExactFitSize()` + a run-loop drain makes plans resolve against un-laid-out rows: fix the test, not the overlay.
- **Close-mid-bead**: the removed occlusion observer also used to cancel an in-flight bead when the window ordered out. Post-refactor, a bead in flight when the popover closes finishes invisibly and self-removes on its own ~0.7 s timers; a reopen inside that window could briefly composite a stale bead over rebuilt rows. Accepted by the design (beads are sub-second, reopen ritual is slower in practice) — do NOT re-add an occlusion observer for it.
- **Behavior deltas that are INTENDED** (do not "fix" if a test or reviewer notices): unmute no longer pulses (member set unchanged — old code pulsed on the gold flip); a Main-Out target switch onto already-connected devices pulses on the NEXT backend snapshot rather than the same turn; the Groups editor never pulses at all.
- If any Verified fact above contradicts what you find in the files, STOP and report — do not adapt around it.

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
