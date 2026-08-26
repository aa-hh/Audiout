# T6 — Onboarding / first run: audit fixes (work order)

**Branch:** `claude/fix-onboarding` — create as a worktree from current `main`-line HEAD
(`git worktree add .claude/worktrees/fix-onboarding -b claude/fix-onboarding`), push to
`origin/claude/fix-onboarding` immediately. Working tree is clean; no uncommitted work to carry.

**Binding build/test rule (coordinator):** ALL compiles and test runs go through the wrapper
scripts, which route work to the remote test mule: `bash scripts/build.sh` and
`bash scripts/run-tests.sh --filter <Suite>`. Bare `swift`-CLI build/test invocations are
FORBIDDEN (they opt out of the mule, the concurrency cap, and the sources cache, and pin work
to the machine running many parallel agents). `AUDIOUT_BUILD_LOCAL=1` only if the mule is
unreachable, and report it. Never pipe `run-tests.sh` through `| tail` (it eats the exit
code). Never kill or abandon an in-flight remote test run (orphaned legs pin the build lock).

**Owned files (touch nothing else except the two scoped exceptions):**
- `AudioutCore/Sources/AudioutOnboardingUI/*` (all files, incl. its AGENTS.md)
- `AudioutCore/Sources/AudioutCore/SetupModel.swift`
- `AudioutCore/Sources/AudioutCore/SetupFlowModel.swift`
- `AudioutCore/Sources/AudioutCore/PTPHelperService.swift` (seam only)
- `AudioutCore/Package.swift` (platform floor line only)
- Test files under `AudioutCore/Tests/AudioutCoreTests/` for the suites named in Verification
- SCOPED EXCEPTION 1: `AudioutCore/Sources/AudioutCore/AppSettings.swift` — ONE new persisted
  Bool property, nothing else (step 2)
- SCOPED EXCEPTION 2: `AudioutCore/Sources/AudioutCore/PermissionMode.swift` — Sendable
  annotation on `SimulatedPTPHelper` ONLY if the compiler demands it (step 3)

**DO NOT TOUCH:** `Tokens.swift`, `scripts/make-app.sh` (already ships `MIN_MACOS=14.2` —
no change needed, nothing to hand to T7), `AudioutApp/AppDelegate.swift`, the demo-pane
accessibility opt-out (`DemoPaneView.installAccessibilityOptOut`) and its policing tests —
`test_demoAccessibilityElements` (must stay empty) and `test_ribbonIsAccessible` (must stay
true) pass AS-IS, unmodified. No token swaps, no snapshot regeneration, no cleanup, no new
abstractions, no error handling for impossible cases, no backwards-compat shims.

**Deferred (do not do):**
- P1-5 snapshot fixture regeneration (`dev/notes/onboarding-snapshots/*.png`) — post-merge wrap-up.
- P2-1 `tertiaryLabel` contrast (SetupCardView:428, :297; SetupCheckRowView:105;
  SetupRibbonView:179, :257) — the tokens track owns every token swap. Do not touch these colors.

---

## Goal

Setup is the first thing a paying (€30) user sees, and the audit found the failures are
concentrated in un-rehearsed states: Speaker Sync can lock the gate forever with no words on
screen (P0-1), macOS 14.0/14.1 is promised a capability it cannot have (P1-1), the audible
tone probe fires unwarned (P1-2), and several waits/refusals are silent to keyboard and
VoiceOver users. This order gives every one of those states authored words, an exit, or both —
at minimal diff, in this window's plain-speech voice (PRODUCT.md:88 binds: decision-bearing
strings read in plain speech, no jargon).

## Verified facts

Each was read in this session; you may rely on them without re-deriving.

- `SetupFlowModel.skippableSteps = [.bluetooth, .remoteControl]` — SetupFlowModel.swift:125.
  `skip()` guards on it (317-320). `isComplete(.speakerSync)` demands `.enabled` (163).
  `isReadyForFinalCheck = setup.requiredPermissionsNotGranted().isEmpty && activeStep == nil` (357-359).
  `auditVerdict` → `Self.firstUnmetRequiredStep(in:)` → `requiredPermissionsNotGranted().first` (390-395, 472-474).
- `SetupModel` is `@MainActor final class` (SetupModel.swift:428-429). `ptpHelperStatus` set at
  four sites: refreshStatuses (852), registerPTPHelper (882), refreshPTPHelperStatus (897-899),
  auditRequiredPermissions (~1043-1046). `registerPTPHelper()` swallows the throw to stderr
  only (875-884). `unmetRequiredPermissions()` counts ptpHelper unmet on anything but
  `.enabled`/`.notRegistered` (947-949) — the app wake audit uses this to force-reopen the
  window. `requiredPermissionsNotGranted()` demands `.enabled` (981-983).
  `complete()` persists via `settings.hasCompletedSetup` (1061-1062); `settings: AppSettings`
  is a stored let (499).
- `AppSettings` persistence pattern: key constant + computed var over `defaults`
  (AppSettings.swift:85, 146-149).
- `PTPHelperStatus` has `.notRegistered/.requiresApproval/.enabled/.notFound`; `.notFound` is
  documented "a packaging bug, not a user decision… same posture as PermissionStatus/unsupported"
  (PTPHelperService.swift:25-31 area). `PTPHelperManaging` is NOT Sendable (PTPHelperService.swift:46);
  `SMAppServicePTPHelper` is a struct holding `let service: SMAppService` (86-130) and has
  `unregister()`. Conformers: `SimulatedPTPHelper` (PermissionMode.swift:201), test fakes at
  SetupModelTests.swift:198 (already `@unchecked Sendable`), PTPHelperReconcilerTests.swift:28/44
  (:44 already `@unchecked Sendable`), OnboardingWindowLevelTests.swift:32,
  OnboardingUITests.swift:204 (both plain).
- AppDelegate re-registers the helper at every launch when status is `.notRegistered`
  (AppDelegate.swift:919-929 — read-only fact; file is off-limits). Consequence: an
  unregister-on-skip design cannot work; a skip must instead be remembered (step 5d).
- `activeRibbonContent` (OnboardingViewController.swift:1069-1152) has NO speakerSync branch
  other than the `.permissionLost` one (1100-1108, which already carries "Open Login Items…"
  at 1106). `firstAskRibbonContent` = headline + why + primary + showsSkip only (1163-1171).
- Speaker Sync copy deck (content(for:), 587-601): detail = "Your speakers play in perfect
  time by sharing one clock, through a small helper. Approve it once in Login Items.",
  whyLine = "A small helper shares one clock so your speakers never drift.",
  allowTitle = "Turn On at Login", isSkippable: false.
- Audio: `audioAutoPassNote = "Requires macOS 14.2 or later"` (772);
  `state(for:)` special-cases only audio for `.autoPassed` (759-770). Audio whyLine =
  "Audiout needs this to send your music to your speakers." (535); detail already contains
  "Allowing plays a brief tone to confirm it's working." (531-533).
- `AudioutCore/Package.swift` is swift-tools 5.10 with `platforms: [.macOS(.v14)]` (:60);
  `scripts/make-app.sh` already defaults `MIN_MACOS="${MIN_MACOS:-14.2}"` (:34) and stamps
  `LSMinimumSystemVersion` from it (:610).
- `SetupCardView.isPressable` excludes `.pending`/`.autoPassed` (554-560); `isBroken` is a
  stored flag passed via `apply` (450-452 uses it); `applyAccessibility` derives role from
  `isPressable` (640-645); `stateSuffix` returns ", allowed" for `.autoPassed` (647-656);
  `accessibilityAction` = `isLive ? content.allowTitle : "Show"` (660-663).
- `rowPressed(_:)` dispatch (1431-1448): live → `ribbonPrimaryTapped()`; `.pending/.active/.autoPassed`
  → silent break. `displayedActiveStep` honors `snapBackStep` while incomplete (626-629);
  `refresh` clears snapBackStep when its step completes (651); `announceTransitions` already
  announces the ribbon status on a snapBackStep change (1293-1298).
- `isBroken(step)` = live-and-provably-denied, or permission-lost-and-still-missing (856-859).
- Focus: `refreshKeyboardFocus` re-anchors only on active-step change or CTA appear/disappear
  (1306-1313); a wait strips every button (RibbonContent.buttonSignature and
  `rebuildActionsIfNeeded` guard, SetupRibbonView.swift:61-66, 440-443); VC already reads
  `ribbon.primaryButton` (1312).
- `syncPromptInFlight()` fires on the in-flight EDGE (940-951); `markPromptStuck()` (1012-1016);
  `stuckPromptDelay = 20` (974); `stuckPromptSteps = [.audio, .localNetwork, .bluetooth]` (979);
  `waitingStatus` (1027); `announce()` posts + records into `test_announcements` (1255-1261).
- ✕ refusal: `windowShouldClose` returns `!isPromptInFlight`, silently
  (OnboardingWindowController.swift:287-289). Window is `.titled, .closable` (:61); no Escape
  handling anywhere in the target (`cancelOperation` does not appear in AudioutOnboardingUI).
- Settings-trip latch: `applyAllowResult` arms `settingsTripStep` on Remote Control's `.none`
  destination (1560-1566) and on real trips (1567-1570); it clears only on step completion
  (660-663) or a resign→activate pair (457-477). The Remote Control poll fires `onChange` only
  on a transition (SetupModel.swift:908-920), so no repaint happens in the deny-without-resign
  case — "clear on repaint" can never fire; a timeout ceiling is the only variant that works.
- Polls: `startRemoteControlPoll`/`startPTPHelperPoll` (481-504), 1.5 s, invalidate only on
  granted/`.enabled`. The PTP poll's `ptpHelper.status` is a synchronous launchd XPC round-trip
  on the main thread (perf P2-6; SetupModel.swift:896-901).
- `SystemSettingsOpener.open` falls back on `NSWorkspace.open == false` (SystemSettingsOpener.swift:16-20)
  — dead branch: the scheme resolves and returns true even when the anchor is wrong
  (SetupModel.swift:113-121 doc records the misroute). `privacyRoot` is referenced elsewhere
  (SetupModelTests:1347,1369) — keep the symbol, remove only the opener's use.
- `permissionLostText(for:)` hand-joins names and splices "them/it" (1399-1413); says
  "\(joined) access was switched off after setup." — wrong for a Login Item (hardening §5 P2 +
  onboarding P3). Pinned by `test_permissionLostBannerText`-named hooks (AGENTS.md:543-545).
- Header labels: VC `titleLabel` 20 pt bold (372-377); hero headline label in `SetupHeroHeadView`
  (SetupRibbonView.swift:69-95 area). `NSAccessibilityHeadingRole` in AppKit is macOS 26+
  (SDK NSAccessibilityConstants.h:553) — use the raw AX string instead (step 7k).
- Preview-frame caption: `SetupPreviewFrameView.captionLabel` (SetupRibbonView.swift:161, 179);
  VC sets `previewFrame.caption` in `refreshHero` (701-716). `demoMode(for: .remoteControl)`
  returns `.prompt` exactly on its first ask (872-882 + offersSettingsFallback 793).
- Telemetry writes JSON lines to `~/Library/Logs/Audiout/` (Telemetry.swift:35-70) — a place a
  support ticket can reach; disabled under HeadlessRuntime.
- Baseline (this session, pre-change):
  `bash scripts/run-tests.sh --filter 'OnboardingUITests|SetupFlowModelTests|SetupModelTests|OnboardingPermissionColorTests|OnboardingWindowLevelTests|SetupTelemetryTests'`
  → "Test run with 259 tests in 7 suites passed", exit 0.

## Copy deck (exact strings — use verbatim; em-dashes are \u{2014}, ellipses \u{2026})

- C1 audio whyLine (P1-2): `Audiout needs this to send your music to your speakers. Allowing plays a brief tone to confirm it's working.`
- C2 speakerSync recovery status (P0-1): `It isn't on yet — the switch is in Login Items, not Privacy & Security.`
- C3 speakerSync recovery body (P0-1): `Your speakers play in perfect time by sharing one clock, through a small helper. Approve it once in Login Items. You can skip this for now — without it your speakers may drift apart.`
- C4 speakerSync recovery primary: `Open Login Items…` (identical to the existing string at VC:1106)
- C5 speakerSync auto-pass note (P0-1): `Couldn't be turned on`
- C6 close-refused status (P2-4): `Answer the macOS dialog first — it's on screen now.`
- C7 permission-lost, one name (hardening 15 / P3): `<Name> was turned off after setup. Turn it back on and your speakers pick up where they left off.`
- C8 permission-lost, several names: `<A and B[, and C]> were turned off after setup. Turn them back on and your speakers pick up where they left off.` (join via `ListFormatter.localizedString(byJoining:)`)
- C9 Remote Control spoken caption (P1-4): `You'll see this from macOS: an alert, then System Settings. Choose Open System Settings — not Deny — then turn Audiout on in the list.`

## Steps

Do them in order. All code compiles together; run the Verification suite after step 9.

**1. Package floor → 14.2 (P1-1).**
`AudioutCore/Package.swift:60`: change `platforms: [.macOS(.v14)]` to
`platforms: [.macOS("14.2")]` (the version-string form; `.v14` cannot express a minor).
This closes P1-1 outright — the app can no longer install on 14.0/14.1, so `.unsupported`
audio can no longer reach a real user, and no distinct finale is needed. Do NOT delete the
`.unsupported` machinery (`UnsupportedAudioCaptureProbe`, `isComplete(.audio)`'s `.unsupported`
arm, `audioAutoPassNote`): test fakes exercise it and the gate logic is load-bearing. Update the
comment block above the platforms line if it names `.v14`.

**2. AppSettings: one persisted flag.**
In `AppSettings.swift`, following the `hasCompletedSetup` pattern exactly (Keys constant +
computed var over `defaults`): add key `"speakerSync.wasEnabled"` and
`public var speakerSyncWasEnabled: Bool`. Doc comment: set once the helper is first seen
`.enabled`; cleared by an explicit skip; gates the wake audit's "turned off in Login Items"
nag so a user who never approved (or skipped) is never nagged. Nothing else in this file.

**3. PTPHelperManaging goes Sendable (seam for step 4g).**
`PTPHelperService.swift:46`: `public protocol PTPHelperManaging: Sendable`. Mark
`SMAppServicePTPHelper` `@unchecked Sendable` with a one-line comment (immutable struct; SMAppService
status reads are thread-safe). Annotate every other conformer the compiler then flags with
`@unchecked Sendable` (known: `SimulatedPTPHelper` in PermissionMode.swift:201 — annotation
only, nothing else in that file; test fakes at OnboardingWindowLevelTests.swift:32,
OnboardingUITests.swift:204, PTPHelperReconcilerTests.swift:28). Two fakes already carry it.

**4. SetupModel.**
a. Add `private func setPTPHelperStatus(_ next: PTPHelperStatus)`: assigns `ptpHelperStatus`,
   and when `next == .enabled` sets `settings.speakerSyncWasEnabled = true` (the ratchet).
   Route all four assignment sites (852, 882, 897-899, ~1043-1046) through it.
b. `registerPTPHelper()` (875-884): add `public private(set) var ptpHelperRegistrationFailed = false`.
   In the `do` set it false; in the `catch`, set it true and add
   `Telemetry.log(.permission, "ptp_register_failed", ["error": String(describing: error)])`
   so the failure reaches `~/Library/Logs/Audiout/` (support-ticket reachable), keeping the
   existing stderr line.
c. Add `public func noteSpeakerSyncSkipped()` → `settings.speakerSyncWasEnabled = false`.
d. `unmetRequiredPermissions()` (947-949): the ptpHelper clause becomes — unmet only when
   `ptpHelperStatus == .requiresApproval && settings.speakerSyncWasEnabled`. Rewrite the doc
   bullet (934-938): the wake audit now fires only for a REGRESSION (was enabled, off now);
   never-approved, skipped, `.notFound` (packaging bug) and `.notRegistered` never nag.
e. `requiredPermissionsNotGranted()` (981-983): ptpHelper clause becomes — not-granted when
   `ptpHelperStatus != .enabled && ptpHelperStatus != .notFound && !ptpHelperRegistrationFailed`.
   (`.notFound`/failed registration must not hold the gate: the user cannot fix a packaging bug.)
f. `refreshPTPHelperStatus()` (896-901) becomes `async`: capture `let helper = ptpHelper`,
   read `await Task.detached { helper.status }.value`, then the existing
   guard-changed → assign (via 4a) → `onChange?()` on the main actor. Update its doc comment
   ("read off-main; launchd XPC must not ride the 1.5 s poll on the main thread" — perf P2-6).
g. `SystemSettingsPane` doc comment (113-121): replace the "falls back to privacyRoot if a
   specific pane URL won't open" promise with the truth: the anchors are best-effort;
   `NSWorkspace.open` returns true even when the anchor misroutes, so no code-level fallback
   exists — the ribbon's written path sentence is the recovery.

**5. SetupFlowModel — the P0-1 escape hatch (decision: SKIPPABLE, see Open decisions #1).**
a. `skippableSteps` (125) becomes `[.bluetooth, .remoteControl, .speakerSync]`; update its doc
   comment (three steps; Speaker Sync's PERMISSION is still audited when it was ever enabled —
   the skip filter below is what lets the gate open).
b. `isComplete(.speakerSync)` (163): true when `setup.ptpHelperStatus == .enabled`, OR
   `.notFound`, OR `setup.ptpHelperRegistrationFailed` (auto-pass posture, mirroring the
   `.unsupported` audio comment two lines up — say so in a comment).
c. Add `private func unmetRequiredSteps() -> [SetupStep]`: `setup.requiredPermissionsNotGranted()`
   mapped via `Self.step(for:)`, with `.speakerSync` filtered out when
   `skippedSteps.contains(.speakerSync)`. Use it in BOTH `isReadyForFinalCheck` (357-359 —
   `unmetRequiredSteps().isEmpty && activeStep == nil`) and `auditVerdict` (393 — first element
   replaces `Self.firstUnmetRequiredStep(in:)`). The static `firstUnmetRequiredIndex` used by
   `init` stays as-is (skippedSteps is always empty at init).
d. `skip(_:)` (317-320): after inserting into `skippedSteps`, if the step is `.speakerSync`
   call `setup.noteSpeakerSyncSkipped()`. `reopen(_:)` needs no model call (the flag re-ratchets
   only on a real `.enabled`).

**6. SystemSettingsOpener (P2-5).**
Body of `open` becomes a single `NSWorkspace.shared.open(pane.url)` (discard the result);
delete the fallback branch. Rewrite both doc comments to best-effort honesty (same wording
direction as step 4g); keep `SystemSettingsPane.privacyRoot` itself untouched (other call
sites and tests use it).

**7. OnboardingViewController + views.**
a. **P1-2 tone warning.** `content(for: .audio)` whyLine (535) becomes copy C1. Fit is safe:
   the why label allows 3 lines (`SetupHeroHeadView` `maximumNumberOfLines = 3`),
   C1 wraps to 2 at the hero's 418 pt, and the audio mock (269×240) still clears the frame —
   `everyMockFitsTheStage` pins it. Do not touch `detail`.
b. **P0-1 change 1 — the requiresApproval-after-trip state.** Add
   `private var didTripLoginItems = false`, set to true at both places that open Login Items
   for the flow: `openDestination`'s `.loginItems` arm (1581-1583) and `openSettings(for: .speakerSync)`
   (1491). In `activeRibbonContent`, after the `isPermissionLost` branch (1109) and before
   `isProvablyDenied`, insert:
   for `step == .speakerSync` with `didTripLoginItems && model.ptpHelperStatus == .requiresApproval`:
   status = (`Self.alertSymbol`, C2, `Tokens.Color.warningText`, false); body = `Self.ribbonBody(C3)`;
   primary = (C4, .prominent); showsSkip = true; return.
c. **P0-1 change 2 UI half.** `content(for: .speakerSync)` (599): `isSkippable: true` (first ask
   gains the standard "Skip for now"; the why line already names what a skip forfeits).
d. **P0-1 change 3 — auto-pass.** Add `static let speakerSyncAutoPassNote = C5`. In
   `state(for:)` (759-770), before the `.completed` return: if `step == .speakerSync` and
   (`model.ptpHelperStatus == .notFound || model.ptpHelperRegistrationFailed`), return
   `.autoPassed(note: Self.speakerSyncAutoPassNote)`. Extend the PTP poll's stop condition
   (501) to also invalidate on `.notFound` (it cannot self-heal). Note: `isComplete` (step 5b)
   is what routes these here — the row auto-passes, gate opens, note explains.
e. **P1-3 broken rows pressable.** `SetupCardView.isPressable` (554-560): return true when
   `isBroken`, before the state switch. In `rowPressed(_:)` (1431), after the
   `step == displayedActiveStep` early-return, insert: if `isBroken(step)` →
   `snapBackStep = step; browseStep = nil; refresh(animated: canAnimate); return`.
   (Pressing the loud row snaps the flow to it; the existing snap-back announcement at
   1293-1298 speaks the recovery status for free, and `applyAccessibility` flips the role to
   `.button` with the existing "Show" action because it derives from `isPressable` — the
   VoiceOver group-with-no-action fixes itself.)
f. **P1-4 spoken caption.** On `SetupPreviewFrameView`, add `var spokenCaption: String?`
   (didSet applies): when non-nil, `captionLabel.setAccessibilityLabel(spokenCaption)`;
   when nil, restore nil (visible text speaks). In `refreshHero`'s active branch (703-706),
   set `previewFrame.spokenCaption = (active == .remoteControl && demoMode(for: active) == .prompt) ? C9 : nil`;
   set nil in the other branches. Do NOT change the demo opt-out. (System Audio's instruction
   is covered by 7a — the why line is stock-control text the ribbon already exposes.)
g. **P2-2 focus after a wait.** In `refreshKeyboardFocus` (1306-1313): track a third anchor,
   `focusAnchorHadPrimary: Bool`; the guard also passes when the previous paint had no primary
   button and this one does (`ribbon.primaryButton != nil`) — the wait ending. Everything else
   unchanged.
h. **P2-3 announce the wait + the stuck hint.** In `syncPromptInFlight` (940-951), on the
   `inFlight == true` edge, `announce(Self.waitingStatus)`. In `markPromptStuck` (1012-1016),
   after setting `stuckPromptStep`, `announce(Self.stuckPromptHint)`.
i. **P2-4 refused ✕ says why.** Add to the VC: `private var closeRefusedDuringPrompt = false`,
   a constant `static let closeRefusedStatus = C6`, and
   `func noteCloseRefused()` — sets the flag, re-arms the stuck timer at a shortened
   `static let stuckPromptDelayAfterCloseAttempt: TimeInterval = 5` when not already stuck
   (same body as `startStuckPromptTimer` with the shorter interval; skip under
   `HeadlessRuntime` like the original), `announce(Self.closeRefusedStatus)`, and
   `refresh(animated: false)`. Clear the flag on the prompt-resolved edge in
   `syncPromptInFlight`. In `activeRibbonContent`'s prompting branch (1084-1096): when
   `closeRefusedDuringPrompt` and not stuck, the status line is
   (`nil`, `Self.closeRefusedStatus`, `Tokens.Color.warningText`, true) instead of
   `waitingStatus` (spinner kept — still waiting). In `OnboardingWindowController.windowShouldClose`
   (287-289): when refusing, call `contentVC.noteCloseRefused()` before returning false.
j. **P2-6 settings-trip ceiling (decision: timeout, see Open decisions #3).** Add
   `static let settingsTripCeiling: TimeInterval = 20` and a one-shot `settingsTripTimer`:
   armed whenever `settingsTripStep` is set (both arms of `applyAllowResult`, 1554-1571, and
   `settingsLinkTapped`, 1591-1595); cancelled in `appDidResignActive` (the trip genuinely
   departed — the resign→activate pair owns it from there), on step completion (660-663) and
   on the return-clear (466-473). On fire: clear `settingsTripStep`/`settingsTripDeparted`,
   `refresh(animated: false)`. Guard arming under `HeadlessRuntime` and add
   `public func test_fireSettingsTripTimer()` mirroring `test_fireStuckPromptTimer` (1619-1621).
k. **P3 batch.**
   - Escape → ✕: on the VC, `override func cancelOperation(_ sender: Any?)` →
     `view.window?.performClose(nil)` (routes through `windowShouldClose`, so 7i's feedback
     covers Escape too).
   - Polls pause/resume (perf P3-19): in `appDidResignActive` (457-459) invalidate and nil
     both poll timers; in `appDidBecomeActive` (466-477) restart both. Add early-outs inside
     the two start functions: `startRemoteControlPoll` returns if
     `model.remoteControlStatus == .granted`; `startPTPHelperPoll` returns if
     `model.ptpHelperStatus == .enabled || model.ptpHelperStatus == .notFound`.
     (Known trade, accepted by the order: a toggle flipped while another app is frontmost now
     lands on the return re-read (466-477) instead of live — the trip machinery already
     re-reads on every return.)
   - PTP poll off-main (perf P2-6): the poll body wraps the now-async model call —
     single-flight guard var, then a `Task { @MainActor in … }` that awaits
     `model.refreshPTPHelperStatus()` and clears the guard; exit conditions as today.
   - `permissionLostText(for:)` (1399-1413) rewritten per hardening 15: join names with
     `ListFormatter.localizedString(byJoining:)`; one FULL sentence per arity — copy C7
     (count == 1) and C8 (count > 1); no spliced pronoun, and "access" is gone (it was wrong
     for the Speaker Sync Login Item). Keep the count == 0 defensive arm.
   - Heading roles: on the VC's `titleLabel` (372) and `SetupHeroHeadView`'s headline label,
     `setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))` with a one-line
     comment (AppKit's `NSAccessibilityHeadingRole` constant is macOS 26+; the raw AX string
     is what VoiceOver's rotor reads and is fine on 14.2).
l. **P2-7 spoken auto-pass.** `SetupCardView.stateSuffix` (647-656): split the arm —
   `.completed` keeps ", allowed"; `.autoPassed(let note)` returns ", " + note with its first
   character lowercased (e.g. ", requires macOS 14.2 or later", ", couldn't be turned on").

**8. Docs land with code.** Update `AudioutOnboardingUI/AGENTS.md` minimally: skippable set is
three steps; the new Speaker Sync states (requiresApproval-after-trip recovery, `.notFound`/
failed-registration auto-pass, the skip's wake-audit memory); the System Audio why line now
carries the tone warning (amendment to the first-ask deletion rationale — the picture cannot
show a sound); the ✕ refusal now says why; Escape closes. Update the copy tables it reprints
(the System Audio why row). Keep each note to a line or two in the existing style; do not
restructure the file.

**9. Tests.** Update pins your changes break and add one test per new behavior, in the
existing suites (fakes for the helper/status already exist — OnboardingUITests.swift:204,
243). Must-cover list:
   - SetupFlowModelTests: speakerSync is skippable; skip → gate can open with helper
     unapproved; `.notFound`/registration-failed complete the step; verifyForDone does not
     snap back to a skipped speakerSync.
   - SetupModelTests: wake audit (`unmetRequiredPermissions`) nags only after
     `speakerSyncWasEnabled`; skip clears the flag; `.notFound` never gates
     `requiredPermissionsNotGranted`; registration throw sets the flag + logs
     `ptp_register_failed` (SetupTelemetryTests if that's where telemetry pins live).
   - OnboardingUITests: the requiresApproval-after-trip ribbon (status C2, primary C4,
     showsSkip); speakerSync auto-pass note C5; broken pending row is pressable and pressing
     it moves `test_activeStep`; row a11y role flips to button; `test_announcements` gains the
     wait edge, the stuck hint, and the close-refusal; the close-refused status line C6; the
     settings-trip ceiling clears the spinner (`test_fireSettingsTripTimer`); autoPassed
     spoken suffix carries the note; permission-lost text per-arity (C7/C8); Remote Control
     first-ask spoken caption C9; focus re-anchor after a wait if headless-assertable via
     `ribbon.primaryButton` — skip if it needs a real key window.
   - Existing pins expected to need updating: skippableSteps assertions, permission-lost
     banner text, `", allowed"` suffix assertions, any `refreshPTPHelperStatus()` sync calls
     (now `await`ed).

## Verification

Run in this order, from the worktree root; paste outputs.

1. `bash scripts/build.sh` → exit 0. (Baseline: build was green before this order.)
2. `bash scripts/run-tests.sh --filter 'OnboardingUITests|SetupFlowModelTests|SetupModelTests|OnboardingPermissionColorTests|OnboardingWindowLevelTests|SetupTelemetryTests'`
   → all pass, exit 0. Pre-change baseline observed this session: **259 tests in 7 suites, all
   passed** (the new count will be higher; zero failures is the bar).
3. The two boundary pins pass UNMODIFIED: `test_demoAccessibilityElements` still empty,
   `test_ribbonIsAccessible` still true (they run inside OnboardingUITests).
4. Commit triggers the repo guards (full suite + self-review); let them run — do not bypass,
   do not pipe through `tail`.

Done = commands 1-3 ran in your session and passed, with output pasted. Do not merge — push
to `origin/claude/fix-onboarding` and stop; merging needs Alec's explicit go-ahead.

## Acceptance checklist

- [ ] A user who declines the Login Items approval sees C2/C3, an "Open Login Items…" retry,
      and a working "Skip for now" — the gate can open; nothing renders the untouched first
      ask for that state any more.
- [ ] `.notFound` or a thrown `register()` auto-passes the row with note C5, opens the gate,
      logs `ptp_register_failed` to Telemetry, and never force-reopens the window on wake.
- [ ] A skipped Speaker Sync never wakes the nag audit; a once-enabled-then-revoked one still does.
- [ ] Package floor is 14.2; `.unsupported` machinery intact.
- [ ] System Audio first ask warns about the tone (C1) — visibly and to VoiceOver.
- [ ] Broken rows: pressable, `.button` role, press snaps the flow.
- [ ] Wait edge, stuck hint, and refused-✕ are announced; refused ✕ shows C6 and shortens the
      stuck hint to 5 s; Escape = ✕.
- [ ] Settings-trip spinner cannot latch past 20 s without a real departure.
- [ ] Polls pause on app resign, resume on activate; PTP status read is off-main.
- [ ] Permission-lost header: ListFormatter join, full sentence per arity, no "access", no
      spliced pronoun (C7/C8).
- [ ] `.autoPassed` speaks its note, not "allowed".
- [ ] Dead Settings-URL fallback gone; doc comments honest.
- [ ] AGENTS.md updated; no file outside the owned list (+2 scoped exceptions) touched.

## Open decisions (made here; Alec may veto)

1. **Escape hatch = make `.speakerSync` skippable** (NOT dropping `.ptpHelper` from
   `RequiredPermission`). Verified in code: dropping the case is strictly larger — with the
   step still un-skippable, an unapproved helper keeps the card active forever and the gate
   still never opens (SetupFlowModel:145-147, 357-359), it deletes the enum case across 5+
   files, and it kills the revocation re-entry whose recovery copy already exists (VC:1100-1108).
   Skippable needs only steps 5a-5d plus the wake-audit memory (2, 4a, 4c, 4d).
2. **Skip persistence = `speakerSyncWasEnabled` ratchet in AppSettings.** Unregister-on-skip
   was rejected: AppDelegate re-registers at every launch on `.notRegistered`
   (AppDelegate.swift:919-929) and that file is off-limits, so the skip would be undone.
3. **P2-6 latch fix = 20 s timeout ceiling**, not clear-on-repaint: the poll only repaints on
   a status TRANSITION, so in the deny-without-resign case no repaint ever comes — the
   repaint variant cannot fire.
4. **P1-2 placement = appended to the audio why line** (C1), not a resurrected first-ask body:
   smallest diff, VoiceOver-visible, and the fit math holds (3-line max, mock clears the frame).
5. **New copy (C1-C9) and the owner-verbatim table edits are flagged OWNER-PENDING** in
   AGENTS.md per that file's convention — Alec signs off at review, as with the spine titles.
6. **P3-19 trade accepted:** pausing polls on resign means a grant made while Settings is
   frontmost lands on return, not live. The return re-read already covers correctness.

## Execution plan

One track, SERIAL (every finding routes through `OnboardingViewController.swift` and the
`SetupModel`/`SetupFlowModel` pair — no disjoint file split exists). Model: **opus**,
effort **high** (the P0-1 state machine spans three files and the gate contract). Worktree
from current HEAD (`7886f98d`); tree is clean.

## Executor rules (verbatim)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
