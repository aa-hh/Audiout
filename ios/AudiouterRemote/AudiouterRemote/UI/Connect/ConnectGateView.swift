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

    /// The field stands down at accessibility text sizes, on the primer and
    /// the searching junction alike: the copy alone runs most of the screen
    /// there, and the room the light wants is the room it needs.
    private var typeSizeAllowsField: Bool { typeSize < .accessibility1 }

    /// Whether the waves are what is on screen right now — the one junction
    /// that wants the whole viewport to lay itself out in.
    private var isShowingSearchWaves: Bool {
        currentJunction == .searching && typeSizeAllowsField
    }

    private var isPrimer: Bool { currentJunction == .primer }

    /// How long "Looking for your Mac…" stands alone before the checklist
    /// unfolds under it. Long enough that a normal discovery never shows a
    /// troubleshooting list; short enough that a stuck one doesn't wait.
    private static let searchPatience: Duration = .seconds(8)

    var body: some View {
        ZStack {
            WarmSignal.canvasGradient.ignoresSafeArea()

            // The intro's field is the screen, not a panel on it: it runs edge
            // to edge behind the name and the way in. At accessibility text
            // sizes it stands down and the plain canvas is the ground.
            if isPrimer, typeSizeAllowsField {
                RoomField(tuning: .intro).ignoresSafeArea()
            }

            VStack(spacing: 0) {
                GeometryReader { viewport in
                    ScrollView {
                        junction
                            .frame(maxWidth: .infinity, alignment: isPrimer ? .center : .leading)
                            .padding(.horizontal, 22)
                            .padding(.top, isFullScreen ? 44 : 28)
                            .padding(.bottom, 24)
                            // The waves centre in whatever the copy leaves, so
                            // their junction claims the viewport rather than
                            // sizing to content and stacking tight under the
                            // headline with the rest of the screen left bare.
                            // The primer claims it to centre the mark and the
                            // name in it — and because the caption and the
                            // button sit BELOW this scroll area, centring here
                            // already lands the block a little above the
                            // screen's true middle, which is where it wants to
                            // be under a bottom action.
                            .frame(minHeight: isShowingSearchWaves || isPrimer ? viewport.size.height : nil,
                                   alignment: isPrimer ? .center : .top)
                            .animation(motionCurve, value: searchIsTakingLong)
                    }
                }

                if isPrimer {
                    // Bottom-pinned, above the safe area: on the one screen
                    // with a single thing to do, the thing to do is under the
                    // thumb rather than under the sentence. The mechanism line
                    // rides with it rather than with the name, because it is
                    // priming the permission prompt this button raises — it
                    // belongs where the tap happens, not where the app is
                    // introduced.
                    VStack(spacing: 14) {
                        Text("It finds Audiouter running on your Mac, over your home Wi-Fi.")
                            .font(.footnote)
                            .foregroundStyle(WarmSignal.label2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        GoldGlassAction(title: "Find My Mac", action: onCompletePrimer)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
                }

                #if DEBUG
                // Debug builds only: the Demo system is a development tool and
                // does not ship. It never appears on the primer either — that
                // screen is one thing to do, and this is not it.
                if isFullScreen, !isPrimer {
                    demoFoot
                        .padding(.horizontal, 22)
                        .padding(.bottom, 18)
                }
                #endif
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
            // The app's first screen, so it introduces the app rather than
            // asking anything: its own icon as the mark, the name at
            // instruction size, the one line that says what it does, and no
            // eyebrow — there is nowhere else to be. The mechanism line and the
            // action are pinned to the bottom of the screen, not here.
            VStack(spacing: 22) {
                AppIconMark()
                JunctionCopy(
                    instruction: "Audiouter",
                    supporting: "Control your Mac's speakers from this iPhone.",
                    isCentered: true
                )
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

            if typeSizeAllowsField {
                // The checklist unfolds on glass OVER the waves, which keep
                // running underneath: the browse is still going while the list
                // is read, and the field is what says so.
                ZStack {
                    SearchWaves()

                    if searchIsTakingLong {
                        searchChecklist
                            .padding(16)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchIsTakingLong {
                // No waves at accessibility sizes, so the checklist takes the
                // slot on its own.
                searchChecklist
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

    /// The App Store review requirement (T19): a reviewer with no Mac around
    /// must be able to read this and know what to check. It waits for the
    /// pause that means it's needed.
    ///
    /// It sits on live, moving content, which is what the system's Liquid
    /// Glass is for; below the OS that has it, the app's own glass panel is
    /// the same idea with a flat material.
    @ViewBuilder
    private var searchChecklist: some View {
        let rows = VStack(alignment: .leading, spacing: 14) {
            checklistStep(1, "Make sure this iPhone and your Mac are on the same Wi-Fi network.")
            checklistStep(2, "Open Audiouter on your Mac and keep it running.")
            checklistStep(3, "In Audiouter's Settings › General on your Mac, turn on \u{201C}Allow control from iPhone on this network.\u{201D}")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)

        if #available(iOS 26.0, *) {
            rows.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: WarmSignal.Radius.panel, style: .continuous))
        } else {
            rows.glassPanel(cornerRadius: WarmSignal.Radius.panel)
        }
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

    #if DEBUG
    /// The app's ONE `enterDemo` call site (house rule: opt-in only, never a
    /// fallback), and a DEBUG-ONLY one: the Demo system is a development tool
    /// that never ships. It sits under every junction it is offered on at a
    /// whisper, and steps up to a full band at the same moment the checklist
    /// unfolds — the point where "try it without a Mac" stops being a
    /// curiosity and starts being the useful offer.
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
        .buttonStyle(PressFade())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demo system")
        .accessibilityHint("Double tap to try a simulated Mac with sample speakers")
    }
    #endif

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

// MARK: - The mark

/// The app's own icon on the primer, home-screen style: the squircle at the
/// size iOS draws it, with a shadow so it stands ON the field rather than being
/// printed into it.
///
/// It draws its own copy of the artwork (`AppIconMark.png`) rather than the
/// app icon, because the app icon is not loadable as an image on device — see
/// `iconImage` for why. If that copy ever fails to load there is nothing
/// honest to draw, so nothing is drawn — a stand-in mark would be the app
/// introducing itself as something it isn't.
private struct AppIconMark: View {
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .largeTitle) private var side: CGFloat = 100

    var body: some View {
        if let icon = Self.iconImage {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                // The iOS squircle at this size: ~22 pt on 100 pt, held as a
                // ratio so it stays the same shape when the type scale grows it.
                .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0.12),
                        radius: scheme == .dark ? 20 : 14,
                        y: 8)
                // The name below carries it; VoiceOver reading "image" here
                // would only delay the sentence that says what the app is.
                .accessibilityHidden(true)
        }
    }

    /// Computed, not stored: `UIImage(named:)` keeps its own cache, and a
    /// static stored image would be shared mutable state to reason about.
    ///
    /// This loads a plain PNG file resource, NOT the app icon. Asking for the
    /// icon by its `CFBundleIconName` crashed the app on a real phone with
    /// `NSInternalInconsistencyException: Need an imageRef`: on device that
    /// name resolves to an app-icon rendition inside `Assets.car`, which is a
    /// non-nil `UIImage` with no backing `CGImage`, so drawing it throws. The
    /// simulator returns a real bitmap for the same call, which is why it only
    /// ever crashed on hardware.
    ///
    /// So the `cgImage` check is the point: non-nil is not the same as
    /// renderable, and an `if let` alone does not catch this. Do not simplify
    /// it away — nil here just renders nothing, which beats a crash.
    ///
    /// `AppIconMark.png` is generated from `Audiouter.icon` (the Icon Composer
    /// source in this same folder). To regenerate: build for a device, then
    /// pull the appearance-neutral 1024x1024 `Audiouter` rendition out of the
    /// built `Assets.car` (CoreUI's `CUICatalog.imagesWithName:`) and
    /// downscale it to 512 px.
    private static var iconImage: UIImage? {
        guard let icon = UIImage(named: "AppIconMark"), icon.cgImage != nil else { return nil }
        return icon
    }
}

// MARK: - Junction copy

/// Every junction's text, in one voice: the eyebrow says where you are, the
/// instruction says what to do, and the supporting line is only ever the
/// detail that instruction can't carry.
private struct JunctionCopy: View {
    /// Absent on the primer alone: it is the app's first screen, and "where you
    /// are" is not a question anyone has there yet.
    var eyebrow: String?
    let instruction: String
    /// The arrival junction's acknowledgement — the one place the Mac's name
    /// itself is the gold, because there is no action to spend it on.
    var instructionInGold = false
    var supporting: String?
    /// The primer alone: its block is a title card under the app's mark, not a
    /// junction's left-aligned instruction.
    var isCentered = false

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 16

    var body: some View {
        VStack(alignment: isCentered ? .center : .leading, spacing: 12) {
            if let eyebrow {
                Text(eyebrow)
                    .microLabel()
                    .foregroundStyle(WarmSignal.label2)
            }

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
        .multilineTextAlignment(isCentered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: isCentered ? .center : .leading)
    }
}

// MARK: - Actions

/// The shared on-accent ink: the label colour for every gold action in the
/// app, the first-run one included. Both golds are light enough that the app's
/// own dark ground reads on them (5.0:1 light, 10.0:1 dark) where white does
/// not (3.3:1 in light), so the label is dark in both appearances — gold is a
/// fill, not a surface, and it does not follow the ground.
private let goldInk = Color(red: 0x16 / 255, green: 0x13 / 255, blue: 0x0F / 255)

/// The primer CTA's fill: one value in BOTH appearances — dark `WarmSignal.gold`,
/// which is light `WarmSignal.glow` (owner call: the brighter gold is more
/// inviting on the intro's green field, and the dark ink measures ~10:1 on it
/// either way). Every later GoldAction stays on the themed `WarmSignal.gold`.
private let primerGold = Color(red: 0xE8 / 255, green: 0xB8 / 255, blue: 0x4B / 255)

/// The one live action a junction gets, and the only gold on the screen.
///
/// A capsule, like the first-run action it follows: the shape of the button on
/// screen one is the shape of every button after it.
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
                .background(Capsule(style: .continuous).fill(WarmSignal.gold))
        }
        .buttonStyle(.plain)
    }
}

/// The intro's way in: the app's gold, as the system's Liquid Glass over the
/// field's light — an object standing ON the room rather than a hole cut out
/// of it, which is exactly what live moving content asks for. The system's own
/// interactive glass carries the press. Below the OS that has it, the same
/// capsule in flat gold with a hairline edge, and ``PressFade`` for the press.
private struct GoldGlassAction: View {
    let title: String
    let action: () -> Void

    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 17

    private var shape: Capsule { Capsule(style: .continuous) }

    private var label: some View {
        Text(title)
            .font(.system(size: titleSize, weight: .semibold))
            .foregroundStyle(goldInk)
            .lineLimit(1)
            // The capsule is pinned to the bottom, so at accessibility sizes
            // the label gives way rather than pushing the screen off it.
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: WarmSignal.hitTarget)
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                label.glassEffect(.regular.tint(primerGold).interactive(), in: shape)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: action) {
                label
                    .background(shape.fill(primerGold))
                    .overlay(shape.strokeBorder(WarmSignal.glassEdge, lineWidth: 0.5))
            }
            .buttonStyle(PressFade())
        }
    }
}

/// A press the finger can see on a fill that has no other state to show.
private struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
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
/// is doing: calling across the house. The intro's room, in gold and quieter:
/// wavefronts leaving ONE source at the centre and fading as they cross —
/// Warm Signal's own signal, going out and not yet answered.
///
/// It claims NO progress. Nothing fills, counts, or estimates, because a
/// Bonjour browse cannot say how much is left either; the fronts say "still
/// listening" and stop there. That is also why each front ends in a fade
/// rather than an arrival: nothing has arrived.
///
/// The height ceiling keeps it a field rather than a full screen of light on a
/// tall phone; below it the square simply takes the width, which is what binds
/// on a small one.
private struct SearchWaves: View {
    var body: some View {
        RoomField(tuning: .search)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 360)
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
