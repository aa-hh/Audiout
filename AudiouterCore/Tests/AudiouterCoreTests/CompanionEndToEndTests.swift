// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import Network
import AudiouterProtocol
@testable import AudiouterCore

/// Mac-side end-to-end integration test (PLAN-COMPANION-APP.md T8): assembles
/// `MockBackend` + REAL `GroupController`/`AppRoutingController`/
/// `ExcludedAppsController` (temp-dir stores, `CompanionCommandDispatcherTests`'
/// construction pattern) + the REAL `CompanionSnapshotBuilder`/
/// `CompanionCommandDispatcher`/`CompanionServer`, wired the way `AppDelegate`
/// (T7) is expected to wire them — without any AppKit import — and drives the
/// whole stack through two loopback WebSocket clients.
///
/// The loopback harness (`LoopbackHub`/`connectClient`/`sendHello`) is copied
/// from `CompanionServerTests`, including its two load-bearing traps:
/// - a WebSocket **client** must dial a `ws://` URL, not a bare host/port
///   endpoint, or the upgrade handshake aborts (ECONNABORTED);
/// - the listener is pinned to `127.0.0.1` via `requiredLocalEndpoint`, and
///   connections are handed to the internal `accept(_:)` seam rather than
///   `CompanionServer.start(name:)`'s own all-interfaces, Bonjour-advertising
///   listener — which is exactly what trips macOS's Application Firewall
///   prompt for the `xctest` process under `swift test`.
@MainActor
@Suite final class CompanionEndToEndTests: IsolatedSuite {

    // MARK: - The assembled stack (AppDelegate-shaped, no AppKit)

    /// Wires `MockBackend` + real controllers + the real builder/dispatcher/
    /// server the way `AppDelegate` does: any controller-level change (Mac UI
    /// action or an applied phone command) rebuilds the snapshot and
    /// broadcasts it; an incoming `command` frame hops to the main actor,
    /// executes against the dispatcher, replies, and broadcasts. `@unchecked
    /// Sendable` because `CompanionServer.onCommand` is `@Sendable` (it may
    /// fire from any thread) and this instance is captured by it — every
    /// mutable/isolated member is only ever touched after the `Task {
    /// @MainActor in }` hop below, matching `CompanionServer`'s own
    /// queue-confinement discipline.
    @MainActor
    private final class Rig: @unchecked Sendable {
        static let serverName = "TestMac"

        let backend: MockBackend
        let groupController: GroupController
        let appRouting: AppRoutingController
        let excludedApps: ExcludedAppsController
        let settings: AppSettings
        let dispatcher: CompanionCommandDispatcher
        let server = CompanionServer()

        init(scratchDir: URL, defaults: UserDefaults, fleet: [Device] = .demoFleet) {
            backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
            groupController = GroupController(
                backend: backend,
                store: GroupStore(directory: scratchDir),
                routingStore: RoutingStore(directory: scratchDir),
                loadPersisted: false
            )
            appRouting = AppRoutingController(store: AppRouteStore(directory: scratchDir), loadPersisted: false)
            excludedApps = ExcludedAppsController(store: ExcludedAppsStore(directory: scratchDir), loadPersisted: false)
            settings = AppSettings(defaults: defaults)
            let excluded = excludedApps
            dispatcher = CompanionCommandDispatcher(
                groupController: groupController,
                appRouting: appRouting,
                settings: settings,
                isExcluded: { excluded.isExcluded($0) },
                setLocalPlaybackVolume: { _, _ in }, // not under test here
                applyStartBuffer: { _ in }           // not under test here
            )

            // Mac-originated mutations (a direct controller call, same as the
            // popover/mixer window would make) rebuild + broadcast. These
            // closures are inferred `@MainActor` (not `@Sendable`) because
            // they're formed here, inside this MainActor initializer.
            groupController.onStateDidChange = { [self] in rebuildAndBroadcast() }
            appRouting.onRoutesDidChange = { [self] in rebuildAndBroadcast() }

            // Phone-originated commands: `onCommand` is `@Sendable` and may
            // fire from the server's own queue — hop to main ASYNCHRONOUSLY
            // (never `.sync`, per `CompanionServer`'s own wiring-surface
            // doc), execute, reply, then broadcast (redundant with the
            // onStateDidChange broadcast above for state-changing commands;
            // harmless since CompanionServer suppresses identical repeats,
            // and load-bearing for refusals/no-ops that never touch state).
            server.onCommand = { [self] requestID, command, clientID, reply in
                Task { @MainActor in
                    let result = self.dispatcher.execute(command)
                    reply(CompanionServer.CommandResult(
                        applied: result.applied,
                        refusalReason: result.refusalReason,
                        autoSwappedCurrentDevice: result.autoSwappedCurrentDevice
                    ))
                    self.rebuildAndBroadcast()
                }
            }

            // T5's deferred-welcome window: a client that says hello before
            // any broadcast waits for the first one. The real wiring
            // broadcasts once right after start; do the same here.
            rebuildAndBroadcast()
        }

        func buildSnapshot() -> Snapshot {
            CompanionSnapshotBuilder.build(
                devices: backend.devices,
                groupController: groupController,
                appRouting: appRouting,
                excludedBundleIDs: excludedApps.excludedBundleIDs,
                iconFor: { _ in "icon" },
                addableApps: [],
                runningRouted: [],
                liveRoutedAppNames: [:],
                localFallbackActive: false,
                takeoverStatus: nil,
                serverName: Self.serverName,
                connectVolume: settings.connectVolume,
                connectVolumeMin: AppSettings.minConnectVolume,
                connectVolumeMax: AppSettings.maxConnectVolume,
                startBufferMs: settings.startBufferMs,
                startBufferOptionsMs: AppSettings.startBufferOptionsMs
            )
        }

        func rebuildAndBroadcast() {
            server.broadcast(buildSnapshot())
        }
    }

    /// Discovers the fleet synchronously before handing `backend` to a
    /// `Rig` — same blocking-discovery-wait idiom as
    /// `GroupControllerTests.makeBackend`/`CompanionCommandDispatcherTests.makeContext`.
    private func makeRig(fleet: [Device] = .demoFleet) async throws -> Rig {
        let rig = Rig(scratchDir: scratchDir, defaults: isolatedDefaults, fleet: fleet)
        try await waitForFleet(rig.backend, count: fleet.count)
        rig.rebuildAndBroadcast() // the fleet is now visible in the snapshot
        return rig
    }

    private func waitForFleet(_ backend: MockBackend, count: Int) async throws {
        let stream = backend.makeEventStream()
        let box = E2ECountBox()
        try await confirmation("fleet discovered") { discovered in
            let task = Task {
                for await event in stream {
                    if case .deviceAdded = event, await box.increment() >= count {
                        discovered(); break
                    }
                }
            }
            defer { task.cancel() }
            backend.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }
    }

    // MARK: - Concurrency-safe test plumbing (copied from CompanionServerTests)

    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { _value = value }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private final class MessageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [CompanionMessage] = []
        private var _closed = false
        func append(_ message: CompanionMessage) { lock.withLock { _messages.append(message) } }
        func markClosed() { lock.withLock { _closed = true } }
        var messages: [CompanionMessage] { lock.withLock { _messages } }
        var closed: Bool { lock.withLock { _closed } }
        func contains(_ message: CompanionMessage) -> Bool { messages.contains(message) }
        /// A `state` broadcast whose snapshot satisfies `predicate`.
        func containsState(where predicate: (Snapshot) -> Bool) -> Bool {
            messages.contains {
                if case .state(let snapshot) = $0 { return predicate(snapshot) }
                return false
            }
        }
    }

    /// `async`, unlike `CompanionServerTests`' synchronous twin: THIS suite is
    /// `@MainActor` (`CompanionCommandDispatcher` requires it), so a test
    /// method runs ON the main actor's executor. Phone-originated commands
    /// only complete via a `Task { @MainActor in }` hop (`Rig.init`'s
    /// `onCommand` wiring) — if this loop blocked that executor with a
    /// synchronous `Thread.sleep`, that Task could never run and the
    /// condition it exists to satisfy would never become true (self-deadlock).
    /// `await Task.sleep` actually suspends, freeing the executor between
    /// polls.
    nonisolated private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    // MARK: - Loopback WebSocket harness (copied from CompanionServerTests)

    private final class LoopbackHub: @unchecked Sendable {
        let listener: NWListener
        let netQueue = DispatchQueue(label: "CompanionEndToEndTests.loopback")
        private let lock = NSLock()
        private var pending: [NWConnection] = []
        private var _isReady = false

        init() throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.withLock { self.pending.append(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    guard let self else { return }
                    self.lock.withLock { self._isReady = true }
                }
            }
            listener.start(queue: netQueue)
        }

        var isReady: Bool { lock.withLock { _isReady } }
        var hasPending: Bool { lock.withLock { !pending.isEmpty } }
        func popPending() -> NWConnection? {
            lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        }
        func cancel() { listener.cancel() }
    }

    nonisolated private func makeHub() async throws -> LoopbackHub {
        let hub = try LoopbackHub()
        try #require(await waitUntil { hub.isReady }, "test loopback listener never reached .ready")
        let port = try #require(hub.listener.port, "listener bound no port")
        try #require(port.rawValue != 0, "listener port never left the placeholder 0")
        return hub
    }

    nonisolated private func connectClient(via hub: LoopbackHub, to server: CompanionServer) async throws -> (client: NWConnection, log: MessageLog) {
        let port = try #require(hub.listener.port)
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // A WebSocket client must dial a `ws://` URL endpoint — a plain
        // host/port endpoint aborts the upgrade handshake.
        let url = try #require(URL(string: "ws://127.0.0.1:\(port.rawValue)"))
        let client = NWConnection(to: .url(url), using: params)

        let log = MessageLog()
        let ready = LockedBox(false)
        client.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.value = true
            case .cancelled, .failed: log.markClosed()
            default: break
            }
        }
        client.start(queue: hub.netQueue)
        receiveInto(log, from: client)

        try #require(await waitUntil { hub.hasPending }, "the loopback listener never accepted the client")
        let serverSide = try #require(hub.popPending())
        server.accept(serverSide)
        try #require(await waitUntil { ready.value }, "the WebSocket handshake never completed")
        return (client, log)
    }

    nonisolated private func receiveInto(_ log: MessageLog, from client: NWConnection) {
        client.receiveMessage { data, context, _, error in
            if error != nil { log.markClosed(); return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                log.markClosed()
                return
            }
            guard let data, !data.isEmpty else { log.markClosed(); return }
            if let envelope = try? CompanionEnvelope.decode(data) {
                log.append(envelope.message)
            }
            self.receiveInto(log, from: client)
        }
    }

    nonisolated private func sendText(_ data: Data, over client: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        client.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    nonisolated private func sendHello(over client: NWConnection, name: String = "phone") throws {
        sendText(try CompanionEnvelope(message: .hello(clientName: name, protoVersion: CompanionProto.version)).encoded(), over: client)
    }

    nonisolated private func sendCommand(_ command: CompanionCommand, requestID: String, over client: NWConnection) throws {
        sendText(try CompanionEnvelope(message: .command(requestID: requestID, command: command)).encoded(), over: client)
    }

    /// Connects a client, says hello, and waits for its welcome — the shared
    /// setup every scenario below starts from.
    nonisolated private func connectAndWelcome(via hub: LoopbackHub, to server: CompanionServer, name: String) async throws -> (client: NWConnection, log: MessageLog) {
        let (client, log) = try await connectClient(via: hub, to: server)
        try sendHello(over: client, name: name)
        try #require(await waitUntil { log.messages.contains { if case .welcome = $0 { return true } else { return false } } },
                     "\(name) was never welcomed")
        return (client, log)
    }

    // MARK: 1 — connect+hello → welcome carries a correct full snapshot

    @Test func connectAndHelloYieldsWelcomeCarryingTheCorrectFullSnapshot() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let hub = try await makeHub()
        defer { hub.cancel() }

        let (client, log) = try await connectClient(via: hub, to: rig.server)
        defer { client.cancel() }
        try sendHello(over: client)

        let expected = rig.buildSnapshot()
        #expect(expected.devices.count == [Device].demoFleet.count, "sanity: the fleet is really in the snapshot")
        #expect(await waitUntil {
            log.contains(.welcome(serverName: Rig.serverName, protoVersion: CompanionProto.version, snapshot: expected))
        }, "the client never received a welcome carrying the correct full snapshot")
    }

    // MARK: 2 — client A's setDeviceSelected applies + both clients see the state broadcast

    @Test func setDeviceSelectedAppliesAndBroadcastsToBothClients() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let hub = try await makeHub()
        defer { hub.cancel() }

        let (clientA, logA) = try await connectAndWelcome(via: hub, to: rig.server, name: "phoneA")
        defer { clientA.cancel() }
        let (clientB, logB) = try await connectAndWelcome(via: hub, to: rig.server, name: "phoneB")
        defer { clientB.cancel() }

        try sendCommand(.setDeviceSelected(id: "office", selected: true), requestID: "r1", over: clientA)

        #expect(await waitUntil {
            logA.contains(.commandResult(requestID: "r1", applied: true, refusalReason: nil, autoSwappedCurrentDevice: false))
        }, "client A never received its commandResult")
        #expect(rig.groupController.isSpeakerSelected("office"), "the command never reached the real GroupController")

        for (name, log) in [("A", logA), ("B", logB)] {
            #expect(await waitUntil {
                log.containsState { $0.devices.first(where: { $0.id == "office" })?.isSelected == true }
            }, "client \(name) never received a state broadcast reflecting the selection — via GroupController truth, not Device.isSelected")
        }
    }

    // MARK: 3 — a refusal round-trips applied:false + a reason, with no state change

    @Test func invalidStartBufferMsIsRefusedAndChangesNothing() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let hub = try await makeHub()
        defer { hub.cancel() }

        let (client, log) = try await connectAndWelcome(via: hub, to: rig.server, name: "phone")
        defer { client.cancel() }
        let before = rig.settings.startBufferMs

        try sendCommand(.setStartBufferMs(ms: 42), requestID: "r-refuse", over: client) // 42 is not one of AppSettings.startBufferOptionsMs

        #expect(await waitUntil {
            log.messages.contains {
                if case .commandResult(let requestID, let applied, let refusalReason, _) = $0 {
                    return requestID == "r-refuse" && applied == false && refusalReason != nil
                }
                return false
            }
        }, "the invalid buffer size was never refused with a reason")
        #expect(rig.settings.startBufferMs == before, "a refused command must not change settings")
        #expect(!log.messages.contains { if case .state = $0 { return true } else { return false } },
                "a refusal that changed nothing must not produce a state broadcast beyond the initial welcome")
    }

    @Test func excludedAppRouteIsRefusedAndNeverAddsARoute() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let hub = try await makeHub()
        defer { hub.cancel() }
        rig.excludedApps.exclude(bundleID: "com.excluded.app", displayName: "Excluded")

        let (client, log) = try await connectAndWelcome(via: hub, to: rig.server, name: "phone")
        defer { client.cancel() }

        try sendCommand(.addAppRoute(bundleID: "com.excluded.app", displayName: "Excluded"), requestID: "r-excl", over: client)

        #expect(await waitUntil {
            log.messages.contains {
                if case .commandResult(let requestID, let applied, let refusalReason, _) = $0 {
                    return requestID == "r-excl" && applied == false && refusalReason != nil
                }
                return false
            }
        }, "an excluded app's addAppRoute was never refused with a reason")
        #expect(!rig.appRouting.appRoutes.contains { $0.bundleID == "com.excluded.app" }, "the excluded route must never be created")
    }

    // MARK: 4 — a Mac-originated mutation (direct controller call) broadcasts to both clients

    @Test func macOriginatedGroupRenameBroadcastsToBothClients() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let hub = try await makeHub()
        defer { hub.cancel() }

        let (clientA, logA) = try await connectAndWelcome(via: hub, to: rig.server, name: "phoneA")
        defer { clientA.cancel() }
        let (clientB, logB) = try await connectAndWelcome(via: hub, to: rig.server, name: "phoneB")
        defer { clientB.cancel() }

        try rig.groupController.saveGroup(Group(id: "g1", name: "Original Name", memberIDs: ["office"], memberVolumes: [:]))
        for (name, log) in [("A", logA), ("B", logB)] {
            #expect(await waitUntil { log.containsState { $0.groups.contains { $0.id == "g1" && $0.name == "Original Name" } } },
                    "client \(name) never saw the group's creation")
        }

        // The Mac's own UI (popover/mixer window) calls straight into
        // GroupController — never through the dispatcher/command path. This
        // must still reach both phones.
        try rig.groupController.saveGroup(Group(id: "g1", name: "Renamed", memberIDs: ["office"], memberVolumes: [:]))

        for (name, log) in [("A", logA), ("B", logB)] {
            #expect(await waitUntil { log.containsState { $0.groups.first(where: { $0.id == "g1" })?.name == "Renamed" } },
                    "client \(name) never received the Mac-originated rename")
        }
    }

    // MARK: 5 — group CRUD round-trip: create via A → both see it; delete → both see it gone + Main Out falls back

    @Test func groupCreateAndDeleteRoundTripWithMainOutFallback() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let hub = try await makeHub()
        defer { hub.cancel() }

        let (clientA, logA) = try await connectAndWelcome(via: hub, to: rig.server, name: "phoneA")
        defer { clientA.cancel() }
        let (clientB, logB) = try await connectAndWelcome(via: hub, to: rig.server, name: "phoneB")
        defer { clientB.cancel() }

        // Create via client A.
        try sendCommand(.createGroup(name: "Downstairs", memberIDs: ["office"], iconSymbolName: nil), requestID: "c1", over: clientA)
        #expect(await waitUntil {
            logA.contains(.commandResult(requestID: "c1", applied: true, refusalReason: nil, autoSwappedCurrentDevice: false))
        }, "client A's createGroup never completed")
        for (name, log) in [("A", logA), ("B", logB)] {
            #expect(await waitUntil { log.containsState { $0.groups.contains { $0.name == "Downstairs" } } },
                    "client \(name) never saw the created group")
        }
        let groupID = try #require(rig.groupController.groups.first { $0.name == "Downstairs" }?.id)

        // Point Main Out at it directly (Mac-side action) so the delete
        // below has something to fall back from.
        rig.groupController.setMainOut(.group(id: groupID))
        for (name, log) in [("A", logA), ("B", logB)] {
            #expect(await waitUntil { log.containsState { $0.mainOut.kind == "group" && $0.mainOut.groupID == groupID } },
                    "client \(name) never saw Main Out point at the new group")
        }

        // Delete via client B.
        try sendCommand(.deleteGroup(id: groupID), requestID: "d1", over: clientB)
        #expect(await waitUntil {
            logB.contains(.commandResult(requestID: "d1", applied: true, refusalReason: nil, autoSwappedCurrentDevice: false))
        }, "client B's deleteGroup never completed")
        #expect(rig.groupController.mainOut == .selectedDevices, "GroupController itself must fall back off the deleted group")

        for (name, log) in [("A", logA), ("B", logB)] {
            #expect(await waitUntil { log.containsState { !$0.groups.contains { $0.id == groupID } } },
                    "client \(name) never saw the group disappear")
            #expect(await waitUntil { log.containsState { $0.mainOut.kind == "selected" } },
                    "client \(name) never saw Main Out fall back after its target group was deleted")
        }
    }
}

private actor E2ECountBox {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}
