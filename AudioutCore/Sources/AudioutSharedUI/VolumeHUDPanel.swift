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
    }

    /// Muted reads as muted, full stop: the level is beside the point when
    /// nothing is coming out. Otherwise the percentage, with the waves filled
    /// to match.
    public static func content(volumePercent: Int, isMuted: Bool) -> Content {
        if isMuted {
            return Content(symbolName: "speaker.slash.fill", variableValue: 0, text: "Muted")
        }
        return Content(symbolName: "speaker.wave.3.fill",
                       variableValue: Double(volumePercent) / 100,
                       text: "\(volumePercent)%")
    }

    private static let panelSize = NSSize(width: 200, height: 44)
    /// How long the HUD holds after the last press, and how long it takes to
    /// fade out afterwards — matched to the system HUD's own feel.
    private static let holdDuration: TimeInterval = 1.5
    private static let fadeDuration: TimeInterval = 0.25
    /// Inset from the screen's visible corner.
    private static let screenInset: CGFloat = 16

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var dismissTimer: Timer?
    private var appliedSymbolName: String?
    private var shown = false

    /// `nil` = read the live `accessibilityDisplayShouldReduceMotion`. Tests
    /// drive both sides of the fade with this (SharedUI's Reduce Motion seam
    /// rule).
    public var test_reduceMotionOverride: Bool?

    /// The text the label is actually carrying.
    public var test_text: String { label.stringValue }

    /// The symbol name last applied, or `nil` when the image view holds no
    /// image (`NSImage` only reports its own `symbolName` above our
    /// deployment floor, so the applied name is remembered alongside it).
    public var test_symbolName: String? { imageView.image == nil ? nil : appliedSymbolName }

    /// Whether the HUD is currently up. Model state, not `isVisible`, so it
    /// stays true under `HeadlessRuntime` — where no window is ever ordered on
    /// screen.
    public var test_isShown: Bool { shown }

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
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: effectView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
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
        label.stringValue = content.text

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
