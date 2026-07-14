# P1 — OwnTone JSON+websocket integration brief (T-R2)

Research brief for the real-backend tasks **T-C1 / T-C2**. Transcribe from this;
do not re-derive. Every claim below with a `curl`/log line next to it was run
live against the actual running server (`dev/owntone/`, OwnTone **29.2**,
`GET /api/config` → `"version": "29.2"`, `"websocket_port": 3688`) on
2026-07-13, listening at `http://localhost:3689` — NOT copied from docs alone.
Doc sources cross-checked, both identical:

- Local: `dev/owntone/install/usr/share/doc/owntone/docs/json-api.md`
- Official: https://owntone.github.io/owntone-server/json-api/

Also grounded in `dev/notes/0f-pipe-brief.md` (the pipe-input invariants — config-
follows-tap, explicit queue→play, suspend-to-pause, zombie de-select) and
`PLAN-0e-0f.md` (Q7 connect-only). RESOLVED DECISIONS in `PLAN-PHASE-1.md`
(Q4 mute/solo, Q7 connect-only-never-supervise) are load-bearing for §4/§5 below.

---

## 1. Outputs: list / select / volume

### `GET /api/outputs`

```shell
curl -X GET "http://localhost:3689/api/outputs"
```

Live response (this server, 3 outputs registered — one AirPlay-2 TV, one
AirPlay-2 loopback-ish "MacBook Air (7)", one AirPlay-1 fake receiver
currently NOT running):

```json
{ "outputs": [
  { "id": "151895285848972", "name": "[LG] webOS TV UR78006LK", "type": "AirPlay 2",
    "selected": false, "has_password": false, "requires_auth": false,
    "needs_auth_key": false, "volume": 50, "offset_ms": 0, "format": "alac",
    "supported_formats": ["alac"] },
  { "id": "257994599294063", "name": "MacBook Air (7)", "type": "AirPlay 2",
    "selected": false, "has_password": false, "requires_auth": false,
    "needs_auth_key": false, "volume": 50, "offset_ms": 0, "format": "alac",
    "supported_formats": ["alac"] },
  { "id": "144408875765259", "name": "Verify Receiver", "type": "AirPlay 1",
    "selected": false, "has_password": false, "requires_auth": false,
    "needs_auth_key": false, "volume": 70, "offset_ms": 0, "format": "alac",
    "supported_formats": ["alac"] }
] }
```

**`output` object fields** (confirmed byte-for-byte against both doc copies AND
this response):

| Key | Type | Notes for T-C1's `Device` mapping |
| --- | --- | --- |
| `id` | **string** | Numeric-looking but IS a JSON string (`"151895285848972"`) — do NOT decode as `Int` in Swift `Codable`, keep `String`. This is the #1 footgun: `output.id` must round-trip byte-identical into `outputs/set` and `outputs/{id}`. |
| `name` | string | Display name → `Device.name`. |
| `type` | string | Observed values: `"AirPlay 2"`, `"AirPlay 1"` (NOT bare `"AirPlay"` — the doc's own table says `AirPlay`/`Chromecast`/`ALSA`/`Pulseaudio`/`fifo` but the LIVE server emits the AirPlay variant with a version suffix). **T-C1 must match on `hasPrefix("AirPlay")`, not `== "AirPlay"`**, for the kind heuristic (PLAN-PHASE-1.md T-C1). |
| `selected` | boolean | Maps to `Device.isSelected`. THE zombie-detection field — see §4. |
| `has_password` / `requires_auth` / `needs_auth_key` | boolean | Not consumed by T-C1's mapping today; PIN/auth flows are out of scope for Phase 1 (no such devices in the test fleet). |
| `volume` | integer 0–100 | Maps to `Device.volume`. No mute/solo field exists — confirmed absent from the object; Q4's app-side volume-based mute/solo is the only option, not a gap in this brief. |
| `offset_ms` | integer | Playback offset, unused by T-C1. |
| `format` / `supported_formats` | string / array | Observed `"alac"` for both AirPlay outputs on this server (not `"pcm"` — that's the `fifo`-type INPUT's format per the doc example, a different object). Not consumed by Device mapping. |

`GET /api/outputs/{id}` (single) returns the same object shape, 200 OK.

### `PUT /api/outputs/set` — select the active output set

```shell
curl -X PUT "http://localhost:3689/api/outputs/set" \
     -H 'Content-Type: application/json' \
     -d '{"outputs":["144408875765259"]}'
```

Live: **HTTP 204**, empty body. Body is `{"outputs":[<string ids>]}` — replaces
the entire selected set (enables listed ids, disables everything else). Confirmed
`{"outputs":[]}` (empty array) deselects everything, also 204.

**Important caveat found live, not in either doc**: `PUT /api/outputs/set` returns
204 (success) EVEN WHEN the target output's underlying transport is dead. Selecting
"Verify Receiver" (a registered-but-not-currently-running fake shairport instance)
returned 204, but a subsequent `GET /api/outputs` showed `"selected": false` — the
selection did not stick, and the server log (`dev/owntone/log/owntone.log`)
recorded:
```
raop: No response from 'Verify Receiver' (192.168.1.183) to OPTIONS request
player: The AirPlay 1 device 'Verify Receiver' failed to activate
```
**API success (204) is not proof the output was actually selected** — T-C1 MUST
re-`GET /api/outputs` after any `outputs/set` call and verify `selected` actually
flipped, not just trust the 204. This is the same class of issue as the
0f-pipe-brief.md zombie note, but observed here at *selection* time, not just
mid-playback.

### `PUT /api/outputs/{id}` — per-output volume (and/or selected)

```shell
curl -X PUT 'http://localhost:3689/api/outputs/144408875765259' \
     -H 'Content-Type: application/json' -d '{"volume": 42}'
```

Live: **HTTP 204**. Follow-up `GET /api/outputs/144408875765259` confirmed
`"volume": 42` immediately. Body also optionally accepts `"selected": true|false`
in the same PUT (per-output toggle, alternative to the bulk `outputs/set`); not
exercised live in this session but documented identically in both doc copies.
Scale is 0–100 (matches 0f-pipe-brief.md's dB-mapping finding: 0–100 linear onto
approximately −30…0 dB at the AirPlay device).

**Volume out-of-range is a hard 400**, not clamped — verified live:
```shell
curl -X PUT 'http://localhost:3689/api/outputs/144408875765259' -d '{"volume":200}'
# → HTTP 400, HTML body (see §5)
```
Server log: `player: Volume (200) for player_volume_setabs_speaker is out of range`.
**T-C1 must clamp client-side (`Int.clampedToVolume`, already exists per
`Device.swift:88`) before sending — OwnTone will reject, not clamp, an
out-of-range value.**

There is also `PUT /api/player/volume?volume=N&output_id=ID` (master volume, or
a specific output's volume via the player endpoint instead of `/api/outputs/{id}`)
— documented, not separately re-verified live since `/api/outputs/{id}` already
covers T-C1's need; note its existence in case T-C2's master-volume plumbing wants
the single master-volume form (`PUT /api/player/volume?volume=N`, no `output_id`).

---

## 2. Queue / player control for the pipe item

Recipe from 0f-pipe-brief.md, re-verified live this session, exact and unchanged:

```shell
curl -X PUT  'http://localhost:3689/api/queue/clear'                                    # 204
curl -X POST 'http://localhost:3689/api/queue/items/add?uris=library:track:2'           # 200 + queue-item JSON body (NOT 204 — see below)
curl -X PUT  'http://localhost:3689/api/player/play'                                     # 204 (or 500 — see §5)
```

**Correction to 0f-pipe-brief.md's implied response codes**: `queue/clear` and
`player/play`/`player/stop` are 204/empty as documented, but
`POST /api/queue/items/add` returns **200 OK with a JSON body** (the added queue
item), not 204. Live:
```json
{ "version": 53, "count": 1, "items": [ { "id": 20, "position": 0, "track_id": 2,
  "title": "spike.fifo", "...": "...", "data_kind": "pipe",
  "path": ".../dev/owntone/media/spike.fifo", "uri": "library:track:2",
  "type": "wav", "bitrate": 0, "samplerate": 0, "channels": 0 } ] }
```
T-C1/T-C2's HTTP client must not assume every mutating call is 204 — check per
endpoint, don't hardcode "any 2xx with empty body."

`queue/items/add` also supports `clear=true&playback=start` as a one-shot
combined form (documented, not exercised live — the brief keeps the explicit
3-step sequence since 0f-pipe-brief.md's autostart-noop caveat below argues for
being explicit anyway).

### `GET /api/player`

```shell
curl -X GET "http://localhost:3689/api/player"
```
Live: `{ "state": "stop", "repeat": "off", "consume": false, "shuffle": false, "volume": 70, "item_id": 0, "item_length_ms": 0, "item_progress_ms": 0 }`
Fields match doc exactly: `state` ∈ `play`/`pause`/`stop`, `repeat`, `consume`,
`shuffle`, `volume` (master, 0–100), `item_id`, `item_length_ms`,
`item_progress_ms`. When something is queued/playing, an additional
`artwork_url` key appears (observed `".../artwork/nowplaying"` — optional, not
schema-guaranteed, don't rely on its presence).

**Autostart-noop invariant (from 0f-pipe-brief.md, still true)**: if the pipe
track is already the current queue item (e.g. left over from a prior run, still
`pause`d from EOF-suspend), a bare `player/play` with nothing newly queued can
no-op. **T-C2 must always run the explicit `queue/clear` →
`queue/items/add?uris=library:track:{id}` → `player/play` sequence**, never rely
on the pipe's own autostart-on-write behavior, exactly as 0f-pipe-brief.md
concluded.

### Finding the pipe's track id after a rescan

The pipe's numeric queue-add id (`library:track:N`) is **not guaranteed stable**
across a library rescan/OwnTone restart — 0f-pipe-brief.md observed it as
`library:track:2` but a fresh library could assign any id. **Recipe, verified
live both ways:**

```shell
# (a) free-text search — works, but matches on filename substring:
curl -G "http://localhost:3689/api/search" \
     --data-urlencode "type=track" --data-urlencode "query=spike" --data-urlencode "limit=5"

# (b) query-language search on data_kind — the ROBUST form, recommended for T-C2:
curl -G "http://localhost:3689/api/search" \
     --data-urlencode "expression=data_kind is pipe" --data-urlencode "type=tracks"
```
Both returned, live:
```json
{ "tracks": { "items": [ { "id": 2, "title": "spike.fifo", "...": "...",
  "data_kind": "pipe", "path": ".../dev/owntone/media/spike.fifo",
  "uri": "library:track:2", "...": "..." } ], "total": 1, "offset": 0, "limit": 5 } }
```
**Recommendation: T-C2 should use `expression=data_kind is pipe`**, not a
filename search — it's independent of the FIFO's filename and returns exactly the
one-and-only pipe input regardless of what it's named or how many non-pipe library
items exist. Take `items[0].uri` (the `library:track:N` string) as the id to feed
`queue/items/add?uris=`. If `total == 0`, the FIFO hasn't been scanned yet — issue
`PUT /api/update` (below) and retry (0f-pipe-brief.md: rescan is 204 and
"appeared as a library track within ~2 s," reconfirmed 204/instant this session).

### `PUT /api/update` — trigger rescan

```shell
curl -X PUT "http://localhost:3689/api/update"
```
Live: **HTTP 204**, confirmed instant (server log shows
`Bulk library scan completed in 0 sec` back-to-back with the request in the same
second). No polling loop needed for the rescan itself, but the *search* for the
new track id should still be attempted with a short retry/backoff in case of
FS-event timing skew (0f-pipe-brief.md said "~2 s" in one earlier run).

---

## 3. Websocket on :3688 — notify protocol

### Handshake + subscribe (verified live, three independent client runs)

```shell
curl --include --no-buffer \
     --header "Connection: Upgrade" --header "Upgrade: websocket" \
     --header "Host: localhost:3688" --header "Origin: http://localhost:3688" \
     --header "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
     --header "Sec-WebSocket-Version: 13" \
     --header "Sec-WebSocket-Protocol: notify" \
     http://localhost:3688/
```
Live response headers:
```
HTTP/1.1 101 Switching Protocols
Upgrade: WebSocket
Connection: Upgrade
Sec-WebSocket-Accept: qGEgH3En71di5rrssAZTmtRTyFk=
Sec-WebSocket-Protocol: notify
```
Confirms: standard RFC6455 upgrade, **`Sec-WebSocket-Protocol: notify` is
required** (server echoes it back; this is the subprotocol negotiation, not a
custom header check) — in `URLSessionWebSocketTask` terms, this means dialing with
the `notify` subprotocol via the request's `Sec-WebSocket-Protocol` header (see
Swift snippet below).

After the 101 upgrade, the client sends one text frame to declare interest:
```json
{ "notify": ["player", "outputs", "volume", "queue", "update", "database", "options"] }
```
Verified live via a Python `websockets` client (`subprotocols=["notify"]`,
`ws.subprotocol` negotiated back as `"notify"`) — connect + send succeeded with
no error, no rejection, no ack frame (the server does not echo/ack the
subscription; silence after `send()` is the expected "accepted" state).

### Event kinds

Per both doc copies (identical): `update`, `database`, `outputs`, `player`,
`options`, `volume`, `queue`. Each event message, per docs, is presumed to be a
JSON object of the shape `{"notify": ["<type>", ...]}` — i.e. **the push message
carries only event NAMES, no payload/diff/state** (this brief could not
empirically confirm the exact push-message shape — see below — but the docs are
explicit that consuming a notification means "the server will send a message each
time one of the events occurred," with no documented payload fields beyond the
type array). **Client must always re-`GET` the relevant resource after any
notification** — there is nothing else to parse out of the push frame.

### VERDICT: websocket push did NOT fire in this session — treat as unreliable, poll primarily

This is the most important empirical finding in this brief and **contradicts the
plan's assumption** that push notifications are the primary update path.

**What was tested:** four independent client connections (raw `curl` handshake
sanity check; three separate Python `websockets` scripts, one driven live via the
harness's `Monitor` websocket-watch tool) all connected successfully, correctly
negotiated the `notify` subprotocol, and sent a well-formed subscribe message
covering every documented event type. Across those sessions, **~30 real,
HTTP-200/204-confirmed state-changing API calls were issued while a subscribed
websocket client was actively listening**:
- `PUT /api/outputs/set` (select AND deselect, several times)
- `PUT /api/outputs/{id}` (volume changes, several distinct values)
- `PUT /api/queue/clear`
- `POST /api/queue/items/add`
- `PUT /api/player/play` / `PUT /api/player/stop`
- `PUT /api/update` (library rescan, confirmed "1 changes"/"0 changes" in server log)

**Zero notification frames were received on the websocket in any of the four
runs**, despite every one of those operations being exactly the kind the docs
list as triggering `outputs`/`volume`/`queue`/`player`/`update` events, and
despite server-side confirmation (log lines, follow-up GETs) that the state
genuinely changed. This was cross-checked against a control case (an unsubscribed
websocket connection, and a connection that sent no subscribe message at all) —
behaved identically (silence), which doesn't disambiguate much, but combined with
the *subscribed* runs' total silence, the simplest explanation is that push
notifications are not being delivered by this OwnTone 29.2 build/config, not that
this brief's test methodology missed a step (subprotocol negotiated correctly,
handshake headers correct, message format matches the doc's only given example
verbatim).

Root cause NOT determined (no source tree available locally to inspect the
notify-emission code path; `buildoptions` in `/api/config` does list
`"Websockets"` as present, so it's not a missing-at-build-time feature).
Candidates worth a follow-up spike if push is ever revisited: a libevent/libwebsockets
event-loop quirk under this specific build, a possible requirement for a
`Origin` header value the docs don't mention, or a genuine regression in 29.2.

**Recommendation for T-C1: poll as the PRIMARY update mechanism, not a fallback.**
- Poll `GET /api/outputs` + `GET /api/player` on a fixed interval. **Recommend
  1000 ms** — fast enough that zombie de-selection (§4) and queue/player state
  drift are caught within a UI-imperceptible window, slow enough to be cheap
  against a local server (sub-5ms round-trip observed on every live call in this
  session) and not thrash `URLSession`.
- Still attempt the websocket connection and still consume any notification that
  DOES arrive (if this was an environment fluke, real events would only make
  polling more responsive, never less correct — treat it as a free accelerant,
  not a dependency). On any notification, re-GET immediately rather than waiting
  for the next poll tick, same as the plan assumed.
- Do **not** build T-C1's state-refresh logic to depend on the websocket firing —
  if `BackendEvent` emission is gated solely on notify frames, this session's
  evidence says the UI would silently go stale. Poll drives the emission; the
  websocket is a latency optimization only, never the sole trigger.
- Re-verify this finding early in T-C1 (it's cheap — a few `curl`/websocket
  calls) in case it's a config toggle on this particular `dev/owntone/` instance;
  if a later run DOES show push events firing, downgrade the poll interval
  finding to "poll as fallback at 2–3 s" per the original plan assumption, but
  do not assume that without re-testing — this brief's negative result was
  reproduced 4/4 times.

### Swift `URLSessionWebSocketTask` snippet

```swift
import Foundation

final class OwnToneWebSocketMonitor: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!

    func connect(host: String = "localhost", port: Int = 3688) {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: URL(string: "ws://\(host):\(port)/")!)
        // Subprotocol negotiation — this is what the `Sec-WebSocket-Protocol: notify`
        // header in the curl example corresponds to; URLSessionWebSocketTask negotiates
        // it via this initializer, not a manually-set header (the underlying transport
        // handles the handshake itself).
        task = session.webSocketTask(with: request, protocols: ["notify"])
        task?.resume()
        subscribe()
        receiveLoop()
    }

    private func subscribe() {
        let body = ["notify": ["player", "outputs", "volume", "queue", "update"]]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error { print("subscribe send failed: \(error)") }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            switch result {
            case .success(let message):
                // Per §3 above: the frame carries only event-type names, no payload.
                // Treat receipt of ANY frame as "something changed, re-GET now."
                if case .string(let text) = message {
                    print("notify frame: \(text)")
                }
                self?.onNotification?()  // caller re-GETs /api/outputs + /api/player
            case .failure(let error):
                print("websocket receive failed: \(error) — falling back to poll-only")
                return  // do not reschedule; the poll loop (primary path) continues independently
            }
            self?.receiveLoop()
        }
    }

    var onNotification: (() -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                     didOpenWithProtocol protocol: String?) {
        print("websocket opened, negotiated subprotocol: \(`protocol` ?? "none")")
        // Live-verified: this prints "notify" — confirms the handshake matched
        // the curl example's Sec-WebSocket-Protocol negotiation.
    }
}
```

Poll-primary companion (the actual driver of `BackendEvent` emission per the
verdict above):

```swift
func startPolling(interval: TimeInterval = 1.0) {
    Task {
        while !Task.isCancelled {
            await refreshOutputsAndPlayer()   // GET /api/outputs, GET /api/player, diff, emit events
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}
```

---

## 4. Zombie detection: `outputs[].selected` drops while player says `play`

Reproduced this session (not the exact long-pause scenario from 0f-pipe-brief.md,
but the same failure SIGNATURE, live, from the current server's log while
"Verify Receiver" — a fake AirPlay-1 output whose shairport process was not
actually running):

```
raop: No response from 'Verify Receiver' (192.168.1.183) to OPTIONS request
player: The AirPlay 1 device 'Verify Receiver' failed to activate
```
and, separately, when `player/play` was issued against an EMPTY queue:
```
web: Error starting playback.
web: JSON api request failed with error code 500 (/api/player/play)
```
And in an earlier state, `PUT /api/outputs/set` selecting the same dead output
returned 204 (accepted) but the immediate follow-up `GET /api/outputs` showed
`"selected": false` — **the selection silently failed to take effect**, matching
0f-pipe-brief.md's core warning: **"API success is NOT proof audio/volume reached
a device"** and **"the app must watch `outputs[].selected`, not just player
state."**

### Detection + recovery sequence for T-C1/T-C2

1. **After every `outputs/set` call, re-`GET /api/outputs` and confirm the ids
   you selected actually show `"selected": true`.** Do not trust the 204.
2. **During steady-state polling** (§3's 1 s interval), compare the currently
   expected-selected set (the app's own model / last successful `outputs/set`
   call) against the live `selected` values on each poll tick. If a
   previously-selected output flips to `selected: false` **without the app having
   called `outputs/set` itself**, that's the zombie signature — treat it as a
   silent drop, not a user action.
3. **Cross-check against `GET /api/player`**: 0f-pipe-brief.md's original
   long-pause reproduction showed the player state staying `"play"` while the
   output silently deselected — i.e. **the zombie is detectable specifically as
   "player state play/pause but a previously-selected output is now
   unselected,"** not as any single-endpoint error. T-C1's diff logic needs both
   GETs to catch it; polling only `/api/player` (state-only) would miss it
   entirely, and polling only `/api/outputs` would miss a genuinely-intentional
   stop.
4. **Recovery, per 0f-pipe-brief.md (empirically the only thing that worked
   there)**:
   - Re-issue `PUT /api/outputs/set` with the full intended output set (re-select).
   - Re-run the explicit playback sequence: `queue/clear` →
     `queue/items/add?uris=library:track:{id}` → `player/play` (do not assume
     `player/play` alone resumes a wedged session — 0f-pipe-brief.md found a
     `queue/clear` + play/stop cycle, or in the worst case an OwnTone restart, was
     required to unwedge autostart; T-C2 owns the explicit-sequence side, T-C1
     owns re-selecting the output — they must cooperate, which is why T-C2 depends
     on T-C1).
   - If recovery fails after one retry (re-select + re-play still shows
     `selected: false`), **surface the failure to the UI as a device-level error
     state, do not loop retrying indefinitely** — 0f-pipe-brief.md's dead-session
     case needed a shairport-side restart that OwnTone/the app cannot force (and
     per Q7, must not try to supervise anything OwnTone-adjacent beyond OwnTone
     itself, let alone a third-party AirPlay receiver).
5. **Do not conflate this with the empty-queue 500** (a distinct, immediate,
   synchronous error — see §5) — the zombie case is a *delayed, asynchronous*
   divergence between what the app asked for and what `GET /api/outputs` reports
   on a later poll, discoverable only by diffing.

---

## 5. Error shapes

All verified live this session.

### Non-2xx bodies are HTML, not JSON

Every 4xx/5xx observed returned `Content-Type` HTML (a literal `<html>...`
Bad-Request/Internal-Server-Error page), **never a JSON error body** — T-C1's
error handling must not attempt to `JSONDecode` a non-2xx response.

**400 Bad Request** — observed for: an unknown/malformed output id in the path
(`/api/outputs/999999999999999`), a malformed JSON body (`{not json`), an
unrecognized route (`/api/nonexistent`), and an out-of-range volume (`{"volume":200}`):
```
HTTP/1.1 400 Bad Request
<html><head><title>400 Bad Request</title></head><body><h1>Bad Request</h1></body></html>
```
Matching server log lines (useful for T-V1's diagnostics, not consumed by the
Swift client): `JSON api request failed with error code 400 (/api/outputs/…)`,
`Failed to parse incoming request`, `Unrecognized JSON API request: '/api/nonexistent'`,
`No output found for '/api/outputs/999999999999999'`,
`Volume (200) for player_volume_setabs_speaker is out of range`.

**500 Internal Server Error** — observed for `PUT /api/player/play` when the
queue is empty (reproduced twice, deterministic):
```
HTTP/1.1 500 Internal Server Error
<html><head><title>500 Internal Server Error</title></head><body><h1>Internal Server Error</h1></body></html>
```
Server log: `web: Error starting playback.` /
`web: JSON api request failed with error code 500 (/api/player/play)`.
**T-C2 must never call `player/play` without having just added the pipe item to
the queue in the same sequence** — this isn't hypothetical, it 500s reliably.

### Timeouts

Not separately reproduced (the server was always up and fast — sub-5ms on every
live call in this session), but the client-side contract is unaffected: use a
short, explicit `URLRequest.timeoutInterval` (recommend 5 s, matching this
brief's own `curl -m 5` throughout) so a hung connection surfaces as a
`URLError.timedOut` promptly rather than blocking the poll loop.

### Connection refused (OwnTone down) — verified live

```shell
curl -m 3 "http://localhost:9999/api/config"
# curl: (7) Failed to connect to localhost port 9999 after 0 ms: Couldn't connect to server
```
In Swift, the equivalent is `URLError.Code.cannotConnectToHost` (from
`URLSession`'s `data(for:)`/completion-handler error). **Per RESOLVED Q7
(connect-only, never-supervise): T-C1's posture on connection-refused is to
surface a clear "engine not reachable" `BackendEvent`/state to the UI and STOP —
it must never attempt to launch, restart, or otherwise manage the OwnTone
process.** The existing `dev/owntone/start-owntone.sh` + admin dialog is the
human's tool, not the app's. Practically:
- `start()`'s initial `GET /api/config` health-check (per T-C1's spec in
  PLAN-PHASE-1.md) should catch this immediately at launch and set an
  "unreachable" state rather than silently retrying forever.
- The poll loop (§3) should catch a later disconnect the same way — on
  `cannotConnectToHost`/`timedOut`, transition to "unreachable," keep polling at
  the same interval (cheap, and resumes automatically if OwnTone comes back), but
  do NOT spawn/supervise anything.
- The websocket monitor (§3) should treat a connect failure or an abrupt close
  the same way — attempt reconnect on a backoff, but this is orthogonal to (and,
  per the §3 verdict, not load-bearing for) the poll-driven state refresh.

---

## Summary table — every endpoint T-C1/T-C2 calls

| Method | Path | Body | Live response | Used by |
| --- | --- | --- | --- | --- |
| GET | `/api/config` | — | 200, JSON (`version`, `websocket_port`, …) | T-C1 `start()` health-check |
| GET | `/api/outputs` | — | 200, `{"outputs":[…]}` | T-C1 poll + initial `deviceAdded` |
| GET | `/api/outputs/{id}` | — | 200, single output object | optional single-output refresh |
| PUT | `/api/outputs/set` | `{"outputs":[ids]}` | 204 (re-GET to confirm, §1/§4) | T-C1 `setOutputSet` |
| PUT | `/api/outputs/{id}` | `{"volume":0-100}` and/or `{"selected":bool}` | 204, or 400 if out of range | T-C1 `setVolume` / Q4 mute |
| GET | `/api/player` | — | 200, player-state object | T-C1 poll |
| PUT | `/api/player/play` | — | 204, or 500 if queue empty (§5) | T-C2 explicit-play sequence |
| PUT | `/api/player/pause` | — | 204 | (documented; not separately exercised) |
| PUT | `/api/player/stop` | — | 204 | T-C2 teardown |
| GET | `/api/queue` | — | 200, `{"version","count","items"}` | debugging/verification |
| PUT | `/api/queue/clear` | — | 204 | T-C2 explicit-play sequence |
| POST | `/api/queue/items/add` | query `uris=library:track:N` | **200**, JSON queue-item body (not 204) | T-C2 explicit-play sequence |
| GET | `/api/search` | query `expression=data_kind is pipe&type=tracks` | 200, JSON paging/track object | T-C2 "find pipe id after rescan" |
| PUT | `/api/update` | — | 204, instant | T-C2 rescan-then-search |
| WS | `ws://localhost:3688/` | subprotocol `notify`, then `{"notify":[types]}` | 101 upgrade; **0 push frames observed in 4 live test runs** | T-C1 accelerant only, NOT primary (§3 verdict) |

## What T-C1/T-C2 should NOT assume (corrections to plan-stage assumptions)

1. **Websocket push is not proven reliable on this build** — poll every 1 s as
   the primary state-refresh driver; treat the websocket as best-effort.
2. **`outputs/set` returning 204 does not mean the output is actually selected**
   — always re-GET and diff.
3. **`queue/items/add` is 200+JSON, not 204** — don't assume uniform empty 2xx
   responses across all mutating endpoints.
4. **`player/play` on an empty queue is a hard 500**, not a no-op — never call it
   outside the clear→add→play sequence.
5. **Output `type` is `"AirPlay 1"`/`"AirPlay 2"` on this server, not bare
   `"AirPlay"`** — match with a prefix check.
6. **Volume out-of-range is rejected (400), not clamped** — clamp client-side
   before sending.
7. **All error bodies are HTML, never JSON** — don't try to decode error
   responses as the API's JSON schema.

State left behind: OwnTone still running, player `stop`, no outputs selected,
queue cleared — same idle state as found at task start. "Verify Receiver"'s
volume was left at 20 (changed from 70 during live PUT tests); harmless, it's a
non-running fixture output with no other consumer.
