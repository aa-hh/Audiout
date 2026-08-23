import Testing
@testable import AudioutCore

@Suite struct ConnectionStateTests {

    private let allCauses: [ConnectionFailure.Cause] = [
        .notResponding, .vanished, .refusedOrBusy, .authRequired,
        .droppedMidStream, .timedOut, .unknown,
    ]

    // MARK: Copy table

    @Test func everyCauseHasNonEmptyHeadlineAndSuggestion() {
        for cause in allCauses {
            let failure = ConnectionFailure(cause: cause)
            #expect(!failure.headline.isEmpty, "\(cause) headline")
            #expect(!failure.suggestion.isEmpty, "\(cause) suggestion")
        }
    }

    @Test func headlinesAreSentenceCaseWithNoTerminalPeriod() {
        for cause in allCauses {
            let headline = ConnectionFailure(cause: cause).headline
            let first = headline.first!
            #expect(first.isUppercase, "\(cause) headline should start uppercase: \(headline)")
            #expect(!headline.hasSuffix("."), "\(cause) headline should not end with a period: \(headline)")
        }
    }

    @Test func suggestionsAreSentenceCaseAndEndWithPeriod() {
        for cause in allCauses {
            let suggestion = ConnectionFailure(cause: cause).suggestion
            let first = suggestion.first!
            #expect(first.isUppercase, "\(cause) suggestion should start uppercase: \(suggestion)")
            #expect(suggestion.hasSuffix("."), "\(cause) suggestion should end with a period: \(suggestion)")
        }
    }

    // MARK: Verbatim copy (guards against accidental rewording of approved copy)

    @Test func verbatimCopyTable() {
        let expected: [ConnectionFailure.Cause: (headline: String, suggestion: String)] = [
            .notResponding: (
                "Didn't respond",
                "The speaker is visible on the network but isn't answering AirPlay requests — it may be stuck or held by another app. Power-cycle it, then try again."
            ),
            .vanished: (
                "Not on the network",
                "The speaker is no longer visible on the network. Check that it's powered on and on the same Wi-Fi, then try again."
            ),
            .refusedOrBusy: (
                "Connection refused",
                "The speaker refused the connection — another device may hold an exclusive session. Stop playback from other apps or restart the speaker, then try again."
            ),
            .authRequired: (
                "Password required",
                "This speaker requires a password or pairing. If it's a Mac, set AirPlay Receiver to allow “Anyone on the same network” in its System Settings, then try again. Entering a password here isn't supported yet."
            ),
            .droppedMidStream: (
                "Connection dropped",
                "The speaker dropped the stream and reconnecting failed. Check the speaker, then try again."
            ),
            .timedOut: (
                "Took too long",
                "The connection attempt didn't complete. The speaker or network may be busy — try again."
            ),
            .unknown: (
                "Couldn't connect",
                "The connection failed for an unknown reason. Try again, or check the speaker."
            ),
        ]
        for (cause, copy) in expected {
            let failure = ConnectionFailure(cause: cause)
            #expect(failure.headline == copy.headline, "\(cause) headline")
            #expect(failure.suggestion == copy.suggestion, "\(cause) suggestion")
        }
    }

    // MARK: Equatable behavior

    @Test func connectionFailureEqualityIsSensitiveToDetail() {
        let noDetail = ConnectionFailure(cause: .timedOut)
        let withDetail = ConnectionFailure(cause: .timedOut, detail: "engine log line")
        let sameDetail = ConnectionFailure(cause: .timedOut, detail: "engine log line")
        #expect(noDetail != withDetail)
        #expect(withDetail == sameDetail)
    }

    @Test func connectionFailureEqualityIsSensitiveToCause() {
        let a = ConnectionFailure(cause: .vanished, detail: "same")
        let b = ConnectionFailure(cause: .notResponding, detail: "same")
        #expect(a != b)
    }

    @Test func connectionStateEqualityComparesAssociatedFailure() {
        #expect(ConnectionState.off == .off)
        #expect(ConnectionState.connecting == .connecting)
        #expect(ConnectionState.connecting != .connected)
        #expect(
            ConnectionState.failed(ConnectionFailure(cause: .unknown)) ==
            .failed(ConnectionFailure(cause: .unknown))
        )
        #expect(
            ConnectionState.failed(ConnectionFailure(cause: .unknown)) !=
            .failed(ConnectionFailure(cause: .unknown, detail: "extra"))
        )
        #expect(
            ConnectionState.failed(ConnectionFailure(cause: .vanished)) !=
            .failed(ConnectionFailure(cause: .timedOut))
        )
    }

    // MARK: Device integration

    @Test func deviceDefaultsToOff() {
        let device = Device(id: "a", name: "A", kind: .generic)
        #expect(device.connectionState == .off)
    }

    @Test func deviceEqualityIsSensitiveToConnectionState() {
        let base = Device(id: "a", name: "A", kind: .generic)
        var connecting = base
        connecting.connectionState = .connecting
        #expect(base != connecting)

        var failedA = base
        failedA.connectionState = .failed(ConnectionFailure(cause: .vanished))
        var failedB = base
        failedB.connectionState = .failed(ConnectionFailure(cause: .timedOut))
        #expect(failedA != failedB)

        var failedC = base
        failedC.connectionState = .failed(ConnectionFailure(cause: .vanished))
        #expect(failedA == failedC)
    }

    @Test func deviceExplicitConnectionStateInit() {
        let device = Device(id: "a", name: "A", kind: .generic, connectionState: .reconnecting)
        #expect(device.connectionState == .reconnecting)
    }
}
