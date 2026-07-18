#import "include/ObjCExceptionShim.h"

NSString *const AUDObjCExceptionErrorDomain = @"com.audiouted.ObjCExceptionShim";
NSString *const AUDObjCExceptionNameKey = @"AUDObjCExceptionName";
NSString *const AUDObjCExceptionReasonKey = @"AUDObjCExceptionReason";
NSString *const AUDObjCExceptionCallStackSymbolsKey = @"AUDObjCExceptionCallStackSymbols";

NSError *_Nullable AUDCatchObjCException(void (NS_NOESCAPE ^_Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSMutableDictionary<NSString *, id> *userInfo = [NSMutableDictionary dictionary];
        userInfo[AUDObjCExceptionNameKey] = exception.name ?: @"";
        userInfo[AUDObjCExceptionReasonKey] = exception.reason ?: @"";
        userInfo[AUDObjCExceptionCallStackSymbolsKey] = exception.callStackSymbols ?: @[];
        userInfo[NSLocalizedDescriptionKey] =
            [NSString stringWithFormat:@"%@: %@", exception.name ?: @"NSException", exception.reason ?: @""];
        return [NSError errorWithDomain:AUDObjCExceptionErrorDomain code:1 userInfo:userInfo];
    }
}
