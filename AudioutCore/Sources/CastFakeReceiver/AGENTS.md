# CastFakeReceiver

## Purpose

A Cast receiver faked well enough to drive the whole Phase-0 loop offline:
CONNECT, heartbeat, LAUNCH, LOAD, fetch the stream, play, pause, stop. It exists
so `CastSender` is exercised end to end before any hardware arrives — framing,
virtual connections and `requestId` routing all break here first.

It is not an emulator: no Bonjour advertising, no DeviceAuth, no app registry,
no decoding. "Playback" means fetching some of the stream and then declaring
itself PLAYING. `onFetchComplete` hands back the first 44 bytes and a byte
count as evidence the audio server really served WAV — never audio to play.

## Rules

- **LICENSE-CLEAN.** Like `CastSender`: no code from GPL/copyleft sources.
- **macOS 15+.** `SecPKCS12Import` with `kSecImportToMemoryOnly` is what keeps
  the throwaway identity out of the login keychain, and that option is macOS 15.
  Tests gate per-test with `guard #available` — swift-testing rejects
  `@available` on `@Suite` and `@Test`.
- **Loopback-only listener.** Binding anything wider is what trips the
  Application Firewall prompt on a test run.
- **One session at a time.** A single in-flight fetch connection is tracked, so
  a second concurrent LOAD clobbers the first. Fine for a spike; do not build a
  multi-sender test on it.
- **No owner but the caller** — callbacks are `weak self` and there is no
  `deinit`, so a dropped receiver just stops answering. Hold it strongly and
  call `stop()`.
- **The embedded identity is a throwaway,** self-signed, passphrase `fake`. Dev
  and test only; it secures nothing and must never reach the shipping app.

## Map

| Type | What it is |
|---|---|
| `FakeCastIdentity` | The embedded throwaway TLS identity. |
| `FakeCastReceiver` | Loopback TLS listener answering the Cast handshake. |
