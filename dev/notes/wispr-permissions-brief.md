# Wispr-style permission flow — design brief

Shaped and confirmed with Alec 2026-08-11 (one correction round: the Reduce
Motion rule). No code written yet. Branch: `claude/wispr-flow-permissions-f1a9a3`.
Scope: the permission-granting interaction ONLY — no other onboarding content.

## Decisions (Alec, 2026-08-11)

1. **Hard gate (full Wispr).** Done is absent — not disabled — until every
   required grant verifies. This REVERSES the documented "setup is guidance,
   not a gate" decision: update `SetupModel.complete()`'s doc comment,
   `AudiouterOnboardingUI/AGENTS.md`, and remove the "Continue without every
   permission?" sheet in the same change.
2. **Demo medium: native-drawn AppKit mock** — a miniature System Settings
   pane / permission dialog drawn in code, not a screen recording. Adapts to
   light/dark, never goes stale across macOS 14–26.
3. **Layout: two-pane window (~800pt).** Sequential cards left, demo pane
   right, on the Warm Signal canvas in the System Settings visual language.
4. **Demo motion rule:** Reduce Motion off → the active step's demo loops
   continuously (only while the window is visible and the step is active;
   stops when occluded — zero idle CPU still holds). Reduce Motion on → the
   demo plays ONCE, then shows a replay button. All other choreography
   (card expand, checkmark) is instant under Reduce Motion per house rules.
5. **Bluetooth joins the flow** (Alec, mid-shape): today the BT prompt fires
   right AFTER setup — onboarding defers `backend.start()` until the window
   closes, and the backend's BT enumerator asks on startup. Jarring. It
   becomes its own card, and a skipped/denied card must ALSO stop the
   post-setup auto-ask (defer to the user's first Bluetooth interaction).

## The flow — one window, five sequential cards

| # | Card | Verify signal (all already built) | Notes |
|---|------|-----------------------------------|-------|
| 1 | System Audio | `CoreAudioTonePermissionProbe` (audible tone, tap held up to 60 s while the prompt is up) + `PermissionStateObserver`/`TCCProbeRunner` for grants made in Settings | The scary one — copy pre-warns about the "screen recording" framing and the beep |
| 2 | Local Network | `LocalNetworkPrimer` browse succeeding — advance shows "Found N speakers", a better proof than a checkmark | Auto-passes (card pre-completed) on macOS 14 via `osGatesLocalNetwork`. Can NEVER prove denial — see gate consequences |
| 3 | Bluetooth | `CBManager.authorization` — sync, prompt-free, and the ONLY permission here with a full honest status API (granted/denied/undetermined all real). Prompt fires via `BTAuthorizationRequest` (exists, `BTDeviceEnumerator.swift`), whose `onDecided` callback IS the advance signal — no polling | SKIPPABLE. Skipped or denied → the enumerator must not auto-ask at backend start; it defers until the user first touches a BT feature (ungranted IOBluetooth is already a safe no-op behind `isBluetoothAuthorized()`) |
| 4 | Speaker Sync | Existing 1.5 s `SMAppService` status poll | Login Items approval, not TCC |
| 5 | Remote Control | Existing 1.5 s `AXIsProcessTrusted` poll | OPTIONAL — skippable; stays excluded from required |

## Card anatomy & choreography (the Wispr pattern)

- Inactive cards collapse to a title-only strip; exactly ONE Allow button on
  screen at a time. Completed cards stay collapsed with a checkmark.
- On grant, in order: window pulls itself to front (the user is in System
  Settings / the TCC prompt at that moment), checkmark slides in, card title
  rewrites from imperative to earned capability, next card expands and the
  demo pane swaps.
  - Title pattern per step, imperative → capability (final strings are the
    builder's, Alec reviews): "Let Audiouter hear your Mac's sound" →
    "Audiouter can now hear your Mac's sound". Existing row detail copy is
    reused as the card description.
- Allow is two-mode (Wispr's trick): first click fires the native prompt /
  probe; every later click deep-links to the right Settings pane
  (`SystemSettingsPane`). Remote Control keeps its no-deep-link exception
  (re-prime is the only path that highlights the app row).
- Spinner on the active card while probing (`isProbingAudio` etc.).
- Keyboard: Return fires the active card's Allow; once Done exists, Return
  is Done.
- Expand/collapse uses the house collapse language (0.15 s, `.easeInEaseOut`
  — the `collapseRevealDuration` precedent; onboarding currently shares no
  constant with it, see punch-list V10 before minting a new one).

## Demo pane spec

- Right pane hosts a native-drawn miniature of the EXACT surface for the
  active step's current mode:
  - Prompt mode (first Allow): the permission dialog with a cursor moving to
    and pressing Allow/OK.
  - Settings mode (retry / after denial): the relevant Settings pane with the
    Audiouter row's toggle animating on — System Audio Recording Only
    section, Local Network list, Privacy & Security ▸ Bluetooth, Login
    Items, Accessibility respectively. (Bluetooth retry should deep-link to
    the PRIVACY Bluetooth pane — `?Privacy_Bluetooth` — not the existing
    `SystemSettingsPane.bluetooth` radio-settings pane; add the new pane
    case.)
- Demos are size-matched across steps (Wispr sizes dialog crops identically
  so consecutive steps read at the same scale; whole-window walkthroughs
  render larger). Rounded corners + soft shadow on the mock, per their
  treatment.
- Step 2's demo on macOS 15+ shows the Local Network prompt; the card copy
  must also say a speaker needs to be powered on (see gate consequences).
- Completion state (all granted): a calm settled illustration/state in the
  demo pane, no shadow-heavy chrome (Wispr swaps to a flat illustration).

## Gate mechanics

- Done appears only when the three REQUIRED cards (System Audio, Local
  Network, Speaker Sync) are verified; Bluetooth and Remote Control are
  skippable and never block. Clicking Done re-verifies everything; if
  something was revoked, snap back to the first unmet card with a plain
  explanation. The required set (`RequiredPermission`) is unchanged.
- The ✕ close remains the ONLY exit (existing contract: `onFinished` fires
  but completion is not persisted; the flow returns next launch).
- Accepted consequences of the hard gate:
  - Local Network genuinely requires a discoverable speaker; card offers a
    retry and says to power one on. "Found nothing" is indistinguishable
    from denial (no OS status API) — the card must never claim "denied".
  - Ad-hoc dev builds can't verify Speaker Sync (`SMAppService` never reaches
    `.enabled` unsigned): dev path is `AIRPLAY_PERMISSIONS=granted`
    (simulated seams, already built) — never weaken the gate for it.
- `.permissionLost` re-entry: same window, sequence starts at the first
  unmet card; the banner concept can fold into the header line.

## Integration map (verified on this branch 2026-08-11)

- UI to rebuild: `AudiouterCore/Sources/AudiouterOnboardingUI/` — read its
  `AGENTS.md` FIRST (floating-window decision history, Done-vs-✕ contract,
  wrap-stability rules). `OnboardingWindowController` keeps its float/focus
  behavior (`.floating` for life, `keyWindowProvider` guard, no re-center on
  re-present). `OnboardingViewController` layout is replaced;
  `PermissionRowView`/`PTPHelperRowView` become the card views.
- Detection layer untouched: probes, `SetupModel` statuses,
  `PermissionStateObserver` (ZERO-timer rule in that file — drive audio
  auto-advance + window re-front from `onBecameGranted`, never add a poll),
  `TCCProbeRunner`, `AIRPLAY_SETUP` presentation gate.
- Bluetooth wiring (the one detection-layer change): `SetupModel` gains a
  Bluetooth status backed by `CBManager.authorization` + a prime that
  instantiates `BTAuthorizationRequest` (retain until `onDecided`). The
  enumerator's own startup ask becomes conditional: never auto-fire when
  authorization is `.notDetermined` after setup ran — wait for the first
  user-initiated BT action. `BTConnectionManager`'s `isBluetoothAuthorized()`
  gate already makes ungranted safe (no SIGABRT).
- Known traps carried forward: in-process TCC reads are cached for the
  process lifetime (never poll them); `ProminentButton` exists for a real
  AppKit key-window bug — keep it; keep fixed accessory metrics so text
  never re-wraps on state change; `IconTileView.setLit`'s off-window +
  Reduce Motion guards keep snapshots deterministic — the demo pane needs
  the same guards.
- Snapshot harness `Sources/onboarding-snapshot`: regenerate variants for
  the new layout (collapsed/expanded/complete per step, both appearances).
  Extend the `test_*` hook pattern for sequencing + gate assertions.

## Wispr reference (measured from the shipping app, not screenshots)

Source: `/Applications/Wispr Flow.app` v1.6.447 (Electron), installed on
this Mac — onboarding component + SCSS readable inside
`Contents/Resources/app.asar`. Re-extract if needed. Do NOT commit Wispr
assets (GIFs etc.) into this GPL repo.

Mechanics worth mirroring precisely:
- Gate = the Continue button absent from layout, never disabled.
- Collapsed card 68px title strip → 172px expanded, one CSS-state change,
  0.2 s `cubic-bezier(0.05, 0.6, 0.4, 0.95)` (we use our own 0.15 s house curve).
- Checkmark: width 0→20px + fade over 0.2 s, delayed 0.2 s after grant.
- Auto-advance polls 1 s (their luxury; our detection is event-driven), then
  refocuses their own window before advancing.
- Copy structure per card: imperative benefit title / one-line reassurance
  ("Flow will only access the mic when you are actively using it") /
  post-grant capability title / ⓘ tooltip carrying the honest mechanism.
- Their known mistakes, avoided here: demo GIFs go stale (their mic dialog
  wording already is — native drawing fixes this), Reduce Motion ignored
  (rule 4 fixes this), help-center step order contradicts the app.

## Out of scope

Capability tour, Done meter sweep, the privacy-priming page idea, any other
onboarding pages, popover/mixer surfaces, probe internals, signing work.
