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

1. **Teardown SIGABRT (exit 134)** at "Stopping airptp event loop" on
   `engine.stop()` after streaming — pre-existing, does not affect playback.
2. **SIGPIPE unprotected**: no `SIG_IGN`/`SO_NOSIGPIPE`/`MSG_NOSIGNAL`
   anywhere; a receiver-closed socket during a send could kill the process
   (OwnTone masks SIGPIPE on all non-main threads, main.c:718-732).
3. **No post-CONNECTED device callback**: session failures after `addOutput`
   resolves are silently swallowed (`callback_id` spent). NativeBackend needs
   an async state channel — see dev/notes/p2b-nativebackend-seam-brief.md.
4. **No write-cadence deficit/overrun detection** (OwnTone player.c
   pb_write_deficit_max model absent) — diagnostic/robustness gap.
5. Hardening backlog from the 2026-07-17 hosting-delta audit: `libhash` is a
   fixed constant (every install advertises the same AirPlay device id + PTP
   clock-id seed — two machines on one LAN collide); `general.ipv6` shim
   default = on vs OwnTone off; `event_set_log_callback` not wired; conffile
   shim silently returns 0/NULL for unknown keys; `gcry_check_version(NULL)`
   skips min-version enforcement; device_start/stop idempotency guards;
   `device_flush` primitive (needed for pause/seek).

## What's next (see dev/notes/p2b-*.md briefs, written 2026-07-17)

Multi-room sync checkpoint (extend the probe to 2+ outputs — speakers are
back); then T-BACKEND-1 NativeBackend (seam brief has the 10-step checklist);
multistream `stream_id` design for per-app routing (p2b-multistream-brief);
synced local output (p2b-synced-local-brief); SMAppService helper
productionization — NB: requires a paid Developer ID cert for the sanctioned
install path (p2b-helper-productionization-brief).
