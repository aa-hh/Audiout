import Foundation

/// Live connection lifecycle of a device the app is (or was) routing to.
///
/// This is a *presentation-and-policy* layer on top of `Device.isSelected` /
/// `Device.isAvailable`, not a replacement for either: membership in the
/// Selected Devices set still lives in `GroupController`, and routing is still
/// `OutputBackend.setOutputSet`. `connectionState` answers a different
/// question — "did the enable actually take?" — because OwnTone's
/// `PUT /api/outputs/set` returns success before the speaker has accepted the
/// session, and a failed activation just quietly reverts `selected` back to
/// `false` a moment later (`dev/notes/p1-owntone-api-brief.md` §1/§4). The
/// backend owns every transition; the UI only renders it
/// (`dev/notes/p1-connection-status-brief.md` §1).
///
/// State machine: `.off → .connecting → .connected`, `.connecting → .failed`,
/// `.connected → .reconnecting → .connected|.failed`. See the design brief §1
/// for the full entry-condition table, including the "sticky-failed" rule:
/// `.failed` survives the device being dropped from the expected-selected set
/// (that removal is failure *cleanup*, not a state override), and only clears
/// on `.off` when the device disappears entirely, or on retry (`.connecting`).
public enum ConnectionState: Equatable, Sendable {
    case off
    case connecting
    case connected
    case reconnecting
    case failed(ConnectionFailure)
}

/// Why an enable/stream failed, in user-presentable terms.
///
/// Constructed by the backend (an immediate best-guess from what it already
/// knows — see `p1-connection-status-brief.md` §3) and then possibly replaced
/// once `ConnectionDiagnosing` returns better evidence (§4).
public struct ConnectionFailure: Equatable, Sendable {

    /// The category of failure, driving the copy in `headline`/`suggestion`
    /// below. See the design brief §5 for how each case is diagnosed.
    public enum Cause: Equatable, Sendable {
        case notResponding    // advertised but AirPlay service not answering
        case vanished         // no longer advertised on the network
        case refusedOrBusy    // refused/403 — often an exclusive session elsewhere
        case authRequired     // password / pairing needed (unsupported)
        case droppedMidStream // was connected, silently dropped, recovery failed
        case timedOut         // connecting never resolved within 10 s
        // No shared PTP clock was reachable at connect time (T4,
        // PLAN-AIRPLAY-COEXISTENCE.md) — the on-demand helper either isn't
        // approved yet or didn't bind in time. Hard-failed rather than left
        // pending: a PTP-only receiver (Sonos/HomePod) accepts the session
        // but plays silence with no clock, so "connecting" would hang forever
        // with no audio.
        case timingUnavailable
        // A Bluetooth speaker refused the connect FAST — the live-measured
        // signature of a speaker another host (usually a phone) currently
        // holds. A powered-off speaker instead holds the OS attempt ~15.4 s
        // (dev/notes/bt-spike-findings-2026-08-07.md), which classifies as
        // `.timedOut`. Never auto-fight the other host (Decision 3).
        case connectedElsewhere
        case unknown
    }

    public var cause: Cause

    /// Raw evidence (e.g. matched engine-log line). Backs "Copy details".
    public var detail: String?

    public init(cause: Cause, detail: String? = nil) {
        self.cause = cause
        self.detail = detail
    }
}

extension ConnectionFailure {

    /// e.g. "Didn't respond" — short, sentence case, no terminal period.
    ///
    /// Presentation copy lives ON the type (not in UI code) so it's a single
    /// source of truth shared by the row sublabel, the diagnosis panel, and
    /// "Copy details" — see brief §2/§6/§7.
    public var headline: String {
        switch cause {
        case .notResponding:    return "Didn't respond"
        case .vanished:         return "Not on the network"
        case .refusedOrBusy:    return "Connection refused"
        case .authRequired:     return "Password required"
        case .droppedMidStream: return "Connection dropped"
        case .timedOut:         return "Took too long"
        case .timingUnavailable: return "Sync unavailable"
        case .connectedElsewhere: return "Connected elsewhere"
        case .unknown:          return "Couldn't connect"
        }
    }

    /// One sentence: what happened + what to do. Sentence case, ends with period.
    public var suggestion: String {
        switch cause {
        case .notResponding:
            return "The speaker is visible on the network but isn't answering AirPlay requests — it may be stuck or held by another app. Power-cycle it, then try again."
        case .vanished:
            return "The speaker is no longer visible on the network. Check that it's powered on and on the same Wi-Fi, then try again."
        case .refusedOrBusy:
            return "The speaker refused the connection — another device may hold an exclusive session. Stop playback from other apps or restart the speaker, then try again."
        case .authRequired:
            // A Mac receiver in "Current User" access-control mode is by far the
            // most common way to hit this (live 2026-08-06: act=2 in the TXT
            // record), and it has a receiver-side fix — name it. Entering a
            // password in Audiouter itself is roadmapped, not shipped.
            return "This speaker requires a password or pairing. If it's a Mac, set AirPlay Receiver to allow “Anyone on the same network” in its System Settings, then try again. Entering a password here isn't supported yet."
        case .droppedMidStream:
            return "The speaker dropped the stream and reconnecting failed. Check the speaker, then try again."
        case .timedOut:
            return "The connection attempt didn't complete. The speaker or network may be busy — try again."
        case .timingUnavailable:
            return "This speaker needs the Speaker Sync helper to stay in time, and it isn't ready. Approve it in Login Items & Extensions if prompted, then try again."
        case .connectedElsewhere:
            return "The speaker is connected to another device. Disconnect it there — or from this Mac's Bluetooth Settings — then try again."
        case .unknown:
            return "The connection failed for an unknown reason. Try again, or check the speaker."
        }
    }
}

/// Everything a `ConnectionDiagnosing` implementation needs to investigate a
/// failure, without depending on the concrete backend that produced it.
public struct DiagnosisContext: Sendable {
    public var deviceID: String
    public var deviceName: String
    /// OwnTone `has_password || requires_auth || needs_auth_key`.
    public var requiresAuth: Bool
    /// What the backend already inferred (e.g. `.timedOut`, `.droppedMidStream`,
    /// `.unknown`) before diagnosis ran — the fallback if nothing conclusive
    /// turns up (brief §5, step 5).
    public var priorCause: ConnectionFailure.Cause

    public init(deviceID: String, deviceName: String, requiresAuth: Bool, priorCause: ConnectionFailure.Cause) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.requiresAuth = requiresAuth
        self.priorCause = priorCause
    }
}

/// Investigates *why* a connection failed and turns raw evidence (engine log,
/// Bonjour presence, a TCP probe, auth flags) into one plain-English cause.
///
/// The backend fires this off in the background after immediately reporting
/// `.failed` with its best guess, then replaces the failure if diagnosis
/// returns something more specific and the device is still failed by then
/// (brief §3 "Failure flow"). `NetworkConnectionDiagnostics` (T3) is the real
/// implementation; tests inject fakes.
public protocol ConnectionDiagnosing: Sendable {
    /// Investigate a failure and return the best-evidence ConnectionFailure.
    /// Must complete within ~4 s (probes are bounded); never throws.
    func diagnose(_ context: DiagnosisContext) async -> ConnectionFailure
}
