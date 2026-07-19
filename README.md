# Audiouter

A native AppKit macOS app for sending system audio to several AirPlay 2
speakers at once — per-device volume, mute, saved groups, per-app routing,
and multi-room sync.

## Requirements

- macOS (Apple Silicon)
- Xcode / Swift toolchain (Swift Package Manager)

## Getting started

```bash
cd AudiouterCore
swift test            # run the core test suite against the mock backend
```

The app talks to speakers through an `OutputBackend` protocol with three
implementations (mock, OwnTone, native); UI/control work should target the
mock backend and never assume real hardware is attached. See
[dev/README.md](dev/README.md) for the offline dev setup and
[AGENTS.md](AGENTS.md) for where things live in the codebase.

To build the real `.app` bundle (required for the native backend's
TCC-gated audio capture):

```bash
./scripts/make-app.sh
```

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
# Audiouter
