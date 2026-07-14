# Build notes — T-BUILD-1 (compile + link the vendored C cluster)

**Task:** make the vendored C cluster in `Sources/CAirPlayEngine/` **compile and
link** on macOS 14.4 arm64 (Swift 5.10, brew at `/opt/homebrew`).
**Status:** DONE — `swift build` and `swift build --build-tests` both succeed;
the test executable links with **no undefined symbols** and the two scaffold
tests pass. **Zero compiler warnings** across the whole clean build (no
implicit-function-declaration / incompatible-pointer warnings — strong evidence
the shim signatures match every airplay.c call site).

This file records **every macOS-porting fix** so the port is reproducible, and
the exact **T-SHIM-1 starting state** (which shim functions are real vs stubbed).

Companion: `seam-map.md` is the authoritative extraction blueprint; this file
records how T-BUILD-1 executed the compile/link half of it.

---

## 0. Environment (verified)

- macOS 14.4.1 (23E224), arm64. Swift 5.10 (clang-1500.3.9.4).
- brew prefix `/opt/homebrew`; formulae present: `libevent`, `libsodium`,
  `libgcrypt`, `libgpg-error`, `libplist`, `ffmpeg`. `pkg-config libplist-2.0`
  resolves to `-lplist-2.0`.
- No `swift build` sandbox EPERM was hit; `dangerouslyDisableSandbox` was not
  needed.

---

## 1. New files created (the porting layer)

| file | purpose |
|---|---|
| `compat/config.h` | Hand-written replacement for OwnTone's autotools-generated `config.h`. |
| `compat/endian_compat.h` | macOS `<libkern/OSByteOrder.h>` mapping for glibc `htobe*/be*toh`. |
| `shims/*.c` (11 new) | Minimal shim bodies (mostly stubs) so the cut OwnTone symbols link. |

Shim `.c` files added: `logger.c`, `misc.c`, `conffile.c`, `commands.c`,
`player.c`, `db.c`, `artwork.c`, `dmap_common.c`, `mdns.c`, `transcode.c`,
`outputs.c`, `ptpd.c`. (`ptpd.c` is a real adaptation, see §4.)

**The T-PKG-1 scaffold shim *headers* were REWRITTEN**, not merely filled in:
they had speculative signatures/types that diverged from the real OwnTone
headers (which is what airplay.c actually compiles against). Each rewritten
header now mirrors the OwnTone declaration for the exact subset the cluster
uses. Key corrections the scaffold had wrong (all would have failed to compile
or linked with type-mismatch warnings):

- `output_status_cb` is `void(*)(struct output_device*, enum output_device_state)`
  (scaffold had `(uint64_t,uint64_t,enum)`).
- `outputs_cb(int callback_id, uint64_t, enum)` (scaffold had `uint64_t` cb id).
- `OUTPUT_STATE_FAILED = -1`, `OUTPUT_STATE_PASSWORD = -2` (negative; scaffold
  had them positive).
- `struct output_device` needs the full field set incl. bitfields
  (`v6_disabled` etc.), `type`, `type_name`, `state` — airplay.c reads them.
- `struct output_buffer.data[]` is `[MAX + 2]`, and `output_data` has an
  `evbuf` field.
- `ptpd_slave_add(uint32_t*, addr)`, `ptpd_slave_remove(uint32_t)` returns void,
  `ptpd_init(uint64_t clock_id_seed)` (scaffold had `int*`/`int`/`void*`).
- `transcode_frame` is `typedef void`; `transcode_encode(struct evbuffer*, ...)`;
  `transcode_frame_new(void*, ...)` (scaffold had a struct + wrong first args).
- `player_device_add/remove(void *device)` (scaffold had `struct output_device*`).
- `commands_base_new(evbase, command_exit_cb)` (scaffold had `void*`).
- `mdns` `MDNS_CONNECTION_TEST = (1 << 1)` (scaffold had `(1 << 0)`).
- `artwork_get_by_queue_item_id(..., int item_id, ...)` (scaffold had uint32_t)
  and it needs the `ART_FMT_PNG/JPEG` + `ART_DEFAULT_WIDTH/HEIGHT` macros.
- `dmap_encode_queue_metadata(songlist, song, queue_item)` — 3 args (scaffold 2).

Also: the T-PKG-1 scaffold declared `device_id_colon_parse/make` and
`device_id_hex` in `misc.h`. **Removed** — those are `static` functions/locals
*inside* airplay.c (lines 564/585/609/2899), not misc.h symbols; declaring them
would clash.

---

## 2. macOS-porting fixes (categorized)

### 2a. autotools artifact: `config.h` (README gap 1 & 2)

- `sender/plist_wrap.h` and (guarded) `libairptp/src/utils.h`, `rtp_common.c`,
  `misc.h` include `config.h`. OwnTone generates it via `configure`.
- **Fix:** hand-wrote `compat/config.h` defining only the macros the cluster
  reads (grepped): `PACKAGE_NAME` ("AirPlayEngine" — neutral, SPEC §4),
  `PACKAGE_VERSION`, `HAVE_DECL_PLIST_NEW_INT=1` (brew libplist has
  `plist_new_int`), `HAVE_LIBKERN_OSBYTEORDER_H=1`, `HAVE_GETADDRINFO`,
  `HAVE_GETNAMEINFO`, `HAVE_STRSEP`. It also `#include <limits.h>` (see 2d).
  Deliberately NOT defined: `HAVE_ENDIAN_H`, `HAVE_SYS_ENDIAN_H` (macOS has
  neither).
- **Force-included into every TU** via `-include config.h` + `-DHAVE_CONFIG_H`
  in the C target's `cSettings` (Package.swift). This is the autotools
  equivalent (`-include config.h`) and avoids editing the GPL/MIT vendored
  sources. `PACKAGE_NAME` in `airplay_events.c:218` — which includes no
  config.h itself — is resolved this way.

### 2b. endian byte-order helpers (README gap 3)

- `rtp_common.c`, `airplay.c` (via `misc.h`) and `libairptp/src/ptp_msg_handle.c`
  (via `utils.h`) use glibc `htobe16/32/64`, `be16toh/32toh/64toh`. macOS has
  no `<endian.h>`.
- **Fix (two paths, both activated):**
  1. `compat/endian_compat.h` maps every glibc name onto
     `<libkern/OSByteOrder.h>`'s `OSSwapHostToBigInt*` etc. (guarded with
     `#ifndef` so it's safe to include alongside the libairptp copy). Included
     from `shims/misc.h` (which `rtp_common.c`/`airplay.c` include) via the
     file-relative path `"../compat/endian_compat.h"` — file-relative so it
     resolves BOTH when the C sources compile AND when clang parses the module
     map for `import CAirPlayEngine` (that context lacks the C target's
     `-I` search paths).
  2. `libairptp/src/utils.h` already carried its own identical OSByteOrder
     fallback under `#elif defined(HAVE_LIBKERN_OSBYTEORDER_H)` — activated by
     defining that macro in `config.h`. So `ptp_msg_handle.c` gets its endian
     helpers through utils.h, no source edit needed.

### 2c. logger domain constants (README gap 4)

- `rtp_common.c` uses `L_PLAYER` (and the cluster uses `L_AIRPLAY`).
- **Fix:** `shims/logger.h` now carries the **full** OwnTone log-domain table
  (`L_CONF..L_RCP`, `L_PLAYER=16`, `L_AIRPLAY=30`) and severity table
  (`E_FATAL..E_SPAM`) verbatim, plus the exact `DPRINTF/DVPRINTF/DHEXDUMP`
  signatures (note `DHEXDUMP` takes `int data_len`).

### 2d. missing transitive includes (GNU-ism / include-graph assumptions)

- `airplay.c:3881` uses `CHAR_BIT` without including `<limits.h>` (relied on
  OwnTone's include graph). **Fix:** `compat/config.h` `#include <limits.h>`
  (force-included first everywhere).

### 2e. host-provided globals (link stage)

- `airplay.c:459` declares `extern struct event_base *evbase_player;` — the
  player thread's libevent base OwnTone's `player.c` owns. **Fix:** defined
  `struct event_base *evbase_player = NULL;` in `shims/outputs.c` (the engine
  runner shim). T-API-1 sets it to the engine thread's base before
  `airplay_init` (seam-map §8).
- `conffile.h` declares `extern uint64_t libhash;` (OwnTone: a hash of the
  library name, used by airplay.c as the device id + PTP clock-id seed at
  918/4291/4335). **Fix:** declared in `shims/conffile.h`, defined in
  `shims/conffile.c` with a fixed non-zero seed (TODO(T-SHIM-1): derive from
  the Swift-provided client name for a stable/unique id).

### 2f. config surface types (libconfuse stand-ins)

- airplay.c reads `cfgopt->nvalues` (4103) on a `cfg_opt_t`. **Fix:**
  `shims/conffile.h` makes `cfg_opt_t` a *complete* type exposing `nvalues`
  (cfg_t stays opaque). Accessors return the seam-map §3.1 defaults;
  `cfg_gettsec` returns NULL so all per-device override branches short-circuit.

### 2g. brew linkage (README gap 4 — the placeholder flag set)

- Resolved the placeholder `unsafeFlags` into a real, **portable** flag set:
  - Brew prefix resolved at manifest time via `$HOMEBREW_PREFIX` → `brew
    --prefix` → `/opt/homebrew` (arm64) / `/usr/local` (Intel) fallback. So the
    package builds on both brew layouts without editing Package.swift.
  - `-I<prefix>/opt/<formula>/include` and `-L.../lib` generated per formula
    (`libevent libsodium libgcrypt libgpg-error libplist ffmpeg`).
  - Linked libs: `event`, `sodium`, `gcrypt`, `gpg-error`, `plist-2.0`, and (as
    of T-SHIM-2) `avcodec`, `avutil`, `swresample` for the ffmpeg ALAC encoder
    (`shims/transcode.c`). Symbol-verified: the linked test binary references
    `_avcodec_find_encoder`/`_swr_convert`/`_av_frame_alloc`/`_avcodec_send_frame`
    and `otool -L` shows the three ffmpeg dylibs.
  - pair_ap built with **`CONFIG_GCRYPT`** (libgcrypt + libsodium, **zero
    openssl**) — verified by symbol scan of the compiled objects: `_gcry_*` and
    `_crypto_*` (sodium) undefineds present, **0** `EVP_/SSL_/OPENSSL_` symbols.

### 2h. Swift module import (`import CAirPlayEngine`)

- The umbrella header pulls in shim headers that `#include <event2/event.h>`,
  `<plist/plist.h>`, etc. A C target's `cSettings .unsafeFlags` do **not**
  propagate to a dependent Swift target's clang importer, so `import
  CAirPlayEngine` failed to find the brew headers.
- **Fix:** the AirPlayEngine Swift target now passes the same brew `-I` paths to
  the clang importer via `swiftSettings: .unsafeFlags(["-Xcc", "-I..."])`. A
  link-probe in `AirPlayEngine.swift` (`scaffoldBufferDurationMs` →
  `outputs_buffer_duration_ms_get()`) forces a genuine link-time dependency on
  the C cluster, and the new test `testCClusterLinks` asserts it returns 2250.

---

## 3. libairptp: source-vs-`.a` decision (seam-map §7.4, task item 5)

**Decision: fold libairptp in as VENDORED SOURCE** (the current layout), not a
prebuilt `.a`. Rationale:
- The 4 vendored `src/*.c` (`airptp.c`, `daemon.c`, `ptp_msg_handle.c`,
  `utils.c`) compile cleanly under SwiftPM's clang with only the endian +
  config compat already in place — no autotools needed.
- `libairptp/daemon/airptpd.c` (the standalone daemon binary, which has
  `main()`) is **not** vendored, so there's no `main()` collision and no
  separate build system.
- One build system, one dependency graph. The MIT PTP *helper* (T-HELPER-
  DESIGN-1) remains a separate future binary that links only libairptp — that
  severability is a licensing/packaging property, independent of how the engine
  compiles libairptp here.

---

## 4. Which shim bodies are REAL vs STUBBED (T-SHIM-1 starting state)

Legend: **REAL** = behaviorally correct now; **STUB** = links but does nothing
useful (TODO(T-SHIM-1) in the body); **PARTIAL** = minimal-real.

| shim | file | state | notes |
|---|---|---|---|
| logger | `logger.c` | **REAL (T-SHIM-2)** | DPRINTF/DVPRINTF → os_log (subsystem `com.airplayengine`) + stderr mirror for E_WARN and up (or `AIRPLAYENGINE_LOG_STDERR`). Severity gated by `AIRPLAYENGINE_LOG_LEVEL` (default E_LOG). DHEXDUMP does a real offset/hex/ascii dump (capped 512 B). Fresh code, not ported. |
| misc: `log_fatal_null` | `misc.c` | REAL | aborts on NULL (CHECK_NULL contract). |
| misc: `quality_is_equal` | `misc.c` | REAL | trivial field compare. |
| misc: `keyval_alloc` | `misc.c` | **REAL (T-SHIM-2)** | real calloc (ported). |
| misc: net_* | `misc.c` | **REAL (T-SHIM-2)** | net_bind/connect/socket_close/sockaddr_get/address_get/if_get/mac_get ported near-verbatim from OwnTone misc.c, trimmed to the macOS branch (AF_LINK net_mac_get; getifaddrs net_if_get). Compile+link only — **no socket opened to a real device yet** (that's T-API-1). |
| misc: keyval_add/get/clear | `misc.c` | **REAL (T-SHIM-2)** | full TXT keyval linked-list ported (case-insensitive get, dup-key handling). Unit-tested. |
| misc: safe_hextou32/64 | `misc.c` | **REAL (T-SHIM-2)** | strtoul/strtoull base-16 with range/errno checks, ported. Unit-tested. |
| misc: thread_setname, uuid_make | `misc.c` | **REAL (T-SHIM-2)** | thread_setname → macOS `pthread_setname_np(name)`; uuid_make → OwnTone's dependency-free PRNG variant (no libuuid). |
| conffile | `conffile.c` | **REAL (T-SHIM-2)** | Fresh in-memory config struct returns the seam-map §3.1 global keys (user_agent, library.name, bind_address, ipv6=true, timing/control_port=0, max_volume=11); `cfg_gettsec`→NULL. `conffile_set_*` setters let T-API-1 populate it from the Swift config. `libhash` = fixed seed + setter (real name-derivation still deferred to T-API-1). Defaults unit-tested. |
| commands | `commands.c` | REAL | trivial alloc/free is behaviorally complete (no dispatch needed). |
| player | `player.c` | **REAL (T-SHIM-2)** | player_device_add/remove ported from OwnTone player.c device_add/device_remove_family, run SYNCHRONOUSLY (no command queue) into the outputs.c registry: add takes ownership + marks advertised; remove clears the disappearing family and removes the device when both addresses gone AND no live session. get_status/playback controls stay no-op (audio-only sender). |
| db / artwork / dmap_common | `db.c`,`artwork.c`,`dmap_common.c` | REAL (no-op) | metadata path is cut (Q6) — permanent no-ops, not placeholders. |
| mdns | `mdns.c` | REAL (no-op) | `mdns_browse` returns 0; discovery is app-owned (Q5). |
| transcode | `transcode.c` | **REAL (T-SHIM-2, ffmpeg ALAC — Q2a first light)** | Purpose-built libavcodec ALAC encoder (NOT a port of OwnTone's 2645-LOC transcode.c): AV_CODEC_ID_ALAC, S16P planar, frame_size forced to 352 (same "misuse" hack as OwnTone), interleaved-S16→S16P via libswresample. `transcode_decode_setup_raw` records source quality; `transcode_encode` emits the raw ALAC packet into the evbuffer. avcodec/avutil/swresample now linked (Package.swift). **TODO(seam-map §5.3, R-C):** later swap to the vendored ~50-LOC uncompressed-ALAC encoder to shed ffmpeg — NOT done here. Compile+link + symbol-verified; **not run against a receiver** (that needs the two-host harness). |
| ptpd | `ptpd.c` | **REAL** | near-verbatim adaptation of OwnTone's ptpd.c against the vendored libairptp; only its includes were re-pointed at the shims. Compiles+links; not exercised at build time. |
| outputs (registry) | `outputs.c` | **REAL (T-SHIM-2)** | `outputs_device_add` now does the real OwnTone merge (re-appearing device: move addresses/name/password into the existing entry, free the incoming dup, mark advertised=1; new device: take ownership + prepend). `outputs_device_free` frees owned strings (name/auth_key/v4/v6_address), the stop_timer, and calls the backend `device_free_extra` (guarded on `extra_device_info` non-NULL — airplay_device_free_extra NULL-derefs otherwise). session add/remove, name/quality/buffer-duration/exclusive unchanged. |
| **outputs (`outputs_cb` dispatcher)** | `outputs.c` | **REAL — R-A DONE (T-SHIM-1)** | The R-A async-callback dispatcher is now implemented per `docs/outputs-dispatcher-contract.md`. It ports OwnTone outputs.c's callback machinery: a 64-slot callback-id registry (`outputs_callback_add`/`_remove`/`_get`, replace-on-add per device), `outputs_cb` marks a slot ready + defers delivery on `evbase_player` (never inline — re-entrancy safe), and a deferred drain (`deferred_cb` / `outputs_cb_deferred_run`) re-resolves the device by `device_id`, updates `device->state`, invokes the `output_status_cb`, drops a stopped/failed unheld device, and fires an **engine completion hook** (`outputs_engine_completion_set`) that unblocks T-API-1's async waiter. Contract enforced: **N ∈ {0,1}, exactly once per `callback_id`**; negative/out-of-range/empty ids are defensive no-ops (never hang); the pending slot is NOT cleared on session teardown, so the `start_retry` id-hand-off (contract §4c) still delivers exactly one completion. Verified by `OutputsDispatcherTests` (9 cases: normal/error/password/auth-retry/replace-on-add/N=0-flush/illegal-ids/stop-removes-dead-device/multi-device). |
| `evbase_player` global | `outputs.c` | PARTIAL | defined as NULL; T-API-1 sets it, then calls `outputs_dispatcher_init()` (wires the deferred event to the base) before `airplay_init`. |

### Functions still needing REAL bodies

All the T-SHIM real-session shim bodies are now implemented (R-A dispatcher in
T-SHIM-1; the rest in T-SHIM-2). Remaining work is **T-API-1** (the Swift
wrapper) + a later ffmpeg-shedding swap, NOT more shim bodies:

1. ~~`outputs_cb` — the async-callback dispatcher (**R-A**).~~ **DONE (T-SHIM-1).**
2. ~~`misc.c` net helpers (net_bind/connect/socket_close/sockaddr_get/address_get/
   if_get/mac_get).~~ **DONE (T-SHIM-2)** — ported, macOS branch, compile+link only.
3. ~~`misc.c`: keyval_add/get/clear, safe_hextou32/64, thread_setname, uuid_make.~~
   **DONE (T-SHIM-2).**
4. ~~`transcode.c`: ffmpeg-backed ALAC encoder + avcodec/avutil/swresample link.~~
   **DONE (T-SHIM-2, Q2a).** TODO(seam-map §5.3): the later uncompressed-ALAC swap
   to drop ffmpeg (R-C) is deliberately NOT done — needs the live receiver harness.
5. ~~`conffile.c`: real static config struct + libhash.~~ **DONE (T-SHIM-2)** —
   struct + setters in place; deriving `libhash` from the Swift client name is the
   only residual (needs the name → T-API-1 calls `conffile_set_libhash`).
6. ~~`player.c`: wire player_device_add/remove into the registry.~~ **DONE
   (T-SHIM-2).** (Swift device-added/removed events are surfaced by the app-side
   discovery layer, not from inside the C cluster.)
7. ~~`logger.c`: os_log routing + env-gated severity.~~ **DONE (T-SHIM-2).**
8. ~~`outputs.c`: registry ownership/merge + string-freeing outputs_device_free +
   device_free_extra.~~ **DONE (T-SHIM-2).**

**Precise remaining gap before a real session (T-API-1's job):** see §6 below.

---

## 5. Verification performed (no runtime — compile + link only, per task)

- `swift build` (clean): **Build complete**, 0 warnings, all 24 C files compile.
- `swift build --build-tests`: **links** the test executable — no undefined
  symbols (the whole C archive resolves against brew event/sodium/gcrypt/
  gpg-error/plist-2.0).
- `nm` on the linked test binary: `_airplay_init`, `_airplay_write`,
  `_output_airplay` present; no undefined cluster symbols.
- pair_ap object scan: gcrypt+sodium symbols, **0** openssl.
- `swift test`: 2 scaffold tests pass (incl. the C-cluster link probe).
- **No audio / network / PTP was run.** This is a headless compile+link task.

### T-SHIM-2 verification (compile + unit-level only)

- Clean `swift build`: **Build complete, 0 warnings** (all shims + vendored C).
- `swift test`: **17 tests pass** — the 9 dispatcher tests (unchanged behaviour,
  see the makeDevice note), 2 scaffold, and 6 new focused T-SHIM-2 tests
  (`ShimUnitTests`: keyval add/get/clear + dup-key, safe_hextou32/64, conffile
  defaults, conffile setters). Stable across repeated runs (an earlier NULL-deref
  in `outputs_device_free` via `airplay_device_free_extra` was fixed by guarding
  on `extra_device_info`).
- ffmpeg link verified by `nm -u` (encoder/resampler symbols referenced) +
  `otool -L` (libavcodec.62 / libavutil.60 / libswresample.6 dylibs).
- **Still NO real network/PTP/audio session** — no socket opened to a real
  device, no libevent loop run against hardware. The net helpers and the ALAC
  encoder are compile+link + unit-verified only. Driving a real session is
  T-API-1 (gated on the receiver harness).

---

## 6. Precise remaining gap before a real session (what T-API-1 must do)

Every real-session shim body now exists. The engine still cannot attempt a
session because **nothing creates/owns the engine thread + event base or calls
the entry points**. T-API-1 (the Swift wrapper) must, in order:

1. **Own the engine thread + base (seam-map §8, risk R-B).** Create one
   `event_base` on one dedicated thread, set the shim global
   `evbase_player = <that base>` (declared in `shims/outputs.c`) BEFORE
   `airplay_init`, and run `event_base_dispatch` on it. All C entry points below
   must be marshalled onto this thread.
2. **Wire the dispatcher to the loop.** After setting `evbase_player`, call
   `outputs_dispatcher_init()` (creates the deferred-delivery event on the base)
   and `outputs_engine_completion_set(cb, ctx)` so the completion hook resumes
   the Swift async waiter that armed each `callback_id`. (In unit tests the drain
   is driven synchronously; in production it fires off the libevent event.)
3. **Populate config from the Swift session config** via the new
   `conffile_set_*` setters (user_agent, library name, bind_address, ipv6,
   timing/control ports) and derive + set `libhash` from the client name
   (`conffile_set_libhash`) so the device id / PTP clock-id seed is stable.
   The strings passed are NOT copied — keep them alive for the engine's lifetime.
4. **Start the backend:** call `output_airplay.init()` (== `airplay_init`) on the
   engine thread. This starts the timing/control UDP services (now real
   `net_bind`), the keep-alive timer, `ptpd_init`, and `airplay_events_init`.
5. **Feed discovery:** for each speaker the app-side NWBrowser finds, build an
   `output_device` (+ `airplay_extra` with `mdns_name`, and the TXT `keyval`) and
   call `airplay_device_cb(...)` (seam-map §4), which parses features/deviceid
   (now real `keyval_get`/`safe_hextou*`) and calls `player_device_add` (now real
   → registry). Removal calls the same cb with `port < 0`.
6. **Drive a session:** `outputs_callback_add(device, statusCb)` to get a
   `callback_id`, then `output_airplay.device_start(device, callback_id)`; wait
   for the deferred completion (STREAMING/PASSWORD/FAILED). Then `device_volume_set`,
   and pump PCM via `output_airplay.write(output_buffer)` **on the engine thread**
   (risk R-B — the write path shares unlocked state with the loop). The ALAC
   encoder (now real) turns each 352-sample PCM16 frame into an ALAC packet.

**What (if anything) still blocks T-API-1:**

- **Nothing blocks starting the wrapper.** All C symbols it needs exist, compile,
  and link. It can be written and its non-session bits (config, discovery,
  registry, dispatcher wiring) unit-tested immediately.
- **What blocks a *successful* real session is not shim code — it's runtime
  validation that can only happen against a receiver** (the two-host harness):
  the R-A callback-count accounting under real error/retry/reconnect paths
  (§10.1), the R-B write-thread cadence/backpressure (§10.2), the ALAC-frame
  acceptance by AP2 receivers (R-C, §10.3 — ffmpeg path is the validated one, so
  we ship it first), and macOS `net_if_get`/v6-scope-id behaviour for PTP peers
  (§10.4). Those are T-API-1 / receiver-testing concerns, explicitly out of scope
  for the compile+unit-level shim work.
- **One residual shim nicety, not a blocker:** `libhash` is still a fixed seed
  until T-API-1 passes a real client name to `conffile_set_libhash`. The engine
  runs fine with the fixed seed (device id is just non-unique across installs).
