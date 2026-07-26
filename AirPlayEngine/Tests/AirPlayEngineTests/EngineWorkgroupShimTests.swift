// T5 (PLAN-AUDIO-THREAD-SCHEDULING.md) hermetic tests for the
// engine_workgroup shim. This is the ONLY thing testable without a real
// tap-bearing aggregate device and a live workgroup: the NULL-argument
// contract. Whether AudioObjectID 0 (kAudioObjectUnknown) or any other
// non-tap device actually publishes 'oswg' is a live/gated question (T7),
// not something this shim can fake — so this file sticks to what a headless
// process can prove: engine_workgroup_join never crashes and returns EINVAL
// when its output-token pointer is NULL.

import XCTest
@testable import AirPlayEngine
import CAirPlayEngine

final class EngineWorkgroupShimTests: XCTestCase {

    // NULL-safety, hard requirement (T5 verify): the token output pointer
    // being NULL must return EINVAL, not crash. Device id is irrelevant to
    // this check — the shim rejects a NULL out_token before it ever touches
    // Core Audio.
    func testJoinWithNullTokenPointerReturnsEINVALWithoutCrashing() {
        let rc = engine_workgroup_join(0, nil)
        XCTAssertEqual(rc, EINVAL, "engine_workgroup_join must return EINVAL for a NULL out_token, not crash")
    }

    // A device id with no 'oswg' property (kAudioObjectUnknown / 0 is not a
    // real device) must also fail cleanly with EINVAL and leave *out_token
    // untouched at NULL — not a random device left dangling.
    func testJoinWithUnknownDeviceIdFailsCleanlyAndLeavesTokenNil() {
        // engine_workgroup_token is an opaque C struct (never defined, only
        // forward-declared), so the Clang importer bridges a pointer to it
        // as OpaquePointer — same convention this package already uses for
        // cfg_t / event_base / transcode contexts.
        var token: OpaquePointer? = nil
        let rc = engine_workgroup_join(0 /* kAudioObjectUnknown */, &token)
        XCTAssertEqual(rc, EINVAL)
        XCTAssertNil(token)
    }

    // leave(NULL) must be a documented safe no-op (mirrors free()'s
    // NULL-safety) so cleanup/defer paths can call it unconditionally even
    // when join() never succeeded.
    func testLeaveWithNullTokenIsSafeNoOp() {
        engine_workgroup_leave(nil)
        engine_workgroup_leave(nil)
    }
}
