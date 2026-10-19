// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing
@testable import AudioutCore

/// `ExpiredTrialSurvey`: picking our survey out of PostHog's list, who is owed
/// the invite, and the event properties in the shapes posthog-ios sends.
@Suite struct ExpiredTrialSurveyTests {

    private let isolation = TestIsolation(owner: "ExpiredTrialSurveyTests")

    private static let ourID = "0190aaaa-0000-0000-0000-000000000001"
    private static let websiteID = "01a13c28-5cc6-0000-1781-5d89d92876da"
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let server = URL(string: "https://license.example.com")!
    private static let types = ["single_choice", "multiple_choice", "single_choice", "single_choice", "open"]

    private static func surveyJSON(id: String, name: String, start: String = "2026-10-17T00:00:00Z",
                                   end: String? = nil, types: [String] = types,
                                   iteration: Int? = nil) -> [String: Any] {
        [
            "id": id, "name": name, "type": "api",
            "start_date": start,
            "end_date": end ?? NSNull(),
            "current_iteration": iteration ?? NSNull(),
            "current_iteration_start_date": iteration == nil ? NSNull() : "2026-10-18T00:00:00Z",
            "questions": types.enumerated().map { ["id": "q\($0.offset + 1)", "type": $0.element, "question": "Question \($0.offset + 1)"] },
        ]
    }

    private static func payload(_ surveys: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["surveys": surveys])
    }

    private static func ours(iteration: Int? = nil) -> ExpiredTrialSurvey {
        ExpiredTrialSurvey.parse(payload([surveyJSON(id: ourID, name: "Mac", iteration: iteration)]),
                                 surveyID: ourID, now: now)!
    }

    /// Red if `parse` stopped matching by `id`, e.g. took the first survey or
    /// matched by name: the website's survey would then be answered from the Mac.
    @Test func parsePicksOurIDBesideTheWebsiteSurvey() {
        let data = Self.payload([Self.surveyJSON(id: Self.websiteID, name: "Mac"),
                                 Self.surveyJSON(id: Self.ourID, name: "Two quick questions")])
        let survey = ExpiredTrialSurvey.parse(data, surveyID: Self.ourID, now: Self.now)
        #expect(survey?.id == Self.ourID)
        #expect(survey?.questions.map(\.id) == ["q1", "q2", "q3", "q4", "q5"])
    }

    /// Red if `parse` dropped its start-date, end-date, or question-type-order
    /// check: a survey not yet live, already over, or reshaped would be shown.
    @Test func parseRejectsUnstartedEndedAndMisorderedSurveys() {
        let notStarted = Self.surveyJSON(id: Self.ourID, name: "Mac", start: "2027-10-17T00:00:00Z")
        let ended = Self.surveyJSON(id: Self.ourID, name: "Mac", end: "2026-10-18T00:00:00.000Z")
        let misordered = Self.surveyJSON(id: Self.ourID, name: "Mac",
                                         types: ["multiple_choice", "single_choice", "single_choice", "single_choice", "open"])
        for survey in [notStarted, ended, misordered] {
            #expect(ExpiredTrialSurvey.parse(Self.payload([survey]), surveyID: Self.ourID, now: Self.now) == nil)
        }
    }

    /// Red if any one condition of `isOwed` is dropped or the day threshold
    /// moves off 2: a Mac that should not be asked would be invited.
    @Test func isOwedNeedsEveryCondition() {
        func make(days: Int, done: Bool = false, trialEnded: Bool = true) -> AppSettings {
            let settings = AppSettings(defaults: isolation.makeDefaults(), licenseServerURL: Self.server)
            let offset: TimeInterval = trialEnded ? -30 * 86_400 : -1 * 86_400
            TrialClock.start(settings: settings, now: Date().addingTimeInterval(offset))
            settings.trialEndedStreamingDays = days
            settings.expiredTrialSurveyDone = done
            return settings
        }
        #expect(!ExpiredTrialSurvey.isOwed(settings: make(days: 1), consent: true))
        #expect(!ExpiredTrialSurvey.isOwed(settings: make(days: 2), consent: false))
        #expect(!ExpiredTrialSurvey.isOwed(settings: make(days: 2, done: true), consent: true))
        #expect(!ExpiredTrialSurvey.isOwed(settings: make(days: 2, trialEnded: false), consent: true))
        #expect(ExpiredTrialSurvey.isOwed(settings: make(days: 2), consent: true))
    }

    /// Red if `isOwed` stops requiring `LicenseGate.limitsToOneSpeaker`: a
    /// Mac that bought a key after its trial ran out would be asked why it
    /// did not buy.
    @Test func aLicensedInstallWhoseTrialEndedIsNotOwed() {
        let settings = AppSettings(defaults: isolation.makeDefaults(), licenseServerURL: Self.server)
        TrialClock.start(settings: settings, now: Date().addingTimeInterval(-30 * 86_400))
        settings.trialEndedStreamingDays = 2
        settings.licenseKey = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"
        #expect(TrialClock.hasEnded(settings: settings))
        #expect(!ExpiredTrialSurvey.isOwed(settings: settings, consent: true))
    }

    /// Red if `countStreamingDay` stops incrementing `trialEndedStreamingDays`
    /// for an unlicensed Mac past its trial: the invite would never come due.
    @Test func countStreamingDayCountsAfterTheTrialEnds() {
        let ended = AppSettings(defaults: isolation.makeDefaults(), licenseServerURL: Self.server)
        TrialClock.start(settings: ended, now: Date().addingTimeInterval(-30 * 86_400))
        #expect(ExpiredTrialSurvey.countStreamingDay(settings: ended))
        #expect(ended.trialEndedStreamingDays == 1)
    }

    /// Red if `countStreamingDay` drops its `TrialClock.hasEnded` check: days
    /// streamed during the trial would count toward the invite.
    @Test func countStreamingDaySkipsADayInTheTrial() {
        let running = AppSettings(defaults: isolation.makeDefaults(), licenseServerURL: Self.server)
        TrialClock.start(settings: running, now: Date().addingTimeInterval(-1 * 86_400))
        #expect(!ExpiredTrialSurvey.countStreamingDay(settings: running))
        #expect(running.trialEndedStreamingDays == 0)
    }

    /// Red if `countStreamingDay` drops its `LicenseGate.limitsToOneSpeaker`
    /// check: a Mac that bought a key would keep counting toward the invite.
    @Test func countStreamingDaySkipsALicensedInstall() {
        let settings = AppSettings(defaults: isolation.makeDefaults(), licenseServerURL: Self.server)
        TrialClock.start(settings: settings, now: Date().addingTimeInterval(-30 * 86_400))
        settings.licenseKey = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"
        #expect(!ExpiredTrialSurvey.countStreamingDay(settings: settings))
        #expect(settings.trialEndedStreamingDays == 0)
    }

    /// Red if `recordUnansweredLook` stops persisting its count in
    /// `expiredTrialUnansweredLooks` or `maxUnansweredLooks` moves off 3: the
    /// invite would be spent on the wrong close.
    @Test func recordUnansweredLookSpendsOnTheThirdClose() {
        let settings = AppSettings(defaults: isolation.makeDefaults(), licenseServerURL: Self.server)
        #expect(!ExpiredTrialSurvey.recordUnansweredLook(settings: settings))
        #expect(!ExpiredTrialSurvey.recordUnansweredLook(settings: settings))
        #expect(ExpiredTrialSurvey.recordUnansweredLook(settings: settings))
        #expect(settings.expiredTrialUnansweredLooks == 3)
    }

    /// Red if the missing-something details stop going to question 2 as an
    /// array, leak into questions 3 or 4, or a `$set` comes back (PostHog drops
    /// it for an install with no person profile).
    @Test func sentPropertiesForMissingSomething() {
        let props = Self.ours().sentProperties(.init(reason: "It's missing something I need",
                                                     detail: ["A", "B"], text: "More speakers"))
        #expect(props["$survey_response_q1"] as? String == "It's missing something I need")
        #expect(props["$survey_response_q2"] as? [String] == ["A", "B"])
        #expect(props["$survey_response_q3"] == nil)
        #expect(props["$survey_response_q4"] == nil)
        #expect(props["$survey_response_q5"] as? String == "More speakers")
        #expect(props["$set"] == nil)
        #expect((props["$survey_questions"] as? [[String: any Sendable]])?.count == 5)
    }

    /// Red if a dismissal with nothing answered reads as partly completed, or
    /// a `$set` comes back.
    @Test func dismissedPropertiesWithNoAnswers() {
        let props = Self.ours().dismissedProperties(.init())
        #expect(props["$survey_partially_completed"] as? Bool == false)
        #expect(props["$set"] == nil)
    }

    /// Red if `baseProperties` stops sending `$survey_iteration`, which would
    /// fold a later round of the survey into the first in PostHog's results.
    @Test func sentPropertiesCarryTheIteration() {
        let props = Self.ours(iteration: 2).sentProperties(.init(reason: "Too expensive"))
        #expect(props["$survey_iteration"] as? Int == 2)
    }
}
