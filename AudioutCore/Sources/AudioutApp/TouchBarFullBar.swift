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
/// WHEN IT SHOWS: while Audiout owns the volume AND the user hasn't turned the
/// feature off in Settings › General. Ownership lasts the whole time our
/// aggregate is the Mac's default output, and for that whole time macOS's own
/// volume controls do nothing — including the "Speakers unreachable. Playing on
/// your Mac" fallback, where the aggregate stays the default output. So the
/// user needs ours on screen whenever we hold the volume, streaming or not.
/// Either fact going false hands the bar straight back.
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
    /// `true` when the bar goes up, `false` when it is handed back. The app
    /// keeps the backend's levels flowing for exactly that span, because
    /// ``noteAudioLevel(_:)`` is the play/pause glyph's only input.
    var onPresentedChange: ((Bool) -> Void)?
    /// Seconds a slow output (a Cast receiver) takes to catch up with the
    /// Mac, or `nil` when nothing is slow, handed to the closure on the main
    /// thread. Asked each time the glyph flips, to pulse for that long.
    var slowOutputDelay: ((@escaping (TimeInterval?) -> Void) -> Void)?

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
    private var isEnabled = true

    // MARK: - Presenting

    /// Follow volume ownership — we can only drive volume when we own it.
    func setOwnsVolume(_ owns: Bool) {
        ownsVolume = owns
        reconcilePresentation()
    }

    /// Follow the user's Settings › General opt-out.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        reconcilePresentation()
    }

    private func reconcilePresentation() {
        (ownsVolume && isEnabled) ? present() : dismiss()
    }

    private func present() {
        guard !presented, TouchBarHardware.isPresent, TouchBarPrivateAPI.isAvailable else { return }
        // Install the dim handler BEFORE the first presentation: macOS dims the
        // bar on idle, sleep and lock, and a bar presented without this goes away
        // on the first dim and is never restored for us.
        TouchBarDimObserver.shared.install { [weak self] dimmed in
            guard let self, self.presented else { return }
            dimmed ? TouchBarPrivateAPI.dismiss(self.bar) : self.reassert()
        }

        presented = true
        onPresentedChange?(true)
        reassert()
    }

    private func dismiss() {
        guard presented else { return }
        presented = false
        onPresentedChange?(false)
        TouchBarPrivateAPI.dismiss(bar)
    }

    /// (Re)present the bar. Also the recovery path after a dim — the presentation
    /// is not restored automatically.
    private func reassert() {
        TouchBarPrivateAPI.presentFullWidth(bar)
        applyAwaitingPlayback()
    }

    // MARK: - Play/pause state

    /// Feed the app's own audio level so the play/pause icon reflects reality:
    /// the pause glyph while sound is flowing, play while it isn't.
    ///
    /// WHY THIS SIGNAL: the honest one — now-playing state — is unreachable.
    /// `MediaRemote`'s symbols still resolve on macOS 27, but
    /// `MRMediaRemoteGetNowPlayingApplicationIsPlaying` never calls back; Apple
    /// gated it. We are already tapping the system audio to route it, so "is
    /// sound actually coming out" is a fact we own outright.
    ///
    /// TRAP: the backend emits levels only while someone asks for them, and the
    /// popover asks only while it is open. A bar that relied on the popover's
    /// request sat on play whenever the popover was closed, which is nearly
    /// always. ``onPresentedChange`` is how the app asks on the bar's behalf
    /// (`MeteringControlling.setDeviceLevelsWanted`), for as long as it is up.
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
        notePlaybackStarted(playing)
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
                guard let self, CACurrentMediaTime() - self.lastAudibleAt >= Self.silenceHold else { return }
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

    /// While a speaker has been told to play but has not yet confirmed that
    /// sound is coming out (a Cast receiver loading, which can take seconds),
    /// the play/pause button pulses its opacity so a press visibly registered.
    /// It goes steady again once every speaker confirms or gives up. It also
    /// pulses after sound starts or stops leaving the Mac while a slow output
    /// is in the room (a Cast receiver is ~5 s behind), until it catches up. With
    /// Reduce Motion on it holds at half opacity instead of pulsing. The glyph
    /// is untouched: play versus pause still follows the audio level above.
    func setAwaitingPlayback(_ waiting: Bool) {
        speakerStillConnecting = waiting
        reconcileAwaitingPlayback()
    }

    /// Sound has started or stopped leaving the Mac. With a slow output in the
    /// room, that output catches up only after its delay: it starts sounding
    /// that much later, and keeps playing its buffer that much longer after a
    /// stop. Pulse until it has caught up. A stop is noticed only after
    /// `silenceHold` of quiet, so that much of the delay has already passed.
    private func notePlaybackStarted(_ playing: Bool) {
        startWaitTimer?.invalidate()
        startWaitTimer = nil
        reconcileAwaitingPlayback()
        flipCount += 1
        let flip = flipCount
        let asked = CACurrentMediaTime()
        slowOutputDelay? { [weak self] slow in
            // A later flip owns the pulse; this answer is stale.
            guard let self, flip == self.flipCount, let slow else { return }
            let delay = (playing ? slow : slow - Self.silenceHold) - (CACurrentMediaTime() - asked)
            guard delay > 0 else { return }
            self.startWaitTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.startWaitTimer = nil
                    self?.reconcileAwaitingPlayback()
                }
            }
            self.reconcileAwaitingPlayback()
        }
    }

    private func reconcileAwaitingPlayback() {
        let waiting = speakerStillConnecting || startWaitTimer != nil
        guard waiting != awaitingPlayback else { return }
        awaitingPlayback = waiting
        applyAwaitingPlayback()
    }

    /// Quiet needed before the glyph reads "stopped".
    private static let silenceHold: TimeInterval = 2.0
    private var speakerStillConnecting = false
    private var startWaitTimer: Timer?
    private var flipCount = 0
    private var awaitingPlayback = false
    private var pulseTimer: Timer?

    /// Also called when the button is rebuilt and when the bar comes back after
    /// a dim, so a fresh button picks the pulse up.
    ///
    /// TRAP: the Touch Bar draws its buttons in a system process, which renders
    /// `alphaValue` but ignores a Core Animation animation added to the button's
    /// layer. The first version pulsed that way and showed nothing on hardware.
    /// So a timer steps `alphaValue` itself.
    private func applyAwaitingPlayback() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        guard let button = playPauseButton else { return }
        guard awaitingPlayback else {
            button.alphaValue = 1
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            button.alphaValue = 0.5
            return
        }
        // One full fade out and back every 1.6 s, as a cosine between 1 and 0.35.
        let start = CACurrentMediaTime()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let button = self?.playPauseButton else { return }
                let phase = (CACurrentMediaTime() - start) / 1.6 * 2 * .pi
                button.alphaValue = 0.675 + 0.325 * cos(phase)
            }
        }
        pulseTimer = timer
    }

    // MARK: - The bar

    /// The one bar we ever present. The private dismiss matches on OBJECT
    /// IDENTITY: it must be handed the same instance that was presented, or the
    /// bar stays on screen and goes on swallowing the volume buttons.
    private lazy var bar: NSTouchBar = makeBar()

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
            applyAwaitingPlayback()
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
    ///   without this the user has to tap once per step, which is what the owner hit.
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
