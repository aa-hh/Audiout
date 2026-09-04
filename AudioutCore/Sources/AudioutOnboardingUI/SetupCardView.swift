// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The static identity of one permission step — the parts that never change
/// with state. The TITLE is not here: it is per-state (imperative while asking,
/// earned capability once granted) and Local Network's even carries a count, so
/// ``title(for:foundSpeakers:)`` resolves it in one place instead of letting
/// each caller pick a string.
struct SetupCardContent {

    let step: SetupStep
    /// SF Symbol for the leading icon tile. Every tile shares the same neutral
    /// `raised` well + hairline rim (the fill is never coloured); only the
    /// glyph carries ``iconColor``, and the tint is permanent.
    let symbolName: String
    /// Override for a glyph SF Symbols doesn't ship (Bluetooth's rune, which
    /// stock AppKit provides as a named template instead). A template image
    /// the tile tints with ``iconColor`` exactly like a symbol; when set,
    /// ``symbolName`` is unused.
    var customIcon: NSImage? = nil
    /// This card's resting glyph tint — one of the four
    /// `Tokens.Color.permission*` hues (Bluetooth alone carries its brand
    /// blue instead — see its case).
    let iconColor: NSColor
    /// The imperative ask, shown while the card is active (and on any state
    /// that has NOT earned a checkmark — skipped, or auto-passed because the OS
    /// can't grant it). The RIBBON carries this now; the spine has its own
    /// shorter table below.
    let activeTitle: String
    /// The earned capability, shown only alongside a checkmark.
    let completedTitle: String
    /// The plain-language "why" — the ribbon's body copy. Reused verbatim from
    /// the pre-sequential rows: these strings are TCC-framing tested (they
    /// defuse the OS's "recording" wording before it appears).
    ///
    /// It is NOT shown on a first ask (owner-approved 2026-08-12): the
    /// hero leads with ``heroHeadline`` over ``whyLine`` and then shows the
    /// rehearsal, and a paragraph between them was the third thing to read
    /// before the one button. The recovery states — denied, permission-lost,
    /// a wait, a stuck dialog — still carry it, because there the words ARE
    /// the instruction.
    let detail: String
    /// The HERO's headline for this step: what pressing the button gets you,
    /// in the fewest words that still say it (owner copy deck, VERBATIM).
    /// Deliberately a third title source beside ``activeTitle`` and
    /// ``spineAskTitle`` — the hero has 418 pt and a 20 pt face, which is
    /// neither the ribbon's sentence nor the spine's label.
    let heroHeadline: String
    /// The one line under the headline: why Audiout needs it. Owner-verbatim,
    /// and the ONLY body copy a first ask shows.
    let whyLine: String
    /// First-fire call to action. It names the CAPABILITY rather than repeating
    /// the OS's "Allow" (owner copy 2026-08-12): the gold button in the bar is
    /// the app's promise, and the rehearsal beside it is where "Allow" appears.
    let allowTitle: String
    /// Whether this step offers Skip (Bluetooth and Remote Control only — both
    /// are outside `RequiredPermission`, so passing on one can't touch the gate).
    let isSkippable: Bool
    /// The SPINE's own imperative title — a short form of ``activeTitle`` that
    /// fits the 288 pt column.
    let spineAskTitle: String
    /// The SPINE's own earned title — a short form of ``completedTitle``.
    let spineDoneTitle: String


    /// The one place the per-state title table lives (brief §"Card anatomy":
    /// imperative → earned capability). The RIBBON reads this; the spine reads
    /// ``spineTitle(for:foundSpeakers:)``.
    ///
    /// `foundSpeakers` only matters for Local Network, whose completed title
    /// carries the browse's real count — "3 speakers on your network" is
    /// something the user can check. `nil` means NO browse ran at all (macOS
    /// 14, where local network isn't gated), so that copy must not imply the
    /// user did anything;
    /// a count of zero is a genuine browse that saw nothing, which since the
    /// self-discovery primer still completes the step (the PERMISSION is what
    /// was granted), so its copy says exactly that and nothing more.
    func title(for state: SetupCardState, foundSpeakers: Int? = nil) -> String {
        switch state {
        case .active, .pending, .skipped, .autoPassed:
            return activeTitle
        case .completed:
            guard step == .localNetwork else { return completedTitle }
            switch foundSpeakers {
            case nil: return "Speakers on your Wi\u{2011}Fi are already reachable"
            case 0: return "No speakers found yet \u{2014} switch one on and it'll appear"
            // "Found" read as "connected to" to the owner, who was connected to
            // none of them: the count is what DISCOVERY saw, so the copy says
            // where they are rather than what we did with them.
            case 1: return "1 speaker on your network"
            case let count?: return "\(count) speakers on your network"
            }
        }
    }

    /// The SPINE's title table — a SECOND title source, deliberately, and one
    /// that has to be kept in step with the long one above.
    ///
    /// The 288 pt spine column can't carry the ribbon's full sentences, and
    /// truncating reviewed copy is worse than writing a short form of it. Same
    /// grammar as ``title(for:foundSpeakers:)``: the earned title appears only
    /// for `.completed`, and Local Network's earned title is still the COUNT —
    /// shortened here too, because "No speakers found yet — switch one on and
    /// it'll appear" is a ribbon sentence, not a row label.
    func spineTitle(for state: SetupCardState, foundSpeakers: Int? = nil) -> String {
        switch state {
        case .active, .pending, .skipped, .autoPassed:
            return spineAskTitle
        case .completed:
            guard step == .localNetwork else { return spineDoneTitle }
            switch foundSpeakers {
            case nil: return spineDoneTitle
            case 0: return "No speakers found yet"
            case 1: return "1 speaker on your network"
            case let count?: return "\(count) speakers on your network"
            }
        }
    }
}

/// How a row renders right now — derived from ``SetupFlowModel`` by the view
/// controller, never decided here.
enum SetupCardState: Equatable {
    /// Not reached yet: LOCKED — dimmed, with the padlock in the trailing slot.
    case pending
    /// The one live step. The hero pane is showing its rehearsal, and the
    /// ribbon beneath it carries its ask and its buttons.
    case active
    /// Verified: capability title, checkmark. Browsable.
    case completed
    /// Complete only because this OS cannot grant it at all (the pre-14.2
    /// process tap). The row carries `note` where the checkmark would be —
    /// claiming a grant nobody made would be a lie.
    case autoPassed(note: String)
    /// The user passed on it. Clicking it re-arms the ask.
    case skipped
}

/// One row of the Setup window's SPINE: a compact status strip — icon tile,
/// short title, and exactly one trailing marker (padlock, checkmark, skip
/// slash, broken-permission alert, or the auto-pass note) — plus a leading edge
/// bar that marks the live row EMBER and a broken one red.
///
/// It carries no body, no buttons and no copy beyond its title (Direction 04,
/// owner-chosen): the rehearsal is the onboarding's actual idea, so the mock
/// and the ribbon of real UI beneath it own the stage, and the left column
/// shrinks to a browsable index of where you are. A row is PRESSABLE in every
/// state the user has already reached — the live one fires its primary action,
/// a decided one browses it in the hero pane, a skipped one re-arms its ask —
/// and refuses silently when locked, because the flow is sequential and jumping
/// ahead would ask for a permission out of order.
///
/// Stock AppKit only (SF Symbols, `NSImageView`, system colours) — the only
/// custom drawing is the shared `IconTileView` / `RoundedContainerView` chrome,
/// which has no stock equivalent for the System Settings grouped-inset look.
/// The row itself draws no border and no corner of its own (Direction 04
/// grouped-inset pass, owner critique): it is a full-bleed strip living inside
/// the ONE `RoundedContainerView` `OnboardingViewController.makeSpine()`
/// builds around the whole column, separated from its neighbours by a
/// hairline that container draws — the same anatomy `DemoPaneView`'s Login
/// Items mock already draws for its grouped list. A row's own state paints a
/// SELECTION FILL, never a stroke, so "current" reads as one row lit inside a
/// group rather than one card singled out among six.
final class SetupSpineRowView: NSView {

    // MARK: Metrics

    /// Inset from the row edge to its content.
    static let horizontalInset: CGFloat = 12
    /// Padding above/below the tile — with `iconSide` this IS the row height.
    static let headerVerticalInset: CGFloat = 6
    /// Icon-tile side. Smaller than the card era's: six rows plus a header have
    /// to sit in a 288 pt column without the spine ever scrolling.
    static let iconSide: CGFloat = 24
    /// Gap from the icon tile to the title.
    static let iconGap: CGFloat = 9
    /// The row's floor height — `iconSide` + both insets, stated so the check
    /// row and the permission rows can never drift apart.
    static let minHeight: CGFloat = iconSide + headerVerticalInset * 2
    /// Corner radius of the shared group container the spine's rows sit inside
    /// (`OnboardingViewController.makeSpine()`), and of the keyboard focus
    /// ring a single row draws over itself — the two are visually the same
    /// radius on purpose, since a focused first/last row's ring should read as
    /// part of the one rounded group, not a corner of its own. It is the ROW
    /// rung rather than the panel one for that same reason: the group's corner
    /// IS the first and last row's corner, so it rounds like a row.
    static let cornerRadius: CGFloat = Tokens.Layout.Radius.row
    /// The trailing marker slot: one position that says locked, then earned.
    /// Also the checkmark's grown width (the 0 → 16 slide-in).
    static let markerSlot: CGFloat = 16
    /// The leading edge bar — EMBER on the live row, red on a broken one, gone
    /// otherwise. Clipped by the surface's own corner radius.
    static let edgeBarWidth: CGFloat = 3
    /// How far a locked step's icon tile fades. Enough to read as not-yet-yours
    /// beside the live row, not so far that the glyph stops being legible.
    static let lockedTileAlpha: CGFloat = 0.5
    /// A skipped row's tile — dimmed, but less than locked: the user reached
    /// this one, they just said no.
    static let skippedTileAlpha: CGFloat = 0.55
    /// The pressable row's pointer-hover wash, in the app's shared hover colour
    /// and alpha (`PopoverColumnGrid.rowHoverWashAlpha`) so a hovered row feels
    /// like a hovered row everywhere else in the app.
    static var hoverWashFraction: CGFloat { PopoverColumnGrid.rowHoverWashAlpha }

    // MARK: Choreography timing

    /// The checkmark's slide-in: width 0 → 16 pt plus a fade, on the
    /// system-driven motion band (warm-signal-v3 §6: 180–260 ms easeOut)…
    static let checkmarkDuration: TimeInterval = 0.2
    /// …delayed by the same amount after the grant lands, so the re-fronted
    /// window has settled before anything moves on it.
    static let checkmarkDelay: TimeInterval = 0.2

    // MARK: Wiring

    private let content: SetupCardContent
    private let onPress: () -> Void

    private var iconTile: IconTileView!
    private let titleLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    /// Sits in the same trailing slot as the checkmark, for a step the flow
    /// hasn't reached: locked steps have to READ locked, not merely un-ticked.
    private let lockGlyph = NSImageView()
    /// Same slot again, for a step the user passed on.
    private let skipGlyph = NSImageView()
    /// Same slot again, for a permission that was on and is off now.
    private let brokenGlyph = NSImageView()
    /// Same slot again, for an ask this row is waiting to hear back on.
    private let spinner = NSProgressIndicator()
    /// Sits where the checkmark would, for a step this OS cannot grant.
    private let noteLabel = NSTextField(labelWithString: "")

    private var surface: RoundedContainerView!
    /// The 3 pt leading bar. A `RoundedContainerView` with no corner of its own:
    /// it re-stamps its fill per appearance for free, and the SURFACE's radius
    /// (via `masksToBounds`) is what rounds its ends.
    private var edgeBar: RoundedContainerView!
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

    private var checkmarkWidthConstraint: NSLayoutConstraint!
    private var checkmarkGeneration = 0

    private(set) var state: SetupCardState = .pending
    /// Whether this row is the flow's live step — the gold edge, the lifted
    /// surface, and the press that fires the ribbon's primary action.
    private(set) var isLive = false
    /// Whether the hero pane is currently browsing this (decided) row.
    private(set) var isBrowseSelected = false
    /// Whether this step's permission was granted and has since been switched
    /// off — the red edge and the alert marker.
    private(set) var isBroken = false
    /// Whether this row's ask is unresolved and the trailing slot is showing
    /// the spinner instead of any other marker.
    private(set) var isWaiting = false

    init(content: SetupCardContent, onPress: @escaping () -> Void) {
        self.content = content
        self.onPress = onPress
        super.init(frame: .zero)
        build()
        apply(.pending, foundSpeakers: nil, isLive: false, isBrowseSelected: false,
              isBroken: false, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        // No radius and no border of its own (owner critique, Direction 04
        // grouped-inset pass): the row is a plain full-bleed strip inside the
        // SPINE's one shared `RoundedContainerView` (built by
        // `OnboardingViewController.makeSpine()`), which owns the rounding, the
        // rim and the hairline separators between rows. A per-row border/radius
        // is exactly the "six separate cards" shape the grouped-inset list
        // replaces — masking still matters here, so the edge bar can't paint
        // past a row it belongs to.
        surface = RoundedContainerView(fill: Tokens.Color.panel, border: .clear, radius: 0)
        surface.wantsLayer = true
        surface.layer?.masksToBounds = true
        addSubview(surface)

        edgeBar = RoundedContainerView(fill: Tokens.Color.ember, border: .clear, radius: 0)
        edgeBar.borderWidth = 0
        edgeBar.isHidden = true
        surface.addSubview(edgeBar)

        iconTile = IconTileView(symbolName: content.symbolName,
                                customImage: content.customIcon,
                                accessibility: content.spineAskTitle,
                                color: content.iconColor,
                                side: Self.iconSide,
                                pointSize: 11)

        titleLabel.font = Tokens.Font.bodyEmphasized
        titleLabel.lineBreakMode = .byTruncatingTail
        // Last-resort headroom before the tail truncates — the earned titles are
        // long, and a squeeze on one machine's font metrics shouldn't eat words.
        titleLabel.allowsDefaultTighteningForTruncation = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                  accessibilityDescription: "Allowed")
        checkmark.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        checkmark.contentTintColor = Tokens.Color.gold
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.alphaValue = 0

        configureMarker(lockGlyph, symbolName: "lock.fill", accessibility: "Locked",
                        tint: Tokens.Color.tertiaryLabel)
        // razor: a skipped row is the slash glyph plus a dimmed title, NOT a
        // dashed rim. `RoundedContainerView` draws its border on the layer, and
        // a dash pattern needs a `CAShapeLayer` of its own — a whole second
        // drawing path for one state. Upgrade path: if a dashed rim is ever
        // wanted, give that view an optional shape-layer border.
        configureMarker(skipGlyph, symbolName: "slash.circle", accessibility: "Skipped",
                        tint: Tokens.Color.label2)
        configureMarker(brokenGlyph, symbolName: "exclamationmark.triangle.fill",
                        accessibility: "Turned off", tint: Tokens.Color.failure)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        noteLabel.font = Tokens.Font.caption
        noteLabel.textColor = Tokens.Color.inkSecondary
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.setContentHuggingPriority(.required, for: .horizontal)
        noteLabel.isHidden = true

        surface.addSubview(iconTile)
        surface.addSubview(titleLabel)
        surface.addSubview(checkmark)
        surface.addSubview(lockGlyph)
        surface.addSubview(skipGlyph)
        surface.addSubview(brokenGlyph)
        surface.addSubview(spinner)
        surface.addSubview(noteLabel)

        let inset = Self.horizontalInset
        let vInset = Self.headerVerticalInset
        let textLeading = inset + Self.iconSide + Self.iconGap

        checkmarkWidthConstraint = checkmark.widthAnchor.constraint(equalToConstant: 0)

        var constraints: [NSLayoutConstraint] = [
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minHeight),

            edgeBar.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            edgeBar.topAnchor.constraint(equalTo: surface.topAnchor),
            edgeBar.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            edgeBar.widthAnchor.constraint(equalToConstant: Self.edgeBarWidth),

            iconTile.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: inset),
            iconTile.topAnchor.constraint(equalTo: surface.topAnchor, constant: vInset),
            iconTile.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -vInset),

            titleLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: textLeading),
            titleLabel.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            checkmark.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            checkmark.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            checkmarkWidthConstraint,
            checkmark.heightAnchor.constraint(equalToConstant: Self.markerSlot),

            noteLabel.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            noteLabel.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            spinner.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: noteLabel.leadingAnchor, constant: -8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),
        ]
        // The three static markers share the checkmark's ONE slot: only one can
        // ever show, so they are pinned to the same trailing inset (never to
        // each other, whose widths are zero when hidden).
        for glyph in [lockGlyph, skipGlyph, brokenGlyph] {
            constraints += [
                glyph.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
                glyph.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
                glyph.widthAnchor.constraint(equalToConstant: Self.markerSlot),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: glyph.leadingAnchor, constant: -8),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func configureMarker(_ view: NSImageView, symbolName: String,
                                 accessibility: String, tint: NSColor) {
        view.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibility)
        view.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        view.contentTintColor = tint
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
    }

    // MARK: State

    /// Whether Reduce Motion is on — through the override seam every animated
    /// instrument in this codebase uses, so a headless test can drive both sides.
    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Repaint for `state`.
    ///
    /// - Parameters:
    ///   - foundSpeakers: Local Network's browse count, for the earned title.
    ///   - isLive: this row is the flow's current step — the gold edge and the
    ///     lifted surface, and a press that fires the ribbon's primary action.
    ///   - isBrowseSelected: the hero pane is showing this (decided) row.
    ///   - isBroken: this permission was granted and is off now.
    ///   - isWaiting: this row's ask is unresolved — the spinner takes the
    ///     trailing slot over every other marker.
    ///   - animated: run the grant choreography (the checkmark slide-in).
    ///     Callers pass false for the first build, Reduce Motion, and any
    ///     off-window/occluded window — steady states must render settled or
    ///     snapshots stop being deterministic.
    func apply(_ state: SetupCardState,
               foundSpeakers: Int?,
               isLive: Bool,
               isBrowseSelected: Bool,
               isBroken: Bool,
               isWaiting: Bool = false,
               animated: Bool) {
        let wasCompleted = isCheckmarked(self.state)
        self.state = state
        self.isLive = isLive
        self.isBrowseSelected = isBrowseSelected
        self.isBroken = isBroken
        self.isWaiting = isWaiting

        titleLabel.stringValue = content.spineTitle(for: state, foundSpeakers: foundSpeakers)
        // A step the flow hasn't reached is LOCKED and must read locked: dimmed
        // text and tile, plus the padlock below. Every state the user HAS
        // reached keeps authored secondary ink, which clears the 4.5:1 text
        // floor in both appearances where the system alias did not.
        titleLabel.textColor = switch state {
        case .active: Tokens.Color.label
        case .pending: Tokens.Color.tertiaryLabel
        case .completed, .autoPassed, .skipped: Tokens.Color.inkSecondary
        }
        // Dimming is the tile's ONLY state role: its glyph tint is permanent,
        // and the trailing marker is what says "earned".
        iconTile.alphaValue = switch state {
        case .pending: Self.lockedTileAlpha
        case .skipped: Self.skippedTileAlpha
        case .active, .completed, .autoPassed: 1
        }

        if case .autoPassed(let note) = state {
            noteLabel.stringValue = note
            noteLabel.isHidden = false
        } else {
            noteLabel.isHidden = true
        }

        // One trailing slot, one occupant — the spinner outranks every other
        // marker while waiting (the user just acted; broken/locked/skipped
        // yield to it), and a broken permission outranks the rest otherwise,
        // because it is the only one asking for something.
        lockGlyph.isHidden = isWaiting || isBroken || state != .pending
        skipGlyph.isHidden = isWaiting || isBroken || state != .skipped
        brokenGlyph.isHidden = isWaiting || !isBroken
        applyCheckmark(shown: !isWaiting && !isBroken && isCheckmarked(state),
                       animated: animated && !wasCompleted && isCheckmarked(state))
        if isWaiting && !reduceMotion { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        applySurface()
        applyAccessibility()
        // Pressability comes and goes with the state, and the cursor rect with it.
        window?.invalidateCursorRects(for: self)
    }

    /// Fill and edge bar by state — a SELECTION FILL inside the shared group,
    /// never a per-row border (owner critique, Direction 04 grouped-inset
    /// pass: six individually bordered cards with gaps between them read as a
    /// generic wizard, not the macOS grouped-inset list `DemoPaneView`'s own
    /// Login Items mock already draws correctly).
    ///
    /// The live row is the one lifted off the group's own `panel` fill, and it
    /// is lifted with a GOLD WASH at ``PopoverColumnGrid/rowLiveWashAlpha`` —
    /// 12 %, the same alpha every sounding device row in the popover paints,
    /// measured 1.256:1 on dark `panel` and 1.140:1 on the light ground. The
    /// 2026-08-12 ruling that made this row ember rather than gold (gold was
    /// spent entirely on the ONE button the step wants pressed, and a gold bar
    /// on the spine competed with it across the window) is superseded by
    /// decisions F4 and R4 of the design migration,
    /// `dev/notes/design-migration-scoping/01-decisions.md`: live is one gold
    /// wash everywhere in the app, so this row says what a sounding device row
    /// says. The ember EDGE BAR the old reading also carried does not come
    /// back with it. A BROKEN row overrides the wash with the failure hue,
    /// because it is the only row asking to be looked at. The browse selection
    /// is its own neutral tinted fill — browsing is a reading position, not a
    /// change of state, so it never stacks with the live/broken tint, only
    /// with hover.
    ///
    /// Every blend goes through ``dynamicBlend(_:fraction:of:)``: blending a
    /// dynamic token in place would flatten it to whichever appearance happened
    /// to be current, which is exactly the 1.13:1 dark rim the critique
    /// measured on the old active card.
    private func applySurface() {
        var fill = Tokens.Color.panel

        if isBroken {
            fill = dynamicBlend(Tokens.Color.panel, fraction: 0.08, of: Tokens.Color.failure)
        } else if isLive {
            fill = dynamicBlend(Tokens.Color.panel,
                                fraction: PopoverColumnGrid.rowLiveWashAlpha,
                                of: Tokens.Color.gold)
        } else if isBrowseSelected {
            fill = dynamicBlend(Tokens.Color.panel, fraction: 0.16,
                                of: NSColor.selectedContentBackgroundColor)
        }
        if isHovered, isPressable {
            fill = dynamicBlend(fill, fraction: Self.hoverWashFraction,
                                of: NSColor.selectedContentBackgroundColor)
        }

        surface.fill = fill

        // The bar is the FAILURE mark, and nothing else. A live row is already
        // the one carrying the selection fill inside the group, so an ember
        // rule beside it said the same thing twice — and a coloured leading
        // edge is not a shape macOS's own grouped lists draw (owner,
        // 2026-08-13). A broken row keeps it: that row is asking to be looked
        // at, which the fill alone does not say.
        edgeBar.isHidden = !isBroken
        edgeBar.fill = Tokens.Color.failure
    }

    /// Whether this state has EARNED a checkmark. Only a real verification
    /// does: an auto-pass carries a note instead, and a skipped step stays
    /// visibly unfinished.
    private func isCheckmarked(_ state: SetupCardState) -> Bool { state == .completed }

    /// The checkmark's width-0 → 16 pt slide plus fade, delayed after the grant
    /// (Wispr's exact figures — see the brief's "Wispr reference"). Instant
    /// whenever the choreography is off; every other marker swap is instant by
    /// construction, there being no clip height left to animate.
    private func applyCheckmark(shown: Bool, animated: Bool) {
        checkmarkGeneration += 1
        guard animated else {
            checkmarkWidthConstraint.constant = shown ? Self.markerSlot : 0
            checkmark.alphaValue = shown ? 1 : 0
            return
        }
        checkmarkWidthConstraint.constant = 0
        checkmark.alphaValue = 0
        let generation = checkmarkGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkmarkDelay) { [weak self] in
            guard let self, self.checkmarkGeneration == generation,
                  self.isCheckmarked(self.state) else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.checkmarkDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                self.checkmarkWidthConstraint.animator().constant = Self.markerSlot
                self.checkmark.animator().alphaValue = 1
                self.layoutSubtreeIfNeeded()
            }
        }
    }

    // MARK: Interaction

    /// Whether a click on this row does anything. The live row fires its primary
    /// action, a granted one browses it in the hero pane, a skipped one re-arms
    /// its ask. Two states are not pressable: a LOCKED row (the flow is
    /// sequential, and jumping ahead would ask for a permission out of order),
    /// and an AUTO-PASSED one (its permanent note is the whole story, and there
    /// is no honest hero for a grant macOS cannot make). Both refuse SILENTLY
    /// (owner decision: no padlock shake — a refusal that animates invites a
    /// second try).
    var isPressable: Bool {
        // A BROKEN row is the one row on the spine asking to be looked at, so
        // it is pressable whatever state it is otherwise in — pressing it snaps
        // the flow to it. Ahead of the switch, because the state it wears
        // (usually `.pending`) would otherwise refuse the click.
        if isBroken { return true }
        switch state {
        case .pending, .autoPassed: return false
        // The live row IS its primary button. Safe for every step, because no
        // step's primary is itself a decision any more: each one raises a
        // surface the user still has to answer — macOS's dialog for the five
        // permissions, Audiout's own Share / Don't Share sheet for Usage
        // Statistics. Usage Statistics briefly granted on the click instead,
        // and this row is where that reached the user (owner, live: "clicking
        // on the line item accepts, even though the person might not actually
        // be meaning to").
        case .active: return isLive
        case .completed, .skipped: return true
        }
    }

    /// A pressable row must act on the click that ACTIVATES the app — same rule
    /// as `ProminentButton.acceptsFirstMouse` (the bounce-to-Settings-and-back
    /// loop returns the user to an inactive app, where a stock view spends the
    /// first click on activation). A locked row refuses the click either way,
    /// so it keeps stock behaviour.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isPressable }

    /// AppKit hit-tests the deepest view first, so nothing inside the row can
    /// swallow this — the spine has no sub-controls left at all.
    override func mouseUp(with event: NSEvent) {
        guard isPressable else { super.mouseUp(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { super.mouseUp(with: event); return }
        onPress()
    }

    /// Swallow the press half too, so the row doesn't pass an unhandled
    /// mouseDown up to whatever is behind it while it's acting as a button.
    override func mouseDown(with event: NSEvent) {
        guard isPressable else { super.mouseDown(with: event); return }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isPressable else { return }
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

    // MARK: Keyboard

    /// A row that can be clicked can be tabbed to and pressed — the spine is
    /// the window's only navigation, so it cannot be mouse-only.
    override var acceptsFirstResponder: Bool { isPressable }

    override func keyDown(with event: NSEvent) {
        guard isPressable else { super.keyDown(with: event); return }
        switch event.charactersIgnoringModifiers {
        case " ", "\r": onPress()
        default: super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds,
                     xRadius: Self.cornerRadius,
                     yRadius: Self.cornerRadius).fill()
    }

    // MARK: Accessibility

    /// The row IS the button as far as VoiceOver is concerned, named for what
    /// pressing it does. A locked row is a plain group — its press would be
    /// refused, and offering it would be a lie. The LABEL carries the state
    /// too: the trailing marker is the only thing that distinguishes an allowed
    /// row from a skipped one on screen, and a marker VoiceOver can't see is a
    /// marker that isn't there.
    private func applyAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(isPressable ? .button : .group)
        setAccessibilityLabel(titleLabel.stringValue + stateSuffix)
        setAccessibilityHelp(accessibilityAction)
    }

    private var stateSuffix: String {
        if isWaiting { return ", waiting" }
        if isBroken { return ", turned off \u{2014} needs attention" }
        switch state {
        case .active: return ""
        case .pending: return ", locked"
        case .completed: return ", allowed"
        // An auto-pass is NOT a grant, and saying "allowed" for one hid the
        // whole reason it passed. The visible note is the explanation; this is
        // the same words, lower-cased into the sentence the label already is.
        case .autoPassed(let note): return ", " + note.prefix(1).lowercased() + note.dropFirst()
        case .skipped: return ", skipped"
        }
    }

    /// What pressing does: the live row runs its ask, a decided one opens it in
    /// the hero pane. Nothing for a locked row, which refuses.
    private var accessibilityAction: String? {
        guard isPressable else { return nil }
        return isLive ? content.allowTitle : "Show"
    }

    override func accessibilityPerformPress() -> Bool {
        guard isPressable else { return false }
        onPress()
        return true
    }

    // MARK: Test-support hooks

    var test_title: String { titleLabel.stringValue }
    var test_hasCheckmark: Bool { checkmarkWidthConstraint.constant > 0 && checkmark.alphaValue > 0 }
    /// Whether the trailing slot is showing the padlock (a step the flow hasn't
    /// reached yet).
    var test_isLocked: Bool { !lockGlyph.isHidden }
    /// Whether the trailing slot is showing the skip slash.
    var test_isSkipped: Bool { !skipGlyph.isHidden }
    /// Whether the row is drawing the broken-permission treatment.
    var test_isBroken: Bool { isBroken }
    /// Whether the trailing slot is showing the waiting spinner.
    var test_isWaiting: Bool { isWaiting }
    /// Overrides the live Reduce Motion read for the waiting spinner, so a
    /// headless test can drive both sides deterministically.
    var test_reduceMotionOverride: Bool?
    /// Whether the waiting spinner is actually animating right now — distinct
    /// from ``test_isWaiting``, which is the logical state Reduce Motion must
    /// not silence.
    var test_spinnerIsAnimating: Bool { isWaiting && !reduceMotion }
    /// Whether the hero pane is browsing this row.
    var test_isBrowseSelected: Bool { isBrowseSelected }
    /// The leading edge bar's fill, or nil when no bar is drawn — the ember-not-
    /// gold rule has no other headless signal.
    var test_edgeBarFill: NSColor? { edgeBar.isHidden ? nil : edgeBar.fill }
    /// The title colour, so a test can pin that a locked step is dimmed further
    /// than a completed one.
    var test_titleColor: NSColor? { titleLabel.textColor }
    var test_iconTileAlpha: CGFloat { iconTile.alphaValue }
    /// The tile's glyph tint — the row's `iconColor` in EVERY state.
    var test_iconTint: NSColor? { iconTile.test_restingTint }
    /// Whether a click on the row does anything right now.
    var test_isPressable: Bool { isPressable }
    var test_accessibilityIsButton: Bool { accessibilityRole() == .button }
    var test_accessibilityAction: String? { accessibilityHelp() }
    var test_accessibilityLabel: String? { accessibilityLabel() }
    /// Press the ROW exactly as AppKit/VoiceOver would.
    func test_pressCard() -> Bool { accessibilityPerformPress() }
    var test_note: String? { noteLabel.isHidden ? nil : noteLabel.stringValue }
}
