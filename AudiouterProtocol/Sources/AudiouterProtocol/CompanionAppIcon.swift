// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One app icon as sent to the phone, keyed by the bundle ID the phone
/// requested it for.
public struct AppIconPayload: Codable, Equatable, Sendable {
    public var bundleID: String
    /// PNG bytes, 128×128. `nil` means the Mac has no icon for this bundle
    /// ID (uninstalled or unresolvable) — a definitive negative, not a
    /// transport failure, so the phone stops asking.
    public var png: Data?

    public init(bundleID: String, png: Data?) {
        self.bundleID = bundleID
        self.png = png
    }
}

/// Paging constants for `CompanionCommand.requestAppIcons` /
/// `CompanionMessage.appIcons`.
public enum CompanionAppIcons {
    /// 8 icons × ≤66 KB (128×128 RGBA PNG ceiling) × 1.37 base64 ≈ 723 KB,
    /// under `MacConnection.maxInboundFrameBytes` = 1 MB
    /// (MacConnection.swift:503).
    public static let pageSize = 8
    public static let maxRequestedBundleIDs = 128
}
