// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore

/// `PermissionMode` is the `AIRPLAY_PERMISSIONS` env knob (sibling of
/// `AIRPLAY_BACKEND`/`AIRPLAY_SETUP`) that lets the app run with SIMULATED
/// permission seams so dev/test iteration never touches real macOS TCC — the
/// grant that otherwise re-pins to the binary on every ad-hoc rebuild. These
/// pin the env resolution, the simulated seams' reported states, and that a
/// `.granted` bundle drives `SetupModel` to a fully-satisfied result while a
/// `.denied` bundle leaves every required permission unmet.
@MainActor
final class PermissionModeTests: IsolatedTestCase {

    // MARK: Resolution

    func test_resolve_defaultsToSystem_whenUnset() {
        XCTAssertEqual(PermissionMode.resolved(environment: [:]), .system)
    }

    func test_resolve_grantedTokens() {
        for token in ["granted", "GRANTED", "grant", "allow", "yes"] {
            XCTAssertEqual(
                PermissionMode.resolved(environment: ["AIRPLAY_PERMISSIONS": token]),
                .granted, "token \"\(token)\" should resolve to .granted")
        }
    }

    func test_resolve_deniedTokens() {
        for token in ["denied", "Denied", "deny", "no"] {
            XCTAssertEqual(
                PermissionMode.resolved(environment: ["AIRPLAY_PERMISSIONS": token]),
                .denied, "token \"\(token)\" should resolve to .denied")
        }
    }

    func test_resolve_systemTokens() {
        for token in ["system", "real", "auto", "os"] {
            XCTAssertEqual(
                PermissionMode.resolved(environment: ["AIRPLAY_PERMISSIONS": token]),
                .system, "token \"\(token)\" should resolve to .system")
        }
    }

    func test_resolve_unrecognizedFallsBackToSystem() {
        // Unrecognized value → .system (dev knob, forgiving), never a crash.
        XCTAssertEqual(
            PermissionMode.resolved(environment: ["AIRPLAY_PERMISSIONS": "maybe"]),
            .system)
    }

    // MARK: Simulated seams report the mode's state

    func test_grantedProviders_reportSatisfied() async {
        let p = PermissionMode.granted.makeProviders()
        let audio = await p.audioProbe.probe()
        XCTAssertEqual(audio, .granted)
        XCTAssertEqual(p.audioProbe.currentStatusSilently(), .granted)
        let reachable = await p.localNetwork.probe()
        XCTAssertTrue(reachable)
        XCTAssertTrue(p.remoteControl.isTrusted())
        XCTAssertEqual(p.ptpHelper.status, .enabled)
    }

    func test_deniedProviders_reportUnsatisfied() async {
        let p = PermissionMode.denied.makeProviders()
        let audio = await p.audioProbe.probe()
        XCTAssertEqual(audio, .denied)
        XCTAssertEqual(p.audioProbe.currentStatusSilently(), .denied)
        let reachable = await p.localNetwork.probe()
        XCTAssertFalse(reachable)
        XCTAssertFalse(p.remoteControl.isTrusted())
        XCTAssertEqual(p.ptpHelper.status, .requiresApproval)
    }

    /// A simulated primer must NEVER open the real Accessibility dialog — that's
    /// the whole point of the airtight seam. We can't assert "no dialog" directly,
    /// but `prime()` returning without touching AX and `isTrusted()` staying on
    /// the canned value proves it's the simulation, not the OS.
    func test_simulatedRemoteControl_primeIsSilentNoop() {
        let primer = SimulatedRemoteControlPrimer(trusted: false)
        primer.prime()
        XCTAssertFalse(primer.isTrusted())
    }

    // MARK: End-to-end through SetupModel

    func test_grantedProviders_driveSetupModelToSatisfied() async {
        let model = SetupModel(providers: PermissionMode.granted.makeProviders(),
                               settings: AppSettings(defaults: isolatedDefaults),
                               localNetworkGated: true)
        await model.requestAudioCapture()
        await model.primeLocalNetwork()
        model.primeRemoteControl()
        model.registerPTPHelper()

        XCTAssertEqual(model.audioStatus, .granted)
        XCTAssertEqual(model.localNetworkStatus, .granted)
        XCTAssertEqual(model.remoteControlStatus, .granted)
        XCTAssertEqual(model.ptpHelperStatus, .enabled)
        XCTAssertTrue(model.requiredPermissionsNotGranted().isEmpty,
                      "granted providers should satisfy every required permission")
    }

    func test_deniedProviders_leaveRequiredPermissionsUnmet() async {
        let model = SetupModel(providers: PermissionMode.denied.makeProviders(),
                               settings: AppSettings(defaults: isolatedDefaults),
                               localNetworkGated: true)
        await model.requestAudioCapture()
        await model.primeLocalNetwork()
        model.registerPTPHelper()

        XCTAssertEqual(model.audioStatus, .denied)
        XCTAssertEqual(model.localNetworkStatus, .requested)
        XCTAssertEqual(model.ptpHelperStatus, .requiresApproval)
        let notGranted = Set(model.requiredPermissionsNotGranted())
        XCTAssertTrue(notGranted.contains(.audioCapture))
        XCTAssertTrue(notGranted.contains(.localNetwork))
        XCTAssertTrue(notGranted.contains(.ptpHelper))
    }
}
