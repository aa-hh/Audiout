// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network
import AudiouterProtocol

/// Owns the browser, the (single) live ``MacConnection``, and the Wi-Fi
/// path monitor; gives the app layer its scenePhase API
/// (`enterBackground()` / `enterForeground()`).
///
/// Everything — browser callbacks, connection transitions, reconnect
/// timers, path updates — runs on the one serial `queue`, and all
/// callbacks fire on it too; the session layer (T12) hops to the main
/// actor. The ONLY persisted value is the last-used Mac id — routing state
/// is never persisted on the phone (house rule).
///
/// Reconnect policy: while foregrounded, if the connection drops for any
/// reason other than `.closedByUs` and the last-used Mac is still being
/// browsed, reconnect — first attempt immediately (eager), then capped
/// exponential backoff (`NetworkBackoff`). If the Mac is not currently
/// browsed, the next browse result that contains it triggers the attempt.
/// Reconnect is seamless for the UI because every successful handshake's
/// welcome republishes a full snapshot through `onSnapshot`.
final class ConnectionController: @unchecked Sendable {

    // MARK: App-facing callbacks (fired on `queue`)

    var onMacsChanged: (@Sendable ([DiscoveredMac]) -> Void)?
    var onBrowserStateChanged: (@Sendable (MacBrowserState) -> Void)?
    var onConnectionStateChanged: (@Sendable (MacConnectionState) -> Void)?
    var onWiFiChanged: (@Sendable (Bool) -> Void)?
    /// Fired for the welcome snapshot AND every subsequent state broadcast —
    /// the app layer only ever renders the latest one.
    var onSnapshot: (@Sendable (Snapshot) -> Void)?
    var onCommandResult: (@Sendable (_ requestID: String, _ applied: Bool, _ refusalReason: String?, _ autoSwappedCurrentDevice: Bool) -> Void)?

    // MARK: State (touched on `queue` only, except reads via `queue.sync`)

    let queue = DispatchQueue(label: "AudiouterRemote.ConnectionController")
    private(set) var macs: [DiscoveredMac] = []
    private(set) var browserState: MacBrowserState = .idle
    private(set) var connectionState: MacConnectionState = .idle
    /// Optimistic until the first path update, so launch doesn't flash a
    /// "no Wi-Fi" warning before the monitor reports.
    private(set) var onWiFi = true
    private(set) var latestSnapshot: Snapshot?
    private(set) var isForegrounded = true
    private(set) var reconnectAttempts = 0

    private let defaults: UserDefaults
    private let clientName: String
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
        self.transportFactory = transportFactory
        self.browser = MacBrowser(queue: queue)
        // Auto-reconnect to the remembered Mac out of the gate — unless
        // there is nothing remembered yet.
        self.wantsConnection = defaults.string(forKey: Self.lastUsedMacIDKey) != nil

        browser.onMacsChanged = { [weak self] macs in
            self?.handleMacsChanged(macs)
        }
        browser.onStateChange = { [weak self] state in
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
    func enterForeground() {
        queue.async {
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
            self.defaults.set(mac.id, forKey: Self.lastUsedMacIDKey)
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
        self.macs = macs
        onMacsChanged?(macs)
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
        let conn = MacConnection(mac: mac, transport: transport, clientName: clientName, queue: queue)
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
            case .disconnected(let reason):
                connection = nil
                if reason != .closedByUs {
                    scheduleReconnectIfNeeded()
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

    private func scheduleReconnectIfNeeded() {
        guard isForegrounded, wantsConnection,
              connection == nil, pendingReconnect == nil,
              let id = lastUsedMacID,
              macs.contains(where: { $0.id == id })
        else { return }

        // Eager first attempt, then the shared capped backoff.
        let attempt = reconnectAttempts
        let delay = attempt == 0 ? 0 : NetworkBackoff.delay(afterAttempt: attempt - 1)
        reconnectAttempts = attempt + 1

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReconnect = nil
            guard self.isForegrounded, self.wantsConnection, self.connection == nil,
                  let mac = self.macs.first(where: { $0.id == id })
            else { return }
            self.openConnection(to: mac)
        }
        pendingReconnect = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let wifi = path.status == .satisfied
            guard wifi != self.onWiFi else { return }
            self.onWiFi = wifi
            self.onWiFiChanged?(wifi)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }
}
