// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudiouterPopoverUI

/// Regression coverage for the **first-collapse jump** (`CardView.setBodyCollapsed`).
///
/// THE BUG: `bodyHeightConstraint`'s constant was only ever seeded to the body's
/// expanded height as a SIDE EFFECT of a prior EXPAND animation. So on the FIRST
/// collapse of a freshly-opened popover — a card that has been shown but never
/// toggled — the constraint still held its as-created constant (`0`). Activating
/// it there pinned the clip to 0 IMMEDIATELY while `animator().constant = 0`
/// animated 0→0 (a no-op): the body height SNAPPED shut (only its alpha faded),
/// and the left-spine rail overlay — which reads the live clip floor on every
/// layout pass — snapped with it. Every LATER collapse looked fine because the
/// intervening expand had left the constant at the real height. Net effect: a
/// visible jump on the first collapse only, exactly as reported.
///
/// These tests build a REAL `CardView` in a REAL window and lay it out EXACTLY
/// ONCE (mirroring "popover just opened, card never touched"), then drive real
/// `setBodyCollapsed(animated: true)` calls. They pin the invariant that makes
/// the animation correct: a collapse always begins its height animation at the
/// EXPANDED height, so the first collapse travels the identical `height → 0` path
/// every subsequent collapse does. Because the drawn rail geometry (and the body
/// content position) are a pure function of that clip height at any animation
/// progress (see `BusRailCollapseResolveTests` behavior 3), identical start +
/// end + timing ⇒ identical intermediate geometry ⇒ no first-collapse jump.
///
/// `CardView.setBodyCollapsed(animated:)` has no Reduce-Motion gate of its own
/// (the controller decides `animated`), so the animated path runs deterministically
/// here regardless of the CI machine's accessibility settings.
@MainActor
@Suite final class CardViewCollapseTrajectoryTests: IsolatedSuite {

    private let headerRowHeight: CGFloat = 28
    private let bodyRowHeight: CGFloat = 24
    private let bodyRowCount = 4

    /// Windows are retained for the test's lifetime so nothing deallocs a view
    /// mid-animation (borderless test windows are never ordered on screen / closed).
    private var windows: [NSWindow] = []

    /// A real `CardView` (header row + several body rows) hosted in a real window
    /// and laid out ONCE — the "freshly-opened popover, never toggled" state. The
    /// initial expanded end state is applied via the same NON-animated path the
    /// panel uses on build (`applyPendingCollapseIfNeeded`), so the card starts
    /// exactly as it does in the live popover.
    private func makeLaidOutExpandedCard() -> CardView {
        let card = CardView()

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: headerRowHeight).isActive = true
        card.addRow(header)

        for _ in 0..<bodyRowCount {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: bodyRowHeight).isActive = true
            card.addBodyRow(row)
        }
        // The live panel applies the expanded end state synchronously on build.
        card.setBodyCollapsed(false, animated: false)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        windows.append(window)
        card.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: content.topAnchor),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        // The single "popover just opened" layout pass — nothing has toggled yet.
        content.layoutSubtreeIfNeeded()
        return card
    }

    /// The core regression: the FIRST animated collapse of a never-toggled card
    /// must begin its height animation at the EXPANDED height, not snap from 0.
    /// Before the fix, `lastAnimatedStartHeight` would be `0` here (the snap).
    @Test func firstAnimatedCollapseStartsFromExpandedHeightNotZero() throws {
        let card = makeLaidOutExpandedCard()

        let expandedHeight = card.bodyFittingHeight
        #expect(abs(expandedHeight - CGFloat(bodyRowCount) * bodyRowHeight) <= 0.5,
                "the expanded body is exactly its body rows stacked")
        #expect(expandedHeight > 0, "precondition: there is a body to collapse")

        card.setBodyCollapsed(true, animated: true)

        let firstStart = try #require(card.lastAnimatedStartHeight,
                                      "an animated collapse must record its start height")
        #expect(abs(firstStart - expandedHeight) <= 0.5,
                "FIRST collapse must animate DOWN from the expanded height — a 0 here is the snap glitch")
    }

    /// First-collapse-vs-second-collapse trajectory parity: the height animation
    /// starts from the same value both times, so — with the shared duration and
    /// timing curve — the clip (and thus the rail + body content) occupy identical
    /// geometry at every animation progress point. This is the property whose
    /// absence the user saw as "the first collapse jumps, the rest are fine".
    @Test func firstAndSecondCollapseShareIdenticalStartHeight() throws {
        let card = makeLaidOutExpandedCard()

        let expandedHeight = card.bodyFittingHeight

        // First collapse (fresh card, never toggled).
        card.setBodyCollapsed(true, animated: true)
        let firstStart = try #require(card.lastAnimatedStartHeight)

        // Expand back to the same expanded state. The collapse animation is
        // still IN FLIGHT here (the model constant interpolates over the
        // duration, and no runloop has ticked), so the retarget rule applies:
        // the expand continues from the LIVE height — never a forced 0, which
        // would jump the body shut mid-flight (the rapid-toggle deformation,
        // live gif 2026-08-11).
        card.setBodyCollapsed(false, animated: true)
        let expandStart = try #require(card.lastAnimatedStartHeight)
        #expect(abs(expandStart - expandedHeight) <= 0.5,
                "a mid-flight expand retarget continues from the live height")

        // … then the second collapse from that identical expanded state.
        card.setBodyCollapsed(true, animated: true)
        let secondStart = try #require(card.lastAnimatedStartHeight)

        #expect(abs(firstStart - secondStart) <= 0.5,
                "first and second collapse must share the same start height (identical trajectory)")
        #expect(abs(firstStart - expandedHeight) <= 0.5,
                "…and that shared start is the true expanded height, not the stale 0")
    }

    /// An expand from REST (a settled, completed collapse) floors at 0. Rest is
    /// reached via the non-animated path — the same end state the animated
    /// completion applies — so this pins the 0-floor without needing a runloop.
    @Test func expandFromSettledCollapseStartsAtZero() throws {
        let card = makeLaidOutExpandedCard()

        card.setBodyCollapsed(true, animated: false)
        card.layoutSubtreeIfNeeded()

        card.setBodyCollapsed(false, animated: true)
        let start = try #require(card.lastAnimatedStartHeight)
        #expect(abs(start - 0) <= 0.5,
                "an expand from rest animates UP from the collapsed floor (0)")
    }

    /// The non-animated path (initial build + Reduce Motion) is unaffected: it
    /// applies the end state synchronously and records no animation start height,
    /// so the fix touches ONLY the animated trajectory.
    @Test func nonAnimatedCollapseRecordsNoAnimationStart() {
        let card = makeLaidOutExpandedCard()

        card.setBodyCollapsed(true, animated: false)
        #expect(card.lastAnimatedStartHeight == nil,
                "the non-animated end-state path must not record an animation start height")
        // The panel settles layout after a non-animated collapse (`fittingSizeSettled`);
        // mirror that so the clip's FRAME reflects the applied end-state constraint.
        card.layoutSubtreeIfNeeded()
        #expect(abs(card.bodyClipHeight - 0) <= 0.5, "collapsed end state applied synchronously")
    }

    deinit {
        windows.removeAll()
    }
}
