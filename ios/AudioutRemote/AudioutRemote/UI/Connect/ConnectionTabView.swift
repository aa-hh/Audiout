// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudioutProtocol

/// Tab 4 (D4): Connection + Settings merged into one tab on purpose, so it
/// never looks thin. Top to bottom: the current-Mac header (status, Demo
/// badge), the per-phone approval banner when one applies (D2 REVISED),
/// ``MacListView`` (discovered Macs, switch, Demo system row), then
/// navigation links into the Mac-settings half (``RemoteSettingsView``,
/// T17b) and ``AboutView``.
///
/// Connection-management state — the browsed Mac list, the browser's
/// idle/browsing/permissionSuspected state, Wi-Fi reachability — is
/// deliberately NOT part of ``MacSessionProtocol``: that protocol is
/// command-and-snapshot only and shared verbatim with the other three tabs.
/// This view takes that state (and the connect/disconnect/demo actions)
/// alongside `session` from whatever owns the ``ConnectionController``
/// (`RootView`), rather than smuggling it through the shared protocol.
struct ConnectionTabView: View {
    let session: any MacSessionProtocol
    let macs: [DiscoveredMac]
    let browserState: MacBrowserState
    let onWiFi: Bool
    let lastUsedMacID: String?
    let isDemoActive: Bool
    let onConnect: (DiscoveredMac) -> Void
    let onDisconnect: () -> Void
    let onEnterDemo: () -> Void
    let onExitDemo: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ConnectionHeaderRow(session: session)
                    if let status = session.connectionStatus.approvalStatus {
                        ApprovalStatusCard(status: status, onCancel: onDisconnect, onRetry: retryLastMac)
                    }
                }

                MacListView(
                    macs: macs,
                    browserState: browserState,
                    onWiFi: onWiFi,
                    connectionState: session.connectionStatus,
                    lastUsedMacID: lastUsedMacID,
                    isDemoActive: isDemoActive,
                    onConnect: onConnect,
                    onDisconnect: onDisconnect,
                    onEnterDemo: onEnterDemo,
                    onExitDemo: onExitDemo
                )

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
            }
            .navigationTitle("Connection")
        }
        .toastOverlay(session.toasts)
    }

    private func retryLastMac() {
        guard let lastUsedMacID, let mac = macs.first(where: { $0.id == lastUsedMacID }) else { return }
        onConnect(mac)
    }
}

// MARK: - Header

/// Mirrors `SpeakersView`'s header copy/symbols so the two tabs agree on
/// what "Connecting…"/"Live" look like — kept as a local, small duplicate
/// rather than a shared type, since this task's file scope is UI/Connect
/// only.
private struct ConnectionHeaderRow: View {
    let session: any MacSessionProtocol

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.snapshot?.serverName ?? "No Mac Connected")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if session.isDemo {
                Text("Demo")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow.opacity(0.25)))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Demo mode active")
            }
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

    private var statusSymbol: String {
        switch session.connectionStatus {
        case .live: return "checkmark.circle.fill"
        case .connecting, .handshaking, .awaitingApproval: return "arrow.triangle.2.circlepath.circle.fill"
        case .idle, .disconnected: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch session.connectionStatus {
        case .live: return .green
        case .connecting, .handshaking, .awaitingApproval: return .yellow
        case .idle, .disconnected: return .secondary
        }
    }
}

// MARK: - Approval

/// Renders ``ApprovalStatus`` prominently, using ITS OWN headline/guidance
/// strings verbatim (MacConnection.swift) rather than parallel copy:
///
/// - `.waitingForApproval`: non-error styling (blue, hourglass) + Cancel,
///   which just calls `onDisconnect` — there is nothing to poll, the Mac's
///   `welcome`/`goodbye` resolves this on its own.
/// - `.denied`: terminal — no button at all. Offering "Try Again" here
///   would imply retrying helps, which it never does (the Mac remembers the
///   denial); the guidance text is the only way out, and it says so.
/// - `.promptTimedOut`: retryable — a Try Again button that redials the
///   same Mac and re-asks its user.
private struct ApprovalStatusCard: View {
    let status: ApprovalStatus
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(status.headline)
                    .font(.headline)
            } icon: {
                Image(systemName: symbolName)
                    .foregroundStyle(tint)
            }
            .accessibilityAddTraits(.isHeader)

            Text(status.guidance)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch status {
            case .waitingForApproval:
                HStack {
                    ProgressView()
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                }
            case .promptTimedOut:
                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)
            case .denied:
                EmptyView()
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var symbolName: String {
        switch status {
        case .waitingForApproval: return "hourglass.circle.fill"
        case .denied: return "xmark.octagon.fill"
        case .promptTimedOut: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .waitingForApproval: return .blue
        case .denied: return .red
        case .promptTimedOut: return .orange
        }
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

private func previewMac(name: String) -> DiscoveredMac {
    DiscoveredMac(
        id: "\(name)._audiout._tcplocal.",
        endpoint: .service(name: name, type: CompanionProto.serviceType, domain: "local.", interface: nil),
        name: name,
        protoVersion: CompanionProto.version,
        isIncompatible: false
    )
}

#Preview("Demo active") {
    let demo = DemoMacSession()
    return ConnectionTabView(
        session: demo, macs: [], browserState: .idle, onWiFi: true,
        lastUsedMacID: nil, isDemoActive: true,
        onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
    )
}

#Preview("Found Macs, not yet connected") {
    let mac = previewMac(name: "Alec's Mac")
    return ConnectionTabView(
        session: PreviewConnectionSession(connectionStatus: .idle),
        macs: [mac], browserState: .browsing, onWiFi: true,
        lastUsedMacID: nil, isDemoActive: false,
        onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
    )
}

#Preview("Awaiting approval") {
    let mac = previewMac(name: "Alec's Mac")
    return ConnectionTabView(
        session: PreviewConnectionSession(connectionStatus: .awaitingApproval),
        macs: [mac], browserState: .browsing, onWiFi: true,
        lastUsedMacID: mac.id, isDemoActive: false,
        onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
    )
}

#Preview("Denied") {
    let mac = previewMac(name: "Alec's Mac")
    return ConnectionTabView(
        session: PreviewConnectionSession(connectionStatus: .disconnected(.goodbye(CompanionGoodbyeReason.notApproved))),
        macs: [mac], browserState: .browsing, onWiFi: true,
        lastUsedMacID: mac.id, isDemoActive: false,
        onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
    )
}

#Preview("Prompt timed out") {
    let mac = previewMac(name: "Alec's Mac")
    return ConnectionTabView(
        session: PreviewConnectionSession(connectionStatus: .disconnected(.goodbye(CompanionGoodbyeReason.approvalTimedOut))),
        macs: [mac], browserState: .browsing, onWiFi: true,
        lastUsedMacID: mac.id, isDemoActive: false,
        onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
    )
}

#Preview("Permission denied") {
    ConnectionTabView(
        session: PreviewConnectionSession(connectionStatus: .idle),
        macs: [], browserState: .permissionSuspected, onWiFi: true,
        lastUsedMacID: nil, isDemoActive: false,
        onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
    )
}

#Preview("No Wi-Fi") {
    ConnectionTabView(
        session: PreviewConnectionSession(connectionStatus: .idle),
        macs: [], browserState: .idle, onWiFi: false,
        lastUsedMacID: nil, isDemoActive: false,
        onConnect: { _ in }, onDisconnect: {}, onEnterDemo: {}, onExitDemo: {}
    )
}
