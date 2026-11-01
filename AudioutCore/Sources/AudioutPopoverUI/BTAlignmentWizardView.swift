// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The alignment wizard's window content (wizard-stage v2 spec §3/§4): one
/// FIXED chassis — title row, ``AlignmentStageView``, readout caption —
/// with only the bottom band changing per
/// ``BTAlignmentWizardSession/Screen``. The stage sits at the same y on every
/// screen, so a run never reflows under the user.
///
/// Three ownership boundaries the file depends on and never re-decides:
///
/// - **The ladder owns the words.** The readout's status word is
///   `stage.rung.word`, read AFTER `stage.apply`. This view computes no
///   half-width thresholds of its own — a word boundary and a look boundary
///   are physically the same constant, in ``AlignmentStageView/Rung``.
/// - **Identity color names WHICH speaker, never state.** The target plate
///   wears `wireCore`, the reference plate `ring` (the target's Deep
///   companion / `ring`'s own light hex at 0.9 in light mode) — resolved
///   HERE, per `effectiveAppearance`,
///   and handed to the plate cell, which never picks a hue itself. Gold
///   stays the app's "is it live" voice and is spent only on the one primary
///   plate per screen.
/// - **The click count is an aside to the TITLE.** It rides the title row's
///   right slot alongside the intro's cost note, never the content stack.
///
/// The view is sized by its HOST sheet, not by a card stack: it holds one
/// fixed content width and republishes its height through
/// ``onContentSizeChange``. It has no ✕ — a sheet carries no close chrome, so
/// Stop, Done and Esc are the way out. This view owns the SESSION
/// driving (start/answer/accept/tryAgain) but not its lifetime — the HOST
/// creates the session, mounts this view, and tears both down (`onFinished`)
/// so the tick can never outlive the surface.
public final class BTAlignmentWizardView: NSView {

    /// One entry in the reference picker: another available speaker the target
    /// can be compared against.
    public struct ReferenceOption: Equatable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    // MARK: The locked copy (spec §4 — exact strings)

    static let introCopy =
        "You’ll hear a click from each speaker. Tap the one you hear first."
    /// The same sentence when the two speakers really do make DIFFERENT sounds
    /// — a Bluetooth speaker against the Mac or an AirPlay one, which is every
    /// run on the default reference. The cue has been in the audio since
    /// roadmap 056 and was never advertised, and naming it is the cheapest
    /// distinguishability win available (`dev/notes/wizard-tick-stimulus-brief.md`
    /// §5.2). Named per SIDE, never assumed: the timbre follows the TRANSPORT,
    /// so a Mac target and a Bluetooth reference is the same sentence the other
    /// way round. Target first, matching the answer plates' own left-to-right
    /// order. Bluetooth-against-Bluetooth makes ONE sound on both sides and
    /// keeps ``introCopy`` verbatim.
    static func introCopyNamingSounds(target: String, targetIsBluetooth: Bool,
                                      reference: String) -> String {
        let targetSound = targetIsBluetooth ? highSound : lowSound
        let referenceSound = targetIsBluetooth ? lowSound : highSound
        return "You’ll hear \(targetSound) from \(target) and \(referenceSound) "
            + "from \(reference). Tap the one you hear first."
    }
    /// The two timbres in the user's words. Plain description, no instrument
    /// voice: they are sounds in the room, not readings.
    private static let highSound = "a higher note"
    private static let lowSound = "a lower note"
    /// The old "Can't tell", renamed because it is no longer a shrug: a
    /// posterior treats "both at once" as evidence that the offset is inside
    /// the ear's fusion window, which is the direct answer to "it sounded
    /// perfect to me but I had no way of saying so". Worded as a REPLY to
    /// ``questionPrompt`` — the two name plates answer "which clicked first?"
    /// by naming a speaker, so the third has to answer it too. "They sound
    /// together" answered a question the screen wasn't asking.
    ///
    /// `public` for the same reason ``test_setPlatePressed(titled:_:)`` is:
    /// the `wizard-snapshot` tool presses this plate by title, and a copy of
    /// the string there would silently shoot an unpressed screen the day the
    /// title changes.
    public static let togetherTitle = "Both at once"
    /// The way OUT, spelled out. The 9.5 pt ✕ was the only exit and the live
    /// run never found it ("no way to exit").
    static let stopTitle = "Stop"
    static let soundsRightTitle = "Sounds right"
    static let stillOffTitle = "Still off"
    /// The manual path — typing a number or tapping the paddles in the SYNC
    /// control. Offered beside a proposal the listener doesn't like and on the
    /// unsettled bow-out, never as the default.
    static let setByHandTitle = "Set it manually"
    static let tryAgainTitle = "Try again"
    static let unsettledCopy =
        "Your answers aren’t settling on one value. "
        + "Moving closer to the speakers usually helps."
    /// The host-driven bow-out for a target that vanished mid-run — see
    /// ``showTargetLost()``.
    static func targetLostCopy(target: String) -> String { "\(target) went away." }
    /// The run reached the end of what this control can do. Prior trim back.
    /// "manually", not "by hand": the same act the ``setByHandTitle`` button
    /// names, so the prose and the button cannot read as two different
    /// escapes. The apostrophe is the typographic one every other line on
    /// these three screens uses.
    static let unreachableCopy =
        "Couldn’t find the alignment. Try moving closer to the speakers, "
        + "or set the delay manually from the SYNC control."
    /// The third failure, and the one the run has to say out loud rather than
    /// round away: the answers put the speaker AHEAD of the Mac, which the Mac
    /// being the zero makes impossible. Nothing is stored. The screen now
    /// carries a real Try again button, so the copy no longer has to offer one
    /// in prose (spec §1).
    static let macIsLateCopy =
        "Couldn’t get a clean reading. This Mac sounded later than the speaker, "
        + "which shouldn’t happen. Try again."
    /// The question, on the question screen — the one decision the run
    /// hangs on, asked ~15 times, so it stays in front of the user.
    static let questionPrompt = "Which clicked first?"
    /// How sure the run is, in the units the user is actually judging — the
    /// stage's tooltip, where the number is available without being the
    /// headline.
    static func confidenceCopy(_ intervalMs: ClosedRange<Double>) -> String {
        "Somewhere between \(signedMs(intervalMs.lowerBound)) "
        + "and \(signedMs(intervalMs.upperBound)) ms"
    }
    /// A real minus sign (U+2212), not a hyphen — "-8" reads as a bug.
    private static func signedMs(_ ms: Double) -> String {
        String(Int(ms.rounded())).replacingOccurrences(of: "-", with: "−")
    }
    /// Where the run is — the title line's right slot during the questions. A
    /// run has no fixed length, so the total is "about". Sentence case, plain
    /// system caption: it is an aside to the title beside it, not a second
    /// piece of instrument chrome (owner ruling 2026-08-24).
    static func clickCountCopy(_ click: Int) -> String { "Click \(click) of about 15" }
    /// Shown in the reference line's place while no second speaker can be
    /// established — Start stays disabled until one is.
    static let noReferenceCopy = "Select another speaker to compare against"
    /// The picker field's label. It carries NO device name — the sheet title
    /// already says `Align <target>` and the stage stamps both names under
    /// their lights, so a third printing bought nothing and cost the field its
    /// measure (a real speaker name pushed the label past 400 pt). Matches
    /// ``soleReferenceCopy(name:)`` word for word, so the choice case and the
    /// stated case read as the same line with and without a control.
    static let compareLabel = "Compare against"
    /// The one-option case: nothing to choose, so the line states the fact
    /// rather than mounting a picker with a single item in it (spec §1).
    private static func soleReferenceCopy(name: String) -> String {
        "Compare against \(name)"
    }

    /// The proposal's whole instruction — the NUMBER moved to the readout, so
    /// the sentence is free to be about listening.
    private static let proposalBody = "Listen: the clicks should land as one."
    /// The finale's headline: the speaker is ready, and plays with everything.
    static func keptReadyCopy(target: String) -> String {
        "\(target) is ready to play with everything."
    }
    /// A Bluetooth run wrote a MEASURED LATENCY; the number is the stage's
    /// caption, and this quiet line says where to change it later.
    private static let keptLatencyCaption = "Change it anytime from the SYNC control."
    /// The Mac's own row has no second store: its trim IS the kept value.
    /// Both captions point at the SYNC control because both values are edited
    /// there — the Mac's row carries the identical chip and drawer. "the
    /// popover" named nothing the user can see on screen (it is our word for
    /// the window, not theirs), and it was the app's only user-facing use of
    /// it.
    private static let keptLocalCaption = "Change it anytime from the SYNC control."
    /// What the run costs, before it starts — the title line's right slot on
    /// the intro, where the click count lives once the run is under way.
    private static let introSlotText = "About 15 clicks"

    // MARK: The iPhone link

    /// The title row's trailing link on the intro: the way to Audiout Remote's
    /// App Store page. A quiet text button, never gold and never a panel —
    /// the page's job is the Mac's own run, and a QR column in the middle of
    /// it read as an advert (owner ruling 2026-11-01).
    static let remoteLinkTitle = "Measure with your iPhone"
    /// The trailing panel's heading when the two speakers make ONE sound and
    /// there is no automatic mic path — the Mac's own by-ear run, named the one
    /// thing it is (the glossary in `audiout-shared/CONTEXT.md`). The automatic
    /// path uses ``autoPanelTitle`` instead.
    static let byEarPanelTitle = "Align by ear"
    /// The sheet's TITLE, on every screen — the plain sentence-form heading a
    /// sheet gets everywhere else in the app (`GroupCreationSheetController`'s
    /// "Add scene", `Tokens.Font.bodyEmphasized` at full `label`). It replaced
    /// a tracked all-caps `ALIGN · <NAME>` mono nameplate (owner ruling
    /// 2026-08-24): that voice is the app's instrument chrome, and spending it
    /// on the sheet's own heading made the wizard read as a readout panel
    /// rather than a thing the user is doing.
    private static func wizardTitle(target: String) -> String { "Align \(target)" }
    /// The readout on the kept screen — crossfaded in when the stage's lock
    /// sequence settles, over the proposal's own bare number.
    private static func keptReadout(valueMs: Int) -> String { "\(valueMs) ms · kept" }

    // MARK: Copy awaiting the owner's eye (2026-09-13)

    /// The intro's heading when the Mac can measure through its own mic
    /// (``BTAlignmentWizardSession/listeningIsPossible``): the run asks for
    /// nothing until the mic fails to get a read, so it is billed as what it
    /// is, with no word of a fallback until one happens (owner ruling
    /// 2026-11-01). Where the two speakers make one sound
    /// there is no mic path and the user really does tap, so that page keeps
    /// ``byEarPanelTitle``.
    static let autoPanelTitle = "Hands-free alignment"
    /// The lead line on the automatic path: what the Mac does the moment Start
    /// is pressed, which is also why the mic prompt is expected rather than a
    /// surprise.
    static let autoLeadCopy =
        "This Mac measures the offset itself using its built-in microphone."
    /// The first question after the mic spent its budget without a read
    /// (``BTAlignmentWizardSession/listeningFailed``) — and only then: the
    /// intro promises a hands-free run and does not hedge it. The naming half
    /// is spliced from ``introCopyNamingSounds`` verbatim so the two can never
    /// drift — lower-cased at the seam because it follows a dash.
    static let listeningFailedLead = "The microphone couldn’t get a clear read."
    static func listeningFailedCopy(target: String, targetIsBluetooth: Bool,
                                    reference: String) -> String {
        let naming = introCopyNamingSounds(target: target,
                                           targetIsBluetooth: targetIsBluetooth,
                                           reference: reference)
        return listeningFailedLead + " Match it by ear — "
            + naming.prefix(1).lowercased() + naming.dropFirst()
    }
    /// The listening screen's headline — the focal point of a screen that is
    /// measuring on its own and asking the user for nothing. First-alignment
    /// and realignment variants; the realign one says a value already exists.
    static let listeningHeadlineFirst = "Listening to your speakers"
    static let listeningHeadlineRealign = "Checking your last alignment"
    /// The supporting line under the headline, the same for both variants:
    /// what the Mac is doing, and the one thing the room can do to help.
    static let listeningBody =
        "Each speaker plays a low tone that slides down over a soft chord, one after the other. "
        + "Your Mac is timing them with its built-in microphone. Keep the room quiet."
    /// A proposal RECALLED from a previous run, reached only when the mic
    /// never listened — nothing was measured, so the number is a question.
    static func recalledProposalCopy(valueMs: Int) -> String {
        "Last time it was \(valueMs) ms. Still right?"
    }
    static func recalledReadout(valueMs: Int) -> String { "\(valueMs) ms · last time" }

    // MARK: Host seams

    /// The wizard finished (Done, Stop, or the window's ✕): the host closes the
    /// window and disposes of the session.
    var onFinished: (() -> Void)?

    /// The unsettled screen's "Set it by hand", carrying the run's best guess
    /// so the host can open the row's SYNC drawer on it. Fired BEFORE
    /// ``onFinished``.
    var onSetByHand: ((Double) -> Void)?

    /// The user picked a different reference. The HOST owns the consequences —
    /// engaging the new speaker, releasing the old, and telling the session to
    /// restart — because only it can touch the selection.
    var onSelectReference: ((String) -> Void)?

    /// A screen changed, so the content's height did too. The host window
    /// re-fits itself around it.
    var onContentSizeChange: (() -> Void)?

    /// Opens the iPhone link. Replaced by tests so a click opens nothing.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// The picker's menu, pushed by the host on every reconcile so devices
    /// coming and going are reflected. Repaints only on a real change.
    public var referenceOptions: [ReferenceOption] = [] {
        didSet {
            guard referenceOptions != oldValue else { return }
            render(session.screen)
        }
    }

    /// Where the phone app stands — pushed by the host, the way
    /// ``referenceOptions`` is, because only the app layer can see the Allow
    /// switch and the companion server's clients. The intro reads only
    /// whether it is `unavailable`, which hides the iPhone link.
    public enum RemoteInviteState: Equatable {
        /// This build does not carry Audiout Remote at all
        /// (`AppSettings.remoteAppIsOffered`), so the intro offers no link to
        /// an app nobody can download.
        case unavailable
        /// Allow control from iPhone resolves off (setting or launch option).
        case allowOff
        /// Allow is on and no phone has connected: the code and the address.
        case notConnected
        /// A phone is connected. The name is the approval's `lastKnownName`,
        /// and `nil` whenever the Mac cannot say which phone it is.
        case connected(phoneName: String?)
    }

    /// Repaints the intro when it changes, so the link appears or goes with
    /// the build's phone app.
    public var remoteInvite: RemoteInviteState = .notConnected {
        didSet {
            guard remoteInvite != oldValue else { return }
            if case .intro = session.screen { render(session.screen) }
        }
    }

    private let session: BTAlignmentWizardSession
    /// The picker is INTRO-ONLY (spec §1): it is disabled once the run leaves
    /// the intro, which locks the reference for the rest of the run.
    private let referencePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The picker's full-measure width — see ``addReferenceRow``.
    private lazy var referencePopUpWidth: NSLayoutConstraint =
        referencePopUp.widthAnchor.constraint(equalToConstant: Self.bodyMeasure)
    private weak var referenceLineLabel: NSTextField?
    private weak var startPlate: AlignmentPlateButton?
    /// The three answer plates ←/→/SPACE route through: a key press does a
    /// real `performClick`, so the plate visibly depresses.
    private weak var targetPlate: AlignmentPlateButton?
    private weak var referencePlate: AlignmentPlateButton?
    private weak var togetherPlate: AlignmentPlateButton?
    /// The unsettled screen's best guess, held for the "Set it by hand"
    /// button — a target/action selector carries no payload.
    private var pendingBestGuessMs: Double?

    // MARK: Geometry (spec §3)

    /// The host window is a fixed 560 wide with 28 pt horizontal insets; this
    /// is what is left for the wizard itself.
    private static let viewWidth: CGFloat = 504
    private static let contentPadding: CGFloat = 0
    private static var contentWidth: CGFloat { viewWidth - 2 * contentPadding }
    /// The spacing scale: 4 / 12 / 16 / 28, where 28 is the ONE band break per
    /// screen (under the readout).
    private static let spacingTight: CGFloat = 4
    private static let spacingRow: CGFloat = 12
    private static let spacingGroup: CGFloat = 16
    private static let spacingBand: CGFloat = 28

    /// The title line: a `bodyEmphasized` heading needs real leading, where
    /// the 8.5 pt mono nameplate it replaced fitted in 14.
    private static let titleRowHeight: CGFloat = 18
    private static let readoutHeight: CGFloat = 15
    private static let plateWidth: CGFloat = 220
    private static let plateHeight: CGFloat = 64
    /// 220 + 64 + 220 = the full content width, so an edge-anchored pair lands
    /// exactly on the two edges with no spacer views.
    private static let plateGap: CGFloat = 64
    /// The two ANSWER plates are the screen's hero (owner ruling 2026-08-23):
    /// 236 + 32 + 236 fills the width, 88 tall, with a larger title.
    private static let answerPlateWidth: CGFloat = 236
    private static let answerPlateHeight: CGFloat = 88
    private static let answerPlateGap: CGFloat = 32
    /// The intro's one centred panel, at the body measure every other
    /// centred paragraph on the sheet uses.
    private static let introPanelWidth: CGFloat = bodyMeasure
    /// The unsettled screen's three-up: 160 × 3 + 12 × 2 also fills the width.
    private static let narrowPlateWidth: CGFloat = 160
    private static let togetherBarWidth: CGFloat = 400
    private static let togetherBarHeight: CGFloat = 36
    /// Minimum hit height for the corner row's real buttons.
    private static let cornerButtonHeight: CGFloat = 24
    /// Body copy wraps at the together bar's width, so a long line becomes
    /// two centred lines rather than one 470 pt run.
    private static let bodyMeasure: CGFloat = togetherBarWidth

    // MARK: The fixed chassis

    let stage = AlignmentStageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let clickCountLabel = NSTextField(labelWithString: "")
    /// The intro's iPhone link, sharing the title row's right slot with the
    /// click count — never both at once: the count starts after the intro.
    private lazy var remoteLink = makeCornerButton(Self.remoteLinkTitle,
                                                   #selector(remoteLinkClicked(_:)))
    /// The stage's accessible caption — a REAL text field, never layer text.
    private let readout = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()
    /// The band under the readout holds the per-screen content one of two
    /// ways, and exactly one of these is ever active. Centred is the default
    /// (a short bow-out floats in the middle of the slack rather than leaving
    /// a hole under it); the INTRO pins to the top instead — its own content
    /// is short enough that centring dropped the opening sentence into the
    /// middle of the sheet, well below where the eye lands off the stage.
    /// The readout's own height, which goes to ZERO on the four screens that
    /// print no caption. The stage does not move — the readout hangs BELOW it
    /// — so this only closes the gap under the instrument, and closing it is
    /// what lifts the intro's opening sentence out of the middle of the sheet:
    /// an empty 15 pt row plus the 28 pt band break put 55 pt of nothing
    /// between the stage and the first word.
    private var readoutHeightConstraint: NSLayoutConstraint!
    private var readoutTopConstraint: NSLayoutConstraint!
    /// The listening screen's progress bar and the timer that fills it from
    /// the probe's start; both nil on every other screen.
    private var probeProgress: NSProgressIndicator?
    private var probeProgressTimer: Timer?

    public init(session: BTAlignmentWizardSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: 0))
        buildChrome()
        session.onScreenChange = { [weak self] screen in
            self?.render(screen)
            // Only arriving on listening (the first listen or a retry, which
            // goes listening → listening) sends the lights home; a repaint of
            // the same screen, such as a picker refresh, keeps their verdicts.
            if case .listening = screen { self?.stage.resetListening(animated: true) }
        }
        session.onProbeStarted = { [weak self] in self?.startProbeProgress() }
        session.onProbeSpeakerChecked = { [weak self] speaker, heard in
            self?.stage.setListeningPhase(heard ? .heard : .missed, for: speaker, animated: true)
        }
        render(session.screen)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Stop or Esc while listening changes no screen, so `render` never
    /// stops the progress timer; the view going away must.
    deinit { stopProbeProgress() }

    // MARK: Chrome

    private func buildChrome() {
        translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(remoteLink)
        for label in [titleLabel, clickCountLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            // MANDATORY on the RIGHT slot and harmless on the left: a label
            // left in the default multi-line mode publishes no HORIZONTAL
            // content-size constraint, so Auto Layout is free to hand it zero
            // width — and a slot pinned on ONE edge only then renders at the
            // 4 pt empty-field bearing and is simply not on screen.
            label.usesSingleLineMode = true
            titleRow.addSubview(label)
        }
        titleLabel.font = Tokens.Font.bodyEmphasized
        titleLabel.textColor = Tokens.Color.label
        clickCountLabel.font = Tokens.Font.caption
        clickCountLabel.textColor = Tokens.Color.label2
        clickCountLabel.alignment = .right
        // The two slots are pinned to OPPOSITE edges of a plain container,
        // so nothing but this stops a long device name running straight under
        // `Click n of about 15` or the iPhone link — labels overprinting each
        // other. The name is the half that gives way: the right slot is
        // fixed-width chrome and always says the same thing.
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)

        // The stage is PERSISTENT: `render` re-points it at a new state but
        // never tears it down, or every screen change would restart the
        // instrument the run's continuity is drawn on. Same for the readout —
        // the kept line CROSSFADES over the proposal's number.
        stage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stage)

        readout.translatesAutoresizingMaskIntoConstraints = false
        styleReadout(hero: false)
        readout.alignment = .center
        addSubview(readout)

        referencePopUp.translatesAutoresizingMaskIntoConstraints = false
        // REGULAR size, stock bezel — this is one of the intro's two actions,
        // and the same control the mixer's Main Out destination is. At
        // `.small` in the caption voice it read as punctuation inside a
        // sentence (see ``addReferenceRow``).
        referencePopUp.controlSize = .regular
        referencePopUp.font = Tokens.Font.body
        referencePopUp.setAccessibilityLabel("Compare against")

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        // Every band is centred: the plate rows span the full width by their
        // own arithmetic, the copy and the lone plates sit on the midline.
        contentStack.alignment = .centerX
        contentStack.spacing = Self.spacingGroup
        addSubview(contentStack)
        addSubview(titleRow)
        readoutTopConstraint = readout.topAnchor.constraint(
            equalTo: stage.bottomAnchor, constant: Self.spacingRow)
        readoutHeightConstraint = readout.heightAnchor.constraint(
            equalToConstant: Self.readoutHeight)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.viewWidth),

            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: Self.contentPadding),
            titleRow.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.contentPadding),
            titleRow.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.contentPadding),
            titleRow.heightAnchor.constraint(equalToConstant: Self.titleRowHeight),
            titleLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            clickCountLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            // FIRST BASELINE, not centre — the same rule the corner rows' key
            // chips follow: the caption's type is 2 pt smaller than the
            // title's, and centring two sizes drops the smaller one's baseline
            // below the larger's, which reads as a subscript.
            clickCountLabel.firstBaselineAnchor.constraint(
                equalTo: titleLabel.firstBaselineAnchor),
            remoteLink.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            remoteLink.firstBaselineAnchor.constraint(
                equalTo: titleLabel.firstBaselineAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: clickCountLabel.leadingAnchor,
                constant: -Self.spacingRow),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: remoteLink.leadingAnchor,
                constant: -Self.spacingRow),

            stage.topAnchor.constraint(
                equalTo: titleRow.bottomAnchor, constant: Self.spacingGroup),
            stage.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.contentPadding),
            stage.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.contentPadding),
            stage.heightAnchor.constraint(equalToConstant: AlignmentStageView.stageHeight),

            readoutTopConstraint,
            readout.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.contentPadding),
            readout.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.contentPadding),
            readoutHeightConstraint,

            // Every screen hugs its own content: the band sits one band break
            // under the readout and the sheet ends where the band does. The
            // stage stays put across screens; only the sheet's bottom edge
            // moves. A fixed question-screen height used to float the short
            // screens in the middle of empty chassis (owner, 2026-11-01).
            contentStack.topAnchor.constraint(
                equalTo: readout.bottomAnchor, constant: Self.spacingBand),
            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.contentPadding),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.contentPadding),
            contentStack.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -Self.contentPadding),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    /// The unmodified key map is delivered to the FIRST RESPONDER (see
    /// ``keyDown(with:)``), so the view has to be able to be one.
    ///
    /// Load-bearing for the `initialFirstResponder` path below, and only that
    /// path: AppKit's own become-key pass SKIPS an `initialFirstResponder`
    /// that declines — probed on a real sheet, the assignment alone left the
    /// WINDOW holding first responder — while a direct `makeFirstResponder`
    /// call does not consult this at all.
    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Never pre-focus an answer plate — a run must not open with one side
        // already looking chosen (spec §3).
        window.initialFirstResponder = self
        // …and claim it now as well: `initialFirstResponder` is only consulted
        // when the window BECOMES key, which a sheet may already be by the time
        // its content mounts. This is what makes ←/→/Space live from the first
        // frame rather than from the next activation.
        window.makeFirstResponder(self)
    }

    /// Re-claims the keystrokes after a screen change. A render tears out the
    /// plates, and if one of them held first responder — Full Keyboard Access
    /// makes a clicked plate the responder — AppKit drops focus to the WINDOW,
    /// where a plain arrow `keyDown` dies. Focus that is still inside this view
    /// (a plate, the reference picker, a future field editor) is left alone.
    private func ensureKeyboardFocus() {
        guard let window, !isEditingText else { return }
        if let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: self) { return }
        window.makeFirstResponder(self)
    }

    /// The two identity hues are resolved HERE, per appearance, and handed to
    /// the plates — which draw whatever tint they are given and never pick one
    /// (spec §2.1). The electric values are unreadable as chrome on a light
    /// ground, so light mode gets the Deep companions.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        targetPlate?.configure(title: targetPlate?.title ?? "", keycap: "←",
                               identityTint: targetTint)
        referencePlate?.configure(title: referencePlate?.title ?? "", keycap: "→",
                                  identityTint: referenceTint)
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The tint carries the plate RIM's alpha. Dark = the light's own hex at
    /// FULL strength (owner ruling 2026-08-23, over spec §2.1's 0.45: at
    /// 0.45 the rims measured olive and mauve, 45% of the lights' chroma —
    /// the plates did not wear the lights' colour); light = the token's own
    /// light hex at 0.9. The target reaches its light hex through
    /// `syncSignalDeep`; `ring` carries its own, so the reference needs no
    /// Deep companion. Composited on the flat light ground the reference rim
    /// measures 4.45:1, and the cell restores full alpha for the keycap glyph
    /// (5.47:1).
    private var targetTint: NSColor {
        isDarkAppearance
            ? Tokens.Color.wireCore
            : Tokens.Color.syncSignalDeep.withAlphaComponent(Self.lightRimAlpha)
    }

    private var referenceTint: NSColor {
        isDarkAppearance
            ? Tokens.Color.ring
            : Tokens.Color.ring.withAlphaComponent(Self.lightRimAlpha)
    }

    private static let lightRimAlpha: CGFloat = 0.9

    // MARK: Keyboard (question + proposal)

    /// The map is ← target, → reference, Space "Both at once", Esc Stop, and
    /// Return the screen's default plate. Every one of them is unmodified, so
    /// it reaches the first responder's ``keyDown(with:)`` and never
    /// `performKeyEquivalent` (live bug, build wizardv6: the arrows did
    /// nothing while a suite calling `performKeyEquivalent` stayed green).
    /// The live path for the three answer
    /// keys and Esc, which is why this view claims first responder
    /// (``acceptsFirstResponder``). A plate held by Full Keyboard Access also
    /// lands here: `NSButton` passes an arrow it doesn't want up the responder
    /// chain, and this view is its superview.
    ///
    /// Return is deliberately NOT handled: `super.keyDown` walks the chain up
    /// to the window, whose default-button dispatch fires the screen's default
    /// plate (`keyEquivalent = "\r"`) — the same probe confirms it, and
    /// swallowing Return here would kill it.
    public override func keyDown(with event: NSEvent) {
        lastKeyDownWasConsumed = handleUnmodifiedKey(event)
        guard !lastKeyDownWasConsumed else { return }
        super.keyDown(with: event)
    }

    /// The one unmodified key map, and the one thing that answers "did the
    /// wizard take that key?" — recorded for the test seam because
    /// `keyDown(with:)` cannot return it.
    private func handleUnmodifiedKey(_ event: NSEvent) -> Bool {
        guard !isEditingText,
              event.modifierFlags.intersection(Self.heldModifiers).isEmpty
        else { return false }
        // The three answer keys go through the PLATE's own `performClick`, so
        // a key press visibly depresses the plate it names.
        switch event.keyCode {
        case Self.escapeKeyCode:
            session.cancel()
            onFinished?()
            return true
        case Self.leftArrowKeyCode where isAnswering:
            targetPlate?.performClick(nil)
            return true
        case Self.rightArrowKeyCode where isAnswering:
            referencePlate?.performClick(nil)
            return true
        case Self.spaceKeyCode where isAnswering:
            togetherPlate?.performClick(nil)
            return true
        default:
            return false
        }
    }

    private var lastKeyDownWasConsumed = false

    /// The modifiers a USER can be holding — the only ones "is this key
    /// unmodified?" may look at.
    ///
    /// **TRAP: `.deviceIndependentFlagsMask` is NOT that question** (live bug,
    /// build wizardv7 — ←/→ did nothing on the question screen while Space,
    /// Esc, Return and ⌘Z all worked). AppKit stamps every ARROW keyDown with
    /// `.function` + `.numericPad`, and both bits sit inside that mask, so the
    /// map's "no modifiers" guard rejected exactly the two keys that carry
    /// them and nothing else. Probed via `NSEvent(cgEvent:)` on a real ←:
    /// `deviceIndependent = 0x20a00000` (function 0x800000, numericPad
    /// 0x200000) against `0x20000000` for Space/Esc/Return. Caps Lock is left
    /// out on purpose: a user with it on still gets the arrows.
    private static let heldModifiers: NSEvent.ModifierFlags =
        [.command, .option, .control, .shift]

    /// A live field editor owns the keys and both entry points stand aside for
    /// it — cheap protection for any editable field this sheet gains later.
    private var isEditingText: Bool { window?.firstResponder is NSText }

    /// Whether a which-side answer is what the panel is asking for right now.
    private var isAnswering: Bool {
        if case .question = session.screen { return true }
        return false
    }

    private static let escapeKeyCode: UInt16 = 53
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    private static let spaceKeyCode: UInt16 = 49

    // MARK: Screen rendering

    private func render(_ screen: BTAlignmentWizardSession.Screen) {
        clearContent()
        stopProbeProgress()

        styleReadout(hero: false)
        updateTitleRow(for: screen)
        applyReadoutHeight(for: screen)
        refreshReferencePopUp()
        // Armed BEFORE the apply: under Reduce Motion and headless the lock
        // sequence settles synchronously inside it.
        armKeptReadout(for: screen)
        stage.apply(Self.stageState(for: screen, range: session.candidateRange), animated: true)

        switch screen {
        case .intro:
            readout.stringValue = ""
            stage.lightNames = (session.targetName, session.reference?.name ?? "")
            addIntroPanels(byEarBody: introBody())
            // A CHOICE gets its own band; a STATEMENT stays tucked under the
            // sentence it qualifies (see ``addReferenceRow``).
            contentStack.setCustomSpacing(
                referenceOptions.count > 1 ? Self.spacingBand : Self.spacingRow,
                after: contentStack.arrangedSubviews[0])
            addReferenceRow()
            // A full band break before Start. At the stack's own 16 the CTA
            // sat right under the reference line and read as part of it —
            // "far too big, squished against text" (owner, live 2026-08-24).
            // The plate's size never changed; what it was missing was air.
            contentStack.setCustomSpacing(Self.spacingBand,
                                          after: contentStack.arrangedSubviews.last!)
            let canStart = session.reference != nil
            let start = makePlate("Start", keycap: canStart ? "⏎" : nil, isPrimary: true,
                                  action: #selector(startClicked(_:)), isDefault: true)
            start.isEnabled = canStart
            startPlate = start
            addCentredPlate(start)
            // The intro's way OUT. A sheet carries no ✕, so before this row
            // the only exit was Esc — and with no reference to compare
            // against, Start is disabled and the screen had no enabled
            // control at all. Same corner row, same trailing corner as the
            // question and proposal screens; there is simply no Undo to put
            // in the other corner yet. Esc still stops the run — only the
            // printed chip is gone (owner ruling 2026-09-13).
            addCornerRow(trailing: (Self.stopTitle, #selector(stopClicked(_:))))
            // The panel is spoken as it reads — the hands-free lead when the
            // mic path is available, plain by-ear otherwise.
            let panelSpoken: String
            if session.listeningIsPossible, session.reference != nil {
                panelSpoken = "\(Self.autoPanelTitle): \(Self.autoLeadCopy)"
            } else {
                panelSpoken = "\(Self.byEarPanelTitle): \(introBody())"
            }
            setAccessibilityLabel("Align \(session.targetName). " + panelSpoken)

        case .listening(let isRealignment):
            // The mic is doing the work, so the screen asks for nothing: no
            // plates, no Undo, no click count. The HEADLINE carries the state
            // (the selling point of this guided step is out loud, not buried in
            // grey), so the readout above the band stays empty and the band
            // centres cleanly.
            readout.stringValue = ""
            let headline = isRealignment
                ? Self.listeningHeadlineRealign : Self.listeningHeadlineFirst
            addListeningMic()
            addHeadline(headline)
            addBody(Self.listeningBody)
            addProbeProgress()
            addCornerRow(trailing: (Self.stopTitle, #selector(stopClicked(_:))))
            setAccessibilityLabel(headline + ". " + Self.listeningBody)

        case .question(_, let intervalMs, let answersSoFar):
            let referenceName = session.reference?.name ?? ""
            // Why the user is suddenly being asked: said once, over the first
            // question, and only when the mic tried and failed.
            let failureNote: String? = session.listeningFailed && answersSoFar == 0
                ? Self.listeningFailedCopy(target: session.targetName,
                                           targetIsBluetooth: session.targetIsBluetooth,
                                           reference: referenceName)
                : nil
            if let failureNote { addBody(failureNote) }
            // The QUESTION is the headline; the rung is the stage's to decide
            // and the readout only says the word it settled on (spec §1/§5).
            // The interval itself is the stage's tooltip.
            readout.attributedStringValue = Self.readoutCopy(word: stage.rung.word)
            stage.toolTip = Self.confidenceCopy(intervalMs)
            let target = makePlate(session.targetName, keycap: "←", tint: targetTint,
                                   action: #selector(targetClicked(_:)),
                                   width: Self.answerPlateWidth, height: Self.answerPlateHeight)
            let reference = makePlate(referenceName, keycap: "→", tint: referenceTint,
                                      action: #selector(referenceClicked(_:)),
                                      width: Self.answerPlateWidth, height: Self.answerPlateHeight)
            for plate in [target, reference] { plate.font = Tokens.Font.plateTitle }
            targetPlate = target
            referencePlate = reference
            addEdgePlateRow(target, reference, gap: Self.answerPlateGap)
            contentStack.setCustomSpacing(Self.spacingRow,
                                          after: contentStack.arrangedSubviews.last!)
            let together = makePlate(Self.togetherTitle, keycap: "SPACE",
                                     action: #selector(togetherClicked(_:)),
                                     width: Self.togetherBarWidth,
                                     height: Self.togetherBarHeight,
                                     chipPlacement: .inline)
            togetherPlate = together
            addCentredPlate(together)
            addCornerRow(trailing: (Self.stopTitle, #selector(stopClicked(_:))))
            // Spoken from the SAME strings the screen prints: the question
            // verbatim, then the three plates in reading order. The old label
            // asked with a different verb ("ticked") and offered only two of
            // the three answers.
            setAccessibilityLabel(
                (failureNote.map { "\($0) " } ?? "")
                + "\(Self.questionPrompt) \(session.targetName), \(referenceName), "
                + "or \(Self.togetherTitle)?")

        case .proposal(let valueMs):
            // Rounded, NOT `BTSyncTrim.quantise`: a Bluetooth run's result is
            // the speaker's measured latency, which routinely runs past the
            // trim's ±500 ms and would be clamped into a lie.
            let wholeMs = Int(valueMs.rounded())
            styleReadout(hero: true)
            // A RECALLED value was never measured this run, so it is put as a
            // question; an earned or measured one states its result.
            let isRecalled = session.proposalIsRecalled
            readout.stringValue = isRecalled
                ? Self.recalledReadout(valueMs: wholeMs)
                : "\(wholeMs) ms"
            addBody(isRecalled ? Self.recalledProposalCopy(valueMs: wholeMs) : Self.proposalBody)
            // A measured proposal's reject escalates: "Try again" listens once
            // more, then "Align by ear" hands to the questions. An earned or
            // recalled proposal reads "Still off".
            let rejectTitle: String = session.proposalIsMeasured
                ? (session.rejectReRunsMic ? Self.tryAgainTitle : Self.byEarPanelTitle)
                : Self.stillOffTitle
            addEdgePlateRow(
                makePlate(Self.soundsRightTitle, keycap: "⏎", isPrimary: true,
                          action: #selector(acceptClicked(_:)), isDefault: true),
                makePlate(rejectTitle, action: #selector(rejectClicked(_:))))
            // The manual path sits beside a proposal the listener doesn't
            // like — quiet, never a plate; Stop stays the way out.
            addCornerRow(leading: (Self.setByHandTitle, #selector(setByHandClicked(_:))),
                         trailing: (Self.stopTitle, #selector(stopClicked(_:))))
            pendingBestGuessMs = valueMs
            setAccessibilityLabel(
                "Aligned at \(wholeMs) milliseconds. Does it sound right?")

        case .kept:
            // The readout keeps the proposal's number until the stage's lock
            // settles — `armKeptReadout` crossfades "· kept" over it there.
            // The winning message is the hero line: the speaker is ready.
            let ready = Self.keptReadyCopy(target: session.targetName)
            let caption = session.measuresLatency ? Self.keptLatencyCaption : Self.keptLocalCaption
            addBody(ready, hero: true)
            addCaption(caption)
            contentStack.setCustomSpacing(Self.spacingTight,
                                          after: contentStack.arrangedSubviews[0])
            addCentredPlate(makeDonePlate(isPrimary: true, keycap: "⏎",
                                          action: #selector(keptDoneClicked(_:)),
                                          isDefault: true))
            setAccessibilityLabel(ready + " " + caption)

        case .unsettled(let bestGuessMs):
            readout.stringValue = ""
            addBody(Self.unsettledCopy)
            // Try again is the default — the copy itself says what to do —
            // and the manual path is the quiet alternative.
            addNarrowPlateRow([
                makePlate(Self.tryAgainTitle, keycap: "⏎", isPrimary: true,
                          action: #selector(tryAgainClicked(_:)),
                          width: Self.narrowPlateWidth, isDefault: true),
                makePlate(Self.setByHandTitle, action: #selector(setByHandClicked(_:)),
                          width: Self.narrowPlateWidth),
                makeDonePlate(action: #selector(doneClicked(_:)),
                              width: Self.narrowPlateWidth),
            ])
            pendingBestGuessMs = bestGuessMs
            setAccessibilityLabel(Self.unsettledCopy)

        case .unreachable:
            readout.stringValue = ""
            addBody(Self.unreachableCopy)
            addEdgePlateRow(
                makePlate(Self.tryAgainTitle, keycap: "⏎", isPrimary: true,
                          action: #selector(tryAgainClicked(_:)), isDefault: true),
                makeDonePlate(action: #selector(doneClicked(_:))))
            setAccessibilityLabel(Self.unreachableCopy)

        case .macIsLate:
            readout.stringValue = ""
            addBody(Self.macIsLateCopy)
            addEdgePlateRow(
                makePlate(Self.tryAgainTitle, keycap: "⏎", isPrimary: true,
                          action: #selector(tryAgainClicked(_:)), isDefault: true),
                makeDonePlate(action: #selector(doneClicked(_:))))
            setAccessibilityLabel(Self.macIsLateCopy)
        }
        needsLayout = true
        ensureKeyboardFocus()
        onContentSizeChange?()
    }

    /// The intro's sentence, with the two sounds named only when the pair
    /// actually makes two — the session owns that fact, since it owns the
    /// reference.
    private func introBody() -> String {
        guard session.pairSoundsDiffer, let reference = session.reference else {
            return Self.introCopy
        }
        return Self.introCopyNamingSounds(target: session.targetName,
                                          targetIsBluetooth: session.targetIsBluetooth,
                                          reference: reference.name)
    }

    /// The screen-change preamble: empty the content band and drop every
    /// per-screen reference.
    private func clearContent() {
        stage.toolTip = nil
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        referenceLineLabel = nil
        startPlate = nil
        targetPlate = nil
        referencePlate = nil
        togetherPlate = nil
        pendingBestGuessMs = nil
    }

    /// The HOST's target-lost bow-out — the one screen the SESSION cannot
    /// know: by the time the host sees the target vanish it has already
    /// cancelled the run, and a modal sheet that vanishes with it is more
    /// jarring than one line and a Done. Detached from `onScreenChange` so
    /// nothing repaints over it; Done rides `doneClicked`, whose `cancel()`
    /// is inert against the already-ended session.
    ///
    /// `public` for the reason ``togetherTitle`` is: it is the ONE bow-out no
    /// session state can reach, so `wizard-snapshot` has to drive it directly
    /// or the fourth bow-out is the one screen nobody ever looks at.
    public func showTargetLost() {
        session.onScreenChange = nil
        clearContent()
        stopProbeProgress()
        styleReadout(hero: false)
        readout.stringValue = ""
        titleLabel.stringValue = Self.wizardTitle(target: session.targetName)
        clickCountLabel.stringValue = ""
        setReadoutShown(false)
        stage.apply(.dormant, animated: true)
        let copy = Self.targetLostCopy(target: session.targetName)
        addBody(copy)
        // The stack's own group spacing, NOT the kept screen's tight pairing
        // this screen was cut from: there is no caption under the sentence to
        // bind it to, and the other three bow-outs all stand their buttons a
        // full band gap below the line. At 4 pt this one read as cramped
        // beside its siblings.
        addCentredPlate(makeDonePlate(isPrimary: true, keycap: "⏎",
                                      action: #selector(doneClicked(_:)),
                                      isDefault: true))
        setAccessibilityLabel(copy)
        needsLayout = true
        onContentSizeChange?()
    }

    /// What the stage shows for a screen. Only a live run has a belief to
    /// draw — every bow-out leaves the instrument dim and still.
    private static func stageState(for screen: BTAlignmentWizardSession.Screen,
                                   range: ClosedRange<Double>) -> AlignmentStageView.State {
        switch screen {
        case .intro: return .armed(range: range)
        case .listening: return .measuring(range: range)
        case .question(_, let intervalMs, _):
            return .question(intervalMs: intervalMs, range: range)
        case .proposal(let valueMs): return .listening(valueMs: valueMs, range: range)
        case .kept(let valueMs): return .locked(valueMs: valueMs, range: range)
        case .unsettled, .unreachable, .macIsLate: return .dormant
        }
    }

    /// The question, plus the ladder's own word for where the run is. The
    /// word comes from the RUNG — this view owns no thresholds.
    ///
    /// TWO VOICES ON ONE LINE. The question is the thing the user is here to
    /// answer ~15 times, so it wears the label's weight and brightness; the
    /// word is status and stays in the caption voice beside it. Set flat, the
    /// two read as a single eight-word string of chrome and the ask
    /// disappears into it — the readout still has to be smaller than the
    /// plates it is asking about (they are the hero), so emphasis, not size,
    /// is what separates them.
    private static func readoutCopy(word: String?) -> NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let line = NSMutableAttributedString(
            string: questionPrompt,
            attributes: [.font: Tokens.Font.captionEmphasized,
                         .foregroundColor: Tokens.Color.label,
                         .paragraphStyle: centred])
        guard let word else { return line }
        line.append(NSAttributedString(
            string: " · " + word,
            attributes: [.font: Tokens.Font.caption,
                         .foregroundColor: Tokens.Color.label2,
                         .paragraphStyle: centred]))
        return line
    }

    // MARK: The title row

    private func updateTitleRow(for screen: BTAlignmentWizardSession.Screen) {
        titleLabel.stringValue = Self.wizardTitle(target: session.targetName)
        var showsRemoteLink = false
        if case .intro = screen { showsRemoteLink = remoteInvite != .unavailable }
        remoteLink.isHidden = !showsRemoteLink
        switch screen {
        // "About 15 clicks" rides the by-ear panel, so this slot holds the
        // iPhone link there and stays empty until the run starts counting.
        // Nothing has been asked yet on either screen.
        case .intro, .listening: clickCountLabel.stringValue = ""
        case .question(_, _, let answersSoFar):
            clickCountLabel.stringValue = Self.clickCountCopy(answersSoFar + 1)
        case .proposal, .kept, .unsettled, .unreachable, .macIsLate:
            clickCountLabel.stringValue = ""
        }
    }

    // MARK: The readout

    /// The kept line arrives on the stage's OWN cue, not on the screen change:
    /// the lock is a 1.62 s sequence, and the words land as it settles.
    private func armKeptReadout(for screen: BTAlignmentWizardSession.Screen) {
        stage.onLockedSettled = nil
        guard case .kept(let valueMs) = screen else { return }
        let text = Self.keptReadout(valueMs: Int(valueMs.rounded()))
        stage.onLockedSettled = { [weak self] in self?.crossfadeReadout(text) }
    }

    /// The stage's caption voice — caption-size semibold tabular digits (iOS
    /// Readout weight) in `label2` (tabular, so the centred line doesn't
    /// shimmy as the numbers change); the proposal's hero readout differs by
    /// ink, not weight.
    private func styleReadout(hero: Bool) {
        readout.font = Tokens.Font.readout
        readout.textColor = hero ? Tokens.Color.label : Tokens.Color.label2
    }

    /// Which screens print a caption under the stage. Driven off the SCREEN,
    /// never off `readout.stringValue`: the kept screen's own line arrives
    /// LATER, on the stage's lock cue (``armKeptReadout``), so a string test
    /// would have collapsed the row to zero and then crossfaded the words in
    /// behind it.
    private func applyReadoutHeight(for screen: BTAlignmentWizardSession.Screen) {
        switch screen {
        case .question, .proposal, .kept: setReadoutShown(true)
        case .intro, .listening, .unsettled, .unreachable, .macIsLate: setReadoutShown(false)
        }
    }

    /// A hidden readout takes its gap with it, so the band sits one band
    /// break under the stage rather than a row gap plus a band break.
    private func setReadoutShown(_ shown: Bool) {
        readoutHeightConstraint.constant = shown ? Self.readoutHeight : 0
        readoutTopConstraint.constant = shown ? Self.spacingRow : 0
    }

    private func crossfadeReadout(_ text: String) {
        // The number stays the stage's caption; the hero of the kept screen
        // is the ready line beneath it (owner ruling 2026-08-23).
        styleReadout(hero: false)
        guard !HeadlessRuntime.isActive,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            readout.stringValue = text
            return
        }
        readout.wantsLayer = true
        let fade = CATransition()
        fade.duration = 0.25
        // `CATransition` is filed under the literal reserved key "transition"
        // whatever key is passed here — see `AudioutSharedUI/AGENTS.md`.
        readout.layer?.add(fade, forKey: "transition")
        readout.stringValue = text
    }

    // MARK: Content bands

    /// Plain speech: body regular, `label2`, centred, wrapping at the
    /// together bar's measure. Never the loudest text on a screen — the
    /// plates and the readout are.
    private func addBody(_ text: String, hero: Bool = false) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = hero ? Tokens.Font.bodyEmphasized : Tokens.Font.body
        label.textColor = hero ? Tokens.Color.label : Tokens.Color.label2
        label.alignment = .center
        label.preferredMaxLayoutWidth = Self.bodyMeasure
        contentStack.addArrangedSubview(label)
    }

    /// The listening screen's focal headline — the `display` voice (20 pt/700)
    /// on full `label`, centred, at most two lines. macOS has no balanced-wrap
    /// API, so a short headline sits on one line and the cap is a safety.
    private func addHeadline(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Tokens.Font.display
        label.textColor = Tokens.Color.label
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = Self.bodyMeasure
        contentStack.addArrangedSubview(label)
    }

    /// The live "listening on the mic" cue — a stock `mic.fill` symbol tinted to
    /// the label ink, pulsing while the room is measured. STATIC headless and
    /// under Reduce Motion, so the snapshot stays deterministic.
    private func addListeningMic() {
        let mic = NSImageView()
        mic.translatesAutoresizingMaskIntoConstraints = false
        mic.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        mic.contentTintColor = Tokens.Color.label
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           !HeadlessRuntime.isActive {
            mic.addSymbolEffect(.variableColor.iterative.dimInactiveLayers)
        }
        contentStack.addArrangedSubview(mic)
    }

    /// The listening screen's determinate bar: empty until the probe starts,
    /// then filled over the probe's lead plus its two lanes. Driven by a
    /// plain timer, no animation API, so headless and Reduce Motion need no
    /// branch.
    private func addProbeProgress() {
        let bar = NSProgressIndicator()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.widthAnchor.constraint(equalToConstant: Self.bodyMeasure).isActive = true
        contentStack.addArrangedSubview(bar)
        probeProgress = bar
        if session.probeStartedAt != nil { startProbeProgress() }
    }

    /// The bar and the stage's speaker turns share this one clock.
    private func startProbeProgress() {
        guard probeProgress != nil, probeProgressTimer == nil,
              let total = session.probeListeningSeconds else { return }
        probeProgressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let bar = self.probeProgress,
                  let started = self.session.probeStartedAt else { return }
            let elapsed = Date().timeIntervalSince(started)
            bar.doubleValue = min(1, elapsed / total)
            self.stage.setListeningTurn(self.session.probeSpeakerPlaying(at: elapsed),
                                        levelAboveRoomDB: self.session.probeLevelAboveRoomDB?(),
                                        now: CACurrentMediaTime())
        }
    }

    private func stopProbeProgress() {
        probeProgressTimer?.invalidate()
        probeProgressTimer = nil
        probeProgress = nil
    }

    /// The intro's one panel: the Mac's own run, centred by `contentStack`'s
    /// `.centerX`. Not pressable — Start, below it, stays the page's one
    /// primary control and the only gold on the screen.
    private func addIntroPanels(byEarBody: String) {
        let byEar = NSStackView()
        byEar.orientation = .vertical
        byEar.alignment = .centerX
        byEar.spacing = Self.spacingRow
        byEar.translatesAutoresizingMaskIntoConstraints = false
        // When the Mac can measure through its own mic, the panel says that
        // and nothing else — not even the click count, which is the cost of a
        // by-ear run this page does not promise. Otherwise the two speakers
        // make one sound, there is no automatic path, and the panel stays the
        // by-ear instructions with their cost.
        if session.listeningIsPossible, session.reference != nil {
            byEar.addArrangedSubview(panelHeading(Self.autoPanelTitle))
            byEar.addArrangedSubview(panelLine(Self.autoLeadCopy))
        } else {
            byEar.addArrangedSubview(panelHeading(Self.byEarPanelTitle))
            byEar.addArrangedSubview(panelLine(byEarBody))
            byEar.addArrangedSubview(panelLine(Self.introSlotText))
        }

        byEar.widthAnchor.constraint(equalToConstant: Self.introPanelWidth).isActive = true
        let row = NSStackView(views: [byEar])
        row.orientation = .horizontal
        contentStack.addArrangedSubview(row)
    }

    @objc private func remoteLinkClicked(_ sender: NSButton) {
        guard let url = URL(string: RemoteInviteView.codeURLString) else { return }
        openURL(url)
    }

    /// A panel's title — the plate voice, on the CHASSIS ink. `stageInk`
    /// belongs to the fixed dark plate above; the band under it themes with
    /// the window, and cream text on the light chassis is unreadable
    /// (measured in the wizard snapshot).
    private func panelHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Tokens.Font.plateTitle
        label.textColor = Tokens.Color.label
        label.alignment = .center
        return label
    }

    /// A panel's body line — the same quiet voice `addBody` uses, on both
    /// sides, so neither panel shouts over the other.
    private func panelLine(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Tokens.Font.detail
        label.textColor = Tokens.Color.label2
        label.alignment = .center
        label.preferredMaxLayoutWidth = Self.introPanelWidth
        return label
    }

    /// The reference the run compares against — intro only (spec §1). With one
    /// candidate there is nothing to choose, so the line states it; with none it
    /// says so and Start stays off.
    ///
    /// **A CHOICE is a FORM FIELD; a STATEMENT is a caption.** The picker case
    /// is the intro's second action and has to look like one at a glance, so it
    /// is the macOS form field every Settings pane already taught the user:
    /// `Compare against` on its own line above a LARGE pop-up spanning
    /// ``bodyMeasure`` — one bounded 400 pt object with the chevron out at the
    /// far edge. Wearing the control's own bounds is the point: the field is
    /// exactly as clickable as it looks, which a label-plus-ground container
    /// cannot honestly claim. Inside the sentence, at any size, it reads as
    /// prose (owner, two live passes 2026-08-24: "blends right into the
    /// background beside this huge CTA", then "bring the fact that this is an
    /// element you need to interact with further in focus").
    ///
    /// Start is untouched and still the primary — gold, 64 pt tall, the one
    /// thing Return fires. The field being WIDER is form above, submit below.
    ///
    /// The 0- and 1-candidate lines stay captions with no control mounted at
    /// all: nothing on them can be clicked, and a field would promise an
    /// affordance the screen doesn't have.
    private func addReferenceRow() {
        switch referenceOptions.count {
        case 0:
            referenceLineLabel = addCaption(Self.noReferenceCopy)
        case 1:
            referenceLineLabel = addCaption(
                Self.soleReferenceCopy(name: referenceOptions[0].name))
        default:
            let label = makeRaisedLabel(Self.compareLabel)
            referenceLineLabel = label
            referencePopUp.controlSize = .large
            referencePopUp.font = Tokens.Font.body
            // The label is a sibling view, so VoiceOver would otherwise reach
            // the pop-up with only a device name to announce.
            referencePopUp.setAccessibilityLabel(Self.compareLabel)
            // The pop-up is PERSISTENT and re-mounted on every intro render, so
            // its width is one stored constraint rather than a fresh one each
            // time — `isActive = true` on the same object is idempotent where a
            // new constraint per render would pile up.
            referencePopUpWidth.isActive = true
            let field = NSStackView(views: [label, referencePopUp])
            field.orientation = .vertical
            field.alignment = .leading
            field.spacing = Self.spacingTight
            contentStack.addArrangedSubview(field)
        }
    }

    /// Each item carries its own target/action + id, the idiom real menu
    /// tracking dispatches through (`MainOutRowMenuDispatchTests`): a
    /// pop-up-wide action would arrive with the wrong sender type.
    private func refreshReferencePopUp() {
        referencePopUp.menu?.removeAllItems()
        for option in referenceOptions {
            let item = NSMenuItem(title: option.name,
                                  action: #selector(referencePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            referencePopUp.menu?.addItem(item)
        }
        // One candidate is not a choice — that case renders as plain text. Once
        // the run has left the intro the reference is locked (owner, 2026-10-06).
        let onIntro: Bool
        if case .intro = session.screen { onIntro = true } else { onIntro = false }
        referencePopUp.isEnabled = referenceOptions.count > 1 && onIntro
        if let id = session.reference?.id,
           let index = referenceOptions.firstIndex(where: { $0.id == id }) {
            referencePopUp.selectItem(at: index)
        }
    }

    private func makeCaption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.label2
        return label
    }

    /// The reference FIELD’s label: body voice at full `label`, one step above
    /// the caption every other quiet line here wears — it labels a control, not
    /// a fact.
    private func makeRaisedLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Tokens.Font.body
        label.textColor = Tokens.Color.label
        return label
    }

    @discardableResult
    private func addCaption(_ text: String) -> NSTextField {
        let label = makeCaption(text)
        contentStack.addArrangedSubview(label)
        return label
    }

    /// Two plates on the content's two edges — 220 + 64 + 220 is exactly the
    /// content width, so the gap does the anchoring.
    private func addEdgePlateRow(_ leading: NSView, _ trailing: NSView,
                                 gap: CGFloat = BTAlignmentWizardView.plateGap) {
        let row = NSStackView(views: [leading, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = gap
        contentStack.addArrangedSubview(row)
    }

    /// The unsettled screen's three-up — 160 × 3 + 12 × 2 also fills the width.
    private func addNarrowPlateRow(_ plates: [NSView]) {
        let row = NSStackView(views: plates)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Self.spacingRow
        contentStack.addArrangedSubview(row)
    }

    /// A single plate centred across the full content width — the "together"
    /// answer sits between the two sides it reconciles, not beside them, and
    /// the same holder centres every lone primary.
    private func addCentredPlate(_ plate: NSView) {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(plate)
        NSLayoutConstraint.activate([
            plate.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            plate.topAnchor.constraint(equalTo: holder.topAnchor),
            plate.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        contentStack.addArrangedSubview(holder)
    }

    /// Corner rows are REAL buttons, quiet text in the caption voice; Esc stops
    /// the run regardless of what the row prints. The title is the word a test
    /// clicks and VoiceOver speaks.
    typealias CornerSpec = (title: String, action: Selector)

    /// One exit in the trailing corner.
    private func addCornerRow(trailing: CornerSpec) {
        addCornerRow(leading: nil, trailing: trailing)
    }

    private func addCornerRow(leading: CornerSpec?, trailing: CornerSpec) {
        let leadingItem: NSView
        if let leading {
            leadingItem = makeCornerButton(leading.title, leading.action)
        } else {
            // A zero-width stand-in rather than a one-item row: the row's
            // `.equalSpacing` needs two ends to push the exit onto the
            // trailing edge, and Stop must land in the SAME corner it does
            // on every other screen.
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: 0).isActive = true
            leadingItem = spacer
        }
        let trail = makeCornerButton(trailing.title, trailing.action)
        let row = NSStackView(views: [leadingItem, trail])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .equalSpacing
        row.spacing = Self.spacingGroup
        // Spans the content width so the two exits land on the two EDGES —
        // side by side they were a mis-click away from each other.
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        contentStack.addArrangedSubview(row)
    }

    private func makeCornerButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.title = title
        button.target = self
        button.action = action
        button.heightAnchor.constraint(
            equalToConstant: Self.cornerButtonHeight).isActive = true
        styleCornerButton(button)
        return button
    }

    private func styleCornerButton(_ button: NSButton) {
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [.font: Tokens.Font.captionEmphasized,
                         .foregroundColor: Tokens.Color.label2])
    }

    private func makePlate(_ title: String, keycap: String? = nil, isPrimary: Bool = false,
                           tint: NSColor? = nil, action: Selector,
                           width: CGFloat = BTAlignmentWizardView.plateWidth,
                           height: CGFloat = BTAlignmentWizardView.plateHeight,
                           isDefault: Bool = false,
                           chipPlacement: AlignmentPlateCell.ChipPlacement = .trailing) -> AlignmentPlateButton {
        let plate = AlignmentPlateButton(
            frame: NSRect(x: 0, y: 0, width: width, height: height))
        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.target = self
        plate.action = action
        plate.configure(title: title, keycap: keycap,
                        isPrimary: isPrimary, identityTint: tint, chipPlacement: chipPlacement)
        // A plate carrying a DEVICE NAME keeps its fixed width and truncates:
        // the chassis is fixed, so a long name must shrink its label, never
        // widen the view.
        plate.cell?.lineBreakMode = .byTruncatingTail
        plate.cell?.usesSingleLineMode = true
        // Return reaches the screen's one default plate through the WINDOW's
        // default-button dispatch — `keyEquivalent = "\r"` registers the plate
        // as the window's default button, and an unmodified Return travels the
        // responder chain up to it, which is exactly why `keyDown(with:)`
        // deliberately falls through to `super` rather than claiming Return.
        if isDefault { plate.keyEquivalent = "\r" }
        NSLayoutConstraint.activate([
            plate.widthAnchor.constraint(equalToConstant: width),
            plate.heightAnchor.constraint(equalToConstant: height),
        ])
        return plate
    }

    private func makeDonePlate(isPrimary: Bool = false, keycap: String? = nil,
                               action: Selector,
                               width: CGFloat = BTAlignmentWizardView.plateWidth,
                               isDefault: Bool = false) -> AlignmentPlateButton {
        makePlate("Done", keycap: keycap, isPrimary: isPrimary, action: action,
                  width: width, isDefault: isDefault)
    }

    // MARK: Actions (all real target/action dispatch)

    @objc private func startClicked(_ sender: NSButton) { session.start() }
    @objc private func targetClicked(_ sender: NSButton) { session.answer(.target) }
    @objc private func referenceClicked(_ sender: NSButton) { session.answer(.reference) }
    @objc private func togetherClicked(_ sender: NSButton) { session.answer(.together) }
    @objc private func stopClicked(_ sender: NSButton) {
        session.cancel()
        onFinished?()
    }
    @objc private func acceptClicked(_ sender: NSButton) { session.acceptProposal() }
    @objc private func rejectClicked(_ sender: NSButton) { session.rejectProposal() }
    @objc private func tryAgainClicked(_ sender: NSButton) { session.tryAgain() }
    /// The kept screen's Done. The run committed on Accept, so this is a close
    /// and nothing else — `cancel()` would be inert here anyway, but saying
    /// "done" is what actually happened.
    @objc private func keptDoneClicked(_ sender: NSButton) {
        session.done()
        onFinished?()
    }
    @objc private func setByHandClicked(_ sender: NSButton) {
        if let pendingBestGuessMs { onSetByHand?(pendingBestGuessMs) }
        onFinished?()
    }
    @objc private func doneClicked(_ sender: NSButton) {
        // Every screen behind this button is a BOW-OUT: the session already put
        // the tick off and the prior value back, and marked itself ended — so
        // `cancel()` is inert here, and deliberately so. It used to fire a
        // second tick-off edge, which the backend pays for as a re-anchor of
        // every sink. Kept as the one unconditional close call.
        session.cancel()
        onFinished?()
    }
    @objc private func referencePicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectReference?(id)
    }

    // MARK: Test-support hooks (performClick = real dispatch)

    var test_screen: BTAlignmentWizardSession.Screen { session.screen }
    var test_hasProgressBar: Bool {
        guard let probeProgress else { return false }
        return probeProgress.isDescendant(of: contentStack)
    }
    var test_stage: AlignmentStageView { stage }
    /// Every direct text label in the mounted band, in reading order — the
    /// listening screen splits its message across a display headline and a body
    /// line, where ``test_bodyText`` reads a single label.
    var test_bandLabels: [String] {
        contentStack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }
    /// The screen's body copy. On the INTRO that sentence lives inside the
    /// by-ear panel; everywhere else it is the band's first label.
    var test_bodyText: String? {
        if let label = contentStack.arrangedSubviews.first as? NSTextField {
            return label.stringValue
        }
        return byEarPanelLabels.dropFirst().first?.stringValue
    }

    /// The title row's iPhone link, or `nil` where it is hidden.
    public var test_remoteLinkTitle: String? { remoteLink.isHidden ? nil : remoteLink.title }
    func test_clickRemoteLink() { remoteLink.performClick(nil) }
    public var test_byEarPanelHeading: String? { byEarPanelLabels.first?.stringValue }
    /// Every line of the intro panel, in reading order — heading, the
    /// lead/instruction lines, and the cost note — where `test_bodyText` (which
    /// reads one instruction line alone) cannot see them.
    var test_byEarPanelLines: [String] { byEarPanelLabels.map(\.stringValue) }

    /// The labels of the intro panel, in reading order.
    private var byEarPanelLabels: [NSTextField] {
        (introPanelStacks.last?.arrangedSubviews ?? []).compactMap { $0 as? NSTextField }
    }

    private var introPanelStacks: [NSStackView] {
        guard let row = contentStack.arrangedSubviews.first as? NSStackView else { return [] }
        return row.arrangedSubviews.compactMap { $0 as? NSStackView }
    }

    /// The title row's right slot: the live click count, or `nil` on the
    /// intro (whose cost note rides the by-ear panel) and once the run is
    /// over.
    var test_clickCountText: String? {
        clickCountLabel.stringValue.isEmpty ? nil : clickCountLabel.stringValue
    }
    /// The stage's caption — `nil` on the screens that show no number.
    var test_readoutText: String? {
        readout.stringValue.isEmpty ? nil : readout.stringValue
    }
    var test_buttonTitles: [String] { actionButtons.map(\.title) }
    var test_referenceOptionTitles: [String] {
        referencePopUp.menu?.items.map(\.title) ?? []
    }
    var test_selectedReferenceTitle: String? { referencePopUp.selectedItem?.title }
    var test_referencePickerIsEnabled: Bool { referencePopUp.isEnabled }
    var test_startIsEnabled: Bool { startPlate?.isEnabled ?? false }
    var test_buttonIsEnabled: (String) -> Bool {
        { [weak self] title in
            self?.actionButtons.first { $0.title == title }?.isEnabled ?? false
        }
    }
    /// The identity tint a named plate is wearing — which speaker its rim and
    /// keycap chip say it is.
    var test_plateIdentityTint: (String) -> NSColor? {
        { [weak self] title in
            (self?.actionButtons.first { $0.title == title } as? AlignmentPlateButton)?
                .test_identityTint
        }
    }
    var test_referenceLineText: String? { referenceLineLabel?.stringValue }
    /// Is the reference line dressed as a CONTROL or as a STATEMENT? The label
    /// voice, the pop-up's `.large` size and its full-measure width are all
    /// asserted together, because the voice alone passes on a screen that still
    /// reads as prose. A caption line mounts no pop-up at all, so it fails the
    /// last three outright.
    var test_referenceLineIsRaised: Bool {
        referenceLineLabel?.font == Tokens.Font.body
            && referencePopUp.superview != nil
            && referencePopUp.controlSize == .large
            && referencePopUpWidth.isActive
            && referencePopUpWidth.constant == Self.bodyMeasure
    }
    /// The screens' own buttons, in reading order — the answer plates and the
    /// corner buttons each sit a stack deeper than the rest, so this walks the
    /// nesting. An `NSPopUpButton` is an `NSButton` too, so the reference
    /// picker has to be excluded or it answers to a device name.
    private var actionButtons: [NSButton] { Self.buttons(in: contentStack) }
    private static func buttons(in view: NSView) -> [NSButton] {
        let children = (view as? NSStackView)?.arrangedSubviews ?? view.subviews
        return children.flatMap { child -> [NSButton] in
            guard let button = child as? NSButton else { return buttons(in: child) }
            return button is NSPopUpButton ? [] : [button]
        }
    }
    /// A real key event, split down the SAME two entry points AppKit's own
    /// dispatch uses (see ``keyDown(with:)``'s trap note): a Command-modified
    /// key is offered as a key equivalent, everything else is delivered as a
    /// plain `keyDown`. Routing every key through `performKeyEquivalent` here
    /// would let a dead arrow map ship green — live dispatch never runs that
    /// pass for unmodified keys. The split asks ``heldModifiers``, not the
    /// device-independent mask, for that trap's second half: an arrow arrives
    /// carrying `.function` + `.numericPad` and is still a plain `keyDown`.
    /// Returns whether the wizard consumed the key.
    @discardableResult
    func test_sendKey(keyCode: UInt16, characters: String = "",
                      modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode) else { return false }
        guard !modifiers.intersection(Self.heldModifiers).isEmpty else {
            keyDown(with: event)
            return lastKeyDownWasConsumed
        }
        return performKeyEquivalent(with: event)
    }
    /// Does the mounted content fit the width it was given? A long device name
    /// used to make the content's required width pin unsatisfiable; nothing
    /// here asserts an absolute width, only that the content still fits.
    var test_contentFitsItsWidth: Bool {
        layoutSubtreeIfNeeded()
        let available = bounds.width - 2 * Self.contentPadding
        // The ROWS — the plates and the reference line, the parts that carry
        // device names. A wrapping body label sizes itself and is not what a
        // long name breaks.
        return contentStack.arrangedSubviews
            .compactMap { $0 as? NSStackView }
            .allSatisfy { $0.fittingSize.width <= available }
    }
    /// Do the title row's two slots stay clear of each other? The name and
    /// the click count are pinned to OPPOSITE edges of a plain container, so a
    /// long device name has nothing but its truncation guard between it and
    /// overprinting the count.
    var test_titleSlotsAreClear: Bool {
        layoutSubtreeIfNeeded()
        return titleLabel.frame.maxX <= clickCountLabel.frame.minX
    }
    private func clickButton(titled title: String) {
        actionButtons.first { $0.title == title }?.performClick(nil)
    }
    func test_clickButton(titled title: String) { clickButton(titled: title) }
    /// Hold a plate down (or let it go) without a mouse — the pressed skin
    /// for the snapshot renderer.
    public func test_setPlatePressed(titled title: String, _ pressed: Bool) {
        guard let plate = actionButtons.first(where: { $0.title == title }) else { return }
        plate.cell?.isHighlighted = pressed
        plate.needsDisplay = true
    }
    /// Real menu dispatch: the item's OWN action on its OWN target, sender =
    /// the item — exactly what AppKit menu tracking sends.
    func test_selectReference(titled title: String) {
        guard let item = referencePopUp.menu?.items.first(where: { $0.title == title }),
              let action = item.action, let target = item.target as? NSObject else { return }
        _ = target.perform(action, with: item)
    }
}
