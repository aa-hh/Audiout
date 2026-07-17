# AirPlayEngine

## Status (2026-07-17): first light PASSED, Phase 2b hardening complete

The engine has been streamed audibly to a real Sonos speaker over AirPlay 2
with PTP timing (`docs/first-light-report.md`), and every follow-up item
from that gated session — teardown SIGABRT, SIGPIPE, the post-CONNECTED
device-state gap, write-cadence diagnostics, the libhash per-install-seed
collision, and the remaining hosting-hardening backlog — is fixed
(`PLAN-PHASE-2B.md` D3, tracked in `docs/first-light-report.md`'s "Known
follow-ups" section). All fixes stayed inside `shims/`/`Sources/AirPlayEngine/`;
no new vendored-C diffs were needed (`docs/VENDORED-DIFFS.md`). The engine now
exposes an async device-state stream (`makeStateStream()`) that
`AirPlayControllerCore`'s `NativeBackend` consumes — see
`../dev/notes/p2b-nativebackend-runbook.md` for how to run the native backend
end-to-end. The sections below (build status, shim inventory, package layout)
describe the extraction/bring-up work that got the engine to first light;
they're kept for historical/onboarding context and are still accurate for
the vendored-C layer, which hasn't changed since.

A standalone SwiftPM package that extracts OwnTone's AirPlay 2 sender
(`airplay.c` + `airplay_events.c` + `rtp_common.c` + `pair_ap` + `evrtsp` +
`libairptp`) into an engine this project owns, names neutrally, and wraps in
a Swift API — with **no OwnTone runtime dependency**. This is Phase 2 of the
AirPlay Controller project; see `../PLAN-PHASE-2.md` for the full plan and
`docs/seam-map.md` for the extraction blueprint this package follows.

## What this is

- The C sources under `Sources/CAirPlayEngine/{sender,evrtsp,pair_ap,libairptp}/`
  are **vendored** (copied, license headers preserved verbatim) from a
  pinned OwnTone Server clone (tag `29.2`, at `../dev/owntone-src/`, which is
  git-ignored and NOT a build dependency — it is read-only source-of-truth
  for the extraction, not something this package links against or requires
  at runtime).
- Every OwnTone-plumbing dependency the vendored sender cluster used to call
  (`conffile`, `logger`, `mdns`, `misc`, `player`, `db`, `artwork`,
  `dmap_common`, `transcode`, `ptpd`, `outputs.c`) is replaced by a thin
  **shim** we own, under `Sources/CAirPlayEngine/shims/`. Once T-BUILD-1 and
  T-SHIM-1 land, this package will build and run **without OwnTone present
  at all** — the `dev/owntone-src/` clone becomes purely historical
  provenance, not a dependency.
- The Swift target `AirPlayEngine` (in `Sources/AirPlayEngine/`) is the
  neutral public API surface the app will use. No OwnTone naming appears in
  any public symbol, per `SPEC.md` §4.

## Build status: Swift session API landed (T-API-1) — build + headless tests green

As of **T-API-1**, the neutral Swift wrapper (`Sources/AirPlayEngine/`) is
implemented over the vendored+shimmed C cluster: an owned engine thread + libevent
base, the C async-completion dispatcher bridged to `async/await`, discovery-in,
the session lifecycle (`addOutput`/`removeOutput`/`setVolume`/`write`/`stop`), and
a `localOutput` placeholder. A real network/PTP session is a **separate gated
step** — see "Running a live session (gated)" below.

**Phase 2b (2026-07-17) added:** an async device-state stream
(`makeStateStream`), write-cadence diagnostics (`writeCadenceSnapshot`), a
per-install libhash seed (`EngineConfig.installSeed`), and the
`flushOutput(_:)` no-op seam — see "Swift API surface" below and
`docs/first-light-report.md`'s "Known follow-ups" for what each one fixes.
`swift build` is green and **61 tests pass** (`swift test`, 2026-07-17).

### Swift API surface

```swift
public actor AirPlayEngine {
    init(config: EngineConfig = EngineConfig())
    func start() async throws
    func stop() async
    // discovery IN (app-owned NWBrowser feeds resolved descriptors):
    func updateDiscovery(_ descriptor: DeviceDescriptor) async throws -> OutputID
    func removeDiscovery(_ descriptor: DeviceDescriptor) async
    // session lifecycle:
    func addOutput(_ id: OutputID) async throws       // idempotent (T-ENG-HARDEN-1)
    func removeOutput(_ id: OutputID) async throws    // idempotent (T-ENG-HARDEN-1)
    func setVolume(_ id: OutputID, _ volume: Double) async throws
    func flushOutput(_ id: OutputID) async throws     // NO-OP SEAM (T-ENG-HARDEN-1) — future pause/seek
    nonisolated func write(pcm: Data, pts: timespec)   // hot path, fire-and-forget
    // Phase 2b (T-ENG-STATESTREAM-1): every device-state transition, incl.
    // out-of-band ones after an op's callback_id is already spent. Each call
    // returns an independent AsyncStream (mirrors OutputBackend.makeEventStream()).
    nonisolated func makeStateStream() -> AsyncStream<(OutputID, OutputState)>
    // Phase 2b (T-ENG-CADENCE-1): diagnostic write-cadence deficit/overrun,
    // never gates a write.
    nonisolated func writeCadenceSnapshot() -> WriteCadenceSnapshot
    // SPEC §8.1 synced local Core Audio sink — placeholder surface only:
    var localOutput: LocalOutputSink { get }
    func setLocalOutputEnabled(_ enabled: Bool)
}
```

`addOutput`/`removeOutput`/`setVolume`/`write`/`stop` are the primitives a future
`NativeBackend` (T-BACKEND-1) implements the app's `OutputBackend` protocol on top
of — the API is shaped to fit that without redesign.

**How the C completion callback bridges to async/await.** Each session op arms a
waiter: on the engine thread it calls `outputs_callback_add(device, statusCb)` to
get a `callback_id`, registers a Swift continuation under that id
(`CompletionRegistry`), then issues the backend op (`output_airplay.device_start`
etc.) which returns N (1 in this cluster). When the RTSP/PTP state machine later
reports via `outputs_cb`, the vendored dispatcher (shims/outputs.c) delivers it —
deferred, on `evbase_player` — to a `@convention(c)` completion hook we installed
via `outputs_engine_completion_set`; the hook resumes the matching continuation
with the terminal `OutputState`. If N ≤ 0 the op resolves immediately (never
hangs).

**Threading model (seam-map §8, risk R-B).** One dedicated OS thread owns one
libevent `event_base`; `evbase_player` is set to it before `airplay_init`, and
`event_base_dispatch` runs on it. Every C entry point is marshaled onto that
thread via `event_base_once` (`EngineThread.run`/`enqueue`). The `write` path is
`nonisolated` and copies PCM before handing it to the engine thread, so the audio
producer never blocks on the actor.

### Discovery-in bridge (no GPL source edits)

`airplay_device_cb` (the sender's discovery callback) is `static` in the vendored
`airplay.c`, so Swift can't name it directly. But `airplay_init` passes it to
`mdns_browse("_airplay._tcp", airplay_device_cb, …)` — so the `mdns_browse` shim
**captures** that function pointer, and `shims/engine_bridge.c` exposes
`airplayengine_feed_device(...)` to invoke it with an app-resolved descriptor.
This drives discovery-in per seam-map §4 without touching the GPL source.

### Running a live session (gated) — `engine-probe`

The `engine-probe` executable target is the artifact for a **later, human-gated**
one-device session. It builds green but **refuses to open any socket** unless the
explicit flag is passed:

```
swift run engine-probe \
  --address 192.168.1.50 --port 7000 \
  --device-id AA:BB:CC:DD:EE:FF \
  --features "0x445F8A00,0x1C340" --model AudioAccessory5,1 \
  --pcm /path/to/audio-s16le-44100-2ch.raw \
  --i-have-a-receiver-and-owntone-is-stopped
```

Without `--i-have-a-receiver-and-owntone-is-stopped` it just prints its plan and
exits 0 (what build/CI exercise). A **live** run requires ALL of:

1. A real AirPlay 2 receiver on the LAN (see `docs/receiver-harness-guide.md`).
2. **OwnTone / any other AirPlay sender or PTP daemon STOPPED** — the AirPlay 2
   PTP clock binds UDP **319/320**, which a running dev/OwnTone instance contends
   for.
3. A human present to confirm audio and stop the run.

**T-API-1 did NOT run this.** It is the deliverable for the gated live-test step.

## (historical) Build status: COMPILES + LINKS; R-A dispatcher REAL (T-BUILD-1 + T-SHIM-1 item 1 done)

As of T-BUILD-1, the vendored C cluster **compiles and links** on macOS 14.4
arm64 (Swift 5.10, brew at `/opt/homebrew` — and portably on Intel `/usr/local`).
As of **T-SHIM-1 (item 1)**, the load-bearing **R-A `outputs_cb` async-callback
dispatcher is REAL** (see `docs/outputs-dispatcher-contract.md` and the outputs
row in `docs/build-notes.md` §4), with a dedicated correctness net:

```
$ swift build              # Build complete — 0 warnings, all C files compile
$ swift build --build-tests # links the test executable, no undefined symbols
$ swift test               # 11 tests pass: 2 scaffold + 9 OutputsDispatcherTests (R-A)
```

- `Package.swift` builds the C target and the Swift target; the brew prefix is
  resolved portably (`$HOMEBREW_PREFIX` → `brew --prefix` → arch fallback).
- All vendored source files compile; the shim `.c` bodies satisfy every cut
  OwnTone symbol so the archive links against brew libevent/libsodium/libgcrypt
  (+libgpg-error)/libplist with **no unresolved symbols**.
- **Zero compiler warnings** — no implicit-function-declaration or
  incompatible-pointer warnings, confirming the shim signatures match every
  airplay.c call site.
- `import CAirPlayEngine` works from Swift (a link probe in `AirPlayEngine.swift`
  calls a C entry point through the module map).

**Full detail — every macOS-porting fix, the libairptp decision, and the exact
list of shim functions still needing real bodies — is in
[`docs/build-notes.md`](docs/build-notes.md).**

### What T-BUILD-1 fixed (summary)

1. **`config.h`** — hand-wrote `compat/config.h` (PACKAGE_NAME, HAVE_* macros
   the cluster reads) and force-include it into every TU via `-include config.h`
   (the autotools equivalent), fixing `PACKAGE_NAME`/plist/endian macro gaps
   without editing the GPL/MIT sources.
2. **endian helpers** — `compat/endian_compat.h` maps glibc `htobe*/be*toh` onto
   macOS `<libkern/OSByteOrder.h>`; the libairptp copy is activated via
   `HAVE_LIBKERN_OSBYTEORDER_H`.
3. **`L_PLAYER`** and the full logger domain/severity table restored verbatim in
   `shims/logger.h`.
4. **brew linkage** — resolved the placeholder `unsafeFlags` into real, portable
   `-I`/`-L`/`-l` flags; pair_ap built with `CONFIG_GCRYPT` (gcrypt+sodium, zero
   openssl — symbol-verified). ffmpeg is `-I`'d but **not linked** yet (the
   transcode shim references no ffmpeg symbols; T-SHIM-1 links it).
5. **libairptp** folded in as **vendored source** (not a prebuilt `.a`) — the
   `src/*.c` compile cleanly and the daemon `main()` isn't vendored, so no build
   system or symbol collision. (seam-map §7.4 decision.)
6. **shim headers rewritten** to mirror the real OwnTone signatures/types (the
   T-PKG-1 scaffold's speculative shapes diverged — see build-notes §1), plus
   host globals (`evbase_player`, `libhash`) and a `<limits.h>` include gap.

## Package layout

```
AirPlayEngine/
├── Package.swift            — one C target (CAirPlayEngine) + one Swift
│                               target (AirPlayEngine) + a test target.
├── LICENSE, COPYING, NOTICE — see "Licensing" below.
├── docs/                    — seam-map.md (authoritative extraction
│                               blueprint), license-inventory.md,
│                               ptp-study.md, receiver-harness-guide.md.
├── Sources/
│   ├── CAirPlayEngine/
│   │   ├── include/         — umbrella header + module.modulemap.
│   │   ├── sender/          — GPL-2.0-or-later: airplay.c,
│   │   │                      airplay_events.c(+.h), rtp_common.c(+.h),
│   │   │                      plist_wrap.h.
│   │   ├── evrtsp/          — BSD-3-Clause: rtsp.c, evrtsp.h,
│   │   │                      rtsp-internal.h, log.h.
│   │   ├── pair_ap/         — MIT: pair.c(+.h), pair-internal.h,
│   │   │                      pair-tlv.c(+.h), pair_fruit.c, pair_homekit.c.
│   │   ├── libairptp/       — MIT: airptp.h, LICENSE, src/*.{c,h}.
│   │   └── shims/           — GPL-2.0-or-later, new code: 10 shim units
│   │                          replacing OwnTone plumbing (stubs only for
│   │                          now — see "Shim inventory" below).
│   └── AirPlayEngine/       — the neutral Swift wrapper (placeholder until
│                               T-API-1).
└── Tests/AirPlayEngineTests/ — scaffold smoke test.
```

**Why one C target with license-labeled subdirectories, not one SwiftPM
target per license?** GPL/MIT/BSD compliance rides on per-file license
headers, the NOTICE file, and legible directory organization — not on
SwiftPM target boundaries. The vendored sources `#include` each other
directly across what would be those boundaries (e.g. `airplay.c` includes
`"evrtsp/evrtsp.h"` and `"pair_ap/pair.h"`), so a multi-target split would
fight the existing include structure rather than help licensing legibility.

## Shim inventory (headers + `.c` bodies now present)

Per `docs/seam-map.md` §9, these shim units replace OwnTone's plumbing. As of
T-BUILD-1 each has a **`.c` body** so the cluster links. Bodies are mostly
minimal stubs (T-SHIM-1 fills in real logic); a few are already real. The
`state` column is the T-SHIM-1 starting point — see
[`docs/build-notes.md` §4](docs/build-notes.md) for the per-function detail.

| shim | files | seam-map | state (T-BUILD-1) |
|------|-------|----------|-------------------|
| logger | `shims/logger.{h,c}` | §3.2 | PARTIAL (→ stderr) |
| misc | `shims/misc.{h,c}` | §3.3 | net/keyval/hex/uuid **STUB**; quality_is_equal + log_fatal_null REAL |
| conffile | `shims/conffile.{h,c}` | §3.1 | PARTIAL (returns defaults) |
| commands | `shims/commands.{h,c}` | §3.7 | REAL (trivial alloc/free) |
| player | `shims/player.{h,c}` | §3.6 | **STUB** |
| db | `shims/db.{h,c}` | §3.4 | REAL no-op (metadata cut) |
| artwork | `shims/artwork.{h,c}` | §3.4 | REAL no-op |
| dmap_common | `shims/dmap_common.{h,c}` | §3.4 | REAL no-op |
| mdns | `shims/mdns.{h,c}` | §3.5, §4 | REAL no-op (app-owned discovery) |
| transcode | `shims/transcode.{h,c}` | §3.8, §5 | **STUB** (no encoder yet — Q2a is T-SHIM-1) |
| ptpd | `shims/ptpd.{h,c}` | §3.9, §6 | **REAL** (adapted from OwnTone's ptpd.c) |
| outputs | `shims/outputs.{h,c}` | §2, §9 row 10 | registry PARTIAL; **`outputs_cb` dispatcher REAL (R-A done)** |

New porting-layer files also added: `compat/config.h` (hand-written autotools
replacement) and `compat/endian_compat.h` (macOS byte-order shim).

**R-A dispatcher — DONE.** `shims/outputs.c`'s `outputs_cb` async-callback
dispatcher (seam-map risk R-A) is now **REAL**: it ports OwnTone's 64-slot
callback-id registry + deferred delivery and adds an engine completion hook
(`outputs_engine_completion_set`) that unblocks T-API-1's async waiter. It
honours the exact contract in `docs/outputs-dispatcher-contract.md` — **N ∈ {0,1}
callbacks per op, delivered exactly once per `callback_id`**, keyed by
`callback_id` and resolved by `device_id`, deferred onto `evbase_player`, with
the error / password / auth-retry-id-hand-off / teardown / illegal-id paths all
covered. Verified by `Tests/AirPlayEngineTests/OutputsDispatcherTests.swift` (9
cases). T-API-1 wires the Swift async waiter to the completion hook and calls
`outputs_dispatcher_init()` after setting `evbase_player`.

## Vendored source stats

26 files vendored, **16,537 total lines** (`wc -l` across all vendored
`.c`/`.h` files under `sender/`, `evrtsp/`, `pair_ap/`, and `libairptp/`),
matching `docs/seam-map.md`'s §0 estimate of ~16,448 LOC (the small delta is
expected — the seam-map's estimate predates the exact vendoring pass).

## Brew dependencies the build will need

Per `docs/seam-map.md` §7 and Appendix A (confirmed installed via
`brew list` / `pkg-config --exists` at scaffold time):

- **libevent** — the sender cluster's event loop + evrtsp's RTSP transport.
- **libsodium** — pair_ap's crypto (always required).
- **libgcrypt** (+ its own `libgpg-error` dependency) — pair_ap is built
  with `CONFIG_GCRYPT` (not `CONFIG_OPENSSL`), matching what airplay.c and
  rtp_common.c already use directly.
- **libplist** — `plist_wrap.h` / AirPlay's plist-based RTSP payloads.
- **ffmpeg** (libavcodec) — the ALAC encoder shim (`shims/transcode.h`),
  per RESOLVED DECISIONS Q2: link ffmpeg first for first light, evaluate
  vendoring Apple's own ALAC encoder (or the dependency-free
  "uncompressed ALAC" trick lifted from OwnTone's `raop.c`) as a later
  dependency-shedding follow-up.

All five are Homebrew-installed on this machine; `Package.swift`'s
`unsafeFlags` currently hardcode the Apple Silicon `/opt/homebrew` prefix
(see the `TODO(T-BUILD-1)` comment there re: Intel portability).

## Licensing

This project is **GPL-2.0-or-later**, open source (RESOLVED DECISIONS,
`../PLAN-PHASE-2.md`, Q4 — supersedes an earlier "personal use only" intent).
See `LICENSE` (pointer + summary), `COPYING` (full GPL-2.0 text), and
`NOTICE` (full per-component attribution: GPL sender core, BSD evrtsp, MIT
pair_ap, MIT libairptp) in this directory. `docs/license-inventory.md` is
the detailed inventory these files are derived from.

Every vendored source file retains its original license header verbatim.
Files that shipped without an explicit header in upstream OwnTone
(`rtp_common.h`, `pair_ap/pair.h` + `pair-internal.h` + `pair-tlv.h`,
several `libairptp` internal headers, `evrtsp/rtsp-internal.h`) have had an
`SPDX-License-Identifier` line added, per `docs/license-inventory.md`'s
recommendation — the original copyright text (where present) was preserved
below the added SPDX line, not replaced.

The tiny privileged PTP helper (a future SMAppService launchd daemon, design
in `docs/`) will link only the MIT `libairptp` cluster — not the GPL sender
— and can therefore ship as a separate, standalone MIT-licensed binary
(GPL-2.0 §3 severability), per `NOTICE`.

## Where the next tasks pick up

This section is now historical (kept for onboarding — it traces how the
engine got built from scratch). All items below are DONE.

- **T-BUILD-1** (compile + link the extracted C cluster): **DONE.** The cluster
  compiles and links; `swift build`/`--build-tests`/`swift test` all pass.
  See [`docs/build-notes.md`](docs/build-notes.md) for every macOS-porting fix
  and the libairptp source-vs-`.a` decision (folded in as source).
- **T-SHIM-1** (implement the real shim bodies): starts from the shim `.c`
  files now in `Sources/CAirPlayEngine/shims/`, most of which are minimal stubs
  with `TODO(T-SHIM-1)` markers. The exact per-function starting state (REAL vs
  STUB) is tabulated in [`docs/build-notes.md` §4](docs/build-notes.md).
  Priority order:
  1. ~~**`shims/outputs.c` `outputs_cb` async-callback dispatcher** — the
     load-bearing R-A piece.~~ **DONE** — implemented to
     `docs/outputs-dispatcher-contract.md` and covered by `OutputsDispatcherTests`
     (9 cases). Remaining outputs work is the registry ownership/merge + string
     freeing, not the dispatcher.
  2. `shims/misc.c` net helpers (BSD sockets, macOS scope-id for `net_if_get`),
     keyval TXT parser, `safe_hextou*`, `thread_setname`, `uuid_make`.
  3. `shims/transcode.c` ffmpeg-backed ALAC encoder (Q2a) — then add
     avcodec/avutil/swresample to `Package.swift`.
  4. `shims/conffile.c` real config struct wired to the Swift API; `shims/
     player.c` device add/remove → registry + Swift events; `shims/logger.c`
     os_log routing.
- **T-API-1** (Swift session API): the C cluster is linkable and `import
  CAirPlayEngine` works. T-API-1 sets `evbase_player` (defined in
  `shims/outputs.c`) to the engine thread's event_base and builds the async
  bridge over the libevent loop (seam-map §8).
- **Gated first light** (`docs/first-light-report.md`): **DONE, PASSED,
  2026-07-16/17.** Audible, human-confirmed session against a real Sonos
  Move over AirPlay 2 with PTP timing. Six hosting-layer bugs found and
  fixed; zero vendored-protocol-code bugs.
- **Phase 2b hardening** (`PLAN-PHASE-2B.md` D3, `docs/first-light-report.md`
  "Known follow-ups"): **DONE.** Teardown SIGABRT, SIGPIPE, post-CONNECTED
  device-state stream, write-cadence diagnostics, libhash per-install seed,
  and the remaining hosting-hardening backlog are all fixed.
- **Phase 2b native backend** (`AirPlayControllerCore`'s `NativeBackend`,
  `NativeDiscovery`, `NativeCaptureCoordinator`, `AIRPLAY_BACKEND=native`):
  **DONE.** This engine package doesn't own that code — see
  `../dev/notes/p2b-nativebackend-runbook.md` and
  `../AirPlayControllerCore/AGENTS.md` for how to run it.
- **What's actually next**: the D7 gated live-verification session (multi-room
  2-output sync, native end-to-end on a real speaker, volume A/B, real-fleet
  discovery watch, teardown stress — checklist in
  `dev/notes/p2b-nativebackend-runbook.md`), then the deferred items listed in
  `docs/first-light-report.md`'s "What's next" (AP1/`raop.c` sender,
  multistream, synced local output, helper productionization).
