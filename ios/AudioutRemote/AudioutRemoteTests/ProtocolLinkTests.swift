// Copyright (c) 2026 ahh. All rights reserved.

import Testing
import Foundation
@testable import AudioutProtocol

/// Proves the local `AudioutProtocol` package dependency actually links on
/// iOS (T10) — everything downstream (T11+) depends on this seam existing.
@Suite("Protocol package link")
struct ProtocolLinkTests {
    @Test("CompanionMessage round-trips through the wire envelope")
    func roundTripsHello() throws {
        let original = CompanionMessage.hello(clientID: UUID().uuidString, clientName: "iPhone", protoVersion: CompanionProto.version)
        let envelope = CompanionEnvelope(message: original)

        let data = try envelope.encoded()
        let decoded = try CompanionEnvelope.decode(data)

        #expect(decoded.message == original)
        #expect(decoded.v == CompanionProto.version)
    }
}
