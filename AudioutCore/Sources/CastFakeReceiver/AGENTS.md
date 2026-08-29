# CastFakeReceiver

## Purpose

A Cast receiver faked well enough to drive the whole Phase-0 loop offline,
CONNECT through STOP. It exists so `CastSender` is exercised end to end before
any hardware arrives — framing, virtual connections and `requestId` routing all
break here first.

It is not an emulator: no Bonjour advertising, no DeviceAuth, no app registry,
no decoding. "Playback" is reading the stream and running a clock against it;
`onFetchComplete` hands back what was fetched as evidence the audio server
really served WAV — never audio to play.

## Rules

- **LICENSE-CLEAN.** Like `CastSender`: no code from GPL/copyleft sources.
- **The lead is emergent, not a setting.** The receiver starts its clock once
  it holds `startupLead` seconds, and the sender paces at exactly real time —
  so that buffer level IS the lead the sender measures, and a stall's cost
  never comes back. **Trap:** PLAYING is announced before the buffer is full,
  so a session's first seconds report a lead still climbing.
- **macOS 15+.** `kSecImportToMemoryOnly` keeps the throwaway identity out of
  the login keychain, and that option is macOS 15. Tests gate per-test with
  `guard #available` — swift-testing rejects `@available` on `@Suite`/`@Test`.
- **Loopback-only listener.** Binding anything wider is what trips the
  Application Firewall prompt on a test run.
- **One session at a time.** One in-flight fetch is tracked, so a second
  concurrent LOAD clobbers the first — do not build a multi-sender test on it.
- **No owner but the caller** — callbacks are `weak self` and there is no
  `deinit`, so a dropped receiver just stops answering. Hold it strongly and
  call `stop()`.
- **The embedded identity is a throwaway**, self-signed, passphrase `fake`: dev
  and test only, and it must never reach the shipping app.

## Map

| Type | What it is |
|---|---|
| `FakeCastIdentity` | The embedded throwaway TLS identity. |
| `FakeCastReceiver` | Loopback TLS listener answering the Cast handshake. |
