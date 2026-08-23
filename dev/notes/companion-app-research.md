# Companion iPhone App — Research

*2026-07-26. Research only — no code. Grounded in three parallel investigations: the Mac
app's state/command surface, its existing network infrastructure, and iOS/App Store
constraints (current as of mid-2026, sources cited in the constraints section).*

## 1. What we're building (confirmed with Alec this session)

- A **native iPhone app**, shipped **publicly on the App Store**, that remote-controls
  the Audiout Mac app.
- **Sonos connection model:** works only when the phone is on the same Wi-Fi as the Mac.
  No accounts, no login, no cloud — the phone finds the Mac on the network and connects.
- **Full control scope** — everything the popover does: speaker select/deselect, Main Out
  target, all volume levels (Main Out master, per-device, per-app), mute at every level,
  per-app routing (add/remove/route/volume), and group create/edit/activate/delete.
- **Live shared control:** the Mac and any number of phones see the same state, and a
  change made anywhere appears everywhere immediately. No VU meters on the phone — state
  sync only, no level streaming.
- **The phone gets its own UI**, not a popover clone: idiomatic iOS navigation (tab bar —
  e.g. Speakers / Apps / Groups), optimized for the phone. The protocol syncs *state*;
  each client renders it natively.

This reverses `docs/SPEC.md:30` ("Remote control: Mac only (no phone app)"). Per the
docs-first rule, SPEC.md must be updated on the same branch that lands the code.

## 2. How it works end to end (recommended architecture)

```
iPhone app                                Mac app
─────────                                 ───────
NWBrowser "_audiout._tcp"  ◄──Bonjour── NWListener (ephemeral port)
        │                                 advertises name + TXT {proto=1, name=…}
        ▼
NWConnection + WebSocket  ────connect───► accepts; sends FULL STATE SNAPSHOT
        │                                         │
        ├── command {setVolume …} ───────────────►│ hop to MainActor,
        │                                         │ call the SAME model methods
        │                                         │ the popover calls
        ◄── state delta broadcast ────────────────┤ to ALL connected phones
```

**Server = source of truth.** The Mac app hosts the server; phones are thin clients.
On every fresh connection the Mac pushes a complete state snapshot, then incremental
updates. Phone-originated commands are applied through the exact same controller methods
the popover uses, and the resulting state change is broadcast to every client (including
the one that sent the command — the echo *is* the confirmation). This makes reconnects
invisible (snapshot re-sync), makes multiple phones trivial, and means the Mac UI and
phone can never disagree for more than a broadcast interval.

**Transport: Bonjour + Network.framework WebSocket, both sides.** Confirmed as the 2026
best practice for LAN remotes; every Apple alternative is disqualified (DeviceDiscoveryUI
is tvOS-only, MultipeerConnectivity is effectively end-of-life, Wi-Fi Aware has no macOS
support). On iOS, connect the `NWConnection` directly to the browse result's
`NWEndpoint.service(…)` — no hostname/URL resolution step, correct multi-address
handling. Use `.bonjourWithTXTRecord` on the browser (plain `.bonjour` returns nil
metadata). Stick with `NWBrowser`/`NWConnection` — the new async `NetworkListener`/
`NetworkConnection` API is iOS 26-only and `NWConnection` is not deprecated.

**Wire format:** JSON messages over the WebSocket. New Codable DTOs are required —
`Device`, `BackendEvent`, `MainOutTarget`, `ConnectionState` are not `Codable` today.
Version with the repo's established `{schemaVersion, payload}` envelope idiom
(refuse-forward, ignore-unknown-keys), plus a `proto=` key in the Bonjour TXT record so
the phone can refuse an incompatible Mac before even connecting.

**Shared code:** a new dependency-free Swift package target (e.g. `AudioutProtocol`)
holding the DTOs + message enums, compiled into both the Mac app and the iOS app. Keep it
free of AppKit/backend imports so the iOS app never pulls in Mac-only code.

## 3. What already exists on the Mac side (build on, don't invent)

The infrastructure research found the Mac app already contains a working template for
nearly every piece:

| Need | Existing template | Where |
|---|---|---|
| Bonjour-advertised LAN server | **DACPServer** — `NWListener`, ephemeral port, TXT record, serial-queue confinement, per-connection idle timeout, pure-function request parsing behind a socket-free test seam | `AudioutCore/Sources/AudioutCore/DACPServer.swift` |
| Resilient Bonjour browsing (for the iOS side to copy) | `NetworkFrameworkBrowser` — per-service-type recreate on `.failed` with capped exponential backoff | `NativeDiscovery.swift:650` |
| Local-network permission preflight | `LocalNetworkPrimer` — browse-as-permission-check (macOS has no status API; iOS has none either, same trick applies) | `LocalNetworkPrimer.swift` |
| Demo-mode policy | `BackendKind.resolved()` — mock is explicit opt-in only, never a silent fallback | `OwnToneBackend.swift:806` |
| Wire versioning idiom | `{schemaVersion, payload}` envelope, refuse-forward | all five persistence stores |
| Offline peer handling | `hasEverBeenAP2` sticky capability — a vanished peer is *offline*, not *forgotten* | `NativeDiscovery.swift:243` |

**No new entitlements needed on the Mac.** The app is unsandboxed (hardened runtime
only), so it can bind a listening socket freely — DACPServer proves this in production.
And `NSBonjourServices` gates *browsing*, not *advertising*, so advertising
`_audiout._tcp` needs no Info.plist change on the Mac either.

**State/command surface is fully mapped** (see the agent report in this branch's history
for the complete table). The short version:

- State lives in five main-thread-confined controllers — `GroupController` (selection,
  Main Out, groups, mute, master volumes), `AppRoutingController` (per-app rows),
  `ExcludedAppsController`, `DeviceIconController`, `AppSettings` — plus live device
  state read from `backend.devices`.
- Every popover command lands on a named controller method (e.g.
  `GroupController.setDeviceSelected`, `setMainOut`, `setMemberVolume`,
  `AppRoutingController.setDestination`). The network layer calls these same methods —
  no parallel mutation path.
- Backend → app propagation is a single `AsyncStream<BackendEvent>`;
  `makeEventStream()` returns an **independent stream per caller and replays the full
  device snapshot to late subscribers** — the companion server can subscribe without
  touching the UI's stream. This is the single best hook that exists.

## 4. The one real gap on the Mac side

**`GroupController` (and friends) publish nothing.** No Combine, no NotificationCenter,
no change closures — the popover works because every delegate callback mutates and then
explicitly calls `rebuild()`. Selection changes, Main Out switches, and group CRUD emit
no observable event at all.

So the companion server needs a **state broadcaster**: after any inbound command it
applies, and on every `BackendEvent`, rebuild the snapshot on the main actor, diff
against the last broadcast, and push the delta to all clients (coalesced, e.g. ~50 ms).
Mac-UI-originated changes flow through the same tap — the cleanest spot is the
`AppDelegate` coordination layer, which already sees every backend event, plus either a
small multicast change hook added to `GroupController`/`AppRoutingController` or a
rebuild-after-repaint tap. This is additive work, not a refactor — the controllers
themselves don't change.

Threading rule for all of it: inbound commands hop to the main actor before touching any
controller; snapshots are built on the main actor; the WebSocket I/O lives on its own
serial queue like DACPServer.

## 5. Protocol subtleties the state mapping surfaced

- **`Device.isSelected` is a trap** — it means "in the backend's output set", not
  membership (passthrough = empty backend set). Snapshots must be built from
  `GroupController.isSpeakerSelected(_:)` / `isMainOutMember(_:)`.
- **Commands can be refused or transformed.** `setDeviceSelected` returns a
  `SelectionResult` (applied / refusal reason / auto-swap notice). The protocol must
  round-trip this so the phone can toast the same feedback the popover shows.
- **Master-volume drags are stateful** (begin → set… → end, with proportional scaling).
  The protocol needs the begin/end brackets, and phone slider input should be coalesced
  (send at most ~20 Hz, always send the release value).
- **Launch semantics:** the routing set intentionally resets to passthrough at every Mac
  launch, and `.device` per-app routes are cleared at launch. The phone renders whatever
  the snapshot says — no phone-side persistence of routing state, ever.
- **Mute is volume-based** (stash/restore), handled entirely inside `GroupController` —
  the phone just sends "mute X" and renders the resulting state.
- **Scope recommendation:** the phone gets the popover surface **plus full groups CRUD**
  (on the Mac that lives in the Groups window, but it's core to the couch use-case).
  Mac-only concerns stay Mac-only: Settings panes (theme, density, buffer, exclusions),
  onboarding, Quit. Excluded apps affect the phone only in that excluded apps never
  appear in snapshots.

## 6. iOS-side constraints (the things that bite)

- **Info.plist:** `NSLocalNetworkUsageDescription` (concrete wording — vague strings
  draw 5.1.1 rejections: "Audiout uses the local network to find and control the
  Audiout app on your Mac") + `NSBonjourServices` = `["_audiout._tcp"]`. Browsing a
  type not in that array fails outright, independent of user permission.
- **There is still no Local Network permission status/request API (mid-2026).** The
  prompt fires on first browse. Denial does NOT error the browser — it sits in
  `.waiting` with `dns(-65570)` forever, indistinguishable from "no Mac found" unless
  handled explicitly. The app must show "check Local Network permission in Settings"
  (deep-link) rather than spinning. iOS 18 added state-desync bugs (denied-but-working,
  re-grant needing reboot) — never treat one successful packet as proof of grant; QA on
  fresh installs.
- **Backgrounding kills the socket** within seconds, and no background mode legitimately
  saves it (declaring `audio` without playing audio is a known rejection). Correct
  pattern, and what Sonos-style remotes do: tolerate the drop, reconnect eagerly on
  foreground, and rely on snapshot-on-connect to make it seamless.
- **Wi-Fi only:** set `prohibitedInterfaceTypes = [.cellular]`, use
  `NWPathMonitor(requiredInterfaceType: .wifi)` to drive an honest "not on your Mac's
  network" state.
- **No special audio permissions** — the phone plays nothing; plain TCP + Local Network
  privacy is the entire permission story. The multicast entitlement is not needed for
  declared Bonjour types.
- **Minimum iOS:** 17 or 18 (recommend 18) — everything needed is long-available;
  the iOS-26-only new Network API is not worth requiring.

## 7. App Store review path

The reviewer will not have a Mac running Audiout. Guideline 2.1 (App Completeness) is
the risk; >40% of stuck reviews are 2.1. The proven package:

1. **Review notes** stating plainly: companion controller for free Mac host software, no
   account, no backend; what the reviewer sees with and without a host.
2. **Demo video** (short screen recording: discovery → connect → control with iPhone +
   Mac on one network) linked in the notes — the single most effective artifact.
3. **A visible demo mode** — a "Demo system" entry in the discovery screen driving a
   simulated Mac, mirroring the Mac app's `MockBackend`/`AIRPLAY_MOCK_SCENARIO` pattern
   and its policy: explicitly user-chosen, clearly labeled, never a silent fallback.
   This also rescues the experience if the reviewer denies the local-network prompt.
4. A graceful "no Mac found" empty state with help text — effectively a review
   requirement, and good product anyway.

Expect possibly one review round-trip regardless (recent precedent: a Pi-hole companion
resolved via notes + video). The `lance` App Store Connect operator is available for the
ASC side when we get there.

## 8. Open decisions for Alec

1. **Is phone control always-on, or a Mac-side toggle?** Recommendation: on by default
   with a Settings checkbox ("Allow control from iPhone on this network"), so it's
   discoverable but declinable.
2. **Open-on-LAN vs first-connect approval.** Sonos is fully open on the network (the
   model Alec referenced). Recommendation: ship open like Sonos — anyone on your Wi-Fi
   can control playback, same as Sonos accepts. A one-time "Allow 'Alec's iPhone' to
   control?" prompt on the Mac is the easy upgrade later if wanted.
3. **App name/branding** for the store ("Audiout Remote"?) — needed before ASC setup,
   not before building.

## 9. Suggested build shape (for the eventual plan, not started)

1. **Protocol + Mac server first:** `AudioutProtocol` target (DTOs, messages),
   companion server in AudioutCore (DACPServer-style NWListener + WebSocket +
   Bonjour advertise), state broadcaster, command dispatch onto the existing
   controllers. Fully testable with loopback WebSocket clients — no iOS code yet, and
   the socket-free parse/serialize seams follow the DACPServer testing pattern.
2. **iPhone app:** new Xcode project consuming `AudioutProtocol`; discovery/connect
   flow with all the permission-denial UX; tab-based SwiftUI UI (Speakers / Apps /
   Groups); reconnect + snapshot re-sync.
3. **Demo mode + review prep:** simulated system on the phone, demo video, review
   notes, TestFlight, then App Store.

Phase 1 alone is independently valuable and de-risks everything: it proves the shared-
state model with two Mac-side clients before any iOS work exists.
