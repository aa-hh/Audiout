# PLAN — Phase 2b: `NativeBackend` on the extracted engine

**Status: ✅ CLOSED — merged to `main` 2026-07-17 (`ceef81b`, + `723b72a` for
the popover fix). The native AirPlay 2 backend is THE shipping path.** No
OwnTone server, no runtime dependency. Gate PASSED by ear against real Sonos.
On main: core **411 / 0 failures** (2 live-gated skips), engine **98 / 0**,
harnesses 67/67 + 33/33. See "Outcome" below before reading the task list —
several things changed during execution.

Executed via parallel agents in the worktree `phase2-native-backend` (branch
`claude/phase2-native-backend`, branched from merged main 2127b4b — includes
engine first light + popover per-app routing).

Predecessor: PLAN-PHASE-2.md (extraction — complete through T-API-1 + first
light PASSED). Evidence ledger: `AirPlayEngine/docs/first-light-report.md`.
Roadmap briefs: `dev/notes/p2b-*.md` (indexed in `dev/AGENTS.md`).

---

## Outcome (2026-07-17) — what actually happened

All 14 planned tasks landed, plus a full adversarial review pass. Then the
**gated live session did its job**: it found bugs no headless suite could,
because the suites were green the whole time. What the plan did NOT anticipate
is that **the two worst bugs were in the app's DEFAULT state** — not edge
cases. Every launch, every user.

**Found by the gate and fixed (all verified by ear on real hardware):**

| Bug | Cause |
|---|---|
| No audio, green LED | Discovery raced onto an IPv6 link-local address; engine runs `ipv6=0`. Now IPv4-only + a 12s op timeout (a stalled op was leaking continuations and hanging quit). |
| Powered-off Sonos read as "AirPlay 1 coming soon" | `_airplay` drops before `_raop` on shutdown, so it looked raop-only. Sticky-AP2 bit + `isAvailable`. |
| Previous AirPlay device auto-streamed on launch | Persisted routing was auto-resumed. **Alec's decision: every launch defaults to `{current device}` = passthrough.** Saved groups still persist. |
| **Passthrough was SILENT** | The tap is `.mutedWhenTapped` (correct while streaming) but ran **unconditionally from launch** — muting system audio and sending it nowhere. `isPassthrough` was documented as the gate for exactly this and was wired to **nothing**. Capture is now gated on the live AirPlay output set. |
| **Current Device slider + mute did nothing** | The local device is display-only, so `setVolume`/`setMuted` hit the `outputIDs` guard and no-op'd. New `SystemOutputVolume` drives the real default output device, two-way. |
| Devices invisible until popover reopened | The mid-open repaint path only walked existing rows. A device-set change now forces a rebuild + animated resize. |
| Volume keys adjusted a muted device | Keys change system volume = the local device, which is muted while streaming. They now drive the Main Out target. |
| Permission prompt had no rationale | `make-app.sh` wrote no `NSAudioCaptureUsageDescription`. macOS asked to "record" — in the *Screen* & System Audio Recording bucket — with no reason, against a user model of "send audio to a speaker". |

**Deltas from the plan as written** (the task list below is the original and is
NOT edited to match — this section is the correction):
- The plan assumed capture lifecycle was settled. It was not: gating capture on
  the output set is the single most important change in 2b, and it was not a
  planned task.
- `AP1 raop port` stays deferred (unchanged). AP1 devices are discovered and
  shown unsupported, as designed — verified live.
- Latency: start buffer is configurable, product default 1000ms (~2.2s vs the
  old 3.5s); Settings › Audio › Advanced exposes it.

**Gated session checklist: PASSED.** Multi-room Move+Move 2 sync, native e2e
audio, smooth volume, AP1 dimmed/coming-soon, toggle-spam clean, clean quit,
no SIGABRT/SIGPIPE. Re-gate after the fixes also passed: launch→Mac plays,
deselect→audio returns, slider moves real audio, volume keys tracked live,
powered-off Sonos = failed (not AP1).

**Next iteration: synced-local output + multistream per-app engine routing.**
Its prereqs all landed here (monotonic pts, state stream, D5 vendored-diff
posture). Known open items are tracked as separate tasks, not here:
- **`redirect-connect` is INERT on main**: `reapplyRouting()` has ZERO
  production callers — routes save but never open a session. Do NOT simply wire
  it up: the redirect union feeds the capture gate, so one redirect would start
  the single global tap and mute the whole Mac.
- First-run permission setup flow (release-readiness, same bucket as the AP1
  port — irrelevant for Alec, essential before anyone else runs this).
- Default-output selector divergence: `NativeBackend` reads
  `kAudioHardwarePropertyDefaultOutputDevice` but `NativeCaptureCoordinator`
  listens on `...DefaultSystemOutputDevice` — different devices.

---

## Resolved decisions (Alec, 2026-07-17) — authoritative

- **D1 Scope:** NativeBackend end-to-end only. Multistream, synced-local
  output, EQ/auto-reconnect: deferred. **AP1 (raop.c) sender port: deferred to
  the NEXT iteration, first in line** (the "Mixer" AirPort Express gen2 is
  AP2-capable, so the current fleet needs no AP1 sender).
- **D2 Capture: IN-PROCESS Core Audio process tap** (not the audiocap
  subprocess). pts straight off the IOProc's `AudioTimeStamp.mHostTime`; zero
  IPC. audiocap and the OwnTone FIFO path stay untouched.
- **D3 Engine backlog: fix ALL of it** — teardown SIGABRT, SIGPIPE, post-
  CONNECTED state stream, write-cadence detection, libhash per-install seed,
  and the remaining hardening items (ipv6 default, loud config misses, gcry
  version floor, libevent log hook, start/stop idempotency, `device_flush`
  no-op seam).
- **D4 `setOutputSet` partial failure: best-effort** — apply what succeeds,
  mark the failed device unavailable, emit `deviceUpdated`. No rollback.
- **D5 Vendored-C posture: documented diffs OK.** When a fix genuinely cannot
  live in a shim, a minimal license-headered diff against upstream is allowed;
  EVERY such diff is recorded in `AirPlayEngine/docs/VENDORED-DIFFS.md`
  (seeded with the pre-existing libairptp `#ifndef` logging guard).
- **D6 AP1 devices are DISCOVERED and SHOWN:** `NativeDiscovery` browses both
  `_airplay._tcp` and `_raop._tcp`; AP1-only receivers appear in the popover
  dimmed/disabled, and clicking one shows a brief "AirPlay 1 support is coming
  soon" explanation (small transient content-sized `NSPopover` anchored to the
  row). NativeBackend never `addOutput`s them and keeps an explicit seam for
  the future raop sender.
- **D7 Live verification: ONE batched user-present gated session at the end**
  (multi-room 2-output sync → `AIRPLAY_BACKEND=native` end-to-end → volume
  A/B → real-fleet discovery watch). EXCEPTION (Alec, post-approval): passive
  Bonjour discovery scans against the live LAN are allowed during development
  — browsing is read-only (no root, no PTP, no audio). The LG TV may appear in
  scans but must NEVER be used as an output.

## Standing constraints (all tasks)

- Vendored OwnTone C stays byte-identical; fixes go in shims/hosting. D5 is
  the only escape hatch, and each use is ledgered.
- No OwnTone naming in any new/public symbol. GPL/MIT/BSD headers retained.
- Pure AppKit, documented controls only. The popover is exactly content-sized
  with animated resize — NEVER a scrollbar.
- All non-gated verification is headless: build + hermetic unit tests (no
  TCC, no hardware; live LAN discovery scans are the sole D7 exception).
- Both test suites must stay green: `AudioutedCoreTests` (note:
  `CaptureCoordinatorTests.testCaptureCrashOverBudgetSurfacesError` is a
  KNOWN pre-existing load-flaky test — if it is the only failure under
  parallel-agent CPU load, re-run it in isolation before investigating) and
  `AirPlayEngineTests` (29 tests). `audiocap --selftest` unaffected (audiocap
  is not edited).

---

## Task list

### Engine hardening (AirPlayEngine package)

**T-ENG-STATESTREAM-1 — Async device-state stream (backlog #3)** ⭐ critical path
- files: `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift`,
  `.../AirPlayTypes.swift`, `AirPlayEngine/Sources/CAirPlayEngine/shims/outputs.c`.
- what: `makeStateStream() -> AsyncStream<(OutputID, OutputState)>` mirroring
  `OutputBackend.makeEventStream()`. Surface the dispatcher's out-of-band
  `deferred_cb` deliveries (currently discarded once `callback_id` is spent)
  so `.streaming → .failed` after `addOutput` resolves is observable. No polling.
- model: opus · effort: high
- verify: headless test fires a synthetic post-terminal `outputs_cb` +
  deferred run and asserts the stream yields; existing 29 tests green.

**T-ENG-SIGABRT-1 — Fix teardown SIGABRT on `engine.stop()` (backlog #1)**
- files: `AirPlayEngine/Sources/AirPlayEngine/EngineThread.swift`,
  `AirPlayEngine/Sources/CAirPlayEngine/shims/ptpd.c`, possibly vendored
  `libairptp/src/daemon.c` (abort at "Stopping airptp event loop").
- what: Root-cause and fix the exit-134 abort during airptp teardown after
  streaming. Prefer shim/hosting (thread-join ordering / loop-break
  sequencing). Vendored change ⇒ D5 ledger entry.
- model: opus · effort: high
- verify: headless start→addOutput(stub)→stop loop exits 0 repeatedly; real
  stream+stop confirmed in the gated session.

**T-ENG-SIGPIPE-1 — Mask SIGPIPE (backlog #2)**
- files: `AirPlayEngine/Sources/CAirPlayEngine/shims/engine_bridge.c`.
- what: OwnTone masks SIGPIPE (main.c:718-732); our hosting doesn't. Add
  `SIG_IGN`/`SO_NOSIGPIPE` in the engine init path.
- model: sonnet · effort: low
- verify: headless test asserts the disposition after `start()`.

**T-ENG-CADENCE-1 — Write-cadence deficit/overrun detection (backlog #4)**
- files: `AirPlayEngine.swift` (hot path + accumulator), `AirPlayTypes.swift`.
- what: Track write-cadence deficit/overrun vs the configured frame rate
  (OwnTone player.c `pb_write_deficit_max` model); surface as diagnostic
  (log + counter). Allocation-free on the hot path; never gates writes.
- model: sonnet · effort: med
- verify: paced/underfed test feed reflects deficit; nominal feed ~zero.

**T-ENG-LIBHASH-1 — Per-install device id / PTP clock-id seed (backlog #5.1)**
- files: `AirPlayEngine.swift` (`hashClientName`/`applyConfigOnEngineThread`),
  `AirPlayTypes.swift` (EngineConfig seed field).
- what: libhash is a fixed FNV of client name → two installs on one LAN
  collide (device id + PTP clock-id seed). Derive from a per-install stable
  value (host UUID / persisted random); keep the non-zero invariant.
- model: sonnet · effort: low
- verify: same clientName + different seed → different non-zero libhash.

**T-ENG-HARDEN-1 — Remaining hardening (backlog #5.2–7)**
- files: `shims/conffile.c`/`.h`, `shims/engine_bridge.c`, `shims/logger.c`,
  `AirPlayEngine.swift`.
- what: (a) `general.ipv6` default off (match OwnTone); (b) wire
  `event_set_log_callback` to the logger shim; (c) conffile unknown-key
  returns made loud (assert/log in debug); (d) `gcry_check_version` gets a
  real min-version floor; (e) device_start/stop idempotency guards;
  (f) `device_flush` primitive as a NO-OP SEAM only (pause/seek later).
- model: opus · effort: high
- verify: unit test per item; existing tests green.
- serialization: runs AFTER T-ENG-SIGPIPE-1 (shares engine_bridge.c) and
  AFTER the engine-Swift chain (shares AirPlayEngine.swift).

**T-ENG-MULTIROOM-CLI-1 — engine-probe multi-output mode**
- files: `AirPlayEngine/Sources/engine-probe/main.swift` (sole editor).
- what: Repeatable `--address`/`--device-id`, one shared advancing pts, one
  PCM source fanned to all outputs. Plan-print without the gate flag exactly
  as today; live run stays behind `--i-have-a-receiver-and-owntone-is-stopped`.
- model: sonnet · effort: med
- verify: no-flag run prints an N-device plan, exits 0; build green.

### Native path (AudioutedCore package)

**T-NB-PKGDEP-1 — Engine package dependency wiring**
- files: `AudioutedCore/Package.swift` (sole editor).
- what: Local path dependency on `AirPlayEngine` + product dep on the core
  library target. Platform floor: engine is .v14 (tap API is 14.4+; Alec runs
  14.4.1) — raise the core floor to .v14 if that is the minimal working
  configuration rather than fighting availability annotations; record the
  choice. Mock/OwnTone paths unaffected.
- model: sonnet · effort: low
- verify: `swift build` + existing tests build in AudioutedCore.

**T-NB-CAPTURE-1 — In-process process-tap capture → `engine.write(pcm:pts:)`** ⭐
- files: NEW `AudioutedCore/Sources/AudioutedCore/NativeCaptureCoordinator.swift`
  + NEW `.../Tests/AudioutedCoreTests/NativeCaptureCoordinatorTests.swift`.
  Reference (read-only, do NOT edit): `dev/audiocap/Sources/audiocap/TapEngine.swift`.
- what: Core Audio process tap (`CATapDescription` /
  `AudioHardwareCreateProcessTap` + aggregate device, macOS 14.4+) inside the
  app process, adapted from our own TapEngine. pts per buffer from the
  IOProc's `AudioTimeStamp.mHostTime`. READ THE REAL ASBD — the tap rate
  tracks the default output device; apply the Phase-0 config-follows-tap
  invariant (configure the ENGINE's quality to match the tap, don't resample
  blindly). Convert to the engine's expected PCM format (read the engine
  code / EngineConfig for what it wants — first light ran S16LE/44.1k/2ch).
  `.mutedWhenTapped` mute mode. Handle default-device change + start/stop
  lifecycle + tap-creation failure / device loss surfaced as capture errors.
  Inject tap + engine behind protocols; tests hermetic (no TCC/tap).
- model: opus · effort: high
- verify: hermetic state-machine test (create→buffers w/ advancing mHostTime→
  converted→forwarded→device-change→stop→error surfaced).

**T-NB-DISCOVERY-1 — `NativeDiscovery` (NWBrowser, both service types)** ⭐
- files: NEW `.../AudioutedCore/NativeDiscovery.swift` + NEW
  `NativeDiscoveryTests.swift` + NEW env-gated `NativeDiscoveryLiveTests.swift`.
- what: Browse `_airplay._tcp` AND `_raop._tcp`. Per resolved service:
  `DeviceDescriptor` (name/host/address/family/port + TXT `deviceid`/
  `features`/`model`); classify AP2-capable vs AP1-only (raop-only, or no AP2
  features bit); own the colon-hex-TXT-id ⟷ `OutputID` mapping (NEVER
  reformat ids); appear/update/disappear callbacks with an
  `isAirPlay2Supported` flag; de-dupe devices advertising both services;
  handle duplicate resolves, IPv4/IPv6 races, `.ready/.failed/.cancelled`.
  AP1-only devices are surfaced, not dropped.
- LIVE verification (allowed per D7 exception): ground-truth the LAN with
  `dns-sd -B _airplay._tcp` / `-B _raop._tcp` (timeout-bounded); start
  `dev/fake-speakers.sh` (shairport-sync, AirPlay 1, ONE instance max) to get
  a genuine AP1-only service, run the env-gated live test
  (`AIRPLAY_LIVE_DISCOVERY=1`), assert the real fleet classifies correctly
  (Sonos Move / Move 2 / AirPort Express = AP2; fake speaker = AP1-only; the
  LG TV may appear — list-only, never an output), stop the fake speaker.
- model: opus · effort: high
- verify: hermetic tests with injected browser (both service types, AP1/AP2
  classification, id round-trip) + the live scan above.

**T-NB-BACKEND-1 — `NativeBackend : OutputBackend`** ⭐
- files: NEW `.../AudioutedCore/NativeBackend.swift` + NEW
  `NativeBackendTests.swift`.
- what: Fresh implementation of the `OwnToneBackend` shape (NOT a refactor):
  own `known`/`order` + `stateQueue`; `start()` wires NativeDiscovery →
  engine descriptor feed and subscribes `engine.makeStateStream()`;
  `setOutputSet` diff-and-converge with D4 best-effort policy; `setVolume`
  0–100 → engine; `setMuted` via the stashed-volume shim (pattern at
  `OwnToneBackend.swift:206-220`); `Device.kind` from TXT `model`;
  `Device.id` = colon-hex TXT id; `Device.supportsAirPlay2` from discovery;
  AP1-only devices emitted `deviceAdded` with `supportsAirPlay2=false`,
  `isAvailable=false`, and NEVER `addOutput`-ed; `.level` pass-through.
  Explicit seam comment + protocol shape for the future raop sender (D6).
  Ground capture wiring in how the app currently connects CaptureCoordinator
  ↔ OwnToneBackend before writing.
- model: opus · effort: high
- verify: NativeBackendTests (spy engine + injected discovery): deviceAdded,
  AP1 surfaced-unavailable-never-added, deviceUpdated on state transition,
  best-effort convergence, mute stash/restore. Existing suites green.

**T-NB-RESOLVER-1 — `BackendKind.native` + `AIRPLAY_BACKEND=native`**
- files: `.../AudioutedCore/OwnToneBackend.swift` (resolver:
  `BackendKind` ~:481-513, `makeBackend` ~:521-534). HOT FILE, sole editor.
- what: Add `.native`, map `"native"` in `resolved()`, `makeBackend` case
  constructing NativeBackend + NativeCaptureCoordinator. Do NOT touch the
  `.ownTone` case (its deletion is a later, gated cleanup).
- model: sonnet · effort: low
- verify: `AIRPLAY_BACKEND=native` resolves; build green.

**T-NB-RESOLVER-1b — Resolution tests for `native`**
- files: `.../Tests/AudioutedCoreTests/BackendKindResolutionTests.swift`
  (sole editor; strictly AFTER T-NB-RESOLVER-1).
- what: `native` + case-insensitive variants; keep existing assertions.
- model: haiku · effort: low
- verify: `swift test` green.

### UI

**T-UI-AP1-1 — AP1-only devices: dimmed row + "coming soon" explanation**
- files: `.../AudioutedPopoverUI/PopoverController.swift`,
  `.../AudioutedSharedUI/DeviceRowView.swift`, `MockBackend.swift`
  (add one AP1-only fixture device), + NEW test (e.g.
  `DeviceRowUnsupportedTests.swift`). Sole editor of all four.
- what: Grounded: `Device.supportsAirPlay2` exists (Device.swift:51);
  `DeviceRowView.apply` already disables on `!isAvailable` and greys via
  `rowTextColor` (DeviceRowView.swift:184-207, 371-375). Extend:
  `supportsAirPlay2 == false` renders visibly unsupported (dimmed, toggle
  disabled, accessible label mentioning AirPlay 1); row click presents a
  small transient content-sized `NSPopover` anchored to the row: "AirPlay 1
  support is coming soon." Pure AppKit; main popover stays content-sized.
- model: sonnet · effort: med
- verify: unit/harness test asserts disabled/dimmed + explain affordance;
  existing DeviceRow/popover tests green.

### Docs / ledger

**T-DOC-2B-1 — Status docs, runbook, VENDORED-DIFFS ledger (runs LAST)**
- files: `AirPlayEngine/README.md`, `AirPlayEngine/docs/first-light-report.md`
  (tick the backlog), NEW `AirPlayEngine/docs/VENDORED-DIFFS.md`, root
  `AGENTS.md` (refresh the stale map: engine exists, `native` backend, AP1
  coming-soon), `dev/README.md` (`AIRPLAY_BACKEND=native`), NEW
  `dev/notes/p2b-nativebackend-runbook.md` (native headless run, TCC grant
  flow via `scripts/make-app.sh` stable path, and the D7 gated-session
  checklist). Sole editor of each.
- what: Consolidate. Build the ledger from `git diff` over the vendored dirs
  (everything under `Sources/CAirPlayEngine/` EXCEPT `shims/`), seeded with
  the pre-existing libairptp logging guard: file, license, rationale, hunk.
  Do NOT edit SPEC.md (deferred close-out).
- model: sonnet · effort: med
- verify: ledger matches the actual vendored diff; AGENTS.md no longer stale.

---

## Serialization / hot files (Workflow: shared worktree, one owner per file)

- `AirPlayEngine.swift` + `AirPlayTypes.swift`: STATESTREAM → CADENCE →
  LIBHASH → HARDEN (strict serial chain).
- `engine_bridge.c`: SIGPIPE → HARDEN.
- `ptpd.c` (+ vendored daemon.c): SIGABRT only.
- `outputs.c`: STATESTREAM only. `conffile.c`/`logger.c`: HARDEN only.
- Core `Package.swift`: PKGDEP only. Resolver file: RESOLVER only, then its
  test file: RESOLVER-1b. UI files + MockBackend: UI-AP1 only.
- New files: one owner each. No agent runs `git commit` (shared index; the
  orchestrator commits).
- Cross-package: core builds compile the engine sources — transient breakage
  from a concurrent engine agent looks like errors in files you didn't touch:
  wait 60–120 s and retry (up to ~5×) before investigating. SwiftPM
  "another instance" lock waits are normal.
- PTP 319/320: no live streaming outside the gated session. Live LAN
  *discovery* scans are allowed (D7 exception).

## Critical path

PKGDEP → DISCOVERY ∥ CAPTURE → BACKEND → RESOLVER → RESOLVER-1b, with
STATESTREAM a parallel hard prerequisite of BACKEND.

## Gated session checklist (Alec present, ONE session, at the end)

1. Stop OwnTone (frees PTP 319/320); firewall allowlist per first-light script.
2. Multi-room: engine-probe 2-output run (Sonos Move + Move 2), sync by ear.
3. `AIRPLAY_BACKEND=native` app end-to-end on a real speaker (TCC grant flow).
4. Volume-curve A/B vs OwnTone (perceptual check).
5. Watch real-fleet discovery incl. an AP1-only device appearing unsupported
   (fake speaker) and the LG TV listed but never targeted.
6. Teardown: stop/start cycles — no SIGABRT; force-drop a receiver — no
   SIGPIPE death.

## Risks

R1 in-app TCC (stable .app path via scripts/make-app.sh; documented in
runbook) · R2 dual-service discovery classification (mitigated: live LAN
scans during dev, per Alec) · R3 pts correctness (2-output gated run is the
real check) · R4 vendored-C reach (D5 ledger) · R5 platform floor (PKGDEP
verifies) · R6 volume-curve fidelity (gated A/B) · R7 cross-plan resolver
contention (none known in-flight) · R8 the serial engine-Swift chain is the
throughput bottleneck by design.
