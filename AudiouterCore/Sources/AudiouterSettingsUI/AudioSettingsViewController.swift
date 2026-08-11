// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import UniformTypeIdentifiers
import AudiouterCore
import AudiouterSharedUI

/// Everything the Audio pane's **Advanced › Audio buffer** control needs from
/// the app layer (PLAN-LATENCY-SETTING.md). Built by the app ONLY when the
/// resolved backend is `LatencyConfigurable` — the pane renders no Advanced
/// section at all when this is nil, so backends without the concept (mock-less
/// builds, OwnTone) never show a dead knob.
public struct LatencySettingModel {
    /// The offered buffer values in ms (`AppSettings.startBufferOptionsMs`).
    public let optionsMs: [Int]
    /// The value in force at pane creation (persisted setting, or the env
    /// override when one won at launch).
    public let initialMs: Int
    /// Non-nil when `AIRPLAY_START_BUFFER_MS` overrode the setting for this
    /// launch: the control renders disabled with an explanatory note.
    public let envOverrideMs: Int?
    /// Whether any device is currently streaming — drives the reconnect status
    /// UI ("Reconnecting speakers…" / "Speakers reconnected" vs plain "Applied").
    public let isStreaming: @MainActor () -> Bool
    /// Persist + apply the new value; returns when the reconnect pass is done.
    public let apply: @MainActor (Int) async -> Void

    public init(optionsMs: [Int],
                initialMs: Int,
                envOverrideMs: Int?,
                isStreaming: @escaping @MainActor () -> Bool,
                apply: @escaping @MainActor (Int) async -> Void) {
        self.optionsMs = optionsMs
        self.initialMs = initialMs
        self.envOverrideMs = envOverrideMs
        self.isStreaming = isStreaming
        self.apply = apply
    }
}

/// Everything the Audio pane's **wake-restore** control needs from the app layer
/// (B6b). If, after the Mac wakes from sleep, a selected speaker doesn't reconnect
/// within the chosen delay, the backend un-mutes the Mac's own output (the stuck
/// capture gate is lifted without clearing the user's selection). Options are in
/// MINUTES (`0` = Never — `AppSettings.wakeRestoreMinuteOptions`); `apply` persists
/// the choice and pushes it to the backend.
public struct WakeAudioRestoreModel {
    /// The offered fallback delays in minutes (`0` = Never).
    public let minuteOptions: [Int]
    /// The persisted value in force at pane creation.
    public let initialMinutes: Int
    /// Persist + push the new value to the backend (fires on every popup change).
    public let apply: @MainActor (Int) -> Void

    public init(minuteOptions: [Int],
                initialMinutes: Int,
                apply: @escaping @MainActor (Int) -> Void) {
        self.minuteOptions = minuteOptions
        self.initialMinutes = initialMinutes
        self.apply = apply
    }
}

/// Settings › **Audio** pane. Step 3: the **excluded applications** denylist,
/// plus (2026-07-17, PLAN-LATENCY-SETTING.md) the **Advanced › Audio buffer**
/// control.
///
/// LOCKED DECISION (2026-07-17): "excluded" means *never captured* — the app
/// always plays locally and can't be routed. This pane only edits the list
/// (persisted via `ExcludedAppsController`); the app layer enforces the
/// precedence (pruning any route for a newly-excluded app) via ``onChange``.
///
/// The list is a bordered column of `icon · name · remove` rows plus an "Add
/// application…" row that doubles as the empty state — the same idiom as the
/// popover's Applications card. Add offers running apps, plus "Choose from
/// Finder…" so a not-currently-running app (e.g. a comms app) can be
/// pre-excluded.
///
/// **Audio buffer (Advanced):** an `NSPopUpButton` of bare millisecond values
/// (numeric by design — named presets with embedded delay text don't survive
/// localization; the one localizable sentence is the caption). Changing the
/// popup applies immediately (V1, PLAN-ONE-SURFACE-032.md — no CTA): while
/// streaming, the apply tears down and re-establishes the live sessions (a
/// ~3–5 s audible gap), so a spinner + "Reconnecting speakers…" replaces the
/// idle state; when idle it applies silently. Either way, completion shows a
/// transient confirmation, and the hint line says up front that changing the
/// value reconnects active speakers. When `AIRPLAY_START_BUFFER_MS` overrode
/// the setting at launch the control renders disabled with a note instead.
@MainActor
public final class AudioSettingsViewController: NSViewController {

    private let excluded: ExcludedAppsController
    private let runningAppsProvider: () -> [AppPickerItem]
    private let latency: LatencySettingModel?
    private let wakeRestore: WakeAudioRestoreModel?

    /// Persistence for the connect-volume row. Read/written DIRECTLY here (not via
    /// an injected app-layer model like `latency`/`wakeRestore`) on purpose: the
    /// seed that consumes it — ``NativeBackend/connectVolumeSeed`` — reads
    /// `AppSettings.connectVolume` LIVE on the next connect, so persisting the new
    /// value is the whole job; there is nothing to push to a running session.
    /// Injectable so tests use a throwaway `UserDefaults` suite, never `.standard`.
    private let settings: AppSettings

    // Connect-volume state.
    private let connectVolumeSlider = NSSlider()
    private let connectVolumeValueLabel = NSTextField(labelWithString: "")
    private let connectVolumeHint = SettingsForm.hintLabel()

    // Wake-restore state (nil/untouched when `wakeRestore` is nil).
    private let wakeRestorePopup = NSPopUpButton()
    private let wakeRestoreHint = SettingsForm.hintLabel()

    /// Fired after the denylist changes so the app can enforce precedence (prune
    /// routes) and refresh the popover.
    public var onChange: (() -> Void)?

    /// Fired after a connect-volume change or a buffer-apply commits (T6), so
    /// the app can broadcast the new settings to the companion app. Nil
    /// (unset) is a no-op — the app layer claims it in `openSettings`, same
    /// single-assignment idiom as ``onChange``.
    public var onSettingChanged: (() -> Void)?

    private let listStack = NSStackView()
    private let listContainer = BorderedListView()

    // Advanced › Audio buffer state (all nil/untouched when `latency` is nil).
    private let bufferPopup = NSPopUpButton()
    private let bufferHint = SettingsForm.hintLabel()
    // Advanced › Sync offset state (T-OFFSET-UI; mounts alongside the buffer
    // control — same `latency != nil` native-backend gate, since the offset only
    // feeds `SyncedLocalSink`, a native-only feature).
    private let syncOffsetSlider = NSSlider()
    private let syncOffsetValueLabel = NSTextField(labelWithString: "")
    // Apply-in-progress feedback for the buffer popup (V1: applies immediately,
    // no CTA — see `applyBuffer(_:)`).
    private let applySpinner = NSProgressIndicator()
    private let applyStatusLabel = NSTextField(labelWithString: "")
    private var appliedMs = 0
    private var isApplying = false
    private var statusResetWorkItem: DispatchWorkItem?

    private static let rowHeight: CGFloat = 34

    public init(excluded: ExcludedAppsController,
                runningAppsProvider: @escaping () -> [AppPickerItem] = RunningApps.regularRunningApps,
                settings: AppSettings = AppSettings(),
                latency: LatencySettingModel? = nil,
                wakeRestore: WakeAudioRestoreModel? = nil) {
        self.excluded = excluded
        self.runningAppsProvider = runningAppsProvider
        self.settings = settings
        self.latency = latency
        self.wakeRestore = wakeRestore
        super.init(nibName: nil, bundle: nil)
        title = "Audio"
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let heading = SettingsForm.label("Excluded applications")
        heading.font = Tokens.Font.body

        // `hintLabel`, not a hand-rolled `label` + wrap properties: it also
        // resolves `preferredMaxLayoutWidth`, without which this sentence's
        // unwrapped width drags the whole pane (and the live window) wider
        // than the fixed content column — see hintLabel's doc comment.
        let subtitle = SettingsForm.hintLabel(
            "Audio from these apps always plays on your Mac — never sent to speakers.")

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 4),
            listStack.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: -4),
        ])

        let column = NSStackView(views: [heading, subtitle, listContainer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false

        for sectionView in makeConnectVolumeSectionViews() {
            column.addArrangedSubview(sectionView)
            sectionView.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        if wakeRestore != nil {
            for sectionView in makeWakeRestoreSectionViews() {
                column.addArrangedSubview(sectionView)
                sectionView.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }

        if latency != nil {
            for sectionView in makeAdvancedSectionViews() {
                column.addArrangedSubview(sectionView)
                sectionView.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: SettingsForm.contentWidth),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsForm.horizontalPadding),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsForm.horizontalPadding),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: SettingsForm.verticalPadding),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -SettingsForm.verticalPadding),
            subtitle.widthAnchor.constraint(equalTo: column.widthAnchor),
            listContainer.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        view = container
        rebuildList()
    }

    // MARK: Connect volume (G1-N1)

    /// Format a percent as a bare locale-aware number + "%".
    private static func percentLabel(_ percent: Int) -> String {
        "\(msFormatter.string(from: NSNumber(value: percent)) ?? String(percent))%"
    }

    /// The connect-volume sub-section: hairline + heading + a slider row. Mounts
    /// unconditionally (a universal preference; only the native backend acts on it,
    /// which is the shipping backend). The slider is bounded to
    /// ``AppSettings/minConnectVolume``…``AppSettings/maxConnectVolume`` so the UI
    /// itself can never select 0/silent. Persists on change — no CTA, since it only
    /// affects the NEXT speaker connect, never a live session.
    private func makeConnectVolumeSectionViews() -> [NSView] {
        var views: [NSView] = []

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        views.append(hairline)

        connectVolumeSlider.translatesAutoresizingMaskIntoConstraints = false
        connectVolumeSlider.minValue = Double(AppSettings.minConnectVolume)
        connectVolumeSlider.maxValue = Double(AppSettings.maxConnectVolume)
        connectVolumeSlider.integerValue = settings.connectVolume
        connectVolumeSlider.isContinuous = true
        connectVolumeSlider.target = self
        connectVolumeSlider.action = #selector(connectVolumeChanged)
        connectVolumeSlider.setAccessibilityLabel("Volume when connecting a speaker")
        connectVolumeSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        connectVolumeValueLabel.font = Tokens.Font.body
        connectVolumeValueLabel.textColor = Tokens.Color.secondaryLabel
        connectVolumeValueLabel.alignment = .right
        connectVolumeValueLabel.stringValue = Self.percentLabel(settings.connectVolume)
        // Fixed width so the row doesn't shift as the number's digit count changes.
        connectVolumeValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let control = NSStackView(views: [connectVolumeSlider, connectVolumeValueLabel])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = 8
        control.translatesAutoresizingMaskIntoConstraints = false

        views.append(SettingsForm.row(
            title: "Volume when connecting a speaker",
            control: control))

        // Live hint (spec §5.2): re-written on every drag, so the consequence
        // of the chosen level is always spelled out — replaces the old static
        // subtitle.
        connectVolumeHint.stringValue = Self.connectVolumeHintLine(settings.connectVolume)
        views.append(connectVolumeHint)
        return views
    }

    /// The connect-volume live hint: value + consequence, the
    /// "`Buffer: 120 ms — safe for Wi-Fi speakers`" pattern.
    private static func connectVolumeHintLine(_ percent: Int) -> String {
        let consequence: String
        switch percent {
        case ..<21:  consequence = "a quiet, gentle start"
        case ..<51:  consequence = "a moderate, comfortable start"
        case ..<76:  consequence = "a loud start"
        default:     consequence = "a very loud start — may startle"
        }
        return "Connects at \(percentLabel(percent)) — \(consequence). "
            + "Each speaker's own slider takes over right after."
    }

    /// Re-read the two values a REMOTE client can also change (the phone's
    /// `setConnectVolume` / `setStartBufferMs`) and repaint their controls.
    ///
    /// This pane builds its controls once and the surface caches the whole
    /// screen for the process's life, so without this a phone-driven change
    /// left the slider and popup showing the launch-time values permanently —
    /// not just until the pane was reopened. The stored settings themselves
    /// were always correct; only this paint was stale.
    ///
    /// Called when the Settings screen BECOMES VISIBLE, deliberately not on
    /// every remote write: `connectVolumeSlider` is `isContinuous`, so writing
    /// to it while the user is dragging would fight the drag — and nobody can
    /// be dragging a control on a screen that is only now appearing.
    public func reloadFromSettings() {
        // Nothing to reconcile before the controls exist — and the load path
        // reads `settings` itself, so an unloaded pane comes up current. This
        // must NOT force the view: building a whole pane to answer a reconcile
        // is the opposite of what the caller asked for.
        guard isViewLoaded else { return }

        let percent = settings.connectVolume
        connectVolumeSlider.integerValue = percent
        connectVolumeValueLabel.stringValue = Self.percentLabel(percent)
        connectVolumeHint.stringValue = Self.connectVolumeHintLine(percent)

        // The buffer popup is disabled outright under an env override, and
        // then its one item is that override — nothing to reconcile.
        guard let latency, latency.envOverrideMs == nil else { return }
        let ms = settings.startBufferMs
        appliedMs = ms
        if let index = latency.optionsMs.firstIndex(of: ms) {
            bufferPopup.selectItem(at: index)
        }
        bufferHint.stringValue = Self.bufferHintLine(ms)
    }

    @objc private func connectVolumeChanged() {
        let percent = connectVolumeSlider.integerValue
        connectVolumeValueLabel.stringValue = Self.percentLabel(percent)
        connectVolumeHint.stringValue = Self.connectVolumeHintLine(percent)
        settings.connectVolume = percent
        onSettingChanged?()
    }

    // MARK: Wake restore (B6b)

    /// Format one option as "Never" / "1 minute" / "N minutes" (bare number + unit
    /// by design — house style, `AppSettings.wakeRestoreMinuteOptions`).
    private static func wakeMinutesLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Never"
        case 1: return "1 minute"
        default: return "\(minutes) minutes"
        }
    }

    /// The wake-restore sub-section: hairline + heading + the popup row. Applies
    /// immediately on change (persist + push to backend) — no CTA, since un-gating
    /// the Mac's own output on a future wake has no live-session cost now.
    private func makeWakeRestoreSectionViews() -> [NSView] {
        guard let wakeRestore else { return [] }
        var views: [NSView] = []

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        views.append(hairline)

        wakeRestorePopup.translatesAutoresizingMaskIntoConstraints = false
        for minutes in wakeRestore.minuteOptions {
            wakeRestorePopup.addItem(withTitle: Self.wakeMinutesLabel(minutes))
        }
        if let index = wakeRestore.minuteOptions.firstIndex(of: wakeRestore.initialMinutes) {
            wakeRestorePopup.selectItem(at: index)
        }
        wakeRestorePopup.target = self
        wakeRestorePopup.action = #selector(wakeRestoreChanged)
        wakeRestorePopup.setAccessibilityLabel("Restore Mac audio if speakers don't reconnect")

        views.append(SettingsForm.row(
            title: "Restore Mac audio if speakers don't reconnect",
            control: wakeRestorePopup))

        // Live hint (spec §5.2) — re-written on every popup change.
        wakeRestoreHint.stringValue = Self.wakeRestoreHintLine(wakeRestore.initialMinutes)
        views.append(wakeRestoreHint)
        return views
    }

    /// The wake-restore live hint: what the chosen delay actually does after a
    /// wake from sleep.
    private static func wakeRestoreHintLine(_ minutes: Int) -> String {
        guard minutes != 0 else {
            return "Never — after waking, this Mac stays silent until the speakers reconnect."
        }
        return "After waking, if the speakers are still gone after "
            + "\(wakeMinutesLabel(minutes).lowercased()), audio plays on this Mac instead."
    }

    @objc private func wakeRestoreChanged() {
        guard let wakeRestore else { return }
        let index = wakeRestorePopup.indexOfSelectedItem
        guard wakeRestore.minuteOptions.indices.contains(index) else { return }
        let minutes = wakeRestore.minuteOptions[index]
        wakeRestoreHint.stringValue = Self.wakeRestoreHintLine(minutes)
        wakeRestore.apply(minutes)
    }

    // MARK: Advanced › Audio buffer (PLAN-LATENCY-SETTING.md)

    /// Format one option as a bare locale-aware number + "ms" (numeric labels by
    /// design — see the type comment).
    private static let msFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func msLabel(_ ms: Int) -> String {
        "\(msFormatter.string(from: NSNumber(value: ms)) ?? String(ms)) ms"
    }

    /// Format a signed offset as a bare, locale-aware "+N ms" / "−N ms" / "0 ms"
    /// (numeric by design, same house rule as ``msLabel(_:)`` — no named preset
    /// text). Unlike ``msLabel(_:)`` this can be negative, so the sign is made
    /// explicit rather than relying on the formatter's default minus glyph.
    private static func syncOffsetLabel(_ ms: Int) -> String {
        let magnitude = msFormatter.string(from: NSNumber(value: abs(ms))) ?? String(abs(ms))
        let sign = ms > 0 ? "+" : (ms < 0 ? "\u{2212}" : "")
        return "\(sign)\(magnitude) ms"
    }

    /// The Advanced sub-section's stacked views: hairline + "Advanced" label +
    /// the Audio buffer row (+ env-override note, or the apply-feedback row).
    private func makeAdvancedSectionViews() -> [NSView] {
        guard let latency else { return [] }
        var views: [NSView] = []

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        views.append(hairline)

        let advancedLabel = SettingsForm.label("Advanced")
        advancedLabel.font = Tokens.Font.captionEmphasized
        advancedLabel.textColor = Tokens.Color.secondaryLabel
        views.append(advancedLabel)

        // The popup: numeric options, or the env value alone (disabled) when
        // an env override won at launch.
        bufferPopup.translatesAutoresizingMaskIntoConstraints = false
        if let envMs = latency.envOverrideMs {
            bufferPopup.addItem(withTitle: Self.msLabel(envMs))
            bufferPopup.isEnabled = false
        } else {
            for option in latency.optionsMs {
                bufferPopup.addItem(withTitle: Self.msLabel(option))
            }
            appliedMs = latency.initialMs
            if let index = latency.optionsMs.firstIndex(of: latency.initialMs) {
                bufferPopup.selectItem(at: index)
            }
            bufferPopup.target = self
            bufferPopup.action = #selector(bufferOptionChanged)
        }
        bufferPopup.setAccessibilityLabel("Audio buffer")

        views.append(SettingsForm.row(
            title: "Audio buffer",
            control: bufferPopup))

        // Live hint (spec §5.2 — the "`Buffer: 120 ms — safe for Wi-Fi
        // speakers`" pattern itself): re-written on every popup change,
        // states the currently-applied value's consequence AND that changing
        // it reconnects active speakers (V1: the popup applies immediately,
        // there's no CTA to carry that warning instead).
        bufferHint.stringValue = Self.bufferHintLine(latency.envOverrideMs ?? latency.initialMs)
        views.append(bufferHint)
        views.append(contentsOf: makeSyncOffsetSectionViews())

        if let envMs = latency.envOverrideMs {
            let note = SettingsForm.label(
                "Your buffer is locked to \(Self.msLabel(envMs)) by a launch option for this session.")
            note.font = Tokens.Font.caption
            note.textColor = Tokens.Color.warning
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 0
            // Not `hintLabel` (wrong color: this one's `.warning`, not
            // `.secondaryLabel`) but it needs the SAME `preferredMaxLayoutWidth`
            // fix — see hintLabel's doc comment for why an unset one drags the
            // whole pane wider than the fixed content column.
            note.preferredMaxLayoutWidth = SettingsForm.contentWidth - 40
            views.append(note)
            return views
        }

        // Apply-in-progress feedback: spinner + status label, fixed height so
        // the transition never resizes the window. No button — picking a
        // popup option applies it directly (`bufferOptionChanged`).
        applySpinner.translatesAutoresizingMaskIntoConstraints = false
        applySpinner.style = .spinning
        applySpinner.controlSize = .small
        applySpinner.isDisplayedWhenStopped = false

        applyStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        applyStatusLabel.font = Tokens.Font.caption
        applyStatusLabel.textColor = Tokens.Color.secondaryLabel
        applyStatusLabel.isHidden = true

        let statusRow = NSView()
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addSubview(applySpinner)
        statusRow.addSubview(applyStatusLabel)
        NSLayoutConstraint.activate([
            statusRow.heightAnchor.constraint(equalToConstant: 20),
            applySpinner.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor),
            applySpinner.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            applyStatusLabel.leadingAnchor.constraint(equalTo: applySpinner.trailingAnchor, constant: 6),
            applyStatusLabel.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
        ])
        views.append(statusRow)

        return views
    }

    /// The audio-buffer live hint: value + consequence + the cost of changing
    /// it. Banded on the value (not the option index) so a future option list
    /// re-tune keeps honest wording without touching this.
    private static func bufferHintLine(_ ms: Int) -> String {
        let consequence: String
        switch ms {
        case ..<1001: consequence = "fastest response, safe for Wi-Fi speakers"
        case ..<1501: consequence = "extra cushion for busy Wi-Fi"
        default:      consequence = "slowest response, strongest against dropouts"
        }
        return "Buffer: \(msLabel(ms)) — \(consequence). Changing this reconnects your active speakers."
    }

    @objc private func bufferOptionChanged() {
        guard let target = updateBufferHintAndResolveTarget() else { return }
        Task { await applyBuffer(target) }
    }

    /// Reads the popup's current selection, refreshes the hint to describe it,
    /// and clears any stale transient confirmation — every popup touch does
    /// this, whether or not it results in an apply. Returns the value to
    /// apply, or nil when it matches what's already applied (reselecting the
    /// current value is a no-op, not a fresh apply).
    private func updateBufferHintAndResolveTarget() -> Int? {
        guard let latency else { return nil }
        let index = bufferPopup.indexOfSelectedItem
        guard latency.optionsMs.indices.contains(index) else { return nil }
        let ms = latency.optionsMs[index]
        bufferHint.stringValue = Self.bufferHintLine(ms)
        clearTransientStatus()
        return ms == appliedMs ? nil : ms
    }

    /// Apply a new buffer value — the flow a live popup selection triggers via
    /// `bufferOptionChanged`, awaitable so tests can drive it deterministically.
    private func applyBuffer(_ target: Int) async {
        guard let latency, latency.envOverrideMs == nil, !isApplying else { return }
        let wasStreaming = latency.isStreaming()

        isApplying = true
        bufferPopup.isEnabled = false
        if wasStreaming {
            applySpinner.startAnimation(nil)
            applyStatusLabel.stringValue = "Reconnecting speakers…"
            applyStatusLabel.isHidden = false
        }

        await latency.apply(target)

        appliedMs = target
        onSettingChanged?()
        isApplying = false
        bufferPopup.isEnabled = true
        applySpinner.stopAnimation(nil)
        applyStatusLabel.stringValue = wasStreaming ? "Speakers reconnected" : "Applied"
        applyStatusLabel.isHidden = false

        // Transient confirmation: fades after a beat (cancelled by any newer
        // apply so a stale "reconnected" can't outlive a fresh one).
        let reset = DispatchWorkItem { [weak self] in
            self?.applyStatusLabel.isHidden = true
        }
        statusResetWorkItem = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: reset)
    }

    private func clearTransientStatus() {
        statusResetWorkItem?.cancel()
        statusResetWorkItem = nil
        if !isApplying {
            applyStatusLabel.isHidden = true
        }
    }

    // MARK: Advanced › Sync offset (T-OFFSET-UI)

    /// The sync-offset sub-row: a slider (matching ``AppSettings/minSyncOffsetMs``…
    /// ``AppSettings/maxSyncOffsetMs``) + a bare "±N ms" value label, same layout
    /// idiom as the connect-volume row above. Applies immediately on change,
    /// persist-only — unlike the Audio buffer control just above, this never
    /// reconnects anything: it's a static bias `SyncedLocalSink` re-reads live
    /// at its next connect/rebuild, not a value that requires tearing down a
    /// live session to take effect.
    private func makeSyncOffsetSectionViews() -> [NSView] {
        syncOffsetSlider.translatesAutoresizingMaskIntoConstraints = false
        syncOffsetSlider.minValue = Double(AppSettings.minSyncOffsetMs)
        syncOffsetSlider.maxValue = Double(AppSettings.maxSyncOffsetMs)
        syncOffsetSlider.integerValue = settings.syncOffsetMs
        syncOffsetSlider.isContinuous = true
        syncOffsetSlider.target = self
        syncOffsetSlider.action = #selector(syncOffsetChanged)
        syncOffsetSlider.setAccessibilityLabel("Local speaker sync offset")
        syncOffsetSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        syncOffsetValueLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        syncOffsetValueLabel.textColor = .secondaryLabelColor
        syncOffsetValueLabel.alignment = .right
        syncOffsetValueLabel.stringValue = Self.syncOffsetLabel(settings.syncOffsetMs)
        // Fixed width so the row doesn't shift as sign/digit count changes.
        syncOffsetValueLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let control = NSStackView(views: [syncOffsetSlider, syncOffsetValueLabel])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = 8
        control.translatesAutoresizingMaskIntoConstraints = false

        return [SettingsForm.row(
            title: "Local speaker sync offset",
            subtitle: "Fine-tune the delay on this Mac's own speakers when playing "
                + "in sync with AirPlay devices. Raise it if the Mac plays ahead of "
                + "your speakers, lower it if it plays behind.",
            control: control)]
    }

    @objc private func syncOffsetChanged() {
        let ms = syncOffsetSlider.integerValue
        syncOffsetValueLabel.stringValue = Self.syncOffsetLabel(ms)
        settings.syncOffsetMs = ms
    }

    // MARK: List

    /// Repopulate the list from the controller and resize the pane to fit.
    ///
    /// Writing `preferredContentSize` is what makes the HOST grow too, but not
    /// by itself: AppKit's tab controller never resizes its host (probed —
    /// see the sizing-trap note on `SettingsRootViewController`). The write
    /// below reaches the host only because `SettingsRootViewController`
    /// observes each pane's `preferredContentSize` by KVO and republishes
    /// `fittedContentSize` from there. Without that the pane would silently
    /// clip when a user adds an excluded app.
    private func rebuildList() {
        for row in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for app in excluded.excludedApps {
            listStack.addArrangedSubview(makeExcludedRow(app))
        }
        listStack.addArrangedSubview(makeAddRow())
        for row in listStack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }

        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: SettingsForm.contentWidth, height: view.fittingSize.height)
    }

    private func makeExcludedRow(_ app: ExcludedApp) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = icon(for: app.bundleID)

        let nameLabel = SettingsForm.label(app.displayName)
        nameLabel.lineBreakMode = .byTruncatingTail

        let remove = NSButton()
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.isBordered = false
        remove.setButtonType(.momentaryChange)
        remove.imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        remove.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(config)
        remove.contentTintColor = Tokens.Color.secondaryLabel
        remove.target = self
        remove.action = #selector(removeTapped(_:))
        remove.identifier = NSUserInterfaceItemIdentifier(app.bundleID)
        remove.setAccessibilityLabel("Remove \(app.displayName)")

        row.addSubview(iconView)
        row.addSubview(nameLabel)
        row.addSubview(remove)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -8),
            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            remove.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func makeAddRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageLeading
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        button.title = "Add App…"
        button.contentTintColor = Tokens.Color.secondaryLabel
        button.target = self
        button.action = #selector(addTapped(_:))
        button.setAccessibilityLabel("Add excluded application")

        row.addSubview(button)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    /// Resolve an excluded app's icon: the running app's icon if it's running,
    /// else the installed app's cached icon, else a generic placeholder (an
    /// excluded app need not be running — it can be pre-excluded). Mirrors the
    /// popover's `appIcon`.
    private func icon(for bundleID: String) -> NSImage? {
        if let running = runningAppsProvider().first(where: { $0.bundleID == bundleID }), let icon = running.icon {
            return icon
        }
        if let icon = AppIconCache.icon(forBundleID: bundleID) {
            return icon
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // MARK: Actions

    @objc private func removeTapped(_ sender: NSButton) {
        guard let bundleID = sender.identifier?.rawValue else { return }
        remove(bundleID: bundleID)
    }

    @objc private func addTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let alreadyExcluded = excluded.excludedBundleIDs
        for app in runningAppsProvider() where !alreadyExcluded.contains(app.bundleID) {
            let item = NSMenuItem(title: app.displayName, action: #selector(pickRunningApp(_:)), keyEquivalent: "")
            item.target = self
            item.image = app.icon
            item.representedObject = app
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let browse = NSMenuItem(title: "Choose from Finder…", action: #selector(browseForApp), keyEquivalent: "")
        browse.target = self
        menu.addItem(browse)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func pickRunningApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppPickerItem else { return }
        add(bundleID: app.bundleID, displayName: app.displayName)
    }

    @objc private func browseForApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        add(bundleID: bundleID, displayName: name.isEmpty ? bundleID : name)
    }

    private func add(bundleID: String, displayName: String) {
        excluded.exclude(bundleID: bundleID, displayName: displayName)
        rebuildList()
        onChange?()
    }

    private func remove(bundleID: String) {
        excluded.remove(bundleID: bundleID)
        rebuildList()
        onChange?()
    }

    // MARK: Test-support hooks

    /// The excluded bundle ids in list order.
    public var test_excludedBundleIDs: [String] {
        _ = view
        return excluded.excludedApps.map(\.bundleID)
    }

    /// Exclude an app, running the same path a picker selection would (persist +
    /// rebuild + notify) — bypassing the untestable menu/open-panel.
    public func test_addExcluded(bundleID: String, displayName: String) {
        _ = view
        add(bundleID: bundleID, displayName: displayName)
    }

    /// Remove an app, running the same path the ✕ would.
    public func test_removeExcluded(bundleID: String) {
        _ = view
        remove(bundleID: bundleID)
    }

    // MARK: Test-support hooks (Connect volume — G1-N1)

    /// The connect-volume slider's current percent (mirrors the persisted value).
    public var test_connectVolumePercent: Int {
        _ = view
        return connectVolumeSlider.integerValue
    }

    /// The trailing "NN%" label text.
    public var test_connectVolumeValueLabel: String {
        _ = view
        return connectVolumeValueLabel.stringValue
    }

    /// The slider's `[min, max]` bounds — the UI can never select outside these.
    public var test_connectVolumeBounds: (min: Int, max: Int) {
        _ = view
        return (Int(connectVolumeSlider.minValue), Int(connectVolumeSlider.maxValue))
    }

    /// Simulate the user dragging the slider to `percent` (persists immediately).
    /// Values outside the slider bounds are clamped by `NSSlider` itself, exactly
    /// as a real drag would be.
    public func test_setConnectVolume(percent: Int) {
        _ = view
        connectVolumeSlider.integerValue = percent
        connectVolumeChanged()
    }

    /// The connect-volume live hint line (W1, spec §5.2).
    public var test_connectVolumeHint: String {
        _ = view
        return connectVolumeHint.stringValue
    }

    // MARK: Test-support hooks (Wake restore — B6b)

    /// Whether the wake-restore section mounted (a `WakeAudioRestoreModel` was injected).
    public var test_hasWakeRestoreSection: Bool {
        _ = view
        return wakeRestore != nil && wakeRestorePopup.numberOfItems > 0
    }

    /// The wake-restore popup's option titles, in order.
    public var test_wakeRestoreOptionTitles: [String] {
        _ = view
        return wakeRestorePopup.itemTitles
    }

    /// The currently-selected wake-restore option title.
    public var test_wakeRestoreSelectedTitle: String? {
        _ = view
        return wakeRestorePopup.titleOfSelectedItem
    }

    /// Simulate the user picking `minutes` in the wake-restore popup (applies immediately).
    public func test_selectWakeRestore(minutes: Int) {
        _ = view
        guard let wakeRestore, let index = wakeRestore.minuteOptions.firstIndex(of: minutes) else { return }
        wakeRestorePopup.selectItem(at: index)
        wakeRestoreChanged()
    }

    /// The wake-restore live hint line (W1, spec §5.2).
    public var test_wakeRestoreHint: String {
        _ = view
        return wakeRestoreHint.stringValue
    }

    // MARK: Test-support hooks (Advanced › Audio buffer)

    /// Whether the Advanced section mounted (i.e. a `LatencySettingModel` was
    /// injected — the native-backend case).
    public var test_hasLatencySection: Bool {
        _ = view
        return latency != nil && bufferPopup.numberOfItems > 0
    }

    /// The popup's option titles, in order (numeric-label contract).
    public var test_latencyOptionTitles: [String] {
        _ = view
        return bufferPopup.itemTitles
    }

    /// Simulate the user picking `ms` in the popup — applies immediately (V1),
    /// same path a live selection takes. Awaitable so tests can assert the
    /// post-apply state deterministically.
    public func test_selectLatencyOption(ms: Int) async {
        _ = view
        guard let latency, let index = latency.optionsMs.firstIndex(of: ms) else { return }
        bufferPopup.selectItem(at: index)
        guard let target = updateBufferHintAndResolveTarget() else { return }
        await applyBuffer(target)
    }

    /// The audio-buffer live hint line (W1, spec §5.2).
    public var test_bufferHint: String {
        _ = view
        return bufferHint.stringValue
    }

    /// The option the popup is currently showing — what a reader would see,
    /// as opposed to what has been applied.
    public var test_bufferSelectedTitle: String? {
        _ = view
        return bufferPopup.titleOfSelectedItem
    }

    public var test_bufferPopupEnabled: Bool { _ = view; return bufferPopup.isEnabled }
    public var test_applyStatusText: String? {
        _ = view
        return applyStatusLabel.isHidden ? nil : applyStatusLabel.stringValue
    }

    // MARK: Test-support hooks (Advanced › Sync offset — T-OFFSET-UI)

    /// Whether the sync-offset section mounted (mirrors ``test_hasLatencySection``
    /// — same native-backend gate).
    public var test_hasSyncOffsetSection: Bool {
        _ = view
        return latency != nil
    }

    /// The slider's current ms value (mirrors the persisted setting).
    public var test_syncOffsetMs: Int {
        _ = view
        return syncOffsetSlider.integerValue
    }

    /// The trailing "±N ms" label text.
    public var test_syncOffsetValueLabel: String {
        _ = view
        return syncOffsetValueLabel.stringValue
    }

    /// The slider's `[min, max]` bounds — the UI can never select outside these.
    public var test_syncOffsetBounds: (min: Int, max: Int) {
        _ = view
        return (Int(syncOffsetSlider.minValue), Int(syncOffsetSlider.maxValue))
    }

    /// Simulate the user dragging the sync-offset slider to `ms` (persists
    /// immediately, same as a real drag).
    public func test_setSyncOffset(ms: Int) {
        _ = view
        syncOffsetSlider.integerValue = ms
        syncOffsetChanged()
    }
}

/// A rounded hairline border around the excluded-apps list. Drawn with
/// `NSColor.separatorColor` in `draw(_:)` (resolved under the current appearance),
/// so it adapts to light/dark and the app's theme override with no manual
/// appearance-change bookkeeping.
final class BorderedListView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        Tokens.Color.separator.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
