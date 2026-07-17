// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import UniformTypeIdentifiers
import AirPlayControllerCore

/// Settings › **Audio** pane. Step 3: the **excluded applications** denylist.
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
@MainActor
public final class AudioSettingsViewController: NSViewController {

    private let excluded: ExcludedAppsController
    private let runningAppsProvider: () -> [AppPickerItem]

    /// Fired after the denylist changes so the app can enforce precedence (prune
    /// routes) and refresh the popover.
    public var onChange: (() -> Void)?

    private let listStack = NSStackView()
    private let listContainer = BorderedListView()

    private static let rowHeight: CGFloat = 34

    public init(excluded: ExcludedAppsController,
                runningAppsProvider: @escaping () -> [AppPickerItem] = RunningApps.regularRunningApps) {
        self.excluded = excluded
        self.runningAppsProvider = runningAppsProvider
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
