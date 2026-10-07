// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutSettingsUI

@MainActor
@Suite final class HelpButtonTests: IsolatedSuite {
    // Leaving the native tooltip, accessibility help or popover label unchanged after text changes turns it red.
    @Test func textChangesReachEveryHelpSurface() {
        let button = HelpButton(subject: "Reconnect speakers", text: "Off")
        let label = button.test_helpLabel
        button.performClick(nil)
        defer { button.dismissHelp() }
        button.text = "Next launch reconnects the speakers you last used."

        #expect(button.toolTip == button.text)
        #expect(button.accessibilityHelp() == button.text)
        #expect(label.stringValue == button.text)
        #expect(button.accessibilityLabel() == "Help for Reconnect speakers")
        #expect(button.bezelStyle == .helpButton)
        #expect(button.acceptsFirstResponder)
    }

    // Capping the popover label or keeping its original height when longer help arrives turns it red.
    @Test func longHelpWrapsAndResizesThePopoverContent() throws {
        let button = HelpButton(subject: "License", text: "Short")
        let label = button.test_helpLabel
        let content = try #require(label.superview)
        let shortHeight = content.frame.height
        button.text = "Audiout checks in with the license server once per launch to spot a key shared across many machines. It sends your key, a random per-Mac id, and the app version. Nothing else."

        #expect(label.maximumNumberOfLines == 0)
        #expect(label.lineBreakMode == .byWordWrapping)
        #expect(label.cell?.truncatesLastVisibleLine == false)
        #expect(content.frame.height > shortHeight)
        #expect(label.frame.width > 0 && label.frame.width < 300)
        let measured = try #require(label.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude)))
        #expect(label.frame.height >= measured.height)
    }

    // Letting the real button action create a popover under HeadlessRuntime turns it red.
    @Test func activationStaysInvisibleInTests() {
        let button = HelpButton(subject: "Theme", text: "Follow the system.")
        #expect(HeadlessRuntime.isActive)
        button.performClick(nil)
        #expect(button.test_hasPopover)
        #expect(!button.test_isPopoverShown)
        button.performClick(nil)
        #expect(!button.test_hasPopover)
        button.performClick(nil)
        button.dismissHelp()
        #expect(!button.test_hasPopover)
    }

    // Keeping the previous anchor's popup, or letting hidden/detached anchors retain it, turns it red.
    @Test func helpClosesWhenItsAnchorIsReplacedHiddenOrDetached() {
        let first = HelpButton(subject: "Theme", text: "Theme help")
        let second = HelpButton(subject: "Accent", text: "Accent help")
        let host = NSView()
        host.addSubview(first)
        host.addSubview(second)
        first.performClick(nil)
        second.performClick(nil)
        #expect(!first.test_hasPopover)
        #expect(second.test_hasPopover)
        second.isHidden = true
        #expect(!second.test_hasPopover)
        first.performClick(nil)
        first.removeFromSuperview()
        #expect(!first.test_hasPopover)
    }

    // Sending Escape past the help responder instead of closing its own popup turns it red.
    @Test func escapeClosesTheHeldHelpFromItsContentResponder() throws {
        let button = HelpButton(subject: "Theme", text: "Theme help")
        button.performClick(nil)
        let content = try #require(button.test_helpLabel.superview)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        content.keyDown(with: escape)
        #expect(!button.test_hasPopover)
    }

    // Removing the host-window focus assignment from help activation sends Escape to the previous responder and turns it red.
    @Test func activationGivesHelpTheHostWindowFocusBeforeEscape() {
        let panel = ControlPanelPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 100),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        panel.contentView = content
        let previous = NSButton(title: "Previous control", target: nil, action: nil)
        let button = HelpButton(subject: "License", text: "License check-in disclosure")
        content.addSubview(previous)
        content.addSubview(button)
        #expect(panel.makeFirstResponder(previous))
        #expect(panel.firstResponder === previous)
        var hostCancelled = false
        panel.cancelHandler = { hostCancelled = true; return true }

        button.performClick(nil)

        #expect(panel.firstResponder === button)
        #expect(button.test_hasPopover)
        #expect(!button.test_isPopoverShown)
        #expect(panel.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil) == true)
        #expect(!button.test_hasPopover)
        #expect(!hostCancelled)
        #expect(panel.firstResponder === button)
        #expect(panel.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil) == true)
        #expect(hostCancelled)
    }

    // Replacing existing captions or keeping a removed help button in the row turns it red.
    @Test func helpRemainsOptInAndSeparateFromTheCaption() throws {
        let row = ListRowView(title: "A speaker", caption: "Allowed")
        #expect(helpButtons(in: row).isEmpty)
        #expect(row.titleLabel.toolTip == nil)
        row.helpText = "An explanation"
        let button = try #require(helpButtons(in: row).first)
        row.helpText = "Changed explanation"
        #expect(button.toolTip == "Changed explanation")
        #expect(row.caption == "Allowed")
        row.helpText = nil
        #expect(helpButtons(in: row).isEmpty)
        #expect(row.caption == "Allowed")
    }

    // Letting a long title push the help control over the accessory, or spacing short-title help at the far edge, turns it red.
    @Test func helpStaysBesideTitlesAndBeforeAccessories() throws {
        for title in ["Theme", "Reconnect last speakers when Audiout starts and keep this very long title readable"] {
            let accessory = NSSwitch()
            let row = ListRowView(title: title, accessory: accessory, helpText: "Explain")
            let window = host(row, width: 360)
            defer { window.close() }
            let button = try #require(helpButtons(in: row).first)
            // Native text fields include side insets outside their alignment rectangles.
            let titleFrame = row.titleLabel.convert(row.titleLabel.alignmentRect(forFrame: row.titleLabel.bounds), to: row)
            let helpFrame = button.convert(button.alignmentRect(forFrame: button.bounds), to: row)
            let accessoryFrame = accessory.convert(accessory.alignmentRect(forFrame: accessory.bounds), to: row)

            #expect(abs(helpFrame.minX - titleFrame.maxX - 4) < 1)
            #expect(helpFrame.width >= button.intrinsicContentSize.width)
            #expect(helpFrame.maxX <= accessoryFrame.minX - 10)
            #expect(row.titleLabel.lineBreakMode == .byTruncatingTail)
            #expect(row.titleLabel.toolTip == title)
            #expect(row.titleLabel.contentCompressionResistancePriority(for: .horizontal)
                    < button.contentCompressionResistancePriority(for: .horizontal))
        }
    }

    // Constraining an opted-in full-width caption to the title column turns it red.
    @Test func helpLeavesSpanningCaptionsIndependent() {
        let accessory = NSView()
        accessory.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let row = ListRowView(title: "Connection volume", caption: "A caption that needs to wrap over the full width of the row because it describes a longer setting.", accessory: accessory,
                              captionSpansRow: true, helpText: "Explanation")
        let window = host(row, width: 440)
        defer { window.close() }
        #expect(row.captionLabel.alignmentRect(forFrame: row.captionLabel.frame).width
                == 440 - ListRowView.leadingInset - ListRowView.trailingInset)
        #expect(row.captionLabel.frame.width > row.titleLabel.superview!.frame.width)
        #expect(row.captionLabel.preferredMaxLayoutWidth == row.captionLabel.frame.width)
    }

    // Keeping spare space around the Add row above an ordinary one-row card turns it red.
    @Test func emptyAppsCardReturnsToOneCompactRowAfterRemovalAndReopening() throws {
        let directory = scratchDir.appendingPathComponent("excluded-apps", isDirectory: true)
        let excluded = ExcludedAppsController(store: ExcludedAppsStore(directory: directory))
        let pane = AudioSettingsViewController(excluded: excluded, runningAppsProvider: { [] },
                                               settings: AppSettings(defaults: isolatedDefaults))
        let window = host(pane.view, width: SurfaceLayout.contentPaneWidth)
        defer { window.close() }

        func measure(_ pane: AudioSettingsViewController) throws -> CGFloat {
            pane.view.layoutSubtreeIfNeeded()
            let add = try #require(descendants(in: pane.view).compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "Add excluded app" })
            let row = try #require(add.subviews.first as? ListRowView)
            let stack = try #require(add.superview as? NSStackView)
            let card = try #require(stack.superview)
            let ordinary = SettingsPane.makeCard(rows: [ListRowView(title: "Ordinary row")])
            let referenceWindow = host(ordinary.container, width: card.frame.width)
            defer { referenceWindow.close() }
            let details = "card actual/fitted=\(card.frame.height)/\(card.fittingSize.height), stack=\(stack.frame.height)/\(stack.fittingSize.height), button=\(add.frame.height)/\(add.fittingSize.height), row=\(row.frame.height)/\(row.fittingSize.height), ordinary=\(ordinary.container.frame.height)/\(ordinary.container.fittingSize.height), button frame=\(add.frame), alignment=\(add.alignmentRect(forFrame: add.frame)), insets=\(add.alignmentRectInsets)"
            #expect(abs(add.frame.height - row.fittingSize.height) < 1, "\(details)")
            if stack.arrangedSubviews.count == 1 {
                #expect(abs(card.frame.height - ordinary.container.frame.height) < 1, "\(details)")
                #expect(abs(card.frame.height - card.fittingSize.height) < 1, "\(details)")
            }
            return card.frame.height
        }

        let initialHeight = try measure(pane)
        pane.test_addExcluded(bundleID: "com.example.geometry", displayName: "Geometry app")
        #expect(try measure(pane) > initialHeight)
        pane.test_removeExcluded(bundleID: "com.example.geometry")
        #expect(abs(try measure(pane) - initialHeight) < 1)
        let reopened = AudioSettingsViewController(excluded: excluded, runningAppsProvider: { [] },
                                               settings: AppSettings(defaults: isolatedDefaults))
        let reopenedWindow = host(reopened.view, width: SurfaceLayout.contentPaneWidth)
        defer { reopenedWindow.close() }
        #expect(abs(try measure(reopened) - initialHeight) < 1)
    }

    // Truncating the connection title or centering its controls against only one line turns it red.
    @Test func connectionVolumeTitleFitsTwoLinesBesideCenteredHelpAndControls() throws {
        let directory = scratchDir.appendingPathComponent("excluded-apps", isDirectory: true)
        let pane = AudioSettingsViewController(
            excluded: ExcludedAppsController(store: ExcludedAppsStore(directory: directory)),
            runningAppsProvider: { [] }, settings: AppSettings(defaults: isolatedDefaults))
        let window = host(pane.view, width: SurfaceLayout.contentPaneWidth)
        defer { window.close() }
        let row = try #require(descendants(in: pane.view).compactMap { $0 as? ListRowView }
            .first { $0.titleLabel.stringValue == "Volume when connecting a speaker" })
        let button = try #require(helpButtons(in: row).first)
        let accessory = try #require(row.accessory)
        let titleFrame = row.titleLabel.convert(row.titleLabel.alignmentRect(forFrame: row.titleLabel.bounds), to: row)
        let helpFrame = button.convert(button.alignmentRect(forFrame: button.bounds), to: row)
        let accessoryFrame = accessory.convert(accessory.alignmentRect(forFrame: accessory.bounds), to: row)
        let textBounds = NSRect(x: 0, y: 0, width: row.titleLabel.frame.width, height: .greatestFiniteMagnitude)
        let fullTitle = NSTextField(wrappingLabelWithString: row.titleLabel.stringValue)
        fullTitle.font = row.titleLabel.font
        fullTitle.maximumNumberOfLines = 0
        fullTitle.preferredMaxLayoutWidth = row.titleLabel.frame.width
        let fullTextHeight = try #require(fullTitle.cell?.cellSize(forBounds: textBounds).height)
        let singleLineHeight = NSTextField(labelWithString: row.titleLabel.stringValue)
        singleLineHeight.font = row.titleLabel.font
        let details = "row=\(row.frame), title=\(titleFrame), help=\(helpFrame), accessory=\(accessoryFrame), full text height=\(fullTextHeight)"
        #expect(row.titleLabel.lineBreakMode == .byWordWrapping)
        #expect(row.titleLabel.maximumNumberOfLines == 2)
        #expect(row.titleLabel.frame.height > singleLineHeight.intrinsicContentSize.height, "\(details)")
        #expect(row.titleLabel.frame.height >= fullTextHeight, "\(details)")
        #expect(row.titleLabel.frame.height <= singleLineHeight.intrinsicContentSize.height * 2 + 1, "\(details)")
        #expect(abs(helpFrame.minX - titleFrame.maxX - 4) < 1, "\(details)")
        #expect(helpFrame.maxX <= accessoryFrame.minX - 10, "\(details)")
        #expect(abs(helpFrame.midY - titleFrame.midY) < 1, "\(details)")
        #expect(abs(accessoryFrame.midY - titleFrame.midY) < 1, "\(details)")
        let before = row.titleLabel.frame
        pane.test_setConnectVolume(percent: 80)
        pane.view.layoutSubtreeIfNeeded()
        #expect(row.titleLabel.frame == before, "Changing live help must not change title geometry")
    }

    private func helpButtons(in view: NSView) -> [HelpButton] {
        (view as? HelpButton).map { [$0] } ?? view.subviews.flatMap { helpButtons(in: $0) }
    }

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    private func host(_ row: NSView, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        window.contentView = content
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        return window
    }
}
