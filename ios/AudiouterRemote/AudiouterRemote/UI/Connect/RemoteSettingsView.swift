// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// The Mac-settings half of tab 4 (D10): exactly two remote controls —
/// connect volume and the audio start buffer. Sync offset, excluded apps and
/// theme are Mac-only and never surface here.
///
/// Connect volume follows the same local-echo-while-dragging pattern as
/// `DeviceRowView`/`SpeakersView`'s sliders: `localConnectVolume` tracks the
/// thumb during a drag so the ~50ms coalesced effect from the Mac never
/// fights the user's finger, then clears on release to reconcile from the
/// next snapshot.
///
/// The audio buffer picker is the opposite of live: selecting a value only
/// stages it in `stagedBufferMs` (D10 — "never a live control"). Nothing is
/// sent until "Apply & Reconnect" is tapped. The button stays disabled until
/// the staged value differs from `snapshot.settings.startBufferMs`, AND
/// (`isApplyingBuffer`) stays disabled again after a tap, because the Mac
/// refuses a second apply while one is already in flight — so the button
/// only re-enables once the snapshot itself reports the new value (handled
/// in the `onChange` below), not just when the network call returns. If a
/// refusal toast arrives while an apply is in flight (the attempt itself
/// failed rather than a stale double-tap), `isApplyingBuffer` is cleared so
/// the user can retry without losing their staged selection.
struct RemoteSettingsView: View {
    let session: any MacSessionProtocol

    @State private var localConnectVolume: Double?
    @State private var stagedBufferMs: Int?
    @State private var isApplyingBuffer = false

    init(session: any MacSessionProtocol) {
        self.session = session
    }

    /// Preview-only seam: seeds a staged-but-unapplied buffer value so a
    /// `#Preview` can show the Apply button enabled without simulating a
    /// picker interaction. Never called outside `#Preview`.
    fileprivate init(session: any MacSessionProtocol, previewStagedBufferMs: Int) {
        self.session = session
        _stagedBufferMs = State(initialValue: previewStagedBufferMs)
    }

    var body: some View {
        Form {
            if let snapshot = session.snapshot {
                connectVolumeSection(snapshot)
                bufferSection(snapshot)
            } else {
                Section {
                    Text("Connect to a Mac to see its settings.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Label(
                    "Sync offset, excluded apps, and appearance are configured on the Mac.",
                    systemImage: "laptopcomputer"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Mac Settings")
        .onChange(of: session.snapshot?.settings.startBufferMs) { _, newValue in
            guard let staged = stagedBufferMs, let newValue, newValue == staged else { return }
            stagedBufferMs = nil
            isApplyingBuffer = false
        }
        .onChange(of: session.toasts.current) { _, _ in
            guard isApplyingBuffer else { return }
            isApplyingBuffer = false
        }
        .toastOverlay(session.toasts)
    }

    // MARK: Connect volume

    private func connectVolumeSection(_ snapshot: Snapshot) -> some View {
        Section {
            Slider(
                value: Binding(
                    get: { localConnectVolume ?? Double(snapshot.settings.connectVolume) },
                    set: { newValue in
                        localConnectVolume = newValue
                        session.setConnectVolume(Int(newValue.rounded()), isFinal: false)
                    }
                ),
                in: Double(snapshot.settings.connectVolumeMin)...Double(snapshot.settings.connectVolumeMax),
                step: 1,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    let final = Int((localConnectVolume ?? Double(snapshot.settings.connectVolume)).rounded())
                    session.setConnectVolume(final, isFinal: true)
                    localConnectVolume = nil
                }
            )
            .accessibilityLabel("Connect volume")
            .accessibilityValue("\(Int(localConnectVolume ?? Double(snapshot.settings.connectVolume))) percent")
        } header: {
            Text("Connect Volume")
        } footer: {
            Text("The volume a speaker starts at when it joins.")
        }
    }

    // MARK: Audio buffer

    private func bufferSection(_ snapshot: Snapshot) -> some View {
        let current = snapshot.settings.startBufferMs
        let staged = stagedBufferMs ?? current
        let canApply = staged != current && !isApplyingBuffer

        return Section {
            Picker("Audio Buffer", selection: Binding(
                get: { staged },
                set: { stagedBufferMs = $0 }
            )) {
                ForEach(snapshot.settings.startBufferOptionsMs, id: \.self) { ms in
                    Text("\(ms) ms").tag(ms)
                }
            }
            .accessibilityLabel("Audio buffer size")
            .accessibilityValue(
                staged != current ? "\(staged) milliseconds, not yet applied" : "\(staged) milliseconds"
            )

            Button {
                isApplyingBuffer = true
                session.setStartBufferMs(staged)
            } label: {
                if isApplyingBuffer {
                    HStack {
                        ProgressView()
                        Text("Applying…")
                    }
                } else {
                    Text("Apply & Reconnect")
                }
            }
            .disabled(!canApply)
            .accessibilityHint(
                "Briefly interrupts audio on all speakers, about 3 to 5 seconds, while the Mac reconnects them at the new buffer size."
            )
        } header: {
            Text("Audio Buffer")
        } footer: {
            Text("Applying briefly interrupts audio on all speakers (about 3–5 seconds) while the Mac tears down and re-establishes each stream.")
        }
    }
}

// MARK: - Previews

#Preview("Default") {
    NavigationStack {
        RemoteSettingsView(session: DemoMacSession())
    }
}

#Preview("Staged buffer change") {
    let demo = DemoMacSession()
    // Pick an option that isn't the current value, so Apply & Reconnect
    // previews enabled.
    let current = demo.snapshot!.settings.startBufferMs
    let staged = demo.snapshot!.settings.startBufferOptionsMs.first { $0 != current } ?? current
    return NavigationStack {
        RemoteSettingsView(session: demo, previewStagedBufferMs: staged)
    }
}
