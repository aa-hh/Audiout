// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import Foundation
import Network
import Testing
@testable import CastSender

/// TXT-record parsing for `_googlecast._tcp` (roadmap 006 Phase 0). Pure — the
/// browse itself needs a real device on the network, but the record shape a
/// device advertises is exactly this.
@Suite struct CastBrowserTests {

    private let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 8009)

    private func txtRecord(_ pairs: [String: String]) -> NWTXTRecord {
        var txt = NWTXTRecord()
        for (key, value) in pairs { txt[key] = value }
        return txt
    }

    @Test func parsesAFullRecord() {
        let record = CastDeviceRecord.parse(
            txt: txtRecord(["id": "deadbeef", "fn": "Kitchen speaker", "md": "Chromecast Audio"]),
            endpoint: endpoint
        )
        #expect(record == CastDeviceRecord(
            id: "deadbeef",
            friendlyName: "Kitchen speaker",
            model: "Chromecast Audio",
            endpoint: endpoint
        ))
    }

    @Test func rejectsARecordWithoutAnID() {
        #expect(CastDeviceRecord.parse(txt: txtRecord(["fn": "Kitchen speaker"]), endpoint: endpoint) == nil)
    }

    @Test func toleratesAMissingModel() {
        let record = CastDeviceRecord.parse(txt: txtRecord(["id": "deadbeef", "fn": "Kitchen"]), endpoint: endpoint)
        #expect(record?.model == nil)
        #expect(record?.friendlyName == "Kitchen")
    }

    /// The `.failed` recovery's one testable piece without a live NWBrowser —
    /// same shape as `NetworkFrameworkBrowser`'s own backoff test.
    @Test func backoffDoublesAndCaps() {
        #expect(CastBrowser.nextDelay(afterAttempt: 0) == 1)
        #expect(CastBrowser.nextDelay(afterAttempt: 1) == 2)
        #expect(CastBrowser.nextDelay(afterAttempt: 2) == 4)
        #expect(CastBrowser.nextDelay(afterAttempt: 5) == 30)
        #expect(CastBrowser.nextDelay(afterAttempt: 20) == 30)
    }
}
