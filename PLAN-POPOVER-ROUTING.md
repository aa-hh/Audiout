# PLAN — Popover per-app routing + collapsible sections + exact-fit sizing

*2026-07-16. Decisions confirmed with Alec this date; supersedes the "Future (v2):
Applications section" note in SPEC.md §9. Task format follows PLAN-PHASE-1/2.*

## A. End state (one paragraph)

The popover gains a third card, **Applications**, rendered last (below Selected
Devices): one row per user-routed app (app icon · name · always-visible volume
slider, dimmed while local · "redirect audio to…" `NSPopUpButton` sectioned
**Current device / AirPlay devices**), plus a full-width "+ Add application…"
row that doubles as the empty state and opens a running-app picker
(`NSWorkspace`, `.regular` apps only). Every section title gets a leading
chevron; chevron **or title** click collapses/expands the card body with an
animated popover resize. Collapse defaults are recomputed on every open —
System + Selected Devices expanded, Applications collapsed unless ≥1 app is
redirected — and manual toggles never persist. The `NSScrollView` is removed:
the popover is exactly its content height, **no scrollbar ever**, and grows/
shrinks with expansion state.

## B. Resolved decisions (Alec, 2026-07-16) — authoritative

1. **Scope: UI + model + persistence only.** Wired against `MockBackend`; no
   `OutputBackend` changes. Redirects persist and render but move no audio until
   the native engine supports per-app streams (per-process taps already proven
   in `dev/audiocap`; `CaptureCoordinator` is single-global-tap today).
2. **Ownership: new `AppRoutingController`** (sibling of `GroupController`, NOT
   folded into it), backed by a new versioned-JSON `AppRouteStore` mirroring
   `RoutingStore`.
3. **Per-app volume: always visible, dimmed/disabled while destination is
   "Current device"** (matches `DeviceRowView` dimming + shared column grid).
4. **Per-app menu = Current device / AirPlay devices only — no Groups.** Main
   Out's existing Output Groups entries stay as-is.
5. **Collapse toggle target: chevron + section title** (rest of header inert).
6. **Add affordance: in-card full-width "+ Add application…" row** (hover-action
   style), not a header "+" button.
7. **Lost device: silent fallback.** If a route's target device disappears, the
   route resets to Current device (persisted). No greyed placeholder.
8. **"Current device" == "no redirect"** — the app plays locally; there is no
   separate no-redirect state.

## C. Task list

**T-1 — `AppRoute` + `AppRouteStore`** *(sonnet / low)*
New `Sources/AirPlayControllerCore/AppRouteStore.swift` mirroring
`RoutingStore.swift`: `AppRoute` (bundleID identity, displayName, destination
`.currentDevice | .device(id:)` flattened for Codable, volume 0–100 default
100), injectable directory, `app-routes.json`, schemaVersion 1, newer-schema →
treated missing. New `AppRouteStoreTests` (round-trip, missing file, future
schema, clamp).

**T-2 — `AppRoutingController`** *(sonnet / medium)*
New `Sources/AirPlayControllerCore/AppRoutingController.swift`: holds
`private(set) appRoutes`, `setAppRoute`/`setAppVolume`/`removeAppRoute`,
`routedAppCount` (destination != currentDevice), persists every mutation,
`handleDeviceUnavailable(id:)` → resets affected routes to `.currentDevice`
(decision 7). Tests for all of the above.

**T-3 — Exact-fit popover: remove `NSScrollView`, animated resize** *(opus / high)*
`PopoverPanelViewController.swift` + `PopoverController.swift`. Pin the stack
directly (no scroll view, no scroller chrome), `fittingSizeSettled()` helper
(`layoutSubtreeIfNeeded()` → `fittingSize`), size the popover via the documented
`preferredContentSize` tracking channel (explicit `contentSize` as fallback),
animate in a single `NSAnimationContext` group; non-animated path for initial
show + Reduce Motion; animator proxies so rapid toggles retarget smoothly.
Must not reintroduce the empty-popover Auto Layout trap (see comment at
PopoverPanelViewController loadView); remove/no-op `scrollToTop` + its
`toggle()` call site. Exposes the resize primitive T-4 consumes.

**T-4 — Collapsible-card infrastructure** *(opus / high)*
`PopoverPanelViewController.swift` + `CardView.swift`. Leading chevron
(`chevron.down`/`chevron.right`) + clickable title (decision 5);
`beginCard(..., collapsible:collapsed:onToggle:)`. Collapse = clip-container
height animation + body fade, `isHidden` only after completion; same animation
group as the popover resize (T-3). Must not strand `DeviceRowView`-style hover
monitors on hidden rows.

**T-5 — Collapse-default policy** *(sonnet / low)*
`PopoverController.swift` `rebuild()`: defaults recomputed per open (System +
Selected Devices expanded; Applications expanded iff
`appRoutingController.routedAppCount > 0`); manual toggles held in transient
state discarded on next open.

**T-6 — `AppRowView` + Add row** *(sonnet / medium)*
New `Sources/AirPlayControllerSharedUI/AppRowView.swift` on `PopoverColumnGrid`:
icon · truncating name · `ControlCenterSlider` (dimmed when local, decision 3) ·
% · sectioned popup (disabled-header style per `MainOutRowView`). Delegate:
didSetVolume / didSelectDestination / didRemove (hover-revealed ✕,
`HoverActionButton` idiom). Takes plain values — no dependency on Core's
`AppRoute`. Plus the "+ Add application…" row (decision 6). `test_*` hooks +
tests. **Truncation check at 623 pt: report, don't widen (Alec).**

**T-7 — Running-app picker** *(sonnet / medium)*
`PopoverController.swift` + injectable `RunningAppsProvider` (closure over
`NSWorkspace.shared.runningApplications`, `.regular` only). Picking an app
creates a route (destination `.currentDevice`) and rebuilds.

**T-8 — Wire the Applications card** *(opus / high)*
`PopoverController.swift`: third `beginCard` after Selected Devices; rows from
`appRoutes`; delegate → `AppRoutingController`; destination menu from the
local/AirPlay device split (mirrors `refreshMainOutRow`); `deviceRemoved`/
unavailable → `handleDeviceUnavailable`. Panel stays a pure function of
controller state.

**T-9 — Harness + snapshot coverage** *(sonnet / medium)*
`popover-harness` assertions (card present + last, collapse defaults, menu
sections, no scroller) and `popover-snapshot` scenes seeded with routes
(collapsed + expanded), proving no scrollbar sliver.

**T-10 — Test hooks + XCTest** *(sonnet / medium)*
`PopoverController` `test_*` hooks (app rows, destinations, collapse state) +
`PopoverControllerTests` cases: exact-fit height, collapse defaults, add-app,
menu sections, lost-device fallback.

**T-11 — App wiring** *(haiku / low)*
`AppDelegate.swift` (+ harness/snapshot mains): construct `AppRoutingController`
with the production store, inject into `PopoverController`. No `Package.swift`
changes expected (new files land in existing targets).

**T-12 — Docs** *(sonnet / low)*
SPEC.md §9 (Applications section shipped; collapsible sections; exact-fit
no-scroll sizing; decisions 1–8) + `AirPlayControllerCore/AGENTS.md`
(`AppRoutingController`, `AppRouteStore`).

## D. Parallelization — waves, hot files, critical path

Hot file: `PopoverController.swift` (T-3, T-5, T-7, T-8, T-10) — serialize.
`PopoverPanelViewController.swift` (T-3 → T-4) serialized by dependency.

- **Wave 0 (parallel):** T-1 · T-6 · T-3
- **Wave 1 (parallel):** T-2 (after T-1) · T-4 (after T-3)
- **Wave 2 (serialized, same file):** T-5 → T-7
- **Wave 3:** T-8 (∥ T-11)
- **Wave 4 (parallel):** T-9 · T-10 · T-12

**Critical path:** T-3 → T-4 → T-5/T-7 → T-8 → T-10.

## E. Risk mitigations (agreed 2026-07-16)

1. **Resize jank (T-3):** one animation drives everything — card clip-height
   constraint + popover size change in the same `NSAnimationContext` group,
   same duration/curve; layout settled synchronously before animating; prefer
   the `preferredContentSize` channel; clip + fade instead of hide; Reduce
   Motion + non-animated fallback path; animator proxies for retargetable rapid
   toggles; end-state size assertions in tests (smoothness verified live by
   Alec).
2. **Hover monitors (T-4/T-6):** replicate `DeviceRowView`'s monitor discipline;
   collapsing must clear/park hover state on hidden rows.
3. **623 pt width (T-6):** if app names over-truncate, flag to Alec — do not
   widen the panel.
4. **Engine-honesty:** out of scope here (handled separately by Alec).

## F. Verification

From `AirPlayControllerCore/`: `swift build`, `swift test`,
`swift run popover-harness`, `swift run popover-snapshot` (PNGs must show no
scrollbar sliver). Live look: `AIRPLAY_DEBUG_POPOVER_PNG` hook.
