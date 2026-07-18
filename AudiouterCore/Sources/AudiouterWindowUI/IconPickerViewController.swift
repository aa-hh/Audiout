// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// A compact SF Symbol picker, presented by the caller as an anchored
/// `NSPopover` (`present(_:asPopoverRelativeTo:of:preferredEdge:)`) from an
/// icon well or the detail view's large icon — this controller has no
/// opinion on presentation, it only builds the content view and reports back.
///
/// CONFIGURATION-ONLY (`../../AGENTS.md`): picking a symbol here never
/// activates a group or moves audio — it only reports a symbol name string
/// for the caller to persist (typically via `DeviceIconController`).
///
/// Layout, top to bottom:
/// - a grid of borderless square buttons, one per `DeviceIcon.curated`
///   symbol (already filtered through `DeviceIcon.isValid` so a stale
///   curated name never renders a blank glyph), ~``columnsPerRow`` per row;
/// - a search field accepting ANY SF Symbol name, validated live against
///   `DeviceIcon.isValid`: valid shows a preview + enables Apply, invalid or
///   empty shows no preview and disables Apply;
/// - a trailing "Use default icon" button that reports `nil` immediately
///   (no Apply gate — resetting is always available).
///
/// Every path — a grid tap, Apply, or "Use default icon" — funnels through
/// ``onPick``, then dismisses itself via `dismiss(self)` when actually
/// presented (`view.window != nil`, the same live-vs-headless-test pattern
/// `GroupCreationSheetController.finish` uses).
public final class IconPickerViewController: NSViewController {

    /// Reports the picked symbol name (grid tap or Apply), or `nil` for
    /// "use default icon". Fired exactly once per picker use.
    public var onPick: ((String?) -> Void)?

    /// Curated buttons per row (approved: "~5-6 per row").
    private static let columnsPerRow = 6
    /// Square button/glyph cell size.
    private static let cellSize: CGFloat = 32
    private static let contentWidth: CGFloat = 260

    private let grid = NSGridView()
    private let searchField = NSSearchField()
    private let previewImageView = NSImageView()
    private let applyButton = NSButton()
    private let defaultButton = NSButton()

    /// The curated symbol names actually offered, in row order — pre-filtered
    /// through `DeviceIcon.isValid` at build time (never trust the curation
    /// list blindly; a name can go stale on a future OS).
    private var curatedNames: [String] = DeviceIcon.curated.filter(DeviceIcon.isValid)

    private var currentSymbolName: String?
    private var defaultSymbolName: String = ""

    /// Live search-field text, validated each keystroke.
    private var searchText: String = "" {
        didSet { updateSearchState() }
    }

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        let container = NSView()

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        buildGridRows()

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Symbol name"
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.delegate = self

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.contentTintColor = .secondaryLabelColor
        previewImageView.isHidden = true

        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.title = "Apply"
        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(applyTapped(_:))
        applyButton.isEnabled = false

        defaultButton.translatesAutoresizingMaskIntoConstraints = false
        defaultButton.title = "Use default icon"
        defaultButton.bezelStyle = .rounded
        defaultButton.target = self
        defaultButton.action = #selector(defaultTapped(_:))

        let searchRow = NSStackView(views: [searchField, previewImageView, applyButton])
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 6
        previewImageView.widthAnchor.constraint(equalToConstant: Self.cellSize * 0.6).isActive = true
        previewImageView.heightAnchor.constraint(equalToConstant: Self.cellSize * 0.6).isActive = true

        for v in [grid, searchRow, defaultButton] {
            container.addSubview(v)
        }

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.contentWidth),

            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),

            searchRow.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            searchRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            defaultButton.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 12),
            defaultButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            defaultButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        view = container
    }

    /// (Re)build the curated grid's rows/cells from ``curatedNames``, one
    /// borderless square `NSButton` per symbol, ``columnsPerRow`` per row.
    private func buildGridRows() {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        var rowCells: [NSView] = []
        for name in curatedNames {
            let button = makeCuratedButton(name: name)
            rowCells.append(button)
            if rowCells.count == Self.columnsPerRow {
                grid.addRow(with: rowCells)
                rowCells.removeAll()
            }
        }
        if !rowCells.isEmpty {
            // Pad the final partial row so NSGridView keeps column alignment.
            while rowCells.count < Self.columnsPerRow { rowCells.append(NSView()) }
            grid.addRow(with: rowCells)
        }
    }

    private func makeCuratedButton(name: String) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Self.cellSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.cellSize).isActive = true
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.toolTip = name
        let image = NSImage(systemSymbolName: name, accessibilityDescription: name)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(curatedButtonTapped(_:))
        button.identifier = NSUserInterfaceItemIdentifier(name)
        return button
    }

    // MARK: Configuration

    /// Configure the picker before presenting it. `currentSymbolName` isn't
    /// otherwise reflected in this compact layout (no persistent selection
    /// highlight) — it's accepted for parity with other configure-style
    /// entry points and future use.
    public func configure(currentSymbolName: String?, defaultSymbolName: String) {
        self.currentSymbolName = currentSymbolName
        self.defaultSymbolName = defaultSymbolName
    }

    // MARK: Search validation

    private func updateSearchState() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, DeviceIcon.isValid(trimmed) {
            let image = NSImage(systemSymbolName: trimmed, accessibilityDescription: trimmed)
            image?.isTemplate = true
            previewImageView.image = image
            previewImageView.contentTintColor = .secondaryLabelColor
            previewImageView.isHidden = false
            applyButton.isEnabled = true
        } else {
            previewImageView.image = nil
            previewImageView.isHidden = true
            applyButton.isEnabled = false
        }
    }

    private var previewSymbolName: String? {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, DeviceIcon.isValid(trimmed) else { return nil }
        return trimmed
    }

    // MARK: Actions

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchText = sender.stringValue
    }

    @objc private func curatedButtonTapped(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        pick(name)
    }

    @objc private func applyTapped(_ sender: NSButton) {
        apply()
    }

    @objc private func defaultTapped(_ sender: NSButton) {
        useDefault()
    }

    private func apply() {
        guard let name = previewSymbolName else { return }
        pick(name)
    }

    private func useDefault() {
        pick(nil)
    }

    /// Report `name` via ``onPick`` and dismiss when actually presented
    /// (`view.window != nil`) — mirrors `GroupCreationSheetController.finish`
    /// so a headless test can drive `test_pickCurated`/`test_apply`/
    /// `test_useDefault` without a hosting popover.
    private func pick(_ name: String?) {
        onPick?(name)
        if view.window != nil { dismiss(self) }
    }

    // MARK: Test-support hooks
    //
    // No synthesized clicks in headless runs (`../AGENTS.md`) — these drive
    // the same code paths a real UI interaction would.

    /// Simulate typing `text` into the search field (no commit).
    public func test_setSearchText(_ text: String) {
        searchField.stringValue = text
        searchText = text
    }

    /// Whether Apply is currently enabled (live search text resolves via
    /// `DeviceIcon.isValid`).
    public var test_isApplyEnabled: Bool { applyButton.isEnabled }

    /// The symbol name the live preview currently resolves to, or `nil` if
    /// the search field is empty/invalid.
    public var test_previewSymbolName: String? { previewSymbolName }

    /// Simulate clicking Apply (no-op when disabled, exactly like the real
    /// button).
    public func test_apply() { apply() }

    /// Simulate tapping a curated grid cell by symbol name.
    public func test_pickCurated(_ name: String) {
        guard curatedNames.contains(name) else { return }
        pick(name)
    }

    /// Simulate clicking "Use default icon".
    public func test_useDefault() { useDefault() }

    /// The curated symbol names actually offered as grid cells, in order
    /// (already filtered through `DeviceIcon.isValid`).
    public var test_curatedSymbolNames: [String] { curatedNames }
}

extension IconPickerViewController: NSSearchFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        searchText = field.stringValue
    }
}
