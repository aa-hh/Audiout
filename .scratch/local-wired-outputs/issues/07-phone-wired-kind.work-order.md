# Work order — Phone: classify and draw a `"wired"` speaker row

## Goal

The Mac is about to send wired Core Audio outputs (headphone jack, USB, HDMI, non-default built-in speakers) in the companion snapshot as `kind: "wired"`. Today the phone folds every unknown kind into the AirPlay filter chip, so those rows would show under "AirPlay". Make the phone treat a wired row the way it already treats the local Mac: a real speaker row with the Mac-chosen glyph, under All and Favourites, under no transport chip. Two files change, one test lands.

## Verified facts

- The phone's only kind fold is `SpeakerTransport.of(_:)` at `/Users/alechenderson/Projects/audiout-remote/AudioutRemote/UI/Speakers/SpeakersView.swift:118-125`: `guard !device.isLocalDevice else { return nil }`, then `"bluetooth"` → `.bluetooth`, `"cast"` → `.cast`, `default` → `.airplay`. Doc comment `:94-101` says it is "the only place in the app that knows which wire kinds are AirPlay". `enum SpeakerTransport` is internal (`:102`), so `@testable import` reaches it.
- Its readers: `presentTransports` (`SpeakersView.swift:237-239`) and `filtered(_:)` (`:270-276`) for the chips; `SyncSheetModel.speakerKind` (`/Users/alechenderson/Projects/audiout-remote/AudioutRemote/UI/Sync/SyncSheetModel.swift:651-659`) for analytics, where `nil` already maps to `.airplay` with a comment saying nil is the local Mac (`:655-656`).
- The sync sheet is reachable only when `device.alignment != nil` (`/Users/alechenderson/Projects/audiout-remote/AudioutRemote/UI/Speakers/DeviceRowView.swift:469`, `:846`). The Mac sends `alignment` only for `kind == .bluetooth` (`/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cpi-consumption-analysis-2e6406/AudioutCore/Sources/AudioutCore/CompanionSnapshotBuilder.swift:242`). So a wired row never opens the sync sheet and `speaker_kind` never sees one; the `Analytics.SpeakerKind` enum (`/Users/alechenderson/Projects/audiout-remote/AudioutRemote/Model/Analytics.swift:103-105`) needs no new value.
- Glyph: the phone draws `device.iconSymbolName` straight off the wire (`DeviceRowView.swift:661`). The Mac fills that field from `host.symbolName(for:)` (`CompanionCoordinator.swift:524`) → `DeviceIcon.symbolName(for:)` → `device.symbolName` (`AudioutCore/Sources/AudioutSharedUI/DeviceIcon.swift:164-165`), and the uncommitted `Device.swift` diff in the Mac worktree gives `.wired` per-transport glyphs there (`laptopcomputer`, `headphones`, `cable.connector`, `display`, fallback `hifispeaker`). The transport does not need to be on the wire; the glyph already is. Putting it on the wire would cost a new optional field in `audiout-shared`, a tag, and a pin bump in both apps (AGENTS.md "Shared-code changes") for nothing the phone would read.
- Ordering: the Mac sends devices sorted by id (`CompanionCoordinator.swift:572-574`); the phone cuts the list by state (Playing / Ready / Unavailable) and keeps the Mac's order inside each section (`SpeakersView.swift:278-294`, `:334-342`). No device is grouped "next to the Mac" on the phone today; the design rejects transport grouping in favour of state (`:336-342`).
- Every other `kind` switch in the app is on a different field: `MainOutState.kind` (`"selected"`/`"group"`: `DemoMacSession.swift:236,325,607`, `DeviceRowView.swift:118`, `MainOutPicker.swift:48,64`, `SyncSheetModel.swift:666`), app destination kind (`DemoMacSession.swift:359`), toast kind (`ToastCenter.swift:22`). None reads a device kind. Grep: `git grep -n -E '"bluetooth"|"airplay"|"wired"|switch .*kind' -- '*.swift'`.
- Per-app destinations on the phone require `supportsAirPlay2` (`/Users/alechenderson/Projects/audiout-remote/AudioutRemote/UI/Apps/AppsView.swift:157-161`), so wired rows (and Bluetooth rows, already `supportsAirPlay2 == false`) are not offered. Group editor member rows are every snapshot device with no kind filter (`GroupEditorView.swift:87-94`), so wired rows are offered as group members with no change.
- Test seam: `/Users/alechenderson/Projects/audiout-remote/AudioutRemoteTests/SpeakerRowRulesTests.swift` is the suite for "Speakers-tab rules that live in the views rather than on the wire" (`:9-11`); its `makeDevice(...)` fixture (`:29-54`) builds a `DeviceState` with `kind: "generic"` hard-coded (`:41`) and no `kind:` parameter. Nothing tests `SpeakerTransport.of` today (`git grep SpeakerTransport AudioutRemoteTests` → no hits).
- Test commands the repo documents (`/Users/alechenderson/Projects/audiout-remote/AGENTS.md:119-131`): `scripts/mule-test.sh <SuiteName>` for a headless run on the mule's simulator (verdict line prefixed `mule-test:`); compile check and phone build at `AGENTS.md:96-108`. From the Mac repo, `bash scripts/ios.sh build --root /Users/alechenderson/Projects/audiout-remote` is the compile check (`scripts/ios.sh:4`). Verification on the physical iPhone is the standing rule (`AGENTS.md:80-85`).
- The phone checkout has uncommitted changes in `AudioutRemote.xcodeproj/project.pbxproj` and `Package.resolved` from another session. Do not touch them; do not commit.

## Settled decisions

1. `"wired"` maps to no transport chip (`nil`), same as the local Mac. No new chip, no new `SpeakerChip` case. Reason: on the Mac these rows are "the Mac and its other outputs"; a chip named for them would be a fourth transport lens for rows the reader thinks of as the Mac.
2. No ordering change on the phone. Wired rows sit wherever their state puts them, in the Mac's id order, like every other row.
3. Glyph comes from `iconSymbolName` as it already does. No wire change.
4. No demo-mode wired device, no analytics change.

## Steps

1. **Test first.** In `AudioutRemoteTests/SpeakerRowRulesTests.swift`, add a `kind: String = "generic"` parameter to `makeDevice` (`:29-36`) and pass it at `:41` in place of the literal. Add one `@Test` named `aWiredRowBelongsToNoTransportChip` — defect: a `"wired"` row falling through `default` into the AirPlay chip. Assert `SpeakerTransport.of(makeDevice(kind: "wired")) == nil` and, in the same test, `SpeakerTransport.of(makeDevice(kind: "generic")) == .airplay` so the default arm is still proven. Run `scripts/mule-test.sh SpeakerRowRulesTests` from the phone repo and paste the failing verdict.
2. **`SpeakersView.swift` `SpeakerTransport.of(_:)` (`:118-125`).** Add `case "wired": return nil` beside the `"cast"` arm, so the `default` still covers the AirPlay-class kinds. Rewrite the type's doc comment (`:94-101`) and the method's (`:111-117`) in one or two sentences each so they state that both the local Mac and a wired output (`"wired"`, the Mac's own jack/USB/HDMI outputs) belong to no transport chip and stay under All and Favourites; keep the sentence that `SyncSheetModel.speakerKind` is the second reader. Re-run the step 1 command; paste the pass.
3. **`SyncSheetModel.swift:655-656`.** Change the comment so `nil` reads as "the local Mac or a wired output — both AirPlay-class for `speaker_kind`, held back from the chips only because they belong to no filter". No code change; the arm `case .airplay, nil: .airplay` stays.

## Out of scope — do not touch

- No `SpeakerChip.wired`, no "Wired" label, no change to `visibleChips` or `presentTransports`.
- No ordering or sectioning change in `SpeakerConsole`; no "under This Mac" grouping.
- No `audiout-shared` edit, no pin bump, no `Package.resolved` or `.pbxproj` edit (those files carry another session's uncommitted changes).
- No `DemoMacSession` wired fixture; no `Analytics.SpeakerKind` case; no `analytics-events.md` row.
- No change to `AppsView.redirectableDevices` or `GroupEditorView.memberRowIDs`.
- No `DeviceRowView` glyph logic; the wire's `iconSymbolName` already carries the glyph.
- No cleanup, no abstractions, no backwards-compat shims.

## Verification

From `/Users/alechenderson/Projects/audiout-remote`:

- `scripts/mule-test.sh SpeakerRowRulesTests` → last line `mule-test: passed N tests` (N = the suite's current count plus 1). Step 1 must first show a FAILED verdict naming `SpeakerRowRulesTests`.

From `/Users/alechenderson/Projects/AirPlay Controller`:

- `bash scripts/ios.sh build --root /Users/alechenderson/Projects/audiout-remote` → build succeeds (compile check of the app target).

Done means both commands ran in the executor's session and passed, with output pasted. The physical-iPhone run of the whole test target (AGENTS.md standing rule) is Alec's, not the executor's; the executor says "compile-verified and mule-passed", never "verified on device".

Test seam: `SpeakerRowRulesTests.swift`, new test in step 1. Defect it catches: a `"wired"` row classified as AirPlay and drawn under the AirPlay chip.

## Execution plan

One track, all three steps. Files: `AudioutRemote/UI/Speakers/SpeakersView.swift`, `AudioutRemote/UI/Sync/SyncSheetModel.swift` (comment only), `AudioutRemoteTests/SpeakerRowRulesTests.swift`. Model: haiku. Effort: low. Work directly in the `/Users/alechenderson/Projects/audiout-remote` checkout (no worktree: the repo's uncommitted `.pbxproj`/`Package.resolved` edits are not on any commit and the build may depend on them); nobody commits or pushes. Independent of every Mac-side ticket: the phone change is correct whether or not the Mac ever sends `"wired"`.

## Executor rules (copy verbatim into the handoff prompt)
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.

## Product questions (recommended default applied above; reopen only if you disagree)

- Should wired rows get their own filter chip ("Wired")? Default: no, they behave like the local Mac. A chip only appears once two transports are present, so a household with one wired output and AirPlay speakers would gain a chip row it does not have today.
- Should the phone offer wired rows as per-app destinations? Default: no change now. `AppsView.swift:157-161` gates on `supportsAirPlay2`, which already excludes Bluetooth rows while the Mac accepts Bluetooth per-app routes (ticket 05 fact at `.scratch/local-wired-outputs/issues/05-routing-scope.work-order.md:11`). Wired inherits that existing gap; fixing it is a separate ticket that also covers Bluetooth.

## Cross-area questions

- [ticket-05 / Mac] The phone's per-app destination list (`AppsView.swift:157-161`) will not show wired or Bluetooth rows even after ticket 05 lets the Mac route apps to them. If the phone is meant to offer them, that is a new ticket replacing the `supportsAirPlay2` gate with `!isLocalDevice` plus whatever the Mac's `canBePerAppRouteTarget` refuses (Cast). Not in this work order.