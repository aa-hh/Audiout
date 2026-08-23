# PTP Privileged-Helper Design

Task **T-HELPER-DESIGN-1** (PLAN-PHASE-2.md, §C Wave 2). **Design only — no
implementation.** This is the security contract for the one privileged surface in
the whole product (SPEC.md §4.1: *"no large or third-party component ever runs
privileged, and everything privileged is small enough to read line-by-line"*).

Primary input: `AirPlayEngine/docs/ptp-study.md` (T-PTP-1 — the libairptp
privilege-boundary analysis). Every design claim below is grounded in that study;
citations of the form `airptp.c:NNN` / §N refer to it. Secondary inputs:
SPEC.md §4 (security principles) and PLAN-PHASE-2.md RESOLVED DECISIONS.

Companion deliverable: the **T-PTP-PROBE** task spec at the end — a gating
empirical check that must run **before** any helper code is written.

---

## 0. TL;DR

- **The helper is a tiny MIT root daemon that owns UDP 319/320 and the PTP master
  clock, and nothing else.** As shipped (T2), it is a freshly-written
  `Sources/ptp-helper/main.c` — the vendored tree never actually contains a
  `daemon/airptpd.c` to re-home (see §6.1) — that links only `Clibairptp` +
  libevent and calls `airptp_daemon_bind(NULL)` [root] then
  `airptp_daemon_start(hdl, seed, is_shared=true)`. No audio, no RTSP, no pairing, no
  PCM — exactly nqptp's remit (ptp-study §3).
- **The unprivileged engine is a pure PTP client.** It consumes clock state via
  read-only `airptp_daemon_find()` (`shm_open(/airptp_shm, O_RDONLY)` + mmap) and
  drives peers via `airptp_peer_add/remove()` (`sendto localhost:320`). All
  RTSP/ALAC/RTP/pairing stays engine-side (ptp-study §1, §3).
- **IPC = libairptp's native transport verbatim** (POSIX shm read-only for clock
  state + loopback-UDP PTP TLVs for peer control). Do **not** invent a
  unix-socket shim (ptp-study §3; justified in §4 below).
- **GATING UNKNOWN → T-PTP-PROBE.** The study flags (§4, §5.2) that it is
  *unverified* whether a **root** `bind()` of 319/320 even succeeds on macOS —
  macOS may reserve those ports (shairport's AIRPLAY2.md: "already used by
  macOS"). If a root bind fails, the entire helper-on-319/320 design must be
  rethought. A ~30-line probe (spec'd at the end) must run first.

---

## 1. The exact privilege boundary

### 1.1 What runs as root — and only this

The helper process, and only the helper process, ever holds root, and only for:

1. `airptp_daemon_bind(NULL)` — the **single privileged call** in the entire
   libairptp surface. It binds UDP **319** (`PTP_EVENT_PORT`) and **320**
   (`PTP_GENERAL_PORT`) via `utils_net_bind` → `bind()` (`utils.c:87`). Ports
   < 1024 require root (ptp-study §1).
2. `airptp_daemon_start(hdl, seed, is_shared=true)` — spawns the libevent PTP
   master thread on the *already-bound* fds and creates `/airptp_shm`.
   **`start()` needs no privilege itself** (airptp.h:38 verbatim), but it consumes
   the fds `bind()` stored in the same handle, so **bind and start are inseparable
   in one process** (ptp-study §1, §5.1). The helper does both; the engine does
   neither.
3. The libevent master loop that answers 319/320 and emits Announce (1 s) /
   Signaling (1 s) / Sync+Follow-Up (125 ms) to peers (ptp-study §2).

That is the **entire** privileged attack surface: two `bind()`s plus a fixed-size
PTP packet loop. No dynamic-parse-heavy code, no filesystem writes beyond the
shm, no audio path. Auditable line-by-line, per SPEC §4.1.

### 1.2 What the helper deliberately does NOT do

No RTSP, no pairing/HomeKit keys, no ALAC/RTP, no PCM, no discovery, no config
files, no metadata. It never sees audio or secrets. It is a clock daemon, full
stop (mirrors nqptp — ptp-study §3).

### 1.3 What the unprivileged engine does

The shipped engine is a pure **deferred client** (mode 3, ptp-study §1), as landed in
`AirPlayEngine/Sources/CAirPlayEngine/shims/ptpd.c` (T-SHIM-1). By default it
is **find-only** — it never calls `airptp_daemon_bind`, and it **does not find the
clock at engine startup** (T2b/7295940). Instead, the clock lookup is deferred to
connect time: when a user clicks a device to stream, the app connects to the helper's
Mach service (T2/4c7da45, demand-starting it), then the session's `convergeDevice`
call runs `ptpd_daemon_probe()` (T4/1298a70) which finds the helper and snapshots the
clock_id. A dev/CI-only escape hatch, `AUDIOUT_PTP_INPROC_BIND=1`, restores the old
in-process bind so the engine can still be exercised end-to-end before the root helper
is installed (see §6.3); the shipped default has no such fallback. The shim reimplements
OwnTone's six `ptpd_*` wrappers pointed **find-only**:

- `ptpd_find_or_bind()` → `airptp_daemon_find()` **only** — never binds (the
  helper owns the ports). Read-only mmap of `/airptp_shm`. **Now called per connect,
  not at engine start** (T4).
- `ptpd_init()` → no-op (a found shared daemon means `start()` is skipped —
  ptp-study §1 `ptpd.c:120-121`). **Returns 0 ("deferred") when no daemon is present**
  (T2b/7295940), so the engine never latches `airplay_ptp_is_disabled` until a live
  helper is found.
- `ptpd_clock_id_get()` → `airptp_clock_id_get()` — pure struct read from the
  client's snapshot; the value is sent to the speaker in RTSP SETUP
  (`airplay.c:2741`).
- `ptpd_slave_add()/remove()` → `airptp_peer_add/remove()` — `sendto localhost:320`
  as a peer's timing-address is learned from its SETUP reply
  (`handle_timingpeerinfo`, ptp-study §1).

### 1.4 What crosses the boundary (diagram)

```
┌──────────────────────────────────────────────┐         ┌───────────────────────────────────┐
│  PTP HELPER  (root, SMAppService daemon)       │         │  AirPlayEngine  (unprivileged user) │
│  MIT libairptp, shared-daemon mode             │         │  GPL sender + ptpd.h shim (client)  │
│  ── the ONLY privileged process ──             │         │                                     │
│                                                │         │                                     │
│  airptp_daemon_bind(NULL)    ← ROOT (319+320)  │         │  airptp_daemon_find()               │
│  airptp_daemon_start(seed, is_shared=true)     │         │                                     │
│  runs PTP master libevent loop                 │         │                                     │
│                                                │         │                                     │
│  publishes /airptp_shm  ─────── shm (RO) ──────┼────────▶│  mmap PROT_READ:                    │
│    { version, clock_id, ts(heartbeat),         │  clock  │    clock_id, event/general ports,   │
│      event_port, general_port, ipv4/6 }        │  state  │    ipv4/6 flags, liveness ts        │
│                                                │         │    → memcpy snapshot, munmap        │
│                                                │         │                                     │
│  listens 127.0.0.1:320 ◀─── loopback UDP ──────┼◀────────┤  airptp_peer_add(addr)/remove(id)   │
│    PTP signaling TLVs (peer add/del)           │ control │    sendto localhost:320 (PTP TLVs)  │
│                                                │         │                                     │
│  independently sends PTP Sync/Follow-Up/       │         │  ── stays engine-side, NEVER cross: │
│  Announce to the speakers on the LAN  ─────────┼── LAN ─▶│     RTSP, ALAC, RTP audio, pairing  │
│  (data plane is the helper's own PTP only)     │ (speakers)│   keys, PCM, discovery, config    │
└──────────────────────────────────────────────┘         └───────────────────────────────────┘

CROSSES helper→engine:  clock_id (u64), ports, ipv4/6 flags, liveness ts   [read-only, static + heartbeat]
CROSSES engine→helper:  "add peer <addr>" / "remove peer <id>"             [PTP TLVs over loopback]
NEVER CROSSES:          audio/PCM, RTSP, pairing keys, ALAC, metadata      [helper never sees them]
```

The helper→engine channel carries **no secrets and no audio** — just a static
discovery/handshake record plus a heartbeat. The engine→helper channel is
control-only (no data plane); the helper independently emits PTP timing to the
speakers on the LAN (ptp-study §3).

---

## 2. SMAppService packaging

### 2.1 What SMAppService gives us

`SMAppService.daemon(plistName:)` registers a **launchd daemon** whose executable
and launchd plist ship **inside the app bundle** (`Contents/Library/LaunchDaemons/`
for the plist, `Contents/MacOS/` or a bundled tool dir for the binary). No
installer, no `sudo` script, no manual `/Library/LaunchDaemons` copy. The app
calls `register()`; the OS validates the bundled plist and code signature and runs
the daemon as **root** under launchd. This is the "official mechanism" SPEC §4.1
names.

### 2.2 The launchd plist (shape)

Shipped verbatim as `scripts/ptp-helper.plist`, installed by
`scripts/make-app.sh` at `Contents/Library/LaunchDaemons/<Label>.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.audiout.Audiout.ptphelper</string>

    <key>BundleProgram</key>
    <string>Contents/MacOS/ptp-helper</string>   <!-- path is relative to the app bundle -->

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>                                       <!-- respawn only on crash (non-zero exit) -->

    <key>MachServices</key>
    <dict>
        <key>com.audiout.Audiout.ptphelper</key>
        <true/>
    </dict>                                       <!-- demand-start trigger: launchd launches on first app connect -->

    <key>AssociatedBundleIdentifiers</key>        <!-- ties the daemon to this app in Login Items -->
    <string>com.audiout.Audiout</string>

    <key>ProcessType</key>
    <string>Interactive</string>                  <!-- low-latency: PTP is timing-sensitive -->
</dict>
</plist>
```

Notes:
- `BundleProgram` (not `Program`) — SMAppService daemons reference the executable
  by a bundle-relative path.
- `make-app.sh` requires `Label` + ".plist" to equal the plist's own filename
  (`$LAUNCH_DAEMONS_DIR/$HELPER_LABEL.plist`) — `SMAppService.daemon(plistName:)`
  resolves the plist by that exact name.
- The daemon runs **foreground** under launchd — `Sources/ptp-helper/main.c` has
  no `daemonize()` call at all; launchd owns backgrounding (ptp-study §3's
  survey of OwnTone's upstream daemon reached the same conclusion, "reuse
  airptpd.c almost verbatim", but the shipped helper is a fresh file, not a
  port of that daemon — see §6.1).
- **On-demand launch (T3):** `RunAtLoad` is removed and `MachServices` + demand-start
  replace the always-up guarantee. The helper launches only when the app connects to
  the Mach service (typically when the user clicks a device to stream). **Why:** macOS's
  own AirPlay 2 sender needs UDP 319/320; holding them permanently breaks the system
  AirPlay dropdown (confirmed live 2026-07-26). T5's automatic takeover requires them
  to be released when idle, so the helper must not bind at boot — instead it launches
  on demand, binds briefly during streaming, and self-exits when the last peer disconnects.

### 2.3 One-time user approval UX

`SMAppService` registration is **not** silent. On first `register()` the daemon
appears **disabled**, and macOS surfaces it in **System Settings → General →
Login Items & Extensions** (the "Allow in the Background" list). The user must
toggle it on once. The app must:

1. Call `SMAppService.daemon(plistName:).register()` at first launch (or when the
   user first activates a PTP-requiring session).
2. Read `.status` — expect `.requiresApproval` on first run.
3. When `.requiresApproval`, show a plain, honest explainer ("AirPlay 2 sync needs
   a small background helper to keep speaker clocks in sync — approve it in
   Login Items") and deep-link the user to Login Items via
   `SMAppService.openSystemSettingsLoginItems()`.
4. Poll/observe `.status` until `.enabled`; only then treat PTP as available.
   Until then, run degraded (NTP-only path / "clock unavailable" — §5.4).

Sign + firewall-register at install (Phase-0 lesson, SPEC §4 pt 4, 0c gotcha 2):
the daemon binary is Developer-ID signed, and the Application Firewall must
allowlist it and it must be **restarted** after allowlisting (the firewall
verdict sticks to already-bound sockets — SPEC 0c). Under launchd `KeepAlive`,
"restart" = `SMAppService` re-register / `launchctl kickstart -k`, or simply the
next KeepAlive respawn.

### 2.4 KeepAlive — crash-only respawn with idle-exit

The study flags a real hazard (ptp-study §2, §3 crash semantics, §5.3): a client
that already `find()`'d holds a **one-shot snapshot** — it `munmap`s immediately
(`airptp.c:209`), so it will **not** notice a mid-session helper crash via the shm
heartbeat, and will keep `sendto`-ing peer TLVs into a dead listener (silent
no-op). Two mechanisms together handle this:

- **`KeepAlive={SuccessfulExit: false}`** (T2, T3) → launchd respawns the helper
  **only on crash** (non-zero exit). A **clean exit 0** (idle-exit when the peer
  table is empty, or bind-give-up when 319/320 never became available) is left
  down, not fought back up. `daemon_shm_create` does `shm_unlink` before `O_EXCL`
  create (ptp-study §3), so a leftover `/airptp_shm` from the dead instance never
  blocks the restart — the helper is **restart-safe with no manual cleanup**. The
  OS also reclaims the bound 319/320 on process death, so the rebind is clean. The
  exit-code contract is the bridge: every expected outcome (idle exit, bind gave up,
  SIGTERM) returns 0; only a genuine internal failure returns non-zero.
- **Engine re-`find()` per connect** (T4) → the engine calls
  `airptp_daemon_find()` **at the start of every session** (not once at launch) and
  checks the returned liveness `ts` against the 15 s stale window (`AIRPTP_STALE_SECS`,
  `airptp.c:198`). The app also **demand-starts** the helper via a Mach service
  connection on the click that starts the session (T2 check-in), so a lazy helper
  has time to bind before the engine's find window opens. A stale/missing find =
  "PTP unavailable" surfaced to the UI; the app waits for the next session start
  (or user retry) to re-find.

Net: launchd respawns on crash only (idle-exit keeps ports free for macOS's AirPlay);
per-session demand-start and re-find guarantee the engine can find a live helper when
a user clicks to stream.

---

## 3. The UNVERIFIED macOS risk — does a root bind of 319/320 succeed? (GATING)

**This is the gating unknown for the entire helper design.** The study is
explicit that it is *unverified* whether macOS permits a **root** `bind()` on
319/320 (ptp-study §4 table row 3, §4 closing caveat, §5.2):

- shairport-sync's AIRPLAY2.md says AP2 mode is infeasible on a Mac because nqptp
  "needs ports 319 and 320, which are already used by macOS." That wording
  ("already used by macOS") suggests an **active OS listener**, which would reject
  even a root binder — not merely that unprivileged nqptp can't reach a low port.
- But nqptp binds *unprivileged*; our helper binds *as root*. It is genuinely
  unknown whether root changes the outcome. libairptp uses a plain `bind()` with
  **no `SO_REUSEADDR`/`SO_REUSEPORT`** (ptp-study §4, `utils.c:83`), so if macOS
  holds the port, the helper gets a hard `EADDRINUSE` and `airptp_daemon_bind`
  returns NULL — no fallback.

**Why this gates everything:** if macOS owns 319/320 even against root, the whole
"helper binds 319/320" premise collapses. The speakers *expect* PTP on 319/320,
so we cannot simply move the helper to `airptp_ports_override` high ports — the
speakers won't follow (ptp-study §4 caveat: "speakers expect 319/320, so this
could be a real problem"). A failure here forces a **design rethink**
(candidates, all worse: disable macOS's PTP responder if one exists; a
network-namespace/second-interface trick; or accept that the sender host cannot
also be a PTP master and rearchitect). None of that should be designed
speculatively — **run the probe first.**

The probe (**T-PTP-PROBE**, full spec at the end) is a ~30-line C or Swift
program that, elevated via an `osascript` admin dialog, attempts `bind()` on UDP
319 and 320 and reports `SUCCESS` vs `EADDRINUSE`/`EACCES`. It has **zero
dependency on any helper code** and must run **before** T-HELPER-DESIGN-1 is
considered final and before any helper is built. **Mark: gating unknown.**

Two-host harness note: the RESOLVED two-host setup sidesteps 319/320 *contention*
(dev Mac binds them for the master; the receiver box's nqptp binds its own on a
different host — ptp-study §4). But it does **not** answer this probe — the
*shipped helper still binds 319/320 on the user's own Mac*, so the probe tests the
one thing the two-host harness can't (ptp-study §5.2).

---

## 4. IPC — reuse libairptp's native transport; do NOT invent a unix-socket shim

**Decision: keep libairptp's native transport verbatim** — POSIX shm
`/airptp_shm` (single-buffered, master role, read-only for clients) for clock
state, plus loopback-UDP:320 PTP TLVs for peer control (ptp-study §3).

Justification (ptp-study §3):

1. **It already is the nqptp reference design.** nqptp publishes clock state via a
   versioned POSIX shm (`/nqptp`) and takes control over a socket; libairptp does
   the same (`/airptp_shm`, version `{0,1}`, loopback-UDP control). We inherit an
   architecture shairport-sync has validated in production.
2. **The shim already speaks it, unchanged.** `airplay.c` only knows `ptpd_*`;
   `ptpd_*` only knows `airptp_*`. Keeping the native transport means the
   engine-side shim is *OwnTone's `ptpd.c` minus the bind branch* (find-only). A
   unix-socket protocol would force reimplementing **both** ends and re-deriving
   the peer-id/TLV framing — pure risk, zero gain.
3. **What crosses is minimal and read-mostly** (§1.4): a static clock record +
   heartbeat one way, peer add/remove TLVs the other. No secrets, no data plane —
   there is nothing a richer IPC would protect.
4. **Single-buffered shm is correct for the master role.** nqptp double-buffers
   (`main`/`secondary` + `__sync_synchronize`) because it streams a
   continuously-updating offset a client polls every frame. Our sender only reads
   static `clock_id`+ports once at `find()` and lets the daemon push Sync/Follow-Up
   to speakers directly — the engine never polls a live offset. **Do not "fix"
   the shm to match nqptp** (ptp-study §5.5).

The helper side needs **no bespoke shim at all** — `Sources/ptp-helper/main.c`
is a thin `bind→start(shared)→wait-for-signal→end` driver directly over
`airptp_daemon_bind`/`airptp_daemon_start`/`airptp_end` (§6.1), the same shape
the study found in OwnTone's own daemon (ptp-study §3). All shim work
(T-SHIM-1) is engine-side, in
`AirPlayEngine/Sources/CAirPlayEngine/shims/ptpd.c`.

**One deliberate addition to the Mach service, for seamless handoff:** the
per-peer XPC handler in `ptp_helper_mach_checkin()` recognizes exactly one
message — a dictionary with `{"release": true}` — and treats it as a shutdown
trigger, nothing more (no reply, no other key ever read). Without it, handing
319/320 back to macOS means waiting out the ~15s idle-exit window (§2.4); the
seamless-handoff feature needs that in ~1s, right when the app has already
decided to give up the ports. This does not change the answer above: shm +
loopback-UDP remain the only data path, and the release verb is a trigger, not
a transport — the 15s idle path is still the normal, unsolicited case, this is
just an accelerator for the one case where the app already knows it's time.

---

## 5. Threading / lifecycle

### 5.1 Startup order: helper launched on demand at session start

1. **App launch:** register the SMAppService daemon (§2.3); ensure `.status ==
   .enabled` (else drive the approval UX). The helper is **not running yet**
   (no `RunAtLoad`); it will be launched on demand when a user clicks a device.
2. **User clicks device to stream:** app calls `PTPHelperService.ensureHelperUp()` or
   connects to the Mach service (T2 check-in) → launchd **demand-starts** the helper
   (if not already running).
3. **Helper start (root, on-demand):** `bind(319/320)` with retry (~10 s) → `start(is_shared=true)`
   → publishes `/airptp_shm`, begins the master loop. `start()` returns only after the loop is
   up and the shm exists (the daemon blocks the caller on a start-result pipe —
   ptp-study §2 lifecycle). **Failure to bind (ports busy, e.g. macOS AirPlay holding them)
   is not fatal** (T2/4c7da45) — the helper exits cleanly (status 0) and will retry on the
   next session start (T4).
4. **Engine session start (unprivileged):** on **each** session, **`ptpd_daemon_probe()`**
   (T4/1298a70) calls `airptp_daemon_find()` → snapshot clock_id/ports; send clock_id to the
   speaker in RTSP SETUP; as each speaker's SETUP reply returns its timing-peer address,
   `airptp_peer_add()` over loopback. The helper then emits PTP to that speaker.
5. **Session teardown:** `airptp_peer_remove()` per speaker (`airplay.c:1244`).
   The peer table drops to zero; the helper's idle-exit timer (T2) counts down ~15 s,
   then the helper calls `airptp_end()` and exits cleanly (status 0) — launchd does not
   respawn it (§2.4), and UDP 319/320 are released so macOS can reclaim them.

The helper's lifecycle is **session-scoped and self-managing** — it launches when needed,
binds the ports briefly during streaming, and releases them when idle (unlike nqptp,
which is long-lived; this choice is what enables coexistence with macOS's AirPlay per
§2.2).

### 5.2 What the engine does on stale / no find() data

`airptp_daemon_find()` returns "no daemon" if `/airptp_shm` is absent, its
`version_major` mismatches, or its heartbeat `ts + 15 s < now` (ptp-study §1,
§2). On any of these the engine must:

- **Not** start a PTP-timed session against Sonos/HomePod (they silently discard
  non-PTP audio — SPEC 0b: pyatv's SNTP path plays silence on Sonos).
- Surface **"clock unavailable"** status to the UI (mirrors OwnTone's degraded
  path, `airplay.c:4338` "only NTP will be available").
- Wait for launchd `KeepAlive` to (re)start the helper, then re-`find()` before
  retrying. Because the engine holds a one-shot snapshot (§2.4), it must
  re-`find()` per session rather than trusting a cached handle across a possible
  crash.

### 5.3 Unauthenticated loopback control — accepted limitation (recorded)

The loopback control channel on :320 is **unauthenticated**: any local process
can inject peer add/remove TLVs, and the daemon's peer table is **global, not
partitioned per client** (ptp-study §2, §3, §5.4) — a second local consumer could
add/remove the same speaker (peers are keyed by a djb hash of the address, so two
adders share one entry and either can remove it).

**For this personal, single-user tool this is acceptable** and is recorded here as
a known limitation per the task requirement. Defense-in-depth options, none
blocking and none adopted now (ptp-study §3, §5.4):
- bind the control listener to `127.0.0.1` only (reduces exposure to local
  processes — it is already loopback, so marginal);
- add a shared-token TLV so only our engine's add/remove are honored.

Cap: 32 simultaneous PTP peers (`AIRPTP_MAX_PEERS`, ptp-study §2) — far above our
2 Sonos + 1 AirPort Express fleet.

---

## 6. Build / verification note

### 6.1 The helper is separable MIT code

`libairptp` is **MIT** (`LICENSE` ©2026 OwnTone; every file carries the MIT
header — ptp-study §3), cleanly separable from the **GPL-2.0+** sender cluster.
So the helper ships as **its own MIT binary** — matching RESOLVED DECISIONS Q4
("the tiny SMAppService PTP helper ships MIT") and SPEC §4.1.

As landed (T1/T2), the vendored `libairptp/` tree checked into this repo
(`AirPlayEngine/Sources/CAirPlayEngine/libairptp/`) never actually included a
`daemon/airptpd.c` to reuse — only `src/{airptp,daemon,utils,ptp_msg_handle}.c`
plus `airptp.h`. `ptp-study.md`'s survey of upstream OwnTone assumed that
standalone daemon would be re-homed verbatim; instead:

- `libairptp/src/*` (the clock engine) moved into its **own SwiftPM target**,
  `Clibairptp` (see `AirPlayEngine/Package.swift`), so both the helper and the
  engine's shim can depend on it without duplicating compilation;
- the helper itself is a **freshly-written** `bind→start(shared)→wait-for-signal→end`
  driver, `AirPlayEngine/Sources/ptp-helper/main.c` — not a port of any
  `airptpd.c` — that depends only on `Clibairptp` (+ a **statically-linked**
  libevent — see §6.1.1), so it stays small enough to read line-by-line
  (SPEC §4.1);
- it is packaged as a Developer-ID-signed Mach-O launchd daemon under
  SMAppService (plist §2.2, signing, firewall allowlist);
- it has no `daemonize()` call — launchd owns backgrounding; it runs foreground;
- it derives a real per-host clock-id seed via `gethostuuid()` (folded to a
  u64), stable across restarts on the same host — never a hardcoded constant
  and never passed in from the app;
- its signal handling uses a `sig_atomic_t` flag checked in a plain
  `pause()`-style wait loop (SIGTERM/SIGINT), not the vendored library's own
  event loop primitives; `shm_open`/`shm_unlink`/`getaddrinfo("localhost")` all
  work unchanged on macOS.

A `AUDIOUT_PTP_PORTS` env var (parsed in `main.c`, applied via
`airptp_ports_override()` before binding) lets the helper itself run on high,
unprivileged ports for the same CI/dev path described in §6.2.

### 6.1.1 The helper statically links libevent (Library Validation)

**The helper links `libevent_core.a` + `libevent_pthreads.a` statically, not the
Homebrew libevent dylib the app links.** This is not a size optimization — it is
required for the hardened-runtime Developer-ID launchd daemon to run at all.

The first Developer-ID live test (2026-07-21) crashed the daemon at load time
(`launchctl print` → `last exit reason = OS_REASON_DYLD`, KeepAlive respawning in
a throttle loop). `dyld` refused to map the Homebrew
`libevent-2.1.7.dylib` into the process: *"code signature ... not valid for use in
process: mapping process and mapped file (non-platform) have different Team IDs."*
That is **Library Validation** (part of the hardened runtime): a Developer-ID
binary may only load libraries signed by the same Team ID or by Apple, and
Homebrew's libevent is ad-hoc-signed. The **app** dodges this with the
`com.apple.security.cs.disable-library-validation` entitlement
(`scripts/Audiout.entitlements`); the **helper deliberately carries no
entitlements** (§1.1 — smallest privileged surface), so it enforces validation.

Rather than weaken the root daemon with that entitlement, the helper
**static-links** libevent, so at runtime it has **no external dylib dependency at
all** (`otool -L Contents/MacOS/ptp-helper` → only `libSystem`) and there is
nothing for Library Validation to reject. Mechanically (`AirPlayEngine/Package.swift`):
the shared `Clibairptp` target carries **no** libevent linker settings (a
static-library target does not resolve its own external symbols — its consumers
do), so its two consumers link libevent *differently* — `CAirPlayEngine` (the app
path) links the dylib as before, while the `ptp-helper` executable passes the
`.a` archive paths to the linker. Verified live: after the fix the daemon runs as
**root**, stable, having bound 319/320 and started the PTP master.

### 6.2 Which side runs what in the two-host harness (clarified)

This is the crux the task asks to nail down:

| Host | Role | PTP software | Ports |
|---|---|---|---|
| **THIS Mac** (dev/sender) | AirPlay **sender** + PTP **master** | our helper (`airptpd` in shared-daemon mode; or interim in-proc `airptp_daemon_bind` under osascript) | binds 319/320 **locally** as the master clock for the speakers |
| **Second machine** (receiver, RESOLVED) | AirPlay-2 **receiver** | **its own nqptp** (shairport-sync AP2 needs it) | binds 319/320 **on that box** |

So: **the sender Mac runs our helper (PTP master); the receiver box runs its own
nqptp (PTP slave/observer for shairport).** They are on **different hosts**, so
there is **no 319/320 contention** — each binds its own (ptp-study §4). This is
precisely why the two-host harness works where single-host does not. Do **not**
run nqptp on the sender Mac; do **not** expect our helper to serve the receiver's
clock — each host owns its own PTP endpoint. (libairptp is "always master";
nqptp is "always slave" — ptp-study §3, complementary roles, one per host.)

For CI / unprivileged smoke tests of the shim (no root, no second host),
`airptp_ports_override(30319, 30320)` runs the whole find/start/peer path on high
ports with **no privilege** (ptp-study §3 interim) — this validates the
engine↔daemon IPC without touching 319/320 or the firewall.

### 6.3 Interim dev launch (pre-helper / pre-signing)

Two dev fallbacks exist, both bypassing the SMAppService/root path:

- run the built `ptp-helper` binary directly under an **`osascript`
  admin-privilege prompt** with ahh present (RESOLVED DECISIONS; ptp-study §3
  interim) — the live-test stand-in for the signed launchd daemon;
- or set `AUDIOUT_PTP_INPROC_BIND=1` so the engine's own shim
  (`shims/ptpd.c`) falls back to an in-process `airptp_daemon_bind`, skipping
  the helper/IPC path entirely (§1.3).

**Neither is a substitute for the real `SMAppService.register()` → root-bind
path**, which needs a Developer-ID-signed build to exercise live — this repo
is still ad-hoc signed, so that path is build/bundle/unprivileged-IPC-verified
only, not live-tested, until Developer-ID signing lands.

### 6.4 Verification checklist for this design

**Waves 1–2 (T1–T7) BUILT+COMMITTED (2026-07-26, SHAs in PLAN-AIRPLAY-COEXISTENCE.md):**

- [x] **T-PTP-PROBE equivalent** — G1 live port probe (PLAN Wave 0) confirmed root bind of 319/320 succeeds on macOS;
      macOS releases ports ~1–3 s after default-output switch-away.
- [x] **T1 (libairptp)** — `airptp_peer_active_count()` exposed + `localhost_msg_send()` family fix (40f49b6).
- [x] **T2 (helper on-demand)** — Mach check-in, bind retry, idle-exit, exit-code contract (4c7da45).
- [x] **T3 (plist)** — `RunAtLoad` removed, `KeepAlive={SuccessfulExit:false}`, `MachServices` + demand-start (e05f5a1).
- [x] **T4 (app demand-start + per-connect probe)** — `PTPHelperService`, `ptpd_daemon_probe()`, `PTPClockProbe.swift` (1298a70).
- [x] **T5 (default-output switch)** — `DefaultOutputSwitcher.swift` (c437b26).
- [x] **T6 (takeover UI)** — `TakeoverStatus`, `BackendEvent.takeoverStatus`, banner (bee8ef1).
- [x] **T7 (yield-back verification)** — `PTPYieldBackTests.swift` (281cd66).

**Remaining:**
- [ ] SMAppService daemon registers, appears in Login Items, reaches `.enabled` after user approval (ad-hoc cannot verify; Developer ID needed).
- [ ] Engine (client mode, per-connect) finds the helper's `/airptp_shm`, reads clock_id,
      adds/removes a peer over loopback — CI validated on high ports via `airptp_ports_override` with no root.
- [ ] Crash-respawn: helper crashes mid-session (`kill -9`); launchd respawns on KeepAlive;
      engine's next session peer-add detects stale shm and surfaces "clock unavailable"; recovery on retry.
- [ ] Idle-exit: session ends (all peers removed) → helper self-exits ≤ 45 s → ports free → system AirPlay dropdown works.
- [ ] Two-host live test (dev Mac = helper, receiver = shairport) still pending (Alec's post-commit checklist).

---

## 7. Cross-references

- `AirPlayEngine/docs/ptp-study.md` — T-PTP-1, the privilege-boundary analysis
  (primary input; every §/file:line citation above resolves there).
- `AirPlayEngine/docs/seam-map.md` — T-SEAM-1, the `ptpd.h`→`airptp_*` shim
  surface (T-SHIM-1 consumes both this doc and the study).
- `SPEC.md` §4 (security principles), §8 0c (PTP-needs-root + firewall lessons).
- PLAN-PHASE-2.md — T-HELPER-DESIGN-1, RESOLVED DECISIONS.

---

## APPENDIX — T-PTP-PROBE (follow-up task spec, schedulable)

**T-PTP-PROBE — Empirical: does a root bind of UDP 319/320 succeed on macOS?**
**⛔ GATING UNKNOWN — schedule and run BEFORE any helper implementation.**

- **files:** `dev/ptp-probe/` (new, throwaway) — one ~30-line C or Swift program +
  a one-line osascript launcher; write findings to
  `dev/notes/p2-ptp-bind-probe.md`.
- **why (gating):** The helper design (§3) assumes a **root** process can `bind()`
  UDP 319/320 on macOS. This is **unverified** — macOS may reserve those ports
  even against root (ptp-study §4, §5.2; shairport AIRPLAY2.md "already used by
  macOS"). If the bind fails, the "helper owns 319/320" premise collapses and the
  design must be reworked (§3). No helper code should be written until this
  passes. The two-host harness does **not** answer this — the shipped helper still
  binds 319/320 on the user's own Mac.
- **what:** A minimal standalone program that:
  1. creates two UDP sockets (one AF_INET or AF_INET6 per the helper's plan; test
     both families if quick);
  2. attempts `bind()` to port **319**, then **320**, on `INADDR_ANY`/`in6addr_any`;
  3. uses a **plain `bind()` with no `SO_REUSEADDR`/`SO_REUSEPORT`** (match
     libairptp's `utils.c` exactly, so the result reflects the real helper —
     ptp-study §4);
  4. prints, per port: `SUCCESS` or the exact errno (`EADDRINUSE` = port taken,
     `EACCES` = privilege — should not occur under root, `EADDRNOTAVAIL`, etc.);
  5. exits non-zero if either bind fails.
  Run it **twice**: (a) unelevated — expect `EACCES` (confirms the privilege
  requirement and that the probe works); (b) **elevated via an `osascript`
  admin-privilege dialog** (`do shell script "…" with administrator privileges`),
  ahh present — this is the answer that matters.
  Optional but cheap: also probe with `airptp_ports_override`-style high ports
  (30319/30320) unelevated to confirm the non-privileged CI path binds cleanly.
- **acceptance / decision:**
  - **PASS** = both 319 and 320 `bind()` **SUCCESS under admin/root**. → The helper
    design in this doc stands; proceed to build the SMAppService helper.
  - **FAIL** = either returns `EADDRINUSE` (or otherwise fails) **under root**. →
    macOS owns the port; **escalate — the helper-on-319/320 design needs a
    rethink** (per §3: identify/disable any macOS PTP responder, or a
    second-interface/namespace approach, or rearchitect). Do NOT proceed to helper
    implementation.
  - Record the exact macOS version tested (Phase-0 machine: macOS 14.4.1 —
    SPEC 0a) alongside the verdict, since OS-reservation behavior may be
    version-specific.
- **kind:** research / probe · **depends_on:** none (deliberately — it must run
  first). · **blocks:** any helper implementation task.
- **model:** sonnet 5 — small, bounded, empirical; the judgment is in reading the
  errno, not in code volume. · **effort:** low (~30 lines + one osascript run,
  ahh present for the admin prompt).
- **verify:** `dev/notes/p2-ptp-bind-probe.md` states, per port, SUCCESS/errno
  under both unelevated and admin runs, names the macOS version, and gives the
  PASS/FAIL verdict + the design consequence.
