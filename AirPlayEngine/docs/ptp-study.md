# PTP Study — libairptp interface, daemon mode, privilege boundary, port-conflict reality

Task **T-PTP-1** (PLAN-PHASE-2.md). Feeds **T-HELPER-DESIGN-1** and **T-SHIM-1**
(the `ptpd.h`→`airptp_*` shim).

All local file:line citations are against
`dev/owntone-src/src/libairptp/` and `dev/owntone-src/src/`.

Reference clock-sharing design (nqptp) fetched from
`github.com/mikebrady/nqptp` and `shairport-sync/AIRPLAY2.md`.

---

## 0. TL;DR verdicts

- **Privilege boundary verdict (confirms the plan, with one clarification).**
  The plan's claim is *correct*: **only `airptp_daemon_bind()` touches privileged
  sockets** (binds UDP 319/320). Everything else — `airptp_daemon_start()`,
  `airptp_daemon_find()`, `airptp_peer_add/remove()`, `airptp_clock_id_get()` — is
  pure computation + local IPC and needs **no privilege**. Clarification the plan
  under-states: `airptp_daemon_start()` on the *daemon* side is the thing that
  actually runs the PTP master (opens `/airptp_shm`, spawns the libevent thread,
  answers 319/320 packets), but it does **not itself bind** — it operates on the
  already-bound fds. So the root/non-root cut is **`bind()` vs `start()`**, and the
  helper must do *both* (bind then start), because `start()` needs the fds `bind()`
  produced in the same process. See §1.

- **Daemon-mode viability: VIABLE and close to ideal for our helper.** libairptp
  ships a first-class **shared daemon mode** (`is_shared=true`) that publishes clock
  state through a POSIX shared-memory segment `/airptp_shm` and accepts peer
  add/remove over a **loopback UDP control channel** (localhost:320, PTP signaling
  TLVs). Unprivileged clients `airptp_daemon_find()` (mmap the shm read-only) and
  `airptp_peer_add/remove()` (sendto localhost). This is structurally the same split
  nqptp uses. The bundled `airptpd` binary *is* our helper, minus signing/launchd.
  See §2.

- **IPC recommendation: keep libairptp's native transport (POSIX shm read-only for
  clock state + loopback-UDP for peer control). Do NOT invent a unix-socket shim.**
  It already matches the nqptp reference design (shm for state), the code is MIT and
  self-contained, and reusing it verbatim means the helper is `airptpd.c` with an
  `SMAppService` wrapper rather than a bespoke protocol we have to audit and keep in
  sync with airplay.c's `ptpd_*` expectations. See §3.

- **Port-conflict reality: hard `EADDRINUSE`; strictly one PTP daemon per host.**
  `utils_net_bind()` does a plain `bind()` with **no `SO_REUSEADDR`/`SO_REUSEPORT`**
  (`utils.c:83-89`). Two daemons (OwnTone, our helper, nqptp, macOS's own PTP) cannot
  co-hold 319/320 — the second loses the bind. This is exactly why libairptp/nqptp
  have a *shared* daemon at all, and it is the mechanical basis of the live-test
  serialization rule. See §4.

Nothing found **contradicts** the plan. Two refinements/cautions are flagged in §5.

---

## 1. libairptp public API and the exact privilege boundary

Public surface — `libairptp/airptp.h`:

| Call | Header ref | Privilege | What it touches |
|---|---|---|---|
| `airptp_callbacks_register()` | airptp.h:28-29 | none | sets thread-local log/hexdump/thread-name cbs |
| `airptp_daemon_bind(node)` | airptp.h:34-35 | **ROOT** | binds UDP **319 + 320** (`airptp.c:102-144` → `utils_net_bind` → `bind()` `utils.c:87`) |
| `airptp_daemon_start(hdl, seed, is_shared)` | airptp.h:39-40 | none | spawns libevent thread on already-bound fds; if shared, creates `/airptp_shm` (`airptp.c:148-175` → `daemon_start` `daemon.c:517-561`) |
| `airptp_daemon_find()` | airptp.h:43-44 | none | `shm_open("/airptp_shm", O_RDONLY)` + `mmap(PROT_READ)` (`airptp.c:177-224`) |
| `airptp_peer_add(&id, addr, hdl)` | airptp.h:46-47 | none | validates addr, `sendto` localhost:general_port (`airptp.c:226-262`) |
| `airptp_peer_remove(id, hdl)` | airptp.h:49-50 | none | `sendto` localhost:general_port (`airptp.c:264-275`) |
| `airptp_clock_id_get(&id, hdl)` | airptp.h:58-59 | none | reads `hdl->daemon_info.clock_id` from mmap'd copy (`airptp.c:292-300`) |
| `airptp_end(hdl)` | airptp.h:53-54 | none | stops daemon thread / closes fds / frees (`airptp.c:277-290`) |
| `airptp_errmsg_get()` | airptp.h:61-62 | none | thread-local errmsg string |
| `airptp_ports_override(e, g)` | airptp.h:66-67 | none | overrides 319/320 → high ports for tests (`airptp.c:308-313`) |

### Where root is *actually* needed — verified

**`airptp_daemon_bind()` is the ONLY call that touches a privileged socket.** Trace:
`airptp_daemon_bind` (`airptp.c:110,117`) calls `utils_net_bind` twice (event port,
general port) → `bind_one` → `bind()` at `utils.c:87` on ports 319 (`PTP_EVENT_PORT`)
and 320 (`PTP_GENERAL_PORT`). Ports < 1024 require `CAP_NET_BIND_SERVICE`/root. The
header comment at airptp.h:31-33 is accurate: *"Returns a handle if it was possible to
bind to port 319 and 320. This normally requires root privileges."*

**`airptp_daemon_start()` needs NO privilege** — header says so verbatim (airptp.h:38:
*"Starting the daemon does not require privileges."*) and the code confirms it: it
never calls `bind()`; it does `pthread_create` + `event_new` on the fds already in the
handle, and for shared mode `shm_open(..., O_CREAT|O_RDWR, 0644)` (`daemon.c:103`) —
shm creation in the user's namespace is unprivileged. **Caveat for the helper: bind and
start must run in the same process/handle** — `start()` consumes the fds that `bind()`
stored in `hdl->daemon.*_svc.socket` (`airptp.c:128-132`). You cannot bind in a root
helper and then `start()` in the unprivileged engine over an FFI; the fds don't cross
that boundary. Hence the helper does *both*.

**All client-side calls are unprivileged pure-IPC:**
- `airptp_daemon_find()` — read-only `shm_open`/`mmap` of `/airptp_shm`
  (`airptp.c:186-193`), a stale-check (`ts + 15s`, `airptp.c:198`), and a version check
  (`airptp.c:194`). No socket, no root.
- `airptp_peer_add/remove()` — build a PTP signaling message and `sendto("localhost",
  general_port)` (`airptp.c:252,274` → `ptp_msg_peer_add_send`/`_del_send`
  `ptp_msg_handle.c:957-972` → `localhost_msg_send` `ptp_msg_handle.c:851-876`). Sending
  a UDP datagram to a high-numbered destination from an ephemeral source port is
  unprivileged.
- `airptp_clock_id_get()` — pure struct read from the client's mmap'd copy
  (`airptp.c:298`).

### The three modes (airptp.h:6-14)

1. **Shared daemon** — `bind()` [root] then `start(is_shared=true)`. Publishes
   `/airptp_shm`; other processes can `find()` it. **This is our helper.**
2. **Private daemon** — `bind()` [root] then `start(is_shared=false)`. Runs the master
   clock but does **not** create `/airptp_shm`; `daemon_info` is stack-local
   (`daemon.c:472-475`), so no other process can `find()` it. This is what OwnTone does
   in-process when it can't find an existing daemon (see `ptpd.c:123`, `is_shared=false`).
3. **Client** — no bind, no start; `find()` an existing shared daemon and drive
   `peer_add/remove` + `clock_id_get`.

### How airplay.c consumes it — via the `ptpd_*` wrapper, not libairptp directly

`airplay.c` includes `ptpd.h` (airplay.c:55) and calls only the six `ptpd_*` wrappers.
`src/ptpd.c` is the thin adapter over `airptp_*`:

- `ptpd_find_or_bind()` (`ptpd.c:73-103`) — **the privilege split point.** Tries
  `airptp_daemon_find()` first (`ptpd.c:86`); if a shared daemon exists, uses it
  (client mode, zero privilege). Else sets `airptp_create_own_service=true` and
  `airptp_daemon_bind()` (`ptpd.c:95`) — this is the call OwnTone must make **before
  dropping root** (comment ptpd.h:13-14: *"binds privileged ports 319 and 320, so must
  be called before the server drops privileges"*).
- `ptpd_init(seed)` (`ptpd.c:106-130`) — after privilege drop; only calls
  `airptp_daemon_start(..., is_shared=false)` if this process did the binding
  (`ptpd.c:123`). If it found a shared daemon, it's a no-op (`ptpd.c:120-121`).
- `ptpd_clock_id_get()` (`ptpd.c:50-58`) → `airptp_clock_id_get`. Used at
  airplay.c:1173 (per-session clock id) and airplay.c:2741 (plist `ClockID` sent to the
  speaker in SETUP).
- `ptpd_slave_add()` / `ptpd_slave_remove()` (`ptpd.c:60-70`) → `airptp_peer_add/remove`.
  Called when a speaker's `SETUP` reply hands back its timing-peer address list:
  `handle_timingpeerinfo` (airplay.c:3140-3173) walks the plist `Addresses`, picks a
  family-matching address, appends `%ifname` for link-local IPv6, and
  `ptpd_slave_add(slave_id, peer_straddress)` (airplay.c:3167). Removed on session
  teardown (airplay.c:1244-1245). The per-session id is stored as
  `session->ptpd_slave_id` (airplay.c:310).
- `ptpd_init(libhash)` at airplay.c:4335; `ptpd_deinit()` at airplay.c:4382.

**Shim implication (T-SHIM-1):** our `ptpd.h` shim reimplements exactly these six
functions on top of `airptp_*`, but with the find/bind logic pointed at the *helper's*
shared daemon rather than an in-process private daemon. In the shipped product the
engine is a pure **client**: `ptpd_find_or_bind()` → `airptp_daemon_find()` only (never
binds — the helper owns the ports), `ptpd_init()` → no-op, and add/remove/clock_id go
over shm+loopback to the helper. The only field of the wrapper that carries state is the
`airptp_handle*` from `find()`.

---

## 2. Bundled daemon mode — how an unprivileged process shares its clock

The daemon is `libairptp/daemon/airptpd.c` (built with `./configure --enable-daemon`).
It is a ~400-line thin `main()` around the shared-daemon API:

```
airptp_ports_override(...)          // optional -E/-G test ports   airptpd.c:290-295
hdl = airptp_daemon_bind(NULL);     // ROOT: binds 319/320          airptpd.c:297
airptp_daemon_start(hdl, seed, /*is_shared=*/true);  //             airptpd.c:303
// then a signalfd/kqueue event loop until SIGTERM, airptp_end()    airptpd.c:378-383
```

### Protocol / IPC — two distinct channels

**(A) Clock-state publication → POSIX shared memory (read-mostly, lock-free).**
On `start(is_shared=true)` the daemon thread `daemon_shm_create()` (`daemon.c:94-124`):
`shm_open("/airptp_shm", O_CREAT|O_EXCL|O_RDWR, 0644)` → `ftruncate` →
`mmap(PROT_READ|PROT_WRITE, MAP_SHARED)`, then fills `struct airptp_daemon_info`. The
struct (`airptp_internal.h:57-67`):

```c
struct airptp_daemon_info {
  uint16_t version_major;   // AIRPTP_SHM_STRUCTS_VERSION_MAJOR = 0
  uint16_t version_minor;   //                              _MINOR = 1
  uint64_t clock_id;
  time_t   ts;              // liveness heartbeat
  uint16_t event_port;      // 319 (or override)
  uint16_t general_port;    // 320 (or override)
  bool     ipv4_enabled;
  bool     ipv6_enabled;
};
```

A 5-second timer (`DAEMON_INTERVAL_SECS_SHM_UPDATE`, `daemon.c:41`) rewrites
`info->ts = time(NULL)` (`shm_update_cb` `daemon.c:365-372`) as a **heartbeat**.
Clients (`airptp_daemon_find` `airptp.c:177-224`) `shm_open(O_RDONLY)` + `mmap(PROT_READ)`,
reject a mismatched `version_major` (`airptp.c:194`), and treat the daemon as gone if
`ts + AIRPTP_STALE_SECS(15) < now` (`airptp.c:198`). The client **memcpy's the struct
out and immediately munmaps** (`airptp.c:207-210`) — it keeps a private snapshot, so it
does not observe live updates after `find()`. This is fine because `clock_id`/ports are
static for a daemon's lifetime; the heartbeat only matters at `find()` time.

Consistency note: airptp's shm is **not** double-buffered like nqptp's (see §3).
It gets away with it because the only mutable field clients read is `ts` (a single
aligned `time_t` written by one writer), and the substantive fields are write-once at
create. nqptp double-buffers because it streams *continuously changing* offset/time
fields.

**(B) Peer control → loopback UDP (localhost, general port 320) carrying PTP TLVs.**
There is no separate command socket. To add/remove a peer, a client crafts a PTP
**signaling** message with an org-extension TLV and `sendto("localhost", general_port)`:

- `airptp_peer_add` → `ptp_msg_peer_add_send` → `msg_peer_add_make`
  (`ptp_msg_handle.c:466-491`) writes org code `PTP_TLV_ORG_OWN` + subtype
  `PTP_TLV_ORG_OWN_PEER_ADD` (`{0x00,0x00,0x01}`) + `be32` peer id + addr_len + raw
  `sockaddr` → `localhost_msg_send` (`ptp_msg_handle.c:851-876`, `getaddrinfo("localhost")`
  + `sendto`).
- `airptp_peer_remove` → subtype `PTP_TLV_ORG_OWN_PEER_DEL` (`{0x00,0x00,0x02}`) + peer id.
- The daemon receives it on its bound general-port fd (`incoming_cb` `daemon.c:339-362`)
  → `ptp_msg_handle` (`ptp_msg_handle.c:978+`) → `PTP_MSGTYPE_SIGNALING` →
  `tlv_handle_org_subtype_peer_add/del` (`ptp_msg_handle.c:694-739`) →
  `daemon_peer_add/del` (`daemon.c:224-294`).

The **peer id is a djb hash of the address string** computed client-side
(`airptp.c:250`), so add and remove agree on the id without a round-trip.

### Lifecycle

- **Start:** bind (root) → `daemon_start` spawns a pthread running `run()`
  (`daemon.c:432-500`); the parent blocks on a start-result pipe
  (`loop_start_wait`/`loop_start_signal` `daemon.c:376-406`) so `start()` returns only
  after the loop is up and the shm exists. The `daemon_info` (incl. `clock_id`) is
  copied back to the caller over that pipe.
- **Run:** a libevent loop services 319/320, and periodically emits Announce (1s),
  Signaling (1s), Sync/Follow-Up (125ms) to all active peers
  (`daemon.c:299-336`, `ptp_msg_handle.c:910-954`). Always tries to be **master**
  (README:14-15 — the key difference from nqptp, which wants to be *slave*).
- **Stop:** write to `exit_pipe` → `event_base_loopbreak` (`daemon.c:409-425,563-583`);
  `daemon_shm_destroy` `shm_unlink`s `/airptp_shm` (`daemon.c:84-92`).

### Multi-client support

**Yes, natively.** The shm is read-only-shared to arbitrarily many `find()`ers, and any
number of processes can `sendto` the loopback control channel. The daemon holds one flat
peer table `peers[AIRPTP_MAX_PEERS=32]` (`airptp_internal.h:20,116`); adds are deduped by
id (`peer_exists` `daemon.c:211-222`) and pruned when inactive (`peers_prune`
`daemon.c:173-196`, staleness via `last_seen`). Note: the peer table is **global to the
daemon, not partitioned per client** — two engine instances adding the same speaker
share one peer entry (same djb id), and either could remove it. For our single-app use
this is a non-issue, but worth recording for the helper design (the helper is a shared
resource; a future second consumer could step on peers). Cap is 32 simultaneous PTP
peers.

---

## 3. Design — the privileged-helper boundary for OUR app (feeds T-HELPER-DESIGN-1)

### Recommended shape

```
┌─────────────────────────────────────────┐        ┌──────────────────────────────┐
│  PTP helper (root, SMAppService daemon)  │        │  AirPlayEngine (unprivileged) │
│  MIT libairptp, shared-daemon mode       │        │  GPL sender + ptpd.h shim     │
│                                          │        │                              │
│  airptp_daemon_bind(NULL)   [ROOT]       │        │  airptp_daemon_find()         │
│  airptp_daemon_start(seed, is_shared=1)  │        │    → mmap /airptp_shm (RO)     │
│  owns UDP 319 + 320 + master clock       │        │  airptp_clock_id_get()        │
│  publishes /airptp_shm                    │◀──shm──│  airptp_peer_add/remove()     │
│  listens localhost:320 for peer TLVs      │◀──UDP──│    → sendto localhost:320      │
│  NO audio, NO RTSP, NO pairing, clock-only│        │  all RTSP/ALAC/RTP/pairing    │
└─────────────────────────────────────────┘        └──────────────────────────────┘
```

The helper is `airptpd.c` re-homed under an `SMAppService` launchd daemon. What runs as
root is **only**: `bind(319)`, `bind(320)`, and the libevent PTP master loop. That is
the entire attack surface — a tiny, auditable clock daemon that speaks PTP and nothing
else (mirrors nqptp's remit).

### IPC choice: shared memory (à la nqptp) + loopback UDP — KEEP libairptp's native transport

**Recommendation: do not build a unix-socket shim. Reuse libairptp's existing shm +
loopback-UDP transport verbatim.** Rationale:

- **It already is the nqptp reference design.** nqptp exposes clock state through a POSIX
  shm segment `"/nqptp"` (`NQPTP_INTERFACE_NAME`), struct-versioned
  (`NQPTP_SHM_STRUCTURES_VERSION 10`), and takes control commands over a socket (port
  9000). libairptp does the same with `/airptp_shm` + version `{0,1}` + loopback-UDP
  control. Same architecture, so we inherit a design that shairport-sync has validated
  in production.
- **The shim already speaks it.** airplay.c only knows `ptpd_*`, and `ptpd_*` only knows
  `airptp_*`. If we keep the native transport, the engine-side shim is *unchanged from
  OwnTone's `ptpd.c`* except pointing find-only. A unix-socket protocol would mean
  reimplementing both ends and re-deriving the peer-id/TLV framing — pure risk for zero
  gain.
- **What crosses the boundary is minimal and read-mostly:**
  - Helper → engine (shm, read-only): `clock_id` (uint64), event/general ports, ipv4/6
    flags, liveness `ts`. Static except the heartbeat. No secrets, no audio.
  - Engine → helper (loopback UDP): "add peer `<addr>`" / "remove peer `<id>`" as PTP
    signaling TLVs. No data plane; the helper independently sends PTP to the speakers.
  - Audio, RTSP, pairing keys, PCM — **none of it crosses.** The helper never sees them.

**One hardening note vs. stock airptpd:** the loopback control channel is an
*unauthenticated* UDP port on 320. Any local process could inject peer add/remove TLVs.
For a personal tool on a single-user Mac this is acceptable; the design doc should record
it as a known limitation and, if we want defense-in-depth later, either (a) bind the
control listener to `127.0.0.1` only, or (b) add a token TLV. Not blocking.

### nqptp comparison — the exact reference interface shape

For the record (from `nqptp-shm-structures.h`), so T-HELPER-DESIGN-1 can note where we
diverge:

```c
#define NQPTP_INTERFACE_NAME "/nqptp"
#define NQPTP_SHM_STRUCTURES_VERSION 10

typedef struct {
  uint64_t master_clock_id;
  uint64_t local_time;
  uint64_t local_to_master_time_offset;
  uint64_t master_clock_start_time;
} shm_structure_set;

struct shm_structure {
  uint16_t version;
  shm_structure_set main;
  shm_structure_set secondary;   // written after main, via __sync_synchronize();
};                                // reader re-reads until main==secondary
```

Differences that matter:
- **nqptp double-buffers** (`main`/`secondary` + `__sync_synchronize`) because it
  publishes *continuously-updating* time/offset fields a client polls every audio frame.
  **libairptp does not**, because our sender-side use only reads static `clock_id`+ports
  once at `find()` and lets the daemon push Sync/Follow-Up to speakers directly — the
  engine never polls a live offset. This is the "always master vs. always slave"
  distinction (libairptp README:14-15): nqptp is a *slave/observer* whose output a
  receiver reads continuously; airptpd is a *master* that emits timing, so its shm is
  just a discovery/handshake record. **We inherit the simpler model — good.**
- **nqptp control = TCP/UDP port 9000 with a text command protocol; airptp control =
  loopback UDP on the PTP general port with binary PTP TLVs.** Ours is more coupled to
  PTP but needs no separate port.

### Crash / restart semantics

- **Helper crash:** `/airptp_shm` `ts` stops advancing. Within `AIRPTP_STALE_SECS`(15s)
  the engine's next `airptp_daemon_find()` returns "stale" (`airptp.c:198`) → treated as
  "no daemon." **However**, an engine that already `find()`'d holds a *snapshot* (the
  munmap at `airptp.c:209` means it won't notice staleness mid-session) and will keep
  `sendto`-ing peer TLVs into the void — those silently no-op once the listener is gone.
  Design consequence: **the engine must re-`find()` on session start**, and the helper
  must be restarted by launchd (`KeepAlive`) before a new session. On crash, in-flight
  PTP to speakers stops → speakers fall back / drop sync; the engine should surface a
  "clock unavailable" status. Note the OS also reclaims the bound 319/320 on process
  death, so restart is clean (no stuck bind) — unless a zombie holds the fd.
- **Stale shm cleanup:** `daemon_shm_create` does `shm_unlink` before `O_EXCL` create
  (`daemon.c:101-103`), so a leftover `/airptp_shm` from a crashed prior instance doesn't
  block restart. Good — the helper is restart-safe without manual cleanup.
- **Engine crash:** helper keeps running; its peer table retains the dead engine's peers
  until they go stale (`last_seen + 15s`, `peers_msg_send` `daemon.c:890`) and
  `peers_prune` drops them. Self-healing.
- **launchd lifecycle:** run the helper as a `KeepAlive` SMAppService daemon so it's
  always up before the engine needs it; the engine is a pure client that tolerates
  find-miss by reporting "PTP unavailable" (exactly OwnTone's degraded path,
  airplay.c:4338 "only NTP will be available").

### How close can we stay to libairptp's daemon code? (licensing + reuse)

- **License: MIT — confirmed.** `libairptp/LICENSE` is the MIT text, "Copyright (c) 2026
  OwnTone." Every source file carries the MIT header verbatim: `airptp.c:1-23`,
  `daemon.c:1-23`, `daemon/airptpd.c:1-23`. This is cleanly separable from the
  **GPL-2.0+** sender cluster (`airplay.c`/`ptpd.c` carry the GPL header,
  e.g. `ptpd.c:1-15`). So **the helper can ship as its own MIT binary** — matching the
  plan's "tiny SMAppService PTP helper ships MIT" (RESOLVED DECISIONS Q4) and SPEC §4.1.
- **Reuse verdict: reuse `airptpd.c` almost verbatim; write only a thin macOS wrapper.**
  What we keep unchanged: all of `libairptp/src/*` (the clock engine) and the bulk of
  `daemon/airptpd.c` (bind→start(shared)→event loop). What we add/change:
  - Package it as a signed Mach-O launchd daemon under `SMAppService` (plist,
    code-signing, firewall allowlist registration — Phase-0 lessons).
  - The `airptpd.c` signal loop already uses **kqueue** on non-Linux
    (`airptpd.c:49-54,192-228,350-367`), so it's macOS-ready as-is; `daemonize()` is
    unused under launchd (launchd owns backgrounding) — drop it and always run
    foreground.
  - `shm_open`/`shm_unlink` and `getaddrinfo("localhost")` all work on macOS unchanged.
  - Feed a real per-host clock-id seed instead of the hardcoded `0xdeadbeef`
    (`airptpd.c:303`).
- **No bespoke shim needed on the helper side.** The "shim" work (T-SHIM-1) is entirely
  on the *engine* side (`ptpd.h`), not the helper. The helper is essentially stock
  upstream code.

### Interim (pre-helper) dev launch

Until the SMAppService helper exists, run the built `airptpd` (or the engine's own
in-process `airptp_daemon_bind`) under an **`osascript` admin-privilege prompt** with
ahh present (RESOLVED DECISIONS / plan T-HELPER-DESIGN-1). For non-privileged local
smoke tests, `airptp_ports_override(30319, 30320)` (as `tests/daemon.c:67` does) lets the
whole find/start/peer path run on high ports with **no root at all** — use this for CI
and unit smoke tests of the shim.

---

## 4. Port-conflict reality — governs the live-test serialization rule

**Confirmed: contention for 319/320 is a hard `EADDRINUSE` failure; exactly one PTP
daemon can hold them per host.**

- `utils_net_bind` → `bind_one` does a **plain `bind()`** with the only setsockopt being
  `IPV6_V6ONLY` (`utils.c:83`). **No `SO_REUSEADDR`, no `SO_REUSEPORT`** anywhere in the
  bind path (`utils.c:60-121`). Verified by grep: the sole `setsockopt` is the v6-only
  flag. So a second binder on the same port gets `EADDRINUSE`; `bind_one` returns -1,
  `airptp_daemon_bind` hits its error path (`airptp.c:112,119`) → returns NULL with
  "Could not bind to PTP event/general port... Check privileges and that it's free."

Implications for every daemon combination on one Mac:

| Contender A | Contender B | Result |
|---|---|---|
| OwnTone (in-proc airptp) | our helper | second `bind()` fails; whoever binds first wins |
| our helper | nqptp | mutually exclusive — nqptp also demands *exclusive* 319/320 (shairport AIRPLAY2.md: "NQPTP must have exclusive access to ports 319 and 320") |
| our helper | **macOS itself** | **macOS reserves 319/320**, so even root `bind()` can fail — this is *why* shairport-sync can't run AP2 on a Mac (AIRPLAY2.md: "Shairport Sync can not run in AirPlay 2 mode on a Mac because NQPTP... needs ports 319 and 320, which are already used by macOS") |

**This is the mechanical basis of the plan's serialization rule** (PLAN §D hot-resources:
"engine-PTP vs nqptp can't both hold live on one host; live PTP sessions take turns").
Because the *shared* daemon model exists precisely to avoid multiple binders, the correct
posture is: **exactly one PTP master on the sender host (our helper), and the receiver's
nqptp on a *different* host** — which is exactly the RESOLVED two-host harness (ahh's
second machine runs shairport-sync AP2 + nqptp). On the two-host setup there is **no
319/320 war at all**: the dev Mac binds them for our sender-side master, the receiver box
binds its own for nqptp. Single-host testing (if ever) must serialize: only one of
{our helper, any nqptp} up at a time, and macOS's own reservation may still block us.

Caveat to re-check at harness time (flagged, not blocking T-PTP-1): whether macOS
*actually* refuses a root `bind()` on 319/320, or merely that shairport's unprivileged
nqptp can't get them. libairptp binds as root in our helper, so it may succeed where
nqptp fails — but the AIRPLAY2.md wording ("already used by macOS") suggests an active OS
listener, which would block even root. **Verify empirically before committing the helper
to 319/320**; if macOS truly owns them, the helper may need `airptp_ports_override` to
non-standard ports AND the speakers told to use those (speakers expect 319/320, so this
could be a real problem — escalate to T-HELPER-DESIGN-1 / harness).

---

## 5. Anything contradicting the plan's assumptions

**No contradictions.** The plan's grounded PTP claims all check out:
- ✅ `airptp_daemon_bind()` = the only root call (§1).
- ✅ `start`/`peer`/`clock_id`/`find` are unprivileged (§1).
- ✅ Three modes exist as described (§1).
- ✅ shared-daemon `find()` + peer add/remove is the helper↔engine split (§2, §3).
- ✅ libairptp is MIT and separable from the GPL sender (§3).
- ✅ `airptp_ports_override` enables non-privileged local testing (§3 interim).
- ✅ 319/320 contention forces live-test turn-taking (§4).

**Refinements / cautions to carry into T-HELPER-DESIGN-1 (not contradictions):**

1. **bind+start are inseparable in one process.** The plan's phrasing ("helper = bind +
   run master clock; unprivileged engine = find + peer add/remove") is right, but be
   explicit that `start()` must run in the *same* process as `bind()` (it consumes the
   bound fds). The helper does bind→start(shared); the engine never calls start. (§1)

2. **macOS may own 319/320 even against root.** The two-host harness sidesteps this, but
   the *shipped helper on the user's Mac* still has to bind 319/320 locally to be the PTP
   master for the speakers. Whether macOS's reservation blocks a root `bind()` is
   unverified and is a genuine risk to the whole helper design — must be tested before
   T-HELPER-DESIGN-1 finalizes. (§4)

3. **Client `find()` takes a one-shot snapshot** (munmaps immediately, `airptp.c:209`),
   so the engine won't detect a mid-session helper crash via the shm heartbeat. The
   design must re-`find()` per session and rely on launchd `KeepAlive`; surface a
   "clock unavailable" status on find-miss. (§2, §3 crash semantics)

4. **The loopback control channel is unauthenticated** (any local process can inject peer
   TLVs on :320). Acceptable for a personal single-user tool; record as a known
   limitation, optionally bind control to 127.0.0.1. (§3)

5. **airptp shm is single-buffered, unlike nqptp's double-buffered `main`/`secondary`.**
   This is *correct and sufficient* for the master-clock (sender) role — do not "fix" it
   to match nqptp; the fields the engine reads are write-once + a lone heartbeat. (§3)

---

## Appendix — file:line index

libairptp (all MIT):
- API header: `libairptp/airptp.h`
- `airptp_daemon_bind` (root bind): `libairptp/src/airptp.c:102-144`
- `airptp_daemon_start`: `airptp.c:148-175`
- `airptp_daemon_find` (RO mmap): `airptp.c:177-224`
- `airptp_peer_add/remove`: `airptp.c:226-275`
- `airptp_clock_id_get`: `airptp.c:292-300`
- `airptp_ports_override`: `airptp.c:308-313`
- shm create/heartbeat/destroy: `libairptp/src/daemon.c:84-124,365-372`
- daemon thread `run`/start/stop: `daemon.c:432-583`
- shm struct `airptp_daemon_info`: `libairptp/src/airptp_internal.h:57-67`
- shm name/version/stale: `airptp_internal.h:11-17`
- peer table cap (32): `airptp_internal.h:20`
- peer add/del TLV make: `libairptp/src/ptp_msg_handle.c:466-511`
- loopback control send: `ptp_msg_handle.c:851-876,957-972`
- peer TLV receive→daemon_peer_add/del: `ptp_msg_handle.c:694-739`
- plain bind, no SO_REUSE*: `libairptp/src/utils.c:60-121` (bind at `:87`)
- bundled daemon `main`: `libairptp/daemon/airptpd.c` (bind :297, start(shared) :303)
- test client (client mode): `libairptp/tests/client.c`
- test daemon (ports override): `libairptp/tests/daemon.c:67-73`
- README (modes, always-master vs nqptp-slave): `libairptp/README.md:1-15`

sender consumption (GPL-2.0+):
- `ptpd.h` wrapper surface: `src/ptpd.h`
- `ptpd.c` adapter (privilege split at find_or_bind): `src/ptpd.c:73-130`
- airplay.c PTP calls: `src/outputs/airplay.c:55,1173,1244-1245,2741,3167,3233,4335,4382`
- `handle_timingpeerinfo` (peer add from SETUP): `airplay.c:3140-3173`

nqptp reference (github.com/mikebrady/nqptp):
- shm name `/nqptp`, version 10, `shm_structure`/`shm_structure_set`, double-buffer:
  `nqptp-shm-structures.h`
- control port 9000; exclusive 319/320; macOS unsupported: `nqptp/README.md`,
  `shairport-sync/AIRPLAY2.md`
