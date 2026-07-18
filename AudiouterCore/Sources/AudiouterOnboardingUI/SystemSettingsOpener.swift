// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// Opens a System Settings privacy pane via `NSWorkspace`. Kept as a tiny seam so
/// the onboarding view controller stays AppKit-`NSWorkspace`-free and testable
/// (a test injects a closure that records the pane instead of launching Settings).
///
/// The `x-apple.systempreferences:` anchors (``SystemSettingsPane``) are
/// best-effort — Apple can rename one between OS releases — so if a specific pane
/// URL won't open we fall back to the Privacy & Security root, which always does.
public enum SystemSettingsOpener {

    /// Open the given pane, falling back to the Privacy & Security root.
    public static func open(_ pane: SystemSettingsPane) {
        if !NSWorkspace.shared.open(pane.url) {
            _ = NSWorkspace.shared.open(SystemSettingsPane.privacyRoot)
        }
    }
}
