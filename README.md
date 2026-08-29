# Audiout

A native AppKit macOS app for sending system audio to several AirPlay 2
speakers at once — per-device volume, mute, saved groups, per-app routing,
and multi-room sync.

## Requirements

- macOS (Apple Silicon), 14.4 or later
- Xcode / Swift toolchain (Swift Package Manager), Swift 5.10+
- [Homebrew](https://brew.sh) — **required for now.** The native AirPlay 2
  sender links several C libraries that the build currently expects to find
  via Homebrew rather than bundling itself (see "Homebrew dependencies"
  below). This is a known limitation, not a permanent design — a future
  build will bundle these libraries into the `.app` so end users won't need
  Homebrew at all.

## Homebrew dependencies

Install Homebrew first if you don't have it:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then install each library the native AirPlay backend needs. You can install
them all in one line (`brew install libevent libsodium libgcrypt libgpg-error libplist ffmpeg`),
but here's what each one is actually for, in case something goes wrong and
you need to know which piece to look at:

1. **libevent** — `brew install libevent`
   The event loop underlying the AirPlay RTSP/event transport (evrtsp).
2. **libsodium** — `brew install libsodium`
   Cryptography for AirPlay 2 device pairing.
3. **libgcrypt** — `brew install libgcrypt`
   Cryptography used by the sender core and pairing alongside libsodium.
4. **libgpg-error** — `brew install libgpg-error`
   A dependency libgcrypt itself needs; installed automatically alongside
   it, but listed here since the build links against it directly too.
5. **libplist** — `brew install libplist`
   Parses/builds the Apple property-list payloads AirPlay's RTSP control
   channel uses.
6. **ffmpeg** — `brew install ffmpeg`
   Provides the ALAC audio encoder (via libavcodec/libavutil/libswresample)
   used to encode PCM audio for the AirPlay 2 stream.

Verify Homebrew can see all of them before building:

```bash
for f in libevent libsodium libgcrypt libgpg-error libplist ffmpeg; do
  brew --prefix "$f" >/dev/null 2>&1 && echo "OK: $f" || echo "MISSING: $f"
done
```

Every line should print `OK`. If one prints `MISSING`, run `brew install
<name>` for that formula and re-check.

## Getting started

```bash
cd AudioutCore
swift test --build-system native   # run the core test suite against the mock backend
```

`--build-system native` is required on every `swift build`/`test`/`run` here —
the default engine relinks every executable on each invocation and keeps a
separate cache, so mixing the two costs a cold rebuild. See
[CLAUDE.md](CLAUDE.md#build--run).

The app talks to speakers through an `OutputBackend` protocol with three
implementations (mock, OwnTone, native); UI/control work should target the
mock backend and never assume real hardware is attached. See
[dev/README.md](dev/README.md) for the offline dev setup and
[AGENTS.md](AGENTS.md) for where things live in the codebase.

To build the real `.app` bundle (required for the native backend's
TCC-gated audio capture) — this is the step that needs every Homebrew
dependency above installed and discoverable:

```bash
./scripts/make-app.sh
```

If the build fails to find a header or fails to link, re-run the
verification loop above first — a missing or not-yet-linked Homebrew
formula is the most common cause.

## Documentation

- [docs/SPEC.md](docs/SPEC.md) — the product spec, source of truth for what
  to build.
- [docs/plans/](docs/plans/) — phased execution plans and their resolved
  decisions.
- [AGENTS.md](AGENTS.md) — orientation for coding agents: where things live
  and the rules that apply everywhere.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE) — the
AirPlay 2 sender is derived in part from OwnTone and bundles third-party
code under GPL, BSD, and MIT terms.

The one exception is the `AudioutProtocol/` package (the wire protocol
shared with the iPhone companion app), which is MIT — see
[AudioutProtocol/LICENSE](AudioutProtocol/LICENSE).
