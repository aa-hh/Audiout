// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `TrialClock`: the local record of a 14-day trial, and what the licence
/// server is allowed to do to it. The rules under defense: a trial starts once
/// and keeps its dates, the server's dates beat the local ones, days left round
/// up, and deleting the licence key deletes the trial with it.
@Suite struct TrialClockTests {

    private let isolation = TestIsolation(owner: "TrialClockTests")
    private var defaults: UserDefaults { isolation.isolatedDefaults }

    private static let started = Date(timeIntervalSince1970: 1_800_000_000)
    private static let key = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"

    private func settings() -> AppSettings { AppSettings(defaults: defaults) }

    // MARK: Reading the state

    /// Red if `state` stopped answering `.none` for a Mac that has stored
    /// nothing — a fresh install would then look like it was mid-trial.
    @Test func freshInstallHasNoTrial() {
        #expect(TrialClock.state(settings: settings(), now: Self.started) == .none)
    }

    /// Red if `start` stopped writing a 14-day expiry, or if a just-started
    /// trial claimed to be registered with the server.
    @Test func aStartedTrialHasFourteenDaysLeft() {
        let settings = settings()
        TrialClock.start(settings: settings, now: Self.started)
        #expect(TrialClock.state(settings: settings, now: Self.started)
                == .active(daysLeft: 14,
                           expiresAt: Self.started.addingTimeInterval(TrialClock.length),
                           registered: false))
    }

    /// Red if `daysLeft` started rounding down: 36 hours left is the last two
    /// days of the trial, not one.
    @Test func daysLeftRoundsUp() {
        let settings = settings()
        TrialClock.start(settings: settings, now: Self.started)
        let thirtySixHoursLeft = Self.started
            .addingTimeInterval(TrialClock.length - 36 * 3600)
        #expect(TrialClock.state(settings: settings, now: thirtySixHoursLeft)
                == .active(daysLeft: 2,
                           expiresAt: Self.started.addingTimeInterval(TrialClock.length),
                           registered: false))
    }

    /// Red if the final part-day started reading as zero days left instead of
    /// one, which is what the pill would then show on the last day.
    @Test func oneSecondBeforeExpiryStillHasADayLeft() {
        let settings = settings()
        TrialClock.start(settings: settings, now: Self.started)
        let expiresAt = Self.started.addingTimeInterval(TrialClock.length)
        #expect(TrialClock.state(settings: settings, now: expiresAt.addingTimeInterval(-1))
                == .active(daysLeft: 1, expiresAt: expiresAt, registered: false))
    }

    /// Red if the expiry moment itself were treated as still active — the
    /// boundary belongs to `.expired`.
    @Test func theExpiryMomentIsExpired() {
        let settings = settings()
        TrialClock.start(settings: settings, now: Self.started)
        let expiresAt = Self.started.addingTimeInterval(TrialClock.length)
        #expect(TrialClock.state(settings: settings, now: expiresAt)
                == .expired(expiresAt: expiresAt))
    }

    // MARK: Starting

    /// Red if `start` stopped being idempotent, which would let every launch
    /// push the expiry date forward and make the trial endless.
    @Test func startingTwiceKeepsTheFirstDates() {
        let settings = settings()
        TrialClock.start(settings: settings, now: Self.started)
        TrialClock.start(settings: settings, now: Self.started.addingTimeInterval(3 * 86_400))
        #expect(settings.trialStartedAt == Self.started)
        #expect(settings.trialExpiresAt == Self.started.addingTimeInterval(TrialClock.length))
    }

    // MARK: The server's answer

    /// Red if `apply` stopped overwriting the local dates or stopped storing
    /// the key: a locally started trial would then keep its own clock, and the
    /// trial key would never reach the validate path.
    @Test func applyReplacesLocalDatesWithTheServersAndStoresTheKey() {
        let settings = settings()
        TrialClock.start(settings: settings, now: Self.started)
        let serverStarted = Self.started.addingTimeInterval(2 * 86_400)
        let serverExpires = serverStarted.addingTimeInterval(TrialClock.length)
        TrialClock.apply(settings: settings,
                         startedAt: serverStarted,
                         expiresAt: serverExpires,
                         key: Self.key)
        #expect(settings.trialStartedAt == serverStarted)
        #expect(settings.licenseKey == Self.key)
        #expect(TrialClock.state(settings: settings, now: serverStarted)
                == .active(daysLeft: 14, expiresAt: serverExpires, registered: true))
    }

    // MARK: The two one-time banners

    /// The moment `daysAgo` days into a 14-day trial that started at `started`.
    private func day(_ daysAgo: Double) -> Date {
        Self.started.addingTimeInterval(daysAgo * 86_400)
    }

    /// Red if the banners started appearing early — on day one a trialist has
    /// nothing to be warned about.
    @Test func noBannerIsOwedEarlyInTheTrialOrOutsideOne() {
        let settings = settings()
        #expect(TrialClock.owedBanner(settings: settings, now: Self.started) == nil,
                "no trial, no banner")

        TrialClock.start(settings: settings, now: Self.started)
        #expect(TrialClock.owedBanner(settings: settings, now: day(1)) == nil)
        #expect(TrialClock.owedBanner(settings: settings, now: day(10)) == nil,
                "four days left is still too early")
        #expect(TrialClock.owedBanner(settings: settings, now: day(20)) == nil,
                "a trial that is over warns about nothing")
    }

    /// Red if either banner stopped being one-time — the pair would then nag
    /// on every open for the rest of the trial.
    @Test func eachBannerIsOwedOnceAndThenNeverAgain() {
        let settings = settings()
        TrialClock.start(settings: settings, now: Self.started)

        #expect(TrialClock.owedBanner(settings: settings, now: day(11)) == .threeDays)
        TrialClock.markBannerShown(.threeDays, settings: settings)
        #expect(TrialClock.owedBanner(settings: settings, now: day(11)) == nil)
        #expect(TrialClock.owedBanner(settings: settings, now: day(11.5)) == nil,
                "still the three-day window, and it is spent")

        #expect(TrialClock.owedBanner(settings: settings, now: day(13.5)) == .lastDay)
        TrialClock.markBannerShown(.lastDay, settings: settings)
        #expect(TrialClock.owedBanner(settings: settings, now: day(13.5)) == nil)
    }

    /// Red if a Mac first opened on day 14 got the "ends in 3 days" warning
    /// after the last-day one — the trial would appear to count backwards.
    @Test func theLastDayBannerSpendsTheThreeDayOneToo() {
        let settings = settings()
        TrialClock.start(settings: settings, now: Self.started)

        // Never opened between day 11 and day 14: both are due, and only the
        // sharper one shows.
        #expect(TrialClock.owedBanner(settings: settings, now: day(13.5)) == .lastDay)
        TrialClock.markBannerShown(.lastDay, settings: settings)

        #expect(settings.trialBannerThreeDaysShown, "the milder warning is spent unshown")
        #expect(TrialClock.owedBanner(settings: settings, now: day(13.6)) == nil)
    }

    // MARK: Clearing

    /// Red if deleting the licence key stopped clearing the trial fields — the
    /// install would keep counting down a trial whose key it no longer holds.
    @Test func clearingTheLicenceKeyClearsTheTrial() {
        let settings = settings()
        TrialClock.apply(settings: settings,
                         startedAt: Self.started,
                         expiresAt: Self.started.addingTimeInterval(TrialClock.length),
                         key: Self.key)
        settings.trialBannerThreeDaysShown = true
        settings.trialBannerLastDayShown = true

        settings.licenseKey = nil

        #expect(TrialClock.state(settings: settings, now: Self.started) == .none)
        #expect(settings.trialStartedAt == nil)
        #expect(settings.trialExpiresAt == nil)
        #expect(!settings.trialRegistered)
        #expect(!settings.trialBannerThreeDaysShown)
        #expect(!settings.trialBannerLastDayShown)
    }
}
