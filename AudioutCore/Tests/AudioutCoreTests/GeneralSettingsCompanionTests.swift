// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutSettingsUI
@testable import AudioutSharedUI

/// FIX-C: the Settings › Audiout Remote "Allow control from iPhone" switch
/// must never misrepresent whether the companion LAN server is actually
/// running.
///
/// Before this fix, the pane (then part of General) rendered and wrote
/// `AppSettings.allowRemoteControl` directly — the RAW persisted bool — while
/// `AppDelegate` started/stopped the server from
/// `AppSettings.resolvedAllowRemoteControl`, which lets `AUDIOUT_COMPANION`
/// win over that same setting. With the env var set, the switch could show
/// OFF on a fresh profile while a LAN server was running, and unchecking it
/// did nothing — a switch that lies is the worst kind of security-relevant
/// UI bug. These assert the pane now reflects the EFFECTIVE (resolved) state,
/// disables itself and explains why while an override is in force, and stays
/// exactly as before when no override is present.
@MainActor
@Suite struct GeneralSettingsCompanionTests {

    private func makeSettings() -> AppSettings {
        let suite = "AudioutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    private func makePane(settings: AppSettings, environment: [String: String]) -> RemoteSettingsViewController {
        RemoteSettingsViewController(settings: settings, environment: environment, remoteAppIsOffered: true)
    }

    // MARK: No override present — unchanged behavior

    @Test func noOverrideReflectsRawSettingAndIsEnabled() {
        let settings = makeSettings()
        settings.allowRemoteControl = true
        let pane = makePane(settings: settings, environment: [:])

        #expect(pane.test_allowRemoteControlIsOn)
        #expect(pane.test_allowRemoteControlIsEnabled)
        #expect(pane.test_allowRemoteControlOverrideNote == nil)
    }

    @Test func noOverrideTogglingWritesTheSettingAndFiresCallback() {
        let settings = makeSettings()
        settings.allowRemoteControl = false
        let pane = makePane(settings: settings, environment: [:])

        var callbackFired = false
        pane.onAllowRemoteControlChanged = { callbackFired = true }

        pane.test_toggleAllowRemoteControl(true)
        #expect(pane.test_allowRemoteControlIsOn)
        #expect(settings.allowRemoteControl)
        #expect(callbackFired)

        callbackFired = false
        pane.test_toggleAllowRemoteControl(false)
        #expect(!pane.test_allowRemoteControlIsOn)
        #expect(!settings.allowRemoteControl)
        #expect(callbackFired)
    }

    @Test func garbageEnvValueBehavesAsNoOverride() {
        // An unrecognized env value falls back to the setting AND must not
        // lock the switch — only a RECOGNIZED override may disable it.
        let settings = makeSettings()
        settings.allowRemoteControl = true
        let pane = makePane(settings: settings, environment: ["AUDIOUT_COMPANION": "banana"])

        #expect(pane.test_allowRemoteControlIsOn)
        #expect(pane.test_allowRemoteControlIsEnabled)
        #expect(pane.test_allowRemoteControlOverrideNote == nil)
    }

    // MARK: Override present — the switch must be honest

    @Test func overridePresentReflectsEffectiveValueAndDisables() {
        let settings = makeSettings()
        // The setting says OFF; the env var forces ON. Pre-fix, the switch
        // rendered OFF (the raw setting) while the server actually ran.
        settings.allowRemoteControl = false
        let pane = makePane(settings: settings, environment: ["AUDIOUT_COMPANION": "1"])

        #expect(pane.test_allowRemoteControlIsOn)
        #expect(!pane.test_allowRemoteControlIsEnabled)
        let note = pane.test_allowRemoteControlOverrideNote
        #expect(note != nil)
        // The note must NOT leak the raw environment-variable name to the user;
        // it says a launch option is in force, in plain words.
        #expect(note?.contains("AUDIOUT_COMPANION") == false)
        #expect(note?.contains("launch option") == true)
        #expect(pane.test_allowRemoteControlOverrideNoteTextColor == Tokens.Color.label2,
                "this note names a setting in force, not a failure — it never takes the red")
    }

    @Test func overrideForcedOffAlsoReflectsEffectiveValue() {
        let settings = makeSettings()
        settings.allowRemoteControl = true
        let pane = makePane(settings: settings, environment: ["AUDIOUT_COMPANION": "off"])

        #expect(!pane.test_allowRemoteControlIsOn)
        #expect(!pane.test_allowRemoteControlIsEnabled)
        #expect(pane.test_allowRemoteControlOverrideNote != nil)
    }

    @Test func overridePresentTogglingIsImpossibleNotSilentlyIneffective() {
        let settings = makeSettings()
        settings.allowRemoteControl = false
        let pane = makePane(settings: settings, environment: ["AUDIOUT_COMPANION": "1"])

        var callbackFired = false
        pane.onAllowRemoteControlChanged = { callbackFired = true }

        // Attempt to uncheck it, exactly as the (disabled, in the real UI)
        // control's action would run if somehow invoked.
        pane.test_toggleAllowRemoteControl(false)

        // The switch bounces back to the effective (forced) value rather
        // than adopting the attempted state, the setting is untouched, and no
        // "changed" callback fires — nothing about reality actually changed.
        #expect(pane.test_allowRemoteControlIsOn)
        #expect(!settings.allowRemoteControl)
        #expect(!callbackFired)
    }

    /// Red if the Audiout Remote row's readout stops following the switch or
    /// stops counting only the iPhones that were allowed.
    @Test func readoutFollowsTheSwitchAndTheAllowedPhones() throws {
        let settings = makeSettings()
        settings.allowRemoteControl = false
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioutTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let approvals = CompanionApprovalController(store: CompanionApprovalStore(directory: dir))
        let pane = RemoteSettingsViewController(settings: settings, environment: [:],
                                                remoteAppIsOffered: true, approvals: approvals)
        let root = SettingsRootViewController(sections: [
            .init(title: "Audiout Remote", symbolName: "iphone", viewController: pane),
        ])
        #expect(root.test_readoutLines(at: 0) == ["Off"])

        pane.test_toggleAllowRemoteControl(true)
        #expect(root.test_readoutLines(at: 0) == ["On · no iPhones yet"])

        approvals.presentPrompt = { _, _, respond in respond(false) }
        approvals.handleRequest(clientID: "7C1D93F0-1111-4A2A-B3C4-D5E6F7A8B9C0", clientName: "Guest's iPhone") { _ in }
        #expect(root.test_readoutLines(at: 0) == ["On · no iPhones allowed"])

        approvals.presentPrompt = { _, _, respond in respond(true) }
        approvals.handleRequest(clientID: "2B5E5A2B-58D8-4979-9F41-92E668FD9C0A", clientName: "Owner's iPhone") { _ in }
        approvals.handleRequest(clientID: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D", clientName: "Kid's iPhone") { _ in }
        #expect(root.test_readoutLines(at: 0) == ["On · 2 iPhones allowed"])
    }
}

/// T24: the "Remembered iPhones" list under the remote-control switch —
/// remembered phones render with their decision, revoking one removes it,
/// persists the removal, and drops the live client; no controller injected
/// (or no phones remembered) means no visible section at all.
@MainActor
@Suite final class GeneralSettingsRememberedPhonesTests: IsolatedSuite {

    private static let ownerID = "2B5E5A2B-58D8-4979-9F41-92E668FD9C0A"
    private static let guestID = "7C1D93F0-1111-4A2A-B3C4-D5E6F7A8B9C0"

    private func makeController(records: [CompanionApproval]) throws -> CompanionApprovalController {
        let store = CompanionApprovalStore(directory: scratchDir)
        try store.save(records)
        return CompanionApprovalController(store: store)
    }

    private func makePane(approvals: CompanionApprovalController?) -> RemoteSettingsViewController {
        RemoteSettingsViewController(settings: AppSettings(defaults: isolatedDefaults),
                                     environment: [:], remoteAppIsOffered: true,
                                     approvals: approvals)
    }

    private func record(_ id: String, name: String, decision: CompanionApproval.Decision) -> CompanionApproval {
        CompanionApproval(clientID: id, lastKnownName: name, decision: decision,
                          firstSeen: .distantPast, lastSeen: .distantPast)
    }

    @Test func rememberedPhonesRenderWithTheirDecisions() throws {
        let controller = try makeController(records: [
            record(Self.ownerID, name: "Owner's iPhone", decision: .approved),
            record(Self.guestID, name: "Guest's iPhone", decision: .denied),
        ])
        let pane = makePane(approvals: controller)

        #expect(pane.test_phoneListIsVisible)
        #expect(pane.test_phoneRowCount == 2)
        #expect(pane.test_rememberedPhones.map(\.name) == ["Owner's iPhone", "Guest's iPhone"])
        #expect(pane.test_rememberedPhones.map(\.decision) == ["Allowed", "Denied"])
        #expect(pane.test_phoneRowDecisionTextColor(at: 1) == Tokens.Color.labelCool,
                "a recorded \"Denied\" is a fact about a past decision, not a failure — it never takes the red")
    }

    @Test func emptyListHidesTheSection() throws {
        let pane = makePane(approvals: try makeController(records: []))
        #expect(!pane.test_phoneListIsVisible)
        #expect(pane.test_phoneRowCount == 0)
    }

    @Test func noControllerMountsNoSection() {
        let pane = makePane(approvals: nil)
        #expect(!pane.test_phoneListIsVisible)
    }

    @Test func revokeRemovesTheRowPersistsAndDropsTheLiveClient() throws {
        let controller = try makeController(records: [
            record(Self.ownerID, name: "Owner's iPhone", decision: .approved),
            record(Self.guestID, name: "Guest's iPhone", decision: .denied),
        ])
        var dropped: [String] = []
        controller.dropClient = { dropped.append($0) }
        let pane = makePane(approvals: controller)

        pane.test_revokePhone(clientID: Self.ownerID)

        #expect(pane.test_phoneRowCount == 1, "the revoked row must leave the VIEW, not just the model")
        #expect(pane.test_rememberedPhones.map(\.name) == ["Guest's iPhone"])
        #expect(dropped == [Self.ownerID], "revoking from Settings must drop the live client")
        // Persisted: a fresh load over the same directory no longer has it.
        #expect(try CompanionApprovalStore(directory: scratchDir).load()?.map(\.clientID) == [Self.guestID])
    }

    // MARK: The invitation to Audiout Remote

    /// Defect this names: a release built before Audiout Remote is approved
    /// still offers the Audiout Remote section — the Allow switch, the QR
    /// invitation and the phone list, three offers to pair with an app nobody
    /// can download. The app builds the section only while `isOffered`.
    @Test func aBuildWithoutTheCompanionOffersNoRemoteSection() throws {
        let settings = AppSettings(defaults: isolatedDefaults)
        settings.allowRemoteControl = true
        let pane = RemoteSettingsViewController(settings: settings, environment: [:],
                                                 remoteAppIsOffered: false,
                                                 approvals: try makeController(records: [
                                                    record(Self.ownerID, name: "Owner's iPhone",
                                                           decision: .approved),
                                                 ]))
        #expect(!pane.isOffered)
        #expect(!pane.test_remoteInviteRowIsMounted)
        #expect(!pane.test_allowRemoteControlIsOn,
                "the effective state is off, whatever the persisted setting says")
    }

    /// Defect this names: the invitation stays in the pane after the switch
    /// goes off, so a Mac that refuses phones goes on inviting one.
    @Test func theInvitationIsMountedOnlyWhileTheSwitchIsOn() throws {
        let settings = AppSettings(defaults: isolatedDefaults)
        settings.allowRemoteControl = true
        let pane = RemoteSettingsViewController(settings: settings, environment: [:], remoteAppIsOffered: true,
                                                 approvals: try makeController(records: []))
        #expect(pane.test_remoteInviteRowIsMounted)

        pane.test_toggleAllowRemoteControl(false)
        #expect(!pane.test_remoteInviteRowIsMounted)

        pane.test_toggleAllowRemoteControl(true)
        #expect(pane.test_remoteInviteRowIsMounted, "turning it back on re-mounts the row")
    }

    /// Defect this names: the QR keeps taking up the pane once a phone is
    /// already remembered, where only the address is still useful.
    @Test func theQRDropsOnceAPhoneIsRemembered() throws {
        let settings = AppSettings(defaults: isolatedDefaults)
        settings.allowRemoteControl = true
        let controller = try makeController(records: [])
        controller.presentPrompt = { _, _, respond in respond(true) }
        let pane = RemoteSettingsViewController(settings: settings, environment: [:], remoteAppIsOffered: true,
                                                 approvals: controller)
        #expect(pane.test_remoteInviteQRIsVisible)

        controller.handleRequest(clientID: Self.ownerID, clientName: "Owner's iPhone") { _ in }

        #expect(!pane.test_remoteInviteQRIsVisible)
        #expect(pane.test_remoteInviteRowIsMounted,
                "the row stays — a second phone in the house still needs the address")
    }

    /// Defect this names: the link launching a real browser out of a test
    /// run, or pointing somewhere other than the invitation's own page.
    @Test func theLinkOpensThePageThroughTheInjectedSeam() throws {
        var opened: [URL] = []
        let settings = AppSettings(defaults: isolatedDefaults)
        settings.allowRemoteControl = true
        let pane = RemoteSettingsViewController(settings: settings, environment: [:], remoteAppIsOffered: true,
                                                 openURL: { opened.append($0) },
                                                 approvals: try makeController(records: []))
        #expect(pane.test_remoteInviteButtonTitle == "Open audiout.app/remote")

        pane.test_tapRemoteInviteLink()

        #expect(opened.map(\.absoluteString) == [RemoteInviteView.pageURLString])
    }

    /// A phone approved WHILE the window is open (the prompt path) appears
    /// live — the pane claims the controller's `onChange`.
    @Test func aNewDecisionAppearsInTheOpenList() throws {
        let controller = try makeController(records: [])
        controller.presentPrompt = { _, _, respond in respond(true) }
        let pane = makePane(approvals: controller)
        #expect(!pane.test_phoneListIsVisible)

        controller.handleRequest(clientID: Self.ownerID, clientName: "Owner's iPhone") { _ in }

        #expect(pane.test_phoneListIsVisible)
        #expect(pane.test_rememberedPhones.map(\.name) == ["Owner's iPhone"])
    }
}
