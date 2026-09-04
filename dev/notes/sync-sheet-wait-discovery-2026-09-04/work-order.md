# Work order: the sync sheet's wait becomes real acts (2026-09-04)

Two tracks, executed in parallel by two agents. The shared wire change is already done. Read `synthesis.md` beside this file first (sections 1 and 3), then your track. Every line number below was read on the exact base commit named for your track; verify each anchor with a grep before editing, because the file may have shifted by a few lines.

Rulings from Alec (2026-09-04), binding for both tracks:
1. A wrong stored number is worse than a wait. Measure-early is an escape that appears only once the Mac has seen the clock jump, never on the clean path.
2. The sheet may start the metronome clicks once the user taps "I'm there". That tap is the consent.
3. A first pairing and any speaker already connected when the Mac app launches get a settle window too.
4. The multi-speaker list is out of scope. Nothing in this order builds it.

One change from the published write-up: the phone shows **no number** while a speaker settles. The detector's own count resets on every jump, so any number would jitter 10, 9, 10, 8 on a Sonos mid-settle; a countdown from the fixed 60 s floor was the lie we are removing. The phone shows a phrase per state instead.

## The wire (done)

`audiout-shared` branch `claude/alignment-clock-state`, commit `0377c3e8be42b205a2c92ed32ab41de9205a6b39`, pushed to origin. `DeviceState.AlignmentState.clockState: String?` with values `"unknown"`, `"settling"`, `"steady"`, nil = older Mac (treat as steady). `settleRemainingSeconds` stays in the struct; a Mac that publishes `clockState` publishes nil there. Both consumers pin to that revision (not a tag) in this order; the tag `0.7.0` and the re-pin to it happen at merge, by Alec.

---

## Track M: Mac (agent 1)

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/settle-clock-state`, branch `claude/settle-clock-state` (= `claude/settle-window-adaptive` merged with `main`, head `6125143a`, pushed to origin). Run every command from that directory. Never `cd` into the main checkout. Never build the `.dev` bundle id; no live-test slot is needed.

Files: `AudioutCore/Sources/AudioutCore/BTAlignmentFreshness.swift` (F), `AudioutCore/Sources/AudioutCore/NativeBackend.swift` (N), `AudioutCore/Sources/AudioutCore/CompanionSnapshotBuilder.swift` (B), `AudioutCore/Sources/AudioutApp/AppDelegate.swift` (A), `AudioutCore/Package.swift` + `Package.resolved`, tests under `AudioutCore/Tests/AudioutCoreTests/`.

### M1. Pin the shared package to the branch revision

`AudioutCore/Package.swift:163` reads `.package(url: "https://github.com/aa-hh/audiout-shared.git", from: "0.6.0")`. Change to `.package(url: "https://github.com/aa-hh/audiout-shared.git", revision: "0377c3e8be42b205a2c92ed32ab41de9205a6b39")`. Add a one-line comment above it: `// Pinned to a revision until 0.7.0 is tagged at merge (clockState).` Run `bash scripts/build.sh` once so `Package.resolved` updates; commit the resolved file with the change.

### M2. The clock verdict as a tri-state (F)

On the base commit F has: `noteConnected` :102-116, `noteAligned` :139-155, `noteClockOutcome` :182-220, `isStableLocked` :237-239, `report` :252-282, `settleRemainingSeconds` :300-305, `BTAlignmentReport` :365-378.

1. Add `public enum ClockState: String, Sendable { case unknown, settling, steady }` inside `BTAlignmentFreshness`, doc comment copied from the wire struct's `clockState` doc (in `audiout-shared` at `Sources/AudioutProtocol/CompanionSnapshot.swift` on the pinned revision).
2. Add `private var seenJumpSinceLinkUIDs: Set<String> = []`. Insert on `.jumped` in `noteClockOutcome`. Remove in `noteConnected` (a new link is a new clock). Do NOT clear it on `.rebaselined` or `.ignored`: a sink rebuild loses the baseline, not the fact that this link's clock jumps.
3. Add the pure rule, static, assertable without a clock:
   ```swift
   static func clockState(stableForSeconds: Double, seenJump: Bool,
                          lastConnectedAt: Date?, now: Date) -> ClockState {
       if stableForSeconds >= BTClockStability.stableAfterSeconds { return .steady }
       if seenJump { return .settling }
       return settleRemainingSeconds(lastConnectedAt: lastConnectedAt, now: now) != nil ? .unknown : .steady
   }
   ```
   and a private `clockStateLocked(_ uid: String, now: Date) -> ClockState` that reads the three dictionaries under the lock. The last line is the floor's only remaining job: no evidence for a whole minute means the Mac has nothing to add and the button goes live, which is what an older Mac did.
4. `report(...)`: replace the `settleRemaining` if-chain (:268-279) with `clockState: clockStateLocked(uid, now: now)` and `settleRemainingSeconds: nil`. Update the doc comment (:245-251) to say the number is no longer published and why (see the top of this order). `BTAlignmentReport` gains `public let clockState: ClockState` (init param, default `.steady` so existing test call sites still compile). Delete `advancingSampleMaxAgeSeconds` (:63) if nothing else reads it after this change; grep first.
5. `noteAligned`: replace the `settling` expression (:144-146) with `clockStateLocked(uid, now: date) != .steady`. Same outcome as today inside the floor; past the floor it now also marks an alignment made while the detector says settling. Keep the doc comment's reasoning, trimmed to match.
6. `noteClockOutcome`: compute `let before = clockStateLocked(uid, now: date)` at the top of the locked block and `let after = clockStateLocked(uid, now: date)` at the bottom; `publish = before != after || movedInserted` where `movedInserted` is the existing "moved" line insert (:210-214). Remove the two hand-written publish conditions at :200 and :204-205; the before/after comparison covers both (arrival at steady; a jump while steady or while unknown). Keep the `.frozen` early return.
7. Floor expiry with no evidence needs a rebroadcast, because nothing else fires at that instant. Add `private let floorRebroadcastDelay: TimeInterval` set from a new `init(floorRebroadcastDelay: TimeInterval = BTAlignmentFreshness.settleSeconds)`. In `noteConnected`, after recording, schedule on `DispatchQueue.global(qos: .utility)` at `.now() + floorRebroadcastDelay + 0.1`: take the lock, and if `lastConnectedAtByUID[uid] == date` (same link-up, not superseded) and `clockStateLocked(uid, now: Date()) == .steady` and `stableForSecondsByUID[uid, default: 0] < stableAfterSeconds` (steady by expiry, not by evidence), fire `_onChange`. One line of doc: "the state flipped on a clock, so the phone has to be told".
8. Update the doc comments on `settleSeconds` (:49-56) and the type header so they describe the tri-state, not a countdown.

### M3. First pairing and launch get a window (N)

In `applyBTSnapshots`, the new-device branch builds `Device(id: id, name: snapshot.name, kind: .bluetooth, isAvailable: snapshot.isConnected, ...)` then `known[id] = device; order.append(id); emit(.deviceAdded(device))` (on `main` that is `NativeBackend.swift:8434-8449`; on your branch about 20 lines later; find it by the comment `Same as the AirPlay row (\`mapDiscovered\`)`). Before `known[id] = device` add:
```swift
// The first time this process lists a connected Bluetooth device is the
// only link-up it will ever see for it: a first pairing, or a speaker
// already up when the app launched. Both start a settle window (Alec,
// 2026-09-04); neither stales a stored tuning, because the store has no
// alignment instant to be earlier than (`BTAlignmentFreshness.status`).
if snapshot.isConnected { btAlignmentFreshness.noteConnected(uid: id) }
```
Confirm with a test where possible (see M6); if no existing harness feeds `applyBTSnapshots` from a test, say so in your report rather than building one.

### M4. Map it onto the wire (B)

`CompanionSnapshotBuilder.alignmentState(for:...)` (:236-250 on main, same on your branch): add `clockState: report.clockState.rawValue` to the `DeviceState.AlignmentState(...)` call; `settleRemainingSeconds: report.settleRemainingSeconds` stays (it is nil now).

### M5. Rebroadcast wiring (A)

Confirm `btAlignmentFreshness.onChange` reaches `scheduleCompanionBroadcast()` (on main: `NativeBackend.swift:10696-10697` exposes it as `onBTAlignmentChanged`; grep `onBTAlignmentChanged` in `AppDelegate.swift`). No change expected; if the hook is missing on your branch, wire it and say so.

### M6. Tests

- `BTAlignmentFreshnessTests.swift` (the branch added ~210 lines; extend, don't rewrite): (a) the pure rule: steady at 10 s; settling when a jump was seen regardless of the floor; unknown inside the floor with no evidence; steady past the floor with no evidence. (b) Sony-class sequence: connect, one `.ignored`, ten `.advanced` one second apart → `report` says `.steady` and `onChange` fired exactly once at the flip. (c) Sonos-class: connect, jumps for 40 s → `.settling` from the first jump (one `onChange` at unknown→settling, none per further jump), then ten clean seconds → `.steady`, one `onChange`. (d) a jump while steady → `.settling` and one `onChange`. (e) reconnect → `.unknown`, jump memory cleared. (f) floor expiry rebroadcast: `init(floorRebroadcastDelay: 0.05)`, connect, no samples, expect `onChange` within 1 s and `report` `.steady`. (g) `noteAligned` marks `measuredWhileSettling` when settling and past the floor.
- Update every existing assertion on `settleRemainingSeconds` to the new nil-plus-state shape.
- `CompanionSnapshotBuilder` tests if a suite exists (grep `alignmentState` under Tests): the wire field carries the raw value.
- Run: `bash scripts/run-tests.sh --filter BTAlignmentFreshnessTests`, `--filter BTClockStabilityTests`, `--filter NativeBackendBTAlignmentInterceptTests`, and whatever suite covers `CompanionSnapshotBuilder`. Then `bash scripts/build.sh`. Paste the last lines of each real run in your report.

### M7. Commit and push

Stage, run `scripts/self-review.sh` and read the diff (Guard 7; do not talk about it in the report beyond "self-review run"), commit with a message in the repo's voice, push to `origin claude/settle-clock-state`. Guard 4 runs the full suite on commit; if it fails on a test your diff does not touch, stop, paste the failing test name and output, do not bypass the guard. Do not merge anything.

### M8. Out of scope

The Mac's own alignment wizard; the pacing/drift path in `BTSyncedSink`/`SyncCore`; the `AUDIOUT_BT_CLOCK_WATCH` switch (leave it); analytics (no new Mac-side user action); docs beyond doc comments.

---

## Track P: phone (agent 2)

Worktree: `/Users/alechenderson/Projects/audiout-remote/.claude/worktrees/sync-sheet-acts`, branch `claude/sync-sheet-acts` (= `claude/settle-window-phone`, head `65a1dbc`, pushed to origin; hooks path already set). Run every command from that directory. This app is proprietary: never paste code from the Mac repo.

Design authority: `DESIGN.md` in that worktree ("The sync surfaces" ~:1095-1141, "Do's and Don'ts" ~:1141-1204, Overview :120-175). The design skill is mandatory here (Alec, 2026-09-04): "ensure that the UI agents use /impeccable skill to help them shape and distill the point they are trying to get across." Concretely: before editing any view, invoke the Skill tool with `impeccable` and args `distill AudioutRemote/UI/Sync/SyncSheet.swift`; follow its setup (its context script, run once, with that target) and load its craft-floor reference before the first UI edit; when the screens are written, invoke it again with args `clarify AudioutRemote/UI/Sync/SyncSheet.swift` for the copy pass. The screens and copy below are the brief the skill works within; it may tighten wording and layout, it may not add screens, states, colours or a second gold pill.

Base file: `AudioutRemote/UI/Sync/SyncSheet.swift` on `65a1dbc`. Anchors on that commit: `Page` enum :92-94, init seeding :82-90, body modifiers :128-186, `content` :202-220, `placementPage` :230-277, `footnote` :283-294, `macBlocker` :299-304, `waitingToSettle`/`ctaReady` :308-311, `recheckDue` :346-348, `keepAwake` :352-354, `reseedSettle`/`tickSettle` :356-370, `startRun` :384-394, `runDidFinish` :401-424, `measuredPage` :504-572, `followUpLine` :578-607, `verdictLine` :629-634, copy statics :662-724, `FineTunePage` :804-940, `GoldCTA` :947-978. Other files: `AudioutRemote/Model/DemoMacSession.swift` (settle :73-77, :134-139, :395-397, :441), `AudioutRemote/Model/ProbeCaptureSession.swift` (:77-97 permission API), `AudioutRemote/Model/MacSessionProtocol.swift` (:54 `setDeviceSelected`, :56 `setMainOut`, :86-93 alignment commands), `AudioutRemote/UI/Speakers/DeviceRowView.swift` (:768-776 `alignmentWord`), `AudioutRemoteTests/DemoMacSessionTests.swift` (settle tests ~:374-452), `AudioutRemote.xcodeproj/project.pbxproj` (~:605-612, the `audiout-shared` package reference).

### P1. Pin the shared package to the branch revision

In `project.pbxproj`, the `XCRemoteSwiftPackageReference "audiout-shared"` has `requirement = { kind = upToNextMajorVersion; minimumVersion = 0.6.0; }`. Change it to `requirement = { kind = revision; revision = 0377c3e8be42b205a2c92ed32ab41de9205a6b39; };`. Update `Package.resolved` under the project if one is checked in (grep for `audiout-shared`). This is the one pbxproj edit the repo's rules expect for a pin bump.

### P2. The clock state replaces the countdown

- Add `private var clockState: String? { alignment?.clockState }` and `private var clockReady: Bool { clockState == nil || clockState == "steady" }`.
- `waitingToSettle` becomes `!clockReady`. `ctaReady` stays `macBlocker == nil && !waitingToSettle`. `recheckDue` and `keepAwake` keep reading `waitingToSettle`; they now follow the Mac's word and no local count.
- Delete `settleRemaining`, `settleSeed`, the init seeding (:85-89), `.task(id: settleSeed)`, `.onChange(of: session.snapshotGeneration) { reseedSettle() }` (keep the `targetID` onChange minus the reseed), `reseedSettle()`, `tickSettle()`, `roundedUp`, and every copy function that took `remaining:`. Replace: `forwardLine(target:)` → "The {target} is still settling, so this could move. This iPhone will check again once it's steady. Keep it where it is."; `offerWaitingLine` → "Check again once it's steady."; `readyValue` (the button's VoiceOver value while not live) → "Not yet. The {target} is still settling." when settling, "Getting the {target} ready." when unknown; `settlingLine` is deleted (E's footnote below replaces it). Keep `readyAnnouncement`, `recheckAnnouncement`, `recheckVerdictLine`, `offerLine`, `offerHint`, `offerReadyAnnouncement`, `movedOfferLine`, `chainLine`, `reopenAfterEarlyLine`, `movedPlacementLine`.
- `DemoMacSession`: publish `clockState` instead of a countdown: `"unknown"` for the first 3 s after the demo target is picked, `"settling"` from 3 s to `demoSettleSeconds` (15), `"steady"` after; `endSettleWindow()` sets steady; `settleRemainingSeconds` nil throughout. Keep the "moved" mark logic. Update `DemoMacSessionTests` accordingly (the tests at ~:374-452 assert the old number).

### P3. The pre-run screens

Extend `Page` with `.playing`, `.microphone`, `.walk`, `.listen`; keep `.placement` as the last pre-run screen (E) to keep the diff small. Add `@State private var walkedThisSheet = false` and `@State private var heardOnlyOne = false` and `@State private var runIsEarly = false`.

Pure, testable page choice: `static func firstPreRunPage(blocked: Bool, micUndetermined: Bool, walked: Bool) -> Page` → `blocked ? .playing : (!walked && micUndetermined) ? .microphone : walked ? .placement : .walk`. Call it in `init` (the snapshot is available there, as the existing seeding shows) and on the chain button (`targetID` change) with `walked: walkedThisSheet`. Add `static var permissionUndetermined: Bool { AVAudioApplication.shared.recordPermission == .undetermined }` to `ProbeCaptureSession` beside `permissionDenied`.

`content`: the `micDenied` refusal page shows for any pre-run page, not only `.placement`.

Every pre-run page: one title in `.title2.weight(.semibold)` `WarmSignal.label` (as today's placement title), one body in `.subheadline` `WarmSignal.label2`, `Spacer`, then the actions row; padding 20; exactly one `GoldCTA` per page or none; page changes animate with `.spring(duration: 0.25)` and no travel under Reduce Motion. Names come from `targetName` / `referenceName`.

**A `.playing`** — shown while `macBlocker != nil` at entry.
- Title: "Both speakers need to be playing."
- Body when `alignment?.referenceID == nil`: "Nothing else is playing to compare the {target} against. Play something on another speaker, or on your Mac." No button.
- Body when the target is not sounding and `session.snapshot?.mainOut.kind == "selected"`: "The {target} isn't playing yet. The room has to hear it and the {reference} together." Gold button "Play the {target}" → `session.setDeviceSelected(id: targetID, selected: true)`.
- Body when the target is not sounding and `mainOut.kind == "group"`: "Main Out is playing to a group the {target} isn't in." No button.
- When `macBlocker` becomes nil while on this page: body "Both are playing." and gold button "Continue" → next page per `firstPreRunPage` with `blocked: false`. The page never advances on its own.

**B `.microphone`** — shown only when `permissionUndetermined`.
- Title: "Audiout needs to hear the room."
- Body: "It listens for two quick sweeps from your speakers, from wherever this iPhone is standing."
- Gold button "Allow the microphone" → `Task { let ok = await ProbeCaptureSession.requestPermission(); page = ok ? .walk : page }` (a denial makes `micDenied` true and `content` shows the refusal page).
- Remove nothing from `AlignmentRunController.start()`: its own `requestPermission()` call (`AlignmentRunController.swift:171`) is now a no-op for a granted phone and still protects the demo/other paths.

**C `.walk`**
- Title: "Take the phone to where you listen."
- Body: "Not next to a speaker. Where you actually sit."
- Gold "I'm there" → `.listen`. Plain gold-text "Adjust by ear" (existing style) → `.fineTune`.

**D `.listen`** — `onAppear`: `ticksOn = true; session.setAlignmentTick(targetID: targetID, active: true)` (the same call `FineTunePage` makes on appear). A refused tick arrives as `commandRefused` and the existing handler sets `ticksOn = false`; the copy must then not claim clicking.
- Title: "Can you hear both from here?"
- Body (`ticksOn`): "The {target} and the {reference} are each clicking. If the clicks land apart, that's what's about to be fixed."
- Body (`!ticksOn`): "The {target} and the {reference} should both be playing music from here."
- Body (`heardOnlyOne`): "Move somewhere both reach you, or turn the quiet one up. The clicks keep going." (or "...Then answer again." when `!ticksOn`).
- Two neutral chips, not gold: "Both" → `.placement`; "Only one" → `heardOnlyOne = true`. Chip style: `WarmSignal.well` fill, `WarmSignal.rim` 0.5 pt stroke, `WarmSignal.Radius.control`, label ink, `.microLabel(13)`, `hittable(drawn:)` to the 44 pt floor. No timer, no auto-advance. Ticks keep running into E. Set `walkedThisSheet = true` when leaving D.

**E `.placement`** — the existing page, retitled.
- Title: "Hold still."
- Body: "You'll hear two quick sweeps over the music. Stay quiet while they play."
- Footnote precedence (replaces `footnote`): `macBlocker` line; else `clockState == "unknown"` → "Getting the {target} ready."; else `"settling"` → "The {target} is still settling after connecting. Hold on."; else `markReason == "measuredWhileSettling"` → `reopenAfterEarlyLine`; `"moved"` → `movedPlacementLine`; else `alignment?.staleReason == "reconnected"` → "The {target} picks a fresh delay every time it reconnects, so the old number no longer fits."; else nil.
- "Measure it now" (existing gold text, :254-260) shows only when `macBlocker == nil && clockState == "settling"`. Its accessibility hint stays.
- `GoldCTA("Measure", enabled: ctaReady)`. Tapping Measure or Measure it now: if `ticksOn` → `session.setAlignmentTick(targetID: targetID, active: false); ticksOn = false`; then `runIsEarly = !clockReady`; then `startRun()`.
- When `ctaReady` flips to true while on E and `ticksOn`: stop the ticks the same way. The existing `sensoryFeedback(trigger: ctaReady)` and the VoiceOver line already fire; the fill change in `GoldCTA` already animates. Nothing else moves.
- "Adjust by ear" stays beside the button.

Chain button on the verdict (:554-559): also set `run = nil; verdict = nil; runIsEarly = false; heardOnlyOne = false`, then `page = Self.firstPreRunPage(blocked: <macBlocker for the new target>, micUndetermined: ProbeCaptureSession.permissionUndetermined, walked: walkedThisSheet)`. Compute the new target's blocker from the snapshot before switching `targetID`, or switch first and read the computed property.

`onDisappear` already stops ticks and cancels the run; keep it.

### P4. The verdict for an early reading

When `runIsEarly` and the run produced a number, the headline uses a new `static func earlyVerdictLine(target:measuredMs:correctedMs:) -> String`: in the ±4 ms band → "First reading: the {target} is in step."; otherwise "First reading: the {target} was trailing." / "...was ahead." followed by " Your Mac moved it; this iPhone will check again once it's steady." when `correctedMs != 0`, or " Your Mac couldn't change it." otherwise. Never the word "Fixed." on an early reading. `verdictLine` (:629-634) is unchanged for ordinary runs; `recheckVerdictLine` unchanged for the re-check. Store `wasEarly` on `Verdict` beside `wasRecheck`.

### P5. The by-ear page while settling

`FineTunePage` gains `let clockReady: Bool` and `let targetIsSettling: String?` (nil, or the footnote to show). While `!clockReady`: the slider is drawn but inert (`allowsHitTesting(false)`, chevrons at 0.5 opacity, `accessibilityValue("Unavailable while the speaker settles")`, adjustable action ignored), and one footnote above it in `WarmSignal.labelCool2`: "The {target} is still settling after connecting. The slider unlocks when it's steady." Revert, Clear and Start/Stop the ticks stay live. When `clockReady` flips, the slider simply unlocks. Body copy (:829) becomes: "Slide well over one way, then the other, and keep the side where the two clicks got closer. Then work in small moves. Keep the music playing — the ticks ride on top of it."

### P6. DESIGN.md

In "The sync surfaces", replace the sheet's state list to describe the five pre-run screens (A only when a speaker is silent, B only when the microphone is undecided, C and D once per sheet, E always), the clock state phrases, the lockout, the early-reading verdict, and that no number is shown while settling and why. In the Decision Record add: "**Alec, 2026-09-04 — the wait is spent on real acts.** Four rulings: a wrong stored number is worse than a wait, so measuring early is an escape shown only once the Mac has seen the clock jump; the clicks may start on the user's own 'I'm there' tap; a first pairing and a launch-time connection get a settle window; the multi-speaker list waits for evidence." Keep both under 25 lines total. Fix the "Haptics" entry if its wording no longer matches.

### P7. Tests and verification

- `AudioutRemoteTests`: add tests for `firstPreRunPage`, the E footnote precedence (make it a static pure function taking the inputs), `earlyVerdictLine`, and `clockReady` for nil/"steady"/"unknown"/"settling". Update `DemoMacSessionTests` for `clockState`.
- Compile: from the Mac worktree named at the top of Track M, `bash scripts/ios.sh build --root /Users/alechenderson/Projects/audiout-remote/.claude/worktrees/sync-sheet-acts`. Must succeed; the pin pulls the pushed branch.
- Tests: `bash scripts/ios.sh test --root <same>`. If it reports no iOS Simulator runtime, report "compile-verified" and do NOT download a runtime (7.5 GB, deleted on purpose).
- Device verification on Alec's iPhone is his, not yours; say it is owed.

### P8. Commit and push

Commit on `claude/sync-sheet-acts` in the repo's voice; the pre-commit guard checks for copied shared code. Push to `origin claude/sync-sheet-acts`. Do not merge. Report: files changed, each command with the tail of its real output, what is owed.

### P9. Out of scope

Speakers rows, invite card, groups; any notification, background mode or idle-timer change beyond what the branch already does; the multi-speaker list; a second filled gold button on any screen; green anywhere new; any number on screen while settling; analytics (the phone has no sink).
