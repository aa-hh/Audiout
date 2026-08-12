// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// Settings › **Appearance** pane: a Theme picker built from **miniature window
/// previews** (Match System / Light / Dark) — the standard macOS pattern
/// (System Settings › Appearance; SoundSource's own Theme picker, ahh's
/// reference). Each option renders a tiny window mock *in that appearance* —
/// light chrome for Light, dark chrome for Dark, a diagonal light/dark split for
/// Match System — with the label beneath and an accent ring on the selection.
/// A literal preview of the appearance is far more legible than abstract
/// glyph tiles.
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

    /// Fired after an Accent dial selection is persisted AND applied to the
    /// live token remap (`Tokens.accentStyle`), so the app layer can nudge any
    /// open surfaces to repaint. Not called at launch — the app seeds
    /// `Tokens.accentStyle` from `AppSettings.accentStyle` there.
    public var onAccentChanged: ((AccentStyle) -> Void)?

    /// Tile order == this array; the single source of truth mapping a tile index
    /// to a theme (no parallel `switch` to drift out of sync).
    private let order: [AppearanceTheme] = [.system, .light, .dark]
    private var tiles: [ThemeTileButton] = []
    private var selectedIndex = 0

    /// Radio order == this array — same single-source-of-truth idiom as `order`.
    private let accentOrder: [AccentStyle] = [.fullGold, .subtle, .systemAccent]
    private var accentRadios: [NSButton] = []
    private let accentHint = SettingsForm.hintLabel()

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

        // Section-header voice (roadmap 050 typeset pass): the same role must
        // read the same in every pane — Audio's headers already use it.
        let heading = SettingsForm.sectionHeader("Theme")
        let subtitle = SettingsForm.label("Follow the system, or force light or dark.")
        subtitle.font = Tokens.Font.caption
        subtitle.textColor = Tokens.Color.secondaryLabel

        let column = NSStackView(views: [heading, tileRow, subtitle])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8

        view = SettingsForm.paneView(rows: [column, makeAccentSection()])
    }

    /// The **Accent** dial (Warm Signal spec §1.3 / §5.2 — decision i): three
    /// stock radios under a hairline. The pane persists the choice AND applies
    /// the live token remap itself (`Tokens.accentStyle` — the token module is
    /// process-local state, not an `NSApp` side effect, so unlike the theme
    /// there is no app-layer apply step to defer to); ``onAccentChanged`` then
    /// lets the app nudge open surfaces to repaint.
    private func makeAccentSection() -> NSView {
        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false

        // Same section-header voice as Theme and the Audio pane's headers.
        let heading = SettingsForm.sectionHeader("Accent")

        let subtitle = SettingsForm.label("How strongly meters, dots, and rings use the brand gold.")
        subtitle.font = Tokens.Font.caption
        subtitle.textColor = Tokens.Color.secondaryLabel

        accentRadios = accentOrder.map { style in
            let radio = NSButton(radioButtonWithTitle: style.displayName,
                                 target: self,
                                 action: #selector(accentTapped(_:)))
            radio.translatesAutoresizingMaskIntoConstraints = false
            radio.setAccessibilityLabel(style.displayName)
            return radio
        }
        // Horizontal on purpose: the three dial names fit comfortably in the
        // fixed 460 pt form width and keep the pane short (see
        // `eachTabHasNonDegenerateFittedSize`).
        let radioColumn = NSStackView(views: accentRadios)
        radioColumn.orientation = .horizontal
        radioColumn.alignment = .firstBaseline
        radioColumn.spacing = 12

        applyAccentSelection(settings.accentStyle)

        let column = NSStackView(views: [hairline, heading, subtitle, radioColumn, accentHint])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        hairline.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    /// Reflect `style` in the radio group + the live hint line (no persistence,
    /// no side effects — shared by `loadView` and the click path).
    private func applyAccentSelection(_ style: AccentStyle) {
        let index = accentOrder.firstIndex(of: style) ?? 0
        for (radioIndex, radio) in accentRadios.enumerated() {
            radio.state = radioIndex == index ? .on : .off
        }
        accentHint.stringValue = style.hintLine
    }

    @objc private func accentTapped(_ sender: NSButton) {
        guard let index = accentRadios.firstIndex(of: sender),
              let style = accentOrder[safe: index] else { return }
        applyAccentSelection(style)
        settings.accentStyle = style
        Tokens.accentStyle = style
        onAccentChanged?(style)
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
        // `.radioButton` role + a 0/1 accessibility value is the standard AX
        // contract VoiceOver reads aloud as "selected"/"not selected" — without
        // it, all three tiles announce identically and the current theme is
        // never conveyed non-visually.
        tile.setAccessibilityRole(.radioButton)
        tile.setAccessibilityLabel(theme.displayName)
        return tile
    }

    private func selectTile(for theme: AppearanceTheme) {
        selectedIndex = order.firstIndex(of: theme) ?? 0
        applySelectionHighlight()
    }

    private func applySelectionHighlight() {
        for (index, tile) in tiles.enumerated() {
            let isSelected = index == selectedIndex
            tile.isSelectedTile = isSelected
            tile.setAccessibilityValue(isSelected)
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

    /// Whether `theme`'s tile currently reports itself as VoiceOver-selected
    /// (`.radioButton` role + a 1/0 accessibility value, set in
    /// `applySelectionHighlight()`) — verifies the fix for all three tiles
    /// previously sounding identical to VoiceOver.
    public func test_isTileAccessibilitySelected(_ theme: AppearanceTheme) -> Bool {
        _ = view
        guard let index = order.firstIndex(of: theme), let tile = tiles[safe: index] else { return false }
        return (tile.accessibilityValue() as? NSNumber)?.boolValue ?? false
    }

    // MARK: Test-support hooks (Accent dial — W1, spec §1.3)

    /// The accent style whose radio is currently on.
    public var test_selectedAccentStyle: AccentStyle {
        _ = view
        let index = accentRadios.firstIndex(where: { $0.state == .on }) ?? 0
        return accentOrder[safe: index] ?? .fullGold
    }

    /// Select `style` and run the same action a real radio click would
    /// (persist + remap `Tokens.accentStyle` + fire ``onAccentChanged``).
    public func test_selectAccentStyle(_ style: AccentStyle) {
        _ = view
        guard let index = accentOrder.firstIndex(of: style),
              let radio = accentRadios[safe: index] else { return }
        accentTapped(radio)
    }

    /// The live hint line under the accent radios.
    public var test_accentHint: String {
        _ = view
        return accentHint.stringValue
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
        static let lightChrome = NSColor(srgbRed: 0.91, green: 0.91, blue: 0.92, alpha: 1)
        static let lightStroke = NSColor(srgbRed: 0.74, green: 0.74, blue: 0.76, alpha: 1)

        static let darkChrome = NSColor(srgbRed: 0.24, green: 0.24, blue: 0.25, alpha: 1)
        static let darkStroke = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55)

        static let red = NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1)
        static let yellow = NSColor(srgbRed: 0.99, green: 0.74, blue: 0.18, alpha: 1)
        static let green = NSColor(srgbRed: 0.15, green: 0.79, blue: 0.25, alpha: 1)
    }

    /// One theme's **warm product-panel** preview palette (Warm Signal spec
    /// §5.2 — the tiles "preview the actual product", so the body is the real
    /// warm canvas with a lit gold row + meter sliver; these are the ONLY
    /// warm/gold pixels anywhere in Settings, because they depict the product).
    /// Same ABSOLUTE-palette exception as `Mock` above, deliberately extended
    /// to the warm values: the tile portrays an appearance, it doesn't adopt
    /// one, so these are fixed sRGB mirrors of the spec §1.1/§1.2 hexes —
    /// never the live semantic `Tokens` (which follow the CURRENT appearance
    /// and accent dial, and would make a "Light" tile go dark in dark mode).
    private struct WarmPreviewPalette {
        let chrome: NSColor    // title-bar strip (window chrome stays system-ish)
        let stroke: NSColor    // outer frame
        let canvas: NSColor    // §1.1/§1.2 `canvas`
        let well: NSColor      // §1.1/§1.2 `well` (the row's icon well)
        let name: NSColor      // §1.1/§1.2 `text` (the lit row's name bar)
        let nameDim: NSColor   // §1.1/§1.2 `text-3` (the idle row's name bar)
        let gold: NSColor      // §1.1/§1.2 `gold` (route-armed dot, meter hot end)
        let ember: NSColor     // §1.1/§1.2 `ember` (meter low end)

        /// Dark flagship (spec §1.1). `well` is `0x100D0A` — the fader-
        /// legibility retune's darkened value (`Tokens.Color.well`'s dark
        /// case, Tokens.swift), NOT the original spec hex `0x2B2620`: this
        /// tile depicts the live product, so a token re-tune must carry over
        /// here too. `PreviewPaletteTokenPinTests` pins every literal below
        /// that has a `Tokens.Color` counterpart against the live token, so a
        /// future re-tune fails loudly here instead of drifting silently
        /// (this exact case — `well` sat stale through one retune already).
        static let dark = WarmPreviewPalette(
            chrome: Mock.darkChrome, stroke: Mock.darkStroke,
            canvas: NSColor(srgbRed: 0x16 / 255, green: 0x13 / 255, blue: 0x0F / 255, alpha: 1),
            well: NSColor(srgbRed: 0x10 / 255, green: 0x0D / 255, blue: 0x0A / 255, alpha: 1),
            name: NSColor(srgbRed: 0xEF / 255, green: 0xE9 / 255, blue: 0xDD / 255, alpha: 1),
            nameDim: NSColor(srgbRed: 0x7A / 255, green: 0x70 / 255, blue: 0x62 / 255, alpha: 1),
            gold: NSColor(srgbRed: 0xE8 / 255, green: 0xB8 / 255, blue: 0x4B / 255, alpha: 1),
            ember: NSColor(srgbRed: 0x8A / 255, green: 0x6A / 255, blue: 0x2F / 255, alpha: 1))

        /// Circuit light (the 2026-08-07 light-theme decision — `canvas` is
        /// Circuit `bg/normal`, `well` the deepened Circuit `bg/highlight`,
        /// `ember` and `gold` the light instruments darkened until each clears
        /// 3:1 on the `well` they are drawn over, 2026-08-12).
        static let light = WarmPreviewPalette(
            chrome: Mock.lightChrome, stroke: Mock.lightStroke,
            canvas: NSColor(srgbRed: 0xFB / 255, green: 0xFB / 255, blue: 0xF9 / 255, alpha: 1),
            well: NSColor(srgbRed: 0xE2 / 255, green: 0xDF / 255, blue: 0xD3 / 255, alpha: 1),
            name: NSColor(srgbRed: 0x2B / 255, green: 0x25 / 255, blue: 0x19 / 255, alpha: 1),
            nameDim: NSColor(srgbRed: 0x9A / 255, green: 0x8F / 255, blue: 0x7D / 255, alpha: 1),
            gold: NSColor(srgbRed: 0xA6 / 255, green: 0x7C / 255, blue: 0x1E / 255, alpha: 1),
            ember: NSColor(srgbRed: 0x9C / 255, green: 0x7E / 255, blue: 0x3C / 255, alpha: 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let ringInset: CGFloat = 3
        let labelHeight: CGFloat = 16
        let gap: CGFloat = 6
        let ringCornerRadius: CGFloat = 9
        // Top-down (isFlipped): preview thumbnail on top, label beneath it.
        let thumb = NSRect(
            x: ringInset,
            y: ringInset,
            width: bounds.width - 2 * ringInset,
            height: bounds.height - labelHeight - gap - 2 * ringInset)

        drawPreview(in: thumb)

        // Selection ring (accent) / hover ring (subtle), around the thumbnail.
        let ringRect = thumb.insetBy(dx: -2.5, dy: -2.5)
        let ring = NSBezierPath(roundedRect: ringRect, xRadius: ringCornerRadius, yRadius: ringCornerRadius)
        if isSelectedTile {
            Tokens.Color.accent.setStroke()
            ring.lineWidth = 2.5
            ring.stroke()
        } else if isHovered {
            Tokens.Color.separator.setStroke()
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
            drawWindowMock(in: rect, palette: .light, trafficLights: true)
        case .dark:
            drawWindowMock(in: rect, palette: .dark, trafficLights: true)
        case .system:
            // Diagonal split: light on the left, dark clipped to the leaning
            // right region — the macOS "Auto" metaphor for "matches whichever the
            // system is".
            drawWindowMock(in: rect, palette: .light, trafficLights: true)

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
            drawWindowMock(in: rect, palette: .dark, trafficLights: false)
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

    /// Draw one miniature window previewing the REAL warm panel (spec §5.2):
    /// rounded body filled with the warm canvas, a title-bar strip with
    /// optional traffic lights, then a **lit gold row** (icon well · name bar ·
    /// gold route-armed dot, with an ember→gold meter sliver beneath the name)
    /// over an idle dimmed row — the popover's own status-cluster language in
    /// miniature.
    private func drawWindowMock(in rect: NSRect, palette: WarmPreviewPalette, trafficLights: Bool) {
        let radius: CGFloat = 6
        let frame = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        frame.addClip()

        palette.canvas.setFill()
        rect.fill()

        // Title bar at the top (top-down coords: minY = top).
        let barHeight = max(11, rect.height * 0.28)
        let titleBar = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: barHeight)
        palette.chrome.setFill()
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

        // Lit row: icon well · name bar · gold dot, meter sliver under the name.
        let wellSize: CGFloat = 9
        let rowX = rect.minX + 8
        let litY = titleBar.maxY + 6
        let well = NSRect(x: rowX, y: litY, width: wellSize, height: wellSize)
        palette.well.setFill()
        NSBezierPath(roundedRect: well, xRadius: 2.5, yRadius: 2.5).fill()

        let nameX = well.maxX + 5
        let name = NSRect(x: nameX, y: litY + 1.5, width: rect.width * 0.34, height: 2.5)
        palette.name.setFill()
        NSBezierPath(roundedRect: name, xRadius: 1.25, yRadius: 1.25).fill()

        // Route-armed gold corner dot at the row's trailing edge.
        let dotDiameter: CGFloat = 4
        let dot = NSRect(x: rect.maxX - 10 - dotDiameter, y: well.midY - dotDiameter / 2,
                         width: dotDiameter, height: dotDiameter)
        palette.gold.setFill()
        NSBezierPath(ovalIn: dot).fill()

        // Meter sliver: the warm ember→gold gradient (never failure red).
        let meter = NSRect(x: nameX, y: name.maxY + 2.5, width: rect.width * 0.42, height: 2)
        let meterPath = NSBezierPath(roundedRect: meter, xRadius: 1, yRadius: 1)
        NSGradient(colors: [palette.ember, palette.gold])?.draw(in: meterPath, angle: 0)

        // Idle row beneath: dimmed name, no dot, no meter.
        let idleY = meter.maxY + 5
        if idleY + wellSize < rect.maxY - 3 {
            let idleWell = NSRect(x: rowX, y: idleY, width: wellSize, height: wellSize)
            palette.well.setFill()
            NSBezierPath(roundedRect: idleWell, xRadius: 2.5, yRadius: 2.5).fill()

            let idleName = NSRect(x: nameX, y: idleWell.midY - 1.25, width: rect.width * 0.28, height: 2.5)
            palette.nameDim.setFill()
            NSBezierPath(roundedRect: idleName, xRadius: 1.25, yRadius: 1.25).fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        palette.stroke.setStroke()
        frame.lineWidth = 1
        frame.stroke()
    }

    // MARK: Test-support hooks (V5 — preview-palette/Tokens pin)

    /// The dark/light preview palettes' `canvas`/`well`/`gold`/`ember` —
    /// the four fields that mirror a real `Tokens.Color` case (`name`/
    /// `nameDim`/`chrome`/`stroke` have no token counterpart: they're mock
    /// window chrome or the spec's unaliased `text`/`text-3`). `WarmPreviewPalette`
    /// is `private`, reachable only from this file, so the pin test goes
    /// through this accessor rather than the type directly.
    static func test_previewPaletteColor(dark isDark: Bool, field: TestPreviewField) -> NSColor {
        let palette: WarmPreviewPalette = isDark ? .dark : .light
        switch field {
        case .canvas: return palette.canvas
        case .well: return palette.well
        case .gold: return palette.gold
        case .ember: return palette.ember
        }
    }

    enum TestPreviewField { case canvas, well, gold, ember }
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

private extension AccentStyle {
    /// Radio title (spec §1.3's three dial names).
    var displayName: String {
        switch self {
        case .fullGold:     return "Full Gold"
        case .subtle:       return "Subtle"
        case .systemAccent: return "Follow System Accent"
        }
    }

    /// The live hint line for the current dial position — what this choice
    /// actually does to the instruments, per §1.3's remap table.
    var hintLine: String {
        switch self {
        case .fullGold:     return "Meters, dots, and rings glow in the full brand gold."
        case .subtle:       return "A quieter gold — softer meters, and no glow around the routing dot."
        case .systemAccent: return "Gold instruments take on this Mac's accent color instead."
        }
    }
}

private extension Array {
    /// Bounds-checked subscript so an index can never trap.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
