import Foundation
import Testing
@testable import AudiouterCore

/// BT-CONNECT: ``BTConnectionManager``'s attempt pipeline — TCC gate first
/// (never a real IOBluetooth touch here: every seam is injected), the hard
/// timeout over `openConnection`, the endpoint poll, the one-shot ~5 s
/// fallback nudge, and the address derivation. Timing knobs are shrunk to
/// tens of milliseconds so nothing costs wall-clock seconds.
@Suite final class BTConnectionManagerTests: IsolatedSuite {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        func record(_ event: String) { lock.withLock { _events.append(event) } }
        var events: [String] { lock.withLock { _events } }
    }

    private func makeManager(
        authorized: Bool = true,
        openReturn: Int32 = 0,
        openDelay: TimeInterval = 0,
        endpointAppears: Bool = true,
        connectTimeout: TimeInterval = 0.5,
        fallbackDelay: TimeInterval = 0.05,
        appearWindow: TimeInterval = 0.2,
        recorder: Recorder = Recorder()
    ) -> (BTConnectionManager, Recorder) {
        let manager = BTConnectionManager(
            isBluetoothAuthorized: { authorized },
            openConnection: { address in
                recorder.record("open:\(address)")
                if openDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(openDelay * 1_000_000_000))
                }
                return openReturn
            },
            closeConnection: { address in recorder.record("close:\(address)") },
            endpointExists: { address in
                recorder.record("endpoint:\(address)")
                return endpointAppears
            },
            connectTimeout: connectTimeout,
            fallbackSuggestionDelay: fallbackDelay,
            endpointAppearWindow: appearWindow,
            endpointPollInterval: 0.01)
        return (manager, recorder)
    }

    // MARK: TCC gate

    /// Ungranted: the outcome is `.unauthorized` and NO seam ran — the gate
    /// must sit before any IOBluetooth-shaped call (an ungranted touch kills
    /// the process in production).
    @Test func unauthorizedConnectNeverTouchesTheSeams() async {
        let (manager, recorder) = makeManager(authorized: false)
        let outcome = await manager.connect(address: "C4-38-75-0E-BF-4A")
        #expect(outcome == .unauthorized)
        #expect(recorder.events.isEmpty)
    }

    @Test func unauthorizedDisconnectNeverTouchesTheSeams() {
        let (manager, recorder) = makeManager(authorized: false)
        manager.disconnect(address: "C4-38-75-0E-BF-4A")
        #expect(recorder.events.isEmpty)
    }

    // MARK: Outcomes

    @Test func openSuccessThenEndpointIsConnected() async {
        let (manager, recorder) = makeManager()
        let outcome = await manager.connect(address: "C4-38-75-0E-BF-4A")
        #expect(outcome == .connected)
        #expect(recorder.events.first == "open:C4-38-75-0E-BF-4A")
        #expect(recorder.events.contains("endpoint:C4-38-75-0E-BF-4A"))
    }

    /// A nonzero IOReturn fails immediately with the code as the reason and
    /// never polls for an endpoint.
    @Test func openFailureCarriesTheReturnCodeAndSkipsThePoll() async {
        let (manager, recorder) = makeManager(openReturn: Int32(bitPattern: 0xE00002D6))
        let outcome = await manager.connect(address: "C4-38-75-0E-BF-4A")
        guard case .failed(_, let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason == "0xe00002d6", "the spike's powered-off code, verbatim")
        #expect(!recorder.events.contains { $0.hasPrefix("endpoint:") })
    }

    /// Baseband up but no Core Audio endpoint inside the window: failed with
    /// the distinct reason (the A2DP-without-audio case the plan flags).
    @Test func missingEndpointFailsAfterTheAppearWindow() async {
        let (manager, _) = makeManager(endpointAppears: false)
        let outcome = await manager.connect(address: "C4-38-75-0E-BF-4A")
        guard case .failed(_, let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason == "no_audio_endpoint")
    }

    /// The hard ceiling: an open that outlives `connectTimeout` resolves
    /// `.failed("timeout")` at the ceiling, not at the open's own pace.
    @Test func hangingOpenHitsTheHardTimeout() async {
        // openDelay is deliberately huge: the ONLY way the test finishes well
        // under it is the timeout race winning. No tight wall-clock margin —
        // scheduler latency under machine load once pushed a 0.1s ceiling past
        // 12s of elapsed and flaked a `< 5` assertion (the roadmap-023 class).
        let (manager, _) = makeManager(openDelay: 60, connectTimeout: 0.1)
        let began = Date()
        let outcome = await manager.connect(address: "C4-38-75-0E-BF-4A")
        let elapsed = Date().timeIntervalSince(began)
        guard case .failed(let reportedElapsed, let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason == "timeout")
        #expect(elapsed < 60, "must resolve at the ceiling, never at the open's own pace")
        #expect(reportedElapsed >= 0.1)
    }

    // MARK: Fallback nudge

    /// A slow attempt fires `onFallbackSuggested` once, mid-flight, while the
    /// attempt continues to its own outcome.
    @Test func slowAttemptSuggestsTheFallbackOnceMidFlight() async {
        let (manager, recorder) = makeManager(openDelay: 0.15, fallbackDelay: 0.05)
        manager.onFallbackSuggested = { address in recorder.record("fallback:\(address)") }
        let outcome = await manager.connect(address: "C4-38-75-0E-BF-4A")
        #expect(outcome == .connected, "the attempt still ran to completion")
        let fallbacks = recorder.events.filter { $0.hasPrefix("fallback:") }
        #expect(fallbacks == ["fallback:C4-38-75-0E-BF-4A"])
        let order = recorder.events
        #expect(order.firstIndex(of: "fallback:C4-38-75-0E-BF-4A")! < order.firstIndex(of: "endpoint:C4-38-75-0E-BF-4A")!,
                "the nudge fired while the attempt was still in flight")
    }

    /// A fast attempt never bothers the user with the fallback.
    @Test func fastAttemptNeverSuggestsTheFallback() async {
        let (manager, recorder) = makeManager(fallbackDelay: 0.1)
        manager.onFallbackSuggested = { address in recorder.record("fallback:\(address)") }
        _ = await manager.connect(address: "C4-38-75-0E-BF-4A")
        try? await Task.sleep(nanoseconds: 200_000_000)   // past the (cancelled) delay
        #expect(!recorder.events.contains { $0.hasPrefix("fallback:") })
    }

    // MARK: Disconnect

    @Test func disconnectCallsClose() {
        let (manager, recorder) = makeManager()
        manager.disconnect(address: "C4-38-75-0E-BF-4A")
        #expect(recorder.events == ["close:C4-38-75-0E-BF-4A"])
    }

    // MARK: Address derivation

    /// `Device.id` (Core Audio UID) → the bare MAC IOBluetooth wants, across
    /// the observed formats.
    @Test func macAddressFromUID() {
        #expect(BTConnectionManager.macAddress(fromUID: "C4-38-75-0E-BF-4A:output") == "C4-38-75-0E-BF-4A")
        #expect(BTConnectionManager.macAddress(fromUID: "c4:38:75:0e:bf:4a") == "C4-38-75-0E-BF-4A")
        #expect(BTConnectionManager.macAddress(fromUID: "not-a-mac") == nil)
        #expect(BTConnectionManager.macAddress(fromUID: "BuiltInSpeakerDevice_UID") == nil)
    }

    /// The Decision-3 fallback deep-link: the Bluetooth pane, not a Privacy
    /// anchor.
    @Test func bluetoothSettingsPaneURL() {
        #expect(SystemSettingsPane.bluetooth.url.absoluteString ==
                "x-apple.systempreferences:com.apple.BluetoothSettings")
    }
}
