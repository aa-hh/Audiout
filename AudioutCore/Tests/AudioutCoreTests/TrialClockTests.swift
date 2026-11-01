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

    /// Red if `hasEnded` lost either half of the question. The local dates
    /// answer for a Mac that never reached the server; the server's reason
    /// answers for a Mac reinstalled mid-trial, which has no dates left and
    /// would otherwise be welcomed as a newcomer at the gate.
    @Test func hasEndedReadsTheDatesAndTheServersReason() {
        let running = settings()
        TrialClock.start(settings: running, now: Self.started)
        #expect(!TrialClock.hasEnded(settings: running, now: Self.started))
        #expect(TrialClock.hasEnded(settings: running,
                                    now: Self.started.addingTimeInterval(TrialClock.length)))

        let reinstalled = AppSettings(defaults: isolation.makeDefaults())
        reinstalled.licenseKey = Self.key
        reinstalled.licenseReason = "trial_expired"
        #expect(TrialClock.state(settings: reinstalled, now: Self.started) == .none)
        #expect(TrialClock.hasEnded(settings: reinstalled, now: Self.started))

        // Every other verdict is somebody else's story — a refunded purchase
        // is not a trial that ran out, and the gate says different words.
        let refunded = AppSettings(defaults: isolation.makeDefaults())
        refunded.licenseKey = Self.key
        refunded.licenseReason = "refunded"
        #expect(!TrialClock.hasEnded(settings: refunded, now: Self.started))
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

    /// Red if the start guard ignores the mark.
    @Test func startRefusesAMacThatHasHeldAPaidLicence() {
        let settings = settings()
        settings.hasHeldPaidLicense = true
        TrialClock.start(settings: settings, now: Self.started)
        #expect(settings.trialStartedAt == nil)
        #expect(TrialClock.state(settings: settings, now: Self.started) == .none)
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
        #expect(settings.trialKey == nil)
    }

    // MARK: Whose key is stored

    /// The Macs `holdsKey` must tell apart.
    enum StoredKeyCase: CaseIterable {
        /// The trial's key, its trial running.
        case trialKeyRunning
        /// The trial's key, its trial ended by the dates.
        case trialKeyEnded
        /// A Mac whose dates and recorded trial key are gone, still holding
        /// the key the server last called `trial_expired`.
        case datesGoneServerSaysEnded
        /// A key the person typed over the trial's, not yet answered.
        case typedOverTheTrialKey
    }

    /// Red if `holdsKey` hid a key the person typed over the trial's (it
    /// would vanish from the field and ride the Buy link as `?t=`), or stopped
    /// hiding the trial's key, running, ended, or on a Mac with only the
    /// server's `trial_expired` left to say so.
    @Test(arguments: StoredKeyCase.allCases)
    func holdsKeyTellsTheTrialKeyFromThePersonsOwn(_ storedKey: StoredKeyCase) {
        let settings = settings()
        let expiresAt = Self.started.addingTimeInterval(TrialClock.length)
        var now = Self.started.addingTimeInterval(86_400)
        switch storedKey {
        case .trialKeyRunning:
            TrialClock.apply(settings: settings, startedAt: Self.started, expiresAt: expiresAt, key: Self.key)
        case .trialKeyEnded:
            TrialClock.apply(settings: settings, startedAt: Self.started, expiresAt: expiresAt, key: Self.key)
            now = expiresAt.addingTimeInterval(86_400)
        case .datesGoneServerSaysEnded:
            settings.licenseKey = Self.key
            settings.licenseStatus = .revoked
            settings.licenseReason = "trial_expired"
        case .typedOverTheTrialKey:
            TrialClock.apply(settings: settings, startedAt: Self.started, expiresAt: expiresAt, key: Self.key)
            settings.licenseKey = "AUDT-EEEEE-FFFFF-GGGGG-HHHHH"
        }
        #expect(TrialClock.holdsKey(settings: settings, now: now) == (storedKey != .typedOverTheTrialKey))
    }
}
