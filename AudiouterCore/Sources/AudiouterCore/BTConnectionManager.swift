// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (PLAN-UNIVERSAL-SYNC Decision 5): this file carries NO
// GPL SPDX header, unlike most siblings. It is a fresh Apple-only implementation
// (IOBluetooth + CoreBluetooth + Core Audio) written for this project — the
// throwaway `dev/bt-multi-spike` harness was read for its findings only
// (`dev/notes/bt-spike-findings-2026-08-07.md`), never copied. Do not add a GPL
// header to this file, and do not move GPL-derived code into it.

import CoreBluetooth
import Foundation
import IOBluetooth

// MARK: - Outcome

/// Terminal result of one ``BTConnectionManaging/connect(address:)`` attempt.
enum BTConnectOutcome: Equatable, Sendable {
    /// Baseband + A2DP are up AND the Core Audio output endpoint exists — the
    /// speaker can carry audio right now.
    case connected
    /// The attempt ended without a usable audio endpoint. `elapsed` feeds the
    /// stolen-vs-powered-off classification (BT-RECONNECT): live-measured
    /// 2026-08-07, a powered-off speaker holds the OS attempt ~15.4 s before
    /// failing (0xe00002d6, consistent across brands), while a speaker another
    /// host holds refuses fast.
    case failed(elapsed: TimeInterval, reason: String)
    /// Bluetooth TCC not granted — IOBluetooth was never touched (an ungranted
    /// touch KILLS the process; see ``BTDeviceEnumerator``'s class doc).
    case unauthorized
}

// MARK: - Seam

/// The slice of ``BTConnectionManager`` ``NativeBackend`` drives. A protocol
/// (same discipline as ``BTDeviceEnumerating``) so tests script outcomes with
/// no IOBluetooth, no HAL, and no Bluetooth TCC in the loop.
protocol BTConnectionManaging: AnyObject, Sendable {
    /// Fires on ANY IOBluetooth connect/disconnect edge once
    /// ``startObservingConnections()`` ran — wired to the enumerator's
    /// `refresh()` so a row's greyed/available state follows the baseband edge
    /// instead of waiting for the Core Audio device-list listener alone.
    var onConnectionsChanged: (@Sendable () -> Void)? { get set }
    /// Fires (at most once per attempt, with the attempt's address) when a
    /// connect has run ~5 s without resolving — the live UX number: the OS
    /// attempt continues toward its ~15–20 s horizon, but the UI should now
    /// offer the Bluetooth Settings deep-link fallback (Decision 3:
    /// auto-connect, then fall back).
    var onFallbackSuggested: (@Sendable (_ address: String) -> Void)? { get set }
    func connect(address: String) async -> BTConnectOutcome
    func disconnect(address: String)
    func startObservingConnections()
    func stopObservingConnections()
}

// MARK: - Manager

/// BT-CONNECT: programmatic connect/disconnect for already-PAIRED Bluetooth
/// speakers (pairing itself is Apple's, one Settings trip — plan §C).
/// `IOBluetoothDevice.openConnection()` restores baseband + A2DP and the Core
/// Audio endpoint follows ~0.6 s later (2.4–4.4 s total on powered devices,
/// live-verified on two brands); `closeConnection()` drops the endpoint in
/// 0.2–0.4 s.
///
/// TCC: every IOBluetooth touch sits behind `isBluetoothAuthorized()`
/// (`CBManager.authorization`, a prompt-free read) — ungranted, connect
/// resolves `.unauthorized` and disconnect/observe no-op, because an ungranted
/// IOBluetooth call kills the process outright (SIGABRT, no prompt). The grant
/// itself arrives via the bundled app's `NSBluetoothAlwaysUsageDescription`
/// prompt (`scripts/make-app.sh`).
final class BTConnectionManager: BTConnectionManaging, @unchecked Sendable {

    /// Hard ceiling over the whole attempt. The OS's own failure horizon is
    /// ~15.4 s (live-measured); the ceiling only catches a wedged stack.
    static let defaultConnectTimeout: TimeInterval = 20
    /// See ``BTConnectionManaging/onFallbackSuggested``.
    static let defaultFallbackSuggestionDelay: TimeInterval = 5
    /// How long after a successful baseband open the Core Audio endpoint gets
    /// to appear (live-measured ~0.6 s; generous margin).
    static let defaultEndpointAppearWindow: TimeInterval = 5
    static let defaultEndpointPollInterval: TimeInterval = 0.25

    var onConnectionsChanged: (@Sendable () -> Void)? {
        get { lock.withLock { _onConnectionsChanged } }
        set { lock.withLock { _onConnectionsChanged = newValue } }
    }
    var onFallbackSuggested: (@Sendable (_ address: String) -> Void)? {
        get { lock.withLock { _onFallbackSuggested } }
        set { lock.withLock { _onFallbackSuggested = newValue } }
    }

    private let lock = NSLock()
    private var _onConnectionsChanged: (@Sendable () -> Void)?
    private var _onFallbackSuggested: (@Sendable (String) -> Void)?
    /// `true` from the first authorized ``startObservingConnections()`` until
    /// ``stopObservingConnections()`` — the idempotency claim, separate from
    /// the cancel closure so the claim can be taken under `lock` while the
    /// registration itself runs outside it.
    private var observing = false
    /// Tears down the live registration. Returned by the register seam; called
    /// ONLY outside `lock` (see ``stopObservingConnections()``).
    private var cancelObservation: (@Sendable () -> Void)?

    private let isBluetoothAuthorized: @Sendable () -> Bool
    private let openConnection: @Sendable (String) async -> Int32
    private let closeConnection: @Sendable (String) -> Void
    private let endpointExists: @Sendable (String) -> Bool
    /// The IOBluetooth notification seam: given the change handler, registers
    /// for connect notifications and returns the matching teardown (nil when
    /// registration failed). BOTH directions may synchronously call the handler
    /// (register replays every currently-connected device; unregister can
    /// deliver a final edge), so the manager calls this seam — and the returned
    /// teardown — strictly outside `lock`.
    private let registerConnectNotifications:
        @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)?
    private let connectTimeout: TimeInterval
    private let fallbackSuggestionDelay: TimeInterval
    private let endpointAppearWindow: TimeInterval
    private let endpointPollInterval: TimeInterval

    /// Production defaults touch real IOBluetooth / the HAL; tests inject all
    /// four seams (and shrink the timing knobs so nothing costs wall-clock
    /// seconds).
    init(
        isBluetoothAuthorized: @escaping @Sendable () -> Bool = { CBManager.authorization == .allowedAlways },
        openConnection: @escaping @Sendable (String) async -> Int32 = BTConnectionManager.systemOpenConnection,
        closeConnection: @escaping @Sendable (String) -> Void = BTConnectionManager.systemCloseConnection,
        endpointExists: @escaping @Sendable (String) -> Bool = BTConnectionManager.systemEndpointExists,
        registerConnectNotifications: @escaping @Sendable (@escaping @Sendable () -> Void)
            -> (@Sendable () -> Void)? = BTConnectionManager.systemRegisterConnectNotifications,
        connectTimeout: TimeInterval = BTConnectionManager.defaultConnectTimeout,
        fallbackSuggestionDelay: TimeInterval = BTConnectionManager.defaultFallbackSuggestionDelay,
        endpointAppearWindow: TimeInterval = BTConnectionManager.defaultEndpointAppearWindow,
        endpointPollInterval: TimeInterval = BTConnectionManager.defaultEndpointPollInterval
    ) {
        self.isBluetoothAuthorized = isBluetoothAuthorized
        self.openConnection = openConnection
        self.closeConnection = closeConnection
        self.endpointExists = endpointExists
        self.registerConnectNotifications = registerConnectNotifications
        self.connectTimeout = connectTimeout
        self.fallbackSuggestionDelay = fallbackSuggestionDelay
        self.endpointAppearWindow = endpointAppearWindow
        self.endpointPollInterval = endpointPollInterval
    }

    deinit {
        stopObservingConnections()
    }

    // MARK: Connect / disconnect

    /// One full reconnect attempt: TCC gate → `openConnection()` under the
    /// hard timeout → poll Core Audio for the endpoint. Exactly one terminal
    /// outcome; `onFallbackSuggested` may fire mid-flight (once).
    func connect(address: String) async -> BTConnectOutcome {
        guard isBluetoothAuthorized() else {
            Telemetry.log(.localPlayback, "bt_connect_unauthorized", ["address": address])
            return .unauthorized
        }
        let began = Date()
        // The fallback nudge: armed for the whole attempt, claimed on the way
        // out so it can never fire after the outcome resolved.
        let fallbackOnce = OnceFlag()
        let fallback = onFallbackSuggested
        let fallbackTask = Task { [fallbackSuggestionDelay] in
            try? await Task.sleep(nanoseconds: UInt64(fallbackSuggestionDelay * 1_000_000_000))
            guard !Task.isCancelled, fallbackOnce.claim() else { return }
            fallback?(address)
        }
        defer {
            _ = fallbackOnce.claim()
            fallbackTask.cancel()
        }

        guard let openReturn = await Self.race(timeout: connectTimeout, operation: { [openConnection] in
            await openConnection(address)
        }) else {
            // The ceiling elapsed. The abandoned OS attempt keeps blocking its
            // own worker thread until IOBluetooth gives up — accepted: it holds
            // no lock of ours and resolves within the OS's own horizon.
            let elapsed = Date().timeIntervalSince(began)
            Telemetry.log(.localPlayback, "bt_connect_failed", [
                "address": address, "reason": "timeout",
                "elapsed": String(format: "%.1f", elapsed),
            ])
            return .failed(elapsed: elapsed, reason: "timeout")
        }
        guard openReturn == 0 else {
            let elapsed = Date().timeIntervalSince(began)
            let reason = String(format: "0x%08x", UInt32(bitPattern: openReturn))
            Telemetry.log(.localPlayback, "bt_connect_failed", [
                "address": address, "reason": reason,
                "elapsed": String(format: "%.1f", elapsed),
            ])
            return .failed(elapsed: elapsed, reason: reason)
        }

        // Baseband is up; the audio endpoint follows (~0.6 s live-measured).
        let pollDeadline = Date().addingTimeInterval(endpointAppearWindow)
        while true {
            if endpointExists(address) {
                Telemetry.log(.localPlayback, "bt_connect_succeeded", [
                    "address": address,
                    "elapsed": String(format: "%.1f", Date().timeIntervalSince(began)),
                ])
                return .connected
            }
            guard Date() < pollDeadline else { break }
            try? await Task.sleep(nanoseconds: UInt64(endpointPollInterval * 1_000_000_000))
        }
        let elapsed = Date().timeIntervalSince(began)
        Telemetry.log(.localPlayback, "bt_connect_failed", [
            "address": address, "reason": "no_audio_endpoint",
            "elapsed": String(format: "%.1f", elapsed),
        ])
        return .failed(elapsed: elapsed, reason: "no_audio_endpoint")
    }

    func disconnect(address: String) {
        guard isBluetoothAuthorized() else { return }
        closeConnection(address)
        Telemetry.log(.localPlayback, "bt_disconnect", ["address": address])
    }

    // MARK: Availability notifications

    /// Register for IOBluetooth connect notifications (and, per connected
    /// device, its disconnect notification) → `onConnectionsChanged`.
    /// TCC-gated like everything else here; idempotent.
    func startObservingConnections() {
        guard isBluetoothAuthorized() else { return }
        lock.lock()
        guard !observing else {
            lock.unlock()
            return
        }
        observing = true
        lock.unlock()
        // The registration call must sit OUTSIDE the critical section:
        // IOBluetooth SYNCHRONOUSLY replays every currently-connected device
        // into the target during `register` (ReturnAllCurrentDevices), and the
        // handler re-enters this manager through the `onConnectionsChanged`
        // getter — same lock → main-thread deadlock before the status item
        // exists (live-hit 2026-08-07; only reachable once the Bluetooth TCC
        // grant lets the authorization guard above pass).
        let cancel = registerConnectNotifications { [weak self] in
            self?.onConnectionsChanged?()
        }
        lock.withLock { cancelObservation = cancel }
    }

    func stopObservingConnections() {
        lock.lock()
        let cancel = cancelObservation
        cancelObservation = nil
        observing = false
        lock.unlock()
        // The teardown runs OUTSIDE the lock for the same reason `register`
        // does (the register-side deadlock's exact mirror): IOBluetooth can
        // synchronously deliver a final edge into the handler mid-unregister,
        // re-entering this manager through the `onConnectionsChanged` getter.
        cancel?()
    }

    // MARK: Address helpers

    /// `Device.id` for a BT row is the Core Audio UID
    /// (`AA-BB-CC-DD-EE-FF:output`); IOBluetooth wants the bare MAC address.
    /// `nil` when the UID doesn't contain a 6-byte MAC.
    static func macAddress(fromUID uid: String) -> String? {
        BTDeviceEnumerator.derivedUID(fromAddress: uid).map { String($0.dropLast(":output".count)) }
    }

    // MARK: Production seam defaults (real IOBluetooth / HAL)
    //
    // NEVER call without the authorization gate having passed — an ungranted
    // IOBluetooth touch kills the process (see the class doc).

    private static let invalidAddressReturn: Int32 = -1

    private static let systemOpenConnection: @Sendable (String) async -> Int32 = { address in
        await withCheckedContinuation { continuation in
            // `openConnection()` BLOCKS its calling thread until the baseband
            // is up or the OS gives up (~15.4 s on a powered-off speaker) — a
            // global-queue hop keeps that stall off the caller.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let device = IOBluetoothDevice(addressString: address) else {
                    continuation.resume(returning: invalidAddressReturn)
                    return
                }
                continuation.resume(returning: device.openConnection())
            }
        }
    }

    private static let systemCloseConnection: @Sendable (String) -> Void = { address in
        _ = IOBluetoothDevice(addressString: address)?.closeConnection()
    }

    /// The same Core Audio listing the enumerator's production seam uses,
    /// matched on the normalized MAC (never string-equality on the UID, so a
    /// casing/format difference can't miss a live endpoint).
    private static let systemEndpointExists: @Sendable (String) -> Bool = { address in
        guard let key = BTDeviceEnumerator.macKey(address) else { return false }
        return BTDeviceEnumerator.systemOutputs().contains {
            $0.transportType == kAudioDeviceTransportTypeBluetooth
                && $0.hasOutputStreams
                && BTDeviceEnumerator.macKey($0.uid) == key
        }
    }

    /// Production register seam: the target/selector bridge into IOBluetooth's
    /// notification API. The returned teardown retains the target and the
    /// registration handle for the observation's whole lifetime.
    private static let systemRegisterConnectNotifications:
        @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Void)? = { onChange in
            let target = ConnectionNotificationTarget(onChange: onChange)
            let note = IOBluetoothDevice.register(
                forConnectNotifications: target,
                selector: #selector(ConnectionNotificationTarget.deviceConnected(_:device:)))
            return {
                note?.unregister()
                target.invalidate()
            }
        }

    // MARK: Internals

    /// Race `operation` against a timeout; `nil` = the timeout won. The losing
    /// operation is abandoned, never cancelled (IOBluetooth's blocking open has
    /// no cancellation), so the continuation is single-resume-guarded.
    private static func race<T: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = OnceFlag()
            Task {
                let value = await operation()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.withLock {
                if claimed { return false }
                claimed = true
                return true
            }
        }
    }
}

/// ObjC-visible target for `IOBluetoothDevice.register(forConnectNotifications:
/// selector:)` — IOBluetooth's notification API is target/selector, so the
/// Swift-closure manager above needs this small bridge. Each connect edge also
/// registers that device's disconnect notification (a disconnect registration
/// is per-device, and only a connected device can disconnect).
private final class ConnectionNotificationTarget: NSObject, @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var disconnectNotifications: [IOBluetoothUserNotification] = []

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    @objc func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let handle = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))) {
            lock.withLock { disconnectNotifications.append(handle) }
        }
        onChange()
    }

    @objc func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        lock.withLock { disconnectNotifications.removeAll { $0 === notification } }
        onChange()
    }

    func invalidate() {
        lock.withLock {
            disconnectNotifications.forEach { $0.unregister() }
            disconnectNotifications.removeAll()
        }
    }
}
