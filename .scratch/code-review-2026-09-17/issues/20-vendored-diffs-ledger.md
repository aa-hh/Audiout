# 20 — AirPlayEngine: ledger the four unrecorded vendored edits

Status: ready-for-agent
Wave: 4
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings engine #5, engine #6

Four vendored files carry local edits `VENDORED-DIFFS.md` does not record; shim headers still announce STUB STATUS.

## Done when

Every local hunk in `sender/`, `pair_ap/`, `evrtsp/`, `libairptp/` appears in the ledger with licence, rationale and hunk; the STUB STATUS banners are replaced by one line stating the shim is the real implementation. No code changes.

## Test seam

none (docs); `git diff` against upstream per the ledger's own method

## Verification

```bash
grep -c '^## ' AirPlayEngine/docs/VENDORED-DIFFS.md
```

## Findings (verbatim from the area reports)

### 5. [SUBSTANCE] Four vendored files carry local edits that `VENDORED-DIFFS.md` does not record
- Where: `AirPlayEngine/Sources/CAirPlayEngine/sender/airplay_events.c` (+295/−5), `sender/airplay_events.h:1`,
  `pair_ap/pair_fruit.c`, `pair_ap/pair_homekit.c`; ledger `AirPlayEngine/docs/VENDORED-DIFFS.md:30-36`
- Evidence: `git diff 7549cb66 -- <those paths>`:
  ```
  airplay_events.c | 300 ++++++++++++++++++++-   (295 insertions, 5 deletions)
  -airplay_events_listen(const char *name, const char *address, ...
  +airplay_events_listen(const char *name, uint64_t device_id, const char *address, ...
  +  free_ng(usr->ng);        (pair_fruit.c)
  +  free_ng(usr->ng);        (pair_homekit.c)
  ```
  while the ledger states: **Total vendored files touched: 7** — `airplay.c`, `raop.c`, `ptp_msg_handle.c`,
  `libairptp/airptp.h`, `libairptp/src/airptp.c`, `airptp_internal.h`, `daemon.c`. None of the four above
  appear, and `airplay_events.c` carries no in-file `[AirPlayEngine vendored change …]` marker either.
- Why it matters: the AGENTS.md rule is "vendored sources change only as a last resort, marked in place and
  ledgered as an exception". Eleven files, not seven, now differ from upstream, so the next re-vendor or
  upstream merge will silently drop the speaker-input event path and two real leak fixes.
- Fix: add ledger entries for the speaker-input change (commit `83dc9483`), the two `free_ng` leak fixes
  (`a10defd3`), the `raop.c` double-free null-out (`5c1f5969`), the libairptp shm-name override (`b961398e`)
  and the stream-cap raise (`ffd89914`), and put the dated in-file markers on `airplay_events.c`/`.h` the
  other entries use. Update the "Total vendored files touched" line.
- Confidence: high

### 6. [SUBSTANCE] Shim headers still announce "STUB STATUS" for code that has been the real implementation for a year
- Where: `AirPlayEngine/Sources/CAirPlayEngine/shims/logger.h:19-25`, `shims/outputs.h:38-46`,
  `shims/misc.h:26-35`, `shims/outputs.c:1-25` and `:42-43` and `:1058`, `shims/conffile.c:30-33`,
  `AirPlayEngine/Package.swift:10-14`
- Evidence:
  ```c
  // STUB STATUS (T-BUILD-1): the .c bodies (logger.c) are MINIMAL stubs so the
  // link succeeds — DPRINTF/DVPRINTF/DHEXDUMP currently no-op (or write to stderr).
  // TODO(T-SHIM-1): implement real logging in logger.c
  ```
  (logger.c is 368 lines of os_log + file-rotation routing), and
  ```c
  /* ... For T-BUILD-1 (compile+link only) it is NULL.
   * TODO(T-API-1): set this to the engine thread's event_base before airplay_init runs */
  ```
  (`AirPlayEngine.swift:419` sets it on every start), and Package.swift: "STATUS (T-PKG-1 — scaffold only):
  … the C target does NOT compile yet."
- Why it matters: a reviewer opening the load-bearing shim layer cold is told, at the top of each file, that
  none of it works — so they either distrust correct code or go looking for the real implementation elsewhere.
- Fix: delete the STUB STATUS blocks and the completed `TODO(T-BUILD-1/T-SHIM-1/T-API-1)` markers; keep only
  the two that name genuinely open work (`outputs.c:1058` quality tracking, `transcode.c:22-27` the ffmpeg
  swap), and say what is missing rather than naming a finished task id.
- Confidence: high
