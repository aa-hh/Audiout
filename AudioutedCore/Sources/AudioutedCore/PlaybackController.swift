import Foundation

/// The subset of OwnTone's JSON API the ``CaptureCoordinator`` drives to realise
/// the **explicit-play invariant** (0f-pipe-brief.md:69-75, brief §2): after the
/// FIFO has data, playback is started explicitly with
/// `queue/clear → queue/items/add?uris=library:track:{id} → player/play`; on
/// teardown, `player/stop`. Autostart is NEVER relied upon.
///
/// Extracted as a protocol purely so the coordinator's state machine is
/// unit-testable without a live OwnTone: tests inject a fake that records the
/// call sequence and can be scripted to fail (empty-queue 500, unreachable, pipe
/// not-yet-scanned). `OwnToneClient` conforms in an extension below, so the real
/// path uses the exact same HTTP surface T-C1 already built and tested.
protocol PlaybackController: Sendable {
    /// `GET /api/config` health-check. Throws `OwnToneClient.ClientError.unreachable`
    /// if OwnTone is down (Q7: connect-only — the coordinator surfaces it, never
    /// launches the server).
    func healthCheck() async throws

    /// `PUT /api/update` — trigger a library rescan so a freshly-`mkfifo`'d pipe
    /// gets indexed (brief §2). `204`, instant.
    func updateLibrary() async throws

    /// `GET /api/search?expression=data_kind is pipe` — the robust,
    /// filename-independent way to find the pipe track's `library:track:N` URI
    /// (brief §2). `nil` means the FIFO hasn't been scanned yet → caller issues
    /// `updateLibrary()` and retries.
    func findPipeTrackURI() async throws -> String?

    /// `PUT /api/queue/clear` (brief §2). Step 1 of the explicit sequence.
    func clearQueue() async throws

    /// `POST /api/queue/items/add?uris=<uri>` (brief §2). Step 2. Must precede
    /// `play()` or `play()` 500s on an empty queue (brief don't-assume #4).
    func addToQueue(uri: String) async throws

    /// `PUT /api/player/play` (brief §2). Step 3. **Hard 500 on an empty queue** —
    /// only ever called after `addToQueue`.
    func play() async throws

    /// `PUT /api/player/stop` (brief §2). Teardown — the paused pipe session must
    /// be explicitly stopped or it wedges the next activation (0f-pipe-brief.md:19-20).
    func stop() async throws
}

/// `OwnToneClient` (T-C1's HTTP client) already implements every method the
/// coordinator needs, one-for-one. This makes the real playback path go through
/// exactly that already-tested surface.
extension OwnToneClient: PlaybackController {}
