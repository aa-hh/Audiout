// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The Groups screen's card overview: one card per saved group in a two-column
/// grid, with the dashed "New Group" tile as the grid's last cell, and the
/// former empty pane absorbed as this screen's own zero-groups canvas.
///
/// Direction C (`dev/notes/groups-speakers-split-direction-c-brief-2026-08-27.md`):
/// the sidebar became the fleet, so saved groups live HERE, in the content
/// pane, and a card pushes in-pane to the editor. Configuration-only like the
/// rest of the module — opening a card never activates anything.
///
/// The grid is the module's first `NSCollectionView`, deliberately: it is the
/// stock platform answer to a 2D card grid (one Tab stop for the whole grid,
/// arrow keys moving in two dimensions, scrolling past ~8 groups for free) and
/// hand-rolling those three behaviours over an `NSStackView` would be strictly
/// worse than the AppKit control that already has them.
public final class GroupsOverviewViewController: NSViewController {

    // MARK: Callbacks

    /// A card was opened (click, Return or Space) — the host pushes the editor.
    public var onOpenGroup: ((String) -> Void)?
    /// The dashed "+" tile (grid or empty canvas) was activated.
    public var onNewGroup: (() -> Void)?
    /// A card's "Rename…" context item was chosen.
    public var onRequestRename: ((String) -> Void)?
    /// A card's "Delete Group…" context item was chosen.
    public var onRequestDelete: ((String) -> Void)?

    // MARK: Model

    private let groupController: GroupController

    /// Per-device icon overrides, so a card's member chips wear the same glyphs
    /// the sidebar and the editor draw. Optional exactly like the editor's.
    public var deviceIconController: DeviceIconController?

    /// The last fleet snapshot handed in by the host — member chips resolve
    /// their glyphs against it.
    private var devices: [Device] = []

    /// One rendered description per saved group, rebuilt whenever the model
    /// changes. The cards draw from these AND the headless seams read from
    /// them, so a test and the screen can never disagree about what a card
    /// says.
    private var plans: [CardPlan] = []

    /// Which grid cell is selected, mirrored out of the collection view so the
    /// Return/Space path has a truth to read in a headless run (where no cell
    /// view is ever realized).
    private var selectedIndex: Int?

    // MARK: Views

    private let titleGlyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Groups")
    private let countLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let collectionView = GridCollectionView()

    private let emptyContainer = NSView()
    private let emptyMessageLabel = NSTextField(labelWithString: "Group your speakers")
    private let emptySubtitleLabel = NSTextField(wrappingLabelWithString:
        "Save a set of speakers as a group, then switch to it in two clicks from the menu bar.")
    private let emptyNewTile = NewGroupTileView()

    private static let cardItemIdentifier = NSUserInterfaceItemIdentifier("GroupCardItem")
    private static let newTileItemIdentifier = NSUserInterfaceItemIdentifier("NewGroupTileItem")

    // MARK: Init

    public init(groupController: GroupController) {
        self.groupController = groupController
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    public override func loadView() {
        let container = NSView()

        titleGlyph.translatesAutoresizingMaskIntoConstraints = false
        titleGlyph.image = NSImage(systemSymbolName: Group.defaultIconSymbolName,
                                   accessibilityDescription: nil)
        titleGlyph.image?.isTemplate = true
        titleGlyph.contentTintColor = Tokens.Color.secondaryLabel

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Tokens.Font.heading
        titleLabel.textColor = Tokens.Color.label

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = Tokens.Font.caption
        countLabel.textColor = Tokens.Color.inkTertiary

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: GroupsOverviewLayout.cardWidth,
                                 height: GroupsOverviewLayout.cardHeight)
        layout.sectionInset = NSEdgeInsets(top: GroupsOverviewLayout.gridInset,
                                           left: GroupsOverviewLayout.gridInset,
                                           bottom: GroupsOverviewLayout.gridInset,
                                           right: GroupsOverviewLayout.gridInset)
        layout.minimumInteritemSpacing = GroupsOverviewLayout.gridGutter
        layout.minimumLineSpacing = GroupsOverviewLayout.gridGutter

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.onOpenSelection = { [weak self] in self?.openSelection() }
        collectionView.register(GroupCardItem.self,
                                forItemWithIdentifier: Self.cardItemIdentifier)
        collectionView.register(NewGroupTileItem.self,
                                forItemWithIdentifier: Self.newTileItemIdentifier)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        emptyMessageLabel.font = Tokens.Font.titleLarge
        emptyMessageLabel.textColor = Tokens.Color.secondaryLabel
        emptyMessageLabel.alignment = .center

        emptySubtitleLabel.font = Tokens.Font.subtitleLarge
        emptySubtitleLabel.textColor = Tokens.Color.inkTertiary
        emptySubtitleLabel.alignment = .center
        emptySubtitleLabel.isSelectable = false
        // A PARAGRAPH, not a width driver: on one line this sentence is the
        // widest thing on the screen and AppKit would widen the surface to fit
        // it, so it wraps inside the pane's own measure (the old empty pane's
        // lesson, carried over verbatim).
        emptySubtitleLabel.preferredMaxLayoutWidth = GroupsOverviewLayout.emptyTextWidth
        emptySubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        emptyNewTile.translatesAutoresizingMaskIntoConstraints = false
        emptyNewTile.isKeyboardFocusable = true
        emptyNewTile.onActivate = { [weak self] in self?.onNewGroup?() }

        let emptyStack = NSStackView(views: [emptyMessageLabel, emptySubtitleLabel, emptyNewTile])
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 4
        emptyStack.setCustomSpacing(16, after: emptySubtitleLabel)

        emptyContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyContainer.addSubview(emptyStack)

        container.addSubview(titleGlyph)
        container.addSubview(titleLabel)
        container.addSubview(countLabel)
        container.addSubview(scrollView)
        container.addSubview(emptyContainer)

        let inset = GroupsOverviewLayout.gridInset
        NSLayoutConstraint.activate([
            titleGlyph.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            titleGlyph.topAnchor.constraint(equalTo: container.topAnchor,
                                            constant: GroupsOverviewLayout.headerTopInset),
            titleGlyph.widthAnchor.constraint(equalToConstant: GroupsOverviewLayout.headerGlyphSize),
            titleGlyph.heightAnchor.constraint(equalToConstant: GroupsOverviewLayout.headerGlyphSize),

            titleLabel.leadingAnchor.constraint(equalTo: titleGlyph.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: titleGlyph.centerYAnchor),

            countLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                                constant: 8),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleGlyph.bottomAnchor,
                                            constant: GroupsOverviewLayout.headerToGridGap),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyContainer.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyStack.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: emptyContainer.leadingAnchor,
                                                constant: inset),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: emptyContainer.trailingAnchor,
                                                 constant: -inset),
            emptySubtitleLabel.widthAnchor.constraint(
                lessThanOrEqualToConstant: GroupsOverviewLayout.emptyTextWidth),
            emptyNewTile.widthAnchor.constraint(equalToConstant: GroupsOverviewLayout.cardWidth),
            emptyNewTile.heightAnchor.constraint(equalToConstant: GroupsOverviewLayout.cardHeight),
        ])

        view = container
        rebuild()
    }

    // MARK: Host input

    /// Re-read the model and redraw. `devices` is the host's latest fleet
    /// snapshot; the groups and the active group are read from the shared
    /// `GroupController`, exactly as the editor reads them.
    public func reload(devices: [Device]) {
        self.devices = devices
        guard isViewLoaded else { return }
        rebuild()
    }

    private func rebuild() {
        let groups = groupController.groups
        let activeID = groupController.activeGroupID
        plans = groups.map { plan(for: $0, isLive: $0.id == activeID) }

        countLabel.stringValue = plans.count == 1 ? "1 group" : "\(plans.count) groups"

        let isEmpty = plans.isEmpty
        scrollView.isHidden = isEmpty
        emptyContainer.isHidden = !isEmpty
        titleGlyph.isHidden = isEmpty
        titleLabel.isHidden = isEmpty
        countLabel.isHidden = isEmpty

        // `reloadData()` drops the collection view's OWN selection, so a
        // surviving mirror would be a lie — and Return would then open a card
        // the grid isn't showing as selected (or, after a delete, the wrong
        // one). The mirror goes wherever the real selection goes.
        selectedIndex = nil
        collectionView.reloadData()
    }

    private func plan(for group: Group, isLive: Bool) -> CardPlan {
        let shown = group.memberIDs.prefix(GroupsOverviewLayout.maxChips)
        let overflow = group.memberIDs.count - shown.count
        return CardPlan(
            groupID: group.id,
            name: group.name,
            symbolName: DeviceIcon.resolve(group.iconSymbolName,
                                           default: Group.defaultIconSymbolName),
            memberCount: group.memberIDs.count,
            isLive: isLive,
            chipSymbolNames: shown.map(chipSymbolName(forMember:)),
            overflowText: overflow > 0 ? "+\(overflow)" : nil)
    }

    private func chipSymbolName(forMember deviceID: String) -> String {
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            // A member the current fleet snapshot doesn't hold (offline, or not
            // yet discovered) still occupies its chip — the group's size must
            // not appear to shrink while a speaker is away.
            return Device.Kind.generic.symbolName
        }
        return deviceIconController?.symbolName(for: device) ?? device.kind.symbolName
    }

    // MARK: Grid contents

    /// Saved groups plus the trailing dashed "New Group" tile.
    private var cellCount: Int { plans.count + 1 }

    private func isNewTileIndex(_ index: Int) -> Bool { index == plans.count }

    private func index(ofGroup id: String) -> Int? {
        plans.firstIndex { $0.groupID == id }
    }

    // MARK: Actions

    private func activate(index: Int) {
        guard index >= 0, index < cellCount else { return }
        selectedIndex = index
        collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        if isNewTileIndex(index) {
            onNewGroup?()
        } else {
            onOpenGroup?(plans[index].groupID)
        }
    }

    private func openSelection() {
        guard let selectedIndex else { return }
        activate(index: selectedIndex)
    }

    // MARK: Context menu

    /// Built per right-click, like `SidebarViewController.menuNeedsUpdate`:
    /// only a saved group carries an identity to act on, so the New tile and
    /// blank grid space get nothing at all.
    private func contextMenu(forCardAt index: Int) -> NSMenu {
        let menu = NSMenu()
        // Nothing validates these items, so AppKit must not be left to enable
        // them (`autoenablesItems` would disable every one without a validator).
        menu.autoenablesItems = false
        guard index >= 0, index < plans.count else { return menu }
        let id = plans[index].groupID
        menu.addItem(contextMenuItem("Rename…", #selector(renameMenuItemSelected(_:)), id))
        // No destructive styling: `NSMenuItem` has no equivalent of
        // `hasDestructiveAction`, and the confirmation the delete goes through
        // is the host's, not this menu's.
        menu.addItem(contextMenuItem("Delete Group…", #selector(deleteMenuItemSelected(_:)), id))
        return menu
    }

    private func contextMenuItem(_ title: String, _ action: Selector, _ represented: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
    }

    @objc private func renameMenuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRequestRename?(id)
    }

    @objc private func deleteMenuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRequestDelete?(id)
    }

    // MARK: - Test seams (no synthesized clicks in headless runs)

    /// The saved-group cards, in the order they are laid out.
    public var test_cardGroupIDs: [String] { plans.map(\.groupID) }

    /// Click a card: selects it and opens its editor.
    public func test_clickCard(id: String) {
        guard let index = index(ofGroup: id) else { return }
        activate(index: index)
    }

    /// Whether the card draws the gold live treatment (border + wave marker).
    public func test_cardShowsLive(id: String) -> Bool {
        plans.first { $0.groupID == id }?.isLive ?? false
    }

    /// How many member chips the card draws (the `+N` chip not counted).
    public func test_chipCount(forCard id: String) -> Int {
        plans.first { $0.groupID == id }?.chipSymbolNames.count ?? 0
    }

    /// The overflow chip's text ("+3"), or `nil` when every member has a chip.
    public func test_overflowChipText(forCard id: String) -> String? {
        plans.first { $0.groupID == id }?.overflowText
    }

    /// A member chip's glyph tint. Built here rather than read off a card
    /// because the grid's cells are never realized headlessly.
    public static var test_memberChipGlyphTint: NSColor? {
        MemberChipView(symbolName: "hifispeaker").test_glyphTint
    }

    /// The titles the card's right-click menu would show.
    public func test_contextMenuItems(forCard id: String) -> [String] {
        guard let index = index(ofGroup: id) else { return [] }
        return contextMenu(forCardAt: index).items.map(\.title)
    }

    /// Choose one of the card's context items by title.
    public func test_clickContextMenuItem(_ title: String, forCard id: String) {
        guard let index = index(ofGroup: id),
              let item = contextMenu(forCardAt: index).items.first(where: { $0.title == title }),
              let action = item.action else { return }
        // Straight to the item's own target rather than through `NSApp`: this
        // runs headless, where there is no application object to route it.
        _ = (item.target as? NSObject)?.perform(action, with: item)
    }

    /// Activate the dashed "+" tile — the grid's last cell and the empty
    /// canvas's centred one both land here.
    public func test_tapNewGroup() { onNewGroup?() }

    /// Whether the zero-groups canvas is showing instead of the grid.
    public var test_isShowingEmptyCanvas: Bool { plans.isEmpty && !emptyContainer.isHidden }

    /// The empty canvas's headline text.
    public var test_emptyMessageText: String { emptyMessageLabel.stringValue }

    /// The empty canvas's teaching subtitle.
    public var test_emptySubtitleText: String { emptySubtitleLabel.stringValue }

    /// Move the grid's selection to a card, without opening it (the arrow-key
    /// path).
    public func test_selectCard(id: String) {
        guard let index = index(ofGroup: id) else { return }
        selectedIndex = index
        collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
    }

    /// Open whatever the grid has selected (the Return/Space path).
    public func test_openSelectedCard() { openSelection() }

    /// Whether the grid currently has a selection at all — the mirror the
    /// Return/Space path reads.
    public var test_hasSelectedCard: Bool { selectedIndex != nil }

    // The empty canvas's "+" tile is a real stored view, so its keyboard and
    // VoiceOver paths are reachable headlessly. The GRID's tile and the cards
    // are not: they exist only as realized collection items, which a run
    // without a sized window never has.

    /// Whether the empty canvas's tile joins the window's Tab loop.
    public var test_emptyTileAcceptsFocus: Bool { emptyNewTile.acceptsFirstResponder }

    /// Drive a real Space/Return through the empty canvas tile's `keyDown`.
    public func test_pressKeyOnEmptyTile(_ characters: String) {
        emptyNewTile.test_pressKey(characters)
    }

    /// Drive the empty canvas tile's VoiceOver "press".
    @discardableResult
    public func test_accessibilityPressEmptyTile() -> Bool {
        emptyNewTile.accessibilityPerformPress()
    }
}

// MARK: - NSCollectionViewDataSource

extension GroupsOverviewViewController: NSCollectionViewDataSource {

    public func collectionView(_ collectionView: NSCollectionView,
                               numberOfItemsInSection section: Int) -> Int {
        cellCount
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        if isNewTileIndex(indexPath.item) {
            let item = collectionView.makeItem(withIdentifier: Self.newTileItemIdentifier,
                                               for: indexPath)
            (item as? NewGroupTileItem)?.tileView.onActivate = { [weak self] in
                self?.activate(index: indexPath.item)
            }
            return item
        }
        let item = collectionView.makeItem(withIdentifier: Self.cardItemIdentifier, for: indexPath)
        if let cardItem = item as? GroupCardItem {
            cardItem.cardView.plan = plans[indexPath.item]
            cardItem.cardView.onActivate = { [weak self] in self?.activate(index: indexPath.item) }
            cardItem.cardView.contextMenuProvider = { [weak self] in
                self?.contextMenu(forCardAt: indexPath.item)
            }
        }
        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension GroupsOverviewViewController: NSCollectionViewDelegate {

    public func collectionView(_ collectionView: NSCollectionView,
                               didSelectItemsAt indexPaths: Set<IndexPath>) {
        // Selection alone never opens anything (arrow keys move, Return/Space
        // opens) — this only mirrors AppKit's selection back into the model.
        selectedIndex = indexPaths.first?.item
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if let selectedIndex, indexPaths.contains(IndexPath(item: selectedIndex, section: 0)) {
            self.selectedIndex = nil
        }
    }
}

// MARK: - Layout constants

/// The card grid's own geometry. Deliberately NOT part of `GroupsPaneLayout`:
/// that enum is the editor/detail panes' header-PARITY grammar (measured by
/// `GroupsHeaderParityTests`), and a grid that swaps in behind the same sidebar
/// shares none of those numbers.
///
/// The two columns are arithmetic, not a guess:
/// `16 + 182 + 16 + 182 + 16 = 412`, inside the 413 pt content pane.
enum GroupsOverviewLayout {
    static let cardWidth: CGFloat = 182
    static let cardHeight: CGFloat = 118
    static let gridInset: CGFloat = 16
    static let gridGutter: CGFloat = 16
    static let chipSize: CGFloat = 24

    /// Inside a card: the padding its content sits within.
    static let cardPadding: CGFloat = 12
    /// The gap between member chips along a card's bottom edge.
    static let chipGap: CGFloat = 6
    static let chipCornerRadius: CGFloat = 6
    /// How many member chips a card draws before the `+N` chip takes over.
    static let maxChips: Int = 4

    static let headerTopInset: CGFloat = 14
    static let headerGlyphSize: CGFloat = 17
    static let headerToGridGap: CGFloat = 6

    /// The measure the empty canvas's paragraph wraps to — the pane's width
    /// less its own margins, so the copy can never widen the surface.
    static let emptyTextWidth: CGFloat = SurfaceLayout.contentPaneWidth - gridInset * 2
}

// MARK: - Card description

/// Everything a card draws, computed once per rebuild. The card view renders
/// this and the headless seams read it, so the screen and a test can never
/// disagree about what a card says.
private struct CardPlan {
    let groupID: String
    let name: String
    let symbolName: String
    let memberCount: Int
    let isLive: Bool
    let chipSymbolNames: [String]
    let overflowText: String?

    /// "5 speakers", or "5 speakers · Playing now" with the live half in gold.
    var metaText: String {
        let speakers = memberCount == 1 ? "1 speaker" : "\(memberCount) speakers"
        return isLive ? "\(speakers) · Playing now" : speakers
    }
}

// MARK: - Collection view

/// The grid itself. Subclassed for ONE reason: Return and Space open the
/// selected card. Everything else the grid does — the single Tab stop, 2D
/// arrow-key movement, scrolling — is stock `NSCollectionView` behaviour.
private final class GridCollectionView: NSCollectionView {

    var onOpenSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isSpace = event.charactersIgnoringModifiers == " "
        // Only when there is something to open. With nothing selected these
        // keys have nothing to do here, and swallowing them would cost Space
        // its stock page-scroll.
        if (isReturn || isSpace), !selectionIndexPaths.isEmpty {
            onOpenSelection?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Card item

private final class GroupCardItem: NSCollectionViewItem {

    let cardView = GroupCardView()

    override func loadView() { view = cardView }

    override var isSelected: Bool {
        didSet { cardView.isSelectedInGrid = isSelected }
    }
}

/// One saved group's card, in `GroupedSectionView`'s `.card` vocabulary:
/// a `raised` fill inside a 1 pt `hairline` edge at the grouped-list radius.
/// The active Main Out group's card wears that edge in gold instead — gold
/// means LIVE, and the group genuinely is.
///
/// `draw(_:)`-based rather than a frozen layer colour, for the same reason
/// `GroupedSectionView` is: every token re-resolves per appearance flip and
/// Increase Contrast on each paint.
private final class GroupCardView: NSView {

    var onActivate: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    var plan: CardPlan? { didSet { applyPlan() } }
    var isSelectedInGrid: Bool = false { didSet { needsDisplay = true } }

    private let glyphView = NSImageView()
    private let liveMarkerView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let chipStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.contentTintColor = Tokens.Color.secondaryLabel

        liveMarkerView.translatesAutoresizingMaskIntoConstraints = false
        liveMarkerView.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                       accessibilityDescription: "Playing now")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        liveMarkerView.image?.isTemplate = true
        liveMarkerView.contentTintColor = Tokens.Color.gold
        liveMarkerView.toolTip = "Playing now"
        liveMarkerView.isHidden = true

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Tokens.Font.bodyEmphasized
        nameLabel.textColor = Tokens.Color.label
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = Tokens.Font.caption
        metaLabel.textColor = Tokens.Color.inkTertiary
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipStack.orientation = .horizontal
        chipStack.spacing = GroupsOverviewLayout.chipGap

        addSubview(glyphView)
        addSubview(liveMarkerView)
        addSubview(nameLabel)
        addSubview(metaLabel)
        addSubview(chipStack)

        let pad = GroupsOverviewLayout.cardPadding
        NSLayoutConstraint.activate([
            glyphView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            glyphView.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            glyphView.widthAnchor.constraint(equalToConstant: 17),
            glyphView.heightAnchor.constraint(equalToConstant: 17),

            liveMarkerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            liveMarkerView.centerYAnchor.constraint(equalTo: glyphView.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            nameLabel.topAnchor.constraint(equalTo: glyphView.bottomAnchor, constant: 7),

            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),

            chipStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            chipStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
            chipStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            chipStack.heightAnchor.constraint(equalToConstant: GroupsOverviewLayout.chipSize),
        ])

        setAccessibilityRole(.button)
    }

    private func applyPlan() {
        guard let plan else { return }
        glyphView.image = NSImage(systemSymbolName: plan.symbolName, accessibilityDescription: nil)
        glyphView.image?.isTemplate = true
        liveMarkerView.isHidden = !plan.isLive

        nameLabel.stringValue = plan.name
        metaLabel.attributedStringValue = metaAttributedString(plan)

        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for symbol in plan.chipSymbolNames {
            chipStack.addArrangedSubview(MemberChipView(symbolName: symbol))
        }
        if let overflowText = plan.overflowText {
            chipStack.addArrangedSubview(MemberChipView(overflowText: overflowText))
        }

        toolTip = plan.isLive ? "Playing now" : nil
        setAccessibilityLabel(plan.isLive ? "\(plan.name), Playing now" : plan.name)
        needsDisplay = true
    }

    /// The meta line: the speaker count in the frozen tertiary text colour,
    /// and — on the live card only — the "Playing now" half in gold. One of
    /// the live card's THREE gold sites (with its wave glyph and its border),
    /// under the module's seven-site rule in `AGENTS.md`.
    private func metaAttributedString(_ plan: CardPlan) -> NSAttributedString {
        let text = plan.metaText
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: Tokens.Font.caption,
                         .foregroundColor: Tokens.Color.inkTertiary])
        guard plan.isLive, let liveRange = text.range(of: "Playing now") else { return attributed }
        attributed.addAttribute(.foregroundColor, value: Tokens.Color.gold,
                                range: NSRange(liveRange, in: text))
        return attributed
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Tokens.Layout.groupedSectionCornerRadius
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        Tokens.Color.raised.setFill()
        body.fill()
        (plan?.isLive == true ? Tokens.Color.gold : Tokens.Color.hairline).setStroke()
        body.lineWidth = 1
        body.stroke()

        guard isSelectedInGrid else { return }
        // Stock focus/selection appearance — never gold, which on this screen
        // is reserved for LIVE.
        let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                                 xRadius: radius - 1, yRadius: radius - 1)
        NSColor.keyboardFocusIndicatorColor.setStroke()
        focus.lineWidth = 2
        focus.stroke()
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }

    /// The VoiceOver / Full Keyboard Access "press" entry point. A bare
    /// `NSView` wearing `.button` gets no press handler for free, so without
    /// this the card announces itself as a button and then refuses to open
    /// (`DeviceIconWellView` carries the same override for the same reason).
    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One member speaker's 24 pt chip along a card's bottom edge — a `well` fill
/// in a hairline edge — or the dashed borderless `+N` chip standing in for the
/// members past the fourth.
private final class MemberChipView: NSView {

    private let isOverflow: Bool
    private let label = NSTextField(labelWithString: "")
    private let glyphView = NSImageView()

    init(symbolName: String) {
        isOverflow = false
        super.init(frame: .zero)
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        // Medium weight so the stroke has body at 13 pt; `label` so the glyph
        // is black on the light seat (14.7:1) and near-white on the dark one.
        glyphView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        glyphView.image?.isTemplate = true
        glyphView.contentTintColor = Tokens.Color.label
        addSubview(glyphView)
        NSLayoutConstraint.activate([
            glyphView.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: 13),
            glyphView.heightAnchor.constraint(equalToConstant: 13),
        ])
        applyFixedSize()
    }

    init(overflowText: String) {
        isOverflow = true
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = overflowText
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.inkTertiary
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyFixedSize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyFixedSize() {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: GroupsOverviewLayout.chipSize),
            heightAnchor.constraint(equalToConstant: GroupsOverviewLayout.chipSize),
        ])
    }

    // The card owns the click; a chip is a picture of a member, not a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius = GroupsOverviewLayout.chipCornerRadius
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        path.lineWidth = 1
        if isOverflow {
            path.setLineDash([3, 2], count: 2, phase: 0)
            Tokens.Color.hairline.setStroke()
            path.stroke()
            return
        }
        Tokens.Color.iconSeatFill.setFill()
        path.fill()
        Tokens.Color.containerEdge.setStroke()
        path.stroke()
    }

    /// The member glyph's tint (nil on the overflow chip).
    var test_glyphTint: NSColor? { isOverflow ? nil : glyphView.contentTintColor }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - New Group tile

private final class NewGroupTileItem: NSCollectionViewItem {

    let tileView = NewGroupTileView()

    override func loadView() { view = tileView }
}

/// The dashed "+" tile: the grid's last cell, and the empty canvas's centred
/// call to action. Both doors run the host's one creation sheet.
private final class NewGroupTileView: NSView {

    var onActivate: (() -> Void)?

    /// Whether this copy joins the hosting window's Tab loop. ONLY the empty
    /// canvas's does: the grid's copy is the last CELL of an
    /// `NSCollectionView`, which already reaches it with the grid's one Tab
    /// stop plus arrow keys and Return/Space, and a focusable cell view there
    /// would add a second Tab stop inside the grid.
    var isKeyboardFocusable = false

    private let ringView = NSView()
    private let plusView = NSImageView()
    private let label = NSTextField(labelWithString: "New Group")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        plusView.translatesAutoresizingMaskIntoConstraints = false
        plusView.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        plusView.image?.isTemplate = true
        plusView.contentTintColor = Tokens.Color.secondaryLabel

        ringView.translatesAutoresizingMaskIntoConstraints = false
        ringView.wantsLayer = true
        ringView.layer?.cornerRadius = 14
        ringView.layer?.borderWidth = 1
        ringView.layer?.borderColor = Tokens.Color.hairline.cgColor
        ringView.addSubview(plusView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.inkTertiary

        addSubview(ringView)
        addSubview(label)

        NSLayoutConstraint.activate([
            ringView.centerXAnchor.constraint(equalTo: centerXAnchor),
            ringView.widthAnchor.constraint(equalToConstant: 28),
            ringView.heightAnchor.constraint(equalToConstant: 28),
            ringView.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 6),

            plusView.centerXAnchor.constraint(equalTo: ringView.centerXAnchor),
            plusView.centerYAnchor.constraint(equalTo: ringView.centerYAnchor),
            plusView.widthAnchor.constraint(equalToConstant: 14),
            plusView.heightAnchor.constraint(equalToConstant: 14),

            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: ringView.bottomAnchor, constant: 9),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel("New Group")
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Tokens.Layout.groupedSectionCornerRadius
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        Tokens.Color.hairline.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }

    // MARK: Keyboard / VoiceOver operability (A11Y-GROUPS)
    //
    // The pane this tile replaced put a stock `NSButton` on the empty canvas,
    // which came with all of the following for free. Being a bare `NSView`
    // this one hand-rolls it, exactly as `DeviceIconWellView` and the editor's
    // `BackBandView` do.

    override var acceptsFirstResponder: Bool { isKeyboardFocusable }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}":   // space, Return, keypad Enter
            onActivate?()
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    /// The standard system focus ring, traced around the tile's own dashed
    /// rounded rect so the ring hugs what the user can see.
    override func drawFocusRingMask() {
        let radius = Tokens.Layout.groupedSectionCornerRadius
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    /// Headless seam: drives a real Space/Return through `keyDown(with:)`
    /// rather than calling `onActivate` directly, so the key mapping itself is
    /// what gets asserted (`DeviceIconWellView.test_pressKey`'s pattern; no
    /// window is needed because `keyDown` never touches `window`).
    func test_pressKey(_ characters: String) {
        keyDown(with: NSEvent.keyEvent(with: .keyDown,
                                       location: .zero,
                                       modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: 0,
                                       context: nil,
                                       characters: characters,
                                       charactersIgnoringModifiers: characters,
                                       isARepeat: false,
                                       keyCode: 0)!)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ringView.layer?.borderColor = Tokens.Color.hairline.cgColor
        needsDisplay = true
    }
}
