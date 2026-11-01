// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The Mac's one invitation to Audiout Remote (`shape-mac-invites.md`): a QR
/// tile carrying ``RemoteInviteView/codeURLString``, with the page address as
/// text under it. Each host writes its own heading and line around this.
///
/// Two hosts mount this same view at two sizes — Settings › Audiout Remote
/// (72 pt) and the Setup window's iPhone card (160 pt). The alignment wizard
/// dropped its tile for a text link (owner ruling 2026-11-01). It is never a button
/// and never gold: it is information a person takes to their phone, and the
/// only pressable way to the same page is the stock push button each host
/// puts beside it.
///
/// **The tile does not theme, in any appearance or accent-dial position.** A
/// QR code is a print artifact a camera reads, not chrome — black modules on
/// white paper is what a scanner is built for, and a "dark mode" code is a
/// code that fails in the dark. It joins the wizard stage and the EQ scope
/// under PRODUCT.md's "instruments never theme", which is why the two fixed
/// colours here are `NSColor.white` and the artwork's own black rather than
/// `Tokens` values (the sanctioned-exception rule asks for a written reason,
/// and this is it).
///
/// **The tile is hidden from accessibility and the address text is the
/// element.** There is nothing a screen reader can do with a bitmap of
/// modules; the address is the thing it can read out.
public final class RemoteInviteView: NSView {

    /// The page every host's "Open audiout.app/remote" button opens and every
    /// tile prints under the code. Before the iPhone app is on the store this
    /// page says so and takes an email; after it, it carries the store badge.
    public static let pageURLString = "https://audiout.app/remote"

    /// What every QR tile encodes: the App Store listing itself, so a scan
    /// lands one tap from installing (owner decision 2026-11-01). Baked into
    /// `Resources/Audiout-Remote-QR.pdf`; this copy exists so a test can read
    /// the drawn code back and catch artwork that drifted from it.
    public static let codeURLString = "https://apps.apple.com/app/audiout-remote/id6804838945"

    /// The same address as the user reads and types it: no scheme, caption
    /// voice, printed beside every tile.
    public static let pageAddress = "audiout.app/remote"

    /// `pageURLString` as a `URL`, for the hosts' own "Open audiout.app/remote"
    /// buttons.
    public static var pageURL: URL { URL(string: pageURLString)! }

    /// The tile sizes, one per host (`shape-mac-invites.md` §5.1).
    public static let settingsTileSide: CGFloat = 72
    public static let setupTileSide: CGFloat = 160

    private let tile: QRTileView
    private let addressLabel = NSTextField(labelWithString: RemoteInviteView.pageAddress)

    /// - Parameter tileSide: one of the three sizes above.
    public init(tileSide: CGFloat) {
        self.tile = QRTileView(side: tileSide)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addressLabel.font = Tokens.Font.caption
        addressLabel.textColor = Tokens.Color.label2
        // The address is what a screen reader reads in the tile's place.
        tile.setAccessibilityElement(false)

        let stack = NSStackView(views: [tile, addressLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Test-support hooks

    public var test_addressText: String { addressLabel.stringValue }
    public var test_tileSide: CGFloat { tile.side }
    /// The tile rendered exactly as it draws on screen, so a test can put a
    /// real QR reader on it rather than trusting the generator.
    public func test_renderTile() -> NSImage { tile.render() }
}

/// The QR tile itself: a square of white paper carrying the code.
///
/// The code is designed artwork (`Resources/Audiout-Remote-QR.pdf`: rounded
/// modules, the brand mark in the middle), not a generated bitmap, so it is
/// drawn smoothed at any scale rather than snapped to device pixels. The tile
/// pads it so the white margin is at least four modules on every side, the QR
/// standard's own quiet zone, at every size.
private final class QRTileView: NSView {

    /// The artwork's geometry, measured from the designer's 512-unit SVG: 41
    /// modules of 11 units each, with 30 units (under three modules) of white
    /// around them. Only the ratios matter; the PDF is drawn to fit.
    ///
    /// The bundled copy is a PDF (`rsvg-convert -f pdf`) because NSImage's
    /// own SVG renderer ignores the artwork's clip path and draws the module
    /// layer as one solid black square.
    private static let artworkSide: CGFloat = 512
    private static let artworkMargin: CGFloat = 30
    private static let moduleSide: CGFloat = 11
    private static let quietZoneModules: CGFloat = 4

    /// One image, shared by every tile — every size carries the same code.
    /// `nil` only if the bundled asset is missing, which leaves a blank tile
    /// rather than a crash (the same degrade as ``BrandMark``).
    private static let code: NSImage? = BrandMark.resourceBundle
        .flatMap { $0.url(forResource: "Audiout-Remote-QR", withExtension: "pdf") }
        .flatMap { NSImage(contentsOf: $0) }

    let side: CGFloat

    init(side: CGFloat) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // FIXED, both appearances and every accent-dial position — see
        // `RemoteInviteView`'s note on why a QR code is not chrome.
        NSColor.white.setFill()
        bounds.fill()
        guard let code = Self.code else { return }
        // Grow the artwork's own margin to the full quiet zone: the artwork
        // is drawn into a square that much smaller than the tile.
        let quiet = Self.quietZoneModules * Self.moduleSide
        let extra = max(0, quiet - Self.artworkMargin)
        let drawn = side * Self.artworkSide / (Self.artworkSide + 2 * extra)
        let origin = (side - drawn) / 2
        NSGraphicsContext.current?.imageInterpolation = .high
        code.draw(in: NSRect(x: origin, y: origin, width: drawn, height: drawn))
    }

    /// The tile as an image, for the test that decodes it back.
    func render() -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        draw(bounds)
        image.unlockFocus()
        return image
    }
}
