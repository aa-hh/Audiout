# AudioutCore

## Purpose

This Swift package is the whole app: a UI-agnostic core library, AppKit UI
targets and the shipping executable. Core never imports AppKit; UI depends on
the model, never the reverse.

## Rules

- `scripts/run-tests.sh --filter <Suite>` for the inner loop, never a bare `swift test`.
- Tests must stay invisible: nothing a test does may reach the screen.
- This Mac's own AirPlay receiver is never surfaced as a device (2026-08-07).
- `.passwordRequired` never flattens to `.unknown`; keep the auth cause and its honest copy.
- Every `show*()` entry gates on-screen presentation behind `HeadlessRuntime.isActive`.
- `Device.isSelected` means "in the backend's output set", not UI membership.
- Scope arbiter: whole-system routing always wins a contested device, per-app yields.
- Bundle-ID resolution must reach every Core Audio process, never a single pid.
- `AppRouteDestination` is three cases; never read `.currentDevice` as redirected.
- Every real (re)connect reseeds the engine volume, or the stream is inaudible.
- Never touch IOBluetooth outside `BTDeviceEnumerator`'s gate; an ungated call kills the process.
- `TCCAccessPreflight` is cached for the process lifetime; read grants through `TCCProbeRunner`.
- `CompanionSnapshotBuilder` fields never come from `Device` state; use the UI's selection.
- Use `IsolatedSuite` for shared state; concurrent suites sharing defaults flake.
- Guard 3 flags `UserDefaults(suiteName:)` in tests; each one leaks a plist.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- [AudioutCore](Sources/AudioutCore/AGENTS.md) → model and backends
- [AudioutSharedUI](Sources/AudioutSharedUI/AGENTS.md) → shared row views
- [AudioutPopoverUI](Sources/AudioutPopoverUI/AGENTS.md) → menu-bar popover
- [AudioutWindowUI](Sources/AudioutWindowUI/AGENTS.md) → Groups screen
- [AudioutSettingsUI](Sources/AudioutSettingsUI/AGENTS.md) → Settings screen
- [AudioutOnboardingUI](Sources/AudioutOnboardingUI/AGENTS.md) → Setup window
- [AudioutApp](Sources/AudioutApp/AGENTS.md) → shipping executable
- [CastSender](Sources/CastSender/AGENTS.md) → Cast sender
- [CastFakeReceiver](Sources/CastFakeReceiver/AGENTS.md) → offline fake receiver
- [ObjCExceptionShim](Sources/ObjCExceptionShim/AGENTS.md) → NSException bridge
- [cast-spike](Sources/cast-spike/AGENTS.md) → Cast measurement CLI
