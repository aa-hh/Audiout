# PLAN — Phase 0e & 0f (+ 0d, OwnTone relocation)

Feasibility spike: system-audio capture (0e) and end-to-end capture → 3-speaker
playback (0f). Scope, decisions, and prior 0a–0c findings live in `SPEC.md`.
This file is the executable task doc; `SPEC.md` §8 is updated as tasks land.

**End state:** a Swift CLI captures all system audio (and a single app's audio)
via Core Audio process taps, writes PCM to a file and to stdout, feeds a named
FIFO that OwnTone's pipe input consumes, and all three speakers play Mac audio
in sync — with latency and 10-minute stability measured and written up.

---

## Verified facts (grounded 2026-07-13)

- **Core Audio taps API** (macOS 14.4+): `AudioHardwareCreateProcessTap`,
  `CATapDescription` (selectors `initStereoGlobalTapButExcludeProcesses:`,
  `initMonoGlobalTapButExcludeProcesses:`, and a per-process init for a single
  PID/objectID), `AudioHardwareCreateAggregateDevice` (tap UUID in the sub-device
  list), `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`. Tap format is
  read from `kAudioTapPropertyFormat` (ASBD) — typically **48 kHz float32**.
  Canonical reference: `github.com/insidegui/AudioCap`.
- **Process EXCLUSION is a first-class selector** (`...ButExcludeProcesses:`) —
  this is exactly the mechanism that prevents a capture→playback feedback loop and
  enables "This Mac (don't stream)" bypass. (Answers a 0f known risk.)
- **TCC:** capturing needs `NSAudioCaptureUsageDescription` (a plist string,
  manually added). Public path = permission prompt on first capture. AudioCap uses
  a private TCC API only to pre-check status; we do NOT need the private API for the
  spike.
- **OwnTone pipe input:** must be a named FIFO **inside a configured library
  directory**; OwnTone autodetects it, autostarts playback when bytes are written,
  autostops when they stop. **Format = PCM16 (S16LE); valid pipe sample rates are
  44100, 48000, 88200, 96000.** `.metadata` companion pipe (same path + `.metadata`)
  is optional. => 48 kHz is a legal pipe rate, so we may skip 48→44.1 resampling and
  only need float32→S16LE + (if a mono tap) channel handling. Verify in T-0f-1.
- **Local state:** OwnTone binary + config currently live under the session
  scratchpad (`/private/tmp/claude-501/.../scratchpad/owntone-build/...` and
  `.../scratchpad/ot/`). This path is ephemeral — relocation/rebuild task included.
- **Package constraint:** `AirPlayControllerCore/Package.swift` targets
  `.macOS(.v13)`; taps need 14.4. The capture CLI must be a SEPARATE tool with its
  own `.macOS(.v14)`+ deployment target, not added to the v13 core target.
- **Existing mock/dummy system (Alec added 2026-07-13, commit 5b8521b).** TWO
  independent layers, and neither covers the 0e/0f audio path — important:
  - *In-app `MockBackend`* (`AirPlayControllerCore/Sources/AirPlayControllerCore/MockBackend.swift`)
    implements the `OutputBackend` protocol (`OutputBackend.swift`) with a fabricated
    `[Device]` fleet (`.demoFleet`, `MockBackend.swift:209`): staggered discovery,
    volume/mute/solo, output-set selection, fake RMS level meters, optional
    drop/reconnect. It mocks the **control + discovery + state** layer only — it has
    "no network and no audio … the wire/audio path (by design)" is NOT exercised
    (`dev/README.md:9`). Value type `Device` (id/name/kind/volume/mute/solo/
    selected/available/supportsAirPlay2) is the shared model.
  - *`dev/fake-speakers.sh`* runs a real shairport-sync **AirPlay-1** receiver for
    real `NWBrowser`/Bonjour discovery + AirPlay-1 send-path checks. Single-machine
    limits (verified in-repo): only ONE instance (Homebrew build ignores the RTSP
    port, every instance binds `:5000`), and macOS's own AirPlay Receiver must be
    turned off first. Does NOT do AirPlay-2 PTP or Sonos quirks.
- **Existing backend toggle (compile-time only).** `makeBackend(_ kind:)` in
  `OwnToneBackend.swift:43-48` switches `.mock` ↔ `.ownTone` via a `BackendKind`
  enum; the default is hardcoded `.mock` (`:43`). `OwnToneBackend` is a stub whose
  methods `assertionFailure` (`OwnToneBackend.swift:21-30`). There is currently NO
  runtime/env/config switch and no wiring from any backend to the 0e/0f CLI tools —
  the toggle is one call site in code. This is what T-TOGGLE-1 generalises.

---

## Task list

Legend: model = recommended agent · effort = low/med/high · P? = parallelizable.
"USER-GATED" tasks need Alec physically present (password, TCC dialog, listening).

### T-0d — Per-device volume via OwnTone JSON API  [checkbox]
- Goal: confirm the per-output volume control primitive.
- Steps: start relocated OwnTone; `GET /api/outputs` to list IDs; `PUT /api/outputs/{id}`
  `{"volume": N}` for each of the 3 speakers; confirm audible/independent change.
- Deliverable: one-line PASS note + example curl in SPEC.md §8 0d.
- Deps: T-HK-1 (relocated OwnTone). Parallel with 0e/0f research.
- USER-GATED (listening confirmation, and OwnTone needs root/sudo password).
- Model: haiku · Effort: low · Size: ~15 min. Rationale: single documented API call.

### T-HK-1 — Relocate / rebuild OwnTone out of session scratchpad
- Goal: OwnTone survives session end; stable config in-project (git-ignored).
- Steps: copy the built tree (or `make install` to a prefix) into a durable
  location; rewrite `owntone.conf` paths (db/log/cache/media/library) to that
  location; update `start-owntone.sh`; re-verify Application Firewall allowlist
  applies to the NEW binary path and RESTART after allowlisting (0c lesson);
  smoke-test playback to one speaker.
- Deliverable: durable OwnTone dir + updated start script + note of its path in SPEC.
- Deps: none. Parallel with all research.
- USER-GATED (sudo for root run + firewall allowlist dialog; brief listen).
- Model: sonnet · Effort: med · Size: ~45 min. Rationale: path rewrites + the
  firewall/root gotchas are easy to get subtly wrong; not trivial, not deep.
- DECIDED: lives at `dev/owntone/` in the project, git-ignored (see Resolved
  decisions).

### T-0e-1 — Core Audio taps API research brief
- Goal: a precise, cited implementation brief so the prototype is a transcription,
  not a discovery.
- Steps: read AudioCap sample + Apple docs; pin exact signatures/selectors for
  global tap, per-process tap, exclude-processes, aggregate device creation,
  IOProc block, tap-format ASBD; document TCC (`NSAudioCaptureUsageDescription`,
  prompt timing) and Audio MIDI Setup aggregate-device visibility/cleanup.
- Deliverable: `dev/notes/0e-taps-brief.md` (API + gotchas + permission UX).
- Deps: none. PARALLEL with T-HK-1, T-0f-1, T-0d.
- Model: opus · Effort: med · Size: ~45 min. Rationale: correctness-sensitive
  private-ish API; a wrong signature costs the whole prototype.

### T-0e-2 — Swift capture CLI: global (all-system) tap → PCM file + stdout
**✅ PASSED 2026-07-13.** Built at `dev/audiocap/`, dependency-free. Alec verified
NON-SILENT capture from Terminal (peak 0.36, RMS −30.8 dBFS, 10s, exact byte
count). Observed tap ASBD on this machine: **44.1 kHz** Float32 LE *interleaved*
stereo (rate tracks default output device — never hardcode). TCC: the grant
attaches to the PARENT APP of the CLI (Terminal), prompts don't render from
agent shells — human verification runs happen in Alec's own Terminal, and a
REBUILD RESETS THE GRANT (ad-hoc signing) → every task that edits the CLI ends
with Alec re-running the verify command in Terminal. IOProc gotcha for later
tasks: index the AudioBufferList via `UnsafeMutableAudioBufferListPointer` on
the ORIGINAL pointer — `inInputData.pointee` struct-copy yields nil mData.
- Goal: prove all-system capture; produce the stdout stream 0f needs.
- Steps: new SwiftPM executable `dev/audiocap/` (own `.macOS(.v14)` target, NOT the
  v13 core lib); `initStereoGlobalTapButExcludeProcesses:[]`; aggregate device;
  IOProc; write raw PCM to `--out file.pcm` and/or `--stdout`; print the tap ASBD
  (rate/format/channels) on start; clean teardown (Stop/Destroy, remove aggregate).
- Deliverable: `dev/audiocap/` tool + a captured `.pcm` + documented ASBD.
- Deps: T-0e-1. USER-GATED (first run triggers the TCC audio-capture dialog — Alec
  must approve; note exact dialog wording in the brief). NB: this gate is real
  hardware-free — capture works with ANY Mac audio playing (e.g. a local file);
  no speakers needed, so it can run before the OwnTone/speaker tasks are ready.
- Verify: play a known tone locally, capture, and confirm the `.pcm` plays it back
  correctly (ffplay) at the printed ASBD. (No mock substitutes here — this is the
  capture layer the mock deliberately does NOT cover, per `dev/README.md:9`.)
- Model: opus · Effort: high · Size: ~2–3 h. Rationale: new low-level Core Audio
  code, teardown/lifetime correctness, this is the spike's core risk.

### T-0e-3 — Per-app (single-process) tap variant
**✅ PASSED 2026-07-13.** Alec-verified via the Goertzel tone tests
(dev/notes/0e3-0f2-verify.md steps 1–2): `--pid` captured only the target
process's tone; `--exclude` removed the target from the global tap. Per-app
capture and process exclusion — the foundations of §9 routing and the
"This Mac (don't stream)" bypass — are proven on the real taps API.
- Goal: prove per-app capture (spec §9 routing depends on it) and process-exclude.
- Steps: extend the CLI with `--pid <n>`/`--bundle <id>` (translate to process
  AudioObjectID) for a single-process tap; add `--exclude <pid...>` on the global
  tap; capture e.g. Music/Spotify alone; verify excluded process is absent.
- Deliverable: documented per-app capture + exclude working; note in brief.
- Deps: T-0e-2. USER-GATED (needs the target app playing; reuses TCC grant).
- Model: opus · Effort: med · Size: ~1 h. Rationale: builds on 0e-2 but the
  object-ID lookup + exclude semantics are fiddly and correctness-sensitive.

### T-0f-1 — OwnTone pipe-input format & latency investigation
- Goal: pin the exact byte contract and latency behavior of the pipe input.
- Steps: `mkfifo` inside OwnTone's library dir; feed a known S16LE file (48000 and
  44100) via ffmpeg; confirm autostart/autostop; confirm whether 48 kHz avoids
  resampling; measure pipe buffering/latency; test underrun behavior on write gaps.
- Deliverable: `dev/notes/0f-pipe-brief.md` (exact format, sample-rate decision,
  latency notes, underrun behavior).
- Deps: T-HK-1. PARALLEL with T-0e-* and T-0d.
- USER-GATED lightly (needs OwnTone running to one speaker; brief listen).
- Model: sonnet · Effort: med · Size: ~1 h. Rationale: empirical config work,
  documented API surface, no novel code.

### T-0f-2 — Format-bridge: tap PCM → S16LE pipe writer
**✅ PASSED 2026-07-13.** Full chain verified by Alec via `dev/verify-0f2-e2e.sh`:
30 s system audio → global tap → Float32→S16LE (symmetric ×32767) → FIFO →
OwnTone → fake shairport receiver; receiver-side PCM non-silent (RMS 0.011),
byte-exact rate, 0 ring failures. Config-follows-tap applied
(`pipe_sample_rate = 44100`). Lesson for the app: **exclusion targets resolve
lazily** — a pid is only excludable once it has opened an audio stream (a silent
process can't and needn't be excluded).
- Goal: convert tap output (48k float32, possibly mono) to the pipe's PCM16 and
  write to the FIFO without underruns.
- Steps: in the CLI add `--pipe <fifo>` mode; AVAudioConverter (or manual) float32→
  int16, channel/rate handling per T-0f-1's decision; ring buffer + blocking FIFO
  write; graceful handling when OwnTone isn't draining yet.
- Deliverable: CLI `--pipe` mode; a raw S16LE capture verified with ffplay.
- Verify (hardware-free pre-check, optional): route capture → FIFO → OwnTone → the
  `dev/fake-speakers.sh` shairport AirPlay-1 receiver (SILENT=0) to shake out the
  format/backpressure path on ONE local receiver before touching real speakers.
  This exercises the OwnTone→AirPlay-1 send + the pipe writer, but NOT AirPlay-2
  PTP sync — so it de-risks 0f-3 without weakening it. Real multi-room sync stays
  a 0f-3 human gate.
- Deps: T-0e-2, T-0f-1. Model: opus · Effort: high · Size: ~2 h. Rationale:
  real-time format conversion + backpressure is where glitches/underruns hide.

### T-0f-3 — End-to-end wire-up + latency/stability measurement
**✅ PASSED 2026-07-13** (fake-receiver form per the no-speakers revision).
Alec ran `dev/verify-0f3-soak.sh`: full 10-minute soak, VERDICT: PASS —
stable non-silent stream for the full duration, no underruns flagged, output
stayed selected. Real-multi-room form remains deferred checkpoint 4.
- Goal: THE spike payoff — Mac audio on all 3 speakers in sync, continuously.
- Steps: capture CLI `--pipe` → OwnTone FIFO → select all 3 outputs (0c path) →
  play Spotify/Music; verify sync across rooms; rough stopwatch end-to-end latency;
  run ~10 min for underruns / App-Nap / sleep-wake stability; capture failures.
- Deliverable: PASS/FAIL + latency number + stability log in SPEC.md §8 0f.
- Deps: T-0f-2, T-0d (volume), T-0c (done). USER-GATED HARD (multi-room listening,
  the whole test is human-judged).
- Model: opus · Effort: high · Size: ~1.5 h (+ 10 min live). Rationale: integration
  across every prior piece; diagnosing sync/latency needs judgment.

### T-TOGGLE-1 — System-wide dev toggle: dummy vs real devices
- Goal: ONE switch that selects dummy (mock) vs real (OwnTone) devices everywhere,
  generalising today's compile-time `makeBackend(.mock)` call site into a runtime
  choice — so spike tools and (later) the app all honour the same knob.
- What the toggle actually governs today: which `OutputBackend` the control/state
  layer talks to — `.mock` (`MockBackend`, fabricated fleet) vs `.ownTone`
  (`OwnToneBackend`, currently a stub). It does NOT switch the 0e capture path
  (there is only the real tap; the mock has no audio path by design).
- Steps:
  1. Add a single resolution point in `AirPlayControllerCore`: a
     `BackendKind.resolved` (or `makeBackend()` with no arg) that reads, in order,
     an explicit arg → env var `AIRPLAY_BACKEND` (`mock`|`owntone`) → default
     `.mock`. Keep the enum; this only adds the resolver, so existing callers and
     the 5 `MockBackendTests` stay green.
  2. Honour it in `mock-speakers-demo/main.swift` (replace the hardcoded
     `MockBackend(...)` with the resolver) so the one existing executable proves the
     switch end-to-end headlessly.
  3. Document the knob in `dev/README.md` (env var + values + default) alongside the
     existing two-layer mock explanation.
  4. Scope note in the task doc: the *capture* CLI (`dev/audiocap/`) has no dummy
     mode; the toggle is a backend/output-layer concern. For the spike, "real"
     means OwnTone→speakers; "dummy" means MockBackend (UI/control only). Map to
     future app: the same env/arg becomes a hidden Developer setting (spec §4 seam —
     the app holds an `OutputBackend`, never a concrete type).
- Deliverable: resolver in core + env-var support + updated `mock-speakers-demo` +
  `dev/README.md` note; `swift test` still passes.
- Deps: none (pure `AirPlayControllerCore` work; independent of taps/OwnTone).
  PARALLEL with everything. HOT FILES: `OwnToneBackend.swift` (the resolver lives
  by `makeBackend`) and `mock-speakers-demo/main.swift` — no other task touches
  these, so no contention within this plan.
- Model: sonnet · Effort: low · Size: ~40 min. Rationale: small, well-bounded Swift
  in an existing seam with tests already in place; not correctness-critical to the
  spike, but touches the shared backend factory so not haiku-trivial.
- OPEN QUESTION Q5 (env var vs CLI flag vs config, and whether the spike toggle
  should also gate anything beyond the backend) — see below; recommend env var.

### T-DOC-1 — Update SPEC.md §8 (0d/0e/0f) + Phase-0 close-out
- Goal: fold results into the spec: check boxes, record findings, the 48k-vs-44.1
  decision, TCC UX the user will see, feedback-loop resolution, latency/stability,
  and a one-line pointer to the dev toggle (T-TOGGLE-1) so §4/§9 note the seam.
- Deliverable: edited `SPEC.md` §8; note the OwnTone-relocation path + dev toggle.
- Deps: T-0d, T-0e-3, T-0f-3, T-TOGGLE-1. Model: sonnet · Effort: low · Size: ~30 min.
  Rationale: prose consolidation of verified results.
- HOT FILE: `SPEC.md` (see waves — must not run concurrently with any other SPEC edit).

---

## Waves / parallelization

- **Wave 1 (all parallel):** T-HK-1 · T-0e-1 · **T-TOGGLE-1** · (T-0f-1 starts once
  T-HK-1 gives a running OwnTone). Critical-path seed = T-0e-1. T-TOGGLE-1 is
  pure `AirPlayControllerCore` work, independent of taps/OwnTone/speakers, and
  edits only `OwnToneBackend.swift` + `mock-speakers-demo/main.swift` (untouched by
  any other task) → fully parallel, off the critical path.
- **Wave 2:** T-0d (after T-HK-1) ∥ T-0e-2 (after T-0e-1) ∥ T-0f-1 (after T-HK-1).
  T-0e-2 and T-0f-1 touch different trees → parallel. T-0d needs the same OwnTone
  instance as T-0f-1 — serialize those two on the OwnTone process (or use separate
  runs); flag as a shared-resource (not shared-file) contention. Note T-0e-2 is now
  hardware-free (any local audio + TCC dialog), so it need not wait on OwnTone.
- **Wave 3:** T-0e-3 (after T-0e-2) ∥ start T-0f-2 (after T-0e-2 + T-0f-1). Both
  edit the `dev/audiocap/` CLI → **HOT FILE, serialize** (0e-3 then 0f-2, or one
  agent does both).
- **Wave 4:** T-0f-3 (after T-0f-2 + T-0d).
- **Wave 5:** T-DOC-1 (after 0d, 0e-3, 0f-3, T-TOGGLE-1) — sole editor of SPEC.md.

**Critical path (unchanged):** T-0e-1 → T-0e-2 → T-0f-2 → T-0f-3 → T-DOC-1.
(T-0e-2 and T-0f-2 are the two opus/high risk nodes; everything else, including
T-TOGGLE-1, is slack.)

**Shared-resource / hot-file contentions to respect:**
- `dev/audiocap/` CLI — edited by 0e-2, 0e-3, 0f-2. One owner at a time.
- `OwnToneBackend.swift` + `mock-speakers-demo/main.swift` — edited only by
  T-TOGGLE-1 (its resolver sits beside `makeBackend`). No other task touches them.
- `dev/README.md` — edited only by T-TOGGLE-1 in this plan.
- `SPEC.md` — only T-DOC-1 writes it (0d may tick its own box; keep to one writer).
- OwnTone process/config — T-HK-1, T-0d, T-0f-1, T-0f-3 all drive it. Serialize live use.

---

## Open questions — needs confirmation (new, from the toggle revision)

- **Q5 — Dev-toggle mechanism & reach.** How should the dummy/real switch be
  driven, and should it gate anything beyond the output backend?
  - (a, recommended) **Env var `AIRPLAY_BACKEND=mock|owntone`**, resolved once in
    `AirPlayControllerCore`, default `mock`; scope = the `OutputBackend` only (the
    capture CLI stays real-only, since the mock has no audio path). Cheapest,
    works for headless tools and the future app's hidden Developer setting.
  - (b) A CLI flag (`--backend mock|owntone`) on each executable — explicit but
    must be threaded through every entry point.
  - (c) A config file / `UserDefaults` key — closest to the future app's Developer
    setting, heavier than the spike needs now.
  - Recommendation (a); (a) and (c) can coexist later (env overrides default).

## Resolved decisions (Alec, 2026-07-13)

- **Q1 — OwnTone location: `dev/owntone/` in the project, git-ignored.** OwnTone
  is a lab fixture: the final app vendors extracted *source* (airplay.c,
  libairptp, pair_ap), never the running server, so nothing outside the project
  should depend on it and cleanup is one folder deletion.
- **Q2 — NO BlackHole fallback.** If process taps hit a wall, STOP and reassess
  with Alec — do not validate 0f on a capture mechanism we won't ship. (Agents:
  do not install BlackHole or any virtual driver; a taps failure is a
  stop-and-report condition, not a route-around.)
- **Q3 — Test source app: Spotify if installed, else Music.** Check at T-0e-3
  start; either satisfies the single-process requirement.
- **Q4 — 48 kHz, no resample.** Pipeline runs at the tap's native 48 kHz
  (float32→S16LE conversion only); OwnTone pipe accepts 48 kHz. Add a resampler
  only if a speaker audibly fails at 48 kHz (T-0f-1 verifies).
- **Q5 — Dev toggle: env var, backend-scope only.** `AIRPLAY_BACKEND=mock|owntone`,
  resolved once in `AirPlayControllerCore` (explicit arg → env → default `.mock`).
  Scope is the `OutputBackend` seam only — the capture CLI stays real-only (the
  mock has no audio path by design). Maps onto a future hidden Developer setting.
  NB: `OwnToneBackend` is still a stub that `assertionFailure`s — the toggle task
  builds the switch, not the real backend (that lands in 0f/Phase 1).
- **Q6 — No TV in tests.** The LG TV on the current network is NOT to be used as
  a test output. Tests stay silent/local: mock backend + `dev/fake-speakers.sh`.
- **Q7 — Speakers are gone for now, returning eventually (2026-07-13).** Alec no
  longer has access to the Sonos Moves / AirPort Express — that is WHY the dummy
  setup exists. All real-hardware verification converts to DEFERRED checkpoints
  (below); the 0a–0c results stand as the AirPlay 2/PTP/Sonos/sync evidence.

## Deferred real-hardware checkpoints (when speakers return)

Run before calling v1 done:
1. Audible per-device volume on ≥2 real AirPlay 2 devices (T-0d's original form).
2. Multi-room sync re-verification (walk test, metronome track — 0c procedure).
3. 48 kHz pipeline accepted by real Sonos (Q4 assumption; T-0f-1 can only verify
   against shairport locally).
4. End-to-end latency + 10-min stability on real hardware (T-0f-3's original form).

## Revisions for the no-speakers reality (2026-07-13)

- **T-0d** → API-level only: set distinct volumes per output via
  `PUT /api/outputs/{id}` against the fake shairport receiver + verify OwnTone
  state; note that 0c logs already showed distinct per-device volumes sent to real
  Sonos. Audible confirmation → deferred checkpoint 1. No longer USER-GATED.
- **T-0f-1** → unchanged in substance; the output during pipe tests is the
  shairport fake receiver (audio audible from the Mac itself — no speakers
  needed). macOS AirPlay Receiver must be OFF first (repo note).
- **T-0f-3** → end-to-end = capture → FIFO → OwnTone → fake shairport receiver,
  continuous, latency + 10-min soak. IMPORTANT feedback-loop hazard: shairport
  plays through the Mac's own output while we capture ALL system audio — the
  capture MUST exclude the shairport-sync process (the `...ButExcludeProcesses:`
  selector), which conveniently exercises the exclude feature for real. Sync
  across multiple rooms → deferred checkpoint 2. Still lightly USER-GATED (a
  local listen), no speakers required.
