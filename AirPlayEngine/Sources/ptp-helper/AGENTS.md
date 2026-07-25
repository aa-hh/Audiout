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
`AUDIOUTER_PTP_PORTS` override contract changes, or the SMAppService
plist/Info.plist identity scheme (`scripts/ptp-helper.plist`,
`scripts/ptp-helper-info.plist`) changes.

## Notable Patterns

- **`airptp_daemon_bind(NULL)` binds all interfaces on 319/320** — this is
  intentional (real PTP peers must be reachable), unlike the unrelated xctest
  PTP *test* daemon elsewhere in the repo, which must bind loopback-only. Do
  not conflate the two.
- **`AUDIOUTER_PTP_PORTS=EVENT,GENERAL` env override** lets the whole
  bind/start/find/peer path run unprivileged on high ports (CI/dev), applied
  via `airptp_ports_override()` before `airptp_daemon_bind()`. Parsed in
  `ptp_helper_apply_port_override_if_set()`.
- **Static-links libevent**, not the Homebrew dylib (see
  `AirPlayEngine/Package.swift`'s `ptp-helper` target `linkerSettings`, and
  design doc §6.1.1). Required because this is a hardened-runtime Developer-ID
  daemon with Library Validation ON (no disable-library-validation
  entitlement): dyld refuses to load an ad-hoc-signed dylib into it. The
  sibling `Clibairptp` target deliberately has empty linker settings so
  `CAirPlayEngine` (the app) can link libevent as a dylib instead.
- **No `daemonize()`** — launchd (or the interim dev path's
  osascript-elevated foreground caller) owns backgrounding; the process just
  blocks in `pause()` until SIGTERM/SIGINT.
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

1. `ptp_helper_apply_port_override_if_set()` — if `AUDIOUTER_PTP_PORTS` is
   set, override ports before anything binds (unprivileged test path only).
2. `airptp_callbacks_register()` — wires `logmsg`/`hexdump`/`thread_name_set`
   to stderr (which launchd redirects per the bundled plist).
3. `ptp_helper_clock_id_seed_get()` — derive a stable per-host clock-id seed.
4. `airptp_daemon_bind(NULL)` — the one privileged call; binds 319/320 (or
   override ports) on all interfaces.
5. `airptp_daemon_start(hdl, seed, is_shared=true)` — publishes `/airptp_shm`
   and starts the PTP master loop on its own thread. Needs no privilege
   itself; it consumes the fds `bind()` already stored in the handle.
6. Install SIGTERM/SIGINT handlers, block in `pause()`.
7. On signal, `airptp_end(hdl)` — clean shutdown, unlinks `/airptp_shm`.

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
| `AirPlayEngine/Tests/AirPlayEngineTests/PTPHelperIPCTests.swift` | Exercises the bind/start/find/peer IPC path, typically via the `AUDIOUTER_PTP_PORTS` unprivileged override rather than a real root daemon. |
| `AudiouterCore/Sources/AudiouterCore/PTPHelperService.swift` | App-side `PTPHelperManaging`/`SMAppServicePTPHelper` seam for registering and querying this daemon — unit-tested via an injected fake, never the real `SMAppService` call. |

## Cross-references

- `AirPlayEngine/docs/ptp-helper-design.md` — full design rationale (privilege
  boundary, SMAppService packaging, IPC, threading/lifecycle, build
  verification). Section numbers cited above refer to this doc.
- `AirPlayEngine/Package.swift` — `ptp-helper` and `Clibairptp` target
  definitions, linker settings.
- `scripts/ptp-helper.plist`, `scripts/ptp-helper-info.plist`,
  `scripts/make-app.sh` — packaging: launchd plist, embedded Info.plist,
  `BUNDLE_ID` substitution.
