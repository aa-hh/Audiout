// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

/// The volume readout shown when Audiout consumes a hardware volume/mute key.
///
/// WHY IT EXISTS: while the Mac's default output cannot take a volume write
/// (our aggregate, or plain HDMI), `VolumeKeyInterceptor` swallows the key so
/// macOS never draws its own crossed-out HUD — which also means the press
/// produces no visible feedback at all. This replaces the system HUD for
/// exactly that state: same job, driven by the value we actually moved.
///
/// A transient, non-interactive panel — it never takes focus, never takes a
/// click, and holds for 1.5 s after the last press before fading out. Repeat
/// presses update it in place and re-arm the hold, so walking the volume up
/// reads as one continuous readout rather than a stutter of panels.
///
/// The pure content decision lives in ``Content`` — the same
/// decision/rendering split as `MenuBarStatus`/`StatusItemIcon`, so what the
/// HUD says is unit-testable without a window server.
@MainActor
public final class VolumeHUDPanel: NSPanel {

    /// What the HUD shows for a given volume/mute pair. Pure and
    /// AppKit-free-in-spirit (plain values only) so it can be asserted
    /// directly.
    public struct Content: Equatable {
        public let symbolName: String
        /// The SF Symbol's `variableValue` (0…1) — the filled-wave level.
        public let variableValue: Double
        public let text: String
        /// The VoiceOver announcement — worded in full sentences, unlike
        /// `text`, since it is spoken rather than read off a HUD.
        public let spokenDescription: String
    }

    /// Muted reads as muted, full stop: the level is beside the point when
    /// nothing is coming out. Otherwise the percentage, with the waves filled
    /// to match.
    public static func content(volumePercent: Int, isMuted: Bool) -> Content {
        if isMuted {
            // SharedUI rule S3 ("glyph NEVER swaps to a slash",
            // `AudioutSharedUI/AGENTS.md`) governs a row's mute BUTTON, which
            // is a control; this HUD is a transient readout carrying no
            // number, and the slash is what macOS's own volume HUD shows.
            return Content(symbolName: "speaker.slash.fill", variableValue: 0, text: "Muted",
                           spokenDescription: "Volume muted")
        }
        return Content(symbolName: "speaker.wave.3.fill",
                       variableValue: Double(volumePercent) / 100,
                       text: "\(volumePercent)%",
                       spokenDescription: "Volume \(volumePercent)%")
    }

    /// The bar's fill, in segments (`0...VolumeStep.coarseDetents`). Muted
    /// reads as empty. Otherwise the percent is scaled to the segment count
    /// and quantised to the nearest QUARTER segment rather than filled
    /// proportionally: `VolumeStep.next` snaps to a detent grid in INTEGER
    /// space (`round(i × 6.25)`), which is not an exact multiple of
    /// `100 / coarseDetents` — a raw proportional fill would visibly miss a
    /// whole segment on the first press. Quarter-quantising lands every
    /// coarse detent on a whole segment and every `⇧⌥` fine detent on an
    /// exact quarter.
    public static func filledSegments(volumePercent: Int, isMuted: Bool) -> Double {
        guard !isMuted else { return 0 }
        let clamped = Double(min(max(volumePercent, 0), 100))
        let raw = clamped / 100 * VolumeStep.coarseDetents
        let quarterQuantised = (raw * 4).rounded() / 4
        return min(max(quarterQuantised, 0), VolumeStep.coarseDetents)
    }

    private static let panelSize = NSSize(width: 200, height: 44)
    /// How long the HUD holds after the last press, and how long it takes to
    /// fade out afterwards — matched to the system HUD's own feel.
    private static let holdDuration: TimeInterval = 1.5
    private static let fadeDuration: TimeInterval = 0.25
    /// Inset from the screen's visible corner.
    private static let screenInset: CGFloat = 16
    /// Segment-bar geometry: the bar's height, the gap between segments, and
    /// each segment's corner radius.
    fileprivate static let barHeight: CGFloat = 6
    fileprivate static let segmentGap: CGFloat = 2
    fileprivate static let segmentCornerRadius: CGFloat = 1

    private let imageView = NSImageView()
    private let segmentBar = VolumeSegmentBarView()
    private var dismissTimer: Timer?
    private var appliedSymbolName: String?
    /// The text the last `show(...)` applied. The label view is gone (step 12
    /// replaced it with the segment bar), so `test_text` has nothing left to
    /// read back from — this stores it directly instead.
    private var appliedText = ""
    private var shown = false

    /// `nil` = read the live `accessibilityDisplayShouldReduceMotion`. Tests
    /// drive both sides of the fade with this (SharedUI's Reduce Motion seam
    /// rule).
    public var test_reduceMotionOverride: Bool?

    /// The text the last `show(...)` applied.
    public var test_text: String { appliedText }

    /// The symbol name last applied, or `nil` when the image view holds no
    /// image (`NSImage` only reports its own `symbolName` above our
    /// deployment floor, so the applied name is remembered alongside it).
    public var test_symbolName: String? { imageView.image == nil ? nil : appliedSymbolName }

    /// The segment count the bar is currently showing.
    public var test_filledSegments: Double { segmentBar.filledSegments }

    /// Whether the HUD is currently up. Model state, not `isVisible`, so it
    /// stays true under `HeadlessRuntime` — where no window is ever ordered on
    /// screen.
    public var test_isShown: Bool { shown }

    /// The announcement string the last `show(...)` COMPUTED — not proof that
    /// anything reached VoiceOver. It is set beside the `NSAccessibility.post`
    /// rather than by it, so deleting that call leaves this, and the test that
    /// reads it, green while the HUD goes silent. Observing the post itself
    /// would mean a seam existing only for the test, which a one-line platform
    /// call does not earn.
    public private(set) var test_lastAnnouncement: String?

    /// Test-only: runs the private dismiss path directly, without waiting on
    /// the real hold timer — simulates a fade-out already in flight.
    public func test_simulateDismiss() { dismiss() }

    public init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        ignoresMouseEvents = true
        // A menu-bar app restores no windows (AudioutApp's AGENTS.md rule),
        // and a transient HUD least of all.
        isRestorable = false
        hidesOnDeactivate = false
        // The one owner is the app delegate's own property; AppKit must not
        // release this out from under it on close.
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        // Opaque stand-in while Reduce Transparency is on. Installed BEFORE
        // the content subviews — the cover composites above the blur and
        // below the content (its documented contract).
        ReduceTransparencyFallbackView.install(in: effectView)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        segmentBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [imageView, segmentBar])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            segmentBar.heightAnchor.constraint(equalToConstant: Self.barHeight),
        ])

        contentView = effectView
    }

    /// Show (or update) the HUD for the given Main Out level, positioned at
    /// the top-right of `screen` — the macOS 26+ system HUD region, and the
    /// corner the user is already glancing at for the menu-bar glyph.
    ///
    /// Appears instantly with no animation, exactly as the system HUD does; a
    /// call while it is already up updates the content in place and re-arms
    /// the hold.
    public func show(volumePercent: Int, isMuted: Bool, on screen: NSScreen?) {
        let content = Self.content(volumePercent: volumePercent, isMuted: isMuted)
        let image = NSImage(systemSymbolName: content.symbolName,
                            variableValue: content.variableValue,
                            accessibilityDescription: content.text)
        image?.isTemplate = true
        imageView.image = image
        appliedSymbolName = content.symbolName
        appliedText = content.text
        segmentBar.filledSegments = Self.filledSegments(volumePercent: volumePercent, isMuted: isMuted)

        if let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame {
            setFrameOrigin(NSPoint(
                x: visibleFrame.maxX - Self.panelSize.width - Self.screenInset,
                y: visibleFrame.maxY - Self.panelSize.height - Self.screenInset))
        }

        dismissTimer?.invalidate()
        alphaValue = 1
        shown = true
        // NEVER put a real window on screen under `swift test` or a headless
        // harness — the same gate `ControlPanelWindowController.show` uses.
        // Everything else still runs, so headless assertions stay as strong.
        if !HeadlessRuntime.isActive {
            orderFront(nil)
        }
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: Self.holdDuration, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }

        // VoiceOver announcement (same idiom as `PopoverController
        // .postAnnouncement`). Not gated on `HeadlessRuntime.isActive` — this
        // is not on-screen presentation, it reaches no assistive technology
        // under test, and neither existing announcement site gates it either.
        test_lastAnnouncement = content.spokenDescription
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: content.spokenDescription,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        shown = false
        guard !reduceMotion else {
            finishDismiss()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            // A newer `show()` may have already re-shown the panel by the
            // time this runs — never start (or land) a fade meant for a dismiss
            // that no longer applies.
            guard !self.shown else { return }
            context.duration = Self.fadeDuration
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishDismiss() }
        }
    }

    /// The actual "go away" — shared by the Reduce Motion path (synchronous)
    /// and the fade's completion (async, up to `fadeDuration` later). Guarded
    /// on `shown`: a keypress mid-fade calls `show()`, which sets `shown =
    /// true` again, and this stale fade's completion must then be a no-op —
    /// otherwise it orders the just-reshown panel back out from under it.
    private func finishDismiss() {
        guard !shown else { return }
        orderOut(nil)
        alphaValue = 1
    }
}

/// The sixteen-segment level bar that replaces the HUD's old percentage
/// label. Custom-drawn: the stock discrete-segment control,
/// `NSLevelIndicator` with `.discreteCapacity` — this repo's prescribed
/// control for level meters (`OutputBackend.swift`, `docs/SPEC.md` §9) —
/// floors a fractional `doubleValue` to the nearest whole segment instead of
/// rendering it (verified by rendering one offscreen: an 8.25-of-16 value
/// painted 8 solid segments and an empty 9th, no partial fill anywhere), and
/// a visible quarter-fill on a `⇧⌥` fine step is this bar's whole point.
private final class VolumeSegmentBarView: NSView {

    /// One press should move exactly one segment, one `⇧⌥` fine step exactly
    /// a quarter of one — so setting this always comes from
    /// `VolumeHUDPanel.filledSegments(volumePercent:isMuted:)`, never a raw
    /// percentage.
    var filledSegments: Double = 0 {
        didSet { needsDisplay = true }
    }

    /// Non-interactive: a HUD readout takes no click, and the real control is
    /// wherever the volume actually got moved (a key, the Touch Bar, a row
    /// slider).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Colours are resolved fresh on every pass here, never cached at
    /// construction — unlike this file's label-era pattern (`label.textColor
    /// = .labelColor`, safe only for a system dynamic color), caching a
    /// `Tokens` value would freeze it. That makes `needsDisplay = true` on
    /// every `filledSegments` push the ONLY invalidation this view needs: no
    /// `accessibilityDisplayOptionsDidChangeNotification` or
    /// `Tokens.accentStyleDidChangeNotification` observer is added, because
    /// `VolumeHUDPanel` is a reused singleton for the app's whole life
    /// (`AppDelegate`) whose `show(...)` pushes a fresh value on every
    /// appearance, and the HUD's entire visible life is under 1.75 s from
    /// that push — a stale render between pushes is unreachable.
    override func draw(_ dirtyRect: NSRect) {
        let count = Int(VolumeStep.coarseDetents)
        guard count > 0 else { return }
        let totalGap = VolumeHUDPanel.segmentGap * CGFloat(count - 1)
        let segmentWidth = (bounds.width - totalGap) / CGFloat(count)
        guard segmentWidth > 0 else { return }

        let filledColor = Tokens.Color.label
        let emptyColor = Tokens.Color.label3

        for i in 0..<count {
            let x = CGFloat(i) * (segmentWidth + VolumeHUDPanel.segmentGap)
            let segmentRect = NSRect(x: x, y: 0, width: segmentWidth, height: bounds.height)
            let segmentPath = NSBezierPath(roundedRect: segmentRect,
                                           xRadius: VolumeHUDPanel.segmentCornerRadius,
                                           yRadius: VolumeHUDPanel.segmentCornerRadius)
            emptyColor.setFill()
            segmentPath.fill()

            let fillFraction = min(max(filledSegments - Double(i), 0), 1)
            guard fillFraction > 0 else { continue }
            NSGraphicsContext.current?.saveGraphicsState()
            segmentPath.addClip()
            filledColor.setFill()
            NSRect(x: x, y: 0, width: segmentWidth * fillFraction, height: bounds.height).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }
}
