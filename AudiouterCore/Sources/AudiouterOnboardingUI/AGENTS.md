# AudiouterOnboardingUI

## Purpose

The first-run onboarding/permission-priming window (pure AppKit). A single
screen — welcome header, reassurance copy, a card of permission rows, a Done
footer — that reframes the OS's "recording" language before any TCC prompt
fires, and (unlike the popover/window/settings surfaces) is also re-shown
later if a required permission gets revoked. All permission logic (probes,
`PermissionStatus`, `SetupModel`) lives in Core; this folder only renders
status and forwards taps. Keep this file up to date when a row is added or
removed, when the required-permission set changes, or when the polling/banner
behavior changes.

## Rules

- Three surfaces, not four: **System Audio** and **Local Network** are real
  `PermissionStatus`-backed TCC probes; **Remote Control** (Accessibility) is
  primed ahead of a not-yet-shipped feature, included now to avoid a cold
  third prompt later; the **PTP helper** row is a `PTPHelperStatus`
  (`SMAppService` Login-Items approval), not a TCC permission at all — it has
  no "Denied" state and registers automatically at load with no prompt of its
  own.
- `OnboardingReason` drives whether the `.permissionLost` warning banner
  renders: `.firstRun` (default, every existing call site) is unchanged;
  `.permissionLost([RequiredPermission])` is used when `SetupModel.auditRequiredPermissions()`
  finds a REQUIRED permission (Remote Control is deliberately excluded — it's
  an enhancement, not a requirement) revoked after setup already completed.
  The banner re-words itself to the still-missing subset and hides once every
  permission it named is granted, without expanding to cover anything it
  didn't originally flag.
- Accessibility and the PTP helper can only be confirmed by a silent poll, not
  a single re-focus check: `OnboardingViewController` runs
  `remoteControlPoll`/`ptpHelperPoll` `Timer`s (~1.5s) while the window is
  open, each stopping once its status flips to granted/`.enabled`.
  `OnboardingWindowController` additionally re-fronts the window and calls
  `refreshStatuses()` on `NSApplication.didBecomeActiveNotification`, so
  returning from System Settings updates the rows even without the poll.
- Done and ✕ are NOT equivalent: both call `dismiss()` exactly once
  (single-fire guard) and both fire `onFinished`, but only Done calls
  `SetupModel.complete()`. Closing with ✕ leaves setup incomplete so the flow
  reappears next launch. Setup is "guidance, not a gate" — Done still asks
  "Continue Anyway?" via a sheet when a required permission is ungranted, but
  never hard-blocks finishing.
- The window is deliberately `.floating` while open (owner decision
  2026-08-07, punch-list W10 — this REVERSES an earlier reversal, so read the
  history before touching it). The first floating version was demoted to
  normal level because it read as "the setup keeps popping up"; the
  normal-level compromise then relied on `NSApp.activate(ignoringOtherApps:)`
  re-fronts, which macOS 14's cooperative activation may decline while another
  app is frontmost — so granting a permission left the window buried, which
  the owner judged worse. Floating is bounded two ways: the window exists only
  for a summoned flow that dies at Done/✕, and the reactivate hook takes key
  ONLY when no other window in the app holds it (`keyWindowProvider` seam), so
  it never yanks focus from Settings. The per-Allow re-fronts in
  `allowAudio()`/the network `onAllow` stay — they restore keyboard focus
  after a TCC prompt; floating only guarantees visibility.
- `present()` sizes and centers on the FIRST call only — a re-present (the
  `presentSetup` re-entry guard, "Open Setup…" while open) must not
  re-center a window the user moved.
- Remote Control's "Open Settings…" action re-fires the Accessibility system
  PROMPT (`model.primeRemoteControl()`) rather than deep-linking to the pane —
  its own "Open System Settings" button is the only path that scrolls to/
  highlights Audiouter in the list; macOS gives no URL way to do that.
- The trailing accessory column (`PermissionRowView.accessoryColumnWidth`,
  184pt) is a fixed width so the text column's wrap boundary never moves
  between states (Allow… → Requested + Open Settings) — changing that
  constant without checking every status string still fits will reintroduce
  layout shift.
- `ProminentButton` exists only to fix a real AppKit bug: a `bezelColor` fill
  drops to plain bezel when its window resigns key but does NOT recolor the
  (forced-white) title to match, so it goes white-on-white. It tracks
  key-window state itself rather than being made a true default button,
  because a window has only one Return-default and this screen has several
  "Allow…" CTAs.
- Stock AppKit only (SF Symbols, `NSButton`, `NSProgressIndicator`, system
  colors) per repo house rules — the only custom drawing is `IconTileView`
  and `RoundedContainerView`, which have no stock equivalent for the System
  Settings grouped-inset-list look.
- `test_` hooks throughout (`test_applyStatuses`, `test_tapDone`,
  `test_resolvePendingConfirmation`, `test_rootView`, per-row
  `test_buttonTitles`) exist because this window isn't visible to a headless
  harness; the Done confirmation sheet in particular has no window to host on
  in tests, so it stashes a pending confirmation instead of presenting.
- Per-row tile colour lives ONLY in `Tokens.Color` (never a hardcoded
  `NSColor`) and tints the SF Symbol GLYPH only, via `IconTileView`'s `color`
  param — the tile fill and rim stay `Tokens.Color.raised`/hairline on every
  row, so don't colour the tile itself.
- The glyph tint is PERMANENT across every status (Alec, 2026-08-11) — the
  "Allowed"/"Enabled" status chip alone carries state; don't reintroduce a
  granted-state recolour (the old grant-goes-gold crossfade was removed as
  redundant). The four tints are dial-aware in `.subtle` only and must NEVER
  route through `accentDynamic`, which collapses distinct hues into one
  accent.
- `PermissionRowContent.iconColor` has no default, so every call site picks
  explicitly rather than inheriting a stale colour.

## Feature Flow

1. App constructs `OnboardingWindowController` with a `SetupModel` and a
   reason (`.firstRun` or `.permissionLost`); `present()` activates the app
   and centers the window.
2. `OnboardingViewController.viewDidLoad()` binds `model.onChange`, calls
   `refresh()` + `refreshStatuses()` (silent — never springs an unrequested
   prompt), registers the PTP helper unconditionally, and starts both polls.
3. User taps a row's "Allow…" — routes to the matching `SetupModel` probe
   (`requestAudioCapture()`, `primeLocalNetwork()`, `primeRemoteControl()`),
   which may trigger a real TCC prompt; the window re-activates itself after.
4. `model.onChange` fires → `refresh()` repaints all four rows and
   `refreshPermissionLostBanner()` re-evaluates the banner.
5. Returning from System Settings (`didBecomeActiveNotification`) re-fronts
   the window and re-reads live status; the polls independently catch
   Accessibility/PTP grants made without a focus change.
6. Done taps: if every required permission is granted, finishes immediately;
   otherwise shows a "Continue without every permission?" sheet before
   finishing. ✕ finishes without persisting completion.
7. `finish()`/`dismiss()` fire `onFinished` exactly once, unbind
   `model.onChange`, and close the window — the app starts the (deferred)
   backend from `onFinished`.

## Map

| Type | What it is |
|---|---|
| `OnboardingWindowController` | Owns the window; lazy-create-then-reuse lifecycle; Done-vs-✕ dismissal contract; reactivate re-front. |
| `OnboardingViewController` | Assembles header/reassurance/permission-card/footer; binds `SetupModel` status to rows; owns both polling timers. |
| `OnboardingReason` | `.firstRun` vs `.permissionLost([RequiredPermission])` — drives the warning banner. |
| `PermissionRowView` | One TCC-backed row (audio/network/remote-control); trailing accessory swaps by `PermissionStatus`. |
| `PTPHelperRowView` | The PTP helper daemon row; trailing accessory swaps by `PTPHelperStatus`, no "Denied"/probing states. |
| `SystemSettingsOpener` | `NSWorkspace` seam for opening a `SystemSettingsPane`, with a Privacy & Security root fallback. |
| `ProminentButton` | Accent-filled CTA button with key-window-aware title color. |
| `IconTileView` / `RoundedContainerView` | Shared appearance-adaptive chrome (icon chip, grouped-inset card) — no stock AppKit equivalent. |

## Tests

| File | Focus |
|---|---|
| `AudiouterCore/Tests/AudiouterCoreTests/OnboardingUITests.swift` | Row status rendering, Done/confirmation-sheet flow, `.permissionLost` banner behavior, structural `test_` hooks. |
| `AudiouterCore/Tests/AudiouterCoreTests/SetupModelTests.swift` | The underlying `SetupModel` probes/status this UI binds to (not this folder, but the seam it depends on). |
| `AudiouterCore/Tests/AudiouterCoreTests/OnboardingPermissionColorTests.swift` | The four per-row tile colours: distinctness, contrast floors, tint permanent across statuses, tile fill unchanged. |
