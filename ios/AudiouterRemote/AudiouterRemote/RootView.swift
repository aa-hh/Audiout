// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import AudiouterProtocol

/// The one long-lived session owner for the process: a real
/// ``ConnectionController`` (wrapped in a ``RemoteSession``) plus an
/// optional ``DemoMacSession``. `activeSession` is whichever is current —
/// every tab (`SpeakersView`/`AppsView`/`GroupsView`/`SettingsTabView`)
/// touches only that, through ``MacSessionProtocol``, and never knows or
/// cares which backend it is.
///
/// Demo stays opt-in only, never a fallback (house rule): `demoSession` is
/// nil until `enterDemo()` runs, and the ONLY call site for that is the
/// Connect gate's labeled "Demo system" row (``ConnectGateView``) — which is
/// itself `#if DEBUG`, so demo is a development tool and never ships.
@MainActor
@Observable
final class AppSessionModel {
    let controller: ConnectionController
    let iconStore: AppIconStore
    private let remoteSession: RemoteSession
    private(set) var demoSession: DemoMacSession?

    private(set) var macs: [DiscoveredMac] = []
    private(set) var browserState: MacBrowserState = .idle
    private(set) var onWiFi = true

    /// The Connect gate's one-sentence primer, shown once ever: it explains
    /// what the app is about to go looking for BEFORE any system prompt
    /// appears, so the Local Network alert lands on a reader who already
    /// knows why. While it stands, `start()` is a no-op — browsing (and its
    /// prompt) begins with ``completePrimer()``.
    private(set) var needsPrimer: Bool

    /// Whether the full-screen Connect gate is up instead of the tab shell.
    /// Starts true: with no Mac and no demo there is nothing to control.
    private(set) var showConnectGate = true

    private static let primerSeenKey = "hasSeenConnectPrimer"

    /// How long the gate holds on its arrival junction after a session goes
    /// live, so the connection is acknowledged on the screen the user was
    /// reading rather than vanishing under a tab bar.
    private static let arrivalBeat: Duration = .milliseconds(800)

    private var started = false
    /// First-launch convenience only (T17a): with nothing remembered yet,
    /// exactly one Mac on the network is an unambiguous choice. Fires at
    /// most once per process, so a later explicit `disconnect()` is never
    /// silently re-auto-connected out from under the user.
    private var didAttemptFirstLaunchAutoConnect = false
    /// Held so the next status change can cancel it: an in-flight beat that
    /// outlives its own `.live` would lower the gate on a dead session.
    private var arrivalBeatTask: Task<Void, Never>?

    var activeSession: any MacSessionProtocol { demoSession ?? remoteSession }
    var isDemoActive: Bool { demoSession != nil }
    var lastUsedMacID: String? { controller.lastUsedMacID }

    init(controller: ConnectionController = ConnectionController()) {
        // The smoke test walks the searching junction, so it must never see
        // the primer; `-uitest-primer` is the opposite switch, for a UI test
        // that wants the first-launch screen on a machine that has already
        // stored the flag. It wins, so one launch can ask for both.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uitest-primer") {
            self.needsPrimer = true
        } else if arguments.contains("-uitest-isolated") {
            self.needsPrimer = false
        } else {
            self.needsPrimer = !UserDefaults.standard.bool(forKey: Self.primerSeenKey)
        }

        self.controller = controller
        let iconStore = AppIconStore()
        self.iconStore = iconStore
        self.remoteSession = RemoteSession(controller: controller, iconStore: iconStore)

        controller.setOnMacsChanged { [weak self] macs in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleMacsChanged(macs) } }
        }
        controller.setOnBrowserStateChanged { [weak self] state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.browserState = state } }
        }
        controller.setOnWiFiChanged { [weak self] onWiFi in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onWiFi = onWiFi } }
        }
    }

    /// Idempotent — safe to call from `.task` on every `RootView` body
    /// re-evaluation.
    func start() {
        // A primer launch starts nothing: `RootView`'s `.task` stays
        // unconditional and `completePrimer()` performs the real start, so
        // the Local Network prompt can't beat the sentence that explains it.
        guard !needsPrimer else { return }
        guard !started else { return }
        started = true
        // UI-test isolation: the smoke test walks the Demo system, which
        // needs the deterministic no-Mac empty state. With a real Audiouter
        // on the LAN, browsing would fill the list and the remembered-Mac
        // reconnect would navigate away mid-test (both live-caught once a
        // real Mac existed). Demo mode needs no controller.
        guard !ProcessInfo.processInfo.arguments.contains("-uitest-isolated") else { return }
        controller.start()
    }

    func enterForeground() { controller.enterForeground() }
    func enterBackground() { controller.enterBackground() }

    func connect(to mac: DiscoveredMac) {
        demoSession = nil
        controller.connect(to: mac)
    }

    /// The user hung up, deliberately. This — never a `.closedByUs` status —
    /// is the signal that raises the gate again: `enterBackground()` closes
    /// with the same reason on every trip to the home screen.
    func disconnect() {
        controller.disconnect()
        showConnectGate = true
    }

    /// See the type doc comment — the one place a `DemoMacSession` gets
    /// constructed. Drops any live/pending Mac connection first: exactly one
    /// session is ever active.
    func enterDemo() {
        controller.disconnect()
        // Entering demo IS getting past the intro: without this, leaving the
        // demo would drop the user back on a first-run screen they have
        // already read and acted on.
        markPrimerSeen()
        demoSession = DemoMacSession()
        showConnectGate = false
    }

    func exitDemo() {
        demoSession = nil
        showConnectGate = true
    }

    /// Marks the primer read (once ever) and begins browsing.
    func completePrimer() {
        markPrimerSeen()
        start()
    }

    /// The once-ever flag, without starting anything: `enterDemo()` needs the
    /// primer retired but must not begin browsing.
    private func markPrimerSeen() {
        guard needsPrimer else { return }
        UserDefaults.standard.set(true, forKey: Self.primerSeenKey)
        needsPrimer = false
    }

    /// Debug-only affordance (the row is `#if DEBUG` in `SettingsTabView`):
    /// clears the once-ever flag and puts the gate back on the primer, so the
    /// intro can be reviewed on a device without a reinstall.
    func replayPrimer() {
        UserDefaults.standard.removeObject(forKey: Self.primerSeenKey)
        needsPrimer = true
        showConnectGate = true
    }

    /// The gate's half of the connection story, driven from `RootView` — the
    /// controller's `onConnectionStateChanged` handler is already taken by
    /// ``RemoteSession`` and each `set…` slot holds exactly one closure.
    ///
    /// Only two statuses move the gate. A transient drop after a live
    /// session does NOT: the controller redials with backoff on its own and
    /// the shell's banners already say so, and throwing the user back to a
    /// full-screen gate mid-listen would be the app losing its place, not
    /// reporting a fact.
    func noteConnectionStatusChanged(to status: MacConnectionState) {
        arrivalBeatTask?.cancel()
        arrivalBeatTask = nil

        switch status {
        case .live where showConnectGate:
            arrivalBeatTask = Task { [weak self] in
                try? await Task.sleep(for: Self.arrivalBeat)
                guard !Task.isCancelled, let self, self.activeSession.connectionStatus == .live else { return }
                self.showConnectGate = false
            }
        case .disconnected(let reason) where reason.reconnectClass == .terminal && !isDemoActive:
            showConnectGate = true
        default:
            break
        }
    }

    private func handleMacsChanged(_ macs: [DiscoveredMac]) {
        self.macs = macs
        guard !didAttemptFirstLaunchAutoConnect,
              !isDemoActive,
              controller.lastUsedMacID == nil,
              macs.count == 1,
              let mac = macs.first,
              !mac.isIncompatible
        else { return }
        didAttemptFirstLaunchAutoConnect = true
        connect(to: mac)
    }
}

/// Two screens, never both: the full-screen ``ConnectGateView`` whenever
/// there is neither a live Mac nor a demo, and otherwise the 4-tab shell
/// (T10, wired up in T17a) — Speakers / Apps / Groups / Settings, all
/// sharing one ``AppSessionModel``.
///
/// The gate owns getting connected, so the shell has no "not connected"
/// landing tab to open on any more: it appears already earned, on Speakers.
/// Scene-phase transitions drive the controller's background/foreground
/// lifecycle (teardown while backgrounded, eager reconnect +
/// permission-suspected browser recovery on return) on both screens alike.
struct RootView: View {
    @State private var model = AppSessionModel()
    @State private var selection: Tab = .speakers
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Tab: Hashable {
        case speakers, apps, groups, settings
    }

    var body: some View {
        Group {
            if model.showConnectGate {
                ConnectGateView(
                    session: model.activeSession,
                    macs: model.macs,
                    browserState: model.browserState,
                    onWiFi: model.onWiFi,
                    lastUsedMacID: model.lastUsedMacID,
                    onConnect: model.connect(to:),
                    onDisconnect: model.disconnect,
                    needsPrimer: model.needsPrimer,
                    onCompletePrimer: model.completePrimer,
                    onEnterDemo: model.enterDemo
                )
                .transition(gateTransition)
            } else {
                shell
                    .transition(gateTransition)
            }
        }
        // Warm Signal's gold, everywhere the tint reaches: tab-bar selection,
        // buttons, chevrons, picker menus, toggles. It does NOT reach
        // `Color.accentColor` (which resolves from the app accent — no asset
        // catalog exists, so system blue — and ignores an ancestor tint), so
        // the four explicit `.accentColor` literals in UI/Groups/ are swapped
        // to `WarmSignal.gold` directly.
        .tint(WarmSignal.gold)
        .environment(model.iconStore)
        .task { model.start() }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .snappy(duration: 0.35),
                   value: model.showConnectGate)
        .onChange(of: model.showConnectGate) { _, showingGate in
            if !showingGate { selection = .speakers }
        }
        .onChange(of: model.activeSession.connectionStatus) { _, status in
            model.noteConnectionStatusChanged(to: status)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.enterForeground()
            case .background: model.enterBackground()
            case .inactive: break
            @unknown default: break
            }
        }
    }

    private var shell: some View {
        TabView(selection: $selection) {
            SpeakersView(session: model.activeSession)
                .tabItem { Label("Speakers", systemImage: "speaker.wave.2") }
                .tag(Tab.speakers)

            AppsView(session: model.activeSession)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(Tab.apps)

            GroupsView(session: model.activeSession)
                .tabItem { Label("Groups", systemImage: "rectangle.3.group") }
                .tag(Tab.groups)

            SettingsTabView(
                session: model.activeSession,
                macs: model.macs,
                browserState: model.browserState,
                onWiFi: model.onWiFi,
                lastUsedMacID: model.lastUsedMacID,
                onConnect: model.connect(to:),
                onDisconnect: model.disconnect,
                onExitDemo: model.exitDemo,
                onReplayPrimer: model.replayPrimer
            )
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(Tab.settings)
        }
    }

    private var gateTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }
}

#Preview {
    RootView()
}
