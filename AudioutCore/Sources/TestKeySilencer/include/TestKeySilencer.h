// TestKeySilencer.h
//
// Linked into the test target only, never the app. When the test bundle
// loads, it replaces -[NSResponder noResponderFor:] with a silent version.
// AppKit calls that method when a key press reaches the end of the
// responder chain without anything handling it, and its stock version plays
// the system alert sound. Tests that send real key presses into windows hit
// that path, so every such test beeped on the Mac running it.
#import <objc/runtime.h>

/// The silent implementation installed on NSResponder, so a test can check
/// the replacement is in place.
IMP AUDSilentNoResponderImplementation(void);
