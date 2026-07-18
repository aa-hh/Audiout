import Foundation
import ObjCExceptionShim

/// A Swift-typed view of an NSException caught by `AUDCatchObjCException`.
/// AVFAudio (AVAudioPlayerNode.play/scheduleBuffer/connect) and
/// NSThread.start raise NSException instead of returning NSError — Swift's
/// `catch` cannot see those at all, so this is the one supported bridge.
public struct ObjCExceptionError: Error, CustomStringConvertible {
    public let name: String
    public let reason: String
    public let callStackSymbols: [String]

    public var description: String {
        "ObjCExceptionError(\(name)): \(reason)"
    }
}

/// Runs `body` and rethrows any Swift error it throws unchanged. If the
/// Objective-C call(s) inside `body` raise an NSException instead (a case
/// Swift's own `try`/`catch` cannot observe), it is caught at the ObjC/Swift
/// boundary and surfaced as an `ObjCExceptionError`.
///
/// Wrap only the specific ObjC call that can throw, not a larger scope —
/// `AUDCatchObjCException` cannot distinguish "this line raised" from
/// "something else inside the block raised".
public func catchingObjCException<T>(_ body: () throws -> T) throws -> T {
    var result: Result<T, Error>?
    let objcError = AUDCatchObjCException {
        do {
            result = .success(try body())
        } catch {
            result = .failure(error)
        }
    }
    if let objcError = objcError as NSError? {
        let userInfo = objcError.userInfo
        throw ObjCExceptionError(
            name: userInfo[AUDObjCExceptionNameKey] as? String ?? "",
            reason: userInfo[AUDObjCExceptionReasonKey] as? String ?? "",
            callStackSymbols: userInfo[AUDObjCExceptionCallStackSymbolsKey] as? [String] ?? []
        )
    }
    switch result! {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    }
}
