// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The "New Group" sheet (design revamp, SPEC.md §9 "Group setup"): a standard
/// macOS sheet presented on the Groups window, the way Calendar presents "New
/// Calendar". The Groups window is CONFIGURATION-ONLY under the
/// revamp, and that constraint reaches this sheet too: it only ever edits a
/// group's identity and membership, never activates it — no Main Out change,
/// no routing. Activation lives in the app's popover, not here.
///
/// Layout, top to bottom, form capped to ``formWidth``:
/// - a "New Group" title line (design critique: the sheet used to open as an
///   anonymous form with no heading);
/// - a `Name` `NSTextField`, prefilled by the caller via ``configure``;
/// - a "Speakers" label + a scrollable checklist of `MembershipRowView` rows.
///   EVERY device is a candidate, unavailable ones included (Alec,
///   2026-08-28 — reverses the earlier available-only rule): a sleeping
///   HomePod can be put in "Whole House" now and simply plays when it is
///   back. Unavailable rows render dimmed with the row's own "Unavailable"
///   annotation; the caller passes devices already sorted available-first;
/// - a live "N speaker(s) selected" count label in secondary color;
/// - bottom-trailing Cancel (Escape) / Create (Return, the default button) —
///   Create is enabled only once at least one row is checked, recomputed on
///   every toggle.
///
/// On Create: builds `memberVolumes` from each checked device's current volume
/// and calls
/// `GroupController.createGroup(name:memberIDs:memberVolumes:iconSymbolName:)`,
/// which dedups an identical member set onto the existing group rather than
/// making a copy (and in that case leaves the existing group's icon alone).
/// ``onComplete`` reports the outcome (`nil` on cancel); the caller decides
/// whether to select the new/resolved group in the sidebar — this controller
/// never activates it.
///
/// An icon well sits beside the Name field: a bordered square button, corner
/// pencil badge included (`../../AGENTS.md`'s "bordered + pencil = editable"),
/// showing ``Group/defaultIconSymbolName`` until the user picks something else
/// via an anchored `IconPickerViewController` popover (same construction as
/// the group editor's icon well). The chosen name (`nil` = default) is
/// threaded through ``commit()`` into `createGroup`.
public final class GroupCreationSheetController: NSViewController {

    private let groupController: GroupController
    /// Resolves membership-row icons to any per-device override; `nil` when
    /// the caller doesn't care to show overrides (rows fall back to each
    /// device's kind-derived default).
    private let deviceIconController: DeviceIconController?

    /// Fired once, either with the created/resolved group (`alreadyExisted`
    /// true when `createGroup` deduped onto an existing group instead of
    /// making a copy), or `nil` when the user cancelled.
    public var onComplete: (((group: Group, alreadyExisted: Bool)?) -> Void)?

    /// Form width cap (approved design: ~380–420pt for a creation sheet).
    private static let formWidth: CGFloat = 400
    /// Caps the checklist's height before it scrolls, so a long fleet doesn't
    /// grow the sheet past a reasonable size. Sized so a SEVEN-device fleet (the
    /// demo fleet, and a realistic household ceiling) fits without scrolling —
    /// at 220 a 7-row list overflowed by a few points and scrolled for no
    /// visible reason. Recompute this if `MembershipRowView.rowHeight` or the
    /// stack spacing changes: 7 rows + 6 gaps + the document view's 4pt top and
    /// bottom insets — 7×32 + 6×4 + 8 = 256, plus the same ~8pt of slack the
    /// 28pt-row value carried (`rowHeight` grew to 32 on 2026-08-12).
    private static let checklistMaxHeight: CGFloat = 264

    /// Icon well square size (matches `IconPickerViewController`'s curated
    /// grid cells so the well previews at the same scale as the grid it opens).
    private static let iconWellSize: CGFloat = 32

    /// Pencil badge diameter, scaled down from `DeviceIconWellView`'s 22pt (at
    /// its 64pt well) to this sheet's smaller 32pt well — same proportion,
    /// smaller stage. Corner-badge overlay, not a second custom control: see
    /// `iconWellPencilBadge`.
    private static let pencilBadgeDiameter: CGFloat = 14

    private let nameField = NSTextField(string: "")
    private let titleLabel = NSTextField(labelWithString: "New Group")
    private let iconWellButton = NSButton()
    /// Corner pencil badge overlaid on `iconWellButton` — the sheet's icon
    /// well is a plain bordered square with no edit cue otherwise, breaking
    /// the house rule "bordered + pencil = editable" (`../../AGENTS.md`) that
    /// `DeviceIconWellView` teaches everywhere else in this screen. Click-
    /// through and non-interactive (`PencilBadgeView.hitTest` is nil) so the
    /// button underneath keeps handling the click; this is cosmetic parity,
    /// not a second custom control.
    private let iconWellPencilBadge = PencilBadgeView(diameter: GroupCreationSheetController.pencilBadgeDiameter)
    private let stackView = NSStackView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()
    private let createButton = NSButton()

    /// The user's chosen icon override, `nil` meaning "use the default group
    /// icon" (``Group/defaultIconSymbolName``). Threaded into ``commit()``.
    private var selectedIconSymbolName: String?

    /// Keeps the checklist scroll view exactly as tall as its rows (built
    /// lazily in `loadView` — the document view must exist first). See the
    /// comment at its activation site.
    private lazy var checklistHugsContentConstraint: NSLayoutConstraint = {
        let c = scrollView.heightAnchor.constraint(
            equalTo: scrollView.documentView!.heightAnchor)
        c.priority = .defaultHigh
        return c
    }()

    /// Membership rows keyed by device id, so toggles and tests can find them.
    private var rowsByID: [String: MembershipRowView] = [:]
    /// The devices offered as membership candidates, in order — already
    /// filtered to `isAvailable` by ``configure``.
    private var candidateDevices: [Device] = []
    /// Checked device ids (a subset of `candidateDevices`).
    private var checkedIDs: Set<String> = []

    public init(groupController: GroupController, deviceIconController: DeviceIconController? = nil) {
        self.groupController = groupController
        self.deviceIconController = deviceIconController
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Focus the name field with its prefilled text SELECTED the moment the
    /// sheet appears — keeping the suggestion costs nothing and replacing it is
    /// just typing, so the prefill never traps the user into a meaningless
    /// name. Only fires on a genuine on-screen presentation (headless runs
    /// never call this).
    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    public override func loadView() {
        // Standard sheet message style: the anonymous form's missing title
        // line (design critique — a sheet with no heading reads as an
        // unlabeled form).
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Tokens.Font.bodyEmphasized

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "Group name"
        nameField.setAccessibilityLabel("Group name")
        nameField.target = self
        nameField.action = #selector(nameFieldReturnPressed(_:))

        iconWellButton.translatesAutoresizingMaskIntoConstraints = false
        iconWellButton.widthAnchor.constraint(equalToConstant: Self.iconWellSize).isActive = true
        iconWellButton.heightAnchor.constraint(equalToConstant: Self.iconWellSize).isActive = true
        iconWellButton.bezelStyle = .regularSquare
        iconWellButton.isBordered = true
        iconWellButton.imagePosition = .imageOnly
        iconWellButton.toolTip = "Choose icon"
        iconWellButton.setAccessibilityLabel("Choose group icon")
        iconWellButton.target = self
        iconWellButton.action = #selector(iconWellTapped(_:))
        updateIconWell()

        // Corner pencil badge — "bordered + pencil = editable" parity with
        // `DeviceIconWellView`. Added after `updateIconWell()` so it draws
        // above the resolved glyph.
        iconWellPencilBadge.translatesAutoresizingMaskIntoConstraints = false
        iconWellButton.addSubview(iconWellPencilBadge)
        NSLayoutConstraint.activate([
            iconWellPencilBadge.widthAnchor.constraint(equalToConstant: Self.pencilBadgeDiameter),
            iconWellPencilBadge.heightAnchor.constraint(equalToConstant: Self.pencilBadgeDiameter),
            iconWellPencilBadge.trailingAnchor.constraint(equalTo: iconWellButton.trailingAnchor, constant: -1),
            iconWellPencilBadge.bottomAnchor.constraint(equalTo: iconWellButton.bottomAnchor, constant: -1),
        ])

        let speakersLabel = NSTextField(labelWithString: "Speakers")
        speakersLabel.translatesAutoresizingMaskIntoConstraints = false
        speakersLabel.textColor = Tokens.Color.secondaryLabel

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.spacing = 4

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = Tokens.Font.caption
        countLabel.textColor = Tokens.Color.secondaryLabel

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"   // Escape
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))

        createButton.translatesAutoresizingMaskIntoConstraints = false
        createButton.title = "Create"
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"       // default button (Return)
        createButton.target = self
        createButton.action = #selector(createTapped(_:))

        let container = NSView()
        for v in [titleLabel, iconWellButton, nameField, speakersLabel, scrollView, countLabel, cancelButton, createButton] {
            container.addSubview(v)
        }

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.formWidth),

            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            iconWellButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            iconWellButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            nameField.centerYAnchor.constraint(equalTo: iconWellButton.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: iconWellButton.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            speakersLabel.topAnchor.constraint(equalTo: iconWellButton.bottomAnchor, constant: 16),
            speakersLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            scrollView.topAnchor.constraint(equalTo: speakersLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.checklistMaxHeight),
            // An NSScrollView has no intrinsic size, so without this the whole
            // checklist collapses to zero under `fittingSize` (which is how the
            // sheet sizes itself). Hug the checklist content at less-than-
            // required priority so the ≤ maxHeight cap above can still win for
            // long fleets (content taller than the cap → the list scrolls).
            checklistHugsContentConstraint,

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 4),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -4),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            countLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            countLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            createButton.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 16),
            createButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            createButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            cancelButton.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -12),
        ])

        view = container
    }

    // MARK: Model

    /// Configure the sheet before presenting it: prefill the name field with
    /// `defaultName`, and build the membership checklist from `devices` —
    /// EVERY device, unavailable ones included (Alec, 2026-08-28: an offline
    /// speaker may join a group and plays when it returns; this is also what
    /// keeps the add bar's "New Group from N Speakers…" count honest when the
    /// selection includes a sleeping speaker). `preselected` checks any
    /// candidate whose id is a member.
    public func configure(defaultName: String, devices: [Device], preselected: Set<String> = []) {
        nameField.stringValue = defaultName
        candidateDevices = devices
        checkedIDs = preselected.intersection(Set(candidateDevices.map(\.id)))
        buildRows()
        updateCountLabel()
        updateCreateEnabled()
    }

    /// The copy an EMPTY checklist carries. Zero available speakers used to
    /// render as an empty box beside a disabled Create button, which reads as
    /// a broken sheet rather than "nothing has been found yet".
    private static let emptyChecklistText =
        "No speakers found yet. Speakers appear here once they\u{2019}re reachable on your network."

    /// The empty-state label while it is mounted, else nil.
    private var emptyChecklistLabel: NSTextField?

    /// (Re)build the membership checklist rows from `candidateDevices`.
    private func buildRows() {
        for v in stackView.arrangedSubviews { stackView.removeArrangedSubview(v); v.removeFromSuperview() }
        rowsByID.removeAll()
        emptyChecklistLabel = nil
        guard !candidateDevices.isEmpty else {
            let label = NSTextField(wrappingLabelWithString: Self.emptyChecklistText)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = Tokens.Font.body
            label.textColor = Tokens.Color.secondaryLabel
            stackView.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            label.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            emptyChecklistLabel = label
            return
        }
        for device in candidateDevices {
            // `.systemSheet` (Alec, Q6): this is a STOCK AppKit sheet on the
            // system's own white/grey, where `ember` measures ~2.34–2.48:1 and
            // a gold node would be near-invisible. The rail/node language is
            // warm-pane-only — plain stock rows here, no node, no gold.
            let row = MembershipRowView(
                device: device, checked: checkedIDs.contains(device.id),
                iconSymbolName: deviceIconController?.symbolName(for: device),
                surface: .systemSheet)
            row.onToggle = { [weak self] deviceID, isChecked in
                self?.handleToggle(deviceID: deviceID, isChecked: isChecked)
            }
            rowsByID[device.id] = row
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        }
    }

    private func handleToggle(deviceID: String, isChecked: Bool) {
        if isChecked {
            checkedIDs.insert(deviceID)
        } else {
            checkedIDs.remove(deviceID)
        }
        updateCountLabel()
        updateCreateEnabled()
    }

    private var isCreateEnabled: Bool { !checkedIDs.isEmpty }

    private func updateCreateEnabled() {
        createButton.isEnabled = isCreateEnabled
    }

    private func updateCountLabel() {
        let count = checkedIDs.count
        countLabel.stringValue = count == 1 ? "1 speaker selected" : "\(count) speakers selected"
    }

    // MARK: Actions

    @objc private func nameFieldReturnPressed(_ sender: NSTextField) {
        // Return in the name field commits the sheet exactly like clicking
        // Create — but only when Create would itself be enabled.
        guard isCreateEnabled else { return }
        commit()
    }

    @objc private func createTapped(_ sender: NSButton) {
        commit()
    }

    @objc private func cancelTapped(_ sender: NSButton) {
        cancel()
    }

    @objc private func iconWellTapped(_ sender: NSButton) {
        let picker = IconPickerViewController()
        picker.configure(currentSymbolName: selectedIconSymbolName, defaultSymbolName: Group.defaultIconSymbolName)
        picker.onPick = { [weak self] name in
            self?.pickIcon(name)
        }
        present(picker, asPopoverRelativeTo: sender.bounds, of: sender,
                preferredEdge: .maxY, behavior: .transient)
    }

    /// Apply a picked icon (`nil` = default) and refresh the well's glyph.
    /// Shared by the real popover callback and ``test_pickIcon(_:)``.
    private func pickIcon(_ name: String?) {
        selectedIconSymbolName = name
        updateIconWell()
    }

    /// Refresh the icon well's glyph from ``selectedIconSymbolName``, falling
    /// back through ``DeviceIcon/resolve(_:default:)`` exactly like every
    /// other icon-rendering site — a stale override never shows a blank glyph.
    private func updateIconWell() {
        let symbolName = DeviceIcon.resolve(selectedIconSymbolName, default: Group.defaultIconSymbolName)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Group icon")
        image?.isTemplate = true
        iconWellButton.image = image
        iconWellButton.contentTintColor = Tokens.Color.secondaryLabel
    }

    /// Persist the checked candidates as a new group via
    /// ``GroupController/createGroup`` (which dedups by member set); each member's
    /// `memberVolumes` entry is that device's current backend volume.
    private func commit() {
        guard isCreateEnabled else { return }
        // ONCE. Return in the name field and the default button's own Return
        // both land here, and a second landing arrives AFTER the first has
        // already saved the group — so the sheet refused the name it had just
        // created, on a first-ever group ("that name is already taken",
        // live-caught 2026-09-03). Everything below is re-runnable after a
        // REFUSAL (the flag is only set once a group actually exists), so a
        // corrected name still commits.
        guard !hasCreatedGroup else { return }
        // An alert this sheet raised is still up. The second landing
        // would raise a SECOND alert on a window that already has one
        // attached, and AppKit hosts that orphan on a blank window of
        // its own — live-caught 2026-09-03, a grey "Untitled" window
        // behind the dedup alert.
        guard !isShowingAlert else { return }
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "New Group" : trimmed
        // TAKEN NAME first: refusing the name wins over resolving the member
        // set, so the user fixes one thing at a time. Case-insensitive, and
        // against every group — nothing here is being renamed.
        guard !isNameTaken(name) else {
            test_duplicateNameRefused = true
            presentSheetAlert(
                messageText: "That name is already taken.",
                informativeText:
                    "Another group is named \u{201C}\(name)\u{201D}. Choose a different name.")
            return
        }
        let memberIDs = candidateDevices.map(\.id).filter { checkedIDs.contains($0) }
        let memberVolumes = Dictionary(uniqueKeysWithValues: memberIDs.compactMap { id -> (String, Int)? in
            candidateDevices.first(where: { $0.id == id }).map { (id, $0.volume) }
        })
        let result: GroupController.CreateResult
        do {
            result = try groupController.createGroup(
                name: name, memberIDs: memberIDs, memberVolumes: memberVolumes,
                iconSymbolName: selectedIconSymbolName)
        } catch {
            // REPORTED, never swallowed (the editor's `saveOrReport` contract,
            // one surface over): the sheet used to `try?` this and simply do
            // nothing, so a failed write looked exactly like a dead button.
            // The form stays intact and Create stays enabled — try again.
            test_saveFailureReported = true
            presentSheetAlert(
                messageText: "Couldn\u{2019}t create the group.",
                informativeText: "The group couldn\u{2019}t be saved. Try again.")
            return
        }
        hasCreatedGroup = !result.alreadyExisted
        Analytics.capture("scene:created", [
            "source": "sheet",
            "member_count": String(memberIDs.count),
            "already_existed": result.alreadyExisted ? "true" : "false",
        ])
        // DEDUP SAID OUT LOUD: `createGroup` resolves an identical member set
        // onto the existing group rather than making a copy, and silently
        // landing the user in some other group's editor reads as a bug.
        if result.alreadyExisted, let window = view.window {
            presentAlreadyExistsAlert(result: result, on: window)
            return
        }
        finish((group: result.group, alreadyExisted: result.alreadyExisted))
    }

    /// Set once ``commit()`` has actually saved a NEW group, so a second
    /// Return or click cannot run the form again against the group it just
    /// made. Not set when the member set resolved onto an existing group —
    /// nothing was written, and the user may still go back and change the
    /// selection.
    private var hasCreatedGroup = false

    /// Whether an alert this sheet raised is on screen and unanswered.
    private var alertIsUp = false

    /// `nil` = read the real state. A real alert cannot be begun headlessly
    /// without putting a sheet on the developer's screen, so the re-entry
    /// guard is unreachable in `swift test` without this — same seam shape as
    /// `ControlPanelWindowController.test_hasAttachedSheetOverride`.
    public var test_alertIsUpOverride: Bool?

    private var isShowingAlert: Bool { test_alertIsUpOverride ?? alertIsUp }

    /// Whether any saved group already carries `name` (case-insensitively).
    private func isNameTaken(_ name: String) -> Bool {
        groupController.groups.contains {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// A window-guarded warning sheet on this sheet's own window — mirrors
    /// `GroupEditorViewController.presentPersistFailureAlert`. Headless runs
    /// have no window; the `test_*` seams observe the outcome instead.
    private func presentSheetAlert(messageText: String, informativeText: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alertIsUp = true
        alert.beginSheetModal(for: window) { [weak self] _ in self?.alertIsUp = false }
    }

    /// "These speakers are already a group" — a CHOICE, not a redirect: open
    /// the group that already holds them, or go back to the form (untouched)
    /// and change the selection.
    private func presentAlreadyExistsAlert(result: GroupController.CreateResult,
                                           on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText =
            "Those speakers are already saved as \u{201C}\(result.group.name)\u{201D}."
        alert.informativeText = "You can open that group, or go back and change the selection."
        alert.addButton(withTitle: "Open \u{201C}\(result.group.name)\u{201D}")
        alert.addButton(withTitle: "Go Back")
        alertIsUp = true
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.alertIsUp = false
            guard response == .alertFirstButtonReturn else { return }
            self?.finish((group: result.group, alreadyExisted: result.alreadyExisted))
        }
    }

    private func cancel() {
        finish(nil)
    }

    /// Report the outcome and dismiss. Dismissing only when actually presented
    /// (`view.window != nil`) lets a headless test drive `commit()`/`cancel()`
    /// directly without a hosting window — mirrors
    /// `GroupEditorViewController.test_confirmDelete`'s bypass of the
    /// sheet-only path.
    private func finish(_ result: (group: Group, alreadyExisted: Bool)?) {
        onComplete?(result)
        if view.window != nil { dismiss(self) }
    }

    // MARK: Test-support hooks
    //
    // No synthesized clicks in headless runs (`../AGENTS.md`) — these drive
    // the same code paths a real UI interaction would.

    /// Simulate typing a new name into the name field (no commit).
    public func test_setName(_ name: String) {
        nameField.stringValue = name
    }

    /// The name field's current text (the caller-provided prefill until the
    /// user edits it).
    public var test_nameFieldText: String { nameField.stringValue }

    /// Simulate ticking/unticking a candidate's membership checkbox.
    public func test_setMembership(deviceID: String, isChecked: Bool) {
        guard let row = rowsByID[deviceID] else { return }
        row.isChecked = isChecked
        handleToggle(deviceID: deviceID, isChecked: isChecked)
    }

    /// Checked candidate device ids, in candidate order.
    public var test_checkedDeviceIDs: [String] {
        candidateDevices.map(\.id).filter { checkedIDs.contains($0) }
    }

    /// All candidate device ids offered as membership rows (available devices
    /// only — see ``configure``).
    public var test_candidateDeviceIDs: [String] { candidateDevices.map(\.id) }

    /// Whether Create is currently enabled (>= 1 row checked).
    public var test_isCreateEnabled: Bool { isCreateEnabled }

    /// Whether the checklist would scroll at its current content height — its
    /// rows are taller than the cap that stops the sheet growing. Pure
    /// arithmetic against the same two numbers Auto Layout resolves, so it
    /// holds headlessly without a presented sheet.
    public var test_checklistScrolls: Bool {
        guard let documentView = scrollView.documentView else { return false }
        return documentView.fittingSize.height > Self.checklistMaxHeight + 0.5
    }

    /// The live selection-count label's current text.
    public var test_countText: String { countLabel.stringValue }

    /// Simulate clicking Create (no-op when disabled, exactly like the real
    /// button).
    public func test_commit() { commit() }

    /// Simulate clicking Cancel.
    public func test_cancel() { cancel() }

    /// The icon well's currently-resolved symbol name (``Group/defaultIconSymbolName``
    /// until a pick overrides it, resolved through ``DeviceIcon/resolve(_:default:)``
    /// exactly like the rendered glyph).
    public var test_iconWellSymbolName: String {
        DeviceIcon.resolve(selectedIconSymbolName, default: Group.defaultIconSymbolName)
    }

    /// Simulate picking an icon from the picker (`nil` = "use default icon"),
    /// bypassing the popover exactly like `IconPickerViewController`'s own
    /// `test_pickCurated`/`test_useDefault` hooks bypass presentation.
    public func test_pickIcon(_ name: String?) { pickIcon(name) }

    /// The sheet's title line ("New Group"). `loadViewIfNeeded()` first since a
    /// headless test may ask before the sheet has ever been presented (the
    /// view loads lazily, same as every other hook below that reads it).
    public var test_titleText: String {
        loadViewIfNeeded()
        return titleLabel.stringValue
    }

    /// The empty checklist's explanation while it is mounted, else nil (the
    /// checklist has real rows).
    public var test_emptyChecklistText: String? {
        emptyChecklistLabel?.stringValue
    }

    /// True once a failed save was REPORTED rather than swallowed. Headless
    /// seam — the alert is a window-guarded sheet.
    public private(set) var test_saveFailureReported = false

    /// True once a commit was refused because another group already had that
    /// name. Headless seam, same reason as ``test_saveFailureReported``.
    public private(set) var test_duplicateNameRefused = false

    /// True while the icon well's corner pencil badge is mounted — the
    /// "bordered + pencil = editable" cue this sheet's icon well otherwise
    /// lacked. `loadViewIfNeeded()` for the same reason as `test_titleText`.
    public var test_iconWellShowsPencil: Bool {
        loadViewIfNeeded()
        return iconWellPencilBadge.superview === iconWellButton
    }
}

/// A flipped document view so the checklist scrolls from the top rather than
/// bottom-gravitating with dead space above the rows. File-scoped on purpose.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The creation sheet's icon-well corner pencil — a cosmetic echo of
/// `DeviceIconWellView`'s badge (`../../AGENTS.md`'s "bordered + pencil =
/// editable"), NOT a second custom control: no hover step-up, no keyboard
/// handling, nothing the well itself doesn't already provide. `hitTest`
/// always returns `nil` so a click anywhere on the badge still reaches
/// `iconWellButton` underneath it.
private final class PencilBadgeView: NSView {
    init(diameter: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.backgroundColor = Tokens.Color.iconWellBadge.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Tokens.Color.iconWellBadgeBorder.cgColor

        let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        pencil?.isTemplate = true
        let pencilView = NSImageView(image: pencil ?? NSImage())
        // Fixed white, matching `DeviceIconWellView.badgePencilImageView` —
        // the badge fill it sits on is a fixed dark scrim in both themes, so
        // this glyph never has to chase the appearance either.
        pencilView.contentTintColor = .white
        pencilView.imageScaling = .scaleProportionallyUpOrDown
        pencilView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pencilView)
        NSLayoutConstraint.activate([
            pencilView.centerXAnchor.constraint(equalTo: centerXAnchor),
            pencilView.centerYAnchor.constraint(equalTo: centerYAnchor),
            pencilView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.55),
            pencilView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.55),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
