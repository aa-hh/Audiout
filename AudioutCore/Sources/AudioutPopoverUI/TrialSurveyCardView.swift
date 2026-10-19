// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The expired-trial survey: a card that rises over the shell's content view
/// on a dimmed ground, asks why the user has not bought (one tap), one
/// follow-up for three of the five reasons, an optional few lines of text, then
/// shows a thank-you mark. The host (`AppSurfaceController`) sends the events;
/// this view only reports the answers.
final class TrialSurveyCardView: NSView {

    enum Step: Equatable { case reason, detail, text, thanks }

    // MARK: Constants

    /// Every size, duration and curve the card and its thank-you mark use, in
    /// one place.
    enum Metrics {
        // Card
        static let cardWidth: CGFloat = 420
        static let cardRadius: CGFloat = Tokens.Layout.Radius.row
        static let cardEdgeWidth: CGFloat = 1
        static let shadowOffsetY: CGFloat = 18
        static let shadowBlur: CGFloat = 44
        static let shadowOpacity: Float = 0.4
        static let progressHeight: CGFloat = 3
        static let insetTop: CGFloat = 22
        static let insetSide: CGFloat = 20
        static let insetBottom: CGFloat = 18
        static let spacing: CGFloat = 16
        static let questionSpacing: CGFloat = 4
        static let fieldHintSpacing: CGFloat = 6
        static let footerSpacing: CGFloat = 16
        // Text step: about four lines of `body`, scrolling past that.
        static let textAreaHeight: CGFloat = 84
        static let textAreaInset: CGFloat = 6
        // Tiles
        static let tileHeight: CGFloat = 44
        static let tileSpacing: CGFloat = 8
        static let tileRadius: CGFloat = Tokens.Layout.Radius.control
        static let tilePaddingLeading: CGFloat = 6
        static let tilePaddingTrailing: CGFloat = 14
        static let tileGap: CGFloat = 12
        static let iconWellSize: CGFloat = 32
        static let tileGlyphSize: CGFloat = 20
        static let tileEdgeWidth: CGFloat = 1
        static let tileChosenEdgeWidth: CGFloat = 1.5
        static let hoverWashAlpha: CGFloat = PopoverColumnGrid.rowHoverWashAlpha
        static let chosenWashAlpha: CGFloat = 0.18
        // Card motion
        static let appearDuration: CFTimeInterval = 0.2
        static let appearStartScale: CGFloat = 0.96
        static let advanceDelay: TimeInterval = 0.12
        static let progressDuration: TimeInterval = 0.2
        static let stepSlideDuration: CFTimeInterval = 0.2
        static let stepSlideDistance: CGFloat = 32
        // razor: a hard cap keeps one pasted essay out of the event; raise it if answers come back cut.
        static let textLimit = 500
        // Thank-you step
        static let thanksInsetTop: CGFloat = 36
        static let thanksSpacing: CGFloat = 14
        static let thanksButtonExtraGap: CGFloat = 6
        static let stageSize = NSSize(width: 160, height: 100)
        static let markGlyphPointSize: CGFloat = 30
        static let ringDiameter: CGFloat = 72
        static let ringLineWidth: CGFloat = 3.8
        static let dotDiameter: CGFloat = 19
        static let glowSize = NSSize(width: 150, height: 96)
        static let glowBlur: CGFloat = 36
        static let glowOpacity: Float = 0.22
        /// Radial stops of the glow layer standing in for the blurred ellipse:
        /// full, full, half at the ellipse's edge, clear at edge + blur.
        static var glowStops: [NSNumber] { [0, 0.3, 0.62, 1] }
        // Thank-you motion (Figma frame 70:7077)
        static let ringDrawDuration: CFTimeInterval = 0.42
        static var ringDrawCurve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1) }
        /// The lit stretch behind the drawing tip.
        static let highlighterSweep: CGFloat = .pi / 4
        /// The lit stretch fades to grey over the last 120 ms of the draw, so
        /// it is gone when the dot pops.
        static let highlighterFadeBegin: CFTimeInterval = 0.30
        static let highlighterFadeDuration: CFTimeInterval = 0.12
        static let dotPopBegin: CFTimeInterval = 0.42
        static let dotStiffness: CGFloat = 400
        static let dotDamping: CGFloat = 21
        static let dotMass: CGFloat = 1
        /// Damping ratio 21 / (2 * sqrt(400)) = 0.525: from rest, the scale
        /// peaks near 1.15 about 185 ms after the pop starts.
        static let dotInitialVelocity: CGFloat = 0
        static let glowBegin: CFTimeInterval = 0.6
        static let glowDuration: CFTimeInterval = 0.24
        static let reduceMotionFadeDuration: CFTimeInterval = 0.2
    }

    // MARK: Copy

    struct Option {
        let title: String
        let symbol: String
    }

    struct Detail {
        let question: String
        let subline: String?
        let multi: Bool
        let options: [Option]
    }

    static let reasonQuestion = "What\u{2019}s kept you from buying a license?"
    static let textQuestion = "Anything else we should know?"
    static let textSubline = "Optional."
    static let textPlaceholder = "What would make Audiout worth buying for you?"
    static let textHint = "Leave out names, emails or anything personal."
    static let thanksTitle = "Thanks."
    static let thanksBody = "That helps decide what we build next."

    /// Titles are the survey's choice texts: `ExpiredTrialSurvey` keys its
    /// follow-up questions on them.
    static let reasons: [Option] = [
        Option(title: "The price", symbol: "tag"),
        Option(title: "It's missing something I need", symbol: "puzzlepiece"),
        Option(title: "It hasn't been reliable enough", symbol: "exclamationmark.arrow.triangle.2.circlepath"),
        Option(title: "I don't use it often enough", symbol: "calendar"),
        Option(title: "I use something else for this", symbol: "arrow.left.arrow.right"),
    ]

    static let details: [String: Detail] = [
        "It's missing something I need": Detail(
            question: "What would you need?", subline: "Pick any.", multi: true, options: [
                Option(title: "A sleep timer that fades out", symbol: "moon.zzz"),
                Option(title: "Shortcuts and automation", symbol: "bolt"),
                Option(title: "Add a speaker by IP address", symbol: "network"),
                Option(title: "A volume limit per speaker", symbol: "speaker.wave.1"),
                Option(title: "Play a line-in or other input", symbol: "cable.connector"),
            ]),
        "It hasn't been reliable enough": Detail(
            question: "What went wrong most often?", subline: nil, multi: false, options: [
                Option(title: "Sound drops out or stutters", symbol: "waveform.slash"),
                Option(title: "Speakers drift out of sync", symbol: "timer"),
                Option(title: "A speaker won't connect or disappears", symbol: "antenna.radiowaves.left.and.right.slash"),
                Option(title: "Sound lags behind video", symbol: "tv"),
            ]),
        "I use something else for this": Detail(
            question: "What do you use instead?", subline: nil, multi: false, options: [
                Option(title: "Airfoil", symbol: "wind"),
                Option(title: "SoundSource", symbol: "slider.horizontal.3"),
                Option(title: "Apple's own AirPlay", symbol: "airplayaudio"),
                Option(title: "The Sonos app", symbol: "hifispeaker.2"),
            ]),
    ]

    // MARK: State

    var onSent: ((ExpiredTrialSurvey.Answers) -> Void)?
    var onDismissed: ((ExpiredTrialSurvey.Answers) -> Void)?
    var onDone: (() -> Void)?

    let survey: ExpiredTrialSurvey
    private(set) var answers = ExpiredTrialSurvey.Answers()
    private(set) var step: Step = .reason
    /// Steps shown before the current one, for Back.
    private var history: [Step] = []
    /// Shuffled once per card, so Back returns to the same order.
    private let reasonOrder: [Option]
    private var progressFraction: CGFloat = 0
    private var advanceTimer: Timer?

    private let shadowHost = SurveyShadowHostView()
    private let card = SurveyCardChromeView()
    private let progressFill = SurveyColorBarView(color: { Tokens.Color.gold })
    private lazy var progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
    private let body = NSView()
    private lazy var bodyTop = body.topAnchor.constraint(
        equalTo: card.topAnchor, constant: Metrics.cardEdgeWidth + Metrics.progressHeight + Metrics.insetTop)
    private var stepView: NSView?
    private var tiles: [SurveyTileButton] = []
    private var continueButton: ProminentButton?
    private var textView: SurveyTextView?
    private var markView: SurveyThanksMarkView?

    private static var animates: Bool { !HeadlessRuntime.isActive }
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(survey: ExpiredTrialSurvey) {
        self.survey = survey
        self.reasonOrder = Self.reasons.shuffled()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let track = SurveyColorBarView(color: { Tokens.Color.hairline })
        for view in [shadowHost, card, track, progressFill, body] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(shadowHost)
        shadowHost.addSubview(card)
        card.addSubview(track)
        card.addSubview(progressFill)
        card.addSubview(body)
        NSLayoutConstraint.activate([
            shadowHost.centerXAnchor.constraint(equalTo: centerXAnchor),
            shadowHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            shadowHost.widthAnchor.constraint(equalToConstant: Metrics.cardWidth),
            card.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            card.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            card.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
            track.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.cardEdgeWidth),
            track.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            track.heightAnchor.constraint(equalToConstant: Metrics.progressHeight),
            progressFill.topAnchor.constraint(equalTo: track.topAnchor),
            progressFill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            progressFill.heightAnchor.constraint(equalToConstant: Metrics.progressHeight),
            progressWidth,
            bodyTop,
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.cardEdgeWidth + Metrics.insetSide),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -(Metrics.cardEdgeWidth + Metrics.insetSide)),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -(Metrics.cardEdgeWidth + Metrics.insetBottom)),
        ])

        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)

        NotificationCenter.default.addObserver(
            self, selector: #selector(restampColors),
            name: Tokens.accentStyleDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(restampColors),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        show(.reason, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        advanceTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: Ground

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Tokens.Color.cardScrim.setFill()
        bounds.fill(using: .sourceOver)
    }

    /// The dimmed ground takes clicks and scrolls so nothing beneath reacts.
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    @objc private func restampColors() {
        func mark(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(mark)
        }
        mark(self)
        markView?.restampColors()
    }

    // MARK: Appear

    /// Fade the ground in and lift the card from 96 % scale; instant under
    /// Reduce Motion or headless. Takes the keyboard for the number keys.
    func appear() {
        // The host pins this view by constraints just before calling, so only
        // the superview's pass gives `shadowHost` the bounds the scale centres on.
        (superview ?? self).layoutSubtreeIfNeeded()
        window?.makeFirstResponder(self)
        guard Self.animates, !Self.reduceMotion, let hostLayer = shadowHost.layer, let rootLayer = layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Metrics.appearDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        rootLayer.add(fade, forKey: "surveyAppearFade")
        let center = CGPoint(x: hostLayer.bounds.midX, y: hostLayer.bounds.midY)
        var start = CATransform3DMakeTranslation(center.x, center.y, 0)
        start = CATransform3DScale(start, Metrics.appearStartScale, Metrics.appearStartScale, 1)
        start = CATransform3DTranslate(start, -center.x, -center.y, 0)
        let lift = CABasicAnimation(keyPath: "transform")
        lift.fromValue = start
        lift.toValue = CATransform3DIdentity
        lift.duration = Metrics.appearDuration
        lift.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hostLayer.add(lift, forKey: "surveyAppearLift")
    }

    // MARK: Leaving

    /// Not now, Escape, or the host ending the card: before the thank-you
    /// step that is a dismissal with the answers so far; on it, Done.
    func dismiss() {
        advanceTimer?.invalidate()
        advanceTimer = nil
        if step == .thanks {
            onDone?()
        } else {
            onDismissed?(answers)
        }
    }

    /// The shell's cancel handler. Always handled while the card is up.
    func handleEscape() -> Bool {
        dismiss()
        return true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        if let digit = Int(chars), digit >= 1, digit <= tiles.count {
            tiles[digit - 1].performClick(nil)
            return
        }
        if chars == "\r" {
            if step == .thanks { doneClicked(); return }
            if let continueButton, continueButton.isEnabled { continueClicked(); return }
        }
        super.keyDown(with: event)
    }

    // MARK: Steps

    private var detail: Detail? { answers.reason.flatMap { Self.details[$0] } }

    private func fraction(for step: Step) -> CGFloat {
        switch step {
        case .reason: return 1.0 / 3
        case .detail: return 2.0 / 3
        case .text, .thanks: return 1
        }
    }

    private func goForward(to next: Step) {
        history.append(step)
        show(next, animated: true)
    }

    private func show(_ next: Step, animated: Bool) {
        advanceTimer?.invalidate()
        advanceTimer = nil
        step = next
        tiles = []
        continueButton = nil
        textView = nil
        markView = nil

        let content: NSView
        switch next {
        case .reason:
            content = choiceStep(question: Self.reasonQuestion, subline: nil, options: reasonOrder, multi: false)
        case .detail:
            let detail = detail!
            content = choiceStep(question: detail.question, subline: detail.subline, options: detail.options, multi: detail.multi)
        case .text:
            content = textStep()
        case .thanks:
            content = thanksStep()
        }
        bodyTop.constant = Metrics.cardEdgeWidth + Metrics.progressHeight
            + (next == .thanks ? Metrics.thanksInsetTop : Metrics.insetTop)

        stepView?.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        body.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: body.topAnchor),
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        stepView = content
        setProgress(fraction(for: next), animated: animated)
        layoutSubtreeIfNeeded()
        if animated { slideIn(content) }
        window?.makeFirstResponder(textView ?? self)
        markView?.play()
    }

    private func setProgress(_ fraction: CGFloat, animated: Bool) {
        progressFraction = fraction
        let width = Metrics.cardWidth * fraction
        guard animated, Self.animates, !Self.reduceMotion else {
            progressWidth.constant = width
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.progressDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            progressWidth.animator().constant = width
        }
    }

    /// The next step slides in from the right and fades up; a plain fade
    /// under Reduce Motion; nothing headless.
    private func slideIn(_ view: NSView) {
        guard Self.animates, let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        if Self.reduceMotion {
            group.animations = [fade]
        } else {
            let slide = CABasicAnimation(keyPath: "transform")
            slide.fromValue = CATransform3DMakeTranslation(Metrics.stepSlideDistance, 0, 0)
            slide.toValue = CATransform3DIdentity
            group.animations = [fade, slide]
        }
        group.duration = Metrics.stepSlideDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "surveyStepIn")
    }

    // MARK: Step views

    private func questionGroup(_ question: String, subline: String?) -> NSStackView {
        let title = NSTextField(wrappingLabelWithString: question)
        title.font = Tokens.Font.display
        title.textColor = Tokens.Color.label
        title.isSelectable = false
        title.preferredMaxLayoutWidth = Metrics.cardWidth - 2 * (Metrics.cardEdgeWidth + Metrics.insetSide)
        var views: [NSView] = [title]
        if let subline {
            let sub = NSTextField(labelWithString: subline)
            sub.font = Tokens.Font.body
            sub.textColor = Tokens.Color.label2
            views.append(sub)
        }
        card.setAccessibilityTitleUIElement(title)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.questionSpacing
        return stack
    }

    private func column(_ views: [NSView], spacing: CGFloat = Metrics.spacing) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views where !(view is NSTextField) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// Back on the left; the link and the primary button on the right.
    private func footer(back: Bool, link: TextLinkButton?, primary: ProminentButton?) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Metrics.footerSpacing
        if back {
            stack.addView(TextLinkButton(title: "Back", target: self, action: #selector(backClicked)), in: .leading)
        }
        if let link { stack.addView(link, in: .trailing) }
        if let primary { stack.addView(primary, in: .trailing) }
        return stack
    }

    private func choiceStep(question: String, subline: String?, options: [Option], multi: Bool) -> NSView {
        let tileViews = options.enumerated().map { index, option in
            let tile = SurveyTileButton(title: option.title, symbolName: option.symbol, keyHint: "\(index + 1)")
            tile.target = self
            tile.action = #selector(tileClicked(_:))
            return tile
        }
        tiles = tileViews
        let tileStack = column(tileViews, spacing: Metrics.tileSpacing)
        var primary: ProminentButton?
        if multi {
            let button = ProminentButton(title: "Continue", target: self, action: #selector(continueClicked))
            button.isEnabled = false
            continueButton = button
            primary = button
        }
        let notNow = TextLinkButton(title: "Not now", target: self, action: #selector(notNowClicked))
        let foot = footer(back: step != .reason, link: notNow, primary: primary)
        return column([questionGroup(question, subline: subline), tileStack, foot])
    }

    private func textStep() -> NSView {
        let contentWidth = Metrics.cardWidth - 2 * (Metrics.cardEdgeWidth + Metrics.insetSide)
        let field = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: Metrics.textAreaHeight))
        field.borderType = .bezelBorder
        field.hasVerticalScroller = true
        field.hasHorizontalScroller = false
        field.autohidesScrollers = true
        let area = SurveyTextView(frame: NSRect(origin: .zero, size: field.contentSize))
        area.minSize = NSSize(width: 0, height: field.contentSize.height)
        area.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        area.isVerticallyResizable = true
        area.isHorizontallyResizable = false
        area.autoresizingMask = [.width]
        area.textContainer?.widthTracksTextView = true
        area.textContainerInset = NSSize(width: Metrics.textAreaInset, height: Metrics.textAreaInset)
        area.isRichText = false
        area.allowsUndo = true
        area.drawsBackground = true
        area.backgroundColor = .textBackgroundColor
        area.font = Tokens.Font.body
        area.textColor = Tokens.Color.label
        area.insertionPointColor = Tokens.Color.label
        area.placeholder = Self.textPlaceholder
        area.setAccessibilityPlaceholderValue(Self.textPlaceholder)
        area.setAccessibilityLabel(Self.textQuestion)
        area.delegate = self
        area.onSend = { [weak self] in self?.sendClicked() }
        field.documentView = area
        field.heightAnchor.constraint(equalToConstant: Metrics.textAreaHeight).isActive = true
        textView = area
        let hint = NSTextField(labelWithString: Self.textHint)
        hint.font = Tokens.Font.caption
        hint.textColor = Tokens.Color.label2
        let fieldGroup = NSStackView(views: [field, hint])
        fieldGroup.orientation = .vertical
        fieldGroup.alignment = .leading
        fieldGroup.spacing = Metrics.fieldHintSpacing
        field.widthAnchor.constraint(equalTo: fieldGroup.widthAnchor).isActive = true
        let skip = TextLinkButton(title: "Skip", target: self, action: #selector(skipClicked))
        let send = ProminentButton(title: "Send", target: self, action: #selector(sendClicked))
        let foot = footer(back: true, link: skip, primary: send)
        return column([questionGroup(Self.textQuestion, subline: Self.textSubline), fieldGroup, foot])
    }

    private func thanksStep() -> NSView {
        let mark = SurveyThanksMarkView()
        markView = mark
        let title = NSTextField(labelWithString: Self.thanksTitle)
        title.font = Tokens.Font.display
        title.textColor = Tokens.Color.label
        let line = NSTextField(labelWithString: Self.thanksBody)
        line.font = Tokens.Font.body
        line.textColor = Tokens.Color.label2
        let done = ProminentButton(title: "Done", target: self, action: #selector(doneClicked))
        card.setAccessibilityTitleUIElement(title)
        let stack = NSStackView(views: [mark, title, line, done])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.thanksSpacing
        stack.setCustomSpacing(Metrics.thanksSpacing * 2 + Metrics.thanksButtonExtraGap, after: line)
        return stack
    }

    // MARK: Actions

    @objc private func tileClicked(_ sender: SurveyTileButton) {
        guard advanceTimer == nil, let index = tiles.firstIndex(of: sender) else { return }
        if step == .detail, detail?.multi == true {
            sender.isChosen.toggle()
            answers.detail = tiles.filter(\.isChosen).map(\.title)
            continueButton?.isEnabled = !answers.detail.isEmpty
            return
        }
        for (i, tile) in tiles.enumerated() { tile.isChosen = i == index }
        let next: Step
        if step == .reason {
            answers.reason = sender.title
            answers.detail = []
            next = detail == nil ? .text : .detail
        } else {
            answers.detail = [sender.title]
            next = .text
        }
        guard Self.animates else {
            goForward(to: next)
            return
        }
        advanceTimer = Timer.scheduledTimer(withTimeInterval: Metrics.advanceDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceTimer = nil
                self?.goForward(to: next)
            }
        }
    }

    @objc private func continueClicked() {
        guard !answers.detail.isEmpty else { return }
        goForward(to: .text)
    }

    /// Return to the step shown before this one, clearing its answer.
    @objc private func backClicked() {
        guard let previous = history.popLast() else { return }
        switch previous {
        case .reason: answers = ExpiredTrialSurvey.Answers()
        case .detail: answers.detail = []
        case .text, .thanks: break
        }
        show(previous, animated: true)
    }

    @objc private func notNowClicked() { dismiss() }

    @objc private func skipClicked() {
        answers.text = nil
        finish()
    }

    @objc private func sendClicked() {
        let typed = (textView?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        answers.text = typed.isEmpty ? nil : String(typed.prefix(Metrics.textLimit))
        finish()
    }

    private func finish() {
        guard step == .text else { return }
        onSent?(answers)
        history.append(step)
        show(.thanks, animated: true)
    }

    @objc private func doneClicked() { onDone?() }

    // MARK: Test hooks

    var test_step: Step { step }
    var test_tileTitles: [String] { tiles.map(\.title) }
    var test_chosenTitles: [String] { tiles.filter(\.isChosen).map(\.title) }
    func test_pick(_ index: Int) { tiles[index].performClick(nil) }
    func test_pressKey(_ characters: String) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: 0) else { return }
        keyDown(with: event)
    }
    func test_continue() { continueClicked() }
    func test_back() { backClicked() }
    func test_notNow() { notNowClicked() }
    func test_skip() { skipClicked() }
    var test_textView: NSTextView? { textView }
    func test_send() { sendClicked() }
    func test_done() { doneClicked() }
    var test_progressFraction: CGFloat { progressFraction }
}

extension TrialSurveyCardView: NSTextViewDelegate {
    /// Caps the answer at `Metrics.textLimit` while typing; a paste that
    /// would pass it goes in cut to fit.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard let replacement = replacementString else { return true }
        let room = Metrics.textLimit - ((textView.string as NSString).length - range.length)
        if (replacement as NSString).length <= room { return true }
        var used = 0
        let fit = String(replacement.prefix { used += $0.utf16.count; return used <= room })
        if !fit.isEmpty { textView.insertText(fit, replacementRange: range) }
        return false
    }
}

// MARK: - Text area

/// The text step's answer: Return starts a new line, Command-Return sends,
/// Tab moves on to the buttons, and Escape goes up the responder chain to
/// the shell's cancel handler, so it dismisses the card as before. Draws its
/// placeholder while empty.
final class SurveyTextView: NSTextView {
    var onSend: (() -> Void)?
    var placeholder = ""

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "\r" {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }

    /// NSTextView turns Escape into completion; the card wants it to dismiss.
    override func cancelOperation(_ sender: Any?) {
        nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        NSAttributedString(string: placeholder, attributes: [
            .font: font ?? Tokens.Font.body,
            .foregroundColor: NSColor.placeholderTextColor,
        ]).draw(at: NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y))
    }
}

// MARK: - Card chrome

/// Carries the card's drop shadow; the card inside clips to its corners.
private final class SurveyShadowHostView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        guard let layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = Tokens.Color.shadow.cgColor
        layer.shadowOpacity = TrialSurveyCardView.Metrics.shadowOpacity
        layer.shadowRadius = TrialSurveyCardView.Metrics.shadowBlur / 2
        // A plain (unflipped) view's layer is y-up: a negative y falls below the card.
        layer.shadowOffset = CGSize(width: 0, height: -TrialSurveyCardView.Metrics.shadowOffsetY)
    }

    override func layout() {
        super.layout()
        let radius = TrialSurveyCardView.Metrics.cardRadius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

/// The card: `panel` fill, a `containerEdge` edge, rounded corners that clip
/// the progress line.
private final class SurveyCardChromeView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = TrialSurveyCardView.Metrics.cardRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.backgroundColor = Tokens.Color.panel.cgColor
        layer.borderColor = Tokens.Color.containerEdge.cgColor
        layer.borderWidth = TrialSurveyCardView.Metrics.cardEdgeWidth
    }
}

/// A flat bar in one token colour (the progress track and its fill).
private final class SurveyColorBarView: NSView {
    private let color: () -> NSColor

    init(color: @escaping () -> NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        color().setFill()
        bounds.fill(using: .sourceOver)
    }
}

// MARK: - Tile

/// One answer: an icon well, the label and its number key. A button, so
/// focus, Space and VoiceOver come from AppKit; the look is drawn here.
final class SurveyTileButton: NSButton {
    private typealias M = TrialSurveyCardView.Metrics

    let symbolName: String
    let keyHint: String
    var isChosen = false {
        didSet {
            needsDisplay = true
            setAccessibilitySelected(isChosen)
        }
    }
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var hoverArea: NSTrackingArea?

    init(title: String, symbolName: String, keyHint: String) {
        self.symbolName = symbolName
        self.keyHint = keyHint
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: M.tileHeight).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: M.tileHeight) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: M.tileRadius, yRadius: M.tileRadius).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let edgeWidth = isChosen ? M.tileChosenEdgeWidth : M.tileEdgeWidth
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: edgeWidth / 2, dy: edgeWidth / 2),
                                 xRadius: M.tileRadius, yRadius: M.tileRadius)
        Tokens.Color.raised.setFill()
        shape.fill()
        if isChosen || isHovered {
            Tokens.Color.engagedChrome.withAlphaComponent(isChosen ? M.chosenWashAlpha : M.hoverWashAlpha).setFill()
            shape.fill()
        }
        (isChosen ? Tokens.Color.gold : Tokens.Color.containerEdge).setStroke()
        shape.lineWidth = edgeWidth
        shape.stroke()

        let well = NSRect(x: M.tilePaddingLeading, y: (bounds.height - M.iconWellSize) / 2,
                          width: M.iconWellSize, height: M.iconWellSize)
        Tokens.Color.well.setFill()
        NSBezierPath(roundedRect: well, xRadius: Tokens.Layout.Radius.control, yRadius: Tokens.Layout.Radius.control).fill()
        let glyphColor = isChosen ? Tokens.Color.gold : Tokens.Color.label2
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: M.tileGlyphSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [glyphColor]))) {
            let scale = min(M.tileGlyphSize / image.size.width, M.tileGlyphSize / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: well.midX - size.width / 2, y: well.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }

        let hint = NSAttributedString(string: keyHint, attributes: [
            .font: Tokens.Font.keycap,
            .foregroundColor: isChosen ? Tokens.Color.gold : Tokens.Color.label3,
        ])
        let hintSize = hint.size()
        let hintX = bounds.width - M.tilePaddingTrailing - hintSize.width
        hint.draw(at: NSPoint(x: hintX, y: (bounds.height - hintSize.height) / 2))

        let label = NSAttributedString(string: title, attributes: [
            .font: Tokens.Font.body,
            .foregroundColor: Tokens.Color.label,
        ])
        let labelX = well.maxX + M.tileGap
        let labelHeight = label.size().height
        label.draw(with: NSRect(x: labelX, y: (bounds.height - labelHeight) / 2,
                                width: max(0, hintX - M.tileGap - labelX), height: labelHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - Thank-you mark

/// The thank-you mark: a speaker glyph inside an open `rim` ring whose gap
/// holds a `gold` dot, over a soft `glow`. On `play()` the ring draws in one
/// clockwise sweep from its bottom opening to the dot with a lit stretch at
/// its tip, the dot pops, then the glow fades up.
final class SurveyThanksMarkView: NSView {
    private typealias M = TrialSurveyCardView.Metrics

    /// Holds every layer below the glyph, so Reduce Motion fades them as one.
    private let layersView = NSView()
    private let glyph = NSImageView()
    private let glowLayer = CAGradientLayer()
    private let ringLayer = CAShapeLayer()
    /// The lit stretch: a conic gradient (rotated to follow the tip) inside a
    /// container masked to the stroke behind the tip.
    private let highlighterContainer = CALayer()
    private let highlighterGradient = CAGradientLayer()
    private let highlighterMask = CAShapeLayer()
    private let dotLayer = CAShapeLayer()

    /// Where the sweep starts: the gap's edge just right of the bottom. The
    /// gap is the halo ring's, centred on the dot.
    private static let startAngle = PopoverColumnGrid.haloRingGapCenterAngle - PopoverColumnGrid.haloRingGapWidth / 2
    private static let sweep = 2 * .pi - PopoverColumnGrid.haloRingGapWidth

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layersView.wantsLayer = true
        layersView.translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = NSImage(systemSymbolName: "hifispeaker", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: M.markGlyphPointSize, weight: .regular))
        glyph.contentTintColor = Tokens.Color.label
        addSubview(layersView)
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: M.stageSize.width),
            heightAnchor.constraint(equalToConstant: M.stageSize.height),
            layersView.leadingAnchor.constraint(equalTo: leadingAnchor),
            layersView.trailingAnchor.constraint(equalTo: trailingAnchor),
            layersView.topAnchor.constraint(equalTo: topAnchor),
            layersView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)

        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1, y: 1)
        glowLayer.locations = M.glowStops
        glowLayer.opacity = M.glowOpacity

        ringLayer.fillColor = nil
        ringLayer.lineWidth = M.ringLineWidth
        ringLayer.lineCap = .round

        highlighterGradient.type = .conic
        highlighterGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        highlighterGradient.endPoint = CGPoint(x: 1, y: 0.5)
        // Bright at angle 0 and grey a sweep away on both sides, so the
        // gradient's own direction cannot matter: the mask shows only the
        // stretch behind the tip.
        let edge = NSNumber(value: Double(M.highlighterSweep / (2 * .pi)))
        highlighterGradient.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
        highlighterMask.fillColor = nil
        highlighterMask.strokeColor = NSColor.black.cgColor
        highlighterMask.lineWidth = M.ringLineWidth
        highlighterMask.lineCap = .round
        highlighterContainer.mask = highlighterMask
        highlighterContainer.addSublayer(highlighterGradient)
        highlighterContainer.opacity = 0

        let layer = layersView.layer!
        layer.masksToBounds = false
        for sublayer in [glowLayer, ringLayer, highlighterContainer, dotLayer] { layer.addSublayer(sublayer) }
        restampColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = layersView.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = M.ringDiameter / 2
        let glowExtent = NSSize(width: M.glowSize.width + 2 * M.glowBlur, height: M.glowSize.height + 2 * M.glowBlur)
        glowLayer.frame = CGRect(x: center.x - glowExtent.width / 2, y: center.y - glowExtent.height / 2,
                                 width: glowExtent.width, height: glowExtent.height)
        // `layersView` is unflipped, so its layers are y-up and `clockwise:
        // true` runs with decreasing angle: clockwise on screen.
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: Self.startAngle,
                    endAngle: Self.startAngle - Self.sweep, clockwise: true)
        ringLayer.frame = bounds
        ringLayer.path = path
        highlighterContainer.frame = bounds
        highlighterMask.frame = bounds
        highlighterMask.path = path
        let side = M.ringDiameter + 2 * M.ringLineWidth
        highlighterGradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        highlighterGradient.position = center
        let dotAngle = PopoverColumnGrid.haloRingGapCenterAngle
        let dotCenter = CGPoint(x: center.x + radius * cos(dotAngle), y: center.y + radius * sin(dotAngle))
        dotLayer.bounds = CGRect(x: 0, y: 0, width: M.dotDiameter, height: M.dotDiameter)
        dotLayer.position = dotCenter
        dotLayer.path = CGPath(ellipseIn: dotLayer.bounds, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restampColors()
    }

    func restampColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let glow = Tokens.Color.glow
            glowLayer.colors = [glow.cgColor, glow.cgColor, glow.withAlphaComponent(0.5).cgColor,
                                glow.withAlphaComponent(0).cgColor]
            ringLayer.strokeColor = Tokens.Color.rim.cgColor
            highlighterGradient.colors = [glow.cgColor, Tokens.Color.rim.cgColor, Tokens.Color.rim.cgColor, glow.cgColor]
            dotLayer.fillColor = Tokens.Color.gold.cgColor
        }
        glyph.contentTintColor = Tokens.Color.label
    }

    /// Runs the thank-you timeline once. Headless, everything stays settled.
    /// Model values are the settled state; animations only lead into it.
    func play() {
        guard !HeadlessRuntime.isActive, let host = layersView.layer else { return }
        layoutSubtreeIfNeeded()
        let now = host.convertTime(CACurrentMediaTime(), from: nil)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = M.reduceMotionFadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            host.add(fade, forKey: "markFade")
            return
        }

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = M.ringDrawDuration
        draw.timingFunction = M.ringDrawCurve
        ringLayer.add(draw, forKey: "ringDraw")

        // The lit stretch rides the tip: the mask's end follows the ring's,
        // its start trails by the sweep, and the gradient's bright angle
        // turns with them on the same curve.
        let trail = M.highlighterSweep / Self.sweep
        let maskEnd = CABasicAnimation(keyPath: "strokeEnd")
        maskEnd.fromValue = 0
        maskEnd.toValue = 1
        let maskStart = CABasicAnimation(keyPath: "strokeStart")
        maskStart.fromValue = -trail
        maskStart.toValue = 1 - trail
        let maskGroup = CAAnimationGroup()
        maskGroup.animations = [maskEnd, maskStart]
        maskGroup.duration = M.ringDrawDuration
        maskGroup.timingFunction = M.ringDrawCurve
        highlighterMask.add(maskGroup, forKey: "highlighterTrack")
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = Self.startAngle
        turn.toValue = Self.startAngle - Self.sweep
        turn.duration = M.ringDrawDuration
        turn.timingFunction = M.ringDrawCurve
        highlighterGradient.add(turn, forKey: "highlighterTurn")
        let lit = CABasicAnimation(keyPath: "opacity")
        lit.fromValue = 1
        lit.toValue = 0
        lit.beginTime = now + M.highlighterFadeBegin
        lit.duration = M.highlighterFadeDuration
        lit.fillMode = .backwards
        highlighterContainer.add(lit, forKey: "highlighterFade")

        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.stiffness = M.dotStiffness
        pop.damping = M.dotDamping
        pop.mass = M.dotMass
        pop.initialVelocity = M.dotInitialVelocity
        pop.fromValue = 0
        pop.toValue = 1
        pop.beginTime = now + M.dotPopBegin
        pop.duration = pop.settlingDuration
        pop.fillMode = .backwards
        dotLayer.add(pop, forKey: "dotPop")

        let glowIn = CABasicAnimation(keyPath: "opacity")
        glowIn.fromValue = 0
        glowIn.toValue = M.glowOpacity
        glowIn.beginTime = now + M.glowBegin
        glowIn.duration = M.glowDuration
        glowIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glowIn.fillMode = .backwards
        glowLayer.add(glowIn, forKey: "glowIn")
    }
}
