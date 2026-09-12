// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// "App translocation" is Gatekeeper running a downloaded, quarantined app
/// from a randomized read-only mirror instead of its real path. It happens
/// when the app is opened straight from a DMG or Downloads without first
/// being moved. `applicationsDestination(for:)` names the copy after the
/// running bundle's own name, never a fixed "Audiout.app", so a differently
/// named dev or handover build lands beside the live copy instead of over it.
public enum AppTranslocation {

    /// True when `bundleURL` points at Gatekeeper's translocated mirror.
    public static func isTranslocated(bundleURL: URL) -> Bool {
        bundleURL.path.contains("/AppTranslocation/")
    }

    /// Where a translocated bundle should be copied to restore normal operation.
    public static func applicationsDestination(for bundleURL: URL) -> URL {
        URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleURL.lastPathComponent)
    }
}
