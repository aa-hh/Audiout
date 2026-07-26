// Headless tests for the receiver→sender remote-control stream (speaker-input
// task): the C hook `airplayengine_remote_fire` (shims/engine_bridge.c) → the
// Swift `RemoteEventHub` → `engine.makeRemoteEventStream()`.
//
// SCOPE: BUILD + HEADLESS ONLY. No event loop, no sockets, no "airplay events"
// thread. These call the REAL C fire function directly (the same call
// airplay_events.c / player.c make on a live event) and assert the stream yields
// the correctly mapped `RemoteEvent`. This exercises the genuine FFI + enum
// mapping (`RemoteEventHub.deliver` + `TransportCommand.init(_:)`), not a mock.

import Testing
import Foundation
@testable import AirPlayEngine
import CAirPlayEngine

// `engine.enterHeadlessTestMode()` installs `airplayengine_remote_fire`'s
// hook into a process-global slot (see `shims/engine_bridge.c`) — the same
// class of hazard `SerializedEngineStateSuite.swift` documents for the
// `shims/outputs.c` device registry. Under swift-testing's in-process
// concurrency, two of this suite's tests running at once install/read that
// global hook concurrently, so one test's `airplayengine_remote_fire` call
// can be observed by another test's stream reader (or the hook gets
// clobbered mid-test), which reproduced as an intermittent
// `RemoteEventTestTimeout` under full-suite runs (never in isolation).
// Nesting into the same `.serialized` parent as the outputs.c-registry
// suites removes the collision — reusing the existing parent rather than a
// second one because a separate `.serialized` suite would still race
// against `SerializedEngineState`'s own children, which only a single
// shared parent actually prevents (see that file's siblings T15/T16 for
// where this was first found, for the libgcrypt global-init case).
extension SerializedEngineState {

@Suite struct RemoteEventStreamTests {

    // MARK: - Volume: an inbound device-volume change maps to .volume(id, level).

    @Test func remoteStreamYieldsVolume() async throws {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode() // installs the remote-control hook
        let reader = RemoteEventReader(engine.makeRemoteEventStream())

        airplayengine_remote_fire(0xABCD, AIRPLAYENGINE_REMOTE_VOLUME, 0.75)

        let event = try await reader.next(timeout: 2)
        #expect(event == .volume(OutputID(rawValue: 0xABCD), level: 0.75))

        await engine.stop()
    }

    // MARK: - Volume is clamped into 0...1 (a receiver could report out of range).

    @Test func remoteVolumeIsClamped() async throws {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()
        let reader = RemoteEventReader(engine.makeRemoteEventStream())

        airplayengine_remote_fire(0x1, AIRPLAYENGINE_REMOTE_VOLUME, 1.5)   // over
        airplayengine_remote_fire(0x2, AIRPLAYENGINE_REMOTE_VOLUME, -0.5)  // under

        let over = try await reader.next(timeout: 2)
        let under = try await reader.next(timeout: 2)
        #expect(over == .volume(OutputID(rawValue: 0x1), level: 1.0))
        #expect(under == .volume(OutputID(rawValue: 0x2), level: 0.0))

        await engine.stop()
    }

    // MARK: - Transport: each key maps to the matching .transport(command).

    @Test func remoteStreamYieldsTransport() async throws {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()
        let reader = RemoteEventReader(engine.makeRemoteEventStream())

        airplayengine_remote_fire(0, AIRPLAYENGINE_REMOTE_PLAYPAUSE, -1)
        airplayengine_remote_fire(0, AIRPLAYENGINE_REMOTE_NEXT, -1)
        airplayengine_remote_fire(0, AIRPLAYENGINE_REMOTE_PREVIOUS, -1)

        let playPause = try await reader.next(timeout: 2)
        let next = try await reader.next(timeout: 2)
        let previous = try await reader.next(timeout: 2)
        #expect(playPause == .transport(.playPause))
        #expect(next == .transport(.next))
        #expect(previous == .transport(.previous))

        await engine.stop()
    }

    // MARK: - An UNKNOWN remote event is dropped, not surfaced.
    //
    // Fire UNKNOWN then a known transport; only the known one should arrive, in
    // that order (proving UNKNOWN was swallowed rather than mismapped).
    @Test func unknownRemoteEventIsDropped() async throws {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()
        let reader = RemoteEventReader(engine.makeRemoteEventStream())

        airplayengine_remote_fire(0, AIRPLAYENGINE_REMOTE_UNKNOWN, -1) // dropped
        airplayengine_remote_fire(0, AIRPLAYENGINE_REMOTE_NEXT, -1)    // delivered

        let first = try await reader.next(timeout: 2)
        #expect(first == .transport(.next), "UNKNOWN must be swallowed so .next is first")

        await engine.stop()
    }

    // MARK: - After stop(), the stream finishes and no further events are delivered.

    @Test func streamFinishesOnStop() async throws {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()
        let reader = RemoteEventReader(engine.makeRemoteEventStream())

        await engine.stop() // uninstalls the hook + finishes live streams

        // A fire after teardown reaches no hub (shared cleared) — nothing delivered.
        airplayengine_remote_fire(0, AIRPLAYENGINE_REMOTE_PLAYPAUSE, -1)
        await #expect(throws: (any Error).self) {
            try await reader.next(timeout: 1)
        }
    }
}

} // extension SerializedEngineState

/// Drains an `AsyncStream<RemoteEvent>` into a locked FIFO on a background task
/// and exposes a timeout-guarded `next()` — the remote-event twin of
/// `StateStreamTests`' `StreamReader`.
private final class RemoteEventReader: @unchecked Sendable {
    private let task: Task<Void, Never>
    private let sink: Sink

    init(_ stream: AsyncStream<RemoteEvent>) {
        let sink = Sink()
        self.sink = sink
        self.task = Task { for await event in stream { sink.append(event) } }
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [RemoteEvent] = []
        func append(_ e: RemoteEvent) { lock.lock(); items.append(e); lock.unlock() }
        func popFirst() -> RemoteEvent? {
            lock.lock(); defer { lock.unlock() }
            return items.isEmpty ? nil : items.removeFirst()
        }
    }

    func next(timeout seconds: Double) async throws -> RemoteEvent {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let element = sink.popFirst() { return element }
            try await Task.sleep(nanoseconds: 2_000_000) // 2ms
        }
        throw RemoteEventTestTimeout()
    }

    deinit { task.cancel() }
}

private struct RemoteEventTestTimeout: Error {}
