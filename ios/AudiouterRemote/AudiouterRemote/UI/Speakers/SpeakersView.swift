// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// Tab 1: which Mac is connected, Main Out (picker + master volume/mute),
/// and every speaker. The only state this view owns locally is the Main Out
/// master slider's in-drag echo (`localMasterVolume`) — everything else comes
/// straight from `session.snapshot`, mirroring the same local-echo-while-
/// dragging policy `DeviceRowView` uses per-row.
struct SpeakersView: View {
    let session: any MacSessionProtocol

    @State private var localMasterVolume: Double?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                StatusBanners(snapshot: session.snapshot)

                if let snapshot = session.snapshot {
                    List {
                        Section("Main Out") {
                            MainOutPicker(snapshot: snapshot, session: session)
                            masterRow(snapshot)
                        }

                        Section("Speakers") {
                            ForEach(snapshot.devices, id: \.id) { device in
                                DeviceRowView(device: device, session: session)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    Spacer()
                    ContentUnavailableView(
                        "No Speakers",
                        systemImage: "speaker.wave.2",
                        description: Text("Connect to a Mac to see its speakers here.")
                    )
                    Spacer()
                }
            }
            .navigationTitle("Speakers")
            .navigationBarTitleDisplayMode(.inline)
        }
        .toastOverlay(session.toasts)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.snapshot?.serverName ?? "No Mac")
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
        .padding(.horizontal)
        .padding(.vertical, 8)
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

    // MARK: Main Out master row

    private func masterRow(_ snapshot: Snapshot) -> some View {
        HStack(spacing: 12) {
            Button {
                session.setMainOutMuted(!snapshot.mainOutMuted)
            } label: {
                Image(systemName: snapshot.mainOutMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(snapshot.mainOutMuted ? "Unmute Main Out" : "Mute Main Out")

            Slider(
                value: Binding(
                    get: { localMasterVolume ?? Double(snapshot.mainOutMasterVolume) },
                    set: { newValue in
                        localMasterVolume = newValue
                        session.setMainOutMasterVolume(Int(newValue.rounded()), isFinal: false)
                    }
                ),
                in: 0...100,
                step: 1,
                onEditingChanged: { editing in
                    if editing {
                        session.beginMainOutDrag()
                    } else {
                        let final = Int((localMasterVolume ?? Double(snapshot.mainOutMasterVolume)).rounded())
                        session.setMainOutMasterVolume(final, isFinal: true)
                        session.endMainOutDrag()
                        localMasterVolume = nil
                    }
                }
            )
            .accessibilityLabel("Main Out volume")
            .accessibilityValue("\(Int(localMasterVolume ?? Double(snapshot.mainOutMasterVolume))) percent")
        }
    }
}

// MARK: - Previews

/// Preview-only stand-in for the banner/offline scenarios `DemoMacSession`
/// has no public seam to produce (it hardcodes `localFallbackActive: false`,
/// `takeoverStatus: nil` by design — those are real-Mac-only conditions).
/// Never used outside `#Preview`.
@MainActor
private final class PreviewSession: MacSessionProtocol {
    var snapshot: Snapshot?
    var connectionStatus: MacConnectionState
    let isDemo: Bool
    let toasts = ToastCenter()

    init(snapshot: Snapshot?, connectionStatus: MacConnectionState, isDemo: Bool = false) {
        self.snapshot = snapshot
        self.connectionStatus = connectionStatus
        self.isDemo = isDemo
    }

    func setDeviceSelected(id: String, selected: Bool) {}
    func retryConnection(id: String) {}
    func setMainOut(_ state: MainOutState) {}
    func setDeviceVolume(id: String, volume: Int, isFinal: Bool) {}
    func setDeviceMuted(id: String, muted: Bool) {}
    func beginMainOutDrag() {}
    func setMainOutMasterVolume(_ volume: Int, isFinal: Bool) {}
    func endMainOutDrag() {}
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

#Preview("Healthy — Demo") {
    SpeakersView(session: DemoMacSession())
}

#Preview("Failed device + banners") {
    let base = DemoMacSession().snapshot!
    let bannered = Snapshot(
        serverName: base.serverName,
        devices: base.devices,
        mainOut: base.mainOut,
        mainOutMasterVolume: base.mainOutMasterVolume,
        mainOutMuted: base.mainOutMuted,
        groups: base.groups,
        activeGroupID: base.activeGroupID,
        appRoutes: base.appRoutes,
        liveRoutedAppNames: base.liveRoutedAppNames,
        addableApps: base.addableApps,
        localFallbackActive: true,
        takeoverStatus: "Waiting for you to allow AirPlay timing in Login Items & Extensions…",
        systemDefaultIsAirPlayActive: true,
        settings: base.settings
    )
    return SpeakersView(session: PreviewSession(snapshot: bannered, connectionStatus: .live))
}

#Preview("Offline") {
    SpeakersView(session: PreviewSession(snapshot: nil, connectionStatus: .disconnected(.keepaliveTimeout)))
}
