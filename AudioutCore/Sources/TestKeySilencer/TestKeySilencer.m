#import "TestKeySilencer.h"
#import <AppKit/AppKit.h>

static void AUDSilentNoResponder(id self, SEL _cmd, SEL eventSelector) {}

IMP AUDSilentNoResponderImplementation(void) {
    return (IMP)AUDSilentNoResponder;
}

// Runs when the test bundle is loaded, before any test, so a test written
// later is covered without doing anything.
__attribute__((constructor))
static void AUDInstallSilentNoResponder(void) {
    for (Class cls in @[NSResponder.class, NSWindow.class, NSApplication.class]) {
        Method method = class_getInstanceMethod(cls, @selector(noResponderFor:));
        if (method) method_setImplementation(method, (IMP)AUDSilentNoResponder);
    }
}
