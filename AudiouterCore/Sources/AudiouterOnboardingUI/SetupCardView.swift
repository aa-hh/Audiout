// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The static identity of one permission card — the parts that never change
/// with state. The TITLE is not here: it is per-state (imperative while asking,
/// earned capability once granted) and Local Network's even carries a count, so
/// ``title(for:foundSpeakers:)`` resolves it in one place instead of letting
/// each caller pick a string.
struct SetupCardContent {

    let step: SetupStep
    /// SF Symbol for the leading icon tile. Every tile shares the same neutral
    /// `raised` well + hairline rim (the fill is never coloured); only the
    /// glyph carries ``iconColor``, and it warms to gold once granted.
    let symbolName: String
    /// This card's resting glyph tint — one of the four
    /// `Tokens.Color.permission*` hues.
    let iconColor: NSColor
    /// The imperative ask, shown while the card is active (and on any state
    /// that has NOT earned a checkmark — skipped, or auto-passed because the OS
    /// can't grant it).
    let activeTitle: String
    /// The earned capability, shown only alongside a checkmark.
    let completedTitle: String
    /// The plain-language "why", shown only while the card is expanded. Reused
    /// verbatim from the pre-sequential rows — these strings are TCC-framing
    /// tested (they defuse the OS's "recording" wording before it appears).
    let detail: String
    /// First-fire call to action.
    let allowTitle: String
    /// Whether this card offers Skip (Bluetooth and Remote Control only — both
    /// are outside `RequiredPermission`, so passing on one can't touch the gate).
    let isSkippable: Bool

    /// The one place the per-state title table lives (brief §"Card anatomy":
    /// imperative → earned capability).
    ///
    /// `foundSpeakers` only matters for Local Network, whose completed title IS
    /// the proof — "Found 3 speakers" is something the user can check, where a
    /// checkmark for a permission macOS won't confirm is a claim we can't back.
    /// A count of zero there means the step completed WITHOUT a browse (macOS
    /// 14, where local network isn't gated at all), so the copy must not imply
    /// the user did anything.
    func title(for state: SetupCardState, foundSpeakers: Int = 0) -> String {
        switch state {
        case .active, .pending, .skipped, .autoPassed:
            return activeTitle
        case .completed:
            guard step == .localNetwork else { return completedTitle }
            switch foundSpeakers {
            case 0: return "Speakers on your Wi\u{2011}Fi are already reachable"
            case 1: return "Found 1 speaker"
            default: return "Found \(foundSpeakers) speakers"
            }
        }
    }
}

/// How a card renders right now — derived from ``SetupFlowModel`` by the view
/// controller, never decided here.
enum SetupCardState: Equatable {
    /// Not reached yet: a collapsed strip, imperative title, no checkmark. NOT
    /// dimmed — a pending step is a promise, not a disabled control.
    case pending
    /// The one expanded card.
    case active
    /// Verified: collapsed strip, capability title, checkmark.
    case completed
    /// Complete only because this OS cannot grant it at all (the pre-14.2
    /// process tap). The strip carries `note` where the checkmark would be —
    /// claiming a grant nobody made would be a lie.
    case autoPassed(note: String)
    /// The user passed on it: collapsed, imperative title, no checkmark. The
    /// app asks again the next time it genuinely needs the capability.
    case skipped
}

/// One permission card in the Setup window's sequential flow: a collapsed strip
/// (icon tile, title, and — once verified — a checkmark) that expands, for
/// exactly one step at a time, into the same strip plus the "why" copy and an
/// accessory row (Allow…, a spinner while probing, Open Settings… after a
/// denial, and Skip on the two optional steps).
///
/// Expanding and collapsing animate the body's CLIP HEIGHT on
/// `Tokens.Motion.collapseRevealDuration` — the same one motion language every
/// collapsible element in the app uses (`CardView.setBodyCollapsed` in
/// `AudiouterPopoverUI` is the reference implementation, and the source of the
/// two traps handled below: SEED the clip with its current height before
/// animating it shut, and lay the collapsed start state out before animating it
/// open, or the travel has nowhere to go).
///
/// Stock AppKit only (SF Symbols, `NSButton`, `NSProgressIndicator`, system
/// colours) — the only custom drawing is the shared `IconTileView` /
/// `RoundedContainerView` chrome, which has no stock equivalent for the System
/// Settings grouped-inset look.
final class SetupCardView: NSView {

    // MARK: Metrics

    /// Inset from the card edge to its content.
    static let horizontalInset: CGFloat = 14
    /// Padding above/below the header strip — with `iconSide` this IS the
    /// collapsed card height.
    static let headerVerticalInset: CGFloat = 7
    /// Icon-tile side for a card (smaller than `IconTileView.side`: five
    /// collapsed strips plus one expanded card have to fit a fixed-height
    /// window without the stack scrolling).
    static let iconSide: CGFloat = 26
    /// Gap from the icon tile to the text column — also the left edge every
    /// expanded line aligns to.
    static let iconGap: CGFloat = 12
    /// Width of the leading accessory slot that holds Allow… / Open Settings… /
    /// the probe spinner. FIXED, for the same reason the old parallel rows
    /// pinned a 184 pt accessory column: whatever the slot currently holds, the
    /// Skip button beside it sits at the same x, so a state change never nudges
    /// a control sideways.
    ///
    /// Sized for the widest occupant that ever SHARES the row with Skip —
    /// "Open Settings…" — not for the widest occupant overall. Speaker Sync's
    /// longer "Open Login Items…" simply overflows the slot, which is safe
    /// because that card isn't skippable and nothing sits to its right; sizing
    /// the slot for it instead left a visible dead gap between Allow… and Skip
    /// on the two cards that do pair them.
    static let primarySlotWidth: CGFloat = 134
    /// Height reserved for the accessory row, so swapping a button for the
    /// spinner never changes the card's height.
    static let accessoryHeight: CGFloat = 24
    /// The checkmark's grown width (Wispr's 0 → 20 slide-in).
    static let checkmarkWidth: CGFloat = 20
    /// How far a locked step's icon tile fades. Enough to read as not-yet-yours
    /// beside the active card, not so far that the glyph stops being legible.
    static let lockedTileAlpha: CGFloat = 0.5
    /// The active card's pointer-hover wash, in the app's shared hover colour and
    /// alpha (`PopoverColumnGrid.rowHoverWashAlpha`) so a hovered card feels like
    /// a hovered row.
    static var hoverWashFraction: CGFloat { PopoverColumnGrid.rowHoverWashAlpha }
    /// The exact width the wrapping copy gets, derived from the FIXED left pane.
    ///
    /// This is the wrap-stability rule in its new form. The old parallel rows
    /// pinned a 184 pt accessory column so the text's right edge never moved
    /// between states; here the accessory sits BELOW the copy, so the text width
    /// is a constant of the layout — and pinning `preferredMaxLayoutWidth` to it
    /// once, at build time, is what makes an expanded card's height
    /// deterministic. Deriving it from the resolved frame in `layout()` instead
    /// made the height depend on WHEN AutoLayout got there, which showed up as
    /// snapshot fixtures of the same state rendering at different heights.
    static var textColumnWidth: CGFloat {
        OnboardingViewController.leftPaneWidth - OnboardingViewController.paneMargin * 2
            - horizontalInset - iconSide - iconGap - horizontalInset
    }

    // MARK: Choreography timing

    /// The checkmark's slide-in: width 0 → 20 pt plus a fade, on the
    /// system-driven motion band (warm-signal-v3 §6: 180–260 ms easeOut)…
    static let checkmarkDuration: TimeInterval = 0.2
    /// …delayed by the same amount after the grant lands, so the re-fronted
    /// window has settled before anything moves on it.
    static let checkmarkDelay: TimeInterval = 0.2

    // MARK: Wiring

    private let content: SetupCardContent
    private let onAllow: () -> Void
    private let onSkip: () -> Void
    private let onOpenSettings: () -> Void

    private var iconTile: IconTileView!
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    /// The honest "asked, found nothing" line under Local Network's copy — nil
    /// (hidden) for every other state and step.
    private let hintLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    /// Sits in the same trailing slot as the checkmark, for a step the flow
    /// hasn't reached: locked steps have to READ locked, not merely un-ticked.
    private let lockGlyph = NSImageView()
    /// Sits where the checkmark would, for a step this OS cannot grant.
    private let noteLabel = NSTextField(labelWithString: "")

    private var surface: RoundedContainerView!
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

    private let primarySlot = NSView()
    private let spinner = NSProgressIndicator()
    private var allowButton: NSButton?
    private var skipButton: NSButton?
    /// The quiet SECOND path, offered beside the primary rather than replacing
    /// it: Local Network's retry IS its own browse, so the pane is a demotion,
    /// not the two-mode flip every other card does.
    private var settingsLinkButton: NSButton!

    private let bodyClip = ClipView()
    private let bodyStack = NSStackView()
    private var bodyHeight: NSLayoutConstraint!
    private var checkmarkWidthConstraint: NSLayoutConstraint!

    private(set) var state: SetupCardState = .pending
    /// Whether a prompt/probe for this step is in flight — the spinner is showing
    /// and the card-level click target is inert.
    private var isProbing = false
    private var isBodyCollapsed = true
    private var collapseGeneration = 0

    init(content: SetupCardContent,
         onAllow: @escaping () -> Void,
         onSkip: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void = {}) {
        self.content = content
        self.onAllow = onAllow
        self.onSkip = onSkip
        self.onOpenSettings = onOpenSettings
        super.init(frame: .zero)
        build()
        apply(.pending, foundSpeakers: 0, isProbing: false, offersSettingsFallback: false, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        surface = RoundedContainerView()
        addSubview(surface)

        iconTile = IconTileView(symbolName: content.symbolName,
                                accessibility: content.activeTitle,
                                color: content.iconColor,
                                side: Self.iconSide,
                                pointSize: 13)

        titleLabel.font = Tokens.Font.bodyEmphasized
        titleLabel.lineBreakMode = .byTruncatingTail
        // Last-resort headroom before the tail truncates — the earned titles are
        // long, and a squeeze on one machine's font metrics shouldn't eat words.
        titleLabel.allowsDefaultTighteningForTruncation = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                  accessibilityDescription: "Allowed")
        checkmark.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        checkmark.contentTintColor = .systemGreen
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.alphaValue = 0

        lockGlyph.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")
        lockGlyph.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        lockGlyph.contentTintColor = Tokens.Color.tertiaryLabel
        lockGlyph.translatesAutoresizingMaskIntoConstraints = false
        lockGlyph.isHidden = true

        noteLabel.font = Tokens.Font.caption
        noteLabel.textColor = Tokens.Color.secondaryLabel
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.setContentHuggingPriority(.required, for: .horizontal)
        noteLabel.isHidden = true

        detailLabel.font = Tokens.Font.caption
        detailLabel.textColor = Tokens.Color.secondaryLabel
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        detailLabel.stringValue = content.detail
        detailLabel.preferredMaxLayoutWidth = Self.textColumnWidth
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = Tokens.Font.caption
        hintLabel.textColor = Tokens.Color.warning
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 0
        hintLabel.preferredMaxLayoutWidth = Self.textColumnWidth
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        primarySlot.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSStackView(views: [primarySlot])
        accessory.orientation = .horizontal
        accessory.alignment = .centerY
        accessory.spacing = 8
        accessory.translatesAutoresizingMaskIntoConstraints = false
        if content.isSkippable {
            let skip = onboardingActionButton(title: "Skip", prominent: false,
                                              target: self, action: #selector(skipTapped))
            skipButton = skip
            accessory.addArrangedSubview(skip)
        }
        settingsLinkButton = onboardingActionButton(title: "Open Settings…", prominent: false,
                                                    target: self, action: #selector(settingsTapped))
        settingsLinkButton.isHidden = true
        accessory.addArrangedSubview(settingsLinkButton)

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 8
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.addArrangedSubview(detailLabel)
        bodyStack.addArrangedSubview(hintLabel)
        bodyStack.addArrangedSubview(accessory)

        bodyClip.translatesAutoresizingMaskIntoConstraints = false
        bodyClip.addSubview(bodyStack)

        surface.addSubview(iconTile)
        surface.addSubview(titleLabel)
        surface.addSubview(checkmark)
        surface.addSubview(lockGlyph)
        surface.addSubview(noteLabel)
        surface.addSubview(bodyClip)

        let inset = Self.horizontalInset
        let vInset = Self.headerVerticalInset
        let textLeading = inset + Self.iconSide + Self.iconGap

        bodyHeight = bodyClip.heightAnchor.constraint(equalToConstant: 0)
        checkmarkWidthConstraint = checkmark.widthAnchor.constraint(equalToConstant: 0)

        // The body's bottom pin is deliberately breakable: the clip is shorter
        // than its content for the whole collapse, and a required pin would
        // fight the animated height instead of being clipped by it.
        let bodyBottom = bodyStack.bottomAnchor.constraint(equalTo: bodyClip.bottomAnchor)
        bodyBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconTile.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: inset),
            iconTile.topAnchor.constraint(equalTo: surface.topAnchor, constant: vInset),

            titleLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: textLeading),
            titleLabel.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            checkmark.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            checkmark.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            checkmarkWidthConstraint,
            checkmark.heightAnchor.constraint(equalToConstant: 16),

            // The lock shares the checkmark's slot — the trailing marker is ONE
            // position that says locked, then earned. Pinned to the same trailing
            // inset rather than to the checkmark, whose width is 0 when hidden.
            lockGlyph.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            lockGlyph.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            noteLabel.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            noteLabel.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            // The title yields to whichever trailing accessory is showing.
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: noteLabel.leadingAnchor, constant: -8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: lockGlyph.leadingAnchor, constant: -8),

            bodyClip.topAnchor.constraint(equalTo: iconTile.bottomAnchor, constant: vInset),
            bodyClip.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            bodyClip.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            bodyClip.bottomAnchor.constraint(equalTo: surface.bottomAnchor),

            bodyStack.topAnchor.constraint(equalTo: bodyClip.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: bodyClip.leadingAnchor, constant: textLeading),
            bodyStack.trailingAnchor.constraint(equalTo: bodyClip.trailingAnchor, constant: -inset),
            bodyBottom,

            primarySlot.widthAnchor.constraint(equalToConstant: Self.primarySlotWidth),
            primarySlot.heightAnchor.constraint(equalToConstant: Self.accessoryHeight),
        ])
    }

    // MARK: State

    /// Repaint for `state`.
    ///
    /// - Parameters:
    ///   - foundSpeakers: Local Network's browse count, for the completed title.
    ///   - isProbing: a prompt/probe for this step is in flight — the spinner
    ///     replaces the Allow button (never both, and never a second prompt).
    ///   - offersSettingsFallback: the two-mode Allow's second mode — the
    ///     prompt is spent, so the button becomes the Settings deep link.
    ///   - hint: an extra honest line under the copy (Local Network's "no
    ///     speakers found yet"), or nil.
    ///   - primaryTitle: replaces the Allow title without changing what the
    ///     click does (Local Network's "Try Again" — the retry is the same
    ///     browse, so it must not become a Settings link).
    ///   - offersSettingsLink: show the quiet secondary "Open Settings…"
    ///     BESIDE the primary, rather than in place of it.
    ///   - animated: run the grant choreography (checkmark slide-in, clip
    ///     collapse/expand). Callers pass false for the first build, Reduce
    ///     Motion, and any off-window/occluded window — steady states must
    ///     render settled or snapshots stop being deterministic.
    func apply(_ state: SetupCardState,
               foundSpeakers: Int,
               isProbing: Bool,
               offersSettingsFallback: Bool,
               hint: String? = nil,
               primaryTitle: String? = nil,
               offersSettingsLink: Bool = false,
               animated: Bool) {
        let wasCompleted = isCheckmarked(self.state)
        self.state = state
        self.isProbing = isProbing

        titleLabel.stringValue = content.title(for: state, foundSpeakers: foundSpeakers)
        // A step the flow hasn't reached is LOCKED and must read locked (owner
        // decision 2026-08-11): dimmed text and tile, plus the lock below.
        // Completed and skipped steps stay legible — the user did reach those.
        titleLabel.textColor = switch state {
        case .active: Tokens.Color.label
        case .pending: Tokens.Color.tertiaryLabel
        case .completed, .autoPassed, .skipped: Tokens.Color.secondaryLabel
        }
        iconTile.alphaValue = state == .pending ? Self.lockedTileAlpha : 1
        iconTile.setLit(isCheckmarked(state))
        // The lock and the checkmark share one slot, so only one can show; a
        // skipped step gets neither (the user answered, they just said no).
        lockGlyph.isHidden = state != .pending

        if case .autoPassed(let note) = state {
            noteLabel.stringValue = note
            noteLabel.isHidden = false
        } else {
            noteLabel.isHidden = true
        }

        hintLabel.stringValue = hint ?? ""
        hintLabel.isHidden = hint == nil

        applyCheckmark(shown: isCheckmarked(state),
                       animated: animated && !wasCompleted && isCheckmarked(state))
        rebuildPrimarySlot(isProbing: isProbing, offersSettingsFallback: offersSettingsFallback,
                           primaryTitle: primaryTitle)
        settingsLinkButton.isHidden = !(state == .active && offersSettingsLink)
        setBodyCollapsed(state != .active, animated: animated)
        applySurface()
        applyAccessibility()
        // Only the active card is a click target, so its tracking area comes and
        // goes with the state.
        window?.invalidateCursorRects(for: self)
    }

    /// Fill and border by state: the active card is the one lifted off the
    /// canvas, so current-vs-locked can't be mistaken. Elevation is one rung up
    /// the warm surface ladder (`raised` over `panel`) plus a heavier neutral
    /// rim — no new colour, and nothing gold (that budget belongs to the
    /// instruments and the granted tile).
    private func applySurface() {
        guard state == .active else {
            surface.fill = Tokens.Color.panel
            surface.border = Tokens.Color.hairline
            surface.borderWidth = 1
            return
        }
        surface.fill = isHovered
            ? Tokens.Color.raised.blended(withFraction: Self.hoverWashFraction,
                                          of: NSColor.selectedContentBackgroundColor) ?? Tokens.Color.raised
            : Tokens.Color.raised
        surface.border = Tokens.Color.label.withAlphaComponent(0.18)
        surface.borderWidth = 1.5
    }

    /// Whether this state has EARNED a checkmark. Only a real verification
    /// does: an auto-pass carries a note instead, and a skipped step stays
    /// visibly unfinished.
    private func isCheckmarked(_ state: SetupCardState) -> Bool { state == .completed }

    /// Rebuild the leading accessory slot. Exactly one occupant: the spinner
    /// while a prompt/probe is in flight, otherwise the two-mode Allow button.
    private func rebuildPrimarySlot(isProbing: Bool, offersSettingsFallback: Bool,
                                    primaryTitle: String?) {
        for view in primarySlot.subviews { view.removeFromSuperview() }
        allowButton = nil
        guard state == .active else { spinner.stopAnimation(nil); return }

        let occupant: NSView
        if isProbing {
            spinner.startAnimation(nil)
            occupant = spinner
        } else {
            spinner.stopAnimation(nil)
            let title = primaryTitle ?? (offersSettingsFallback ? "Open Settings…" : content.allowTitle)
            let button = onboardingActionButton(title: title, prominent: true,
                                                target: self, action: #selector(allowTapped))
            allowButton = button
            occupant = button
        }
        primarySlot.addSubview(occupant)
        NSLayoutConstraint.activate([
            occupant.leadingAnchor.constraint(equalTo: primarySlot.leadingAnchor),
            occupant.centerYAnchor.constraint(equalTo: primarySlot.centerYAnchor),
        ])
        if occupant !== spinner {
            // A BUTTON fills the slot rather than sitting in it: "Allow…" is far
            // narrower than "Open Settings…", and a button hugging its own title
            // inside a fixed slot leaves a dead gap before Skip that reads as a
            // layout mistake. `>=` so a wider button (Speaker Sync's "Open Login
            // Items…") overflows instead of being squeezed. The spinner keeps
            // its natural size — the SLOT is what holds Skip's position there.
            occupant.trailingAnchor.constraint(greaterThanOrEqualTo: primarySlot.trailingAnchor)
                .isActive = true
        }
    }

    /// The checkmark's width-0 → 20 pt slide plus fade, delayed after the grant
    /// (Wispr's exact figures — see the brief's "Wispr reference"). Instant
    /// whenever the choreography is off.
    private func applyCheckmark(shown: Bool, animated: Bool) {
        guard animated else {
            checkmarkWidthConstraint.constant = shown ? Self.checkmarkWidth : 0
            checkmark.alphaValue = shown ? 1 : 0
            return
        }
        checkmarkWidthConstraint.constant = 0
        checkmark.alphaValue = 0
        let generation = collapseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkmarkDelay) { [weak self] in
            guard let self, self.collapseGeneration == generation,
                  self.isCheckmarked(self.state) else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.checkmarkDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                self.checkmarkWidthConstraint.animator().constant = Self.checkmarkWidth
                self.checkmark.animator().alphaValue = 1
                self.layoutSubtreeIfNeeded()
            }
        }
    }

    /// Collapse/expand the body by animating its CLIP HEIGHT and nothing else —
    /// the house collapse language (`CardView.setBodyCollapsed`). Carries both
    /// of that implementation's traps: SEED the clip with its current height
    /// before animating it to 0 (or the first collapse snaps), and lay the
    /// collapsed start state out before animating open (or the expand has
    /// nothing to travel).
    private func setBodyCollapsed(_ collapsed: Bool, animated: Bool) {
        if animated && collapsed == isBodyCollapsed { return }
        isBodyCollapsed = collapsed

        if !animated {
            // End state applied directly (initial build, Reduce Motion,
            // off-window). EXPANDED deactivates the pinned height entirely, so
            // the clip takes the body's own intrinsic height — a measured
            // constant here would freeze whatever the copy happened to wrap to
            // at that instant.
            if collapsed {
                bodyHeight.constant = 0
                bodyHeight.isActive = true
                bodyClip.isHidden = true
            } else {
                bodyClip.isHidden = false
                bodyHeight.isActive = false
            }
            return
        }

        // Settle the body's natural height BEFORE animating, so the expand
        // target is exact.
        layoutSubtreeIfNeeded()
        let target = bodyStack.fittingSize.height

        collapseGeneration += 1
        let generation = collapseGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Tokens.Motion.collapseRevealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            if collapsed {
                // SEED the current height before animating to 0: activating the
                // constraint alone pins the clip shut instantly, and the
                // animation then travels 0 → 0 (the "first collapse snaps" trap).
                bodyHeight.constant = bodyClip.frame.height
                bodyHeight.isActive = true
                layoutSubtreeIfNeeded()
                bodyHeight.animator().constant = 0
            } else {
                // Clear hidden and lay the collapsed START state out before
                // animating up, or the expand has nothing to travel.
                bodyClip.isHidden = false
                bodyHeight.isActive = true
                bodyHeight.constant = 0
                layoutSubtreeIfNeeded()
                bodyHeight.animator().constant = target
            }
            layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self, generation == self.collapseGeneration else { return }
            // A superseded animation must not touch the terminal state — the
            // newest one owns it.
            if self.isBodyCollapsed {
                self.bodyClip.isHidden = true
            } else {
                // Expanded: drop the pin so the body flexes with its content again.
                self.bodyHeight.isActive = false
            }
        })
    }

    // MARK: Actions

    @objc private func allowTapped() { onAllow() }
    @objc private func skipTapped() { onSkip() }
    @objc private func settingsTapped() { onOpenSettings() }

    /// Whether a click anywhere on this card should fire its Allow (owner
    /// decision 2026-08-11: the whole active card is the target, the button is
    /// just the visible affordance). A locked strip is NOT clickable — the flow
    /// is sequential, and jumping ahead would ask for a permission out of order.
    /// The in-flight guard is the UI half of single-flight.
    private var isCardClickable: Bool { state == .active && !isProbing }

    /// AppKit hit-tests the deepest view first, so a click that lands on Skip,
    /// Allow… or the spinner never reaches here — the sub-controls sit above the
    /// card-level target by construction, with no coordinate maths to keep in
    /// step.
    override func mouseUp(with event: NSEvent) {
        guard isCardClickable else { super.mouseUp(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { super.mouseUp(with: event); return }
        allowTapped()
    }

    /// Swallow the press half too, so the card doesn't pass an unhandled
    /// mouseDown up to whatever is behind it while it's acting as a button.
    override func mouseDown(with event: NSEvent) {
        guard isCardClickable else { super.mouseDown(with: event); return }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isCardClickable else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applySurface()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applySurface()
    }

    /// The card IS the button as far as VoiceOver is concerned, named for what
    /// pressing it does. A card that isn't the live one is a plain group — its
    /// press would be refused, and offering it would be a lie.
    private func applyAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(isCardClickable ? .button : .group)
        setAccessibilityLabel(titleLabel.stringValue)
        let action = allowButton?.title ?? content.allowTitle
        setAccessibilityHelp(isCardClickable ? action : nil)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isCardClickable else { return false }
        allowTapped()
        return true
    }

    /// Make (or stop making) this card's Allow button the window's
    /// Return-default. While Done doesn't exist yet, Return belongs to the one
    /// live Allow; once Done appears, Done takes it.
    func setAllowIsReturnDefault(_ isDefault: Bool) {
        allowButton?.keyEquivalent = isDefault ? "\r" : ""
    }

    // MARK: Test-support hooks

    var test_title: String { titleLabel.stringValue }
    var test_hasCheckmark: Bool { checkmarkWidthConstraint.constant > 0 && checkmark.alphaValue > 0 }
    /// Whether the trailing slot is showing the lock (a step the flow hasn't
    /// reached yet).
    var test_isLocked: Bool { !lockGlyph.isHidden }
    /// The title colour, so a test can pin that a locked step is dimmed further
    /// than a completed one.
    var test_titleColor: NSColor? { titleLabel.textColor }
    var test_iconTileAlpha: CGFloat { iconTile.alphaValue }
    /// Whether the surface is drawing the active card's emphasis.
    var test_isEmphasized: Bool { surface.borderWidth > 1 }
    /// Whether a click anywhere on the card fires Allow right now.
    var test_isCardClickable: Bool { isCardClickable }
    var test_accessibilityIsButton: Bool { accessibilityRole() == .button }
    var test_accessibilityAction: String? { accessibilityHelp() }
    /// Press the CARD (not its button) exactly as AppKit/VoiceOver would.
    func test_pressCard() -> Bool { accessibilityPerformPress() }
    var test_note: String? { noteLabel.isHidden ? nil : noteLabel.stringValue }
    var test_hint: String? { hintLabel.isHidden ? nil : hintLabel.stringValue }
    var test_isBodyCollapsed: Bool { isBodyCollapsed }
    var test_isProbing: Bool { primarySlot.subviews.contains(spinner) }
    var test_offersSkip: Bool { skipButton != nil && state == .active }
    /// The titles of the buttons the card currently offers, in order.
    var test_buttonTitles: [String] {
        var titles = (primarySlot.subviews.compactMap { ($0 as? NSButton)?.title })
        if state == .active, let skip = skipButton { titles.append(skip.title) }
        if !settingsLinkButton.isHidden { titles.append(settingsLinkButton.title) }
        return titles
    }
    /// Press the demoted "Open Settings…" link exactly as the button does.
    func test_tapSettingsLink() { settingsTapped() }
    var test_allowIsReturnDefault: Bool { allowButton?.keyEquivalent == "\r" }

    func test_tapAllow() { allowTapped() }
    func test_tapSkip() { skipTapped() }
}

/// A plain clipping container: the card body lives inside one so animating the
/// clip's HEIGHT reveals/hides the content instead of resizing it.
final class ClipView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.masksToBounds = true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
