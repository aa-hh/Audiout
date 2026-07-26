// AirPlayEngine's counterpart to
// `AudiouterCoreTests/SerializedSharedStateSuite.swift` (see the migration
// cookbook's Part II §18). AirPlayEngine is the LOWER package —
// AudiouterCore depends on it, not the reverse — so this package cannot
// import AudiouterCore's `SerializedSharedState` type; it needs its own
// declaration following the same pattern.
//
// Why this exists: `shims/outputs.c` keeps the device/callback registry as
// plain C process-globals (`outputs_list`, the completion-registry table,
// etc. — see `docs/outputs-dispatcher-contract.md`). Under XCTest's
// one-process-per-test-METHOD model that was safe by construction: no two
// test methods could ever touch those globals at the same moment, because
// they were never running at the same moment. swift-testing runs tests
// **concurrently inside one process** by default, so any suite that installs
// C callbacks into that registry, or reads/writes it directly, can now
// collide with another such suite's test running at the same time — a
// `output_status_cb` from one test's device firing into a completion table
// another test just reset would misattribute or lose callbacks.
//
// The fix is the same one T2 proved out on the AudiouterCore side: don't put
// `.serialized` on each affected suite independently — that only orders
// tests *within* a suite, so two independently-serialized suites can still
// run against each other, which is exactly the collision that matters here
// since the state is global to the process. Instead, every suite that
// touches the shared C registry nests as a child of ONE `.serialized`
// parent declared here, via `extension SerializedEngineState { @Suite ... }`
// in the consumer's own file (the file does not move). A `.serialized`
// parent gives true mutual exclusion across all of its (possibly
// multi-file) children — T2 measured a maximum concurrent overlap of 1
// doing this on the AudiouterCore side, and the probe suites below confirm
// the same holds in this package's toolchain.
//
// Confirmed by `grep -rl "outputs_dispatcher_reset\|outputs_list\|
// outputs_engine_completion_set" AirPlayEngine/Tests/` (T3, 2026-07-26) — the
// files expected to nest into this suite once Wave 3 (T14/T15/T16) converts
// them:
//
//   - AirPlayEngineAPITests.swift
//   - OutputsDispatcherTests.swift
//   - E1StabilityTests.swift
//   - StateStreamTests.swift
//   - MultiStreamWriteRoutingTests.swift
//
// `PTPHelperIPCTests.swift` was in the migration plan's original estimate of
// six files but does NOT belong here: it touches a *different* set of
// process-globals (`libairptp`'s `airptp_event_port` / `airptp_general_port`
// / `airptp_shm_name`, overridden via `ptp_test_ports_override()` /
// `ptp_test_shm_name_override()` — see that file's `tearDown()`), not the
// `shims/outputs.c` device registry this suite exists for. It is the only
// test in its file today, so it has no sibling to collide with yet, but if a
// second PTP-IPC test is ever added, it will need its OWN serialized parent
// for the `libairptp` globals rather than piggybacking on this one — the two
// registries are unrelated and serializing them together would just be
// unnecessary lock contention.
//
// Do NOT repeat `.serialized` on a child suite — it inherits from this
// parent. Do NOT add a suite here that only needs its own isolated
// scratch-dir/state; that's a lighter-weight problem than this file solves
// and such suites should stay parallel.
import Testing

@Suite(.serialized)
struct SerializedEngineState {}
