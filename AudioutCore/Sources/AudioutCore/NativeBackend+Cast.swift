import Foundation
import AudioToolbox
import AirPlayEngine
import CastSender

extension NativeBackend {
    // MARK: Cast receivers → deviceAdded/deviceUpdated (CAST-ENUM)

    /// Fold one Cast browse snapshot into `known`/`order` (CAST-ENUM), the same
    /// shape `applyBTSnapshots` uses for the BT merged list. On `stateQueue`.
    ///
    /// An id absent from this list has dropped off the network, not been
    /// deleted: the row is kept (unavailable) and its browse record is kept too,
    /// so a receiver that comes back is addressable without a fresh browse. The
    /// connection state is deliberately NOT touched here — the session's own
    /// channel is the truth about whether it is still playing, and a Bonjour
    /// blip is not evidence either way.
    ///
    /// The unavailable flip is DEBOUNCED behind ``castAbsenceGrace``: a wired
    /// receiver advertises intermittently, and greying the row on the first
    /// browse that omits it made the device read as disabled mid-session. A
    /// browse that lists the id again inside the grace cancels the flip.
    func applyCastSnapshots(_ records: [CastDeviceRecord]) {   // on stateQueue
        for record in records {
            castRecords[record.id] = record
            castAbsenceFlips[record.id] = nil        // back inside the grace: no flip
            if var device = known[record.id] {
                let returned = !device.isAvailable
                device.name = record.friendlyName
                device.isAvailable = true
                if device != known[record.id] { commitKnownDevice(record.id, device) }
                if returned { logCastRowState(device) }
            } else {
                let device = Device(
                    id: record.id, name: record.friendlyName, kind: .cast,
                    isAvailable: true, supportsAirPlay2: false)
                known[record.id] = device
                order.append(record.id)
                emit(.deviceAdded(device))
                logCastRowState(device)
            }
        }
        let present = Set(records.map(\CastDeviceRecord.id))
        for id in order where known[id]?.kind == .cast && !present.contains(id) {
            guard known[id]?.isAvailable == true, castAbsenceFlips[id] == nil else { continue }
            castAbsenceGeneration += 1
            let generation = castAbsenceGeneration
            castAbsenceFlips[id] = generation
            stateQueue.asyncAfter(deadline: .now() + castAbsenceGrace) { [weak self] in
                self?.expireCastAbsence(id, generation)
            }
        }
    }

    /// The grace elapsed with the receiver still missing from the browse — it
    /// really has left the network, so grey the row now. Inert if a later browse
    /// listed the id again (the entry was dropped) or if a newer absence has
    /// since armed its own timer (the generation moved on). On `stateQueue`.
    private func expireCastAbsence(_ id: String, _ generation: Int) {   // on stateQueue
        guard castAbsenceFlips[id] == generation else { return }
        castAbsenceFlips[id] = nil
        guard var device = known[id], device.isCast, device.isAvailable else { return }
        device.isAvailable = false
        commitKnownDevice(id, device)
        logCastRowState(device)
    }

    /// One `cast_row_state` line per Cast availability / connection-state change:
    /// the diagnostic that says whether a row the user saw as "disabled" really
    /// was unavailable, or merely lacked a connection halo. Emitted only from
    /// `stateQueue` (never the capture IOProc), and `Telemetry.log` formats and
    /// hands off to its own queue, so it never blocks a decision.
    func logCastRowState(_ device: Device) {   // on stateQueue
        Telemetry.log(.cast, "cast_row_state", [
            "device": device.id,
            "isAvailable": device.isAvailable ? "true" : "false",
            "connectionState": Self.castRowConnectionName(device.connectionState),
        ])
    }

    private static func castRowConnectionName(_ state: ConnectionState) -> String {
        switch state {
        case .off: return "off"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting: return "reconnecting"
        case .failed(let failure): return "failed(\(failure.cause))"
        }
    }

}

/// Optional backend capability for a CAST row's SYNC control (CAST-SYNC) —
/// same `backend as? Capability` posture as ``BTOutputControlling``, and
/// `NativeBackend` is again the only conformer.
///
/// The value is the user's BY-EAR offset, in whole milliseconds, ±
/// ``BTSyncTrim/castRangeMs``. It is NOT the receiver's buffer: that is
/// measured on the wire and taken out automatically. This covers only what the
/// protocol cannot see — the receiver's output stage, its DAC, and, when the
/// target is a TV, the HDMI → TV → soundbar chain behind it.
public protocol CastSyncOffsetControlling: AnyObject {
    /// The stored offset for a receiver (0 when none).
    func castUserOffsetMs(forDevice id: String) -> Double
    /// Whether this receiver has an ENTRY at all — the honest answer to "tuned
    /// or never tuned?", which the value alone cannot give: a receiver
    /// deliberately set to 0 ms is tuned, and must not read "Not set".
    func castHasUserOffset(forDevice id: String) -> Bool
    /// Store an offset and apply it to the live Cast feed.
    func setCastUserOffsetMs(_ ms: Double, forDevice id: String)
    /// Delete the stored offset and put the live feed back on no correction.
    /// REMOVED, never written as 0: ``castHasUserOffset(forDevice:)`` answers
    /// by existence, so a stored 0 would leave the row reading "0 ms".
    func clearCastUserOffset(forDevice id: String)
}

extension NativeBackend: CastSyncOffsetControlling {

    public func castUserOffsetMs(forDevice id: String) -> Double {
        castOffsetLock.withLock { castOffsetsByID[id] ?? 0 }
    }

    public func castHasUserOffset(forDevice id: String) -> Bool {
        castOffsetLock.withLock { castOffsetsByID[id] != nil }
    }

    public func setCastUserOffsetMs(_ ms: Double, forDevice id: String) {
        let value = BTSyncTrim.quantise(ms, rangeMs: BTSyncTrim.castRangeMs)
        let all: [String: Double] = castOffsetLock.withLock {
            castOffsetsByID[id] = value
            return castOffsetsByID
        }
        do { try castOffsetStore?.save(all) } catch { StoreRecovery.noteWriteFailure(error) }
        pushCastUserOffset(value, forDevice: id)
    }

    public func clearCastUserOffset(forDevice id: String) {
        let all: [String: Double] = castOffsetLock.withLock {
            castOffsetsByID.removeValue(forKey: id)
            return castOffsetsByID
        }
        do { try castOffsetStore?.save(all) } catch { StoreRecovery.noteWriteFailure(error) }
        pushCastUserOffset(0, forDevice: id)
    }

    /// The one write onto the live feed. The session manager owns the per-device
    /// delay line and applies `max(0, roomDelay + userOffset)`, so this term is
    /// stored beside the controller's automatic one rather than competing with
    /// it — writing the offset never disturbs the room delay, and vice versa.
    /// An id with no session is ignored there (the `setLevel` posture), which is
    /// why an unarmed receiver needs no guard here and picks its value up from
    /// the arm instead.
    private func pushCastUserOffset(_ ms: Double, forDevice id: String) {
        castOutputManager?.setCastUserOffsetMs(Int(ms), forDeviceID: id)
    }

    /// Re-push every armed receiver's stored offset — the Cast twin of the
    /// Bluetooth sinks' arm-time trim replay, so a receiver the user reselects
    /// comes back carrying the offset it was tuned to rather than none.
    func pushStoredCastUserOffsets(forDeviceIDs ids: [String]) {
        let stored = castOffsetLock.withLock { castOffsetsByID }
        for id in ids {
            pushCastUserOffset(stored[id] ?? 0, forDevice: id)
        }
    }
}
