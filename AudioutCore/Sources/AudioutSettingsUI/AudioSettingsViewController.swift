// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import UniformTypeIdentifiers
import AudioutCore
import AudioutSharedUI

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
    /// Persist + apply the new value; returns when the reconnect pass is done,
    /// with how many of the devices that were streaming actually came back
    /// (`reconnected`) out of how many there were (`expected`).
    public let apply: @MainActor (Int) async -> (reconnected: Int, expected: Int)

    public init(optionsMs: [Int],
                initialMs: Int,
                envOverrideMs: Int?,
                isStreaming: @escaping @MainActor () -> Bool,
                apply: @escaping @MainActor (Int) async -> (reconnected: Int, expected: Int)) {
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
    // Advanced is a disclosure, collapsed by default (roadmap 050): the buffer
    // is an expert control and doesn't deserve a standing row.
    private let advancedDisclosure = NSButton()
    private let advancedContent = NSStackView()
    private let advancedClip = NSView()
    private lazy var advancedClipCollapsed = advancedClip.heightAnchor.constraint(equalToConstant: 0)
    // The pane's column stack, kept because `republishFittedHeight()` measures
    // IT rather than the root (see that method's trap note).
    private weak var columnStack: NSStackView?
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
        // Section-header voice (roadmap 050): real weight separation from
        // body-font row titles, shared with every other header in the panes.
        let heading = SettingsForm.sectionHeader("Apps that stay on this Mac")

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
        columnStack = column

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
        // `.defaultHigh`, same reason as `SettingsForm.paneView(rows:width:)`:
        // the pane host's edge pins own the real width once mounted, and a 1pt
        // split divider must be able to shave this without a conflict.
        let widthConstraint = container.widthAnchor.constraint(equalToConstant: SettingsForm.contentWidth)
        widthConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            widthConstraint,
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

        // Monospaced digits on the panel's well (roadmap 050) — the readout as
        // instrument. One shared width with the sync-offset readout below so
        // both sliders land on the same column.
        let connectVolumeWell = SettingsForm.readoutWell(connectVolumeValueLabel, width: 56)
        connectVolumeValueLabel.stringValue = Self.percentLabel(settings.connectVolume)

        let control = NSStackView(views: [connectVolumeSlider, connectVolumeWell])
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

    /// The Advanced sub-section: hairline + a **disclosure header** (collapsed
    /// by default, roadmap 050) whose content stack holds the Audio buffer row
    /// (+ env-override note, or the apply-feedback row).
    /// Expanding/collapsing republishes `preferredContentSize`, which reaches
    /// the host via the same KVO path `rebuildList()` uses — no second path.
    private func makeAdvancedSectionViews() -> [NSView] {
        guard latency != nil else { return [] }

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false

        advancedDisclosure.translatesAutoresizingMaskIntoConstraints = false
        advancedDisclosure.setButtonType(.pushOnPushOff)
        advancedDisclosure.bezelStyle = .disclosure
        advancedDisclosure.title = ""
        advancedDisclosure.state = .off
        advancedDisclosure.target = self
        advancedDisclosure.action = #selector(advancedDisclosureToggled)
        advancedDisclosure.setAccessibilityLabel("Advanced")

        // The title is a click target too, not just the triangle — a
        // disclosure whose label is dead misses most of the clicks aimed at
        // it. Borderless button in the section-header voice, same action.
        let advancedTitle = NSButton()
        advancedTitle.translatesAutoresizingMaskIntoConstraints = false
        advancedTitle.isBordered = false
        advancedTitle.setButtonType(.momentaryChange)
        advancedTitle.attributedTitle = NSAttributedString(
            string: "Advanced",
            attributes: [.font: Tokens.Font.captionEmphasized,
                         .foregroundColor: Tokens.Color.secondaryLabel])
        advancedTitle.target = self
        advancedTitle.action = #selector(advancedTitleTapped)
        // A click-target duplicate of the triangle beside it, which keeps the
        // label — VoiceOver should hear "Advanced" once, not twice.
        advancedTitle.setAccessibilityElement(false)

        let header = NSStackView(views: [advancedDisclosure, advancedTitle])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        advancedContent.orientation = .vertical
        advancedContent.alignment = .leading
        advancedContent.spacing = 12
        advancedContent.translatesAutoresizingMaskIntoConstraints = false
        for contentView in makeAdvancedContentViews() {
            advancedContent.addArrangedSubview(contentView)
            contentView.widthAnchor.constraint(equalTo: advancedContent.widthAnchor).isActive = true
        }

        // Collapsed by default via the app's one collapse idiom — the
        // `CardView` clip (AudioutPopoverUI): the content sits inside a
        // layer-clipped container whose REQUIRED height==0 constraint is the
        // single controlled value; the content's bottom pin is `.defaultHigh`,
        // so the clip always wins without a conflict. Probed alternatives that
        // do NOT work in-place on a stack child once it has been shown:
        // `isHidden`, `setVisibilityPriority(.notVisible)`, and a 999
        // zero-height constraint fighting the stack directly — the stack kept
        // demanding the expanded height for all three.
        advancedClip.translatesAutoresizingMaskIntoConstraints = false
        advancedClip.wantsLayer = true
        advancedClip.layer?.masksToBounds = true
        advancedClip.addSubview(advancedContent)
        let bottomPin = advancedContent.bottomAnchor.constraint(equalTo: advancedClip.bottomAnchor)
        bottomPin.priority = .defaultHigh
        NSLayoutConstraint.activate([
            advancedContent.leadingAnchor.constraint(equalTo: advancedClip.leadingAnchor),
            advancedContent.trailingAnchor.constraint(equalTo: advancedClip.trailingAnchor),
            // 4pt inside the clip + the column's own 8pt spacing = the
            // standard 12pt section gap when expanded; collapsed, only the
            // stack's 8pt remains above the pane's bottom padding.
            advancedContent.topAnchor.constraint(equalTo: advancedClip.topAnchor, constant: 4),
            bottomPin,
        ])
        advancedClipCollapsed.isActive = true
        advancedContent.isHidden = true

        return [hairline, header, advancedClip]
    }

    /// Clicking the word "Advanced" mirrors the triangle exactly: flip the
    /// disclosure's state (so its rotation animates as if clicked), then run
    /// the same fold.
    @objc private func advancedTitleTapped() {
        advancedDisclosure.state = advancedDisclosure.state == .on ? .off : .on
        advancedDisclosureToggled()
    }

    @objc private func advancedDisclosureToggled() {
        // Instant under Reduce Motion AND headless (module rule, AudioutPopoverUI
        // AGENTS.md): the fold clock ticks off the main runloop, which the harness
        // tools and `swift test` don't reliably spin — a deferred terminal state
        // would be stranded.
        setAdvancedExpanded(
            advancedDisclosure.state == .on,
            animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                && !HeadlessRuntime.isActive)
    }

    /// The same choreography as `CardView.setBodyCollapsed` (the app's one fold
    /// gesture, `Tokens.Motion.collapseRevealDuration`): the clip height is the
    /// single animated value on `FoldAnimator`'s clock, this pane republishes
    /// its `preferredContentSize` from it every tick (`foldAnimatorDidTick`),
    /// and the surface follows each published size instantly — no second clock.
    /// Expand un-hides before travel and hands the rest height back to the
    /// content's bottom pin on arrival; collapse seeds the constraint from the
    /// LIVE clip height (so a first-ever or retargeted fold travels instead of
    /// snapping) and hides only on arrival. `animated == false` (Reduce
    /// Motion) applies the end state directly.
    private func setAdvancedExpanded(_ expanded: Bool, animated: Bool) {
        if expanded {
            advancedContent.isHidden = false
            guard animated else {
                advancedClipCollapsed.isActive = false
                republishFittedHeight()
                return
            }
            advancedContent.layoutSubtreeIfNeeded()
            let target = advancedContent.fittingSize.height + 4
            advancedClipCollapsed.isActive = true
            FoldAnimator.shared.animate(advancedClipCollapsed, to: target, follower: self) { [weak self] in
                guard let self else { return }
                self.advancedClipCollapsed.isActive = false
                self.republishFittedHeight()
            }
        } else {
            guard animated else {
                advancedClipCollapsed.constant = 0
                advancedClipCollapsed.isActive = true
                advancedContent.isHidden = true
                republishFittedHeight()
                return
            }
            if !advancedClipCollapsed.isActive {
                advancedClipCollapsed.constant = advancedClip.frame.height
                advancedClipCollapsed.isActive = true
                view.layoutSubtreeIfNeeded()
            }
            FoldAnimator.shared.animate(advancedClipCollapsed, to: 0, follower: self) { [weak self] in
                guard let self else { return }
                self.advancedContent.isHidden = true
                self.republishFittedHeight()
            }
        }
    }

    /// Republish `preferredContentSize` from the COLUMN's fitting height, not
    /// the root's — the host resizes via its KVO on `preferredContentSize`
    /// (see the sizing-trap note on the root). Measuring the root is a trap
    /// that only bites on SHRINK: `layoutSubtreeIfNeeded` on a windowless
    /// top-level view installs a priority-501 height constraint pinning the
    /// root to its current frame (probed 2026-08-12: `hcons=[501:h==424]` on
    /// the root while the column solved to 214), and `fittingSize`'s pull-to-
    /// zero at priority 50 loses to it — so the pane grows fine but keeps its
    /// dead space forever after a disclosure collapse or list removal. The
    /// column has no such lock; its fitting height + the standard insets IS
    /// the pane's honest height.
    private func republishFittedHeight() {
        view.layoutSubtreeIfNeeded()
        guard let columnStack else { return }
        preferredContentSize = NSSize(
            width: SettingsForm.contentWidth,
            height: columnStack.fittingSize.height + SettingsForm.verticalPadding * 2)
    }

    /// The rows INSIDE the Advanced disclosure.
    private func makeAdvancedContentViews() -> [NSView] {
        guard let latency else { return [] }
        var views: [NSView] = []

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

        if let envMs = latency.envOverrideMs {
            let note = SettingsForm.label(
                "Your buffer is locked to \(Self.msLabel(envMs)) by a launch option for this session.")
            note.font = Tokens.Font.caption
            note.textColor = Tokens.Color.label2
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 0
            // Not `hintLabel` — that helper is for a live hint a pane rewrites
            // on every control change, and this line is fixed for the session.
            // It is styled to match (`label2`, caption) and needs the SAME
            // `preferredMaxLayoutWidth` fix — see hintLabel's doc comment for
            // why an unset one drags the whole pane wider than the fixed
            // content column.
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
        Analytics.capture("settings:buffer_changed", ["ms": String(target)])
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

        let result = await latency.apply(target)

        appliedMs = target
        onSettingChanged?()
        isApplying = false
        bufferPopup.isEnabled = true
        applySpinner.stopAnimation(nil)
        // Only claim they all came back if they all came back — the re-add is
        // best-effort per device (D4), and a silent speaker the pane called
        // "reconnected" is the kind of lie this app doesn't tell.
        applyStatusLabel.stringValue = wasStreaming
            ? (result.reconnected == result.expected
                ? "Speakers reconnected"
                : "Some speakers didn't reconnect — check the mixer")
            : "Applied"
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

    // MARK: List

    /// Repopulate the list from the controller and re-measure the pane.
    ///
    /// Nothing outside this pane is resized by the write below: the surface
    /// frame is fixed, so the pane's new height simply grows the scroll
    /// document the Settings pane host wraps it in, and the extra rows become
    /// scrollable content rather than a taller window.
    private func rebuildList() {
        for row in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        // ONE snapshot for the whole rebuild: `runningAppsProvider()`
        // materializes every running app's icon, so calling it per row made an
        // n-row rebuild cost n full enumerations of the system's app list.
        let running = Dictionary(runningAppsProvider().map { ($0.bundleID, $0) },
                                 uniquingKeysWith: { first, _ in first })
        for app in excluded.excludedApps {
            listStack.addArrangedSubview(makeExcludedRow(app, running: running))
        }
        listStack.addArrangedSubview(makeAddRow())
        for row in listStack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }

        republishFittedHeight()
    }

    private func makeExcludedRow(_ app: ExcludedApp, running: [String: AppPickerItem]) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = icon(for: app.bundleID, running: running)

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
    /// `running` is the caller's one snapshot of the running-apps list, so a
    /// rebuild enumerates the system once rather than once per row.
    private func icon(for bundleID: String, running: [String: AppPickerItem]) -> NSImage? {
        if let icon = running[bundleID]?.icon {
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
        Analytics.capture("settings:excluded_app_removed")
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
        Analytics.capture("settings:excluded_app_added")
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

    // MARK: Test-support hooks (Advanced disclosure — roadmap 050)

    /// Whether the Advanced disclosure content is currently expanded.
    public var test_advancedExpanded: Bool {
        _ = view
        return latency != nil && !advancedContent.isHidden
    }

    /// Drive the disclosure triangle, running the same expand/collapse +
    /// republish a click would, then settle the fold — the runloop time a
    /// headless test cannot spend (`FoldAnimator.test_settleNow`).
    public func test_toggleAdvanced() {
        _ = view
        advancedDisclosure.state = advancedDisclosure.state == .on ? .off : .on
        advancedDisclosureToggled()
        FoldAnimator.shared.test_settleNow()
    }

    /// Click the word "Advanced" — the label is a click target mirroring the
    /// triangle — then settle the fold.
    public func test_tapAdvancedTitle() {
        _ = view
        advancedTitleTapped()
        FoldAnimator.shared.test_settleNow()
    }
}

extension AudioSettingsViewController: FoldFollowing {
    /// Per-tick follow: the pane's published size IS the clip's current
    /// height, frame by frame — the surface applies it instantly during a
    /// fold (`AppSurfaceController`, `FoldAnimator.shared.isFolding`).
    public func foldAnimatorDidTick() { republishFittedHeight() }
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
