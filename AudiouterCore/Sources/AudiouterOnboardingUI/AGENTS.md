# AudiouterOnboardingUI

## Purpose

The first-run Setup window (pure AppKit): a **two-pane** screen that asks for the
five permissions **one at a time**. LEFT, a fixed column with the hero, the five
sequential cards, the final-check status row, and the Done footer. RIGHT, a native-drawn miniature of the
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
  `SetupFlowModel.isDoneAvailable`; never disabled, never alpha-hidden. **The
  gate now means "the final check PASSED"** (owner decision 2026-08-11, after a
  live telemetry trail showed five clicks swallowed during an invisible ~2 s
  verification): the moment every card is decided — every REQUIRED permission
  granted AND no card still active (`isReadyForFinalCheck`, the gate's old two
  conditions; a skip is the decision that clears an undecided optional card) —
  the flow AUTO-RUNS `runFinalCheck()`, the same silent audit `verifyForDone()`
  uses (one audit machinery, two entry points), and only its pass opens the
  gate. **The beat:** while the check is pending/running there is NO CTA, NO
  settled finale, NO ripple — the demo pane HOLDS its current frame
  (`DemoPaneView.holdCurrentFrame`) — and on the pass the finale crossfade, the
  one-shot ripple, and the CTA fade-in all arrive in the same repaint. A check
  failure reuses the snap-back machinery (the offending card re-opens; the row
  reverts to pending — `finalCheckState` derives pending whenever readiness is
  lost, so nobody has to remember to revert it). The check logs its own
  `setup_done` outcomes, `auto_check_passed` / `auto_check_refused` + `unmet`,
  beside the click's `finished`/`refused`/`swallowed_in_flight`.
  `verifyForDone()` still re-verifies REQUIRED permissions only — a skip is a
  decision, not a permission — and stays on the CTA click unchanged
  and is NEAR-INSTANT by construction: the click's audit TRUSTS the proven
  Local Network grant (`auditRequiredPermissions(trustingProvenLocalNetworkGrant:)`)
  instead of re-browsing it — the auto-check's own browse is the one visible
  re-proof per gate opening, and re-proving it again invisibly behind the
  click was the v7 "took two clicks" (a 3.2 s verification with the second
  click correctly swallowed inside it). The app-level wake audit keeps the
  browse: there it is the only Local Network revocation detector and the
  granted card's only speaker recount. On a `.permissionLost` re-entry the
  walk starts at the lost step, so an undecided optional card BEHIND that start
  is not walked and cannot block Done; one AFTER it (Remote Control) is shown
  and must be decided, as the flow always re-offered it. There is no
  "Continue without every permission?" sheet — it and its paths were deleted in the
  same change. Clicking Done re-verifies (`verifyForDone()`, silent reads only) and
  on failure snaps the flow back to the card that came up short. **The verification
  is SINGLE-FLIGHT, and `SetupModel` coalesces concurrent Local Network probes onto
  one running prime** — the audit's re-browse takes seconds, and a colliding prime
  is answered `.undecided` by the primer's in-flight guard, which the model would
  record as a real "not granted": that fabricated answer is how clicking Done while
  the reactivation `refreshStatuses()` was still browsing refused to finish (live,
  2026-08-11 — "Start listening took two clicks"). The ✕ close remains
  the one ungated exit and still doesn't persist completion. Done rides DIRECTLY
  under the card stack (`cardsToFooterGap`), not pinned to the pane's bottom edge:
  the window is a fixed height, so the bottom pin left the complete state with the
  collapsed stack at the top and Done ~250 pt below it across an empty band. The
  pane's lower slack now falls below the footer. Done's FACE is the finale CTA —
  **"Start listening"** (owner copy 2026-08-11: closing setup is what starts the
  deferred audio engine, so the button names that), a gold `ProminentButton` that
  fades in on the gate's beat. The face changed; the gate contract above did not.
- **The final-check row is a STATUS row, not a card** (`SetupCheckRowView`,
  sixth in the column below Remote Control): never expandable, no body, no
  Allow/Skip — but in the column's grammar (same surface/inset, icon tile,
  title, one trailing slot). Three states, copy is owner-reviewed and EXACT:
  pending **"One last check"** (dormant like the locked cards' dimming but with
  NO padlock — it isn't permission-locked, it's waiting its turn), running
  **"Making sure everything's ready…"** (small spinner in the trailing slot),
  passed **"Everything's ready"** (the completed cards' green checkmark). Icon:
  SF "checklist" tinted `Tokens.Color.gold` — deliberately NOT a permission
  hue: the row is the first note of the finale's colour story, and the tint is
  PERMANENT like every tile (gold-on-`raised` ≥3:1 is measured in
  `OnboardingPermissionColorTests`). Unlike the demo pane the row is REAL UI:
  one VoiceOver element whose label is the state-carrying title, so the pixels
  and the spoken state can never disagree.
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
  plain `.group`, because its press is refused). **The live card, every
  prominent Allow, and the CTA act on the click that ACTIVATES the app**
  (`acceptsFirstMouse` overrides on `ProminentButton` and `SetupCardView`; v4
  live fix 2026-08-11, "Start listening took two clicks"): the bounce to System
  Settings and back often returns the user to an INACTIVE app — the poll grants
  the last card while Settings is frontmost, where macOS may decline our
  re-activation — and a stock control spends the returning click on activation.
  Skip and other secondary controls keep stock first-mouse behaviour.
- **Checkmark ⇔ capability title.** A card that has EARNED a checkmark shows the
  capability title; every state that hasn't (pending, skipped, and an auto-passed
  step the OS can't grant) keeps the imperative one. The auto-pass carries a NOTE
  where the checkmark would be ("Requires macOS 14.2 or later"), because claiming a
  grant nobody made would be a lie. Local Network's earned title is the found COUNT
  ("3 speakers on your network" — found ≠ connected, and the phrasing must never
  imply a connection) rather than a checkmark — it is the detail a user can check.
  The count is an `Int?`: `nil` means no browse ran at all (macOS 14, ungated), and
  `0` means a real browse that saw nothing on a permission that IS granted — two
  different sentences, neither implying the user did something they didn't.
- **The two-mode Allow.** First fire runs the native prompt/probe; once that prompt
  is spent the same slot becomes "Open Settings…". Which statuses count as spent
  lives in `offersSettingsFallback(_:)` and MUST stay in lockstep with
  `SetupFlowModel.allow(_:)`'s own preflight — the button must not promise a prompt
  the model will refuse to fire. **Remote Control asks ONCE, then deep-links to
  `SystemSettingsPane.accessibility`** (owner decision 2026-08-11 — this REPLACES
  the rule that its "Open Settings…" re-fires the Accessibility PROMPT). The first
  fire must stay `primeRemoteControl()`, because prompting is what REGISTERS this
  app's row in the Accessibility list at all: a cold deep link would drop the user
  on a list with no Audiouter row to switch on. The retry deep-links because the
  rationale for re-priming did not survive contact with reality — it rested on the
  claim that the alert's own "Open System Settings" button is the only path that
  scrolls to/highlights Audiouter in the list, and the owner has NEVER seen that
  highlight across many live runs. With no highlight to buy, re-priming only cost
  an extra window and an extra click. The retry reuses the `settings_fallback_denied`
  outcome, whose meaning already covered "was already asked once".
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
    ungated, no browse ran) keeps its own line. **A proved grant is STICKY**: a
    rescan that proves nothing (empty browse, in-flight `.undecided`) must never
    take `.granted` back — only the mDNS policy refusal revokes it. The
    activation-rescan downgrade was the live-caught state flap of 2026-08-11.
  - **denied** takes the ordinary two-mode shape: `offersSettingsFallback` is
    true, so the primary becomes "Open Settings…" — re-browsing a refusal only
    gets refused again. No speaker hint there: a speaker isn't the problem.
  - **requested** (asked, nothing answered) keeps the old no-dead-end handling:
    the "Nothing has answered yet. If the permission dialog is open, choose
    Allow — or try again." line (it must NOT claim "no speakers found" — this
    state means the DIALOG went unanswered, not that a browse came up empty), a
    primary **Try Again** that re-runs the prime, and "Open Settings…" as a
    quiet SECONDARY beside it where that pane exists (`isLocalNetworkGated`,
    macOS 15+). Flipping this state to Settings-only left nothing able to
    re-browse the speaker the user had just switched on.
- **A wait on screen always SAYS what it is waiting for.** The active card's
  in-flight state is a small spinner plus a caption in the TEXT column (never the
  fixed accessory column — the wrap-stability rule is untouched). **The caption's
  band is RESERVED**: the expanded card's height is identical with and without it
  (the deterministic-height rule), so tapping Allow never shifts the cards below —
  the show/hide height flap was a review-caught defect of 2026-08-11. The hint
  label does not yet have the same reservation (known follow-up). Two phases:
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
  - **AMENDMENT (owner decision 2026-08-11) — float, but YIELD.** A refinement,
    not a reversal: any path that opens System Settings (a privacy pane OR Speaker
    Sync's Login Items) drops `window.level` to `.normal` first, and
    `appDidBecomeActive` restores `.floating`. Floating otherwise parks us on top
    of the one app we deliberately send the user to. The seam is the content VC's
    `onWillOpenSystemSettings` closure, which the window controller wires to
    `yieldToSystemSettings()`; `test_windowLevel` is what pins the contract.
    - **"Native permission alerts already draw above a floating window" is only
      true of the TCC dialogs** (owner live observation 2026-08-11 — this scopes
      down a claim this file used to make flat). A system process draws those, at
      a level of its own. The **Accessibility Access alert is ordinary window
      chrome at NORMAL level**, and a floating Setup window buries it completely —
      the user clicks Allow on Remote Control and nothing appears to happen.
    - So **Remote Control's ASK is a yield site too**, and the only one that isn't
      a Settings trip. `performAllow` fires `onWillOpenSystemSettings?()` BEFORE
      `await flow.allow(.remoteControl)`, not after: by the time that call
      returns, the alert is already on screen. The closure is idempotent, so a
      granted short-circuit that raises no alert costs nothing — the next
      `appDidBecomeActive` restores the level either way. The name was kept
      (that alert's one forward button opens System Settings anyway).
    - **And the `.none` branch must NOT `returnToFront()` for Remote Control**
      without positive evidence (`remoteControlStatus == .granted`). The re-front
      assumes the user has come BACK from a dialog; for this step the dialog just
      OPENED, and fronting ourselves re-buries the panel the yield stepped aside
      for. Same shape, same reason as Local Network's rule — both live in
      `shouldReturnToFront(after:)`. `test_returnToFrontCount` pins it.
  - **TRAP: the level drop only sticks if `appDidBecomeActive` is gated on
    having actually LOST the front** (live fix 2026-08-11 — Settings still
    opened behind the window with the drop in place). The click that fires
    Allow is often the same click that activates our app, and
    `didBecomeActiveNotification` is delivered on the run loop while the Allow
    is still resolving through its `await` — so our own activation lands AFTER
    the deep link and instantly restored `.floating` (and re-ordered the window
    in) before System Settings finished coming forward. The window controller
    now arms `isYieldingToSettings` on the yield and disarms it on
    `didResignActiveNotification`: an activation with no deactivation in front
    of it is our own, not a return, and re-floats nothing. The window still
    can't get lost — the first real return (user click, or the grant-lands
    `returnToFront()`, both of which follow a genuine resign) restores float.
    `test_appDidResignActive()` is the seam; true cross-app z-order is not
    observable headless, so this pair of hooks is what tests can pin.
- **The window is `OnboardingWindow`, the click witness** (live symptom: the
  first "Start listening" click left NO telemetry at all — not even the
  single-flight swallow — so the failure sat somewhere no view-level fix or
  log could see). Its `sendEvent` logs a `setup_click` down/up pair for every
  physical click (what it hit, whether the app was active/key at delivery)
  and force-activates an inactive app BEFORE dispatching the click — a click
  that landed on this window is intent to use it. Silence in the trail now
  means the click never reached the app at all. This complements, never
  replaces, the `acceptsFirstMouse` overrides: those are what let the same
  click also press the control.
- `present()` sizes and centers on the FIRST call only — a re-present (the
  `presentSetup` re-entry guard, "Open Setup…" while open) must not re-center a
  window the user moved. The content's `fittingSize` is a FIXED
  `contentWidth × contentHeight` (820 × 560), not a per-step measurement: the
  window must not resize under the user as cards expand and collapse.
- **Both on-screen paths are gated on `HeadlessRuntime`** — `present()` and the
  `appDidBecomeActive` re-front. The sizing/centering and the take-key DECISION
  still run headless (the latter counted into `test_frontCount`), so both
  contracts stay just as testable; only `activate`/`makeKeyAndOrderFront` are
  skipped. Ungated, a `swift test` run parks this `.floating` window above
  everything on the developer's real screen — un-clickable, because the test
  process is not a foreground app — until the whole run ends. This window is
  more disruptive than the others when it leaks, which is why it is called out
  here as well as in `HeadlessRuntime`'s own doc comment.
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
  snapshots stop being deterministic.
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
  down to the welcome line once every permission it named is granted, without
  expanding to cover anything it didn't originally flag. **The welcome subtitle
  holds in EVERY other state, complete included** (owner decision 2026-08-11): the
  payoff line — "Your Mac's sound can reach every room.", deliberately with NO
  found-speaker count — belongs to the demo pane's finale card, under "You're all
  set.", never to the header. Which header message is showing is tracked as a
  message KIND, and that kind is what the banner hooks report — never a
  string-compare against the welcome copy. The `test_showsPermissionLostBanner` /
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
  - **The prompt mock is the macOS 26 "Liquid Glass" privacy dialog, not the old
    alert** (owner decision 2026-08-11, from screenshots of the real dialogs —
    this REVERSES the previous "centred, icon above the text, 6 pt rounded
    buttons with an accent-filled default" drawing, which was the pre-26 shape
    and read to the owner as "an abstract allow thing"). The anatomy, which is
    generic across all five steps:
    a TALL portrait card (real 283 × 340 pt, drawn here at ~0.85 of that, with a
    large ~24 pt continuous corner); an ICON TILE top-LEFT (which icon depends on
    the step — see below) with a `systemBlue` circle badge carrying a white
    `hand.raised.fill` overlapping its bottom-trailing corner — the marker that
    says *privacy prompt*; a small grey
    Help circle top-right; a bold LEFT-ALIGNED title over two or three lines; a
    left-aligned `secondaryLabelColor` body; and two EQUAL, NEUTRAL CAPSULE
    buttons filling the content width. **There is no accent-filled default
    button any more** — drawing one would date the mock and, worse, send the user
    looking for a blue button that won't be there. Nothing is centred, and
    nothing is greeked.
    - **The body is the app's REAL Info.plist purpose string** — the same words
      `scripts/make-app.sh` stamps into `NSAudioCaptureUsageDescription` /
      `NSLocalNetworkUsageDescription` / `NSBluetoothAlwaysUsageDescription`, so
      the paragraph the user rehearses here is the paragraph macOS will show.
      Change one there, change it in `bodyText(for:)`. That sentence is why the
      card is drawn near life size at all: the type tiers still hold (nothing
      under 9 pt), which puts the title at 14 pt and the body at 11 pt.
    - **The top-left tile is NOT always the app's icon** (owner screenshots of
      the real dialogs, 2026-08-11). macOS shows the asking app's own icon only
      where the grant is about capturing THAT APP's content — System Audio, which
      really does draw `NSApp.applicationIconImage` with the hand badge on it.
      The CAPABILITY grants show a generic SYSTEM tile instead, the same one for
      every app: the real Local Network dialog draws the Network pane's blue
      rounded square with a white wireframe globe, not Audiouter's icon. So
      `DemoPromptMockView.iconView(for:)` returns the app icon for `.audio` and a
      `systemTile` (`DemoSystemColor.accent` fill, side × 0.23 continuous corner,
      white glyph at side × 0.55) for `.localNetwork` (`network`) and
      `.bluetooth`. Everything else about the slot — size, position, the badge —
      is identical either way; only the tile's CONTENTS change. `.remoteControl`
      and `.speakerSync` never reach this path in practice and keep the app icon
      as the safe default.
      - **Bluetooth's glyph is a NAMED APPROXIMATION, twice over.** No screenshot
        of the real macOS Bluetooth prompt was available and a search turned up
        none, so the system-tile treatment is INFERRED from the Local Network
        one; and SF Symbols ships no Bluetooth rune at all (Apple doesn't licence
        the mark — `name_availability.plist` has no such name), so the tile
        carries `dot.radiowaves.right`, the glyph the Bluetooth setup card beside
        it already uses, rather than a hand-drawn rune. If a real screenshot ever
        contradicts either half, this is the one place to change.
    - `.localNetwork`'s title is the odd one out: macOS phrases it as a QUESTION
      opening on "Allow" — "Allow “Audiouter” to find devices on local
      networks?" — where the other steps use "…would like to…". Verbatim from
      the real dialog; don't regularise it.
    - The per-step hooks stay `askText` / `bodyText` / `confirmTitle` /
      `grantedText`; the ANATOMY is shared. `DemoPaneView.surfaceSize` grew to
      336 × 336 to seat the taller card with a margin around it (the pane has
      516 pt of height, so Replay still clears underneath).
  - **ONE step has a two-stage demo: Remote Control's FIRST ASK** (owner
    decisions 2026-08-11 — a live run showed its demo jumping straight to a
    Settings pane the user had no idea how to reach). Its first ask takes two
    acts on two different surfaces; every other step's first ask is the
    one-surface privacy dialog. **The mapping was REMAPPED the same day**, when
    the retry became a deep link: the first ask now shows the two-stage handoff
    (`makeMock` routes `.prompt` + `.remoteControl` there) and the retry shows
    the plain `DemoSettingsMockView`, which is exactly what each click really
    does. It was the other way round, which put a portrait TCC privacy card — a
    dialog shape macOS never shows for Accessibility — in front of the first
    ask. `DemoMode` did not change: `.prompt` still means "the surface this ask
    raises", `.settings` still means "the pane", so both stay assertable.
    **Speaker Sync briefly had a two-stage demo
    too, and it was RETRACTED the same day** (owner re-test 2026-08-11): the
    premise was that registering the login item raises an alert of this shape,
    but macOS opens System Settings DIRECTLY from the card's "Open Login
    Items…" — no alert exists. (The research behind the original build had
    already flagged that panel as unconfirmed; the re-test confirmed the
    doubt.) `DemoLoginItemsMockView` was DELETED rather than left orphaned —
    it is in git history with this rationale if the premise ever revives.
    Don't re-add a Speaker Sync alert stage without a screenshot.
  - **Remote Control's two-stage demo opens on `DemoSystemAlertMockView`, the
    classic macOS ALERT PANEL** (owner decision 2026-08-11, from a screenshot
    of the real Accessibility Access alert taken against a signed build — this
    REPLACES the earlier stage-one surface, the re-fired privacy card). Its
    whole reason to exist is that the real panel is a completely different
    SHAPE from the macOS 26 privacy card above, and the earlier drawing
    implied the user would meet the card twice:
    - LANDSCAPE (288 pt wide, height from the copy — about 1.8 : 1) with a small
      ~12 pt corner, against the card's tall portrait and its ~24 pt one;
    - a plain, non-bold HEADER line naming the access ("Accessibility Access");
    - a **full-bleed hairline divider** under it — the one structural element the
      privacy card has nothing like, and the fastest way to tell them apart;
    - a two-column body: the gold privacy PADLOCK left, bold ask and Settings
      instruction right, the two centred against each other as a group;
    - a Help circle bottom-LEFT; bottom-RIGHT "Open System Settings" (neutral)
      then "Deny" — and **the REFUSAL is the accent-filled default**, the
      opposite emphasis from the card's two equal neutral capsules. That is why
      the pointer goes for the QUIET button: on this panel the blue one is the
      wrong answer, and the demo has to show that.
    - The padlock is `lock.fill` filled with a gold GRADIENT, because the real
      icon is artwork with some dimension in it and a flat amber symbol at this
      size reads as a toolbar glyph. **TRAP: the mask has to be built in an
      `NSImage` of its own** — compositing the gradient `.sourceAtop` straight
      into `draw(_:)` does not clip to the symbol (the view's backing store is
      not the empty destination that mode needs) and the whole icon rect comes
      out a solid gold rectangle. Draw the gradient into a fresh image and knock
      the symbol's alpha out of it with `.destinationIn`.
    - Accessibility's padlock carries a blue circular badge with the
      `accessibility` glyph (SF Symbols 5 / macOS 14 — checked against
      `name_availability.plist`, and the package floor is macOS 14). No other
      step raises this alert, so no other step earns a marker.
    - It is a passive SURFACE, not a `DemoMockView`: it draws itself and exposes
      `pressTarget`/`pressPoint(in:)`/`addPressAnimation(on:pressedAt:)`, while
      the host owns the cursor and the crossfade — a stage that owned a cursor
      would put a second one on screen. `pointerRest` is where a host parks that
      pointer: resting it on "Open System Settings" reads as a press that already
      happened, which is what the first drawing did.
    - `DemoNotificationBannerView` — the drawn "Background Items Added" banner
      from Speaker Sync's deleted two-stage era — is likewise only in git
      history.
  - **Remote Control's two stages.** Its first Allow raises the alert, whose own
    button opens the pane, so the user has two clicks to make on two different
    surfaces — and a demo that opened straight onto the Settings pane showed the
    toggle without showing how the pane carrying it is reached.
    `DemoSettingsHandoffMockView` plays both in ONE pass: the system alert with
    the pointer pressing **Open System Settings**, a crossfade, then the ordinary
    Settings pass with the pointer flipping the Audiouter toggle on, then back to
    the alert. Two presses, two surfaces, one clock. `test_demoStage` is `nil`
    for every step but Remote Control.
    - Stage two is `DemoSettingsMockView` unchanged; the container sequences the
      two, owns the crossfade, and owns stage one's POINTER (the alert has none
      of its own). Stage two draws its own pointer inside the Settings mock, so
      the host's is invisible from the crossfade until the alert comes back —
      the two never share a frame.
    - `DemoStage` names its two surfaces; `DemoHandoffStage` was deleted rather
      than kept as a second enum with the same two cases, and
      `test_demoHandoffStage` folded into `test_demoStage`.
    - `DemoPromptOutcome` went with it. It existed only to relabel the privacy
      card's buttons for the re-fired ask; with a real alert drawn for that job,
      the card is back to one shape (two equal neutral capsules, "Don't Allow"
      beside its confirming title) and `confirmTitle(for:)` lost its `outcome:`.
    - `surfaceSize` did NOT change: at 288 pt wide and ~158 tall the alert clears
      its margins inside the existing 336 × 336, and the handoff container is now
      the Settings pane's 300 × 190 rather than the card's taller box.
    - **A stage keeps writing its score in its OWN seconds.** `DemoMockView`
      .`stageWindow` is the seam: set it and `keyframes(_:_:timing:)` lays that
      score onto the host's longer pass at an offset, holding the first and last
      values through the time either side (Core Animation wants a linear score to
      span the whole animation, and "not on screen yet" has to look like a hold
      anyway). So a mock never has to know whether it is playing alone or as a
      stage — `DemoSettingsMockView` needed no change at all.
    - **TRAP: a nested mock still has its autoresizing mask on.** The pane turns
      `translatesAutoresizingMaskIntoConstraints` off for the mock it installs;
      a mock nested one stage deeper is its container's job, and left on, both
      stages render as nothing but their drawn pointer.
  - **`DemoSystemColor` is a documented exception to "colour literals live only in
    `Tokens`"** (root `AGENTS.md`). Four values have no semantic equivalent that
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
    display-weight "You're all set." over the payoff line) — it is also the
    model-layer state, so every animation ends there and snapshots stay
    deterministic. The rings' travel is DERIVED, never authored — from the icon
    centre's real distance to the FARTHEST surface edge, so the wave sweeps the
    whole stage and deliberately crosses the frame on every side — and the RING
    LAYERS ONLY are masked by a soft per-edge feather (`ringFeatherWidth`, ~24 pt
    fading to clear at each edge), so a crossing ring dissolves instead of being
    truncated by the rounded-corner clip. Both halves are owner-tested history:
    an authored end-scale hard-clipped the ripple live, and the nearest-edge
    derivation that replaced it was rejected live as "one little line that goes
    out" — big travel PLUS feather is the fix, and the feather must never touch
    the aura/text or the settled render (rings rest at opacity 0).
    The aura/rings stamp resolved `gold`/`glow`, so the view observes the
    accent-dial and a11y notifications like the mocks do. On the animated
    transition the shot rides the step crossfade itself (fired as the fade
    STARTS), or the text would reveal twice.
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
  - **Every press fires ONE shared click splash** (added 2026-08-11): two
    concentric hairline rings rippling out from the cursor's TIP — a sound wave
    leaving the click, the one place this audio app's own character shows inside
    a mock of somebody else's chrome. It lives entirely in
    `DemoCursorView.addClickSplash(on:at:)`: pure `CAShapeLayer`s anchored on
    `tipPoint` INSIDE the cursor view, so they ride the cursor's transform and
    no call site keeps coordinates in step. Three press sites arm it, each at
    the beat its existing press/state-change already uses (none of which the
    splash replaces or retimes): the prompt mock's confirm press and the
    Settings switch flip (both `DemoBeat.pressEnd` — the Settings call also
    covers the handoff's stage two for free, through `stageWindow`), and the
    handoff's stage-one alert press (`DemoBeat.pressEnd`).
    - **Duration is 0.18 s, and that number is load-bearing:** it is the
      TIGHTEST press-to-cursor-fade window any pass has (the prompt mock
      presses at 1.90 s and its cursor is fully faded by 2.08 s). A longer
      splash gets clipped by the cursor fade it rides inside.
    - **Colour judgment call:** neutral `labelColor` ink — NOT `Tokens` gold and
      not `DemoSystemColor.accent`. The splash is arguably cursor chrome rather
      than mock content, but it plays ON surfaces that must read as macOS, and a
      gold burst would claim macOS draws Audiouter-coloured feedback; the ripple
      FORM carries the product note instead. `labelColor` also guarantees
      contrast on every press target (all mid-grey at press time — the switch
      track only turns blue after `pressEnd`). Stamped per pass like the switch
      tint, so appearance changes catch up on the next loop.
    - **The layers' MODEL opacity is 0 and nothing ever sets it otherwise** —
      only the pass's keyframes make a ring visible, so `applySettledState`
      needs no new line and a settled/headless frame cannot carry a splash by
      construction. Pure layers, never views, so `installAccessibilityOptOut`
      needed no extension either. `test_clickSplashesAreSettled` /
      `test_clickSplashesAreArmed` (on `DemoMockView`, walking nested stages)
      pin both halves.
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
  which is exactly when the user is looking at it. It now also takes a `fill` and a
  `titleFont` (the CTA passes `Tokens.Color.goldCTA` — a deep gold AUTHORED for
  white ink, measured rationale on the token; the flagship `gold` is too light a
  fill for body text — plus the emphasized weight) and an opt-in
  `picksInkFromFill`: the key-window ink is then MEASURED white-or-black against
  the resolved fill per appearance and Increase Contrast, proving the ink instead
  of assuming it (white wins on every authored `goldCTA` variant). The
  `.systemAccent` dial keeps forced white regardless — platform convention for a
  live-accent fill. Accent-filled Allow buttons keep forced white and
  `Tokens.Font.body`; don't route them through the measure (it would flip a blue
  accent's ink to black). **TRAP:**
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
  fill and rim stay `Tokens.Color.raised`/hairline on every card. **The tint is
  PERMANENT** (owner decision 2026-08-11 — this REPLACES the earlier
  "granting crossfades the glyph to `Tokens.Color.gold`" rule): the grant-goes-gold
  crossfade duplicated the checkmark/status the row already shows, so the glyph
  never recolours and `IconTileView` has no `setLit`/`isLit` at all. The card's
  only state role for the tile is the locked dimming (`lockedTileAlpha`). The
  tints are dial-aware in `.subtle` only and must NEVER route through
  `accentDynamic`, which collapses distinct hues into one accent.
- `test_` hooks throughout, because this window isn't visible to a headless
  harness: sequencing (`test_activeStep`, `test_expandedSteps`, `test_title(of:)`,
  `test_hasCheckmark`, `test_note(of:)`, `test_hint(of:)`), the real Allow/Skip
  paths (`test_tapAllow`, `test_allow([steps])`, `test_tapSkip`), the gate
  (`test_doneExists`, `test_doneIsReturnDefault`, `test_snapBackStep`), the demo
  (`test_demoMode`, `test_demoStage`, `test_isDemoAnimating`,
  `test_demoShowsReplay`), and the window
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
| `SetupCheckRowView` | The sixth row: the automatic final check's pending/running/passed status strip. |
| `ClipView` | The card body's masking container — the thing whose HEIGHT the collapse animates. |
| `DemoPaneView` / `DemoMode` | The right pane: the elevated surface, the mode swap crossfade, the motion policy, the Replay button. |
| `DemoMockView` | Timeline base class for the animated mocks: restartable score, settled-state hook, and the two multi-stage seams — `held(_:)` and the `stageWindow` offset. |
| `DemoPromptMockView` / `DemoSettingsMockView` / `DemoSettledMockView` | The privacy-dialog miniature, the Settings-pane miniature, and the completion finale (one-shot ripple, static gold-aura resting frame). |
| `DemoSystemAlertMockView` / `DemoLockIconView` | The classic macOS ALERT panel Remote Control's two-stage pass opens on — header, divider, gold padlock, accent-filled refusal — and the gradient-filled padlock it leads with. A passive surface: the host owns the cursor and the crossfade. |
| `DemoSettingsHandoffMockView` / `DemoStage` | Remote Control's two-stage FIRST ASK: the Accessibility alert handing off to the Settings pane in one pass, the owner of stage one's pointer, and which of its two surfaces the pass rests on. |
| `DemoWindowSurfaceView` / `DemoPushButtonView` / `DemoButtonEmphasis` / `DemoSwitchView` / `DemoSidebarView` / `DemoSettingsRowView` / `DemoGreekBarView` / `DemoPillView` / `DemoDotView` / `DemoBluetoothGlyphView` / `DemoCursorView` | The drawn parts of the mocks — window body, dialog button (neutral capsule or accent rounded rect), switch, sidebar, list row, greeked label, pill, circle, the hand-drawn Bluetooth rune, pointer. |
| `SystemSettingsOpener` | `NSWorkspace` seam for opening a `SystemSettingsPane`, with a Privacy & Security root fallback. |
| `ProminentButton` | Fill-tinted CTA button with key-window-aware title ink (forced white, or measured from the fill). |
| `IconTileView` / `RoundedContainerView` | Shared appearance-adaptive chrome (icon chip, grouped-inset card) — no stock AppKit equivalent. |

## Tests

| File | Focus |
|---|---|
| `AudiouterCore/Tests/AudiouterCoreTests/OnboardingUITests.swift` | Sequencing, locked/active rendering, the card-level click target and its refusals, skip, the two-mode Allow and its deep links, the Done gate + snap-back, the demo pane's mode/idle rules, the lost-permission header, window level/float/re-present, Done-vs-✕. |
| `AudiouterCore/Tests/AudiouterCoreTests/SetupFlowModelTests.swift` | The sequence, gate and Allow decision table this UI renders (Core, not this folder, but the seam it depends on). |
| `AudiouterCore/Tests/AudiouterCoreTests/SetupModelTests.swift` | The underlying `SetupModel` probes/status, the Local Network found count, and the version-gated System Settings deep links. |
| `AudiouterCore/Tests/AudiouterCoreTests/OnboardingPermissionColorTests.swift` | The four per-card tile colours: distinctness, contrast floors, tint permanence across every card state, tile fill unchanged. |
| `AudiouterCore/Sources/onboarding-snapshot` | Offscreen PNG fixtures (per-step — including the in-flight wait and Remote Control's two-stage first ask at rest — remote-control-retry, the running final check, denied, complete, permission-lost × light/dark) in `dev/notes/onboarding-snapshots/`. |
