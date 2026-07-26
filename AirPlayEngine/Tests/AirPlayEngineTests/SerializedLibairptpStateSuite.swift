// This package's SECOND `.serialized` parent, alongside `SerializedEngineState`
// (SerializedEngineStateSuite.swift) — deliberately separate from it, per that
// file's own note: "the two registries are unrelated and serializing them
// together would just be unnecessary lock contention."
//
// This one exists for `libairptp`'s process-globals — `airptp_event_port`,
// `airptp_general_port`, `airptp_shm_name` (libairptp/src/airptp.c), and
// `shims/ptpd.c`'s own module-static `ptpd_hdl`, which those globals feed via
// `airptp_daemon_find()`/`airptp_daemon_bind()`. None of this overlaps
// `shims/outputs.c`'s device/callback registry, which is what
// `SerializedEngineState` exists for.
//
// Nests, via `extension SerializedLibairptpState { @Suite ... }` in the
// consumer's own file (the file does not move):
//   - PTPHelperIPCTests.swift — drives real bind/start/find/peer-add/remove
//     against the high test ports + a test-only shm name.
//   - ShimUnitTests.swift's `PtpdShimTests` (T2b) — exercises `shims/ptpd.c`'s
//     deferred-lookup contract (`ptpd_init`/`ptpd_clock_id_get`/
//     `ptpd_slave_add`/`ptpd_slave_remove`/`ptpd_deinit`), including a
//     lazy-find against a test daemon started on the same overridden globals.
//   - PTPHelperLifecycleTests.swift (T2) — launches the real built helper as a
//     subprocess and drives `airptp_daemon_find()` + peer add/remove against
//     it, so it writes the same port/shm globals from the test side while the
//     subprocess owns the other end.
//
// Both touch the same process-wide state (directly or via `ptpd_hdl`), so
// letting them run concurrently would risk one test's `ptp_test_ports_override`/
// `ptp_test_shm_name_override` call landing mid-way through the other's
// bind/find sequence, or one test's `ptpd_deinit()` freeing a handle another
// test's lazy-find just cached in `ptpd_hdl`. `.serialized` on one shared
// parent gives true mutual exclusion across both files, the same fix T2
// proved out for `SerializedEngineState`.
import Testing

@Suite(.serialized)
struct SerializedLibairptpState {}
