import Network
import XCTest
@testable import AudioutedCore

/// Drives ``NetworkConnectionDiagnostics`` purely through its injected seams —
/// no real network, filesystem, or clock — covering every row of the brief §4
/// decision table.
final class ConnectionDiagnosticsTests: XCTestCase {

    // MARK: Builders

    /// A diagnostics instance whose seams are all overridden. Any seam left `nil`
    /// gets a benign default (log absent, Bonjour present-with-endpoint so the
    /// probe runs, probe ready) so each test only has to state the seam it cares
    /// about.
    private func diagnostics(
        bonjour: (@Sendable (_ deviceName: String) async -> BonjourPresence)? = nil,
        tcpProbe: (@Sendable (_ endpoint: BonjourPresence.Endpoint) async -> TCPProbeResult)? = nil,
        logTail: (@Sendable () -> String?)? = nil
    ) -> NetworkConnectionDiagnostics {
        let endpoint = BonjourPresence.Endpoint(serviceName: "Kitchen", serviceType: "_airplay._tcp")
        return NetworkConnectionDiagnostics(
            bonjour: bonjour ?? { _ in BonjourPresence(isPresent: true, endpoint: endpoint) },
            tcpProbe: tcpProbe ?? { _ in .ready },
            logTail: logTail ?? { nil },
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    private func context(
        deviceName: String = "Kitchen",
        requiresAuth: Bool = false,
        priorCause: ConnectionFailure.Cause = .unknown
    ) -> DiagnosisContext {
        DiagnosisContext(
            deviceID: "out-1",
            deviceName: deviceName,
            requiresAuth: requiresAuth,
            priorCause: priorCause
        )
    }

    // MARK: Step 1 — auth flag wins

    func testAuthFlagWinsBeforeAnyProbe() async {
        // Even with a log line + present Bonjour + refused probe that would map
        // elsewhere, requiresAuth short-circuits to .authRequired with no detail.
        let diag = diagnostics(
            bonjour: { _ in .absent },
            tcpProbe: { _ in .refused },
            logTail: { "No response from Kitchen" }
        )
        let result = await diag.diagnose(context(requiresAuth: true))
        XCTAssertEqual(result.cause, .authRequired)
        XCTAssertNil(result.detail)
    }

    // MARK: Step 2 — engine-log patterns

    func testLogNoResponseMapsToNotResponding() async {
        let line = "[player] No response from Kitchen (giving up)"
        let diag = diagnostics(logTail: { line })
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .notResponding)
        XCTAssertEqual(result.detail, line)
    }

    func testLog403MapsToRefusedOrBusy() async {
        let line = "[raop] Kitchen returned status 403 Forbidden"
        let diag = diagnostics(logTail: { line })
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .refusedOrBusy)
        XCTAssertEqual(result.detail, line)
    }

    func testLogAuthPatternMapsToAuthRequired() async {
        let line = "[raop] Kitchen requires pairing before streaming"
        let diag = diagnostics(logTail: { line })
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .authRequired)
        XCTAssertEqual(result.detail, line)
    }

    func testLogPasswordPatternMapsToAuthRequired() async {
        let line = "[raop] Kitchen: password needed"
        let diag = diagnostics(logTail: { line })
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .authRequired)
    }

    /// "failed to activate" alone is inconclusive: it must NOT decide the cause,
    /// but the matched line still rides along as `detail` while probing continues.
    func testFailedToActivateAloneKeepsProbingButRetainsDetail() async {
        let line = "[player] failed to activate Kitchen"
        let diag = diagnostics(
            bonjour: { _ in .absent },  // step 3 decides → .vanished
            logTail: { line }
        )
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .vanished)
        XCTAssertEqual(result.detail, line, "the inconclusive log line still becomes detail")
    }

    func testLogScansNewestLineFirst() async {
        // Two matching lines; the newest (last) one should win.
        let tail = """
        [player] No response from Kitchen
        [raop] Kitchen returned status 403 Forbidden
        """
        let diag = diagnostics(logTail: { tail })
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .refusedOrBusy, "the 403 line is newer than the no-response line")
        XCTAssertTrue(result.detail?.contains("403") == true)
    }

    func testLogIgnoresLinesNotNamingTheDevice() async {
        // A 403 for a different device must not be attributed to Kitchen.
        let tail = """
        [raop] Bedroom returned status 403 Forbidden
        [player] enabling Kitchen
        """
        let diag = diagnostics(
            bonjour: { _ in .absent },
            logTail: { tail }
        )
        let result = await diag.diagnose(context())
        // The only Kitchen line ("enabling") is inconclusive → falls through to
        // Bonjour, and it becomes the detail.
        XCTAssertEqual(result.cause, .vanished)
        XCTAssertEqual(result.detail, "[player] enabling Kitchen")
    }

    func testDeviceNameMatchIsCaseInsensitive() async {
        let line = "[player] No response from KITCHEN"
        let diag = diagnostics(logTail: { line })
        let result = await diag.diagnose(context(deviceName: "kitchen"))
        XCTAssertEqual(result.cause, .notResponding)
    }

    // MARK: Step 3 — Bonjour presence

    func testAbsentFromBonjourMapsToVanished() async {
        let diag = diagnostics(bonjour: { _ in .absent })
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .vanished)
        XCTAssertNil(result.detail)
    }

    func testVanishedKeepsInconclusiveLogDetail() async {
        let line = "[player] failed to activate Kitchen"
        let diag = diagnostics(
            bonjour: { _ in .absent },
            logTail: { line }
        )
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .vanished)
        XCTAssertEqual(result.detail, line)
    }

    // MARK: Step 4 — TCP probe classification

    func testProbeReadyMapsToNotResponding() async {
        let diag = diagnostics(tcpProbe: { _ in .ready })
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .notResponding)
    }

    func testProbeRefusedMapsToRefusedOrBusy() async {
        let diag = diagnostics(tcpProbe: { _ in .refused })
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .refusedOrBusy)
    }

    func testProbeTimedOutMapsToNotResponding() async {
        let diag = diagnostics(tcpProbe: { _ in .timedOut })
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .notResponding)
    }

    func testProbeReceivesTheMatchedEndpoint() async {
        // The endpoint that Bonjour resolved must be the one handed to the probe.
        let resolved = BonjourPresence.Endpoint(serviceName: "AABBCC@Kitchen", serviceType: "_raop._tcp")
        let seen = EndpointBox()
        let diag = diagnostics(
            bonjour: { _ in BonjourPresence(isPresent: true, endpoint: resolved) },
            tcpProbe: { endpoint in
                await seen.set(endpoint)
                return .ready
            }
        )
        _ = await diag.diagnose(context())
        let captured = await seen.value
        XCTAssertEqual(captured?.serviceName, "AABBCC@Kitchen")
        XCTAssertEqual(captured?.serviceType, "_raop._tcp")
    }

    func testPresentWithoutEndpointFallsThroughToPriorCause() async {
        // Present but no resolvable endpoint → skip the probe → step 5.
        let diag = diagnostics(bonjour: { _ in BonjourPresence(isPresent: true, endpoint: nil) })
        let result = await diag.diagnose(context(priorCause: .droppedMidStream))
        XCTAssertEqual(result.cause, .droppedMidStream)
    }

    // MARK: Step 5 — fallback to priorCause

    func testNothingConclusiveFallsBackToPriorCause() async {
        // Present but no endpoint → the probe is skipped and step 5 carries the
        // backend's prior guess (.timedOut here) through unchanged.
        let diag = diagnostics(bonjour: { _ in BonjourPresence(isPresent: true, endpoint: nil) })
        let result = await diag.diagnose(context(priorCause: .timedOut))
        XCTAssertEqual(result.cause, .timedOut)
    }

    func testFallbackKeepsInconclusiveLogDetail() async {
        let line = "[player] failed to activate Kitchen"
        let diag = diagnostics(
            bonjour: { _ in BonjourPresence(isPresent: true, endpoint: nil) },
            logTail: { line }
        )
        let result = await diag.diagnose(context(priorCause: .unknown))
        XCTAssertEqual(result.cause, .unknown)
        XCTAssertEqual(result.detail, line, "the log line survives all the way to the fallback")
    }

    func testFallbackUsesUnknownWhenPriorCauseIsUnknown() async {
        let diag = diagnostics(bonjour: { _ in BonjourPresence(isPresent: true, endpoint: nil) })
        let result = await diag.diagnose(context(priorCause: .unknown))
        XCTAssertEqual(result.cause, .unknown)
    }

    // MARK: Default TCP probe — NWConnection state classification
    //
    // The real probe closure never runs in these tests (it's behind the
    // `tcpProbe` seam), so its state→verdict matrix is pinned directly via
    // `probeVerdict(for:)`. Per Apple's `NWConnection` docs `.waiting` is
    // transient — only an active refusal may decide there; everything else
    // must leave the 3 s bound in charge.

    func testProbeVerdictReadyIsReady() {
        XCTAssertEqual(NetworkConnectionDiagnostics.probeVerdict(for: .ready), .ready)
    }

    func testProbeVerdictWaitingRefusedIsRefused() {
        XCTAssertEqual(
            NetworkConnectionDiagnostics.probeVerdict(for: .waiting(.posix(.ECONNREFUSED))),
            .refused)
    }

    func testProbeVerdictTransientWaitingIsNotTerminal() {
        // A momentarily-unrouted host (path change) can still reach .ready
        // within the bound — the first .waiting must NOT resolve the probe.
        XCTAssertNil(NetworkConnectionDiagnostics.probeVerdict(for: .waiting(.posix(.EHOSTUNREACH))))
        XCTAssertNil(NetworkConnectionDiagnostics.probeVerdict(for: .waiting(.posix(.ENETDOWN))))
    }

    func testProbeVerdictFailedRefusedIsRefused() {
        XCTAssertEqual(
            NetworkConnectionDiagnostics.probeVerdict(for: .failed(.posix(.ECONNREFUSED))),
            .refused)
    }

    func testProbeVerdictOtherHardFailureIsTimedOut() {
        XCTAssertEqual(
            NetworkConnectionDiagnostics.probeVerdict(for: .failed(.posix(.ETIMEDOUT))),
            .timedOut)
    }

    func testProbeVerdictNonTerminalStatesKeepWaiting() {
        XCTAssertNil(NetworkConnectionDiagnostics.probeVerdict(for: .setup))
        XCTAssertNil(NetworkConnectionDiagnostics.probeVerdict(for: .preparing))
    }

    // MARK: Never-throws / robustness

    func testNilLogTailIsSkippedGracefully() async {
        // No log available → straight to Bonjour → probe.
        let diag = diagnostics(logTail: { nil })
        let result = await diag.diagnose(context())
        XCTAssertEqual(result.cause, .notResponding)  // present + probe ready
        XCTAssertNil(result.detail)
    }
}

// MARK: - Test helpers

/// Actor box to capture the endpoint passed to the probe across the async
/// boundary without data races.
private actor EndpointBox {
    private(set) var value: BonjourPresence.Endpoint?
    func set(_ endpoint: BonjourPresence.Endpoint) { value = endpoint }
}
