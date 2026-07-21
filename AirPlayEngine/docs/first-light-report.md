# Gated first-light report — 2026-07-16/17 ✅ PASSED

The extracted engine's first-ever live session against real hardware: **Sonos
Move (192.168.4.38), AirPlay 2, PTP timing — audible, human-confirmed** (full
25 s test tone at −18 dB, LED white, session + teardown observed). This was
"THE moment of truth" deferred in PLAN-PHASE-2.md — it passed after six
hosting-layer bugs were found and fixed. **Not one bug was in the vendored
protocol code**: `sender/airplay.c`, `sender/rtp_common.c`, and
`sender/airplay_events.c` were verified byte-identical to the OwnTone build
that plays this same speaker. Every failure was an application-layer duty
OwnTone's `main()`/player performed that our hosting didn't (or a
probe/wrapper bug). Keep that lesson: **when the engine misbehaves, suspect
the hosting seam first.**

## The six bugs (in discovery order)

1. **`engine.start()` deadlocked ~1 h.** `evthread_use_pthreads()` was never
   called, so cross-thread `event_base_once` could not wake the engine loop
   blocked in `kevent` — enqueued work sat until the 3600 s keep-alive timer.
   Fix: enable evthread before any base exists (`EngineThread.swift`, static
   let) + link `event_pthreads` (Package.swift). Diagnosed via `sample`
   thread stacks (main parked in async runtime, engine idle in kevent).
2. **Every pairing attempt refused** — "Out of memory for verification setup
   context" (misleading). libgcrypt requires the *application* to run
   `gcry_check_version` + `GCRYCTL_INITIALIZATION_FINISHED`; pair_ap only
   checks (`is_initialized`, pair.c). OwnTone's `main()` did it; we didn't.
   Fix: `engine_crypto_init()` in shims/engine_bridge.c, called at start.
3. **Silent NTP fallback → Sonos hangs up.** `ptpd_find_or_bind()` — the ONLY
   privileged step (binds UDP 319/320) — is an app duty (OwnTone `main()` runs
   it as root before dropping privileges); `airplay_init`'s `ptpd_init()` only
   finds/starts an already-bound daemon. Fix: call it in `start()` after
   config apply, non-fatal by design (NTP receivers still work unprivileged).
4. **`addOutput` never resumed — success OR failure.** `AirPlayTypes.swift`
   classified `.connected` non-terminal, but CONNECTED is the single terminal
   success callback for `device_start` (STREAMING deliberately fires no cb —
   `// Make a cb?` in `airplay_write`; the contract doc always said CONNECTED
   is terminal). The discarded completion also spent `callback_id`, so the
   later failure path (`outputs_cb(-1, …)`) was a defensive no-op → both paths
   hung. One-line fix + 4 regression tests.
5. **Frozen write timestamp.** The probe read `CLOCK_MONOTONIC` once and
   stamped every chunk with it; `timestamp_set()` stores pts as "the player
   clock … normally now" and periodic sync packets re-anchor RTP position ↔
   that time. A frozen pts claims advancing audio plays at a receding past →
   receiver keeps the session, schedules nothing. Fix: calculated advancing
   pts (t0 + samples/rate) + absolute-deadline pacing (engine-probe).
6. **Volume pinned to the −30 dB floor** (the final "zero audio"). The Swift
   wrapper scaled volume by `device->max_volume` — a field the AirPlay 2
   backend never reads and the engine never initializes (calloc → 0), so
   `device->volume` was always 0 → `airplay_volume_from_pct(0)` = −30 dB =
   inaudible on a Sonos, LED green-never-white, volume buttons dead. The
   vendored contract is `volume ∈ [0-100]` percent (airplay.c:1873). Fix:
   map normalized 0…1 → 0…100 directly (`applyVolumeOnDevice`); the old unit
   test had encoded the bug and was corrected. Forensic clearance that
   isolated it: ALAC shim round-trip (250/250 packets decode, 440 Hz Goertzel
   spike >400× neighbors), RTP path (2999/2999 packets sent, 0 errors, AEAD
   ciphertext round-trips through libsodium's reference decoder), config
   defaults matched, PTP healthy (our Announce p1=128/class=6 wins BMCA over
   Sonos p1=250/class=248; its 200+ DelayReqs = it slaves to us).

## Operational gotchas (bake into the app installer/runbook)

- **Firewall must allowlist the binary BEFORE it binds** (`socketfilterfw
  --add` + `--unblockapp`); verdicts stick to already-bound sockets (Phase-0
  lesson, reconfirmed). A transient first-send EPERM burst (~19 sends, self-
  healing) was observed once and is UNEXPLAINED — likely firewall-verdict
  timing or launch-path hygiene, NOT TCC (root daemons are exempt from Local
  Network privacy). Reproduce under controlled conditions before shipping.
- libairptp per-packet tx/rx logging is compiled out by default; the hard
  `#define 0`s were made `#ifndef`-guarded ([vendored change, MIT] —
  ptp_msg_handle.c) so `-DAIRPTP_LOG_SENT=1 -DAIRPTP_LOG_RECEIVED=1` work
  (currently ON in Package.swift for bring-up).
- Logger: `AIRPLAYENGINE_LOG_LEVEL` (E_INFO=3, E_DBG=4, E_SPAM=5),
  `AIRPLAYENGINE_LOG_STDERR=1` mirrors info/debug to stderr. stdout is
  block-buffered under a pipe — run the probe under `script(1)` for live
  output.

## Known follow-ups (ranked; none block first light)

**Status update, Phase 2b (2026-07-17): all six items below are FIXED.** See
`PLAN-PHASE-2B.md` D3 ("fix ALL of it") and the T-ENG-* task reports. None of
the fixes required a vendored-C change — see `docs/VENDORED-DIFFS.md`'s
"Phase 2b engine hardening tasks" audit table for the per-item disposition.

1. ~~**Teardown SIGABRT (exit 134)** at "Stopping airptp event loop" on
   `engine.stop()` after streaming.~~ **FIXED (T-ENG-SIGABRT-1).**
   Root-caused to a double `ptpd_deinit()` — the vendored `airplay_deinit()`
   already tears down the PTP daemon, and the hosting `stop()` path called it
   a second time for symmetry with the hosting-added `ptpd_find_or_bind()` in
   `start()`. `airptp_end()` frees the handle but doesn't null the caller's
   pointer, so the second call re-entered `daemon_stop()` and
   `pthread_join()`'d an already-joined thread → abort. Fixed by making
   `shims/ptpd.c`'s `ptpd_deinit()` idempotent (nulls `ptpd_hdl` after
   `airptp_end()`, so repeat calls are clean no-ops).
2. ~~**SIGPIPE unprotected**: no `SIG_IGN`/`SO_NOSIGPIPE`/`MSG_NOSIGNAL`
   anywhere; a receiver-closed socket during a send could kill the
   process.~~ **FIXED (T-ENG-SIGPIPE-1).** `engine_mask_sigpipe()`
   (`shims/engine_bridge.c`) sets `SIGPIPE` to `SIG_IGN` process-wide,
   mirroring OwnTone `main.c:718-732`; called from `AirPlayEngine.start()`
   before any socket opens.
3. ~~**No post-CONNECTED device callback**: session failures after
   `addOutput` resolves are silently swallowed.~~ **FIXED
   (T-ENG-STATESTREAM-1).** `makeStateStream() -> AsyncStream<(OutputID,
   OutputState)>` on `AirPlayEngine` fans out every `outputs_cb` report,
   including out-of-band post-terminal ones the dispatcher used to drop once
   `callback_id` was spent. `NativeBackend` (T-NB-BACKEND-1) subscribes this
   instead of polling.
4. ~~**No write-cadence deficit/overrun detection**.~~ **FIXED
   (T-ENG-CADENCE-1).** `writeCadenceSnapshot() -> WriteCadenceSnapshot` on
   `AirPlayEngine` tracks cumulative deficit/overrun seconds and the last
   per-write gap against `CLOCK_MONOTONIC_RAW`, allocation-free on the hot
   `write(pcm:pts:)` path; diagnostic only, never gates a write.
5. ~~Hardening backlog from the 2026-07-17 hosting-delta audit.~~ **FIXED**,
   split across two tasks:
   - **libhash per-install seed collision — FIXED (T-ENG-LIBHASH-1).**
     `EngineConfig.installSeed` (defaults to a fresh random value per
     construction) is mixed into `hashClientName`'s FNV-1a input, so two
     installs with the same client name no longer collide on AirPlay device
     id / PTP clock-id. Caveat recorded in that task's notes: the random
     default only prevents collisions between concurrently-constructed
     engines in one process — persisting a stable per-install seed across
     relaunches is app-level work, not yet done.
   - **Remaining items (ipv6 default, loud config misses, gcry version
     floor, libevent log hook, start/stop idempotency, `device_flush`
     seam) — FIXED (T-ENG-HARDEN-1).** `general.ipv6` shim default flipped
     to off (Swift `EngineConfig` still re-enables it via
     `conffile_set_ipv6`); `event_set_log_callback` wired to the logger shim
     (`engine_logger_wire_libevent()`); conffile unknown-key lookups now log
     at `E_WARN` + `assert()` in debug; `engine_crypto_init` passes a real
     `1.8.0` min-version floor to `gcry_check_version` instead of `NULL`;
     `addOutput`/`removeOutput` are now idempotent (no-op on an
     already-active/already-stopped output); `flushOutput(_:)` added as an
     explicit no-op seam for a future pause/seek primitive (validates
     started + known-output, does not yet issue `device_flush`).

## What's next

Phase 2b (`PLAN-PHASE-2B.md`) picked up immediately after this report and is
now complete: `NativeBackend : OutputBackend` (in-process engine + app-owned
`NativeDiscovery` over both `_airplay._tcp`/`_raop._tcp`), an in-process Core
Audio process-tap capture path (`NativeCaptureCoordinator`), and the
`AIRPLAY_BACKEND=native` resolver wiring. AP1-only device rows originally
shipped dimmed/disabled with a "coming soon" explanation (D6); that gate has
since been retired (see the AP1 (RAOP) first light section below) — AP1
receivers are now driven through the same engine as AP2. See
`dev/notes/p2b-nativebackend-runbook.md` for how to run it and the gated
live-verification checklist (D7) — that gated session (multi-room 2-output
sync, native end-to-end on a real speaker, volume A/B, real-fleet discovery
watch, teardown stress) is the one piece of Phase 2b that still requires
ahh present with real hardware; everything else is headless-verified.

Deferred beyond Phase 2b (see the roadmap briefs in `dev/notes/p2b-*.md`,
indexed in `dev/AGENTS.md`): multistream `stream_id` design for per-app
routing (`p2b-multistream-brief.md`); synced local output
(`p2b-synced-local-brief.md`); SMAppService helper productionization —
requires a paid Developer ID cert for the sanctioned install path
(`p2b-helper-productionization-brief.md`).

## AP1 (RAOP) first light — pending

The AP1 (`raop.c`) sender port and its engine-side wiring (T1/T3–T9; see
`docs/raop-seam-brief.md` and `docs/VENDORED-DIFFS.md` Entry 3) are complete
and headless-verified — `output_raop` compiles, links, and dispatches
alongside `output_airplay`, and `NativeBackend` now drives AP1 receivers
exactly like AP2 ones. What this report's AP2 first light gave AP2 (a
human-confirmed, by-ear session against real hardware) AP1 has not yet had:
no gated live test against a real classic-AirPlay (RAOP) receiver has been
run. This section is a placeholder for that result — fill in the date,
receiver, and outcome (pass/fail, any hosting-layer bugs found, by analogy
with the six AP2 bugs above) once ahh runs it.
