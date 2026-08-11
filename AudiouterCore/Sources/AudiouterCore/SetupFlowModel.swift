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

/// What one Allow click did — exactly one of these per click, logged to
/// ``Telemetry`` as the `outcome` field of a `setup_allow` line so a live
/// session leaves a readable trail of "the user clicked, and then?".
public enum SetupAllowOutcome: String, Equatable, Sendable {
    /// The native prompt / probe was fired.
    case promptTriggered = "prompt_triggered"
    /// The permission was already granted — no prompt, and deliberately NO
    /// Settings deep link (sending someone to fix what isn't broken).
    case alreadyGranted = "already_granted"
    /// The permission is determined-and-denied, or was already asked once, so
    /// the prompt would silently no-op — the click deep-links to Settings.
    case settingsFallbackDenied = "settings_fallback_denied"
    /// Speaker Sync's only path: Login Items approval, which has no prompt.
    case settingsOpened = "settings_opened"
    /// The prompt/probe ran and came back without a grant (a denial, or a
    /// browse that found nothing). The card's next click becomes the deep link.
    case probeTimeout = "probe_timeout"
    /// A prompt or probe for this step is already in flight — the second click
    /// is a no-op (single-flight).
    case promptInFlight = "prompt_in_flight"
    /// Bluetooth only: the previous prompt sat undecided past its timeout, so
    /// this click asked again rather than reporting a prompt still in flight —
    /// the un-wedge, named so a live session shows it happened.
    case promptRearmed = "prompt_rearmed"
}

/// Where an Allow click sends the user, when it sends them anywhere. The flow
/// model stays AppKit-free, so it names the destination and the UI opens it —
/// which is also what lets the Setup window drop its floating level first (it
/// has to yield to System Settings).
public enum SetupAllowDestination: Equatable, Sendable {
    /// Nothing to open — the click was handled in-app.
    case none
    /// Deep-link to this privacy pane.
    case settingsPane(SystemSettingsPane)
    /// Open System Settings ▸ General ▸ Login Items & Extensions.
    case loginItems
}

/// The full answer to one Allow click.
public struct SetupAllowResult: Equatable, Sendable {
    public let outcome: SetupAllowOutcome
    public let destination: SetupAllowDestination

    init(_ outcome: SetupAllowOutcome, _ destination: SetupAllowDestination = .none) {
        self.outcome = outcome
        self.destination = destination
    }
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

    /// How many speakers the last Local Network browse saw — the Local Network
    /// card's completed title ("Found 3 speakers") instead of a checkmark.
    public var localNetworkFoundSpeakers: Int { setup.localNetworkFoundSpeakers }

    // MARK: The Allow click

    /// The step whose prompt/probe is currently in flight, if any — the
    /// single-flight guard, so a double-click can't stack two prompts.
    private var inFlightStep: SetupStep?

    /// Whether Bluetooth's prompt has already been fired this presentation —
    /// only to name the outcome (a second ask is a re-arm, not a first ask).
    /// Whether one is IN FLIGHT is ``SetupModel/isPrimingBluetooth``, which is
    /// also what expires: Bluetooth is the one prompt whose answer arrives on a
    /// callback we can't await, and a callback that never decides must not latch
    /// the card shut for the rest of the presentation.
    private var didPrimeBluetooth = false

    /// Run one Allow click for `step` and report what it did.
    ///
    /// Three rules hold for every step (Wispr's habits, brief §"Window layering
    /// + prompt sequencing"):
    ///
    /// - **Never open Settings for something already granted** — the click is a
    ///   no-op that says so.
    /// - **Preflight where a real status read exists.** A determined-and-denied
    ///   permission's prompt silently no-ops, so that click goes STRAIGHT to the
    ///   Settings deep link rather than pretending to ask.
    /// - **Single-flight.** A second click while a prompt/probe is in flight is a
    ///   no-op, not a second prompt.
    public func allow(_ step: SetupStep) async -> SetupAllowResult {
        let result = await route(step)
        Telemetry.log(.permission, "setup_allow", [
            "step": Self.telemetryName(step),
            "outcome": result.outcome.rawValue,
        ])
        return result
    }

    private func route(_ step: SetupStep) async -> SetupAllowResult {
        guard inFlightStep == nil else { return SetupAllowResult(.promptInFlight) }
        // Short-circuit a step that is already satisfied — including the two
        // auto-passes, where there is nothing to ask for and no pane to open.
        guard !isComplete(step) else { return SetupAllowResult(.alreadyGranted) }

        inFlightStep = step
        defer { inFlightStep = nil }

        switch step {
        case .audio:
            // A confirmed denial is the one audio state a re-probe can't fix
            // (and re-probing replays the audible tone for nothing).
            if setup.audioStatus == .denied {
                return SetupAllowResult(.settingsFallbackDenied,
                                        .settingsPane(.screenAndSystemAudioRecording))
            }
            await setup.requestAudioCapture()
            return SetupAllowResult(setup.audioStatus == .granted ? .promptTriggered : .probeTimeout)

        case .localNetwork:
            // No two-mode flip here: this card's "prompt" IS the browse, so a
            // browse that found nothing must be re-runnable — the user was told
            // to turn a speaker on and try again, and nothing else re-browses.
            // The Settings pane is offered alongside it by the UI (macOS 15+,
            // where that pane exists), never instead of it.
            await setup.primeLocalNetwork()
            return SetupAllowResult(setup.localNetworkStatus == .granted ? .promptTriggered : .probeTimeout)

        case .bluetooth:
            // The one permission with an honest three-valued read, so the
            // preflight here is real: denied means the prompt is spent.
            if setup.bluetoothStatus == .denied {
                return SetupAllowResult(.settingsFallbackDenied, .settingsPane(.bluetoothPrivacy))
            }
            // In flight means "asked, and the answer hasn't landed" — held by
            // the model, which also un-holds it if the prompt never decides, so
            // a later click can ask again instead of clicking into nothing.
            if setup.isPrimingBluetooth { return SetupAllowResult(.promptInFlight) }
            let isRearm = didPrimeBluetooth
            didPrimeBluetooth = true
            setup.primeBluetooth()
            return SetupAllowResult(isRearm ? .promptRearmed : .promptTriggered)

        case .speakerSync:
            // Not a TCC permission at all: registration already happened at
            // load, and approval only exists in Login Items.
            return SetupAllowResult(.settingsOpened, .loginItems)

        case .remoteControl:
            // Accessibility's own prompt is the ONLY path that highlights this
            // app in the list, so a retry re-primes instead of deep-linking
            // (documented exception — see AudiouterOnboardingUI/AGENTS.md).
            setup.primeRemoteControl()
            return SetupAllowResult(setup.remoteControlStatus == .granted ? .promptTriggered : .probeTimeout)
        }
    }

    /// Stable step name for ``Telemetry`` — explicit, so a future added case is
    /// a compile error here rather than a silently unlabeled log line (same
    /// posture as `PermissionStatus.telemetryDescription`).
    private static func telemetryName(_ step: SetupStep) -> String {
        switch step {
        case .audio: return "audio"
        case .localNetwork: return "local_network"
        case .bluetooth: return "bluetooth"
        case .speakerSync: return "speaker_sync"
        case .remoteControl: return "remote_control"
        }
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
