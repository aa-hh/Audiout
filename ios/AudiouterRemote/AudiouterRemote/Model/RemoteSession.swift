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

    private let controller: ConnectionController
    private let sender: CommandSender

    init(controller: ConnectionController, clock: CommandClock = WallCommandClock()) {
        self.controller = controller
        self.sender = CommandSender(
            transport: { [weak controller] command, requestID in
                controller?.send(command: command, requestID: requestID)
            },
            clock: clock
        )

        controller.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in self?.snapshot = snapshot }
        }
        controller.onConnectionStateChanged = { [weak self] state in
            Task { @MainActor in self?.connectionStatus = state }
        }
        controller.onCommandResult = { [weak self] requestID, applied, refusalReason, autoSwapped in
            Task { @MainActor in
                self?.handleCommandResult(applied: applied, refusalReason: refusalReason, autoSwapped: autoSwapped)
            }
        }
    }

    private func handleCommandResult(applied: Bool, refusalReason: String?, autoSwapped: Bool) {
        if !applied, let reason = refusalReason {
            toasts.show(.refusal(reason: reason))
        } else if autoSwapped {
            toasts.show(.autoSwap)
        }
    }

    // MARK: Devices

    func setDeviceSelected(id: String, selected: Bool) {
        sender.send(.setDeviceSelected(id: id, selected: selected))
    }

    func retryConnection(id: String) {
        sender.send(.retryConnection(id: id))
    }

    func setMainOut(_ state: MainOutState) {
        sender.send(.setMainOut(state))
    }

    func setDeviceVolume(id: String, volume: Int, isFinal: Bool) {
        let command = CompanionCommand.setDeviceVolume(id: id, volume: volume)
        let key = "device.volume.\(id)"
        if isFinal {
            sender.sendFinal(command, key: key)
        } else {
            sender.sendCoalesced(command, key: key)
        }
    }

    func setDeviceMuted(id: String, muted: Bool) {
        sender.send(.setDeviceMuted(id: id, muted: muted))
    }

    // MARK: Main Out master

    func beginMainOutDrag() {
        sender.send(.beginMainOutDrag)
    }

    func setMainOutMasterVolume(_ volume: Int, isFinal: Bool) {
        let command = CompanionCommand.setMainOutMasterVolume(volume: volume)
        let key = "mainOut.master"
        if isFinal {
            sender.sendFinal(command, key: key)
        } else {
            sender.sendCoalesced(command, key: key)
        }
    }

    func endMainOutDrag() {
        sender.send(.endMainOutDrag)
    }

    func setMainOutMuted(_ muted: Bool) {
        sender.send(.setMainOutMuted(muted: muted))
    }

    // MARK: Groups

    func createGroup(name: String, memberIDs: [String], iconSymbolName: String?) {
        sender.send(.createGroup(name: name, memberIDs: memberIDs, iconSymbolName: iconSymbolName))
    }

    func updateGroup(_ group: GroupState) {
        sender.send(.updateGroup(group))
    }

    func deleteGroup(id: String) {
        sender.send(.deleteGroup(id: id))
    }

    func setGroupMuted(id: String, muted: Bool) {
        sender.send(.setGroupMuted(id: id, muted: muted))
    }

    // MARK: Apps

    func addAppRoute(bundleID: String, displayName: String) {
        sender.send(.addAppRoute(bundleID: bundleID, displayName: displayName))
    }

    func removeAppRoute(bundleID: String) {
        sender.send(.removeAppRoute(bundleID: bundleID))
    }

    func setAppDestination(bundleID: String, kind: String, deviceID: String?) {
        sender.send(.setAppDestination(bundleID: bundleID, kind: kind, deviceID: deviceID))
    }

    func setAppVolume(bundleID: String, volume: Int, isFinal: Bool) {
        let command = CompanionCommand.setAppVolume(bundleID: bundleID, volume: volume)
        let key = "app.volume.\(bundleID)"
        if isFinal {
            sender.sendFinal(command, key: key)
        } else {
            sender.sendCoalesced(command, key: key)
        }
    }

    // MARK: Settings

    func setConnectVolume(_ volume: Int, isFinal: Bool) {
        let command = CompanionCommand.setConnectVolume(volume: volume)
        let key = "settings.connectVolume"
        if isFinal {
            sender.sendFinal(command, key: key)
        } else {
            sender.sendCoalesced(command, key: key)
        }
    }

    func setStartBufferMs(_ ms: Int) {
        sender.send(.setStartBufferMs(ms: ms))
    }
}
