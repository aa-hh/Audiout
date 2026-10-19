# Preliminary whole-codebase review — 2026-09-17

Status: findings only, nothing fixed. Reviewed at `dcc587c8` (main), branch `claude/unslop-code-ca8d54`.

Eight read-only reviewers, one per area, against one brief ([brief.md](brief.md)). The bar: reliable
code a competent Swift/AppKit engineer can read cold. Every finding cites file:line and quotes the
code; I spot-checked the top twenty against the source and all held. Per-area reports with full
evidence are in [areas/](areas/).

## Verdict

The codebase is far stronger than its first-review status suggests. There are no TODO/FIXME
stubs, no `#if false`, no empty `catch` blocks, no force-casts on OS data, every Core Audio call
checks its status, and the long "why" comments citing SPEC sections are the right kind. The
mechanical AI-tell scan found nothing real (6,599 of 6,897 hits were Apple API names; the rest
were C `#define` lines and UI copy). The suite of 4,136 tests has zero commented-out tests and
two-thirds name the defect they pin.

The problems are of two kinds, and neither is "AI slop":

1. **A rule written carefully in one place and not followed in a second.** Nine stores quarantine
   a corrupt file; one does not. `CompanionServer` caps every pool; `DACPServer` and the Cast
   audio server cap nothing. `MainOutRowView` fixed the slider-drag flag; `AppRowView` still
   carries the bug with a comment naming it. `run-tests.sh` documents why remote arguments must
   be quoted; `build.sh` sends them unquoted. This is the dominant pattern across all eight areas.
2. **Size.** `NativeBackend.swift` is 13,222 lines and one 234-property type. `PopoverController`
   is 5,992 lines. `AppDelegate` is 4,205 with one 818-line method. `NativeBackendTests` is
   11,104. None can be reviewed cold, and the per-property lock/queue rules that make the audio
   code correct can only be checked by holding a whole file.

| Class | Count | Meaning |
|---|---|---|
| BUG | 43 | the code is wrong; fix on those grounds |
| SUBSTANCE | 76 | wrong for the job: duplication, dead code, size, stale comments, convention drift |
| COSMETIC | 12 | reads badly, nothing breaks |

## Fix first (ranked)

Bugs a user or an attacker on the LAN can feel, then bugs that lose user data, then the rest.
Each line points at the area report that carries the evidence and the fix.

1. **Live system audio served to any LAN peer.** `CastSender/CastLiveAudioServer.swift:169,214` binds all interfaces by default (`CastOutputManager.swift:438`), serves any path, caps nothing, never times out. [model #1]
2. **Root PTP daemon shuts down on request from any local process.** `ptp-helper/main.c:463-478` never validates the XPC peer. [engine #4]
3. **Persisted speaker latencies, trims, Cast offsets and EQ are loaded with `try?` and silently reset.** `NativeBackend.swift:1785-1804`. The writes on the same stores are handled; the reads are not. [capture #1]
4. **A schema downgrade destroys the newer file on next save**, in all nine stores (`GroupStore.swift:144` and siblings). Newer build then older build = groups, routes, EQ gone, no quarantine copy. [model #9]
5. **Every AirPlay session gets identical `session_uuid` and `group_uuid`.** `shims/misc.c:778-807` re-seeds `srand(time())` per call and is called twice in the same second. [engine #1]
6. **Use-after-free window on the engine write path.** `EngineThread.base` (`EngineThread.swift:23,244,264`) is read from any thread and freed on the engine thread with no lock. [engine #2]
7. **DACP peer can push NaN volume to a speaker.** `DACPServer.swift:293,347`; `Double("nan")` parses and `level(fromDb:)` passes it through. [model #3]
8. **`DACPServer` accepts unlimited connections** — the exact file-descriptor exhaustion `CompanionServer` documents and guards. [model #2]
9. **"Play everywhere" and per-app local playback fail silently.** `try? sink.start()` at `NativeBackend.swift:4474,5243,5348,10217`. [capture #5]
10. **`AppRowView` slider stops tracking the model after any keyboard/VoiceOver volume change.** `AppRowView.swift:718`; the fix already exists in `MainOutRowView.swift:689`. [popover #1]
11. **`LevelMeterView` never stops its display link when it leaves a window**; every popover `rebuild()` strands a running one and its row. `LevelMeterView.swift` has no `viewDidMoveToWindow`; three sibling views do. [popover #2]
12. **`DefaultOutputDeviceMonitor` leaks a `DispatchWorkItem` per notification** (closure captures the item that owns it), `DefaultOutputDeviceMonitor.swift:383-395`. [capture #2]
13. **`SyncedLocalSink` never deinits** — the render box at `SyncedLocalSink.swift:190-195` is a strong `boxed = self` under a comment that says "unowned". [sync #2]
14. **A failed engine restart after device change or wake is swallowed**, `SyncedLocalSink.swift:372` (`restartEngine: { try? self?.start() }`). [sync #3]
15. **Both render callbacks resample two clocks per cycle** through a helper whose doc says production must never call it per buffer, `SyncedLocalSink.swift:650` and the BT twin. [sync #1]
16. **Real-time contract asserted then broken in the same buffer**: `handleBuffer` drops audio rather than wait on a 2-instruction lock, then blocks on an `NSLock` around an `AVAudioConverter` run (`NativeCaptureCoordinator.swift:1683-1696, 4419`). Both mixers block the delivery thread the same way (`AppRouteMixer.swift:389`, `LeveledAppInjector.swift:264`). [capture #4, #10]
17. **`build.sh:53` sends remote arguments as unquoted `$*`**, the failure `run-tests.sh:161-171` documents and defends against. [scripts #1]
18. **Pre-commit Guard 4's fallback build passes `--build-system native`** twenty lines under its own comment saying it must not (`.githooks/pre-commit:246`). [scripts #2]
19. **`housekeeping.sh:168` calls a sibling by relative path**, so its PTP-helper warning never fires. [scripts #3]
20. **`O_CLOEXEC` passed to `fcntl(F_SETFL)` does nothing**; sockets are not close-on-exec despite the comment (`shims/misc.c:197`). [engine #7]
21. **Companion approval prompts stack without limit** from a peer cycling client IDs; nothing withdraws or frees them (`CompanionApprovalStore.swift:158-180`). Dark today: `remoteAppIsOffered` is false. [model #4]
22. **Companion approval store neither quarantines a corrupt file nor reports a failed save** the way the other nine stores do. [model #5, #6]
23. **`bind()` writes the C `stream_id` outside the per-output op gate** that exists to make it atomic (`AirPlayEngine.swift:853-895`), and the arm-collision recovery clears the *other* op's callback slot (`:1554-1560`). [engine #3, #9]
24. **`MixTimeline.add` allocates before the pending-frames cap applies**; one clamped-to-zero timestamp asks for a multi-gigabyte append (`AppRouteMixer.swift:614`). [capture #3]
25. **Test suite: 14 suites hand-roll a wait loop that fails open, 59 assertions follow a fixed sleep, one `try! #require` crashes the whole run, one named test asserts nothing.** [tests #1–#6]

## Structural work (the substance findings, grouped)

These are not bugs. They are what stops a cold reviewer, and they are where the next bugs will hide.

- **Split the four unreadable files along seams the code already names.** `NativeBackend.swift` → `+Bluetooth`, `+Cast`, per-app routing (the extensions exist). `PopoverController` → BT wizard funnel, sync drawer, Applications card (its MARK sections). `AppDelegate` → the ~930-line companion server wiring, which becomes testable the moment it leaves the untestable target. `DemoPaneView.swift` (3,344 lines, 26 types). `NativeBackendTests.swift` (11,104). [capture #6, #21; popover #3; shell #3, #5, #9; tests #10]
- **Delete what the spec already retired.** `OwnToneBackend` + client + monitor + `PlaybackController` + 842 test lines drive a server `docs/SPEC.md` §3 says never ships and that is already gone from `dev/`. ~15 `NativeBackend` comments cite it by line number. [model #7]
- **Move test scaffolding out of shipping types.** ~1,400 lines of `test_*` in `PopoverController`, ~1,280 in `DeviceRowView` (including a per-pixel bitmap scanner), 22 on `NativeBackend` of which three are load-bearing production knobs named `test_`. [popover #5; capture #15]
- **Dedupe the hand-copies.** The `mHostTime → CLOCK_MONOTONIC` trio in both taps [capture #17]; two identical no-op process enumerators [capture #13]; `SilenceFallbackBannerView` = `SystemAirPlayNoteBannerView(.warning)` [popover #4]; the layer-colour stamp idiom hand-rolled 26 times in 17 files [popover #6]; pane header/scroll scaffold across three detail controllers [shell #4]; sidebar cell builders across two packages [shell #8]; `renderPNG` byte-identical in three snapshot tools [scripts #6]; 23 private `tempDirectory()` and 10 `assertSameHue` copies in tests [tests #7, #8]; the self-review hash in two files [scripts #15].
- **Fix comments that are now false.** `PerAppCaptureCoordinator` header claims a bug that is fixed and says nothing calls it (two live instances do) [capture #7]; `SyncedLocalSink:643` says the rebase is pre-roll only [sync #7]; shim headers still say "STUB STATUS" [engine #6]; `SuiteWait`'s "KNOWN GAP" points at finished work [tests #9]; root `AGENTS.md` housekeeping thresholds don't match the script [scripts #9]; `GroupController` carries a 2026-07-17 merge note and a 36-line post-mortem of deleted code [model #10].
- **Finish the migrations that stopped half-way.** `SuiteWait` (180 sites moved, 14 hand-rolled loops left); deprecated `Tokens` aliases (five at zero consumers still offered) [popover #8]; `Tokens.Layout` forwarders with no consumers [popover #7]; STABILITY markers (one left, four docs describe several) [popover, also noted].
- **Licence hygiene.** 37 `AudioutCore` files have no SPDX header with no documented reason [model #15]. Four vendored `AirPlayEngine` files carry local edits the ledger does not record — this breaks the rule the ledger exists for [engine #5].
- **Strict concurrency is off.** `Package.swift` is tools 5.10 with no `StrictConcurrency`, so the 109 `@unchecked Sendable` and 8 `nonisolated(unsafe)` in production are unchecked assertions [popover #14].

## Suggested waves

1. **Network + data-loss bugs** (items 1–9, 21–22): small diffs, high stakes, all in Core.
2. **UI + lifecycle bugs** (10–14, 16): small diffs, need a live look.
3. **Scripts + hooks** (17–19, 25): safe to land any time; the test fixes are mechanical.
4. **Engine** (5, 6, 20, 23 + ledger): touch the C boundary, need the hardware suite.
5. **Splits and deletes**: one file per PR, tests unchanged, so the diff is mechanical and reviewable.

Every wave gets an adversarial review before merge (green tests missed ten real defects on the last
big ticket). Cut tickets into `issues/` per wave when a wave starts, not now.

## Method and limits

- Scanner (`unslop_code_scan.py`) over all Swift, shell, C shims, dev: 6,897 hits, effectively all noise for this codebase. Kept for the record in the scratchpad, not here.
- Build/hallucinated-API step skipped deliberately: main's last merge ran the full suite under Guard 4, and Swift does not compile a made-up call.
- Vendored C (`sender/`, `pair_ap/`, `evrtsp/`, `libairptp/`) was not style-reviewed by rule; only ledger drift was checked.
- Reviewers read 100 % of the capture and sync areas, ~55–65 % of the rest in full with grep sweeps over the remainder. Counts per area are in each report.
- Reviewer model: Opus, high effort, one per area. Consolidation and spot-checks: Fable.
