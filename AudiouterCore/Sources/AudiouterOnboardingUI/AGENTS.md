# AudiouterOnboardingUI

## Purpose

The first-run Setup window (pure AppKit): a **two-pane** screen that asks for the
five permissions **one at a time**. LEFT, a fixed column with the hero, the five
sequential cards, and the Done footer. RIGHT, a native-drawn miniature of the
exact surface the active card's Allow button is about to raise. It reframes the
OS's "recording" language before any TCC prompt fires, and (unlike the
popover/window/settings surfaces) is also re-shown later if a required permission
gets revoked. All permission logic lives in Core — `SetupModel` owns the statuses
and probes, `SetupFlowModel` owns the sequence, the skip set, the Done gate and
the Allow decision table; this folder only renders them and forwards taps. Keep
this file up to date when a card is added or removed, when the required-permission
set changes, or when the gate/motion/demo rules change.

## Rules

- **Five cards, four kinds of thing:** **System Audio** and **Local Network** are
  real `PermissionStatus`-backed TCC probes; **Bluetooth** is the one permission
  with a fully honest status API (`CBManager.authorization` — granted/denied/
  undetermined all real); **Remote Control** (Accessibility) is primed ahead of a
  not-yet-shipped feature, included now to avoid a cold prompt later; **Speaker
  Sync** is a `PTPHelperStatus` (`SMAppService` Login-Items approval), not a TCC
  permission at all — it has no "Denied" state and registers automatically at load
  with no prompt of its own.
- **Setup is a GATE, not guidance** (owner decision 2026-08-11 — this REVERSES the
  documented "setup is guidance, not a gate" decision, so read the history before
  changing it back). Done is **ABSENT from the view hierarchy** until
  `SetupFlowModel.isDoneAvailable`; never disabled, never alpha-hidden. There is no
  "Continue without every permission?" sheet — it and its paths were deleted in the
  same change. Clicking Done re-verifies (`verifyForDone()`, silent reads only) and
  on failure snaps the flow back to the card that came up short. The ✕ close remains
  the one ungated exit and still doesn't persist completion. Done rides DIRECTLY
  under the card stack (`cardsToFooterGap`), not pinned to the pane's bottom edge:
  the window is a fixed height, so the bottom pin left the complete state with the
  collapsed stack at the top and Done ~250 pt below it across an empty band. The
  pane's lower slack now falls below the footer. Done's FACE is the finale CTA —
  **"Start listening"** (owner copy 2026-08-11: closing setup is what starts the
  deferred audio engine, so the button names that), a gold `ProminentButton` that
  fades in on the gate's beat. The face changed; the gate contract above did not.
- **Exactly ONE card is expanded.** `SetupCardView` renders five states
  (`SetupCardState`): `pending`, `active`, `completed`, `autoPassed(note:)`,
  `skipped`. The invariant a test pins is `test_expandedSteps == [activeStep]`.
- **Locked steps READ locked** (owner decision 2026-08-11 — this REPLACES an
  earlier "pending strips render at full opacity, never disabled-looking" rule).
  A step the flow hasn't reached is dimmed (`tertiaryLabel` title,
  `lockedTileAlpha` on the icon tile) and carries a tertiary `lock.fill` in the
  SAME trailing slot the checkmark will eventually take — one position that says
  locked, then earned. Completed = checkmark. Skipped = neither, with the
  imperative title kept: the user answered, they just said no. The ACTIVE card is
  lifted instead — one rung up the warm ladder (`raised` over `panel`) plus a
  heavier neutral rim — so current-vs-locked is unmistakable without inventing a
  colour or spending gold.
- **The whole ACTIVE card is the click target** (owner decision 2026-08-11): a
  click anywhere on it fires the same action as its Allow button, which stays as
  the visible affordance. It is two-mode aware for free (it fires whatever the
  button currently offers) and inert while a probe is in flight — the UI half of
  single-flight. Locked strips are NOT clickable: the flow is sequential, and
  jumping ahead would ask for a permission out of order. **Sub-controls sit above
  the card-level target by CONSTRUCTION, not by arithmetic** — AppKit hit-tests
  the deepest view first, so a click on Skip, Allow… or the spinner never reaches
  `mouseUp`; there are no coordinates to keep in step. The card takes a
  `pointingHand` cursor rect and the shared row hover wash while it's live, and
  VoiceOver sees it as a `.button` named for the action (a non-live card is a
  plain `.group`, because its press is refused).
- **Checkmark ⇔ capability title.** A card that has EARNED a checkmark shows the
  capability title; every state that hasn't (pending, skipped, and an auto-passed
  step the OS can't grant) keeps the imperative one. The auto-pass carries a NOTE
  where the checkmark would be ("Requires macOS 14.2 or later"), because claiming a
  grant nobody made would be a lie. Local Network's earned title is the found COUNT
  ("Found 3 speakers") rather than a checkmark — it is the detail a user can check.
  The count is an `Int?`: `nil` means no browse ran at all (macOS 14, ungated), and
  `0` means a real browse that saw nothing on a permission that IS granted — two
  different sentences, neither implying the user did something they didn't.
- **The two-mode Allow.** First fire runs the native prompt/probe; once that prompt
  is spent the same slot becomes "Open Settings…". Which statuses count as spent
  lives in `offersSettingsFallback(_:)` and MUST stay in lockstep with
  `SetupFlowModel.allow(_:)`'s own preflight — the button must not promise a prompt
  the model will refuse to fire. **Remote Control's "Open Settings…" re-fires the
  Accessibility system PROMPT** (`model.primeRemoteControl()`) rather than
  deep-linking: the prompt's own "Open System Settings" button is the only path that
  scrolls to/highlights Audiouter in the list; macOS gives no URL way to do that.
  Bluetooth's retry goes to `SystemSettingsPane.bluetoothPrivacy` (the app-grant
  pane), never the radio pane. Speaker Sync has ONE mode: Login Items. **Local
  Network is NOT two-mode** — see below. Bluetooth's wait is the MODEL's to report
  (`SetupModel.isPrimingBluetooth`), because its answer arrives on a callback the
  click can't await: the card shows the spinner for as long as that wait lasts, and
  the wait expires after `bluetoothPromptTimeout` (10 s) so a prompt whose decision
  callback never fires can't latch the card shut — the next click asks again under
  the `prompt_rearmed` outcome.
- **Local Network now proves BOTH answers, and still must never dead-end**
  (2026-08-11 — this REPLACES the earlier "must never claim a denial" rule, which
  was true only while the browse was the sole signal). `LocalNetworkPrimer`
  publishes its own Bonjour service and browses for it, so the GRANT is provable
  with no speaker on the network, and an mDNS `kDNSServiceErr_PolicyDenied` is a
  real refusal. Three card shapes follow:
  - **granted** completes the step — the permission is the gate, not the speaker.
    The earned title carries the real count, including the honest zero ("No
    speakers found yet — switch one on and it'll appear"); `nil` (macOS 14,
    ungated, no browse ran) keeps its own line.
  - **denied** takes the ordinary two-mode shape: `offersSettingsFallback` is
    true, so the primary becomes "Open Settings…" — re-browsing a refusal only
    gets refused again. No speaker hint there: a speaker isn't the problem.
  - **requested** (asked, nothing answered) keeps the old no-dead-end handling:
    the "No speakers found yet. Turn one on, then try again." line, a primary
    **Try Again** that re-runs the prime, and "Open Settings…" as a quiet
    SECONDARY beside it where that pane exists (`isLocalNetworkGated`, macOS
    15+). Flipping this state to Settings-only left nothing able to re-browse the
    speaker the user had just switched on.
- **A wait on screen always SAYS what it is waiting for.** The active card's
  in-flight state is a small spinner plus a caption in the TEXT column (never the
  fixed accessory column — the wrap-stability rule is untouched), in two phases:
  "Waiting for your answer…" while a system dialog is unanswered (Local Network
  up to its 60 s ceiling, Bluetooth, System Audio, Remote Control), then
  "Checking your network…" for Local Network's brief post-grant count, driven by
  the primer's OWN reachability callback (`SetupModel.localNetworkPhase`) — never
  a timer. A refusal has no second phase, and an undecided prime clears the
  caption and returns the card to its actionable state; a wait must never latch.
  Speaker Sync is unchanged (its Login Items approval is a poll, not our prompt).
- **The window is deliberately `.floating` while open** (owner decision 2026-08-07,
  punch-list W10 — this REVERSES an earlier reversal, so read the history before
  touching it). The first floating version was demoted to normal level because it
  read as "the setup keeps popping up"; the normal-level compromise then relied on
  `NSApp.activate(ignoringOtherApps:)` re-fronts, which macOS 14's cooperative
  activation may decline while another app is frontmost — so granting a permission
  left the window buried, which the owner judged worse. Floating is bounded two
  ways: the window exists only for a summoned flow that dies at Done/✕, and the
  reactivate hook takes key ONLY when no other window in the app holds it
  (`keyWindowProvider` seam).
  - **AMENDMENT (owner decision 2026-08-11) — float, but YIELD to System
    Settings.** A refinement, not a reversal: any path that opens System Settings
    (a privacy pane OR Speaker Sync's Login Items) drops `window.level` to
    `.normal` first, and `appDidBecomeActive` restores `.floating`. Floating
    otherwise parks us on top of the one app we deliberately send the user to.
    Native permission ALERTS already draw above a floating window, so this is only
    about Settings. The seam is the content VC's `onWillOpenSystemSettings`
    closure, which the window controller wires to `yieldToSystemSettings()`;
    `test_windowLevel` is what pins the contract.
- `present()` sizes and centers on the FIRST call only — a re-present (the
  `presentSetup` re-entry guard, "Open Setup…" while open) must not re-center a
  window the user moved. The content's `fittingSize` is a FIXED
  `contentWidth × contentHeight` (820 × 560), not a per-step measurement: the
  window must not resize under the user as cards expand and collapse.
- **`leftPaneWidth` is 420, not the 380 the layout was first specified at.** The
  longest earned title truncated on a collapsed strip at 380, and the titles are
  reviewed copy — the column moves, not the words. The demo's fixed surface still
  clears its margins in the 400 left over.
- **Wrap stability, new form.** The old parallel rows pinned a 184 pt accessory
  column so the text's right edge never moved between states. In the sequential
  card the accessory sits BELOW the copy, so the text width is a constant of the
  layout — `SetupCardView.textColumnWidth`, derived from the fixed left pane and
  stamped into `preferredMaxLayoutWidth` once at build time. Deriving it from the
  resolved frame in `layout()` instead made an expanded card's height depend on
  WHEN AutoLayout got there, which showed up as snapshot fixtures of the same state
  rendering at different heights. `primarySlotWidth` is the same idea for controls:
  a fixed slot so Allow… → Open Settings… can't nudge Skip sideways, sized for the
  widest occupant that ever SHARES the row with Skip (buttons stretch to fill it;
  Speaker Sync's longer lone button is allowed to overflow).
- **One motion language.** Expand/collapse animates the body's CLIP HEIGHT and
  nothing else, on `Tokens.Motion.collapseRevealDuration` — the same constant every
  collapsible element in the app uses (`CardView.setBodyCollapsed` in
  `AudiouterPopoverUI` is the reference implementation, and
  `PopoverPanelViewController.collapseRevealDuration` now aliases the token so there
  is one home). Both of that implementation's traps are carried here: SEED the clip
  with its current height before animating it shut, and lay the collapsed START
  state out before animating it open.
- **Grant choreography, in this order:** re-front
  (`NSApp?.activate` + `makeKeyAndOrderFront`) → checkmark slides in (width 0 → 20
  pt + fade, 0.2 s easeOut, delayed 0.2 s) → title rewrites → the card collapses
  and the next expands → the demo crossfades (0.22 s; into the COMPLETE state the
  finale's one-shot rides this same crossfade) → the Start listening CTA fades in
  when the gate opens. It fires on the TRANSITION into complete, never on a repaint
  that changed nothing. **Reduce Motion, an off-window/occluded window, and `HeadlessRuntime`
  make every beat an instant swap** — steady states must render settled or
  snapshots stop being deterministic (same rule as `IconTileView.setLit`).
- **Keyboard:** while Done doesn't exist, Return belongs to the one live Allow
  (`SetupCardView.setAllowIsReturnDefault`); the moment Done exists, Done takes it.
- Accessibility and the PTP helper can only be confirmed by a silent poll, not a
  single re-focus check: `OnboardingViewController` runs
  `remoteControlPoll`/`ptpHelperPoll` `Timer`s (~1.5 s) while the window is open,
  each stopping once its status flips to granted/`.enabled`.
  `OnboardingWindowController` additionally re-fronts the window and calls
  `refreshStatuses()` on `NSApplication.didBecomeActiveNotification`. **The
  load-time `refreshStatuses()` is not optional:** `bluetoothStatus` starts
  `.unknown`, so without it the Bluetooth card paints undetermined even when the
  grant is already in place.
- **`SetupFlowModel` is constructed in the VC's `init`** — at presentation time,
  before anything can be granted. Its start position is fixed at construction from
  the first unmet required step, so building it later reads as a re-entry and opens
  on a different card. It has no `onChange`: repaint from `SetupModel.onChange`,
  plus explicitly after `skip()` and a Done snap-back, which are UI-initiated.
- `OnboardingReason` drives the lost-permission message: `.firstRun` (default) is
  the plain welcome; `.permissionLost([RequiredPermission])` is used when
  `SetupModel.auditRequiredPermissions()` finds a REQUIRED permission (Remote
  Control is deliberately excluded — it's an enhancement, not a requirement)
  revoked after setup already completed. **There is no banner VIEW any more** — the
  message rides the header subtitle tinted `Tokens.Color.warning`, so the layout is
  identical either way. It re-words itself to the still-missing subset and stands
  down once every permission it named is granted, without expanding to cover
  anything it didn't originally flag. **The subtitle carries THREE messages, in
  precedence order:** that warning → the COMPLETE line, "Your Mac's sound can
  reach every room." (owner copy 2026-08-11 — deliberately NO found-speaker count),
  whenever the Done gate is open → the welcome line. Which one is showing is
  tracked as a message KIND, and that kind is what the banner hooks report — a
  string-compare predicate ("not the welcome copy") would call the complete line a
  warning. The `test_showsPermissionLostBanner` /
  `test_permissionLostBannerIsVisible` / `test_permissionLostBannerText` hooks
  kept their names so the intent stayed testable across the rebuild.
- Done and ✕ are NOT equivalent: both call `dismiss()` exactly once (single-fire
  guard) and both fire `onFinished`, but only Done calls `SetupModel.complete()`.
  Closing with ✕ leaves setup incomplete so the flow reappears next launch.
- **`DemoPaneView` is an APPROVED custom-drawn exception** to the stock-controls
  house rule (root `AGENTS.md`), confined to that one file. Everything is drawn in
  code — no screenshots, no recordings, no bundled images (`NSApp
  .applicationIconImage` and SF Symbols aside): a captured GIF of a macOS dialog
  goes stale the release after it ships (Wispr's mic-prompt GIF already has), while
  drawn chrome re-resolves its colours per appearance and never claims to be a
  screenshot.
  - **The mock CONTENT is macOS, not us** (owner decision 2026-08-11). Everything
    inside a mock is painted in SEMANTIC SYSTEM colours and the system font —
    `windowBackgroundColor` for the dialog/pane body, `controlBackgroundColor` for
    the grouped list, `labelColor`/`secondaryLabelColor`, `separatorColor` rims,
    `controlAccentColor` on the confirming button, `systemBlue` on the switch, and
    the app's REAL icon in the Settings row. Never `Tokens` — the point is that it
    reads instantly as "this is what macOS will show you", and a warm surface or a
    dial-remapped accent inside it would read as Audiouter drawing its own dialog.
    Only the framing AROUND the demo (the right pane's canvas and the elevated
    surface it sits on) stays Warm Signal. Consequently the pane observes
    `NSColor.systemColorsDidChangeNotification`, NOT
    `Tokens.accentStyleDidChangeNotification`: the user's macOS accent is what its
    stamped `CGColor`s are derived from, and the app's own dial is deliberately not.
  - **`DemoSystemColor` is a documented exception to "colour literals live only in
    `Tokens`"** (root `AGENTS.md`). Five values have no semantic equivalent that
    survives both appearances — above all, System Settings paints its sidebar
    DARKER than its content pane, and `windowBackgroundColor` vs
    `controlBackgroundColor` INVERTS that in dark mode, flipping the one structural
    cue that says "System Settings". They are measured from real recordings and
    wrapped in `NSColor(name:dynamicProvider:)` so both appearances are real. They
    stay in this file rather than moving to `Tokens`: they are a mimic of another
    app's chrome, not palette values, and in `Tokens` something in the app proper
    would eventually paint with them.
  - **TRAP: the mock switch's knob is a `CALayer` this view owns, not a subview.**
    AppKit owns a layer-backed VIEW's layer geometry (`position`, `bounds`,
    `transform`) and rewrites it on the next layout pass. Positioning an `NSView`
    knob by constraint and offsetting it with `layer.transform` for the ON state
    looked right until layout wiped the transform — an ON switch then rendered with
    a blue track and the knob still parked at the LEFT, i.e. a switch claiming to be
    on while drawing off. A layer nobody else manages keeps the static state and the
    animated flip on one property. `test_knobIsAtTrailingEnd` pins it.
  - The **pane title is the one string in the Settings mock that must be real
    text** — it says which pane this is. System Audio's is the SUBSECTION heading
    our row lives under, "System Audio Recording Only", not the pane's own "Screen &
    System Audio Recording" (owner decision): we don't ask for the screen, and
    "Screen" is the very word the card copy exists to defuse.
  - **Motion policy (owner rule, binding).** Reduce Motion OFF → the active step's
    mock loops, but ONLY while its window is really on screen (occlusion state) and
    a step is active; it stops otherwise, so an idle Setup window burns no CPU.
    Reduce Motion ON → the mock plays ONCE on step activation, rests at its settled
    frame, and offers a **Replay** button. Off-window and headless never animate.
    Reads go through the `test_reduceMotionOverride` seam and the workspace
    `accessibilityDisplayOptionsDidChangeNotification`, and because the mocks stamp
    resolved `CGColor`s they also observe `Tokens.accentStyleDidChangeNotification`
    (SharedUI AGENTS.md's rule for any new animated/token-coloured instrument).
  - **The settled FINALE is the one exception to the loop rule** (owner decision
    2026-08-11): `DemoSettledMockView` plays a ONE-SHOT celebration — gold signal
    rings rippling out of the app icon — the first time its frame is on a really
    visible window (the grant transition, or the first presentation of a window
    opened with everything already granted), then goes fully static. The shot is
    CONSUMED, so a repaint that changes nothing can never re-fire it; Reduce Motion
    spends it without motion; off-window/headless leave it UNSPENT so the
    presentation that can show it still gets it. No loop, no Replay, no idle motion
    after it. Its RESTING frame must read rich on its own (static gold aura +
    display-weight "You're all set.") — it is also the model-layer state, so every
    animation ends there and snapshots stay deterministic. The aura/rings stamp
    resolved `gold`/`glow`, so the view observes the accent-dial and a11y
    notifications like the mocks do. On the animated transition the shot rides the
    step crossfade itself (fired as the fade STARTS), or the text would reveal
    twice.
  - **A pass must END where it started.** The settled frame is the surface AS THE
    USER WILL FIND IT — the ask, or the switch off — never the finished state: the
    pane always shows the ACTIVE step's mock, so resting on "allowed" would sit
    beside a card still asking for that very permission and claim it was already
    given. Ending at the start also makes the loop seamless and gives the play-once
    path a truthful resting frame.
  - Each loop is ONE restartable timeline: keyframes laid out over a single
    duration (`DemoMockView.keyframes` takes its score in SECONDS) driven by a
    sentinel animation whose completion decides whether to loop, so play,
    play-once, and stop are the same code path with a flag. The cursor moves by
    TRANSFORM, never by `position` — AutoLayout owns its frame and would reset it.
  - The demo is DECORATIVE and excluded from the accessibility tree; the card copy
    beside it carries every word of the information. Un-electing `mockHost` alone is
    NOT enough — an ignored container HOISTS its children, so the mock's real
    `NSTextField`s ("Allow", "Don't Allow", the pane title) stayed reachable. Every
    descendant is un-elected as the mock is installed
    (`DemoPaneView.installAccessibilityOptOut`), and a test walks the host asserting
    nothing is left. Replay, a real control, stays accessible.
  - **The pointer is the real macOS arrow** (`NSCursor.arrow.image`), ~1.5× life
    size, and every motion path anchors on its HOT SPOT (the tip), never the image
    centre — an image-centre anchor lands the press off the button. The arrow's ink
    fills about half its image box, so `DemoCursorView` is sized from the pointer
    height the caller asks for, not from the box.
- **Bluetooth SHARES Remote Control's `Tokens.Color.permission*` hue** rather than
  minting a fifth token, which would need authored light/dark/Increase-Contrast
  values and a measured contrast rationale from the palette owner. The two cards are
  never adjacent, so the repeat doesn't read as a mistake. Upgrade path: add
  `permissionBluetooth` to `Tokens` with those three variants and swap one line.
- `ProminentButton` exists only to fix a real AppKit bug: a `bezelColor` fill drops
  to plain bezel when its window resigns key but does NOT recolor the (forced-white)
  title to match, so it goes white-on-white. Being the Return-default doesn't fix
  it — the sequential flow DOES make the one live Allow the default, and the
  white-on-white still happens the moment the window resigns key to System Settings,
  which is exactly when the user is looking at it. It now also takes a `fill` (the
  CTA passes `Tokens.Color.gold`) and an opt-in `picksInkFromFill`: the key-window
  ink is then MEASURED white-or-black against the resolved fill, because the
  authored gold columns cross that line per appearance and Increase Contrast (dark
  gold is a light fill; light-IC gold is a dark one) — except under the
  `.systemAccent` dial, where gold IS the live accent and forced white stays the
  platform convention. Accent-filled Allow buttons keep forced white; don't route
  them through the measure (it would flip a blue accent's ink to black). **TRAP:**
  the shared `onboardingActionButton` factory must set
  `translatesAutoresizingMaskIntoConstraints = false`; the card's Allow slot
  constrains the button directly rather than through an `NSStackView` (which used to
  turn that off for us), and left on, AutoLayout synthesises width/height from the
  zero frame and the button renders as nothing at all — the directly-constructed
  gold CTA in `refreshDone()` has to set it too, for the same reason.
- Stock AppKit only (SF Symbols, `NSButton`, `NSProgressIndicator`, system colours)
  per repo house rules — the custom drawing is `IconTileView`/`RoundedContainerView`
  (no stock equivalent for the System Settings grouped-inset look) and the demo
  pane's mocks (above).
- Per-card tile colour lives ONLY in `Tokens.Color` (never a hardcoded `NSColor`)
  and tints the SF Symbol GLYPH only, via `IconTileView`'s `color` param — the tile
  fill and rim stay `Tokens.Color.raised`/hairline on every card. Granting
  crossfades the glyph to `Tokens.Color.gold` for all cards alike — a deliberate
  exception to per-card colour; don't "fix" a granted card to light its own resting
  hue. The resting tints are dial-aware in `.subtle` only and must NEVER route
  through `accentDynamic`, which collapses distinct hues into one accent.
  `setLit`'s Reduce-Motion and off-window guards must stay, or snapshots stop being
  deterministic.
- `test_` hooks throughout, because this window isn't visible to a headless
  harness: sequencing (`test_activeStep`, `test_expandedSteps`, `test_title(of:)`,
  `test_hasCheckmark`, `test_note(of:)`, `test_hint(of:)`), the real Allow/Skip
  paths (`test_tapAllow`, `test_allow([steps])`, `test_tapSkip`), the gate
  (`test_doneExists`, `test_doneIsReturnDefault`, `test_snapBackStep`), the demo
  (`test_demoMode`, `test_isDemoAnimating`, `test_demoShowsReplay`), and the window
  level (`test_windowLevel`). `test_refreshStatuses()` is the AWAITED silent
  re-read — the load-time one fires a detached task, so a caller that needs its
  result (Bluetooth and Remote Control only reach `.granted` through it) has to be
  able to wait.

## Feature Flow

1. App constructs `OnboardingWindowController` with a `SetupModel` and a reason
   (`.firstRun` or `.permissionLost`); `present()` activates the app, sizes the
   window to the fixed content size and centers it.
2. `OnboardingViewController.init` builds the `SetupFlowModel` (fixing where the
   flow starts). `viewDidLoad()` binds `model.onChange`, registers the PTP helper,
   kicks the silent `refreshStatuses()`, paints, and starts both polls.
3. The user clicks the active card's Allow. `SetupFlowModel.allow(_:)` decides:
   short-circuit an already-granted step, preflight a determined-and-denied one
   straight to Settings, single-flight anything already in flight, otherwise fire
   the prompt/probe — and logs exactly one named outcome per click to `Telemetry`
   (`setup_allow` + `outcome`). The VC performs any Settings destination (dropping
   the window level first) or re-fronts after a prompt.
4. `model.onChange` fires → `refresh()` recomputes every card, runs the grant
   choreography on any newly-completed step, updates the demo pane, the gate and
   the header message.
5. Returning from System Settings (`didBecomeActiveNotification`) restores the
   floating level, re-fronts, and re-reads live status; the polls independently
   catch Accessibility/Login-Items grants made without a focus change.
6. Done re-verifies and either finishes or snaps back. ✕ finishes without
   persisting completion.
7. `finish()`/`dismiss()` fire `onFinished` exactly once, unbind `model.onChange`,
   and close the window — the app starts the (deferred) backend from `onFinished`.

## Map

| Type | What it is |
|---|---|
| `OnboardingWindowController` | Owns the window; lazy-create-then-reuse lifecycle; Done-vs-✕ dismissal contract; reactivate re-front; the floating level and its yield-to-Settings amendment. |
| `OnboardingViewController` | Assembles the two panes; turns `SetupModel` + `SetupFlowModel` into card states; owns the grant choreography, the Done gate, the header message and both polling timers. |
| `OnboardingReason` | `.firstRun` vs `.permissionLost([RequiredPermission])` — drives the header message. |
| `SetupCardView` / `SetupCardContent` / `SetupCardState` | One permission card: collapsed strip ↔ expanded body on the shared clip-height motion, the locked/active surface treatment, and the card-level click target. The per-state title table lives on `SetupCardContent`. |
| `ClipView` | The card body's masking container — the thing whose HEIGHT the collapse animates. |
| `DemoPaneView` / `DemoMode` | The right pane: the elevated surface, the mode swap crossfade, the motion policy, the Replay button. |
| `DemoMockView` | Timeline base class (restartable score, settled-state hook) for the two animated mocks. |
| `DemoPromptMockView` / `DemoSettingsMockView` / `DemoSettledMockView` | The permission-dialog miniature, the Settings-pane miniature, and the completion finale (one-shot ripple, static gold-aura resting frame). |
| `DemoDialogSurfaceView` / `DemoCapsuleView` / `DemoToggleView` / `DemoSettingsRowView` / `DemoPlaceholderBarView` / `DemoCursorView` | The drawn parts of the mocks. |
| `SystemSettingsOpener` | `NSWorkspace` seam for opening a `SystemSettingsPane`, with a Privacy & Security root fallback. |
| `ProminentButton` | Fill-tinted CTA button with key-window-aware title ink (forced white, or measured from the fill). |
| `IconTileView` / `RoundedContainerView` | Shared appearance-adaptive chrome (icon chip, grouped-inset card) — no stock AppKit equivalent. |

## Tests

| File | Focus |
|---|---|
| `AudiouterCore/Tests/AudiouterCoreTests/OnboardingUITests.swift` | Sequencing, locked/active rendering, the card-level click target and its refusals, skip, the two-mode Allow and its deep links, the Done gate + snap-back, the demo pane's mode/idle rules, the lost-permission header, window level/float/re-present, Done-vs-✕. |
| `AudiouterCore/Tests/AudiouterCoreTests/SetupFlowModelTests.swift` | The sequence, gate and Allow decision table this UI renders (Core, not this folder, but the seam it depends on). |
| `AudiouterCore/Tests/AudiouterCoreTests/SetupModelTests.swift` | The underlying `SetupModel` probes/status, the Local Network found count, and the version-gated System Settings deep links. |
| `AudiouterCore/Tests/AudiouterCoreTests/OnboardingPermissionColorTests.swift` | The four per-card tile colours: distinctness, contrast floors, granted-lights-gold, tile fill unchanged. |
| `AudiouterCore/Sources/onboarding-snapshot` | Offscreen PNG fixtures (per-step, the in-flight wait, denied, complete, permission-lost × light/dark) in `dev/notes/onboarding-snapshots/`. |
