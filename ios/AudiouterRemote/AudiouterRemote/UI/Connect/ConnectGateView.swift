// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import AudiouterProtocol

/// The Connect gate: the whole screen, whenever there is neither a live Mac
/// nor a demo (``RootView``), and the same view again as the Settings tab's
/// "Switch Mac…" sheet.
///
/// It is wayfinding, not a settings page. A general Mac user should get from
/// launch to a live connection without reading: exactly ONE junction shows at
/// a time, it says the one thing to do next in plain speech, and it carries at
/// most one gold action — the single live thing to press. Console voice is
/// allowed in the eyebrow and nowhere else, because the eyebrow is the only
/// text nobody has to read to proceed.
///
/// Connection-management state — the browsed Mac list, the browser's
/// idle/browsing/permissionSuspected state, Wi-Fi reachability — is
/// deliberately NOT part of ``MacSessionProtocol``: that protocol is
/// command-and-snapshot only and shared verbatim with the three shell tabs.
/// This view takes that state (and the connect/disconnect/demo actions)
/// alongside `session` from whatever owns the ``ConnectionController``
/// (`RootView`), rather than smuggling it through the shared protocol.
struct ConnectGateView: View {
    let session: any MacSessionProtocol
    let macs: [DiscoveredMac]
    let browserState: MacBrowserState
    let onWiFi: Bool
    /// The Mac the controller is dialing or would auto-reconnect to — the one
    /// the progress and approval junctions can name.
    let lastUsedMacID: String?
    let onConnect: (DiscoveredMac) -> Void
    let onDisconnect: () -> Void

    /// Full screen, or the Settings tab's switch sheet. The sheet drops the
    /// primer and the Demo foot: its reader already has a session, so neither
    /// junction is a decision they are at.
    var isFullScreen = true
    var needsPrimer = false
    var onCompletePrimer: () -> Void = {}
    var onEnterDemo: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Set by the searching junction's own `.task`, so it can only elapse
    /// while that junction is actually on screen.
    @State private var searchIsTakingLong = false

    /// The waves stand down at accessibility text sizes: the copy alone runs
    /// most of the screen there, and the room they want is the room it needs.
    private var typeSizeAllowsWaves: Bool { typeSize < .accessibility1 }

    /// Whether the waves are what is on screen right now — the one junction
    /// that wants the whole viewport to lay itself out in.
    private var isShowingSearchWaves: Bool {
        currentJunction == .searching && !searchIsTakingLong && typeSizeAllowsWaves
    }

    /// How long "Looking for your Mac…" stands alone before the checklist
    /// unfolds under it. Long enough that a normal discovery never shows a
    /// troubleshooting list; short enough that a stuck one doesn't wait.
    private static let searchPatience: Duration = .seconds(8)

    var body: some View {
        ZStack {
            WarmSignal.canvasGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                GeometryReader { viewport in
                    ScrollView {
                        junction
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                            .padding(.top, isFullScreen ? 44 : 28)
                            .padding(.bottom, 24)
                            // The waves centre in whatever the copy leaves, so
                            // their junction claims the viewport rather than
                            // sizing to content and stacking tight under the
                            // headline with the rest of the screen left bare.
                            .frame(minHeight: isShowingSearchWaves ? viewport.size.height : nil,
                                   alignment: .top)
                            .animation(motionCurve, value: searchIsTakingLong)
                    }
                }

                if isFullScreen {
                    demoFoot
                        .padding(.horizontal, 22)
                        .padding(.bottom, 18)
                }
            }
        }
        .animation(motionCurve, value: currentJunction)
        .toastOverlay(session.toasts)
    }

    /// One tempo for every change this screen makes.
    private var motionCurve: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .snappy(duration: 0.35)
    }

    // MARK: - Which junction

    /// The one junction on screen. Ordering is the whole design: the primer
    /// outranks everything because it precedes the permission prompt; Wi-Fi
    /// outranks browsing because nothing can be found without it; and a live
    /// connection attempt outranks browse state, because what the app is
    /// doing right now beats what it can see.
    private enum Junction: Equatable {
        case primer
        case noWiFi
        case connecting
        case awaitingApproval
        case denied
        case promptTimedOut
        case arrived
        case localNetwork
        case searching
        case oneMac
        case severalMacs
    }

    private var currentJunction: Junction {
        if isFullScreen, needsPrimer { return .primer }
        if !onWiFi { return .noWiFi }

        switch session.connectionStatus {
        case .connecting, .handshaking: return .connecting
        case .awaitingApproval: return .awaitingApproval
        case .live:
            // The sheet's reader came here to switch Macs, so a live session
            // is the thing they are leaving, not a destination: it falls
            // through to the browse junctions, where the connected Mac shows
            // as connected and the others stay dialable.
            if isFullScreen { return .arrived }
        case .idle: break
        case .disconnected:
            switch session.connectionStatus.approvalStatus {
            case .some(.denied): return .denied
            case .some(.promptTimedOut): return .promptTimedOut
            default: break
            }
        }

        if browserState == .permissionSuspected { return .localNetwork }
        if macs.isEmpty { return .searching }
        // An incompatible Mac has no Connect to offer, and neither does the
        // one already connected, so a lone one of either goes to the list,
        // which already knows how to show a Mac it can't dial.
        if macs.count == 1, !macs[0].isIncompatible, macs[0].id != connectedMacID { return .oneMac }
        return .severalMacs
    }

    /// The Mac the live session is with, if any — there is one connection at
    /// a time, so the last-used id IS the live one.
    private var connectedMacID: String? {
        session.connectionStatus == .live ? lastUsedMacID : nil
    }

    @ViewBuilder
    private var junction: some View {
        switch currentJunction {
        case .primer:
            VStack(alignment: .leading, spacing: 24) {
                JunctionCopy(
                    eyebrow: "Audiouter",
                    instruction: "Audiouter finds your Mac over your home Wi-Fi"
                )
                GoldAction(title: "Find my Mac", action: onCompletePrimer)
            }

        case .noWiFi:
            JunctionCopy(
                eyebrow: "No Wi-Fi",
                instruction: "Join the same Wi-Fi network as your Mac"
            )

        case .connecting:
            VStack(alignment: .leading, spacing: 20) {
                JunctionCopy(eyebrow: "Connecting", instruction: dialingMacName)
                ProgressView()
            }

        case .awaitingApproval:
            VStack(alignment: .leading, spacing: 24) {
                JunctionCopy(
                    eyebrow: "Approval",
                    instruction: "Go to \(dialingMacName) and click Allow",
                    supporting: ApprovalStatus.waitingForApproval.guidance
                )
                QuietAction(title: "Cancel", action: onDisconnect)
            }

        case .denied:
            // Terminal on purpose: no retry button anywhere. The Mac
            // remembers the denial, so redialing is harassment rather than
            // recovery, and the guidance is the only way out.
            JunctionCopy(
                eyebrow: "Not allowed",
                instruction: ApprovalStatus.denied.headline,
                supporting: ApprovalStatus.denied.guidance
            )

        case .promptTimedOut:
            VStack(alignment: .leading, spacing: 24) {
                JunctionCopy(
                    eyebrow: "No answer",
                    instruction: ApprovalStatus.promptTimedOut.headline,
                    supporting: ApprovalStatus.promptTimedOut.guidance
                )
                GoldAction(title: "Try Again", action: retryLastMac)
            }

        case .arrived:
            JunctionCopy(
                eyebrow: "Connected",
                instruction: session.snapshot?.serverName ?? dialingMacName,
                instructionInGold: true
            )

        case .localNetwork:
            VStack(alignment: .leading, spacing: 24) {
                JunctionCopy(
                    eyebrow: "Local network",
                    instruction: "Local Network Access Needed",
                    // Verbatim from the old PermissionDeniedView: the
                    // detector is a HEURISTIC (iOS never reports the grant),
                    // so a user who simply hasn't answered the prompt yet
                    // must not be told they denied it.
                    supporting: "This app may not be allowed to find devices on your Wi-Fi network. If you haven't answered the \u{201C}Local Network\u{201D} prompt yet, this clears itself as soon as you do \u{2014} otherwise, allow it in Settings."
                )
                GoldAction(title: "Open Settings", action: openSystemSettings)
                    .accessibilityHint("Opens this app's page in the Settings app, where Local Network access can be turned on.")
            }

        case .searching:
            searchingJunction

        case .oneMac:
            VStack(alignment: .leading, spacing: 24) {
                JunctionCopy(eyebrow: "Mac found", instruction: macs[0].name)
                GoldAction(title: "Connect") { onConnect(macs[0]) }
            }

        case .severalMacs:
            VStack(alignment: .leading, spacing: 20) {
                JunctionCopy(eyebrow: "Macs on your network", instruction: "Choose your Mac")
                VStack(spacing: 10) {
                    ForEach(macs) { mac in
                        MacBand(mac: mac, isConnectedHere: mac.id == connectedMacID) { onConnect(mac) }
                    }
                }
            }
        }
    }

    // MARK: - Searching

    private var searchingJunction: some View {
        VStack(alignment: .leading, spacing: 24) {
            JunctionCopy(eyebrow: "Searching", instruction: "Looking for your Mac…")

            if searchIsTakingLong {
                // The App Store review requirement (T19): a reviewer with no
                // Mac around must be able to read this and know what to
                // check. It waits for the pause that means it's needed.
                VStack(alignment: .leading, spacing: 14) {
                    checklistStep(1, "Make sure this iPhone and your Mac are on the same Wi-Fi network.")
                    checklistStep(2, "Open Audiouter on your Mac and keep it running.")
                    checklistStep(3, "In Audiouter's Settings › General on your Mac, turn on \u{201C}Allow control from iPhone on this network.\u{201D}")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(cornerRadius: WarmSignal.Radius.panel)
                .transition(.opacity)
            } else if typeSizeAllowsWaves {
                // The waves give way to the checklist rather than sitting
                // above it: once there is something useful to say, saying it
                // beats atmosphere.
                SearchWaves()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: Self.searchPatience)
            // Cancelled means the junction left before the patience elapsed;
            // setting the flag then would show the checklist at t=0 on the
            // next visit, which is the opposite of waiting for the pause.
            guard !Task.isCancelled else { return }
            searchIsTakingLong = true
        }
        .onDisappear { searchIsTakingLong = false }
    }

    /// Numbered because the order is the information: a reader who does step
    /// 2 first has nothing to look at.
    private func checklistStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .microLabel()
                .foregroundStyle(WarmSignal.label3)
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(WarmSignal.label2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Demo foot

    /// The app's ONE `enterDemo` call site (house rule: opt-in only, never a
    /// fallback). It sits under every junction at a whisper, and steps up to
    /// a full band at the same moment the checklist unfolds — the point where
    /// "try it without a Mac" stops being a curiosity and starts being the
    /// useful offer.
    private var demoFoot: some View {
        Group {
            if demoIsPromoted {
                demoRow.glassPanel(cornerRadius: WarmSignal.Radius.row)
            } else {
                demoRow
            }
        }
    }

    private var demoIsPromoted: Bool { searchIsTakingLong && currentJunction == .searching }

    private var demoRow: some View {
        Button(action: onEnterDemo) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.tv")
                    .foregroundStyle(WarmSignal.label2)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Demo system")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(WarmSignal.label)
                    Text("Try the app without a Mac")
                        .font(.system(size: 13))
                        .foregroundStyle(WarmSignal.label2)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: WarmSignal.hitTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demo system")
        .accessibilityHint("Double tap to try a simulated Mac with sample speakers")
    }

    // MARK: - Helpers

    /// The Mac being dialed, by name. There is one connection at a time, so
    /// the last-used id IS the one in flight.
    private var dialingMacName: String {
        macs.first { $0.id == lastUsedMacID }?.name ?? "your Mac"
    }

    private func retryLastMac() {
        guard let lastUsedMacID, let mac = macs.first(where: { $0.id == lastUsedMacID }) else { return }
        onConnect(mac)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Junction copy

/// Every junction's text, in one voice: the eyebrow says where you are, the
/// instruction says what to do, and the supporting line is only ever the
/// detail that instruction can't carry.
private struct JunctionCopy: View {
    let eyebrow: String
    let instruction: String
    /// The arrival junction's acknowledgement — the one place the Mac's name
    /// itself is the gold, because there is no action to spend it on.
    var instructionInGold = false
    var supporting: String?

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow)
                .microLabel()
                .foregroundStyle(WarmSignal.label2)

            Text(instruction)
                .font(.system(size: titleSize, weight: .bold))
                .tracking(-0.7)
                // Raw `gold`, not `goldText`: this renders at 32 pt, above
                // the large-text threshold the darkened variant exists for.
                .foregroundStyle(instructionInGold ? WarmSignal.gold : WarmSignal.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let supporting {
                Text(supporting)
                    .font(.system(size: bodySize))
                    .foregroundStyle(WarmSignal.label2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Actions

/// Ink on a gold fill. Both golds are light enough that the app's own dark
/// ground reads on them (5.0:1 light, 10.0:1 dark) where white does not
/// (3.3:1 in light), so the label is dark in both appearances — this is a
/// fill, not a surface, and it does not follow the ground.
private let goldInk = Color(red: 0x16 / 255, green: 0x13 / 255, blue: 0x0F / 255)

/// The one live action a junction gets, and the only gold on the screen.
private struct GoldAction: View {
    let title: String
    let action: () -> Void

    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 17

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(goldInk)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: WarmSignal.hitTarget)
                .background(
                    RoundedRectangle(cornerRadius: WarmSignal.Radius.control, style: .continuous)
                        .fill(WarmSignal.gold)
                )
        }
        .buttonStyle(.plain)
    }
}

/// A junction's subordinate way out (Cancel). Glass, never gold: it is the
/// action the screen is not asking for.
private struct QuietAction: View {
    let title: String
    let action: () -> Void

    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 16

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: titleSize, weight: .medium))
                .foregroundStyle(WarmSignal.label2)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(minHeight: WarmSignal.hitTarget)
                .glassPanel(cornerRadius: WarmSignal.Radius.control)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Several Macs

/// One discovered Mac, as a band. Incompatible Macs (refuse-forward: this Mac
/// speaks a newer protocol than we do) are shown, never dialed — the band
/// explains that updating the app, not the Mac, is what would fix it.
private struct MacBand: View {
    let mac: DiscoveredMac
    /// The Mac the live session is already with: shown as connected, and
    /// not dialable — the only thing to do with it here is leave it alone.
    var isConnectedHere = false
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(WarmSignal.label2)
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(mac.isIncompatible ? WarmSignal.label3 : WarmSignal.label)
                    Text(statusText)
                        .font(.system(size: 13))
                        .foregroundStyle(mac.isIncompatible ? WarmSignal.caution : WarmSignal.label2)
                }

                Spacer(minLength: 8)

                if isConnectedHere {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(WarmSignal.gold)
                        .accessibilityHidden(true)
                } else if !mac.isIncompatible {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WarmSignal.label3)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: WarmSignal.hitTarget, alignment: .leading)
            .glassPanel(cornerRadius: WarmSignal.Radius.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(mac.isIncompatible || isConnectedHere)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mac.name). \(statusText)")
        .accessibilityAddTraits(isConnectedHere ? [.isSelected] : [])
    }

    private var statusText: String {
        if mac.isIncompatible { return "Update this app to connect" }
        if isConnectedHere { return "Connected" }
        return "Tap to connect"
    }
}

// MARK: - The search waves

/// The screen below "Looking for your Mac…", given to the one thing the app
/// is doing: calling across the house. A gold core with rings leaving it on a
/// slow even beat — Warm Signal's own signal, going out and not yet answered.
///
/// It claims NO progress. Nothing fills, counts, or estimates, because a
/// Bonjour browse cannot say how much is left either; the rings say "still
/// listening" and stop there. That is also why the far end of each ring is a
/// fade rather than an arrival: nothing has arrived.
///
/// Decorative and hidden from VoiceOver — the headline above already carries
/// the whole state in words. It holds still under Reduce Motion rather than
/// swapping in something else that moves.
private struct SearchWaves: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// One ring's whole journey, core to edge. Slow on purpose: the honest
    /// mood here is patience — most of the time the Mac is simply not awake
    /// yet, and a brisk sweep would tell the reader to expect an answer.
    private static let period: Double = 2.8
    /// Rings in flight at once, evenly spaced along the period.
    private static let ringCount = 3
    private static let coreDiameter: CGFloat = 10
    private static let lineWidth: CGFloat = 2
    /// The beat Reduce Motion rests on. Not 0: a ring's alpha starts there, so
    /// phase 0 would rest one of the three invisible and pose the other two.
    private static let stillPhase: Double = 0.22
    /// Height ceiling, so the field stays a field and not a full screen of
    /// circles on a tall phone. Below it the square simply takes the width,
    /// which is what binds on a small one.
    private static let maxHeight: CGFloat = 360

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { context, size in
                draw(context, size: size, phase: phase(at: timeline.date))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: Self.maxHeight)
        .accessibilityHidden(true)
    }

    private func phase(at date: Date) -> Double {
        guard !reduceMotion else { return Self.stillPhase }
        return (date.timeIntervalSinceReferenceDate / Self.period)
            .truncatingRemainder(dividingBy: 1)
    }

    /// Peak ring alpha, per ground. Dark takes more: gold fading toward a
    /// near-black canvas loses its edge much faster than the same fade toward
    /// cream, so matched alphas leave the dark rings a stop quieter.
    private var ringPeak: Double { scheme == .dark ? 0.72 : 0.62 }

    private func draw(_ context: GraphicsContext, size: CGSize, phase: Double) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let coreRadius = Self.coreDiameter / 2
        let maxRadius = min(size.width, size.height) / 2 - Self.lineWidth
        guard maxRadius > coreRadius else { return }

        for index in 0..<Self.ringCount {
            let progress = (phase + Double(index) / Double(Self.ringCount))
                .truncatingRemainder(dividingBy: 1)
            // Ease-out travel: a wave spreads fastest as it leaves and slows as
            // it widens, which is also what stops the rings bunching at the rim.
            let radius = coreRadius + (maxRadius - coreRadius) * pow(progress, 0.72)
            // In over the first sliver so no ring pops into being at the core;
            // out across the whole journey so the rim is a fade, not a stop.
            let alpha = ringPeak * min(1, progress / 0.14) * pow(1 - progress, 1.5)
            context.stroke(
                Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .color(WarmSignal.gold.opacity(alpha)),
                lineWidth: Self.lineWidth)
        }

        // The core brightens as each ring leaves it, so the rings come FROM
        // somewhere rather than simply existing.
        let breath = 0.86 + 0.14 * cos(phase * Double(Self.ringCount) * 2 * .pi)
        context.fill(
            Path(ellipseIn: CGRect(x: centre.x - coreRadius, y: centre.y - coreRadius,
                                   width: Self.coreDiameter, height: Self.coreDiameter)),
            with: .color(WarmSignal.gold.opacity(breath)))
    }
}

// MARK: - Previews

/// Preview-only stand-in for connection states `DemoMacSession` can't
/// produce (it hardcodes `.live`) — same idiom as `SpeakersView`'s
/// `PreviewSession`, kept local to this file.
@MainActor
private final class PreviewConnectionSession: MacSessionProtocol {
    var snapshot: Snapshot?
    var connectionStatus: MacConnectionState
    let isDemo: Bool
    let toasts = ToastCenter()

    init(snapshot: Snapshot? = nil, connectionStatus: MacConnectionState, isDemo: Bool = false) {
        self.snapshot = snapshot
        self.connectionStatus = connectionStatus
        self.isDemo = isDemo
    }

    func setDeviceSelected(id: String, selected: Bool) {}
    func retryConnection(id: String) {}
    func setMainOut(_ state: MainOutState) {}
    func setDeviceVolume(id: String, volume: Int, isFinal: Bool) {}
    func setDeviceMuted(id: String, muted: Bool) {}
    func setMainOutMasterVolume(_ volume: Int, isFinal: Bool) {}
    func setMainOutMuted(_ muted: Bool) {}
    func createGroup(name: String, memberIDs: [String], iconSymbolName: String?) {}
    func updateGroup(_ group: GroupState) {}
    func deleteGroup(id: String) {}
    func setGroupMuted(id: String, muted: Bool) {}
    func addAppRoute(bundleID: String, displayName: String) {}
    func removeAppRoute(bundleID: String) {}
    func setAppDestination(bundleID: String, kind: String, deviceID: String?) {}
    func setAppVolume(bundleID: String, volume: Int, isFinal: Bool) {}
    func setConnectVolume(_ volume: Int, isFinal: Bool) {}
    func setStartBufferMs(_ ms: Int) {}
}

private func previewMac(name: String, isIncompatible: Bool = false) -> DiscoveredMac {
    DiscoveredMac(
        id: "\(name)._audiouter._tcplocal.",
        endpoint: .service(name: name, type: CompanionProto.serviceType, domain: "local.", interface: nil),
        name: name,
        protoVersion: isIncompatible ? CompanionProto.version + 1 : CompanionProto.version,
        isIncompatible: isIncompatible
    )
}

@MainActor
private func previewGate(
    status: MacConnectionState = .idle,
    macs: [DiscoveredMac] = [],
    browserState: MacBrowserState = .browsing,
    onWiFi: Bool = true,
    lastUsedMacID: String? = nil,
    needsPrimer: Bool = false
) -> ConnectGateView {
    ConnectGateView(
        session: PreviewConnectionSession(connectionStatus: status),
        macs: macs,
        browserState: browserState,
        onWiFi: onWiFi,
        lastUsedMacID: lastUsedMacID,
        onConnect: { _ in },
        onDisconnect: {},
        needsPrimer: needsPrimer,
        onCompletePrimer: {},
        onEnterDemo: {}
    )
}

#Preview("Primer") {
    previewGate(needsPrimer: true)
}

#Preview("Searching") {
    previewGate()
}

#Preview("One Mac found") {
    previewGate(macs: [previewMac(name: "Alec's Mac")])
}

#Preview("Several Macs") {
    previewGate(macs: [previewMac(name: "Alec's Mac"),
                       previewMac(name: "Living Room iMac", isIncompatible: true)])
}

#Preview("Awaiting approval") {
    let mac = previewMac(name: "Alec's Mac")
    return previewGate(status: .awaitingApproval, macs: [mac], lastUsedMacID: mac.id)
}

#Preview("Denied") {
    let mac = previewMac(name: "Alec's Mac")
    return previewGate(
        status: .disconnected(.goodbye(CompanionGoodbyeReason.notApproved)),
        macs: [mac], lastUsedMacID: mac.id
    )
}

#Preview("Prompt timed out") {
    let mac = previewMac(name: "Alec's Mac")
    return previewGate(
        status: .disconnected(.goodbye(CompanionGoodbyeReason.approvalTimedOut)),
        macs: [mac], lastUsedMacID: mac.id
    )
}

#Preview("Local Network") {
    previewGate(browserState: .permissionSuspected)
}

#Preview("No Wi-Fi") {
    previewGate(browserState: .idle, onWiFi: false)
}
