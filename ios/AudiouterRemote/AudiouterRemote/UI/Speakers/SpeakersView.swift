// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// Tab 1: which Mac is connected, Main Out (picker + master volume/mute),
/// and every speaker. This view owns no local state at all — every value it
/// renders comes straight from `session.snapshot`. The in-drag slider echoes
/// live one level down, in ``MainOutRow`` and ``DeviceRowView``, so each dies
/// with the list it's in.
struct SpeakersView: View {
    let session: any MacSessionProtocol

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                StatusBanners(snapshot: session.snapshot)

                if let snapshot = session.snapshot {
                    List {
                        Section("Main Out") {
                            MainOutPicker(snapshot: snapshot, session: session)
                            MainOutRow(masterVolume: snapshot.mainOutMasterVolume,
                                       isMuted: snapshot.mainOutMuted,
                                       session: session)
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
}

// MARK: - Main Out master row

/// Main Out's mute + master volume. A leaf view for the same reason
/// ``DeviceRowView`` is one: the in-drag echo (`localVolume`) has to be scoped
/// to the row so it dies with the list whenever the snapshot goes away
/// (backgrounding, a keepalive drop, a reconnect). Held on `SpeakersView` —
/// which lives as long as the app does — a drag whose release callback never
/// arrived left the echo set forever, and the thumb then ignored every later
/// snapshot the Mac sent.
///
/// The echo now outlives the RELEASE too — that's what keeps the thumb off the
/// ~50ms rubber-band back to the pre-release value — which is only safe
/// because it stays bounded: the next Main Out snapshot clears it, and a
/// disconnect or a tab change takes the whole list, and this view with it. The
/// other three sliders still clear on release; this is the one that was
/// reported.
struct MainOutRow: View {
    let masterVolume: Int
    let isMuted: Bool
    let session: any MacSessionProtocol

    @State private var localVolume: Double?
    /// True from the drag's first tick to its release. While it's true the
    /// Mac's echoes must NOT clear `localVolume` — they arrive ~50ms behind
    /// the finger and would drag the thumb backwards under it.
    @State private var isDragging = false

    /// What the thumb shows: the finger while a drag is in flight (and the
    /// value it was released at until the Mac echoes it back), the Mac's
    /// value whenever neither applies.
    static func thumbValue(local: Double?, server: Int) -> Double {
        local ?? Double(server)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                session.setMainOutMuted(!isMuted)
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isMuted ? "Unmute Main Out" : "Mute Main Out")

            Slider(
                value: Binding(
                    get: { Self.thumbValue(local: localVolume, server: masterVolume) },
                    set: { newValue in
                        localVolume = newValue
                        session.setMainOutMasterVolume(Int(newValue.rounded()), isFinal: false)
                    }
                ),
                in: 0...100,
                step: 1,
                onEditingChanged: { editing in
                    // Local echo while dragging, coalesced sends, always send
                    // the release value — no drag bracket (Main is a
                    // stateless set).
                    isDragging = editing
                    guard !editing else { return }
                    let final = Int(Self.thumbValue(local: localVolume, server: masterVolume).rounded())
                    session.setMainOutMasterVolume(final, isFinal: true)
                    // The echo is ~50ms behind, so clearing the echo HERE (as
                    // the other rows still do) rubber-bands the thumb to the
                    // pre-release value for that beat. Hold it instead and let
                    // the snapshot below clear it.
                }
            )
            .onChange(of: masterVolume) {
                // The bound on the hold: any snapshot that moves Main Out ends
                // it, so a released — or stranded — echo can never outlive one
                // round trip, and the thumb goes back to following the Mac.
                guard !isDragging else { return }
                localVolume = nil
            }
            .accessibilityLabel("Main Out volume")
            .accessibilityValue("\(Int(Self.thumbValue(local: localVolume, server: masterVolume))) percent")
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
