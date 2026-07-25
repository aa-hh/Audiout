# PTPHelperTestSupport

## Purpose

A TEST-ONLY C shim that re-exposes `Clibairptp`'s `airptp_*` API as a
Swift-visible module (T7, `ptp-helper-design.md` §6.2). It owns exactly one
thing: making `airptp_*` callable from Swift test code. `Clibairptp/module.modulemap`
deliberately declares `airptp.h` as a `textual header` (so the vendored,
byte-identical header — which uses `bool` without `#include <stdbool.h>` —
passes Clang's modular self-containment check), and a textual header is never
part of a module's Swift-visible interface. This target's own header
(`include/ptp_test_support.h`) is a normal, self-contained modular header
that forwards 1:1 to the real `airptp_*` calls. No logic of its own, no
vendored source touched.

Keep this file up to date if the forwarded function set changes (i.e. if
`ptp_test_support.c`/`.h` gain or drop a `ptp_test_*` wrapper).

## Notable Patterns

- **Pass-through only**: every `ptp_test_*` function in `ptp_test_support.c`
  has an identical signature to its `airptp_*` twin in `libairptp/airptp.h`
  and does nothing but call it. Do not add logic here — if behavior needs to
  differ from `airptp_*`, that belongs elsewhere.
- **Test-only boundary**: this target exists solely so
  `Tests/AirPlayEngineTests/PTPHelperIPCTests.swift` can drive real
  `airptp_daemon_bind`/`_start`/`_find`/`_peer_add` etc. calls. It is not
  used by `ptp-helper` (the production daemon) or `AirPlayEngine` — those
  link `Clibairptp` directly.
- `struct airptp_handle` stays opaque here (forward-declared only, never
  defined) — this shim only forwards pointers to it.

## External Dependencies

| Dependency | Usage |
|---|---|
| `Clibairptp` | The only dependency (`Package.swift`); `ptp_test_support.c` includes its vendored `airptp.h` and forwards every call to the real `airptp_*` entry points. |

## Tests

| File | Focus |
|---|---|
| `../../Tests/AirPlayEngineTests/PTPHelperIPCTests.swift` | Drives the real PTP daemon bind/start/find/peer-add/peer-remove/clock-id/errmsg calls through this shim's `ptp_test_*` wrappers. |
