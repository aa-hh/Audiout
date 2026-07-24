// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import ServiceManagement

/// The state of the privileged PTP helper daemon — the root `SMAppService`
/// launchd daemon that owns UDP 319/320 and the PTP master clock so AirPlay 2
/// speakers can share one timing source (AirPlayEngine/docs/ptp-helper-design.md
/// §2). A re-mapping of `SMAppService.Status`, not the raw enum itself, so
/// ``SetupModel`` and the onboarding UI never import `ServiceManagement` and a
/// test can construct any state with zero system dependency.
public enum PTPHelperStatus: Equatable, Sendable {
    /// Never registered, or unregistered since (`register()` hasn't run, or
    /// failed — see ``PTPHelperManaging/register()``'s doc comment).
    case notRegistered
    /// Registered, but not yet approved in System Settings › General › Login
    /// Items & Extensions. PTP is NOT usable in this state — treat it exactly
    /// like a stale/missing `airptp_shm` find (design doc §5.2): no PTP-timed
    /// session, "clock unavailable" surfaced to the UI.
    case requiresApproval
    /// Approved and running under launchd. `airptp_daemon_find()` can be
    /// expected to succeed (mirrors `SMAppService.Status.enabled`).
    case enabled
    /// The daemon is missing from the bundle, or launchd doesn't recognize the
    /// label at all (mirrors `.notFound`) — a packaging bug, not a user
    /// decision. There is nothing the approval UX can do about it, same
    /// posture as ``PermissionStatus/unsupported``.
    case notFound
}

/// The app-side seam for the PTP helper's `SMAppService` daemon registration —
/// mirrors `AudiouterSettingsUI`'s `LoginItemManaging` pattern exactly: a
/// protocol, not a bare `SMAppService` call, so ``SetupModel`` and its UI are
/// unit-testable without registering a real launchd daemon as a side effect of
/// a test run.
///
/// NOTE (Developer-ID gating, PROGRESS.md T5/T6): `register()` cannot reach
/// `.enabled` on this branch's ad-hoc-signed build — `SMAppService` daemon
/// registration validates the bundled launchd plist's code signature, which
/// ad-hoc signing does not satisfy. The real register()→approve→enabled path
/// is build/bundle-tested only (T5) and unit-tested only via the injected fake
/// (T6) until Developer ID signing lands; never call the real
/// `SMAppServicePTPHelper` from a test.
public protocol PTPHelperManaging {
    /// The live status, mapped from `SMAppService.Status`. Read fresh, not
    /// cached — the user can flip the Login Items toggle, or macOS can revoke
    /// it, at any time outside the app's control.
    var status: PTPHelperStatus { get }

    /// Register the daemon. Idempotent — `SMAppService.register()` is a no-op
    /// if already registered — and registering itself shows NO system prompt
    /// (unlike the audio/network/Accessibility seams): the daemon merely
    /// appears, disabled, in Login Items. The user-facing step is the
    /// *approval* afterwards, surfaced by `.requiresApproval`. Throws if the
    /// system refuses (e.g. a loose dev binary outside a proper bundle — same
    /// failure mode ``LoginItemManaging`` documents).
    func register() throws

    /// Deep-link to System Settings › General › Login Items & Extensions,
    /// where the user approves (or later revokes) the helper. Wraps the
    /// static `SMAppService.openSystemSettingsLoginItems()`.
    func openSystemSettingsLoginItems()
}

/// Production `PTPHelperManaging` over `SMAppService.daemon(plistName:)`.
///
/// The plist name below MUST equal the bundled launchd plist's filename
/// (`Contents/Library/LaunchDaemons/<name>`, `Label` + ".plist") — see
/// `scripts/ptp-helper.plist`'s own comment and `scripts/make-app.sh`'s
/// `HELPER_LABEL`. `SMAppService.daemon(plistName:)` resolves the plist by
/// this exact string; a mismatch fails registration silently into `.notFound`.
public struct SMAppServicePTPHelper: PTPHelperManaging {

    /// Mirrors `scripts/make-app.sh`'s `HELPER_LABEL` + ".plist" and
    /// `scripts/ptp-helper.plist`'s `Label` — BOTH are `${BUNDLE_ID}.ptphelper`
    /// at build time, so this reads the RUNNING bundle's own identifier rather
    /// than a hardcoded default. Without this, a side-by-side dev build under a
    /// distinct `BUNDLE_ID` override would ask `SMAppService` for a DIFFERENT
    /// app's already-claimed daemon identity, and `register()` would silently
    /// no-op instead of registering its own (2026-07-24 live-testing bug — see
    /// `scripts/ptp-helper.plist`'s comment for the full story). Falls back to
    /// the shipped default only if `Bundle.main.bundleIdentifier` is somehow
    /// unavailable (never true for a real app bundle).
    public static var plistName: String {
        "\(Bundle.main.bundleIdentifier ?? "com.audiouter.Audiouter").ptphelper.plist"
    }

    private let service: SMAppService

    public init(plistName: String = SMAppServicePTPHelper.plistName) {
        self.service = .daemon(plistName: plistName)
    }

    public var status: PTPHelperStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    public func register() throws {
        try service.register()
    }

    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
