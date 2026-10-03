// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
import ObjectiveC
import TestKeySilencer

/// A key press nothing handles makes AppKit play the alert sound, and tests
/// that send real key presses into windows made the Mac running them beep.
/// `TestKeySilencer` replaces that method when the test bundle loads. If the
/// target is unlinked or its load-time hook stops running, this fails.
@MainActor
struct TestKeySilencerTests {
    @Test(arguments: [NSResponder.self, NSWindow.self, NSApplication.self] as [AnyClass])
    func unhandledKeysAreSilent(_ cls: AnyClass) {
        let method = class_getInstanceMethod(cls, #selector(NSResponder.noResponder(for:)))
        #expect(method.map(method_getImplementation) == AUDSilentNoResponderImplementation())
    }
}
