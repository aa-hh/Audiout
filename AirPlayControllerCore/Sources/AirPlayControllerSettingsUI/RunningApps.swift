// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit

/// A plain-value snapshot of one pickable application for the Audio pane's
/// "Add application…" picker. Deliberately its own small type (not the popover's
/// `RunningAppInfo`) so `AirPlayControllerSettingsUI` stays decoupled from
/// `AirPlayControllerPopoverUI` — the same isolation idiom the row views use
/// against Core's models. Injectable so tests supply a fixed list.
public struct AppPickerItem: Equatable {
    public let bundleID: String
    public let displayName: String
    public let icon: NSImage?

    public init(bundleID: String, displayName: String, icon: NSImage?) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.icon = icon
    }

    /// `Equatable` ignores `icon` (`NSImage` isn't meaningfully comparable; tests
    /// only care about identity/name).
    public static func == (lhs: AppPickerItem, rhs: AppPickerItem) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.displayName == rhs.displayName
    }
}

/// Source of pickable running apps for the Audio pane.
public enum RunningApps {

    /// Every `.regular`-activation-policy app (Dock-visible, not a background
    /// agent) with a bundle id — the same filter the popover picker uses,
    /// mapped to `AppPickerItem`.
    public static func regularRunningApps() -> [AppPickerItem] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return AppPickerItem(bundleID: bundleID,
                                     displayName: app.localizedName ?? bundleID,
                                     icon: app.icon)
            }
    }
}
