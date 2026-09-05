<!--
Handoff plan. Self-contained: a fresh agent with no prior conversation context can
execute from this file alone. Produced by a research-grounded, READ-ONLY investigation
pass on 2026-07-29. NOTHING IS FIXED — this is the spec for the redesign, plus one
open safety question the owner must decide before any code lands.
All file:line anchors are against `main` @ 2042de1.
-->

# PLAN — Connect-volume seed redesign: device-reported → last-known → connect-default

**Status:** READ-ONLY research complete. No code written.
**Worktree:** `~/Projects/AirPlay Controller/.claude/worktrees/connect-volume-seed`
**Branch:** `claude/connect-volume-seed` (off `main` @ 2042de1, NOT merged).

---

## 1. Owner's directive (verbatim intent, 2026-07-29)

Today, connecting/selecting a device seeds its volume to a fixed **connect-default**
level (35%, `AppSettings.defaultConnectVolume`) — a holdover from when the seed
inherited the Mac's own system volume and speakers could BLAST on first connect
(G1-N1). The owner wants the priority order changed, in this order:

1. **If the device/system reports its own current volume** ("the device tells us I
   was at x percent") — take that.
2. **Otherwise hold the previous level that device had in our system** (persisted
   per device, across app restarts — not just in-session).
3. **The fixed connect-default becomes a last-resort fallback**, only for a device
   this app has never seen before.

This changes **only** the user-initiated connect branch. The existing F-REBIND
branch (an out-of-band reconnect the user didn't ask for — a tap rebuild, a
Bluetooth-glitch reconnect, etc.) already does something close to tier 2 today, but
in-memory only — see §2.

---

## 2. Current behavior, with anchors

### 2.1 The seed function

`NativeBackend.connectVolumeSeed(_:outputID:)` —
`AudioutCore/Sources/AudioutCore/NativeBackend.swift:5428-5462`. Called from
both add-success sites (a plain user connect races an out-of-band engine-state
mirror of the same completion; whichever flips `added` false→true first wins,
capped at one push per connect — see the doc comment at `:5392-5410` and
`AudioutCore/AGENTS.md`'s "Every real (re)connect must reseed the engine volume"
rule):

- `convergeDevice`'s post-`addOutput` write — `NativeBackend.swift:3746`
- `applyEngineState`'s `.connected`/`.streaming` branch — `NativeBackend.swift:4844`

```swift
// NativeBackend.swift:5442-5448
let isUserConnect = userConnectSeed.remove(id) != nil
let seed: Int
if !isUserConnect, let inSession = stashedVolume[id] ?? known[id]?.volume {
    seed = inSession
} else {
    seed = min(max(connectVolumeProvider(), AppSettings.minConnectVolume), AppSettings.maxConnectVolume)
}
```

- **`isUserConnect`** is true iff `id` is in `userConnectSeed`
  (`NativeBackend.swift:590`), a `Set<String>` populated at exactly one site —
  `setOutputSet`'s "user asked for this device ON" branch,
  `NativeBackend.swift:1822-1829` (`self.userConnectSeed.insert(id)`,
  comment-tagged "F-REBIND"). Nothing else ever inserts into it. This is **the**
  branch this redesign changes.
- **Not a user connect** (an out-of-band rebind) already does something close to
  tier 2: `stashedVolume[id] ?? known[id].volume` — but this is in-memory state for
  the CURRENT process only (see §4). `stashedVolume` is the pre-mute stash
  (`NativeBackend.swift:551`); `known` is the "last-known snapshot, by id"
  dictionary (`:278`), never persisted to disk.
- The clamp (`AppSettings.minConnectVolume…maxConnectVolume`, 5…100,
  `AppSettings.swift:177,180`) bounds only the **default** branch — deliberately,
  so a bad/injected provider value can never reach the −30 dB silent floor. The
  F-REBIND preserve branch is NOT re-clamped: a level the user dialled in
  (including a deliberate very-low value) is theirs to keep.

### 2.2 Why the seed exists at all — do not lose this invariant

The engine's per-output volume field is zero-initialized; 0 maps to ≈ −30 dB
(quietest non-muted level, effectively silent) — `AirPlayEngine.swift:650-657`
per the existing doc comment. **Every** code path that lands here MUST end by
pushing *some* real value to the engine (`pushVolume`, which serializes per
output id — `volumeInFlight`/`volumePending`, latest-wins, since the vendored C
dispatcher permits only one pending `setVolume` callback per device). The
redesign changes **which** value is chosen for the user-connect branch; it must
not reopen a path where nothing is pushed on a fresh session.

### 2.3 The wire↔UI domain conversion — the seed must stay UI-domain

`connectVolumeSeed` returns a **UI-domain** (0–100, pre-gain) integer, and pushes
`engineVolume(forID:uiVolume:)` (`NativeBackend.swift:5198-5199+`) — the single
place `Main × Group × Device` is formed (`:5179-5198`) — to the engine. Any new
tier-1 source (§3) MUST be converted the same direction `setSpeakerVolume` already
demonstrates for a receiver-initiated report:

`setSpeakerVolume(id:outputID:level:)` (`NativeBackend.swift:4991-5007`) receives
a **wire** level (0.0…1.0, already gain-applied) and inverts it back to a stored
UI-domain value:

```swift
// NativeBackend.swift:4992-4995
let gain = masterGainFraction
guard gain > 0 else { return }
let wirePct = Int((level * 100).rounded()).clampedToVolume
let stored = Int((Double(wirePct) / gain).rounded()).clampedToVolume
```

This is the exact inversion pattern a device-reported connect-time volume must
reuse — the receiver's report is necessarily a wire-domain figure (see §3), and
storing it un-inverted into `known[id].volume` would corrupt the user's stored
level the moment any Main/Group gain is non-100 (each reconnect would then
re-attenuate an already-attenuated number — the same ratchet-toward-silence bug
`setSpeakerVolume`'s doc comment already warns about at `:4980-4983`).

---

## 3. Feasibility verdict: does the receiver report its own current volume?

**Verdict: no reliable connect-time PULL exists. The only receiver-volume signal is
an asynchronous, receiver-initiated PUSH with no protocol guarantee of firing at
connect, and no code today waits for one before seeding. Tier 1 must be scoped as
"opportunistic, bounded-wait listen," not "query the device," and needs a live
A/B against real hardware before its usefulness can be trusted.**

### 3.1 There is no GET_PARAMETER (or any pull) in the vendored sender

`grep -rn "GET_PARAMETER" AirPlayEngine/Sources/CAirPlayEngine/` returns **zero
matches**. The connect sequence table
(`AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c:3735-3790`) only ever
issues `SET_PARAMETER` — we **push** `session->volume = device->volume`
(`airplay.c:1674`, `:1958-1968`), where `device->volume` is a value **we** already
chose (the seed itself, prior to this change). `response_handler_volume_start`
(`airplay.c:3216-3226`) only triggers the metadata-startup send; it does not parse
a volume back out of the response. **AirPlay's classic/RAOP volume model makes
the sender the authority** — there is no "ask the receiver what it's set to"
primitive at all, for AP1 or AP2/RAOP alike (this sender code path is shared).

### 3.2 The only receiver-volume signal is a push, and it is a "changed", not "here's my current level"

Two receiver→sender channels exist, and both are already wired into
`NativeBackend`, but both are framed by their own doc comments as **a report of a
volume the receiver just changed to** (a physical/virtual knob turn), not an
initial-state announcement:

- **RTSP reverse `/event` channel** —
  `AirPlayEngine/Sources/CAirPlayEngine/sender/airplay_events.c`. Comment at
  `:336-341`: *"Some receivers report **a change** to their OWN volume back to
  the sender on this event channel as an RTSP SET_PARAMETER carrying a `volume:
  <dB>` line."* Parsing: `volume_parse` (`:349-391`, text `volume:` line),
  `plist_find_volume`/`event_bplist_volume` (`:477-557`, best-effort bplist
  fallback for receivers that report via plist instead of a text line). Delivered
  to Swift via `airplayengine_remote_fire(..., AIRPLAYENGINE_REMOTE_VOLUME, volume)`
  (`:678`, `:716`) → `RemoteEventHub` (`AirPlayEngine.swift:1780-1830`) →
  `NativeBackend.applyRemoteVolume` (`NativeBackend.swift:4937-4942`) →
  `setSpeakerVolume`. **Swift-side doc comment confirms this path is "rarely
  exercised"** in practice (`NativeBackend.swift:4934-4936`).
- **DACP callback** — `AudioutCore/Sources/AudioutCore/DACPServer.swift`.
  The receiver makes an HTTP `GET /ctrl-int/1/setproperty?dmcp.device-volume=<dB>`
  request **to us** (`:17-28`), matched by `Active-Remote` token →
  `NativeBackend.applyDacpVolume` (`:4949-4956`) → `setSpeakerVolume`. Doc-tagged
  "the real path for Sonos et al." (`:4944-4945`) — i.e. this is the channel that
  actually fires in practice, but it is, again, framed and used today purely as
  "the speaker changed its own volume," fired on a live knob/remote action.

### 3.3 Whether either fires unprompted at connect time is unverified — and the sender never waits for one

Nothing in this codebase instruments or waits for an early volume report during
the connect sequence. The event channel and DACP listener are both live and
subscribed continuously (`subscribeRemoteEventStream`,
`NativeBackend.swift:4901-4916`, started once at `start()` — `:1335`), so if a
receiver spontaneously announces its volume immediately after RTSP/DACP session
establishment (some receivers do this for other property classes, e.g. Now
Playing state, on some protocols — **not confirmed for volume on any receiver
this app targets**), the report would already arrive and move the slider via
`setSpeakerVolume` — but only as an **after-the-fact correction**, race-prone
against `connectVolumeSeed`'s own push in the same connect episode, and with no
guarantee it arrives at all (most receivers apparently don't proactively report
initial volume — DACP/event volume messages are documented and coded here purely
as change notifications). There is no live evidence in this repo (telemetry,
tests, or comments) of a receiver ever reporting its OWN pre-connect volume
*before* our seed push lands.

**Practical consequence for the design:** because the vendored sender is the
protocol's volume authority and must send an explicit `SET_PARAMETER (volume)` as
part of the `AIRPLAY_SEQ_START_PLAYBACK` step
(`airplay.c:3763`, marked `true` = required, with the comment "some devices …
don't register the volume if it isn't last") to begin streaming at all, tier 1
cannot be "block the connect until the receiver tells us its volume" without a
protocol change or a receiver-side guarantee this codebase cannot assert. The
only honest implementation is: **listen for an early device-reported volume in
a short bounded window right after the receiver-facing session opens and before
`connectVolumeSeed` fires its push; if one lands in time, treat it as tier 1;
otherwise fall through to tier 2/3 as today.** This needs live-testing against
real hardware (Sonos, HomePod, AirPort Express, Apple TV) to learn whether any
receiver this app targets does report unprompted, and how quickly — **this is
investigation-remaining, not a settled fact**, and is the plan's largest
uncertainty.

### 3.4 AP1/RAOP

Same C sender code path serves both (no `#ifdef`/branch splitting AP1 from AP2 in
the volume plumbing above); `airplay_volume_to_pct`/`airplay_volume_from_pct`
(`airplay.c:1888-1953`) is the shared dB↔pct map both device kinds go through
before `pushVolume`. So whatever tier-1 mechanism is built (or not) applies
uniformly to AP1/RAOP receivers too — no separate feasibility question there.

---

## 4. Persistence: what exists today, and where tier 2 needs to live

**Current state: `known[id].volume` and `stashedVolume[id]` are IN-MEMORY ONLY.**
Neither is written to disk anywhere. `grep -rn "known\[id\]" NativeBackend.swift`
and a repo-wide search for a per-device volume store both come up empty — the
only Codable/JSON stores in `AudioutCore/Sources/AudioutCore/` are
`AppRouteStore.swift`, `GroupStore.swift`, `RoutingStore.swift`,
`ExcludedAppsStore.swift`, and `DeviceIconStore.swift` — none holds a volume.
`known` is rebuilt fresh from Bonjour discovery every launch
(`mapDiscovered`, `:5040-5074`); a never-before-seen-this-session device's
`baseVolume` falls back to a hardcoded `50` at `:5055` (display-only fallback,
distinct from the connect-time seed — but evidence the model has no durable
memory today).

**So today's F-REBIND "hold previous level" (§2.1, the non-user-connect branch)
only survives a live rebind within the same running process — it does NOT
survive an app quit/relaunch.** Tier 2 of the new design ("hold the previous
level that device had in our system") needs to survive exactly that, per the
owner's framing ("persisted per device") — so this is new work, not a rename of
existing behavior.

### 4.1 Where it should live — an existing, direct analog

`DeviceIconStore.swift` (`AudioutCore/Sources/AudioutCore/DeviceIconStore.swift`)
is the closest sibling: `Codable`, versioned-JSON, `[deviceID: value]` payload,
same `Application Support/Audiout/` directory
(`GroupStore.defaultDirectory`), injectable directory for tests. Device ids are
the stable colon-hex `deviceid` (`Device.swift:39`, `NativeDiscovery.swift:48-49`)
— the same durable key `DeviceIconStore` already keys on, and stable across
restarts and reconnects (not tied to a live session/outputID).

**Recommended shape** (new file, `DeviceVolumeStore.swift`, mirroring
`DeviceIconStore` line-for-line): `Envelope { schemaVersion: Int; volumes:
[String: Int] }`, file `device-volumes.json`, same directory. Store the
**UI-domain** (pre-gain) value — never the wire/effective value, for the same
reason §2.3 gives (storing an effective value would ratchet on repeated
gain-affected reconnects).

### 4.2 When to write it

Every genuine user-set level should update the durable store, not just the
in-memory `known[id].volume` — i.e. the same write points that already call
`applyLocal(id) { $0.volume = ... }` for a *user*-attributable change:
`setSpeakerVolume` (a receiver-reported knob turn — itself now also a source, if
tier 1 lands), `setVolume` (a slider drag), and `connectVolumeSeed`'s own
tier-1/tier-2 write when it seeds a level (so the durable record reflects
reality even before the user next touches the slider — see the open question in
§4.3 about whether the connect-default fallback itself should be persisted).
**Do not write on every `applyLocal` call generally** — mute/select/availability
churn is not a volume-intent event and would thrash the file for no benefit; scope
the write to the same call sites already understood to be "the user (or the
device, if tier 1 lands) set a real level," and debounce/coalesce a fast slider
drag (same shape as `pushVolume`'s in-flight latest-wins coalescing, or simpler —
write on drag-end / a short trailing debounce) so a drag doesn't hit disk on every
tick.

### 4.3 Open sub-question (small, flag for the owner, don't silently decide)

Should a **connect-default fallback** (tier 3, a never-seen device) itself get
written into the durable store the first time it's used, so the SECOND connect
ever made to that device already has a "previous level" (tier 2) instead of
falling to tier 3 again? This seems obviously "yes" for coherence with the
overall design intent, but is called out explicitly rather than assumed.

---

## 5. The anti-blast open question (present to the owner, do not silently decide)

The seed was moved off "inherit the Mac's system volume" specifically because a
real AirPlay speaker could **BLAST the user** on first connect (G1-N1,
`AppSettings.swift:161-169`, `NativeBackend.swift:5374-5381`). The new tier-1
source (§3) reads a number **the receiver itself reports**, which sidesteps the
original "we don't know how loud the Mac is" problem — but introduces a new one:

**What if the device reports 100%?** Plausible causes: a receiver that resets to
full volume on power-cycle/factory-reset-adjacent conditions; a receiver
mis-reporting a raw/uncalibrated value (some devices are known to expose oddly
scaled or clipped volume figures — see the existing AP1 perceptual-floor comment
at `airplay.c`'s dB math and `NativeBackend.swift:5149-5177`'s by-ear AP1 curve,
evidence this codebase already treats raw device-reported numbers with
suspicion); a brand-new device the app has never negotiated with, whose default
factory volume is loud by design. Blindly trusting tier 1 reopens exactly the
blast risk tier-3's fixed-moderate-default was built to close (§2.2's G1-N1
rationale) — except now the "loud" number comes from the device instead of the
Mac.

**This plan deliberately does NOT decide this.** Two shapes, with trade-offs:

- **(a) No clamp on tier 1 — trust the device fully.** Upside: literal reading of
  the owner's directive ("if the device tells us I was at x percent, take that");
  correct behavior for the common case (a device correctly reporting a level the
  user or a previous session set on purpose, including a deliberately loud one).
  Downside: reintroduces an unbounded-blast path the whole `connectVolumeSeed`
  design has spent real effort closing (the −30 dB trap's inverse — a −0 dB
  trap). No protection against a misreporting or freshly-reset device.
- **(b) Clamp/cap tier 1 the same way tier 3's default is clamped** (e.g. to
  `AppSettings.maxConnectVolume`, currently 100 — effectively a no-op unless a
  LOWER ceiling is chosen specifically for device-reported values) **or ramp**
  (seed at a capped level, then glide to the reported level over N seconds/steps
  once audio is confirmed flowing). Upside: closes the blast risk regardless of
  source. Downside: contradicts a device that genuinely, deliberately, was left
  at a loud level by the user on that speaker directly (Sonos app, physical
  remote) — the app would then visibly refuse to honor "take the device's own
  number," which may read as a bug rather than a safety feature; a ramp is also
  meaningfully more implementation work (needs a timer/step mechanism with no
  existing analog in this file — `pushVolume`'s coalescing is not a ramp).

**Recommendation for discussion, not a decision:** a light-touch middle ground —
apply tier 1 as-is (no clamp/ramp) but keep `AppSettings.maxConnectVolume` as an
outer ceiling exactly the way tier 3 already is clamped (so a corrupt/garbage
report, e.g. a receiver that emits a raw value outside 0–100 by mistake, can't
exceed the app's existing top bound) — this is a near-zero-cost safety net (the
same clamp expression tier 3 already uses) rather than a new ramp mechanism, but
still does NOT protect against a legitimately-in-range 100% report. Flag this
distinction to the owner explicitly: "cheap garbage-value clamp" vs. "genuine
anti-blast ramp" are different bars, and only the owner can say which risk is
worth the extra implementation cost.

---

## 6. Design summary (pending the §5 decision)

```
connectVolumeSeed(id, outputID), USER-CONNECT branch only:
  1. tier 1 — a device-reported volume arrived within the bounded listen window
     for THIS connect episode (new machinery — see T-I1/T-F1)
       → convert wire→UI domain via the setSpeakerVolume inversion (§2.3)
       → [§5 OPEN: clamp/ramp or not]
  2. tier 2 — DeviceVolumeStore has a persisted level for this device id
       → use it verbatim (already UI-domain, already a user-owned value —
         same "theirs to keep" logic the existing F-REBIND preserve branch uses)
  3. tier 3 — neither tier 1 nor tier 2 available (never-seen device)
       → connectVolumeProvider(), clamped to min/maxConnectVolume, exactly as today
The non-user-connect (F-REBIND) branch is UNCHANGED — it already preserves the
in-session level and this directive does not touch it.
```

---

## 7. Task breakdown

Investigation tasks first — **T-I1 is the load-bearing unknown and gates whether
tier 1 is worth building at all; T-I2 gates the ramp-vs-clamp shape.** Everything
under Implementation should wait for §5's owner decision at minimum, and T-F1
specifically waits on T-I1.

### Investigation-remaining

| # | Task | Scope | Depends on | Model + effort |
|---|---|---|---|---|
| **T-I1** | **Live protocol probe.** Against 2-3 real receivers spanning vendors (e.g. a Sonos, a HomePod or AirPort Express, one more AP1/AP2 device if available), log every `RemoteEvent`/DACP arrival with a wall-clock timestamp relative to `connect_addoutput_start`/`_resolved` (existing `Telemetry` events, `NativeBackend.swift:3703,3713`), for a device the receiver was left at a non-default volume on its OWN side before the Mac ever connected. Answers: does any receiver report its OWN volume unprompted, and if so, does it land before or after `connectVolumeSeed`'s own push in the same connect episode? This is THE gating question for whether tier 1 is buildable at all versus a fallback-only tier 2/3 design. | Live, owner (or an agent with hardware access). Telemetry-only, no code change needed beyond reading existing logs — `AIRPLAYENGINE_LOG_LEVEL` already prints wire-level volume lines per the AP1 curve doc comment (`NativeBackend.swift:5156`). | — | Owner (live) |
| **T-I2** | **Decide the §5 anti-blast shape with the owner** (no-clamp / cheap-ceiling-clamp / genuine ramp) before T-F1/T-F3 are scoped further — this is a product decision, not a technical one, and the recommendation in §5 is deliberately non-binding. | Discussion only. | — | Owner (discussion) |

### Implementation (do not start before T-I1/T-I2 land)

| # | Task | Scope / files | Depends on | Model + effort |
|---|---|---|---|---|
| **T-F1** | **Tier-1 bounded-listen mechanism**, if T-I1 shows it's worth building: a short-lived per-connect-episode listener keyed by `id`/`outputID` that captures the first `RemoteEvent.volume`/DACP report arriving within a bounded window (e.g. a few hundred ms, tunable) of the connect episode starting, feeding it into `connectVolumeSeed`'s user-connect branch INSTEAD of unconditionally pushing before any such report could arrive. Must reuse the exact wire→UI inversion `setSpeakerVolume` already does (§2.3) — do not duplicate the gain-invert math, factor it out if `connectVolumeSeed` needs it standalone. Must not regress the existing single-push-per-connect guarantee (`:5392-5410`) or the mute carve-out (`:5449-5457`). | `NativeBackend.swift` (`connectVolumeSeed`, `applyRemoteVolume`, `applyDacpVolume`, `setSpeakerVolume`'s inversion factored out), `NativeBackendTests.swift`. | T-I1 (only if it confirms a receiver reports early enough to matter) | Opus, **medium-high** (timing-sensitive, touches the F-REBIND-adjacent de-dup logic) |
| **T-F2** | **`DeviceVolumeStore`** (new file, mirrors `DeviceIconStore.swift` exactly: `Envelope{schemaVersion,volumes:[String:Int]}`, `device-volumes.json`, same directory, injectable for tests). Load at backend `start()`/first discovery merge to seed `known[id].volume` for a device with no live session yet (so tier 2 is available even before this connect episode's `mapDiscovered` runs); this only affects the STORED value used by tier 2/3 lookups, never bypasses `mapDiscovered`'s existing merge logic (§2, `merge(existing:discovered:)`, `:5079-5111`). | New `DeviceVolumeStore.swift` (+ its test file), `NativeBackend.swift` (load-at-start wiring, injected like other stores). | — (independent of T-F1) | Sonnet, **medium** |
| **T-F3** | **Write-through wiring**: persist a UI-domain volume via `DeviceVolumeStore.save` from the write points identified in §4.2 (`setSpeakerVolume`, `setVolume`, and `connectVolumeSeed`'s own seed write per §4.3's sub-decision), debounced/coalesced so a slider drag doesn't hit disk per tick. Resolve §4.3 (persist tier-3 fallback on first use?) explicitly rather than silently picking one. | `NativeBackend.swift`, `AppDelegate` or wherever the backend is composed (`makeBackend`) for store injection. | T-F2 | Sonnet, **medium** |
| **T-F4** | **Rewire `connectVolumeSeed`'s user-connect branch** to the 3-tier order from §6, applying whatever T-I2 decided for §5's clamp/ramp question on tier 1. Update the doc comment block (`:5358-5427`) to describe the new priority order — it currently documents ONLY the fixed-default behavior and will actively mislead the next reader once this lands. | `NativeBackend.swift` (`connectVolumeSeed`). | T-F1 (if built) or a tier-1-absent variant, T-F2/T-F3 | Opus, **medium** (the existing de-dup/F-REBIND/mute-carve-out invariants around this function are dense and easy to regress) |
| **T-F5** | **Tests.** Hermetic coverage: tier 1 present → used (with the §5 clamp/ramp behavior verified); tier 1 absent, tier 2 (persisted store) present → used verbatim, unclamped; neither present → falls to tier 3 exactly as today (regression coverage for the existing `connectSeedsEngineVolumeFromConfiguredDefault` / `autoRecoveryReconnectPreservesInSessionVolume` / `secondReconnectReseedsFromCurrentConnectVolume` tests at `NativeBackendTests.swift:1900,1996,2145` continuing to pass unchanged, since F-REBIND is untouched); a fresh `DeviceVolumeStore` round-trips UI-domain values correctly across a simulated restart (new backend instance, same injected directory). | `NativeBackendTests.swift`, new `DeviceVolumeStoreTests.swift`. | T-F1..T-F4 | Sonnet, **medium** |
| **T-F6** | **Docs.** Update `AudioutCore/AGENTS.md`'s "Every real (re)connect must reseed the engine volume" rule (currently describes only the fixed-default + F-REBIND-preserve shape) to name the new 3-tier order and the persisted store, and update the Settings UI copy/hint (`AudioutSettingsUI/AudioSettingsViewController.swift:266,279`, "Volume when connecting a speaker") if the connect-default's role changes user-visibly (it becomes "used only for a device we've never seen," which may be worth saying in the settings hint). | `AudioutCore/AGENTS.md`, `AudioutSettingsUI/AudioSettingsViewController.swift`. | T-F4 | Sonnet, **low** |

**Execution note.** T-F2 (the persistence store) is fully independent of the tier-1
protocol question and can be built and tested in parallel with T-I1 today — it is
useful regardless of what T-I1 finds, since tier 2 is needed either way. T-F1 is
the only task genuinely gated on live hardware findings.

---

## 8. Standing project rules the executing agent MUST honor

- **`main` is merge-only.** Author everything in a worktree; never commit on
  `main`, never edit the `main` checkout. See root `AGENTS.md`.
- **Docs orient, code decides.** Every claim in this file carries a `file:line`;
  re-verify before acting on it — line numbers move.
- **Vendored C stays byte-identical** (`AirPlayEngine/docs/VENDORED-DIFFS.md` for
  any exception) — nothing in this plan requires touching the C sender/receiver
  code; all new work is Swift-side.
- **Inner loop is `swift test --filter <Suite>`**; the full run is
  `scripts/run-tests.sh`, never a bare `swift test`. See `AudioutCore/AGENTS.md`.
- **`Telemetry.log` is never called from the IOProc/render path** — irrelevant
  here (nothing in this plan touches the render path), but keep any new logging
  off it regardless.

---

## 9. Key file:line index (`main` @ 2042de1)

| What | Where |
|---|---|
| The seed function | `NativeBackend.swift:5428-5462` |
| Its doc comment (−30 dB trap, F-REBIND, de-dup) | `NativeBackend.swift:5358-5427` |
| `userConnectSeed` declaration + sole insert site | `NativeBackend.swift:590`, `:1822-1829` |
| The two add-success call sites | `NativeBackend.swift:3746` (`convergeDevice`), `:4844` (`applyEngineState`) |
| `stashedVolume` / `known` declarations | `NativeBackend.swift:551`, `:278` |
| `AppSettings.connectVolume` + min/max/default | `AppSettings.swift:169,177,180,198-209` |
| Settings UI row | `AudioutSettingsUI/AudioSettingsViewController.swift:96-103,242-274` |
| Wire→UI inversion pattern to reuse | `NativeBackend.swift:4991-5007` (`setSpeakerVolume`) |
| UI→engine domain conversion, Main×Group×Device | `NativeBackend.swift:5179-5199` (`engineVolume(forID:uiVolume:)`) |
| RTSP connect sequence table (SET_PARAMETER only, no GET) | `AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c:3735-3790` |
| Push-only volume math (sender is the authority) | `airplay.c:1674`, `:1888-1953`, `:1958-1968` |
| Reverse `/event` channel volume parse (receiver-initiated push) | `AirPlayEngine/Sources/CAirPlayEngine/sender/airplay_events.c:336-391`, `:477-557` |
| DACP receiver→sender volume callback (the real path for Sonos) | `AudioutCore/Sources/AudioutCore/DACPServer.swift:17-28,292-314` |
| `RemoteEvent`/`RemoteEventHub` plumbing | `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:1780-1830`, `AirPlayTypes.swift:150-153` |
| Swift-side receiver-volume handlers | `NativeBackend.swift:4901-4956` (`subscribeRemoteEventStream`, `applyRemoteEvent`, `applyRemoteVolume`, `applyDacpVolume`) |
| Device id stability (colon-hex MAC) | `Device.swift:39`, `NativeDiscovery.swift:48-49` |
| Closest persistence analog to copy | `AudioutCore/Sources/AudioutCore/DeviceIconStore.swift` (whole file) |
| Existing test coverage to preserve (regression floor) | `NativeBackendTests.swift:1900,1996,2145` |
