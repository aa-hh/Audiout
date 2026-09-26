// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The one-time thanks shown in the popover's note slot after a purchase
/// (Concept A, `dev/notes/thank-you-card-concept-2026-09-26.md`): the banner's
/// recipe with `gold` for its tint, the emitter field's settled rings in a
/// 96 pt well at the leading edge, the words beside them, and a Close button.
/// The rings play one surge on `appear()`, then rest. Never a loop.
final class ThankYouCardView: NSView, FoldFollowing {

    static let height: CGFloat = 112
    static let headline = "Thank you for buying Audiout."
    static let body = "You paid once, and it's yours for good. Every update is included. Your purchase pays for the work on the next ones, and that means a lot to one small team."

    var onClose: (() -> Void)?

    private let headlineLabel: NSTextField
    private let bodyLabel: NSTextField
    private let closeButton: NSButton
    private let well = NSView()
    /// Two layers because `SettledLightLayer` draws exactly two lights and the
    /// card wants three. Empty headless or without a GPU.
    private let ringLayers: [SettledLightLayer]
    private var surgeLink: CADisplayLink?
    private var surgeStart: CFTimeInterval?

    private static let restOpacity: Float = 0.7
    private static let surgeDuration: CFTimeInterval = 2.5

    /// Holds ``fade``. A constraint keeps its items unowned, so this view
    /// outlives it; it is in no hierarchy and lays nothing out.
    private let fadeHost = NSView()
    /// The appear fade's one animated value, riding an inactive constraint
    /// because a constraint constant is what `FoldAnimator` tweens — the
    /// `AppSurfaceController.fadeInMountedScreen` idiom.
    private lazy var fade: NSLayoutConstraint = fadeHost.widthAnchor.constraint(equalToConstant: 0)

    init(width: CGFloat) {
        headlineLabel = NSTextField(labelWithString: Self.headline)
        headlineLabel.font = Tokens.Font.heading
        headlineLabel.textColor = .labelColor
        bodyLabel = NSTextField(wrappingLabelWithString: Self.body)
        bodyLabel.font = Tokens.Font.body
        bodyLabel.textColor = Tokens.Color.label2
        bodyLabel.isSelectable = false
        bodyLabel.preferredMaxLayoutWidth = 380
        closeButton = NSButton(title: "Close", target: nil, action: nil)
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        ringLayers = [SettledLightLayer.make(), SettledLightLayer.make()].compactMap { $0 }

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Tokens.Layout.Radius.control
        layer?.cornerCurve = .continuous
        stampLayerColors()

        well.wantsLayer = true
        well.layer?.cornerRadius = Tokens.Layout.Radius.control
        well.layer?.cornerCurve = .continuous
        well.layer?.masksToBounds = true
        for ring in ringLayers { well.layer?.addSublayer(ring) }

        let text = NSStackView(views: [headlineLabel, bodyLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 12

        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        for view in [well, text, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let widthHint = widthAnchor.constraint(equalToConstant: width)
        // Yields to the note slot's leading/trailing pins; sizes a card measured alone.
        widthHint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            widthHint,
            well.widthAnchor.constraint(equalToConstant: 96),
            well.heightAnchor.constraint(equalToConstant: 96),
            well.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            well.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 118),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -10),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            closeButton.firstBaselineAnchor.constraint(equalTo: headlineLabel.firstBaselineAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.headline + " " + Self.body)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(restampColors),
                           name: Tokens.accentStyleDidChangeNotification, object: nil)
        // Registered directly: `redrawOnAccessibilityDisplayChange()` is internal to AudioutSharedUI.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(restampColors),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        surgeLink?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func closeTapped() { onClose?() }

    // MARK: Colour

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        stampLayerColors()
    }

    /// Resolved under the view's own appearance, the banner's idiom.
    private func stampLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Tokens.Color.gold.withAlphaComponent(0.12).cgColor
        }
    }

    @objc private func restampColors() {
        needsDisplay = true
        if surgeLink == nil { renderStill() }
    }

    // MARK: Rings

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        for ring in ringLayers { ring.fit(to: CGSize(width: 96, height: 96), scale: scale) }
        if surgeLink == nil { renderStill() }
    }

    /// Centres in the well's layer coordinates (origin bottom-left); layer 1
    /// carries the first two lights, layer 2 the third.
    private func lights(opacity: Float) -> [[SettledLightLayer.Light]] {
        var tint = SIMD3<Float>(repeating: 0)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = AlignmentStageView.shaderTint(Tokens.Color.gold.cgColor)
        }
        func light(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ v: Float) -> SettledLightLayer.Light {
            SettledLightLayer.Light(centre: CGPoint(x: x, y: y), radius: r,
                                    opacity: opacity, variant: v, color: tint)
        }
        return [[light(28, 58, 24, 0), light(66, 64, 20, 1)], [light(60, 30, 22, 0)]]
    }

    private func render(opacity: Float, now: CFTimeInterval?) {
        for (ring, lights) in zip(ringLayers, lights(opacity: opacity)) {
            ring.render(lights: lights, now: now)
        }
    }

    private func renderStill() { render(opacity: Self.restOpacity, now: nil) }

    // MARK: Appear

    /// Fade in on the popover's one reveal clock (0.15 s, chosen over the
    /// concept's 0.25 s), then one surge of the rings unless Reduce Motion.
    func appear() {
        fade.constant = 0
        layer?.opacity = 0
        FoldAnimator.shared.animate(fade, to: 1, follower: self) { [weak self] in
            self?.layer?.opacity = 1
        }
        guard !ringLayers.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            renderStill()
            return
        }
        surgeLink?.invalidate()
        let link = displayLink(target: self, selector: #selector(surgeTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        surgeStart = nil
        for ring in ringLayers { ring.resetClock() }
        link.add(to: .main, forMode: .common)
        surgeLink = link
    }

    func foldAnimatorDidTick() { layer?.opacity = Float(fade.constant) }

    @objc private func surgeTick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let start = surgeStart ?? now
        surgeStart = start
        let t = now - start
        guard t < Self.surgeDuration else {
            link.invalidate()
            surgeLink = nil
            renderStill()
            return
        }
        render(opacity: min(1, Self.restOpacity + 0.3 * Self.surgeEnvelope(Float(t))), now: now)
    }

    /// Copied from `EmitterFieldView.surgeEnvelope`
    /// (`AudioutOnboardingUI/EmitterFieldView.swift:571-577`), which this
    /// target cannot import: fast attack, ~1.4 s decay.
    private static func surgeEnvelope(_ x: Float) -> Float {
        let attack = min(max(x / 0.15, 0), 1)
        return attack * attack * (3 - 2 * attack) * exp(-2.6 * x)
    }

    // MARK: Test-support hooks

    var test_headlineText: String { headlineLabel.stringValue }
    var test_bodyText: String { bodyLabel.stringValue }
    var test_closeButton: NSButton { closeButton }
    var test_backgroundColor: NSColor? {
        guard let cgColor = layer?.backgroundColor else { return nil }
        return NSColor(cgColor: cgColor)
    }
}
