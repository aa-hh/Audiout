import Foundation
import Testing
@testable import AudioutCore

/// BT-CONNECT: ``BTConnectionManager``'s attempt pipeline — TCC gate first
/// (never a real IOBluetooth touch here: every seam is injected), the hard
/// timeout over `openConnection`, the endpoint poll, the one-shot ~5 s
/// fallback nudge, and the address derivation. Every timer, and the fake
/// open's own delay, waits on `clock` until the test moves it.
@Suite final class BTConnectionManagerTests: IsolatedSuite {

    private let clock = ManualDelayClock()

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
        connectTimeout: TimeInterval = 20,
        fallbackDelay: TimeInterval = 5,
        appearWindow: TimeInterval = 5,
        recorder: Recorder = Recorder()
    ) -> (BTConnectionManager, Recorder) {
        let clock = self.clock
        let manager = BTConnectionManager(
            isBluetoothAuthorized: { authorized },
            openConnection: { address in
                recorder.record("open:\(address)")
                if openDelay > 0 {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        clock.clock(openDelay, .global(), DispatchWorkItem { continuation.resume() })
                    }
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
            // Equal to the appear window: one wait, then the window is spent.
            endpointPollInterval: 5,
            delayClock: clock.clock,
            uptimeClock: clock.uptime)
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
        let attempt = Task { await manager.connect(address: "C4-38-75-0E-BF-4A") }
        // The fallback nudge, the hard timeout and the poll's first wait.
        await SuiteWait.until("the endpoint poll waits on the clock") { self.clock.pendingCount == 3 }
        clock.advance(by: 5)   // the appear window runs out
        let outcome = await attempt.value
        guard case .failed(_, let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason == "no_audio_endpoint")
    }

    /// The hard ceiling: an open that outlives `connectTimeout` resolves
    /// `.failed("timeout")` at the ceiling, not at the open's own pace.
    @Test func hangingOpenHitsTheHardTimeout() async {
        // The open waits 60 s on the same clock as the 20 s ceiling, so only
        // the timeout winning the race can resolve the attempt at 20.
        let (manager, _) = makeManager(openDelay: 60, connectTimeout: 20)
        let attempt = Task { await manager.connect(address: "C4-38-75-0E-BF-4A") }
        // The fallback nudge, the hard timeout and the open's own delay.
        await SuiteWait.until("the attempt's timers and the open all wait on the clock") {
            self.clock.pendingCount == 3
        }
        clock.advance(by: 20)
        let outcome = await attempt.value
        clock.fireAll()   // lets the abandoned open return, so its task ends
        guard case .failed(let reportedElapsed, let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason == "timeout")
        #expect(reportedElapsed == 20, "must resolve at the ceiling, never at the open's own pace")
    }

    // MARK: Fallback nudge

    /// A slow attempt fires `onFallbackSuggested` once, mid-flight, while the
    /// attempt continues to its own outcome.
    @Test func slowAttemptSuggestsTheFallbackOnceMidFlight() async {
        let (manager, recorder) = makeManager(openDelay: 10, fallbackDelay: 5)
        manager.onFallbackSuggested = { address in recorder.record("fallback:\(address)") }
        let attempt = Task { await manager.connect(address: "C4-38-75-0E-BF-4A") }
        // The fallback nudge, the hard timeout and the open's own delay.
        await SuiteWait.until("the attempt's timers and the open all wait on the clock") {
            self.clock.pendingCount == 3
        }
        clock.advance(by: 5)   // the nudge's delay, with the open still in flight
        clock.advance(by: 5)   // the open returns
        let outcome = await attempt.value
        #expect(outcome == .connected, "the attempt still ran to completion")
        let fallbacks = recorder.events.filter { $0.hasPrefix("fallback:") }
        #expect(fallbacks == ["fallback:C4-38-75-0E-BF-4A"])
        let order = recorder.events
        #expect(order.firstIndex(of: "fallback:C4-38-75-0E-BF-4A")! < order.firstIndex(of: "endpoint:C4-38-75-0E-BF-4A")!,
                "the nudge fired while the attempt was still in flight")
    }

    /// A fast attempt never bothers the user with the fallback.
    @Test func fastAttemptNeverSuggestsTheFallback() async {
        let (manager, recorder) = makeManager()
        manager.onFallbackSuggested = { address in recorder.record("fallback:\(address)") }
        _ = await manager.connect(address: "C4-38-75-0E-BF-4A")
        clock.fireAll()   // the nudge's delay passes after the outcome resolved
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
