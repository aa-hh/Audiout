// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import XCTest
@testable import AirPlayControllerCore

/// `AppSettings` is the scalar half of the persistence split — a thin typed
/// wrapper over `UserDefaults`. These assert the defaults, the round-trip, and
/// forward-compat (an unknown stored value falls back, doesn't trap). A
/// throwaway suite keeps the tests off `.standard`.
final class AppSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AudioControlTests.\(name).\(ObjectIdentifier(self).hashValue)"
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
}
