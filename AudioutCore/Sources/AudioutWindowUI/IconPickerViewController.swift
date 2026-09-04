// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

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
///   curated name never renders a blank glyph), ~``columnsPerRow`` per row.
///   The search field below LIVE-FILTERS this grid: empty shows the full
///   curated set, non-empty case-insensitive-substring-narrows it to
///   matching names on every keystroke (a "No matches" label stands in for
///   an empty result, never a crash);
/// - the same search field ALSO accepts ANY SF Symbol name for an exact-name
///   preview + Apply path, validated live against `DeviceIcon.isValid`:
///   valid shows a preview + enables Apply, invalid or empty shows no
///   preview and disables Apply. This is independent of and coexists with
///   the grid filtering above — a user can narrow the grid with a partial
///   name and tap a result, or type a full valid name and hit Apply
///   directly, in the same field;
/// - a trailing "Use Default Icon" button that reports `nil` immediately
///   (no Apply gate — resetting is always available).
///
/// Every path — a grid tap, Apply, or "Use Default Icon" — funnels through
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
    /// Mini warm-canvas tile behind the exact-name preview glyph (Warm
    /// Signal: the preview shows the symbol on the product's own surface,
    /// not on bare popover material). Hidden/shown in lockstep with
    /// `previewImageView`.
    private let previewTile = WarmPreviewTileView()
    private let applyButton = NSButton()
    private let defaultButton = NSButton()
    private let emptyResultsLabel = NSTextField(labelWithString: "No matches")

    /// Every curated cell currently in the grid, and which one is the current
    /// icon — both rebuilt by ``buildGridRows()``. The cells are layer-stamped,
    /// so one pass over this array re-resolves the whole grid.
    private var curatedButtons: [NSButton] = []
    private weak var selectedButton: NSButton?

    /// The full curated symbol set, pre-filtered through `DeviceIcon.isValid`
    /// once at build time (never trust the curation list blindly; a name can
    /// go stale on a future OS). ``curatedNames`` — the grid's live data
    /// source — is a search-narrowed view of this list.
    private let allCuratedNames: [String] = DeviceIcon.curated.filter(DeviceIcon.isValid)

    /// The curated symbol names actually offered as grid cells, in row order.
    /// Equal to ``allCuratedNames`` when the search field is empty; otherwise
    /// narrowed to a case-insensitive substring match against the trimmed
    /// search text, recomputed on every keystroke by ``updateSearchState()``.
    private var curatedNames: [String] = []

    private var currentSymbolName: String?
    private var defaultSymbolName: String = ""

    /// Live search-field text, validated each keystroke.
    private var searchText: String = "" {
        didSet { updateSearchState() }
    }

    public init() {
        super.init(nibName: nil, bundle: nil)
        curatedNames = allCuratedNames
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        // Appearance-observing root so the cells' layer colours re-resolve on
        // a live theme flip (layer colors don't re-resolve on their own the
        // way `draw(_:)` fills do).
        let container = AppearanceObservingView()
        container.onAppearanceChange = { [weak self] in
            self?.restampCellColors()
        }
        // Every cell is a LAYER fill — a stamped `CGColor` that keeps showing
        // until something re-stamps it. The appearance hook above covers
        // light/dark; Increase Contrast and the accent dial arrive on their own
        // notifications and were re-resolving nowhere (the same pair
        // `EQResponseCurveView` observes). Selector-based observation needs no
        // matching removal (post-10.11 AppKit auto-unregisters).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(cellTokensDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cellTokensDidChange),
            name: Tokens.accentStyleDidChangeNotification,
            object: nil)

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        buildGridRows()

        searchField.translatesAutoresizingMaskIntoConstraints = false
        // Plain words — "Symbol name" leaked SF Symbols jargon onto a
        // general-user surface (the exact-name power path still works: the
        // same field accepts any valid symbol name).
        searchField.placeholderString = "Search icons"
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.delegate = self

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.contentTintColor = Tokens.Color.label2
        previewImageView.isHidden = true

        // The preview glyph sits centered on its mini warm-canvas tile; the
        // tile (not the bare glyph) is what the search row shows/hides.
        previewTile.translatesAutoresizingMaskIntoConstraints = false
        previewTile.isHidden = true
        previewTile.addSubview(previewImageView)

        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.title = "Apply"
        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(applyTapped(_:))
        applyButton.isEnabled = false

        defaultButton.translatesAutoresizingMaskIntoConstraints = false
        defaultButton.title = "Use Default Icon"
        defaultButton.bezelStyle = .rounded
        defaultButton.target = self
        defaultButton.action = #selector(defaultTapped(_:))

        emptyResultsLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyResultsLabel.textColor = Tokens.Color.label2
        emptyResultsLabel.font = Tokens.Font.caption
        emptyResultsLabel.alignment = .center
        emptyResultsLabel.isHidden = true

        let searchRow = NSStackView(views: [searchField, previewTile, applyButton])
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 6
        NSLayoutConstraint.activate([
            previewTile.widthAnchor.constraint(equalToConstant: Self.cellSize * 0.8),
            previewTile.heightAnchor.constraint(equalToConstant: Self.cellSize * 0.8),
            previewImageView.centerXAnchor.constraint(equalTo: previewTile.centerXAnchor),
            previewImageView.centerYAnchor.constraint(equalTo: previewTile.centerYAnchor),
            previewImageView.widthAnchor.constraint(equalToConstant: Self.cellSize * 0.6),
            previewImageView.heightAnchor.constraint(equalToConstant: Self.cellSize * 0.6),
        ])

        for v in [grid, emptyResultsLabel, searchRow, defaultButton] {
            container.addSubview(v)
        }

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.contentWidth),

            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),

            emptyResultsLabel.topAnchor.constraint(equalTo: grid.topAnchor, constant: 4),
            emptyResultsLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

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
        selectedButton = nil        // rebuilt below if the current icon is offered
        curatedButtons.removeAll()
        // `NSGridView.removeRow(at:)` does NOT remove the row's cell views
        // from the view hierarchy (documented behavior) — without the
        // explicit `removeFromSuperview()` every rebuild stacked the old
        // buttons behind the new ones, so a search-narrowed grid still drew
        // the full curated set underneath (latent; surfaced by the selected
        // cell's gold fill rendering on the stale copies too).
        while grid.numberOfRows > 0 {
            for column in 0..<grid.numberOfColumns {
                grid.cell(atColumnIndex: column, rowIndex: 0).contentView?.removeFromSuperview()
            }
            grid.removeRow(at: 0)
        }
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
        restampCellColors()
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
        // VoiceOver must never read a raw SF Symbol name ("hifispeaker.2.fill")
        // aloud — `accessibilityLabel(forSymbol:)` maps every curated name to
        // plain language; the button's own label is set explicitly too, since
        // an `NSImage`'s `accessibilityDescription` alone isn't guaranteed to
        // surface through a borderless, image-only `NSButton`.
        var plainLabel = Self.accessibilityLabel(forSymbol: name)
        // A BINARY, not a ring (audiout-remote DESIGN.md:950-953): the current
        // icon's cell is one solid gold surface carrying an `inkOnFill` glyph;
        // every other cell is the chassis's own `well` recess with a cool
        // glyph. VoiceOver equivalent baked in alongside it: the label says
        // "current icon" so the state is never colour-only.
        let isCurrent = name == effectiveCurrentSymbolName
        if isCurrent {
            plainLabel += ", current icon"
            selectedButton = button
        }
        button.wantsLayer = true
        // No `masksToBounds`: the radius already clips the background fill,
        // and masking would also clip a keyboard focus ring drawn outside the
        // cell's bounds.
        button.layer?.cornerRadius = Tokens.Layout.Radius.control
        let image = NSImage(systemSymbolName: name, accessibilityDescription: plainLabel)
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(curatedButtonTapped(_:))
        button.identifier = NSUserInterfaceItemIdentifier(name)
        button.setAccessibilityLabel(plainLabel)
        curatedButtons.append(button)
        return button
    }

    /// The symbol the picker should mark as "current": the configured
    /// override when set, else the configured default (what the well is
    /// actually showing today). Empty-string default (pre-`configure`)
    /// matches nothing.
    private var effectiveCurrentSymbolName: String? {
        currentSymbolName ?? (defaultSymbolName.isEmpty ? nil : defaultSymbolName)
    }

    /// (Re)resolve every cell's layer colours against the picker's live
    /// effective appearance — called once per grid build and again on every
    /// appearance flip (layer colours are frozen snapshots; `Tokens.Color`
    /// only re-resolves when asked under the right appearance). ONE pass over
    /// the whole grid, so the count below is a count of passes, not of cells.
    private func restampCellColors() {
        test_cellRestampCount += 1
        // `NSApp?.` per the UI-target rule in `AudioutSharedUI/AGENTS.md`; the
        // fallback covers a headless run with no NSApplication at all.
        let appearance = isViewLoaded ? view.effectiveAppearance : (NSApp?.effectiveAppearance ?? .currentDrawing())
        appearance.performAsCurrentDrawingAppearance {
            for button in curatedButtons {
                guard let layer = button.layer else { continue }
                if button === selectedButton {
                    layer.backgroundColor = Tokens.Color.gold.cgColor
                    layer.borderWidth = 0
                    button.contentTintColor = Tokens.Color.inkOnFill
                } else {
                    layer.backgroundColor = Tokens.Color.well.cgColor
                    layer.borderWidth = 1
                    layer.borderColor = Tokens.Color.hairline.cgColor
                    button.contentTintColor = Tokens.Color.labelCool
                }
            }
        }
    }

    /// Plain-language VoiceOver labels for `DeviceIcon.curated` — every symbol
    /// the grid can ever show a button for (the search field's free-text exact
    /// match path previews a symbol but never becomes a grid cell). Falls back
    /// to a space-separated humanization of the raw name for any curated
    /// addition this map hasn't caught up with yet, so a future symbol is
    /// merely less polished, never silent.
    private static let curatedAccessibilityLabels: [String: String] = [
        "hifispeaker.fill": "Speaker",
        "hifispeaker.2.fill": "Stereo speakers",
        "homepod.fill": "HomePod",
        "homepod.2.fill": "Two HomePods",
        "appletv.fill": "Apple TV",
        "tv.fill": "TV",
        "airpods": "AirPods",
        "airpodspro": "AirPods Pro",
        "headphones": "Headphones",
        "speaker.wave.2.fill": "Speaker, medium volume",
        "speaker.wave.3.fill": "Speaker, full volume",
        "radio.fill": "Radio",
        "music.note": "Music note",
        "music.note.house.fill": "Music room",
        "house.fill": "House",
        "bed.double.fill": "Bedroom",
        "sofa.fill": "Living room",
        "fork.knife": "Kitchen",
        "laptopcomputer": "Laptop",
        "desktopcomputer": "Desktop computer",
        "wifi.router.fill": "Wi-Fi router",
        "guitars.fill": "Guitars",
        "gamecontroller.fill": "Game controller",
        "rectangle.3.group": "Grouped devices",
    ]

    private static func accessibilityLabel(forSymbol name: String) -> String {
        curatedAccessibilityLabels[name] ?? name
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    // MARK: Configuration

    /// Configure the picker before presenting it. The effective current
    /// symbol (`currentSymbolName`, falling back to `defaultSymbolName`) is
    /// marked in the curated grid with a solid gold cell + a ", current icon"
    /// VoiceOver label suffix, so the grid rebuilds here in case the view was
    /// already loaded.
    public func configure(currentSymbolName: String?, defaultSymbolName: String) {
        self.currentSymbolName = currentSymbolName
        self.defaultSymbolName = defaultSymbolName
        buildGridRows()
    }

    // MARK: Search validation

    private func updateSearchState() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, DeviceIcon.isValid(trimmed) {
            let image = NSImage(systemSymbolName: trimmed, accessibilityDescription: trimmed)
            image?.isTemplate = true
            previewImageView.image = image
            previewImageView.contentTintColor = Tokens.Color.label2
            previewImageView.isHidden = false
            previewTile.isHidden = false
            applyButton.isEnabled = true
        } else {
            previewImageView.image = nil
            previewImageView.isHidden = true
            previewTile.isHidden = true
            applyButton.isEnabled = false
        }

        updateCuratedGrid(matching: trimmed)
    }

    /// Narrow ``curatedNames`` to a case-insensitive substring match against
    /// `trimmed` (the full curated set when empty), then rebuild the grid so
    /// it reflects the search live — independent of, and alongside, the
    /// exact-name preview/Apply gating above.
    ///
    /// A name matches on the RAW symbol name or on its plain-language label
    /// (``accessibilityLabel(forSymbol:)``), so the words a general user
    /// actually types — "kitchen", "living room", "Apple TV" — find the glyph
    /// whose symbol name says `fork.knife` / `sofa.fill` / `appletv.fill`.
    /// The raw-name path is untouched, so the exact-name power path still
    /// works.
    private func updateCuratedGrid(matching trimmed: String) {
        curatedNames = trimmed.isEmpty
            ? allCuratedNames
            : allCuratedNames.filter {
                $0.range(of: trimmed, options: .caseInsensitive) != nil
                    || Self.accessibilityLabel(forSymbol: $0)
                        .range(of: trimmed, options: .caseInsensitive) != nil
            }

        // `grid`/`emptyResultsLabel` exist independent of the view hierarchy
        // (both are plain stored properties), so this is safe to call even
        // before `loadView` runs — matches `buildGridRows()`'s own contract.
        buildGridRows()
        emptyResultsLabel.isHidden = !curatedNames.isEmpty
        grid.isHidden = curatedNames.isEmpty
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

    /// Increase Contrast or the accent dial moved — re-stamp every cell's
    /// layer colours from the freshly-resolved tokens.
    @objc private func cellTokensDidChange() {
        restampCellColors()
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

    /// Simulate clicking "Use Default Icon".
    public func test_useDefault() { useDefault() }

    /// The curated symbol names actually offered as grid cells right now, in
    /// order — the full curated set (already filtered through
    /// `DeviceIcon.isValid`) when the search field is empty, or the live
    /// search-narrowed subset otherwise. Mirrors what the grid visibly shows.
    public var test_curatedSymbolNames: [String] { curatedNames }

    /// The plain-language VoiceOver label a curated grid button reports for
    /// `symbolName` — pure function, exposed so a test can assert coverage
    /// without traversing `NSGridView`'s button subviews.
    public static func test_accessibilityLabel(forCuratedSymbol name: String) -> String {
        accessibilityLabel(forSymbol: name)
    }

    /// The curated symbol currently wearing the gold "current icon" cell, or
    /// `nil` when the current icon isn't in the visible grid (filtered out, or
    /// the picker is unconfigured).
    public var test_selectedCellSymbolName: String? {
        selectedButton?.identifier?.rawValue
    }

    /// How many times the grid's cell colours have been re-resolved — proves
    /// the accent-dial and Increase-Contrast notifications actually reach them
    /// (they are stamped `CGColor`s, so nothing re-resolves them on its own).
    /// One per PASS over the grid, not one per cell.
    public private(set) var test_cellRestampCount = 0

    /// One cell's glyph tint.
    public func test_cellGlyphTint(for name: String) -> NSColor? {
        curatedButtons.first { $0.identifier?.rawValue == name }?.contentTintColor
    }

    /// One cell's stamped fill, back as an `NSColor`.
    public func test_cellFillColor(for name: String) -> NSColor? {
        guard let cg = curatedButtons.first(where: { $0.identifier?.rawValue == name })?
            .layer?.backgroundColor else { return nil }
        return NSColor(cgColor: cg)
    }
}

// MARK: - Warm Signal helper views (drawing-only)

/// Root view that reports effective-appearance flips to its owner so
/// layer-color styling (the curated cells) can re-resolve live.
private final class AppearanceObservingView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// The mini canvas tile the exact-name preview glyph renders on: a rounded
/// rect at the control radius filled with `Tokens.Color.canvas` and edged with
/// `containerEdge`, so the preview shows the symbol on the product's own
/// surface. Drawn in `draw(_:)` so both tokens re-resolve live per appearance +
/// Increase Contrast (the `WarmCanvasView` pattern); flat fill, no grain.
private final class WarmPreviewTileView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = Tokens.Layout.Radius.control
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        Tokens.Color.canvas.setFill()
        path.fill()
        Tokens.Color.containerEdge.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension IconPickerViewController: NSSearchFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        searchText = field.stringValue
    }
}
