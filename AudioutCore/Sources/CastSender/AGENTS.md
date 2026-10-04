# CastSender

## Purpose

Hand-rolled Google Cast (CASTV2) sender: browse, hold the TLS control
connection, launch the Default Media Receiver, serve it live audio. No UI, no
routing, no app concepts. Callers: `CastDeviceEnumerator`/`CastOutputManager`
(AudioutCore), `CastFakeReceiver`, `cast-spike`.

## Rules

- **The Default Media Receiver never accepts pushed audio** — it is handed a
  URL and pulls. Its media namespace carries LOAD/PLAY/PAUSE/STOP and status
  only; audio leaves through `CastLiveAudioServer` as an endless chunked WAV.
- **LICENSE-CLEAN.** Never copy from stream2chromecast, browser-castv2-client,
  VLC or any copyleft source; every file carries the clean-room banner.
- **Foundation, Network, Security, plus AudioToolbox (Opus encoder) and
  CommonCrypto (AES-CTR) in the streaming files only.**
- **The first Sender Report goes out before the first RTP packet;** a receiver
  drops packet 0 of every frame until it has one.
- Long-form traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

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
| `CastMirrorSpikeRun` | The Cast Streaming (mirroring) measurement. |
| `CastStreamingSession` | One Opus RTP stream: Sender Reports, feedback, resends. |
| `CastStreamingOffer` | OFFER builder; `CastStreamingAnswer` parses the reply. |
| `CastFrameCrypto` | Per-frame AES-128-CTR. |
| `CastOpusEncoder` | AudioToolbox Opus, one packet per frame. |
| `CastRTPPacket` / `CastSenderReport` / `CastReceiverFeedback` | Wire codecs for Cast Streaming. |
