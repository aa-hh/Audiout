// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import QuartzCore

/// Replaces the whole Touch Bar with our own version of the macOS Control Strip
/// while we own the volume: the same everyday controls, but with volume buttons
/// that actually work.
///
/// WHY A WHOLE BAR AND NOT ONE BUTTON: Apple's Control Strip volume controls grey
/// out when the default output publishes no settable volume — our aggregate — and
/// a greyed control posts NO event (live-probed at both the session and HID
/// event-tap layers). We can neither intercept nor un-grey them. Adding a single
/// working control beside the dead ones was the first attempt and read as broken.
/// Presenting our own full-width bar means every control on it is one we drive.
///
/// WHAT DRIVES WHAT: everything except volume is a synthesized aux key
/// (``SystemAuxKey``) — the same mechanism ``MediaKeyController`` already ships,
/// so brightness, keyboard backlight and transport behave exactly as the real
/// keys do, HUD included. Volume alone bypasses that, because an aux key would
/// target the dead aggregate; it drives Main Out directly.
///
/// WHEN IT SHOWS, and it is three facts, not one: only while Audiout owns the
/// volume AND audio is actually leaving the Mac AND the user hasn't turned the
/// feature off in Settings › General. Ownership alone was too broad — it lasts
/// the entire time our aggregate is the Mac's output, so the user's own Touch
/// Bar was gone for hours at a stretch over a feature they might use for
/// seconds. Any of the three going false hands the bar straight back.
///
/// PROVENANCE: the private-API sequence was learned by reading Pock and MTMR
/// (both MIT). No code was copied — this is a clean-room reimplementation, which
/// also keeps the repo's single vendored-code licensing boundary intact.
@MainActor
final class TouchBarFullBar: NSObject, NSTouchBarDelegate {

    private enum ItemID {
        static let brightnessDown = NSTouchBarItem.Identifier("com.audiout.bar.brightnessDown")
        static let brightnessUp = NSTouchBarItem.Identifier("com.audiout.bar.brightnessUp")
        static let illuminationDown = NSTouchBarItem.Identifier("com.audiout.bar.illumDown")
        static let illuminationUp = NSTouchBarItem.Identifier("com.audiout.bar.illumUp")
        static let previous = NSTouchBarItem.Identifier("com.audiout.bar.previous")
        static let playPause = NSTouchBarItem.Identifier("com.audiout.bar.playPause")
        static let next = NSTouchBarItem.Identifier("com.audiout.bar.next")
        static let mute = NSTouchBarItem.Identifier("com.audiout.bar.mute")
        static let volumeDown = NSTouchBarItem.Identifier("com.audiout.bar.volumeDown")
        static let volumeUp = NSTouchBarItem.Identifier("com.audiout.bar.volumeUp")
    }

    /// Volume step, in the caller's terms. Wired by `AppDelegate` — this type
    /// knows nothing about `GroupController`.
    var onVolumeStep: ((_ up: Bool) -> Void)?
    /// Mute toggle.
    var onToggleMute: (() -> Void)?

    private var presented = false

    /// The play/pause button, held so its icon can follow what's actually
    /// playing rather than sitting on one static glyph.
    private weak var playPauseButton: NSButton?
    private var isPlaying = false
    private var silenceTimer: Timer?
    /// When sound was last heard, so the ONE silence timer can decide whether
    /// enough quiet has passed rather than being rescheduled per level tick.
    private var lastAudibleAt: CFTimeInterval = 0

    private var ownsVolume = false
    private var isStreaming = false
    private var isEnabled = true

    // MARK: - Presenting

    /// Follow volume ownership — we can only drive volume when we own it.
    func setOwnsVolume(_ owns: Bool) {
        ownsVolume = owns
        reconcilePresentation()
    }

    /// Follow whether audio is actually leaving the Mac. Ownership lasts as
    /// long as the aggregate is the default output; this is the narrower fact
    /// that says the bar is worth taking right now.
    func setStreaming(_ streaming: Bool) {
        isStreaming = streaming
        reconcilePresentation()
    }

    /// Follow the user's Settings › General opt-out.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        reconcilePresentation()
    }

    private func reconcilePresentation() {
        (ownsVolume && isStreaming && isEnabled) ? present() : dismiss()
    }

    private func present() {
        guard !presented, TouchBarHardware.isPresent, TouchBarPrivateAPI.isAvailable else { return }
        // Install the dim handler BEFORE the first presentation: macOS dims the
        // bar on idle, sleep and lock, and a bar presented without this goes away
        // on the first dim and is never restored for us.
        TouchBarDimObserver.shared.install { [weak self] dimmed in
            guard let self, self.presented else { return }
            dimmed ? TouchBarPrivateAPI.dismiss(self.makeBar()) : self.reassert()
        }

        presented = true
        reassert()
    }

    private func dismiss() {
        guard presented else { return }
        presented = false
        TouchBarPrivateAPI.dismiss(makeBar())
    }

    /// (Re)present the bar. Also the recovery path after a dim — the presentation
    /// is not restored automatically.
    private func reassert() {
        TouchBarPrivateAPI.presentFullWidth(makeBar())
    }

    // MARK: - Play/pause state

    /// Feed the app's own audio level so the play/pause icon reflects reality:
    /// the pause glyph while sound is flowing, play while it isn't.
    ///
    /// WHY THIS SIGNAL: the honest one — now-playing state — is unreachable.
    /// `MediaRemote`'s symbols still resolve on macOS 27, but
    /// `MRMediaRemoteGetNowPlayingApplicationIsPlaying` never calls back; Apple
    /// gated it. We are already tapping the system audio to route it, so "is
    /// sound actually coming out" is a fact we own outright and costs nothing.
    ///
    /// KNOWN IMPRECISION, and it is inherent to the proxy rather than a bug: it
    /// tracks AUDIBLE OUTPUT, not transport state. A notification chime while
    /// the music is paused reads briefly as playing, and audio from a non-media
    /// app counts too. It is right in the case that matters — press pause, the
    /// icon becomes play — and no better signal exists to us.
    ///
    /// Level ticks arrive ~25 times a second PER DEVICE, so this records a
    /// timestamp and nothing else — scheduling a `Timer` here would mean
    /// run-loop churn at audio rate for a glyph that changes every few
    /// minutes. The silence decision rides ONE repeating 1 s timer that exists
    /// only while we believe something is playing.
    func noteAudioLevel(_ rms: Float) {
        // Above the noise floor of a silent tap, well below normal programme
        // level, so a quiet passage doesn't read as a stop.
        guard rms > 0.002 else { return }
        lastAudibleAt = CACurrentMediaTime()
        setPlaying(true)
    }

    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        playPauseButton?.image = NSImage(
            systemSymbolName: playPauseSymbol, accessibilityDescription: "Play or pause")
        playing ? startSilenceTimer() : stopSilenceTimer()
    }

    /// Hysteresis: brief gaps between tracks, or a quiet beat, must not flap
    /// the icon. Only a sustained silence counts as "stopped".
    private func startSilenceTimer() {
        guard silenceTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, CACurrentMediaTime() - self.lastAudibleAt >= 2.0 else { return }
                self.setPlaying(false)
            }
        }
        // Loose: this is a glyph, not a deadline — let the run loop coalesce it.
        timer.tolerance = 0.2
        silenceTimer = timer
    }

    private func stopSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    private var playPauseSymbol: String { isPlaying ? "pause.fill" : "play.fill" }

    // MARK: - The bar

    private func makeBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        // Mirrors the macOS default Control Strip set, minus two macOS 27 can't
        // give us: Launchpad (the app no longer exists) and Mission Control
        // (its key lives on Apple's vendor HID page and cannot be synthesized —
        // neither Pock nor MTMR manages it either).
        bar.defaultItemIdentifiers = [
            ItemID.brightnessDown, ItemID.brightnessUp,
            .flexibleSpace,
            ItemID.illuminationDown, ItemID.illuminationUp,
            .flexibleSpace,
            ItemID.previous, ItemID.playPause, ItemID.next,
            .flexibleSpace,
            ItemID.mute, ItemID.volumeDown, ItemID.volumeUp,
        ]
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case ItemID.brightnessDown:
            return button(identifier, symbol: "sun.min", label: "Brightness down",
                          repeatsWhenHeld: true) {
                SystemAuxKey.brightnessDown.post()
            }
        case ItemID.brightnessUp:
            return button(identifier, symbol: "sun.max", label: "Brightness up",
                          repeatsWhenHeld: true) {
                SystemAuxKey.brightnessUp.post()
            }
        case ItemID.illuminationDown:
            return button(identifier, symbol: "light.min", label: "Keyboard brightness down",
                          repeatsWhenHeld: true) {
                SystemAuxKey.illuminationDown.post()
            }
        case ItemID.illuminationUp:
            return button(identifier, symbol: "light.max", label: "Keyboard brightness up",
                          repeatsWhenHeld: true) {
                SystemAuxKey.illuminationUp.post()
            }
        case ItemID.previous:
            return button(identifier, symbol: "backward.end", label: "Previous") {
                SystemAuxKey.previous.post()
            }
        case ItemID.playPause:
            let item = button(identifier, symbol: playPauseSymbol, label: "Play or pause") {
                SystemAuxKey.playPause.post()
            }
            playPauseButton = item.view as? NSButton
            return item
        case ItemID.next:
            return button(identifier, symbol: "forward.end", label: "Next") {
                SystemAuxKey.next.post()
            }
        // Volume and mute are OURS — an aux key here would go to the aggregate
        // and do nothing, which is the entire reason this bar exists.
        case ItemID.mute:
            return button(identifier, symbol: "speaker.slash", label: "Mute") { [weak self] in
                self?.onToggleMute?()
            }
        case ItemID.volumeDown:
            return button(identifier, symbol: "speaker.wave.1", label: "Volume down",
                          repeatsWhenHeld: true) { [weak self] in
                self?.onVolumeStep?(false)
            }
        case ItemID.volumeUp:
            return button(identifier, symbol: "speaker.wave.3", label: "Volume up",
                          repeatsWhenHeld: true) { [weak self] in
                self?.onVolumeStep?(true)
            }
        default:
            return nil
        }
    }

    /// - Parameter repeatsWhenHeld: `true` for the stepping controls (volume,
    ///   brightness, backlight) — a real function key repeats while held, and
    ///   without this the user has to tap once per step, which is what Alec hit.
    ///   Left `false` for toggles: a repeating mute would flap on and off.
    private func button(_ identifier: NSTouchBarItem.Identifier,
                        symbol: String, label: String,
                        repeatsWhenHeld: Bool = false,
                        action: @escaping () -> Void) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                ?? NSImage(),
            target: ActionProxy.shared, action: #selector(ActionProxy.fire(_:)))
        if repeatsWhenHeld {
            button.isContinuous = true
            // Roughly the system key-repeat feel: a pause long enough that a
            // single tap is unambiguously one step, then steady repeats.
            button.setPeriodicDelay(0.4, interval: 0.1)
        }
        ActionProxy.shared.register(button, action)
        button.setAccessibilityLabel(label)
        item.view = button
        return item
    }
}

// MARK: - Target/action bridging

/// Buttons need an Objective-C target/action pair; closures aren't one. This
/// keeps the closure alongside the button that owns it.
@MainActor
private final class ActionProxy: NSObject {
    static let shared = ActionProxy()
    private var actions: [ObjectIdentifier: () -> Void] = [:]

    func register(_ button: NSButton, _ action: @escaping () -> Void) {
        actions[ObjectIdentifier(button)] = action
    }

    @objc func fire(_ sender: NSButton) {
        actions[ObjectIdentifier(sender)]?()
    }
}

// MARK: - Private API

/// The private Touch Bar calls, resolved at runtime.
///
/// `NSSelectorFromString` rather than a bridging header: these are undocumented
/// and every one is guarded, so a macOS that drops them degrades to "no custom
/// Touch Bar" instead of crashing.
@MainActor
enum TouchBarPrivateAPI {

    private static let presentSelector = NSSelectorFromString(
        "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    private static let dismissSelector = NSSelectorFromString("dismissSystemModalTouchBar:")

    static var isAvailable: Bool {
        NSTouchBar.responds(to: presentSelector) && NSTouchBar.responds(to: dismissSelector)
    }

    /// Present `bar` across the FULL width, hiding the system Control Strip.
    ///
    /// Placement `1` is full-width; `0` would keep the Control Strip on the right.
    /// Full-width is the point here — the Control Strip's volume controls are the
    /// dead ones we are replacing, so leaving them on screen beside working
    /// buttons is exactly the confusion this design removes.
    static func presentFullWidth(_ bar: NSTouchBar) {
        guard isAvailable else { return }
        typealias PresentFn = @convention(c)
            (AnyObject, Selector, NSTouchBar, Int64, NSString?) -> Void
        let imp = NSTouchBar.method(for: presentSelector)
        unsafeBitCast(imp, to: PresentFn.self)(NSTouchBar.self, presentSelector, bar, 1, nil)
    }

    static func dismiss(_ bar: NSTouchBar) {
        guard isAvailable else { return }
        typealias DismissFn = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
        let imp = NSTouchBar.method(for: dismissSelector)
        unsafeBitCast(imp, to: DismissFn.self)(NSTouchBar.self, dismissSelector, bar)
    }
}

/// Tells us when macOS dims the Touch Bar, so a presented bar can be taken down
/// and put back.
///
/// WHY THIS IS NOT OPTIONAL: macOS calls `+[NSFunctionRow
/// markActiveFunctionRowsAsDimmed:]` on idle, sleep, screen lock, and when
/// another app claims the bar. Nothing restores a system-modal presentation
/// afterwards — without this the bar disappears on the first dim and never
/// returns, which is the same class of failure as the Control Strip restart
/// eating a tray registration.
@MainActor
final class TouchBarDimObserver {

    static let shared = TouchBarDimObserver()

    private var onDimChange: ((Bool) -> Void)?
    private var installed = false

    /// Idempotent — installing the swizzle twice would exchange the
    /// implementations back and silently disable it.
    func install(_ handler: @escaping (Bool) -> Void) {
        onDimChange = handler
        guard !installed else { return }
        installed = true

        // Screen lock/unlock is a separate signal from the dim callback and
        // arrives even when the callback doesn't.
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onDimChange?(true) } }
        center.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onDimChange?(false) } }

        installDimSwizzle()
    }

    fileprivate func handleDim(_ dimmed: Bool) { onDimChange?(dimmed) }

    /// Swap `+[NSFunctionRow markActiveFunctionRowsAsDimmed:]` for our own.
    ///
    /// A CLASS method, so `class_getClassMethod` — reaching for the instance
    /// method finds nothing and the swizzle silently no-ops. We deliberately do
    /// NOT call the original: it re-enters this same swizzle.
    private func installDimSwizzle() {
        guard let functionRow = NSClassFromString("NSFunctionRow") else { return }
        let selector = NSSelectorFromString("markActiveFunctionRowsAsDimmed:")
        guard let original = class_getClassMethod(functionRow, selector),
              let replacement = class_getClassMethod(
                TouchBarDimObserver.self, #selector(TouchBarDimObserver.swizzledMarkDimmed(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    @objc private class func swizzledMarkDimmed(_ dimmed: Bool) {
        MainActor.assumeIsolated { TouchBarDimObserver.shared.handleDim(dimmed) }
    }
}
