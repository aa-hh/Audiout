// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Foundation
import Testing
@testable import AudioutCore
@testable import AudioutOnboardingUI
@testable import AudioutSharedUI

/// The sixth Setup card — usage statistics — which is the only one that is not
/// a macOS permission: no prompt, no probe, no System Settings pane. The answer
/// is Audiout's own, kept in `AppSettings.telemetryOptIn`, and PRODUCT.md's
/// rule for that stream ("asked once, never re-nagged") makes a DECLINE as
/// final as a grant. These pin the four things that rule turns into behaviour:
/// the card is asked last and holds the gate until answered; a yes ticks it and
/// persists; a no spends the ask without ever drawing a checkmark; and a build
/// with no analytics sink drops the card entirely rather than showing one.
///
/// Nested under `SerializedSharedState` because granting or declining calls
/// `Analytics.setConsent`, which writes the same process-global flag
/// `AnalyticsTests` drives — running the two concurrently is a real race, not a
/// theoretical one (the same reason `TelemetryTests` lives here).
///
/// The window-level assertions live here too rather than in `OnboardingUITests`
/// for the same reason: answering this card either way calls
/// `Analytics.setConsent`, so every test that touches it has to be serialized.
///
/// Hermetic otherwise: every permission seam is a scripted fake, so no probe,
/// prompt, or Core Audio. The fakes are local copies by the house pattern —
/// `SetupModelTests`, `SetupFlowModelTests` and `OnboardingUITests` each carry
/// their own rather than sharing one set across suites.
extension SerializedSharedState {

@MainActor
@Suite final class SetupUsageStatsTests: IsolatedSuite {

    // MARK: Fakes

    private struct CannedAudioProbe: AudioCapturePermissionProbing {
        let result: PermissionStatus
        func probe() async -> PermissionStatus { result }
        func currentStatusSilently() -> PermissionStatus? { result }
    }

    private struct CannedLocalNetwork: LocalNetworkPriming {
        let reachable: Bool
        func probe() async -> Bool { reachable }
    }

    private struct CannedRemoteControl: RemoteControlPriming {
        let trusted: Bool
        func prime() {}
        func isTrusted() -> Bool { trusted }
    }

    private struct CannedPTPHelper: PTPHelperManaging {
        let status: PTPHelperStatus
        func register() throws {}
        func openSystemSettingsLoginItems() {}
        func unregister() async throws {}
    }

    /// Run what the cards run, in flow order, so the statuses under test are
    /// ones `SetupModel` can really produce.
    private func prime(_ model: SetupModel) async {
        await model.requestAudioCapture()
        if model.isLocalNetworkGated { await model.primeLocalNetwork() }
        await model.refreshStatuses()   // Bluetooth, Speaker Sync, Remote Control
    }

    /// Every OS grant already in — the state a fresh first run reaches by the
    /// time this card comes up. `usageStatsAvailable` is the one variable.
    private func makeSetup(settings: AppSettings? = nil,
                           usageStatsAvailable: Bool = true) -> SetupModel {
        SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                   localNetwork: CannedLocalNetwork(reachable: true),
                   remoteControl: CannedRemoteControl(trusted: true),
                   ptpHelper: CannedPTPHelper(status: .enabled),
                   bluetoothReader: SimulatedBluetoothPermission(status: .granted),
                   bluetoothPrimer: SimulatedBluetoothPermission(status: .granted),
                   settings: settings ?? AppSettings(defaults: isolatedDefaults),
                   localNetworkGated: true,
                   usageStatsAvailable: usageStatsAvailable,
                   // This suite is about the usage-counts card being LAST; a
                   // seventh row in front of it would say nothing about that.
                   remoteAppAvailable: false)
    }

    /// The card is asked LAST — after every real OS grant — and it is a card,
    /// not a checkbox tacked onto the finale.
    @Test func usageStatsIsTheFinalCardAndHoldsTheGateUntilAnswered() async {
        let setup = makeSetup()
        let flow = SetupFlowModel(setup: setup)
        await prime(setup)

        #expect(flow.steps.last == .usageStats)
        #expect(flow.activeStep == .usageStats,
                "every OS grant is in, so the only card left is ours")
        #expect(!flow.isReadyForFinalCheck,
                "an undecided optional card holds the gate exactly like the other three")
    }

    /// The ask RAISES a surface and grants nothing — the same contract every
    /// other step's ask has, with our sheet in place of macOS's dialog. The
    /// answer lands when the sheet is answered, never on the click.
    @Test func theAskRaisesTheConsentSheetAndGrantsNothing() async {
        let settings = AppSettings(defaults: isolatedDefaults)
        let setup = makeSetup(settings: settings)
        let flow = SetupFlowModel(setup: setup)
        await prime(setup)

        let result = await flow.allow(.usageStats)

        #expect(result.outcome == .consentSheetRaised)
        #expect(result.destination == .usageStatsConsent, "ours, not a Settings pane")
        #expect(!settings.telemetryOptIn, "the click is not the consent")
        #expect(!settings.telemetryAsked, "and it has not spent the ask either")
        #expect(flow.display(.usageStats) != .completed)
    }

    /// Answering the sheet is what decides it, either way.
    @Test func answeringTheSheetIsWhatDecidesTheCard() async {
        let settings = AppSettings(defaults: isolatedDefaults)
        let setup = makeSetup(settings: settings)
        let flow = SetupFlowModel(setup: setup)
        await prime(setup)

        setup.grantUsageStats()

        #expect(flow.display(.usageStats) == .completed)
        #expect(settings.telemetryOptIn)
        #expect(settings.telemetryAsked)
        #expect(flow.isReadyForFinalCheck)
    }

    /// Saying no is an ANSWER, not a deferral: the card stays honestly
    /// unchecked, the ask is spent, and the gate opens anyway.
    @Test func decliningUsageStatsSpendsTheAskAndStillOpensTheGate() async {
        let settings = AppSettings(defaults: isolatedDefaults)
        let setup = makeSetup(settings: settings)
        let flow = SetupFlowModel(setup: setup)
        await prime(setup)

        flow.skip(.usageStats)

        #expect(flow.display(.usageStats) != .completed,
                "a decline must never draw a checkmark — nothing was granted")
        #expect(!settings.telemetryOptIn)
        #expect(settings.telemetryAsked, "PRODUCT.md asks once; a no is an answer")
        #expect(flow.activeStep == nil)
        #expect(flow.isReadyForFinalCheck)
    }

    /// The never-re-nag rule, across presentations: a decline given once is
    /// seeded as already-skipped on every later flow, so re-opening Setup for a
    /// revoked permission cannot smuggle the ask back onto the screen.
    @Test func aDeclineIsNeverAskedAgainOnALaterPresentation() async {
        let settings = AppSettings(defaults: isolatedDefaults)
        let first = makeSetup(settings: settings)
        let firstFlow = SetupFlowModel(setup: first)
        await prime(first)
        firstFlow.skip(.usageStats)

        let second = makeSetup(settings: settings)
        let secondFlow = SetupFlowModel(setup: second)
        await prime(second)

        #expect(secondFlow.skippedSteps.contains(.usageStats))
        #expect(secondFlow.activeStep == nil, "the answer stands; nothing re-asks")
    }

    /// A build with no analytics sink has nothing to opt in to, so the card is
    /// DROPPED rather than shown ticked — a checkmark there would claim a state
    /// that isn't real.
    @Test func withoutAnAnalyticsSinkTheCardDoesNotExist() async {
        let setup = makeSetup(usageStatsAvailable: false)
        let flow = SetupFlowModel(setup: setup)
        await prime(setup)

        #expect(!flow.steps.contains(.usageStats))
        #expect(flow.activeStep == nil)
        #expect(flow.isReadyForFinalCheck)
    }

    /// A skipped card is re-openable from its spine row like any other, so a
    /// user who reflexively passed can still change their mind in the window
    /// they are already looking at.
    @Test func aDeclinedCardCanStillBeReopenedAndGranted() async {
        let settings = AppSettings(defaults: isolatedDefaults)
        let setup = makeSetup(settings: settings)
        let flow = SetupFlowModel(setup: setup)
        await prime(setup)
        flow.skip(.usageStats)

        flow.reopen(.usageStats)
        #expect(flow.activeStep == .usageStats)

        #expect(await flow.allow(.usageStats).destination == .usageStatsConsent)
        setup.grantUsageStats()
        #expect(settings.telemetryOptIn)
        #expect(flow.display(.usageStats) == .completed)
    }


    // MARK: The window

    private func makeViewController(_ setup: SetupModel) -> OnboardingViewController {
        let vc = OnboardingViewController(model: setup, reason: .firstRun,
                                          onOpenSettings: { _ in }, onDone: {})
        _ = vc.test_rootView   // force loadView + viewDidLoad
        return vc
    }

    /// The first ask: the privacy card's two-button shape, and a caption naming
    /// the surface's real owner. macOS raises nothing here, so the shared
    /// "You'll see this from macOS" would be a claim we can't back.
    @Test func theFirstAskWearsTheDialogShapeCaptionedAsOurs() async {
        let setup = makeSetup()
        let vc = makeViewController(setup)
        await vc.test_refreshStatuses()
        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_demoMode == .prompt)
        #expect(vc.test_previewFrameLabel == "You'll see this from Audiout",
                "the card is Audiout's, and the band says so rather than nothing")
        #expect(vc.test_ribbonButtonTitles == ["No Thanks", "Share Usage Counts"],
                "asked once means the pass is an answer, not a 'Skip for now'")
    }

    /// Resolve a dynamic token to comparable components: two accesses of a
    /// provider-backed colour are distinct instances whose `isEqual` is not
    /// documented to see through the provider.
    private func resolvedSRGB(_ color: NSColor?) -> NSColor? {
        guard let color else { return nil }
        var resolved: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return resolved
    }

    /// The rehearsal is a DRAWING of the sheet, never the sheet itself (owner
    /// ruling 2026-09-12): a preview carrying the verbatim promise reads as the
    /// ask, and the button then raises a second, identical-looking surface.
    ///
    /// So: no ``UsageStatsConsentCard`` inside it, and not one word of the
    /// promise. The two things a rehearsal must still teach — the question and
    /// the button to press — stay real.
    @Test func theStageDrawsAMockRatherThanTheSheetItself() throws {
        let stage = DemoConsentCardMockView()
        stage.layoutSubtreeIfNeeded()

        let views = [stage] + stage.subviewsRecursively
        #expect(!views.contains(where: { $0 is UsageStatsConsentCard }),
                "the sheet's own view must not be on the rehearsal stage")

        let words = views.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(!words.contains(UsageStatsConsentCard.bodyText),
                "the promise is greeked here — verbatim, it reads as the ask")
        #expect(words.contains(UsageStatsConsentCard.headlineText),
                "the question stays real: a greeked question asks nothing")

        #expect(stage.test_demoButtonTitles == [UsageStatsConsentCard.declineTitle,
                                                UsageStatsConsentCard.shareTitle])
        #expect(stage.test_demoMarkedButtonTitle == UsageStatsConsentCard.shareTitle,
                "and the rehearsal says which of the two to press")

        // In the real button's GOLD, not the grey the macOS mocks mark with.
        // That grey exists to correct a system dialog's emphasis; this sheet is
        // ours, its Share is a `ProminentButton`, and a grey miniature would
        // drop the card's one identity cue.
        let marked = try #require(views.compactMap { $0 as? DemoPushButtonView }
            .first { $0.isMarked })
        #expect(resolvedSRGB(marked.test_fill) == resolvedSRGB(Tokens.Color.gold))
        #expect(stage.hitTest(NSPoint(x: 10, y: 10)) == nil, "it takes no clicks")

        // And the question FITS. It is the one line of real text on a card
        // narrowed to 280 pt; the drawing is not free to truncate it, and a
        // longer headline or a wider font would have to widen the card.
        let title = try #require(views.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == UsageStatsConsentCard.headlineText })
        #expect(title.frame.width >= title.intrinsicContentSize.width,
                "the headline is drawn on one line, uncropped")
    }

    /// The pointer's glide has to END on Share. It is the whole gesture the
    /// stage rehearses, and it is measured from resolved frames — a layout
    /// change that moved the button without moving the travel would leave the
    /// press landing on nothing.
    @Test func thePointerPressLandsOnTheShareButton() {
        let stage = DemoConsentCardMockView()
        stage.layoutSubtreeIfNeeded()

        #expect(stage.test_shareButtonFrame.contains(stage.test_pressPoint))
    }

    /// The card is the ONLY place the app states what it sends, so it is held
    /// to the payload in both directions: it must DISCLOSE what the autocapture
    /// really carries, and it must still name what genuinely never leaves.
    ///
    /// Both halves are regression guards for the same live failure — an earlier
    /// draft promised "never your network" and "never your licence key" while
    /// the SDK was sending both, and nothing caught it until a real ingested
    /// event was read back.
    @Test func theCardStatesWhatIsSentAndWhatIsWithheld() {
        let body = UsageStatsConsentCard.bodyText.lowercased()

        // Disclosed, because it is genuinely sent.
        for disclosed in ["random id", "licensed", "city", "macos"] {
            #expect(body.contains(disclosed),
                    "the card must disclose what the payload carries — missing: \(disclosed)")
        }
        // Withheld, and the card says so.
        for withheld in ["speakers", "play"] {
            #expect(body.contains(withheld),
                    "the card must still name what never leaves — missing: \(withheld)")
        }
        // The claims the payload cannot back any more. An absolute "never" on
        // either of these is the exact sentence that was false before.
        #expect(!body.contains("never your network"))
        #expect(!body.contains("never your licence key"))
    }

    /// The card carries the promise; the hero's why line carries the WHY. They
    /// sit inches apart on the stage, so saying the same thing in both read as
    /// a stutter.
    @Test func theWhyLineDoesNotRepeatTheCard() {
        #expect(OnboardingViewController.content(for: .usageStats).whyLine
                != UsageStatsConsentCard.bodyText)
    }

    @Test func tappingNoThanksAnswersTheCardFromTheRibbon() async {
        let settings = AppSettings(defaults: isolatedDefaults)
        let setup = makeSetup(settings: settings)
        let vc = makeViewController(setup)
        await vc.test_refreshStatuses()
        await vc.test_allow([.audio, .localNetwork])

        vc.test_ribbonTapSkip()

        #expect(!settings.telemetryOptIn)
        #expect(settings.telemetryAsked)
        #expect(!vc.test_hasCheckmark(.usageStats), "a decline is not a grant")
    }

    /// The row keeps its ACTION — it is a control again, and what it reaches is
    /// the sheet. VoiceOver offers the same words the button does.
    @Test func theLiveRowStillOffersItsActionToPress() async {
        let setup = makeSetup()
        let vc = makeViewController(setup)
        await vc.test_refreshStatuses()
        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_isRowPressable(.usageStats))
        #expect(vc.test_rowIsAccessibilityButton(.usageStats))
        #expect(vc.test_rowAccessibilityAction(.usageStats) == "Share Usage Counts")
    }

    /// Browsing the ticked row re-shows this step's OWN card, never a System
    /// Settings pane — it has none, and the shared browse path defaults to one.
    /// The body says where the switch really lives instead.
    @Test func browsingTheGrantedRowReShowsItsOwnCardNotASettingsPane() async {
        let setup = makeSetup()
        let vc = makeViewController(setup)
        await vc.test_refreshStatuses()
        await vc.test_allow([.audio, .localNetwork, .usageStats])
        await vc.test_awaitFinalCheck()

        #expect(await vc.test_pressRow(.usageStats))

        #expect(vc.test_demoMode == .prompt)
        #expect(!vc.test_ribbonButtonTitles.contains("Open settings…"),
                "there is no System Settings pane to open for Audiout's own switch")
    }
}

} // extension SerializedSharedState
