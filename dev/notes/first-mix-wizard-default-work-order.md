# Work order — the wizard is the default; the first-mix card goes; the row shows its tools

Date 2026-09-03. Approved by Alec across three mock rounds
(claude.ai/code/artifact/11ed7cb2-fa33-447d-b11c-370c11337f49). Direction:
"the intelligent wizard should be the default way someone aligns a speaker;
the card (align with your music / align with ticks / not now) should not be
an option; the Mac row should make the sync tool and the equalizer visible
the way the phone's tuning-fork glyph does, without cluttering the row."
The phone is untouched. This amends the 2026-08-08 "ALIGNMENT WIZARD UX
LOCKED" ruling in `docs/plans/PLAN-UNIVERSAL-SYNC.md:199-221` and the
2026-08-22 "EQ never lives on the Mixer" rule (Track C).

Decisions already taken — do not reopen them:

1. **No hold-silent, ever.** A never-aligned Bluetooth speaker that joins a
   mix plays immediately, out of step, until aligned.
2. **No permanent dismissal.** "Not now" was final for the life of the
   install. Gone, with its store record. The backend's once-per-session
   fire (`btAlignmentPromptedUIDs`) is the only memory of an offer.
3. **The wizard never opens by itself.** On the first join, a one-sentence
   NOTE mounts under the row (the phone's invite card, in the Mac's inset
   seat). It stays until the speaker is measured; ✕ hides it for the
   session only.
4. **The untuned Bluetooth chip is the tuning fork.** It reads `Align` with
   a `tuningfork` glyph and opens the wizard. A measured speaker's chip is
   today's readout and opens the drawer.
5. **The drawer carries both doors.** `Align again…` (the wizard) joins
   `Align by ear` (the metronome). `Revert` is deleted. The hidden ⌥-click
   is deleted.
6. **The equalizer is a button beside mute**, on every row with an
   equalizer. Secondary ink at rest; when the speaker's curve is not flat,
   the button's 1 pt border turns `Tokens.Color.partySignal` (the wizard's
   magenta) and the glyph stays as it is. Click opens the speaker's
   equalizer in the Groups window through the existing door.
7. **The surface widens by 30 pt** (`SurfaceLayout.width` 623 → 653) so
   the name column keeps every pixel it has today. The trailing columns
   are anchored from the trailing edge and do not move.
8. **The wizard stays a sheet** (Alec live-approved it across v7–v14).
9. **Main Audio's row gets no equalizer button in this pass** (follow-up).

## Track A — backend: delete the hold and the dismissal record

`AudioutCore/Sources/AudioutCore/NativeBackend.swift`

- Delete the first-mix HOLD: `btAlignmentHeldUIDs` (`:530`),
  `btAlignmentHoldTimeout` (`:545`), `btAlignmentHoldWatchdogs` (`:549`),
  `scheduleBTAlignmentHoldWatchdogLocked` (`:4249-4257`),
  `releaseBTAlignmentHoldLocked` (`:4263-4272`; no other caller — verify),
  the `stop()` cleanup for the held set (`:2375`; keep `:2376`
  `btWizardHeldUIDs`), the deselect-release loop (`:3425-3430`), and the
  `btAlignmentHeldUIDs.contains(uid)` term in `btSinkGain(forUID:)`
  (`:2818`; the WIZARD's own hold `btWizardHeldUIDs` and `muted` stay).
- Delete the DISMISSAL record: `btAlignmentDismissedUIDs` (`:527`), its
  load at `:1598-1599`, the `!dismissed.contains(uid)` term in the fire
  predicate (`:3413-3416`), the `resolveBTAlignmentPrompt(forDevice:dismissed:)`
  protocol requirement (`:10460-10465`) and implementation (`:11134-11144`),
  and the telemetry lines `bt_alignment_prompt_dismissed` and
  `bt_alignment_hold_timeout`.
- KEEP the fire site (`:3405-3423`) minus hold/dismissal: `mixPresent`, the
  `trims[uid] == nil && !btAlignmentPromptedUIDs.contains(uid)` predicate,
  the insert into `btAlignmentPromptedUIDs`,
  `Telemetry.log(... "bt_first_mix_intercept" ...)`, and
  `emit(.btFirstMixAlignmentPrompt)`. Rewrite the comment at `:3405-3412`:
  the speaker connects and plays as-is; the event asks the UI to offer
  alignment.

`AudioutCore/Sources/AudioutCore/OutputBackend.swift:233-241` — keep the
case name; rewrite its doc: "a never-aligned Bluetooth speaker just joined
its first mix and is playing as-is; the UI offers alignment under its row.
At most once per device per session."

`AudioutCore/Sources/AudioutCore/BTTrimStore.swift` — delete
`loadDismissedUIDs()` (`:182-184`), `saveDismissedUIDs(_:)` (`:187-190`), the
`alignmentPromptDismissed` Envelope property (`:106`) and its `nil` argument
at `:199`. Old envelopes still carry the key; `Codable` ignores it.

`AudioutCore/Sources/AudioutApp/AppDelegate.swift`
- Delete the `onResolveBTAlignmentPrompt` wiring (`:1007-1013`).
- The event arm (`:2997-3003`) calls
  `popoverController.offerBTAlignment(deviceID:)` (Track B). Update the
  comment and the log string at `:3127-3128`.

`AudioutCore/Sources/mock-speakers-demo/main.swift:85-88` — print
"♪ never-aligned speaker joined a mix \(deviceID)".

Tests, `AudioutCore/Tests/AudioutCoreTests/NativeBackendBTAlignmentInterceptTests.swift`:
- Delete `dismissalIsFinalAcrossBackendInstances` (`:311`),
  `deselectReleasesTheHold` (`:362`), `watchdogReleasesAnUnansweredHold`
  (`:379`), `volumeDuringHoldStaysSilentAndResolvePushesComposed` (`:399`),
  `watchdogReleasePushesComposedNotUnity` (`:422`), and every
  `resolveBTAlignmentPrompt` call (`:322-323`, `:414`, `:456`, `:820-821`,
  `:853`).
- Rewrite `neverAlignedFirstMixFiresAndHoldsSilent` (`:237`) as
  `neverAlignedFirstMixFiresAndStaysAudible`: the event fires AND the sink
  gain for the device is its composed gain, not 0.
- Keep `soloBTNeverFires`, `mixFormingLaterFiresThePrompt`,
  `alignedDeviceNeverFires`, `promptFiresOncePerSession`,
  `theWizardsReleaseLeavesTheTargetAudible` (adjust: no first-mix hold to
  release; assert the wizard's own hold clears on end-run).
- `BTTrimStoreTests.swift:53-56`, `:83-87` — delete the dismissal round-trip
  and the "survives clearAlignment" dismissal assertion.

## Track B — popover: note, chip, drawer, equalizer button, width

### B1. The card becomes the note

`AudioutCore/Sources/AudioutPopoverUI/BTAlignmentPromptView.swift` →
`git mv` to `BTAlignmentNoteView.swift`, class `BTAlignmentNoteView`. Same
inset seat (`well` fill + `hairline` rim, radius 7, same insets). Contents:

- One wrapping sentence, `Tokens.Font.detail`, `secondaryLabel`:
  `"\(name) will play a little behind the other speakers until it’s aligned. "`
  followed by `"Align it now."` in `Tokens.Color.gold`, semibold. The whole
  sentence is ONE button (an `NSButton` with an attributed title, or a
  label inside a borderless button — whichever keeps the wrapping label's
  width logic from `layout()`), pointer cursor, action `onAlign`.
  `static func noteCopy(name:)` under a "locked copy" MARK.
- A trailing `xmark` button, 16 pt, `inkTertiary`, AX label "Hide",
  action `onHide`.
- AX: the sentence button's label is `"Align \(name)"`, help is the
  sentence.
- Keep the `test_` hooks pattern: `test_copyText`, `test_clickAlign`,
  `test_clickHide`.

### B2. Note state in `PopoverController`

Replace the card state (`:512-522`) and its methods (`:4397-4406`,
`:4421-4446` card half, `:4496-4533`, `:4575-4582`, `:4916-4918`) with:

```swift
/// Devices the backend offered alignment for this session
/// (`BackendEvent.btFirstMixAlignmentPrompt`) and the ones whose note the
/// user hid. Both session-only; the backend re-offers on the next launch
/// while the speaker stays unmeasured.
private var btAlignmentOfferedIDs: Set<String> = []
private var btAlignmentNoteHiddenIDs: Set<String> = []
private var btAlignmentNoteViews: [String: BTAlignmentNoteView] = [:]
public func offerBTAlignment(deviceID: String)   // insert into offered, reconcile
```

- Mount condition per device: offered && !hidden && `devicesByID[id]` is
  Bluetooth, not Cast && `btAlignmentTargetIsLive(id)` &&
  `btMeasuredLatency(for: id) == nil`. Multiple notes may stand at once
  (no queue). Insert with `panel.insertRow(view, after: row)` exactly as
  the card did; remove with `panel.removeRow`.
- Rename `reconcileBTAlignmentPanels` → `reconcileBTAlignmentNotes` for
  the note half and keep the wizard sheet mount in it (or split into two
  functions called back to back — pick the smaller diff). All nine call
  sites (`:1023`, `:1734`, `:2091`, `:3841`, `:4405`, `:4520`, `:4532`,
  `:4682`, `:4866`) keep reconciling.
- `onAlign` → `startBTAlignmentWizard(deviceID:, door: .note)`;
  `onHide` → insert into hidden, reconcile.
- A note is dropped for good the moment `btMeasuredLatency` becomes
  non-nil (the reconcile does it; also clear the id from `offered`).
- The `bt_sync:method_chosen` captures go with the card — **report in the
  task summary that this event stream ends.**

### B3. The door

- `enum BTAlignmentWizardDoor: String { case chip, note, drawer, menu }` in
  `AudioutCore` beside `BTAlignmentWizardSession`.
- `startBTAlignmentWizard(deviceID:door:)`. Callers: `.menu` from
  `deviceRowDidRequestAlignmentWizard` (`:4349-4355`), `.drawer` from
  `syncDrawerDidRequestAlignmentWizard` (`:4963-4966`), `.chip` and
  `.note` from B4/B2. The `bt_sync:wizard_started` capture (`:4681`) gains
  `"door": door.rawValue`.

### B4. The chip is the fork on an untuned Bluetooth row

`AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift`, `updateSyncChip` (`:1776-1818`):

- `chipOffersWizard = device.isBluetooth && !device.isCast && !device.isLocalDevice && !tuned`
  (`tuned` as at `:1778`).
- When true: title `Align`, colour `Tokens.Color.label`; image
  `tuningfork`, 8 pt semibold, `imagePosition = .imageLeading`; no chevron;
  `isUntuned` stays true (dashed border). Tooltip:
  `"This speaker plays a little behind the others until it’s aligned. Click to align it."`
  AX label `"Align \(device.name)"`.
- Otherwise exactly today's chip (Mac and Cast rows keep "Not set").
- Click (`:1862`): when `chipOffersWizard`, route to the alignment-wizard
  delegate path instead of `didToggleSyncDrawerFor`. Extend the delegate
  method with the door (`deviceRow(_:didRequestAlignmentWizardFor:door:)`)
  so the menu passes `.menu` and the chip `.chip`; update the fakes in
  `PopoverEqualizerEntryTests` / `BTRowsUITests`.
- Chip stays 84 × 18; `updateRemovalUndo` (`:1880-1891`) and the disabled
  state (`:732`) unchanged.

### B5. The drawer: Align again…, no Revert, no ⌥

`AudioutCore/Sources/AudioutSharedUI/BTSyncDrawerView.swift`

- New leading button `alignAgainButton`: title `Align again…`, image
  `tuningfork` (same configuration the metronome uses at `:270-280`),
  width `PopoverColumnGrid.syncDrawerAlignAgainButtonWidth = 104` (new
  named constant beside `syncDrawerAlignButtonWidth`, `PopoverColumnGrid.swift:762`).
  Action → `delegate?.syncDrawerDidRequestAlignmentWizard(self)`. Tooltip:
  `"Measure this speaker again. Opens on the last result."`
- Band becomes `[⑂ Align again…] [♪ Align by ear] [Reset alignment]  hold ⇧ for 10 ms  [ − | value | + ]`.
  Update the doc comment at `:44-60`.
- Delete `revertButton` (`:108`, `:289-…`), its baseline logic (`:120`),
  the delegate call it made, and `PopoverColumnGrid.syncDrawerRevertButtonWidth`
  (`:764`). If the delegate protocol has a revert requirement, delete it and
  its `PopoverController` implementation.
- Delete the ⌥-click: `optionIsHeld` (`:616-618`), its test override
  (`:614`), the branch in `alignTapped` (`:502-509`); the metronome button
  only toggles ticks now. `DeviceRowView.alignTooltip` (`:1714`) loses the
  "⌥ for the guided alignment" sentence.
- Width check: at 653 the band has room for the hint. Add a test that
  lays the drawer out at `SurfaceLayout.width` and asserts the hint
  label's frame does not overlap the value cluster. If it does, move the
  hint into the `−`/`+` tooltips and delete the label — say which happened.

### B6. The equalizer button

`DeviceRowView.swift`

- New `eqButton` (`NSButton`, borderless, 24 × 24, image
  `slider.horizontal.3` at the mute glyph's 13 pt configuration, tint
  `Tokens.Color.secondaryLabel`) placed LEADING of `muteButton` with a 6 pt
  gap: new constants `PopoverColumnGrid.eqButtonWidth = 24`,
  `PopoverColumnGrid.eqToMuteGap = 6`. Mounted only when `supportsEqualizer`
  (`:1910`). The identity stack's trailing constraint (`:1541-1543`)
  anchors to the EQ slot's leading on EVERY row (button present or not) so
  name truncation is identical across rows.
- Shaped state: `var isEQShaped: Bool` pushed by the host through the row's
  `apply(...)` (views never read model state — `AudioutSharedUI/AGENTS.md:11`).
  When true, the button's layer gets a 1 pt border in
  `Tokens.Color.partySignal`, corner radius = the mute pill's. Glyph tint
  unchanged. No hover state (nothing on this row has one).
- Tooltip `"Equalizer"`; AX label `"Equalizer for \(device.name)"`, AX
  value `"Shaped"` / `"Flat"`. Click → the existing
  `deviceRowDidRequestEqualizer` path (`PopoverController.swift:4359-4361`
  → `onOpenEqualizer`).
- Host side: `PopoverController` gains `public var deviceEQIsShaped: ((String) -> Bool)?`
  and passes its answer into `apply(...)`. `AppDelegate` wires it from the
  same `DeviceEQStore` the detail pane writes through
  (`DeviceEQStore.swift:17`, `DeviceEQ.isFlat` at `DeviceEQ.swift:46`;
  the write hook is `controller.onSetDeviceEQ` at `AppDelegate.swift:1944`
  — on a committed write, repaint the popover rows so the border updates).
  Read the store the way the detail pane does; do not add a second store.
- Analytics: `Analytics.capture("eq:opened", ["door": "row_button"])` at
  the click, and `["door": "menu"]` on the existing menu path — both in
  `PopoverController` where `onOpenEqualizer` fires. (No `eq:opened` exists
  today — grep confirmed only `eq:adjusted` / `eq:reset`.)
- The row menu keeps `Equalizer…` (menu and button are two doors to one
  place).

### B7. Width

`AudioutCore/Sources/AudioutSharedUI/SurfaceLayout.swift:13` — `623` → `653`.
Both the popover and the Groups window widen (one frame, by design). Run
the layout suites listed below; the `mixer-4-device-detail` window goldens
are reference PNGs no test compares against (`AudioutWindowUI/AGENTS.md:14`
says never regenerate them — leave them alone).

### B8. Tests

`PopoverBTAlignmentUITests.swift` — the card tests (`:139`, `:149`, `:163`,
`:173`, `:183`, `:231-280`, `:895`, `:912`, `:928`) are replaced by:

- `anOfferMountsTheNoteUnderTheRowWithTheLockedCopy`
- `theNoteSurvivesARebuildAndACloseReopen` (same mechanism the card test used)
- `hidingTheNoteIsSessionOnly` — hide, assert unmounted; a fresh
  `offerBTAlignment` for the same id in the same session stays hidden.
- `twoOffersMountTwoNotes`
- `theNoteDropsWhenTheSpeakerIsMeasuredOrDeselected`
- `clickingTheNoteOpensTheWizardWithTheNoteDoor`
- `theWizardStartedEventCarriesItsDoor` — `chip` / `note` / `drawer` / `menu`.
- Keep every wizard door/sheet/Esc/target-lost test.

`BTRowsUITests.swift` (beside `syncRowPutsTheFeedPillsLeftAndTheChipRight`, `:312`):
- `anUntunedBluetoothChipReadsAlignAndOpensTheWizard`
- `aTunedBluetoothChipStillOpensTheDrawer`
- `theMacsOwnUntunedChipStillOpensTheDrawer`
- `aCastChipNeverOffersTheWizard`
- `theDrawerOffersAlignAgainAndNoRevert`
- `theHintDoesNotOverlapTheValueCluster` (B5)
- `theEQButtonSitsLeadingOfMuteOnRowsWithAnEqualizer` (present on AirPlay
  and Bluetooth, absent on the Mac row; identity trailing identical across
  the three)
- `aShapedSpeakerWearsTheMagentaBorderAndAFlatOneDoesNot`
- `clickingTheEQButtonOpensTheEqualizer`

`PopoverEqualizerEntryTests.swift` — rewrite `noRowCarriesAnEQChip`
(`:129-137`) as `theEQButtonIsADoorNotAnEditor`: every row's EQ control is
image-only (no title), and no row hosts an `EQEditorView`.

Run, through the wrappers only:

```bash
bash scripts/build.sh
bash scripts/run-tests.sh --filter PopoverBTAlignmentUITests
bash scripts/run-tests.sh --filter NativeBackendBTAlignmentInterceptTests
bash scripts/run-tests.sh --filter BTTrimStoreTests
bash scripts/run-tests.sh --filter BTDeviceRowTests
bash scripts/run-tests.sh --filter BTPopoverRowsTests
bash scripts/run-tests.sh --filter BTSyncDrawerAccordionTests
bash scripts/run-tests.sh --filter BTSyncDrawerViewTests
bash scripts/run-tests.sh --filter PopoverEqualizerEntryTests
bash scripts/run-tests.sh --filter PopoverCastSyncOffsetTests
bash scripts/run-tests.sh --filter PopoverLocalSyncTrimTests
bash scripts/run-tests.sh --filter BTAlignmentWizardSessionTests
bash scripts/run-tests.sh --filter GroupsHeaderParityTests
bash scripts/run-tests.sh --filter AppRowViewTests
bash scripts/run-tests.sh --filter MembershipRailTests
```

## Track C — docs (same change as the code; AGENTS.md docs-first rule)

- `docs/plans/PLAN-UNIVERSAL-SYNC.md:199-221` — add under the 2026-08-08
  lock: "**AMENDED 2026-09-03 (Alec):** the first-mix card, the hold-silent
  join and the final 'Not now' are removed. A never-aligned Bluetooth
  speaker joining a mix plays as-is; a one-sentence note under its row
  offers the wizard until the speaker is measured (✕ hides it for the
  session). The untuned chip reads Align with a tuning-fork glyph and opens
  the wizard; a measured chip opens the drawer, which carries Align again…
  beside Align by ear and no Revert." Leave the original text above it.
- `dev/notes/per-device-trim-spec.md:93-95` — strike "first-mix intercept
  card (once-ever auto-prompt)"; add the amendment pointer.
- `AudioutCore/Sources/AudioutPopoverUI/AGENTS.md` — `:24` stays (sheet);
  `:26` "EQ never lives on the Mixer" becomes: "The Mixer carries an
  equalizer DOOR (the row button beside mute, and the row menu) and one
  mark (magenta border when the curve is not flat). No editor, no curve,
  no tone control on the Mixer (2026-08-22, amended 2026-09-03)." Rewrite
  the W3/W4 lines for the note model. `AGENTS-HISTORY.md:53` (card
  paragraph), `:58` ("Don't re-add a chip or a drawer" — amend), `:78`
  (map row → `BTAlignmentNoteView`).
- `AudioutCore/AGENTS-HISTORY.md:421-435` — note the first-mix hold was
  removed 2026-09-03; only the wizard's own hold remains.
- `AudioutCore/Sources/AudioutSharedUI/AGENTS.md` — add the EQ button and
  the fork chip to the row's element list if it has one.
- `docs/FIGMA-DESIGN-SYSTEM.md` — the `PopoverColumnGrid` contract mirrors
  the Figma file 1:1: add the three new constants
  (`syncDrawerAlignAgainButtonWidth`, `eqButtonWidth`, `eqToMuteGap`),
  remove `syncDrawerRevertButtonWidth`, note the width change.
- `ROADMAP.jsonl` — mark `065` dropped through the foreman script (never
  hand-edit): `echo '{"id":"065","status":"dropped","notes":"Superseded 2026-09-03: the untuned chip opens the wizard directly; the first-join note replaces the alert state; no guided-vs-manual choice (Alec)."}' | node /Users/alechenderson/.claude/plugins/cache/foundry/foreman/0.46.0-alpha/scripts/roadmap.js update-status`

## Out of scope — do not touch

- The iPhone app and `audiout-shared`.
- The wizard's screens (stage, question, proposal, kept, bow-outs).
- Rehosting the sheet as a window.
- Main Audio's row.
- The Groups window's equalizer editor.
- Committing. Leave the tree uncommitted; the session lead commits.

## Report back

Files changed with a one-line why each; the exact test commands run with
pass/fail counts; the `bt_sync:method_chosen` end-of-stream note; the B5
hint outcome; anything in this order that was wrong against the code and
what you did instead. Never deviate silently.
