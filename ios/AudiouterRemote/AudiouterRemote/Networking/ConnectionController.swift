// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network
import AudiouterProtocol

/// The phone's stable identity for per-phone approval: ONE
/// `UUID().uuidString`, generated on first use and persisted forever (a
/// `UserDefaults` sibling of `lastUsedMacID`). The Mac's approvals store is
/// keyed on it — a regenerated identity IS "a different phone" and
/// re-prompts the Mac's user — so it must never churn casually. The server
/// canonicalizes to uppercase; we generate and persist uppercase
/// (`UUID().uuidString` already is) and re-canonicalize on read, so the
/// same phone can never drift into looking like two.
enum ClientIdentity {
    static let defaultsKey = "companionClientID"

    /// Load-or-create. Repairs in place: a stored value that no longer
    /// parses as a UUID (or isn't uppercase) is replaced/canonicalized and
    /// re-persisted before being returned.
    static func stableID(in defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: defaultsKey), UUID(uuidString: stored) != nil {
            let canonical = stored.uppercased()
            if canonical != stored { defaults.set(canonical, forKey: defaultsKey) }
            return canonical
        }
        return regenerate(in: defaults)
    }

    /// Mint and persist a fresh identity — ONLY for first launch and for
    /// the `invalidClientID` repair path (the Mac told us our identity is
    /// malformed, so keeping it can never succeed).
    @discardableResult
    static func regenerate(in defaults: UserDefaults) -> String {
        let id = UUID().uuidString
        defaults.set(id, forKey: defaultsKey)
        return id
    }
}

/// Owns the browser, the (single) live ``MacConnection``, and the Wi-Fi
/// path monitor; gives the app layer its scenePhase API
/// (`enterBackground()` / `enterForeground()`).
///
/// Everything — browser callbacks, connection transitions, reconnect
/// timers, path updates — runs on the one serial `queue`, and all
/// callbacks fire on it too; the session layer (T12) hops to the main
/// actor. The only persisted values are the last-used Mac id and the
/// phone's ``ClientIdentity`` — routing state is never persisted on the
/// phone (house rule).
///
/// Reconnect policy: while foregrounded, if the connection drops for a
/// RETRYABLE reason (see `MacDisconnectReason.reconnectClass`) and the
/// last-used Mac is still being browsed, reconnect — first attempt
/// immediately (eager), then capped exponential backoff (`NetworkBackoff`).
/// If the Mac is not currently browsed, the next browse result that
/// contains it triggers the attempt. Terminal reasons (`protoMismatch`,
/// `incompatiblePeer`, `notApproved`) settle instead: `connectionState` stays
/// `.disconnected(reason)` with NO redial until the next explicit
/// `connect(to:)`. `serverFull` retries on a long fixed delay;
/// `"disabled"` waits for the Mac's advertisement to disappear and come
/// back. Reconnect is seamless for the UI because every successful
/// handshake's welcome republishes a full snapshot through `onSnapshot`.
final class ConnectionController: @unchecked Sendable {

    // MARK: App-facing callbacks (fired on `queue`)

    /// All callbacks are queue-confined: assign them ONLY through the
    /// `set…` methods below, which hop to `queue` (assignment from main
    /// while the queue is mid-connect was a data race) and immediately
    /// replay the current value where one exists — a subscriber attaching
    /// AFTER the welcome landed must not stare at nil until the server
    /// happens to broadcast again (it suppresses identical broadcasts, so
    /// on an idle Mac "again" is never).
    private var onMacsChanged: (@Sendable ([DiscoveredMac]) -> Void)?
    private var onBrowserStateChanged: (@Sendable (MacBrowserState) -> Void)?
    private var onConnectionStateChanged: (@Sendable (MacConnectionState) -> Void)?
    private var onWiFiChanged: (@Sendable (Bool) -> Void)?
    /// Fired for the welcome snapshot AND every subsequent state broadcast.
    /// Staleness contract: a snapshot is only current while the connection
    /// is `.live` — on ANY disconnect `latestSnapshot` is cleared, no
    /// replay happens, and the app layer must treat the link as having no
    /// data until the next welcome.
    private var onSnapshot: (@Sendable (Snapshot) -> Void)?
    private var onCommandResult: (@Sendable (_ requestID: String, _ applied: Bool, _ refusalReason: String?, _ autoSwappedCurrentDevice: Bool) -> Void)?

    func setOnMacsChanged(_ handler: (@Sendable ([DiscoveredMac]) -> Void)?) {
        queue.async {
            self.onMacsChanged = handler
            handler?(self.macs)
        }
    }

    func setOnBrowserStateChanged(_ handler: (@Sendable (MacBrowserState) -> Void)?) {
        queue.async {
            self.onBrowserStateChanged = handler
            handler?(self.browserState)
        }
    }

    func setOnConnectionStateChanged(_ handler: (@Sendable (MacConnectionState) -> Void)?) {
        queue.async {
            self.onConnectionStateChanged = handler
            handler?(self.connectionState)
        }
    }

    func setOnWiFiChanged(_ handler: (@Sendable (Bool) -> Void)?) {
        queue.async {
            self.onWiFiChanged = handler
            handler?(self.onWiFi)
        }
    }

    func setOnSnapshot(_ handler: (@Sendable (Snapshot) -> Void)?) {
        queue.async {
            self.onSnapshot = handler
            if let snapshot = self.latestSnapshot { handler?(snapshot) }
        }
    }

    /// No replay — command results are events, not state.
    func setOnCommandResult(_ handler: (@Sendable (_ requestID: String, _ applied: Bool, _ refusalReason: String?, _ autoSwappedCurrentDevice: Bool) -> Void)?) {
        queue.async { self.onCommandResult = handler }
    }

    // MARK: State (touched on `queue` only, except reads via `queue.sync`)

    let queue = DispatchQueue(label: "AudiouterRemote.ConnectionController")
    private(set) var macs: [DiscoveredMac] = []
    private(set) var browserState: MacBrowserState = .idle
    private(set) var connectionState: MacConnectionState = .idle
    /// Optimistic until the first path update, so launch doesn't flash a
    /// "no Wi-Fi" warning before the monitor reports.
    private(set) var onWiFi = true
    /// Non-nil ONLY while the current connection has seen its welcome and
    /// has not disconnected — cleared on every disconnect so nothing can
    /// render (or be replayed) an hour-old fleet as if it were current.
    private(set) var latestSnapshot: Snapshot?
    private(set) var isForegrounded = true
    private(set) var reconnectAttempts = 0
    /// Terminal disconnect (protoMismatch / incompatiblePeer): auto-redial
    /// is off until the next explicit `connect(to:)` — redialing a Mac that
    /// speaks a newer protocol can only ever produce the same goodbye.
    private(set) var reconnectSuppressed = false
    /// `goodbye("disabled")`: the user unticked the Mac's checkbox. No
    /// redial until the Mac's advertisement DISAPPEARS from the browse list
    /// and comes back (re-ticking re-advertises) — hammering a Mac that
    /// told us it is turned off is noise.
    private(set) var awaitingReadvertise = false

    /// Fixed retry delay after `goodbye("serverFull")` — much longer than
    /// the capped backoff; a full server does not free a slot on our
    /// schedule.
    static let serverFullRetryDelay: TimeInterval = 60

    /// One repair per settled failure: `goodbye("invalidClientID")`
    /// regenerates the identity ONCE and redials; a second
    /// `invalidClientID` with the fresh identity means the problem is not
    /// the identity — settle (like `.terminal`) instead of minting
    /// identities in a loop. Cleared on `.live` and on every explicit
    /// `connect(to:)`.
    private(set) var identityRepairAttempted = false

    private let defaults: UserDefaults
    private let clientName: String
    /// See ``ClientIdentity`` — loaded at init, replaced only by the
    /// `invalidClientID` repair path. Touched on `queue` after init.
    private var clientID: String
    private let transportFactory: @Sendable (DiscoveredMac) -> MacTransport
    private let browser: MacBrowser
    private var pathMonitor: NWPathMonitor?
    private var connection: MacConnection?
    /// False after an explicit `disconnect()` until the next `connect(to:)` —
    /// a user who hung up shouldn't be auto-redialed.
    private var wantsConnection: Bool
    private var pendingReconnect: DispatchWorkItem?

    private static let lastUsedMacIDKey = "lastUsedMacID"

    var lastUsedMacID: String? {
        defaults.string(forKey: Self.lastUsedMacIDKey)
    }

    init(
        defaults: UserDefaults = .standard,
        clientName: String = ConnectionController.defaultClientName,
        transportFactory: @escaping @Sendable (DiscoveredMac) -> MacTransport = { ResolvedWebSocketTransport(mac: $0) }
    ) {
        self.defaults = defaults
        self.clientName = clientName
        self.clientID = ClientIdentity.stableID(in: defaults)
        self.transportFactory = transportFactory
        self.browser = MacBrowser(queue: queue)
        // Auto-reconnect to the remembered Mac out of the gate — unless
        // there is nothing remembered yet.
        self.wantsConnection = defaults.string(forKey: Self.lastUsedMacIDKey) != nil

        browser.setOnMacsChanged { [weak self] macs in
            self?.handleMacsChanged(macs)
        }
        browser.setOnStateChange { [weak self] state in
            guard let self else { return }
            self.browserState = state
            self.onBrowserStateChanged?(state)
        }
    }

    /// The hello's client name: the device's network host name (UIKit is
    /// off-limits in this layer, and `UIDevice.name` is the generic
    /// "iPhone" since iOS 16 anyway).
    static var defaultClientName: String {
        let host = ProcessInfo.processInfo.hostName
        return host.hasSuffix(".local") ? String(host.dropLast(".local".count)) : host
    }

    // MARK: Lifecycle (call from the app layer)

    func start() {
        queue.async {
            self.browser.start()
            self.startPathMonitor()
        }
    }

    /// scenePhase → `.background`: tear down the connection quietly. The
    /// drop is expected — `.closedByUs` is the no-error-surface reason — and
    /// nothing reconnects until `enterForeground()`. The browser and path
    /// monitor are left alone: the OS suspends the process anyway, and
    /// keeping them means the browse list is warm the moment we resume
    /// (tearing the browser down would also clear the list the eager
    /// foreground reconnect needs).
    func enterBackground() {
        queue.async {
            self.isForegrounded = false
            self.pendingReconnect?.cancel()
            self.pendingReconnect = nil
            self.reconnectAttempts = 0
            self.connection?.closeOnQueue(reason: .closedByUs)
        }
    }

    /// scenePhase → `.active`: eagerly reconnect to the last-used Mac
    /// (immediately once it is browsed; capped backoff after failures).
    /// Also the recovery point for a Local Network grant made in Settings
    /// while we were backgrounded: a suspended browser is recreated so the
    /// grant takes effect without an app relaunch.
    func enterForeground() {
        queue.async {
            self.browser.recreateIfPermissionSuspected()
            guard !self.isForegrounded else { return }
            self.isForegrounded = true
            self.reconnectAttempts = 0
            self.scheduleReconnectIfNeeded()
        }
    }

    // MARK: Connecting (call from the app layer)

    func connect(to mac: DiscoveredMac) {
        queue.async {
            self.wantsConnection = true
            self.reconnectAttempts = 0
            self.reconnectSuppressed = false
            self.awaitingReadvertise = false
            self.identityRepairAttempted = false
            self.defaults.set(mac.id, forKey: Self.lastUsedMacIDKey)
            // Refuse-forward, enforced: a Mac advertising a NEWER protocol
            // is shown but never dialed — dialing it just burns one of its
            // slots to be told `protoMismatch`. Settle in the same state
            // the goodbye would have produced, minus the round trip.
            guard !mac.isIncompatible else {
                self.reconnectSuppressed = true
                self.connectionState = .disconnected(.incompatiblePeer)
                self.onConnectionStateChanged?(self.connectionState)
                return
            }
            self.openConnection(to: mac)
        }
    }

    func disconnect() {
        queue.async {
            self.wantsConnection = false
            self.pendingReconnect?.cancel()
            self.pendingReconnect = nil
            self.reconnectAttempts = 0
            self.connection?.closeOnQueue(reason: .closedByUs)
        }
    }

    func send(command: CompanionCommand, requestID: String) {
        queue.async {
            self.connection?.send(command: command, requestID: requestID)
        }
    }

    // MARK: On `queue`

    func handleMacsChanged(_ macs: [DiscoveredMac]) {
        let previous = self.macs
        self.macs = macs
        onMacsChanged?(macs)
        // `goodbye("disabled")` resolution: the Mac's advertisement going
        // away and coming back is the "user re-ticked the checkbox" signal.
        if awaitingReadvertise, let id = lastUsedMacID,
           !previous.contains(where: { $0.id == id }),
           macs.contains(where: { $0.id == id }) {
            awaitingReadvertise = false
            reconnectAttempts = 0
        }
        // The Mac we want may have just (re)appeared.
        scheduleReconnectIfNeeded()
    }

    private func openConnection(to mac: DiscoveredMac) {
        pendingReconnect?.cancel()
        pendingReconnect = nil
        if let old = connection {
            old.onEvent = nil // replaced — its teardown must not re-enter
            old.closeOnQueue(reason: .closedByUs)
        }
        let transport = transportFactory(mac)
        let conn = MacConnection(mac: mac, transport: transport, clientID: clientID, clientName: clientName, queue: queue)
        connection = conn
        conn.onEvent = { [weak self, weak conn] event in
            guard let self, let conn else { return }
            self.handleConnectionEvent(event, from: conn)
        }
        conn.startOnQueue()
    }

    private func handleConnectionEvent(_ event: MacConnectionEvent, from conn: MacConnection) {
        guard conn === connection else { return } // stale session — never a zombie
        switch event {
        case .stateChanged(let state):
            connectionState = state
            onConnectionStateChanged?(state)
            switch state {
            case .live:
                reconnectAttempts = 0
                identityRepairAttempted = false
            case .disconnected(let reason):
                connection = nil
                // Staleness: whatever snapshot this session delivered is
                // no longer current the instant the session is gone.
                latestSnapshot = nil
                switch reason.reconnectClass {
                case .retry:
                    scheduleReconnectIfNeeded()
                case .longBackoff:
                    scheduleReconnectIfNeeded(minimumDelay: Self.serverFullRetryDelay)
                case .waitForReadvertise:
                    awaitingReadvertise = true
                case .terminal:
                    reconnectSuppressed = true
                case .repairIdentity:
                    if identityRepairAttempted {
                        // The fresh identity was ALSO refused — this is not
                        // an identity problem; stop minting them.
                        reconnectSuppressed = true
                    } else {
                        identityRepairAttempted = true
                        clientID = ClientIdentity.regenerate(in: defaults)
                        scheduleReconnectIfNeeded()
                    }
                case .quiet:
                    break
                }
            default:
                break
            }
        case .welcome(_, let snapshot):
            latestSnapshot = snapshot
            onSnapshot?(snapshot)
        case .snapshot(let snapshot):
            latestSnapshot = snapshot
            onSnapshot?(snapshot)
        case .commandResult(let requestID, let applied, let refusalReason, let autoSwapped):
            onCommandResult?(requestID, applied, refusalReason, autoSwapped)
        }
    }

    private func scheduleReconnectIfNeeded(minimumDelay: TimeInterval = 0) {
        guard isForegrounded, wantsConnection,
              !reconnectSuppressed, !awaitingReadvertise,
              connection == nil, pendingReconnect == nil,
              let id = lastUsedMacID,
              let mac = macs.first(where: { $0.id == id }),
              // Refuse-forward applies to auto-redial too: a Mac that
              // upgraded past us mid-session must not be hammered.
              !mac.isIncompatible
        else { return }

        // Eager first attempt, then the shared capped backoff;
        // `minimumDelay` floors it (serverFull's long fixed delay).
        let attempt = reconnectAttempts
        let delay = max(minimumDelay, attempt == 0 ? 0 : NetworkBackoff.delay(afterAttempt: attempt - 1))
        reconnectAttempts = attempt + 1

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReconnect = nil
            guard self.isForegrounded, self.wantsConnection,
                  !self.reconnectSuppressed, !self.awaitingReadvertise,
                  self.connection == nil,
                  let mac = self.macs.first(where: { $0.id == id }),
                  !mac.isIncompatible
            else { return }
            self.openConnection(to: mac)
        }
        pendingReconnect = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        // The .wifi requirement is meaningless in the simulator: its network
        // rides the host Mac's interface (typed wired/other), so a
        // required-Wi-Fi monitor never satisfies even though Bonjour works
        // fine there — which would pin the UI on "Not on Wi-Fi" and hide
        // every discovered Mac. Any satisfied path counts in the simulator;
        // real devices keep the honest Wi-Fi requirement.
        #if targetEnvironment(simulator)
        let monitor = NWPathMonitor()
        #else
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(satisfied: path.status == .satisfied)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// On `queue`. Internal (not private) so tests can drive path changes
    /// without a real `NWPathMonitor`.
    func handlePathUpdate(satisfied wifi: Bool) {
        guard wifi != onWiFi else { return }
        onWiFi = wifi
        onWiFiChanged?(wifi)
        if wifi {
            // Wi-Fi came back: any backoff in flight was priced for a
            // network that no longer exists — reset it and retry now.
            pendingReconnect?.cancel()
            pendingReconnect = nil
            reconnectAttempts = 0
            scheduleReconnectIfNeeded()
        }
    }
}

/// Terminal-vs-retryable classification of a disconnect reason — the
/// controller's redial policy in one switch. The catch-alls default to
/// `.retry` ON PURPOSE: an unknown goodbye reason from a newer server is
/// not proof that retrying is wrong, and this switch is the extension
/// point for future non-error states (e.g. a per-phone approval flow's
/// "waiting for the user to answer on the Mac" would be a new, long-lived,
/// non-redialing case here — not `.terminal`).
enum ReconnectClass: Equatable, Sendable {
    /// Eager-then-capped-backoff redial (transport failures, keepalive
    /// death, `"shutdown"`, unknown goodbye reasons).
    case retry
    /// `"serverFull"`: retry on `serverFullRetryDelay`, never eagerly.
    case longBackoff
    /// `"disabled"`: settle until the Mac re-advertises.
    case waitForReadvertise
    /// `"protoMismatch"` / `.incompatiblePeer`: redialing can never
    /// succeed with this app version — settle until an explicit connect.
    /// Also `"notApproved"`: the Mac's user pressed Don't Allow, and the
    /// denial is remembered server-side — every redial gets the same
    /// goodbye until they remove this phone in the Mac's Settings ›
    /// General, so redialing is harassment, not recovery.
    case terminal
    /// `"invalidClientID"`: our stored identity is malformed by the
    /// server's rules. Regenerate + persist a fresh one and retry — ONCE
    /// (see `ConnectionController.identityRepairAttempted`); if the fresh
    /// identity is refused too, settle like `.terminal`.
    case repairIdentity
    /// `.closedByUs`: we hung up; no redial, no error surface.
    case quiet
}

extension MacDisconnectReason {
    var reconnectClass: ReconnectClass {
        switch self {
        case .closedByUs: return .quiet
        case .incompatiblePeer: return .terminal
        case .goodbye(CompanionGoodbyeReason.protoMismatch): return .terminal
        case .goodbye(CompanionGoodbyeReason.serverFull): return .longBackoff
        case .goodbye(CompanionGoodbyeReason.disabled): return .waitForReadvertise
        case .goodbye(CompanionGoodbyeReason.notApproved): return .terminal
        case .goodbye(CompanionGoodbyeReason.invalidClientID): return .repairIdentity
        // `approvalTimedOut` lands in the catch-all on purpose: retryable,
        // normal backoff — reconnecting re-asks the Mac's user.
        case .goodbye, .failed, .keepaliveTimeout: return .retry
        }
    }
}
