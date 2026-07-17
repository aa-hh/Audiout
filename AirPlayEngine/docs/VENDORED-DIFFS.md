# Vendored-source diffs ledger

Per `PLAN-PHASE-2B.md` D5: vendored OwnTone C (everything under
`Sources/CAirPlayEngine/` **except** `shims/`) stays byte-identical unless a
fix genuinely cannot live in a shim or the hosting layer. When that escape
hatch is used, the diff must be minimal, keep the original license header
intact, and be recorded here: file, license, rationale, exact hunk.

This ledger is built directly from `git log`/`git diff` over the vendored
directories (`sender/`, `evrtsp/`, `pair_ap/`, `libairptp/`) — **not** from
memory or task summaries. As of this writing (`git status` on this worktree,
2026-07-17) there are **no uncommitted changes** under those directories, and
`git log` shows exactly one historical commit that touched vendored source:
`99209de` ("Engine first light PASSED"), which contains the single entry
below. Every Phase 2b engine task (STATESTREAM, SIGABRT, SIGPIPE, CADENCE,
LIBHASH, HARDEN) stayed entirely inside `shims/` or `Sources/AirPlayEngine/`
— confirmed via `git status --short AirPlayEngine/Sources/CAirPlayEngine/`
excluding `shims/`, which is empty. **Total vendored diffs to date: 1.**

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
