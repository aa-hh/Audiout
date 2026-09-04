# CastFakeReceiver

## Purpose

A Cast receiver faked well enough to drive the whole offline loop, connect
through stop, so `CastSender` is exercised before hardware arrives. Not an
emulator: no advertising, no device auth, no decoding.

## Rules

- LICENSE-CLEAN, like `CastSender`: no code from copyleft sources.
- The lead is emergent, not a setting; playing is announced before the buffer fills, so early leads climb.
- macOS 15 or newer, because the in-memory identity import option is; tests gate per test, not per suite.
- Loopback-only listener: binding wider is what raises the firewall prompt on a test run.
- One session at a time; a second concurrent load clobbers the first fetch.
- Callbacks are weak and there is no deinit, so hold the receiver strongly and stop it yourself.
- The embedded identity is a self-signed throwaway and must never reach the shipping app.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `FakeCastIdentity` → the embedded throwaway TLS identity.
- `FakeCastReceiver` → loopback TLS listener answering the Cast handshake.
