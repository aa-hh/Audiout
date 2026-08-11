// Scaffold smoke test. Proves the Swift test target can import AirPlayEngine
// and — as of T-BUILD-1 — that it links against the vendored+shimmed
// CAirPlayEngine C cluster.

import Testing
@testable import AirPlayEngine

@Suite struct AirPlayEngineScaffoldTests {
    @Test func scaffoldStatusIsPresent() {
        #expect(!AirPlayEngine.scaffoldStatus.isEmpty)
    }
}

// `cClusterLinks` reads `outputs_buffer_duration_ms_get()`, the same
// process-global `shims/outputs.c` state `StartBufferAndLatencyProbeTests`
// sets/restores — under swift-testing's in-process concurrency a concurrent
// setter test can be caught mid-mutation, so this one nests into the shared
// `SerializedEngineState` parent alongside that file rather than staying
// unguarded just because it never itself calls the setter.
extension SerializedEngineState {

@Suite struct AirPlayEngineScaffoldLinkTests {
    // T-BUILD-1: calls into the linked C cluster (shims/outputs.c) through the
    // CAirPlayEngine module. Verifies compile + link + module import all work
    // end to end. The value is the default start-buffer duration (2250 ms) —
    // see shims/outputs.c outputs_buffer_duration_ms_get(). This is NOT a
    // behavioral test of the engine; it's a link probe.
    @Test func cClusterLinks() {
        #expect(AirPlayEngine.scaffoldBufferDurationMs == 2250)
    }
}

} // extension SerializedEngineState
