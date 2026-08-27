// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

/// Opens a System Settings privacy pane via `NSWorkspace`. Kept as a tiny seam so
/// the onboarding view controller stays AppKit-`NSWorkspace`-free and testable
/// (a test injects a closure that records the pane instead of launching Settings).
///
/// The `x-apple.systempreferences:` anchors (``SystemSettingsPane``) are
/// best-effort — Apple can rename one between OS releases — and there is nothing
/// to fall back TO in code: the scheme resolves, so `NSWorkspace.open` returns
/// true even when the anchor lands the user on the wrong pane. The recovery for
/// a misroute is the written path in the onboarding ribbon, not a retry here.
public enum SystemSettingsOpener {

    /// Open the given pane, best-effort — see the type comment for why the
    /// result carries no information worth branching on.
    public static func open(_ pane: SystemSettingsPane) {
        _ = NSWorkspace.shared.open(pane.url)
    }
}
