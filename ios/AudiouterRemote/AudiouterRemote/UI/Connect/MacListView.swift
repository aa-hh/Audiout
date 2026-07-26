// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// Section content for tab 4: every Mac currently browsed (name + status,
/// tap to connect/switch), the always-visible labeled "Demo system" row, and
/// a Disconnect action when something is live. Returns multiple `Section`s
/// (SwiftUI's `View.body` is an implicit `@ViewBuilder`) — meant to be
/// embedded directly inside ``ConnectionTabView``'s `List`, the same idiom
/// `GroupsView` uses for its own sections.
///
/// The three non-list conditions — no Wi-Fi, permission denied, nothing
/// found yet — each get their own explanatory view instead of a bare empty
/// list; the Demo system row stays visible in every one of them, since
/// trying the app without a reachable Mac is exactly what it's for.
struct MacListView: View {
    let macs: [DiscoveredMac]
    let browserState: MacBrowserState
    let onWiFi: Bool
    let connectionState: MacConnectionState
    /// The Mac the controller would auto-reconnect to — used only to mark
    /// which row is "this one" while connecting/connected.
    let lastUsedMacID: String?
    let isDemoActive: Bool
    let onConnect: (DiscoveredMac) -> Void
    let onDisconnect: () -> Void
    let onEnterDemo: () -> Void
    let onExitDemo: () -> Void

    var body: some View {
        Section {
            if !onWiFi {
                NotOnWiFiRow()
            } else if browserState == .permissionSuspected {
                PermissionDeniedView()
            } else if macs.isEmpty {
                EmptyStateView(isSearching: browserState == .browsing)
            } else {
                ForEach(macs) { mac in
                    MacRow(
                        mac: mac,
                        isConnectedHere: isConnected(to: mac),
                        isConnecting: isConnecting(to: mac),
                        onConnect: { onConnect(mac) }
                    )
                }
            }
        } header: {
            Text("Macs on Your Network")
        }

        Section {
            DemoRow(isActive: isDemoActive, onEnter: onEnterDemo, onExit: onExitDemo)
        } footer: {
            Text("A simulated Mac with sample speakers, for trying the app without one on your network. Never used automatically.")
        }

        if isDemoActive || isAnyMacConnectionActive {
            Section {
                Button(role: .destructive) {
                    if isDemoActive { onExitDemo() } else { onDisconnect() }
                } label: {
                    Text(isDemoActive ? "Exit Demo" : "Disconnect")
                }
            }
        }
    }

    private var isAnyMacConnectionActive: Bool {
        switch connectionState {
        case .connecting, .handshaking, .awaitingApproval, .live: return true
        case .idle, .disconnected: return false
        }
    }

    private func isConnected(to mac: DiscoveredMac) -> Bool {
        !isDemoActive && connectionState == .live && lastUsedMacID == mac.id
    }

    private func isConnecting(to mac: DiscoveredMac) -> Bool {
        guard !isDemoActive, lastUsedMacID == mac.id else { return false }
        switch connectionState {
        case .connecting, .handshaking, .awaitingApproval: return true
        default: return false
        }
    }
}

/// One discovered Mac. Incompatible Macs (refuse-forward: this Mac speaks a
/// newer protocol than we do) are shown, never dialed — tapping does
/// nothing, and the row explains that updating the app, not the Mac, is
/// what would fix it.
private struct MacRow: View {
    let mac: DiscoveredMac
    let isConnectedHere: Bool
    let isConnecting: Bool
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name)
                        .font(.body)
                        .foregroundStyle(mac.isIncompatible ? .secondary : .primary)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(mac.isIncompatible ? .orange : .secondary)
                }

                Spacer()

                if isConnectedHere {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                } else if isConnecting {
                    ProgressView()
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(mac.isIncompatible)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mac.name). \(statusText)")
        .accessibilityAddTraits(isConnectedHere ? [.isSelected] : [])
    }

    private var statusText: String {
        if mac.isIncompatible { return "Update this app to connect" }
        if isConnectedHere { return "Connected" }
        if isConnecting { return "Connecting…" }
        return "Tap to connect"
    }
}

/// Always visible, regardless of network state — the labeled "Demo system"
/// row is the ONE call site that ever constructs a `DemoMacSession` (house
/// rule: opt-in only, never a fallback). The "Demo" badge here doubles the
/// header's own badge (``ConnectionTabView``) while active, so it's visible
/// from wherever the user happens to be looking.
private struct DemoRow: View {
    let isActive: Bool
    let onEnter: () -> Void
    let onExit: () -> Void

    var body: some View {
        Button {
            if isActive { onExit() } else { onEnter() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.tv")
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Demo system")
                        .font(.body)
                    Text(isActive ? "Active \u{2014} sample speakers, no Mac needed" : "Try the app without a Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isActive {
                    Text("Demo")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.yellow.opacity(0.25)))
                        .foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demo system" + (isActive ? ", active" : ""))
        .accessibilityHint(isActive ? "Double tap to exit demo mode" : "Double tap to try a simulated Mac with sample speakers")
    }
}

private struct NotOnWiFiRow: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Not on Wi-Fi")
                    .font(.subheadline.weight(.medium))
                Text("Connect to the same Wi-Fi network as your Mac to find it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

private func previewMac(name: String, isIncompatible: Bool = false) -> DiscoveredMac {
    DiscoveredMac(
        id: "\(name)._audiouter._tcplocal.",
        endpoint: .service(name: name, type: CompanionProto.serviceType, domain: "local.", interface: nil),
        name: name,
        protoVersion: isIncompatible ? CompanionProto.version + 1 : CompanionProto.version,
        isIncompatible: isIncompatible
    )
}

#Preview("Searching") {
    List {
        MacListView(
            macs: [], browserState: .browsing, onWiFi: true, connectionState: .idle,
            lastUsedMacID: nil, isDemoActive: false,
            onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
        )
    }
}

#Preview("Found Macs") {
    let macs = [previewMac(name: "Alec's Mac"), previewMac(name: "Living Room iMac", isIncompatible: true)]
    List {
        MacListView(
            macs: macs, browserState: .browsing, onWiFi: true, connectionState: .live,
            lastUsedMacID: macs[0].id, isDemoActive: false,
            onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
        )
    }
}

#Preview("No Wi-Fi") {
    List {
        MacListView(
            macs: [], browserState: .idle, onWiFi: false, connectionState: .idle,
            lastUsedMacID: nil, isDemoActive: false,
            onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
        )
    }
}

#Preview("Permission suspected") {
    List {
        MacListView(
            macs: [], browserState: .permissionSuspected, onWiFi: true, connectionState: .idle,
            lastUsedMacID: nil, isDemoActive: false,
            onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
        )
    }
}

#Preview("Demo active") {
    List {
        MacListView(
            macs: [], browserState: .idle, onWiFi: true, connectionState: .idle,
            lastUsedMacID: nil, isDemoActive: true,
            onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
        )
    }
}
