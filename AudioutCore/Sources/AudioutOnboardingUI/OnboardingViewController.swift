// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Why the onboarding window is being presented right now — drives whether the
/// header carries the "a permission got turned off" message.
///
/// `.firstRun` (the default, used by every existing call site) is the plain
/// welcome. `.permissionLost` is used when the app finds — via
/// ``SetupModel/auditRequiredPermissions()`` on reactivate/wake — that one of
/// the three REQUIRED permissions (``RequiredPermission``; Remote Control is
/// deliberately excluded, it's an enhancement not a requirement) was revoked
/// after setup had already completed, and force-reopens this window rather than
/// silently degrading.
public enum OnboardingReason: Equatable, Sendable {
    case firstRun
    case permissionLost([RequiredPermission])
}

/// The Setup window's content: a SPINE and a HERO.
///
/// LEFT, a narrow column of six compact status rows (``SetupSpineRowView`` plus
/// the final check) — where you are, and nothing else. RIGHT, the hero pane:
/// the native-drawn rehearsal of whatever surface this step's ask is about to
/// raise (``DemoPaneView``), with a ribbon of REAL UI beneath it
/// (``SetupRibbonView``) carrying the ask, the reassurance, the honesty line
/// and the buttons.
///
/// That split is the point (Direction 04, owner-chosen): the rehearsal is this
/// window's actual idea, so it takes the stage, and the copy that explains it
/// sits directly under it rather than across the window in a card the eye has
/// to pair up by hand.
///
/// A thin renderer over two Core models and holding no permission logic of its
/// own: ``SetupModel`` owns the statuses and the probes, ``SetupFlowModel``
/// owns the sequence, the skip set, the Done gate and the Allow decision table.
/// This class turns those into views and turns clicks back into calls.
///
/// **Setup is a GATE** (owner decision 2026-08-11, reversing "guidance, not a
/// gate"): the CTA is ABSENT from the view hierarchy — not disabled, not
/// alpha-hidden — until every required permission verifies and the final check
/// passes, and there is no "continue anyway" escape. The ✕ close remains the
/// one ungated exit, and it deliberately doesn't persist completion, so the
/// flow returns next launch.
@MainActor
public final class OnboardingViewController: NSViewController {

    /// Fixed content size. The window is fixed at exactly this (see
    /// ``OnboardingWindowController/present()``), so no step's copy can resize
    /// the window under the user mid-flow.
    static let contentWidth: CGFloat = 820
    static let contentHeight: CGFloat = 560
    /// The SPINE's fixed width. It carries short row titles and nothing else —
    /// the sentences moved to the ribbon — so it is a fraction of the 420 pt
    /// the card column needed.
    static let spineWidth: CGFloat = 288
    /// Outer margin around both columns.
    static let paneMargin: CGFloat = 26
    /// Gap from the spine to the hero pane.
    static let paneGap: CGFloat = 18

    private let model: SetupModel
    private let flow: SetupFlowModel
    private let reason: OnboardingReason
    private let onOpenSettings: (SystemSettingsPane) -> Void
    private let onDone: () -> Void

    /// Called immediately before ANY System Settings destination is opened (a
    /// privacy pane or Login Items). The window controller uses it to drop this
    /// window's `.floating` level, so System Settings can actually come to the
    /// front — see that class for the amended decision.
    ///
    /// It also fires for Remote Control's ASK, which opens no pane of its own:
    /// the Accessibility Access prompt is an ordinary alert panel at normal
    /// level, not a TCC dialog drawn above everything, so a floating window
    /// buries it exactly the way it buries Settings. The name is kept — that
    /// alert's only button opens System Settings anyway, and every one of the
    /// four call sites is on the way there.
    public var onWillOpenSystemSettings: (() -> Void)?

    /// Called on every edge of "a system permission dialog this flow raised is
    /// still unanswered". The window controller goes quiet while it is true —
    /// see ``isPromptInFlight``.
    public var onPromptInFlightChanged: ((Bool) -> Void)?

    private var rows: [SetupStep: SetupSpineRowView] = [:]
    /// The sixth row: the automatic final check, made visible (owner decision
    /// 2026-08-11 — telemetry showed five clicks swallowed while an invisible
    /// ~2 s verification ran, so the check became a line item and the payoff
    /// waits for it).
    private var checkRow: SetupCheckRowView!
    private var spineStack: NSStackView!
    private var heroHead: SetupHeroHeadView!
    private var previewFrame: SetupPreviewFrameView!
    private var demoPane: DemoPaneView!
    private var ribbon: SetupRibbonView!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!

    /// The step whose Allow is in flight — the waiting beat, and the UI half of
    /// the single-flight rule the flow model enforces.
    private var allowInFlight: SetupStep?

    /// The most recent Allow's work, so a headless press can await exactly what
    /// the real click started (`test_pressRow`) instead of re-implementing it.
    private var allowTask: Task<Void, Never>?

    /// The step whose Allow sent the user to System Settings or Login Items —
    /// armed on the trip out, cleared once the step completes or a genuine
    /// return re-reads status and finds nothing changed. Drives the waiting
    /// spinner through a round-trip `allowInFlight` doesn't cover.
    private var settingsTripStep: SetupStep?
    /// Set once the app has actually lost the front while a Settings trip is
    /// armed — the signal that the trip really left, as opposed to the app's
    /// own catching-up activation (see `appDidBecomeActive`).
    private var settingsTripDeparted = false
    /// The re-read this waiting Settings trip is awaiting, so a headless walk
    /// can wait for exactly what a real return starts (`test_awaitSettingsReturn`).
    private var settingsReturnTask: Task<Void, Never>?

    /// Whether this flow has actually sent the user to Login Items for Speaker
    /// Sync. It is what separates "hasn't asked yet" from "asked, and the switch
    /// is still off" — two states the helper's own `.requiresApproval` cannot
    /// tell apart, and which need opposite words on screen.
    private var didTripLoginItems = false

    /// Set by a failed Done verification: the step to snap back to. It overrides
    /// the flow model's own active step, which is anchored to where this
    /// presentation STARTED and so can't reach back to a step that was fine
    /// when the window opened and has since been revoked.
    private var snapBackStep: SetupStep?

    /// The DECIDED row the hero pane is currently browsing, if any.
    ///
    /// Browsing is pure presentation and deliberately lives here rather than in
    /// ``SetupFlowModel``: it must never touch the sequence or the gate. A
    /// second click on the same row puts it back.
    private var browseStep: SetupStep?

    /// Steps whose skip the user has taken back by clicking the row again. It
    /// only drives the "you skipped this earlier" reassurance — the flow model
    /// has already forgotten the skip by then.
    private var reopenedSteps: Set<SetupStep> = []

    /// Steps already completed at the last repaint — the transition edge the
    /// grant choreography and the announcements fire on (a repaint that changes
    /// nothing must not re-run them).
    private var completedAtLastRefresh: Set<SetupStep> = []
    /// Same idea for refusals: a denial is announced when it first becomes
    /// visible, not on every repaint that still shows it.
    private var deniedAtLastRefresh: Set<SetupStep> = []
    private var announcedCheckPassed = false
    private var announcedSnapBack: SetupStep?
    /// Flips true once the load-time silent status read has LANDED. Before that,
    /// every already-granted step reads as "newly completed" against the empty
    /// `completedAtLastRefresh` it seeds — real state, not a real transition the
    /// user witnessed — so announcements, the re-front and the choreography all
    /// stay off until this is true. The sync first paint is not enough of a
    /// gate: `bluetoothStatus`/`remoteControlStatus` only reach their real value
    /// through the ASYNC read, so a pre-granted step would otherwise announce
    /// itself and re-front the window as the window opens.
    /// The edge sets themselves (`completedAtLastRefresh`, `deniedAtLastRefresh`,
    /// etc.) are seeded on those passes exactly as before.
    private var initialStatusesSettled = false

    /// The load-time status read's own task — the seam a headless walk awaits
    /// (``test_awaitInitialStatuses()``).
    private var initialStatusesTask: Task<Void, Never>?

    /// The active step (and whether the CTA exists) the keyboard focus was last
    /// placed for — focus moves on those transitions and at no other time.
    private var focusAnchorStep: SetupStep??
    private var focusAnchorHadCTA = false
    /// Whether the last paint had a primary button at all. A wait takes every
    /// button out of the layout, which takes the keyboard with them — so the
    /// paint that brings one BACK has to re-anchor, even though the step and the
    /// gate are both unchanged.
    private var focusAnchorHadPrimary = false

    /// Whether this presentation opened with every REQUIRED permission already
    /// granted and an optional step still undecided — the "you came back for
    /// the one you passed on" header. Fixed at init like the flow's own start
    /// position: a grant made later must not re-word the greeting.
    private let opensAsResume: Bool

    /// Polls the silent Accessibility trust read while the window is open, so a
    /// grant made in System Settings shows up even if `AXIsProcessTrusted()` only
    /// flips true a moment after the user returns (a re-focus check alone can miss
    /// that). Stops once granted.
    private var remoteControlPoll: Timer?

    /// Polls the PTP helper's `SMAppService.status` while the window is open, so
    /// approving it in Login Items (System Settings, not this window) is picked
    /// up without needing a re-focus. Stops once `.enabled`.
    private var ptpHelperPoll: Timer?

    public init(model: SetupModel,
                reason: OnboardingReason = .firstRun,
                onOpenSettings: @escaping (SystemSettingsPane) -> Void,
                onDone: @escaping () -> Void) {
        self.model = model
        // Built HERE, at presentation time and before anything can be granted:
        // the flow's start position is fixed at init from the first unmet
        // required step, and building it after a grant would read as a
        // re-entry and open on a different card.
        let flow = SetupFlowModel(setup: model)
        self.flow = flow
        self.reason = reason
        self.onOpenSettings = onOpenSettings
        self.onDone = onDone
        // "Everything required is in, one optional is still open" — the only
        // state where the welcome copy would be wrong in both directions.
        let optionalStillOpen = SetupFlowModel.skippableSteps.contains {
            !flow.isComplete($0) && !flow.skippedSteps.contains($0)
        }
        self.opensAsResume = reason == .firstRun
            && model.requiredPermissionsNotGranted().isEmpty
            && optionalStillOpen
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        remoteControlPoll?.invalidate()
        ptpHelperPoll?.invalidate()
        stuckPromptTimer?.invalidate()
        settingsTripTimer?.invalidate()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    public override func loadView() {
        let background = WarmCanvasView()
        background.translatesAutoresizingMaskIntoConstraints = false

        let spine = makeSpine()
        let hero = makeHeroPane()
        background.addSubview(spine)
        background.addSubview(hero)
        // The finale ripple radiates across the WHOLE window (owner call
        // 2026-08-12), not just the hero panel — so it fades before the window's
        // nearest edge, and passes faintly over the spine on the way out.
        // Nothing in the chromeless finale hierarchy clips, so the rings reach
        // here from where they live in the stage; this only supplies the bounds.
        demoPane.finaleRippleBounds = background

        let margin = Self.paneMargin
        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            background.heightAnchor.constraint(equalToConstant: Self.contentHeight),

            spine.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: margin),
            spine.widthAnchor.constraint(equalToConstant: Self.spineWidth),
            spine.topAnchor.constraint(equalTo: background.topAnchor, constant: margin),
            spine.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -margin),

            hero.leadingAnchor.constraint(equalTo: spine.trailingAnchor, constant: Self.paneGap),
            hero.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -margin),
            hero.topAnchor.constraint(equalTo: background.topAnchor, constant: margin),
            hero.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -margin),
        ])
        view = background
    }

    /// The spine: the hero header over six compact rows, GROUPED INSET —
    /// macOS's native shape for a status list (`DemoPaneView`'s own Login Items
    /// mock already draws it correctly): one rounded, bordered container, its
    /// rows abutting with a hairline between them, rather than six separately
    /// bordered cards with gaps — the "same-size icon + heading + text card"
    /// shape that reads as a generic cross-platform wizard (owner critique,
    /// Direction 04 grouped-inset pass). No buttons, no copy — everything a
    /// step SAYS lives in the ribbon now.
    private func makeSpine() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()

        let group = RoundedContainerView(fill: Tokens.Color.panel,
                                         border: Tokens.Color.hairline,
                                         radius: SetupSpineRowView.cornerRadius)
        // Clips every row's own fill/edge-bar to the group's rounded corners —
        // the first and last rows have no radius of their own (see
        // `SetupSpineRowView`), so this is what keeps them from squaring off
        // past the group's rim.
        group.wantsLayer = true
        group.layer?.masksToBounds = true

        spineStack = NSStackView()
        spineStack.orientation = .vertical
        spineStack.alignment = .leading
        // Zero: the hairline BETWEEN rows is drawn by a separator arranged
        // subview, not by gap-plus-border the way six separate cards were —
        // that gap is exactly what made the column read as six tiles.
        spineStack.spacing = 0
        spineStack.distribution = .fill
        spineStack.translatesAutoresizingMaskIntoConstraints = false
        for step in flow.steps {
            if !rows.isEmpty { addRowSeparator(to: spineStack) }
            let row = makeRow(for: step)
            rows[step] = row
            spineStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: spineStack.widthAnchor).isActive = true
        }
        addRowSeparator(to: spineStack)
        checkRow = SetupCheckRowView()
        spineStack.addArrangedSubview(checkRow)
        checkRow.widthAnchor.constraint(equalTo: spineStack.widthAnchor).isActive = true

        group.addSubview(spineStack)
        NSLayoutConstraint.activate([
            spineStack.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            spineStack.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            spineStack.topAnchor.constraint(equalTo: group.topAnchor),
            spineStack.bottomAnchor.constraint(equalTo: group.bottomAnchor),
        ])

        pane.addSubview(header)
        pane.addSubview(group)

        // Weakest constraint in the column: the spine hangs from the header and
        // the pane's lower slack falls below it.
        let groupAboveBottom = group.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor)
        groupAboveBottom.priority = .defaultLow

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            header.topAnchor.constraint(equalTo: pane.topAnchor),

            group.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            group.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            group.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            groupAboveBottom,
        ])
        return pane
    }

    /// A hairline between two spine rows, inset to the row's text column and
    /// full-bleed to the trailing edge — the same anatomy
    /// `DemoPaneView`'s grouped-list mock already draws for its own rows,
    /// which is what makes the group read as ONE list rather than six tiles
    /// glued together.
    private func addRowSeparator(to stack: NSStackView) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(box)
        let textLeading = SetupSpineRowView.horizontalInset + SetupSpineRowView.iconSide
            + SetupSpineRowView.iconGap
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: textLeading),
            box.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            box.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 1),
        ])
        stack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// The hero: one warm panel, read top to bottom (owner-approved 2026-08-12).
    ///
    /// 1. the HEAD block — headline over the why line, and nothing else;
    /// 2. the labelled PREVIEW FRAME, holding the drawn rehearsal;
    /// 3. the ribbon's lower region — a status line and a paragraph, for the
    ///    states that have to instruct rather than ask;
    /// 4. the BARE BOTTOM BAR — a hairline and the buttons, nothing else.
    ///
    /// The frame is the flexible one: the window is a fixed 820 × 560, so the
    /// head block and the bar take what their words need and the rehearsal gets
    /// everything left over.
    private func makeHeroPane() -> NSView {
        let pane = RoundedContainerView(fill: Tokens.Color.panel,
                                        border: Tokens.Color.hairline,
                                        radius: Tokens.Layout.Radius.row)
        heroHead = SetupHeroHeadView(width: SetupRibbonView.textWidth)
        previewFrame = SetupPreviewFrameView()
        demoPane = DemoPaneView()
        ribbon = SetupRibbonView()
        ribbon.onPrimary = { [weak self] in self?.ribbonPrimaryTapped() }
        ribbon.onSkip = { [weak self] in self?.ribbonSkipTapped() }
        ribbon.onQuietLink = { [weak self] in self?.ribbonQuietLinkTapped() }

        pane.addSubview(heroHead)
        pane.addSubview(previewFrame)
        pane.addSubview(ribbon)
        previewFrame.body.addSubview(demoPane)

        let padding = Self.heroPadding
        NSLayoutConstraint.activate([
            heroHead.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: padding),
            heroHead.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -padding),
            heroHead.topAnchor.constraint(equalTo: pane.topAnchor, constant: padding),

            previewFrame.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: padding),
            previewFrame.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -padding),
            previewFrame.topAnchor.constraint(equalTo: heroHead.bottomAnchor,
                                              constant: Self.heroHeadToFrameGap),
            previewFrame.bottomAnchor.constraint(equalTo: ribbon.topAnchor,
                                                 constant: -Self.heroFrameToRibbonGap),

            // Centred, never pinned: the pane owns its own size, and a
            // rehearsal taller than the frame is CLIPPED by the well rather
            // than fighting the fixed window for room.
            demoPane.centerXAnchor.constraint(equalTo: previewFrame.body.centerXAnchor),
            demoPane.centerYAnchor.constraint(equalTo: previewFrame.body.centerYAnchor),

            ribbon.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: padding),
            ribbon.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -padding),
            ribbon.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -padding),
        ])
        return pane
    }

    /// Interior padding of the hero pane. The preview frame's width is derived
    /// from it (`SetupRibbonView.textWidth`, itself `DemoPaneView.surfaceSize`).
    static let heroPadding: CGFloat = 22
    /// Air between the head block and the preview frame.
    static let heroHeadToFrameGap: CGFloat = 13
    /// Air between the preview frame and the ribbon under it.
    static let heroFrameToRibbonGap: CGFloat = 13

    private func makeHeader() -> NSView {
        // Show the BRAND MARK (not a generic glyph) — a stronger first
        // impression for a paid product. Deliberately not the OS app icon:
        // that tile belongs to Dock/Finder, while the mark is the identity we
        // control (see `BrandMark`). The icon stays as the fallback for a
        // build with no bundled asset.
        let tile = NSImageView()
        tile.image = BrandMark.image
            ?? NSApp?.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
        tile.imageScaling = .scaleProportionallyUpOrDown
        tile.setAccessibilityLabel("Audiout")
        tile.translatesAutoresizingMaskIntoConstraints = false

        titleLabel = NSTextField(labelWithString: "")
        // The window's own heading, so VoiceOver's rotor can find it. The raw
        // AX string, not `NSAccessibilityHeadingRole`: that constant is macOS 26+
        // and this app installs on 14.2.
        titleLabel.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        titleLabel.font = Tokens.Font.display
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.preferredMaxLayoutWidth = Self.spineWidth
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Plain "speakers", never "AirPlay" (spec §5.8, decision m). This one
        // label is also where a `.permissionLost` re-entry says what went off —
        // no separate banner view, so the layout is identical either way.
        subtitleLabel = NSTextField(wrappingLabelWithString: "")
        subtitleLabel.font = Tokens.Font.caption
        subtitleLabel.maximumNumberOfLines = 4
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.preferredMaxLayoutWidth = Self.spineWidth

        let stack = NSStackView(views: [tile, titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(12, after: tile)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 52),
            tile.heightAnchor.constraint(equalToConstant: 52),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    private func makeRow(for step: SetupStep) -> SetupSpineRowView {
        SetupSpineRowView(content: Self.content(for: step),
                          onPress: { [weak self] in self?.rowPressed(step) })
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Bind as soon as the view exists (not only in `viewWillAppear`, which a
        // headless test/harness never triggers) so a model status change — the
        // async audio probe resolving, the Bluetooth prompt being answered —
        // repaints the rows.
        model.onChange = { [weak self] in self?.refresh() }
        // Register the PTP helper daemon once, at load: unlike the probes,
        // registering shows no system prompt of its own, so it's safe to run
        // unconditionally rather than waiting for a tap.
        model.registerPTPHelper()
        // Reflect real current state up front — without this the Bluetooth row
        // paints undetermined even when the grant is already in place
        // (`bluetoothStatus` starts `.unknown`). Silent: never springs a prompt.
        // Held rather than fired and forgotten: what this read LANDS is the
        // window's opening state, not a transition, so nothing announces or
        // re-fronts until it has finished arriving.
        initialStatusesTask = Task { @MainActor in
            await model.refreshStatuses()
            initialStatusesSettled = true
            refresh(animated: false)
        }
        refresh(animated: false)
        startRemoteControlPoll()
        startPTPHelperPoll()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        // Re-attach on every open (a reused window) and re-read current status.
        model.onChange = { [weak self] in self?.refresh() }
        refreshStatuses()
        refresh(animated: false)
    }

    /// Re-derive every permission's live status (see ``SetupModel/refreshStatuses()``).
    /// Called on load, on appear, and — via the window controller — whenever the app
    /// regains focus, so returning from System Settings updates the rows to reality.
    /// Safe to call freely: it never springs a prompt on an un-engaged permission.
    public func refreshStatuses() {
        Task { @MainActor in await model.refreshStatuses() }
    }

    /// The window controller's half of a Settings-trip wait: the app losing
    /// the front is the only honest signal the trip really left (mirrors
    /// `OnboardingWindowController.isYieldingToSettings`).
    public func appDidResignActive() {
        if settingsTripStep != nil {
            settingsTripDeparted = true
            // The trip genuinely left, so the resign→activate pair owns the
            // wait from here and the ceiling has nothing left to catch.
            cancelSettingsTripTimer()
        }
        // Nothing to poll for while another app is frontmost — the return
        // re-read (`appDidBecomeActive`) is what picks up anything that changed
        // over there.
        remoteControlPoll?.invalidate()
        remoteControlPoll = nil
        ptpHelperPoll?.invalidate()
        ptpHelperPoll = nil
    }

    // MARK: The Settings-trip ceiling

    /// How long an armed Settings/Login Items trip may wait without the app ever
    /// losing the front. Past this the trip never really left — the destination
    /// was refused, or opened onto a window that was already showing — and the
    /// spinner would otherwise sit there for the rest of the presentation: the
    /// only other things that clear it are the step completing and a genuine
    /// return, and a poll that repaints only on a status TRANSITION means a
    /// deny-without-leaving produces neither.
    static let settingsTripCeiling: TimeInterval = 20
    private var settingsTripTimer: Timer?

    private func armSettingsTripTimer() {
        // Same rule as the stuck-prompt timer: wall-clock time means nothing to
        // a headless run, which fires it itself (`test_fireSettingsTripTimer`).
        guard !HeadlessRuntime.isActive else { return }
        settingsTripTimer?.invalidate()
        settingsTripTimer = Timer.scheduledTimer(withTimeInterval: Self.settingsTripCeiling,
                                                 repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireSettingsTripCeiling() }
        }
    }

    private func cancelSettingsTripTimer() {
        settingsTripTimer?.invalidate()
        settingsTripTimer = nil
    }

    private func fireSettingsTripCeiling() {
        cancelSettingsTripTimer()
        settingsTripStep = nil
        settingsTripDeparted = false
        refresh(animated: false)
    }

    /// Called on every app reactivation. A genuine return from an armed
    /// Settings trip awaits one status re-read and clears the wait whatever
    /// it finds — "we looked; nothing changed" stops the spinner honestly.
    /// Otherwise this is just the ordinary catching-up activation, so it does
    /// the plain silent re-read as before.
    public func appDidBecomeActive() {
        // Back in front — the polls have somewhere to land again.
        startRemoteControlPoll()
        startPTPHelperPoll()
        if settingsTripDeparted {
            settingsReturnTask = Task { @MainActor in
                await model.refreshStatuses()
                cancelSettingsTripTimer()
                settingsTripStep = nil
                settingsTripDeparted = false
                refresh(animated: false)
            }
        } else {
            refreshStatuses()
        }
    }

    /// Poll the silent Accessibility read every ~1.5 s until it's granted, so a
    /// toggle flipped in System Settings lands on the row even without a re-focus.
    private func startRemoteControlPoll() {
        guard remoteControlPoll == nil else { return }
        // Nothing left to watch for — the grant is already in.
        guard model.remoteControlStatus != .granted else { return }
        remoteControlPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.model.refreshRemoteControlStatus()
                if self.model.remoteControlStatus == .granted { timer.invalidate(); self.remoteControlPoll = nil }
            }
        }
    }

    /// Whether a PTP status read is already out — the launchd round-trip is
    /// slower than the 1.5 s tick on a loaded machine, and stacking reads would
    /// queue them up behind each other.
    private var ptpHelperReadInFlight = false

    /// Poll the PTP helper's `SMAppService.status` every ~1.5 s until it settles,
    /// so approving it in Login Items lands on the row without a re-focus. Same
    /// shape as `startRemoteControlPoll()`, with the read itself off the main
    /// thread (``SetupModel/refreshPTPHelperStatus()``).
    ///
    /// Two states end the poll: `.enabled` (the approval landed) and `.notFound`
    /// (the daemon isn't in the bundle — it cannot heal itself, so waiting for
    /// it would be a timer running forever).
    private func startPTPHelperPoll() {
        guard ptpHelperPoll == nil else { return }
        guard !Self.ptpPollIsSettled(model.ptpHelperStatus) else { return }
        ptpHelperPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard !self.ptpHelperReadInFlight else { return }
                self.ptpHelperReadInFlight = true
                Task { @MainActor in
                    await self.model.refreshPTPHelperStatus()
                    self.ptpHelperReadInFlight = false
                    if Self.ptpPollIsSettled(self.model.ptpHelperStatus) {
                        timer.invalidate()
                        self.ptpHelperPoll = nil
                    }
                }
            }
        }
    }

    /// Whether the helper's status is one the poll can stop on.
    private static func ptpPollIsSettled(_ status: PTPHelperStatus) -> Bool {
        status == .enabled || status == .notFound
    }

    // MARK: Step copy

    /// The per-step copy. THREE title tables, each sized to its own place: the
    /// HERO's headline + why line (owner-verbatim — what a first ask shows), the
    /// ribbon's `activeTitle` sentence, and the SPINE's short form for the
    /// 288 pt column. Change one and check the others.
    ///
    /// The DETAIL strings are still reused verbatim from the pre-sequential
    /// rows — each one is TCC-framing tested — but a FIRST ask no longer shows
    /// one: they are the recovery states' copy now (denied, permission-lost, a
    /// wait, a stuck dialog), where the words are the instruction.
    static func content(for step: SetupStep) -> SetupCardContent {
        switch step {
        case .audio:
            return SetupCardContent(
                step: step,
                symbolName: "waveform",
                iconColor: Tokens.Color.permissionSystemAudio,
                activeTitle: "Let Audiout hear your Mac's sound",
                completedTitle: "Audiout can now hear your Mac's sound",
                // Outcome-framed reassurance FIRST (spec §5.8 house voice: the
                // OS prompt will say "screen recording", so defuse it here —
                // the copy names the AUDIO half, which is all we ask for),
                // then the honest heads-up about the confirmation tone the
                // probe really does play.
                detail: "macOS calls this audio recording. Your audio flows "
                    + "straight to your speakers — nothing is stored or sent. "
                    + "Allowing plays a brief tone to confirm it's working.",
                heroHeadline: "Hear your Mac's sound",
                // The tone warning rides the WHY line, which is the one piece of
                // copy a first ask still shows (the deleted first-ask body is
                // not coming back): the rehearsal above it draws the dialog, and
                // no picture can warn about a sound.
                whyLine: "Audiout needs this to send your music to your speakers. "
                    + "Allowing plays a brief tone to confirm it's working.",
                allowTitle: "Enable System Audio",
                isSkippable: false,
                spineAskTitle: "Hear your Mac's sound",
                spineDoneTitle: "Hearing your Mac's sound")
        case .localNetwork:
            return SetupCardContent(
                step: step,
                symbolName: "wifi",
                iconColor: Tokens.Color.permissionLocalNetwork,
                activeTitle: "Find the speakers on your Wi\u{2011}Fi",
                // Never used: Local Network's completed title is the found
                // count (`SetupCardContent.title(for:foundSpeakers:)`), because
                // a checkmark for a permission macOS refuses to confirm would
                // be a claim we can't back.
                completedTitle: "Found your speakers",
                // Plain "speakers", never "AirPlay", in onboarding copy (spec
                // §5.8, decision m). U+2011 non-breaking hyphen keeps "Wi‑Fi"
                // from wrapping to an orphan "Fi."
                detail: "Find the speakers on your Wi\u{2011}Fi so they show up "
                    + "in your list.",
                heroHeadline: "Find speakers on your Wi\u{2011}Fi",
                whyLine: "Audiout needs this to reach the speakers on your network.",
                allowTitle: "Enable Local Network",
                isSkippable: false,
                spineAskTitle: "Find speakers on Wi\u{2011}Fi",
                spineDoneTitle: "Speakers already reachable")
        case .bluetooth:
            return SetupCardContent(
                step: step,
                // SF Symbols ships no Bluetooth rune, so the tile carries the
                // system's own official one (`NSImage.bluetoothTemplateName`
                // via `bluetoothRuneImage`). The symbol name below is the
                // FALLBACK the tile draws if that image ever fails to load —
                // not a dead value.
                symbolName: "dot.radiowaves.right",
                customIcon: bluetoothRuneImage(height: 13),
                // The rune wears the official Bluetooth SIG brand blue, not a
                // warmed `permission*` hue — rationale on the token.
                iconColor: Tokens.Color.bluetoothBrand,
                activeTitle: "Let Audiout use Bluetooth speakers",
                completedTitle: "Audiout can now use Bluetooth speakers",
                detail: "Reconnect a paired Bluetooth speaker that's switched "
                    + "off, straight from Audiout. Without this you can still "
                    + "use one that's already connected.",
                heroHeadline: "Use Bluetooth speakers",
                whyLine: "Audiout needs this to stream to Bluetooth speakers and "
                    + "wake ones that are off.",
                allowTitle: "Enable Bluetooth Access",
                isSkippable: true,
                spineAskTitle: "Bluetooth speakers",
                spineDoneTitle: "Bluetooth speakers")
        case .speakerSync:
            return SetupCardContent(
                step: step,
                symbolName: "clock.arrow.2.circlepath",
                iconColor: Tokens.Color.permissionSpeakerSync,
                activeTitle: "Keep your speakers in perfect time",
                completedTitle: "Your speakers stay in perfect time",
                detail: "Your speakers play in perfect time by sharing one "
                    + "clock, through a small helper. Approve it once in Login Items.",
                heroHeadline: "Keep speakers in perfect time",
                whyLine: "A small helper shares one clock so your speakers never drift.",
                allowTitle: "Turn On at Login",
                // Skippable (P0-1): approval lives in Login Items, where macOS
                // can simply refuse — and without an exit an unapproved helper
                // locked the gate with nothing to press. The why line above
                // already names what a skip forfeits (speakers may drift).
                isSkippable: true,
                spineAskTitle: "Keep speakers in time",
                spineDoneTitle: "Speakers stay in time")
        case .remoteControl:
            return SetupCardContent(
                step: step,
                symbolName: "accessibility",
                iconColor: Tokens.Color.permissionRemoteControl,
                activeTitle: "Control playback with your volume keys",
                completedTitle: "Your volume keys control Audiout",
                detail: "Use your volume keys while Audiout is your output "
                    + "device, and press play or pause on a speaker to control "
                    + "your Mac.",
                heroHeadline: "Use your volume keys",
                whyLine: "Audiout needs this so your volume keys keep working while "
                    + "it's your output.",
                allowTitle: "Set Up Remote Control\u{2026}",
                isSkippable: true,
                spineAskTitle: "Volume-key control",
                spineDoneTitle: "Volume-key control")
        case .usageStats:
            return SetupCardContent(
                step: step,
                symbolName: "chart.bar.xaxis",
                iconColor: Tokens.Color.permissionUsageStats,
                activeTitle: "Share anonymous usage counts",
                completedTitle: "Audiout counts feature use, anonymously",
                detail: "Audiout counts which features get used. No audio, "
                    + "speaker names, network details or license key ever "
                    + "leave your Mac.",
                // What the button gets: not a capability for the user, and the
                // copy doesn't pretend otherwise. This is the one card where
                // the person being helped is the one who wrote the app, and
                // saying so plainly is what earns the yes.
                heroHeadline: "Help make Audiout better",
                // This is the ONLY place the never-sent promise is made now
                // that the card below is a two-button dialog rather than an
                // itemised ledger. The deleted-body rule still holds — the
                // picture shows the SHAPE of the decision and cannot show its
                // terms, so the terms ride the why line.
                // The WHY, not the terms: the card this ask raises carries the
                // privacy fence in full, and it appears directly under this
                // line on the stage — saying it in both read as a stutter.
                whyLine: "Knowing which features get used is what decides "
                    + "what gets built next.",
                // "Share", matching the Settings › General toggle it is the
                // same switch as. "Counts" rather than "statistics" because
                // counts is what they are and the shorter word is the plainer
                // one.
                allowTitle: "Share Usage Counts",
                isSkippable: true,
                spineAskTitle: "Usage statistics",
                spineDoneTitle: "Usage statistics")
        }
    }

    // MARK: State

    /// The step the flow is on. Normally the flow model's own answer; a failed
    /// Done verification overrides it (see ``snapBackStep``).
    private var displayedActiveStep: SetupStep? {
        if let snapBackStep, !flow.isComplete(snapBackStep) { return snapBackStep }
        return flow.activeStep
    }

    /// Repaint everything from the two models.
    ///
    /// - Parameter animated: `nil` derives it — the grant choreography runs on
    ///   the edge where a step becomes complete, and only on a window that is
    ///   really on screen with Reduce Motion off. Callers pass `false` for the
    ///   initial build and `true`/`canAnimate` for a UI-initiated change (a skip,
    ///   a browse, a snap-back) that isn't a grant.
    private func refresh(animated: Bool? = nil) {
        let completedNow = Set(flow.steps.filter { flow.isComplete($0) })
        let newlyCompleted = completedNow.subtracting(completedAtLastRefresh)
        // Nothing the OPENING state lands is a transition, so the initial read
        // paints settled however it arrives.
        let shouldAnimate = animated ?? (!newlyCompleted.isEmpty && canAnimate && initialStatusesSettled)
        completedAtLastRefresh = completedNow

        // A grant lands while the user is looking at System Settings or a TCC
        // prompt — pull ourselves back to the front FIRST, so the rest of the
        // choreography happens somewhere the user can see it. A permission that
        // was already in place when the window opened is not that.
        if !newlyCompleted.isEmpty, initialStatusesSettled { returnToFront() }
        if let snapBackStep, flow.isComplete(snapBackStep) { self.snapBackStep = nil }

        // A browse is a reading position on a DECIDED row, and it yields to
        // anything that actually moved the flow.
        if !newlyCompleted.isEmpty { browseStep = nil }
        if let browsed = browseStep, !flow.isComplete(browsed) { browseStep = nil }

        // A Settings/Login Items trip's wait ends the instant its step
        // completes — the grant landed, so there is nothing left to wait for.
        if let settingsTripStep, flow.isComplete(settingsTripStep) {
            self.settingsTripStep = nil
            settingsTripDeparted = false
            cancelSettingsTripTimer()
        }

        let active = displayedActiveStep
        for step in flow.steps {
            rows[step]?.apply(state(for: step, active: active),
                              // No browse ever runs on an ungated OS (macOS
                              // 14), so there is no count to report there —
                              // nil, where zero means a real browse that saw
                              // nothing.
                              foundSpeakers: model.isLocalNetworkGated ? flow.localNetworkFoundSpeakers : nil,
                              isLive: step == active,
                              isBrowseSelected: step == browseStep,
                              isBroken: isBroken(step),
                              isWaiting: step == active && isAwaitingOutcome(step),
                              animated: shouldAnimate)
        }
        runFinalCheckIfReady()
        checkRow.apply(displayedCheckState)
        refreshHero(active: active, animated: shouldAnimate)
        let content = ribbonContent(active: active)
        heroHead.apply(content)
        ribbon.apply(content)
        refreshHeaderMessage()
        announceTransitions(newlyCompleted: newlyCompleted, active: active)
        refreshKeyboardFocus(active: active)
    }

    /// The hero pane's two halves: which rehearsal is on stage, and whether the
    /// stage is standing back for a real dialog.
    private func refreshHero(active: SetupStep?, animated: Bool) {
        if let browsed = browseStep {
            // Two steps whose browse is NOT the Settings pane. Usage
            // Statistics has no such pane at all, so it re-shows its own card.
            // Awkward cell B: a
            // GRANTED Local Network on macOS 14 was never gated, so there is
            // no privacy pane to show either, and the dialog it never raised
            // is the honest picture, at rest.
            let mode: DemoMode
            if browsed == .usageStats {
                mode = .prompt
            } else if browsed == .localNetwork, !model.isLocalNetworkGated {
                mode = .prompt
            } else {
                mode = .settings
            }
            demoPane.show(step: browsed, mode: mode, animated: animated,
                          restingSwitchOn: mode == .settings, asBrowse: true)
            previewFrame.caption = Self.previewFrameLabel(for: browsed)
            previewFrame.spokenCaption = nil
            previewFrame.isChromeless = false
        } else if let active {
            demoPane.show(step: active, mode: demoMode(for: active), animated: animated)
            previewFrame.caption = Self.previewFrameLabel(for: active)
            // Remote Control's first ask is the one rehearsal that INSTRUCTS:
            // two surfaces in sequence, with the wrong button drawn ghosted.
            // None of that reaches VoiceOver, so the caption says it instead.
            previewFrame.spokenCaption =
                (active == .remoteControl && demoMode(for: active) == .prompt)
                ? Self.remoteControlSpokenCaption : nil
            previewFrame.isChromeless = false
        } else if flow.finalCheckState == .passed {
            // The beat: the pane HOLDS while the check is pending/running — the
            // finale (crossfade + one-shot ripple) and the CTA arrive together
            // on the pass, in this same repaint.
            demoPane.show(step: active, mode: demoMode(for: active), animated: animated)
            // The finale card is OURS, not macOS's: captioning it would be a
            // lie, and framing it would box in the moment. The frame goes away
            // chrome and all, so the ripple radiates unclipped.
            previewFrame.caption = nil
            previewFrame.spokenCaption = nil
            previewFrame.isChromeless = true
        } else {
            demoPane.holdCurrentFrame()
            previewFrame.spokenCaption = nil
        }
        let waiting = active.map { isPrompting($0) } ?? false
        demoPane.setStageDimmed(waiting, animated: canAnimate)
        // Last: a resolve edge pays back the deferred re-front, and the ribbon
        // above has already been painted without the escape-hatch hint.
        syncPromptInFlight()
    }

    // MARK: The final check

    /// The running check's work — the UI half of single-flight (same idea as
    /// ``allowInFlight``), and the seam a headless walk awaits
    /// (``test_awaitFinalCheck()``).
    private var finalCheckTask: Task<Void, Never>?

    /// What the check row shows. The model owns the state; the task handle
    /// covers the paint between starting the task and the model's own
    /// `.running` becoming observable.
    private var displayedCheckState: SetupFinalCheckState {
        let state = flow.finalCheckState
        if state == .pending, finalCheckTask != nil, flow.isReadyForFinalCheck { return .running }
        return state
    }

    /// Start the automatic check the moment every row is decided. A failure
    /// uses the existing snap-back machinery — the offending step re-opens and
    /// the row reverts to pending (the readiness conjunct in
    /// `SetupFlowModel.finalCheckState` does the reverting).
    private func runFinalCheckIfReady() {
        guard finalCheckTask == nil, flow.isReadyForFinalCheck,
              flow.finalCheckState != .passed else { return }
        finalCheckTask = Task { @MainActor in
            let verdict = await flow.runFinalCheck()
            finalCheckTask = nil
            // A snap-back must land on a VISIBLE stage: the browse yields to it.
            if case .unmet(let step) = verdict { snapBackStep = step; browseStep = nil }
            refresh(animated: canAnimate)
        }
    }

    private func state(for step: SetupStep, active: SetupStep?) -> SetupCardState {
        if step == active { return .active }
        guard flow.isComplete(step) else {
            return flow.skippedSteps.contains(step) ? .skipped : .pending
        }
        // Auto-passed, not granted: this OS has no such permission to give, so
        // the row says why instead of claiming a grant nobody made.
        if step == .audio, model.audioStatus == .unsupported {
            return .autoPassed(note: Self.audioAutoPassNote)
        }
        // Same shape for Speaker Sync's two unfixable states: the daemon isn't
        // in the bundle, or registering it threw. `SetupFlowModel.isComplete`
        // is what routes those here — the row auto-passes so the gate can open,
        // and the note is the whole explanation.
        if step == .speakerSync,
           model.ptpHelperStatus == .notFound || model.ptpHelperRegistrationFailed {
            return .autoPassed(note: Self.speakerSyncAutoPassNote)
        }
        return .completed
    }

    static let audioAutoPassNote = "Requires macOS 14.2 or later"
    static let speakerSyncAutoPassNote = "Couldn't be turned on"

    /// Whether this step's Allow has spent its prompt, so the next click is the
    /// Settings deep link instead (the two-mode Allow). Kept in lockstep with
    /// ``SetupFlowModel/allow(_:)``'s own preflight — the button must not
    /// promise a prompt the model will refuse to fire.
    private func offersSettingsFallback(_ step: SetupStep) -> Bool {
        switch step {
        case .audio:         return model.audioStatus == .denied
        // A PROVEN refusal spends this prompt like any other (the browse would
        // only be refused again). Short of that it is NOT two-mode: this step's
        // prompt IS the browse, so an empty browse keeps its retry and offers
        // the pane beside it (`offersSettingsLink`).
        case .localNetwork:  return model.localNetworkStatus == .denied
        case .bluetooth:     return model.bluetoothStatus == .denied
        // Login Items is Speaker Sync's only mode — its Allow is already the
        // Settings button, so there is no second mode to switch into.
        case .speakerSync:   return false
        // Remote Control's prompt is spent once it has been asked: `.requested`
        // means "asked, and Accessibility still isn't trusted", and asking again
        // silently no-ops. The retry deep-links to the Accessibility pane.
        case .remoteControl: return model.remoteControlStatus == .requested
        // Nothing to spend and nowhere to fall back TO: the answer is given
        // right here, and a "no" is an answer rather than a refusal to route
        // around.
        case .usageStats:    return false
        }
    }

    /// Local Network was asked and nothing answered. Something still has to be
    /// able to re-ask, which is why this step keeps a primary retry instead of
    /// flipping to Settings.
    private func localNetworkUnanswered(_ step: SetupStep) -> Bool {
        step == .localNetwork && step == displayedActiveStep
            && model.localNetworkStatus == .requested
    }

    /// Whether the ribbon shows the demoted "Open Settings…" beside its primary.
    /// Local Network only, and only where that pane exists at all — macOS 14
    /// has no Local Network privacy gate, so there is nowhere to send anyone.
    private func offersSettingsLink(_ step: SetupStep) -> Bool {
        if isStuck(step) { return true }
        return localNetworkUnanswered(step) && model.isLocalNetworkGated
    }

    /// Whether this step is waiting on a prompt or probe it fired — the dimmed
    /// stage, the spinner, and no buttons. Bluetooth's wait is the model's to
    /// report: its prompt answers on a callback, so the click returns long
    /// before the user has answered anything.
    private func isPrompting(_ step: SetupStep) -> Bool {
        if allowInFlight == step { return true }
        return step == .bluetooth && model.isPrimingBluetooth
    }

    /// Whether this row's ask is unresolved and the spine should show the
    /// waiting spinner: a prompt in flight, Local Network's verifying tail
    /// (which `promptInFlightStep` deliberately excludes, but the row still
    /// hasn't heard back), or an armed Settings/Login Items trip.
    private func isAwaitingOutcome(_ step: SetupStep) -> Bool {
        if isPrompting(step) { return true }
        if step == .localNetwork, model.localNetworkPhase != .idle { return true }
        return settingsTripStep == step
    }

    /// Whether this step's own permission is PROVABLY refused. Only three steps
    /// have a refusal we can read: Speaker Sync has no denied state at all, and
    /// Accessibility never reports one (an unanswered ask stays `.requested`).
    private func isProvablyDenied(_ step: SetupStep) -> Bool {
        switch step {
        case .audio:         return model.audioStatus == .denied
        case .localNetwork:  return model.localNetworkStatus == .denied
        case .bluetooth:     return model.bluetoothStatus == .denied
        case .speakerSync, .remoteControl, .usageStats: return false
        }
    }

    /// Whether this step is one the `.permissionLost` re-entry named and which
    /// is STILL missing — the row that opened this window.
    private func isPermissionLost(_ step: SetupStep) -> Bool {
        guard case .permissionLost(let originallyUnmet) = reason,
              let permission = Self.requiredPermission(for: step),
              originallyUnmet.contains(permission) else { return false }
        return model.requiredPermissionsNotGranted().contains(permission)
    }

    /// Whether the row draws BROKEN: something that was on is off now, or the
    /// live step has just been refused. Either way it is the one row on the
    /// spine asking to be looked at.
    private func isBroken(_ step: SetupStep) -> Bool {
        if step == displayedActiveStep, isProvablyDenied(step) { return true }
        return isPermissionLost(step)
    }

    static func requiredPermission(for step: SetupStep) -> RequiredPermission? {
        switch step {
        case .audio:         return .audioCapture
        case .localNetwork:  return .localNetwork
        case .speakerSync:   return .ptpHelper
        // Neither is a `RequiredPermission` — both are skippable, and a
        // revocation of one never re-opens this window.
        case .bluetooth, .remoteControl, .usageStats: return nil
        }
    }

    private func demoMode(for step: SetupStep?) -> DemoMode {
        guard let step else { return .settled }
        // Usage Statistics wears the privacy card's two-button SHAPE — the
        // decision has that shape — but the card is ours, so the frame drops
        // its macOS caption (see `previewFrameLabel(for:)`).
        if step == .usageStats { return .prompt }
        // Speaker Sync has no prompt at all — Login Items is the only surface
        // it ever shows the user.
        if step == .speakerSync { return .settings }
        // Local Network's prompt is spent once a browse has run, so the pane it
        // now offers is the surface worth showing — even though the primary
        // button stays a retry.
        if offersSettingsLink(step) { return .settings }
        return offersSettingsFallback(step) ? .settings : .prompt
    }

    /// Whether the choreography may run: a real, on-screen window with Reduce
    /// Motion off. Everywhere else every beat is an instant swap, so steady
    /// states (first render, snapshots, headless tests, an occluded window)
    /// render settled.
    private var canAnimate: Bool {
        guard !HeadlessRuntime.isActive,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window = view.window, window.isVisible else { return false }
        return window.occlusionState.contains(.visible)
    }

    // MARK: The in-flight prompt

    /// The step whose system dialog is up and unanswered, if any.
    ///
    /// Bluetooth's wait is the model's to report: its prompt answers on a
    /// callback, so the Allow click returns long before the user has decided.
    /// Everything else is covered by ``allowInFlight`` for its whole ask.
    ///
    /// Local Network is the one step whose `allowInFlight` OUTLIVES its dialog:
    /// once the answer lands, the prime spends up to a few more seconds settling
    /// the speaker count (`localNetworkPhase == .verifying`). That tail has no
    /// dialog on screen to go quiet for, so it must NOT count as in flight —
    /// in-flight is what suppresses click activation, refuses the ✕, and (under
    /// the since-removed level demote, where this was found live as "the setup
    /// drops to the background right after I click Allow") buried the window
    /// for the whole settle. The quiet ends the instant the user answers, not
    /// seconds later when the count finishes.
    private var promptInFlightStep: SetupStep? {
        if let allowInFlight {
            if allowInFlight == .localNetwork, model.localNetworkPhase == .verifying { return nil }
            return allowInFlight
        }
        return model.isPrimingBluetooth ? .bluetooth : nil
    }

    /// Whether a system permission dialog this flow raised is still unanswered.
    ///
    /// **Everything that pulls focus stays off while this is true.** Another
    /// process fighting a TCC dialog for input focus is what leaves it frozen
    /// and unclickable — and this app was doing it two ways at once (the
    /// re-front on every grant, and the window's force-activate on mouse-down).
    /// The window LEVEL is not one of them: it stays `.floating` for the whole
    /// ask (see `OnboardingWindowController.setPromptInFlight`).
    private var isPromptInFlight: Bool { promptInFlightStep != nil }

    /// The last value pushed to the window controller, so the level yield and
    /// its restore fire on the EDGE rather than on every repaint.
    private var wasPromptInFlight = false

    /// A return-to-front refused because a dialog was still up. At most one is
    /// owed, and it fires when the flow next has no prompt in flight.
    private var returnToFrontIsDeferred = false

    /// Push the edge, and pay back a deferred re-front once the prompt is
    /// really resolved (granted, denied, or timed out).
    private func syncPromptInFlight() {
        let inFlight = isPromptInFlight
        guard inFlight != wasPromptInFlight else { return }
        wasPromptInFlight = inFlight
        onPromptInFlightChanged?(inFlight)
        if inFlight {
            // The buttons have just left the layout and the stage has dimmed —
            // both invisible to VoiceOver, which would otherwise sit in silence
            // for the whole wait.
            announce(Self.waitingStatus)
            startStuckPromptTimer()
        } else {
            closeRefusedDuringPrompt = false
            cancelStuckPromptTimer()
            if returnToFrontIsDeferred { returnToFront() }
        }
    }

    /// Pull the window back in front of whatever the user was just in (a TCC
    /// prompt, System Settings) and restore keyboard focus.
    private func returnToFront() {
        // A dialog is still up: taking the front now is what leaves it dimmed
        // and unclickable. Owed instead, and paid exactly once on resolve.
        guard !isPromptInFlight else { returnToFrontIsDeferred = true; return }
        returnToFrontIsDeferred = false
        // Counted before the headless bail-out: activation itself is invisible
        // to a headless test, but WHETHER to activate is what
        // `shouldReturnToFront(after:)` decides.
        test_returnToFrontCount += 1
        guard !HeadlessRuntime.isActive else { return }
        NSApp?.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: The stuck-dialog escape hatch

    /// How long an unanswered dialog is normal before the ribbon offers a way
    /// round it. Long enough that reading the prompt isn't rushed, short enough
    /// that a frozen dialog doesn't end the setup.
    static let stuckPromptDelay: TimeInterval = 20

    /// The steps whose ask raises a system dialog that can freeze. Speaker Sync
    /// and Remote Control are excluded because neither waits on one: both send
    /// the user to System Settings themselves.
    static let stuckPromptSteps: Set<SetupStep> = [.audio, .localNetwork, .bluetooth]

    /// The step the timer has flagged. Only ever read through ``isStuck(_:)``,
    /// which re-checks that the SAME prompt is still in flight — so the hint
    /// disappears on resolve without depending on repaint ordering.
    private var stuckPromptStep: SetupStep?
    private var stuckPromptTimer: Timer?

    /// Whether the ribbon should offer the escape hatch. UI only — nothing here
    /// re-asks or re-probes anything.
    private func isStuck(_ step: SetupStep) -> Bool {
        stuckPromptStep == step && promptInFlightStep == step
    }

    /// - Parameter delay: how long to wait. Defaults to ``stuckPromptDelay``;
    ///   a refused ✕ re-arms at ``stuckPromptDelayAfterCloseAttempt``, because
    ///   reaching for the close box IS the user saying the dialog has stopped
    ///   being something they can answer.
    private func startStuckPromptTimer(delay: TimeInterval = OnboardingViewController.stuckPromptDelay) {
        // Wall-clock time means nothing to a headless run — a loaded test
        // machine can hold an ask past the delay and grow a surprise button
        // mid-assertion. Tests fire it themselves (`test_fireStuckPromptTimer`).
        guard !HeadlessRuntime.isActive else { return }
        guard let step = promptInFlightStep, Self.stuckPromptSteps.contains(step) else { return }
        stuckPromptTimer?.invalidate()
        stuckPromptTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                                repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.markPromptStuck() }
        }
    }

    private func cancelStuckPromptTimer() {
        stuckPromptTimer?.invalidate()
        stuckPromptTimer = nil
        stuckPromptStep = nil
    }

    private func markPromptStuck() {
        guard let step = promptInFlightStep, Self.stuckPromptSteps.contains(step) else { return }
        stuckPromptStep = step
        // The hint and its way-round arrive together on screen; without this
        // they arrive silently, in a state the user is already stuck in.
        announce(Self.stuckPromptHint)
        refresh(animated: false)
    }

    /// The escape hatch's line. It names the symptom the user is looking at,
    /// and the "Open Settings…" link beside it is the way through.
    static let stuckPromptHint = "Dialog not responding?"

    // MARK: The refused ✕

    /// Whether the user tried to close the window while a dialog was unanswered
    /// and the window refused. Cleared on the prompt-resolved edge.
    private var closeRefusedDuringPrompt = false

    /// What the refusal says. The ✕ doing nothing is the symptom; this is the
    /// reason, and it points at the window the user has to deal with first.
    static let closeRefusedStatus = "Answer the macOS dialog first \u{2014} it's on screen now."

    /// The shortened stuck-dialog delay after a refused ✕ — reaching for the
    /// close box is itself evidence the dialog has stopped being answerable, so
    /// the way round shouldn't be a further 20 s away.
    static let stuckPromptDelayAfterCloseAttempt: TimeInterval = 5

    /// The window controller's half of a refused ✕: say why, and bring the
    /// escape hatch forward.
    public func noteCloseRefused() {
        closeRefusedDuringPrompt = true
        if stuckPromptStep == nil {
            startStuckPromptTimer(delay: Self.stuckPromptDelayAfterCloseAttempt)
        }
        announce(Self.closeRefusedStatus)
        refresh(animated: false)
    }

    // MARK: The ribbon's copy

    /// The one line every unanswered system dialog gets. It names what the user
    /// is waiting ON — themselves, in another window — rather than implying the
    /// app is busy.
    static let waitingStatus = "Waiting for your answer \u{2014} the real dialog is on screen now."
    /// `.requested` means the ask went out and NOTHING answered it — the
    /// permission dialog is presumably still up, or its window expired. It does
    /// NOT mean the browse found no speaker (a browse that reached the network
    /// proves the grant, speakers or not), so the line must not invent a
    /// switched-off speaker as the reason; it names the actual state and leaves
    /// both doors open.
    static let localNetworkUnansweredStatus = "Nothing has answered yet. If the permission "
        + "dialog is open, choose Allow — or try again."
    /// Speaker Sync's recovery, for a trip to Login Items that came back with
    /// the switch still off. The status names the place people actually go
    /// looking; the body repeats the step's own explanation and then names the
    /// cost of skipping, since a skip is now on offer here.
    static let speakerSyncRecoveryStatus = "It isn't on yet \u{2014} the switch is in Login Items, "
        + "not Privacy & Security."
    static let speakerSyncRecoveryBody = "Your speakers play in perfect time by sharing one clock, "
        + "through a small helper. Approve it once in Login Items. You can skip this for now \u{2014} "
        + "without it your speakers may drift apart."
    static let alertSymbol = "exclamationmark.triangle.fill"
    /// The gate's CTA (owner copy 2026-08-11: closing setup is what starts the
    /// deferred audio engine, so the button names that). Named once — a browse
    /// opened after the gate builds the same button.
    static let ctaTitle = "Start listening"
    /// The preview frame's caption — the sentence the layout used to spend a
    /// whole ribbon line on ("This is what macOS will ask you next."), said by
    /// the frame instead.
    static let previewFrameLabel = "You'll see this from macOS"
    /// The frame's caption, per step. Its whole job is to say WHOSE surface is
    /// inside it, so Usage Statistics gets NONE: that card wears the privacy
    /// dialog's two-button shape because the decision has that shape, but macOS
    /// raises nothing here and captioning it "You'll see this from macOS" would
    /// be a claim we can't back. Same rule the finale already follows — its own
    /// card is ours, so it is uncaptioned too.
    static func previewFrameLabel(for step: SetupStep) -> String? {
        step == .usageStats ? nil : previewFrameLabel
    }
    /// What VoiceOver hears in place of that caption on Remote Control's first
    /// ask — the one rehearsal whose two surfaces and ghosted Deny ARE the
    /// instruction, and which a screen reader cannot see.
    static let remoteControlSpokenCaption = "You'll see this from macOS: an alert, then System "
        + "Settings. Choose Open System Settings \u{2014} not Deny \u{2014} then turn Audiout on "
        + "in the list."

    /// Everything the ribbon shows, for whatever the window is doing right now.
    private func ribbonContent(active: SetupStep?) -> RibbonContent {
        if let browsed = browseStep {
            var content = browseRibbonContent(browsed)
            // The gate contract, unchanged in meaning: the CTA exists iff the
            // final check passed — so a browse opened AFTER the gate keeps it.
            // Browsing is a reading position, and taking the CTA away for it
            // would read as the gate closing on something the user only looked
            // at. The row's own quiet "Open Settings…" sits beside it.
            if flow.isDoneAvailable { content.primary = (Self.ctaTitle, .cta) }
            return content
        }
        if flow.isDoneAvailable {
            var content = RibbonContent()
            content.primary = (Self.ctaTitle, .cta)
            return content
        }
        // The hold beat: every row is decided and the check is still running.
        // No CTA, no ask — the payoff waits for the pass.
        guard let active else { return RibbonContent() }
        return activeRibbonContent(active)
    }

    private func activeRibbonContent(_ step: SetupStep) -> RibbonContent {
        var content = RibbonContent()
        let copy = Self.content(for: step)
        // The headline is the step's IDENTITY, so it holds in every one of its
        // states — a wait, a refusal and a re-entry are all still this step.
        // Only the FIRST ask adds the why line under it: once a state has to
        // instruct, its status and body carry the words instead.
        content.headline = copy.heroHeadline

        // A wait takes every button away: the answer is somewhere else now.
        if step == .localNetwork, model.localNetworkPhase == .verifying {
            content.status = (nil, "Checking your network\u{2026}", Tokens.Color.label2, true)
            content.body = Self.ribbonBody(copy.detail)
            return content
        }
        if isPrompting(step) || (step == .localNetwork && model.localNetworkPhase == .waitingForAnswer) {
            // The escape hatch: after `stuckPromptDelay` with no answer, the
            // wait names the symptom and demotes a way round the frozen dialog.
            if isStuck(step) {
                content.status = (Self.alertSymbol, Self.stuckPromptHint,
                                  Tokens.Color.label2, false)
                content.body = Self.ribbonBody(copy.detail)
                content.quietLink = "Open Settings…"
                return content
            }
            // A refused ✕ replaces the wait's line with the reason it was
            // refused. The spinner stays: we are still waiting on the same
            // dialog, and only the words have something new to say.
            content.status = (nil,
                              closeRefusedDuringPrompt ? Self.closeRefusedStatus : Self.waitingStatus,
                              Tokens.Color.label2, true)
            content.body = Self.ribbonBody(copy.detail)
            return content
        }

        // Something that was ON is off now — the reason this window re-opened.
        if isPermissionLost(step) {
            content.status = (Self.alertSymbol, "This was on \u{2014} macOS says it's off now.",
                              Tokens.Color.label2, false)
            content.body = Self.ribbonBody(
                "Everything else you set up is still in place. Turn **Audiout** back on under "
                + "\(Self.settingsPath(for: step)) — this is the only switch to flip.")
            content.primary = (step == .speakerSync ? "Open Login Items…"
                                                    : "Open Settings…", .prominent)
            return content
        }

        // Speaker Sync came back from Login Items still unapproved — the state
        // that had no words at all (P0-1). It says where the switch really is
        // (users look for it under Privacy & Security, where it isn't), offers
        // the trip again, and offers the way past.
        if step == .speakerSync, didTripLoginItems,
           model.ptpHelperStatus == .requiresApproval {
            content.status = (Self.alertSymbol, Self.speakerSyncRecoveryStatus,
                              Tokens.Color.label2, false)
            content.body = Self.ribbonBody(Self.speakerSyncRecoveryBody)
            content.primary = ("Open Login Items…", .prominent)
            content.showsSkip = true
            return content
        }

        // A refusal. macOS only asks once, so the honest next move is a switch.
        if isProvablyDenied(step) {
            content.status = (Self.alertSymbol,
                              "You chose Don't Allow. macOS only asks once \u{2014} from here it's "
                              + "a switch in System Settings.", Tokens.Color.label2, false)
            content.body = Self.ribbonBody(
                "Turn **Audiout** on under \(Self.settingsPath(for: step)), then come back — "
                + "this row ticks itself.")
            content.primary = ("Open Settings…", .prominent)
            content.showsSkip = copy.isSkippable
            return content
        }

        // Asked, nothing answered — and Local Network's retry IS its own browse,
        // so the pane is a demotion beside it, never a replacement.
        if localNetworkUnanswered(step) {
            content.status = (Self.alertSymbol, Self.localNetworkUnansweredStatus,
                              Tokens.Color.label2, false)
            content.body = Self.ribbonBody(copy.detail)
            content.primary = ("Try Again", .prominent)
            content.quietLink = offersSettingsLink(step) ? "Open Settings…" : nil
            return content
        }

        // Accessibility asked once and can't tell us the answer.
        if step == .remoteControl, model.remoteControlStatus == .requested {
            content.body = Self.ribbonBody(
                "In Settings, switch **Audiout** on under Privacy & Security \u{25B8} Accessibility. "
                + "macOS won't tell us when you do \u{2014} this row ticks itself.")
            content.primary = ("Open Settings…", .prominent)
            content.showsSkip = true
            return content
        }

        // The first ask.
        content = firstAskRibbonContent(step)
        if reopenedSteps.contains(step) {
            content.status = ("slash.circle", "You skipped this earlier \u{2014} nothing's lost.",
                              Tokens.Color.label2, false)
        }
        return content
    }

    /// The FIRST ask: the headline, the why line, and the button. Nothing else.
    ///
    /// Everything that used to sit here — the ask line ("This is what macOS will
    /// ask you next.", "Two clicks, on two different windows."), the reassurance
    /// paragraph and the honesty line — was DELETED rather than restyled (owner
    /// decision 2026-08-12). Each was a sentence explaining a picture the user
    /// is already looking at: the labelled preview frame says whose surface it is,
    /// and the rehearsal inside it shows which button to press, including Remote
    /// Control's two surfaces and its ghosted Deny.
    private func firstAskRibbonContent(_ step: SetupStep) -> RibbonContent {
        var content = RibbonContent()
        let copy = Self.content(for: step)
        content.headline = copy.heroHeadline
        content.why = copy.whyLine
        content.primary = (copy.allowTitle, .prominent)
        content.showsSkip = copy.isSkippable
        content.skipTitle = Self.skipTitle(for: step)
        return content
    }

    /// The one step whose skip is an ANSWER rather than a deferral — see
    /// `RibbonContent.skipTitle`. Everything else keeps the shared "Skip for
    /// now", which its row really does honour.
    static func skipTitle(for step: SetupStep) -> String? {
        step == .usageStats ? "No Thanks" : nil
    }

    /// A decided row, opened for READING: what it bought, and where the switch
    /// lives if the user ever wants it back.
    private func browseRibbonContent(_ step: SetupStep) -> RibbonContent {
        var content = RibbonContent()
        // No auto-passed case here: those rows are not browsable at all.
        // macOS 14 never gated Local Network, so there is no pane to name and
        // nowhere to send anyone.
        content.headline = Self.content(for: step).heroHeadline
        // No System Settings pane on the other side: macOS 14 never gated Local
        // Network, and Usage Statistics is Audiout's own switch — offering
        // "Open Settings…" for either would open the wrong app on nothing.
        let hasPane = !(step == .localNetwork && !model.isLocalNetworkGated)
            && step != .usageStats
        var sentence = browseCapabilitySentence(step)
        if hasPane, step != .speakerSync {
            sentence += " It lives under Privacy & Security \u{25B8} \(Self.paneName(for: step)) "
                + "if you ever want to change it."
        }
        content.body = Self.ribbonBody(sentence)
        content.quietLink = hasPane ? "Open Settings\u{2026}" : nil
        return content
    }

    private func browseCapabilitySentence(_ step: SetupStep) -> String {
        switch step {
        case .audio: return "Audiout can hear your Mac's sound."
        // The earned title verbatim, as a sentence — the count is the detail a
        // user can check, so it is what a browse repeats back.
        case .localNetwork:
            let count = model.isLocalNetworkGated ? flow.localNetworkFoundSpeakers : nil
            return Self.content(for: step).title(for: .completed, foundSpeakers: count) + "."
        case .bluetooth: return "Audiout can use Bluetooth speakers."
        // This one carries its own location: Login Items isn't under Privacy &
        // Security, so the shared path sentence would send the user wrong.
        case .speakerSync: return "Your speakers stay in perfect time. It lives in Login Items\u{2026}"
        case .remoteControl: return "Your volume keys control Audiout."
        // Its switch is OURS, so this one names its own location too — the
        // shared "Privacy & Security ▸ …" sentence would send the user into
        // System Settings looking for a row that isn't there.
        case .usageStats:
            return "Audiout counts feature use, anonymously. It lives in "
                + "Audiout's settings, under General."
        }
    }

    /// The System Settings pane each step's switch lives on, named the way the
    /// pane itself is named. Usage Statistics has none — its switch is
    /// Audiout's own — so it names the place that actually holds it, and every
    /// caller is gated on `hasPane` before it can reach here anyway.
    static func paneName(for step: SetupStep) -> String {
        switch step {
        case .audio:         return "Screen & System Audio Recording"
        case .localNetwork:  return "Local Network"
        case .bluetooth:     return "Bluetooth"
        case .remoteControl: return "Accessibility"
        case .speakerSync:   return "Login Items"
        case .usageStats:    return "Audiout \u{25B8} Settings \u{25B8} General"
        }
    }

    /// The full path a user types into their head: Login Items is NOT under
    /// Privacy & Security, so it names itself.
    static func settingsPath(for step: SetupStep) -> String {
        step == .speakerSync ? "Login Items"
                             : "Privacy & Security \u{25B8} \(paneName(for: step))"
    }

    /// Body copy with `**bold**` runs. The ribbon is the only place in this
    /// window with rich text, and it earns it: the word that matters is the
    /// button that is the WRONG answer, or the app's own name in a list of
    /// twenty.
    static func ribbonBody(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var isBold = false
        for piece in source.components(separatedBy: "**") {
            if !piece.isEmpty {
                result.append(NSAttributedString(string: piece, attributes: [
                    // The bold run is the CAPTION's own emphasized weight: the
                    // body is 11 pt caption, and a `bodyEmphasized` run inside
                    // it sets a bigger face on the one word that matters.
                    .font: isBold ? Tokens.Font.captionEmphasized : Tokens.Font.caption,
                    .foregroundColor: Tokens.Color.label2,
                ]))
            }
            isBold.toggle()
        }
        return result
    }

    // MARK: Announcements

    /// Speak a state change VoiceOver would otherwise miss. Everything this
    /// window does happens somewhere other than the keyboard focus — a grant
    /// lands from System Settings, a check passes on its own — so without this
    /// the whole flow is silent (critique P1).
    private func announce(_ text: String) {
        guard initialStatusesSettled else { return }
        test_announcements.append(text)
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// One announcement per real transition — driven by the same edge sets the
    /// repaint already computes, so a repaint that changes nothing says nothing.
    private func announceTransitions(newlyCompleted: Set<SetupStep>, active: SetupStep?) {
        for step in flow.steps where newlyCompleted.contains(step) {
            let count = model.isLocalNetworkGated ? flow.localNetworkFoundSpeakers : nil
            announce(Self.content(for: step).spineTitle(for: .completed, foundSpeakers: count))
        }

        // A step still prompting keeps its denied edge un-consumed: the status
        // may flip to .denied while the ask is mid-flight (ribbon still on the
        // waiting line), and speaking then would announce the wait instead of
        // the refusal. The edge fires on the repaint after the prompt resolves.
        let deniedNow = Set(flow.steps.filter { isProvablyDenied($0) && !isPrompting($0) })
        let newlyDenied = deniedNow.subtracting(deniedAtLastRefresh)
        deniedAtLastRefresh = deniedNow
        for step in flow.steps where newlyDenied.contains(step) {
            if let status = ribbonContent(active: active).status, step == active {
                announce(status.text)
            }
        }

        if flow.finalCheckState == .passed {
            if !announcedCheckPassed {
                announcedCheckPassed = true
                announce(SetupCheckRowView.title(for: .passed))
            }
        } else {
            announcedCheckPassed = false
        }

        if let snapBackStep, snapBackStep != announcedSnapBack {
            announcedSnapBack = snapBackStep
            if let status = ribbonContent(active: active).status { announce(status.text) }
        } else if snapBackStep == nil {
            announcedSnapBack = nil
        }
    }

    // MARK: Keyboard

    /// Put the keyboard on the button that matters, when — and only when — the
    /// step changes or the gate opens. Moving it on every repaint would fight
    /// a user who has tabbed onto the spine.
    /// Escape is the ✕. It routes through `performClose`, so it obeys the same
    /// refusal — including the ribbon line and the announcement that refusal now
    /// carries — rather than being a second, quieter way out.
    public override func cancelOperation(_ sender: Any?) {
        view.window?.performClose(nil)
    }

    private func refreshKeyboardFocus(active: SetupStep?) {
        guard !HeadlessRuntime.isActive, let window = view.window else { return }
        let hasCTA = ribbon.test_primaryIsCTA
        let hasPrimary = ribbon.primaryButton != nil
        let waitEnded = hasPrimary && !focusAnchorHadPrimary
        guard focusAnchorStep != .some(active) || hasCTA != focusAnchorHadCTA || waitEnded else { return }
        focusAnchorStep = .some(active)
        focusAnchorHadCTA = hasCTA
        focusAnchorHadPrimary = hasPrimary
        if let button = ribbon.primaryButton { window.makeFirstResponder(button) }
    }

    // MARK: The gate

    /// Done re-verifies before finishing: something may have been revoked while
    /// the window sat open. A failure snaps the flow back to the step that came
    /// up short — no sheet, no "continue anyway".
    @objc private func doneTapped() {
        Task { @MainActor in await verifyThenFinish() }
    }

    /// Whether a Done verification is already running — the same single-flight
    /// rule the Allow path has: the audit's Local Network re-browse takes
    /// seconds, and a second click during it must join the outcome already on
    /// its way, not stack a second verification (whose own answer would race
    /// the first past `onDone`).
    private var doneVerifyInFlight = false

    private func verifyThenFinish() async {
        // The third `setup_done` outcome; "finished"/"refused" are logged by
        // `verifyForDone()` itself, but a swallowed click never reaches it.
        guard !doneVerifyInFlight else {
            Telemetry.log(.permission, "setup_done", ["outcome": "swallowed_in_flight"])
            return
        }
        doneVerifyInFlight = true
        defer { doneVerifyInFlight = false }
        switch await flow.verifyForDone() {
        case .complete:
            onDone()
        case .unmet(let step):
            snapBackStep = step
            // A snap-back must land on a VISIBLE stage: the browse yields to it.
            browseStep = nil
            refresh(animated: canAnimate)
        }
    }

    // MARK: Header message

    /// Which message the header is carrying — tracked as a KIND so the banner
    /// hooks report what is showing instead of inferring it from copy. The
    /// welcome line holds in EVERY state including complete (owner decision
    /// 2026-08-11: the payoff line lives on the finale card, not in the
    /// header); only the lost-permission warning and the resume greeting ever
    /// displace it.
    private enum HeaderMessage { case welcome, permissionLost, resume }
    private var headerMessage: HeaderMessage = .welcome

    /// Show the `.permissionLost` warning while any permission it ORIGINALLY
    /// flagged is still missing (re-worded to the still-missing subset, never
    /// expanded to nag about something it didn't open for); the resume or
    /// welcome line otherwise.
    private func refreshHeaderMessage() {
        if case .permissionLost(let originallyUnmet) = reason {
            let notGranted = model.requiredPermissionsNotGranted()
            let stillMissing = originallyUnmet.filter { notGranted.contains($0) }
            if !stillMissing.isEmpty {
                headerMessage = .permissionLost
                titleLabel.stringValue = "Let's get your sound back"
                subtitleLabel.stringValue = Self.permissionLostText(for: stillMissing)
                subtitleLabel.textColor = Tokens.Color.label2
                return
            }
        }
        if opensAsResume {
            headerMessage = .resume
            titleLabel.stringValue = "Pick up where you left off"
            subtitleLabel.stringValue = Self.resumeSubtitle
            subtitleLabel.textColor = Tokens.Color.label2
            return
        }
        headerMessage = .welcome
        titleLabel.stringValue = "Welcome to Audiout"
        subtitleLabel.stringValue = Self.welcomeSubtitle
        subtitleLabel.textColor = Tokens.Color.label2
    }

    static let welcomeSubtitle = "Play your Mac's sound on the speakers around your home. "
        + "A few one-time permissions, one at a time."

    static let resumeSubtitle = "Everything you set up is still in place. One step is still "
        + "open — it's yours whenever you want it."

    /// The specific unmet permission(s), named plainly, so the user knows
    /// exactly what to look for on the spine.
    /// Two whole sentences, one per arity, rather than one sentence with a
    /// pronoun spliced into it: with two names on screen "Flip it back on" was
    /// a broken sentence, and "access was switched off" was plain wrong for
    /// Speaker Sync, whose switch is a Login Item and not an access grant.
    /// The join is `ListFormatter`'s, so the list reads correctly wherever the
    /// app is running.
    static func permissionLostText(for unmet: [RequiredPermission]) -> String {
        let names = unmet.map(displayName(for:))
        // Shouldn't happen — the reason is only built with a non-empty set.
        let joined = names.isEmpty ? "A permission"
                                   : ListFormatter.localizedString(byJoining: names)
        if names.count > 1 {
            return "\(joined) were turned off after setup. Turn them back on and your "
                + "speakers pick up where they left off."
        }
        return "\(joined) was turned off after setup. Turn it back on and your "
            + "speakers pick up where they left off."
    }

    static func displayName(for permission: RequiredPermission) -> String {
        switch permission {
        case .audioCapture: return "System Audio"
        case .localNetwork: return "Local Network"
        // Matches the row's on-screen title (was "PTP helper" — jargon the
        // user never sees anywhere else; spec §5.8's plain-speakers voice).
        case .ptpHelper:    return "Speaker Sync"
        }
    }

    // MARK: Actions

    /// A click on a spine row. What it does depends entirely on where the row
    /// stands: the live one fires the ribbon's own primary (the whole row is
    /// that button's target), a decided one opens for reading, a skipped one
    /// takes the skip back, and a locked one refuses without a sound.
    private func rowPressed(_ step: SetupStep) {
        // The live row is a shortcut to its primary, for every step — see
        // `SetupSpineRowView.isPressable` for why that is safe again.
        if step == displayedActiveStep { ribbonPrimaryTapped(); return }
        // The loud row: pressing it moves the flow there, which is the only
        // thing its treatment was ever asking for. The snap-back announcement
        // in `announceTransitions` then speaks the recovery status.
        if isBroken(step) {
            snapBackStep = step
            browseStep = nil
            refresh(animated: canAnimate)
            return
        }
        switch state(for: step, active: displayedActiveStep) {
        case .completed:
            browseStep = browseStep == step ? nil : step
            refresh(animated: canAnimate)
        case .skipped:
            flow.reopen(step)
            browseStep = nil
            reopenedSteps.insert(step)
            refresh(animated: canAnimate)
        // An auto-passed row refuses alongside a locked one: its permanent note
        // carries the whole story, and no honest hero exists for a grant macOS
        // cannot make.
        case .pending, .active, .autoPassed:
            break
        }
    }

    /// The ribbon's one action button. Which call it makes is the same question
    /// the ribbon asked when it chose the button's shape.
    private func ribbonPrimaryTapped() {
        // A primary that fires a prompt must OWN the stage: browse content
        // would mask the waiting dim, the denied status line and that line's
        // announcement — the P0 this window exists to fix.
        if browseStep != nil {
            browseStep = nil
            refresh(animated: false)
        }
        // The CTA survives a browse (see `ribbonContent(active:)`), so it has to
        // still FINISH from one — the browse condition that used to sit here
        // would have left the button on screen doing nothing.
        if flow.isDoneAvailable { doneTapped(); return }
        guard let step = displayedActiveStep else { return }
        allowTapped(step)
    }

    private func ribbonSkipTapped() {
        guard let step = displayedActiveStep else { return }
        skipTapped(step)
    }

    /// The quiet second path. For the live step that is Local Network's pane
    /// (its retry keeps the browse); for a browsed row it is that row's own
    /// pane, which is the only way a granted permission can be reached again.
    private func ribbonQuietLinkTapped() {
        if let browsed = browseStep { openSettings(for: browsed); return }
        guard let step = displayedActiveStep else { return }
        settingsLinkTapped(step)
    }

    private func openSettings(for step: SetupStep) {
        onWillOpenSystemSettings?()
        switch step {
        case .audio:         onOpenSettings(.screenAndSystemAudioRecording)
        case .localNetwork:  onOpenSettings(.localNetwork)
        case .bluetooth:     onOpenSettings(.bluetoothPrivacy)
        case .remoteControl: onOpenSettings(.accessibility)
        // Login Items has no `SystemSettingsPane` of its own — the model owns
        // that destination, the same one this step's Allow uses.
        case .speakerSync:
            didTripLoginItems = true
            model.openPTPHelperLoginItems()
        // Unreachable: every path here is gated on this step HAVING a System
        // Settings pane, and this one's switch is Audiout's own. Explicit
        // rather than a default, so a step added later is a compile error here.
        case .usageStats: break
        }
    }

    private func allowTapped(_ step: SetupStep) {
        guard allowInFlight == nil else { return }   // single-flight, UI half
        allowInFlight = step
        refresh(animated: false)                     // the wait, instantly
        allowTask = Task { @MainActor in await performAllow(step) }
    }

    /// Run one Allow to completion: yield the window level if this step is about
    /// to raise something we'd otherwise cover, fire it, apply the answer, and
    /// repaint. The caller has already claimed `allowInFlight`.
    private func performAllow(_ step: SetupStep) async {
        // Remote Control is the one step whose ASK needs the yield too. Its
        // prompt is a plain macOS ALERT PANEL — ordinary window chrome at normal
        // level, not a TCC dialog a system process draws above everything — so a
        // floating Setup window buries it and the user never sees what they just
        // asked for (owner live observation 2026-08-11). It has to drop BEFORE
        // the ask: by the time `allow` returns, the alert is already on screen.
        // Harmless when the ask short-circuits and no alert appears — the yield
        // is idempotent, and `appDidBecomeActive` restores the level the next
        // time this app comes forward.
        // The app goes quiet BEFORE the OS prompt is triggered — by the time
        // `allow` returns, the dialog is already up and fighting us for focus.
        syncPromptInFlight()
        if step == .remoteControl { onWillOpenSystemSettings?() }
        let result = await flow.allow(step)
        allowInFlight = nil
        // The resolve edge, ahead of `applyAllowResult`: a denied step's deep
        // link yields the level again right after, and must win.
        syncPromptInFlight()
        applyAllowResult(step, result)
        refresh()
    }

    /// Whether an Allow that stayed in-app (no Settings destination) may pull the
    /// window back to the front. Normally yes — the user came back from a system
    /// dialog and should land on setup rather than on whatever was behind it.
    ///
    /// Two steps say no while the surface they raised may still be up, for the
    /// same reason: re-fronting over it leaves the real dialog dimmed and
    /// unclickable.
    private func shouldReturnToFront(after step: SetupStep) -> Bool {
        switch step {
        // Local Network's "prompt" is a browse whose window can expire while the
        // real alert is still on screen. Both real answers — granted OR denied —
        // mean it was answered, so both take the front back; only `.requested`
        // (nothing answered) leaves it be, and the next natural activation
        // brings the window forward anyway.
        case .localNetwork: return model.localNetworkStatus != .requested
        // The Accessibility alert has just OPENED (that is what the yield above
        // is for); fronting ourselves now would re-bury the very panel we
        // stepped aside for.
        case .remoteControl: return model.remoteControlStatus == .granted
        case .audio, .bluetooth, .speakerSync: return true
        // Nothing ever left this app, so there is no front to take back — and
        // fronting on a click the user made INSIDE this window would be a
        // flash for nothing.
        case .usageStats: return false
        }
    }

    /// What one Allow click does with its answer — re-front, or open the place
    /// the model named. Shared with ``test_tapAllow(_:)`` so the test hook can
    /// never drift from the real click's rules.
    private func applyAllowResult(_ step: SetupStep, _ result: SetupAllowResult) {
        switch result.destination {
        case .none:
            // A prompt ran (or was refused): the user came back from a system
            // dialog, so take the front again — unless the surface that ask
            // raised may still be up (``shouldReturnToFront(after:)``).
            if shouldReturnToFront(after: step) { returnToFront() }
            // Remote Control's first ask fires its alert here rather than
            // opening a destination — the alert is up and unresolved until a
            // poll or a return re-read finds Accessibility trusted.
            if step == .remoteControl, model.remoteControlStatus != .granted {
                settingsTripStep = step
                armSettingsTripTimer()
            }
        // Our own sheet is not a trip out of the app, so it arms no
        // settings-trip ceiling — that timer exists to catch a user who left
        // for System Settings and never came back.
        case .usageStatsConsent:
            openDestination(result.destination)
        case .settingsPane, .loginItems:
            settingsTripStep = step
            armSettingsTripTimer()
            openDestination(result.destination)
        }
    }

    /// How the usage-statistics consent sheet is raised, and how its answer
    /// comes back. Injected so a headless test (and the snapshot renderers) can
    /// answer it without a real modal on screen; `nil` runs the real sheet.
    public var presentUsageStatsConsent: ((@escaping (Bool) -> Void) -> Void)?

    /// Audiout's own Share / Don't Share sheet — the surface this step's ask
    /// raises, exactly as every other step's ask raises one of macOS's.
    ///
    /// It is ``UsageStatsConsentCard`` — the SAME view the rehearsal on the
    /// stage draws, with its buttons live instead of switched off. An `NSAlert`
    /// was the first attempt and was wrong for exactly the reason this window
    /// exists: the stage promises "this is what you'll see", and a stock alert
    /// is not what the stage was showing (owner: "why can't you make it look
    /// exactly like your mock-up"). One card, two hosts, nothing to keep in
    /// step.
    ///
    /// This is NOT the `NSAlert` that was deleted from `AppDelegate`. That one
    /// ambushed the first menu-bar click, with nothing on screen to explain it;
    /// this one answers a card the user is looking at and pressed.
    private func presentConsentSheet() {
        let deliver: (Bool) -> Void = { [weak self] granted in
            guard let self else { return }
            if granted { model.grantUsageStats() } else { flow.skip(.usageStats) }
            announce(granted ? Self.content(for: .usageStats).spineDoneTitle
                             : "Not sharing usage statistics.")
            refresh(animated: canAnimate)
        }
        if let presentUsageStatsConsent {
            presentUsageStatsConsent(deliver)
            return
        }
        // No window means no sheet to attach one to (headless renders, an
        // off-screen controller). Refusing beats a stray app-modal dialog.
        guard view.window != nil else { return }
        presentAsSheet(UsageStatsConsentViewController(onAnswer: deliver))
    }

    /// Open a destination the flow model named, yielding the window level first
    /// so System Settings can actually come to the front.
    private func openDestination(_ destination: SetupAllowDestination) {
        switch destination {
        case .none: return
        // OURS, so no level yield and no `onWillOpenSystemSettings` — nothing
        // is coming to the front over us; the sheet lands on this window.
        case .usageStatsConsent: presentConsentSheet()
        case .settingsPane(let pane):
            onWillOpenSystemSettings?()
            onOpenSettings(pane)
        case .loginItems:
            onWillOpenSystemSettings?()
            didTripLoginItems = true
            model.openPTPHelperLoginItems()
        }
    }

    /// The demoted "Open Settings…" — beside Local Network's retry, and beside
    /// the stuck-dialog hint on any card whose prompt has stopped responding.
    /// It opens the pane directly through the flow model's one deep-link table:
    /// there is no prompt left to fire, and nothing here re-asks.
    private func settingsLinkTapped(_ step: SetupStep) {
        guard step == .localNetwork || isStuck(step) else { return }
        settingsTripStep = step
        armSettingsTripTimer()
        openDestination(SetupFlowModel.settingsDestination(for: step))
    }

    private func skipTapped(_ step: SetupStep) {
        flow.skip(step)
        announce("Skipped. \(Self.content(for: step).spineTitle(for: .skipped))")
        // Skipping is UI-initiated, and `SetupFlowModel` has no change hook of
        // its own, so the repaint is this call site's job.
        refresh(animated: canAnimate)
    }

    // MARK: Test-support hooks

    /// How many times the flow decided to pull the window back to the front.
    /// ``shouldReturnToFront(after:)``'s two refusals — a Local Network browse
    /// that proved nothing, and a Remote Control alert that has only just
    /// opened — have no other headless signal.
    public private(set) var test_returnToFrontCount = 0

    /// Everything this window has asked VoiceOver to say, in order.
    public private(set) var test_announcements: [String] = []

    /// Whether the flow currently counts a system dialog as unanswered.
    public var test_isPromptInFlight: Bool { isPromptInFlight }

    /// Fire the stuck-dialog timer now — its 20 s is not something a test can
    /// wait out, and the timer body is the only thing being skipped.
    public func test_fireStuckPromptTimer() { markPromptStuck() }

    /// Fire the Settings-trip ceiling now — same reason as the stuck-dialog
    /// timer above: its 20 s is not something a test can wait out.
    public func test_fireSettingsTripTimer() { fireSettingsTripCeiling() }

    /// The live step (nil once every step is done or skipped).
    public var test_activeStep: SetupStep? { _ = view; return displayedActiveStep }

    /// The decided row the hero pane is browsing, if any.
    public var test_browseStep: SetupStep? { _ = view; return browseStep }

    /// The on-screen title of a spine row, so a test can pin the imperative →
    /// capability rewrite in its short form.
    public func test_spineTitle(of step: SetupStep) -> String {
        _ = view
        return rows[step]?.test_title ?? ""
    }

    /// Whether a row is showing its earned checkmark.
    public func test_hasCheckmark(_ step: SetupStep) -> Bool { _ = view; return rows[step]?.test_hasCheckmark ?? false }

    /// The note a row shows in place of a checkmark (auto-passed steps).
    public func test_note(of step: SetupStep) -> String? { _ = view; return rows[step]?.test_note }

    /// Whether a row is showing the LOCK — a step the flow hasn't reached.
    public func test_isLocked(_ step: SetupStep) -> Bool { _ = view; return rows[step]?.test_isLocked ?? false }

    /// Whether a row is showing the skip slash.
    public func test_isSkipped(_ step: SetupStep) -> Bool { _ = view; return rows[step]?.test_isSkipped ?? false }

    /// Whether a row is drawing the broken-permission treatment.
    public func test_rowIsBroken(_ step: SetupStep) -> Bool { _ = view; return rows[step]?.test_isBroken ?? false }

    /// Whether a row is drawing the waiting spinner.
    public func test_rowIsWaiting(_ step: SetupStep) -> Bool { _ = view; return rows[step]?.test_isWaiting ?? false }

    /// Overrides a row's live Reduce Motion read, so a headless test can drive
    /// its waiting spinner deterministically.
    public func test_setRowReduceMotionOverride(_ step: SetupStep, _ override: Bool?) {
        _ = view
        rows[step]?.test_reduceMotionOverride = override
    }

    /// Whether a row's waiting spinner is actually animating right now.
    public func test_rowSpinnerIsAnimating(_ step: SetupStep) -> Bool {
        _ = view; return rows[step]?.test_spinnerIsAnimating ?? false
    }

    /// Await whatever a genuine return from an armed Settings trip started —
    /// the seam a headless walk needs since that re-read runs off the app's
    /// own reactivation notification, not off a click.
    public func test_awaitSettingsReturn() async { await settingsReturnTask?.value }

    /// A row's leading edge bar fill, or nil when it draws none — the live
    /// row's is EMBER, gold being reserved for the one button to press.
    public func test_rowEdgeBarFill(_ step: SetupStep) -> NSColor? {
        _ = view
        return rows[step]?.test_edgeBarFill
    }

    /// Whether a row is drawing the browse selection.
    public func test_rowIsBrowseSelected(_ step: SetupStep) -> Bool {
        _ = view
        return rows[step]?.test_isBrowseSelected ?? false
    }

    /// Whether a click on this row does anything.
    public func test_isRowPressable(_ step: SetupStep) -> Bool { _ = view; return rows[step]?.test_isPressable ?? false }

    /// Whether VoiceOver sees this row as a button, under what action name, and
    /// what it reads out.
    public func test_rowIsAccessibilityButton(_ step: SetupStep) -> Bool {
        _ = view
        return rows[step]?.test_accessibilityIsButton ?? false
    }
    public func test_rowAccessibilityAction(_ step: SetupStep) -> String? {
        _ = view
        return rows[step]?.test_accessibilityAction
    }
    public func test_rowAccessibilityLabel(_ step: SetupStep) -> String? {
        _ = view
        return rows[step]?.test_accessibilityLabel
    }

    /// Press a spine ROW and wait for whatever that starts.
    ///
    /// This drives the row view's REAL press entry (`accessibilityPerformPress`,
    /// the same path `mouseUp` takes) and then awaits the work that press
    /// started. It deliberately does not re-implement the dispatch: a hook that
    /// re-implements what it claims to exercise is how a real break in row
    /// selection stayed hidden once already.
    public func test_pressRow(_ step: SetupStep) async -> Bool {
        _ = view
        guard rows[step]?.test_pressCard() == true else { return false }
        await allowTask?.value
        return true
    }

    /// Whether the row's OWN press action is refused (a locked row) — the
    /// no-jump-ahead guard.
    public func test_rowPressIsRefused(_ step: SetupStep) -> Bool {
        _ = view
        guard let row = rows[step] else { return true }
        return !row.test_isPressable && row.test_pressCard() == false
    }

    /// Whether this row acts on the click that ACTIVATES the app (the
    /// bounce-to-Settings-and-back fix — see `SetupSpineRowView.acceptsFirstMouse`).
    public func test_rowAcceptsFirstMouse(_ step: SetupStep) -> Bool {
        _ = view
        return rows[step]?.acceptsFirstMouse(for: nil) ?? false
    }

    /// Drive a step's Allow exactly as the ribbon's button does, and wait for it
    /// — the same ``performAllow(_:)`` the real click runs, the same
    /// single-flight bookkeeping, the same level yield and the same
    /// ``applyAllowResult(_:_:)`` — so none of those rules can be true here and
    /// false on screen.
    public func test_tapAllow(_ step: SetupStep) async {
        _ = view
        allowInFlight = step
        await performAllow(step)
    }

    /// Drive each step's Allow in order — how the snapshot harness reaches
    /// "step 3 is the live one" without a live prompt.
    public func test_allow(_ steps: [SetupStep]) async {
        for step in steps { await test_tapAllow(step) }
    }

    /// Drive Skip exactly as the ribbon's button does.
    public func test_tapSkip(_ step: SetupStep) { _ = view; skipTapped(step) }

    // MARK: Ribbon hooks

    /// The hero's headline and the why line under it — the whole of a first
    /// ask's copy.
    public var test_heroHeadline: String? { _ = view; return heroHead.test_headline }
    public var test_heroWhy: String? { _ = view; return heroHead.test_why }
    /// The preview frame's caption band, or nil when the frame carries none.
    public var test_previewFrameLabel: String? { _ = view; return previewFrame.test_caption }
    /// What VoiceOver reads for that caption band — the spoken instruction where
    /// one is substituted, the visible words otherwise.
    public var test_previewFrameSpokenCaption: String? {
        _ = view; return previewFrame.test_captionAccessibilityLabel
    }
    /// The hero headline's accessibility role — the rotor's heading contract.
    public var test_heroHeadlineIsHeading: Bool {
        _ = view; return heroHead.test_headlineAccessibilityRole?.rawValue == "AXHeading"
    }

    /// Whether the preview frame is drawing its well, rim and clip.
    public var test_previewFrameDrawsChrome: Bool { _ = view; return previewFrame.test_drawsChrome }
    public var test_ribbonStatusText: String? { _ = view; return ribbon.test_statusText }
    /// The status line's own text colour — see ``SetupRibbonView/test_statusTextColor``.
    public var test_ribbonStatusTextColor: NSColor? { _ = view; return ribbon.test_statusTextColor }
    public var test_ribbonBodyText: String? { _ = view; return ribbon.test_bodyText }
    public var test_ribbonButtonTitles: [String] { _ = view; return ribbon.test_buttonTitles }
    /// Whether a wait is on screen (the spinner beat, with every button gone).
    public var test_ribbonIsWaiting: Bool { _ = view; return ribbon.test_isWaiting }
    /// Overrides the ribbon's live Reduce Motion read, so a headless test can
    /// drive its status spinner deterministically.
    public var test_ribbonReduceMotionOverride: Bool? {
        get { _ = view; return ribbon.test_reduceMotionOverride }
        set { _ = view; ribbon.test_reduceMotionOverride = newValue }
    }
    /// Press the ribbon's primary and wait for whatever it starts.
    public func test_ribbonTapPrimary() async {
        _ = view
        ribbon.test_tapPrimary()
        await allowTask?.value
    }
    public func test_ribbonTapSkip() { _ = view; ribbon.test_tapSkip() }
    public func test_ribbonTapQuietLink() { _ = view; ribbon.test_tapQuietLink() }
    /// Whether the ribbon's controls are real, reachable AppKit controls — it
    /// sits inside the hero pane, beside a demo that is deliberately invisible
    /// to VoiceOver, and must never be swept into that.
    public var test_ribbonIsAccessible: Bool { _ = view; return ribbon.test_isAccessible }

    // MARK: Check-row hooks

    /// The check row's displayed state.
    public var test_checkRowState: SetupFinalCheckState { _ = view; return displayedCheckState }

    /// The check row's on-screen title (the state-carrying copy).
    public var test_checkRowTitle: String { _ = view; return checkRow.test_title }

    /// Whether the check row is showing its earned gold checkmark.
    public var test_checkRowHasCheckmark: Bool { _ = view; return checkRow.test_hasCheckmark }

    /// Whether the check row's spinner is on screen (the running state).
    public var test_checkRowIsSpinning: Bool { _ = view; return checkRow.test_isSpinning }

    /// Overrides the check row's live Reduce Motion read, so a headless test
    /// can drive its spinner deterministically.
    public var test_checkRowReduceMotionOverride: Bool? {
        get { _ = view; return checkRow.test_reduceMotionOverride }
        set { _ = view; checkRow.test_reduceMotionOverride = newValue }
    }

    /// Whether the check row's spinner is actually animating right now.
    public var test_checkRowSpinnerIsAnimating: Bool { _ = view; return checkRow.test_spinnerIsAnimating }

    /// What VoiceOver reads for the check row — derived from the same title
    /// the pixels draw.
    public var test_checkRowAccessibilityLabel: String? {
        _ = view
        return checkRow.test_accessibilityLabel
    }

    /// Await the automatic final check the last row decision started, if one
    /// is in flight — a headless walk asserts on the state AFTER the beat.
    public func test_awaitFinalCheck() async { _ = view; await finalCheckTask?.value }

    // MARK: Gate hooks

    /// Whether the gate's CTA is in the view hierarchy at all — the gate
    /// contract is ABSENT, not disabled, so this is the assertion that matters.
    public var test_doneExists: Bool {
        _ = view
        return ribbon.test_primaryIsCTA && ribbon.primaryButton?.superview != nil
    }

    /// Whether the CTA is the window's Return-default (it is, the moment it
    /// exists — every primary owns Return, and the CTA is the primary).
    public var test_doneIsReturnDefault: Bool {
        _ = view
        return ribbon.test_primaryIsCTA && ribbon.primaryButton?.keyEquivalent == "\r"
    }

    /// The gate button's title (nil while the gate is shut).
    public var test_doneTitle: String? {
        _ = view
        return ribbon.test_primaryIsCTA ? ribbon.primaryButton?.title : nil
    }

    /// Whether the gate button is the gold prominent CTA — a `ProminentButton`
    /// carrying the gold fill, not a plain bezel. Compared by RESOLVED
    /// sRGB components: two accesses of a provider-backed token are distinct
    /// `NSColor` instances, and their `isEqual` is not documented to see
    /// through the provider.
    public var test_doneIsGoldProminent: Bool {
        _ = view
        guard ribbon.test_primaryIsCTA,
              let done = ribbon.primaryButton as? ProminentButton else { return false }
        var matches = false
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            matches = done.fill.usingColorSpace(.sRGB) == Tokens.Color.gold.usingColorSpace(.sRGB)
        }
        return matches
    }

    /// Whether the CTA acts on the activating click (the v4 two-clicks fix).
    public var test_doneAcceptsFirstMouse: Bool {
        _ = view
        guard ribbon.test_primaryIsCTA else { return false }
        return ribbon.primaryButton?.acceptsFirstMouse(for: nil) ?? false
    }

    /// Tap Done: re-verifies, then either finishes or snaps back.
    public func test_tapDone() async { _ = view; await verifyThenFinish() }

    /// Whether Done's verification is currently running — the single-flight
    /// flag, exposed so a test can order itself around the in-flight window.
    public var test_doneVerifyInFlight: Bool { doneVerifyInFlight }

    /// The step a failed Done verification snapped back to, if any.
    public var test_snapBackStep: SetupStep? { _ = view; return snapBackStep }

    // MARK: Hero-pane hooks

    /// Which miniature the hero stage is showing.
    public var test_demoMode: DemoMode { _ = view; return demoPane.test_mode }

    /// Which surface a two-stage demo rests on. Remote Control's first ask is
    /// the only one — `nil` for every other step, and for its own retry.
    public var test_demoStage: DemoStage? { _ = view; return demoPane.test_stage }

    /// Whether the demo's timeline is running (the zero-idle-CPU rule).
    public var test_isDemoAnimating: Bool { _ = view; return demoPane.test_isAnimating }

    /// Whether the demo is offering its Reduce Motion Replay button.
    public var test_demoShowsReplay: Bool { _ = view; return demoPane.test_showsReplay }

    /// Whether the stage is standing back for a real dialog (the waiting beat).
    public var test_stageIsDimmed: Bool { _ = view; return demoPane.test_isStageDimmed }

    /// Whether the browsed pane rests with its switch already on.
    public var test_heroRestingSwitchOn: Bool { _ = view; return demoPane.test_restingSwitchOn }

    /// Reduce Motion override for the demo pane (`nil` = the live setting).
    public var test_demoReduceMotionOverride: Bool? {
        get { _ = view; return demoPane.test_reduceMotionOverride }
        set { _ = view; demoPane.test_reduceMotionOverride = newValue }
    }

    /// Override for "this pane is allowed to animate" (`nil` = the live
    /// window/headless check). A headless run is never allowed to animate for
    /// real, so this is the only way to reach the motion POLICY — which of the
    /// two branches runs, and whether it loops — without a live window.
    public var test_demoCanAnimateOverride: Bool? {
        get { _ = view; return demoPane.test_canAnimateOverride }
        set { _ = view; demoPane.test_canAnimateOverride = newValue }
    }

    /// Whether the demo's timeline is set to LOOP — false is the Reduce Motion
    /// single play-through.
    public var test_demoIsLooping: Bool { _ = view; return demoPane.test_isLooping }

    /// How many times the settled finale's one-shot actually ran (the
    /// once-only rule — a repaint that changes nothing must never re-fire it).
    public var test_demoCelebrationRunCount: Int { _ = view; return demoPane.test_celebrationRunCount }

    /// Whether the finale's one-shot is spent — played, or skipped without
    /// motion under Reduce Motion. False on an off-window/headless settle, so
    /// the presentation that can show it still gets it.
    public var test_demoCelebrationConsumed: Bool { _ = view; return demoPane.test_celebrationConsumed }

    /// Press the demo's Replay button exactly as the button does.
    public func test_tapReplay() { _ = view; demoPane.test_tapReplay() }

    /// Anything inside the demo that VoiceOver would still reach. The demo is
    /// decorative — the ribbon beside it carries every word — so this must be
    /// empty, Replay (outside the mock host) aside.
    public var test_demoAccessibilityElements: [String] {
        _ = view
        return demoPane.test_accessibleDemoDescendants
    }

    /// Whether Replay — a real control — is still reachable.
    public var test_replayIsAccessible: Bool { _ = view; return demoPane.test_replayIsAccessible }

    // MARK: Misc hooks

    /// Re-read model status into the rows (the `viewWillAppear` bind, headless).
    public func test_refresh() { _ = view; refresh(animated: false) }

    /// The silent status re-read, AWAITED — `refreshStatuses()` fires a detached
    /// task, so a headless caller that needs the result (Bluetooth and Remote
    /// Control only reach `.granted` through it) has to be able to wait for it.
    public func test_refreshStatuses() async {
        _ = view
        await model.refreshStatuses()
        refresh(animated: false)
    }

    /// Await the LOAD-TIME status read — the pass that decides what the window
    /// opened with, and the point after which a grant is a real transition.
    public func test_awaitInitialStatuses() async { _ = view; await initialStatusesTask?.value }

    /// The laid-out root view (for offscreen snapshot rendering).
    public var test_rootView: NSView {
        _ = view
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The spine column's laid-out frame in its pane — everything the left
    /// column stacks (five permission rows + the check row).
    public var test_spineStackFrame: NSRect {
        _ = view
        view.layoutSubtreeIfNeeded()
        return spineStack.frame
    }

    /// Whether this presentation was opened for a lost permission (the banner's
    /// successor — the message rides the header subtitle now).
    public var test_showsPermissionLostBanner: Bool {
        _ = view
        if case .permissionLost = reason { return true }
        return false
    }

    /// Whether the lost-permission message is currently VISIBLE — distinct from
    /// ``test_showsPermissionLostBanner`` (was one ever warranted) so a test can
    /// assert the message CLEARS once its permission is granted. Reports the
    /// tracked message KIND: the subtitle also carries the resume greeting, so
    /// "not the welcome copy" is no longer evidence of a warning.
    public var test_permissionLostBannerIsVisible: Bool {
        _ = view
        return headerMessage == .permissionLost
    }

    /// The header title currently on screen.
    public var test_titleText: String { _ = view; return titleLabel.stringValue }

    /// The header title's accessibility role — the rotor's heading contract.
    public var test_titleIsHeading: Bool {
        _ = view; return titleLabel.accessibilityRole()?.rawValue == "AXHeading"
    }

    /// The header subtitle currently on screen (welcome, resume, or the
    /// lost-permission warning).
    public var test_subtitleText: String { _ = view; return subtitleLabel.stringValue }

    /// Whether the header is showing the "you came back for the optional step"
    /// greeting.
    public var test_showsResumeHeader: Bool { _ = view; return headerMessage == .resume }

    /// The lost-permission copy, if it's showing (nil for `.firstRun`, and nil
    /// once it clears).
    public var test_permissionLostBannerText: String? {
        _ = view
        return test_permissionLostBannerIsVisible ? subtitleLabel.stringValue : nil
    }
}
