// SPDX-License-Identifier: GPL-2.0-or-later

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

    /// Whether the system has the registration but is waiting for the user to
    /// approve it in System Settings › General › Login Items. `register()`
    /// SUCCEEDS in that state while ``isEnabled`` stays false, so without this
    /// the switch just silently springs back with no explanation.
    var needsApproval: Bool { get }

    /// Open System Settings at the Login Items list, so the approval the user
    /// has to give is one click away instead of a hunt.
    func openSystemSettingsLoginItems()
}

/// Defaults, so the existing test fakes and the snapshot tool keep conforming
/// without change: a seam that cannot report an approval simply never needs one.
public extension LoginItemManaging {
    var needsApproval: Bool { false }
    func openSystemSettingsLoginItems() {}
}

/// Production `LoginItemManaging` over `SMAppService.mainApp` — the macOS 13+
/// API that registers the main app itself as a login item (no separate helper
/// bundle); the package's `.macOS(.v14)` floor covers it.
public struct SMAppServiceLoginItem: LoginItemManaging {

    public init() {}

    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
