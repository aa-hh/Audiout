// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// Builds the menu-bar status item's `NSImage` from the pure
/// `MenuBarStatus` decision. Extracted out of `AudioutApp.StatusItemController`
/// so the "always template" invariant is unit-testable — `AudioutApp` is the
/// bare executable target, which the test target cannot import.
///
/// **Menu-bar status items must ALWAYS be template images.** That is the
/// macOS platform convention: the system then guarantees legibility against
/// any wallpaper, vibrancy, and menu-bar appearance, light or dark. An earlier
/// version of this rendering layered an
/// `NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])` plus
/// `isTemplate = false` onto the streaming state — on an accent-matched
/// wallpaper (e.g. blue accent, blue desktop) that made the streaming icon
/// nearly unreadable, the exact failure template rendering exists to prevent.
/// Do not reintroduce a palette/accent path here: the idle-vs-streaming
/// distinction is already carried by the symbol shape alone
/// (`MenuBarStatus.symbolName`, outline vs. filled).
public enum StatusItemIcon {

    /// Builds the status button's image: the SF Symbol for `state`
    /// (`MenuBarStatus.symbolName(for:)`), `variableValue` set from
    /// `masterVolume` (0...1, clamping is the caller's job — a master-muted
    /// caller passes 0, which is how mute drains the arc), always template.
    /// `isMuted` reaches only the spoken description; the arc already shows it.
    public static func make(state: MenuBarStatus.State,
                            masterVolume: Double,
                            isMuted: Bool) -> NSImage? {
        let image = NSImage(
            systemSymbolName: MenuBarStatus.symbolName(for: state),
            variableValue: masterVolume,
            accessibilityDescription: MenuBarStatus.accessibilityDescription(
                state: state,
                masterVolumePercent: Int((masterVolume * 100).rounded()),
                isMuted: isMuted)
        )
        image?.isTemplate = true
        return image
    }
}
