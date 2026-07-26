// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// One per-app routing row: glyph, name, a destination menu (No Redirect /
/// This Mac / each available speaker), a volume slider, and a dimmed
/// "Not running" state.
///
/// The volume slider binds to LOCAL state while the user's finger is down and
/// only re-syncs from the snapshot when idle. Effects come back through the
/// ~50 Hz coalescer (`MacSessionProtocol`'s slider-policy doc comment); a
/// slider bound straight to `route.volume` would fight the drag every time an
/// echoed value lands mid-gesture.
struct AppRouteRowView: View {
    let route: AppRouteState
    /// Devices this row may redirect to — already filtered to available
    /// AirPlay-capable, non-local devices (mirrors `PopoverController`
    /// .availableAirPlayDestinations on the Mac side).
    let availableDevices: [DeviceState]
    let session: any MacSessionProtocol

    @State private var localVolume: Double
    @State private var isDragging = false

    init(route: AppRouteState, availableDevices: [DeviceState], session: any MacSessionProtocol) {
        self.route = route
        self.availableDevices = availableDevices
        self.session = session
        _localVolume = State(initialValue: Double(route.volume))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AppGlyph(bundleID: route.bundleID, displayName: route.displayName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(route.displayName)
                        .font(.body)
                    if !route.isRunning {
                        Text("Not running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                destinationMenu
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { localVolume },
                        set: { newValue in
                            localVolume = newValue
                            session.setAppVolume(bundleID: route.bundleID,
                                                  volume: Int(newValue.rounded()), isFinal: false)
                        }
                    ),
                    in: 0...100,
                    step: 1,
                    onEditingChanged: { editing in
                        isDragging = editing
                        if !editing {
                            session.setAppVolume(bundleID: route.bundleID,
                                                  volume: Int(localVolume.rounded()), isFinal: true)
                        }
                    }
                )
                .accessibilityLabel("\(route.displayName) volume")
                .accessibilityValue("\(Int(localVolume.rounded())) percent")
            }
        }
        .padding(.vertical, 4)
        .opacity(route.isRunning ? 1.0 : 0.5)
        .onChange(of: route.volume) { _, newValue in
            // Reconcile from the snapshot only when idle — mid-drag the
            // user's finger owns this value, not the server echo.
            guard !isDragging else { return }
            localVolume = Double(newValue)
        }
    }

    private var destinationMenu: some View {
        Menu {
            Button {
                session.setAppDestination(bundleID: route.bundleID, kind: "noRedirect", deviceID: nil)
            } label: {
                destinationLabelContent("No Redirect", isSelected: route.destinationKind == "noRedirect")
            }
            Button {
                session.setAppDestination(bundleID: route.bundleID, kind: "currentDevice", deviceID: nil)
            } label: {
                destinationLabelContent("This Mac", isSelected: route.destinationKind == "currentDevice")
            }
            if !availableDevices.isEmpty {
                Divider()
                ForEach(availableDevices, id: \.id) { device in
                    Button {
                        session.setAppDestination(bundleID: route.bundleID, kind: "device", deviceID: device.id)
                    } label: {
                        destinationLabelContent(
                            device.name,
                            isSelected: route.destinationKind == "device" && route.deviceID == device.id
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(destinationTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(route.displayName) destination, \(destinationTitle)")
    }

    @ViewBuilder
    private func destinationLabelContent(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var destinationTitle: String {
        switch route.destinationKind {
        case "noRedirect": return "No Redirect"
        case "currentDevice": return "This Mac"
        case "device":
            return availableDevices.first(where: { $0.id == route.deviceID })?.name ?? "Unavailable Device"
        default: return route.destinationKind
        }
    }
}

#Preview("Routed, running") {
    List {
        AppRouteRowView(
            route: AppRouteState(bundleID: "com.demo.music", displayName: "Demo Music",
                                  destinationKind: "device", deviceID: "demo-homepod",
                                  volume: 72, isRunning: true),
            availableDevices: [
                DeviceState(id: "demo-homepod", name: "Kitchen HomePod", kind: "homePod",
                            iconSymbolName: "homepod.fill", isAvailable: true, supportsAirPlay2: true,
                            isLocalDevice: false, volume: 40, isMuted: false, isSelected: true,
                            isMainOutMember: true, connection: .init(state: "connected")),
            ],
            session: DemoMacSession()
        )
    }
}

#Preview("Not running") {
    List {
        AppRouteRowView(
            route: AppRouteState(bundleID: "com.demo.browser", displayName: "Demo Browser",
                                  destinationKind: "noRedirect", volume: 100, isRunning: false),
            availableDevices: [],
            session: DemoMacSession()
        )
    }
}
