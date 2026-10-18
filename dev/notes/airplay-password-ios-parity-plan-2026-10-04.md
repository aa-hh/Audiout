# Password entry on the phone: parity with the Mac (plan, 2026-10-04)

Follows PR aa-hh/Audiout#273 (Mac) and aa-hh/audiout-remote#40 (phone). Goal: the phone's password feature reads as the same product as the Mac's, drawn in the phone's own tokens and iOS controls. Impeccable playbooks applied: `adapt.native.md` (iOS conventions) and `extract.md` (nothing earns a new shared component; the extraction is DESIGN.md catching up).

## Owner rulings (2026-10-04)

- Lock beside a protected speaker: exact parity with the Mac, so the speaker's access kind goes on the wire first (shared 0.19.0).
- Forget a saved password from the phone: later, as its own change. Not in this plan.
- Sheet heading: mirror the Mac's single line, `Enter the password for “<name>”`.
- Sheet chrome: keep the hand-drawn card (Cancel + gold Connect side by side).
- Availability: a protected speaker stays under Ready until a password or code was supplied and refused, then moves to Unavailable. This is a Mac-side rule (the Mac publishes the flag) and is landing in PR 273's review-fix commit. No phone sorting change.
- The two un-retryable failures (Apple TV code, home members only): show the Mac's instruction sentence on the row without a Diagnose tap.
- Analytics names stay as documented (Mac `airplay:code_prompt_shown`, phone `speaker:password_prompt_shown`).

Already at parity, no task: result strings, result line hidden until the first submit, close-on-connected, failure headline and suggestion arriving verbatim from the Mac, sheet mounted on the Speakers screen rather than the row.

## Tasks

Phone worktree: `/Users/alechenderson/Projects/audiout-remote/.worktrees/airplay-password` (branch `claude/airplay-password`). Mac worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/pr-250-247-issue-228-793432`. Shared worktree: `/Users/alechenderson/Projects/audiout-shared/worktrees/airplay-password`.

### S1. Access kind on the wire (shared 0.19.0, both pins) — opus, high
- Shared: `Sources/AudioutProtocol/CompanionSnapshot.swift` `ConnectionInfo` gains `access: String?` (`open`, `password`, `onScreenCode`, `homeMembersOnly`), trailing defaulted; round-trip in `CompanionMessageTests.swift`. Additive, no `CompanionProto.version` bump. Land by PR as 0.18.0 did (aa-hh/audiout-shared#24), tag `0.19.0`.
- Mac: `CompanionSnapshotBuilder.swift` fills `access` from `device.airPlayAccess.rawValue` in every state; extend `CompanionSnapshotBuilderTests`. Pin `AudioutCore/Package.swift` to `from: "0.19.0"` plus `Package.resolved`. One commit on the PR 273 branch (consumes a review round, so land together with any other Mac change from this plan).
- Phone: pin `project.pbxproj` `minimumVersion` to `0.19.0` plus `Package.resolved`.
- Verify: shared `swift test`; Mac `bash scripts/build.sh` + `bash scripts/run-tests.sh --filter CompanionSnapshotBuilderTests`; phone `bash scripts/ios.sh build --root <phone worktree>` from the Mac repo.

### P1. Lock beside the name on the phone row — sonnet, medium (after S1)
- `AudioutRemote/UI/Speakers/DeviceRowView.swift`: on the name line, `Image(systemName: "lock.fill")` after the name, 4 pt spacing, `.system(size: 11, weight: .semibold)`, tinted the name's ink (never gold), name keeps `lineLimit(1)` and truncates first. Static rule `showsLockGlyph(_:)` beside `offersPasswordEntry`, reading `connection.access != "open"`. Spoken labels verbatim from the Mac: `Password protected`, `Code required`, `Home members only`; appended to `spokenValue` on the combined row, and as the glyph's own `.accessibilityLabel` on the failed row (which is not a combined element).
- Test in `AudioutRemoteTests/SpeakerRowRulesTests.swift`.

### P3. Instruction shown outright for the two un-retryable failures — sonnet, low (after P1, same file)
- `DeviceRowView.swift` `trailingSlot` / `failureControls`: when `connection.failureCause` is `codeRequired` or `homeMembersOnly`, show `failureSuggestion` without a tap and draw no Diagnose; one static rule read by both so they cannot disagree. Test in `SpeakerRowRulesTests`.

### P4. The sheet: Mac heading, iOS conventions, copy pinned — sonnet, medium (independent)
- `AudioutRemote/UI/Speakers/SpeakerPasswordSheet.swift`: single heading line `Enter the password for “<name>”` at `.title3.weight(.semibold)`, second line dropped; field focused on appear (`@FocusState`); field's padded background `minHeight: WarmSignal.hitTarget`; body in a `ScrollView` with `.presentationDetents([.medium, .large])` (the set `AddAppSheet` uses), keep `.presentationBackground(WarmSignal.canvas)`; `.accessibilityLabel("AirPlay password")` on the field; `AccessibilityNotification.Announcement` when the result line changes (the `ToastBanner` pattern); the three Mac-owned strings lifted to `static let`s.
- `AudioutRemoteTests/MacCopyTripwireTests.swift`: add the three strings to `asTheMacSaysThem`. New `AudioutRemoteTests/SpeakerPasswordSheetRulesTests.swift`: empty submit → first string and nothing sent; `failed` + `authRequired` → the rejection string; other `failed` → the Mac's headline.

### M1. Mac half of the copy tripwire — haiku, low (independent; land in the same Mac commit as S1's Mac half)
- `AudioutPopoverUI/PopoverController.swift`: lift `"That password didn't work. Check it and try again."` to a static; `SpeakerPasswordSheetViewController.swift`: same for `"Enter the speaker's password."`; and the Mac's heading format string. `CompanionCopyTripwireTests.swift`: rows in `mirroredOnThePhone`.

### D1. DESIGN.md (phone) — sonnet, low (after P1, P3, P4)
- Device row failed state: the lock and its meaning, the sheet as shipped. Component catalog: a `field-secure` entry (well fill, control radius, 12 pt padding, 44 pt minimum height). No shared sheet wrapper, no shared lock view (one site each).

### V1. Build, whole phone target, handover — sonnet, low (last)
- `bash scripts/ios.sh build --root …`; `bash scripts/mule-test.sh` (whole target). Report "compile-verified / headless-passing"; the iPhone run is the owner's: lock on a protected row, sheet with VoiceOver, sheet at the largest text size with the keyboard up, wrong password then right one.

## Waves

- Wave 0: S1 (shared PR + tag, then both pins). Nothing else starts until the tag exists.
- Wave 1, three lanes: P1 → P3 (same file, serial) · P4 · M1 (Mac repo).
- Wave 2: D1. Wave 3: V1.
- Critical path: S1 → P1 → P3 → D1 → V1.

## Risks

- S1 is a three-repo commitment: both pins move in one sitting or both apps break.
- The Mac commit (S1 Mac half + M1) lands on PR 273 after the review-fix commit, and costs a review round; it must be one commit.
- Keyboard against a half-height sheet is only settled on the physical phone; P4's detents and scroll are the hedge.
- Never move the sheet onto the row (a row that changes section takes its sheet down with it).
