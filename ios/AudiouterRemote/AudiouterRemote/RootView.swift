// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import Observation
import AudiouterProtocol

/// The one long-lived session owner for the process: a real
/// ``ConnectionController`` (wrapped in a ``RemoteSession``) plus an
/// optional ``DemoMacSession``. `activeSession` is whichever is current —
/// every tab (`SpeakersView`/`AppsView`/`GroupsView`/`ConnectionTabView`)
/// touches only that, through ``MacSessionProtocol``, and never knows or
/// cares which backend it is.
///
/// Demo stays opt-in only, never a fallback (house rule): `demoSession` is
/// nil until `enterDemo()` runs, and the ONLY call site for that is the
/// Connection tab's labeled "Demo system" row (``MacListView``).
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

    private var started = false
    /// First-launch convenience only (T17a): with nothing remembered yet,
    /// exactly one Mac on the network is an unambiguous choice. Fires at
    /// most once per process, so a later explicit `disconnect()` is never
    /// silently re-auto-connected out from under the user.
    private var didAttemptFirstLaunchAutoConnect = false

    var activeSession: any MacSessionProtocol { demoSession ?? remoteSession }
    var isDemoActive: Bool { demoSession != nil }
    var isConnected: Bool { activeSession.connectionStatus == .live }
    var lastUsedMacID: String? { controller.lastUsedMacID }

    init(controller: ConnectionController = ConnectionController()) {
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

    func disconnect() {
        controller.disconnect()
    }

    /// See the type doc comment — the one place a `DemoMacSession` gets
    /// constructed. Drops any live/pending Mac connection first: exactly one
    /// session is ever active.
    func enterDemo() {
        controller.disconnect()
        demoSession = DemoMacSession()
    }

    func exitDemo() {
        demoSession = nil
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

/// The 4-tab shell (T10, wired up in T17a): Speakers / Apps / Groups /
/// Connection, all sharing one ``AppSessionModel``. Lands on the Connection
/// tab by default (nothing to control until a Mac — or Demo — is chosen);
/// the first time the session goes live while the user is still sitting on
/// that tab, it jumps to Speakers on their behalf. Scene-phase transitions
/// drive the controller's background/foreground lifecycle (teardown while
/// backgrounded, eager reconnect + permission-suspected browser recovery on
/// return).
struct RootView: View {
    @State private var model = AppSessionModel()
    @State private var selection: Tab = .connection
    @Environment(\.scenePhase) private var scenePhase

    private enum Tab: Hashable {
        case speakers, apps, groups, connection
    }

    var body: some View {
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

            ConnectionTabView(
                session: model.activeSession,
                macs: model.macs,
                browserState: model.browserState,
                onWiFi: model.onWiFi,
                lastUsedMacID: model.lastUsedMacID,
                isDemoActive: model.isDemoActive,
                onConnect: model.connect(to:),
                onDisconnect: model.disconnect,
                onEnterDemo: model.enterDemo,
                onExitDemo: model.exitDemo
            )
            .tabItem { Label("Connection", systemImage: "antenna.radiowaves.left.and.right") }
            .tag(Tab.connection)
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
        .onChange(of: model.isConnected) { wasConnected, isConnected in
            if isConnected, !wasConnected, selection == .connection {
                selection = .speakers
            }
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
}

#Preview {
    RootView()
}
