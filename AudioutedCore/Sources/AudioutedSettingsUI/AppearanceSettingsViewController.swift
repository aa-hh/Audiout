// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AudioutedCore

/// Settings › **Appearance** pane: a Theme picker built from **miniature window
/// previews** (Match System / Light / Dark) — the standard macOS pattern
/// (System Settings › Appearance; SoundSource's own Theme picker, Alec's
/// reference). Each option renders a tiny window mock *in that appearance* —
/// light chrome for Light, dark chrome for Dark, a diagonal light/dark split for
/// Match System — with the label beneath and an accent ring on the selection.
/// This replaced a first pass of bare gearshape/sun/moon glyph tiles, which read
/// as placeholder (2026-07-17): a literal preview of the appearance is far more
/// legible than an abstract icon.
///
/// Custom-drawn (`ThemeTileButton`) — justified because AppKit ships no control
/// that renders an appearance preview; this is the codebase's one custom-drawn
/// button, everything else uses a stock bezel.
///
/// The pane owns persistence (writes `AppSettings.theme`) but NOT the side
/// effect: applying the override app-wide means touching `NSApp.appearance`,
/// which is the app layer's job (Core/this module stay out of `NSApp`). So a
/// selection persists here and fires ``onThemeChanged`` for the app to apply —
/// the same value the app also reads from `AppSettings` at launch.
@MainActor
public final class AppearanceSettingsViewController: NSViewController {

    private let settings: AppSettings

    /// Fired after a theme selection is persisted, so the app can apply it
    /// (`NSApp.appearance = …`). Not called at launch — the app reads
    /// `AppSettings.theme` directly there.
    public var onThemeChanged: ((AppearanceTheme) -> Void)?

    /// Tile order == this array; the single source of truth mapping a tile index
    /// to a theme (no parallel `switch` to drift out of sync).
    private let order: [AppearanceTheme] = [.system, .light, .dark]
    private var tiles: [ThemeTileButton] = []
    private var selectedIndex = 0

    public init(settings: AppSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = "Appearance"
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        tiles = order.map(makeTile)
        selectTile(for: settings.theme)

        let tileRow = NSStackView(views: tiles)
        tileRow.orientation = .horizontal
        tileRow.spacing = 12
        tileRow.translatesAutoresizingMaskIntoConstraints = false

        let heading = SettingsForm.label("Theme")
        heading.font = .systemFont(ofSize: NSFont.systemFontSize)
        let subtitle = SettingsForm.label("Follow the system, or force light or dark.")
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor

        let column = NSStackView(views: [heading, tileRow, subtitle])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8

        view = SettingsForm.paneView(rows: [column])
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: SettingsForm.contentWidth, height: view.fittingSize.height)
    }

    private func makeTile(for theme: AppearanceTheme) -> ThemeTileButton {
        let tile = ThemeTileButton(theme: theme)
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.widthAnchor.constraint(equalToConstant: 100).isActive = true
        tile.heightAnchor.constraint(equalToConstant: 84).isActive = true
        tile.isBordered = false
        tile.target = self
        tile.action = #selector(tileTapped(_:))
        tile.setAccessibilityLabel(theme.displayName)
        return tile
    }

    private func selectTile(for theme: AppearanceTheme) {
        selectedIndex = order.firstIndex(of: theme) ?? 0
        applySelectionHighlight()
    }

    private func applySelectionHighlight() {
        for (index, tile) in tiles.enumerated() {
            tile.isSelectedTile = index == selectedIndex
        }
    }

    @objc private func tileTapped(_ sender: ThemeTileButton) {
        guard let index = tiles.firstIndex(of: sender) else { return }
        selectedIndex = index
        applySelectionHighlight()
        let theme = order[index]
        settings.theme = theme
        onThemeChanged?(theme)
    }

    // MARK: Test-support hooks

    /// The currently selected theme. Forces the view to load so the initial
    /// selection (applied in `loadView`) is reflected even before the window shows.
    public var test_selectedTheme: AppearanceTheme {
        _ = view   // force the lazy view load so `loadView`'s initial selection applies
        return order[safe: selectedIndex] ?? .system
    }

    /// Select `theme` and run the same action a real click would (persist + fire).
    public func test_selectTheme(_ theme: AppearanceTheme) {
        _ = view
        guard let index = order.firstIndex(of: theme), let tile = tiles[safe: index] else { return }
        tileTapped(tile)
    }
}

/// A theme-picker tile: a miniature window preview rendered *in* its target
/// appearance, with the label beneath and an accent ring on selection. Fully
/// custom-drawn — the preview chrome uses ABSOLUTE (non-adaptive) colours on
/// purpose, so a "Light" tile stays light even while the app is in dark mode,
/// and vice versa (the tile depicts an appearance, it doesn't adopt one).
final class ThemeTileButton: NSButton {

    private let theme: AppearanceTheme

    var isSelectedTile: Bool = false {
        didSet { if isSelectedTile != oldValue { needsDisplay = true } }
    }
    private var isHovered: Bool = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    init(theme: AppearanceTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Draw top-down (origin top-left, y grows downward) so the geometry below
    /// is deterministic and reads directly: preview on top, label beneath —
    /// independent of the ambient coordinate flip.
    override var isFlipped: Bool { true }

    // MARK: Draw

    private enum Mock {
        // Absolute (non-adaptive) preview palettes — a Light tile must look light
        // in dark mode and vice versa, so these are fixed sRGB, never semantic.
        static let lightBody = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        static let lightChrome = NSColor(srgbRed: 0.91, green: 0.91, blue: 0.92, alpha: 1)
        static let lightBar = NSColor(srgbRed: 0.84, green: 0.84, blue: 0.86, alpha: 1)
        static let lightStroke = NSColor(srgbRed: 0.74, green: 0.74, blue: 0.76, alpha: 1)

        static let darkBody = NSColor(srgbRed: 0.14, green: 0.14, blue: 0.15, alpha: 1)
        static let darkChrome = NSColor(srgbRed: 0.24, green: 0.24, blue: 0.25, alpha: 1)
        static let darkBar = NSColor(srgbRed: 0.33, green: 0.33, blue: 0.35, alpha: 1)
        static let darkStroke = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)

        static let red = NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1)
        static let yellow = NSColor(srgbRed: 0.99, green: 0.74, blue: 0.18, alpha: 1)
        static let green = NSColor(srgbRed: 0.15, green: 0.79, blue: 0.25, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let ringInset: CGFloat = 3
        let labelHeight: CGFloat = 16
        let gap: CGFloat = 6
        // Top-down (isFlipped): preview thumbnail on top, label beneath it.
        let thumb = NSRect(
            x: ringInset,
            y: ringInset,
            width: bounds.width - 2 * ringInset,
            height: bounds.height - labelHeight - gap - 2 * ringInset)

        drawPreview(in: thumb)

        // Selection ring (accent) / hover ring (subtle), around the thumbnail.
        let ringRect = thumb.insetBy(dx: -2.5, dy: -2.5)
        let ring = NSBezierPath(roundedRect: ringRect, xRadius: 9, yRadius: 9)
        if isSelectedTile {
            NSColor.controlAccentColor.setStroke()
            ring.lineWidth = 2.5
            ring.stroke()
        } else if isHovered {
            NSColor.separatorColor.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }

        drawLabel(in: NSRect(x: 0, y: thumb.maxY + gap, width: bounds.width, height: labelHeight))
    }

    private func drawLabel(in rect: NSRect) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: isSelectedTile ? .medium : .regular),
            .foregroundColor: isSelectedTile ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]
        let string = NSAttributedString(string: theme.displayName, attributes: attrs)
        let size = string.size()
        let y = rect.minY + (rect.height - size.height) / 2
        string.draw(in: NSRect(x: rect.minX, y: y, width: rect.width, height: size.height))
    }

    private func drawPreview(in rect: NSRect) {
        switch theme {
        case .light:
            drawWindowMock(in: rect, body: Mock.lightBody, chrome: Mock.lightChrome,
                           bar: Mock.lightBar, stroke: Mock.lightStroke, trafficLights: true)
        case .dark:
            drawWindowMock(in: rect, body: Mock.darkBody, chrome: Mock.darkChrome,
                           bar: Mock.darkBar, stroke: Mock.darkStroke, trafficLights: true)
        case .system:
            // Diagonal split: light on the left, dark clipped to the leaning
            // right region — the macOS "Auto" metaphor for "matches whichever the
            // system is".
            drawWindowMock(in: rect, body: Mock.lightBody, chrome: Mock.lightChrome,
                           bar: Mock.lightBar, stroke: Mock.lightStroke, trafficLights: true)

            // Right region leans across the split (top-down coords: minY = top).
            let lean: CGFloat = 8
            let rightRegion = NSBezierPath()
            rightRegion.move(to: NSPoint(x: rect.midX + lean, y: rect.minY))
            rightRegion.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            rightRegion.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            rightRegion.line(to: NSPoint(x: rect.midX - lean, y: rect.maxY))
            rightRegion.close()

            NSGraphicsContext.saveGraphicsState()
            rightRegion.addClip()
            drawWindowMock(in: rect, body: Mock.darkBody, chrome: Mock.darkChrome,
                           bar: Mock.darkBar, stroke: Mock.darkStroke, trafficLights: false)
            NSGraphicsContext.restoreGraphicsState()

            // A crisp divider along the split.
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: rect.midX + lean, y: rect.minY))
            divider.line(to: NSPoint(x: rect.midX - lean, y: rect.maxY))
            let clip = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.35).setStroke()
            divider.lineWidth = 1
            divider.stroke()
            NSGraphicsContext.restoreGraphicsState()

            // Re-stroke the outer frame so the rounded border reads over both halves.
            Mock.lightStroke.setStroke()
            clip.lineWidth = 1
            clip.stroke()
        }
    }

    /// Draw one miniature window: rounded body, a title-bar strip with optional
    /// traffic lights, and a few faint content bars.
    private func drawWindowMock(in rect: NSRect, body: NSColor, chrome: NSColor,
                                bar: NSColor, stroke: NSColor, trafficLights: Bool) {
        let radius: CGFloat = 6
        let frame = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        frame.addClip()

        body.setFill()
        rect.fill()

        // Title bar at the top (top-down coords: minY = top).
        let barHeight = max(11, rect.height * 0.28)
        let titleBar = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: barHeight)
        chrome.setFill()
        titleBar.fill()

        if trafficLights {
            let r: CGFloat = 2.4
            let cy = titleBar.midY
            var cx = rect.minX + 9
            for color in [Mock.red, Mock.yellow, Mock.green] {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).fill()
                cx += 8
            }
        }

        // Content bars below the title bar, marching downward.
        bar.setFill()
        let barX = rect.minX + 9
        var barY = titleBar.maxY + 6
        for widthFraction in [0.52, 0.66, 0.42] {
            guard barY < rect.maxY - 5 else { break }
            let line = NSRect(x: barX, y: barY, width: rect.width * widthFraction, height: 3)
            NSBezierPath(roundedRect: line, xRadius: 1.5, yRadius: 1.5).fill()
            barY += 8
        }

        NSGraphicsContext.restoreGraphicsState()

        stroke.setStroke()
        frame.lineWidth = 1
        frame.stroke()
    }
}

private extension AppearanceTheme {
    /// Sentence-case tile label.
    var displayName: String {
        switch self {
        case .system: return "Match System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

private extension Array {
    /// Bounds-checked subscript so an index can never trap.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
