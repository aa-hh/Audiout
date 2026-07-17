import XCTest
@testable import AirPlayControllerCore

final class ConnectionStateTests: XCTestCase {

    private let allCauses: [ConnectionFailure.Cause] = [
        .notResponding, .vanished, .refusedOrBusy, .authRequired,
        .droppedMidStream, .timedOut, .unknown,
    ]

    // MARK: Copy table

    func testEveryCauseHasNonEmptyHeadlineAndSuggestion() {
        for cause in allCauses {
            let failure = ConnectionFailure(cause: cause)
            XCTAssertFalse(failure.headline.isEmpty, "\(cause) headline")
            XCTAssertFalse(failure.suggestion.isEmpty, "\(cause) suggestion")
        }
    }

    func testHeadlinesAreSentenceCaseWithNoTerminalPeriod() {
        for cause in allCauses {
            let headline = ConnectionFailure(cause: cause).headline
            let first = headline.first!
            XCTAssertTrue(first.isUppercase, "\(cause) headline should start uppercase: \(headline)")
            XCTAssertFalse(headline.hasSuffix("."), "\(cause) headline should not end with a period: \(headline)")
        }
    }

    func testSuggestionsAreSentenceCaseAndEndWithPeriod() {
        for cause in allCauses {
            let suggestion = ConnectionFailure(cause: cause).suggestion
            let first = suggestion.first!
            XCTAssertTrue(first.isUppercase, "\(cause) suggestion should start uppercase: \(suggestion)")
            XCTAssertTrue(suggestion.hasSuffix("."), "\(cause) suggestion should end with a period: \(suggestion)")
        }
    }

    // MARK: Verbatim copy (guards against accidental rewording of approved copy)

    func testVerbatimCopyTable() {
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
                "This speaker requires a password or pairing, which isn't supported yet."
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
            XCTAssertEqual(failure.headline, copy.headline, "\(cause) headline")
            XCTAssertEqual(failure.suggestion, copy.suggestion, "\(cause) suggestion")
        }
    }

    // MARK: Equatable behavior

    func testConnectionFailureEqualityIsSensitiveToDetail() {
        let noDetail = ConnectionFailure(cause: .timedOut)
        let withDetail = ConnectionFailure(cause: .timedOut, detail: "engine log line")
        let sameDetail = ConnectionFailure(cause: .timedOut, detail: "engine log line")
        XCTAssertNotEqual(noDetail, withDetail)
        XCTAssertEqual(withDetail, sameDetail)
    }

    func testConnectionFailureEqualityIsSensitiveToCause() {
        let a = ConnectionFailure(cause: .vanished, detail: "same")
        let b = ConnectionFailure(cause: .notResponding, detail: "same")
        XCTAssertNotEqual(a, b)
    }

    func testConnectionStateEqualityComparesAssociatedFailure() {
        XCTAssertEqual(ConnectionState.off, .off)
        XCTAssertEqual(ConnectionState.connecting, .connecting)
        XCTAssertNotEqual(ConnectionState.connecting, .connected)
        XCTAssertEqual(
            ConnectionState.failed(ConnectionFailure(cause: .unknown)),
            .failed(ConnectionFailure(cause: .unknown))
        )
        XCTAssertNotEqual(
            ConnectionState.failed(ConnectionFailure(cause: .unknown)),
            .failed(ConnectionFailure(cause: .unknown, detail: "extra"))
        )
        XCTAssertNotEqual(
            ConnectionState.failed(ConnectionFailure(cause: .vanished)),
            .failed(ConnectionFailure(cause: .timedOut))
        )
    }

    // MARK: Device integration

    func testDeviceDefaultsToOff() {
        let device = Device(id: "a", name: "A", kind: .generic)
        XCTAssertEqual(device.connectionState, .off)
    }

    func testDeviceEqualityIsSensitiveToConnectionState() {
        let base = Device(id: "a", name: "A", kind: .generic)
        var connecting = base
        connecting.connectionState = .connecting
        XCTAssertNotEqual(base, connecting)

        var failedA = base
        failedA.connectionState = .failed(ConnectionFailure(cause: .vanished))
        var failedB = base
        failedB.connectionState = .failed(ConnectionFailure(cause: .timedOut))
        XCTAssertNotEqual(failedA, failedB)

        var failedC = base
        failedC.connectionState = .failed(ConnectionFailure(cause: .vanished))
        XCTAssertEqual(failedA, failedC)
    }

    func testDeviceExplicitConnectionStateInit() {
        let device = Device(id: "a", name: "A", kind: .generic, connectionState: .reconnecting)
        XCTAssertEqual(device.connectionState, .reconnecting)
    }
}
