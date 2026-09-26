# 05 — Per-app destinations, saved groups, companion snapshot

Status: ready-for-human (built 2026-09-26; live check owed)
Blocked by: 03

## Change

- `NativeBackend+PerAppRouting.swift` `isRouteTargetReachableLocked`: admit
  `device.isWired` beside `isBluetooth`; per-app delivery to a wired UID via
  the sink manager's per-app claim path (`btPerAppClaimedUIDs` equivalent),
  never re-anchoring the shared reference (AGENTS-HISTORY rule).
- `AppRouteTargetEligibility`: wired allowed as a `.device` target; scenes as
  app targets stay AirPlay 2 only.
- `GroupStore`/`GroupController`: nothing special — members are UIDs; confirm a
  group naming an absent wired UID restores greyed, not dropped.
- `CompanionSnapshotBuilder`: wired rows carry `isLocalDevice: false`; if the
  wire schema needs a transport field, that is an `audiout-shared` change first
  (tag, pin bump in BOTH consumers, same session).
- Scope arbiter: whole-system wins a contested wired device, per-app yields —
  same as every other kind.

## Tests

- Route table admits a reachable wired UID and demotes it when whole-system
  claims it (extend the existing arbiter table).
- Snapshot flags for a wired device.
