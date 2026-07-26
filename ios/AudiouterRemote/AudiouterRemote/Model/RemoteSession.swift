// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import AudiouterProtocol

/// The live ``MacSessionProtocol`` conformer: wraps a ``ConnectionController``
/// (T11) and is the ONLY thing tabs (T14-T17b) touch. Everything network-y —
/// the browser, the socket, reconnect — stays behind the controller; this
/// type's whole job is translating between "typed command the UI wants to
/// send" and "state the UI wants to render," plus the slider policy below.
///
/// ``ConnectionController``'s callbacks fire on its own serial queue (by
/// design — see its doc comment: "the session layer (T12) hops to the main
/// actor"), which is exactly what every handler here does before touching
/// `@Observable` state.
///
/// ## Slider policy
///
/// A drag on a continuous control (device volume, Main Out master, app
/// volume, connect volume) calls the matching `set...(_:isFinal:)` on every
/// tick with `isFinal: false`, then once more with `isFinal: true` on
/// release. The UI itself holds the live value locally while dragging (the
/// "local echo" — it never waits on a round trip to move the thumb); this
/// type only decides what actually reaches the wire:
///
/// - `isFinal == false` → ``CommandSender/sendCoalesced(_:key:)``: written
///   immediately if ≥50ms (20 Hz) has passed since the last send under that
///   control's key, dropped otherwise. A dropped interior sample is free —
///   the UI already shows the right value locally, and another tick is
///   coming any millisecond now.
/// - `isFinal == true` → ``CommandSender/sendFinal(_:key:)``: ALWAYS sent,
///   even if it lands inside the coalescing window. The release value is
///   the one the Mac must end up applying; dropping it would leave the
///   speaker holding a stale in-between volume.
///
/// Main Out's master slider additionally brackets the whole gesture with
/// `beginMainOutDrag()` / `endMainOutDrag()` (sent uncoalesced, exactly like
/// every other one-shot command) around that same `setMainOutMasterVolume`
/// stream — mirroring the Mac popover's own drag brackets. No other slider
/// has a server-side bracket to wrap.
///
/// No phone-side persistence of any routing state (house rule): this type
/// holds only the in-memory latest ``Snapshot`` handed to it by the
/// controller: it reads no defaults and writes none itself (the controller's
/// own `lastUsedMacID` is the one exception, and it isn't routing state).
@MainActor
@Observable
final class RemoteSession: MacSessionProtocol {

    private(set) var snapshot: Snapshot?
    private(set) var connectionStatus: MacConnectionState = .idle
    let isDemo = false
    let toasts = ToastCenter()

    /// How long a sent command may go unanswered while `.live` before the
    /// user is told (the Mac replies to every command with a
    /// `commandResult`; silence past this means the Mac app is not
    /// processing — a healthy-looking UI whose commands vanish is the worst
    /// failure shape). `var` so tests shrink it.
    var commandTimeout: TimeInterval = 5
    static let commandTimeoutToastText =
        "The Mac isn't responding. Check Audiouter on your Mac."

    /// requestIDs written to the wire and not yet answered by a
    /// `commandResult` (main-actor confined).
    private var pendingRequests: Set<String> = []

    private let controller: ConnectionController
    private let sender: CommandSender

    /// Event delivery from the controller's queue to the main actor is
    /// `DispatchQueue.main.async` (FIFO), NOT one unstructured `Task` per
    /// event: main-actor Tasks carry no ordering guarantee, so two rapid
    /// snapshots could land reversed and the STALE one would stick (the
    /// server suppresses identical broadcasts, so nothing would ever
    /// correct it). Subscription happens through the controller's `set…`
    /// replay setters, so a session constructed AFTER the link went live
    /// still receives the current snapshot/state immediately.
    init(controller: ConnectionController, clock: CommandClock = WallCommandClock()) {
        self.controller = controller
        self.sender = CommandSender(
            transport: { [weak controller] command, requestID in
                controller?.send(command: command, requestID: requestID)
            },
            clock: clock
        )

        controller.setOnSnapshot { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.snapshot = snapshot }
            }
        }
        controller.setOnConnectionStateChanged { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyConnectionState(state) }
            }
        }
        controller.setOnCommandResult { [weak self] requestID, applied, refusalReason, autoSwapped in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleCommandResult(
                        requestID: requestID,
                        applied: applied,
                        refusalReason: refusalReason,
                        autoSwapped: autoSwapped
                    )
                }
            }
        }
    }

    private func applyConnectionState(_ state: MacConnectionState) {
        connectionStatus = state
        if case .disconnected = state {
            // Staleness contract (mirrors the controller clearing
            // `latestSnapshot`): render nothing rather than an old fleet.
            snapshot = nil
            // The disconnect itself is the surface for anything in flight —
            // a timeout toast on top would be noise.
            pendingRequests.removeAll()
        }
    }

    private func handleCommandResult(requestID: String, applied: Bool, refusalReason: String?, autoSwapped: Bool) {
        pendingRequests.remove(requestID)
        if !applied, let reason = refusalReason {
            toasts.show(.refusal(reason: reason))
        } else if autoSwapped {
            toasts.show(.autoSwap)
        }
    }

    // MARK: Per-request timeout

    /// Every command written to the wire passes through here: the requestID
    /// is tracked until its `commandResult` arrives, and if none does
    /// within `commandTimeout` while still `.live`, a toast surfaces it —
    /// an unanswered command must never just vanish. Coalesced sends that
    /// were dropped by the throttle pass `nil` and track nothing.
    private func track(_ requestID: String?) {
        guard let requestID else { return }
        pendingRequests.insert(requestID)
        DispatchQueue.main.asyncAfter(deadline: .now() + commandTimeout) { [weak self] in
            MainActor.assumeIsolated { self?.requestTimedOut(requestID) }
        }
    }

    private func requestTimedOut(_ requestID: String) {
        guard pendingRequests.remove(requestID) != nil else { return }
        guard case .live = connectionStatus else { return }
        toasts.show(.refusal(reason: Self.commandTimeoutToastText))
    }

    /// Shared slider shape: final → always sent, interior → throttled;
    /// whichever actually reached the wire is tracked for a result.
    private func sendSlider(_ command: CompanionCommand, key: String, isFinal: Bool) {
        if isFinal {
            track(sender.sendFinal(command, key: key))
        } else {
            track(sender.sendCoalesced(command, key: key))
        }
    }

    // MARK: Devices

    func setDeviceSelected(id: String, selected: Bool) {
        track(sender.send(.setDeviceSelected(id: id, selected: selected)))
    }

    func retryConnection(id: String) {
        track(sender.send(.retryConnection(id: id)))
    }

    func setMainOut(_ state: MainOutState) {
        track(sender.send(.setMainOut(state)))
    }

    func setDeviceVolume(id: String, volume: Int, isFinal: Bool) {
        sendSlider(.setDeviceVolume(id: id, volume: volume), key: "device.volume.\(id)", isFinal: isFinal)
    }

    func setDeviceMuted(id: String, muted: Bool) {
        track(sender.send(.setDeviceMuted(id: id, muted: muted)))
    }

    // MARK: Main Out master

    func beginMainOutDrag() {
        track(sender.send(.beginMainOutDrag))
    }

    func setMainOutMasterVolume(_ volume: Int, isFinal: Bool) {
        sendSlider(.setMainOutMasterVolume(volume: volume), key: "mainOut.master", isFinal: isFinal)
    }

    func endMainOutDrag() {
        track(sender.send(.endMainOutDrag))
    }

    func setMainOutMuted(_ muted: Bool) {
        track(sender.send(.setMainOutMuted(muted: muted)))
    }

    // MARK: Groups

    func createGroup(name: String, memberIDs: [String], iconSymbolName: String?) {
        track(sender.send(.createGroup(name: name, memberIDs: memberIDs, iconSymbolName: iconSymbolName)))
    }

    func updateGroup(_ group: GroupState) {
        track(sender.send(.updateGroup(group)))
    }

    func deleteGroup(id: String) {
        track(sender.send(.deleteGroup(id: id)))
    }

    func setGroupMuted(id: String, muted: Bool) {
        track(sender.send(.setGroupMuted(id: id, muted: muted)))
    }

    // MARK: Apps

    func addAppRoute(bundleID: String, displayName: String) {
        track(sender.send(.addAppRoute(bundleID: bundleID, displayName: displayName)))
    }

    func removeAppRoute(bundleID: String) {
        track(sender.send(.removeAppRoute(bundleID: bundleID)))
    }

    func setAppDestination(bundleID: String, kind: String, deviceID: String?) {
        track(sender.send(.setAppDestination(bundleID: bundleID, kind: kind, deviceID: deviceID)))
    }

    func setAppVolume(bundleID: String, volume: Int, isFinal: Bool) {
        sendSlider(.setAppVolume(bundleID: bundleID, volume: volume), key: "app.volume.\(bundleID)", isFinal: isFinal)
    }

    // MARK: Settings

    func setConnectVolume(_ volume: Int, isFinal: Bool) {
        sendSlider(.setConnectVolume(volume: volume), key: "settings.connectVolume", isFinal: isFinal)
    }

    func setStartBufferMs(_ ms: Int) {
        track(sender.send(.setStartBufferMs(ms: ms)))
    }
}
