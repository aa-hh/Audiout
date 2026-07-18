import Foundation

/// Thin async/await wrapper over the OwnTone JSON API (`:3689`).
///
/// Every claim encoded here is grounded in `dev/notes/p1-owntone-api-brief.md`,
/// which was live-verified against OwnTone 29.2. The brief's "don't assume"
/// list drives several non-obvious choices:
///
/// - `output.id` is a JSON **string**, not an `Int` — decoded and round-tripped
///   as `String` (brief §1, footgun #1).
/// - Mutating endpoints are **not** uniformly `204`: `queue/items/add` is
///   `200`+JSON (brief §2). We therefore only assert "2xx", never "204".
/// - Error bodies are **HTML, never JSON** — we never decode a non-2xx body,
///   we branch on the status code alone (brief §5).
/// - Volume out-of-range is a hard `400`, not clamped server-side — callers
///   clamp with `Int.clampedToVolume` before calling `setVolume` (brief §1).
///
/// This is an *internal* type: the public backend seam (`OwnToneBackend`, and
/// the neutral rename in T-C4) hides it. Only network/JSON plumbing lives here;
/// no polling, diffing, or event emission (that's the backend's job).
struct OwnToneClient: @unchecked Sendable {

    /// A network- or protocol-level failure talking to OwnTone. Deliberately
    /// coarse: the UI only needs to distinguish "engine not reachable" (so it
    /// can back off and show an unavailable state, per Q7 connect-only) from
    /// "the server answered but unhappily."
    enum ClientError: Error, Equatable {
        /// `URLError.cannotConnectToHost` / `.timedOut` / `.networkConnectionLost`
        /// — OwnTone is down or unreachable. Per Q7 the backend surfaces this as
        /// an "unavailable" state and keeps polling at a backed-off interval;
        /// it NEVER tries to start/supervise the server.
        case unreachable
        /// A non-2xx HTTP status. Body is HTML (brief §5) so it is discarded —
        /// only the code is carried. `player/play` on an empty queue is the
        /// canonical `500` (brief §2/§5); an out-of-range volume is `400`.
        case http(status: Int)
        /// A 2xx response whose body we expected to decode but couldn't.
        case decoding
    }

    /// Player state from `GET /api/player` (brief §2). Only the fields the
    /// backend diffs on are modelled; unknown keys are ignored by `Codable`.
    struct PlayerState: Decodable, Equatable {
        /// `"play"` / `"pause"` / `"stop"`.
        let state: String
        /// Master volume, 0–100.
        let volume: Int
    }

    private let baseURL: URL
    private let session: URLSession

    /// - Parameters:
    ///   - host/port: the OwnTone JSON API endpoint (default `localhost:3689`).
    ///   - session: injectable so unit tests can stub `URLProtocol` without a
    ///     live server (see the tests) — the whole point of keeping this a
    ///     plain `struct` over an injected `URLSession`.
    ///   - timeout: per-request timeout. The brief recommends 5 s (§5) so a hung
    ///     connection surfaces promptly instead of blocking the poll loop.
    init(host: String = "localhost", port: Int = 3689, session: URLSession? = nil, timeout: TimeInterval = 5) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Reads

    /// `GET /api/config` — the `start()` health-check (brief §5). Returning
    /// normally means OwnTone answered; throwing `.unreachable` means it's down.
    /// We don't consume the body, so we only care that it's a 2xx.
    func healthCheck() async throws {
        _ = try await requestData(method: "GET", path: "/api/config")
    }

    /// `GET /api/outputs` — the primary poll read (brief §1). Returns the raw
    /// output objects; mapping to `Device` is the backend's concern.
    func outputs() async throws -> [OwnToneOutput] {
        let data = try await requestData(method: "GET", path: "/api/outputs")
        do {
            return try JSONDecoder().decode(OutputsEnvelope.self, from: data).outputs
        } catch {
            throw ClientError.decoding
        }
    }

    /// `GET /api/player` — the second poll read (brief §2/§4). Needed alongside
    /// outputs so zombie detection can see "player says play but a selected
    /// output silently dropped."
    func player() async throws -> PlayerState {
        let data = try await requestData(method: "GET", path: "/api/player")
        do {
            return try JSONDecoder().decode(PlayerState.self, from: data)
        } catch {
            throw ClientError.decoding
        }
    }

    // MARK: Output control

    /// `PUT /api/outputs/set` `{"outputs":[ids]}` (brief §1). Replaces the whole
    /// selected set. Returns `204`, but the brief's #2 warning applies: a `204`
    /// does NOT prove the selection stuck — the backend must re-GET and confirm.
    func setOutputSet(_ ids: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["outputs": ids])
        _ = try await requestData(method: "PUT", path: "/api/outputs/set", body: body)
    }

    /// `PUT /api/outputs/{id}` `{"volume":0-100}` (brief §1). Callers must clamp
    /// to 0–100 first — OwnTone rejects out-of-range with `400`, it does not
    /// clamp (brief §1, don't-assume #6).
    func setVolume(_ volume: Int, for id: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["volume": volume])
        _ = try await requestData(method: "PUT", path: "/api/outputs/\(id)", body: body)
    }

    // MARK: Playback (queue → play). Used by T-C2's coordinator; lives here so
    // the HTTP surface stays in one place and is testable in isolation.

    /// `PUT /api/queue/clear` — `204` (brief §2).
    func clearQueue() async throws {
        _ = try await requestData(method: "PUT", path: "/api/queue/clear")
    }

    /// `POST /api/queue/items/add?uris=<uri>` — **200 + JSON** (brief §2,
    /// don't-assume #3). We don't consume the returned queue-item body.
    func addToQueue(uri: String) async throws {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "uris", value: uri)]
        let query = components.percentEncodedQuery ?? ""
        _ = try await requestData(method: "POST", path: "/api/queue/items/add?\(query)")
    }

    /// `PUT /api/player/play` — `204`, or **500 on an empty queue** (brief §2/§5,
    /// don't-assume #4). Callers must have just added an item; the empty-queue
    /// guard lives in the backend, which surfaces the `500` as `.http(500)`.
    func play() async throws {
        _ = try await requestData(method: "PUT", path: "/api/player/play")
    }

    /// `PUT /api/player/stop` — `204` (brief §2). Teardown.
    func stop() async throws {
        _ = try await requestData(method: "PUT", path: "/api/player/stop")
    }

    /// `PUT /api/update` — trigger a library rescan, `204` (brief §2).
    func updateLibrary() async throws {
        _ = try await requestData(method: "PUT", path: "/api/update")
    }

    /// `GET /api/search?expression=data_kind is pipe&type=tracks` (brief §2).
    /// Returns the pipe track's `library:track:N` URI, or `nil` if the FIFO
    /// hasn't been scanned yet (`total == 0` → caller issues `updateLibrary()`
    /// and retries). The robust, filename-independent way to find the pipe.
    func findPipeTrackURI() async throws -> String? {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "expression", value: "data_kind is pipe"),
            URLQueryItem(name: "type", value: "tracks"),
        ]
        let query = components.percentEncodedQuery ?? ""
        let data = try await requestData(method: "GET", path: "/api/search?\(query)")
        do {
            let result = try JSONDecoder().decode(SearchEnvelope.self, from: data)
            return result.tracks?.items.first?.uri
        } catch {
            throw ClientError.decoding
        }
    }

    // MARK: Core request

    /// One request path for everything. Maps `URLError` connection failures to
    /// `.unreachable` and any non-2xx to `.http(status:)` **without touching the
    /// body** (it's HTML, brief §5). Returns the raw 2xx body for callers that
    /// decode it; callers that don't just ignore it.
    private func requestData(method: String, path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponentPreservingQuery(path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut,
                 .networkConnectionLost, .notConnectedToInternet:
                throw ClientError.unreachable
            default:
                throw ClientError.unreachable
            }
        }

        guard let http = response as? HTTPURLResponse else { throw ClientError.unreachable }
        guard (200...299).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode)
        }
        return data
    }
}

// MARK: - Wire types

/// One entry of `GET /api/outputs` (brief §1). `id` is a **string** (footgun #1)
/// and `type` is `"AirPlay 1"`/`"AirPlay 2"` — never bare `"AirPlay"` — so the
/// backend prefix-matches (don't-assume #5).
struct OwnToneOutput: Decodable, Equatable {
    let id: String
    let name: String
    let type: String
    let selected: Bool
    let volume: Int

    /// Raw auth flags. Optional so an OwnTone version that omits any of them
    /// still decodes; the backend only consumes the OR of all three (below)
    /// for `DiagnosisContext.requiresAuth`
    /// (`dev/notes/p1-connection-status-brief.md` §3).
    let hasPassword: Bool?
    let requiresAuth: Bool?
    let needsAuthKey: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, type, selected, volume
        case hasPassword = "has_password"
        case requiresAuth = "requires_auth"
        case needsAuthKey = "needs_auth_key"
    }

    /// `has_password || requires_auth || needs_auth_key` — "this speaker wants
    /// credentials/pairing we don't support" for diagnosis purposes.
    var requiresAnyAuth: Bool {
        (hasPassword ?? false) || (requiresAuth ?? false) || (needsAuthKey ?? false)
    }
}

private struct OutputsEnvelope: Decodable {
    let outputs: [OwnToneOutput]
}

private struct SearchEnvelope: Decodable {
    struct Tracks: Decodable {
        struct Item: Decodable { let uri: String }
        let items: [Item]
    }
    let tracks: Tracks?
}

private extension URL {
    /// `appendingPathComponent` percent-encodes `?`/`&`, which would corrupt the
    /// query strings we build inline (e.g. `/api/search?expression=...`). This
    /// splits a pre-formed `path?query` and reattaches the query verbatim.
    func appendingPathComponentPreservingQuery(_ pathAndQuery: String) -> URL {
        guard let questionMark = pathAndQuery.firstIndex(of: "?") else {
            return appendingPathComponent(pathAndQuery)
        }
        let path = String(pathAndQuery[..<questionMark])
        let query = String(pathAndQuery[pathAndQuery.index(after: questionMark)...])
        var url = appendingPathComponent(path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        url = components.url ?? url
        return url
    }
}
