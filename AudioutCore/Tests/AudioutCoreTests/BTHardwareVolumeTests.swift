import XCTest
@testable import AudioutCore

/// Echo suppression is the only new logic here (the HAL ladder is
/// `SystemOutputVolume`'s), so it is what these tests cover. No live device.
final class BTHardwareVolumeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// Defect: an exact-match echo comparison misfires under HAL quantization —
    /// devices snap a written scalar to their own step grid, so the read-back
    /// never equals what we wrote and our own write is reported as a user
    /// gesture, which slams the slider back.
    func testQuantizedReadBackStillCountsAsEcho() {
        // Worst case on a 1/16 grid: the written scalar sits mid-step, so the
        // read-back lands 1/32 = 0.03125 away (write 0.53 → device stores 0.5).
        let write = BTHardwareVolume.PendingWrite(scalar: 0.53, at: now)
        XCTAssertTrue(BTHardwareVolume.isEcho(
            lastWrite: write, now: now.addingTimeInterval(0.05), readBack: 0.5))
        XCTAssertTrue(BTHardwareVolume.isEcho(
            lastWrite: write, now: now.addingTimeInterval(0.05), readBack: 0.5625))
    }

    /// Defect: too wide a tolerance swallows a real gesture. A move the user can
    /// hear must still be reported.
    func testGenuineChangeIsNotEcho() {
        let write = BTHardwareVolume.PendingWrite(scalar: 0.50, at: now)
        XCTAssertFalse(BTHardwareVolume.isEcho(
            lastWrite: write, now: now.addingTimeInterval(0.05), readBack: 0.60))
    }

    /// Defect: a write record that never expires makes the device permanently
    /// deaf to a later gesture that happens to land on the level we once wrote.
    func testEchoRecordExpires() {
        let write = BTHardwareVolume.PendingWrite(scalar: 0.50, at: now)
        XCTAssertFalse(BTHardwareVolume.isEcho(
            lastWrite: write, now: now.addingTimeInterval(BTHardwareVolume.echoWindow + 0.1), readBack: 0.50))
    }

    /// Defect: with no write on record every device-side change must be
    /// reported; treating "nothing written" as an echo loses the speaker's own
    /// volume buttons entirely.
    func testNoPendingWriteIsNeverEcho() {
        XCTAssertFalse(BTHardwareVolume.isEcho(lastWrite: nil, now: now, readBack: 0.50))
    }
}
