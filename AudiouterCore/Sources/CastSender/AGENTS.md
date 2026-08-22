# CastSender

## Purpose

Hand-rolled Google Cast (CASTV2) sender: browse, hold the TLS control
connection, launch the Default Media Receiver, serve it live audio. No UI, no
routing, no app concepts. **Not linked by the app;** Phase 1 wires it into
`NativeBackend`. Today only `cast-spike` calls it.

## Rules

- **A receiver never accepts pushed audio** — it is handed a URL and pulls. The
  media namespace carries LOAD/PLAY/PAUSE/STOP and status only; audio leaves
  through `CastLiveAudioServer` as an endless chunked WAV response.
- **LICENSE-CLEAN.** Never copy from stream2chromecast, browser-castv2-client,
  VLC or any GPL/copyleft source; every file carries the clean-room banner.
- **Zero dependencies** — Foundation, Network, Security. Protobuf is hand-rolled
  by decision 4 of `dev/notes/006-cast-output-scope-2026-08-22.md`: seven fields,
  cheaper than a codegen toolchain.
- **`NSBonjourServices` must gain `_googlecast._tcp`** before a bundled app can
  browse. The unbundled CLI needs no entry, so a browse that works there and
  finds nothing in the app is this, not `CastBrowser`.
- **Cross-queue reads use `stateLock`, never `queue.sync`** — callers read them
  from completions already on that queue, where a sync getter deadlocks.
- **Nothing owns a `CastSpikeRun` but its caller** — hold it strongly, because
  its callbacks are `weak self` and a dropped run stops silently. Its log lines
  are prefixed `+%.3fs ` from creation; keep new events in that shape.

## Map

| Type | What it is |
|---|---|
| `CastBrowser` | Bonjour browse of `_googlecast._tcp`. |
| `CastDeviceRecord` | One receiver's TXT record. |
| `CastChannel` | TLS control connection, framing, heartbeat. |
| `CastClient` | Receiver/media namespace verbs. |
| `CastMessage` | Hand-rolled CASTV2 protobuf codec. |
| `CastFrameReader` | Reassembles length-prefixed frames. |
| `CastLiveAudioServer` | Serves the endless chunked WAV. |
| `CastPCMSource` | Audio seam; `SineSource` is the tone. |
| `CastSpikeRun` | The whole Phase-0 measurement. |
