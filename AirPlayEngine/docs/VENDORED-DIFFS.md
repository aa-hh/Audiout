# Vendored-source diffs ledger

Per `PLAN-PHASE-2B.md` D5: vendored OwnTone C (everything under
`Sources/CAirPlayEngine/` **except** `shims/`) stays byte-identical unless a
fix genuinely cannot live in a shim or the hosting layer. When that escape
hatch is used, the diff must be minimal, keep the original license header
intact, and be recorded here: file, license, rationale, exact hunk.

This ledger is built directly from `git log`/`git diff` over the vendored
directories (`sender/`, `evrtsp/`, `pair_ap/`, `libairptp/`) — **not** from
memory or task summaries. `git log` shows exactly two changes that touched
vendored source: `99209de` ("Engine first light PASSED"), Entry 1 below, and
the P2b/T1 multi-stream `stream_id` change (Entry 2, on branch
`claude/per-app-routing-engine-73f40c`, 2026-07-17), which is the only
uncommitted vendored change in this worktree at time of writing. Every Phase 2b
engine task (STATESTREAM, SIGABRT, SIGPIPE, CADENCE, LIBHASH, HARDEN) stayed
entirely inside `shims/` or `Sources/AirPlayEngine/`. **Total vendored diffs to
date: 2.** (Note: the sibling `stream_id` additions to `shims/outputs.h` and
`shims/engine_bridge.h` are in `shims/`, which is engine-owned code, NOT the
byte-identical vendored set — so they are documented in Entry 2 for context but
do not themselves count as vendored diffs.)

How to keep this ledger honest going forward: before adding an entry, run

```
git status --short AirPlayEngine/Sources/CAirPlayEngine/ | grep -v '/shims/'
```

against the working tree, and/or `git log -- <path>` for a merged change. If
it's empty, there's nothing to ledger yet.

---

## Entry 1 — `libairptp/src/ptp_msg_handle.c`: `#ifndef`-guard the packet-logging switches

- **File**: `AirPlayEngine/Sources/CAirPlayEngine/libairptp/src/ptp_msg_handle.c`
- **License**: MIT (`AirPlayEngine/Sources/CAirPlayEngine/libairptp/LICENSE`)
- **Landed in**: commit `99209de` ("Engine first light PASSED: six hosting
  fixes, forensic clearance, roadmap briefs"), predates Phase 2b.
- **Rationale**: Upstream hard-codes the per-packet tx/rx debug switches as
  `#define AIRPTP_LOG_RECEIVED 0` / `#define AIRPTP_LOG_SENT 0` with no
  guard, which silently clobbers any `-DAIRPTP_LOG_SENT=1`
  `-DAIRPTP_LOG_RECEIVED=1` passed on the compiler command line — the build
  system (`Package.swift`'s `.define(...)` C settings, used during PTP
  bring-up/debugging) had no way to turn this logging on. Wrapping each
  `#define` in an `#ifndef` is the standard C idiom for "compiler flag wins
  if provided, else this default" and does not change behavior for anyone
  who doesn't pass the flag — this is why the shim/hosting layer couldn't
  absorb it: the macro guard has to live at the exact point upstream defines
  the constant, inside the vendored file itself.
- **Exact hunk** (as it stands in the tree today; see the inline
  `[AirPlayEngine vendored change 2026-07-16]` comment left in the file for
  provenance):

  ```c
  // Debugging
  // [AirPlayEngine vendored change 2026-07-16] #ifndef-guarded so the build can
  // enable per-packet logging via -DAIRPTP_LOG_SENT=1 etc. (Package.swift);
  // upstream hard-coded 0 which silently clobbered the build flag.
  #ifndef AIRPTP_LOG_RECEIVED
  #define AIRPTP_LOG_RECEIVED 0
  #endif
  #ifndef AIRPTP_LOG_SENT
  #define AIRPTP_LOG_SENT 0
  #endif
  ```

  Upstream (OwnTone's vendored libairptp, pre-change) had simply:

  ```c
  // Debugging
  #define AIRPTP_LOG_RECEIVED 0
  #define AIRPTP_LOG_SENT 0
  ```

- **Where the flag is actually set**: `AirPlayEngine/Package.swift`, C target
  settings for the `libairptp` sources —
  `.define("AIRPTP_LOG_SENT", to: "1")`, `.define("AIRPTP_LOG_RECEIVED", to: "1")`
  (currently ON, for bring-up; flip off for a quieter production build —
  the `#ifndef` guard means simply removing those two `.define`s reverts to
  upstream's silent default of `0`, no source edit needed).

---

## Entry 2 — `sender/airplay.c`: add a `stream_id` dimension for multi-stream per-app routing (P2b / T1)

- **File**: `AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c`
- **License**: GPL-2.0-or-later (`AirPlayEngine/Sources/CAirPlayEngine/sender/`)
- **Landed in**: branch `claude/per-app-routing-engine-73f40c`, 2026-07-17
  (P2b multi-stream sender surgery, design brief
  `dev/notes/p2b-multistream-brief.md` §4).
- **Rationale**: The sender's entire fan-out was keyed on audio *quality* with
  no stream identity, so `master_session_make` deduplicated every device onto a
  single master session and every AirPlay speaker received byte-identical audio
  (the documented "route one app, whole-Mac mix streams" bug). Per-app routing
  needs N independent-content streams to coexist. This is the option-(b) surgery
  from the brief: add a `uint32_t stream_id` so the master-session cache key
  becomes `(stream_id, quality, use_ptp)` and the write fan-out matches on
  stream_id in addition to quality. This *cannot* live in a shim: the cache
  dedup loop, the master-session struct, the session struct, and the
  `airplay_write` fan-out are all inside the vendored file, reaching static
  types and the static `airplay_master_sessions` list. It also *cannot* be
  faked by overloading `quality` (the brief §1.4 rejects that: quality feeds the
  ALAC/RTP math and only a couple of AP2 qualities are valid). `stream_id`
  defaults to 0 everywhere, so the pre-change single-stream path is unchanged.
- **Exact changes** (each marked in-file with a dated
  `[AirPlayEngine vendored change 2026-07-17]` comment):
  1. `struct airplay_master_session`: added `uint32_t stream_id;`.
  2. `struct airplay_session`: added `uint32_t stream_id;`.
  3. `master_session_make`: signature gained a leading `uint32_t stream_id`
     parameter; the reuse-cache loop now also requires `ams->stream_id ==
     stream_id`; the new master session stores `ams->stream_id = stream_id`.
  4. `session_make`: sets `session->stream_id = device->stream_id` and passes it
     to `master_session_make` (the only caller).
  5. `airplay_write` fan-out: skips a PCM blob unless
     `obuf->data[i].stream_id == ams->stream_id` **in addition to** the existing
     `quality_is_equal` check. This is the critical cross-talk guard.
  6. The two send loops (`packets_send`, `packets_sync_send`): **no code
     change** — they match on `session->master_session` pointer identity, which
     is strictly stronger than a stream_id compare (a session bound to `ams`
     necessarily carries `ams->stream_id`). A clarifying comment records this
     audit so the four W1 fan-out sites read as coherent.
  7. Test/diagnostic seam: five non-static `airplay_test_master_session_*`
     accessors (make/stream_id/input_buffer_samples/count/reset) so the
     headless `MultiStreamMasterSessionTests` and (T2)
     `MultiStreamWriteRoutingTests` can observe otherwise-static
     master-session identity and fan-out state. Not reachable from any
     shipping path. `input_buffer_samples` was added in T2 (still 2026-07-17)
     alongside the Swift `AirPlayEngine.write(pcm:streamId:pts:)` /
     `write(streams:pts:)` API, so a headless test can prove NO CROSS-TALK end
     to end (Swift API -> C fan-out -> per-stream master session), not just at
     the C `master_session_make` level the original four accessors cover.
- **Sibling shim edits (NOT vendored, listed for context)**: `shims/outputs.h`
  gained `uint32_t stream_id` on `struct output_device` and `struct
  output_data`; `shims/engine_bridge.h` declares the five test-seam
  prototypes. These files are engine-owned `shims/` code, outside the
  byte-identical set.
- **Verification**: `swift build` clean; `swift test` 101/101 pass (was 98,
  +3 new multi-stream tests) as of T1; see T2's own report for the post-T2
  count. The stream_id-0 path is behaviorally unchanged (all pre-existing
  tests still pass).

---

## Phase 2b engine hardening tasks — vendored-dir touch audit

For the record, every Phase 2b engine task explicitly checked whether it
needed a vendored change and, per each task's own report, did not:

| Task | Backlog item | Where the fix landed | Vendored diff? |
|---|---|---|---|
| T-ENG-STATESTREAM-1 | #3 post-CONNECTED state stream | `shims/outputs.c`/`.h` + `AirPlayEngine.swift` | No |
| T-ENG-SIGABRT-1 | #1 teardown SIGABRT | `shims/ptpd.c` (idempotent `ptpd_deinit`) | No — considered vendored `daemon.c`/`airptp.c` per the plan's file list, root-caused to a hosting-side double-teardown instead |
| T-ENG-SIGPIPE-1 | #2 SIGPIPE unprotected | `shims/engine_bridge.c`/`.h` | No |
| T-ENG-CADENCE-1 | #4 write-cadence deficit/overrun | `AirPlayEngine.swift`/`AirPlayTypes.swift` | No |
| T-ENG-LIBHASH-1 | #5.1 libhash per-install seed | `AirPlayEngine.swift` | No |
| T-ENG-HARDEN-1 | #5.2–7 remaining hardening | `shims/conffile.c`/`.h`, `shims/engine_bridge.c`, `shims/logger.c`/`.h`, `AirPlayEngine.swift` | No |

No new entries were added to this ledger by Phase 2b. If a future task
genuinely cannot avoid touching `sender/`, `evrtsp/`, `pair_ap/`, or
`libairptp/` (outside the one seed entry above), add a numbered entry here
following the same format: file, license, rationale, exact hunk, and update
the "Total vendored diffs to date" count at the top of this file.
