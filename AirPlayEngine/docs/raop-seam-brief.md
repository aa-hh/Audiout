# RAOP (AirPlay 1) sender — seam / port brief (T1 → feeds T3)

**Source:** `dev/owntone-src/src/outputs/raop.c` (4792 LOC), OwnTone tag **29.2**.
**Goal:** port the classic **AirPlay-1 / RAOP (AirTunes v2)** sender into
`AirPlayEngine/Sources/CAirPlayEngine/` alongside the already-extracted AP2
sender, and make the engine a **shared, two-backend** engine that dispatches
per-device to `output_airplay` (AP2) **or** `output_raop` (AP1).

This document is written so a C engineer can start T3 **without re-reading
`raop.c`**. It reuses the exact extraction method already proven for the AP2
sender — read `AGENTS.md`, `docs/seam-map.md`, `docs/VENDORED-DIFFS.md`,
`docs/license-inventory.md`, and `docs/outputs-dispatcher-contract.md` first;
they are all authoritative and still apply.

Line numbers are **tag-29.2 absolute** and drift if the clone moves.

**License:** `raop.c` is **GPL-2.0-or-later** (Espen Jürgensen 2012-2020, Julien
BLACHE 2010-2011; crypto adapted from VideoLAN GPLv2+, ALAC from raop_play
GPLv2+, ALAC end-tags from Mike Brady GPLv2+). Same GPL cluster as `airplay.c`.
Keep the header verbatim; copy into `sender/` (the existing GPL dir). Update
`docs/license-inventory.md` when it lands.

---

## 0. TL;DR verdicts

- **The good news: RAOP is a strictly *smaller* dependency surface than AP2.**
  It needs **no PTP** (no `libairptp`, no `ptpd`, no ports 319/320), **no
  HomeKit pairing** (only the `pair_fruit` PIN path, already vendored), and it
  ships its **own uncompressed-ALAC encoder inline** (no lift needed — the AP2
  brief had to *borrow* raop.c's encoder; here it is native). Every heavy dep
  raop.c needs — evrtsp, gcrypt, libevent, rtp_common, pair_ap — is **already
  vendored/linked** for AP2.
- **Almost every shim raop.c wants already exists** (built for AP2): `conffile`,
  `logger`, `misc` (net/keyval/quality), `mdns`/`engine_bridge`, `player`,
  `transcode`, `db`/`artwork`/`dmap` stubs, and the big one — `outputs.c`
  registry + the `outputs_cb` dispatcher. The dispatcher contract is
  **backend-agnostic** and already covers raop.c unchanged (§5).
- **New shim work is tiny:** `safe_atoi32` + `b64_encode` in misc (~50 LOC
  total), an `L_RAOP` log domain constant (1 LOC), one new conffile key name
  (`raop_disable`), and the two-backend **dispatch layer** in `outputs.c`
  (the only nontrivial new piece — §6).
- **The crypto is the classic RSA-AES handshake**, entirely on **gcrypt**
  (RSA-OAEP-SHA1 key-wrap + AES-128-CBC payload) with a **fixed Apple RSA
  public key baked into raop.c** — all self-contained, no new deps (§4).
- **Top risks:** (R1) getting the two-backend `outputs_write` fan-out + the
  shared callback registry wrong (hangs — §5/§6); (R2) `raop_device_stop`/
  `_flush` deref `device->session` with **no NULL guard** (§6.4); (R3)
  metadata/keep-alive is stubbed, and the keep-alive progress packet is a known
  ATV4/HomePod "don't disconnect me" quirk (§7).

---

## 1. Every external symbol raop.c references, classified

Legend: **KEEP** = real dep or already-vendored C, use as-is. **SHIM(exist)** =
a shim already written for AP2 covers it. **SHIM(new)** = must be added (LOC
est.). **STUB** = metadata/db/artwork/library path, gut to no-op exactly as
`airplay.c` did. **CUT** = do not port.

### 1.1 Includes (raop.c:39-73)

| include | class | disposition |
|---|---|---|
| libc (`stdio…netinet`, `strings.h`) | KEEP | system |
| `<event2/event.h>`, `<event2/buffer.h>` | KEEP | brew libevent (linked) |
| `<gcrypt.h>` | KEEP | brew libgcrypt (linked) — RSA/AES/MD5 |
| `"evrtsp/evrtsp.h"` | KEEP (vendored) | evrtsp cluster (present) |
| `"conffile.h"` | SHIM(exist) | `shims/conffile.{h,c}` |
| `"logger.h"` | SHIM(exist) + 1 new const | `shims/logger.{h,c}`; add `L_RAOP` |
| `"mdns.h"` | SHIM(exist) / discovery seam | `shims/mdns.{h,c}` + `engine_bridge` (needs 2nd cb — §6.6) |
| `"misc.h"` | SHIM(exist) + 2 new fns | `shims/misc.{h,c}`; add `safe_atoi32`, `b64_encode` |
| `"player.h"` | SHIM(exist) | `shims/player.{h,c}` (`player_device_add/remove`) |
| `"db.h"` | STUB | metadata path only (§7) |
| `"artwork.h"` | STUB | metadata path only (§7) |
| `"dmap_common.h"` | STUB | metadata path only (§7) |
| `"rtp_common.h"` | KEEP (vendored) | `sender/rtp_common.{c,h}` (present) |
| `"transcode.h"` | SHIM(exist) | `shims/transcode.{h,c}` (ffmpeg-ALAC; or use raop's inline uncompressed — §3) |
| `"outputs.h"` | SHIM(exist, extend) | `shims/outputs.{h,c}` — becomes two-backend dispatcher (§6) |
| `"pair_ap/pair.h"` | KEEP (vendored) | pair_ap cluster (present); raop uses the **fruit/PIN** path only |

**Note: raop.c does NOT include `ptpd.h` or `libairptp`.** RAOP timing is
NTP-style over its own UDP timing service (§4/§4bis). Do **not** pull PTP in.

### 1.2 Config keys raop.c reads (via `conffile` shim — all SHIM(exist) except one new key)

Global: `general.user_agent` (1130), `library.name` (1133),
`airplay_shared.uncompressed_alac` (4716 — **this is the flag that flips ALAC
off-ffmpeg; seam-map §3.1 already notes it is read *only* by raop.c**).
Also `libhash` extern (1150 — `Client-Instance`/`DACP-ID`; `conffile_set_libhash`).

Per-device `airplay.<name>` (all optional, short-circuit to default when
`cfg_gettsec` returns NULL): `exclude` (4240), `permanent` (4246),
`exclusive` (4252), **`raop_disable` (4258 — NEW key name; add to conffile shim,
default false, same handling as AP2's `airplay2_disable`)**, `nickname` (4264),
`password` (4346), `max_volume` (4382), `reconnect` (4410, NODEFAULT → ATV4/
HomePod heuristic). `cfg`, `cfg_getsec/getbool/getint/getstr/gettsec/getopt/
cfg_opt_getnbool` are all already in the conffile shim.

### 1.3 misc helpers

SHIM(exist): `net_bind` (4700/4708 timing+control services), `net_connect`
(3395 data socket), `net_socket_close`, `net_address_get` (3263),
`quality_is_equal` (1877/4378/4599), `keyval_get` (TXT parse, 4301-4441),
`safe_hextou64` (4220/4356), `STOB` (443/1924), `CHECK_NULL`, `MIN`/`MAX`,
`struct net_socket`, `union net_sockaddr`, `if_nametoindex` (2122, system).

**SHIM(new), misc.c (~50 LOC total):**
- **`safe_atoi32(const char*, int32_t*)`** — raop.c:3539/3555/3571 (parse SETUP
  transport ports), 4367/4371/4375 (parse `sr`/`ss`/`ch` TXT). AP2 never needed
  it (uses `safe_hextou`). Thin `strtol` wrapper w/ full-consume + range check.
  **~15 LOC.** Header decl next to `safe_hextou32` in `shims/misc.h`.
- **`b64_encode(const uint8_t*, int) -> char*`** (malloc'd) — raop.c:851 (RSA-
  wrapped AES key → SDP `a=rsaaeskey`), 1598 (Apple-Challenge), 4681 (AES IV →
  `a=aesiv`). AP2's SDP-free path never needed base64. Standard RFC-4648 base64
  (OwnTone's own is in `src/misc.c:170`). **~35 LOC.** Decl in `shims/misc.h`.
  *(raop.c strips `=` padding itself at 1607/4690/4694.)*

### 1.4 logger

SHIM(exist) + **new domain constant `L_RAOP`** (used ~180× as the domain arg to
`DPRINTF`/`DHEXDUMP`). OwnTone numbers it in `logger.h`; add the one constant
alongside `L_AIRPLAY` in `shims/logger.h`. `DPRINTF`, severities `E_FATAL..
E_SPAM` already present. **~1 LOC.**

### 1.5 evrtsp (all KEEP — vendored, present)

`evrtsp_request_new/free`, `evrtsp_make_request`, `evrtsp_add_header`,
`evrtsp_find_header`, `evrtsp_method`, `evrtsp_connection_new/free/set_base/
set_closecb/get_local_address` (1531), `enum evrtsp_cmd_type`
(`EVRTSP_REQ_OPTIONS/ANNOUNCE/SETUP/RECORD/FLUSH/TEARDOWN/SET_PARAMETER/POST`),
`req->{output_headers,input_headers,output_buffer,input_buffer,response_code,
response_code_line}`, `RTSP_OK/UNAUTHORIZED/FORBIDDEN` (evrtsp.h:47-49). All
confirmed declared in `evrtsp/evrtsp.h`.

### 1.6 gcrypt (all KEEP — brew libgcrypt, linked)

RSA-OAEP: `gcry_md_*` (SHA1/MD5), `gcry_mpi_scan/aprint/release`,
`gcry_sexp_build/find_token/nth_mpi/release`, `gcry_pk_encrypt`,
`gcry_random_bytes`, `gcry_randomize`. AES payload: `gcry_cipher_open`
(`GCRY_CIPHER_AES`,`GCRY_CIPHER_MODE_CBC`, 4653), `gcry_cipher_setkey/setiv/
reset/encrypt/close`. Digest auth: `gcry_md_*` MD5 (raop_add_auth, 917-989).

### 1.7 rtp_common (all KEEP — vendored, present)

`rtp_session_new` (1891 — called with **`ptp_clock_id = 0`**, the non-PTP mode),
`rtp_session_free`, `rtp_packet_next` (2971), `rtp_packet_get` (2945, resend),
`rtp_packet_commit` (3001), `rtp_sync_is_time` (3054), `rtp_sync_packet_next`
(3072/3080), `struct rtp_session`, `struct rtp_packet`, `struct rtcp_timestamp`
(`{uint32_t pos; struct timespec ts;}`), `RTP_MARKER_BIT` (rtp_common.h:9).
**rtp_common already supports raop.c unchanged** — same API AP2 uses (§4bis).

### 1.8 pair_ap (KEEP — vendored, present; fruit/PIN path only)

`PAIR_CLIENT_FRUIT`, `pair_setup_new/free/result/errmsg`,
`pair_setup_request1/2/3`, `pair_setup_response1/2/3`, `pair_verify_new/free/
errmsg`, `pair_verify_request1/2`, `pair_verify_response1`, `struct
pair_setup_context`, `struct pair_verify_context`. RAOP uses ONLY
`PAIR_CLIENT_FRUIT` (tvOS PIN verification, raop.c:3784-4167) — it never touches
`pair_homekit`'s HomeKit/transient modes. `pair_fruit.c` is already vendored.

### 1.9 outputs.h types/symbols (SHIM(exist) — the registry; extend for 2 backends §6)

Types (all already in `shims/outputs.h`, mirrored verbatim from OwnTone):
`struct output_device` (raop reads `id,name,type,type_name,extra_device_info,
supported_formats,has_password,requires_auth,password,auth_key,volume,max_volume,
offset_ms,quality,resurrect,v4/v6_address,v4/v6_port,v6_disabled,session`),
`struct output_buffer`/`output_data` (`obuf->pts`, `obuf->data[i].{buffer,
bufsize,samples,quality}` — raop_write, 4597-4611), `struct output_metadata`,
`enum output_device_state`, `enum output_types` (**`OUTPUT_TYPE_RAOP` = value 0,
already in the enum**), `enum media_format` (`MEDIA_FORMAT_ALAC`, 4277),
`struct output_definition`.

Registry symbols raop.c calls back into (all present in `shims/outputs.c`):
`outputs_cb` (1813), `outputs_device_get` (2669/3287/3724/3942/3975/4005/4052),
`outputs_device_session_add` (2275), `outputs_device_session_remove` (1989),
`outputs_device_free` (4485), `outputs_quality_subscribe/unsubscribe`
(1882/1894/1823), `outputs_buffer_duration_ms_get` (1914),
`outputs_exclusive_mode_get` (4252), `outputs_name` (4275).
`player_device_add/remove` (4478/4293) via the player shim.

**No `outputs_list` call in raop.c** (AP2 needs it for `device_id_find_byname`;
raop matches sessions by socket address instead — §4bis). Nothing new here.

### 1.10 STUB (metadata/db/artwork/dmap — gut exactly as airplay.c did, §7)

`db_queue_fetch_byitemid` (2322), `db_speaker_save` (4060), `free_queue_item`
(2346), `struct db_queue_item`; `artwork_get_by_queue_item_id` (2334),
`ART_DEFAULT_WIDTH/HEIGHT`, `ART_FMT_PNG/JPEG` (2462/2466);
`dmap_encode_queue_metadata` (2344). All reachable only from
`raop_metadata_prepare`/`_send`/`_send_generic` — early-return those (§7).

### 1.11 CUT

Nothing to lift — unlike AP2, raop.c's inline ALAC encoder **stays** (§3). Do
not port raop.c's `#ifdef PREFER_AIRPLAY2` priority logic meaningfully (§8).

### 1.12 Symbol-collision check (raop.c + airplay.c in ONE binary)

raop.c's only **non-static** symbol is `struct output_definition output_raop`
(4766). Every helper (`session_make`, `session_cleanup`, `packets_send`,
`master_session_make`, `raop_status`, …) is `static` → file scope, no clash
with airplay.c's identically-named statics. `evbase_player` is a shared extern
(defined once in the shim). Both use gcrypt/evrtsp/rtp_common re-entrantly with
their own static session lists. **No link collisions.**

---

## 2. The classic RSA-AES handshake flow (ANNOUNCE / SETUP / RECORD)

RAOP's startup is a linear RTSP request chain, each step's callback firing the
next (all on `evbase_player` via evrtsp). Entry: `raop_device_start_generic`
(4493) → `session_make` (2189) → `OPTIONS`.

```
device_start
  session_make (2189): calloc rs, connection_setup (v6 then v4 fallback),
                       master_session_make (ALAC encoder + rtp_session)
  ├─ if device->auth_key  -> raop_pair_verify (fruit /pair-verify)  ──┐
  └─ else OPTIONS (raop_send_req_options 1701)                        │
        raop_cb_startup_options (3671):                               │
          401 -> raop_parse_auth + re-OPTIONS with Digest (MD5)       │
          403 -> requires_auth -> pair-pin-start (PIN)                │
          200 -> only_probe? report CONNECTED + cleanup               │
                 else if supports_post & supports_auth_setup:         │
                       POST /auth-setup (1657, no-encrypt flag)  ◄── AP2 speakers
                       (Sonos/AptX) need this or ANNOUNCE 403s        │
                 -> ANNOUNCE ◄──────────────────────────────────────┘
  ANNOUNCE (raop_send_req_announce 1515):
     - build SDP (raop_make_sdp 1179): "AppleLossless", fmtp 352-sample frame;
       IF rs->encrypt add  a=rsaaeskey:<b64(RSA-wrapped AES key)>  a=aesiv:<b64 IV>
     - IF rs->encrypt add  Apple-Challenge: <b64(16 random bytes)>
  raop_cb_startup_announce (3611): 200 -> SETUP
  SETUP (raop_send_req_setup 1465): Transport: RTP/AVP/UDP;unicast;mode=record;
       control_port=<ours>;timing_port=<ours>
  raop_cb_startup_setup (3455): parse Session + Transport reply ->
       rs->server_port / control_port / timing_port (safe_atoi32)  -> RECORD
  RECORD (raop_send_req_record 1411): Range npt=0-, RTP-Info seq=..;rtptime=..
  raop_cb_startup_record (3414): 200 -> set initial volume (SET_PARAMETER) ->
  raop_cb_startup_volume (3370): net_connect data UDP socket (server_fd) ->
       state = CONNECTED, raop_status() fires outputs_cb(CONNECTED)  ✓ start done
```

### 2bis. The fixed Apple RSA key + AES session key (crypto, all on gcrypt)

- **Fixed Apple RSA public key** baked into raop.c: `raop_rsa_pubkey[]`
  (277-292, 256-byte modulus) + `raop_rsa_exp[]` = `0x010001` (294). Keep the
  byte arrays verbatim.
- **AES session key/IV**: `raop_init` (4641) generates a random 16-byte AES key
  and IV (`gcry_randomize`, 4649-4650), opens **AES-128-CBC** (`gcry_cipher_open
  GCRY_CIPHER_AES/MODE_CBC`, 4653), sets the key (4663).
- **Key-wrap for SDP**: `raop_crypt_encrypt_aes_key_base64` (733) pads the AES
  key with **RSA-OAEP-SHA1** (`raop_crypt_add_oaep_padding` 597 + `raop_crypt_
  mgf1` 538 — RFC-2437, all gcrypt `gcry_md_*`/`gcry_random_bytes`), RSA-encrypts
  it under the fixed Apple pubkey (`gcry_pk_encrypt` 814), base64s the result
  → `raop_aes_key_b64`. IV → `raop_aes_iv_b64` (4681). Both go in the ANNOUNCE
  SDP (only when `rs->encrypt`).
- **Per-packet payload encryption**: `packet_encrypt` (2828) AES-CBC-encrypts
  the RTP payload in 16-byte blocks (reset+setiv each packet, 2834-2852), called
  from `packets_send` only when `rms->encrypt` (2975).
- **Digest auth** (password-protected devices): `raop_add_auth` (879) builds an
  RTSP `Digest` header with **MD5** (`gcry_md_*`), triggered by a 401 with
  `WWW-Authenticate` (`raop_parse_auth` 1010). Optional `auth_quirk_itunes`
  uppercase-hex + `iTunes` username for gen-1 APEX.

**Whether a device encrypts is per-device** (`rs->encrypt`, set in `session_make`
2220-2250 by `devtype` and the TXT `ek` flag). Most modern AP2-capable speakers
that also expose RAOP advertise `et=0,4` (auth-setup, no `ek`) → **unencrypted
audio + the no-auth `/auth-setup` handshake** (the comment at 1634-1656 explains
Sonos Beam / APEX fw-7.8 require the auth-setup POST even though we don't encrypt).
The RSA/AES machinery must still be present for the devices that do want it.

**Existing pieces that cover this handshake:** RTSP transport = **evrtsp**
(vendored); all crypto = **gcrypt** (linked, same as AP2). Nothing new.

---

## 3. The uncompressed-ALAC encoder (ships INSIDE raop.c — we are using it)

We are streaming **uncompressed ALAC — no ffmpeg**. Unlike the AP2 brief (which
had to *lift* this encoder into airplay.c), **raop.c already contains it inline**:

- `alac_write_bits` (raop.c:366) — big-endian bit writer, ≤8 bits/call.
- `alac_encode_uncompressed(dst, raw, len)` (raop.c:411) — writes a 3-bit ALAC
  frame header (`channel=1 stereo`, `is-not-compressed=1`), byteswaps the PCM
  samples to big-endian into the bitstream, then a 3-bit end tag.
  `ALAC_HEADER_LEN = 3`; output size = `3 + rawbuf_size + 1` (the `+1` is the
  end tag, added in OwnTone 29.2 for FFmpeg-decoder compat — see the Mike Brady
  copyright line).
- `alac_encode_no_xcode` (raop.c:441) wraps it into an evbuffer.
- `alac_encode` (raop.c:484) dispatches: `raop_uncompressed_alac` → the inline
  encoder; else `alac_encode_xcode` → ffmpeg via the transcode shim.
- `raop_uncompressed_alac` is set from `airplay_shared.uncompressed_alac`
  (4716).

**T3 plan:** set `uncompressed_alac = true` in the conffile shim (engine
default). Then `master_session_make`'s ffmpeg encoder setup (1899-1912,
`transcode_decode_setup_raw`/`transcode_encode_setup`) is still *run* but its
`encode_ctx` is unused on the send path — either leave it (harmless, matches AP2)
or short-circuit it when `uncompressed_alac`. **Recommendation: mirror AP2 —
ship ffmpeg-linked first to reproduce OwnTone's validated path for first light,
then flip `uncompressed_alac=true` and drop ffmpeg.** Same residual risk as AP2
(R-C in seam-map): the uncompressed frame is validated against real AP1
receivers by OwnTone itself, so this is *lower* risk here than it was for AP2's
`ct=2` untested path — RAOP is the encoder's native home.

Format is fixed **44100/16/2, 352 samples/packet** (`RAOP_SAMPLES_PER_PACKET`,
`RAOP_QUALITY_*_DEFAULT`, 77-84). `rd->supported_formats = MEDIA_FORMAT_ALAC`.

---

## 4. RAOP timing/RTP model — NTP-style, NOT PTP

**Do not pull in `libairptp`/`ptpd`/PTP.** RAOP predates PTP; it runs its own
two UDP services, both bound in `raop_init` (4700/4708) via `net_bind`
(ephemeral port) with `event_new` read-persist handlers on `evbase_player`:

- **Timing service** (`raop_timing_svc`, `timing_svc_cb` 3148): the receiver
  sends a 32-byte NTP-style request (`0x80 0xd2`); we reply (`0x80 0xd3`) with
  our receive + transmit **NTP timestamps** derived from `CLOCK_MONOTONIC`
  (`timing_get_clock_ntp` 514 → `timespec_to_ntp` 494, NTP epoch delta
  `0x83aa7e80`, `FRAC = 2^32`). This is AirTunes-v2 clock sync — pure userspace
  UDP, no privileged ports, no daemon.
- **Control service** (`raop_control_svc`, `control_svc_cb` 3230): receiver
  sends a retransmit request (`0x80 0xd5`, seq_start + seq_len); we match the
  session by peer address (`session_find_by_address` 2159) and resend from the
  RTP retransmit buffer (`packets_resend` 2929 → `rtp_packet_get`).

Clock id into `rtp_session_new` is **`0`** (raop.c:1891) — the non-PTP path.

### 4bis. RTP packetization onto the existing `rtp_common`

Identical API surface AP2 uses — `rtp_common` already supports it:

- **Audio** (`packets_send` 2957): `alac_encode` → `rtp_packet_next(rtp_session,
  len, samples_per_packet=352, RAOP_RTP_PAYLOADTYPE=0x60)` → optional
  `packet_encrypt` (AES) → `packet_send` (`send()` on the connected `server_fd`
  UDP socket) → `rtp_packet_commit` (stores in the retransmit ring,
  `RAOP_PACKET_BUFFER_SIZE = 1000`). First packet to a just-joined device sets
  `RTP_MARKER_BIT` (2990).
- **Sync** (`packets_sync_send` 3044): on join sends an init sync packet
  (`0x90`) to the device's control port; periodically (`rtp_sync_is_time`) sends
  `0x80` sync packets. Built via `rtp_sync_packet_next` + `control_packet_send`
  (`sendto` to `rs->control_port`). `timestamp_set` (3015) maintains
  `rms->cur_stamp.pos = rtp_session->pos + input_buffer_samples -
  output_buffer_samples`.
- **Write path** (`raop_write` 4588): for each master session, match
  `obuf->data[i]` by `quality_is_equal`, `timestamp_set`, `packets_sync_send`,
  append PCM to `input_buffer`, and drain full `rawbuf_size` packets via
  `packets_send`. Then promote just-CONNECTED sessions to STREAMING (4626-4637)
  and arm the keep-alive timer.

**Multi-stream note:** the P2b `stream_id` surgery (VENDORED-DIFFS Entry 2) was
applied to `airplay.c`'s master-session cache + `airplay_write` fan-out. **The
same surgery must be applied to raop.c** if AP1 devices participate in per-app
routing: add `uint32_t stream_id` to `struct raop_master_session` (159) and
`struct raop_session` (187), key `master_session_make`'s reuse loop (1875) on it,
set it in `session_make` (from `device->stream_id`), and gate `raop_write`'s
fan-out (4599) on `obuf->data[i].stream_id == rms->stream_id`. Ledger it as a
new VENDORED-DIFFS entry. If AP1 is single-stream-only at first, default 0 and
skip (behaviour unchanged) — a T3 scoping decision.

---

## 5. `outputs_cb` callback-accounting — raop.c obeys the SAME contract

`docs/outputs-dispatcher-contract.md` is authoritative and **covers raop.c
unchanged**. raop.c's `raop_status` (1813) is the exact analogue of airplay.c's
`session_status`:

```c
outputs_cb(rs->callback_id, rs->device_id, state);
rs->callback_id = -1;                 // consumed; cannot fire again
```

The `callback_id = -1` linchpin, the deferral onto the loop, and the
"resolve device by device_id at delivery" rules are all identical. **N ∈ {0,1},
delivered exactly once, keyed by callback_id.** Per-op (return value → N):

| op | fn (line) | returns | N | notes |
|---|---|---|---|---|
| `device_start` | `raop_device_start`→`_generic` (4536/4493) | 1 or -1 | 1/0 | OPTIONS→…→RECORD→volume→CONNECTED |
| `device_probe` | `raop_device_probe` (4530) | 1 or -1 | 1/0 | OPTIONS only, reports CONNECTED then cleanup |
| `device_stop` | `raop_device_stop` (4542) | **1** | 1 | TEARDOWN → STOPPED (⚠ derefs `device->session`, §6.4) |
| `device_flush` | `raop_device_flush` (4554) | **1 or 0** | 1/0 | **0 if not STREAMING** (⚠ derefs `device->session`) |
| `device_volume_set` | `raop_set_volume_one` (2744) | 1 or 0 | 1/0 | 0 if no live session; on send-fail fires FAILED on the *stale* id then returns 0 (§5edge) |
| `device_authorize` | `raop_device_authorize` (4147) | 1 or -1 | 1/0 | fruit PIN `/pair-setup-pin` |
| `device_cb_set` | `raop_device_cb_set` (4572) | void | 0 | re-arms callback_id, starts no op |

**Edge paths (all resolve to exactly-1, matching contract §4):**
- Failure: `session_failure` (1994) → `raop_status` once → `session_cleanup`
  (does not re-fire; id already -1).
- Deferred failure: `deferred_session_failure` (2006) / `raop_rtsp_close_cb`
  (2017) → arm `deferredev` → `deferredev_cb` (2064) → `session_failure` — 1,
  later.
- **ipv6→ipv4 retry (the subtle one, §4c analogue):** `raop_startup_cancel`
  (3306) sets `v6_disabled`, TEARDOWNs, then `raop_cb_startup_retry` (3280)
  **saves `callback_id`, `session_cleanup` (no fire), `raop_device_start(device,
  callback_id)` reuses the SAME id.** → still exactly 1. **The dispatcher must
  NOT release the waiter on teardown — only on an actual `outputs_cb`.** Already
  guaranteed by the existing dispatcher.
- Teardown: `session_teardown_cb` (2028) → STOPPED once.
- PIN start / password: `RAOP_STATE_PASSWORD` → `raop_status` maps to
  `OUTPUT_STATE_PASSWORD` (-2) once.

§5edge (`raop_set_volume_one` 2753-2759): on internal-send failure it calls
`session_failure` (fires FAILED on `rs->callback_id`, which at that point is the
*previous* id since the new one isn't armed until 2761) **and returns 0**. The
return-0 correctly registers no waiter for the new op; the FAILED report flows to
the old/-1 id and is handled by the **out-of-band device-state hook**
(`outputs_engine_state_set`, outputs.h) — exactly the AP2 behaviour. No change.

**Consequence: the callback dispatcher, registry, and completion/state hooks are
BACKEND-AGNOSTIC and need no per-backend logic.** One shared
`OUTPUTS_MAX_CALLBACKS` table; `outputs_callback_add(device, cb)` allocates an id
regardless of `device->type`; `outputs_cb` resolves `device_id`→device the same
way. This is why R-A does not re-open for T3.

---

## 6. Two-backend dispatch design (the one nontrivial new piece)

Today `shims/outputs.c` is single-backend (AP2 only). For a **shared engine**
hosting AP1 + AP2, the registry stays shared but the *operations* must dispatch
per-device to the correct `struct output_definition`.

### 6.1 Backend selection by `device->type`

```c
/* shims/outputs.c */
extern struct output_definition output_airplay;  /* sender/airplay.c */
extern struct output_definition output_raop;      /* sender/raop.c   */

static struct output_definition *
backend_for(struct output_device *d)
{
  switch (d->type)
    {
      case OUTPUT_TYPE_AIRPLAY: return &output_airplay;
      case OUTPUT_TYPE_RAOP:    return &output_raop;
      default:                  return NULL;   /* log bug, treat as no-op */
    }
}
```

`device->type` is stamped at discovery: `raop_device_cb` sets
`OUTPUT_TYPE_RAOP` (4274); `airplay_device_cb` sets `OUTPUT_TYPE_AIRPLAY`. The
opaque `device->session` (`void*`) is a `struct raop_session*` or `struct
airplay_session*`; **only the owning backend ever casts it** (dispatch-by-type
guarantees no cross-cast).

### 6.2 The per-op dispatch wrappers

Each engine entry point (the T-API-1 / `engine_bridge` surface) routes through a
wrapper that picks the backend and forwards, preserving the **return value N**
(which is what the async waiter keys on — §5):

```c
int outputs_device_start (struct output_device *d, int cb){ return backend_for(d)->device_start(d, cb); }
int outputs_device_stop  (struct output_device *d, int cb){ return backend_for(d)->device_stop (d, cb); }
int outputs_device_flush (struct output_device *d, int cb){ return backend_for(d)->device_flush(d, cb); }
int outputs_device_probe (struct output_device *d, int cb){ return backend_for(d)->device_probe(d, cb); }
int outputs_device_volume_set(struct output_device *d,int cb){ return backend_for(d)->device_volume_set(d,cb); }
int outputs_device_authorize(struct output_device *d,const char*pin,int cb){ return backend_for(d)->device_authorize(d,pin,cb); }
void outputs_device_cb_set   (struct output_device *d,int cb){ backend_for(d)->device_cb_set(d,cb); }
void outputs_device_free_extra(struct output_device *d){ if(backend_for(d)->device_free_extra) backend_for(d)->device_free_extra(d); }
```

*(These are the engine-side wrappers the Swift layer calls; the existing
single-backend calls in `engine_bridge.c` that hardcode `airplay_device_start`
etc. get repointed through these.)*

### 6.3 write fan-out — call BOTH backends' `.write` (contract-critical, R1)

`outputs_write(obuf)` must invoke **`output_raop.write(obuf)` AND
`output_airplay.write(obuf)`** on the engine thread. Each backend's `write`
iterates *its own* static master-session list and self-filters by
quality/stream_id, so the same `obuf` fed to both is correct — RAOP sessions get
RAOP packets, AP2 sessions get AP2 packets, no cross-talk. Order doesn't matter
(disjoint session sets). **Do not** try to route an obuf to only one backend;
`write` is a broadcast and each side no-ops when it owns no matching session.

### 6.4 init/deinit — run BOTH at engine start/stop

`AirPlayEngine.start()` must call `raop_init()` **and** `airplay_init()` (both
return 0/-1); `stop()` calls `raop_deinit()` + `airplay_deinit()`. They are
independent: `raop_init` binds its own timing+control UDP services + sets up
AES/RSA + arms the keep-alive timer + `mdns_browse("_raop._tcp", …)`;
`airplay_init` binds *its* services + PTP + `mdns_browse("_airplay._tcp", …)`.
Both live on the single `evbase_player`. `outputs_registry_clear()` (already
present) empties the shared registry between starts.

**⚠ NULL-guard gap (R2):** `raop_device_stop` (4544) and `raop_device_flush`
(4557) do `rs = device->session; rs->callback_id = …` with **no NULL check** —
matching OwnTone's invariant that the player only stops/flushes a device with a
live session. The engine's dispatch wrappers (or the Swift layer) must uphold
that: never call stop/flush on a device whose `session == NULL`. (AP2's
equivalents guard or are likewise invariant-protected — verify parity.)

### 6.5 The shared callback registry

Unchanged from §5: one `OUTPUTS_MAX_CALLBACKS` table, `outputs_callback_add`/
`_remove`/`_get`/`_clear`, `outputs_cb` deferral, and the completion + state
hooks — all backend-agnostic. Both `raop_status` and airplay's `session_status`
feed the identical `outputs_cb(callback_id, device_id, state)`.

### 6.6 Discovery: `engine_bridge` must capture TWO device callbacks

`raop_init` calls `mdns_browse("_raop._tcp", raop_device_cb, …)`; `airplay_init`
calls `mdns_browse("_airplay._tcp", airplay_device_cb, …)`. The current
`engine_bridge` captures a **single** device cb (`airplayengine_feed_device`
routes to it). Extend it to capture both (keyed by the browse `type` string) and
add a feed entry that targets `raop_device_cb`, or add a `type`/backend argument
to the feed API. The app-owned NWBrowser then feeds a resolved device into the
right backend. A speaker that advertises **both** `_raop._tcp` and
`_airplay._tcp` (typical Sonos/HomePod) is fed to whichever backend the app
selects — mirror OwnTone's `.priority` (AP2 preferred) or expose the choice.
TXT keys raop reads: `tp` (must contain UDP), `pw`, `sf` (bit 9 → requires_auth),
`sr`/`ss`/`ch` (quality), `am` (devtype), `ek` (encrypt), `md`/`et` (metadata/
auth-setup). `keyval` carries them, same as AP2.

---

## 7. Metadata / keep-alive — STUB (as airplay.c), with one caveat

Gut the metadata path exactly like AP2 (seam-map §3.4):
- `raop_metadata_prepare` (2314) → **return NULL** (kills the db/artwork/dmap
  refs at 2322/2334/2344).
- `raop_metadata_send` (2590) → **no-op**.
- `raop_metadata_purge` (2302) → **no-op**.
- `db_speaker_save` (4060, auth-key persistence after PIN) → **no-op** (persist
  the auth_key in Swift if wanted; the callback still completes — save is
  fire-and-forget, verify around 4060-4074).

**Caveat (R3):** the keep-alive timer (`raop_keep_alive_timer_cb` 2802, armed in
`raop_write`) sends **progress metadata** every 25 s specifically to stop ATV4 /
HomePod from disconnecting (`RAOP_KEEP_ALIVE_INTERVAL`, comment at 100-104). With
metadata stubbed, `raop_metadata_keep_alive_send` (2580) early-returns (no
`wanted_metadata`/`raop_cur_metadata`) → the keep-alive sends nothing. For pure
RAOP that's usually fine (audio + sync packets keep the session alive), but if a
resurrect-class device (`rd->resurrect`, 4410-4414) drops mid-stream, this is the
first place to look. Note it; don't over-engineer at T3.

---

## 8. `struct output_definition output_raop` — the shape T3 must implement

Verbatim from raop.c:4766-4792 (implement each fn; the ones marked → become the
stub/no-op noted above). Field order is irrelevant (designated initializers);
the `shims/outputs.h` `struct output_definition` already declares every slot,
and `device_authorize`'s `(device, pin, callback_id)` signature already matches.

```c
struct output_definition output_raop =
{
  .name             = "AirPlay 1",          // string only; rename neutrally in product
  .cfg_name         = "airplay",            // shares AP2's config section
  .type             = OUTPUT_TYPE_RAOP,     // = 0, dispatch key
  .priority         = 1,                    // (PREFER_AIRPLAY2 → 2); §6.6 selection, else drop
  .disabled         = 0,
  .init             = raop_init,            // AES/RSA + timing/control UDP + keep-alive + mdns
  .deinit           = raop_deinit,
  .device_start     = raop_device_start,    // returns 1/-1
  .device_stop      = raop_device_stop,     // returns 1  (⚠ derefs device->session)
  .device_flush     = raop_device_flush,    // returns 1 or 0 (0 if not STREAMING)
  .device_probe     = raop_device_probe,    // returns 1/-1
  .device_cb_set    = raop_device_cb_set,   // void, re-arm
  .device_free_extra= raop_device_free_extra,
  .device_volume_set= raop_set_volume_one,  // returns 1 or 0
  .device_volume_to_pct = raop_volume_to_pct,   // pure; -30..0 dB scaled by max_volume
  .write            = raop_write,           // hot path, engine thread only
  .metadata_prepare = raop_metadata_prepare,// → STUB return NULL
  .metadata_send    = raop_metadata_send,   // → STUB no-op
  .metadata_purge   = raop_metadata_purge,  // → STUB no-op
  .device_authorize = raop_device_authorize,// fruit PIN
  // .device_quality_set NOT set → leave NULL
};
```

Volume math (`raop_volume_from_pct` 2620 / `raop_volume_to_pct` 2637): pct
0-100 ↔ RAOP dB `-30.0..0` scaled by `device->max_volume`/`RAOP_CONFIG_MAX_
VOLUME(11)`; `-144.0` = off. Pure functions, no shim deps.

---

## 9. Ordered T3 checklist (each unblocks the next)

1. Copy `raop.c` into `sender/` (GPL header verbatim); add its GPL entry to
   `docs/license-inventory.md`.
2. `shims/misc`: add `safe_atoi32` + `b64_encode` (~50 LOC). `shims/logger`: add
   `L_RAOP`. `shims/conffile`: add `raop_disable` key + default
   `uncompressed_alac=true`.
3. Rewrite `shims/outputs.c` operation entry points as the §6 two-backend
   dispatch (`backend_for` + wrappers + dual-`write` + dual-init/deinit). Keep
   the callback registry/dispatcher untouched (§5).
4. `engine_bridge`: capture both device callbacks; add a RAOP feed entry (§6.6).
5. Repoint `engine_bridge.c`'s hardcoded `airplay_*` op calls through the new
   `outputs_device_*` dispatch wrappers.
6. (If AP1 joins per-app routing) apply the `stream_id` surgery to raop.c and
   ledger a new VENDORED-DIFFS entry (§4bis).
7. Build; then the gated single-instance live test against a real AP1/RAOP
   receiver (note: PTP ports are irrelevant to RAOP, but the shared engine still
   starts `airplay_init`'s PTP — the single-instance rule still holds).

**Risks carried into T3:** R1 two-backend `write` fan-out + shared registry
(§5/§6.3) — a hang class if `write` isn't broadcast or a waiter is released on
teardown; R2 unguarded `device->session` deref in stop/flush (§6.4); R3
keep-alive/metadata stubbed for resurrect-class devices (§7). None re-open the
already-closed R-A dispatcher contract.
