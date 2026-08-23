import Foundation
import Testing
@testable import AudioutCore

@Suite struct ObjCExceptionCatchingTests {

    @Test func nsExceptionSurfacesAsSwiftErrorCarryingTheExceptionName() {
        #expect {
            try catchingObjCException {
                NSException(name: NSExceptionName("AUDTestException"), reason: "boom", userInfo: nil).raise()
            }
        } throws: { error in
            guard let objcError = error as? ObjCExceptionError else { return false }
            return objcError.name == "AUDTestException" && objcError.reason == "boom"
        }
    }

    @Test func cleanBlockReturnsItsValueNormally() throws {
        let value = try catchingObjCException { 42 }
        #expect(value == 42)
    }

    @Test func swiftErrorThrownInsideBodyPropagatesUnchanged() {
        struct MyError: Error, Equatable { let code: Int }

        #expect(throws: MyError(code: 7)) {
            try catchingObjCException {
                throw MyError(code: 7)
            }
        }
    }
}
