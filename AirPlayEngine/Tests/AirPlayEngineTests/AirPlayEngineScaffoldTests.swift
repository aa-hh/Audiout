// Scaffold smoke test. Proves the Swift test target can import AirPlayEngine
// and — as of T-BUILD-1 — that it links against the vendored+shimmed
// CAirPlayEngine C cluster. Replaced/extended by real session tests in T-API-1
// once the shims are implemented (T-SHIM-1).

import XCTest
@testable import AirPlayEngine

final class AirPlayEngineScaffoldTests: XCTestCase {
    func testScaffoldStatusIsPresent() {
        XCTAssertFalse(AirPlayEngine.scaffoldStatus.isEmpty)
    }

    // T-BUILD-1: calls into the linked C cluster (shims/outputs.c) through the
    // CAirPlayEngine module. Verifies compile + link + module import all work
    // end to end. The value is the default start-buffer duration (2250 ms) —
    // see shims/outputs.c outputs_buffer_duration_ms_get(). This is NOT a
    // behavioral test of the engine (shim bodies are stubs); it's a link probe.
    func testCClusterLinks() {
        XCTAssertEqual(AirPlayEngine.scaffoldBufferDurationMs, 2250)
    }
}
