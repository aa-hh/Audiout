import Foundation

/// Placeholder for the real backend: Bonjour discovery (`_raop._tcp` /
/// `_airplay._tcp`) + the OwnTone JSON API (`PUT /api/outputs/{id}` for volume,
/// output-set selection) driving the AirPlay-2 sender.
///
/// It exists now only to prove the seam: the app depends on ``OutputBackend``,
/// never on a concrete type, so switching from mock to real is a one-line change
/// (`makeBackend()` below). Every method is intentionally unimplemented — wiring
/// it up is Phase 0d/0f → Phase 1 work, once real speakers are in the room.
public final class OwnToneBackend: OutputBackend {

    public init() {}

    public var devices: [Device] { [] }

    public func makeEventStream() -> AsyncStream<BackendEvent> {
        AsyncStream { $0.finish() }
    }

    public func start() { unimplemented() }
    public func stop() {}
    public func setVolume(_ volume: Int, for id: String) { unimplemented() }
    public func setMuted(_ muted: Bool, for id: String) { unimplemented() }
    public func setSoloed(_ soloed: Bool, for id: String) { unimplemented() }
    public func setOutputSet(_ ids: Set<String>) { unimplemented() }

    private func unimplemented(_ function: StaticString = #function) {
        assertionFailure("OwnToneBackend.\(function) not implemented yet — use MockBackend for offline work.")
    }
}

/// Which backend the app talks to. Flip this (or drive it from a launch
/// argument / hidden setting) to develop against fabricated devices vs. real
/// hardware without touching any UI code.
public enum BackendKind {
    case mock
    case ownTone
}

/// The one place that knows about concrete backend types. Everything else in
/// the app holds an ``OutputBackend``.
public func makeBackend(_ kind: BackendKind = .mock) -> OutputBackend {
    switch kind {
    case .mock:    return MockBackend()
    case .ownTone: return OwnToneBackend()
    }
}
