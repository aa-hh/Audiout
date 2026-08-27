// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutSharedUI

/// `FoldAnimator`'s Reduce Motion contract.
///
/// Reduce Motion is gated inside the animator itself, not only at the call
/// sites: `animate` settles every in-flight fold to its terminal state
/// synchronously, in the caller's own turn. That is the same contract each
/// caller's `animated: false` branch already has, so a fold under Reduce Motion
/// never starts a clock at all.
///
/// `FoldAnimator.shared` is a process-wide singleton, so both tests restore the
/// override and settle any leftover tween on the way out.
@MainActor
@Suite final class FoldAnimatorTests: IsolatedSuite {

    @Test func reduceMotionSettlesTheFoldSynchronously() {
        defer {
            FoldAnimator.shared.test_reduceMotionOverride = nil
            FoldAnimator.shared.test_settleNow()
        }
        FoldAnimator.shared.test_reduceMotionOverride = true

        let view = NSView()
        let clip = view.heightAnchor.constraint(equalToConstant: 10)
        var completed = false

        FoldAnimator.shared.animate(clip, to: 120, follower: nil) { completed = true }

        #expect(clip.constant == 120)
        #expect(completed)
        #expect(FoldAnimator.shared.isFolding == false)
    }

    @Test func withoutReduceMotionTheFoldTravels() {
        defer {
            FoldAnimator.shared.test_reduceMotionOverride = nil
            FoldAnimator.shared.test_settleNow()
        }
        FoldAnimator.shared.test_reduceMotionOverride = false

        let view = NSView()
        let clip = view.heightAnchor.constraint(equalToConstant: 10)
        var completed = false

        FoldAnimator.shared.animate(clip, to: 120, follower: nil) { completed = true }

        // Tick 0 of an eased travel: sampled, but nowhere near the target yet.
        #expect(clip.constant < 120)
        #expect(FoldAnimator.shared.isFolding)
        #expect(completed == false)

        FoldAnimator.shared.test_settleNow()

        #expect(clip.constant == 120)
        #expect(completed)
    }
}
