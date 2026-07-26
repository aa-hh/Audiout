// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// Sheet listing `snapshot.addableApps` — apps the Mac is actually able to
/// route (already sorted and bounded server-side) but has no route for yet.
/// Tapping one calls `addAppRoute` and dismisses; refusals (route caps,
/// excluded apps) come back as toasts through `ToastCenter` — this sheet
/// never duplicates that logic, it only calls the command and gets out of
/// the way.
struct AddAppSheet: View {
    let session: any MacSessionProtocol
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add App")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        let apps = session.snapshot?.addableApps ?? []
        if apps.isEmpty {
            ContentUnavailableView(
                "Nothing to Add",
                systemImage: "square.grid.2x2",
                description: Text("Nothing else is playing audio on the Mac right now.")
            )
        } else {
            List(apps, id: \.bundleID) { app in
                Button {
                    session.addAppRoute(bundleID: app.bundleID, displayName: app.displayName)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        AppGlyph(bundleID: app.bundleID, displayName: app.displayName)
                        Text(app.displayName)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
            }
        }
    }
}

#Preview("With addable apps") {
    AddAppSheet(session: DemoMacSession())
}

#Preview("Empty") {
    let session = DemoMacSession()
    session.addAppRoute(bundleID: "com.demo.video", displayName: "Demo Video")
    return AddAppSheet(session: session)
}
