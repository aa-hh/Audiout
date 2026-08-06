// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// Tab 2: per-app routing. Lists every app the Mac currently has a route for
/// (destination + volume + running state), swipe-to-remove, and an add-app
/// sheet sourced from `snapshot.addableApps`.
///
/// Renders a "connecting" placeholder before the first snapshot arrives —
/// this view never invents state the Mac hasn't sent yet.
struct AppsView: View {
    let session: any MacSessionProtocol
    @State private var isPresentingAddSheet = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Apps")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isPresentingAddSheet = true
                        } label: {
                            Label("Add App", systemImage: "plus")
                        }
                        .disabled(session.snapshot?.addableApps.isEmpty ?? true)
                    }
                }
                .sheet(isPresented: $isPresentingAddSheet) {
                    AddAppSheet(session: session)
                }
        }
        .toastOverlay(session.toasts)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = session.snapshot {
            if snapshot.appRoutes.isEmpty {
                ContentUnavailableView(
                    "No Routed Apps",
                    systemImage: "square.grid.2x2",
                    description: Text("Add an app to send its audio to a specific speaker.")
                )
            } else {
                List {
                    ForEach(snapshot.appRoutes, id: \.bundleID) { route in
                        AppRouteRowView(
                            route: route,
                            availableDevices: redirectableDevices(in: snapshot),
                            session: session
                        )
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            session.removeAppRoute(bundleID: snapshot.appRoutes[index].bundleID)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Apps",
                systemImage: "square.grid.2x2",
                description: Text("Connecting…")
            )
        }
    }

    /// Speakers offerable as a redirect target: available, AirPlay-capable,
    /// non-local, and not carrying the Main Out — the popover applies the
    /// same one-role-per-speaker skip on top of
    /// `PopoverController.availableAirPlayDestinations` (a Main Out member is
    /// never offered as a redirect target), so the phone never offers a
    /// destination the Mac itself wouldn't. The Mac's dispatcher also refuses
    /// it server-side; this filter keeps the refusal from ever being needed.
    private func redirectableDevices(in snapshot: Snapshot) -> [DeviceState] {
        snapshot.devices.filter {
            !$0.isLocalDevice && $0.isAvailable && $0.supportsAirPlay2 && !$0.isMainOutMember
        }
    }
}

#Preview("Routed apps") {
    AppsView(session: DemoMacSession())
}
