// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// Whole-app status strips (D9 full parity), stacked above the device list:
/// local-playback fallback, the PTP takeover strip, and the system-AirPlay
/// double-path/echo note. Text mirrors the Mac popover's own banners verbatim
/// (`PopoverController.localFallbackBannerText` /
/// `.systemAirPlayNoteText`) — `takeoverStatus` itself already arrives as
/// Mac-rendered display text (`AppDelegate.companionTakeoverText`), shown
/// as-is with no phone-side interpretation.
struct StatusBanners: View {
    let snapshot: Snapshot?

    static let localFallbackText =
        "Speakers unreachable — playing on this Mac. Will resume automatically."
    static let systemAirPlayNoteText =
        "Your Mac's system output is also set to AirPlay — audio may play twice. Switch it back to avoid an echo."

    var body: some View {
        if let snapshot {
            VStack(spacing: 8) {
                if snapshot.localFallbackActive {
                    banner(text: Self.localFallbackText, symbol: "speaker.slash.circle.fill", tint: .orange)
                }
                if let takeoverStatus = snapshot.takeoverStatus {
                    banner(text: takeoverStatus, symbol: "arrow.triangle.2.circlepath.circle.fill", tint: .blue)
                }
                // `nil` means "not reported" — treat as false (protocol doc comment).
                if snapshot.systemDefaultIsAirPlayActive == true {
                    banner(text: Self.systemAirPlayNoteText, symbol: "info.circle.fill", tint: .blue)
                }
            }
            .padding([.horizontal, .top])
        }
    }

    private func banner(text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Banners active") {
    StatusBanners(snapshot: Snapshot(
        serverName: "Alec's Mac",
        devices: [],
        mainOut: MainOutState(kind: "selected"),
        mainOutMasterVolume: 40,
        mainOutMuted: false,
        groups: [],
        appRoutes: [],
        liveRoutedAppNames: [:],
        addableApps: [],
        localFallbackActive: true,
        takeoverStatus: "Waiting for you to allow AirPlay timing in Login Items & Extensions…",
        systemDefaultIsAirPlayActive: true,
        settings: SettingsState(connectVolume: 35, connectVolumeMin: 5, connectVolumeMax: 100,
                                 startBufferMs: 1000, startBufferOptionsMs: [1000, 1500, 2250])
    ))
    .padding(.top)
}

#Preview("No banners") {
    StatusBanners(snapshot: nil)
}
