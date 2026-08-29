# Audiout

A native AppKit macOS app for sending system audio to several AirPlay 2
speakers at once — per-device volume, mute, saved groups, per-app routing,
and multi-room sync.

Requires macOS 14.4 or later (Apple Silicon).

## License

GPL-2.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE) — the
AirPlay 2 sender is derived in part from OwnTone and bundles third-party
code under GPL, BSD, and MIT terms.

Corresponding source is in this repository.

## Developers

Building from source requires Xcode, Homebrew, and several native library
dependencies. See [dev/BUILD.md](dev/BUILD.md).

For offline UI work and backend toggles, see [dev/README.md](dev/README.md).
Architecture and product spec: [AGENTS.md](AGENTS.md), [docs/SPEC.md](docs/SPEC.md).
