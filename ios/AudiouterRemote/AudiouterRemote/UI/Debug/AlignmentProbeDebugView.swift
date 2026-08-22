// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import AudiouterProtocol
import ProbeKit

/// Debug-only screen for the BT auto-cal spike
/// (dev/notes/bt-autocal-spike-spec.md): pick a Bluetooth target + a
/// reference, record the Mac's alternating-mute tick probe on the phone's
/// mic, run ``ProbeAnalyzer`` on the result, and either apply or discard the
/// recovered offset. Spike UI only — no onboarding, no polish, reachable
/// only from the DEBUG-gated section in ``RemoteSettingsView`` (the same
/// convention as that view's other `#if DEBUG` tuners).
///
/// This screen never derives the measurement math or the trim sign itself —
/// it just shows Track B's (``ProbeKit``) raw result and forwards it to the
/// Mac (Track A) via `submitProbeResult`, exactly as the spec assigns.
struct AlignmentProbeDebugView: View {
    let session: any MacSessionProtocol

    @State private var targetDeviceID: String?
    @State private var referenceDeviceID: String?
    @State private var capture = ProbeCaptureSession()
    @State private var phase: Phase = .idle
    @State private var micPermissionDenied = false
    @State private var errorText: String?
    @State private var result: ProbeAnalysis?

    private enum Phase: Equatable {
        case idle, capturing, analyzing, done
    }

    /// Preamble before the first REF block — matches the spec's "Probe audio
    /// pattern" section; ``ProbePattern`` itself only carries the repeating
    /// part, since the preamble isn't something the analyzer needs to know.
    private static let preambleSeconds: Double = 5

    private static var patternDurationSeconds: Double {
        let p = ProbePattern.spike
        let perRepetition = Double(2 * p.ticksPerBlock + 2 * p.gapBeats) * p.beatPeriodSeconds
        return preambleSeconds + Double(p.repetitions) * perRepetition
    }

    private var devices: [DeviceState] { session.snapshot?.devices ?? [] }
    private var targets: [DeviceState] { devices.filter { $0.kind == "bluetooth" } }
    private var references: [DeviceState] { devices.filter { $0.id != targetDeviceID } }

    var body: some View {
        Form {
            if micPermissionDenied {
                Section { micDeniedView }
            }

            Section("Target (Bluetooth device)") {
                Picker("Target", selection: $targetDeviceID) {
                    Text("None").tag(String?.none)
                    ForEach(targets, id: \.id) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                if targets.isEmpty {
                    Text("No Bluetooth devices in the current snapshot.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Reference") {
                Picker("Reference", selection: $referenceDeviceID) {
                    Text("Main Out").tag(String?.none)
                    ForEach(references, id: \.id) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
            }

            Section {
                phaseControls
            } footer: {
                if phase == .capturing || phase == .analyzing {
                    Text("Pattern runs about \(Int(Self.patternDurationSeconds)) seconds; recording stops automatically when it ends.")
                }
            }
        }
        .navigationTitle("Alignment Probe")
        .onChange(of: session.snapshot?.alignmentProbe?.state) { _, newValue in
            guard phase == .capturing, newValue != "running" else { return }
            finishCaptureAndAnalyze()
        }
    }

    @ViewBuilder
    private var phaseControls: some View {
        switch phase {
        case .idle:
            Button("Start") { start() }
                .disabled(targetDeviceID == nil)
        case .capturing:
            HStack {
                ProgressView()
                Text("Recording…")
            }
            Button("Cancel", role: .destructive) { cancel() }
        case .analyzing:
            HStack {
                ProgressView()
                Text("Analyzing…")
            }
        case .done:
            if let result {
                resultView(result)
            } else if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
            Button("Reset") { reset() }
        }
    }

    private func resultView(_ analysis: ProbeAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Offset", value: String(format: "%.1f ms", analysis.offsetMs))
            LabeledContent("Spread", value: String(format: "%.1f ms", analysis.spreadMs))
            LabeledContent("Used pairs", value: "\(analysis.usedPairs)")
            LabeledContent("Confident", value: analysis.confident ? "Yes" : "No")
            HStack {
                Button("Discard") { reset() }
                Spacer()
                Button("Apply") { apply(analysis) }
            }
        }
    }

    private var micDeniedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Microphone Access Needed").font(.headline)
            } icon: {
                Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
            }
            Text("The probe records with the microphone to measure speaker timing. Allow it in Settings to run a probe.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Actions

    private func start() {
        guard let targetDeviceID else { return }
        Task {
            guard await ProbeCaptureSession.requestPermission() else {
                micPermissionDenied = true
                return
            }
            micPermissionDenied = false
            do {
                try capture.start()
            } catch {
                errorText = "Couldn't start recording: \(error)"
                result = nil
                phase = .done
                return
            }
            errorText = nil
            result = nil
            phase = .capturing
            session.startAlignmentProbe(targetDeviceID: targetDeviceID, referenceDeviceID: referenceDeviceID)
            let deadline = Self.patternDurationSeconds
            DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
                guard phase == .capturing else { return }
                finishCaptureAndAnalyze()
            }
        }
    }

    private func cancel() {
        session.cancelAlignmentProbe()
        _ = capture.stop()
        phase = .idle
    }

    private func reset() {
        result = nil
        errorText = nil
        phase = .idle
    }

    /// Fires either from the Mac's snapshot reporting the run ended, or from
    /// the pattern-duration fallback timer — whichever lands first; the
    /// `phase == .capturing` guard on both call sites makes the second one a
    /// no-op.
    private func finishCaptureAndAnalyze() {
        guard phase == .capturing else { return }
        phase = .analyzing
        let samples = capture.stop()
        let sampleRate = capture.sampleRate
        Task {
            do {
                let analysis = try ProbeAnalyzer(sampleRate: sampleRate, pattern: .spike).analyze(recording: samples)
                result = analysis
                errorText = nil
            } catch {
                result = nil
                errorText = "\(error)"
            }
            phase = .done
        }
    }

    private func apply(_ analysis: ProbeAnalysis) {
        guard let targetDeviceID else { return }
        session.submitProbeResult(
            targetDeviceID: targetDeviceID,
            offsetMs: analysis.offsetMs,
            spreadMs: analysis.spreadMs,
            confident: analysis.confident
        )
        reset()
    }
}

// MARK: - Previews

#Preview {
    NavigationStack {
        AlignmentProbeDebugView(session: DemoMacSession())
    }
}
