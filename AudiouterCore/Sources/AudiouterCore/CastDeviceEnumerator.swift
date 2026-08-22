// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import CastSender
import Foundation

/// The seam `NativeBackend` ingests Cast discovery through, so its tests never
/// open a Bonjour browser.
protocol CastDeviceEnumerating: AnyObject, Sendable {
    var onSnapshot: (@Sendable ([CastDeviceRecord]) -> Void)? { get set }
    func start()
    func stop()
}

/// Browses `_googlecast._tcp` and hands the backend the WHOLE list on every
/// change — same merged-list contract as `BTDeviceEnumerator`, so an id absent
/// from a snapshot means "not on the network right now", not "deleted".
///
/// A Cast group (several receivers the user grouped in the Google Home app)
/// advertises as ONE virtual device with its own id, so it arrives here as a
/// single row and is driven like any other receiver.
///
/// The browse is silently blocked unless `_googlecast._tcp` is listed in the
/// bundle's `NSBonjourServices` (`scripts/make-app.sh`) — the same trap
/// `LocalNetworkPrimer`'s type has.
final class CastDeviceEnumerator: CastDeviceEnumerating, @unchecked Sendable {

    var onSnapshot: (@Sendable ([CastDeviceRecord]) -> Void)? {
        get { lock.withLock { _onSnapshot } }
        set { lock.withLock { _onSnapshot = newValue } }
    }

    private let lock = NSLock()
    private var _onSnapshot: (@Sendable ([CastDeviceRecord]) -> Void)?
    private let browser = CastBrowser()

    init() {}

    func start() {
        browser.onUpdate = { [weak self] records in
            guard let self else { return }
            self.onSnapshot?(records)
        }
        browser.start()
    }

    func stop() {
        browser.stop()
        browser.onUpdate = nil
    }
}
