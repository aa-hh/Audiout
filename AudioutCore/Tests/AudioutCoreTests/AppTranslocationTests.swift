// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

@Suite struct AppTranslocationTests {

    // Hardcoding the destination name as Audiout.app would make a differently
    // named dev build overwrite the live /Applications/Audiout.app.
    @Test func destinationKeepsTheRunningBundlesOwnName() {
        let bundleURL = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Audiout Dev.app")
        let destination = AppTranslocation.applicationsDestination(for: bundleURL)
        #expect(destination.path == "/Applications/Audiout Dev.app")
    }
}
