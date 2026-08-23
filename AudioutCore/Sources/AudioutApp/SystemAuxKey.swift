// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// A macOS aux-control ("NX") key, and the one way to synthesize a press of it.
///
/// Values from `IOKit/hidsystem/ev_keymap.h` (`NX_KEYTYPE_*`). Posting one is
/// how a menu-bar app reaches whatever the system would have done for a real
/// function-row key press — the frontmost player pauses, the display dims, the
/// keyboard backlight steps — without knowing anything about who handles it.
///
/// **Volume is deliberately absent.** `NX_KEYTYPE_SOUND_UP`/`_DOWN`/`_MUTE`
/// target the Mac's default output, which is our aggregate, which cannot take a
/// volume write — posting them is exactly the no-op this whole workstream
/// exists to route around. Volume goes through `GroupController` instead.
///
/// PERMISSION: posting into the HID stream so it reaches other processes needs
/// Accessibility trust. Untrusted, `post()` silently does nothing.
enum SystemAuxKey: Int32 {
    case brightnessUp = 2       // NX_KEYTYPE_BRIGHTNESS_UP
    case brightnessDown = 3     // NX_KEYTYPE_BRIGHTNESS_DOWN
    case playPause = 16         // NX_KEYTYPE_PLAY
    case next = 17              // NX_KEYTYPE_NEXT
    case previous = 18          // NX_KEYTYPE_PREVIOUS
    case illuminationUp = 21    // NX_KEYTYPE_ILLUMINATION_UP
    case illuminationDown = 22  // NX_KEYTYPE_ILLUMINATION_DOWN

    /// Synthesize a full press (down then up) and post it to the HID event tap —
    /// the same path a hardware key travels.
    func post() {
        postTransition(keyDown: true)
        postTransition(keyDown: false)
    }

    private func postTransition(keyDown: Bool) {
        // A systemDefined event with subtype 8 (NX_SUBTYPE_AUX_CONTROL_BUTTONS)
        // is how the aux keys are represented: key code in the high 16 bits of
        // data1, key state (0xA down / 0xB up) in the next byte, and the same
        // state mirrored into the modifier flags.
        let state = keyDown ? 0xA : 0xB
        let data1 = Int((rawValue << 16) | Int32(state << 8))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(state << 8))

        guard let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: data1, data2: -1
        ) else { return }

        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
