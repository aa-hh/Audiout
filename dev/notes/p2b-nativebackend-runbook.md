# Phase 2b — NativeBackend runbook

How to build/run the native backend headlessly, how to grant it the in-app
TCC permission it needs (system-audio-recording, for the Core Audio process
tap), and the D7 gated-session checklist from `PLAN-PHASE-2B.md` for the one
piece of Phase 2b that needs ahh present with real hardware.

Companion docs: `AirPlayEngine/docs/first-light-report.md` (the engine's own
gated live-test, six hosting bugs found+fixed, all now closed by Phase 2b),
`AirPlayEngine/README.md` (engine package status), `dev/README.md`
(`AIRPLAY_BACKEND` toggle reference), `dev/notes/p2b-nativebackend-seam-brief.md`
(the design brief `NativeBackend` was built from).

---

## 1. What "native" means

`AIRPLAY_BACKEND` (resolved in `OwnToneBackend.swift`'s `resolved()`) now has
three values:

| Value | Backend | Talks to |
|---|---|---|
| `mock` (default) | `MockBackend` | Nothing — fabricated fleet, offline UI dev |
| `owntone` | `OwnToneBackend` | An external OwnTone server process over HTTP/JSON |
| `native` | `NativeBackend` | **In-process** `AirPlayEngine` actor (the vendored+shimmed AirPlay 2 sender) + app-owned `NativeDiscovery` (NWBrowser) + app-owned `NativeCaptureCoordinator` (in-process Core Audio process tap) |

`native` is the only path with **no external process dependency** — no
OwnTone server, no `owntone.conf`, no pipe. Everything (discovery, session
management, PTP, audio capture) runs inside the app's own process.

## 2. Headless build + test (no hardware, no TCC)

Both packages build and test fully offline — the native path's *code* is
hermetically testable even though *running a live session* obviously needs
real network + a receiver + the TCC grant.

```bash
# Engine package (vendored AirPlay 2 sender + shims + Swift wrapper)
cd AirPlayEngine
swift build
swift test              # 61 tests as of 2026-07-17, 0 failures expected

# Core package (Device model, backends incl. NativeBackend/NativeDiscovery/
# NativeCaptureCoordinator, UI targets)
cd ../AudioutCore
swift build
swift test               # 164 tests as of 2026-07-17, 0 failures expected
```

If `CaptureCoordinatorTests.testCaptureCrashOverBudgetSurfacesError` is the
**only** failure, it's a known load-flaky test (documented in
`PLAN-PHASE-2B.md`'s standing constraints) — re-run it in isolation:

```bash
swift test --package-path AudioutCore \
  --filter CaptureCoordinatorTests/testCaptureCrashOverBudgetSurfacesError
```

`NativeBackendTests`, `NativeDiscoveryTests`, `NativeCaptureCoordinatorTests`,
and `DeviceRowUnsupportedTests` are all hermetic (spy engine / injected
`ServiceBrowsing` / injected tap+engine doubles — no TCC, no network, no
hardware). `NativeDiscoveryLiveTests.swift` is the sole exception: it's
env-gated behind `AIRPLAY_LIVE_DISCOVERY=1` and is a **passive Bonjour scan
only** (no root, no PTP, no audio) — safe to run against the real LAN per the
D7 exception in `PLAN-PHASE-2B.md`, but skipped by default.

`engine-probe` (in `AirPlayEngine`) similarly refuses to open a socket
without an explicit flag — see `AirPlayEngine/README.md`'s "Running a live
session (gated)" section. Running it with no flag just prints its plan and
exits 0 (this is what CI/headless verification exercises).

## 3. Running the real app on `native` (in-app TCC grant flow)

The native capture path (`NativeCaptureCoordinator` → `CATapDescription` /
`AudioHardwareCreateProcessTap`, macOS 14.4+) needs the **system audio
recording** TCC permission (the same "Screen & System Audio Recording" /
audio-capture bucket the OS gates process taps behind, distinct from
microphone access). This permission is granted **per bundle identity** and
**sticks across `swift run` invocations only if the binary's identity is
stable** — a bare `swift run` produces a differently-signed binary path each
build in some configurations, which can make TCC re-prompt or silently deny.
Use the stable `.app` bundle path instead:

```bash
# From the repo root:
scripts/make-app.sh                 # → ./build/Audiout.app
open "./build/Audiout.app"
```

`scripts/make-app.sh` (documented in its own header comment) builds the
`AudioutApp` executable in release config, wraps it in a real
`.app` bundle with a stable `CFBundleIdentifier`
(`com.audiout.Audiout`) and `LSUIElement=true` (menu-bar-only,
no Dock icon), and ad-hoc codesigns it. Because the bundle id and signature
are stable across rebuilds (same script, same output path), macOS remembers
the TCC grant between runs — rebuild with `scripts/make-app.sh` again after
code changes and re-`open` the same `.app` path; you should not be
re-prompted.

**First launch on `native`:**

1. Ensure OwnTone (or any other process holding UDP 319/320) is **stopped** —
   the AirPlay 2 PTP clock needs those ports exclusively (see
   `AirPlayEngine/docs/first-light-report.md`'s operational gotchas and §5
   below).
2. **Launch via `open` — NEVER by running the binary directly from a shell.**
   TCC attributes the system-audio grant to the RESPONSIBLE PROCESS: a binary
   exec'd from a terminal (or an agent's shell tool) inherits the terminal's
   TCC identity, the app never appears in System Settings at all, and whether
   capture works silently depends on the terminal's own grant (2026-07-17b
   live session: an hour lost to exactly this). Since `open` does not forward
   shell env vars, set them session-wide first:
   `launchctl setenv AIRPLAY_BACKEND native`, then
   `open "./build/Audiout.app"` (add
   `--stderr /path/to/log` to keep capturing the app's stderr log).
   Unset with `launchctl unsetenv` when done.
3. On first Core Audio tap creation, macOS prompts for the system-audio
   recording permission — grant it. The app then appears in **System
   Settings ▸ Privacy & Security ▸ Screen & System Audio Recording**, in the
   **"System Audio Recording Only"** section at the bottom (the process tap is
   the audio-only TCC class; the app is NOT listed among the full
   screen-recording apps above it). Local Network privacy governs discovery
   separately.
4. Confirm the firewall allowlists the binary **before** it binds any socket
   — verdicts stick to already-bound sockets (Phase 0 + first-light lesson,
   `first-light-report.md` "Operational gotchas"). Use
   `socketfilterfw --add` + `--unblockapp` against the `.app`'s executable
   path if macOS doesn't auto-prompt.

**A stale/denied grant does NOT error.** A TCC-denied tap returns `noErr` and
delivers all-zero buffers: the session connects, PTP syncs, the popover looks
perfect, and the speaker plays silence. Every rebuild re-signs the ad-hoc
bundle and can silently stale the grant — after any rebuild, expect a fresh
prompt (or toggle the app off/on in the TCC pane). To tell "capturing audio"
from "capturing zeros" in one look, launch with `AIRPLAY_DEBUG_LEVELS=1`:
`AppDelegate` then logs the capture RMS ~1/s (`level: <id> rms 0.18…` = real
audio; a flat `rms 0.0` under playing audio = denied tap).

If capture fails with an ACTUAL error (`NativeCaptureError` — see
`NativeCaptureCoordinator.swift`'s doc comments on `tapCreationFailed`), the
permission was likely granted to a *different* signed identity than the one
currently running — rebuild via `scripts/make-app.sh` (same path, same
identity) rather than a fresh `swift run`.

## 4. What NativeBackend actually does (quick orientation)

- `NativeBackend(engine: AirPlayEngine, discovery: NativeDiscovery = NativeDiscovery())`
  — `start()` feeds AP2 descriptors from `NativeDiscovery` into
  `engine.updateDiscovery` and subscribes `engine.makeStateStream()` (push,
  no polling) for `deviceAdded`/`deviceUpdated` events.
- AP1-only devices (raop-only, or no AP2 features bit — `NativeDiscovery`'s
  classification) are surfaced as `deviceAdded` with `supportsAirPlay2 =
  false`, `isAvailable = false`, and are **never** `addOutput`-ed on the
  engine — this is D6 ("AP1 devices are discovered and shown" but not yet
  driven; the raop sender is deferred). The popover renders them dimmed with
  a "coming soon" explanation (`DeviceRowView`/`PopoverController`,
  `T-UI-AP1-1`).
- `setOutputSet` is diff-and-converge against the engine's per-device
  `addOutput`/`removeOutput` primitives (no atomic bulk-set exists in the
  engine, unlike OwnTone's `PUT /api/outputs/set`). Partial failure policy is
  **best-effort, no rollback** (D4): apply what succeeds, mark the failed
  device unavailable, emit `deviceUpdated`.
- `NativeCaptureCoordinator` owns the in-process Core Audio process tap
  (D2 — no `audiocap` subprocess, no IPC) and calls `engine.write(pcm:pts:)`
  on the hot path, with pts taken directly off the IOProc's
  `AudioTimeStamp.mHostTime`.
- `captureCoordinator` is set on the `NativeBackend` instance separately from
  construction (mirrors `OwnToneBackend.captureCoordinator`) — see the
  `.native` case in `OwnToneBackend.swift`'s `makeBackend` for the exact
  wiring order (`engine` → `NativeBackend(engine:)` →
  `NativeCaptureCoordinator(engine:)` → assign to `.captureCoordinator`).

## 5. D7 gated-session checklist

Per `PLAN-PHASE-2B.md`'s "Gated session checklist" — **one batched,
user-present session, ahh at the keyboard with real speakers on the LAN.**
Everything else in Phase 2b was verified headlessly; this is the one
live-hardware step left. Do NOT run PTP/live streaming outside this session
(passive Bonjour *discovery* scans are the sole standing exception, already
covered by `NativeDiscoveryLiveTests` / `AIRPLAY_LIVE_DISCOVERY=1`).

**Before starting:**

- [ ] Stop OwnTone (and any other process holding UDP 319/320).
- [ ] Firewall allowlist per `first-light-report.md`'s operational-gotchas
      section (allowlist BEFORE the binary binds a socket).
- [ ] Fake speaker (`dev/fake-speakers.sh`, shairport-sync, AirPlay 1) ready
      to start for step 5 — **one instance max** (see `dev/README.md`'s
      single-instance limitation).

**Session steps:**

1. **Multi-room sync.** `engine-probe` with two `--address`/`--device-id`
   pairs (Sonos Move + Move 2) — `--i-have-a-receiver-and-owntone-is-stopped`
   required to actually stream (see `AirPlayEngine/README.md`). Confirm sync
   by ear.
2. **`AIRPLAY_BACKEND=native` end-to-end.** Real app (via `scripts/make-app.sh`,
   §3 above), real speaker, TCC already granted or grant it now. Confirm
   audio, confirm the popover shows the device and its state transitions.
3. **Volume-curve A/B vs OwnTone.** Perceptual check — same speaker, same
   nominal volume, `native` vs `owntone` backend, listen for a mismatch (the
   engine maps normalized 0…1 straight to the device's 0–100 percent scale;
   `first-light-report.md` bug #6 is the cautionary tale here).
4. **Real-fleet discovery watch.** Start `dev/fake-speakers.sh` to get a
   genuine AP1-only advertisement; confirm it appears in the popover
   **dimmed/disabled** with the "AirPlay 1 support is coming soon"
   explanation on click (never as a live output). Confirm the LG TV, if it
   appears in the scan, is listed but never targeted as an output. Stop the
   fake speaker when done.
5. **Teardown stress.** Repeated start/stop cycles — confirm no SIGABRT
   (T-ENG-SIGABRT-1's fix). Force-drop a receiver mid-stream (e.g. power it
   off) — confirm no SIGPIPE death (T-ENG-SIGPIPE-1's fix); the app should
   surface a `deviceUpdated`/failed state via `makeStateStream`, not crash.
6. **Latency re-verify (2026-07-17 follow-up, UI shipped 2026-07-17).** The
   native path now defaults to a 1000 ms sender start buffer (was effectively
   2250; measured ~3.5 s click-to-sound → expected ~2.2 s), and it's now a
   user-facing setting (Settings › Audio › Advanced "Audio buffer": 1000 /
   1500 / 2250 ms, Apply & Reconnect CTA). Run the by-ear checklist in
   `AirPlayEngine/docs/latency-analysis.md` — baseline vs default, the
   Settings apply-flow round trip (multi-room, in-sync resume), and the
   optional below-floor sweep. Knobs: `AIRPLAY_START_BUFFER_MS` (300…5000,
   overrides the UI), `AIRPLAY_DEBUG_LATENCY=1` (probe lines on stderr/os_log).

**After the session:** update `AirPlayEngine/docs/first-light-report.md`'s
"What's next" section (or a new dated addendum) with the outcome — pass/fail
per step, any new bugs found, in the same forensic style as the original
first-light bug list.
