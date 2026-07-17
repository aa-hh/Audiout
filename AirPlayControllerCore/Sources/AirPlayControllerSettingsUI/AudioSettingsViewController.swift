// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import UniformTypeIdentifiers
import AirPlayControllerCore

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
    /// Whether any device is currently streaming — drives the CTA label
    /// ("Apply & Reconnect" vs plain "Apply") and the reconnect status UI.
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
/// localization; the one localizable sentence is the caption) plus an explicit
/// CTA. Changing the popup only ARMS the button; nothing applies until it's
/// clicked ("Apply & Reconnect" while streaming — the apply tears down and
/// re-establishes the live sessions, a ~3–5 s audible gap — or plain "Apply"
/// when idle, instant). While reconnecting, a spinner + "Reconnecting
/// speakers…" replaces the idle state; completion shows a transient
/// confirmation. When `AIRPLAY_START_BUFFER_MS` overrode the setting at launch
/// the control renders disabled with a note instead.
@MainActor
public final class AudioSettingsViewController: NSViewController {

    private let excluded: ExcludedAppsController
    private let runningAppsProvider: () -> [AppPickerItem]
    private let latency: LatencySettingModel?

    /// Fired after the denylist changes so the app can enforce precedence (prune
    /// routes) and refresh the popover.
    public var onChange: (() -> Void)?

    private let listStack = NSStackView()
    private let listContainer = BorderedListView()

    // Advanced › Audio buffer state (all nil/untouched when `latency` is nil).
    private let bufferPopup = NSPopUpButton()
    private let applyButton = NSButton()
    private let applySpinner = NSProgressIndicator()
    private let applyStatusLabel = NSTextField(labelWithString: "")
    private var appliedMs = 0
    private var pendingMs = 0
    private var isApplying = false
    private var statusResetWorkItem: DispatchWorkItem?

    private static let rowHeight: CGFloat = 34

    public init(excluded: ExcludedAppsController,
                runningAppsProvider: @escaping () -> [AppPickerItem] = RunningApps.regularRunningApps,
                latency: LatencySettingModel? = nil) {
        self.excluded = excluded
        self.runningAppsProvider = runningAppsProvider
        self.latency = latency
        super.init(nibName: nil, bundle: nil)
        title = "Audio"
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let heading = SettingsForm.label("Excluded applications")
        heading.font = .systemFont(ofSize: NSFont.systemFontSize)

        let subtitle = SettingsForm.label(
            "Audio from these apps always stays on this Mac — never captured or redirected.")
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0

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
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            subtitle.widthAnchor.constraint(equalTo: column.widthAnchor),
            listContainer.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        view = container
        rebuildList()
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

    /// The Advanced sub-section's stacked views: hairline + "Advanced" label +
    /// the Audio buffer row (+ env-override note, or the Apply CTA row).
    private func makeAdvancedSectionViews() -> [NSView] {
        guard let latency else { return [] }
        var views: [NSView] = []

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        views.append(hairline)

        let advancedLabel = SettingsForm.label("Advanced")
        advancedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        advancedLabel.textColor = .secondaryLabelColor
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
            pendingMs = latency.initialMs
            if let index = latency.optionsMs.firstIndex(of: latency.initialMs) {
                bufferPopup.selectItem(at: index)
            }
            bufferPopup.target = self
            bufferPopup.action = #selector(bufferOptionChanged)
        }
        bufferPopup.setAccessibilityLabel("Audio buffer")

        views.append(SettingsForm.row(
            title: "Audio buffer",
            subtitle: "A smaller buffer reacts faster to play and pause. "
                + "A larger buffer resists Wi-Fi hiccups and dropouts.",
            control: bufferPopup))

        if let envMs = latency.envOverrideMs {
            let note = SettingsForm.label(
                "Overridden by AIRPLAY_START_BUFFER_MS (\(Self.msLabel(envMs))) for this launch.")
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .systemOrange
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 0
            views.append(note)
            // The CTA never mounts in env mode; keep the (orphan) button's
            // state honest for the test hooks all the same.
            applyButton.isEnabled = false
            return views
        }

        // The CTA row: [status spinner + label] … [Apply], trailing-aligned,
        // fixed height so status transitions never resize the window.
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.bezelStyle = .push
        applyButton.setButtonType(.momentaryPushIn)
        applyButton.target = self
        applyButton.action = #selector(applyTapped)
        applyButton.setAccessibilityLabel("Apply audio buffer change")

        applySpinner.translatesAutoresizingMaskIntoConstraints = false
        applySpinner.style = .spinning
        applySpinner.controlSize = .small
        applySpinner.isDisplayedWhenStopped = false

        applyStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        applyStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        applyStatusLabel.textColor = .secondaryLabelColor
        applyStatusLabel.isHidden = true

        let ctaRow = NSView()
        ctaRow.translatesAutoresizingMaskIntoConstraints = false
        ctaRow.addSubview(applySpinner)
        ctaRow.addSubview(applyStatusLabel)
        ctaRow.addSubview(applyButton)
        NSLayoutConstraint.activate([
            ctaRow.heightAnchor.constraint(equalToConstant: 28),
            applyButton.trailingAnchor.constraint(equalTo: ctaRow.trailingAnchor),
            applyButton.centerYAnchor.constraint(equalTo: ctaRow.centerYAnchor),
            applyStatusLabel.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -10),
            applyStatusLabel.centerYAnchor.constraint(equalTo: ctaRow.centerYAnchor),
            applySpinner.trailingAnchor.constraint(equalTo: applyStatusLabel.leadingAnchor, constant: -6),
            applySpinner.centerYAnchor.constraint(equalTo: ctaRow.centerYAnchor),
        ])
        views.append(ctaRow)

        updateApplyState()
        return views
    }

    /// Recompute the CTA's enabled/title/default-button state from the pending
    /// vs applied values. The button is the window's default (blue, Return) only
    /// while armed — an idle disabled button should not claim the key equivalent.
    private func updateApplyState() {
        guard let latency, latency.envOverrideMs == nil else { return }
        let armed = pendingMs != appliedMs && !isApplying
        applyButton.isEnabled = armed
        applyButton.title = (armed && latency.isStreaming()) ? "Apply & Reconnect" : "Apply"
        applyButton.keyEquivalent = armed ? "\r" : ""
        bufferPopup.isEnabled = !isApplying
    }

    @objc private func bufferOptionChanged() {
        guard let latency else { return }
        let index = bufferPopup.indexOfSelectedItem
        guard latency.optionsMs.indices.contains(index) else { return }
        pendingMs = latency.optionsMs[index]
        clearTransientStatus()
        updateApplyState()
    }

    @objc private func applyTapped() {
        Task { await performApply() }
    }

    /// The full apply flow, awaitable so tests drive it deterministically.
    func performApply() async {
        guard let latency, latency.envOverrideMs == nil,
              !isApplying, pendingMs != appliedMs else { return }
        let target = pendingMs
        let wasStreaming = latency.isStreaming()

        isApplying = true
        clearTransientStatus()
        updateApplyState()
        if wasStreaming {
            applySpinner.startAnimation(nil)
            applyStatusLabel.stringValue = "Reconnecting speakers…"
            applyStatusLabel.isHidden = false
        }

        await latency.apply(target)

        appliedMs = target
        isApplying = false
        applySpinner.stopAnimation(nil)
        applyStatusLabel.stringValue = wasStreaming ? "Speakers reconnected" : "Applied"
        applyStatusLabel.isHidden = false
        updateApplyState()

        // Transient confirmation: fades after a beat (cancelled by any newer
        // change/apply so a stale "reconnected" can't outlive a fresh arm).
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

    /// Repopulate the list from the controller and resize the pane to fit (the
    /// tab controller resizes the window to `preferredContentSize`).
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
        remove.contentTintColor = .secondaryLabelColor
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
        button.title = "Add application…"
        button.contentTintColor = .secondaryLabelColor
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
    /// else a generic placeholder (an excluded app need not be running — it can
    /// be pre-excluded). Mirrors the popover's `appIcon`.
    private func icon(for bundleID: String) -> NSImage? {
        if let running = runningAppsProvider().first(where: { $0.bundleID == bundleID }), let icon = running.icon {
            return icon
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
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

    /// Simulate the user picking `ms` in the popup (arms the CTA).
    public func test_selectLatencyOption(ms: Int) {
        _ = view
        guard let latency, let index = latency.optionsMs.firstIndex(of: ms) else { return }
        bufferPopup.selectItem(at: index)
        bufferOptionChanged()
    }

    public var test_applyButtonTitle: String { _ = view; return applyButton.title }
    public var test_applyButtonEnabled: Bool { _ = view; return applyButton.isEnabled }
    public var test_bufferPopupEnabled: Bool { _ = view; return bufferPopup.isEnabled }
    public var test_applyStatusText: String? {
        _ = view
        return applyStatusLabel.isHidden ? nil : applyStatusLabel.stringValue
    }

    /// Run the same apply flow the CTA click starts, awaitable.
    public func test_apply() async {
        _ = view
        await performApply()
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
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
