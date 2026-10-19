// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

/// The PostHog survey asked of a Mac whose trial ended without a purchase but
/// that still streams. PostHog cannot target or draw a survey on macOS, so it
/// is created there as an "api" survey and this app fetches its definition,
/// decides who is owed it, and builds the `survey shown` / `survey sent` /
/// `survey dismissed` properties itself, in the shapes posthog-ios sends.
public struct ExpiredTrialSurvey: Equatable, Sendable {

    public struct Question: Equatable, Sendable {
        public let id: String
        public let text: String
    }

    /// What the user picked. `detail` holds the follow-up choices for the
    /// reason that has one; `text` is the optional free-text line.
    public struct Answers: Equatable, Sendable {
        public var reason: String?
        public var detail: [String]
        public var text: String?

        public init(reason: String? = nil, detail: [String] = [], text: String? = nil) {
            self.reason = reason
            self.detail = detail
            self.text = text
        }
    }

    public let id: String
    public let name: String
    public let currentIteration: Int?
    public let currentIterationStartDate: String?
    /// Exactly five: the reason, three follow-ups (one per reason that has
    /// one), and the free-text line.
    public let questions: [Question]

    /// The owner fills this in after creating the survey in PostHog. Empty
    /// means no fetch and no survey.
    public static let surveyID = ""

    /// The question types, in order, a usable survey must have.
    private static let questionTypes = ["single_choice", "multiple_choice", "single_choice", "single_choice", "open"]

    // MARK: - Fetching

    /// The survey with `surveyID` from a `GET /api/surveys/` body, or `nil`
    /// unless it is an "api" survey that has started, has not ended, and has
    /// the five questions in the expected type order.
    public static func parse(_ data: Data, surveyID: String, now: Date) -> ExpiredTrialSurvey? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let surveys = root["surveys"] as? [[String: Any]],
              let survey = surveys.first(where: { $0["id"] as? String == surveyID }),
              survey["type"] as? String == "api",
              let start = (survey["start_date"] as? String).flatMap(date(from:)), start <= now
        else { return nil }
        if let endText = survey["end_date"] as? String {
            guard let end = date(from: endText), end > now else { return nil }
        }
        guard let raw = survey["questions"] as? [[String: Any]],
              raw.map({ $0["type"] as? String ?? "" }) == questionTypes
        else { return nil }
        var questions: [Question] = []
        for q in raw {
            guard let id = q["id"] as? String, let text = q["question"] as? String else { return nil }
            questions.append(Question(id: id, text: text))
        }
        return ExpiredTrialSurvey(id: surveyID,
                                  name: survey["name"] as? String ?? "",
                                  currentIteration: survey["current_iteration"] as? Int,
                                  currentIterationStartDate: survey["current_iteration_start_date"] as? String,
                                  questions: questions)
    }

    private static func date(from text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Fetches the project's surveys and parses ours. Calls `completion` on
    /// the URL session's queue; the caller hops to main. Any failure, or an
    /// empty `surveyID`, gives `nil`.
    public static func fetch(host: String, token: String, surveyID: String,
                             completion: @escaping @Sendable (ExpiredTrialSurvey?) -> Void) {
        guard !surveyID.isEmpty,
              var components = URLComponents(string: host.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/surveys/")
        else { completion(nil); return }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { completion(nil); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil, let data,
                  let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
            else { completion(nil); return }
            completion(parse(data, surveyID: surveyID, now: Date()))
        }.resume()
    }

    // MARK: - Who is owed it

    /// Whether this Mac should be invited: never invited before, consent on,
    /// the trial over with no license bought, and audio reached a speaker on
    /// two or more days since.
    public static func isOwed(settings: AppSettings, consent: Bool) -> Bool {
        !settings.expiredTrialSurveyDone && consent && settings.trialEndedStreamingDays >= 2
            && TrialClock.hasEnded(settings: settings)
            && LicenseGate.limitsToOneSpeaker(settings: settings)
    }

    // MARK: - Event properties

    /// The reasons whose follow-up question applies, by question index.
    private static let detailQuestion: [String: Int] = [
        "It's missing something I need": 1,
        "It hasn't been reliable enough": 2,
        "I use something else for this": 3,
    ]

    /// Properties for `survey shown`.
    public func shownProperties() -> [String: any Sendable] {
        baseProperties()
    }

    /// Properties for `survey sent`.
    public func sentProperties(_ answers: Answers) -> [String: any Sendable] {
        var props = answerProperties(answers)
        props["$set"] = [setKey("$survey_responded"): true]
        return props
    }

    /// Properties for `survey dismissed`, including a partly answered one.
    public func dismissedProperties(_ answers: Answers) -> [String: any Sendable] {
        var props = answerProperties(answers)
        props["$set"] = [setKey("$survey_dismissed"): true]
        props["$survey_partially_completed"] = !responses(answers).isEmpty
        return props
    }

    private func baseProperties() -> [String: any Sendable] {
        var props: [String: any Sendable] = ["$survey_name": name, "$survey_id": id]
        if let currentIteration { props["$survey_iteration"] = currentIteration }
        if let currentIterationStartDate { props["$survey_iteration_start_date"] = currentIterationStartDate }
        return props
    }

    /// Each answered question's response, by question index.
    private func responses(_ answers: Answers) -> [Int: any Sendable] {
        var out: [Int: any Sendable] = [:]
        if let reason = answers.reason {
            out[0] = reason
            switch Self.detailQuestion[reason] {
            case 1?: if !answers.detail.isEmpty { out[1] = answers.detail }
            case let index?: if let first = answers.detail.first { out[index] = first }
            case nil: break
            }
        }
        if let text = answers.text, !text.isEmpty { out[4] = text }
        return out
    }

    private func answerProperties(_ answers: Answers) -> [String: any Sendable] {
        var props = baseProperties()
        let responses = responses(answers)
        var questionList: [[String: any Sendable]] = []
        for (index, question) in questions.enumerated() {
            var entry: [String: any Sendable] = ["id": question.id, "question": question.text]
            if let response = responses[index] {
                entry["response"] = response
                props["$survey_response_\(question.id)"] = response
            }
            questionList.append(entry)
        }
        props["$survey_questions"] = questionList
        return props
    }

    private func setKey(_ prefix: String) -> String {
        if let currentIteration, currentIteration > 0 { return "\(prefix)/\(id)/\(currentIteration)" }
        return "\(prefix)/\(id)"
    }
}
