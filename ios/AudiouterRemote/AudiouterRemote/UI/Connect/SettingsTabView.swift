// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// Tab 4: what this phone is connected to, and the two settings screens.
///
/// Getting connected is ``ConnectGateView``'s job now, so this tab is only
/// ever read by someone who already has a session — which is why it is a
/// stock grouped `List` rather than Warm Signal: the monumental treatment
/// exists to carry a first-run decision, and there is no decision here beyond
/// leaving. Switching Macs borrows the gate back as a sheet, so there is
/// exactly one place in the app that knows how to pick a Mac.
struct SettingsTabView: View {
    let session: any MacSessionProtocol
    let macs: [DiscoveredMac]
    let browserState: MacBrowserState
    let onWiFi: Bool
    let lastUsedMacID: String?
    let onConnect: (DiscoveredMac) -> Void
    let onDisconnect: () -> Void
    let onExitDemo: () -> Void
    let onReplayPrimer: () -> Void

    @State private var isSwitching = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow

                    Button("Switch Mac…") { isSwitching = true }

                    // Leaving a demo is a debug-build concern only: the Demo
                    // system does not ship, so the shipping build has exactly
                    // one way out of here.
                    #if DEBUG
                    Button(role: .destructive) {
                        if session.isDemo { onExitDemo() } else { onDisconnect() }
                    } label: {
                        Text(session.isDemo ? "Exit Demo" : "Disconnect")
                    }
                    #else
                    Button("Disconnect", role: .destructive, action: onDisconnect)
                    #endif
                }

                Section {
                    NavigationLink {
                        RemoteSettingsView(session: session)
                    } label: {
                        Label("Mac Settings", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }

                #if DEBUG
                Section {
                    Button("Replay Intro", action: onReplayPrimer)
                } footer: {
                    Text("Debug builds only — reviews the first-run intro screen.")
                }
                #endif
            }
            .navigationTitle("Settings")
        }
        .toastOverlay(session.toasts)
        .sheet(isPresented: $isSwitching) {
            ConnectGateView(
                session: session,
                macs: macs,
                browserState: browserState,
                onWiFi: onWiFi,
                lastUsedMacID: lastUsedMacID,
                onConnect: onConnect,
                onDisconnect: onDisconnect,
                isFullScreen: false
            )
        }
        // The sheet's job is done the moment the new Mac answers. Pulling it
        // down instead is the cancel — connecting to a new Mac already drops
        // demo and any previous session, so there is nothing to undo.
        .onChange(of: session.connectionStatus) { _, status in
            if status == .live { isSwitching = false }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.snapshot?.serverName ?? statusText)
                    .font(.headline)
                if session.snapshot?.serverName != nil {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            #if DEBUG
            if session.isDemo {
                Text("Demo")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow.opacity(0.25)))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Demo mode active")
            }
            #endif
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch session.connectionStatus {
        case .idle: return "Not Connected"
        case .connecting, .handshaking: return "Connecting…"
        case .awaitingApproval: return "Waiting for Approval…"
        case .live: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }
}

#Preview("Demo active") {
    SettingsTabView(
        session: DemoMacSession(),
        macs: [], browserState: .idle, onWiFi: true, lastUsedMacID: nil,
        onConnect: { _ in }, onDisconnect: {}, onExitDemo: {}, onReplayPrimer: {}
    )
}
