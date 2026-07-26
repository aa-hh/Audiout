// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// `PermissionMode` is the `AIRPLAY_PERMISSIONS` env knob (sibling of
/// `AIRPLAY_BACKEND`/`AIRPLAY_SETUP`) that lets the app run with SIMULATED
/// permission seams so dev/test iteration never touches real macOS TCC — the
/// grant that otherwise re-pins to the binary on every ad-hoc rebuild. These
/// pin the env resolution, the simulated seams' reported states, and that a
/// `.granted` bundle drives `SetupModel` to a fully-satisfied result while a
/// `.denied` bundle leaves every required permission unmet.
@MainActor
@Suite final class PermissionModeTests: IsolatedSuite {

    // MARK: Resolution

    @Test func resolve_defaultsToSystem_whenUnset() {
        #expect(PermissionMode.resolved(environment: [:]) == .system)
    }

    @Test func resolve_grantedTokens() {
        for token in ["granted", "GRANTED", "grant", "allow", "yes"] {
            #expect(
                PermissionMode.resolved(environment: ["AIRPLAY_PERMISSIONS": token]) ==
                .granted, "token \"\(token)\" should resolve to .granted")
        }
    }

    @Test func resolve_deniedTokens() {
        for token in ["denied", "Denied", "deny", "no"] {
            #expect(
                PermissionMode.resolved(environment: ["AIRPLAY_PERMISSIONS": token]) ==
                .denied, "token \"\(token)\" should resolve to .denied")
        }
    }

    @Test func resolve_systemTokens() {
        for token in ["system", "real", "auto", "os"] {
            #expect(
                PermissionMode.resolved(environment: ["AIRPLAY_PERMISSIONS": token]) ==
                .system, "token \"\(token)\" should resolve to .system")
        }
    }

    @Test func resolve_unrecognizedFallsBackToSystem() {
        // Unrecognized value → .system (dev knob, forgiving), never a crash.
        #expect(
            PermissionMode.resolved(environment: ["AIRPLAY_PERMISSIONS": "maybe"]) ==
            .system)
    }

    // MARK: Simulated seams report the mode's state

    @Test func grantedProviders_reportSatisfied() async {
        let p = PermissionMode.granted.makeProviders()
        let audio = await p.audioProbe.probe()
        #expect(audio == .granted)
        #expect(p.audioProbe.currentStatusSilently() == .granted)
        let reachable = await p.localNetwork.probe()
        #expect(reachable)
        #expect(p.remoteControl.isTrusted())
        #expect(p.ptpHelper.status == .enabled)
    }

    @Test func deniedProviders_reportUnsatisfied() async {
        let p = PermissionMode.denied.makeProviders()
        let audio = await p.audioProbe.probe()
        #expect(audio == .denied)
        #expect(p.audioProbe.currentStatusSilently() == .denied)
        let reachable = await p.localNetwork.probe()
        #expect(!reachable)
        #expect(!p.remoteControl.isTrusted())
        #expect(p.ptpHelper.status == .requiresApproval)
    }

    /// A simulated primer must NEVER open the real Accessibility dialog — that's
    /// the whole point of the airtight seam. We can't assert "no dialog" directly,
    /// but `prime()` returning without touching AX and `isTrusted()` staying on
    /// the canned value proves it's the simulation, not the OS.
    @Test func simulatedRemoteControl_primeIsSilentNoop() {
        let primer = SimulatedRemoteControlPrimer(trusted: false)
        primer.prime()
        #expect(!primer.isTrusted())
    }

    // MARK: End-to-end through SetupModel

    @Test func grantedProviders_driveSetupModelToSatisfied() async {
        let model = SetupModel(providers: PermissionMode.granted.makeProviders(),
                               settings: AppSettings(defaults: isolatedDefaults),
                               localNetworkGated: true)
        await model.requestAudioCapture()
        await model.primeLocalNetwork()
        model.primeRemoteControl()
        model.registerPTPHelper()

        #expect(model.audioStatus == .granted)
        #expect(model.localNetworkStatus == .granted)
        #expect(model.remoteControlStatus == .granted)
        #expect(model.ptpHelperStatus == .enabled)
        #expect(model.requiredPermissionsNotGranted().isEmpty,
                      "granted providers should satisfy every required permission")
    }

    @Test func deniedProviders_leaveRequiredPermissionsUnmet() async {
        let model = SetupModel(providers: PermissionMode.denied.makeProviders(),
                               settings: AppSettings(defaults: isolatedDefaults),
                               localNetworkGated: true)
        await model.requestAudioCapture()
        await model.primeLocalNetwork()
        model.registerPTPHelper()

        #expect(model.audioStatus == .denied)
        #expect(model.localNetworkStatus == .requested)
        #expect(model.ptpHelperStatus == .requiresApproval)
        let notGranted = Set(model.requiredPermissionsNotGranted())
        #expect(notGranted.contains(.audioCapture))
        #expect(notGranted.contains(.localNetwork))
        #expect(notGranted.contains(.ptpHelper))
    }
}
