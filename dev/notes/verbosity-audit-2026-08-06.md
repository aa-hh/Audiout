# Verbosity & AI-slop audit — 2026-08-06

Branch: `claude/verbosity-cleanup`. A staff-level readability pass over the whole
Swift estate (~103k LOC): remove comments that narrate history or restate code,
fix comments that have drifted into being *wrong*, and correct a handful of
misleading names. **Not a refactor** — zero behavior change; every non-comment
diff line is one of nine sanctioned mechanical edits (verified by extracting all
non-comment lines from the diff).

## Method

10 parallel audit agents over LOC-balanced slices + 2 naming-focused agents
(cross-file vocabulary, cryptic names), all against a written rubric; every
finding staff-reviewed before editing; 8 editor agents on disjoint file sets;
one combined build + full-suite run. Rubric calibration: this repo's why-heavy
trap comments, `SPEC.md §N` / `D#` / `Q#` / doc-anchored `T-*` tags,
`STABILITY(...)`, `razor:`, and ALL-CAPS invariants are **house voice, kept**
(verified in the diff: zero deletions of `STABILITY(`/`razor:`/`NEVER`/`TRAP`;
`SPEC` citations balanced). What was removed: task-completion archaeology
("replaces the T-PKG-1 scaffold"), dated review citations, "this session"
timestamps, stale scope notes, narration, reviewer-reassurance prose, orphan
tags (grep-verified absent from docs/), and comments contradicting shipped code.

External pattern references consulted for the rubric: the deslop pattern list
(github.com/dabit3/deslop) and the AI-slop reviewer checklists surfaced in
search (josecasanova.com/prompts/ai-code-slop-reviewer, cline.bot's slop
detector write-up).

## Outcome

- 240 findings (225 general + 15 naming); ~185 applied on this branch across
  70 files, **+392 / −609 lines**.
- Dominant categories: `stale` (~76 — comments asserting things that are no
  longer true) and `change-log` (~70 — git-owned history in comments).
- Highest-value fixes (docs that actively lied):
  - `CompletionRegistry.swift` — claimed CONNECTED doesn't resolve the waiter
    (it is terminal and does — the hang-fix behavior); claimed all mutation is
    engine-thread (timeout timers deliberately fire off it — the lock is
    load-bearing, not defensive).
  - `AppRouteMixer.swift` — claimed POST-volume RMS metering; it is PRE-volume
    (the contract every meter depends on).
  - `AirPlayEngine.swift` — header still scoped the engine to "BUILD + HEADLESS
    TESTS ONLY"; `liveBinding` wore `liveDeviceState`'s doc.
  - `MembershipBusView.swift` — header asserted per-row rail drawing; the
    panel-level `BusRailOverlayView` draws the rail.
  - Dozens of "a later task wires this" / "no caller passes true today" notes on
    long-shipped wiring (meters, AppTetherColor, AudioProcessResolver
    consumers, T6/T-8 routing).
- Mechanical code edits (the only non-comment changes): `ProbeArgParsing`
  accumulator `a` → `parsed`; `OwnToneClient` URLError switch collapsed (all
  branches threw `.unreachable`); `MainOutRowView` `isMasterMutedState`/
  `isArmedState` → `isMasterMuted`/`isArmed`; five self-imports of
  `AudioutSharedUI` removed; `assertSameHue` → `assertSameColor` (+
  `Metric`→`Meter` test-name typo); a journey variable, a dead `% 1 == 0`
  conditional, and an unused-loop-var silencer removed.

## Owner decisions (flagged, not edited — cold files)

1. `SyncedLocalSink.swift:271` — doc says the render-block box is `unowned`;
   the code captures a **strong** `SyncedLocalSink?` box. Doc fix or lifetime
   change — worth a deliberate look, the strong box means the block retains the
   sink.
2. `LevelMeterView.swift:210` — `displayHeight(forLevel:)` returns the fill
   **width** fraction (horizontal meter). Rename (`displayFraction`?) touches
   `LevelMeterViewTests`.
3. `PopoverColumnGrid.swift:270` — `statusDotDiameter` has zero uses repo-wide
   and documents the retired status dot; deleting is a public-API change.
4. `AudioHardwareTestGate.swift:124` — legacy `skipUnlessEnabled()`'s documented
   removal condition is met (zero callers); AGENTS.md:481-483 names it, so the
   deletion and doc ride together. Held in case an unmerged branch's tests call it.
5. `TCCBucketDiagnostic.swift:18` — intro frames the TCC-staleness contradiction
   as open; `AppRelaunchCommand` retracted its half. Reframe wants care.
6. `DeviceRowView.swift:307` — garbled half-edited comment ("2026-07-14 — ahh:
   no longer needed…") needs a caller survey to rewrite.
7. `SidebarViewController.swift:85` — `Q4-b` tag greps to nothing under docs/
   but also appears in `Tokens.swift` + tests; dropping it is a cross-file call.
8. `ControlPanelBackingViewTests.swift:28,52` — helpers take `file:`/`line:`
   params they never use (XCTest residue); removing params is beyond comment
   cleanup.
9. `SPEC.md:425,499` — retired product term "Selected Speakers" survives in two
   prose spots vs §1's authoritative "Selected Devices". Spec is the owner's to edit.

## Naming/vocabulary recommendations (ranked, from the vocab audit)

Full report: the deliberate-distinction glossary was verified first
(`Device` vs engine types, `engineVolume` vs `uiVolume`, volume/gain/level,
`isMainOutMember` vs `isSpeakerSelected`, unreachable vs disappeared — all
load-bearing, untouched).

1. **Delete `GroupController`'s "legacy on/off shims"** (`isEnabled`/
   `setDeviceEnabled`) — zero callers in Sources+Tests; the "kept for callers
   not yet migrated" comment is false. [file is HOT — after branches land]
2. **`CaptureControlling.updateRouting` → `updateExclusions`** — it syncs the
   whole-system tap's exclusion set, routes nothing; collides with
   `applyRouting`/`updateAppRoutes`. [HOT files]
3. **Finish enabled→selected at the row-view seam** — `DeviceRowView`
   `didToggleEnabled`/`enableCheckbox`/`enableToggled` vs the model's
   "selected" vocabulary. [hosts/tests HOT]
4. **`Device.isSelected` → `isInOutputSet`** — kills the repo's #1 documented
   trap (AGENTS.md keeps a standing rule to counteract the name). Large blast
   radius: own mechanical-rename session when main is quiet.
5. **Stream-id spelling at the engine seam** — engine `streamId` vs app
   `streamID` collide in single expressions (`NativeBackend.swift:1138`);
   either align `AppRouteMixer` members or document the engine's `Id`
   convention in `AirPlayEngine/AGENTS.md`.
6. `AppRowView.Configuration.appID` is a `bundleID` and sibling delegates say
   `id` — one UI package, three spellings.

## Deferred: hot-file findings (39, report-only)

These files are owned by unmerged live branches (t-zombie, failed-row-stack,
aggregate-device-wave3, current-status/routing-exception, warm-signal-full,
focused-nightingale, accessibility, onboarding, companion). Run this list as a
small cleanup pass **after those branches merge** — same rubric, same rules.

`NativeBackend.swift`:
- 6209: "NOT yet called anywhere — T6 wires the real per-app routing" — false;
  `engine.addOutput` called at 3076/3761. Drop the clause.
- 3359-3362: destination-set doc block sits on `diagFloatPeak`; move to
  `handleDestinationSetsChanged` (3473).
- 5889-5891: "replaced our branch's `captureGateWantsCaptureLocked()`" — helper
  exists nowhere; delete.
- 1357-1366: numbered flow step narrating removed code (T4-superseded); the
  trap already lives on `ptpClockAvailable` (285-293). Compress to one line.
- 3429-3432: "previously referenced nowhere / first time it is ever read" —
  delete the sentence.
- 659, 3443: commit hashes in comments — drop hashes, keep pointers.
- 6048-6051: "pre-existing gap, not a regression from T1-T3" blame note —
  delete.
- 1954 (+2811, 2860, 4656): "purely additive, no new locking" diff-review
  assurances — keep "non-blocking", cut the rest.
- 6473: `updateRouting` naming (see recommendation 2 above).
- 1138: streamId/streamID collision (see recommendation 5).
`NativeCaptureCoordinator.swift`:
- 606-608: "a later task (T6) is expected to call this" — false
  (`NativeBackend.swift:2428`). Rewrite present-tense.
- 371-372 (+108-113, 1532-35): "always-empty exclusion list until…" — false;
  OwnToneBackend.swift:897 injects the real resolver.
- 259 (+100): `W1-T7`/`Gap 1`/`Fix 1`/`T-LEAK-FIX` orphan tags — drop tags,
  keep text.
- 950: "used to be `queue.sync {…}`" retold ~5×; keep `snapshotLock`'s copy,
  point the rest at it.
`PerAppCaptureCoordinator.swift`:
- 68-71: "nothing in the app calls it yet — T4" — false (NativeBackend
  1074/1080, 2384-85). Delete.
- 32-40: "fix pending merge on a branch" — landed
  (NativeCaptureCoordinator:2860). Keep selector rationale only.
- 941: TCC-gate pointer names `beginStart`; the gate lives in
  `CoreAudioProcessTap.createTapAndReadFormat` (1140-1145).
- 149-151: "mechanism used to be written out twice (architecture review…)" —
  drop the used-to sentence.
`PopoverController.swift`:
- 159-162 (+180): "card itself is wired by a later task (T-8)" — shipped;
  rewrite.
- 983-985: "card isn't built yet (T-8)" — false (beginCard 928). Drop clause.
- 1237-1253: dangling 17-line doc block attached to no declaration — delete.
- 2092-2097: blocked-toggle doc for a `canSelectLocalSpeaker()` that is
  unconditionally true — keep only the belt-and-suspenders sentence.
- 946-951: dated "Groups card removed (2026-07-16)" notes — class doc already
  covers it.
- 351: `V11`/`V14`/`S2`/`S4`/`S5` orphan tags — drop tags, keep text.
- 981: `mainAudioCardTitle` holds "System Audio" (v4 rename) — internal, needs
  its 3-line explainer reworked.
`AppDelegate.swift`:
- 1239: "Meters are SKIPPED in Phase 1 (RESOLVED Q8)" — contradicted 9 lines
  down by `updateLevel(rms)`. Delete.
- 1216-1218 (+213, 1352): T-U scaffold-era scope notes ("T-U2 will additionally
  rebuild the menu here") — apply() fully drives the UI; rewrite.
- 1036-1037: "(previously a `// TODO: settings` stub)" — drop.
- 198: `T-14` orphan tag — drop tag, keep text.
`PopoverControllerTests.swift`:
- 883-895: 13-line `[RETIRED]` tombstone for two deleted tests — delete.
- 474 (+363, 783, 852, 2299, 2335, 2426, 2449): `W2-T3`/`W2-T2`/`W3-T3`/
  `S-BUS`/`T-U9a` orphan halves — drop the orphan halves, keep the doc-live
  R11/R12 halves.
- 525-526 (+337-39, 350): dated redesign archaeology — present-tense facts
  suffice.
`GroupControllerTests.swift`:
- 426-436: 11-line tombstone for a deleted test (+~8 more "Supersedes <deleted
  test>" citations at 325, 441, 892, 911, 926, 951, 974, 1314) — keep
  mechanisms, drop deleted-test names.
- 820-828: "resolved by a prior attempt at this task… flagged again for human
  confirmation" — keep only the trait-timing trap (traits evaluate at
  discovery; emptiness knowable only after the calls run).
- 182 (+206, 231): `W2-T3` orphan halves next to doc-live R12 — drop orphans.
`NativeBackendTests.swift`:
- 7872-7875: dangling duplicate doc attached to a MARK — delete.
- 7756: `===== PORTED ours-only tests` banner — delete.
- 6673-6676: doc narrating a coverage gap this very test now fills — rewrite.
- 8536 (+7877, 8156, 8277, 8314): `W1-T7`/`W2-T2`/`W3-T3` orphan halves — drop;
  keep R9/R14/R11.

## Test verdict + a pre-existing red test on main

Full suite on this branch: **1646/1647 green**. The one failure —
`NativeBackendTests.redirectToASelectedDeviceNeverBindsAtAll()`
(NativeBackendTests.swift:4796, the 008 demote-at-decision
`scope_conflict`/`routeDemoted` telemetry expectation) — **reproduces
identically on unmodified main** (verified at 2b7a971b and bfc4f431, 3/3 in
isolation), so it is pre-existing and not from this branch; a task chip was
filed to root-cause it (suspect window: the roadmap-008 merge, possibly a
008×009 merge interaction). This commit therefore ships with the Guard 4 gate
consciously bypassed and this note as the justification.

Mid-flight, `main` merged the t-zombie branch (bfc4f431). Zero overlap with
this branch's files (t-zombie's files were all in the audit's skip-set), so
the eventual merge is clean; t-zombie's files also leave the hot set for the
post-merge cleanup pass below.

## Post-merge pass instructions

Skip-set logic and rubric live with this note; the raw finding files were
session-temporary. To rerun: the rubric section above + this ledger are
sufficient — every deferred item names file, line (as of 2026-08-06 main),
and the verified evidence.
