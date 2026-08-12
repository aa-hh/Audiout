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
    /// Set by the searching junction's own `.task`, so it can only elapse
    /// while that junction is actually on screen.
    @State private var searchIsTakingLong = false

    /// How long "Looking for your Mac…" stands alone before the checklist
    /// unfolds under it. Long enough that a normal discovery never shows a
    /// troubleshooting list; short enough that a stuck one doesn't wait.
    private static let searchPatience: Duration = .seconds(8)

    var body: some View {
        ZStack {
            WarmSignal.canvasGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    junction
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, isFullScreen ? 44 : 28)
                        .padding(.bottom, 24)
                }

                if isFullScreen {
                    demoFoot
                        .padding(.horizontal, 22)
                        .padding(.bottom, 18)
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .snappy(duration: 0.35),
                   value: currentJunction)
        .toastOverlay(session.toasts)
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
            HStack(alignment: .top, spacing: 12) {
                JunctionCopy(eyebrow: "Searching", instruction: "Looking for your Mac…")
                SearchPulse()
                    .padding(.top, 4)
            }

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

// MARK: - The search pulse

/// A gold dot breathing while the browser looks. It is the screen's only
/// motion, and it stands still under Reduce Motion rather than being replaced
/// by something else that moves.
private struct SearchPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    var body: some View {
        Circle()
            .fill(WarmSignal.gold)
            .frame(width: 9, height: 9)
            .opacity(lit ? 1 : 0.3)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                       value: lit)
            .onAppear { lit = true }
            .accessibilityHidden(true)
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
