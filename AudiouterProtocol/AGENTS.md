## Purpose

The wire protocol shared by the Mac app's `CompanionServer` and the iOS
companion app: Bonjour constants (`CompanionProto`), the JSON envelope
(`CompanionEnvelope`/`CompanionMessage`), the command set
(`CompanionCommand`), and the state snapshot types (`Snapshot` and friends).
It is a sibling package to `AudiouterCore`, not a target inside it, because
`AudiouterCore/Package.swift` shells out to `brew --prefix` and pulls in the
whole `AirPlayEngine` graph — the iOS app must depend on a Foundation-only
graph with none of that.

## Rules

- **Zero dependencies, forever.** `Package.swift` here must never grow a
  `dependencies:` entry or a shell-out — that guarantee is the entire reason
  this package exists apart from `AudiouterCore`. If a future need seems to
  require one, it belongs in `AudiouterCore` or a new package, not here.
- **Changing the wire encoding of an existing `CompanionMessage` or
  `CompanionCommand` case is a protocol break**, not a refactor — both peers
  must ship together or one starts misdecoding the other silently. Add a new
  case instead. Bump `CompanionProto.version` only when a case's *semantics*
  change in a way an old peer would misinterpret, not merely for a new case
  (`.unknown` already handles a peer that doesn't recognize one).
- **Refuse-forward, not refuse-behind.** A peer advertising a protocol
  version greater than `CompanionProto.version` is refused
  (`CompanionProto.isIncompatible(peerVersion:)`) — an older peer is fine to
  talk to. This runs twice: once on the Bonjour TXT `proto` key before a
  socket even opens, again on `hello`/`welcome`'s `protoVersion` payload
  field once connected.
- **This package's tests are NOT covered by the repo's Guard 4** test-runner
  wiring (that targets `AudiouterCore`). Run them directly:
  `cd AudiouterProtocol && swift test`.

## Map

- `CompanionProto` — service type, TXT keys, protocol version, refuse-forward check.
- `CompanionMessage` / `CompanionEnvelope` — the eight message cases + the `{v, type, payload}` wire envelope.
- `CompanionCommand` — the phone's 18 outbound commands, hand-Codable.
- `AppIconPayload` / `CompanionAppIcons` — one app's 128×128 PNG (or an explicit "no icon"), plus the page size and request cap bounding the icon request/response pair. Icons ride OUTSIDE `Snapshot` on purpose, so identical-snapshot suppression is never defeated by icon churn.
- `Snapshot` / `DeviceState` / `GroupState` / `AppRouteState` / `MainOutState` / `SettingsState` — full app state, `Equatable` for change-suppression on the server.
