// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore
@testable import AudiouterPopoverUI

/// The popover side of the "excluded ⇒ un-routable" precedence: an excluded app
/// is dropped from the "+ Add application…" picker and its route row is skipped
/// on rebuild. (The app layer additionally prunes the persisted route; this
/// covers the popover's own defensive filtering.)
@MainActor
@Suite struct PopoverExcludedAppsTests {

    private func tempRouting() -> AppRoutingController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
        return AppRoutingController(store: AppRouteStore(directory: dir))
    }

    @Test func excludedAppIsSkippedInRowsAndPicker() {
        let routing = tempRouting()
        routing.addRoute(bundleID: "com.example.music", displayName: "Music")
        routing.addRoute(bundleID: "com.example.safari", displayName: "Safari")

        // The picker candidate list: one un-routed app (Podcasts) we'll exclude.
        let provider: () -> [RunningAppInfo] = {
            [RunningAppInfo(bundleID: "com.example.podcasts", displayName: "Podcasts", icon: nil)]
        }
        let popover = PopoverController(appRouting: routing, runningAppsProvider: provider)
        popover.isAppExcluded = { $0 == "com.example.music" || $0 == "com.example.podcasts" }
        popover.test_simulateOpen()

        // Rows: the excluded routed app (Music) is skipped; Safari remains.
        #expect(popover.test_appRow(for: "com.example.music") == nil)
        #expect(popover.test_appRow(for: "com.example.safari") != nil)
        #expect(popover.test_appRowCount == 1)

        // Picker: Music/Safari are already routed, Podcasts is excluded → nothing
        // left to offer.
        #expect(popover.test_availableAppsForPicker().isEmpty)
    }

    @Test func nothingExcludedLeavesRowsIntact() {
        let routing = tempRouting()
        routing.addRoute(bundleID: "com.example.music", displayName: "Music")
        let popover = PopoverController(appRouting: routing, runningAppsProvider: { [] })
        popover.test_simulateOpen()
        #expect(popover.test_appRow(for: "com.example.music") != nil)
        #expect(popover.test_appRowCount == 1)
    }
}
