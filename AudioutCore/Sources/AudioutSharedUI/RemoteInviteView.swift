// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Mac's one invitation to Audiout Remote (`shape-mac-invites.md`): a QR
/// tile carrying ``RemoteInviteView/pageURLString``, with the address as text
/// under it. Each host writes its own heading and line around this.
///
/// Three hosts mount this same view at three sizes — the alignment wizard
/// sheet's first page (96 pt), Settings › General under the Allow switch
/// (72 pt), and the Setup window's iPhone card (160 pt). It is never a button
/// and never gold: it is information a person takes to their phone, and the
/// only pressable way to the same page is the stock push button each host
/// puts beside it.
///
/// **The tile does not theme, in any appearance or accent-dial position.** A
/// QR code is a print artifact a camera reads, not chrome — black modules on
/// white paper is what a scanner is built for, and a "dark mode" code is a
/// code that fails in the dark. It joins the wizard stage and the EQ scope
/// under PRODUCT.md's "instruments never theme", which is why the two fixed
/// colours here are `NSColor.white` and the generator's own black rather than
/// `Tokens` values (the sanctioned-exception rule asks for a written reason,
/// and this is it).
///
/// **The tile is hidden from accessibility and the address text is the
/// element.** There is nothing a screen reader can do with a bitmap of
/// modules; the address is the thing it can read out.
public final class RemoteInviteView: NSView {

    /// What every QR tile in the app encodes, and the one page all four
    /// invitations point at. Before the iPhone app is on the store this page
    /// says so and takes an email; after it, it carries the store badge. No
    /// Mac string names the store, so nothing here changes on launch day.
    public static let pageURLString = "https://audiout.app/remote"

    /// The same address as the user reads and types it: no scheme, caption
    /// voice, printed beside every tile.
    public static let pageAddress = "audiout.app/remote"

    /// `pageURLString` as a `URL`, for the hosts' own "Open audiout.app/remote"
    /// buttons.
    public static var pageURL: URL { URL(string: pageURLString)! }

    /// The three tile sizes, one per host (`shape-mac-invites.md` §5.1).
    public static let settingsTileSide: CGFloat = 72
    public static let wizardTileSide: CGFloat = 96
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
/// Modules are drawn at a whole number of DEVICE pixels with interpolation
/// off, so no module ever lands on a half pixel and blurs — that is what a
/// camera fails to read. Whatever the scale leaves over stays white, which is
/// the quiet zone doing its job: the code carries a four-module margin at
/// minimum and more is never worse.
private final class QRTileView: NSView {

    /// Four modules of white on every side is the QR standard's own quiet
    /// zone. `CIFilter.qrCodeGenerator()` already draws ONE of them into its
    /// output (measured: a 25-module symbol comes back 27 px square), so the
    /// tile adds the other three.
    private static let quietZoneModules: CGFloat = 4
    private static let generatorQuietZoneModules: CGFloat = 1

    /// One generated code, shared by every tile — all three sizes carry the
    /// same address, and the generator is the expensive part.
    private static let code: CGImage? = makeCode(RemoteInviteView.pageURLString)

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

    /// A change of screen changes how many device pixels a module gets.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // FIXED, both appearances and every accent-dial position — see
        // `RemoteInviteView`'s note on why a QR code is not chrome.
        NSColor.white.setFill()
        bounds.fill()
        guard let code = Self.code, let context = NSGraphicsContext.current?.cgContext else { return }
        let modules = CGFloat(code.width)
        let scale = moduleScale(modules: modules)
        let drawn = modules * scale
        let origin = ((side - drawn) / 2).rounded(.down)
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: origin, y: origin, width: drawn, height: drawn))
    }

    /// Points per module: the largest whole number of device pixels that
    /// still leaves the quiet zone.
    private func moduleScale(modules: CGFloat) -> CGFloat {
        let pixel = 1 / max(1, window?.backingScaleFactor ?? 1)
        let extraQuiet = (Self.quietZoneModules - Self.generatorQuietZoneModules) * 2
        let fits = side / (modules + extraQuiet)
        return max(pixel, (fits / pixel).rounded(.down) * pixel)
    }

    /// The tile as an image, for the test that decodes it back.
    func render() -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        draw(bounds)
        image.unlockFocus()
        return image
    }

    private static func makeCode(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Level M: the middle of the four, and what a printed code this size
        // is normally cut at. Level L would not shrink this address's symbol
        // (both land on version 2, 25 modules).
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: nil).createCGImage(output, from: output.extent)
    }
}
