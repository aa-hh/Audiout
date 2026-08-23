// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// The row-as-fader drag, for a row that lives inside a vertical `ScrollView`.
///
/// NEVER a SwiftUI `DragGesture` for this, whatever its `minimumDistance`
/// and whether or not it is attached with `.simultaneousGesture`: SwiftUI has
/// no equivalent of the design's CSS `touch-action: pan-y` (doc:79), and a
/// `DragGesture` on a scroll-view child wins arbitration outright with no way
/// to give the pan back — the list then does not scroll at all wherever a
/// finger lands on a row, ignoring vertical movement included.
///
/// So the drag is a real `UIGestureRecognizer`, installed through iOS 18's
/// ``SwiftUI/UIGestureRecognizerRepresentable``, and it settles the question
/// in UIKit's own arbitration rather than SwiftUI's:
///
/// - Nothing happens for the first ``slop`` points, so a tap is still a tap.
/// - The first committed movement picks the axis. **Vertical FAILS the
///   recognizer**, which is the whole fix — a failed recognizer prevents
///   nothing, so the enclosing `UIScrollView`'s pan proceeds untouched and the
///   list scrolls exactly like a stock `List`.
/// - Horizontal begins it, at which point the scroll view's own pan has not
///   yet passed its larger hysteresis, so this recognizer wins and the row
///   becomes the fader.
/// - ``UIKit/UIGestureRecognizer/canBePrevented(by:)`` is `false` regardless,
///   so if a scroll pan does get in first it cannot kill the horizontal drag.
///
/// Phases are reported through ``action`` from the recognizer itself rather
/// than through `handleUIGestureRecognizerAction`, because UIKit sends no
/// action for a recognizer that fails — and failing is this recognizer's most
/// important outcome, the one the row needs in order to drop its pressed
/// flash.
struct HorizontalDragGesture: UIGestureRecognizerRepresentable {
    /// What the finger just did. Translation is horizontal points from the
    /// touch-down point, the same number a `DragGesture`'s
    /// `translation.width` carried.
    enum Phase {
        /// Touch-down, before the gesture has decided what it is.
        case down
        /// The finger committed horizontally: this is the fader's first tick.
        case began(CGFloat)
        case changed(CGFloat)
        case ended
        /// Lifted without ever committing — the row's tap.
        case tapped
        /// Committed vertically (the scroll view has it now), or the system
        /// took the touch away.
        case cancelled
    }

    /// How far the finger travels before the axis is decided (doc:1739,
    /// doc:1773).
    var slop: CGFloat = 5
    let action: (Phase) -> Void

    func makeUIGestureRecognizer(context: Context) -> HorizontalDragRecognizer {
        HorizontalDragRecognizer()
    }

    func updateUIGestureRecognizer(_ recognizer: HorizontalDragRecognizer, context: Context) {
        recognizer.slop = slop
        recognizer.report = action
    }
}

/// ``HorizontalDragGesture``'s recognizer. Split out because
/// `UIGestureRecognizerRepresentable` needs a concrete recognizer type, and
/// all of the arbitration lives here.
final class HorizontalDragRecognizer: UIGestureRecognizer {
    var slop: CGFloat = 5
    var report: ((HorizontalDragGesture.Phase) -> Void)?

    private var tracked: UITouch?
    private var origin: CGPoint = .zero

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // Buttons drawn INSIDE the row (a failure card's Diagnose and Try
        // Again) have to keep taking their own taps, so this recognizer never
        // cancels or delays the touch it is watching.
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    /// A scroll view's pan may begin before this recognizer has decided
    /// anything; that must not end the horizontal drag before it starts.
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard tracked == nil, let touch = touches.first else { return }
        tracked = touch
        origin = touch.location(in: view)
        report?(.down)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = tracked, touches.contains(touch) else { return }
        let point = touch.location(in: view)
        let dx = point.x - origin.x, dy = point.y - origin.y

        switch state {
        case .possible:
            guard max(abs(dx), abs(dy)) >= slop else { return }
            guard abs(dx) > abs(dy) else { return fail() }  // the list's pan
            state = .began
            report?(.began(dx))
        case .began, .changed:
            state = .changed
            report?(.changed(dx))
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch = tracked, touches.contains(touch) else { return }
        switch state {
        case .possible:
            // A tap. Reported, then failed rather than recognized: a tap that
            // recognizes would prevent whatever else was still waiting on
            // this touch, and it has nothing to win by doing so.
            report?(.tapped)
            state = .failed
        case .began, .changed:
            state = .ended
            report?(.ended)
        default:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let touch = tracked, touches.contains(touch) else { return }
        report?(.cancelled)
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        tracked = nil
        origin = .zero
    }

    /// Hand the touch back: tell the row to drop whatever it was showing,
    /// then fail so the scroll view's pan is free.
    private func fail() {
        report?(.cancelled)
        state = .failed
    }
}
