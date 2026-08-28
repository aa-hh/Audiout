// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One card in the sequential permission flow, in the order they are asked.
/// `speakerSync` is the PTP helper's user-facing name (Login Items approval,
/// not a TCC grant); `usageStats` is not an OS grant at all — it is Audiout's
/// own opt-in, asked here rather than ambushing the first menu-bar click.
public enum SetupStep: CaseIterable, Sendable {
    case audio
    case localNetwork
    case bluetooth
    case speakerSync
    case remoteControl
    case usageStats
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
    /// A skipped, skippable step was re-opened (a click on a decided-skipped
    /// row in the spine) — the skip never spent a prompt, so the step goes
    /// back to being undecided.
    case skipReopened = "skip_reopened"
    /// Usage Statistics' only path: there is no OS to ask, so the click IS
    /// the answer and it lands in-app.
    case consentGranted = "consent_granted"
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

/// Where the automatic final check stands — the sixth row in the Setup
/// column. `pending` until every card is decided, `running` while the silent
/// audit re-verifies, `passed` once it lands clean. The gate, the settled
/// finale, and the CTA all key off `passed`, so success and forward motion
/// arrive on the same beat — the check made VISIBLE is what closed the live
/// "clicked and nothing happened for two seconds" gap.
public enum SetupFinalCheckState: Equatable, Sendable {
    case pending
    case running
    case passed
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
    /// optional last, per `dev/notes/wispr-permissions-brief.md`. Usage
    /// Statistics sits at the very END, after every real OS grant: it is the
    /// only card that asks for something the user gives US rather than
    /// something macOS gives Audiout, and putting that between two permission
    /// asks would blur the difference the whole window is teaching.
    public static let steps: [SetupStep] = [.audio, .localNetwork, .bluetooth, .speakerSync,
                                            .remoteControl, .usageStats]

    /// The four steps a user may pass on. An UNDECIDED one holds Done shut:
    /// the gate waits for every card to be decided, and a skip is the decision
    /// that clears it (see ``isDoneAvailable``).
    ///
    /// Bluetooth and Remote Control are outside ``RequiredPermission`` entirely,
    /// so their permissions never held Done shut either. **Speaker Sync is
    /// different** and deliberately so: it stays a `RequiredPermission` and is
    /// still audited whenever it was ever enabled, because a helper that was
    /// approved and then switched off is a real regression. What the skip buys
    /// is an EXIT — approval lives in Login Items, macOS can refuse it outright,
    /// and without a skip an unapproved helper locked this gate forever with
    /// nothing on screen to press. ``unmetRequiredSteps()`` is what filters a
    /// skipped Speaker Sync out of the gate.
    ///
    /// **Usage Statistics is skippable in a fourth sense again:** its skip is
    /// the DECLINE, not a deferral. PRODUCT.md's rule for that stream is
    /// "asked once, never re-nagged", so passing on it is an answer the app
    /// keeps (``SetupModel/declineUsageStats()``) and never puts back on
    /// screen. Its button says so — "No Thanks", not "Skip for now".
    public static let skippableSteps: Set<SetupStep> = [.bluetooth, .remoteControl, .speakerSync,
                                                        .usageStats]

    /// Steps the user explicitly passed on. Skipped is NOT granted: such a step
    /// stays unchecked, and the app asks again the next time it genuinely needs
    /// the capability. (Usage Statistics is the exception — see
    /// ``skippableSteps`` — and it is also the only step that can arrive here
    /// pre-seeded, from an answer given in an earlier presentation.)
    public private(set) var skippedSteps: Set<SetupStep> = []

    /// The card order THIS presentation walks. Normally ``steps``; a build with
    /// no analytics sink drops Usage Statistics entirely rather than showing a
    /// row for an ask that can't appear (``SetupModel/usageStatsAreAvailable``).
    /// Dropped, not auto-passed: a checkmark beside "Usage statistics" in a
    /// build that sends nothing would be the one thing this window must never
    /// do — claim a state that isn't real.
    public let steps: [SetupStep]

    private let setup: SetupModel

    /// Index of the first step the flow may make active — see the type's doc.
    /// Fixed at init: it answers "where did this presentation come in", which
    /// later grants must not rewrite.
    private let startIndex: Int

    public init(setup: SetupModel) {
        self.setup = setup
        let steps = setup.usageStatsAreAvailable
            ? Self.steps : Self.steps.filter { $0 != .usageStats }
        self.steps = steps
        self.startIndex = Self.firstUnmetRequiredIndex(in: setup, among: steps) ?? 0
        // An answer already given is an answer: PRODUCT.md asks once. A DECLINE
        // leaves no other trace — `usageStatsOptedIn` is false either way — so
        // the flow seeds it skipped here rather than re-offering the card on
        // every re-entry. A grant needs nothing: `isComplete` reads it.
        if setup.usageStatsWereAnswered, !setup.usageStatsOptedIn {
            skippedSteps.insert(.usageStats)
        }
    }

    /// The one expanded card, or `nil` once every step is completed or skipped.
    public var activeStep: SetupStep? {
        steps[startIndex...].first { !isComplete($0) && !skippedSteps.contains($0) }
    }

    /// Whether this step counts as done — either its own permission verified, or
    /// it auto-passed (below). Skipping does NOT make a step complete.
    public func isComplete(_ step: SetupStep) -> Bool {
        switch step {
        // `.unsupported` is the pre-14.2 process-tap API: no grant exists to
        // give, so a hard gate must not demand it.
        case .audio: return setup.audioStatus == .granted || setup.audioStatus == .unsupported
        // Local Network privacy arrived in macOS 15; below that, access is
        // already allowed and there is no pane to send anyone to. `.granted`
        // means the PERMISSION is granted (self-discovery proves it with zero
        // speakers on the network), which is the honest gate condition;
        // `.requested` (asked, nothing answered) and `.denied` do not complete.
        case .localNetwork: return setup.localNetworkStatus == .granted || !setup.isLocalNetworkGated
        case .bluetooth: return setup.bluetoothStatus == .granted
        // Same auto-pass posture as `.unsupported` audio two lines up: a
        // `.notFound` daemon (missing from the bundle) and a `register()` that
        // threw are packaging/signing faults, not user decisions, so no
        // approval exists to demand and a hard gate must not demand one.
        case .speakerSync:
            return setup.ptpHelperStatus == .enabled
                || setup.ptpHelperStatus == .notFound
                || setup.ptpHelperRegistrationFailed
        case .remoteControl: return setup.remoteControlStatus == .granted
        // Ours, not macOS's: complete means the user said yes. Saying no is a
        // DECISION, not a completion — it lands in `skippedSteps` like every
        // other pass, and the row stays honestly unchecked.
        case .usageStats: return setup.usageStatsOptedIn
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
    /// card's completed title ("3 speakers on your network") instead of a checkmark.
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

    /// Where a step's Settings deep link goes. ONE table, shared by the
    /// denied-path Allow below and the UI's stuck-dialog escape hatch — a
    /// second copy is how the two would drift onto different panes.
    public static func settingsDestination(for step: SetupStep) -> SetupAllowDestination {
        switch step {
        case .audio: return .settingsPane(.screenAndSystemAudioRecording)
        case .localNetwork: return .settingsPane(.localNetwork)
        case .bluetooth: return .settingsPane(.bluetoothPrivacy)
        // Not a privacy pane at all — approval only exists in Login Items.
        case .speakerSync: return .loginItems
        case .remoteControl: return .settingsPane(.accessibility)
        // Nowhere to send anyone: the switch is Audiout's own, in Settings ›
        // General, and there is no System Settings pane for it at all.
        case .usageStats: return .none
        }
    }

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
                return SetupAllowResult(.settingsFallbackDenied, Self.settingsDestination(for: step))
            }
            await setup.requestAudioCapture()
            return SetupAllowResult(setup.audioStatus == .granted ? .promptTriggered : .probeTimeout)

        case .localNetwork:
            // A refusal IS provable here (the mDNS policy error), and it spends
            // the prompt exactly like a denied TCC grant — so this preflight is
            // as real as Bluetooth's.
            if setup.localNetworkStatus == .denied {
                return SetupAllowResult(.settingsFallbackDenied, Self.settingsDestination(for: step))
            }
            // Short of a proven refusal there is no two-mode flip: this card's
            // "prompt" IS the browse, so a browse that found nothing must be
            // re-runnable — the user was told to turn a speaker on and try
            // again, and nothing else re-browses. The Settings pane is offered
            // alongside it by the UI (macOS 15+, where that pane exists).
            await setup.primeLocalNetwork()
            return SetupAllowResult(setup.localNetworkStatus == .granted ? .promptTriggered : .probeTimeout)

        case .bluetooth:
            // The one permission with an honest three-valued read, so the
            // preflight here is real: denied means the prompt is spent.
            if setup.bluetoothStatus == .denied {
                return SetupAllowResult(.settingsFallbackDenied, Self.settingsDestination(for: step))
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
            return SetupAllowResult(.settingsOpened, Self.settingsDestination(for: step))

        case .remoteControl:
            // The FIRST fire has to be the prompt, because prompting is what
            // REGISTERS this app's row in the Accessibility list at all — a cold
            // deep link would drop the user on a list with no Audiout row to
            // switch on. Once that prompt is spent (`.requested`, the same
            // condition the button's two-mode flip reads) asking again silently
            // no-ops, so the retry deep-links like every other step. Re-priming
            // instead was worth an extra window and an extra click only while
            // the alert was believed to highlight us in that list, which no live
            // run has ever shown it doing — see this app's onboarding AGENTS.md.
            if setup.remoteControlStatus == .requested {
                return SetupAllowResult(.settingsFallbackDenied, Self.settingsDestination(for: step))
            }
            setup.primeRemoteControl()
            return SetupAllowResult(setup.remoteControlStatus == .granted ? .promptTriggered : .probeTimeout)

        case .usageStats:
            // No prompt, no probe, no pane — the click IS the grant, and it
            // lands before this returns, so the row is ticked by the time the
            // caller repaints. Named `consentGranted` rather than borrowing
            // `promptTriggered`, so a live trail can't be read as macOS having
            // asked the user something it never asked.
            setup.grantUsageStats()
            return SetupAllowResult(.consentGranted)
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
        case .usageStats: return "usage_stats"
        }
    }

    /// Pass on a step. Ignored for a step that isn't skippable — the gate is the
    /// product decision, and a caller must not be able to talk the flow out of a
    /// required permission.
    public func skip(_ step: SetupStep) {
        guard Self.skippableSteps.contains(step) else { return }
        skippedSteps.insert(step)
        // Remember it beyond this window: the wake audit must stop reading an
        // unapproved helper as "something got turned off in Login Items".
        // `reopen(_:)` needs no counterpart — the flag only re-arms on a real
        // `.enabled`.
        if step == .speakerSync { setup.noteSpeakerSyncSkipped() }
        // The one skip that is a final ANSWER rather than a deferral: record
        // it so the ask is spent and no later presentation re-offers it, and
        // so a sink installed at launch is opted out rather than left as-is.
        if step == .usageStats { setup.declineUsageStats() }
    }

    /// Re-open a previously skipped step so it can be decided again. A skip
    /// never spent a prompt, so re-deciding simply re-opens exactly one step —
    /// ``activeStep`` picks it back up on its own (it walks every undecided,
    /// unskipped step), and ``finalCheckState`` reverts to ``.pending`` on its
    /// own too (its readiness conjunct at `isReadyForFinalCheck` above already
    /// requires `activeStep == nil`, which this breaks). No-op for a step that
    /// was never skipped, or isn't skippable at all.
    public func reopen(_ step: SetupStep) {
        guard Self.skippableSteps.contains(step), skippedSteps.contains(step) else { return }
        skippedSteps.remove(step)
        Telemetry.log(.permission, "setup_allow", [
            "step": Self.telemetryName(step),
            "outcome": SetupAllowOutcome.skipReopened.rawValue,
        ])
    }

    /// Whether every card is decided AND every required permission's cached
    /// status is granted — the moment the automatic final check runs.
    ///
    /// Two conditions, deliberately different in kind (owner decision
    /// 2026-08-11, tightening the required-only condition after the CTA
    /// appeared live beside a still-undecided Remote Control card):
    ///
    /// - **Every required permission is granted** — the product gate.
    ///   Bluetooth and Remote Control stay outside ``RequiredPermission``, so
    ///   their PERMISSIONS can never hold the check back, and the audit
    ///   re-verifies the required set only.
    /// - **No card is still active** — every walked step is granted,
    ///   auto-passed, or explicitly skipped. A skip is a decision; an
    ///   untouched optional card is not, and the check must never run beside a
    ///   card still offering Allow/Skip.
    ///
    /// The required check is not redundant: `activeStep` only walks from the
    /// re-entry start index, so a required permission GRANTED at entry but
    /// revoked mid-presentation is caught here, not by the walk.
    public var isReadyForFinalCheck: Bool {
        unmetRequiredSteps().isEmpty && activeStep == nil
    }

    /// The required steps still standing in the gate's way — the required
    /// permissions that aren't granted, MINUS a Speaker Sync the user has
    /// explicitly skipped. The skip is the exit: without this filter the step
    /// would be skippable in name only, since its permission would keep the
    /// gate shut from the other side.
    private func unmetRequiredSteps() -> [SetupStep] {
        setup.requiredPermissionsNotGranted()
            .map(Self.step(for:))
            .filter { !($0 == .speakerSync && skippedSteps.contains(.speakerSync)) }
    }

    /// Backing store for ``finalCheckState``. The public read derives
    /// `pending` whenever the flow has regressed out of readiness (a card
    /// re-opened, a required permission dropped), so the row can never claim
    /// a check on a flow that is no longer decided.
    private var finalCheck: SetupFinalCheckState = .pending

    /// The sixth row's state — see ``SetupFinalCheckState``.
    public var finalCheckState: SetupFinalCheckState {
        isReadyForFinalCheck ? finalCheck : .pending
    }

    /// Whether Done may exist at all. The Wispr gate: the button is ABSENT from
    /// the layout until this is true, never present-but-disabled.
    ///
    /// The gate means **the final check passed** (owner decision 2026-08-11,
    /// after telemetry showed five clicks swallowed during an invisible ~2 s
    /// verification): the CTA, the settled finale and its one-shot ripple all
    /// arrive on the check's pass, never before. ``finalCheckState`` already
    /// folds in ``isReadyForFinalCheck``, so a card re-opening or a required
    /// permission dropping closes the gate again on its own.
    public var isDoneAvailable: Bool {
        finalCheckState == .passed
    }

    /// The one audit both verifications run — the silent re-read (it is what
    /// catches a revocation the window-focus refresh deliberately can't); its
    /// own return value uses revocation semantics, so the verdict comes from
    /// the gate check. The trust flag is the two entry points' one difference
    /// — see each caller.
    private func auditVerdict(trustingProvenLocalNetworkGrant: Bool) async -> SetupFlowVerification {
        _ = await setup.auditRequiredPermissions(
            trustingProvenLocalNetworkGrant: trustingProvenLocalNetworkGrant)
        guard let unmet = unmetRequiredSteps().first else { return .complete }
        return .unmet(unmet)
    }

    private func record(_ verdict: SetupFlowVerification) {
        finalCheck = verdict == .complete ? .passed : .pending
    }

    /// The automatic verification behind the sixth row: the SAME audit
    /// ``verifyForDone()`` runs — one machinery, two entry points — recorded
    /// into ``finalCheckState`` so the gate can open. Logs its own named
    /// outcome (`setup_done` + `auto_check_passed`/`auto_check_refused` +
    /// `unmet`), so a live trail shows the check the user watched apart from
    /// the click they made.
    public func runFinalCheck() async -> SetupFlowVerification {
        finalCheck = .running
        // The full audit, Local Network re-browse included: this is the ONE
        // re-proof per gate opening, and the row's spinner is where its cost
        // belongs on screen. The CTA click that follows trusts it.
        let verdict = await auditVerdict(trustingProvenLocalNetworkGrant: false)
        record(verdict)
        switch verdict {
        case .complete:
            Telemetry.log(.permission, "setup_done", ["outcome": "auto_check_passed"])
        case .unmet(let unmet):
            Telemetry.log(.permission, "setup_done", [
                "outcome": "auto_check_refused",
                "unmet": Self.telemetryName(unmet),
            ])
        }
        return verdict
    }

    /// Re-verify everything behind a Done tap: SILENT reads only — never the
    /// audible tone probe, which stays reserved for an explicit Allow tap.
    /// Reports the first still-unmet required step so the UI can snap back to it
    /// with a plain explanation.
    ///
    /// NEAR-INSTANT by construction: the click trusts a PROVEN Local Network
    /// grant instead of re-browsing it (the audit's trust flag). Re-proving
    /// behind the click cost an invisible ~3 s and produced the live "Start
    /// listening took two clicks" in its v7 form — the click's own
    /// verification, 3.2 s wide, with the second click correctly swallowed
    /// inside it. Audio and the helper keep their instant silent reads, and a
    /// grant revoked in Settings still can't sneak past: reaching Settings
    /// and back re-browses via the reactivation `refreshStatuses()`.
    /// Like the Allow path, every verification logs exactly ONE named outcome
    /// (`setup_done` + `outcome`): a live session's misbehaviour should be
    /// readable from the trail — finished, refused (and on what), or a click
    /// the UI's single-flight swallowed (logged there) — instead of guessed at.
    public func verifyForDone() async -> SetupFlowVerification {
        let verdict = await auditVerdict(trustingProvenLocalNetworkGrant: true)
        // A refusal reverts the check row to pending; a pass changes nothing
        // the auto-check hadn't already recorded.
        record(verdict)
        switch verdict {
        case .complete:
            Telemetry.log(.permission, "setup_done", ["outcome": "finished"])
        case .unmet(let unmet):
            Telemetry.log(.permission, "setup_done", [
                "outcome": "refused",
                "unmet": Self.telemetryName(unmet),
            ])
        }
        return verdict
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

    private static func firstUnmetRequiredIndex(in setup: SetupModel,
                                                among steps: [SetupStep]) -> Int? {
        firstUnmetRequiredStep(in: setup).flatMap { steps.firstIndex(of: $0) }
    }
}
