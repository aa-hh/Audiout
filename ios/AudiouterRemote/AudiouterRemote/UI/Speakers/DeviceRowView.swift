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
/// otherwise fight the user's finger. `localVolume` clears on release, so the
/// slider reconciles from the next snapshot — and rubber-bands to the
/// pre-release value for that one beat, which ``MainOutRow`` no longer does.
///
/// Volume and mute are enabled by the same rule the Mac's own row uses (see
/// ``isControllable``); the select toggle is enabled by the Mac's separate,
/// weaker checkbox rule (availability alone). `isAvailable == false` means the
/// device is gone from the network entirely (distinct from
/// `connection.state`, which can be "failed"/"off" while still `isAvailable`)
/// — dimmed AND everything disabled, since there's nothing on the other end
/// to apply them. A control the rule disables says WHY when VoiceOver reads
/// it (see ``disabledReason(for:controllable:)``).
struct DeviceRowView: View {
    let device: DeviceState
    let session: any MacSessionProtocol

    @State private var localVolume: Double?
    @State private var showFailureDetail = false

    /// D9's failure card takes the whole control slot: a `"failed"` device
    /// gets headline / details / Try Again INSTEAD of volume + mute. This is
    /// where the phone's row deliberately parts from the Mac's, which keeps a
    /// failed row's controls and only desaturates them.
    static func showsFailureCard(_ device: DeviceState) -> Bool {
        device.connection.state == "failed"
    }

    private var isFailed: Bool { Self.showsFailureCard(device) }

    /// The Mac's rule for the volume slider and the mute button, mirrored
    /// exactly (AudiouterSharedUI/DeviceRowView: `device.isAvailable &&
    /// controllable`, where `PopoverController` passes `controllable` =
    /// `isSpeakerSelected(id) || isRedirectTarget(id)`, and a redirect target
    /// is any app route pointed at this device).
    ///
    /// Connection state is deliberately absent, because it's absent from the
    /// Mac's rule too — there it only dims the controls. So an available but
    /// not-yet-connected device stays draggable and the server's refusal
    /// (`CompanionCommandDispatcher.deviceWriteRefusal`, which gates on
    /// connection state ALONE) surfaces as a toast (`ToastCenter`). A
    /// `"failed"` device is this side's exception: the row swaps both
    /// controls for the failure card (``showsFailureCard(_:)``), so the
    /// rule's answer for it never reaches a control at all.
    ///
    /// Two known gaps against the Mac, both judged harmless:
    /// - TRANSIENT: excluding an app filters its route off the wire
    ///   immediately (`CompanionSnapshotBuilder`), while the Mac's own row
    ///   keeps counting that route until the coordinating layer prunes it —
    ///   so for that beat the phone greys a slider the Mac still has live.
    ///   Self-corrects on the next snapshot.
    /// - BY DESIGN: this rule is STRICTER than the server's refusal gate. A
    ///   connected-but-unselected device's write would be ACCEPTED, so the
    ///   greyed control has no refusal behind it to toast. It follows the
    ///   Mac's row rather than the server's — and the row's own Select switch
    ///   sits directly above it, with the spoken reason below covering
    ///   VoiceOver, so the control is never dead-and-silent.
    static func isControllable(_ device: DeviceState, appRoutes: [AppRouteState]) -> Bool {
        guard device.isAvailable else { return false }
        return device.isSelected || appRoutes.contains {
            $0.destinationKind == "device" && $0.deviceID == device.id
        }
    }

    /// Why volume and mute are disabled, or `nil` while they're live. The Mac
    /// composes this reason into its row's own label (the membership clause in
    /// `AudiouterSharedUI/DeviceRowView.configureAccessibility`); the phone has
    /// no row-level label — each control is its own element — so the clause
    /// rides on the two controls the rule disables instead. Worded in the
    /// phone's own vocabulary ("Select", "Main Out" — what its visible
    /// controls say), and spoken exactly once, never duplicated onto a hint.
    static func disabledReason(for device: DeviceState, controllable: Bool) -> String? {
        if controllable { return nil }
        return device.isAvailable ? "not selected for Main Out" : "unavailable"
    }

    /// This row's answer to that rule. No snapshot yet means no known routes,
    /// so the redirect half is false — never assume controllable, that would
    /// be inventing state.
    private var controlsEnabled: Bool {
        Self.isControllable(device, appRoutes: session.snapshot?.appRoutes ?? [])
    }

    /// The reason as a trailing label clause, matching how the Mac appends its
    /// own clauses (`", \(state)"`). Empty when there's nothing to explain.
    private var disabledClause: String {
        Self.disabledReason(for: device, controllable: controlsEnabled)
            .map { ", \($0)" } ?? ""
    }

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
            .disabled(!controlsEnabled)
            .accessibilityLabel(
                (device.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)") + disabledClause)

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
            .disabled(!controlsEnabled)
            .accessibilityLabel("\(device.name) volume\(disabledClause)")
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
