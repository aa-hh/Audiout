# Building Audiout from source

Audiout is GPL-2.0-or-later. Building it yourself is a supported path, it costs
nothing, and it gets you the same app as the paid download — the difference is
that you do the packaging work yourself. See
[README.md](../README.md#or-build-it-yourself) for what the purchased build adds.

## What you need

- **A Mac with Apple Silicon**, running macOS 14.4 or later.
- **Xcode or the Swift toolchain**, Swift 5.10 or newer.
- **[Homebrew](https://brew.sh)** — required for a source build. The AirPlay 2
  sender links several C libraries that the build expects to find via Homebrew
  rather than bundling itself. This is a limitation of the source build, not a
  permanent design; the released `.app` bundles these libraries so its users
  never need Homebrew.

## Homebrew libraries

Install Homebrew first if you don't have it:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then install everything the native AirPlay backend links against:

```bash
brew install libevent libsodium libgcrypt libgpg-error libplist ffmpeg
```

<details>
<summary>What each library is actually for</summary>

| Library | Why it's needed |
|---|---|
| **libevent** | The event loop underlying the AirPlay RTSP/event transport (evrtsp). |
| **libsodium** | Cryptography for AirPlay 2 device pairing. |
| **libgcrypt** | Cryptography used by the sender core and pairing alongside libsodium. |
| **libgpg-error** | A dependency libgcrypt needs. Installed alongside it, but listed because the build links it directly too. |
| **libplist** | Parses and builds the Apple property-list payloads AirPlay's RTSP control channel uses. |
| **ffmpeg** | Provides the ALAC encoder (via libavcodec/libavutil/libswresample) that encodes PCM audio for the AirPlay 2 stream. |

</details>

Check Homebrew can see all of them before building:

```bash
for f in libevent libsodium libgcrypt libgpg-error libplist ffmpeg; do
  brew --prefix "$f" >/dev/null 2>&1 && echo "OK: $f" || echo "MISSING: $f"
done
```

Every line should print `OK`. If the build later fails to find a header or fails
to link, come back and run this first — a missing or unlinked formula is the
most common cause by a wide margin.

## Build and run

```bash
git config core.hooksPath .githooks   # once per clone, enables the repo guards
bash scripts/build.sh                 # compile check
```

To produce a runnable `.app` bundle — required for the native backend, because
macOS only grants system-audio capture to a signed application:

```bash
bash scripts/make-app.sh
open build/Audiout.app
```

macOS will ask for system-audio recording and Local Network permission on first
run. Both are required for the app to do anything; the app explains why at the
moment it asks.

To work on the interface without any speakers or permission prompts, run against
the mock backend:

```bash
AIRPLAY_BACKEND=mock swift run --package-path AudioutCore AudioutApp
```

## Tests

```bash
bash scripts/run-tests.sh                       # everything
bash scripts/run-tests.sh --filter SomeTests    # one suite
```

Always go through `scripts/run-tests.sh` and `scripts/build.sh` rather than a
bare `swift test` or `swift build` — the wrappers handle the build cache and
concurrency limits that the bare commands opt out of.

## Where things are

| Path | What it is |
|---|---|
| `AudioutCore/` | The app: core library, AppKit UI targets, and the menu-bar executable |
| `AirPlayEngine/` | The vendored AirPlay 2 C sender wrapped in a Swift actor. A separate package on purpose — it is the licensing boundary, and holds no app concepts |
| `dev/` | Offline development tooling (fake speakers, dev scripts) and research notes |
| `scripts/` | Build, packaging, signing and release scripts |
| `docs/SPEC.md` | The product spec |

The app reaches speakers through an `OutputBackend` protocol with three
implementations — mock, OwnTone and native. Interface work should target the
mock backend and never assume real hardware is attached.
[AGENTS.md](../AGENTS.md) has the architectural rules and the traps that the
code alone doesn't convey.

## A note on the licence check

The released build contains a soft licence check: without a key it keeps every
feature working and shows a prompt asking you to buy. A build made from source
has no licence server configured, so it validates nothing, prompts nothing and
updates nothing. That is the intended behaviour of the free build, not a bug.
