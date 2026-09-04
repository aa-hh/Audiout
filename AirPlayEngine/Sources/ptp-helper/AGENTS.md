# ptp-helper

## Purpose

The only process in the product that ever runs as root. It does two privileged
things: bind UDP 319/320 and run the PTP master loop on those descriptors. No
RTSP, no audio, nothing else belongs here.

## Rules

- Privilege boundary: link only `Clibairptp` and libevent, never the GPL sender cluster.
- The helper is demand-started and self-exiting; macOS AirPlay wants the same ports back.
- Exit status is a contract: every expected outcome returns 0, or launchd respawns forever.
- `airptp_daemon_bind(NULL)` binds all interfaces on purpose; the loopback test daemon is a different thing.
- The Mach service carries one boolean, a release trigger; never grow it into an IPC channel.
- XPC, dispatch and os_log are libSystem: a second linked library is a release blocker.
- The port and shm-name overrides let the path run unprivileged; a test copy needs its own shm name.
- A dead-man's watchdog backstops idle exit, because the master loop has wedged while holding the ports.
- libevent is statically linked because Library Validation refuses an ad-hoc dylib in this daemon.
- No daemonize call: launchd owns backgrounding, and the main thread only polls for idleness.
- Idleness is not measured until a peer has appeared or the startup grace expires.
- The clock-id seed is derived from `gethostuuid()`, never hardcoded, so it is stable per host.
- Info.plist is embedded through a linker section, and `CFBundleIdentifier` must match the launchd label.
- The launchd label is derived from the bundle id, so side-by-side dev builds stay independent.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `main.c` → the whole runtime surface of this single-file target.
