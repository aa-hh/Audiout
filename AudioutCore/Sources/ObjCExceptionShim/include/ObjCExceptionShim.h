// ObjCExceptionShim.h
//
// Swift cannot catch NSException (@try/@catch is Objective-C-only), but
// several AVFAudio APIs (AVAudioPlayerNode.play/scheduleBuffer/connect) and
// NSThread.start raise NSException instead of returning NSError — a
// confirmed crash class in this app (4 real crashes). This target is the
// one place @try/@catch is allowed to bridge that gap for Swift callers.
//
// Deliberately minimal: one block-based catcher, no AudioutCore-specific
// or AVFAudio-specific knowledge. Callers wrap exactly the ObjC call that
// can throw, not larger scopes — a wide block risks swallowing an exception
// raised by unrelated code and misreporting where it came from.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The error domain used for NSError values returned by
/// `AUDCatchObjCException`.
extern NSString *const AUDObjCExceptionErrorDomain;

/// User info keys carrying the caught NSException's fields, since NSError
/// cannot represent an NSException directly.
extern NSString *const AUDObjCExceptionNameKey;
extern NSString *const AUDObjCExceptionReasonKey;
extern NSString *const AUDObjCExceptionCallStackSymbolsKey;

/// Runs `block` inside an Objective-C @try/@catch. Returns nil if `block`
/// completes normally. If `block` raises an NSException, the exception is
/// caught (never propagates past this call) and converted into an NSError
/// carrying the exception's name and reason, plus its call stack symbols
/// under `AUDObjCExceptionCallStackSymbolsKey`.
///
/// `block` is NS_NOESCAPE: it runs synchronously on the calling thread and
/// is not retained past this call returning.
NSError *_Nullable AUDCatchObjCException(void (NS_NOESCAPE ^_Nonnull block)(void));

NS_ASSUME_NONNULL_END
