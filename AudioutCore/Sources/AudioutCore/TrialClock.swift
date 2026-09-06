// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Where this Mac stands in its 14-day free trial.
public enum TrialState: Equatable {

    /// No trial has ever started here.
    case none

    /// A trial is running. `registered` is `false` until the licence server has
    /// answered about it, which is an ordinary state rather than a failure — a
    /// trial may start with no network and register later.
    case active(daysLeft: Int, expiresAt: Date, registered: Bool)

    /// The trial ran out. There is no second one.
    case expired(expiresAt: Date)
}

/// A warning shown once in the life of a trial and never again.
///
/// The raw value is the days-left threshold that raises it, and it is what
/// rides the `day` property of `license:banner_shown`.
public enum TrialBanner: String, Equatable {

    /// Three days left.
    case threeDays = "3"

    /// The last day. Tomorrow the welcome gate is back.
    case lastDay = "1"
}

/// The local half of the trial: when it started, when it ends, and whether the
/// licence server knows about it. Callers ask one question, ``state(settings:now:)``.
///
/// A trial can start with no network, so the dates are recorded locally first
/// and the server's own record replaces them in
/// ``apply(settings:startedAt:expiresAt:key:)``. The server's dates always win,
/// even over a trial this Mac started moments ago: a clock set backwards, or an
/// offline start that predates the request, must not buy extra days.
public enum TrialClock {

    private static let day: TimeInterval = 86_400

    /// 14 days, the whole length of a trial.
    public static let length: TimeInterval = 14 * day

    /// Where the trial stands at `now`.
    ///
    /// `daysLeft` rounds UP, so the final part-day still reads "1 day left"
    /// rather than "0 days left" — the state is `.expired` the moment the trial
    /// is actually over, and nothing else says zero.
    public static func state(settings: AppSettings, now: Date = Date()) -> TrialState {
        guard settings.trialStartedAt != nil, let expiresAt = settings.trialExpiresAt else {
            return .none
        }
        guard now < expiresAt else { return .expired(expiresAt: expiresAt) }
        let daysLeft = max(0, Int(ceil(expiresAt.timeIntervalSince(now) / day)))
        return .active(daysLeft: daysLeft, expiresAt: expiresAt, registered: settings.trialRegistered)
    }

    /// Starts the trial locally, unregistered.
    ///
    /// Idempotent: a trial that has already started keeps its own dates, so a
    /// caller may run this on every launch without shortening or extending
    /// anything.
    public static func start(settings: AppSettings, now: Date = Date()) {
        guard settings.trialStartedAt == nil else { return }
        settings.trialStartedAt = now
        settings.trialExpiresAt = now.addingTimeInterval(length)
        settings.trialRegistered = false
    }

    /// Which one-time banner this Mac is still owed, or `nil` for none.
    ///
    /// Only a running trial is owed one. The last-day warning wins whenever
    /// both are due, and it is the only one a Mac gets from then on: someone
    /// who never opened the app between day 11 and day 14 has missed the
    /// milder warning for good, and showing it afterwards would count
    /// backwards.
    public static func owedBanner(settings: AppSettings, now: Date = Date()) -> TrialBanner? {
        guard case .active(let daysLeft, _, _) = state(settings: settings, now: now) else {
            return nil
        }
        if daysLeft <= 1 { return settings.trialBannerLastDayShown ? nil : .lastDay }
        if daysLeft <= 3 { return settings.trialBannerThreeDaysShown ? nil : .threeDays }
        return nil
    }

    /// Records that a banner has gone on screen, and reports it.
    ///
    /// Written the moment the banner appears rather than when it is dismissed:
    /// a flag that waited for a dismissal would bring the banner back after a
    /// quit. The last-day warning marks the three-day one shown too, which is
    /// what ``owedBanner(settings:now:)`` above relies on.
    public static func markBannerShown(_ banner: TrialBanner, settings: AppSettings) {
        switch banner {
        case .threeDays:
            settings.trialBannerThreeDaysShown = true
        case .lastDay:
            settings.trialBannerLastDayShown = true
            settings.trialBannerThreeDaysShown = true
        }
        Analytics.capture("license:banner_shown", ["day": banner.rawValue])
    }

    /// Records what the licence server said about this Mac's trial.
    ///
    /// The server's dates overwrite whatever was here, including a trial this
    /// Mac started seconds ago — the server's record is the one that decides.
    /// Storing the trial key as ``AppSettings/licenseKey`` is what hands the
    /// trial over to the ordinary validate and check-in path: a trial IS a
    /// licence key, and from here nothing downstream needs to know it is one.
    public static func apply(settings: AppSettings,
                             startedAt: Date,
                             expiresAt: Date,
                             key: String) {
        settings.trialStartedAt = startedAt
        settings.trialExpiresAt = expiresAt
        settings.trialRegistered = true
        settings.licenseKey = key
    }
}
