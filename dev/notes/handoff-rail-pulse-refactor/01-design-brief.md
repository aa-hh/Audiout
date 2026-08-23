# Design brief — event-driven rail connect pulse (for scoping)

You are scoping a refactor of the macOS popover's rail **connect pulse**. Produce a
paint-by-numbers work order that an executor can apply WITHOUT judgment calls:
exact files, exact symbols to remove/add, exact edit locations (with current
line anchors), and the test plan. Ground every claim against the real code —
verify the controller hook, the `RailNodeProviding` conformer(s), and the exact
current symbol set before writing the order. Do NOT write code changes yourself;
produce the order.

Work is on branch `claude/rail-animation-bugs-89dd1a` in THIS worktree, on top of
current UNCOMMITTED changes. Read the current state of the files, not `main`.

## The problem (why we're refactoring)
`BusRailOverlayView` (AudioutCore/Sources/AudioutSharedUI/BusRailOverlayView.swift)
INFERS when to fire the connect pulse by diffing an "energize signature" between
consecutive `draw(_:)` passes: `reconcileEnergize`, `connectPulseFires`,
`energizeSignature`, `EnergySignature`, `lastEnergy`, `lastMemberYs`. The signature
is derived from `deviceRows` (the on-screen row set). This is fundamentally
fragile: `deviceRows` changes for reasons that are NOT connections — popover
open/rebuild, and especially subsection collapse/expand, which DROP rows from the
model (`PopoverController.dropSubsectionRowModel` + `updateRailRows`) and re-add
them. Each such change reads as a membership "gain" and fires a spurious pulse.
It's whack-a-mole; we want to end the class.

## The goal / architecture
Fire the pulse from the MODEL EVENT — a device actually transitioning to a
connected member — not from a view draw-diff. Layout changes then can't trigger it
by construction.

1. **`PopoverController` detects the transition.** In the device-update path
   (`update(devices:)` and wherever per-device connection/member state is
   recomputed — find the real spot), compute the current set of MEMBER device IDs =
   members of the active Main Out target AND connected. Use the SAME model predicate
   that decides a `.member` node (e.g. `isMainOutMember(id)` + the device's
   connection state) — do NOT derive it from `deviceRows`/the row views. Diff
   against a stored previous member set:
     - `newlyJoined = current − previous`.
     - If `newlyJoined` is non-empty, tell the rail to play a pulse; pass
       `cameToLife = previous.isEmpty` (the wire was idle → whole bus lights up).
     - Store `current` as the new previous.
   - The previous member set MUST persist across popover open/close and
     `rebuild()`/`rebuildForOpen()` (it is model state) — so opening a panel with
     already-connected speakers is NOT seen as a join. Find where controller
     instance state lives that survives a rebuild (device model does; the row views
     do not).
   - Because membership comes from the model, collapse/expand (which only touch
     `deviceRows`) produce an UNCHANGED member set → no fire. That is the fix.

2. **`BusRailOverlayView` becomes render-only for the pulse.**
   - REMOVE: `reconcileEnergize`, `connectPulseFires`, `energizeSignature`,
     `EnergySignature`, `lastEnergy`, `lastMemberYs`, `settleBaseline`, the
     `draw(_:)` call to `reconcileEnergize`, and everything that existed ONLY to
     manage the diff baseline — the `NSWindow.didChangeOcclusionStateNotification`
     observer + `windowOcclusionStateDidChange`, and the `settleBaseline()` calls in
     `viewDidMoveToWindow`/`accessibilityDisplayOptionsDidChange`/`accentStyleDidChange`
     (KEEP the RM + accent-dial CANCEL of an in-flight pulse). Remove
     `RailPlan.memberYs` (added only for the diff) and its population in
     `RailPlan.resolve`. Remove the now-dead test hooks tied to the diff
     (`test_reconcileEnergize`, and any signature/energy test hooks) — grep and list
     them.
   - ADD a public entry point the panel forwards to, e.g.
     `func playConnectPulse(joinedDeviceIDs: Set<String>, cameToLife: Bool)`. It must:
     guard `windowIsVisible && !reduceMotion`; build the wire path from the current
     settled plan (`wireRuns(for:)` on `resolvePlan()`); compute the departure —
     `cameToLife` → `1` (whole wire from the terminus); else → the MAX
     `fraction(atY:along:)` over the joined devices' node Ys (map each id → its row
     via `deviceRows` + the new `railDeviceID`, convert `railNodeBounds`), fallback
     `1`; then call the existing `runConnectPulse(...)`. Defer the work with
     `RunLoop.main.perform` (as the current code does) so geometry is settled at
     play time.
   - KEEP UNCHANGED: settled-wire drawing (`draw`/`drawPlan`/`wireRuns`/
     `appendVertical`/`fillTerminusDot`), the collapse-reactive geometry INCLUDING
     the `dropsHiddenRows` cut and `RailPlan.resolve`'s terminus logic,
     `runConnectPulse` (incl. the in-flight COALESCE guard `guard pulseLayer == nil`,
     the `strokeWindow` param, `test_pulsesStarted`), `runHeaderDotBloom`,
     `cancelConnectPulse`, `fraction`/`length`, `RailHookProviding.receiveRailPulse`
     (ring bloom), the RM/accent-dial cancel.

3. **`RailNodeProviding` gains `var railDeviceID: String? { get }`** so the overlay
   maps a joined device id → its stop for the departure. Find and update every
   conformer (the device row view(s) that provide `railNode`). If a conformer has no
   device id (e.g. a stub), return `nil`.

4. **`PopoverPanelViewController`** keeps `setRailRows` for geometry
   (deviceRows/sections/`dropsHiddenRows`). ADD a thin forwarder so the controller
   can reach the overlay's `playConnectPulse` (e.g. `func playRailConnectPulse(
   joinedDeviceIDs:cameToLife:)` → `railOverlay.playConnectPulse(...)`).

## Target behavior
- A speaker genuinely connecting → exactly ONE pulse. Wire coming to life (was
  idle) → from the terminus (whole wire, "up and out"). A single new room joining an
  already-live wire → from that room's node. A burst (several rooms within one
  pulse's flight) → coalesced to one (existing `runConnectPulse` guard).
- NO pulse on: popover open/reopen, subsection OR card collapse/expand, resize,
  occlusion change, rebuild, mute/unmute with no membership change, a room LEAVING,
  dormant/idle wires, Reduce Motion. RM / accent-dial change mid-flight still
  cancels the bead.

## Tests (all via `scripts/run-tests.sh`; full suite must pass)
- Rewrite `RailConnectPulseTests` firing tests to drive `playConnectPulse` instead
  of `test_reconcileEnergize`/signatures. Keep & adapt the render/behaviour tests:
  came-to-life departs from terminus; single join departs from its node; burst
  coalesces to one pulse (`test_pulsesStarted == 1`); RM removes/cancels; accent
  cancels; ring bloom; header-dot bloom; settled-model contract; presentation
  animates. DELETE the pure `connectPulseFires`/`energizeSignature` unit tests (gone).
- ADD controller-level regression tests through `PopoverController` seams
  (`test_simulateOpen`, `update(devices:)`, `setDeviceSelected`,
  `test_fireSubsectionHeaderClick`, `test_toggleCard`): a subsection collapse/expand,
  a card collapse/expand, and a popover reopen each trigger ZERO pulses; a genuine
  member transition triggers exactly ONE. This is the regression net for the class.
  Identify a clean way to observe "a pulse was requested" at the controller boundary
  (e.g. assert on the overlay's `test_pulsesStarted`/`test_isConnectPulsing`, or a
  spy on the panel forwarder).
- Keep `BusRailCollapseResolveTests` and `PopoverDeviceVisibilityTests` (geometry) —
  the `dropsHiddenRows` cut and terminus logic are unchanged by this refactor.

## Constraints / traps
- NEVER a bare `swift build` / `swift test` — always `scripts/build.sh` /
  `scripts/run-tests.sh` (they own the remote mule + cache).
- Keep the earlier fixes intact: the `dropsHiddenRows` geometry cut, and
  `runConnectPulse`'s `strokeWindow` rename + `self.window` guard. Do NOT revert them.
- Other overlay hosts (GroupEditorViewController, MainOutDetailViewController) must
  still compile and behave — they simply never call `playConnectPulse`. Confirm
  removing the draw-time reconcile doesn't break them (their `receiveRailPulse` in
  the group editor is already a no-op).
- CA completion callbacks don't fire without an app commit loop (headless tests) —
  keep the existing `Timer.scheduledTimer` handoff/cleanup; do NOT switch to
  `CATransaction` completions.
- Keep the settled-model-layer contract (bead/bloom model fully absorbed; only the
  presentation animates) so `cacheDisplay` snapshots stay deterministic.
- The `mainOutRow` gold/arming (`isSpineLive`) still drives the wire TONE (gold vs
  ember) in drawing — that stays; only the pulse FIRING moves to the model event.
