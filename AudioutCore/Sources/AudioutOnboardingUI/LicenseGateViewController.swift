// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The first-open licence gate: an overlay the one surface draws over the live
/// Mixer, Scenes and Speakers screens (`AppSurfaceController.presentLicenseGate`)
/// after Setup, the way the iPhone's `LockedView` sits over its Speakers tab.
/// This controller's view IS the whole overlay: a `canvas` veil that leaves the
/// screen under it at about a third of its strength, a scrim darkening the
/// bottom 420 pt, and a raised panel 14 pt in from the sides and 8 pt above the
/// bottom.
///
/// The panel has two states, everything centred. `offer`: the title, a
/// subtitle, the gold "Buy Audiout", the trial button (only before any trial)
/// and "I already have a key". `enter`: the same title, a subtitle ending in
/// "click here to paste it", the key boxes and a two-line status label.
/// Buy opens the checkout and moves to `enter`; "I already have a key" moves
/// there without the checkout; a build with no checkout URL opens in `enter`.
/// `enter` ends in "Back" (to `offer`, so a buyer who abandoned the checkout
/// can reach Buy or the trial again; hidden without a checkout URL).
///
/// **The title never moves.** Both states' bodies sit in one slot as tall as
/// the key state needs, so the panel is the same height in both and the
/// transition is a crossfade of the bodies alone. In both, the subtitle sits
/// right under the title and the rest is centred in the space below it. Inside
/// `enter`, every state lands as words in the status label's two reserved
/// lines under the boxes; nothing appears and pushes the rest down.
///
/// There is no Register button: the key submits itself the moment its
/// twentieth character lands. Submitting mirrors
/// `LicenseSheetViewController`'s contract exactly — trim, a
/// changed key clears the stored verdict, the key is SAVED even when the
/// server can't be reached — because "couldn't verify" must never read as "not
/// yours", least of all on a screen the user cannot get past. A refused key's
/// reason is `LicenseCopy` (Core), shared with the Settings sheet.
///
/// An unreachable server passes the gate too (key saved, verified on a later
/// launch) — a hard gate that bricked an offline Mac would punish exactly the
/// buyer it exists to thank.
@MainActor
public final class LicenseGateViewController: NSViewController {

    /// Which body the panel shows.
    enum GateState { case offer, enter }

    private let settings: AppSettings
    private let transport: LicenseValidator.Transport?
    private let openURL: (URL) -> Void
    private let onPassed: () -> Void

    private let panel = GatePanelView()
    private let headlineLabel = NSTextField(labelWithString: "Activate Audiout")

    // The offer.
    private let offerBody = NSView()
    /// Buy, the trial and "I already have a key", centred in the space under
    /// the offer's subtitle.
    private let offerActions = NSStackView()
    private let offerSubtitle = NSTextField(wrappingLabelWithString:
        "Purchasing Audiout provides a licence that unlocks both this Mac as well as its companion iOS remote app.")
    /// The panel's one gold button, the 200 x 44 gold `CTAButton`.
    private var buyButton: CTAButton!
    private let trialButton = CTAButton(title: LicenseGateViewController.trialTitle,
                                        style: .secondary, target: nil, action: nil)
    private let haveKeyButton = TextLinkButton(title: "I already have a key", size: .caption)

    // The key entry.
    private let enterBody = NSView()
    /// The boxes' band, the status label and Back, centred in the space
    /// under the key state's subtitle.
    private let enterActions = NSStackView()
    private let enterSubtitle = NSTextField(labelWithString:
        "Copy your licence key from your receipt email, enter it below, or")
    private let pasteButton = TextActionButton(title: "click here to paste it")
    private let keyEntry = LicenseKeyEntryView()
    /// Two reserved lines: the status, then its detail where there is one.
    private let statusLine = NSTextField(wrappingLabelWithString: "")
    private var statusText = ""
    private var statusColor = Tokens.Color.label2
    private let backButton = TextLinkButton(title: "Back")

    private var state: GateState
    private var didPass = false
    /// A key check is waiting on the licence server.
    private var checking = false
    /// The status line's "Verifying…" pulse is running.
    private var pulsing = false
    /// The clipboard has had its one look on arriving in `enter`.
    private var clipboardOffered = false

    /// Where a pre-filled key may come from, injectable so tests can offer one
    /// without touching the user's real pasteboard. Read when the user clicks
    /// "click here to paste it", or once on arriving in `enter` when
    /// `pasteboardAccessIsAlwaysAllowed` says this app may already read the
    /// pasteboard without being asked.
    public var pasteboardString: () -> String? = { NSPasteboard.general.string(forType: .string) }

    /// Whether macOS is already set to let this app read the pasteboard
    /// silently. Injectable beside the string seam so a test can pick either
    /// arrival path.
    public var pasteboardAccessIsAlwaysAllowed: () -> Bool = {
        if #available(macOS 15.4, *) {
            return NSPasteboard.general.accessBehavior == .alwaysAllow
        }
        return false
    }

    /// The panel's edges against the overlay, and its padding.
    static let panelSideInset: CGFloat = 14
    static let panelBottomInset: CGFloat = 8
    private static let padTop: CGFloat = 16
    private static let padSide: CGFloat = 15
    /// The air above and below each state's body.
    private static let bodyAir: CGFloat = 28
    private static let rowSpacing: CGFloat = 12
    /// Between Buy and the trial button when they share a row.
    private static let ctaGap: CGFloat = 16
    /// From the Buy / trial row down to "I already have a key".
    private static let haveKeyGap: CGFloat = 18
    /// The key row's own band, above and below it.
    private static let keyBandInset: CGFloat = 14
    /// From the status label down to Back.
    private static let backGap: CGFloat = 4
    private static let sectionSpacing: CGFloat = 24
    private static let subtitleWidth: CGFloat = 520
    private static let keyLength = LicenseKeyEntryView.boxCount * LicenseKeyEntryView.groupSize

    private static let trialTitle = "Start 14 day free trial"

    /// How long an accepted key's "Registered" stays readable before the
    /// overlay fades.
    private static let passBeat: TimeInterval = 1.2
    private static let crossfade: TimeInterval = 0.25
    /// "Verifying…" breathes between full strength and this, once per cycle.
    private static let pulseFloor: CGFloat = 0.55
    private static let pulseCycle: CFTimeInterval = 1.4
    private static let pulseKey = "verifyingPulse"

    public init(settings: AppSettings,
                transport: LicenseValidator.Transport? = nil,
                openURL: @escaping (URL) -> Void,
                onPassed: @escaping () -> Void) {
        self.settings = settings
        self.transport = transport
        self.openURL = openURL
        self.onPassed = onPassed
        // A build from source has no checkout, so there is nothing to offer.
        self.state = settings.buyURL == nil ? .enter : .offer
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        headlineLabel.font = Tokens.Font.display
        headlineLabel.textColor = Tokens.Color.label
        headlineLabel.alignment = .center
        headlineLabel.setAccessibilityHeading()

        // The offer.
        offerSubtitle.font = Tokens.Font.titleLarge
        offerSubtitle.textColor = Tokens.Color.label2
        offerSubtitle.alignment = .center
        offerSubtitle.preferredMaxLayoutWidth = Self.subtitleWidth

        buyButton = CTAButton(title: "Buy Audiout", style: .primary, target: self,
                              action: #selector(buyTapped))
        buyButton.keyEquivalent = state == .offer ? "\r" : ""

        // The offer for someone who has no key and never had one. The question
        // is whether a trial has ever STARTED here, not whether one is running:
        // a trial that converted to a purchase has no expiry left (the server's
        // answer to a paid key clears it), so it reads as no trial at all, and
        // if that key is later refunded this gate comes back — offering a
        // second trial that `TrialClock.start` would refuse to give.
        trialButton.target = self
        trialButton.action = #selector(trialTapped)
        trialButton.isHidden = settings.trialStartedAt != nil

        haveKeyButton.target = self
        haveKeyButton.action = #selector(haveKeyTapped)

        // Buy and the trial side by side (owner's call 2026-10-20), the link
        // under them. A hidden trial button DETACHES (the stack view's
        // default), so Buy alone stays centred rather than leaving a gap.
        let ctaRow = NSStackView(views: [buyButton, trialButton])
        ctaRow.orientation = .horizontal
        ctaRow.alignment = .centerY
        ctaRow.spacing = Self.ctaGap
        [ctaRow, haveKeyButton].forEach(offerActions.addArrangedSubview)
        offerActions.setCustomSpacing(Self.haveKeyGap, after: ctaRow)

        // The key entry.
        enterSubtitle.font = Tokens.Font.titleLarge
        enterSubtitle.textColor = Tokens.Color.label2
        pasteButton.target = self
        pasteButton.action = #selector(pasteTapped)
        let subtitleRow = NSStackView(views: [enterSubtitle, pasteButton])
        subtitleRow.orientation = .horizontal
        subtitleRow.alignment = .firstBaseline
        subtitleRow.spacing = 4

        statusLine.font = Tokens.Font.titleLarge
        statusLine.textColor = Tokens.Color.label2
        statusLine.alignment = .center
        statusLine.maximumNumberOfLines = 2
        statusLine.setAccessibilityLabel("Status")
        // Layer-backed for the "Verifying…" pulse.
        statusLine.wantsLayer = true

        // The key row in its own band, 14 pt clear above and below.
        let keyBand = NSView()
        keyBand.translatesAutoresizingMaskIntoConstraints = false
        keyBand.addSubview(keyEntry)

        // Back alone, on the leading edge.
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.isHidden = settings.buyURL == nil
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let bottomRow = NSStackView(views: [backButton, bottomSpacer])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = Self.rowSpacing

        [keyBand, statusLine, bottomRow].forEach(enterActions.addArrangedSubview)
        enterActions.setCustomSpacing(0, after: keyBand)
        enterActions.setCustomSpacing(Self.backGap, after: statusLine)

        // Both bodies share one slot, so the panel keeps one height and the
        // title above never moves. In each, the subtitle sits right under the
        // title and the rest is centred in the space left below it, at least
        // `sectionSpacing` under the subtitle and `bodyAir` above the panel's
        // bottom edge. The taller body sets the slot's height.
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        var constraints: [NSLayoutConstraint] = []
        for (body, subtitle, actions) in [(offerBody, offerSubtitle as NSView, offerActions),
                                          (enterBody, subtitleRow, enterActions)] {
            actions.orientation = .vertical
            actions.alignment = .centerX
            actions.spacing = Self.rowSpacing
            actions.setHuggingPriority(.defaultHigh, for: .vertical)
            for view in [body, subtitle, actions] { view.translatesAutoresizingMaskIntoConstraints = false }
            body.addSubview(subtitle)
            body.addSubview(actions)
            slot.addSubview(body)
            let space = NSLayoutGuide()
            body.addLayoutGuide(space)
            constraints += [
                body.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
                body.topAnchor.constraint(equalTo: slot.topAnchor),
                body.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
                subtitle.topAnchor.constraint(equalTo: body.topAnchor,
                                              constant: Tokens.Layout.titleSubtitleSpacing),
                subtitle.centerXAnchor.constraint(equalTo: body.centerXAnchor),
                space.topAnchor.constraint(equalTo: subtitle.bottomAnchor),
                space.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                actions.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                actions.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                actions.centerYAnchor.constraint(equalTo: space.centerYAnchor),
                actions.topAnchor.constraint(greaterThanOrEqualTo: subtitle.bottomAnchor,
                                             constant: Self.sectionSpacing),
                actions.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor,
                                                constant: -Self.bodyAir),
            ]
        }
        let slotHug = slot.heightAnchor.constraint(equalToConstant: 0)
        slotHug.priority = .defaultLow
        offerBody.isHidden = state != .offer
        enterBody.isHidden = state != .enter

        let column = NSStackView(views: [headlineLabel, slot])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: Self.padTop, left: Self.padSide,
                                         bottom: 0, right: Self.padSide)
        column.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(column)
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.group)
        panel.setAccessibilityLabel("Activate Audiout")

        let root = LicenseGateOverlayView()
        root.addSubview(panel)
        root.onWindowAttach = { [weak self] in self?.attachedToWindow() }
        constraints += [
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.panelSideInset),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.panelSideInset),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.panelBottomInset),
            panel.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor),
            column.topAnchor.constraint(equalTo: panel.topAnchor),
            column.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            slot.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * Self.padSide),
            slotHug,
            offerSubtitle.widthAnchor.constraint(lessThanOrEqualToConstant: Self.subtitleWidth),
            subtitleRow.widthAnchor.constraint(lessThanOrEqualTo: slot.widthAnchor),
            keyEntry.topAnchor.constraint(equalTo: keyBand.topAnchor, constant: Self.keyBandInset),
            keyEntry.bottomAnchor.constraint(equalTo: keyBand.bottomAnchor, constant: -Self.keyBandInset),
            keyEntry.leadingAnchor.constraint(equalTo: keyBand.leadingAnchor),
            keyEntry.trailingAnchor.constraint(equalTo: keyBand.trailingAnchor),
            statusLine.heightAnchor.constraint(equalToConstant: 2 * Self.lineHeight(Tokens.Font.titleLarge)),
            statusLine.widthAnchor.constraint(equalTo: slot.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: slot.widthAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        view = root

        keyEntry.fill(settings.licenseKey ?? "")
        keyEntry.onChange = { [weak self] in self?.entryChanged() }
        // Set rather than shown: the count on arrival is not news, so
        // VoiceOver is not told.
        if !keyEntry.isComplete { setStatus(countLine) }
        applyTabOrder()
    }

    /// One line of `font`, measured rather than guessed — the status label's
    /// whole job is to be exactly two of these tall whatever it holds.
    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    private var countLine: String {
        let left = Self.keyLength - LicenseKeyEntryView.normalised(keyEntry.keyText).count
        return "\(left) character\(left == 1 ? "" : "s") to go"
    }

    private var motionAllowed: Bool {
        !HeadlessRuntime.isActive && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Authored rather than inferred from frames. The offer: Buy, the trial
    /// where there is one, "I already have a key", and back. The key entry:
    /// the paste link, the four boxes, Back where shown, and back.
    private func applyTabOrder() {
        if state == .offer {
            buyButton.nextKeyView = trialButton.isHidden ? haveKeyButton : trialButton
            trialButton.nextKeyView = haveKeyButton
            haveKeyButton.nextKeyView = buyButton
        } else {
            pasteButton.nextKeyView = keyEntry.firstBox
            keyEntry.chainKeyViews(to: backButton.isHidden ? pasteButton : backButton)
            backButton.nextKeyView = pasteButton
        }
    }

    /// The overlay entered a window (mounted, or re-seated after a screen
    /// switch) or that window became key (the surface reopened): in the key
    /// state, offer the clipboard key and put the cursor in the first box that
    /// is not full, so typing starts without a click.
    private func attachedToWindow() {
        offerClipboardKeyOnArrival()
        guard state == .enter, let window = view.window, keyEntry.isEnabled else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) { return }
        keyEntry.focusFirstEmpty()
    }

    /// A key sitting on the clipboard is almost always the one from the
    /// receipt the user just opened — so it is filled in: a full key verifies
    /// at once like any other, and a partial one shows its count. Once only,
    /// on the first arrival in the key state.
    ///
    /// Arrival reads the clipboard ONLY where the app is already set to always
    /// allow pasteboard access. On macOS 15.4 and later a read nobody asked
    /// for raises the system paste alert, so reading here unconditionally
    /// would open every launch of the paid build with a permission dialog.
    /// Everywhere else the key arrives through the paste link instead.
    private func offerClipboardKeyOnArrival() {
        guard state == .enter, !clipboardOffered else { return }
        clipboardOffered = true
        guard keyEntry.keyText.isEmpty, pasteboardAccessIsAlwaysAllowed() else { return }
        let pasted = (pasteboardString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard pasted.hasPrefix("AUDT-") else { return }
        keyEntry.fill(pasted)
    }

    /// The clicked read: the click is the gesture macOS wants before an app
    /// reads the clipboard. A paste REPLACES what is in the boxes; a full key
    /// verifies at once. Nothing happens while the boxes are locked: a check
    /// is in flight, and a paste is an edit typing could not make either.
    @objc private func pasteTapped() {
        guard keyEntry.isEnabled else { return }
        let pasted = (pasteboardString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard pasted.hasPrefix("AUDT-") else {
            let note = "No key on the clipboard. It starts with AUDT-."
            setStatus(statusText, color: statusColor, detail: note)
            announce(note)
            Analytics.capture("license:key_pasted", ["outcome": "no_key"])
            return
        }
        keyEntry.fill(pasted)
        Analytics.capture("license:key_pasted", ["outcome": "filled"])
    }

    // MARK: Actions

    /// Opens the checkout and moves to the key state, where the buyer comes
    /// back with the key from the receipt.
    @objc private func buyTapped() {
        guard let url = settings.buyURL else { return }
        Analytics.capture("license:buy_link_opened", ["source": "gate"])
        openURL(url)
        enterKeyState()
    }

    /// For a buyer who bought on the website before installing: the key
    /// state, without opening the checkout again.
    @objc private func haveKeyTapped() { enterKeyState() }

    /// Back to the offer, so a buyer who abandoned the checkout can reach Buy
    /// (or the trial) again. What is in the boxes stays for the way back.
    @objc private func backTapped() {
        guard state == .enter, settings.buyURL != nil, !checking else { return }
        switchBodies(to: .offer)
        buyButton.keyEquivalent = "\r"
    }

    /// Start the trial and get out of the way in the same breath.
    ///
    /// Nothing here waits on the network: the trial's dates are written
    /// locally, and telling the licence server about them is a later, silent
    /// job (`TrialRegistrar`) that runs with the app already open. A start that
    /// blocked on a server would put back the one wall this gate exists to
    /// remove.
    ///
    /// The pass is granted by the trial that `TrialClock` actually wrote, never
    /// by the click. `start` refuses a Mac that has had a trial before, and
    /// letting the click through anyway would open the app on no trial and no
    /// valid key, then do it again at every launch.
    @objc private func trialTapped() {
        TrialClock.start(settings: settings)
        guard case .active = TrialClock.state(settings: settings) else { return }
        Analytics.capture("license:trial_started")
        pass(afterBeat: false)
    }

    /// `offer` to `enter`. Offers the clipboard key on the first arrival and
    /// puts the caret in the first box that is not full.
    private func enterKeyState() {
        guard state == .offer else { return }
        buyButton.keyEquivalent = ""
        switchBodies(to: .enter)
        offerClipboardKeyOnArrival()
        if keyEntry.isEnabled { keyEntry.focusFirstEmpty() }
    }

    /// The title stays; the bodies crossfade over 0.25 s, at once under
    /// Reduce Motion and headless.
    private func switchBodies(to target: GateState) {
        state = target
        let (incoming, outgoing): (NSView, NSView) = target == .enter ? (enterBody, offerBody) : (offerBody, enterBody)
        incoming.isHidden = false
        if motionAllowed {
            incoming.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.crossfade
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                outgoing.animator().alphaValue = 0
                incoming.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // A quick second switch may have brought it back already.
                    guard self?.state == target else { return }
                    outgoing.isHidden = true
                    outgoing.alphaValue = 1
                }
            }
        } else {
            outgoing.isHidden = true
        }
        applyTabOrder()
    }

    /// Submit what is in the boxes: the path a full key takes the moment its
    /// twentieth character lands, and the deep link's. A check already in
    /// flight drops a second submission.
    private func registerTapped() {
        guard !checking else { return }
        let text = keyEntry.keyText
        guard !text.isEmpty else { return }

        // A different key is an unanswered question: the previous key's
        // verdict must not stand in for it while the server is asked.
        if text != settings.licenseKey { settings.licenseStatus = nil }
        settings.licenseKey = text

        keyEntry.isEnabled = false
        checking = true
        show("Verifying…")
        setPulsing(true)

        let validator = transport.map { LicenseValidator(settings: settings, transport: $0) }
            ?? LicenseValidator(settings: settings)
        validator.validate { [weak self] result in
            guard let self else { return }
            let outcome: String
            switch result {
            case .verified(.active): outcome = "active"
            case .verified(let status): outcome = status.rawValue
            case .unreachable: outcome = "unreachable"
            case .noServer: outcome = "no_server"
            case .noKey: outcome = "no_key"
            }
            Analytics.capture("license:key_submitted", ["outcome": outcome, "source": "gate"])
            self.setPulsing(false)
            switch result {
            case .verified(.active):
                self.show("Registered", color: Tokens.Color.label,
                          detail: "Thank you for supporting Audiout.")
                self.pass(afterBeat: true)
            case .verified(let status):
                // The boxes keep the key, and the caret goes to the first one
                // with nothing selected: the buyer corrects a character rather
                // than retyping twenty.
                self.checking = false
                self.keyEntry.isEnabled = true
                self.show("Key not accepted", color: Tokens.Color.failure,
                          detail: LicenseCopy.statusLine(for: status, reason: self.settings.licenseReason))
                self.keyEntry.focusBox(0)
            case .unreachable, .noServer, .noKey:
                // The key is SAVED and the gate opens: an unreachable server
                // must never lock a buyer out of the thing they paid for. The
                // normal launch validation settles the verdict later.
                self.show("Key saved", detail: "We'll check it next time you're online.")
                self.pass(afterBeat: true)
            }
        }
    }

    /// Open the gate exactly once. `afterBeat` holds the overlay just long
    /// enough for the result line to be read — skipped under Reduce Motion and
    /// headless, where there is nothing to watch.
    private func pass(afterBeat: Bool) {
        guard !didPass else { return }
        didPass = true
        guard afterBeat && motionAllowed else { return onPassed() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.passBeat) { [weak self] in
            self?.onPassed()
        }
    }

    /// A status and its detail land together, read out as one announcement
    /// so VoiceOver has one place to listen.
    private func show(_ status: String, color: NSColor = Tokens.Color.label2, detail: String = "") {
        setStatus(status, color: color, detail: detail)
        announce(detail.isEmpty ? status : "\(status). \(detail)")
    }

    /// The status on line one in `color`, the detail (if any) on line two in
    /// `label2`, both `titleLarge`, centred, each truncating on its own line.
    private func setStatus(_ status: String, color: NSColor = Tokens.Color.label2, detail: String = "") {
        statusText = status
        statusColor = color
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(
            string: detail.isEmpty ? status : "\(status)\n\(detail)",
            attributes: [.font: Tokens.Font.titleLarge, .foregroundColor: Tokens.Color.label2,
                         .paragraphStyle: paragraph])
        text.addAttribute(.foregroundColor, value: color,
                          range: NSRange(location: 0, length: (status as NSString).length))
        statusLine.attributedStringValue = text
    }

    private func announce(_ line: String) {
        guard !line.isEmpty, let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: line,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// "Verifying…" breathes until the verdict lands. Never under Reduce
    /// Motion or headless, where the word alone says it.
    private func setPulsing(_ on: Bool) {
        statusLine.layer?.removeAnimation(forKey: Self.pulseKey)
        statusLine.alphaValue = 1
        pulsing = on && motionAllowed
        guard pulsing, let layer = statusLine.layer else { return }
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [1, Self.pulseFloor, 1]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 2)
        pulse.duration = Self.pulseCycle
        pulse.repeatCount = .infinity
        layer.add(pulse, forKey: Self.pulseKey)
    }

    // MARK: Editing

    /// Every edit, typed, pasted or filled. A full key verifies at once;
    /// anything short of one shows the count and clears the detail, which is
    /// also how typing answers a verdict.
    private func entryChanged() {
        if keyEntry.isComplete {
            registerTapped()
        } else {
            setStatus(countLine)
        }
    }

    /// Switch to the key state without the checkout, fill the boxes with `key`
    /// and submit it — the landing point for `audiout://register?key=…` while
    /// the gate is up. A full key starts its own check as it lands; anything
    /// shorter is submitted as it stands. A submission already in flight drops
    /// the link.
    public func submit(key: String) {
        _ = view
        // The link carries the key, so the clipboard gets no look.
        clipboardOffered = true
        enterKeyState()
        guard !checking else { return }
        keyEntry.fill(key)
        registerTapped()
    }

    /// True while a key check is waiting on the licence server.
    public var isChecking: Bool {
        _ = view
        return checking
    }

    /// The key was validated and stored by the companion path, so the gate
    /// opens as its own check would.
    public func passWithStoredKey() { pass(afterBeat: false) }

    // MARK: Test-support hooks

    /// Replace the boxes' text, as typing or a paste would.
    public func test_setKeyText(_ text: String) {
        _ = view
        keyEntry.fill(text)
    }

    /// Submit what is in the boxes now, the path a full key takes by itself.
    public func test_tapRegister() {
        _ = view
        registerTapped()
    }

    /// Invoke "click here to paste it" as a click would.
    public func test_tapPasteKey() {
        _ = view
        pasteTapped()
    }

    /// Invoke "Buy Audiout" as a click would.
    public func test_tapBuy() {
        _ = view
        buyTapped()
    }

    /// Invoke "I already have a key" as a click would.
    public func test_tapHaveKey() {
        _ = view
        haveKeyTapped()
    }

    /// Invoke "Back" as a click would.
    public func test_tapBack() {
        _ = view
        backTapped()
    }

    /// Invoke the trial offer as a click would.
    public func test_tapTrial() {
        _ = view
        trialTapped()
    }

    /// Which body the panel shows.
    var test_state: GateState {
        _ = view
        return state
    }

    /// Whether the trial offer is on the panel: the offer state only.
    public var test_trialIsVisible: Bool {
        _ = view
        return state == .offer && !trialButton.isHidden
    }

    /// The trial button's title, as drawn.
    public var test_trialTitle: String {
        _ = view
        return trialButton.title
    }

    /// The panel's title.
    public var test_headlineText: String {
        _ = view
        return headlineLabel.stringValue
    }

    /// The current state's subtitle (in `enter`, the sentence before the
    /// paste link).
    public var test_bodyText: String {
        _ = view
        return state == .offer ? offerSubtitle.stringValue : enterSubtitle.stringValue
    }

    /// Arrival, without needing a window.
    public func test_arrive() {
        _ = view
        offerClipboardKeyOnArrival()
    }

    /// The status label's lines as drawn, in the key state only.
    private var statusLines: [String] {
        state == .enter ? statusLine.stringValue.components(separatedBy: "\n") : []
    }

    /// The status label's first line, or `nil` while it is empty or not shown.
    public var test_resultText: String? {
        _ = view
        return statusLines.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The status label's second line, or `nil` while there is none.
    public var test_detailText: String? {
        _ = view
        return statusLines.count > 1 ? statusLines[1] : nil
    }

    /// Whether "Verifying…" is pulsing.
    public var test_statusIsPulsing: Bool { pulsing }

    /// The assembled key.
    public var test_keyText: String {
        _ = view
        return keyEntry.keyText
    }

    /// "Buy Audiout"'s frame in the overlay's coordinates.
    public var test_buyFrame: CGRect {
        _ = view
        return buyButton.convert(buyButton.bounds, to: view)
    }

    /// The trial button's frame in the overlay's coordinates.
    public var test_trialFrame: CGRect {
        _ = view
        return trialButton.convert(trialButton.bounds, to: view)
    }

    /// Whether "Buy Audiout" is offered (the offer state, which needs a buy
    /// URL).
    public var test_buyIsVisible: Bool {
        _ = view
        return state == .offer && !buyButton.isHidden
    }

    /// Whether the gate has fired `onPassed` (or is in the beat before it).
    public var test_didPass: Bool { didPass }

    /// The raised panel, for the layout tests.
    var test_panel: NSView {
        _ = view
        return panel
    }

    /// The key boxes' row.
    var test_keyEntry: LicenseKeyEntryView {
        _ = view
        return keyEntry
    }

    /// Everything the current state shows, title first, for the layout
    /// tests. The offer: the title, the subtitle, Buy, the trial when
    /// offered, and "I already have a key". The key entry: the title, the
    /// subtitle, the paste link, the boxes, the status label, and Back when
    /// shown.
    var test_visibleControls: [NSView] {
        _ = view
        let controls: [NSView] = state == .offer
            ? [headlineLabel, offerSubtitle, buyButton, trialButton, haveKeyButton]
            : [headlineLabel, enterSubtitle, pasteButton, keyEntry, statusLine, backButton]
        return controls.filter { !$0.isHidden }
    }
}

/// The overlay itself: the veil and the scrim, drawn from `Tokens` at draw
/// time so appearance and Increase Contrast changes repaint them. No blur:
/// `NSVisualEffectView`'s within-window blending samples nothing useful from
/// the layer-backed screens under it (it rendered as an opaque tint over the
/// old Metal ground), so the veil is a flat translucent fill.
///
/// It claims every point it covers — a click, a scroll or a stray key that
/// reaches it stops here, so nothing under the gate can be worked. Its own
/// controls still hit normally.
private final class LicenseGateOverlayView: NSView {

    /// The veil's opacity: the screen under it reads at about 34 %.
    static let veilAlpha: CGFloat = 0.66
    /// The scrim covers this much of the bottom (or the whole overlay, if
    /// shorter): clear at its top, `canvas` at 0.55 at 42 %, solid from 82 %.
    static let scrimHeight: CGFloat = 420

    /// Called when the overlay enters a window and whenever that window
    /// becomes key.
    var onWindowAttach: (() -> Void)?
    private var keyObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        redrawOnAccessibilityDisplayChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWindowAttach?() }
        }
        onWindowAttach?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let canvas = Tokens.Color.canvas
        canvas.withAlphaComponent(Self.veilAlpha).setFill()
        bounds.fill()

        let height = min(Self.scrimHeight, bounds.height)
        guard height > 0, let scrim = NSGradient(
            colors: [canvas.withAlphaComponent(0), canvas.withAlphaComponent(0.55), canvas, canvas],
            atLocations: [0, 0.42, 0.82, 1],
            colorSpace: .sRGB) else { return }
        // Unflipped: the scrim's top edge is `height` above the bottom, and its
        // locations run top (clear) to bottom (solid).
        scrim.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: height), angle: -90)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    /// Keys a focused gate control did not use stop here rather than reaching
    /// the screen underneath. Escape still travels on, to the surface's own
    /// close.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { super.keyDown(with: event) }
    }
}

/// The panel: `raised` fill, a 1 pt `rim` edge, the `row` radius, and a soft
/// drop shadow 4 pt down — the iPhone `deckSurface`'s chrome. Layer-drawn, so
/// colours are re-resolved in `updateLayer` on every appearance or contrast
/// change.
private final class GatePanelView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        redrawOnAccessibilityDisplayChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        guard let layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.cornerRadius = Tokens.Layout.Radius.row
        layer.cornerCurve = .continuous
        layer.masksToBounds = false
        layer.backgroundColor = Tokens.Color.raised.cgColor
        layer.borderColor = Tokens.Color.rim.cgColor
        layer.borderWidth = 1
        layer.shadowColor = Tokens.Color.shadow.cgColor
        layer.shadowOpacity = dark ? 0.18 : 0.10
        // A 12 pt blur is a 6 pt layer radius (the survey card's conversion).
        layer.shadowRadius = 12 / 2
        // A plain (unflipped) view's layer is y-up: a negative y falls below.
        layer.shadowOffset = CGSize(width: 0, height: -4)
    }

    override func layout() {
        super.layout()
        let radius = Tokens.Layout.Radius.row
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil)
    }
}
