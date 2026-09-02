# CAirPlayEngine

## Purpose

The C target hosting a vendored AirPlay 2 and RAOP sender from OwnTone, plus
MIT pairing and PTP clusters, made buildable by hand-written shims. Its
responsibility ends at the C ABI the umbrella header exposes.

## Rules

- Vendored C stays byte-identical: fixes belong in the shims, and every exception is ledgered.
- Drive discovery in through the bridge feeds; the shim captures the static callbacks, so the GPL source stays unpatched.
- One thread owns everything; the vendored events thread firing remote events is the only exception.
- A positive N promises exactly N dispatcher callbacks, or the engine hangs waiting forever.
- `evthread_use_pthreads()` must run before the event base exists, or cross-thread work silently defers.
- `engine_crypto_init()` and `engine_mask_sigpipe()` run once on the engine thread before any socket opens.
- Two backends, two separate definitions, not a shared struct; the Swift layer dispatches between them.
- TXT key-value records passed across the discovery seam stay owned by the caller.
- Test-only C symbols are not the shipping API; production Swift never calls them.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `include/` → umbrella header and module map, the only files Swift sees.
- `shims/` → this project's own reimplementations of OwnTone plumbing, plus the Swift-facing bridge.
- `sender/` → the vendored AirPlay 2 and RAOP protocol code, GPL-2.0-or-later.
- `evrtsp/` → vendored RTSP client, BSD-3-Clause.
- `pair_ap/` → vendored AirPlay 2 pairing and encryption, MIT.
- `libairptp/` → vendored PTP clock library, MIT, built as its own target.
- `compat/` → small portability headers covering Linux-to-macOS build gaps.
