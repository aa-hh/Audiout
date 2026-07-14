// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerCore

/// The mixer window's `NSToolbar` delegate (SPEC §9 "Toolbar" + "Master volume"
/// + "Presets picker"). Hosts, in a `.unified` toolbar:
/// - a master-volume `NSSlider` (horizontal, continuous, speaker SF Symbols at
///   both ends per HIG);
/// - a presets `NSPopUpButton` with `pullsDown = false` — "choosing one item
///   from a set", shows the current selection (SPEC §9: saving/renaming are
///   separate actions, NOT mixed into this picker).
///
/// The controller is `NSToolbarDelegate`; it reports master-slider drag
/// brackets + preset selection to its `Delegate` (the window controller), which
/// forwards them to `GroupController`. It never does mixer math itself.
public final class ToolbarController: NSObject, NSToolbarDelegate {

    /// Callbacks to the window controller (→ `GroupController`).
    public protocol Delegate: AnyObject {
        func toolbarDidBeginMasterDrag(_ controller: ToolbarController)
        func toolbarController(_ controller: ToolbarController, didSetMaster volume: Int)
        func toolbarDidEndMasterDrag(_ controller: ToolbarController)
        /// A preset was chosen. `nil` = the "No group" sentinel (deactivate).
        func toolbarController(_ controller: ToolbarController, didSelectPresetGroupID groupID: String?)
    }

    public weak var delegate: Delegate?

    private static let masterItemID = NSToolbarItem.Identifier("master")
    private static let presetsItemID = NSToolbarItem.Identifier("presets")

    private let masterSlider = NSSlider()
    private let presetsPopUp = NSPopUpButton(frame: .zero, pullsDown: false)  // SPEC §9

    /// The group ids backing the presets menu, indexed to the popup's items
    /// (item 0 is the "No group" sentinel → nil).
    private var presetGroupIDs: [String?] = [nil]

    private var isDraggingMaster = false

    public override init() {
        super.init()
        buildMasterSlider()
        buildPresetsPopUp()
    }

    // MARK: State

    /// Rebuild the presets menu + master readout from the current model.
    public func reload(groups: [Group], activeGroupID: String?, masterVolume: Int) {
        // Presets popup — "No group" first, then one item per group.
        presetsPopUp.removeAllItems()
        presetGroupIDs = [nil]
        presetsPopUp.addItem(withTitle: "No group")
        for group in groups {
            presetsPopUp.addItem(withTitle: group.name)
            presetGroupIDs.append(group.id)
        }
        if let activeGroupID, let index = presetGroupIDs.firstIndex(of: activeGroupID) {
            presetsPopUp.selectItem(at: index)
        } else {
            presetsPopUp.selectItem(at: 0)
        }

        // The master slider is meaningful only with an active group; still show
        // the readout so it reflects the group's average.
        masterSlider.isEnabled = activeGroupID != nil
        if !isDraggingMaster { masterSlider.integerValue = masterVolume }
    }

    // MARK: Build

    private func buildMasterSlider() {
        masterSlider.minValue = 0
        masterSlider.maxValue = 100
        masterSlider.isContinuous = true
        masterSlider.target = self
        masterSlider.action = #selector(masterChanged(_:))
        masterSlider.setAccessibilityLabel("Master volume")
        masterSlider.frame = NSRect(x: 0, y: 0, width: 140, height: 24)
    }

    private func buildPresetsPopUp() {
        presetsPopUp.target = self
        presetsPopUp.action = #selector(presetChanged(_:))
        presetsPopUp.setAccessibilityLabel("Preset group")
        presetsPopUp.addItem(withTitle: "No group")
    }

    // MARK: Actions

    @objc private func masterChanged(_ sender: NSSlider) {
        if !isDraggingMaster {
            isDraggingMaster = true
            delegate?.toolbarDidBeginMasterDrag(self)
        }
        delegate?.toolbarController(self, didSetMaster: sender.integerValue)
        if NSApp.currentEvent?.type == .leftMouseUp {
            isDraggingMaster = false
            delegate?.toolbarDidEndMasterDrag(self)
        }
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < presetGroupIDs.count else { return }
        delegate?.toolbarController(self, didSelectPresetGroupID: presetGroupIDs[index])
    }

    // MARK: NSToolbarDelegate

    public func toolbar(_ toolbar: NSToolbar,
                        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.masterItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Master"
            item.paletteLabel = "Master Volume"
            item.view = wrapWithSpeakerIcons(masterSlider)
            return item
        case Self.presetsItemID:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Preset"
            item.paletteLabel = "Preset"
            item.view = presetsPopUp
            return item
        default:
            return nil
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.presetsItemID, .flexibleSpace, Self.masterItemID]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.presetsItemID, Self.masterItemID, .flexibleSpace, .space]
    }

    /// Master slider flanked by low/high speaker SF Symbols (HIG: icons at slider
    /// ends convey meaning — SPEC §9 "Master volume").
    private func wrapWithSpeakerIcons(_ slider: NSSlider) -> NSView {
        let low = NSImageView()
        low.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Quieter")
        low.translatesAutoresizingMaskIntoConstraints = false
        let high = NSImageView()
        high.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Louder")
        high.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [low, slider, high])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        slider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return row
    }

    // MARK: Test-support hooks

    /// The presets popup's item titles, in order (item 0 is "No group").
    public var test_presetTitles: [String] {
        presetsPopUp.itemArray.map(\.title)
    }

    /// The group id currently selected in the presets popup (nil = "No group").
    public var test_selectedPresetGroupID: String? {
        let index = presetsPopUp.indexOfSelectedItem
        guard index >= 0, index < presetGroupIDs.count else { return nil }
        return presetGroupIDs[index]
    }

    /// Simulate a full master-slider drag (begin → set → end).
    public func test_dragMaster(to value: Int) {
        delegate?.toolbarDidBeginMasterDrag(self)
        delegate?.toolbarController(self, didSetMaster: value)
        delegate?.toolbarDidEndMasterDrag(self)
    }

    /// Simulate picking a preset by group id (or nil for "No group").
    public func test_selectPreset(groupID: String?) {
        if let index = presetGroupIDs.firstIndex(of: groupID) {
            presetsPopUp.selectItem(at: index)
        }
        delegate?.toolbarController(self, didSelectPresetGroupID: groupID)
    }

    /// The master slider's current value (for readout assertions).
    public var test_masterValue: Int { masterSlider.integerValue }
}
