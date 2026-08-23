# CastSender

## Purpose

Hand-rolled Google Cast (CASTV2) sender: browse, hold the TLS control
connection, launch the Default Media Receiver, serve it live audio. No UI, no
routing, no app concepts. Callers: `CastDeviceEnumerator`/`CastOutputManager`
(AudiouterCore), `CastFakeReceiver`, `cast-spike`.

## Rules

- **A receiver never accepts pushed audio** — it is handed a URL and pulls. The
  media namespace carries LOAD/PLAY/PAUSE/STOP and status only; audio leaves
  through `CastLiveAudioServer` as an endless chunked WAV response.
- **LICENSE-CLEAN.** Never copy from stream2chromecast, browser-castv2-client,
  VLC or any copyleft source; every file carries the clean-room banner.
- **Zero dependencies** — Foundation, Network, Security. Protobuf is hand-rolled
  by decision 4 of `dev/notes/006-cast-output-scope-2026-08-22.md`: seven
  fields, cheaper than codegen.
- **`NSBonjourServices` carries `_googlecast._tcp`** (`scripts/make-app.sh`
  enforces it) — no bundled app can browse otherwise. A browse
  that works in the CLI but finds nothing in the app is this, not `CastBrowser`.
- **Cross-queue reads take a lock, never `queue.sync`** — `stateLock` in
  `CastChannel`, `portLock` in `CastLiveAudioServer`: callers read them from
  completions already on that queue, where a sync getter deadlocks.
- **Nothing owns a `CastSpikeRun` but its caller** — hold it strongly, because
  its callbacks are `weak self` and a dropped run stops silently. Its log lines
  are prefixed `+%.3fs `; keep new events in that shape.

## Map

| Type | What it is |
|---|---|
| `CastBrowser` | Bonjour browse of `_googlecast._tcp`; recreates itself with backoff after `.failed`. |
| `CastDeviceRecord` | One receiver's TXT record. |
| `CastChannel` | TLS control connection, framing, heartbeat. |
| `CastClient` | Receiver/media verbs; replies `CastApplication`/`CastReceiverStatus`/`CastMediaStatus`. |
| `CastMessage` | Hand-rolled CASTV2 protobuf codec, with `CastNamespace`, `CastIDs`, `CastError`. |
| `CastFrameReader` | Reassembles length-prefixed frames. |
| `CastLiveAudioServer` | Serves the endless chunked WAV. |
| `CastPCMSource` | Audio seam; `SineSource` is the tone. |
| `CastSpikeRun` | The Phase-0 measurement. |
