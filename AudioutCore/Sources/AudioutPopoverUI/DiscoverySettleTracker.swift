// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Decides when network discovery (Bonjour/AirPlay/Cast/BT) has QUIESCED: the
/// device set has stopped changing for a quiet window (~300 ms). The launch
/// splash holds until this reports "settled", so the settled frame is measured
/// and applied BEHIND the opaque cover and the user only ever sees one frame.
///
/// Pure decision, injectable scheduling: `schedule` is the one seam a test
/// drives instead of a real run loop (mirrors `SurfaceSplashView`'s timer
/// hooks). Each distinct device set (re)arms the quiet window; a window that
/// elapses with no change since it was armed settles exactly once. A stable or
/// empty fleet settles from `start()` alone, because nothing re-arms it.
@MainActor
final class DiscoverySettleTracker {

    /// No device-set change for this long ⇒ discovery has quiesced.
    static let defaultQuietWindow: TimeInterval = 0.3

    /// Fired once, when the device set has been quiet for the window.
    var onSettled: (() -> Void)?

    private let quietWindow: TimeInterval
    /// Schedule `fire` after `delay`. The default arms a real one-shot `Timer`;
    /// a test injects a seam that stores the closure and fires it on demand.
    private let schedule: (_ delay: TimeInterval, _ fire: @escaping () -> Void) -> Void

    private(set) var isSettled = false
    private var lastIDs: Set<String>?
    /// Bumped on every arm; a scheduled fire only settles if it is still the
    /// newest arm, so a superseded (real) timer that still fires is ignored.
    private var epoch = 0

    init(quietWindow: TimeInterval = DiscoverySettleTracker.defaultQuietWindow,
         schedule: @escaping (_ delay: TimeInterval, _ fire: @escaping () -> Void) -> Void = { delay, fire in
             Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                 MainActor.assumeIsolated { fire() }
             }
         }) {
        self.quietWindow = quietWindow
        self.schedule = schedule
    }

    /// Arm the quiet window before the first device arrives, so a fleet that
    /// never changes (empty, or fully-known at open) still settles.
    func start() {
        guard !isSettled, lastIDs == nil, epoch == 0 else { return }
        arm()
    }

    /// Feed the latest device-id set from the discovery stream.
    func note(deviceIDs: Set<String>) {
        guard !isSettled, deviceIDs != lastIDs else { return }
        lastIDs = deviceIDs
        arm()
    }

    private func arm() {
        epoch += 1
        let armed = epoch
        schedule(quietWindow) { [weak self] in
            guard let self, self.epoch == armed, !self.isSettled else { return }
            self.settle()
        }
    }

    private func settle() {
        guard !isSettled else { return }
        isSettled = true
        onSettled?()
    }

    // MARK: Test-support hooks

    /// Settle now, exactly as an elapsed quiet window would.
    func test_settleNow() { settle() }
}
