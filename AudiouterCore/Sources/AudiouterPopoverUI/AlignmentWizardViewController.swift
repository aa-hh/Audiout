// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The sheet content hosting the Bayesian alignment wizard. Presented with
/// `presentAsSheet` on the popover/pinned surface — the same idiom as the
/// Groups create sheet — so the host can't close under a live run (AppKit
/// refuses `performClose` while a sheet is attached) and an app-switch
/// tuck-away hides and restores host and wizard together. Content sits on a
/// `WarmCanvasView` ground. A sheet has no ✕: Stop, Done and Esc are the
/// exits, all view-driven.
@MainActor
public final class AlignmentWizardViewController: NSViewController {

    /// Fixed content width — the wizard's screens differ only in height.
    private static let contentWidth: CGFloat = 560
    private static let horizontalInset: CGFloat = 28
    private static let verticalInset: CGFloat = 20

    /// Room-spill radius — a quarter of the content width, the approved
    /// mock's two washes (r 90 + a 26 blur). At 60% they covered the whole
    /// ground and lifted it above the plates' own `raised` fill, so a raised
    /// plate read as recessed.
    private static let spillRadius: CGFloat = contentWidth * 0.25

    private let canvas: WarmCanvasView
    private let wizardView: BTAlignmentWizardView
    /// Two soft radial washes on the sheet ground behind the plate — green
    /// (sync/target) behind the left third, magenta (party/reference) behind
    /// the right third (spec §2.2). A sibling `NSView`, not a sublayer of
    /// `canvas`'s own backing layer — see `RoomSpillView`'s doc comment.
    private let roomSpill = RoomSpillView(frame: .zero)

    /// Hosted = this controller's view is in a real window (the attached
    /// sheet). Headless runs never present, so their teardown skips
    /// `dismiss` and the target-lost bow-out — the override lets tests walk
    /// the hosted paths without a window.
    var test_isHostedOverride: Bool?
    var isHosted: Bool { test_isHostedOverride ?? (viewIfLoaded?.window != nil) }

    public init(wizardView: BTAlignmentWizardView) {
        self.canvas = WarmCanvasView(frame: NSRect(
            x: 0, y: 0, width: Self.contentWidth, height: 0))
        self.wizardView = wizardView
        super.init(nibName: nil, bundle: nil)

        // Drives the spill's per-rung intensity + the lock flash (spec
        // §2.2). The wizard view has ALREADY applied the intro's `.armed`
        // state inside its own init by the time this runs, so the seed comes
        // from `onRungChange`'s own assignment (it reports the live rung to a
        // newly-assigned handler); after that it fires on every rung change.
        wizardView.stage.onRungChange = { [weak self] rung in
            self?.roomSpill.apply(rung: rung)
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        // The spill sits BELOW the wizard content — added to `canvas` first,
        // so it composites behind everything added after it — and spans the
        // full sheet ground, not just the wizard's inset content area (the
        // spill is the room, not the stage — spec §2.2).
        roomSpill.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(roomSpill)

        wizardView.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(wizardView)
        NSLayoutConstraint.activate([
            canvas.widthAnchor.constraint(equalToConstant: Self.contentWidth),

            roomSpill.topAnchor.constraint(equalTo: canvas.topAnchor),
            roomSpill.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            roomSpill.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            roomSpill.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),

            wizardView.topAnchor.constraint(
                equalTo: canvas.topAnchor, constant: Self.verticalInset),
            wizardView.bottomAnchor.constraint(
                equalTo: canvas.bottomAnchor, constant: -Self.verticalInset),
            wizardView.leadingAnchor.constraint(
                equalTo: canvas.leadingAnchor, constant: Self.horizontalInset),
            wizardView.trailingAnchor.constraint(
                equalTo: canvas.trailingAnchor, constant: -Self.horizontalInset),
        ])
        view = canvas
    }

    /// Re-measure the hosted wizard view and republish the fit as
    /// `preferredContentSize` — the wizard's screens differ in height, and
    /// AppKit animates an attached sheet to the presented controller's
    /// preferred size on its own. Unhosted (headless tests, the snapshot
    /// renderer) nothing resizes the view for free, so it is framed directly.
    public func fitToContent() {
        canvas.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.contentWidth, height: canvas.fittingSize.height)
        preferredContentSize = size
        if viewIfLoaded?.window == nil {
            canvas.setFrameSize(size)
            canvas.layoutSubtreeIfNeeded()
            reframeSpillLayers()
        }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        reframeSpillLayers()
    }

    /// Places the two spill layers: green behind the left third of the
    /// STAGE, magenta behind the right third (spec §2.2 — "behind the
    /// plate"), at `spillRadius`, centred on the stage's own midline.
    private func reframeSpillLayers() {
        let radius = Self.spillRadius
        let side = radius * 2
        let stage = wizardView.convert(wizardView.stage.frame, to: roomSpill)
        let centerY = stage.midY
        let leftCenterX = stage.minX + stage.width / 3
        let rightCenterX = stage.minX + stage.width * 2 / 3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        roomSpill.leftSpill.frame = CGRect(
            x: leftCenterX - radius, y: centerY - radius, width: side, height: side)
        roomSpill.rightSpill.frame = CGRect(
            x: rightCenterX - radius, y: centerY - radius, width: side, height: side)
        CATransaction.commit()
    }

    /// The host's teardown path. Dismissing only when actually PRESENTED is
    /// what lets headless runs construct and drive the controller without a
    /// window — the `GroupCreationSheetController.finish` idiom. The test is
    /// `presentingViewController`, not "am I in a window": a keyboard test
    /// mounts this content in a plain window to drive real first-responder
    /// dispatch, and `dismiss` on an unpresented controller raises
    /// `NSInternalInconsistencyException` ("maybe this view controller was not
    /// presented?"). A real sheet always has a presenting controller.
    func dismissSilently() {
        if presentingViewController != nil { dismiss(self) }
    }
}

/// Non-interactive host for the two "room spill" radial gradient washes
/// (wizard-stage-v2 spec §2.2) — a plain sibling `NSView`, not a sublayer of
/// `WarmCanvasView`'s own backing layer. `WarmCanvasView.draw(_:)` re-paints
/// its FULL bounds into `layer.contents` on every appearance/accessibility
/// flip (that view's own doc comment), and nothing in this file can prove a
/// sublayer inserted at index 0 there survives that repaint without editing
/// that shared, out-of-scope view — so this hosts the spill in a dedicated
/// view instead, added to `canvas` BEFORE `wizardView`: it composites above
/// the canvas's own drawn gradient (a separate layer in the tree) and below
/// the wizard content (added after it, later in z-order).
private final class RoomSpillView: NSView {
    let leftSpill = CAGradientLayer()
    let rightSpill = CAGradientLayer()

    /// The rung last applied — re-stamped on a live appearance/accessibility
    /// change (SharedUI AGENTS.md: a stamped `CGColor` goes stale and
    /// nothing re-paints it for free). Starts `.dormant` so a display before
    /// the first `apply(rung:)` has something well-defined to stamp (opacity
    /// 0 either way).
    private var lastRung: AlignmentStageView.Rung = .dormant

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for spill in [leftSpill, rightSpill] {
            spill.type = .radial
            spill.startPoint = CGPoint(x: 0.5, y: 0.5)
            spill.endPoint = CGPoint(x: 1, y: 1)
            spill.opacity = 0
            layer?.addSublayer(spill)
        }
        // Increase Contrast / Reduce Transparency don't change the effective
        // appearance, so `updateLayer()` (below) never fires for them on its
        // own — same pattern as `WarmCanvasView`/`LevelMeterView`.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override var isFlipped: Bool { false }

    /// The stamped `CGColor`s carry the appearance they were resolved under;
    /// a flip has to re-stamp them (the light render was wearing the dark
    /// electric values).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // Decorative only — never intercepts a click meant for the wizard
    // content composited above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func accessibilityDisplayOptionsDidChange() { needsDisplay = true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        stampSettled(animated: false)
    }

    // MARK: Rung-driven state

    /// Applies a new rung — the `stage.onRungChange` handler. `.locked`
    /// plays the flash-then-settle sequence; every other rung re-stamps the
    /// symmetric settled wash directly.
    func apply(rung: AlignmentStageView.Rung) {
        lastRung = rung
        if rung == .locked {
            performLockFlash()
        } else {
            stampSettled(animated: true)
        }
    }

    /// Halo-opacity row of the wizard-stage-v2 spec's §5 look table. The
    /// `peak × (value ÷ 0.58)` normalization is this file's own derivation:
    /// the spill tracks the halos, scaled so the brightest rung hits `peak`.
    private static let midHaloOpacity: CGFloat = 0.58

    private static func haloOpacity(for rung: AlignmentStageView.Rung) -> CGFloat {
        switch rung {
        case .armed: return 0.20
        case .open: return 0.40
        case .closing: return 0.46
        case .near: return 0.52
        case .threshold: return 0.58
        case .fused: return 0.55
        case .locked: return 0.42
        case .dormant: return 0
        }
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Peak spill alpha: 0.10 dark (spec §2.2). OFF in light: measured at
    /// both 0.07 and 0.12 the wash was <1% neutral darkening with no chroma —
    /// invisible as a tint, visible only as banding on the Circuit ground.
    private var peakOpacity: CGFloat { isDarkAppearance ? 0.10 : 0 }

    private var leftTint: NSColor {
        isDarkAppearance ? Tokens.Color.syncSignal : Tokens.Color.syncSignalDeep
    }

    private var rightTint: NSColor {
        isDarkAppearance ? Tokens.Color.partySignal : Tokens.Color.partySignalDeep
    }

    private func gradientColors(_ tint: NSColor) -> [CGColor] {
        [tint.cgColor, tint.withAlphaComponent(0).cgColor]
    }

    /// `(left, right)` opacity for a settled rung. `.locked`'s settled state
    /// is the one asymmetric case (spec §2.2: "settles to a faint
    /// green-only wash" — left low, right 0); every other rung is symmetric.
    private func settledOpacities(for rung: AlignmentStageView.Rung) -> (left: Float, right: Float) {
        let opacity = Self.haloOpacity(for: rung) / Self.midHaloOpacity * peakOpacity
        return (Float(opacity), rung == .locked ? 0 : Float(opacity))
    }

    /// The animation gate: instant under Reduce Motion or a headless run —
    /// neither reliably spins a run loop to finish an eased opacity change
    /// (mirrors `HaloRingView.reduceMotion`).
    private var animatesSpill: Bool {
        !(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || HeadlessRuntime.isActive)
    }

    private func stampSettled(animated: Bool) {
        leftSpill.colors = gradientColors(leftTint)
        rightSpill.colors = gradientColors(rightTint)
        let (left, right) = settledOpacities(for: lastRung)
        CATransaction.begin()
        if animated && animatesSpill {
            CATransaction.setAnimationDuration(0.6)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        leftSpill.opacity = left
        rightSpill.opacity = right
        CATransaction.commit()
    }

    // MARK: The lock flash

    /// Flash both spills to `fuseWhite` at ~0.10, hold, then settle to the
    /// faint green-only wash (spec §2.2). Skipped straight to the settled
    /// end state under Reduce Motion / headless.
    private func performLockFlash() {
        guard animatesSpill else {
            stampSettled(animated: false)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let flash = gradientColors(Tokens.Color.fuseWhite)
        leftSpill.colors = flash
        rightSpill.colors = flash
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        leftSpill.opacity = 0.10
        rightSpill.opacity = 0.10
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.settleAfterLockFlash()
        }
    }

    /// A later rung change within the 0.7 s hold supersedes the flash — this
    /// only lands the settle if `.locked` is still the live rung.
    private func settleAfterLockFlash() {
        guard lastRung == .locked else { return }
        // `CATransition` reserves the literal key "transition" regardless of
        // what's passed here (SharedUI AGENTS.md TRAP) — added BEFORE the
        // property writes it's meant to cross-dissolve.
        let transition = CATransition()
        transition.duration = 0.3
        leftSpill.add(transition, forKey: "transition")
        rightSpill.add(transition, forKey: "transition")
        leftSpill.colors = gradientColors(leftTint)
        rightSpill.colors = gradientColors(rightTint)
        let (left, right) = settledOpacities(for: .locked)
        leftSpill.opacity = left
        rightSpill.opacity = right
    }
}
