# AirPlay 2 sender — seam-cutting map (T-SEAM-1)

**Source:** `dev/owntone-src` — OwnTone pinned at tag **29.2**.
**Goal:** extract the AirPlay 2 *sender* cluster into the SwiftPM package
`AirPlayEngine/` (target `CAirPlayEngine`), replacing all OwnTone plumbing with
thin shims we own. This document is the blueprint for T-PKG-1 / T-BUILD-1 /
T-SHIM-1 / T-API-1.

Grounded in a line-by-line read of `outputs/airplay.c` (4411 LOC),
`outputs/airplay_events.c` (545), `outputs/rtp_common.c` (441), `outputs.h`,
`ptpd.c`, `libairptp/airptp.h`, `conffile.c`, `mdns.h`, `transcode.h`, and the
AirPlay-1 sibling `outputs/raop.c` (for the ALAC verdict).

Line numbers below are **tag-29.2 absolute** and will drift if the clone moves.

---

## 0. TL;DR verdicts (report answers)

- **Cluster size:** 8 vendored source dirs/files → **16 core files, ~13,769 LOC**
  (GPL sender + rtp_common + evrtsp + pair_ap) **+ libairptp ~2,679 LOC** =
  **~16,448 LOC** if libairptp is folded in as source (it can instead build as
  its own `.a` — see §7).
- **Shims:** **10 shim headers/units**, **~900–1,150 LOC total** (the reimplemented
  `outputs.c`/device-registry is the bulk, ~350–450 LOC).
- **ALAC verdict — YES, a PCM-only path exists and is portable.** airplay.c as
  shipped *hardcodes* ALAC via ffmpeg (`XCODE_ALAC`), but the AP2 protocol itself
  advertises LPCM formats, and the AP1 sibling `raop.c` contains a **~50-line
  dependency-free "uncompressed ALAC" encoder** (`alac_encode_uncompressed`) that
  emits an ALAC-framed packet whose body is raw PCM (`ct=2`, `is-not-compressed`
  bit set). Dropping that into airplay.c's `alac_encode()` removes the entire
  ffmpeg/transcode dependency. **Recommendation: ship ffmpeg first (Q2a) to match
  the validated codepath, then swap to the vendored uncompressed encoder to shed
  ffmpeg.** Full detail in §5.
- **Top-3 risks:** (R-A) `outputs.c` device-registry + async-callback contract
  reimplementation is load-bearing and easy to get subtly wrong; (R-B) libevent
  threading across the Swift FFI — the whole cluster assumes one `evbase_player`
  owned by one thread, and `airplay_write()` must run on that thread; (R-C) the
  ALAC-uncompressed swap is statically plausible but unproven on a real receiver
  (bit-exactness of the ALAC frame header for AP2 `ct=2`).

---

## 1. Includes in the three GPL files, classified

### `outputs/airplay.c` (line 21–59)

| # | include | class | disposition |
|---|---------|-------|-------------|
| libc | `stdio/stdbool/unistd/stdint/inttypes/math/errno/sys/socket/netdb/fcntl/time/arpa/net/netinet` | — | system, keep |
| `<event2/event.h>`, `<event2/buffer.h>` | **KEEP (real dep)** | brew libevent |
| `<gcrypt.h>` | **KEEP (real dep)** | brew libgcrypt |
| `"plist_wrap.h"` | **KEEP** | self-contained helper in `outputs/`, wraps brew libplist. Copy as-is. |
| `"evrtsp/evrtsp.h"` | **KEEP (vendored)** | evrtsp cluster |
| `"conffile.h"` | **SHIM** | → static config struct (§3) |
| `"logger.h"` | **SHIM** | DPRINTF/DHEXDUMP/DVPRINTF → log shim (§3) |
| `"mdns.h"` | **SHIM (discovery seam)** | app-owned NWBrowser feeds descriptors (§4). The `mdns_browse` call is cut; the `mdns_browse_cb` shape is reproduced as the Swift→C `addOutput`/`removeOutput` entry. |
| `"misc.h"` | **SHIM (partial)** | reimplement only the ~19 helpers airplay.c uses (§3) |
| `"player.h"` | **REPLACE-with-Swift-callback / STUB** | only 2 symbols: `player_device_add`, `player_device_remove` (§3) |
| `"db.h"` | **STUB-noop** | only in metadata path (§3, Q6) |
| `"artwork.h"` | **STUB-noop** | only in metadata path (§3, Q6) |
| `"dmap_common.h"` | **STUB-noop** | only in metadata path (§3, Q6) |
| `"rtp_common.h"` | **KEEP (vendored)** | rtp_common.c is part of the cluster |
| `"transcode.h"` | **SHIM (ALAC)** | 8 fns; ffmpeg-backed first, replaceable (§5, Q2) |
| `"ptpd.h"` | **SHIM (reimplement on airptp_\*)** | copy `ptpd.c` almost verbatim; it already only calls `airptp_*` + `cfg_getstr` + logger (§6) |
| `"outputs.h"` | **SHIM (the big one)** | reimplemented backend seam + device registry (§2, §3) |
| `"airplay_events.h"` | **KEEP (vendored)** | cluster |
| `"pair_ap/pair.h"` | **KEEP (vendored)** | pair_ap cluster |

### `outputs/airplay_events.c` (line 21–41)

Adds over airplay.c: `<pthread.h>` (KEEP), `<plist/plist.h>` (KEEP — brew libplist
directly), `"commands.h"` (**STUB — see §3.7**), `"player.h"` (**REPLACE/STUB —
the 6 playback-control functions, §3.6**). Everything else already classified.

### `outputs/rtp_common.c` (line 23–38)

Only `<gcrypt.h>` (KEEP), `"logger.h"` (SHIM), `"misc.h"` (SHIM), `"rtp_common.h"`
(KEEP). **rtp_common.c has zero OwnTone-plumbing entanglement beyond logger +
misc** — cleanest file in the cluster.

---

## 2. The `outputs.h` contract — becomes our C API skeleton

`struct output_definition output_airplay` (airplay.c:4385) is the interface
airplay.c *implements*. Reproduce `outputs.h`'s types in the shim; the shim's
`outputs.c` is our reimplemented backend runner + device registry.

### 2.1 `struct output_definition` entry airplay.c fills (airplay.c:4385–4411)

| field | value | semantics for the engine |
|-------|-------|--------------------------|
| `.name` | `"AirPlay 2"` | rename neutrally in product; string only |
| `.cfg_name` | `"airplay"` | config section name → our config struct key |
| `.type` | `OUTPUT_TYPE_AIRPLAY` | keep the enum value; only AIRPLAY survives |
| `.priority` | 1 or 2 | irrelevant with a single backend; drop |
| `.init` | `airplay_init` | one-time: start timing+control UDP services, keep-alive timer, `ptpd_init`, `airplay_events_init`. Returns 0/-1. Engine `start()`. |
| `.deinit` | `airplay_deinit` | teardown all sessions, stop services, `ptpd_deinit`. Engine `stop()`. |
| `.device_start` | `airplay_device_start` | begin RTSP setup sequence to a device. **Returns 1** (one pending cb). |
| `.device_stop` | `airplay_device_stop` | TEARDOWN sequence. Returns 1. |
| `.device_flush` | `airplay_device_flush` | flush; returns **0 if not streaming (no cb)** else 1. |
| `.device_probe` | `airplay_device_probe` | connectivity probe sequence. Returns 1. |
| `.device_cb_set` | `airplay_device_cb_set` | rebind the pending callback id on the live session. Returns void. |
| `.device_free_extra` | `airplay_device_free_extra` | free `airplay_extra` (mdns_name + struct). |
| `.device_volume_set` | `airplay_set_volume_one` | send SET_PARAMETER volume; returns 1 or 0. |
| `.device_volume_to_pct` | `airplay_volume_to_pct` | parse device volume string → pct. Pure. |
| `.write` | `airplay_write` | **the hot path** — feed one `output_buffer` of PCM; packetizes + sends RTP. Void, synchronous (§8). |
| `.metadata_prepare` | `airplay_metadata_prepare` | **STUB → return NULL** (Q6) |
| `.metadata_send` | `airplay_metadata_send` | **STUB → no-op** (Q6) |
| `.metadata_purge` | `airplay_metadata_purge` | **STUB → no-op** (Q6) |
| `.device_authorize` | `airplay_device_authorize` | PIN pairing sequence (Q7 transient path). Returns 1. |
| `.device_quality_set` | *(not set)* | leave NULL |

**The async callback contract (critical):** every `device_*` returning a positive
N promises to call **`outputs_cb(callback_id, device_id, state)`** exactly N times
(see airplay.c:1094 in `session_status()`; the state maps to
`enum output_device_state`). The player/engine blocks waiting for these. Our shim
`outputs_cb` must translate `(callback_id, device_id, state)` into a Swift-visible
event and unblock whatever issued the request. **Getting the N-callbacks
accounting wrong = engine hangs.** This is risk R-A.

### 2.2 `outputs.c`-owned symbols airplay.c *calls back into* (the registry seam)

These are provided by OwnTone's `outputs.c`; our shim must reimplement them:

| symbol | airplay.c sites | shim behavior |
|--------|-----------------|---------------|
| `outputs_list()` | 614 | iterate our device registry (used by `device_id_find_byname`) |
| `outputs_device_get(id)` | 2939,2969,2996,3279,3435,3504,3531,3574 | lookup device by id |
| `outputs_device_add(dev,bool)` | *(via player_device_add path)* | insert/replace in registry; **owns the merge of new vs existing device** |
| `outputs_device_remove/free(dev)` | 4136 (+player path) | remove/free |
| `outputs_device_session_add(id,session)` | 1639 | attach opaque session to device |
| `outputs_device_session_remove(id)` | 1281 | detach |
| `outputs_cb(cb_id,id,state)` | 1094 | **async completion → Swift event** (see 2.1) |
| `outputs_name(type)` | 4006 | return "AirPlay 2" (or neutral name) |
| `outputs_quality_subscribe/unsubscribe(q)` | 1164 (+cleanup) | trivial: track the single 44100/16/2 quality; return 0 |
| `outputs_buffer_duration_ms_get()` | 1196 | return configured `start_buffer_ms` (default 2250) |
| `outputs_exclusive_mode_get()` | 3980 | return false (single-purpose engine) |

`player_device_add/remove` (airplay.c:4129/4026) are the *other* direction —
discovery telling the registry a device appeared/vanished. Since discovery is
app-owned (§4), these become the C entry points the Swift `addOutput/removeOutput`
call, i.e. they *populate* the registry directly (they can be merged with
`outputs_device_add/remove`).

### 2.3 Types to reproduce in the shim `outputs.h`

`enum output_types` (keep only AIRPLAY), `enum output_device_state`
(STOPPED/STARTUP/CONNECTED/STREAMING/FAILED/PASSWORD), `struct output_device`
(the full struct — airplay.c reads `id,name,password,auth_key,volume,relvol,
max_volume,quality,offset_ms,v4_address/port,v6_address/port,requires_auth,
extra_device_info,session,resurrect,supported_formats,selected_format`),
`struct output_metadata` (can be minimal — metadata is stubbed),
`struct output_data`, `struct output_buffer` (the PCM carrier — §8),
`struct media_quality` (from misc.h: sample_rate/bits_per_sample/channels),
`enum media_format` (only `MEDIA_FORMAT_ALAC` used, airplay.c:4008),
`output_status_cb` typedef, and the `OUTPUTS_MAX_QUALITY_SUBSCRIPTIONS` (5) macro
that sizes `output_buffer.data[]`.

---

## 3. The SHIM inventory (per-symbol dispositions + defaults)

### 3.1 conffile / `cfg_*` — every key airplay.c (+ptpd.c) reads, with default

Reimplement `cfg_getstr/getint/getbool/gettsec/getsec/getopt/opt_getnbool` as a
**static config struct** populated from the Swift API. There are **two scopes**:
global keys and per-device keys.

**Global / shared (read once at init):**

| key (section) | airplay.c line | type | default (conffile.c) | notes |
|---|---|---|---|---|
| `general.user_agent` | 4308 | str | `"OwnTone/<ver>"` (:76) | → neutral UA string; sent in RTSP |
| `library.name` | 4309 | str | `"My Music on %h"` (:86) | client name advertised to receiver |
| `airplay_shared.timing_port` | 4311 | int | `0` (:171) | 0 = ephemeral bind |
| `airplay_shared.control_port` | 4319 | int | `0` (:170) | 0 = ephemeral bind |
| `general.start_buffer_ms` | via `outputs_buffer_duration_ms_get` | int | `2250` (:79) | must exceed AIRPLAY_AUDIO_LATENCY_MS |
| `general.bind_address` | ptpd.c:77 | str | none (`::` → NULL) | PTP bind addr; usually NULL |
| `airplay_shared.uncompressed_alac` | **NOT read by airplay.c** | bool | `false` (:172) | only raop.c (AP1) reads it — see §5 |

**Per-device (read in `airplay_device_cb`, keyed by mdns name — all optional):**

| key (`airplay.<name>`) | line | type | default | engine mapping |
|---|---|---|---|---|
| `max_volume` | 1793 | int | `11` (:179) | per-output max volume |
| `exclude` | 3970 | bool | `false` (:180) | drop from list |
| `permanent` | 3975 | bool | `false` (:181) | keep on disappear |
| `exclusive` | 3980 | bool | `false` (:188) | tied to exclusive_mode (return false) |
| `airplay2_disable` | 3985 | bool | `false` (:185) | force-skip AP2 |
| `nickname` | 3990,3992 | str | NULL (:186) | rename device |
| `password` | 3994,3996 | str | NULL (:183) | RTSP auth |
| `ptp_disable` | 4064 | bool | `false` (:189) | disable PTP for device |
| `reconnect` | 4102,4104 | bool (NODEFAULT) | unset (:182) | auto-reconnect; unset→ATV/HomePod heuristic |

**Shim decision:** all per-device keys default to their "off/absent" value; the
engine exposes just `nickname`, `password`, `max_volume`, `ptp_disable` on the
`addOutput` descriptor and hardcodes the rest to defaults. `cfg_gettsec` returns
NULL when no override → all the `if (devcfg && ...)` branches short-circuit.
**~80–120 LOC.**

### 3.2 logger — `logger.h` (SHIM, ~40 LOC)

3 macros/fns to provide: `DPRINTF(sev,dom,fmt,...)` (used **~137×**),
`DVPRINTF(sev,dom,fmt,ap)` (ptpd.c logmsg), `DHEXDUMP(sev,dom,data,len,head)`
(rtp_common, airplay_events, ptpd). Severities `E_FATAL..E_SPAM` (0–5), domain
`L_AIRPLAY=30`. Map to `os_log`/stderr gated by an env level. Keep the enum
constants. `thread_setname(name)` (from misc.h, used by ptpd + airplay_events)
also lives here or in misc shim.

### 3.3 misc — `misc.h` (SHIM partial, ~250–350 LOC)

Reimplement only these (all called by airplay.c/rtp_common.c/airplay_events.c):

- **net helpers** (the biggest chunk): `net_bind(&sock,&port,SOCK_DGRAM,name)`
  (timing/control services, airplay.c:2229), `net_connect(addr,port,type,name)`
  (RTSP + events channel), `net_socket_close`, `net_sockaddr_get`,
  `net_address_get`, `net_if_get` (ipv6 link-local scope for PTP peers,
  airplay.c:3159), `net_mac_get`, `net_socket` — plus `struct net_socket
  {int fd4;int fd6;}` and `union net_sockaddr {sockaddr_in/in6/sa/ss}`. These are
  ordinary BSD-socket wrappers; portable to macOS with minor `SO_REUSEPORT`/
  scope-id care.
- **device_id helpers:** `device_id_colon_parse/make`, `device_id_hex`. String↔u64.
- **keyval:** `keyval_get/add/clear` (+ `struct keyval`) — the TXT-record parser
  interface (§4). ~60 LOC.
- **quality:** `quality_is_equal(a,b)`.
- **macros:** `STOB(s,bits,c)=(s*c*bits/8)`, `CHECK_NULL(dom,expr)`,
  `CHECK_ERR*` (only CHECK_NULL used in cluster).
- **`thread_setname`** (see logger note).

`device_id_find_byname` is **defined inside airplay.c** (line 609) and iterates
`outputs_list()` — it stays; it just needs our registry behind `outputs_list`.

### 3.4 db / artwork / dmap — STUB-noop (Q6)

All three appear **only in the metadata-send path**, which we stub:
- `db_queue_fetch_byitemid(item_id)` — airplay.c:1686 (inside metadata_prepare)
- `artwork_get_by_queue_item_id(...)` — airplay.c:1698
- `dmap_encode_queue_metadata(...)` — airplay.c:1708
- `db_speaker_save(device)` — airplay.c:3512 (volume persistence)

Since `metadata_prepare`/`metadata_send`/`metadata_purge` become no-ops (return
NULL / return), lines 1686–1708 are never reached — the db/artwork/dmap headers
reduce to empty stubs (or the functions can be deleted along with the metadata
functions' bodies). `db_speaker_save` at 3512 → **no-op** (volume persistence, if
wanted, lives in Swift). Confirm the volume path around 3504–3531 still completes
its callback after we no-op the save (it does — save is fire-and-forget).

**Metadata functions to gut:** `airplay_metadata_prepare` (→ return NULL),
`airplay_metadata_send` (→ no-op), `airplay_metadata_purge` (→ no-op), plus the
helpers they call (`rtp_metadata_*`, the progress/artwork senders around
1650–1780). Simplest: keep the functions, early-return, let dead code sit (it
won't link db/artwork if those symbols are stubbed empty). ~30 LOC of stubs.

### 3.5 mdns — SHIM/CUT (discovery seam, §4)

`mdns_browse("_airplay._tcp", airplay_device_cb, MDNS_CONNECTION_TEST)` at 4342 is
the **only** mdns call. **Cut `mdns_init/register/cname` entirely.** Replace the
browse registration with a direct C entry that lets Swift invoke
`airplay_device_cb(name,type,domain,hostname,family,address,port,txt)` — see §4.

### 3.6 player — REPLACE-with-Swift-callback / STUB

- `player_device_add(device)` (airplay.c:4129) / `player_device_remove(device)`
  (4026): the discovery→registry direction. Merge into the registry shim; they
  add/remove in our list and emit a Swift `deviceAdded/Removed` event. Return 0.
- `airplay_events.c` playback controls (speaker's remote → *our* transport):
  `player_get_status(&status)` (→ fill a minimal status; `PLAY_PLAYING` enum),
  `player_playback_pause/start/next/prev`. **Audio-only sender: STUB to no-op**
  (or forward as optional Swift "remote-control received" events). `struct
  player_status` needs one field `status`. ~20 LOC.

### 3.7 commands — STUB (airplay_events.c only)

`commands_base_new(evbase, NULL)` (:507) and `commands_base_destroy(cmdbase)`
(:530). The `cmdbase` is created and destroyed but **never used to dispatch** any
command in airplay_events.c. Provide a trivial `struct commands_base` +
`commands_base_new` (alloc, stash evbase) + `commands_base_destroy` (free). Do
**not** vendor the full `commands.c`/evthr machinery. ~15 LOC.

### 3.8 transcode — SHIM (ALAC), §5, Q2

8 symbols: `transcode_frame_new`, `transcode_frame_free`, `transcode_encode`,
`transcode_encode_setup`, `transcode_encode_cleanup`, `transcode_decode_setup_raw`,
`transcode_decode_cleanup`, `struct transcode_encode_setup_args`, enums
`XCODE_ALAC`/`XCODE_PCM16`, opaque `encode_ctx`/`decode_ctx`, typedef
`transcode_frame`. Two implementations possible (§5).

### 3.9 ptpd — SHIM (reimplement on airptp_*), §6

Copy `ptpd.c` (135 LOC) nearly verbatim — it already only depends on
`libairptp/airptp.h` + logger + `cfg_getstr(general.bind_address)` +
`thread_setname`. Only change: the two `cfg_getstr`/logger calls point at our
shims. This is the thinnest shim.

### 3.10 outputs.c registry/runner — SHIM (the big one), §2.2

The reimplemented device registry + async-callback dispatcher + quality-sub
tracker + buffer helpers. **~350–450 LOC.** Load-bearing; risk R-A.

---

## 4. Discovery seam (Q5 — app-owned NWBrowser)

**What airplay.c registers:** a single browse for `_airplay._tcp` with callback
`airplay_device_cb` (airplay.c:4342). Nothing else is advertised or registered by
the sender.

**What the callback receives** (`mdns_browse_cb` signature, mdns.h:15):
```
void airplay_device_cb(const char *name, const char *type, const char *domain,
                       const char *hostname, int family, const char *address,
                       int port, struct keyval *txt);
```
- `name` — service instance name (also the device identity key via mdns_name).
- `family` — `AF_INET` / `AF_INET6`.
- `address` — resolved numeric IP string (`v4_address`/`v6_address`).
- `port` — RTSP port; **`port < 0` (or the code's `port > 0` guard) signals
  "device disappeared"** → triggers `player_device_remove`.
- `txt` — a `struct keyval` (linked list of key/value strings from the DNS-SD TXT
  record), queried by `keyval_get`.

**TXT keys airplay.c actually reads** (airplay.c:3943–4098):

| TXT key | line | use |
|---|---|---|
| `deviceid` | 3943 | `device_id_colon_parse` → 64-bit device id (also Active-Remote) |
| `features` | 4034 | parsed by `features_parse` into a sub-keyval; gates AP2 |
| `model` | 4083 | device-type heuristic (AirPort/AppleTV/HomePod) → reconnect + keep-alive behavior |

**`features` flags consumed** (after `features_parse`, 4045–4064): `SupportsAirPlayAudio`
(required), `SupportsCoreUtilsPairingAndEncryption` (required — else fall back to
AP1, which we don't have → skip), `MetadataFeatures_0/1/2` (artwork/progress/text —
**irrelevant, metadata stubbed**), `Authentication_8` (`supports_auth_setup`),
`SupportsPTP` (→ `use_ptp`).

**What the app-side NWBrowser must feed the engine's `addOutput` descriptor:**
- `name` (string, instance name)
- `deviceid` (u64, from the TXT `deviceid`, colon-hex `XX:XX:...`)
- `address` + `family` + `port` (resolved endpoint)
- `features` (either the raw TXT `features` string, letting the vendored
  `features_parse` run, **or** pre-parsed booleans: `supportsAirPlayAudio`,
  `supportsCoreUtilsPairingAndEncryption`, `supportsPTP`, `authentication8`)
- `model` (string, for the reconnect/keep-alive heuristic — optional; default
  `AIRPLAY_DEV_OTHER`)
- optional overrides: `nickname`, `password`, `maxVolume`, `ptpDisable`.

**Seam-creep check (R3):** airplay.c's device lifecycle is **NOT** deeply entangled
with live mdns callbacks. The only lifecycle coupling is: (1) add on browse-appear
→ `player_device_add`; (2) remove on browse-disappear (matched by `mdns_name` via
`device_id_find_byname` over `outputs_list()`). Both are cleanly expressible as
`addOutput(descriptor)` / `removeOutput(id)` C entry points that manipulate our
registry. **Q5(a) confirmed feasible — cut `mdns.h` entirely.** The one subtlety:
disappear-matching uses the mdns instance `name`, so `removeOutput` should key on
the same `name`/id the app used in `addOutput`.

---

## 5. ALAC verdict — is there a PCM-only path? **YES.**

### 5.1 What airplay.c does today (ffmpeg-required)

- `master_session_make` (airplay.c:1148) unconditionally sets up an ALAC encoder:
  `encode_args.profile = XCODE_ALAC` (:1152); source ctx from
  `transcode_decode_setup_raw(XCODE_PCM16, quality)` (:1181);
  `transcode_encode_setup(encode_args)` (:1188). On failure it logs *"ffmpeg has
  no ALAC encoder"* (:1192) — OwnTone's `transcode.c` wraps libavcodec.
- Per packet, `packets_send` → `alac_encode` (:2087) → `transcode_encode(...)`
  (:511) actually ALAC-compresses the 352-sample PCM frame.
- SETUP advertises `audioFormat=0x40000` (ALAC/44100/16/2) and `ct=2` (ALAC)
  (airplay.c:2623–2626). **These are hardcoded** — no runtime PCM branch here.

**So in tag-29.2, airplay.c has NO uncompressed/PCM branch of its own.**
`uncompressed_alac` (conffile.c:172) is read **only by `raop.c`** (AP1), confirmed
by a tree-wide grep — airplay.c never references it.

### 5.2 The protocol DOES support PCM/LPCM

The `audioFormat` bitfield comment (airplay.c:2578–2610) enumerates LPCM formats
(`ct=1`, e.g. `0x800` = PCM/44100/16/2) alongside ALAC (`ct=2`). So AP2 receivers
can accept LPCM. However, the least-risky "no-ffmpeg" route is **not** switching to
`ct=1` LPCM (untested against our fleet) but reusing the AP1 uncompressed-ALAC
trick, which keeps `ct=2`/`audioFormat=0x40000` (what airplay.c already sends) but
fills the ALAC frame with raw PCM instead of compressed data.

### 5.3 The portable uncompressed encoder (from raop.c — the ALAC alternative)

`raop.c` proves this is a ~50-line, dependency-free operation:
- `alac_encode()` (raop.c:484) branches on `raop_uncompressed_alac`:
  `alac_encode_no_xcode()` (raop.c:441) vs the ffmpeg path.
- `alac_encode_no_xcode` → `alac_encode_uncompressed(dst,raw,len)` (raop.c:411):
  writes a **3-bit-header ALAC frame** (`channel=1 stereo`, `is-not-compressed=1`),
  then byteswaps the PCM samples to big-endian into the bitstream, then a 3-bit
  end tag. `ALAC_HEADER_LEN=3`, output size `= 3 + rawbuf_size + 1`.
- No ffmpeg, no libavcodec — pure bit-packing with `alac_write_bits`.

**Plan:** (Q2a) link ffmpeg first to reproduce OwnTone's validated path and get
first light; then vendor `alac_encode_uncompressed` + `alac_write_bits` +
`ALAC_HEADER_LEN` from raop.c into airplay.c's `alac_encode()`, delete the
transcode/ffmpeg dependency, and re-verify. The `transcode.h` shim then collapses
to a couple of no-op stubs (the encode_ctx becomes unused). This is the biggest
single dependency win available and turns "read-it-line-by-line" back into reach.

**Residual risk (R-C):** the uncompressed frame is validated for AP1 receivers;
its bit-exactness for an AP2 `ct=2` stream is statically plausible (same ALAC
framing, same `spf=352`) but must be proven on the real two-host receiver harness
before committing to drop ffmpeg. Keep ffmpeg behind a build flag until then.

---

## 6. ptpd.h seam — how airplay.c consumes libairptp

airplay.c never calls `airptp_*` directly; it goes through the thin `ptpd.c`
wrapper (which we vendor as a shim). The functions airplay.c calls and their
libairptp backing (ptpd.c):

| airplay.c call | line | ptpd.c → libairptp |
|---|---|---|
| `ptpd_init(libhash)` | 4335 | `airptp_daemon_start(hdl, clock_id_seed, is_shared=false)` (private daemon) or `airptp_daemon_find()` for the client case |
| `ptpd_clock_id_get()` | 1173, 2741 | `airptp_clock_id_get(&id, hdl)` |
| `ptpd_slave_add(&slave_id, addr)` | 3167 | `airptp_peer_add(&peer_id, addr, hdl)` |
| `ptpd_slave_remove(slave_id)` | 1245 | `airptp_peer_remove(peer_id, hdl)` |
| `ptpd_deinit()` | 4382 | `airptp_end(hdl)` |
| `ptpd_find_or_bind()` | *(called from main.c, root)* | `airptp_daemon_find()` else `airptp_daemon_bind(bind_address)` — **the only privileged step** (binds UDP 319/320) |

**Clock-id flow into the protocol:**
1. Init picks/seeds a clock id (`ptpd_init` → `airptp_daemon_start`).
2. **SETUP:** `payload_make_setup` (airplay.c:2741) puts our clock id into the
   RTSP SETUP plist as `"ClockID"` (int64, signed cast of the u64 —
   `ptpd_clock_id_get()`), and also `master_session_make` (1173) stamps the
   `rtp_session` with `clock_id = use_ptp ? ptpd_clock_id_get() : 0`.
3. **SETPEERS:** the receiver replies with `timingPeerInfo.Addresses`
   (`handle_timingpeerinfo`, airplay.c:3122). For each address of the right
   family (ipv6 gets `%ifname` appended for link-local, 3159), it calls
   `ptpd_slave_add` (3167) → `airptp_peer_add` → the PTP daemon starts syncing to
   that peer. `slave_id` is stored on the session and removed at teardown (1245).

**Privilege boundary (for T-HELPER-DESIGN-1, restated):** only
`airptp_daemon_bind()` needs root (binds 319/320). `airptp_daemon_start`,
`airptp_peer_add/remove`, `airptp_clock_id_get` are unprivileged. So the shipped
split is: privileged helper = `bind` + shared master clock; unprivileged engine =
`airptp_daemon_find()` + peer add/remove. libairptp is **MIT** → the helper can be
its own clean binary. (Full detail owned by T-PTP-1 / T-HELPER-DESIGN-1.)

---

## 7. File manifest for the vendored package

Copy into `AirPlayEngine/Sources/CAirPlayEngine/` (keep original dir structure +
GPL/MIT/BSD headers verbatim). Paths are relative to `dev/owntone-src/src/`.

### 7.1 GPL sender cluster (GPL-2.0-or-later) — KEEP

| file | LOC | notes |
|---|---|---|
| `outputs/airplay.c` | 4411 | primary; edit: swap includes→shims, gut metadata, (later) swap ALAC |
| `outputs/airplay_events.c` | 545 | own thread+evbase; player controls→stub |
| `outputs/airplay_events.h` | 13 | |
| `outputs/rtp_common.c` | 441 | cleanest; logger+misc+gcrypt only |
| `outputs/rtp_common.h` | 164 | |
| `outputs/plist_wrap.h` | (small) | self-contained libplist wrapper; copy as-is |

### 7.2 evrtsp (BSD — Provos/Blaché) — KEEP

| file | LOC |
|---|---|
| `evrtsp/rtsp.c` | 1829 |
| `evrtsp/evrtsp.h` | 185 |
| `evrtsp/rtsp-internal.h` | 118 |
| `evrtsp/log.h` | 51 |

(evrtsp has autotools baggage but the sources compile against brew libevent;
`windows.h`/`winsock2.h` includes are `#ifdef`-guarded and won't build on macOS.)

### 7.3 pair_ap (MIT) — KEEP (both modules per Q7)

| file | LOC |
|---|---|
| `pair_ap/pair.c` | 806 |
| `pair_ap/pair.h` | 266 |
| `pair_ap/pair-internal.h` | 390 |
| `pair_ap/pair-tlv.c` | 221 |
| `pair_ap/pair-tlv.h` | 77 |
| `pair_ap/pair_fruit.c` | 1062 |
| `pair_ap/pair_homekit.c` | 3190 |

**Crypto backend:** pair_ap compiles with **either** `CONFIG_GCRYPT` **or**
`CONFIG_OPENSSL` (plus **libsodium always**). airplay.c + rtp_common.c already use
libgcrypt directly, so **define `CONFIG_GCRYPT`** → pair_ap needs gcrypt + sodium,
**no openssl dependency**. (openssl `<openssl/*>` includes are under
`#if CONFIG_OPENSSL` and won't be compiled.)

### 7.4 libairptp (MIT) — KEEP (build as `.a` or fold in — T-PTP-1/T-BUILD-1)

| file | LOC |
|---|---|
| `libairptp/airptp.h` | 69 |
| `libairptp/src/airptp.c` | 313 |
| `libairptp/src/daemon.c` | 583 |
| `libairptp/src/ptp_msg_handle.c` | 1030 |
| `libairptp/src/utils.c` | 231 |
| `libairptp/src/airptp_internal.h` | 139 |
| `libairptp/src/daemon.h` | 16 |
| `libairptp/src/ptp_definitions.h` | 209 |
| `libairptp/src/ptp_msg_handle.h` | 25 |
| `libairptp/src/utils.h` | 64 |

Self-contained (only libc + POSIX shared-mem/sockets). `libairptp/daemon/airptpd.c`
is the standalone daemon binary — relevant to the PTP helper (T-HELPER-DESIGN-1),
not the engine link. Ships as the separate MIT helper.

### 7.5 Explicitly CUT (do NOT copy)

All other `outputs/*` (`raop.c`* except lift the ~50-LOC uncompressed encoder,
`alsa.c`, `pulse.c`, `cast*.c`, `rcp.c`, `fifo.c`, `dummy.c`, `streaming.c`), and
all OwnTone plumbing `.c`: `outputs.c`, `conffile.c`, `logger.c`, `misc.c`,
`mdns_*.c`, `player.c`, `db*.c`, `artwork.c`, `dmap_common.c`, `transcode.c`,
`commands.c`, `evthr.c`, `ptpd.c` (reimplemented as shim, not copied wholesale but
adapted).

---

## 8. Event-loop + threading story

- **libevent version/features:** libevent 2.x (`<event2/event.h>`,
  `<event2/buffer.h>`). Uses core `event_base`, `event_new`/`evtimer_new`/
  `event_add`, `evbuffer_*`, and evrtsp (which sits on libevent's bufferevent/http
  machinery). No libevent_pthreads required if all access is single-threaded per
  base (it is). brew `libevent` suffices.
- **Who owns the event base:** airplay.c uses `extern struct event_base
  *evbase_player;` (airplay.c:459) — **the player thread's base owns everything**:
  the timing + control UDP services (`event_new(evbase_player,...)`, 2237/2245),
  every RTSP connection (`evrtsp_connection_set_base(ctrl, evbase_player)`, 1429),
  the deferred-failure timer (1594), and the keep-alive timer (4306). In our
  engine, **the engine creates and owns one `event_base` on one dedicated
  "engine" thread** and passes it wherever airplay.c used `evbase_player`
  (`extern` → a shim global we set at `airplay_init`).
- **airplay_events.c owns a SECOND thread + base:** it spawns its own pthread
  ("airplay events", airplay_events.c:464/509) with its own `event_base`
  (`airplay_events_init`, :506). This handles the receiver→sender remote-control
  channel. It's independent of the main engine base. Keep it as a second thread,
  or (audio-only) consider not starting it at all — but `airplay_init` currently
  calls `airplay_events_init`; leaving it running is harmless (its player-control
  callbacks are stubbed, §3.6).
- **Which thread calls `write`:** in OwnTone the **player thread** calls
  `outputs_write` → `output_airplay.write` = `airplay_write` (airplay.c:4232),
  synchronously, on the same thread that owns `evbase_player`. `airplay_write`
  manipulates evbuffers and sends UDP RTP directly (no locking). **Therefore our
  Swift `writePCM` must deliver PCM onto the engine thread** — either by running
  the engine's event loop and pushing PCM via a thread-safe queue drained on that
  thread, or by scheduling `airplay_write` via `event_base_once`/an
  `evbuffer`+notify. **Do NOT call `airplay_write` from an arbitrary Swift thread**
  — it shares state (`airplay_master_sessions`, `airplay_sessions`, timers) with
  the loop with no locks. This is risk R-B and the core of T-API-1's FFI bridge.
- **Consequence for the Swift wrapper:** one owned engine thread runs
  `event_base_dispatch`; all C entry points (`addOutput`, `removeOutput`,
  `device_start/stop`, `setVolume`, `writePCM`) marshal onto that thread; all C→
  Swift callbacks (`outputs_cb`, device add/remove) hop back to Swift async land.
  Lifetime: sessions/devices are owned by the C registry; Swift holds opaque ids.

---

## 9. Ordered shim list + estimated LOC

Build in this order (each unblocks the next; T-BUILD-1 + T-SHIM-1 are one
workstream):

| # | shim | file(s) | est. LOC | risk |
|---|------|---------|---------:|------|
| 1 | logger | `shims/logger.h` (+.c) | ~40 | low |
| 2 | misc (macros, keyval, device_id, quality) | `shims/misc.h` (+.c) | ~120 | low |
| 3 | misc net helpers | (same misc.c) | ~150 | med (macOS socket/scope-id) |
| 4 | conffile static config | `shims/conffile.h` (+.c) | ~100 | low |
| 5 | commands stub | `shims/commands.h` (+.c) | ~15 | low |
| 6 | player stub/callback | `shims/player.h` (+.c) | ~25 | low |
| 7 | db/artwork/dmap no-op | `shims/{db,artwork,dmap_common}.h` | ~20 | low |
| 8 | transcode ALAC (ffmpeg first) | `shims/transcode.h` (+.c) | ~120 (ffmpeg) → ~60 (uncompressed) | **high** (R-C) |
| 9 | ptpd (adapt ptpd.c) | `shims/ptpd.{h,c}` | ~135 | med (privilege split) |
| 10 | **outputs.c registry + async cb + buffers** | `shims/outputs.{h,c}` | ~350–450 | **high** (R-A) |

**Total shim ≈ 900–1,150 LOC** (dominated by outputs.c registry + net helpers +
transcode). **Shim count = 10.**

---

## 10. Top-5 riskiest unknowns (couldn't resolve statically)

1. **(R-A) `outputs.c` async-callback accounting.** The exact number of
   `outputs_cb` calls each sequence emits under error/retry/reconnect paths
   (esp. auth-retry at setup, airplay.c:3182, and TEARDOWN) must match what the
   engine's request-completion logic waits for, or the engine hangs. Needs a
   dynamic trace of a real session, not just the static "return 1".
2. **(R-B) libevent-thread ↔ Swift FFI.** Whether `airplay_write` can be safely
   invoked via `event_base_once` from the Swift audio thread without dropping
   frames at 44.1kHz/352-spf cadence, and how backpressure surfaces
   (`input_buffer` growth at airplay.c:4253). Threading model is clear; the timing
   behavior isn't provable statically.
3. **(R-C) ALAC-uncompressed bit-exactness for AP2 `ct=2`.** The raop.c
   uncompressed encoder is validated for AP1; whether an AP2 HomePod/Sonos accepts
   the identical ALAC framing with `spf=352`/`audioFormat=0x40000` needs the live
   two-host receiver. Until then, ffmpeg stays.
4. **PTP peer-address/ifname handling on macOS.** `net_if_get` + the `%ifname`
   ipv6 link-local suffix (airplay.c:3159) and `airptp_peer_add`'s expectations
   are Linux-tested; macOS scope-id / interface-name semantics may differ. Affects
   SETPEERS success on ipv6 receivers.
5. **evrtsp on macOS + connection reuse/keep-alive.** evrtsp carries autotools +
   Windows codepaths and OwnTone-tuned timeouts; whether its RTSP
   connection/keep-alive state machine behaves identically under the engine's own
   base (vs OwnTone's) — particularly the deferred-failure timer (1594) and
   keep-alive (4275/4306) interplay — is only verifiable at runtime.

---

## Appendix A — full external-symbol disposition index

**KEEP-real-dep (brew):** libevent (`event_*`,`evbuffer_*`,`evtimer_*`),
libgcrypt (`gcry_*`), libplist (`plist_*` via plist_wrap.h + directly in
airplay_events.c), libsodium (pair_ap), ffmpeg/libavcodec (transcode, until ALAC
swap).

**KEEP-vendored:** evrtsp (`evrtsp_*`), pair_ap (`pair_*` — 15 fns listed §2),
rtp_common (`rtp_session_new/free`,`rtp_packet_get/next/commit`,
`rtp_sync_is_time`,`rtp_sync_packet_next`), libairptp (`airptp_*`, via ptpd shim),
airplay_events (`airplay_events_init/deinit/listen`).

**SHIM:** logger (`DPRINTF`,`DVPRINTF`,`DHEXDUMP`, `thread_setname`), misc
(net_*, keyval_*, device_id_*, quality_is_equal, STOB, CHECK_NULL, net_socket,
net_sockaddr), conffile (`cfg_*`, 16 keys §3.1), ptpd (`ptpd_*` on `airptp_*`),
transcode (8 fns §3.8), outputs registry (`outputs_*` §2.2).

**REPLACE-with-Swift-callback:** `player_device_add`/`player_device_remove`
(discovery→registry), `outputs_cb` (async completion→event), the mdns_browse
registration (→ `addOutput`/`removeOutput` C entries).

**STUB-noop:** `db_queue_fetch_byitemid`, `db_speaker_save`,
`artwork_get_by_queue_item_id`, `dmap_encode_queue_metadata` (metadata path);
`player_get_status`/`player_playback_*` (remote-control path); `commands_base_*`.

**CUT:** `mdns_init/register/cname`, all non-AIRPLAY `outputs/*`, all OwnTone
`.c` plumbing (§7.5), raop.c (except the ~50-LOC uncompressed ALAC encoder lifted
into airplay.c).
