# AudioutOnboardingUI

## Purpose

The first-run Setup window (pure AppKit): a **two-pane** screen that asks for the
six grants **one at a time**. LEFT, the **SPINE** — a fixed 288 pt column
of the header over seven compact status rows (the six grants plus the
final-check row), carrying short titles and nothing else. RIGHT, the **HERO** —
one warm panel read top to bottom (owner-approved 2026-08-12):

1. the **HEAD BLOCK** (`SetupHeroHeadView`) — a ~20 pt headline over a ~14.5 pt
   why line in primary ink, and NOTHING else: no overline, no support line, no
   ask line;
2. the **PREVIEW FRAME** (`SetupPreviewFrameView`) — a `well` with a caption band
   on its top edge ("You'll see this from macOS") holding the STAGE, the
   native-drawn miniature of the exact surface this step's ask is about to
   raise — except on Usage Statistics, which wears the privacy card's SHAPE but
   carries NO caption, because macOS raises nothing there (see the Usage
   Statistics rule below);
3. the **RIBBON**'s lower region (`SetupRibbonView`) — the status line and the
   recovery paragraph, for the states that have to instruct rather than ask;
4. the **BARE BOTTOM BAR** — a hairline, then the buttons trailing-aligned, and
   nothing else: the gold primary at the trailing edge with a borderless "Skip
   for now" to its left on the skippable steps.

**A FIRST ASK IS ONLY (1), (2) AND (4).** The ask line, the reassurance
paragraph and the honesty line were DELETED, not moved: each explained a picture
the user is already looking at.

  **One amendment to that rationale:** System Audio's why line now also warns
  that allowing plays a brief tone. The deletion rule holds for anything the
  rehearsal SHOWS — and a picture cannot show a sound, so this one sentence
  rides the why line rather than resurrecting the body. (**OWNER-PENDING**.)

That split is the rebuild's whole point (Direction 04, "the rehearsal leads",
owner-chosen 2026-08-11 — it REPLACES the expanding-card column, so read the
history before pulling the copy back into the left column): the rehearsal is this
window's actual idea, so it takes the stage, and the words that explain it sit
directly under it instead of across the window in a card the eye has to pair up
by hand. There are no expanding cards left, no per-card buttons, and no footer.

It reframes the OS's "recording" language before any TCC prompt fires, and
(unlike the popover/window/settings surfaces) is also re-shown later if a
required permission gets revoked. All permission logic lives in Core —
`SetupModel` owns the statuses and probes, `SetupFlowModel` owns the sequence,
the skip set, the Done gate and the Allow decision table; this folder only
renders them and forwards taps. Keep this file up to date when a row is added or
removed, when the required-permission set changes, or when the
gate/motion/demo/selection rules change.

## Rules

- **Six steps, five kinds of thing:** **System Audio** and **Local Network** are
  real `PermissionStatus`-backed TCC probes; **Bluetooth** is the one permission
  with a fully honest status API (`CBManager.authorization` — granted/denied/
  undetermined all real); **Remote Control** (Accessibility) is primed ahead of a
  not-yet-shipped feature, included now to avoid a cold prompt later; **Speaker
  Sync** is a `PTPHelperStatus` (`SMAppService` Login-Items approval), not a TCC
  permission at all — it has no "Denied" state and registers automatically at load
  with no prompt of its own.
- **Usage Statistics is not a macOS anything.** The last card asks for
  Audiout's own anonymous usage counts (PRODUCT.md Data Collection stream 1,
  `AppSettings.telemetryOptIn`). No prompt, no probe, no System Settings pane:
  the Allow click IS the grant and lands before it returns
  (`SetupAllowOutcome.consentGranted`). It sits LAST on purpose — it is the one
  card asking for something the user gives US rather than something macOS gives
  Audiout, and putting that between two permission asks blurs the difference
  the whole window is teaching. Three things follow from PRODUCT.md's "asked
  once, never re-nagged":
  - **The skip is the DECLINE**, not a deferral, so its button says "No Thanks"
    (`RibbonContent.skipTitle`, the only per-step override of the shared "Skip
    for now") and it spends `telemetryAsked` exactly like a grant does.
  - **A decline is seeded back into `skippedSteps` on every later flow**
    (`SetupFlowModel.init`), so re-opening Setup for a revoked permission can
    never smuggle the ask back onto the screen. Clicking the row still re-opens
    it, which is the deliberate way back inside the window; Settings › General
    is the way back afterwards.
  - **A build with no analytics sink DROPS the card** rather than auto-passing
    it (`SetupModel.usageStatsAreAvailable` → `SetupFlowModel.steps`, the
    per-presentation list the view controller iterates — NOT the static
    `SetupFlowModel.steps` order table). A checkmark beside "Usage statistics"
    in a build that sends nothing would be the one thing this window must never
    do. This is also why the ask was gated on `analyticsAvailable` when it was
    still an alert.

  **Its ask raises Audiout's OWN sheet, and that is what makes the row click
  safe.** `SetupAllowDestination.usageStatsConsent` → `presentConsentSheet()`,
  a stock `NSAlert` on the Setup window with Share / Don't Share. The ask
  GRANTS NOTHING: it raises a surface the user still has to answer, exactly
  like every other step's ask, and the answer arrives from the sheet. Briefly
  it granted on the click instead, and the spine row is where that reached the
  user — a press on a row they were only reading opted them in and advanced
  past the card (owner, live). The row is a shortcut to the primary for every
  step; the fix belongs at the primary, not by taking the click away. Do not
  reintroduce a "grant on click" path here.

  (This sheet is NOT the `NSAlert` deleted from `AppDelegate`. That one
  ambushed the first menu-bar click with nothing on screen to explain it; this
  one answers a card the user is looking at and pressed. `presentUsageStatsConsent`
  is the seam headless tests and the snapshot renderers answer it through.)

  **The promise lives in `UsageStatsConsentCard.bodyText`, and it is held to
  the real payload — not to intent.** An earlier draft promised "never your
  network" and "never your licence key" while the SDK was autocapturing both;
  nothing caught it until a real ingested event was read back out of PostHog.
  Audit the same way before changing what is sent: query the event, list its
  property keys, and make the string match. `SetupUsageStatsTests` pins both
  directions — what must be disclosed, and the two absolute "never" claims that
  must not come back.

  The hero's `whyLine` carries the WHY only. It sits directly above the card on
  the stage, so anything said in both reads as a stutter.

  **TRAP — its live spine row is NOT pressable, and that is load-bearing.**
  Every other live row doubles as a shortcut to its primary button
  (`rowPressed` → `ribbonPrimaryTapped`), which is safe there because the
  primary only raises a system dialog that asks again: a stray row click costs
  a dialog, not a decision. Here the primary IS the consent, applied in-app the
  moment it fires — so the shortcut opted the user in from a click on a row
  they were only trying to read, and then advanced past the card (found live:
  "I click the line item and it just goes to the next step"). One property
  decides it, `SetupCardContent.livePressRunsTheAsk`, and BOTH the row's
  `isPressable` and `rowPressed` read it; don't re-add a step-specific check in
  either. The row goes fully unpressable rather than swallowing the click, so
  nothing — pointer, keyboard or VoiceOver — offers `allowTitle` as a row
  action.

  This ask **used to be an `NSAlert` on the first menu-bar click**, fired from
  `AppDelegate` at the exact moment the user was reaching for the mixer. Don't
  put it back there.

- **FOUR steps are skippable** — Bluetooth, Remote Control, Usage Statistics, and **Speaker
  Sync** (`SetupFlowModel.skippableSteps`). The first two sit outside
  `RequiredPermission` entirely; Speaker Sync stays required and is still audited
  once it has ever been on, so its skip is an EXIT rather than a demotion —
  `SetupFlowModel.unmetRequiredSteps()` is the filter that keeps a skipped one out
  of the gate. Before it, an approval macOS simply refused locked the gate forever
  with nothing on screen to press. Speaker Sync's other states, all new:
  - **Asked, and still off.** Once the flow has actually opened Login Items
    (`didTripLoginItems`) and the helper still reads `.requiresApproval`, the
    ribbon shows its own recovery — where the switch really lives (Login Items,
    not Privacy & Security), "Open Login Items…" to go back, and "Skip for now"
    beside it. (**OWNER-PENDING** copy.)
  - **Nothing there to approve.** `.notFound` (the daemon isn't in the bundle) or a
    `register()` that threw auto-passes the row with the note "Couldn't be turned
    on", the same posture as `.unsupported` audio: a packaging fault is not a user
    decision, so it must not hold the gate shut. (**OWNER-PENDING** copy.)
  - **The skip is remembered** (`AppSettings.speakerSyncWasEnabled` — set the first
    time the status reads `.enabled`, cleared by a skip). The app-level wake audit
    re-opens this window for the Login Item only on a real REGRESSION, never at a
    user who passed on it or never approved it.
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
  the one ungated exit and still doesn't persist completion. **Done lives in the
  RIBBON's action row** — there is no footer any more: the gate's CTA is simply
  the ribbon's one primary button (`RibbonContent.PrimaryKind.cta`), so "absent
  until the check passes" is now literally "the ribbon builds no primary at all".
  The action row is a RESERVED fixed band, so the beat where every button goes
  away moves nothing above it. Done's FACE is the finale CTA —
  **"Start listening"** (owner copy 2026-08-11: closing setup is what starts the
  deferred audio engine, so the button names that), a gold `ProminentButton` that
  fades in on the gate's beat. The face and the place changed; the gate contract
  above did not.
  - **AMENDMENT — the CTA PERSISTS during a browse** (Direction 04): a browse is
    a reading position on a row that is ALREADY decided, so opening one after the
    gate must not read as the gate closing. `ribbonContent(active:)` keeps the CTA
    as the primary for every browse built while `isDoneAvailable`, with the
    browsed row's own quiet "Open Settings…" beside it, and Return stays with the
    CTA. `ribbonPrimaryTapped()` therefore finishes on `isDoneAvailable`
    REGARDLESS of `browseStep` — gated on "no browse", the button would sit on
    screen doing nothing. The gate contract is unchanged in meaning: the CTA
    exists iff the final check passed.
- **The final-check row is a STATUS row, not a card** (`SetupCheckRowView`,
  sixth in the column below Remote Control): never expandable, no body, no
  Allow/Skip — but in the column's grammar (same surface/inset, icon tile,
  title, one trailing slot). Three states, copy is owner-reviewed and EXACT:
  pending **"One last check"** (dormant like the locked rows' dimming but with
  NO padlock — it isn't permission-locked, it's waiting its turn), running
  **"Making sure everything's ready…"** (small spinner in the trailing slot),
  passed **"Everything's ready"** (the completed rows' green checkmark). Icon:
  SF "checklist" tinted `Tokens.Color.gold` — deliberately NOT a permission
  hue: the row is the first note of the finale's colour story, and the tint is
  PERMANENT like every tile (gold-on-`raised` ≥3:1 is measured in
  `OnboardingPermissionColorTests`). Unlike the demo pane the row is REAL UI:
  one VoiceOver element whose label is the state-carrying title, so the pixels
  and the spoken state can never disagree.
- **Nothing expands any more — the SPINE selects, the HERO shows.**
  `SetupSpineRowView` renders the same five states (`SetupCardState`: `pending`,
  `active`, `completed`, `autoPassed(note:)`, `skipped`) as a compact strip: icon
  tile, short title, and exactly ONE trailing marker. What the hero pane is
  showing is decided by two variables and no third:
  - `SetupFlowModel.activeStep` (overridden by a snap-back) is the LIVE row. Its
    rehearsal is on stage and its ask is in the ribbon.
  - `OnboardingViewController.browseStep` is a read-only look at a DECIDED row.
    It is the VC's alone, deliberately NOT the flow model's: browsing must never
    touch the sequence, the skip set or the gate. A browse yields to anything
    that really moved the flow (a new grant clears it), and a second press on the
    same row puts it back.
  Selection rules, in the order the press dispatch applies them:
  - live row → runs the ribbon's primary (the whole row is that button);
  - completed row → browses it: the hero shows the pane that row's
    switch lives on, resting ON (see the K2 amendment below), the ribbon says
    what it bought and offers that pane;
  - AUTO-PASSED row → refused, silently, like a locked one: the row's permanent
    note carries the whole story, and no honest hero exists for a grant macOS
    cannot make;
  - skipped row → `SetupFlowModel.reopen(_:)` re-arms the ask (a skip never spent
    a prompt), and the ribbon leads with "You skipped this earlier — nothing's
    lost."; `finalCheckState` reverts to pending on its own, because readiness is
    a derived read;
  - locked row → refused, silently (owner decision: no padlock shake — a refusal
    that animates invites a second try);
  - a BROKEN permission (granted once, off now, or the live step just refused)
    overrides the row's other markers and routes the ribbon to Settings: it is
    the one row on the spine asking to be looked at, and it says so with the
    failure hue, the red edge bar and the alert glyph.
- **Locked steps READ locked** (owner decision 2026-08-11 — this REPLACES an
  earlier "pending strips render at full opacity, never disabled-looking" rule).
  A step the flow hasn't reached is dimmed (`tertiaryLabel` title,
  `lockedTileAlpha` on the icon tile) and carries a tertiary `lock.fill` in the
  SAME trailing slot the checkmark will eventually take — one position that says
  locked, then earned. Completed = checkmark (`Tokens.Color.success`). Skipped =
  a `slash.circle` in that same slot, with the imperative title kept: the user
  answered, they just said no. The LIVE row is lifted instead — one rung up the
  warm ladder (`raised` over `panel`) plus a heavier neutral rim and a 3 pt **EMBER**
  EDGE BAR down its leading side (ember, NOT gold — owner decision 2026-08-12:
  gold is spent entirely on the ONE button the step wants pressed, and a gold
  bar across the window competed with it. `test_rowEdgeBarFill` pins it) — so current-vs-locked is unmistakable. A
  BROKEN row takes the same shape in the failure hue (tinted fill, red edge bar,
  `exclamationmark.triangle.fill` in the one slot), and a BROWSED row adds a
  heavier neutral rim ON TOP of whatever its base state drew, because browsing is
  a reading position and not a change of state. Every blend goes through
  `dynamicBlend(_:fraction:of:)`: blending a dynamic token in place flattens it
  to whichever appearance happened to be current, which is exactly the 1.13:1
  dark rim the critique measured on the old active card.
  - The same trailing slot ALSO shows a small `NSProgressIndicator` (the
    `SetupCheckRowView` spinner's own config) while the active row's ask is
    unresolved: a prompt still in flight, Local Network's phase not idle, or a
    Settings/Login Items trip this window sent the user on and hasn't yet
    resolved by a grant landing or a genuine return's status re-read. It
    outranks every other marker for the slot ONLY — the stored broken flag,
    surface tint, and red edge bar are untouched, since the user just acted on
    that broken state. VoiceOver's label carries ", waiting" (checked before
    the broken suffix). The clear is gated on losing the front first
    (`appDidResignActive` → `appDidBecomeActive`), because the window
    controller's reactivation refresh also fires on the app's own
    catching-up activation right after the deep link — without that gate the
    spinner would blink out the instant the trip fired, not when the user
    actually comes back.
- **THE WHOLE ROW IS THE PRESS TARGET, and the row has no sub-controls at all**
  (this SUPERSEDES the "whole ACTIVE card is the click target" rule, which had to
  keep Allow/Skip hit-testing above the card by construction — the spine has no
  buttons left to hit-test above anything). Every state the user has already
  DECIDED is pressable; a locked row and an auto-passed one refuse, silently. The
  ONE exception is a row drawn BROKEN: it is pressable whatever state it wears, and
  pressing it snaps the flow to it — the loud treatment was already asking to be
  looked at, and a group VoiceOver cannot press was asking for nothing.
  `SetupSpineRowView.mouseUp` and `accessibilityPerformPress()` are the same one
  entry (`onPress`), and `OnboardingViewController.rowPressed(_:)` is the whole
  dispatch table — the selection rules above. The ACTIONS live in the ribbon:
  `onPrimary` (which is the live step's Allow, or the gate's CTA), `onSkip`, and
  `onQuietLink` (Local Network's demoted pane while live; a browsed row's own
  pane while browsing). A pressable row takes a `pointingHand` cursor rect and the
  shared row hover wash, is a first responder with Space/Return, and VoiceOver
  sees it as a `.button` named for what pressing it does ("Allow…" live, "Show"
  for a decided row) with its STATE in the label (", locked" / ", allowed" /
  ", skipped" / ", turned off — needs attention") — a marker VoiceOver can't see
  is a marker that isn't there. An auto-passed row speaks its NOTE instead
  (", requires macOS 14.2 or later", ", couldn't be turned on"): it never earned a
  grant, so ", allowed" was hiding the only thing worth hearing. A locked row is a plain `.group`. **The live row,
  every prominent Allow, and the CTA act on the click that ACTIVATES the app**
  (`acceptsFirstMouse` overrides on `ProminentButton` and `SetupSpineRowView`; v4
  live fix 2026-08-11, "Start listening took two clicks"): the bounce to System
  Settings and back often returns the user to an INACTIVE app — the poll grants
  the last step while Settings is frontmost, where macOS may decline our
  re-activation — and a stock control spends the returning click on activation.
  Skip and other secondary controls keep stock first-mouse behaviour.
  - **The row is NOT inert while a probe is in flight** (a scoped change from the
    card era, where the card blocked its own second click). The UI half of
    single-flight now sits where the action does: `allowTapped(_:)` returns
    immediately while `allowInFlight != nil`, and the ribbon has taken every
    button off screen for the wait anyway.
- **Checkmark ⇔ capability title.** A row that has EARNED a checkmark shows the
  capability title; every state that hasn't (pending, skipped, and an auto-passed
  step the OS can't grant) keeps the imperative one. The auto-pass carries a NOTE
  where the checkmark would be ("Requires macOS 14.2 or later"), because claiming a
  grant nobody made would be a lie. Local Network's earned title is the found COUNT
  ("3 speakers on your network" — found ≠ connected, and the phrasing must never
  imply a connection) rather than a checkmark — it is the detail a user can check.
  The count is an `Int?`: `nil` means no browse ran at all (macOS 14, ungated), and
  `0` means a real browse that saw nothing on a permission that IS granted — two
  different sentences, neither implying the user did something they didn't.
- **There are TWO title tables, and the spine's is a deliberate second source of
  truth.** `SetupCardContent.title(for:foundSpeakers:)` is the RIBBON's sentence;
  `spineTitle(for:foundSpeakers:)` is the SHORT form the 288 pt column can carry,
  same grammar (earned title only for `.completed`, Local Network's still the
  count). The column can't hold the reviewed sentences, and truncating reviewed
  copy is worse than writing a short form of it — but the two tables have to be
  kept in step by hand, so change one and check the other. The short table today:

  | Step | Spine ask | Spine earned |
  |---|---|---|
  | System Audio | Hear your Mac's sound | Hearing your Mac's sound |
  | Local Network | Find speakers on Wi‑Fi | Speakers already reachable (or the count) |
  | Bluetooth | Bluetooth speakers | Bluetooth speakers |
  | Speaker Sync | Keep speakers in time | Speakers stay in time |
  | Remote Control | Volume-key control | Volume-key control |

  **OWNER-PENDING:** these short titles are the rebuild's own wording, not
  reviewed copy — they await Alec's sign-off like the long table already has.
- **There are THREE title tables now, and the HERO's is owner-verbatim.**
  `SetupCardContent.heroHeadline` + `whyLine` are the owner's copy deck (decision
  2026-08-12, VERBATIM — do not re-word), and `allowTitle` names the
  CAPABILITY rather than repeating the OS's "Allow": the gold button is the
  app's promise, and "Allow" is a word that appears in the rehearsal beside it.

  | Step | Hero headline | Why line | Button |
  |---|---|---|---|
  | System Audio | Hear your Mac's sound | Audiout needs this to send your music to your speakers. Allowing plays a brief tone to confirm it's working. | Enable System Audio |
  | Local Network | Find speakers on your Wi‑Fi | Audiout needs this to reach the speakers on your network. | Enable Local Network |
  | Bluetooth | Use Bluetooth speakers | Audiout needs this to stream to Bluetooth speakers and wake ones that are off. | Enable Bluetooth Access |
  | Speaker Sync | Keep speakers in perfect time | A small helper shares one clock so your speakers never drift. | Turn On at Login |
  | Remote Control | Use your volume keys | Audiout needs this so your volume keys keep working while it's your output. | Set Up Remote Control… |

  Skip's own label is **"Skip for now"** (`SetupRibbonView.skipTitle`).
  The HEADLINE holds in every one of a step's states — it is the step's
  identity — while the WHY line is the first ask's alone: once a state has to
  instruct (denied, permission-lost, a wait, a stuck dialog, Local Network
  unanswered), its status + body carry the words instead. `SetupCardContent
  .detail` survives for exactly those states; a first ask no longer shows one.
- **The two-mode Allow** (now the RIBBON's primary button, not a per-card one —
  everything below is otherwise unchanged). First fire runs the native
  prompt/probe; once that prompt
  is spent the same slot becomes "Open Settings…". Which statuses count as spent
  lives in `offersSettingsFallback(_:)` and MUST stay in lockstep with
  `SetupFlowModel.allow(_:)`'s own preflight — the button must not promise a prompt
  the model will refuse to fire. **Remote Control asks ONCE, then deep-links to
  `SystemSettingsPane.accessibility`** (owner decision 2026-08-11 — this REPLACES
  the rule that its "Open Settings…" re-fires the Accessibility PROMPT). The first
  fire must stay `primeRemoteControl()`, because prompting is what REGISTERS this
  app's row in the Accessibility list at all: a cold deep link would drop the user
  on a list with no Audiout row to switch on. The retry deep-links because the
  rationale for re-priming did not survive contact with reality — it rested on the
  claim that the alert's own "Open System Settings" button is the only path that
  scrolls to/highlights Audiout in the list, and the owner has NEVER seen that
  highlight across many live runs. With no highlight to buy, re-priming only cost
  an extra window and an extra click. The retry reuses the `settings_fallback_denied`
  outcome, whose meaning already covered "was already asked once".
  Bluetooth's retry goes to `SystemSettingsPane.bluetoothPrivacy` (the app-grant
  pane), never the radio pane. Speaker Sync has ONE mode: Login Items. **Local
  Network is NOT two-mode** — see below. Bluetooth's wait is the MODEL's to report
  (`SetupModel.isPrimingBluetooth`), because its answer arrives on a callback the
  click can't await: the ribbon shows the spinner for as long as that wait lasts, and
  the wait expires after `bluetoothPromptTimeout` (10 s) so a prompt whose decision
  callback never fires can't latch the ask shut — the next click asks again under
  the `prompt_rearmed` outcome.
- **Local Network now proves BOTH answers, and still must never dead-end**
  (2026-08-11 — this REPLACES the earlier "must never claim a denial" rule, which
  was true only while the browse was the sole signal). `LocalNetworkPrimer`
  publishes its own Bonjour service and browses for it, so the GRANT is provable
  with no speaker on the network, and an mDNS `kDNSServiceErr_PolicyDenied` is a
  real refusal. Three shapes follow:
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
- **A wait on screen always SAYS what it is waiting for**, and the whole ribbon
  stands back for it. The in-flight state is the ribbon's STATUS line — a small
  spinner plus the wait's own words — with **every button gone** (the answer is
  somewhere else now) and the STAGE dimmed (`DemoPaneView.setStageDimmed`),
  because a rehearsal of a dialog must not compete with the real dialog that is
  on screen. Nothing above the buttons moves while this happens: the ribbon's
  action row is a RESERVED fixed band (`SetupRibbonView.actionRowHeight`), which
  is this layout's successor to the old card's reserved caption band. The line
  is: **"Waiting for your answer — the real dialog is on screen now."** while a
  system dialog is unanswered (Local Network up to its 60 s ceiling, Bluetooth,
  System Audio, Remote Control), then **"Checking your network…"** for Local
  Network's brief post-grant count, driven by the primer's OWN reachability
  callback (`SetupModel.localNetworkPhase`) — never a timer. A refusal has no
  second phase, and an undecided prime clears the wait and returns the step to
  its actionable state; a wait must never latch.
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
  - **AMENDMENT — the app goes QUIET while a prompt is unanswered.** A macOS
    permission dialog loses input focus to any process that grabs it, and comes
    back frozen and unclickable. So for the length of an ask
    (`OnboardingViewController.isPromptInFlight` — the Allow in flight, plus
    `SetupModel.isPrimingBluetooth`, whose prompt outlives the click) the
    reactivate hook re-floats and takes key for nobody, `OnboardingWindow`'s
    force-activate-on-click is suppressed (the click is still DELIVERED — only
    the activation is skipped), and a re-front a grant would earn is OWED, then
    paid exactly ONCE on resolve. Resolve = granted, denied, or timed out.
    - **AMENDMENT TO THE AMENDMENT (owner decision 2026-08-22) — quiet means
      FOCUS, not level: the window stays `.floating` through a TCC ask.** The
      original quiet also dropped the level to `.normal` for the length of the
      dialog, and that demote was the mechanism behind the live "blip": the
      setup vanished behind whatever else was open the moment the ask began and
      popped back when the answer resolved — on EVERY accept, since this is an
      accessory app nothing re-activates. The demote bought nothing: every
      dialog `isPromptInFlight` covers is a TCC dialog a system process draws
      ABOVE a floating window (the scoped observation above), and what freezes
      a dialog is stolen input focus, which window level never touches. The two
      normal-level surfaces (System Settings trips, Remote Control's
      Accessibility alert) still yield — that is `yieldToSystemSettings()`'s
      path, untouched. `aPromptInFlightSilencesEveryWayThisWindowTakesTheFront`
      pins the level staying put.
    - **TRAP: Local Network's `allowInFlight` OUTLIVES its dialog** (live find —
      "the setup drops to the background right after I click Allow", and ONLY
      Local Network, back when the quiet still demoted the level). Its Allow
      stays in flight through the whole prime, but the prime keeps running a
      few seconds PAST the answer to settle the speaker count
      (`localNetworkPhase == .verifying`). That tail has no dialog on screen to
      go quiet for, so `promptInFlightStep` returns nil for `.localNetwork`
      once the phase is `.verifying` — in-flight still gates the ✕, the click
      force-activate and the owed re-front, and none of those should wait on
      the count. Every OTHER step resolves its `allowInFlight` the instant the
      dialog is answered, so none of them hit this. The `.verifying` tail still
      dims the stage and shows "Checking your network…" (that is driven by
      `isPrompting`/`localNetworkPhase`, NOT by the window-level in-flight
      state — the two are deliberately decoupled here).
      `theQuietEndsWhenTheLocalNetworkAnswerLandsNotAfterTheCountSettles`
      pins it.
  - **Escape hatch for a frozen dialog.** After
    `OnboardingViewController.stuckPromptDelay` unanswered, the card adds the
    existing hint line + demoted "Open Settings…" (`stuckPromptSteps` — the
    three that raise a dialog of ours). It is UI ONLY: nothing re-asks, and it
    routes through the one deep-link table,
    `SetupFlowModel.settingsDestination(for:)`, which the denied-path Allow
    shares. `test_fireStuckPromptTimer()` is the seam (20 s is not waitable).
  - **A refused ✕ says why.** `windowShouldClose` still refuses while a dialog is
    unanswered, but no longer in silence: it calls
    `OnboardingViewController.noteCloseRefused()`, which puts the reason on the
    ribbon's status line (spinner kept — the wait is unchanged), announces it, and
    re-arms the stuck-dialog hint at the shortened
    `stuckPromptDelayAfterCloseAttempt` (5 s), since reaching for the close box is
    itself the user saying the dialog has stopped being answerable. **Escape is the
    ✕**: `cancelOperation` routes through `performClose`, so it meets the same
    refusal and the same words rather than being a quieter second way out.
    (**OWNER-PENDING** copy — as is Remote Control's spoken caption, the one
    rehearsal whose instruction VoiceOver cannot see, substituted onto the preview
    frame's caption band via `SetupPreviewFrameView.spokenCaption`.)
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
  window must not resize under the user — and nothing in it expands or collapses
  any more either.
- **Both on-screen paths are gated on `HeadlessRuntime`** — `present()` and the
  `appDidBecomeActive` re-front. The sizing/centering and the take-key DECISION
  still run headless (the latter counted into `test_frontCount`), so both
  contracts stay just as testable; only `activate`/`makeKeyAndOrderFront` are
  skipped. Ungated, a `swift test` run parks this `.floating` window above
  everything on the developer's real screen — un-clickable, because the test
  process is not a foreground app — until the whole run ends. This window is
  more disruptive than the others when it leaks, which is why it is called out
  here as well as in `HeadlessRuntime`'s own doc comment.
- **Hero layout constants** (all on `OnboardingViewController` unless noted):
  `heroPadding` 22 → a 418 × 464 interior; `heroHeadToFrameGap` 13;
  `heroFrameToRibbonGap` 13; `SetupPreviewFrameView.labelBandHeight` 24 and
  `bodyPadding` 8; `SetupRibbonView.actionRowHeight` 32 (the `.large` gold
  button's own height, so the reserved band IS the bar) and `barTopPadding` 12.
  **The frame is the flexible one and it CLIPS**: the window is a fixed
  820 × 560, so the head block and the bar take what their words need and the
  rehearsal gets the rest — the demo pane is CENTRED in the frame body, never
  pinned to it, and anything taller than the frame is cropped by the well. That
  leaves roughly **278 pt** for the surface on a two-line why, and
  `DemoPaneView.surfaceSize` is now exactly that (418 × 278). It was 330 for one
  commit, which the frame silently cropped ~50 pt off the BOTTOM of — the
  buttons the rehearsal exists to point at. The abstraction pass is what paid
  for the fit: with the mocks' paragraphs gone, the privacy card is 240 tall
  instead of 323. `everyMockFitsTheStage` pins it.
- **The spine is 288 pt wide** (`spineWidth`; it REPLACES the card era's
  `leftPaneWidth` of 420, itself a widening of an original 380 to stop the long
  earned titles truncating). The column carries short titles now, so it can be
  narrow — and the width the sentences needed went to the HERO, which is what the
  rebuild is for. The stage's own size is derived from what is left
  (`DemoPaneView.surfaceSize`), so widening the spine narrows the rehearsal.
- **Wrap stability is one constant now, and the old machinery is GONE.**
  `SetupCardView.textColumnWidth` and `primarySlotWidth` were deleted with the
  expanding card: the spine's single title truncates by tail (there is nothing
  below it whose height could depend on the wrap), and the ribbon measures every
  paragraph at ONE width — `SetupRibbonView.textWidth`, which is the stage's
  width, stamped into `preferredMaxLayoutWidth` at build time. The rule that
  survived both layouts: derive the wrapping width from a FIXED constant, never
  from a resolved frame in `layout()` — doing that made a state's height depend
  on when AutoLayout got there, and showed up as snapshot fixtures of the same
  state rendering at different heights. The button row needs no fixed slot any
  more: it is a plain leading-to-trailing run inside the reserved action band, so
  Allow… → Open Settings… simply moves Skip, which nothing else is aligned to.
- **One motion language.** There is no expand/collapse left in this window —
  `Tokens.Motion.collapseRevealDuration` is still the app's one clip-height
  constant (`CardView.setBodyCollapsed` in `AudioutPopoverUI` is the reference
  implementation, and `PopoverPanelViewController.collapseRevealDuration` aliases
  the token so there is one home), and the Setup window simply no longer uses it.
  What moves here is the checkmark slide-in, the stage crossfade, the stage dim,
  and the CTA fade.
- **Grant choreography, in this order:** re-front
  (`NSApp?.activate` + `makeKeyAndOrderFront`) → the checkmark slides into the
  row's trailing slot (width 0 → 16 pt + fade, 0.2 s easeOut, delayed 0.2 s) →
  the row's title rewrites to the earned one → the live edge bar moves to the
  next row → the stage crossfades (0.22 s; into the COMPLETE state the finale's
  one-shot rides this same crossfade) → the Start listening CTA fades in when the
  gate opens. It fires on the TRANSITION into complete, never on a repaint
  that changed nothing. **Reduce Motion, an off-window/occluded window, and `HeadlessRuntime`
  make every beat an instant swap** — steady states must render settled or
  snapshots stop being deterministic.
- **Keyboard:** the ribbon's PRIMARY owns Return, whatever it currently is — so
  "the one live Allow has Return until Done takes it" now holds with nothing to
  hand over, because when the gate opens the CTA *is* the primary. Focus is moved
  onto that button only when the live step changes or the gate opens
  (`refreshKeyboardFocus`); moving it on every repaint would fight a user who has
  tabbed onto the spine, which is itself keyboard-reachable (each pressable row is
  a first responder answering Space/Return, with a drawn focus ring).
- Accessibility and the PTP helper can only be confirmed by a silent poll, not a
  single re-focus check: `OnboardingViewController` runs
  `remoteControlPoll`/`ptpHelperPoll` `Timer`s (~1.5 s) while the window is open,
  each stopping once its status flips to granted/`.enabled`.
  `OnboardingWindowController` additionally re-fronts the window and calls
  `refreshStatuses()` on `NSApplication.didBecomeActiveNotification`. **The
  load-time `refreshStatuses()` is not optional:** `bluetoothStatus` starts
  `.unknown`, so without it the Bluetooth row paints undetermined even when the
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
  message rides the header subtitle tinted `Tokens.Color.warningText` (the
  authored text hue, not the `warning` alias, which is under the 4.5:1 body floor
  in light), so the layout is identical either way; a lost-permission re-entry
  also re-titles the header itself ("Let's get your sound back"), and its row is
  drawn BROKEN on the spine. It re-words itself to the still-missing subset and stands
  down to the welcome line once every permission it named is granted, without
  expanding to cover anything it didn't originally flag. **The welcome subtitle
  holds in EVERY other state, complete included** (owner decision 2026-08-11): the
  payoff line — "Your Mac's sound can reach every room.", deliberately with NO
  found-speaker count — belongs to the demo pane's finale card, under "You're all
  set.", never to the header. Which header message is showing is tracked as a
  message KIND, and that kind is what the banner hooks report — never a
  string-compare against the welcome copy. The `test_showsPermissionLostBanner` /
  `test_permissionLostBannerIsVisible` / `test_permissionLostBannerText` hooks
  kept their names so the intent stayed testable across the rebuild. There is a
  THIRD kind now, `.resume` ("Pick up where you left off"), for a presentation
  that opens with every REQUIRED permission already in and one optional step still
  undecided — fixed at `init` like the flow's own start position, so a grant made
  later cannot re-word the greeting.
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
    a DESATURATED accent on the switch and the badges, and
    the app's REAL icon in the Settings row. Never `Tokens` — the point is that it
    reads instantly as "this is what macOS will show you", and a warm surface or a
    dial-remapped accent inside it would read as Audiout drawing its own dialog.
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
    a PORTRAIT card (269 × 240) with a
    large ~24 pt continuous corner; an ICON TILE top-LEFT (which icon depends on
    the step — see below) with a circle badge carrying a white
    `hand.raised.fill` overlapping its bottom-trailing corner — the marker that
    says *privacy prompt*; a small grey
    Help circle top-right; a heavier two-bar TITLE band; a lighter four-bar gist
    block where the purpose string was; and two EQUAL CAPSULE
    buttons filling the content width, carrying their REAL labels. **There is no
    accent-filled default button** — drawing one would date the mock and, worse,
    send the user looking for a blue button that won't be there. Nothing is
    centred.
    - **The prose is ABSTRACTED and the colour DESATURATED** (owner decision
      2026-08-12 — this REPLACES "nothing is greeked", and with it the rule that
      "the body is the app's REAL Info.plist purpose string"). The card used to
      carry that string verbatim, so the paragraph rehearsed here was the
      paragraph macOS would show; what that bought in fidelity it lost in the
      thing the window is for. Two dense paragraphs of small type sat inside the
      rehearsal under a headline and a why line that had already said the same
      thing, so the eye read the WORDS instead of the SHAPE — and the card they
      made necessary was 323 tall, 50 pt more than the frame has. The anatomy is
      what makes the surface recognisable; the sentences are "close enough" as
      bars (`demoGistBlock`), exactly as the Settings mock's rows already were.
      The per-step copy tables were DELETED rather than left orphaned — they are
      in git history with the Info.plist linkage if the premise revives, and
      that history is also where the one title macOS phrases as a QUESTION
      ("Allow “Audiout” to find devices on local networks?") is recorded.
    - **The BUTTON LABELS are the exception, and they are marked.** They stay
      real text ("Don't Allow"/"Allow", "Open System Settings"/"Deny"): those
      words are what the user has to recognise when the real surface arrives.
      The CORRECT one wears `DemoButtonEmphasis.correct` — a slightly brighter
      fill plus a thin ring — and every other one is a `.ghost`: no fill, a 1 pt
      hairline, so it still reads as a button without competing.
      `exactlyTheCorrectButtonIsMarkedOnEverySurface` pins that exactly one per
      surface is marked.
    - **Nothing inside a mock is saturated blue or gold.** `DemoSystemColor
      .accent` is a desaturated slate rather than `systemBlue` (still the blue
      FAMILY, so the badge and the switch stay recognisable), the record tile is
      a muted red, and the alert's padlock gradient is warm GREY. Gold is spent
      entirely on the one button the step wants pressed, and a saturated
      rehearsal pulled the eye off it. `theMocksAreDesaturated` pins the accent
      and the padlock. The window's three traffic lights KEEP their real
      colours — 7 pt each, and they are the signature that says "a macOS
      window".
    - **The top-left tile is NOT the app's icon for any of the three real steps**
      (owner screenshots of the real dialogs, 2026-08-11). macOS draws a generic
      SYSTEM tile — the same one for every app — and only its CONTENTS change:
      the real Local Network dialog draws the Network pane's blue rounded square
      with a white wireframe globe, not Audiout's icon. So
      `DemoPromptMockView.iconView(for:)` returns a `systemTile`
      (`DemoSystemColor.systemBlue` fill, side × 0.23 continuous corner, white glyph
      at side × 0.55) for `.localNetwork` (`network`) and `.bluetooth`, and a RED
      one carrying `record.circle` for `.audio`. `.remoteControl` and
      `.speakerSync` never reach this path in practice and keep the app icon as
      the safe default. Everything else about the slot — size, position, the
      privacy badge — is identical either way.
      - **CORRECTION (live-confirmed 2026-08-11): System Audio's tile is the RED
        RECORD MARK, not the app icon.** This file used to claim macOS shows the
        asking app's own icon "where the grant is about capturing THAT APP's
        content", with System Audio as the example; the real dialog, seen live,
        leads with the recording mark instead. This is exactly the "if a real
        screenshot ever contradicts it, this is the one place to change" escape
        hatch below being used. It is also why `systemTile` takes a `fill`: red
        for recording, the accent blue for the capability panes.
      - **Bluetooth's glyph is the SYSTEM'S OWN, in both places.** SF Symbols
        ships no Bluetooth rune (`name_availability.plist` has no such name),
        but stock AppKit does — `NSImage.bluetoothTemplateName`, wrapped by
        `bluetoothRuneImage` (OnboardingChrome.swift, which copies before
        rescaling because the named image is a shared cache entry). The demo
        pane's system tile shows it white (matching the real Bluetooth dialog,
        owner screenshot 2026-08-11); the Bluetooth SETUP ROW's icon tile
        carries it tinted Bluetooth SIG brand blue
        (`Tokens.Color.bluetoothBrand`, Alec 2026-08-23) — the one row whose
        tint is a fixed brand hex, not a `permission*` hue. Never hand-draw
        this mark (Alec 2026-08-23: official glyph only).
    - The one per-step hook left is `confirmTitle`; the ANATOMY is shared and
      nothing else in the card varies by step but its icon tile.
      `DemoPaneView.surfaceSize` is
      418 × 278 — the Direction-04 stage inside the hero pane, sized to what the
      preview frame really has; the ribbon sits below the stage and Replay below
      the mock.
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
    - LANDSCAPE (288 pt wide, height from the content) with a small
      ~12 pt corner, against the card's portrait and its ~24 pt one;
    - a short HEADER BAND where the access is named;
    - a **full-bleed hairline divider** under it — the one structural element the
      privacy card has nothing like, and the fastest way to tell them apart;
    - a two-column body: the privacy PADLOCK left, a two-tier gist block right,
      the two centred against each other as a group;
    - a Help circle bottom-LEFT; bottom-RIGHT "Open System Settings" then
      "Deny". **The marking is the deliberate departure from the real panel**
      (owner decision 2026-08-12): the real alert makes the REFUSAL its
      accent-filled default, and drawing that faithfully emphasised the one
      button the user must not press. The warning line that used to correct it
      was deleted with the rest of the first-ask copy, so the mock carries the
      correction itself — "Open System Settings" is the MARKED button and "Deny"
      is a ghost. The SHAPE still tells the two surfaces apart; the emphasis now
      tells the truth about which one moves the user forward.
    - The padlock is `lock.fill` filled with a warm-GREY gradient (gold left
      with the rest of the desaturation), because the real
      icon is artwork with some dimension in it and a flat symbol at this
      size reads as a toolbar glyph. **TRAP: the mask has to be built in an
      `NSImage` of its own** — compositing the gradient `.sourceAtop` straight
      into `draw(_:)` does not clip to the symbol (the view's backing store is
      not the empty destination that mode needs) and the whole icon rect comes
      out a solid rectangle. Draw the gradient into a fresh image and knock
      the symbol's alpha out of it with `.destinationIn`.
    - Accessibility's padlock carries a circular accent badge with the
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
    Settings pass with the pointer flipping the Audiout toggle on, then back to
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
      the card is back to one shape (two equal capsules, "Don't Allow"
      beside its confirming title) and `confirmTitle(for:)` lost its `outcome:`.
    - `surfaceSize` is 418 × 278: the alert (288 × ~118), the privacy card
      (269 × 240), the standalone Settings pane (405 × 256.5 at `metricScale`
      1.35) and the handoff container (the Settings pane's 300 × 190) all clear
      their margins inside it, which `everyMockFitsTheStage` pins.
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
    - **Decision D1 — ONE stage that crossfades (K3), not stacked beats.** The
      alternative considered for the rebuild was showing an ask and its rehearsal
      as two stacked bands, each with its own moment. REJECTED on fit math: the
      window is a FIXED 820 × 560, the stage alone is `DemoPaneView.surfaceSize`
      and the ribbon needs its status/ask/body/honesty lines plus a reserved
      action row under it, and a second band could only be paid for out of the
      stage — which is the thing the whole direction exists to enlarge. So the
      hero keeps ONE stage, and step-to-step change is the existing 0.22 s
      crossfade (`stepCrossfadeDuration`), which is also what the finale's
      one-shot rides. If a second beat is ever wanted, the window height is the
      constraint to renegotiate first.
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
    centre's real distance to the farthest edge of the WHOLE Setup window
    (`DemoPaneView.finaleRippleBounds`, wired to the window-spanning canvas), so
    the wave sweeps the entire window and deliberately crosses the stage frame,
    the hero panel and — faintly, already dissolving — the left spine on every
    side (owner call 2026-08-12: the hero-panel fill gained ~6 px over the stage;
    the celebration is the whole window now). NOTHING clips or feathers it on the
    way out: the finale view has no `masksToBounds` of its own, the preview frame
    is chromeless for this state, and `RoundedContainerView`/the canvas set no
    mask either, so the wave simply leaves the stage and dies by its own fade —
    the reach change needed only re-pointing the bounds, never reparenting the
    layers. Owner-tested history: an authored end-scale hard-clipped the ripple
    live; the nearest-edge derivation that replaced it was rejected live as "one
    little line that goes out"; a per-edge feather mask added to soften the
    crossing was itself rejected live (2026-08-12) as visible cropping — the
    ring's arcs cut and faded well before completing the circle; and the
    hero-panel fill that followed was rejected as barely wider than the stage.
    The fade still completes before the NEAREST window edge, on every side, so no
    edge shows a hard stop; the spine sits farther out than that, so the pass
    over it is a soft glow, not a line. **Never re-introduce a clip or a mask
    here.**
    The one-shot starts on the crossfade, BEFORE the enclosing layout pass, so
    `playCelebration()` takes the fixed stage size first: a zero-sized layout
    puts both centres at the bottom-left corner and the wave visibly launches
    off the icon (live bug, 2026-08-12). For the same reason the AURA is born
    HIDDEN (model opacity 0) and revealed to its resting 1 only by the first
    `layout()` that resolves a real icon centre: its resting opacity is 1, so —
    unlike the rings, whose model 0 protects them — a paint before layout would
    bloom it from that same bottom-left corner (live bug, 2026-08-12, caught on
    the recording after the ring launch was already fixed).
    The aura/rings stamp resolved `gold`/`glow`, so the view observes the
    accent-dial and a11y notifications like the mocks do. On the animated
    transition the shot rides the step crossfade itself (fired as the fade
    STARTS), or the text would reveal twice.
  - **A pass must END where it started.** The settled frame is the surface AS THE
    USER WILL FIND IT — the ask, or the switch off — never the finished state: the
    pane shows the LIVE step's mock, so resting on "allowed" would sit beside a
    row still asking for that very permission and claim it was already
    given. Ending at the start also makes the loop seamless and gives the play-once
    path a truthful resting frame.
    - **AMENDMENT (K2, Direction 04) — the read-only BROWSE rests ON.** The one
      exception, and it is the same rule read the other way: a browse is a look
      at a step that IS granted, so the switch the user would really find on that
      pane is on. `DemoPaneView.show(step:mode:animated:restingSwitchOn:asBrowse:)`
      carries both flags — `restingSwitchOn` seeds `DemoSettingsMockView` with the
      switch already flipped, and `asBrowse` stops the timeline outright (a browse
      never loops, never offers Replay, and never animates, so browsing three
      granted rows in a row cannot put three timelines' worth of motion on
      screen). The LIVE step's rehearsal is untouched by this: it still rests at
      the ask.
  - Each loop is ONE restartable timeline: keyframes laid out over a single
    duration (`DemoMockView.keyframes` takes its score in SECONDS) driven by a
    sentinel animation whose completion decides whether to loop, so play,
    play-once, and stop are the same code path with a flag. The cursor moves by
    TRANSFORM, never by `position` — AutoLayout owns its frame and would reset it.
  - **The a11y boundary runs between the STAGE and the RIBBON, and it is now a
    boundary between SIBLINGS.** The demo is DECORATIVE and excluded from the
    accessibility tree; the ribbon directly beneath it carries every word of the
    information in stock controls VoiceOver reads. That the ribbon lives INSIDE
    the hero pane but OUTSIDE `DemoPaneView` is what makes it safe by
    construction: the opt-out walks the mock subtree only, so it can never reach
    the ribbon's buttons. Un-electing `mockHost` alone is
    NOT enough — an ignored container HOISTS its children, so the mock's real
    `NSTextField`s ("Allow", "Don't Allow", the pane title) stayed reachable. Every
    descendant is un-elected as the mock is installed
    (`DemoPaneView.installAccessibilityOptOut`), and a test walks the host asserting
    nothing is left. Replay, a real control, stays accessible. The two halves are
    pinned by SIBLING tests: `test_demoAccessibilityElements` must stay empty and
    `test_ribbonIsAccessible` must stay true — one without the other would let a
    broadened opt-out swallow the real UI and nothing would notice.
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
      not `DemoSystemColor.systemBlue`. The splash is arguably cursor chrome rather
      than mock content, but it plays ON surfaces that must read as macOS, and a
      gold burst would claim macOS draws Audiout-coloured feedback; the ripple
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
  values and a measured contrast rationale from the palette owner. The two rows are
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
  live-accent fill. **EVERY ribbon primary wears `goldCTA`** (owner decision 2026-08-12) — the
  everyday step button and the gate's CTA alike, because only ever one of them
  is on screen and it is always the thing to press; both therefore route through
  the measure. `RibbonContent.PrimaryKind` survives the merge because the GATE
  contract is written in it (`test_primaryIsCTA` = "the final check passed"), not
  because the two look different. Accent-filled Allow buttons elsewhere keep
  forced white and `Tokens.Font.body`; don't route THOSE through the measure (it
  would flip a blue accent's ink to black). **TRAP:**
  the shared `onboardingActionButton` factory must set
  `translatesAutoresizingMaskIntoConstraints = false`;
  `SetupRibbonView.rebuildActionsIfNeeded` constrains the factory's buttons and
  the directly-constructed gold CTA without an `NSStackView` doing the flag for
  them, so both must set it — left on, AutoLayout synthesises width/height from
  the zero frame and the button renders as nothing at all.
- Stock AppKit only (SF Symbols, `NSButton`, `NSProgressIndicator`, system colours)
  per repo house rules — the custom drawing is `IconTileView`/`RoundedContainerView`
  (no stock equivalent for the System Settings grouped-inset look) and the demo
  pane's mocks (above).
- Per-row tile colour lives ONLY in `Tokens.Color` (never a hardcoded `NSColor`)
  and tints the SF Symbol GLYPH only, via `IconTileView`'s `color` param — the tile
  fill and rim stay `Tokens.Color.raised`/hairline on every row. **The tint is
  PERMANENT** (owner decision 2026-08-11 — this REPLACES the earlier
  "granting crossfades the glyph to `Tokens.Color.gold`" rule): the grant-goes-gold
  crossfade duplicated the checkmark/status the row already shows, so the glyph
  never recolours and `IconTileView` has no `setLit`/`isLit` at all. The row's
  only state role for the tile is DIMMING (`lockedTileAlpha`, and a shallower
  `skippedTileAlpha` — the user reached that one, they just said no). The
  tints are dial-aware in `.subtle` only and must NEVER route through
  `accentDynamic`, which collapses distinct hues into one accent.
- **Four token changes came in with this rebuild** (all in `Tokens.Color`, all
  with their measured contrast rationale on the token itself — read that before
  re-tuning any of them):
  - `warningText` — authored warm warning INK for the header's lost-permission
    message and the ribbon's status line. `warning` itself is untouched (still the
    bare `.systemOrange` alias its non-text consumers use); it measures 2.24:1 vs
    `panel` in light, so a text consumer needed its own token rather than a
    re-tuned shared one.
  - `inkSecondary` — authored secondary text for these surfaces, because the
    system `secondaryLabel` alias is 3.95:1 vs `panel` in light, under the body
    floor. It is the spine's decided-row title ink and the ribbon's body ink.
  - `success` — the earned checkmark's green; the bare `.systemGreen` it replaces
    is 2.14:1 vs `panel` in light, under the 3:1 UI floor.
  - light `raised` is now `#F2F0EA` (was `#FBFBF9`, i.e. identical to
    `canvas`/`panel` — light mode had no surface ladder at all). The live row's
    lift is real in both appearances now. Other `raised` consumers
    (`WarmNameFieldCell`, `DeviceIconWellView`) pick up a faint warm well in
    light: intended, not a side effect to chase out.
  **OWNER-PENDING:** the three authored colour values are the rebuild's own
  choices, measured against the floors but not yet through the palette owner —
  they await Alec's sign-off.
- **Rich text is the RIBBON's alone, and its bold runs are `captionEmphasized`.**
  `OnboardingViewController.ribbonBody(_:)` turns `**bold**` runs into attributed
  text for the one word that matters (the button that is the WRONG answer, the
  app's own name in a list of twenty). The body is 11 pt caption, so the bold run
  is the CAPTION's emphasized weight — `bodyEmphasized` inside it sets a visibly
  bigger face on that one word. `bodyEmphasized` stays right for the things that
  really are body-sized: the spine's row titles and the bar's gold button.
- `test_` hooks throughout, because this window isn't visible to a headless
  harness: sequencing and the spine (`test_activeStep`, `test_browseStep`,
  `test_spineTitle(of:)`, `test_hasCheckmark`, `test_note(of:)`, `test_isLocked`,
  `test_isSkipped`, `test_rowIsBroken`, `test_rowIsBrowseSelected`), the press
  dispatch (`test_pressRow` — which drives the row's REAL press entry and then
  awaits what it started — `test_isRowPressable`, `test_rowPressIsRefused`,
  `test_rowAcceptsFirstMouse`, and the row a11y trio), the ribbon
  (`test_heroHeadline` / `test_heroWhy` / `test_previewFrameLabel`,
  `test_ribbonStatusText` / `BodyText` / `ButtonTitles` — the titles read
  leading-to-trailing, so the primary is LAST — `test_ribbonIsWaiting`,
  `test_ribbonTapPrimary` / `TapSkip` / `TapQuietLink`,
  `test_ribbonIsAccessible`, `test_rowEdgeBarFill`), the real Allow/Skip
  paths (`test_tapAllow`, `test_allow([steps])`, `test_tapSkip`), the gate
  (`test_doneExists`, `test_doneIsReturnDefault`, `test_snapBackStep`), the check
  row (`test_checkRowState`, `test_awaitFinalCheck()`), the announcements
  (`test_announcements`), the hero (`test_demoMode`, `test_demoStage`,
  `test_isDemoAnimating`, `test_demoShowsReplay`, `test_stageIsDimmed`,
  `test_heroRestingSwitchOn`), the mocks' buttons
  (`test_demoButtonTitles` / `test_demoMarkedButtonTitle`, one NSView walk that
  serves every surface), and the window
  level (`test_windowLevel`). `test_refreshStatuses()` is the AWAITED silent
  re-read — the load-time one fires a detached task, so a caller that needs its
  result (Bluetooth and Remote Control only reach `.granted` through it) has to be
  able to wait.
- **The Setup window runs its own display scale at five ledgered off-token
  sizes** (9.5 pt `DemoPaneView:2696`, 11.5 pt `SetupRibbonView:348`, 12 pt
  `DemoPaneView:2336`, 14.5 pt `SetupRibbonView:97`, 24 pt `DemoPaneView:1863`)
  — deliberate, same ledger idea as `DemoSystemColor`; do not tokenise
  without a type-scale decision.

## Feature Flow

1. App constructs `OnboardingWindowController` with a `SetupModel` and a reason
   (`.firstRun` or `.permissionLost`); `present()` activates the app, sizes the
   window to the fixed content size and centers it.
2. `OnboardingViewController.init` builds the `SetupFlowModel` (fixing where the
   flow starts). `viewDidLoad()` binds `model.onChange`, registers the PTP helper,
   kicks the silent `refreshStatuses()`, paints, and starts both polls.
3. The user presses the ribbon's primary — or anywhere on the live ROW, which is
   the same call. `SetupFlowModel.allow(_:)` decides:
   short-circuit an already-granted step, preflight a determined-and-denied one
   straight to Settings, single-flight anything already in flight, otherwise fire
   the prompt/probe — and logs exactly one named outcome per click to `Telemetry`
   (`setup_allow` + `outcome`). The VC performs any Settings destination (dropping
   the window level first) or re-fronts after a prompt. A press on any OTHER row
   browses it, re-arms its skip, or is refused (`rowPressed(_:)`).
4. `model.onChange` fires → `refresh()` recomputes every row, runs the grant
   choreography on any newly-completed step, re-derives the hero (which mock, and
   whether the stage is dimmed), rebuilds the ribbon, runs the final check when
   every row is decided, updates the gate and the header message, and speaks any
   transition VoiceOver would otherwise miss.
5. Returning from System Settings (`didBecomeActiveNotification`) restores the
   floating level, re-fronts, and re-reads live status; the polls independently
   catch Accessibility/Login-Items grants made without a focus change.
6. Done re-verifies and either finishes or snaps back. ✕ finishes without
   persisting completion.
7. `finish()`/`dismiss()` fire `onFinished` exactly once, unbind `model.onChange`,
   and close the window — the app starts the (deferred) backend from `onFinished`.

## The first-open licence gate (sibling window, not a Setup step)

`LicenseGateWindowController` is the OTHER window in this folder: on a
purchased build (`LicenseGate.shouldPresent`, Core) it precedes Setup, the
backend, and the surface — its pass runs the launch block `AppDelegate`
deferred; its abort (✕ or Quit) terminates the app via the injected closure,
never from this target. Rules that hold it together:

- **Register mirrors `LicenseSheetViewController`'s contract** — trim, a
  changed key clears the stored verdict, and the key is SAVED even when the
  server is unreachable, in which case the gate also OPENS (`pass`): "couldn't
  verify" must never read as "not yours", least of all on a blocking window.
  Every verdict's wording is `LicenseCopy` (Core), shared with the Settings
  sheet — never fork a string here.
- **`EmitterFieldView` is a port of the marketing site's hero field**
  (`fields/emitters.js` in the website repo): the MECHANISM — orbit, squash,
  ring shape, falloff, breathing, masks, tone map — is the site's shipped
  DEFAULTS remapped to the warm gold ramp, and must move together with the
  site. Four values are deliberate stage tunings for the small window (marked
  `STAGE TUNING` in the shader): emitter centres, density ×1.7, speed ×1.4,
  paper lift. Don't "fix" those back to the site's numbers — at 440 pt the
  site's wavelength reads as blobs. Colors resolve from
  `Tokens` per frame (bg=`canvas`, lo=`ember`, mid=`accent`, peak=blend), so
  the accent dial and Increase Contrast land free; the MSL source compiles at
  RUNTIME (`makeLibrary(source:)`) because SwiftPM cannot build `.metal`
  files. Reduce Motion = one still at t=40; headless or any Metal failure =
  flat `canvas`, never a crash, never a display loop.
- **`surge()` is the window's ONE authored motion moment** (an `active`
  verdict); don't add entrances or scatter effects around it.

## Map

| Type | What it is |
|---|---|
| `OnboardingWindowController` | Owns the window; lazy-create-then-reuse lifecycle; Done-vs-✕ dismissal contract; reactivate re-front; the floating level and its yield-to-Settings amendment. |
| `LicenseGateWindowController` | The first-open licence gate window: full-bleed field, hidden title, pass/abort single-fire contract. |
| `LicenseGateViewController` | The gate's content: mark + welcome + key field + gold Register over the field's calm centre; Register mirrors the Settings sheet. |
| `EmitterFieldView` | Metal port of the site's hero emitter field, gold ramp, 30 fps, still under Reduce Motion, flat `canvas` headless. |
| `OnboardingViewController` | Assembles the spine and the hero; turns `SetupModel` + `SetupFlowModel` into row states and ribbon content; owns `browseStep`, the press dispatch, the grant choreography, the Done gate, the announcements, the header message and both polling timers. |
| `OnboardingReason` | `.firstRun` vs `.permissionLost([RequiredPermission])` — drives the header message. |
| `SetupSpineRowView` / `SetupCardContent` / `SetupCardState` | One SPINE row: the compact status strip, its one trailing marker, the live/broken/browsed surface treatment, and the whole-row press target. Both per-state title tables (ribbon sentence and spine short form) live on `SetupCardContent`. |
| `SetupHeroHeadView` | The hero's top block: the headline over the why line, and nothing else. |
| `SetupPreviewFrameView` | The labelled well the rehearsal plays inside — caption band ("You'll see this from macOS", off for the finale) over a clipping body. Flexible: it takes whatever the head block and the bar leave. |
| `SetupRibbonView` / `RibbonContent` | The hero's lower half: the status line and the recovery paragraph over the bare bottom bar (hairline + trailing-aligned primary, Skip and quiet link). `RibbonContent` describes the WHOLE hero — the head block reads its `headline`/`why` — and decides nothing. |
| `SetupCheckRowView` | The sixth row: the automatic final check's pending/running/passed status strip. |
| `DemoPaneView` / `DemoMode` | The hero's STAGE: the mock swap crossfade, the browse/settled resting rules, the waiting dim, the motion policy, the Replay button. |
| `DemoMockView` | Timeline base class for the animated mocks: restartable score, settled-state hook, and the two multi-stage seams — `held(_:)` and the `stageWindow` offset. |
| `DemoPromptMockView` / `DemoSettingsMockView` / `DemoSettledMockView` | The privacy-dialog miniature, the Settings-pane miniature, and the completion finale (one-shot ripple, static gold-aura resting frame). |
| `DemoPromptMockView` on `.usageStats` | The SAME dialog mock the TCC cards use, with three deliberate departures — it is Audiout's card, not macOS's. The privacy hand badge and the Help button are HIDDEN (both are macOS's own markers), the buttons read "Don't Share"/"Share" rather than "Don't Allow"/"Allow" (`confirmTitle(for:)` / `refuseTitle(for:)`), and the icon is a TILE wearing the step's identity glyph and hue rather than the app icon — BOTH ways of fetching our own icon are wrong here (`demoIconAsAThirdPartyProcessSeesIt` reproduces another process's stale view of us, and `NSApp.applicationIconImage` resolves to a generic folder in the snapshot renderers, which is not a real `.app`). The frame carries no caption at all for this step, the same rule the finale follows. |
| `DemoSystemAlertMockView` / `DemoLockIconView` | The classic macOS ALERT panel Remote Control's two-stage pass opens on — header, divider, padlock, a MARKED "Open System Settings" beside a ghosted "Deny" — and the gradient-filled padlock it leads with. A passive surface: the host owns the cursor and the crossfade. |
| `DemoSettingsHandoffMockView` / `DemoStage` | Remote Control's two-stage FIRST ASK: the Accessibility alert handing off to the Settings pane in one pass, the owner of stage one's pointer, and which of its two surfaces the pass rests on. |
| `DemoWindowSurfaceView` / `DemoPushButtonView` / `DemoButtonEmphasis` / `DemoSwitchView` / `DemoSidebarView` / `DemoSettingsRowView` / `DemoGreekBarView` / `DemoPillView` / `DemoDotView` / `DemoCursorView` | The drawn parts of the mocks — window body, dialog button (capsule or rounded rect, marked or ghosted), switch, sidebar, list row, greeked label — `demoGistBlock` stacks those into the ragged blocks that stand in for a mock's prose — pill, circle, pointer. |
| `SystemSettingsOpener` | `NSWorkspace` seam for opening a `SystemSettingsPane`, with a Privacy & Security root fallback. |
| `ProminentButton` | Fill-tinted CTA button with key-window-aware title ink (forced white, or measured from the fill). |
| `IconTileView` / `RoundedContainerView` | Shared appearance-adaptive chrome (icon chip, grouped-inset card) — no stock AppKit equivalent. |

## Tests

| File | Focus |
|---|---|
| `AudioutCore/Tests/AudioutCoreTests/OnboardingUITests.swift` | Sequencing, locked/live rendering, the ROW press dispatch (live fire, browse toggle, skip re-arm, locked refusal), the ribbon's copy/buttons/waiting beat, the two-mode Allow and its deep links, the Done gate + snap-back + the browse that keeps the CTA, the final-check row, the announcements, the a11y boundary, the demo pane's mode/idle rules, the lost-permission header, the fixed-window fit, window level/float/re-present, Done-vs-✕. |
| `AudioutCore/Tests/AudioutCoreTests/SetupFlowModelTests.swift` | The sequence, gate and Allow decision table this UI renders (Core, not this folder, but the seam it depends on). |
| `AudioutCore/Tests/AudioutCoreTests/SetupModelTests.swift` | The underlying `SetupModel` probes/status, the Local Network found count, and the version-gated System Settings deep links. |
| `AudioutCore/Tests/AudioutCoreTests/OnboardingPermissionColorTests.swift` | The four per-row tile colours: distinctness, contrast floors, tint permanence across every row state, tile fill unchanged — plus the rebuild's four token changes (`warningText`, `inkSecondary`, `success`, light `raised`) against their stated floors. |
| `AudioutCore/Sources/onboarding-snapshot` | Offscreen PNG fixtures (per-step — including the in-flight wait and Remote Control's two-stage first ask at rest — remote-control-retry, a browsed granted row, a re-armed skip, the running final check, denied, complete, permission-lost × light/dark) in `dev/notes/onboarding-snapshots/`. |
