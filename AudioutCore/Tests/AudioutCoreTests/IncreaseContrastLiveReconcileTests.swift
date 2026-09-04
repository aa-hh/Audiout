// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
import ObjectiveC.runtime
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutSettingsUI
@testable import AudioutWindowUI

/// Increase Contrast has to reach the Groups window and Settings while the app
/// is running.
///
/// The setting picks the high-contrast hex inside each token's own colour
/// provider, off `NSWorkspace.accessibilityDisplayShouldIncreaseContrast`, and
/// the app pins its own appearance for the theme setting — so flipping it in
/// System Settings changes no view's effective appearance and fires no
/// `viewDidChangeEffectiveAppearance`. Every view that paints a token has to
/// hear `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` itself,
/// or it keeps its standard-contrast colours until some unrelated repaint
/// happens along.
///
/// These tests post that notification on the same centre the OS posts it on,
/// and assert each view actually asked to be repainted. Asserting that an
/// observer was registered would be the same class of bug as the one being
/// fixed: it passes on a view whose handler does nothing.
///
/// Why the request is recorded rather than read back: `needsDisplay` is
/// unreadable in a headless run. AppKit drops it on a view with no window, and
/// a view in an offscreen window that has never displayed reports `true`
/// whatever you set (both measured, 2026-09-04). Recording the call as the
/// view makes it is the only way to see the redraw at all.
@MainActor
@Suite final class IncreaseContrastLiveReconcileTests: IsolatedSuite {

    // MARK: Harness

    /// The views that asked to be repainted while the setting flipped.
    private final class RedrawLog {
        var views: Set<ObjectIdentifier> = []
    }

    /// Posts the notification exactly as `NSWorkspace` does, and returns every
    /// view that set `needsDisplay` in response.
    private func redrawRequestsDuringTheFlip() -> Set<ObjectIdentifier> {
        let log = RedrawLog()
        let selector = NSSelectorFromString("setNeedsDisplay:")
        guard let method = class_getInstanceMethod(NSView.self, selector) else {
            Issue.record("NSView has no setNeedsDisplay:")
            return []
        }
        typealias Setter = @convention(c) (NSView, Selector, ObjCBool) -> Void
        let original = method_getImplementation(method)
        let callOriginal = unsafeBitCast(original, to: Setter.self)
        let recording: @convention(block) (NSView, ObjCBool) -> Void = { view, flag in
            if flag.boolValue { log.views.insert(ObjectIdentifier(view)) }
            callOriginal(view, selector, flag)
        }
        method_setImplementation(method, imp_implementationWithBlock(recording))
        defer { method_setImplementation(method, original) }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared)
        return log.views
    }

    /// Flips the setting and names the views that never asked for a repaint.
    private func viewsThatIgnoredTheFlip(_ views: [(name: String, view: NSView)]) -> [String] {
        let asked = redrawRequestsDuringTheFlip()
        return views
            .filter { !asked.contains(ObjectIdentifier($0.view)) }
            .map(\.name)
    }

    /// Every view in `root`'s subtree that paints its own pixels — i.e. whose
    /// class overrides `draw(_:)` or `drawBackground(in:)`. Those are exactly
    /// the views a token change has to reach, and finding them by walking the
    /// real tree means a view added later is covered without editing a list.
    private func customDrawingViews(in root: NSView,
                                    path: String = "") -> [(name: String, view: NSView)] {
        var found: [(String, NSView)] = []
        let name = path.isEmpty ? "\(type(of: root))" : "\(path) › \(type(of: root))"
        if drawsItsOwnPixels(root) { found.append((name, root)) }
        for child in root.subviews { found += customDrawingViews(in: child, path: name) }
        return found
    }

    /// True when one of the app's own classes in `view`'s inheritance chain
    /// defines `drawRect:` or `drawBackground:` itself. Stock AppKit controls
    /// all draw too, so the module-name check is what keeps the walk to views
    /// this codebase is responsible for colouring.
    private func drawsItsOwnPixels(_ view: NSView) -> Bool {
        var cls: AnyClass? = type(of: view)
        while let current = cls {
            if String(cString: class_getName(current)).contains("Audiout"),
               definesDrawing(current) {
                return true
            }
            cls = class_getSuperclass(current)
        }
        return false
    }

    /// Whether `cls` ITSELF (not an ancestor) implements a drawing method.
    private func definesDrawing(_ cls: AnyClass) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return false }
        defer { free(methods) }
        return (0..<Int(count)).contains { index in
            let name = NSStringFromSelector(method_getName(methods[index]))
            return name == "drawRect:" || name == "drawBackground:"
        }
    }

    private func makeExcluded() -> ExcludedAppsController {
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return ExcludedAppsController(store: ExcludedAppsStore(directory: dir))
    }

    private func makeGroupController() -> GroupController {
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return GroupController(backend: MockBackend(fleet: []),
                               store: GroupStore(directory: dir),
                               loadPersisted: false)
    }

    // MARK: The harness itself

    /// The recording has to be able to fail, or every test below is decoration.
    @Test func aViewThatNeverSubscribedIsReportedAsIgnoringTheFlip() {
        final class Unsubscribed: NSView {
            override func draw(_ dirtyRect: NSRect) {}
        }
        let deaf = Unsubscribed()
        let listening = Unsubscribed()
        listening.redrawOnAccessibilityDisplayChange()

        let ignored = viewsThatIgnoredTheFlip([("deaf", deaf), ("listening", listening)])
        #expect(ignored == ["deaf"])
    }

    // MARK: The Groups window

    @Test func theGroupCardAndEverythingOnItRedraws() {
        let card = GroupsOverviewViewController.test_makeCardOffScreen()
        let views = customDrawingViews(in: card)
        #expect(views.count >= 3,
                "expected the card, its icon seat and its chips — found \(views.map(\.name))")
        #expect(viewsThatIgnoredTheFlip(views).isEmpty)
    }

    @Test func theGroupsOverviewCanvasRedraws() {
        let overview = GroupsOverviewViewController(groupController: makeGroupController())
        _ = overview.view
        overview.reload(devices: [])
        #expect(overview.test_isShowingEmptyCanvas)

        let views = customDrawingViews(in: overview.view)
        #expect(!views.isEmpty)
        #expect(viewsThatIgnoredTheFlip(views).isEmpty)
    }

    @Test func theMembershipRowRedraws() {
        let row = MembershipRowView(device: Device(id: "office", name: "Office",
                                                   kind: .generic, isAvailable: true),
                                    checked: true)
        #expect(viewsThatIgnoredTheFlip([("MembershipRowView", row)]).isEmpty)
    }

    @Test func theWindowChromeRedraws() {
        let views: [(String, NSView)] = [
            ("GroupedSectionView", GroupedSectionView()),
            ("PlateRowView", PlateRowView()),
            ("HairlineView", HairlineView()),
        ]
        #expect(viewsThatIgnoredTheFlip(views).isEmpty)
    }

    @Test func theDeviceIconWellRedrawsAndRestampsItsBadge() {
        let well = DeviceIconWellView()
        let stampsBefore = well.test_restampCount

        let ignored = viewsThatIgnoredTheFlip([("DeviceIconWellView", well)])

        #expect(well.test_restampCount > stampsBefore,
                "the badge's colours are frozen CGColors — a repaint alone never moves them")
        #expect(ignored.isEmpty, "the well itself is drawn from live tokens")
    }

    @Test func theCreationSheetPencilBadgeRestamps() {
        let sheet = GroupCreationSheetController(groupController: makeGroupController())
        #expect(sheet.test_iconWellShowsPencil)
        let stampsBefore = sheet.test_pencilBadgeRestampCount

        _ = redrawRequestsDuringTheFlip()

        #expect(sheet.test_pencilBadgeRestampCount > stampsBefore)
    }

    @Test func theIconPickerPreviewTileRedraws() {
        let picker = IconPickerViewController()
        _ = picker.view
        let views = customDrawingViews(in: picker.view)
        #expect(!views.isEmpty)
        #expect(viewsThatIgnoredTheFlip(views).isEmpty)
    }

    // MARK: Settings

    @Test func theAppearancePaneRedraws() {
        let pane = AppearanceSettingsViewController(settings: AppSettings(defaults: makeDefaults()))
        _ = pane.view
        let views = customDrawingViews(in: pane.view)
        #expect(!views.isEmpty, "expected the theme tiles")
        #expect(viewsThatIgnoredTheFlip(views).isEmpty)
    }

    @Test func theAudioPaneRedraws() {
        let pane = AudioSettingsViewController(excluded: makeExcluded(),
                                               runningAppsProvider: { [] })
        _ = pane.view
        let views = customDrawingViews(in: pane.view)
        #expect(!views.isEmpty, "expected the excluded-apps list border")
        #expect(viewsThatIgnoredTheFlip(views).isEmpty)
    }

    @Test func theSettingsValueReadoutRedraws() {
        let well = SettingsForm.readoutWell(NSTextField(labelWithString: "35%"), width: 44)
        let views = customDrawingViews(in: well)
        #expect(!views.isEmpty)
        #expect(viewsThatIgnoredTheFlip(views).isEmpty)
    }
}
