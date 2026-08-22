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
    @State private var lastRecordingURL: URL?
    @State private var recordedSeconds: Double = 0
    @State private var applied = false
    @State private var history: [ProbeRunRecord] = []
    @State private var currentRecordID: UUID?

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

            if !history.isEmpty {
                Section {
                    ForEach(history) { record in historyRow(record) }
                } header: {
                    Text("History")
                } footer: {
                    if let logURL = ProbeRunLog.exportURL() {
                        ShareLink("Export log (JSON)", item: logURL)
                    }
                }
            }
        }
        .navigationTitle("Alignment Probe")
        .onAppear { history = ProbeRunLog.load() }
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
            if recordedSeconds > 0, recordedSeconds < Self.patternDurationSeconds - 2 {
                Label(String(format: "Recording truncated: %.1f s of %.0f s — keep the app open and the screen on for the whole run.",
                             recordedSeconds, Self.patternDurationSeconds),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            if let result {
                resultView(result)
            } else if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
            if let lastRecordingURL {
                ShareLink("Export recording", item: lastRecordingURL)
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
            if applied {
                Label("Applied — the Mac has updated this speaker's trim.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.footnote)
            } else {
                HStack {
                    Button("Discard") { reset() }
                    Spacer()
                    Button("Apply") { apply(analysis) }
                }
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
            applied = false
            phase = .capturing
            // Locking the screen suspends the mic tap and silently truncates
            // the take (live finding: 26 s of a 45 s pattern) — hold the
            // screen awake for the run; cleared again on every finish path.
            UIApplication.shared.isIdleTimerDisabled = true
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
        UIApplication.shared.isIdleTimerDisabled = false
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
        UIApplication.shared.isIdleTimerDisabled = false
        let samples = capture.stop()
        let sampleRate = capture.sampleRate
        recordedSeconds = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        Task {
            // Persist every take before analysis so a failed run can be
            // exported and re-analyzed on a Mac (spike diagnostics).
            lastRecordingURL = Self.writeWAV(samples, sampleRate: sampleRate)
            do {
                let analysis = try ProbeAnalyzer(sampleRate: sampleRate, pattern: .spike).analyze(recording: samples)
                result = analysis
                errorText = nil
                if let targetDeviceID {
                    let record = ProbeRunRecord(
                        id: UUID(), date: Date(),
                        targetDeviceID: targetDeviceID,
                        targetName: devices.first { $0.id == targetDeviceID }?.name ?? targetDeviceID,
                        referenceName: referenceDeviceID.flatMap { id in devices.first { $0.id == id }?.name } ?? "Main Out",
                        offsetMs: analysis.offsetMs, spreadMs: analysis.spreadMs,
                        usedPairs: analysis.usedPairs, confident: analysis.confident,
                        recordedSeconds: recordedSeconds,
                        trimMsAtRun: devices.first { $0.id == targetDeviceID }?.syncTrimMs,
                        applied: false, earSaidInSync: nil)
                    currentRecordID = record.id
                    history = ProbeRunLog.append(record)
                }
            } catch {
                result = nil
                errorText = "\(error)"
            }
            phase = .done
        }
    }

    private func historyRow(_ record: ProbeRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                Spacer()
                Text(String(format: "%+.1f ms", record.offsetMs)).monospacedDigit().bold()
            }
            .font(.footnote)
            HStack(spacing: 6) {
                Text(String(format: "±%.1f · %d pairs", record.spreadMs, record.usedPairs))
                if let trim = record.trimMsAtRun {
                    Text(String(format: "· trim %+.0f", trim))
                }
                if !record.confident { Text("· not confident").foregroundStyle(.orange) }
                if record.applied { Text("· applied").foregroundStyle(.green) }
                Spacer()
                // The study's ear column: what did the room sound like
                // BEFORE this run? Tap to cycle unknown → in sync → flam.
                Button {
                    var updated = record
                    switch record.earSaidInSync {
                    case nil: updated.earSaidInSync = true
                    case true?: updated.earSaidInSync = false
                    case false?: updated.earSaidInSync = nil
                    }
                    ProbeRunLog.update(updated)
                    history = ProbeRunLog.load()
                } label: {
                    switch record.earSaidInSync {
                    case nil: Text("ear?")
                    case true?: Text("ear: sync").foregroundStyle(.green)
                    case false?: Text("ear: flam").foregroundStyle(.red)
                    }
                }
                .buttonStyle(.borderless)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// Mono 16-bit PCM WAV of the take, in the temporary directory.
    /// razor: spike diagnostics — delete with this debug surface.
    private static func writeWAV(_ samples: [Float], sampleRate: Double) -> URL? {
        let rate = UInt32(sampleRate.rounded())
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            var v = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + pcm.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(rate); append32(rate * 2); append16(2); append16(16)
        append("data"); append32(UInt32(pcm.count)); data.append(pcm)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-take-\(Int(Date().timeIntervalSince1970)).wav")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
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
        // Keep the numbers on screen as a receipt (live finding: a vanishing
        // result reads as a glitch and loses the measurement).
        applied = true
        if let currentRecordID, var record = history.first(where: { $0.id == currentRecordID }) {
            record.applied = true
            ProbeRunLog.update(record)
            history = ProbeRunLog.load()
        }
    }
}

// MARK: - Previews

#Preview {
    NavigationStack {
        AlignmentProbeDebugView(session: DemoMacSession())
    }
}
