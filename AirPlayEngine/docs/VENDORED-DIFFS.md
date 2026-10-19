# Vendored-source diffs ledger

Per `PLAN-PHASE-2B.md` D5: vendored OwnTone C (everything under
`Sources/CAirPlayEngine/` **except** `shims/`) stays byte-identical unless a
fix genuinely cannot live in a shim or the hosting layer. When that escape
hatch is used, the diff must be minimal, keep the original license header
intact, and be recorded here: file, license, rationale, exact hunk.

This ledger is built directly from `git log`/`git diff` over the vendored
directories (`sender/`, `evrtsp/`, `pair_ap/`, `libairptp/`) — **not** from
memory or task summaries. The entry list below is the count: every commit
that touched vendored source has an entry, and nothing else does. The first
two are `99209de` ("Engine first light PASSED"), Entry 1 below, and
the P2b/T1 multi-stream `stream_id` change (Entry 2, on branch
`claude/per-app-routing-engine-73f40c`, 2026-07-17), which is the only
uncommitted vendored change in this worktree at time of writing. Every Phase 2b
engine task (STATESTREAM, SIGABRT, SIGPIPE, CADENCE, LIBHASH, HARDEN) stayed
entirely inside `shims/` or `Sources/AirPlayEngine/`. Entry 3 (T3, 2026-07-19)
is the RAOP/AirPlay-1 sender port's vendored diff — originally the single
ffmpeg-encoder guard, extended 2026-07-19 with the multi-stream `stream_id`
surgery (the exact mirror of Entry 2's airplay.c change), which is the
root-cause fix for per-app routing not working on AirPlay-1 receivers.
Entry 5 (T1, 2026-07-26) adds a daemon-side active-peer-count publish to
`libairptp/src/airptp.c` / `airptp_internal.h` / `daemon.c` and the public
`libairptp/airptp.h`; Entry 6 (T1b, 2026-07-26) is the loopback peer-control
delivery fix in `ptp_msg_handle.c` that Entry 5's own new test assertions
surfaced as red. Entries 7-10 (2026-09-20 backfill) cover four commits that
had gone unrecorded: the speaker-input `device_id` threading and inbound
volume parse (`83dc9483`), four verified memory leaks (`a10defd3`), the
pair-verify double-free (`5c1f5969`), and the overridable PTP shared-memory
name (`b961398e`). The stream-cap raise the 2026-09-17 review listed as
missing is not missing: it is Entry 2, item 8.
**Total vendored files touched: 11** (`sender/airplay.c`,
`sender/airplay_events.c`, `sender/airplay_events.h`, `sender/raop.c`,
`pair_ap/pair_fruit.c`, `pair_ap/pair_homekit.c`,
`libairptp/src/ptp_msg_handle.c`, `libairptp/airptp.h`,
`libairptp/src/airptp.c`, `libairptp/src/airptp_internal.h`,
`libairptp/src/daemon.c`); several carry more than one distinct diff — see
the closing paragraph for the per-file list. (Note: the sibling `stream_id`
additions to `shims/outputs.h` and `shims/engine_bridge.h`, and T3's
`shims/misc.{h,c}` / `shims/conffile.c` / `shims/engine_bridge.h` additions, are
in `shims/`, which is engine-owned code, NOT the byte-identical vendored set —
so they are documented in Entries 2 and 3 for context but do not themselves
count as vendored diffs.)

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
  8. Test/diagnostic seam, 2026-09-15 (`[AirPlayEngine vendored change
     2026-09-15] TEST SEAM`): a sixth accessor,
     `airplay_test_master_session_rtp_pos`, returning
     `ams->rtp_session->pos`. `packets_send` advances that position by
     `samples_per_packet` via `rtp_packet_commit`, and only after
     `alac_encode` returned a length, so its DELTA across a headless run
     counts the packets the ALAC encoder actually produced. The 16-stream
     encode benchmark (`MultiStreamEncodeLoadTests`, added with the engine
     stream cap raise 6 -> 16) needs exactly that to prove its timing measured
     real encoding. The position is seeded by `gcry_randomize` in
     `rtp_session_new`, so only the delta is meaningful. Not reachable from
     any shipping path.
- **Sibling shim edits (NOT vendored, listed for context)**: `shims/outputs.h`
  gained `uint32_t stream_id` on `struct output_device` and `struct
  output_data`; `shims/engine_bridge.h` declares the six test-seam
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
  `AudioutCore` — so this ledger's entry count is unaffected; see
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

---

## Entry 5 — `libairptp`: publish a cross-thread daemon-side active-peer count (`airptp_peer_active_count()`) (T1, 2026-07-26)

- **Files**: `AirPlayEngine/Sources/CAirPlayEngine/libairptp/airptp.h`,
  `AirPlayEngine/Sources/CAirPlayEngine/libairptp/src/airptp.c`,
  `AirPlayEngine/Sources/CAirPlayEngine/libairptp/src/airptp_internal.h`,
  `AirPlayEngine/Sources/CAirPlayEngine/libairptp/src/daemon.c`
- **License**: MIT (`AirPlayEngine/Sources/CAirPlayEngine/libairptp/LICENSE`)
- **Landed in**: this worktree, 2026-07-26 (T1,
  `docs/plans/PLAN-AIRPLAY-COEXISTENCE.md`).
- **Rationale**: An on-demand PTP helper needs to know when it can safely
  idle-exit and release ports 319/320 — that decision requires knowing
  whether any peer is still actively using the daemon, and `peers[]`/
  `num_peers` are daemon-thread-only state with no existing cross-thread read
  path. This adds a `_Atomic int active_peers_published` to
  `struct airptp_daemon` (`airptp_internal.h`), a `static void
  active_peers_publish()` in `daemon.c` that walks `peers[]` and counts
  entries seen within `AIRPTP_STALE_SECS`, called after every peer-table
  mutation (`peers_prune`, `daemon_peer_add`, `daemon_peer_del`) plus on the
  5 s shm heartbeat (`shm_update_cb`) so the count also **decays** while peers
  age out without any add/del arriving, and a public `int
  airptp_peer_active_count(struct airptp_handle *hdl)` (`airptp.h`/`airptp.c`)
  that returns `-1` for a non-daemon (client/`find()`'d) handle and the
  published count otherwise. This cannot live in a shim: the atomic has to sit
  inside `struct airptp_daemon` itself (vendored, in `airptp_internal.h`) so
  the daemon thread's existing peer-table mutation sites can update it
  in-place, and the new public accessor has to sit in `airptp.h`/`airptp.c`
  alongside the rest of the client-visible API. Purely additive: no existing
  field, function signature, or behavior changed; the atomic is initialized to
  0 by `calloc` and only ever written by the daemon thread via
  `atomic_store`, read by any thread via `atomic_load`.
- **Exact changes** (each marked in-file with a dated
  `[AirPlayEngine vendored change 2026-07-26]` comment is not present here —
  T1 predates this ledger backfill and used plain comments instead; see the
  hunks below for the actual diff):
  1. `airptp.h`: new public declaration `int airptp_peer_active_count(struct
     airptp_handle *hdl);` with a doc comment explaining the -1/daemon-only
     contract and the decay behavior.
  2. `airptp_internal.h`: `#include <stdatomic.h>`; `struct airptp_daemon`
     gains `_Atomic int active_peers_published;`.
  3. `airptp.c`: new `airptp_peer_active_count()` definition — returns `-1`
     if `!hdl || !hdl->is_daemon || hdl->state != AIRPTP_STATE_RUNNING`,
     else `atomic_load(&hdl->daemon.active_peers_published)`.
  4. `daemon.c`: new `static void active_peers_publish(struct airptp_daemon
     *daemon)` that counts `peers[i].last_seen + AIRPTP_STALE_SECS > now`
     across `0..num_peers`, `atomic_store`s the result; called at the end of
     `peers_prune()`, `daemon_peer_add()`, `daemon_peer_del()`, and
     `shm_update_cb()`.
- **Sibling non-vendored additions (NOT vendored, listed for context)**:
  `Sources/PTPHelperTestSupport/include/ptp_test_support.h` /
  `ptp_test_support.c` gained a pass-through `ptp_test_peer_active_count()`
  forwarder (this target's whole purpose is forwarding, see its own
  `AGENTS.md`); `Tests/AirPlayEngineTests/PTPHelperIPCTests.swift` gained the
  assertions that exercise the new API end to end. Neither is vendored source.
- **Verification**: `swift build` clean. At the time T1's code was written,
  its own two new poll-based assertions ("active peer count should reach 1
  after peer_add" / "should return to 0 after peer_remove") were **red** —
  see Entry 6, the T1b fix that makes them pass. `airptp_peer_active_count()`
  itself and the -1-on-client-handle assertion were green from the start.

---

## Entry 6 — `libairptp/src/ptp_msg_handle.c`: send loopback peer-control messages to the family the daemon actually bound, not resolver order (T1b, 2026-07-26)

- **File**: `AirPlayEngine/Sources/CAirPlayEngine/libairptp/src/ptp_msg_handle.c`
- **License**: MIT (`AirPlayEngine/Sources/CAirPlayEngine/libairptp/LICENSE`)
- **Landed in**: this worktree, 2026-07-26 (T1b,
  `docs/plans/PLAN-AIRPLAY-COEXISTENCE.md`), same commit as Entry 5's backfill.
- **Rationale**: `localhost_msg_send()` resolved `"localhost"` with
  `AF_UNSPEC` and sent only to the *first* `getaddrinfo()` result. On this
  machine (and macOS generally) that result is `::1` (AF_INET6) — verified
  directly. `ptp_msg_peer_add_send()`/`ptp_msg_peer_del_send()` are the only
  callers, used for `airptp_peer_add()`/`airptp_peer_remove()`'s loopback
  control channel to the daemon. Whenever the daemon bound IPv4-only (exactly
  what `PTPHelperIPCTests.swift`'s test daemon does, binding `127.0.0.1`
  explicitly rather than `NULL`/`INADDR_ANY` to avoid re-triggering macOS's
  Application Firewall prompt on every `swift test` run — see that file's own
  comment, ~line 128), every peer add/remove message was silently sent to a
  family the daemon never listens on. `sendto()` on a UDP socket still
  returns success in that case, so callers saw no error at all — this is
  exactly the bug Entry 5's new poll-based test assertions caught (red before
  this fix, per Entry 5's Verification note). This cannot live in a shim: the
  resolution happens inside the vendored `localhost_msg_send()` itself, and
  the fix needs the daemon's actual bound-family state
  (`hdl->daemon_info.ipv4_enabled`/`.ipv6_enabled`, published by the daemon
  into shm and copied into every handle — Entry 5's neighbor, unrelated to
  the active-peer-count feature but already present in the same struct),
  which only the caller (already holding `hdl`) has. The fix does **not**
  broadcast to every resolved loopback candidate — it sends to the ONE family
  the daemon reports enabled, preferring IPv4 when both are (dual-stack
  `NULL`/`INADDR_ANY` binds can enable both `ipv4_enabled` and
  `ipv6_enabled` simultaneously, per `daemon.c`'s `daemon_info_fill()`) —
  keeping exactly one control message per call and the diff to vendored code
  minimal.
- **Exact changes** (marked in-file with dated
  `[AirPlayEngine vendored change 2026-07-26]` comments):
  1. `localhost_msg_send()` gained a fourth parameter, `sa_family_t family`,
     used as `hints.ai_family` in place of the hard-coded `AF_UNSPEC`.
  2. `ptp_msg_peer_add_send()` / `ptp_msg_peer_del_send()`: pass
     `hdl->daemon_info.ipv4_enabled ? AF_INET : AF_INET6` as the new
     argument.

  ```c
   static int
  -localhost_msg_send(void *msg, size_t msg_len, unsigned short port)
  +localhost_msg_send(void *msg, size_t msg_len, unsigned short port, sa_family_t family)
   {
  -  struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_DGRAM };
  +  struct addrinfo hints = { .ai_family = family, .ai_socktype = SOCK_DGRAM };
     struct addrinfo *info = NULL;
  ```

  ```c
     msg_peer_add_make(&msg, peer, hdl->daemon_info.clock_id);
  -  return localhost_msg_send(&msg, sizeof(msg), port);
  +  return localhost_msg_send(&msg, sizeof(msg), port, hdl->daemon_info.ipv4_enabled ? AF_INET : AF_INET6);
  ```

  ```c
     msg_peer_del_make(&msg, peer, hdl->daemon_info.clock_id);
  -  return localhost_msg_send(&msg, sizeof(msg), port);
  +  return localhost_msg_send(&msg, sizeof(msg), port, hdl->daemon_info.ipv4_enabled ? AF_INET : AF_INET6);
  ```

  Confirmed via `git diff -U3 -- AirPlayEngine/Sources/CAirPlayEngine/libairptp/src/ptp_msg_handle.c`:
  exactly these hunks, nothing else in the file touched.
- **NOT changed**: `Tests/AirPlayEngineTests/PTPHelperIPCTests.swift`'s
  loopback-only test-daemon bind (~line 139) — that constraint is load-bearing
  (avoids the firewall prompt) and this fix works with it, not around it: the
  test daemon binds `127.0.0.1` only, so `ipv4_enabled` is true and
  `ipv6_enabled` false, and the fixed `ptp_msg_peer_add_send`/`_del_send` now
  correctly target `AF_INET`.
- **Verification**: `swift test --filter PTPHelperIPCTests` — both previously
  red assertions ("active peer count should reach 1 after peer_add" /
  "should return to 0 after peer_remove") pass. Full `swift test`: 173/173
  pass.

---

## Entry 7 — `sender/airplay_events.{c,h}` and `sender/airplay.c`: thread the owning `device_id` into the events channel and parse the speaker's own volume (speaker-input task, 2026-07-22)

- **Files**: `AirPlayEngine/Sources/CAirPlayEngine/sender/airplay_events.c`,
  `sender/airplay_events.h`, `sender/airplay.c`
- **License**: GPL-2.0-or-later (`AirPlayEngine/COPYING`)
- **Landed in**: commit `83dc9483` (2026-07-22, "Speaker-input
  responsiveness: respond to controls pressed on the speaker")
- **Rationale**: a volume knob turned ON the speaker, and its transport keys,
  arrive on the reverse RTSP events channel that `airplay_events.c` owns.
  OwnTone fed the inbound value into its own player; an audio-only sender
  dropped it. Two things were needed inside the vendored file: the parse of
  the inbound `SET_PARAMETER volume: <dB>` line (and a best-effort bplist
  search for receivers that report a plist instead), and the identity of the
  speaker the channel belongs to, so `airplayengine_remote_fire` routes the
  change to the right output. The events client is created inside
  `airplay_events_listen`, called from `airplay.c`'s SETUP response handler —
  the only place that knows `session->device_id` — so the id has to be
  threaded through the vendored signature. A shim cannot reach either point:
  the read loop, the decrypt and the client struct all live in this file.
- **Exact hunks**: `airplay_events.c` is +287/−4 across hunks at
  `@@ -39`, `@@ -54`, `@@ -129`, `@@ -138`, `@@ -326`, `@@ -401`, `@@ -429`,
  `@@ -476`, `@@ -487`. The signature and struct changes:

  ```c
   #include "pair_ap/pair.h"
  +#include "engine_bridge.h" /* airplayengine_remote_fire — inbound device volume */
  ```

  ```c
   struct airplay_events_client
   {
     char *name;
  +  uint64_t device_id; /* engine-added: which output_device this channel belongs
  +                       * to, so an inbound volume change routes to that speaker. */
     int fd;
  ```

  ```c
   static int
  -client_add(const char *name, int fd, const uint8_t *key, size_t key_len)
  +client_add(const char *name, uint64_t device_id, int fd, const uint8_t *key, size_t key_len)
   {
  ...
  +  client->device_id = device_id;
     client->fd = fd;
  ```

  ```c
   int
  -airplay_events_listen(const char *name, const char *address, unsigned short port, const uint8_t *key, size_t key_len)
  +airplay_events_listen(const char *name, uint64_t device_id, const char *address, unsigned short port, const uint8_t *key, size_t key_len)
  ...
  -  ret = client_add(name, fd, key, key_len);
  +  ret = client_add(name, device_id, fd, key, key_len);
  ```

  `airplay_events.h` (the matching declaration):

  ```c
   int
  -airplay_events_listen(const char *name, const char *address, unsigned short port, const uint8_t *key, size_t key_len);
  +airplay_events_listen(const char *name, uint64_t device_id, const char *address, unsigned short port, const uint8_t *key, size_t key_len);
  ```

  `airplay.c` `@@ -3315,8 +3315,10 @@ response_handler_setup_session`:

  ```c
  -  // Reverse connection, used to receive playback events from device
  -  ret = airplay_events_listen(session->devname, session->address, session->events_port, session->shared_secret, session->shared_secret_len);
  +  // Reverse connection, used to receive playback events from device (transport
  +  // keys + the speaker's own volume). device_id is threaded through so an inbound
  +  // volume change routes to the right speaker (engine-added, speaker-input task).
  +  ret = airplay_events_listen(session->devname, session->device_id, session->address, session->events_port, session->shared_secret, session->shared_secret_len);
  ```

  The new inbound-volume parser, in full (the `@@ -326` hunk also adds
  `volume_normalize`, `key_is_volume`, `plist_number_val`,
  `plist_find_volume` and `event_bplist_volume`, the bplist fallback path;
  `@@ -429` wires both into `incoming_cb`):

  ```c
  /* Some receivers report a change to their OWN volume back to the sender on this
   * event channel as an RTSP SET_PARAMETER carrying a `volume: <dB>` line — the
   * same text/parameters shape the sender sends outbound (airplay.c
   * payload_make_set_volume). OwnTone fed the inbound value through
   * device_volume_to_pct; an audio-only sender never parsed it, so a knob turn on
   * the speaker was silently dropped here.
   *
   * Scan for a `volume:` header line and map its dB to a normalized 0..1 level.
   * The dB<->level map mirrors the outbound path for the default max_volume
   * (airplay_volume_from_pct: -30..0 dB <-> 0..1), and <= -30 dB (including the
   * -144 mute sentinel) clamps to 0. Returns 0 and sets *out on a match, -1 if no
   * valid volume line is present (the caller then tries the transport path). */
  static int
  volume_parse(const uint8_t *in, size_t in_len, double *out)
  {
    static const char key[] = "volume:";
    const size_t keylen = sizeof(key) - 1;
    const uint8_t *p;
    const uint8_t *end = in + in_len;

    for (p = in; p + keylen <= end; p++)
      {
        // Only match at the very start or at the start of a header line, so we
        // don't false-match "volume:" bytes buried inside a binary plist body.
        if (p != in && p[-1] != '\n')
  	continue;
        if (memcmp(p, key, keylen) != 0)
  	continue;

        p += keylen;
        while (p < end && (*p == ' ' || *p == '\t'))
  	p++;

        // strtod needs a NUL-terminated token; copy up to the line end.
        char buf[32];
        size_t n = 0;
        while (p < end && n < sizeof(buf) - 1 && *p != '\r' && *p != '\n')
  	buf[n++] = (char)*p++;
        buf[n] = '\0';

        char *endp = NULL;
        double db = strtod(buf, &endp);
        if (endp == buf) // not a number after "volume:" — keep scanning
  	continue;

        if (db <= -30.0)
  	*out = 0.0;
        else if (db >= 0.0)
  	*out = 1.0;
        else
  	*out = (db + 30.0) / 30.0;
        return 0;
      }

    return -1;
  }
  ```
- **No in-file marker**: commit `83dc9483` added no
  `[AirPlayEngine vendored change ...]` comment to `airplay_events.c`,
  `airplay_events.h` or the `airplay.c` hunk (the hunk's own comment mentions
  "engine-added" but is not the standard marker). This entry is the only
  record of the change. Adding markers would itself be a vendored edit, so it
  is deliberately not done here.

---

## Entry 8 — `pair_ap/pair_fruit.c`, `pair_ap/pair_homekit.c`, `sender/airplay_events.c`, `sender/raop.c`: fix four verified memory leaks (2026-07-24)

- **Files**: `AirPlayEngine/Sources/CAirPlayEngine/pair_ap/pair_fruit.c`,
  `pair_ap/pair_homekit.c` (MIT, `SPDX-License-Identifier: MIT` in
  `pair_ap/pair.h`); `sender/airplay_events.c`, `sender/raop.c`
  (GPL-2.0-or-later, `AirPlayEngine/COPYING`)
- **Landed in**: commit `a10defd3` (2026-07-24, "Waves 1-2: fix verified
  memory leaks + damp the coreaudiod rebuild storm")
- **Rationale**: four leaks found with the allocation instruments, each inside
  a vendored free/teardown function that no shim can reach: `srp_user_new`'s
  error path never freed `usr->ng` (both pairing backends carry the same
  copy of the SRP code); `client_free` never closed the events-channel fd;
  `respond()` leaked both evbuffers when the encrypt step failed; and
  `session_free` left the pair-verify/pair-setup contexts allocated when a
  session was torn down mid-handshake.
- **Exact hunks**:

  `pair_fruit.c` `@@ -260` and `pair_homekit.c` `@@ -369`, one identical line
  in each `srp_user_new` error path:

  ```c
     if (!usr)
       return NULL;

  +  free_ng(usr->ng);
     bnum_free(usr->a);
  ```

  `airplay_events.c` `@@ -109` (`client_free`), `@@ -610` (`respond`) and
  `@@ -773` (`airplay_events_listen`, dropping the now-double close):

  ```c
     free(client->name);
     pair_cipher_free(client->cipher_ctx);

  +  if (client->fd >= 0)
  +    close(client->fd);
  +
     free(client);
  ```

  ```c
         DPRINTF(E_WARN, L_AIRPLAY, "Could not encrypt AirPlay event data response: %s\n", pair_cipher_errmsg(client->cipher_ctx));
  +      evbuffer_free(encrypted);
  +      evbuffer_free(response);
         return -1;
  ```

  ```c
     ret = client_add(name, device_id, fd, key, key_len);
     if (ret < 0)
       {
  -      close(fd);
  +      /* client_add's error path already ran client_free(), which now closes
  +       * fd itself -- closing it again here would double-close (a race with
  +       * any thread that has since reopened the same fd number). */
         return -1;
       }
  ```

  `raop.c` `@@ -2047` (`session_free`):

  ```c
     if (rs->server_fd >= 0)
       close(rs->server_fd);

  +  /* A session torn down mid-handshake (external stop/deinit racing an
  +   * in-flight pair-verify/pair-setup exchange) bypasses the handshake state
  +   * machine's own pair_verify_free()/pair_setup_free() calls -- free them
  +   * here too. Both are NULL-safe, matching every other call site. */
  +  pair_verify_free(rs->pair_verify_ctx);
  +  pair_setup_free(rs->pair_setup_ctx);
  +
     free(rs->realm);
  ```
- **No in-file marker**: no `[AirPlayEngine vendored change ...]` comment was
  added in `pair_fruit.c`, `pair_homekit.c` or `airplay_events.c`; this entry
  is the record.

---

## Entry 9 — `sender/raop.c`: fix the pair-verify double-free and the OOM-path body leak (W0.3, 2026-07-24)

- **File**: `AirPlayEngine/Sources/CAirPlayEngine/sender/raop.c`
- **License**: GPL-2.0-or-later (`AirPlayEngine/COPYING`)
- **Landed in**: commit `5c1f5969` (2026-07-24, "W0.3: fix pair-verify
  double-free + OOM leak in raop.c")
- **Rationale**: Entry 8 made `session_free` free `rs->pair_verify_ctx`, and
  `raop_cb_pair_verify_step2` frees it too — without nulling the pointer the
  second free is a double-free (`pair_verify_free` is NULL-safe, not
  double-free-safe). The second hunk frees the request body on the path where
  the RTSP request could not be created. Both sit inside vendored
  callbacks.
- **Exact hunks**:

  ```c
     if (!req)
       {
         DPRINTF(E_LOG, L_RAOP, "Could not create RTSP request for verification step %d\n", step);
  +      free(body);
         return -1;
       }
  ```

  ```c
     pair_verify_free(rs->pair_verify_ctx);
  +  rs->pair_verify_ctx = NULL; /* null-out after free: session_free() frees it again (NULL-safe, not double-free-safe) */
  ```

---

## Entry 10 — `libairptp`: let a test override the shared-memory name so it cannot collide with the production daemon (2026-07-22)

- **Files**: `AirPlayEngine/Sources/CAirPlayEngine/libairptp/airptp.h`,
  `libairptp/src/airptp.c`, `libairptp/src/airptp_internal.h`,
  `libairptp/src/daemon.c`
- **License**: MIT (`AirPlayEngine/Sources/CAirPlayEngine/libairptp/LICENSE`)
- **Landed in**: commit `b961398e` (2026-07-22, "Isolate PTP IPC test
  shared-memory name from the production daemon")
- **Rationale**: the PTP IPC tests start their own unprivileged daemon, and
  upstream hard-codes the shared-memory object as `/airptp_shm`. On a machine
  where the real root-owned helper is running, the test `shm_unlink`s and
  re-creates the production daemon's own segment. The name is consumed by
  `shm_open`/`shm_unlink` inside the vendored `daemon.c` and `airptp.c`, so no
  shim can redirect it; the smallest change is a mutable buffer plus a public
  override called before bind/start/find.
- **Exact hunks**:

  ```c
  +// By default airptp publishes its shared clock state under the name
  +// /airptp_shm, but for testing you can override that here - e.g. so an
  +// unprivileged test process doesn't collide with a real, root-owned daemon
  +// of the same name already running on the host. Must be called before
  +// airptp_daemon_bind()/airptp_daemon_start()/airptp_daemon_find().
  +void
  +airptp_shm_name_override(const char *name);
  ```

  ```c
   #define AIRPTP_SHM_NAME "/airptp_shm"
  +#define AIRPTP_SHM_NAME_MAXLEN 64
  +
  +// Mutable, overridable via airptp_shm_name_override() (declared in
  +// ../airptp.h, defined in airptp.c alongside airptp_event_port/
  +// airptp_general_port). A fixed buffer, not a `const char *`, because the
  +// override copies its argument in rather than just storing the pointer - a
  +// caller (e.g. a Swift test using String.withCString {}) may not be able to
  +// keep the original storage alive past the override call. daemon.c and
  +// airptp.c must read this instead of the AIRPTP_SHM_NAME macro directly so a
  +// test override actually takes effect.
  +extern char airptp_shm_name[AIRPTP_SHM_NAME_MAXLEN];
  ```

  ```c
   unsigned short airptp_general_port = PTP_GENERAL_PORT;
  +char airptp_shm_name[AIRPTP_SHM_NAME_MAXLEN] = AIRPTP_SHM_NAME;
  ...
  -  fd = shm_open(AIRPTP_SHM_NAME, O_RDONLY, 0);
  +  fd = shm_open(airptp_shm_name, O_RDONLY, 0);
  ...
  +void
  +airptp_shm_name_override(const char *name)
  +{
  +  snprintf(airptp_shm_name, sizeof(airptp_shm_name), "%s", name);
  +}
  ```

  `daemon.c`, three call sites (`daemon_shm_destroy`'s `shm_unlink`, and
  `daemon_shm_create`'s `shm_unlink` + `shm_open`):

  ```c
  -  shm_unlink(AIRPTP_SHM_NAME);
  +  shm_unlink(airptp_shm_name);
  ...
  -  shm_unlink(AIRPTP_SHM_NAME);
  +  shm_unlink(airptp_shm_name);

  -  fd = shm_open(AIRPTP_SHM_NAME, O_CREAT | O_EXCL | O_RDWR, 0644);
  +  fd = shm_open(airptp_shm_name, O_CREAT | O_EXCL | O_RDWR, 0644);
  ```
- **No in-file marker**: the four files carry no
  `[AirPlayEngine vendored change ...]` comment for these hunks; this entry is
  the record.

---

## Not a vendored diff — `libairptp/module.modulemap`

`libairptp/module.modulemap` (added in commit `9c082f06`) sits inside a
vendored directory but is not upstream source: it is a hand-written SwiftPM
module map for the `Clibairptp` target, written by this project. It exists
precisely so the vendored `airptp.h` can stay byte-identical — SwiftPM's
generated map would scan the directory as an umbrella and drag `src/`'s
private headers into the module. Its own header comment says so. No upstream
file is modified by it, so it needs no entry above.

---

**Total vendored files touched: 11** — `sender/airplay.c`,
`sender/airplay_events.c`, `sender/airplay_events.h`, `sender/raop.c`,
`pair_ap/pair_fruit.c`, `pair_ap/pair_homekit.c`,
`libairptp/src/ptp_msg_handle.c`, `libairptp/airptp.h`,
`libairptp/src/airptp.c`, `libairptp/src/airptp_internal.h`,
`libairptp/src/daemon.c`. Several carry more than one distinct diff:
`airplay.c` (Entries 2, 4, 7), `raop.c` (Entries 3a, 3b, 4, 8, 9),
`airplay_events.c` (Entries 7, 8), `ptp_msg_handle.c` (Entries 1, 6), and the
four libairptp files (Entries 5, 10). (Note: the sibling `stream_id`
additions to `shims/outputs.h` and `shims/engine_bridge.h`, and T3's
`shims/misc.{h,c}` / `shims/conffile.c` / `shims/engine_bridge.h` additions,
are in `shims/`, which is engine-owned code, NOT the byte-identical vendored
set — so they are documented in Entries 2 and 3 for context but do not
themselves count as vendored diffs.)
