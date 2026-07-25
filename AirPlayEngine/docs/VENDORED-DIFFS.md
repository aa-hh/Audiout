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
entirely inside `shims/` or `Sources/AirPlayEngine/`. Entry 3 (T3, 2026-07-19)
is the RAOP/AirPlay-1 sender port's vendored diff — originally the single
ffmpeg-encoder guard, extended 2026-07-19 with the multi-stream `stream_id`
surgery (the exact mirror of Entry 2's airplay.c change), which is the
root-cause fix for per-app routing not working on AirPlay-1 receivers.
**Total vendored files touched: 3** (`airplay.c`, `raop.c`, `ptp_msg_handle.c`);
`raop.c` (Entry 3) now carries two distinct diffs. (Note: the sibling `stream_id` additions to `shims/outputs.h` and
`shims/engine_bridge.h`, and T3's `shims/misc.{h,c}` / `shims/conffile.c` /
`shims/engine_bridge.h` additions, are in `shims/`, which is engine-owned code,
NOT the byte-identical vendored set — so they are documented in Entries 2 and 3
for context but do not themselves count as vendored diffs.)

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

## Entry 3 — `sender/raop.c`: (3a) guard the ffmpeg encoder setup on `!raop_uncompressed_alac` (T3); (3b) add a `stream_id` dimension for multi-stream per-app routing (T1-mirror, 2026-07-19)

### Entry 3a — ffmpeg-encoder guard (T3, 2026-07-19)

- **File**: `AirPlayEngine/Sources/CAirPlayEngine/sender/raop.c`
- **License**: GPL-2.0-or-later (`AirPlayEngine/Sources/CAirPlayEngine/sender/`)
- **Landed in**: branch `claude/airplay-one-support-2abab0`, 2026-07-19 (T3 — port
  the classic AirPlay-1 / RAOP sender; design brief `docs/raop-seam-brief.md` §3).
- **Rationale**: `raop.c` is vendored **near-byte-identical** — its bare includes
  (`"conffile.h"`, `"logger.h"`, `"outputs.h"`, `"rtp_common.h"`, `"pair_ap/pair.h"`,
  …) resolve to the existing shims via the C target's header-search paths with no
  edit, and its metadata/db/artwork/dmap calls reach the no-op shims exactly as
  `airplay.c`'s do (so the metadata path is "cut" without touching the source).
  The **one** functional diff is in `master_session_make`. The engine defaults
  `airplay_shared.uncompressed_alac = true` (`shims/conffile.c`), so the RAOP send
  path uses raop.c's own inline uncompressed-ALAC encoder (`alac_encode ->
  alac_encode_no_xcode`) and never the ffmpeg encoder. But upstream still built the
  ffmpeg `encode_ctx` in `master_session_make` **unconditionally** and hard-failed
  the session (`goto error`) when `transcode_encode_setup` returned NULL — i.e. an
  AirPlay-1 session could not even start without libavcodec's ALAC encoder, despite
  its output never being used. Guarding the setup on `!raop_uncompressed_alac`
  removes that dependency (T3 task requirement "keep the built-in uncompressed
  encoder — no ffmpeg dependency"). This *cannot* live in a shim: the ffmpeg-setup
  block, the `raop_uncompressed_alac` static, and the master-session struct are all
  inside the vendored file. It is safe: `encode_ctx` stays NULL and is only ever
  passed to the `alac_encode_xcode` branch — which `alac_encode` skips when
  `raop_uncompressed_alac` — and `master_session_free`'s `transcode_encode_cleanup`
  is NULL-safe (`if (!ctxp || !*ctxp) return;`). The `else` path (uncompressed_alac
  false) is byte-for-byte the upstream ffmpeg path, so nothing regresses if the
  flag is ever flipped off.
- **Exact change** (marked in-file with a dated
  `[AirPlayEngine vendored change 2026-07-19]` comment): the four statements

  ```c
  encode_args.src_ctx = transcode_decode_setup_raw(XCODE_PCM16, quality);
  if (!encode_args.src_ctx) { … goto error; }
  rms->encode_ctx = transcode_encode_setup(encode_args);
  transcode_decode_cleanup(&encode_args.src_ctx);
  if (!rms->encode_ctx) { … goto error; }
  ```

  are wrapped in `if (!raop_uncompressed_alac) { … }`. No other line of `raop.c`
  is modified.
- **The package still links ffmpeg** (`avcodec`/`avutil`/`swresample` in
  `Package.swift`) because the **AP2** backend (`airplay.c`) has no uncompressed
  path and requires the ffmpeg ALAC encoder unconditionally. This diff makes the
  *RAOP* path ffmpeg-free at runtime; a package-wide ffmpeg shed is the AP2-side
  R-C follow-up already noted in `Package.swift` / seam-map §5.3, out of T3 scope.
- **Sibling shim edits (NOT vendored, listed for context)**: `shims/misc.{h,c}`
  gained `safe_atoi32` (decimal SETUP transport / sr·ss·ch parse) and a
  self-contained RFC-4648 `b64_encode` (the RSA-AES SDP handshake: `a=rsaaeskey`,
  `a=aesiv`, `Apple-Challenge`) — both ported/derived from OwnTone's own misc.c but
  living in the engine-owned shim; `shims/conffile.c` serves `uncompressed_alac`
  (default true) so `raop_init` doesn't trip the unknown-key path; `shims/engine_
  bridge.h` declares `extern struct output_definition output_raop` so the Swift
  wrapper/test can reach the backend the way it reaches `output_airplay`.
  `L_RAOP` was already present in `shims/logger.h`. These are all in `shims/`,
  outside the byte-identical vendored set.
- **NOT done in T3 (deferred integration, completed by later tasks)**: the
  two-backend `outputs.c` dispatch (`backend_for` + per-op wrappers + dual
  `write` fan-out) landed in T4 (`shims/outputs.c`/`.h`); the `engine_bridge`
  dual-device-callback capture (brief §6.6) landed in T5
  (`airplayengine_feed_raop_device` / `airplayengine_raop_discovery_ready`,
  `shims/engine_bridge.{h,c}`, `shims/mdns.c` keying the capture on `type`);
  `DeviceDescriptor.ServiceKind` routing landed in T6
  (`AirPlayTypes.swift`/`AirPlayEngine.swift`); and `NativeBackend` driving AP1
  receivers through the shared engine (no longer surfacing them
  dimmed/unsupported) landed in T7. None of T4–T7 touched vendored source —
  they are all `shims/`, `AirPlayEngine.swift`/`AirPlayTypes.swift`, or
  `AudiouterCore` — so this ledger's entry count is unaffected; see
  `PROGRESS.md` for each task's own verification. The optional `stream_id`
  surgery for AP1 per-app routing (brief §4bis) was originally deferred here;
  it landed 2026-07-19 and is documented as Entry 3b below.
- **Verification**: `swift build` clean (raop.c compiles + links, no new
  warnings surfaced in the build log). `swift test` 126/126 pass (was 119; +7 new
  `RaopBackendTests` exercising the `output_raop` descriptor shape, the
  `raop_volume_to_pct` volume-string parse across the -30..0 dB range + off +
  malformed input + max_volume scaling, RFC-4648 `b64_encode` vectors, and
  `safe_atoi32`). All pre-existing AP2 engine tests still pass.

### Entry 3b — `stream_id` multi-stream per-app routing (T1-mirror, 2026-07-19)

- **File**: `AirPlayEngine/Sources/CAirPlayEngine/sender/raop.c`
- **License**: GPL-2.0-or-later (`AirPlayEngine/Sources/CAirPlayEngine/sender/`)
- **Landed in**: branch `claude/airplay-one-support-2abab0`, 2026-07-19.
- **Rationale**: The exact mirror of Entry 2's airplay.c surgery, applied to the
  RAOP sender. `raop.c` was vendored WITHOUT the `stream_id` dimension, so
  `master_session_make` deduplicated every device onto a single master session
  keyed only on `(quality, encrypt)`. Because all per-app streams share one wired
  quality (44100/16/2), audio from different app-streams collided into one RAOP
  session — this is the root cause of per-app routing not working on AirPlay-1
  receivers and of the live-tested pitch-up/crackle (two streams' PCM summed into
  one session) when a per-app route was added, including the AP1+AP2 clock/sync
  breakage. Adding a `uint32_t stream_id` so the cache key becomes
  `(stream_id, quality, encrypt)` and the write fan-out matches on stream_id in
  addition to quality gives each app-stream its own master session (independent
  RTP timeline / ALAC encoder / input buffer). This *cannot* live in a shim (same
  reasons as Entry 2: static types, the static `raop_master_sessions` list, the
  fan-out inside the vendored file) and *cannot* be faked via `quality` (all app
  streams share it). `stream_id` defaults to 0 everywhere, so the pre-change
  single-stream RAOP path is byte-for-byte unchanged.
- **Exact changes** (each marked in-file with a dated
  `[AirPlayEngine vendored change 2026-07-19]` comment; RAOP's reuse key is
  `(quality, encrypt)`, not airplay's `(quality, use_ptp)`, so the added key
  component sits alongside `encrypt`):
  1. `struct raop_master_session`: added `uint32_t stream_id;`.
  2. `struct raop_session`: added `uint32_t stream_id;`.
  3. `master_session_make`: signature gained a leading `uint32_t stream_id`
     parameter; the reuse-cache loop now also requires `rms->stream_id ==
     stream_id`; the new master session stores `rms->stream_id = stream_id`.
  4. `session_make`: sets `rs->stream_id = rd->stream_id` and passes it to
     `master_session_make` (the only caller).
  5. `raop_write` fan-out: skips a PCM blob unless
     `obuf->data[i].stream_id == rms->stream_id` **in addition to** the existing
     `quality_is_equal` check. This is the critical cross-talk guard.
  6. The two send loops (`packets_send`, `packets_sync_send`): **no code
     change** — they gate on `rs->master_session != rms` pointer identity, which
     is strictly stronger than a stream_id compare (a session bound to `rms`
     necessarily carries `rms->stream_id`). A clarifying audit comment was added
     at `packets_send` to record this.
  7. Test/diagnostic seam: six non-static `raop_test_master_session_*` /
     `raop_test_write_one` accessors (make / stream_id / input_buffer_samples /
     count / reset / write_one) so the headless
     `RaopMultiStreamMasterSessionTests` can observe otherwise-static
     master-session identity AND drive the real `raop_write` fan-out to prove no
     cross-talk. Not reachable from any shipping path.
- **Sibling shim edits (NOT vendored, listed for context)**: `shims/engine_bridge.h`
  declares the six `raop_test_*` prototypes. `struct output_device` /
  `struct output_data` already carry `stream_id` (added in Entry 2 for airplay);
  RAOP reuses those same fields, so no further `shims/outputs.h` change was
  needed. These files are engine-owned `shims/` code, outside the byte-identical
  set.
- **Verification**: `swift build` clean; `swift test` 136/136 pass (+4 new
  `RaopMultiStreamMasterSessionTests`: distinct/same/zero stream_id keying and a
  cross-talk write-routing test proving a `stream_id=1` write never grows a
  `stream_id=0` session's input buffer and vice versa). All pre-existing tests
  (incl. AP2 multi-stream and RaopBackendTests) still pass; the stream_id-0 path
  is behaviourally unchanged.

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

---

## Entry 4 — `sender/airplay.c` and `sender/raop.c`: treat `EAGAIN`/`EWOULDBLOCK` on the data-socket send as a dropped packet, not a fatal session error (T6, 2026-07-25)

- **Files**: `AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c`,
  `AirPlayEngine/Sources/CAirPlayEngine/sender/raop.c`
- **License**: GPL-2.0-or-later (`AirPlayEngine/Sources/CAirPlayEngine/sender/`)
- **Landed in**: this worktree, 2026-07-25 (T6, `docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md`
  §E, per findings F23/F24 in §B.2).
- **Rationale**: F23 established that making the AirPlay 2 and RAOP data
  sockets non-blocking costs zero vendored diff — `net_connect` lives in
  `shims/misc.c` (engine-owned), and only the two `SOCK_DGRAM` callers
  (`airplay.c:3187`'s "AirPlay data" socket, `raop.c:3497`'s "RAOP data"
  socket) are affected; the one `SOCK_STREAM` caller (`airplay_events.c:767`,
  the AirPlay events connection) is untouched and keeps its original blocking
  behavior. That shim-only change is documented inline in `misc.c`'s
  `net_connect`, not here — it isn't vendored source. F24 is what forces a
  real vendored diff: once the data socket can return `EAGAIN`/`EWOULDBLOCK`
  from `send()`, both senders' `packet_send` unconditionally treated *any*
  `sent/ret < 0` as fatal and called `deferred_session_failure`, which would
  tear down an otherwise-healthy session on a purely transient
  "socket buffer momentarily full" condition — exactly the kind of sender-side
  hiccup F26 says should never cause an audible dropout on its own. This
  cannot live in a shim: `packet_send` and its `if (sent < 0) { … }` fatal
  path are inside the vendored file, and the fix needs to special-case
  `errno` right where the send return value is checked. The fix is minimal:
  inside the existing `sent/ret < 0` branch, an `errno == EAGAIN || errno ==
  EWOULDBLOCK` check now logs and counts the drop and returns `-1` (packet
  not sent, same signal already used for the pre-existing partial-send case
  just below) **without** calling `deferred_session_failure`. Every other
  negative-return cause (real socket errors) falls through to the unchanged
  `deferred_session_failure` path exactly as before. Each drop counter
  (`airplay_dropped_packets` in `airplay.c`, `raop_dropped_packets` in
  `raop.c`) is a function-local `static uint64_t` declared inside the new
  `if (errno == EAGAIN …)` block specifically so the whole change stays
  inside the one hunk already touching that `if (sent < 0)` block — no
  separate top-of-file declaration hunk. They are logged via `DPRINTF`
  (`E_WARN`) on every drop with a running total; wiring them into T1's
  Swift-side `WriteSchedulingSnapshot` diagnostic probe is left to whichever
  later task needs it (out of T6 scope — T6 only needed the drop counted and
  logged somewhere sane).
- **Exact hunks** (each marked in-file with a dated
  `[AirPlayEngine vendored change 2026-07-25]` comment):

  `sender/airplay.c`, inside `packet_send`:

  ```c
   if (sent < 0)
     {
  +      // [AirPlayEngine vendored change 2026-07-25: EAGAIN on non-blocking DGRAM
  +      // send is a dropped packet, not a fatal session error — see
  +      // docs/VENDORED-DIFFS.md Entry 4]
  +      if (errno == EAGAIN || errno == EWOULDBLOCK)
  +	{
  +	  static uint64_t airplay_dropped_packets;
  +
  +	  airplay_dropped_packets++;
  +	  DPRINTF(E_WARN, L_AIRPLAY, "Dropped packet for '%s' (send would block): %s (total dropped: %" PRIu64 ")\n",
  +	    session->devname, strerror(errno), airplay_dropped_packets);
  +	  return -1;
  +	}
  +
        DPRINTF(E_LOG, L_AIRPLAY, "Send error for '%s': %s\n", session->devname, strerror(errno));

        // Can't free it right away, it would make the ->next in the calling
  ```

  `sender/raop.c`, inside `packet_send`:

  ```c
   ret = send(rs->server_fd, pkt->data, pkt->data_len, 0);
   if (ret < 0)
     {
  +      // [AirPlayEngine vendored change 2026-07-25: EAGAIN on non-blocking DGRAM
  +      // send is a dropped packet, not a fatal session error — see
  +      // docs/VENDORED-DIFFS.md Entry 4]
  +      if (errno == EAGAIN || errno == EWOULDBLOCK)
  +	{
  +	  static uint64_t raop_dropped_packets;
  +
  +	  raop_dropped_packets++;
  +	  DPRINTF(E_WARN, L_RAOP, "Dropped packet for '%s' (send would block): %s (total dropped: %" PRIu64 ")\n",
  +	    rs->devname, strerror(errno), raop_dropped_packets);
  +	  return -1;
  +	}
  +
        DPRINTF(E_LOG, L_RAOP, "Send error for '%s': %s\n", rs->devname, strerror(errno));

        // Can't free it right away, it would make the ->next in the calling
  ```

  Confirmed via `git diff -U3 -- AirPlayEngine/Sources/CAirPlayEngine/sender/`:
  exactly two `@@` hunks, one per file, nothing else in `sender/` touched.
- **Sibling shim edit (NOT vendored, listed for context)**: `shims/misc.c`'s
  `net_connect` now computes `set_nonblock = (type == SOCK_DGRAM)` and passes
  it to `net_connect_addrinfo` instead of the previous hard-coded `false`, so
  `SOCK_DGRAM` data sockets are left non-blocking after connect while
  `SOCK_STREAM` sockets (the events connection) keep the original
  restore-to-blocking step. Pure `shims/` file, outside the byte-identical
  vendored set, per F23 — no ledger entry required for it.
- **Verification**: `swift build` clean (no new warnings from these hunks);
  `git diff -U3 -- AirPlayEngine/Sources/CAirPlayEngine/sender/` shows exactly
  two hunks, matching the quotes above verbatim.

**Total vendored files touched: 3** (`airplay.c`, `raop.c`, `ptp_msg_handle.c`);
`airplay.c` and `raop.c` each now carry more than one distinct diff (Entries
2/4 and 3a/3b/4 respectively).
