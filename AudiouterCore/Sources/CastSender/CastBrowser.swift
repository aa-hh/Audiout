// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Network

/// A Cast device seen on the local network.
public struct CastDeviceRecord: Equatable {
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

    public init() {}

    public func start() {
        queue.async { [self] in
            browser?.cancel()
            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: params)
            // razor: no `.failed` recreate/backoff here — this browser runs for
            // the seconds a spike run needs, not the life of the app.
            // `NetworkFrameworkBrowser` (NativeDiscovery.swift) has the
            // recreate-with-backoff pattern if a long-lived browse ever needs it.
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                let devices = results.compactMap { result -> CastDeviceRecord? in
                    guard case let .bonjour(txt) = result.metadata else { return nil }
                    return CastDeviceRecord.parse(txt: txt, endpoint: result.endpoint)
                }
                self.onUpdate?(devices)
            }
            browser.start(queue: queue)
            self.browser = browser
        }
    }

    public func stop() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
        }
    }
}
