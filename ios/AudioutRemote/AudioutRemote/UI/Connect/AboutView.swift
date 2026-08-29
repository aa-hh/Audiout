// Copyright (c) 2026 ahh. All rights reserved.

import SwiftUI

/// Static app identity + orientation, no external links. App name is read
/// from the bundle rather than hardcoded: `INFOPLIST_KEY_CFBundleDisplayName`
/// is the single source of truth, and a test build overrides it per install
/// (`scripts/ios.sh device --name`), so a literal here would go wrong.
struct AboutView: View {
    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? "Audiout Remote"
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 4) {
                    Image(systemName: "hifispeaker.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(appName)
                        .font(.title2.weight(.semibold))
                    Text(versionString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(appName), \(versionString)")
            }
            .listRowBackground(Color.clear)

            Section {
                Label(
                    "Needs the Audiout app running on a Mac on the same Wi-Fi network.",
                    systemImage: "wifi"
                )
                Label(
                    "The Mac asks you to approve this phone the first time you connect. After that, it reconnects on its own.",
                    systemImage: "checkmark.shield"
                )
            } header: {
                Text("How It Works")
            }
        }
        .navigationTitle("About")
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
