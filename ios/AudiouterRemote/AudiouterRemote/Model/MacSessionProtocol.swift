// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import AudiouterProtocol

/// Everything the UI (Speakers/Apps/Groups/Connect tabs) depends on to
/// render and control a Mac — the only thing they ever touch. ``RemoteSession``
/// (this task, backed by a real ``ConnectionController``) and `DemoMacSession`
/// (T13, an in-memory simulated fleet) both conform; a tab never knows or
/// cares which one it was handed.
///
/// One method per `CompanionCommand` case (`.unknown` excluded — the phone
/// never sends it). The four continuous sliders (device volume, Main Out
/// master, app volume, connect volume) take an `isFinal` flag instead of a
/// separate method: `false` while dragging (subject to the ≤20 Hz
/// coalescing throttle), `true` on release (always sent — see
/// ``RemoteSession``'s doc comment for the full slider policy). All four
/// are plain stateless sets — no slider has a server-side drag bracket
/// (Main Out is its own stored gain on the Mac since the volume decoupling).
///
/// No phone-side persistence of any routing state (house rule) — a
/// conformer may cache nothing beyond what's needed to answer these calls
/// for the lifetime of the process.
@MainActor
protocol MacSessionProtocol: AnyObject {
    /// The latest full app state, or `nil` before the first snapshot arrives.
    var snapshot: Snapshot? { get }
    /// For header display — `DemoMacSession` reports a fixed `.live`.
    /// The per-phone approval flow rides on this too: `.awaitingApproval`
    /// (Mac is prompting its user — waiting surface, NOT an error) and the
    /// `notApproved` / `approvalTimedOut` goodbyes are all reachable, with
    /// ready-made copy, via `connectionStatus.approvalStatus`
    /// (``ApprovalStatus``, MacConnection.swift).
    var connectionStatus: MacConnectionState { get }
    /// True only for `DemoMacSession` — drives the "Demo" badge (T14+).
    var isDemo: Bool { get }
    /// Transient feedback surfaced after a command result (refusal / auto-swap).
    var toasts: ToastCenter { get }

    // MARK: Devices

    func setDeviceSelected(id: String, selected: Bool)
    func retryConnection(id: String)
    func setMainOut(_ state: MainOutState)
    func setDeviceVolume(id: String, volume: Int, isFinal: Bool)
    func setDeviceMuted(id: String, muted: Bool)

    // MARK: Main Out master

    func setMainOutMasterVolume(_ volume: Int, isFinal: Bool)
    func setMainOutMuted(_ muted: Bool)

    // MARK: Groups

    func createGroup(name: String, memberIDs: [String], iconSymbolName: String?)
    func updateGroup(_ group: GroupState)
    func deleteGroup(id: String)
    func setGroupMuted(id: String, muted: Bool)

    // MARK: Apps

    func addAppRoute(bundleID: String, displayName: String)
    func removeAppRoute(bundleID: String)
    func setAppDestination(bundleID: String, kind: String, deviceID: String?)
    func setAppVolume(bundleID: String, volume: Int, isFinal: Bool)

    // MARK: Settings

    func setConnectVolume(_ volume: Int, isFinal: Bool)
    func setStartBufferMs(_ ms: Int)

    // MARK: BT auto-cal spike (debug-only; dev/notes/bt-autocal-spike-spec.md)

    func startAlignmentProbe(targetDeviceID: String, referenceDeviceID: String?)
    func cancelAlignmentProbe()
    func submitProbeResult(targetDeviceID: String, offsetMs: Double, spreadMs: Double, confident: Bool)
}
