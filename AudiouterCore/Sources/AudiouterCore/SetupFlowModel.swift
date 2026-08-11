// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One card in the sequential permission flow, in the order they are asked.
/// `speakerSync` is the PTP helper's user-facing name (Login Items approval,
/// not a TCC grant).
public enum SetupStep: CaseIterable, Sendable {
    case audio
    case localNetwork
    case bluetooth
    case speakerSync
    case remoteControl
}

/// How a step renders. Exactly one step is ``active`` at a time; everything else
/// is collapsed, either with a checkmark (``completed``) or without
/// (``pending``).
public enum SetupStepDisplay: Equatable, Sendable {
    case completed
    case active
    case pending
}

/// Answer to a Done tap, after re-verification.
public enum SetupFlowVerification: Equatable, Sendable {
    /// Every required permission still verifies — the flow may finish.
    case complete
    /// Something is unmet; the UI snaps back to this step.
    case unmet(SetupStep)
}

/// Sequences the permission cards over ``SetupModel``'s statuses: which step is
/// active, which are done, which were skipped, and whether Done may exist yet.
/// AppKit-free, and holds no statuses of its own — every answer is derived from
/// the live model, so a grant made anywhere (a prompt, System Settings, a
/// revocation) moves the flow with no state to keep in sync.
///
/// Two rules do the sequencing, and they are deliberately different:
///
/// - **Where the flow STARTS** is the first unmet REQUIRED step. On a first run
///   that is simply the first card; on a `.permissionLost` re-entry it skips
///   past optional cards the user never engaged, so losing Speaker Sync reopens
///   on Speaker Sync rather than re-asking for Bluetooth.
/// - **Where it moves NEXT** is the first step at or after that start which is
///   neither completed nor skipped. There is no "advance" call to forget: the
///   active step is recomputed on every read.
@MainActor
public final class SetupFlowModel {

    /// The card order the flow asks in — scariest grant first (System Audio),
    /// optional last, per `dev/notes/wispr-permissions-brief.md`.
    public static let steps: [SetupStep] = [.audio, .localNetwork, .bluetooth, .speakerSync, .remoteControl]

    /// The two steps a user may pass on. Both are excluded from
    /// ``RequiredPermission``, so skipping one can never affect the gate.
    public static let skippableSteps: Set<SetupStep> = [.bluetooth, .remoteControl]

    /// Steps the user explicitly passed on. Skipped is NOT granted: such a step
    /// stays unchecked, and the app asks again the next time it genuinely needs
    /// the capability.
    public private(set) var skippedSteps: Set<SetupStep> = []

    private let setup: SetupModel

    /// Index of the first step the flow may make active — see the type's doc.
    /// Fixed at init: it answers "where did this presentation come in", which
    /// later grants must not rewrite.
    private let startIndex: Int

    public init(setup: SetupModel) {
        self.setup = setup
        self.startIndex = Self.firstUnmetRequiredIndex(in: setup) ?? 0
    }

    /// The one expanded card, or `nil` once every step is completed or skipped.
    public var activeStep: SetupStep? {
        Self.steps[startIndex...].first { !isComplete($0) && !skippedSteps.contains($0) }
    }

    /// Whether this step counts as done — either its own permission verified, or
    /// it auto-passed (below). Skipping does NOT make a step complete.
    public func isComplete(_ step: SetupStep) -> Bool {
        switch step {
        // `.unsupported` is the pre-14.2 process-tap API: no grant exists to
        // give, so a hard gate must not demand it.
        case .audio: return setup.audioStatus == .granted || setup.audioStatus == .unsupported
        // Local Network privacy arrived in macOS 15; below that, access is
        // already allowed and there is no pane to send anyone to. `.requested`
        // does NOT complete it — that state means "asked, nothing answered",
        // which is indistinguishable from a denial.
        case .localNetwork: return setup.localNetworkStatus == .granted || !setup.isLocalNetworkGated
        case .bluetooth: return setup.bluetoothStatus == .granted
        case .speakerSync: return setup.ptpHelperStatus == .enabled
        case .remoteControl: return setup.remoteControlStatus == .granted
        }
    }

    /// How to render this step. An auto-passed step reads `completed` here while
    /// ``SetupModel``'s own status stays honest — so the card can say "not
    /// available on this macOS" instead of claiming a grant nobody made.
    public func display(_ step: SetupStep) -> SetupStepDisplay {
        if isComplete(step) { return .completed }
        return step == activeStep ? .active : .pending
    }

    /// Pass on a step. Ignored for a step that isn't skippable — the gate is the
    /// product decision, and a caller must not be able to talk the flow out of a
    /// required permission.
    public func skip(_ step: SetupStep) {
        guard Self.skippableSteps.contains(step) else { return }
        skippedSteps.insert(step)
    }

    /// Whether Done may exist at all. The Wispr gate: the button is ABSENT from
    /// the layout until this is true, never present-but-disabled. Bluetooth and
    /// Remote Control are outside ``RequiredPermission`` and so can never hold
    /// it shut.
    public var isDoneAvailable: Bool {
        setup.requiredPermissionsNotGranted().isEmpty
    }

    /// Re-verify everything behind a Done tap: SILENT reads only — never the
    /// audible tone probe, which stays reserved for an explicit Allow tap.
    /// Reports the first still-unmet required step so the UI can snap back to it
    /// with a plain explanation.
    public func verifyForDone() async -> SetupFlowVerification {
        // The audit is the silent re-read (it is what catches a revocation the
        // window-focus refresh deliberately can't); its own return value uses
        // revocation semantics, so the Done verdict comes from the gate check.
        _ = await setup.auditRequiredPermissions()
        guard let unmet = Self.firstUnmetRequiredStep(in: setup) else { return .complete }
        return .unmet(unmet)
    }

    /// The card a ``RequiredPermission`` is asked on.
    private static func step(for permission: RequiredPermission) -> SetupStep {
        switch permission {
        case .audioCapture: return .audio
        case .localNetwork: return .localNetwork
        case .ptpHelper: return .speakerSync
        }
    }

    /// `requiredPermissionsNotGranted()` reports in flow order and already
    /// treats both auto-passes as granted, so its first element IS the first
    /// unmet card.
    private static func firstUnmetRequiredStep(in setup: SetupModel) -> SetupStep? {
        setup.requiredPermissionsNotGranted().first.map(step(for:))
    }

    private static func firstUnmetRequiredIndex(in setup: SetupModel) -> Int? {
        firstUnmetRequiredStep(in: setup).flatMap { steps.firstIndex(of: $0) }
    }
}
