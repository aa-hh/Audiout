// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The icon leading the Equalizer heading: the filled square in the equalizer
/// green on a shaped curve, the outline in the door's rest ink on a flat one.
/// Re-made on an appearance change, an Increase Contrast change and a backing
/// scale change, because the inks and the pixels are resolved into the image.
///
/// Drawn into one owned sublayer rather than as an `NSImageView` so the flip
/// can cross-fade and grow without AppKit's implicit 0.25 s animation: every
/// write that is not a deliberate flip effect runs with actions disabled.
final class EqualizerMarkView: NSView {
    enum FlipEffect { case none, crossFadeOnly, crossFadeAndScale }

    /// "Flat", or what is shaped, in the editor's own readout words: the
    /// heading's spoken value and tooltip on both Equalizer pages.
    static func summary(_ eq: DeviceEQ) -> String {
        guard !eq.isFlat else { return "Flat" }
        var parts: [String] = []
        if eq.bassDB != 0 { parts.append("Bass " + EQEditorView.gainText(eq.bassDB)) }
        if eq.trebleDB != 0 { parts.append("Treble " + EQEditorView.gainText(eq.trebleDB)) }
        if eq.balance != 0 { parts.append("Balance " + EQEditorView.balanceReadoutText(eq.balance)) }
        if eq.loudness { parts.append("Loudness on") }
        let bands = eq.bandGainsDB.filter { $0 != 0 }.count
        if bands > 0 { parts.append(bands == 1 ? "1 band set" : "\(bands) bands set") }
        return parts.joined(separator: ", ")
    }

    private(set) var isShaped = false
    /// One effect and one announcement per gesture: a scrub that crosses 0 dB
    /// back and forth flips the icon silently after the first time. The
    /// announcement posts on `superview` (the heading row, which is the
    /// accessibility element) because this view is not one and VoiceOver may
    /// drop an announcement posted on it.
    private var animatedThisGesture = false
    private let markLayer = CALayer()

    var test_reduceMotionOverride: Bool?
    private(set) var test_lastFlipEffect: FlipEffect = .none
    private(set) var test_lastAnnouncement: String?
    /// The symbol name `refresh()` last drew.
    private(set) var drawnSymbolName = RowAccessorySymbol.equalizerRest
    var test_shapedSymbolName: String { drawnSymbolName }

    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        markLayer.contentsGravity = .center
        markLayer.contentsScale = 2
        layer?.addSublayer(markLayer)
        setAccessibilityElement(false)
        widthAnchor.constraint(equalToConstant: RowAccessorySymbol.headingPointSize).isActive = true
        heightAnchor.constraint(equalToConstant: RowAccessorySymbol.headingPointSize).isActive = true
        // Selector-based observation needs no matching `removeObserver` —
        // AppKit auto-unregisters on dealloc (same as `DeviceRowView`).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setShaped(_ shaped: Bool, userCaused: Bool) {
        test_lastFlipEffect = .none
        let flipped = shaped != isShaped
        let wantsEffect = flipped && userCaused && !animatedThisGesture
        isShaped = shaped
        guard flipped else { return }
        guard wantsEffect else {
            refresh()
            return
        }
        animatedThisGesture = true
        let message = shaped ? "Equalizer shaped" : "Equalizer flat"
        test_lastAnnouncement = message
        NSAccessibility.post(
            element: superview ?? self,
            notification: .announcementRequested,
            userInfo: [.announcement: message,
                       .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let effect: FlipEffect = shaped && !reduceMotion ? .crossFadeAndScale : .crossFadeOnly
        test_lastFlipEffect = effect

        let oldContents = markLayer.contents
        refresh()
        guard !HeadlessRuntime.isActive else { return }
        let fade = CABasicAnimation(keyPath: "contents")
        fade.fromValue = oldContents
        fade.toValue = markLayer.contents
        fade.duration = shaped ? 0.15 : 0.12
        markLayer.add(fade, forKey: "contents")
        if effect == .crossFadeAndScale {
            let grow = CAKeyframeAnimation(keyPath: "transform.scale")
            grow.values = [1, 1.14, 1]
            grow.keyTimes = [0, NSNumber(value: 0.11 / 0.30), 1]
            grow.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1),
                                    CAMediaTimingFunction(name: .easeInEaseOut)]
            grow.duration = 0.30
            markLayer.add(grow, forKey: "grow")
        }
    }

    /// The user's gesture is over (a committed change or a Reset), so the next
    /// flip may animate and announce again.
    func gestureEnded() {
        animatedThisGesture = false
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        refresh()
    }

    /// Writes the current state's image with actions disabled, so the owned
    /// layer never picks up an implicit animation.
    private func refresh() {
        let scale = window?.backingScaleFactor ?? 2
        let image: NSImage?
        if isShaped {
            image = RowAccessorySymbol.equalizerHeading(shaped: true, in: effectiveAppearance)
            drawnSymbolName = RowAccessorySymbol.equalizerEngaged
        } else {
            image = RowAccessorySymbol.equalizerHeading(shaped: false, in: effectiveAppearance)
            drawnSymbolName = RowAccessorySymbol.equalizerRest
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayer.contentsScale = scale
        markLayer.contents = image?.layerContents(forContentsScale: scale)
        CATransaction.commit()
    }
}
