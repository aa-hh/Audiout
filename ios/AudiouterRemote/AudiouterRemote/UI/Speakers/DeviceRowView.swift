// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// One speaker row: icon (D5 — the Mac's resolved custom icon, read-only),
/// name/kind, select toggle, volume + mute, and — per D9 full status parity —
/// a failure card (headline / expandable suggestion / Try Again) whenever
/// `connection.state == "failed"`, independent of `isAvailable`.
///
/// Volume slider policy: while dragging, the thumb tracks `localVolume` (set
/// on every tick) rather than `device.volume` from the snapshot, because
/// device-volume effects come back through the ~50ms coalescer and would
/// otherwise fight the user's finger. `localVolume` clears on release so the
/// slider reconciles from the next snapshot like any other row.
///
/// `isAvailable == false` means the device is gone from the network entirely
/// (distinct from `connection.state`, which can be "failed"/"off" while still
/// `isAvailable`) — dimmed AND its controls disabled, since there's nothing
/// on the other end to apply them. For a device that IS available but not
/// `connected` (e.g. "off"/"connecting"), volume/mute stay enabled: the Mac
/// refuses those commands for a non-connected device, and that refusal
/// already surfaces as a toast (`ToastCenter`) rather than a pre-disabled
/// control silently doing nothing.
struct DeviceRowView: View {
    let device: DeviceState
    let session: any MacSessionProtocol

    @State private var localVolume: Double?
    @State private var showFailureDetail = false

    private var isFailed: Bool { device.connection.state == "failed" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: device.iconSymbolName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.body)
                    Text(kindLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(isOn: Binding(
                    get: { device.isSelected },
                    set: { session.setDeviceSelected(id: device.id, selected: $0) }
                )) {
                    EmptyView()
                }
                .labelsHidden()
                .disabled(!device.isAvailable)
                .accessibilityLabel("Select \(device.name)")
            }

            if isFailed {
                failureCard
            } else {
                controlsRow
            }
        }
        .padding(.vertical, 4)
        .opacity(device.isAvailable ? 1 : 0.45)
    }

    private var kindLabel: String {
        switch device.kind {
        case "localMac": return "This Mac"
        case "homePod": return "HomePod"
        case "appleTV": return "Apple TV"
        case "airportExpress": return "AirPort Express"
        case "sonos": return "Sonos"
        default: return device.kind.capitalized
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button {
                session.setDeviceMuted(id: device.id, muted: !device.isMuted)
            } label: {
                Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!device.isAvailable)
            .accessibilityLabel(device.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")

            Slider(
                value: Binding(
                    get: { localVolume ?? Double(device.volume) },
                    set: { newValue in
                        localVolume = newValue
                        session.setDeviceVolume(id: device.id, volume: Int(newValue.rounded()), isFinal: false)
                    }
                ),
                in: 0...100,
                step: 1,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    let final = Int((localVolume ?? Double(device.volume)).rounded())
                    session.setDeviceVolume(id: device.id, volume: final, isFinal: true)
                    localVolume = nil
                }
            )
            .disabled(!device.isAvailable)
            .accessibilityLabel("\(device.name) volume")
            .accessibilityValue("\(Int(localVolume ?? Double(device.volume))) percent")
        }
    }

    private var failureCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(device.connection.failureHeadline ?? "Connection failed", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)

            if let suggestion = device.connection.failureSuggestion {
                DisclosureGroup(isExpanded: $showFailureDetail) {
                    Text(suggestion)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Details")
                        .font(.footnote)
                }
            }

            Button("Try Again") {
                session.retryConnection(id: device.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityHint("Retry connecting to \(device.name)")
        }
        .padding(.top, 2)
    }
}

#Preview("Healthy") {
    let demo = DemoMacSession()
    return List {
        ForEach(demo.snapshot!.devices, id: \.id) { device in
            DeviceRowView(device: device, session: demo)
        }
    }
}

#Preview("Failed device") {
    let failed = DeviceState(
        id: "demo-office", name: "Office Speaker", kind: "generic",
        iconSymbolName: "hifispeaker.fill", isAvailable: false, supportsAirPlay2: true,
        isLocalDevice: false, volume: 50, isMuted: false, isSelected: false, isMainOutMember: false,
        connection: DeviceState.ConnectionInfo(
            state: "failed",
            failureHeadline: "Not on the network",
            failureSuggestion: "The speaker is no longer visible on the network. Check that it's powered on and on the same Wi-Fi, then try again."
        )
    )
    return List {
        DeviceRowView(device: failed, session: DemoMacSession())
    }
}
