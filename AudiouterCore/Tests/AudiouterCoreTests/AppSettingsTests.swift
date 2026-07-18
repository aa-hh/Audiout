// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore

/// `AppSettings` is the scalar half of the persistence split — a thin typed
/// wrapper over `UserDefaults`. These assert the defaults, the round-trip, and
/// forward-compat (an unknown stored value falls back, doesn't trap). A
/// throwaway suite keeps the tests off `.standard`.
final class AppSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AudiouterTests.\(name).\(ObjectIdentifier(self).hashValue)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsWhenUnset() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.theme, .system)
        XCTAssertEqual(settings.density, .comfortable)
    }

    func testThemeRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.theme = .dark
        XCTAssertEqual(settings.theme, .dark)
        // A fresh value over the same store reads the persisted value.
        XCTAssertEqual(AppSettings(defaults: defaults).theme, .dark)
    }

    func testDensityRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        settings.density = .compact
        XCTAssertEqual(settings.density, .compact)
        XCTAssertEqual(AppSettings(defaults: defaults).density, .compact)
    }

    func testUnknownStoredValueFallsBack() {
        defaults.set("chartreuse", forKey: "appearance.theme")
        XCTAssertEqual(AppSettings(defaults: defaults).theme, .system)
    }

    // MARK: Audio buffer (PLAN-LATENCY-SETTING.md)

    func testStartBufferDefaultsWhenUnset() {
        XCTAssertEqual(AppSettings(defaults: defaults).startBufferMs,
                       AppSettings.defaultStartBufferMs)
    }

    func testStartBufferRoundTripsEveryOfferedOption() {
        let settings = AppSettings(defaults: defaults)
        for option in AppSettings.startBufferOptionsMs {
            settings.startBufferMs = option
            XCTAssertEqual(AppSettings(defaults: defaults).startBufferMs, option)
        }
    }

    func testStartBufferUnofferedStoredValueFallsBack() {
        // A value the UI never offers (e.g. written by a newer build with a
        // different option list, or hand-edited defaults) resolves to the
        // default rather than leaking into the popup.
        defaults.set(750, forKey: "audio.startBufferMs")
        XCTAssertEqual(AppSettings(defaults: defaults).startBufferMs,
                       AppSettings.defaultStartBufferMs)
        defaults.set(-40, forKey: "audio.startBufferMs")
        XCTAssertEqual(AppSettings(defaults: defaults).startBufferMs,
                       AppSettings.defaultStartBufferMs)
    }

    func testStartBufferOptionListInvariants() {
        // The default must be offered, the floor is the first option, and the
        // whole list must sit inside the engine shim's accepted 300...5000.
        XCTAssertTrue(AppSettings.startBufferOptionsMs.contains(AppSettings.defaultStartBufferMs))
        XCTAssertEqual(AppSettings.startBufferOptionsMs, AppSettings.startBufferOptionsMs.sorted())
        XCTAssertTrue(AppSettings.startBufferOptionsMs.allSatisfy { (300...5000).contains($0) })
    }

    // MARK: Wake restore (B6b)

    func testWakeRestoreDefaultsToTwoMinutesWhenUnset() {
        // Unset must resolve to the default (2), NOT 0 — 0 is a valid "Never" that
        // `UserDefaults.integer` also returns for a missing key.
        XCTAssertEqual(AppSettings(defaults: defaults).wakeRestoreMinutes,
                       AppSettings.defaultWakeRestoreMinutes)
        XCTAssertEqual(AppSettings.defaultWakeRestoreMinutes, 2)
    }

    func testWakeRestoreRoundTripsEveryOfferedOption() {
        let settings = AppSettings(defaults: defaults)
        for option in AppSettings.wakeRestoreMinuteOptions {
            settings.wakeRestoreMinutes = option
            XCTAssertEqual(AppSettings(defaults: defaults).wakeRestoreMinutes, option)
        }
    }

    func testWakeRestoreNeverIsDistinctFromUnset() {
        // Explicitly choosing Never (0) must PERSIST as 0, not be re-defaulted to 2.
        let settings = AppSettings(defaults: defaults)
        settings.wakeRestoreMinutes = 0
        XCTAssertEqual(AppSettings(defaults: defaults).wakeRestoreMinutes, 0)
    }

    func testWakeRestoreUnofferedStoredValueFallsBack() {
        defaults.set(3, forKey: "audio.wakeRestoreMinutes")
        XCTAssertEqual(AppSettings(defaults: defaults).wakeRestoreMinutes,
                       AppSettings.defaultWakeRestoreMinutes)
        defaults.set(-5, forKey: "audio.wakeRestoreMinutes")
        XCTAssertEqual(AppSettings(defaults: defaults).wakeRestoreMinutes,
                       AppSettings.defaultWakeRestoreMinutes)
    }

    func testWakeRestoreOptionListInvariants() {
        // The default must be offered, options ascend, and Never (0) is offered.
        XCTAssertTrue(AppSettings.wakeRestoreMinuteOptions.contains(AppSettings.defaultWakeRestoreMinutes))
        XCTAssertEqual(AppSettings.wakeRestoreMinuteOptions, AppSettings.wakeRestoreMinuteOptions.sorted())
        XCTAssertEqual(AppSettings.wakeRestoreMinuteOptions.first, 0)
    }
}
