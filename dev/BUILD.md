# Building from source

These instructions are for developers who want to compile Audiout locally.
End users should use the pre-built release (bundled libraries, no Homebrew).

## Requirements

- macOS (Apple Silicon), 14.4 or later
- Xcode / Swift toolchain (Swift Package Manager), Swift 5.10+
- [Homebrew](https://brew.sh) — the native AirPlay 2 sender links several C
  libraries that the build currently expects to find via Homebrew rather than
  bundling itself. Release builds bundle these into the `.app`; source builds
  do not.

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

## Compile and test

Use the repo wrappers — not bare `swift build` / `swift test` — so builds
route correctly and caches stay warm. See [CLAUDE.md](../CLAUDE.md#build--run).

```bash
bash scripts/build.sh
bash scripts/run-tests.sh
```

Offline UI work (no hardware, no TCC):

```bash
AIRPLAY_BACKEND=mock swift run --package-path AudioutCore AudioutApp
```

## App bundle (native backend)

The native backend's system-audio capture needs a signed `.app` bundle and a
TCC grant. A bare `swift run` does not reliably hold the grant.

```bash
./scripts/make-app.sh
```

If the build fails to find a header or fails to link, re-run the Homebrew
verification loop above — a missing or not-yet-linked formula is the most
common cause.

For live hardware testing with `AIRPLAY_BACKEND=native`, read
[notes/p2b-nativebackend-runbook.md](notes/p2b-nativebackend-runbook.md)
before attempting a session.
