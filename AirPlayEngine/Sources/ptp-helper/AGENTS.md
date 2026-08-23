# ptp-helper

## Purpose

`ptp-helper` is the **only process in the product that ever runs as root**. It
does exactly two privileged things: bind UDP 319/320 (`airptp_daemon_bind`)
and run the libairptp PTP master loop on those fds (`airptp_daemon_start`). No
RTSP, no ALAC/RTP, no pairing, no PCM, no audio — anything beyond
bind-and-run-the-clock belongs elsewhere. `main.c` is the entire runtime
surface of this target (single-file); the actual PTP protocol logic lives in
`libairptp` (see `Clibairptp` target), which this target links but does not
own.

Privilege boundary: this binary links **only** `Clibairptp` + libevent — never
the GPL sender cluster (ffmpeg/libplist/libgcrypt/RTSP/ALAC) — so the code
that runs as root stays small enough to read line-by-line. Do not add a
dependency here without re-justifying that boundary.

**Keep this file up to date** whenever: `main.c`'s startup sequence changes
(bind/start/shutdown order), the libevent linking strategy changes, the
`AUDIOUT_PTP_*` override contract changes, or the SMAppService
plist/Info.plist identity scheme (`scripts/ptp-helper.plist`,
`scripts/ptp-helper-info.plist`) changes.

## Notable Patterns

- **The helper is DEMAND-STARTED and SELF-EXITING, not long-lived.** macOS's
  own AirPlay wants 319/320 too, so holding them for the login session is the
  bug, not the feature. Older text (design doc §2.2/§2.4, "`RunAtLoad` +
  `KeepAlive=true`", "the helper keeps running") predates
  `PLAN-AIRPLAY-COEXISTENCE.md` T2 — the plan wins.
- **Exit status is a contract, not a detail.** The plist runs
  `KeepAlive={SuccessfulExit:false}`, so **non-zero means "respawn me now"**.
  Every expected outcome — idle exit, bind gave up, SIGTERM — must return
  **0**, or a busy-ports situation becomes a respawn storm that never lets go
  of the ports. Only a genuine internal failure returns non-zero.
- **`airptp_daemon_bind(NULL)` binds all interfaces on 319/320** — this is
  intentional (real PTP peers must be reachable), unlike the unrelated xctest
  PTP *test* daemon elsewhere in the repo, which must bind loopback-only. Do
  not conflate the two. It is retried (`ptp_helper_bind_with_retry()`) because
  macOS frees the ports a second or three *after* the app switches the default
  output away — a single attempt loses that race.
- **The Mach service carries exactly one boolean, never a transport.**
  `ptp_helper_mach_checkin()` opens an XPC listener so launchd has something to
  demand-start the process on; every peer message is ignored except a
  dictionary with `{"release": true}`, which is a shutdown trigger (seamless
  handoff needs the ports freed in ~1s, not the ~15s idle window) — no reply,
  no other key. shm + loopback-UDP remain the only data path across the
  privilege boundary (design doc §4). This is a hard ceiling, not a start:
  never grow it into a general IPC channel — that would put a message parser
  in the one root process.
- **XPC and libdispatch are libSystem, so they add no linked library** — the
  Library Validation constraint below is unaffected. `otool -L` on the built
  helper must keep showing `libSystem.B.dylib` and nothing else; treat any
  growth as a release-blocking regression.
- **`AUDIOUT_PTP_PORTS=EVENT,GENERAL` env override** lets the whole
  bind/start/find/peer path run unprivileged on high ports (CI/dev), applied
  via `airptp_ports_override()` before `airptp_daemon_bind()`. Parsed in
  `ptp_helper_apply_port_override_if_set()`. `AUDIOUT_PTP_SHM_NAME` is its
  companion (`ptp_helper_apply_shm_name_override_if_set()`): an unprivileged
  test copy cannot `shm_unlink()` the real root daemon's `/airptp_shm`, so it
  must publish under a different name or fail on any machine where the shipped
  daemon exists. The timing knobs (`AUDIOUT_PTP_BIND_RETRY_SECS`,
  `AUDIOUT_PTP_BIND_RETRY_INTERVAL_MS`, `AUDIOUT_PTP_IDLE_SECS`,
  `AUDIOUT_PTP_IDLE_GRACE_SECS`) exist so tests can run in seconds; `main.c`'s
  header comment is the authoritative list.
- **Static-links libevent**, not the Homebrew dylib (see
  `AirPlayEngine/Package.swift`'s `ptp-helper` target `linkerSettings`, and
  design doc §6.1.1). Required because this is a hardened-runtime Developer-ID
  daemon with Library Validation ON (no disable-library-validation
  entitlement): dyld refuses to load an ad-hoc-signed dylib into it. The
  sibling `Clibairptp` target deliberately has empty linker settings so
  `CAirPlayEngine` (the app) can link libevent as a dylib instead.
- **No `daemonize()`** — launchd (or the interim dev path's
  osascript-elevated foreground caller) owns backgrounding; the main thread
  just polls for idleness (`ptp_helper_wait_until_idle_or_signal()`) until the
  peer table stays empty or a signal arrives.
- **Idleness is not measured until a peer has appeared once, or a startup
  grace expires.** The helper is started BY a connect click, so beginning at
  zero peers is normal while RTSP SETUP negotiates — without the grace it
  would exit out from under the session that started it.
- **Clock-id seed is derived from `gethostuuid()`**, not hardcoded — stable
  per-host across restarts, with a hostname-fold fallback if `gethostuuid()`
  fails. See `ptp_helper_clock_id_seed_get()`.
- **Info.plist is embedded via a linker section** (`-sectcreate __TEXT
  __info_plist`, done in `scripts/make-app.sh`), not a bundle resource —
  `SMAppService` requires a standalone-executable LaunchDaemon to carry one.
  `CFBundleIdentifier` must match the daemon's launchd `Label`.
- **The launchd `Label`/plist filename are `BUNDLE_ID`-derived**, not
  hardcoded, so side-by-side dev builds under different `BUNDLE_ID`s get
  independent daemon identities (a same-label collision previously caused a
  silent `register()` no-op — see `scripts/ptp-helper.plist`'s comment).

## Feature Flow

1. `ptp_helper_apply_port_override_if_set()` /
   `ptp_helper_apply_shm_name_override_if_set()` — apply the unprivileged
   test-path overrides before anything binds or publishes.
2. `airptp_callbacks_register()` — wires `logmsg`/`hexdump`/`thread_name_set`
   to stderr (which launchd redirects per the bundled plist).
3. Install SIGTERM/SIGINT handlers — **before** the bind retry, so a signal
   arriving while the ports are contended is not ignored for the whole budget.
4. `ptp_helper_mach_checkin()` — hold the launchd Mach-service listener open
   (skipped entirely when `AUDIOUT_PTP_MACH_SERVICE` is unset).
5. `ptp_helper_clock_id_seed_get()` — derive a stable per-host clock-id seed.
6. `ptp_helper_bind_with_retry()` — the one privileged call, retried; binds
   319/320 (or override ports) on all interfaces. Never binding is an
   *expected* outcome: exit 0.
7. `airptp_daemon_start(hdl, seed, is_shared=true)` — publishes the shm clock
   record and starts the PTP master loop on its own thread. Needs no privilege
   itself; it consumes the fds `bind()` already stored in the handle.
8. `ptp_helper_wait_until_idle_or_signal()` — poll `airptp_peer_active_count()`
   until the peer table stays empty for the idle window, a signal arrives, or
   the release verb is received.
9. `airptp_end(hdl)` — clean shutdown, unlinks the shm segment.

## External Dependencies

| Dependency | Usage |
|---|---|
| `Clibairptp` (in-repo, `AirPlayEngine/Sources/CAirPlayEngine/libairptp`) | Provides `airptp.h` / the PTP bind-start-end API this daemon drives. Sole SwiftPM dependency of this target. |
| libevent (`libevent_core.a`, `libevent_pthreads.a`) | Statically linked (see Notable Patterns) — the event loop under `Clibairptp`'s PTP master loop. |
| `uuid/uuid.h`, `gethostuuid()` (system) | Per-host clock-id seed derivation. |

## Tests

No test files live in this folder (it is a single `main.c` executable
target). Related test coverage sits elsewhere:

| File | Focus |
|---|---|
| `AirPlayEngine/Sources/PTPHelperTestSupport` | Sibling target exposing `Clibairptp`'s `airptp_*` API to Swift for tests (needed because `airptp.h` is a `textual header` in the module map, invisible to a bare Swift `import`). |
| `AirPlayEngine/Tests/AirPlayEngineTests/PTPHelperIPCTests.swift` | Exercises the bind/start/find/peer IPC path, typically via the `AUDIOUT_PTP_PORTS` unprivileged override rather than a real root daemon. |
| `AirPlayEngine/Tests/AirPlayEngineTests/PTPHelperLifecycleTests.swift` | Launches the BUILT helper as a subprocess and asserts the on-demand lifecycle: idle-exits with status 0, stays up while a peer is active. Both PTP suites nest under its `SerializedPTPGlobals` parent — libairptp's port/shm-name globals are process-wide, so they must not run concurrently. |
| `AudioutCore/Sources/AudioutCore/PTPHelperService.swift` | App-side `PTPHelperManaging`/`SMAppServicePTPHelper` seam for registering and querying this daemon — unit-tested via an injected fake, never the real `SMAppService` call. |

## Cross-references

- `AirPlayEngine/docs/ptp-helper-design.md` — full design rationale (privilege
  boundary, SMAppService packaging, IPC, threading/lifecycle, build
  verification). Section numbers cited above refer to this doc.
- `AirPlayEngine/Package.swift` — `ptp-helper` and `Clibairptp` target
  definitions, linker settings.
- `scripts/ptp-helper.plist`, `scripts/ptp-helper-info.plist`,
  `scripts/make-app.sh` — packaging: launchd plist, embedded Info.plist,
  `BUNDLE_ID` substitution.
