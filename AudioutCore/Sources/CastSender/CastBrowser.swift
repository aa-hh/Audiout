// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Network

/// A Cast device seen on the local network.
public struct CastDeviceRecord: Equatable, Sendable {
    /// The receiver's stable id (`id` in the TXT record).
    public let id: String
    /// What the user named it (`fn`).
    public let friendlyName: String
    /// The hardware model (`md`), when the receiver advertises one.
    public let model: String?
    public let endpoint: NWEndpoint

    public init(id: String, friendlyName: String, model: String?, endpoint: NWEndpoint) {
        self.id = id
        self.friendlyName = friendlyName
        self.model = model
        self.endpoint = endpoint
    }

    /// Nil unless the TXT record carries both the id and the friendly name —
    /// without them there is nothing to address or to show.
    public static func parse(txt: NWTXTRecord, endpoint: NWEndpoint) -> CastDeviceRecord? {
        guard let id = txt["id"], let friendlyName = txt["fn"] else { return nil }
        return CastDeviceRecord(id: id, friendlyName: friendlyName, model: txt["md"], endpoint: endpoint)
    }
}

/// Browses `_googlecast._tcp` and reports the full device list on every change.
public final class CastBrowser: @unchecked Sendable {

    public var onUpdate: (([CastDeviceRecord]) -> Void)?

    private let queue = DispatchQueue(label: "CastBrowser")
    private var browser: NWBrowser?
    /// The pending recreate after a `.failed`, so `stop()` can cancel the
    /// backoff timer rather than let it revive a browser after teardown.
    private var pendingRecreate: DispatchWorkItem?
    /// Consecutive `.failed` count feeding ``nextDelay(afterAttempt:)``; back to
    /// 0 at the next `.ready`.
    private var failureAttempt = 0
    /// False outside `start()`…`stop()`, so a recreate that was already in
    /// flight when `stop()` ran cannot revive a browse nobody consumes.
    private var running = false

    /// Cap for ``nextDelay(afterAttempt:)``, seconds.
    static let maxBackoffSeconds: TimeInterval = 30

    public init() {}

    public func start() {
        queue.async { [self] in
            running = true
            makeBrowser()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            pendingRecreate?.cancel()
            pendingRecreate = nil
            failureAttempt = 0
            browser?.cancel()
            browser = nil
        }
    }

    /// Pure backoff schedule: 1s, 2s, 4s, … capped at ``maxBackoffSeconds``.
    /// `attempt` is 0-based (the consecutive `.failed`s seen before this one).
    static func nextDelay(afterAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 1 }
        return min(maxBackoffSeconds, pow(2.0, Double(attempt)))
    }

    /// On `queue`. `.failed` is a TERMINAL NWBrowser state — Network.framework
    /// never restarts it, and this browse now runs for the life of the app — so
    /// a failure cancels the browser and recreates it after a capped backoff,
    /// which resets once the replacement reaches `.ready`.
    private func makeBrowser() {
        pendingRecreate?.cancel()
        pendingRecreate = nil
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            // A `.failed` enqueued before `stop()`/`makeBrowser()` ran still
            // gets delivered after them; acting on it would revive a browse
            // with no consumer. Only the browser that is CURRENTLY ours counts.
            guard let self, let browser, browser === self.browser else { return }
            switch state {
            case .ready:
                self.failureAttempt = 0
            case .failed:
                self.scheduleRecreate()
            default:
                // `.waiting` self-recovers inside Network.framework.
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            // Same reason as the state handler: results enqueued before
            // `stop()`/`makeBrowser()` still arrive after them, and `onUpdate`
            // must never fire for a browser that is no longer ours.
            guard let self, let browser, browser === self.browser, self.running else { return }
            let devices = results.compactMap { result -> CastDeviceRecord? in
                guard case let .bonjour(txt) = result.metadata else { return nil }
                return CastDeviceRecord.parse(txt: txt, endpoint: result.endpoint)
            }
            self.onUpdate?(devices)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    /// On `queue` (the state handler is bound to it by `browser.start(queue:)`).
    private func scheduleRecreate() {
        guard running else { return }
        browser?.cancel()
        browser = nil

        let attempt = failureAttempt
        failureAttempt = attempt + 1

        pendingRecreate?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRecreate = nil
            self.makeBrowser()
        }
        pendingRecreate = item
        queue.asyncAfter(deadline: .now() + Self.nextDelay(afterAttempt: attempt), execute: item)
    }
}
