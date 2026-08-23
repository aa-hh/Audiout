// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// An `NSImageView` that POPS ITS HOST ROW'S MENU when clicked.
///
/// A row's icon is the most obvious thing on it and, as a plain `NSImageView`,
/// the most inert — a picture of a speaker that does nothing. This one is the
/// visible door to the same menu right-click already offers ("Equalizer…",
/// and on a Bluetooth row "Align speaker…") — a second way in for anyone who
/// never thinks to right-click a row.
///
/// **Armed only when there is something to show.** The host sets ``onPress``;
/// while it is non-`nil` the view is an accessibility BUTTON (label supplied by
/// the host — "Speaker options", "Main Audio options") and a mouse-down or a
/// VoiceOver press fires it. Setting it back to `nil` returns the view to a
/// plain image: no AX element, no press, no pointing hand. A row whose menu
/// would be empty (This Mac) therefore has a genuinely inert icon, rather than
/// one that lights up and then does nothing.
///
/// It draws NOTHING of its own — no hover chrome, no bezel, no tooltip. The
/// pointing-hand cursor over the icon is the host's job (`resetCursorRects`),
/// because only the host knows where the icon sits in its own coordinates.
public final class MenuTriggerImageView: NSImageView {

    /// What a click (or a VoiceOver press) on the icon does. `nil` = inert.
    public var onPress: (() -> Void)? {
        didSet {
            let armed = onPress != nil
            setAccessibilityElement(armed)
            setAccessibilityRole(armed ? .button : .image)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        guard let onPress else {
            super.mouseDown(with: event)
            return
        }
        onPress()
    }

    public override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}
