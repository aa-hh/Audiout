# CAirPlayEngine

## Purpose

This is the C-level SwiftPM target that hosts a vendored+shimmed AirPlay 2/1
sender extracted from OwnTone: the real GPL protocol code (`sender/`,
`evrtsp/`) plus MIT-licensed pairing (`pair_ap/`) and PTP clock (`libairptp/`)
clusters, made buildable by a layer of hand-written "shim" headers/sources
(`shims/`) that stand in for the OwnTone application plumbing (config, db,
player, mDNS, output registry) this engine doesn't have. It is consumed only
through `import CAirPlayEngine` from the Swift target `Sources/AirPlayEngine`,
which owns threading, session lifecycle, and translating C callbacks into
Swift-visible state. This folder's responsibility ends at the C ABI exposed by
`include/CAirPlayEngine.h` — it does not know about `AVAudioEngine`, app UI,
or macOS permissions.

**Keep this file up to date** when: a shim's STUB STATUS changes (no-op ->
real implementation, e.g. the outputs dispatcher), a new vendored cluster is
added/removed, `engine_bridge.h`'s public C surface changes, or a doc under
`AirPlayEngine/docs/` that this file references is renamed/replaced.

## Notable Patterns

- **Static-symbol capture, not GPL edits.** Where the vendored `sender/*.c`
  calls a `static` function OwnTone would normally reach only via mDNS
  callbacks (`airplay_device_cb`, `raop_device_cb`), the shim captures the
  function pointer at `mdns_browse()` time (`shims/mdns.c`) and re-exposes it
  via `engine_bridge.h`'s `airplayengine_feed_device()` /
  `airplayengine_feed_raop_device()`. This is the intended way to drive
  discovery IN without patching the GPL source.
- **One thread owns everything.** Almost all C entry points (`engine_bridge.h`,
  the discovery feeds, `output_airplay`/`output_raop` function pointers) MUST
  be called on the engine thread; the Swift wrapper marshals calls there. The
  `airplay_events` thread (`sender/airplay_events.c`) is the one exception —
  it fires `airplayengine_remote_fire()` from its own `event_base`.
- **N-callback contract.** Every `output_definition` entry point that returns
  a positive N promises exactly N `outputs_cb(callback_id, device_id, state)`
  calls (see `docs/outputs-dispatcher-contract.md` and `shims/outputs.c`); get
  this wrong and the engine hangs waiting on a callback that never arrives.
- **`evthread_use_pthreads()` must run before the event_base is created**
  (`include/CAirPlayEngine.h`) — without it, cross-thread `event_base_once()`
  silently defers until the keep-alive timer fires (found at first-light,
  2026-07-16).
- **`engine_crypto_init()` and `engine_mask_sigpipe()`** must be called once
  on the engine thread before `airplay_init`/`raop_init` open sockets or do
  crypto — OwnTone's `main()` did both process-wide; this hosting must too.
- **Two independent backends, not a shared struct.** `output_airplay`
  (`sender/airplay.c`) and `output_raop` (`sender/raop.c`) are separate
  non-static `struct output_definition` globals; their file-static helpers
  never collide because RAOP's are the file's only external symbol. Dispatch
  between them by `device->type` is owned by the Swift layer, not this folder.
- **Ownership at the discovery seam**: `struct keyval *txt` passed to the
  `airplayengine_feed_*` functions stays owned by the caller — the callback
  reads it synchronously and does not retain it.
- **Test/diagnostic-only C symbols** (`airplay_test_master_session_*`,
  `raop_test_master_session_*`, `raop_test_write_one`) are declared in
  `engine_bridge.h` but are explicitly NOT part of the shipping session API —
  do not call them from production Swift code.

## Folder Map

- `include/` — umbrella header (`CAirPlayEngine.h`) and module map; the only
  files Swift's `import CAirPlayEngine` sees directly.
- `shims/` — GPL-2.0 code this project owns: reimplementations of OwnTone's
  app plumbing (logger, config, db, player, mDNS, output registry, transcode,
  PTP wrapper) plus `engine_bridge.{c,h}`, the Swift-facing seam.
- `sender/` — the vendored AirPlay 2 (`airplay.c`) and AirPlay 1/RAOP
  (`raop.c`) protocol implementations, plus shared RTP (`rtp_common.c`) and
  the reverse event channel (`airplay_events.c`). GPL-2.0-or-later.
- `evrtsp/` — vendored RTSP client (`rtsp.c`). BSD-3-Clause.
- `pair_ap/` — vendored AirPlay 2 pairing/encryption (`pair.c`,
  `pair_fruit.c`, `pair_homekit.c`, `pair-tlv.c`). MIT.
- `libairptp/` — vendored PTP clock daemon/library (`airptp.c`, `daemon.c`,
  `ptp_msg_handle.c`). MIT. Built as its own SwiftPM target
  (`Sources/CAirPlayEngine/libairptp`), not part of `CAirPlayEngine` itself.
- `compat/` — small portability headers (`endian_compat.h`, `config.h`) for
  build-flag/byte-order gaps between Linux (OwnTone's native target) and macOS.

## Key Types

| Type / symbol | Role |
|---|---|
| `struct output_definition output_airplay` (`sender/airplay.c`) | AirPlay 2 backend's non-static vtable: `.init/.deinit/.device_start/.device_stop/.device_volume_set/.device_cb_set/.write`. Swift calls through these directly. |
| `struct output_definition output_raop` (`sender/raop.c`) | AirPlay 1/RAOP backend's equivalent vtable. |
| `struct output_device` / `struct output_buffer` (`shims/outputs.h`) | Per-device state and the PCM fan-out buffer; field layout mirrors OwnTone's `src/outputs.h` verbatim because `sender/*.c` reads many fields directly. |
| `outputs_cb` / `outputs_cb_register` (`shims/outputs.c`) | The R-A async-callback dispatcher: tracks in-flight callback ids and their expected N-count, delivers on `evbase_player`. |
| `struct airptp_handle` (`libairptp/airptp.h`) | Opaque PTP daemon/client handle; `shims/ptpd.c` wraps it for `sender/airplay.c`'s clock calls. |
| `struct keyval` (`shims/misc.h`) | Linked-list key/value pairs used for DNS-SD TXT records and config; caller-owned across the discovery seam. |
| `airplayengine_remote_event_cb` (`shims/engine_bridge.h`) | Callback type for receiver->sender remote control (transport keys, speaker-driven volume). |

## External Dependencies

| Dependency | Used for |
|---|---|
| libevent (`event2/*.h`) | RTSP client, output dispatcher, PTP daemon event loops; `evbase_player` is the shared player-thread base. |
| libgcrypt (`gcrypt.h`) | Crypto primitives for AirPlay 2 pairing (`pair_ap/`); requires process-wide `engine_crypto_init()`. |
| libsodium | Additional crypto for pairing; initialized alongside libgcrypt in `engine_crypto_init()`. |
| libplist (`plist/plist.h`) | Binary/XML plist parsing for AirPlay's RTSP payloads (`sender/plist_wrap.h`). |
| Vendored OwnTone source (`sender/`, `evrtsp/`) | Extracted AirPlay sender core; see `docs/VENDORED-DIFFS.md` and `docs/license-inventory.md` for what was changed vs. upstream. |

## In-Progress Work

| Marker | Description |
|---|---|
| T-SHIM-1 (`shims/outputs.h`, `shims/outputs.c`) | Registry ownership/merge semantics and string-freeing edge cases around the outputs dispatcher; the dispatcher itself is complete per `shims/outputs.c`'s header comment. |
| T-API-1 (`shims/mdns.h`) | Confirms discovery only ever flows in via `airplayengine_feed_device`/`airplayengine_feed_raop_device`; `mdns_browse` stays a permanent no-op. |
| Stale scaffold comments (`include/CAirPlayEngine.h`, `include/module.modulemap`) | Header comments still describe a T-PKG-1/T-BUILD-1 scaffold state ("not yet wired to build cleanly"); the target does build and has an extensive test suite (`AirPlayEngine/Tests/AirPlayEngineTests/`), so treat those specific claims as outdated pending a comment refresh. |

## Tests

Tests live in `AirPlayEngine/Tests/AirPlayEngineTests/` (Swift, exercising
this C target through the umbrella header and `engine_bridge.h`'s test-only
accessors), not inside this folder.

| File | Focus |
|---|---|
| `OutputsDispatcherTests.swift` | R-A async-callback dispatcher (N-callback contract). |
| `MultiStreamMasterSessionTests.swift` / `RaopMultiStreamMasterSessionTests.swift` | Per-`stream_id` master-session isolation via `airplay_test_master_session_*` / `raop_test_master_session_*`. |
| `MultiStreamWriteRoutingTests.swift` | `write()` fan-out routes PCM to the correct stream's buffer only. |
| `RaopBackendTests.swift` | `output_raop` backend behavior independent of `output_airplay`. |
| `PTPHelperIPCTests.swift` | PTP helper daemon IPC (see `Sources/PTPHelperTestSupport/ptp_test_support.c`). |
| `RemoteEventStreamTests.swift` | Receiver->sender remote control (`airplayengine_remote_event_cb`/`_fire`). |
| `ShimUnitTests.swift`, `EngineProbeParsingTests.swift`, `StateStreamTests.swift`, `WriteCadenceTests.swift`, `StartBufferAndLatencyProbeTests.swift`, `E1StabilityTests.swift`, `AirPlayEngineScaffoldTests.swift`, `AirPlayEngineAPITests.swift` | Shim correctness, state/event streams, buffering/latency, and general session-API coverage. |
