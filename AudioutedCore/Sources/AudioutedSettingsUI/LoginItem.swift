// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import Foundation
import ServiceManagement

/// The "launch at login" seam (Settings › General). An abstraction, not a bare
/// `SMAppService` call, so the General pane is unit-testable without registering
/// a real login item as a side effect of a test run.
public protocol LoginItemManaging {
    /// Whether the app is currently registered to open at login. The source of
    /// truth is the system (`SMAppService`), NOT a stored bool — the user can
    /// change it in System Settings behind our back, so we always read live.
    var isEnabled: Bool { get }

    /// Register (`true`) or unregister (`false`) the login item. Throws if the
    /// system refuses (e.g. a loose dev binary that isn't a registered bundle) —
    /// the caller reverts the toggle and surfaces the failure rather than lying
    /// about the state.
    func setEnabled(_ enabled: Bool) throws
}

/// Production `LoginItemManaging` over `SMAppService.mainApp` — the macOS 13+
/// API that registers the main app itself as a login item (no separate helper
/// bundle). Matches the package's `.macOS(.v13)` floor.
public struct SMAppServiceLoginItem: LoginItemManaging {

    public init() {}

    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
