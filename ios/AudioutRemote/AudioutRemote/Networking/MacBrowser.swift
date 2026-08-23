// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network
import AudioutProtocol

/// Capped exponential backoff schedule shared by ``MacBrowser``'s
/// `.failed`-recreate loop and ``ConnectionController``'s reconnect loop —
/// the `NativeDiscovery.NetworkFrameworkBrowser.nextDelay` idiom from the
/// Mac side: 1s, 2s, 4s, … capped at 30s. Pure so the schedule math is
/// unit-testable without any live browser.
enum NetworkBackoff {
    static let maxSeconds: TimeInterval = 30

    /// `attempt` is 0-based: the count of consecutive failures seen so far,
    /// before this one.
    static func delay(afterAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 1 }
        return min(maxSeconds, pow(2.0, Double(attempt)))
    }
}

/// One Mac advertising the companion service, as browsed. Not yet resolved
/// to an address — resolution happens at connect time (see
/// ``ResolvedWebSocketTransport``); what we carry from browse time is the
/// `.service` endpoint plus the TXT metadata (`name`, `proto`).
struct DiscoveredMac: Identifiable, Equatable, Sendable {
    /// Stable identity across launches for the same advertised service: the
    /// Bonjour instance name + type + domain. This is the ONLY thing about a
    /// Mac that is ever persisted (last-used Mac id) — never routing state.
    let id: String
    /// The browse result's `.service` endpoint — input to connect-time
    /// resolution.
    let endpoint: NWEndpoint
    /// Display name from the TXT `name` key (`Snapshot.serverName`), falling
    /// back to the Bonjour instance name.
    let name: String
    /// TXT `proto` value. A missing or garbled key is treated as 1 (the
    /// oldest version): refuse-forward only refuses NEWER peers, and an
    /// ancient advertiser is fine to talk to.
    let protoVersion: Int
    /// `CompanionProto.isIncompatible(peerVersion:)` — true means this Mac
    /// speaks a NEWER protocol than us; show it, but don't connect.
    let isIncompatible: Bool
}

enum MacBrowserState: Equatable, Sendable {
    case idle
    case browsing
    /// See ``PermissionDenialDetector`` — a heuristic, not an API fact.
    case permissionSuspected
}

/// Detects the iOS Local Network permission denial, for which NO API
/// exists: a denied `NWBrowser` never reaches `.failed` — it sits in
/// `.waiting(.dns(-65570))` (kDNSServiceErr_PolicyDenied) forever, which is
/// indistinguishable at first sight from the transient -65570 blip that
/// occurs while the permission prompt is still on screen. The only handle
/// is this heuristic: that specific DNS error persisting beyond a grace
/// period. Pure (clock injected) so the threshold logic is unit-testable.
struct PermissionDenialDetector {
    /// kDNSServiceErr_PolicyDenied.
    static let policyDeniedCode: Int32 = -65570
    /// How long the denial must persist before we call it. The floor is
    /// set by the system permission alert: -65570 is emitted the whole
    /// time the prompt is ON SCREEN, and a user reading the alert text
    /// takes well over 3s — calling "denied" while they're still deciding
    /// is a false accusation the UI acts on. 8s trades a slower "check
    /// Settings" hint for not misfiring on a slow reader.
    static let threshold: TimeInterval = 8

    private(set) var deniedSince: Date?

    /// Feed every browser `.waiting(error)` here, with the `.dns` error
    /// code if that's what the error is (nil otherwise).
    mutating func browserWaiting(dnsErrorCode code: Int32?, at now: Date) {
        if code == Self.policyDeniedCode {
            if deniedSince == nil { deniedSince = now }
        } else {
            deniedSince = nil
        }
    }

    /// Feed `.ready` (or teardown) here — the condition cleared.
    mutating func cleared() {
        deniedSince = nil
    }

    func isSuspected(at now: Date) -> Bool {
        guard let deniedSince else { return false }
        return now.timeIntervalSince(deniedSince) >= Self.threshold
    }
}

/// Browses `_audiout._tcp` with TXT records (plain `.bonjour` returns nil
/// metadata) and publishes the current set of Macs. Mirrors the Mac side's
/// `NetworkFrameworkBrowser`: `.failed` is a TERMINAL NWBrowser state —
/// Network.framework does not restart it (only `.waiting` self-recovers) —
/// so on `.failed` we cancel and recreate after a capped backoff. A
/// permission denial does NOT fail the browser (see
/// ``PermissionDenialDetector``), so `.waiting` feeds the denial heuristic
/// instead of the recreate path.
///
/// All state lives on the injected serial `queue`; callbacks fire on it too
/// (``ConnectionController`` shares its own queue in, so browser +
/// connection + controller transitions are all serialized together).
final class MacBrowser: @unchecked Sendable {

    /// Queue-confined — assign only through the `set…` methods below.
    private var onMacsChanged: (@Sendable ([DiscoveredMac]) -> Void)?
    private var onStateChange: (@Sendable (MacBrowserState) -> Void)?

    func setOnMacsChanged(_ handler: (@Sendable ([DiscoveredMac]) -> Void)?) {
        queue.async { self.onMacsChanged = handler }
    }

    func setOnStateChange(_ handler: (@Sendable (MacBrowserState) -> Void)?) {
        queue.async { self.onStateChange = handler }
    }

    private let queue: DispatchQueue
    private var browser: NWBrowser?
    /// Pending recreate work, cancellable so `stop()` never leaves a zombie
    /// timer that fires a browser back into existence after teardown.
    private var pendingRecreate: DispatchWorkItem?
    /// Consecutive `.failed` count feeding `NetworkBackoff.delay`; reset to
    /// 0 on `.ready`.
    private var failureAttempt = 0
    private var detector = PermissionDenialDetector()
    /// Scheduled re-check that flips the published state to
    /// `.permissionSuspected` once the denial has persisted past threshold.
    private var pendingDenialCheck: DispatchWorkItem?
    private var publishedState: MacBrowserState = .idle

    init(queue: DispatchQueue = DispatchQueue(label: "AudioutRemote.MacBrowser")) {
        self.queue = queue
    }

    func start() {
        queue.async {
            guard self.browser == nil else { return }
            self.makeBrowser()
        }
    }

    func stop() {
        queue.async {
            self.pendingRecreate?.cancel()
            self.pendingRecreate = nil
            self.pendingDenialCheck?.cancel()
            self.pendingDenialCheck = nil
            self.failureAttempt = 0
            self.detector.cleared()
            self.browser?.cancel()
            self.browser = nil
            self.publish(.idle)
            self.onMacsChanged?([])
        }
    }

    /// Recovery path for a Local Network grant made in Settings AFTER the
    /// denial was called: a denied `NWBrowser` sits in `.waiting` and does
    /// not reliably pick the new grant up, so `permissionSuspected` would
    /// otherwise stick until an app relaunch. Called on foreground return
    /// (`ConnectionController.enterForeground`); a no-op unless the
    /// published state is actually `.permissionSuspected`.
    func recreateIfPermissionSuspected() {
        queue.async {
            guard self.publishedState == .permissionSuspected else { return }
            self.browser?.cancel()
            self.browser = nil
            self.detector.cleared()
            self.pendingDenialCheck?.cancel()
            self.pendingDenialCheck = nil
            self.failureAttempt = 0
            self.publish(.browsing)
            self.makeBrowser()
        }
    }

    // MARK: On `queue`

    private func makeBrowser() {
        pendingRecreate?.cancel()
        pendingRecreate = nil

        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: CompanionProto.serviceType, domain: nil),
            using: params
        )

        browser.stateUpdateHandler = { [weak self] state in
            guard let self, browser === self.browser else { return }
            switch state {
            case .setup:
                break
            case .ready:
                self.failureAttempt = 0
                self.detector.cleared()
                self.pendingDenialCheck?.cancel()
                self.pendingDenialCheck = nil
                self.publish(.browsing)
            case .waiting(let error):
                // `.waiting` self-recovers inside Network.framework once the
                // underlying condition clears — no recreate. It IS the
                // permission-denial signal, though: feed the heuristic.
                var code: Int32?
                if case .dns(let dnsCode) = error { code = dnsCode }
                self.detector.browserWaiting(dnsErrorCode: code, at: Date())
                self.scheduleDenialCheckIfNeeded()
            case .failed:
                self.scheduleRecreate()
            case .cancelled:
                break
            @unknown default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, browser === self.browser else { return }
            self.publishResults(results)
        }

        self.browser = browser
        if publishedState == .idle { publish(.browsing) }
        browser.start(queue: queue)
    }

    private func scheduleRecreate() {
        browser?.cancel()
        browser = nil

        let attempt = failureAttempt
        failureAttempt = attempt + 1
        let delay = NetworkBackoff.delay(afterAttempt: attempt)

        pendingRecreate?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRecreate = nil
            self.makeBrowser()
        }
        pendingRecreate = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleDenialCheckIfNeeded() {
        guard detector.deniedSince != nil, pendingDenialCheck == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDenialCheck = nil
            if self.detector.isSuspected(at: Date()) {
                self.publish(.permissionSuspected)
            }
        }
        pendingDenialCheck = item
        queue.asyncAfter(
            deadline: .now() + PermissionDenialDetector.threshold + 0.1,
            execute: item
        )
    }

    private func publish(_ state: MacBrowserState) {
        guard state != publishedState else { return }
        publishedState = state
        onStateChange?(state)
    }

    private func publishResults(_ results: Set<NWBrowser.Result>) {
        let macs = results
            .compactMap(Self.discoveredMac(from:))
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        onMacsChanged?(macs)
    }

    /// Pure browse-result → model mapping (the TXT metadata captured here at
    /// browse time is all the connection layer ever gets — resolution never
    /// re-reads TXT).
    static func discoveredMac(from result: NWBrowser.Result) -> DiscoveredMac? {
        guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata { txt = record.dictionary }
        let proto = txt[CompanionProto.TXTKey.proto].flatMap(Int.init) ?? 1
        return DiscoveredMac(
            id: "\(name).\(type)\(domain)",
            endpoint: result.endpoint,
            name: txt[CompanionProto.TXTKey.name] ?? name,
            protoVersion: proto,
            isIncompatible: CompanionProto.isIncompatible(peerVersion: proto)
        )
    }
}
