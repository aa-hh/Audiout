// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The volume control every Mixer row carries: a stock `NSSlider` wearing
/// ``WarmFaderCell``, with the `%` readout hanging ``PopoverColumnGrid/sliderToReadout``
/// off its trailing edge. Main Audio, the speaker rows and the app rows all
/// mount this one view, so the three cannot disagree on the drag guard or on
/// the readout's ink.
///
/// The view spans slider + readout; its leading edge IS the slider's. Rows
/// pin its trailing edge ``PopoverColumnGrid/readoutTrailing`` in from their
/// own, which lands the trough on ``PopoverColumnGrid/sliderTrailing``.
///
/// With a nonzero ``haloRoom`` (the speaker rows, whose Cast volume can be
/// pending) the slider's frame is 24 pt tall and ``haloRoom`` wider at each
/// end than its trough, so the pending glow's 3 pt halo is never cut off. The
/// trough and readout land where they would at zero; the view's leading edge
/// sits ``haloRoom`` before the trough, which the host's neighbours give back.
///
/// The slider's behaviour stays stock (tracking, keyboard, scroll-wheel,
/// VoiceOver); hosts label it through ``slider``.
public final class RowVolumeFader: NSView {

    public let slider = NSSlider()
    /// The Warm fader skin installed on ``slider``.
    public let faderCell = WarmFaderCell()
    public let readoutLabel = NSTextField(labelWithString: "")
    /// Clear space between the slider's frame and each end of its trough.
    public let haloRoom: CGFloat

    /// Called with the new level on every slider change, drag included.
    public var onChange: ((Int) -> Void)?

    /// True while a mouse drag is in flight. Model pushes through ``value``
    /// are ignored meanwhile, so the thumb and the number beside it stay under
    /// the pointer.
    private var isDragging = false
    private var dragEndMonitor: Any?
    /// Whether the `%` readout breathes with the thumb: pending AND the
    /// readout would otherwise read `goldText` (the engaged state).
    private var readoutBreathes = false

    /// The level shown. Setting it is a MODEL push: ignored during a mouse
    /// drag (the readout already follows the drag from the slider's own value).
    public var value: Int {
        get { slider.integerValue }
        set {
            guard !isDragging else { return }
            slider.integerValue = newValue
            readoutLabel.stringValue = VolumePercent.label(newValue)
        }
    }

    /// Gold fill and `goldText` readout while the row is actually sounding.
    public var isRouteArmed: Bool {
        get { faderCell.isRouteArmed }
        set { faderCell.isRouteArmed = newValue; updateReadoutInk() }
    }

    /// The "not adjustable right now" treatment (connecting, failed or
    /// unavailable): dims the fader and the readout without disabling the slider.
    public var isMutedControl: Bool {
        get { faderCell.isMutedControl }
        set { faderCell.isMutedControl = newValue; updateReadoutInk() }
    }

    /// A Cast volume change still landing on the receiver.
    public var isPendingApply: Bool {
        get { faderCell.isPendingApply }
        set {
            guard faderCell.isPendingApply != newValue else { return }
            faderCell.isPendingApply = newValue
            // Invalidate explicitly rather than trust the cell's controlView.
            slider.needsDisplay = true
            updateReadoutInk()
        }
    }

    /// Drop a pending hold at once, with no arrival, for a surface that is
    /// hiding: the glow and its timer stop and the readout takes back its
    /// resting ink.
    public func cancelPendingHold() {
        readoutBreathes = false
        faderCell.cancelPendingHold()
        updateReadoutInk()
    }

    /// Whether the slider accepts input. Main Audio keeps it on while muted.
    public var isAdjustable: Bool {
        get { slider.isEnabled }
        set { slider.isEnabled = newValue; updateReadoutInk() }
    }

    public init(haloRoom: CGFloat = 0) {
        self.haloRoom = haloRoom
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        slider.translatesAutoresizingMaskIntoConstraints = false
        // Install the drawing-only cell BEFORE the value/target setup: a cell
        // swap resets cell-held state.
        slider.cell = faderCell
        faderCell.haloRoom = haloRoom
        faderCell.onPulse = { [weak self] strength in self?.updatePendingReadoutInk(strength) }
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true   // fire throughout the drag
        slider.target = self
        slider.action = #selector(sliderChanged(_:))

        readoutLabel.translatesAutoresizingMaskIntoConstraints = false
        readoutLabel.font = Tokens.Font.readout
        readoutLabel.textColor = Tokens.Color.emberText
        readoutLabel.alignment = .right
        readoutLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(slider)
        addSubview(readoutLabel)
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        if haloRoom > 0 {
            // Stock height is 16 pt, which clipped the 17 pt thumb by half a
            // point; 24 pt holds thumb plus ring, centred, so the track stays put.
            slider.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.widthAnchor.constraint(
                equalToConstant: PopoverColumnGrid.sliderWidth + 2 * haloRoom),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            slider.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            readoutLabel.leadingAnchor.constraint(
                equalTo: slider.trailingAnchor,
                constant: PopoverColumnGrid.sliderToReadout - haloRoom),
            readoutLabel.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.readoutWidth),
            readoutLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            readoutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            readoutLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            readoutLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            hug,
        ])
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Three readout inks: `labelCool2` when the row can't be adjusted,
    /// `goldText` while sounding, `emberText` for a stored-but-idle level.
    /// A pending `goldText` readout breathes instead.
    private func updateReadoutInk() {
        if !slider.isEnabled || faderCell.isMutedControl {
            readoutLabel.textColor = Tokens.Color.labelCool2
        } else if faderCell.isRouteArmed {
            readoutLabel.textColor = Tokens.Color.goldText
        } else {
            readoutLabel.textColor = Tokens.Color.emberText
        }
        readoutBreathes = faderCell.isPendingApply && slider.isEnabled
            && !faderCell.isMutedControl && faderCell.isRouteArmed
        updatePendingReadoutInk(faderCell.pulseStrength)
    }

    /// The readout's breath while a Cast volume is pending: dim to live ink
    /// in step with the thumb, held dim under Reduce Motion. Outside the
    /// hold it leaves the resting ink alone.
    private func updatePendingReadoutInk(_ strength: CGFloat?) {
        guard readoutBreathes else { return }
        readoutLabel.textColor = PendingPulse.ink(
            strength: faderCell.reduceMotion ? nil : strength, in: effectiveAppearance)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePendingReadoutInk(faderCell.pulseStrength)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        // Only a genuine mouse drag suppresses model pushes; keyboard, scroll
        // and VoiceOver changes arrive as single events with no drag in flight.
        switch NSApp?.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged:
            isDragging = true
            installDragEndMonitor()
        case .leftMouseUp:
            endDrag()
        default:
            break
        }
        readoutLabel.stringValue = VolumePercent.label(sender.integerValue)
        onChange?(sender.integerValue)
    }

    /// A drag whose last change callback doesn't coincide with mouse-up (a
    /// fast release, or Esc) would otherwise leave the flag set and the thumb
    /// deaf to model updates until the next drag. A scoped `.leftMouseUp`
    /// local monitor clears it from the real gesture end.
    private func installDragEndMonitor() {
        guard dragEndMonitor == nil else { return }
        dragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.endDrag()
            return event
        }
    }

    private func endDrag() {
        isDragging = false
        if let monitor = dragEndMonitor {
            NSEvent.removeMonitor(monitor)
            dragEndMonitor = nil
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A fader detached mid-drag (a rebuild under the pointer) must not
        // keep a monitor or a stuck flag.
        if window == nil { endDrag() }
    }

    deinit { endDrag() }

    // MARK: Test hooks

    /// Holds or releases the drag guard without a real mouse gesture.
    public var test_isDragging: Bool {
        get { isDragging }
        set { isDragging = newValue }
    }

    /// Fires the slider's own target/action after setting its value — the
    /// dispatch AppKit performs during a drag.
    public func test_fireSliderAction(settingValueTo value: Int) {
        slider.integerValue = value
        guard let action = slider.action,
              let target = slider.target as? NSObject else { return }
        _ = target.perform(action, with: slider)
    }
}
