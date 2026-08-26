# Impeccable audit — Onboarding / first run

Surface: `AudioutCore/Sources/AudioutOnboardingUI/` + the Core permission models it renders.
Audience lens: a suspicious buyer who has just paid €30, is meeting five permission
prompts in a row, and will quit at the first hang or dead end.

## Scores

| Dimension | Score | One-line reason |
|---|---|---|
| Accessibility | 2 / 4 | Announcements, row-as-button and a policed demo opt-out are real work — but the first ask's only explanation lives in the a11y-excluded stage, focus is dropped on every wait, and one state lies to VoiceOver. |
| Performance | 3 / 4 | Single-flight everywhere, coalesced network probes, occlusion-gated motion, no polling of the expensive probes. Two timers outlive their usefulness and a hidden 3 s mDNS browse runs per activation. |
| Appearance & Theming | 3 / 4 | Token discipline is genuinely strict (`dynamicBlend`, permission hues never themed, `goldCTA` measured on both sides) — but `tertiaryLabel` slipped through unmeasured, and the checked-in light/dark evidence is stale. |
| Platform Conformance | 3 / 4 | The float/yield/quiet choreography and the macOS 26 deep-link rename are better than most shipping apps. The Settings-URL fallback can't actually fire, Escape does nothing, and the ✕ refuses silently. |
| States & Honesty | 1 / 4 | One required step has NO failure state at all and can lock the gate forever; an OS that cannot do the job is told "Everything's ready"; the audible-tone warning was deleted from the moment it is needed. |
| **Total** | **12 / 20** | |

## Verdict

**Not ready for a paying first-run user.** The craft in this surface is unusually
high — the two-mode Allow, the proven-both-answers Local Network primer, the
go-quiet-for-the-dialog rules, the visible final check — and almost all of it is
about honesty. The failures are concentrated in one place: the states nobody
rehearsed. Speaker Sync has no path for "the user said no" or "registration
failed", and because it is both REQUIRED and UN-SKIPPABLE, those states end the
purchase. Fix P0-1 and the five P1s and this is a strong first run; ship it as it
stands and a subset of buyers will hit an unfinishable setup with no words on
screen explaining why.

---

## P0

### P0-1 — Speaker Sync has no failure state, and it hard-gates the whole product

**Location**
- `AudioutCore/Sources/AudioutCore/SetupModel.swift:981-983` (`requiredPermissionsNotGranted()` demands `.enabled`)
- `AudioutCore/Sources/AudioutCore/SetupFlowModel.swift:125` (`skippableSteps` = bluetooth + remoteControl only)
- `AudioutCore/Sources/AudioutCore/SetupModel.swift:875-884` (`registerPTPHelper()` swallows the throw to stderr)
- `AudioutCore/Sources/AudioutOnboardingUI/OnboardingViewController.swift:1069-1152` (`activeRibbonContent` — no branch reads `ptpHelperStatus`)

**Verified.** A grep of the entire onboarding UI target finds `ptpHelperStatus`
referenced in exactly one place: the 1.5 s poll's exit condition
(`OnboardingViewController.swift:501`). `PTPHelperStatus` has four cases —
`.notRegistered`, `.requiresApproval`, `.enabled`, `.notFound` — and **three of
them render identically**: the untouched first ask, headline "Keep speakers in
perfect time", button "Turn On at Login". There is no denied state, no
"registration failed" state, no "the helper is missing from the bundle" state.

Now trace the user:

1. The user clicks "Turn On at Login". `SetupFlowModel.route` returns
   `.settingsOpened` and opens Login Items (`SetupFlowModel.swift:278-281`).
2. They decline to approve the background item — a completely rational response
   to "this app wants to install a background item", and the exact instinct this
   whole window is written for.
3. `ptpHelperStatus` stays `.requiresApproval`. `isComplete(.speakerSync)` is
   false forever. `isReadyForFinalCheck` is false forever. `isDoneAvailable` is
   false forever. **The "Start listening" button is never built at all** — the
   gate contract is ABSENT, not disabled.
4. Speaker Sync is not in `skippableSteps`, so `content.showsSkip` is false and
   `flow.skip(.speakerSync)` is a documented no-op (`SetupFlowModel.swift:317-320`).
5. The only exit is the ✕, which deliberately does not call `complete()`
   (`OnboardingWindowController.swift:256-260`), so the window returns on the
   next launch. Forever.

The user has paid €30 and cannot get out of the setup screen, and **not one word
on screen explains what is wrong or what would fix it.** The row just keeps
offering the same button.

The registration-failure branch is worse: `registerPTPHelper()` catches the
`register()` throw and writes it to stderr only. `PTPHelperService.swift:39-44`
records that `SMAppService` daemon registration cannot validate under ad-hoc
signing at all, and `PTPHelperStatus.notFound` is documented as "a packaging bug,
not a user decision. There is nothing the approval UX can do about it, same
posture as `PermissionStatus/unsupported`". But `.unsupported` **has** a UI
posture — `SetupCardState.autoPassed(note:)`, which passes the gate and explains
itself. `.notFound` has none: it holds the gate shut with the un-asked first ask
on screen. A signing or packaging regression therefore ships as "nobody can
finish setup", silently, and the app-level revocation audit
(`unmetRequiredPermissions()`, `SetupModel.swift:947-949`) will additionally
force-reopen this window on every wake.

**Impact.** A required, un-skippable step with three unrenderable states, one of
which is the user's own reasonable refusal. Unfinishable purchase, no
explanation, re-presented every launch.

**Recommendation** — three separate changes, all needed:
1. Give Speaker Sync real states in `activeRibbonContent`. `.requiresApproval`
   after a Login Items trip is a "we sent you there and it isn't on yet" state,
   not a first ask: it needs the recovery paragraph (`copy.detail` already
   exists) and the honest sentence that the switch is in Login Items, not
   Privacy & Security.
2. Give the user a way past it. Either make `.speakerSync` skippable with copy
   that says what a skip costs ("your speakers may drift apart"), or drop
   `.ptpHelper` from `RequiredPermission` and let the gate open without it. It
   cannot stay simultaneously required, un-skippable and unreportable.
3. Treat `.notFound` (and a thrown `register()`) as `.autoPassed(note:)` the way
   `.unsupported` audio is — the user cannot fix a packaging bug, so it must not
   gate them. Surface the caught error somewhere a support ticket can reach it,
   not stderr.

---

## P1

### P1-1 — On macOS 14.0/14.1 the flow says "Everything's ready" for a capability the Mac cannot provide

**Location**
- `AudioutCore/Package.swift:60` — `platforms: [.macOS(.v14)]`
- `AudioutCore/Sources/AudioutCore/AudioCapturePermissionProbe.swift:23,31-36` — below macOS 14.2 the probe returns `.unsupported` unconditionally
- `AudioutCore/Sources/AudioutCore/SetupFlowModel.swift:155` — `isComplete(.audio)` accepts `.unsupported`
- `AudioutCore/Sources/AudioutCore/SetupModel.swift:975-977` — `requiredPermissionsNotGranted()` excludes `.unsupported`

**Verified.** The package installs on macOS 14.0. The process-tap API arrives in
14.2. On 14.0/14.1 the audio row auto-passes with the note "Requires macOS 14.2
or later" (`OnboardingViewController.swift:766-772`) — which is honest, at row
level — and then the gate opens, the check row says **"Everything's ready"**, the
finale card says **"You're all set."** over **"Your Mac's sound can reach every
room."**, and the CTA says **"Start listening"**. On that Mac, nothing can be
captured and nothing will ever reach any room.

The row's small grey note is doing all the work against three separate
full-size claims to the contrary. The `dev/notes/onboarding-snapshots/onboarding-light-complete.png`
fixture shows exactly how loud those claims are.

**Impact.** The one product principle this window exists to serve — "The UI never
lies" — is broken at the payoff moment, for a user who has already paid and whose
Mac was never capable. Guaranteed refund, plausibly a bad review.

**Recommendation.** `.unsupported` audio must not silently pass the gate. Either
raise the package floor to macOS 14.2 (simplest, and it is the real floor of the
product), or give this state its own finale: a distinct check-row title and
finale card that say the Mac needs macOS 14.2 for system audio, with the CTA
either absent or renamed. Do not let "Everything's ready" render beside an
auto-passed audio row.

### P1-2 — The audible-tone warning was deleted from the only place it mattered

**Location**
- `AudioutCore/Sources/AudioutCore/AudioCapturePermissionProbe.swift:52-58` — "## The tone IS audible — the UI warns first"
- `AudioutCore/Sources/AudioutOnboardingUI/OnboardingViewController.swift:1163-1171` — `firstAskRibbonContent` sets `headline`, `why`, `primary`, `showsSkip`, and no `body`
- `AudioutCore/Sources/AudioutOnboardingUI/OnboardingViewController.swift:531-533` — the warning sentence, now only reachable from recovery states

**Verified.** `CoreAudioTonePermissionProbe` plays a 440 Hz sine at amplitude 0.1
to the default output device to prove the grant, and its own doc comment states
the design depends on the UI having warned first: *"a brief tone will play when
they Allow, so it's expected — a known, deliberate"* self-test. The sentence that
does the warning — "Allowing plays a brief tone to confirm it's working." — lives
in `SetupCardContent.detail`, and the 2026-08-12 copy deletion removed `detail`
from the first ask. It now appears only after a denial, a permission-lost
re-entry, a wait, or a stuck dialog — i.e. everywhere except before the tone
plays. The stale snapshot `onboarding-light-step1-audio.png` shows the warning in
its old position, which is why this reads as fine in the checked-in evidence.

**Impact.** The user's first action in a paid audio app is: grant a "record your
system audio" permission, then hear an unexplained tone come out of their
speakers. For the audience lens defined here — someone already suspicious of what
this app is recording — that is the single worst possible sequence, and the code
that produces it explicitly assumed it would not happen.

**Recommendation.** Put the tone sentence back on the System Audio first ask.
It does not need the whole `detail` paragraph — one line under the why line, or
appended to the why line, is enough. This is the one first-ask body the deletion
rationale ("a sentence explaining a picture the user is already looking at")
does not apply to: the rehearsal shows no tone.

### P1-3 — A row that shouts "needs attention" refuses every click, silently

**Location**
- `AudioutCore/Sources/AudioutOnboardingUI/OnboardingViewController.swift:856-859` — `isBroken` is computed for every step
- `AudioutCore/Sources/AudioutOnboardingUI/SetupCardView.swift:554-560` — `isPressable` is false for `.pending`
- `AudioutCore/Sources/AudioutOnboardingUI/SetupCardView.swift:450-452, 507-508` — the broken treatment paints regardless of state
- Evidence: `dev/notes/onboarding-snapshots/onboarding-light-permission-lost.png`

**Verified, and the snapshot proves the render path.** On a `.permissionLost`
re-entry naming two permissions, both rows draw broken — failure-tinted fill, red
edge bar, `exclamationmark.triangle.fill` — but only the one the flow is
currently ON is `.active`. The other is `.pending`, which is not pressable, which
means `mouseUp` falls through to `super`, `accessibilityPerformPress()` returns
false, no cursor rect is set and `acceptsFirstResponder` is false. The row is the
loudest thing on the spine and the only one the user cannot touch.

The permission-lost snapshot shows exactly this: "Hear your Mac's sound" and
"Keep speakers in time" both red-flagged, with two padlocked rows between them.

VoiceOver makes it worse: `stateSuffix` (`SetupCardView.swift:649`) appends
", turned off — needs attention" while `applyAccessibility` assigns role `.group`
with no action name — an element that announces a problem and offers nothing.

**Impact.** The flow's most urgent affordance is inert. A user whose Speaker Sync
was revoked clicks the Speaker Sync row — the obvious move — and gets absolute
silence. The design doc's justification for silent refusal ("a refusal that
animates invites a second try") was written for *locked* rows, where the user has
no reason to click; it does not survive being applied to a row drawn in the
failure hue.

**Recommendation.** Either make broken rows pressable — pressing one snaps the
flow to that step, which is what the user means — or stop drawing the broken
treatment on rows the flow has not reached, and let the header message carry the
"and one other thing is off" plural it already builds
(`permissionLostText(for:)`, line 1399). The first is better: the message already
names both, so the spine should be able to take the user to either.

### P1-4 — The first ask's actual instruction is invisible to VoiceOver

**Location**
- `AudioutCore/Sources/AudioutOnboardingUI/OnboardingViewController.swift:1163-1171` — the whole of a first ask's accessible copy
- `AudioutCore/Sources/AudioutOnboardingUI/DemoPaneView.swift` — `installAccessibilityOptOut` un-elects every mock descendant
- `AudioutCore/Sources/AudioutOnboardingUI/AGENTS.md:870-884` — the a11y boundary rule

**Verified.** The demo stage is deliberately and thoroughly excluded from the
accessibility tree, and the stated justification is that "the ribbon directly
beneath it carries every word of the information in stock controls VoiceOver
reads." That was true of the old layout. It is no longer true of the first ask,
because the first ask's ribbon now carries only the headline, the why line and
the button — everything else was deleted on the grounds that the picture says it.

What the picture says, and the ribbon does not:
- which of the two buttons in the real dialog is the right one (the mock marks
  the correct one with `DemoButtonEmphasis.correct` and ghosts the other);
- that Remote Control's first ask is **two clicks on two different windows** —
  the alert, then the Settings pane. The deleted ask line said this in words;
  now only `DemoSettingsHandoffMockView`'s two-stage animation does;
- for the system alert, that "Deny" is the trap and "Open System Settings" is the
  way forward — the mock deliberately re-emphasises this *against* the real
  panel's own default button (`AGENTS.md:697-702`), and that correction is
  purely visual.

The preview frame's caption ("You'll see this from macOS") is a reachable
`NSTextField`, but on its own it names a picture the user cannot see.

**Impact.** A VoiceOver user is sent into the Accessibility alert with no warning
that the emphasised default is the wrong button, and no idea a second surface
follows. Fails the project's own stated commitment: "VoiceOver parity with
visible state".

**Recommendation.** Restore a short accessible-only equivalent for the first ask
— either an `accessibilityLabel` on the preview frame describing the rehearsal in
one sentence per step, or (cleaner) re-add a one-line `body` to
`firstAskRibbonContent` for the two steps whose rehearsal carries an
instruction: System Audio (the tone, see P1-2) and Remote Control (two windows,
press "Open System Settings"). Do not solve it by un-electing less of the mock —
`test_demoAccessibilityElements` staying empty is a good rule.

### P1-5 — The checked-in visual evidence is two design generations stale

**Location** — `dev/notes/onboarding-snapshots/*.png` (all 26)

**Verified by inspection of all light/dark pairs.** Every PNG shows:
- the **old product name**, "Welcome to Audiouter", in the header and in every
  mock (the app is now Audiout, renamed on `main`);
- the **pre-Direction-04 hero**: no headline block, no why line, no labelled
  preview frame, and the deleted ask line ("This is what macOS will ask you
  next.") plus the reassurance paragraph still present;
- **plain bezel buttons** ("Allow…", "Open Settings…", "Start listening")
  instead of the gold `goldCTA` prominent button every ribbon primary now wears;
- **verbatim Info.plist prose** inside the privacy mock, which the 2026-08-12
  abstraction pass replaced with greeked bars, and **saturated system blue**
  accents, which the same pass desaturated;
- a generic blue **folder icon** where the brand mark belongs.

**Impact.** This is the surface's only recorded light/dark, state-by-state
evidence, and it depicts a design that no longer exists. Any appearance or
contrast review conducted against it — including the light/dark half of this
audit — reviews the wrong app. It also silently defeats the snapshot suite's
purpose as a regression net: the fixtures cannot fail against a design they
predate.

**Recommendation.** Regenerate the whole set from `AudioutCore/Sources/onboarding-snapshot`
before anyone reviews this surface visually again, and add regeneration to
whatever gate covers copy or layout changes here. (Note the standing warning that
`window-snapshot` goldens are unreproducible — that does not apply to these,
which are offscreen renders of a fixed-size content view.)

---

## P2

### P2-1 — `tertiaryLabel` is used for four onboarding strings and is under every contrast floor

**Location**
- `AudioutCore/Sources/AudioutSharedUI/Tokens.swift:89` — `tertiaryLabel` is a bare alias for `NSColor.tertiaryLabelColor`
- `SetupCardView.swift:428` — locked (pending) row titles
- `SetupCardView.swift:297` — the padlock glyph tint
- `SetupCheckRowView.swift:105` — the pending check row, "One last check"
- `SetupRibbonView.swift:179, 257` — the preview-frame caption, 10 pt semibold

**Verified by the repo's own reasoning.** The rebuild introduced `inkSecondary`
specifically because the system `secondaryLabel` alias "is 3.95:1 vs `panel` in
light, under the body floor" (`AGENTS.md:976-979`), and
`OnboardingPermissionColorTests` measures `warningText`, `inkSecondary`,
`success`, `goldCTA`, `gold` and the four permission hues against explicit floors.
`tertiaryLabelColor` is by definition lighter than `secondaryLabelColor`, so it
cannot clear 4.5:1 where `secondaryLabel` measured 3.95:1 — and it is not in the
test file at all.

The caption is the worst case: "You'll see this from macOS" at 10 pt semibold is
the *only* thing distinguishing macOS's window from Audiout's inside the hero,
which is the entire stated reason the preview frame exists
(`SetupRibbonView.swift:133-141`). It is drawn in the lightest ink in the palette.

**Impact.** Load-bearing copy below the readable floor in both appearances, on the
one surface the product promises to measure rather than eyeball.

**Recommendation.** Measure `tertiaryLabel` in `OnboardingPermissionColorTests`
against `panel`/`well`/`raised` in both appearances and both dial columns. Where
it fails: the caption and the pending check-row title should move to
`inkSecondary`; locked row titles can keep a dimmer ink but should be authored
and measured (a locked row is not decorative — it is the user's map of what is
still coming). The padlock glyph is non-text and needs 3:1, not 4.5:1.

### P2-2 — Keyboard focus is dropped on every wait and never restored

**Location** — `AudioutCore/Sources/AudioutOnboardingUI/OnboardingViewController.swift:1306-1313`

**Verified.** `refreshKeyboardFocus` returns early unless the active step changed
or the CTA appeared/disappeared. A wait changes neither. But
`SetupRibbonView.rebuildActionsIfNeeded` removes every button from the action row
for the wait beat (documented at `AGENTS.md:317-324`, "every button gone"), which
destroys the current first responder. When the answer lands, the buttons are
rebuilt as new instances and the guard is still satisfied, so focus is never
moved back.

Sequence for a keyboard-only user: Tab to "Enable System Audio" → Return → all
buttons vanish → answer resolves → buttons return → focus is on the window, not
on anything. They must Tab in from the top for every one of the five steps.

**Impact.** The window's stated keyboard contract ("the ribbon's PRIMARY owns
Return") holds only for the mouse path.

**Recommendation.** Also re-anchor focus when `RibbonContent.buttonSignature`
changes from empty to non-empty — i.e. when the wait ends. `SetupRibbonView`
already computes that signature and knows when it rebuilt; surface it.

### P2-3 — The wait is never announced

**Location** — `OnboardingViewController.swift:1265-1299` (`announceTransitions`), `1084-1096` (the wait's status line)

**Verified.** Announcements fire for completions, refusals, the check passing and
a snap-back. The wait — "Waiting for your answer — the real dialog is on screen
now." — is a plain `NSTextField` in the ribbon that VoiceOver will not read on its
own. Combined with P2-2, a VoiceOver user presses Allow and experiences: the
button they were on disappears, focus goes nowhere, and nothing is said. For
Local Network that silence can last up to 60 s (`SetupModel.firstAskBrowseSeconds`).

**Recommendation.** Announce the wait on its edge (the same place `syncPromptInFlight`
already detects), and announce the stuck-dialog hint when `markPromptStuck` fires.

### P2-4 — The ✕ is silently refused for up to 60 seconds

**Location** — `OnboardingWindowController.swift:287-289`

**Verified.** `windowShouldClose` returns `!isPromptInFlight`. During a Local
Network first ask that is up to 60 s; the stuck-dialog hint that is supposed to
be "the honest explanation for why the ✕ isn't doing anything" only appears after
`stuckPromptDelay` = 20 s, sits in the ribbon on the far side of the window from
the ✕, and never mentions the close button.

**Impact.** For 20 s the user clicks the close box and the app does literally
nothing — the exact "apparent hang" this audience quits over. The reasoning
behind the refusal is sound; the silence is not.

**Recommendation.** Do not refuse silently. On a refused close, put the
explanation where the click was: a brief status line ("Answer the macOS dialog
first — it's on screen now") or the standard window shake, and shorten the path
to the stuck hint when the user has actively tried to leave.

### P2-5 — The System Settings deep-link fallback cannot fire

**Location** — `AudioutCore/Sources/AudioutOnboardingUI/SystemSettingsOpener.swift:16-20`

```swift
if !NSWorkspace.shared.open(pane.url) {
    _ = NSWorkspace.shared.open(SystemSettingsPane.privacyRoot)
}
```

**Verified against the repo's own observation.** `SystemSettingsPane`'s doc
(`SetupModel.swift:166-176`) records that the pre-26 bundle id "misroutes there
(**it opens Settings, but not the pane asked for**)". That is `NSWorkspace.open`
returning `true` for a URL that did not do what was asked — which is the general
behaviour for `x-apple.systempreferences:` URLs: the scheme resolves, Settings
launches, and a bad anchor is ignored. So the `false` branch never runs, and the
documented promise — "if a specific pane URL won't open we fall back to the
Privacy & Security root, which always does" — is not a promise the code can keep.

**Impact.** When Apple next renames an anchor, the user is dropped on whatever
pane Settings happened to open, while the ribbon's copy tells them precisely
where to go ("Turn **Audiout** on under Privacy & Security ▸ Screen & System
Audio Recording"). The recovery path fails in the one scenario it was written for
— and this is the recovery path for every denial in the flow.

**Recommendation.** Either drop the dead fallback and be honest in the doc that
the anchor is best-effort, or make the check real (open the root first and the
anchor second is not right either; a version-gated table plus a live check per OS
release is the honest option). At minimum, keep the ribbon's written path
sentence, which is what actually saves the user today — do not treat the deep
link as sufficient on its own.

### P2-6 — Remote Control's Settings-trip spinner can latch

**Location** — `OnboardingViewController.swift:1562-1566` (arms `settingsTripStep` on the `.none` destination), `457-459` / `466-477` (only a real resign→activate pair clears it), `826-830` (`isAwaitingOutcome`)

**Verified in code; the trigger needs a live check.** Remote Control's first ask
raises the Accessibility alert and returns with destination `.none`, at which
point `settingsTripStep = .remoteControl` is armed. That flag is cleared in
exactly two ways: the step completing, or `appDidBecomeActive` firing *after*
`appDidResignActive` set `settingsTripDeparted`. If the user clicks **Deny** on
that alert without the app ever losing the front, neither happens, and
`isAwaitingOutcome(.remoteControl)` stays true — so the spine row spins forever
while the ribbon has already moved on to the "Open Settings…" recovery content.
A row claiming to be waiting for something that has already been answered.

Whether the Accessibility alert makes this app resign active is not determinable
from the code — **needs live check** (deny the Accessibility prompt without
switching apps, and watch the Speaker/Remote Control row's trailing slot).

**Recommendation.** Give the trip flag a ceiling the way Bluetooth's prompt has
one (`bluetoothPromptTimeout`), or clear it on any repaint where the step's
status has been re-read and is still not granted. A waiting indicator with no
timeout is the same class of bug the Bluetooth timeout already fixed.

### P2-7 — An auto-passed row tells VoiceOver it was "allowed"

**Location** — `AudioutCore/Sources/AudioutOnboardingUI/SetupCardView.swift:650-655`

```swift
case .completed, .autoPassed: return ", allowed"
```

**Verified.** `.autoPassed` exists precisely because "claiming a grant nobody
made would be a lie" (`SetupCardView.swift:132-137`), and the visible row honours
that: no checkmark, a permanent note instead. The spoken label does not — it says
"Hear your Mac's sound, allowed" on a Mac where the grant does not exist. The
note is a sibling `NSTextField` inside a row whose role is `.group`; whether
VoiceOver reads it after the row label **needs live check**, but the row's own
label is wrong either way.

**Recommendation.** Give `.autoPassed` its own suffix carrying the note — e.g.
`", \(note)"` → "Hear your Mac's sound, requires macOS 14.2 or later". One line,
and it fixes the spoken half of P1-1 for free.

---

## P3

- **Escape does nothing.** `OnboardingWindowController.swift:61-62` builds a
  `.titled, .closable` window with no cancel key equivalent, so Escape is inert.
  For an assistant-shaped window HIG expects Escape to take the cancel path,
  which here is the ✕. Low severity because the ✕ is present and the gate
  semantics are deliberate — but a user who has been told "there is no way
  forward" will reach for Escape.
- **Two polls outlive their purpose.** `startRemoteControlPoll` /
  `startPTPHelperPoll` (`OnboardingViewController.swift:481-504`) invalidate only
  on success. A skipped Remote Control keeps calling `AXIsProcessTrusted()` every
  1.5 s for the life of the window, and in the P0-1 scenario the PTP poll runs
  forever. Cheap individually, but they are the window's only background work and
  they never stop.
- **A hidden 3 s mDNS browse per app activation.** `refreshStatuses()`
  (`SetupModel.swift:847-849`) re-primes Local Network on every activation once
  the status has left `.unknown`, at `rescanBrowseSeconds` = 3. Invisible (the
  phase is not set, so no spinner), but it means Cmd-Tabbing back to the setup
  window starts three seconds of network browsing every time.
- **"Speaker Sync access was switched off."** `permissionLostText`
  (`OnboardingViewController.swift:1411`) applies the word "access" uniformly, but
  Speaker Sync is a Login Items approval, not an access grant — and the
  `displayName` mapping (line 1421) was already changed once to avoid jargon. The
  sentence reads slightly wrong for the one item in the list that is not a
  permission.
- **The header is not marked as a heading.** `titleLabel` (20 pt bold, line 373)
  and `heroHeadline` (`SetupRibbonView.swift:91`) are plain labels with no
  `accessibilityRole` of heading, so VoiceOver rotor navigation has no structure
  to move through in a window whose whole layout is two columns of text.

---

## Systemic patterns

**1. Every state that was rehearsed is excellent; every state that was not is
absent.** The states someone sat down and thought about — denied, unanswered,
stuck, permission-lost, browse, skip-reopen, macOS 14 vs 15 — are handled with
more care than most shipping apps manage, down to pronoun agreement in the plural
lost-permission sentence. The failures (P0-1, P1-1, P2-6) are all states with no
authored copy at all, which then fall through to a default that quietly asserts
the opposite of the truth. The pattern to fix is not "add these three branches" —
it is that `SetupStep` × status has no exhaustiveness check anywhere. Both title
tables are `switch`-driven (so a new *step* is a compile error), but a new or
unhandled *status* silently renders the first ask.

**2. The 2026-08-12 copy deletion removed load-bearing sentences along with
decorative ones.** The rationale — "each explained a picture the user is already
looking at" — is right for the ask line and the reassurance paragraph. It is
wrong for the tone warning (P1-2), which describes something the picture cannot
show, and it silently broke the a11y boundary's stated premise (P1-4), because
the ribbon stopped carrying "every word". Neither consequence was caught, because
the snapshot fixtures still show the old copy (P1-5).

**3. Honesty is enforced by convention, not by construction.** The invariant "the
UI never lies" is stated in a dozen doc comments and defended by careful naming
(`autoPassed` vs `completed`, `.requested` vs `.denied`, `foundSpeakers: Int?`
distinguishing nil from zero). But it is enforced nowhere: the same file that
insists `.autoPassed` must not claim a grant hands VoiceOver ", allowed"
(P2-7), and the flow that carefully refuses to claim Local Network is granted
will happily say "Everything's ready" on a Mac with no capture API (P1-1). The
gate's conditions are computed from `requiredPermissionsNotGranted()`, which
treats "cannot be granted" and "is granted" as the same answer — that conflation
is the root of P1-1, and it is one function.

**4. Contrast is measured where someone remembered to measure it.**
`OnboardingPermissionColorTests` is genuinely rigorous — dial columns, both
appearances, both surfaces, explicit floors, resolved-component comparison. It
covers exactly the tokens the rebuild authored, and not the one system alias the
rebuild left behind (P2-1). "Contrast is measured, not eyeballed" is a product
commitment; it currently means "the new tokens are measured".

---

## Positive findings

These are worth protecting, because several of them are unusual:

- **The permission model is honest about what macOS can and cannot tell it.**
  `PermissionStatus`'s five cases and their doc comments are the clearest
  statement of the TCC observability problem I have seen in a codebase — a
  provable grant via self-discovery, a provable refusal via
  `kDNSServiceErr_PolicyDenied`, and `.requested` meaning only "asked, nothing
  answered". Most apps collapse all three into a boolean and then lie.
- **Local Network's sticky grant.** `probeLocalNetwork` refusing to downgrade a
  proven `.granted` on an empty rescan (`SetupModel.swift:684-690`) is the fix
  for a live state-flap, and the comment records exactly why. This is the right
  instinct applied correctly.
- **The final check is visible.** Making the ~2 s verification a line item with a
  spinner, after telemetry showed five clicks swallowed inside an invisible one,
  is exactly right — and holding the finale, the ripple and the CTA to arrive on
  the same repaint means success and forward motion land together.
- **The two-mode Allow never promises a prompt that will not fire.**
  `offersSettingsFallback` kept in lockstep with `SetupFlowModel.route`'s
  preflight, with the requirement written down in both places, prevents the
  single most common permission-UX failure ("Allow" that does nothing because
  macOS only asks once).
- **The float / yield / go-quiet choreography.** Dropping the window level for the
  two normal-level surfaces, staying floating for TCC dialogs, gating the restore
  on having actually lost the front, and giving up focus (not z-order) for the
  length of an ask — every one of those was a live bug, and each fix is scoped to
  the real mechanism rather than papered over.
- **`acceptsFirstMouse` on the row and the CTA.** The bounce-to-Settings-and-back
  returning to an inactive app, where a stock control spends the click on
  activation, is a genuinely obscure cause of "the button needs two clicks", and
  it is fixed at the right layer with the window-level click witness beside it.
- **The demo pane's accessibility opt-out is policed from both sides.**
  `test_demoAccessibilityElements` must be empty *and* `test_ribbonIsAccessible`
  must be true — sibling tests, so a broadened opt-out that swallowed the real UI
  would fail loudly. That is the right shape for an invariant like this.
- **Motion policy.** Reduce Motion → play once, rest settled, offer Replay;
  off-window/occluded/headless → instant swap; the finale one-shot consumed so a
  repaint cannot re-fire it, but left unspent off-window so the presentation that
  can show it still gets it. Complete, and it makes snapshots deterministic as a
  side effect.
- **The `nil` vs `0` speaker count.** "No browse ran at all" and "a real browse
  saw nothing" get different sentences, and the earned title is a checkable
  detail rather than a checkmark nobody can verify. Small, and exactly the right
  call.
- **`Int?`, telemetry naming, and the exhaustive `telemetryDescription`
  switches.** Named outcomes per click (`prompt_rearmed`, `swallowed_in_flight`,
  `auto_check_refused`) mean a live session leaves a readable trail — which is
  how several of the bugs above were found in the first place.
