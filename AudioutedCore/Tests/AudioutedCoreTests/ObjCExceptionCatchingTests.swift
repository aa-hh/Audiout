import XCTest
@testable import AudioutedCore

final class ObjCExceptionCatchingTests: XCTestCase {

    func testNSExceptionSurfacesAsSwiftErrorCarryingTheExceptionName() {
        XCTAssertThrowsError(
            try catchingObjCException {
                NSException(name: NSExceptionName("AUDTestException"), reason: "boom", userInfo: nil).raise()
            }
        ) { error in
            guard let objcError = error as? ObjCExceptionError else {
                XCTFail("Expected ObjCExceptionError, got \(error)")
                return
            }
            XCTAssertEqual(objcError.name, "AUDTestException")
            XCTAssertEqual(objcError.reason, "boom")
        }
    }

    func testCleanBlockReturnsItsValueNormally() throws {
        let value = try catchingObjCException { 42 }
        XCTAssertEqual(value, 42)
    }

    func testSwiftErrorThrownInsideBodyPropagatesUnchanged() {
        struct MyError: Error, Equatable { let code: Int }

        XCTAssertThrowsError(
            try catchingObjCException {
                throw MyError(code: 7)
            }
        ) { error in
            XCTAssertEqual(error as? MyError, MyError(code: 7))
        }
    }
}
