# P2b — NativeBackend gap analysis: everything `OutputBackend` promises that `AirPlayEngine` doesn't yet provide

Research brief for **T-BACKEND-1** (PLAN-PHASE-2.md Wave 4). Read-only pass over
`AudioutCore/` and `AirPlayEngine/` — no code or other docs touched.
Companion investigations are running against `AirPlayEngine/` internals
concurrently; this brief only reads it.

**The question:** `OwnToneBackend` is the reference implementation of
`OutputBackend` — it's had to solve device discovery, volume mapping, error
surfaces, zombie recovery, and audio delivery against a real (if spike-grade)
server. `AirPlayEngine` is a session-primitives actor (`start`/`stop`,
`updateDiscovery`, `addOutput`/`removeOutput`/`setVolume`/`write`) with **no**
opinion on any of that. For each thing the UI (via `OutputBackend`) or
`OwnToneBackend`'s behavior currently relies on, what does the engine already
have, what's missing, and who has to build it — `NativeBackend` itself, or
something the app already owns (discovery, capture) that just needs rewiring?

---

## 1. The seam being filled

```
GroupController / UI
        │  (OutputBackend protocol — OutputBackend.swift:31-58)
        ▼
OutputBackend  ◄── NativeBackend (NEW, T-BACKEND-1)  ◄── AirPlayEngine (actor, DONE T-API-1)
        ▲
        └── OwnToneBackend (reference impl, DONE — talks to OwnTone's JSON API instead)
```

`NativeBackend` must present the *exact same* `BackendEvent`-driven contract
`OwnToneBackend` presents, but its dependency is `AirPlayEngine` (a thin,
session-only Swift actor over the vendored C sender), not a JSON+websocket
server. Where `OwnToneBackend` gets something "for free" via an HTTP GET,
`NativeBackend` gets nothing for free — the engine only tracks what it was
explicitly told (`updateDiscovery`) and what state a session op resolved to.

---

## 2. Requirement-by-requirement gap table

### 2.1 `var devices: [Device]` (OutputBackend.swift:35)

- **OwnToneBackend**: `stateQueue.sync { order.compactMap { known[$0] } }` —
  `known`/`order` built from polling `GET /api/outputs` (OwnToneBackend.swift:63,
  115-117, 250-263).
- **Engine has**: `knownOutputs: [OutputID: OutputState]` (AirPlayEngine.swift:91)
  — but it's `private` (not even `internal` beyond the module) and only tracks
  `OutputState` (stopped/startup/connected/streaming/failed/passwordRequired),
  **not** a `Device` (no name, kind, volume, isMuted, isSelected, isAvailable).
- **Missing**: the engine has no notion of `Device` at all — it's the wrong
  layer for it (SPEC §4: engine stays UI/app-agnostic, no OwnTone-shaped
  concepts, and critically **no discovery ownership** — see §2.2). `NativeBackend`
  must own its own `[String: Device]` map exactly like `OwnToneBackend.known`,
  built from (a) what the app's discovery layer resolved and (b) engine session
  state callbacks — there is no `GET /api/outputs` equivalent to poll.
- **Size**: same shape of state as `OwnToneBackend` already has (small — copy the
  pattern), but the *inputs* differ completely (see below).

### 2.2 Discovery ownership — `start()` / `deviceAdded` (OutputBackend.swift:38)

- **OwnToneBackend**: discovery is **implicit** — OwnTone (the external process)
  already has mDNS bound and enumerates AirPlay receivers into `/api/outputs`
  before the Swift process ever runs; the poll loop just reads what's there
  (OwnToneBackend.swift:250-263). `NativeBackend` gets no such gift.
- **Engine has**: `updateDiscovery(_ descriptor: DeviceDescriptor) async throws
  -> OutputID` and `removeDiscovery(_:)` (AirPlayEngine.swift:269-284) — but per
  the type's own doc comment, **"Discovery is app-owned (Q5)"** and PLAN-PHASE-2.md
  Q5 resolved this explicitly: *"App/Phase-1 owns discovery (NWBrowser); the
  engine takes a fully-resolved output descriptor… Cuts the entire `mdns.h`
  dependency out of the C core"* (PLAN-PHASE-2.md, Q5 block). The engine is a
  pure **consumer** of `DeviceDescriptor`s — it does zero mDNS browsing itself.
- **Missing — this is the biggest gap in the whole brief**: nothing in the repo
  today runs an `NWBrowser` for `_airplay._tcp` and feeds
  `AirPlayEngine.updateDiscovery`. `OwnToneBackend.start()` never needed one
  because OwnTone did its own mDNS. `NativeBackend.start()` MUST:
  1. Own (or receive injected) an `NWBrowser` for `_airplay._tcp` (and probably
     `_raop._tcp` for AirPlay-1-only receivers, per `p1-owntone-api-brief.md`
     §1's `"AirPlay 1"` observation — confirm scope: does the engine's vendored
     `airplay.c` cluster handle AP1 devices at all, or AP2-only? `seam-map.md`
     §0 doesn't mention raop.c being *ported*, only *read for the ALAC verdict*
     — treat AP1 receivers as **out of scope for NativeBackend v1** unless a
     sibling investigation says otherwise).
  2. On each resolved service, build a `DeviceDescriptor` (name, hostname,
     address, family, port, txtRecord — AirPlayTypes.swift:36-70) from the
     `NWEndpoint`/TXT record and call `engine.updateDiscovery(descriptor)`.
  3. Map the returned `OutputID` back to a `Device.id` (**format mismatch to
     resolve** — see §3 below).
  4. On an `NWBrowser` "endpoint removed" event, call `removeDiscovery` AND
     emit `.deviceRemoved`/mark-unavailable exactly like `OwnToneBackend`'s
     `markUnreachable` does for the whole-backend-down case (OwnToneBackend.swift:317-330)
     — except here it's per-device, driven by mDNS TTL/departure, not a health-check.
- **This NWBrowser does not exist yet anywhere in `AudioutCore`** —
  confirmed by grep; the only discovery-shaped code today is `OwnToneBackend`
  reading OwnTone's own list. **This is new code, not a rewire**, and it's on
  the critical path before anything else in `NativeBackend` can work (nothing
  to `addOutput` without a discovered device).
- **Size**: medium-large — new `NWBrowser` wrapper + TXT-record parsing (name,
  `deviceid`, `features`, `model`) + lifecycle wiring. Not algorithmically hard
  (Network.framework's Bonjour browsing is well-trodden) but it's a wholly new
  component with its own edge cases (duplicate resolves, IPv4 vs IPv6 races,
  `.ready`/`.failed`/`.cancelled` state handling) that neither backend has had
  to write yet.

### 2.3 `setOutputSet(_ ids: Set<String>)` (OutputBackend.swift:57)

- **OwnToneBackend**: one HTTP call, `PUT /api/outputs/set`, replaces the whole
  selected set atomically server-side (OwnToneBackend.swift:222-240,
  p1-owntone-api-brief.md §1).
- **Engine has**: `addOutput(_ id: OutputID) async throws` and
  `removeOutput(_ id: OutputID) async throws` (AirPlayEngine.swift:317-347) —
  **per-device, one at a time, no bulk "set" primitive**.
- **Missing**: `NativeBackend.setOutputSet` must diff `ids` against its own
  currently-added set and issue N `addOutput`/`removeOutput` calls to converge
  — there is no atomic "replace the whole set" like OwnTone's. Two consequences
  neither `OutputBackend`'s doc comment nor `OwnToneBackend` have had to handle:
  1. **Partial failure mid-convergence.** If a group activation needs to add 3
     outputs and remove 1, and add #2 throws `sessionFailed`, what state is the
     `Device` list left in? `OwnToneBackend` never faces this because
     `outputs/set` is one atomic call (success/fail as a whole, modulo the
     silent-select-failure caveat it already guards). `NativeBackend` needs an
     explicit policy: best-effort (apply what succeeds, mark the failed device's
     `isSelected = false` + surface it) is the natural match for
     `BackendEvent.deviceUpdated`, matching how the UI already tolerates
     partial group state.
  2. **Ordering/concurrency.** `addOutput`/`removeOutput` are each a full
     async RTSP round-trip (arm→issue→await completion per
     outputs-dispatcher-contract.md §1). Firing N of them concurrently via
     `async let`/`TaskGroup` is almost certainly wanted for latency (matches a
     multi-speaker group "add all 3" feeling instant-ish), but the engine's
     `EngineThread` marshals all C calls onto **one thread** (seam-map risk R-B,
     AirPlayEngine.swift:69 "single engine thread") — concurrent Swift-side
     `async` calls are fine (they just queue onto that one thread via
     `engineThread.enqueue`/`run`), but `NativeBackend` should not assume
     wall-clock parallelism, only non-blocking concurrency.
- **Size**: medium — the diff-and-converge logic itself is small, but the
  partial-failure policy is a real design decision (see Open Questions).

### 2.4 `setVolume(_ volume: Int, for id: String)` / volume curve (OutputBackend.swift:51)

- **OwnToneBackend**: passes the UI's 0–100 int straight through to OwnTone's
  `PUT /api/outputs/{id}` `{"volume": N}` (0–100 scale) — p1-owntone-api-brief.md
  §1 confirms OwnTone does the 0-100→dB mapping server-side ("Scale is 0–100…
  approximately −30…0 dB at the AirPlay device"). **OwnToneBackend does zero
  curve math itself** — it's OwnTone's problem.
- **Engine has**: `setVolume(_ id: OutputID, _ volume: Double) async throws` —
  **0.0...1.0 normalized**, and it does its own mapping already:
  `device.pointee.volume = Int32((Double(device.pointee.max_volume) *
  normalized).rounded())` (AirPlayEngine.swift:372-378) — i.e. the engine maps
  normalized 0…1 onto the C device's own `max_volume` scale (whatever units
  `output_device.volume`/`max_volume` are in the vendored AirPlay protocol —
  presumably the AirPlay `SET_PARAMETER` volume field, which per the AirPlay
  spec is itself a **dB-ish value** (`-30.0` to `0.0`, with `-144.0` = mute) —
  **not verified in this brief**, flagged for whichever investigation reads
  `airplay.c`'s volume path (`airplay_set_volume_one`, referenced in
  outputs-dispatcher-contract.md §2).
- **Missing**: `NativeBackend.setVolume` must convert the UI's 0–100 int to the
  engine's 0.0–1.0 normalized double: trivial (`Double(volume) / 100.0`) IF
  the engine's own 0…1→`max_volume` mapping is linear and already matches the
  perceptual/dB curve the SPEC's "linear 0-100 maps to −30…0 dB" note (SPEC.md:241)
  describes. **This needs verification, not assumption**: `OwnToneBackend`
  inherited a *server-side* curve that was tuned by OwnTone's own developers;
  `NativeBackend` inherits whatever `airplay_set_volume_one` does with the raw
  `device->volume` field, which may or may not reproduce the same perceptual
  curve. If the engine's mapping is linear-0..1-to-raw-AirPlay-dB-range
  (plausible, since `-30..0` dB *is* roughly what AirPlay volume fields use),
  the two might coincidentally match — but this is exactly the kind of thing
  that needs an audible A/B check against a real receiver once one's available
  (per MEMORY.md: "speakers currently unavailable, mock rig primary"), flagged
  as a deferred real-hardware checkpoint, not a blocker for headless
  `NativeBackend` completion.
- **Mute (Q4)**: identical shim needed — the engine has no mute concept either
  (only continuous volume), so `NativeBackend` must replicate `OwnToneBackend`'s
  exact pattern: stash pre-mute volume, call `setVolume(id, 0)` on mute, restore
  on unmute (OwnToneBackend.swift:206-220, 460-467). This is a straight copy of
  already-proven logic — cheap.
- **Size**: small for the mechanical unit conversion + mute shim (copy
  `OwnToneBackend`'s pattern almost verbatim); **medium risk** (not size) for
  the curve-fidelity question, which needs a receiver to actually settle.

### 2.5 Device availability / unreachable / error surfaces

- **OwnToneBackend**: has a rich, brief-derived model — `markUnreachable()` on
  connection-refused (OwnToneBackend.swift:317-330), silent-select-failure
  detection (confirmSelectionOrRecover, :336-353), zombie de-selection
  detection+recovery (:265-315, 359-397), HTTP error-shape handling (brief §5).
  All of this exists because OwnTone is a **separate process reached over
  HTTP** that can be down, slow, or silently drop a selection.
- **Engine has**: nothing analogous, because the failure model is entirely
  different. The engine is in-process (an `actor`, not a subprocess+socket) —
  there's no "engine unreachable," only:
  - `AirPlayEngineError.engineNotRunning` — thrown synchronously if you call an
    op before `start()`/after `stop()` (AirPlayTypes.swift:126).
  - `AirPlayEngineError.sessionFailed` / `.passwordRequired` — a specific
    device's RTSP session failed/needs a PIN (thrown from `addOutput`,
    AirPlayEngine.swift:327-332).
  - `AirPlayEngineError.unknownOutput` — called an op on an id never discovered.
  - `AirPlayEngineError.operationRejected` — the C op returned N≤0 unexpectedly.
  - **No "zombie" concept at all.** The dispatcher contract
    (outputs-dispatcher-contract.md §1) guarantees **exactly one terminal
    callback per op** — there is no OwnTone-style "204 success but selection
    silently didn't stick" failure mode *for the op itself*, because the
    engine's completion IS the ground truth (it comes from the same C state
    machine that owns the RTSP session, not a second HTTP layer reporting on a
    third process). **This entire class of `OwnToneBackend` complexity (§1/§4
    of the OwnTone brief) may not have a NativeBackend equivalent** — worth
    treating as a pleasant simplification rather than porting the pattern
    defensively.
  - **What CAN still go wrong post-connection**: a receiver drops off Wi-Fi, a
    session dies mid-stream (RTSP connection closes — outputs-dispatcher-contract.md
    §4a/4b `session_failure`/`deferred_session_failure`), or PTP timing degrades.
    None of these currently have a **push notification path back to Swift** —
    `addOutput`/`removeOutput`/`setVolume` are request/response only. **Missing:
    an async "device state changed after the initial op resolved" event
    channel** — e.g. a session that was `.streaming` transitions to `.failed`
    minutes later with nothing watching. This is the engine-side analogue of
    OwnTone's zombie detection, and right now **nothing in `AirPlayEngine`'s
    public surface delivers it** (`knownOutputs` is updated internally per
    op-call, AirPlayEngine.swift:326/346, but there's no subscription/stream
    exposed for out-of-band transitions). **This is a real engine-side gap**,
    not just a `NativeBackend`-side wiring task — flag it for whichever
    investigation owns `AirPlayEngine`'s public API surface; `NativeBackend`
    cannot invent state changes the C dispatcher never reports.
- **Size**: `NativeBackend`'s own mapping of the 6 existing errors → `Device`
  state / thrown-away-vs-surfaced is small. The missing async device-state-
  change channel is a **cross-cutting gap that isn't NativeBackend's to fix**
  — either the engine needs a `makeStateStream()`-shaped API (mirroring
  `OutputBackend.makeEventStream()`) that surfaces `outputs_cb` deliveries the
  dispatcher already receives (outputs-dispatcher-contract.md §3 `deferred_cb`)
  even when nothing is actively awaiting them, or `NativeBackend` has to poll
  `stateOf`-equivalent (currently test-only, AirPlayEngine.swift:540) on a
  timer — an OwnTone-poll-loop pattern reborn, which would be a regression from
  the "engine completion IS ground truth" simplification above. **Recommend
  the former** (see checklist item 3).

### 2.6 `BackendEvent.level(id:rms:)` — metering (OutputBackend.swift:18-21)

- **OwnToneBackend**: does not emit this at all today (confirmed — grep of
  `OwnToneBackend.swift` shows no `.level` case emission anywhere in the file).
  `dev/notes/playback-meter-research.md` (existing brief, read for this gap
  analysis) confirms: the feature is designed but **not built**, and its
  Phase-B plan is "a real level signal from the capture side (`audiocap`
  computes peak/RMS already)" fanned out as **one shared value** across all
  selected/unmuted devices, because "the real pipeline is a single whole-system
  tap → one FIFO → OwnTone → fan-out" (playback-meter-research.md §0).
- **Engine has**: **nothing**. `AirPlayEngine.write(pcm:pts:)` is a fire-and-
  forget hot path (AirPlayEngine.swift:393-428) with no RMS/peak computation,
  no callback, and — architecturally — the engine never sees raw PCM levels
  as a *concept* distinct from the bytes it hands to `airplay_write`. Computing
  RMS on the engine side would mean adding per-frame math to the hottest path
  in the system for a display-only UI feature.
- **Missing / recommendation**: metering should **not** be `NativeBackend`'s
  or `AirPlayEngine`'s job at all. Per `playback-meter-research.md`'s own
  verdict, the level signal is **upstream of the engine** — it's a property of
  the *captured* audio (the same PCM `NativeBackend`'s caller feeds via
  `write(pcm:pts:)`), and it's identical for every selected device (one tap,
  fan-out). The natural owner is whatever component captures/taps system audio
  for the native path and calls `engine.write(pcm:pts:)` — it should compute
  RMS on the same buffer it's about to hand the engine and emit
  `BackendEvent.level` itself, exactly parallel to how `MockBackend` fabricates
  it on a timer today (playback-meter-research.md §0). **`NativeBackend` only
  needs to plumb that signal through its own event stream** (trivial — one
  more `case` in whatever emits `BackendEvent`s), not compute it. This reframes
  the "gap" from an engine problem to a capture-pipeline problem, which is
  already flagged as its own not-yet-built feature — do not block
  `T-BACKEND-1` on it; wire a pass-through and let the meter feature's own task
  fill in the emitter.
- **Size**: near-zero for `NativeBackend` itself (a pass-through case); the
  real work is the meter feature's own (already-scoped) task.

### 2.7 Capture-side integration — replacing the FIFO with `write(pcm:pts:)`

- **Current real path (`OwnToneBackend` + `CaptureCoordinator`)**: `audiocap`
  (a subprocess) taps system audio and writes raw PCM into a **named FIFO** on
  disk that lives in OwnTone's library directory; OwnTone treats the FIFO as a
  library "pipe" track and streams it out to AirPlay receivers itself
  (CaptureCoordinator.swift:1-47, 0f-pipe-brief.md). The Swift process **never
  touches PCM bytes** in this path — OwnTone's own C code reads the FIFO.
- **What changes for the native path**: `AirPlayEngine.write(pcm: Data, pts:
  timespec)` (AirPlayEngine.swift:393-428) expects **interleaved S16LE PCM,
  fixed 44100 Hz / 16-bit / 2ch** (`PCMFormat.airplay`, AirPlayTypes.swift:148-155)
  handed to it **directly, in-process, per buffer** — there is no FIFO, no
  file, no second process reading it. This is a fundamentally different
  integration shape:
  1. **No `mkfifo`, no library-dir path, no rescan-and-search-for-track-id
     dance** (CaptureCoordinator.swift:248-268, 375-390) — all of that
     `FIFOManaging`/`resolvePipeTrackURI`/`updateLibrary` machinery
     (0f-pipe-brief.md's entire config-follows-tap + explicit-play apparatus)
     is **OwnTone-specific and does not port**. A native-path capture
     coordinator is simpler in this one specific respect: there's no separate
     server to convince to play a file, you just call `write()`.
  2. **But a new concern appears that didn't exist before: `pts` sourcing.**
     `write(pcm:pts:)`'s doc says *"pass the capture clock's timestamp for A/V
     sync"* (AirPlayEngine.swift:388) — OwnTone's FIFO path has no such
     parameter at all (a FIFO is just a byte stream; OwnTone's own player
     clocks it against its own PTP-timed output pipeline). The native path
     pushes clock ownership INTO the caller: whatever captures audio (today,
     `audiocap`, a **subprocess** communicating over a FIFO or stdout pipe) has
     to also produce a `timespec` per buffer that the engine's PTP-synced
     AirPlay-2 sessions can align against. **Two sub-questions, unresolved by
     anything read in this brief:**
     - Does `audiocap` (the existing capture helper) currently emit any
       timestamp at all, or just raw bytes? (Not read in this brief — check
       `dev/audiocap/` sources; flagged as a checklist item, not answered here.)
       If not, a monotonic/host-time timestamp per buffer needs to be added at
       capture time, ideally the Core Audio input callback's own `AudioTimeStamp`
       (the natural, already-accurate source) rather than a wall-clock read at
       the point of handoff to `write()`.
     - **Process boundary**: today's capture is an out-of-process subprocess
       writing to a FIFO (RESOLVED Q2 in CaptureCoordinator.swift:5 — "capture
       runs as a SUBPROCESS"). `AirPlayEngine.write` is an **in-process Swift
       call** (`nonisolated func`, directly callable, no IPC). Does the native
       path keep audio capture as a subprocess (and then need an IPC channel —
       e.g. still a FIFO, or a Mach port / XPC — from `audiocap` into the main
       app process, which then calls `engine.write()`), or does capture move
       **in-process** (a Core Audio tap running inside the main app, calling
       `write()` directly with zero IPC)? This is a real architectural fork,
       not a detail:
       - **In-process capture** is simpler (no IPC, `pts` comes straight off
         the Core Audio callback) but reintroduces whatever motivated Q2's
         "runs as a SUBPROCESS" decision in the first place (TCC/entitlement
         isolation? crash isolation? — not stated in the file read here; check
         `PLAN-0e-0f.md`/`dev/notes/0e-taps-brief.md` for Q2's original
         rationale before assuming it still applies to the native path).
       - **Subprocess + IPC** preserves the existing `audiocap` binary and its
         proven TCC/permission model, but needs a new transport (the FIFO
         trick doesn't compose cleanly with "call an in-process Swift async
         function" — you'd need the subprocess to write frames to a pipe/socket
         that a new coordinator reads and re-dispatches into `engine.write()`,
         basically reinventing the FIFO but consumed by Swift instead of
         OwnTone's C).
     - **Recommendation for the brief**: reuse the subprocess shape (don't
       relitigate Q2 without reading its rationale first), but replace "write
       to a named FIFO scanned by OwnTone" with "write length-prefixed PCM
       frames + a timestamp to a **pipe (stdout or a dedicated fd) that a new
       `NativeCaptureCoordinator` reads in-process and forwards to
       `engine.write(pcm:pts:)`* — this keeps the subprocess/TCC boundary
       intact while eliminating the FIFO-as-library-track indirection
       entirely. This is a **new, small wire protocol** (frame length + pts +
       PCM bytes) that doesn't exist today — `audiocap`'s current output
       format (not read in this brief) may or may not already support this;
       check before assuming a rewrite is needed vs. just adding a pts field.
  3. **Suspend-to-pause / zombie-replay (`replayHook`) has no native
     equivalent to port** — that whole mechanism existed because OwnTone's FIFO
     player suspends-to-pause on EOF and needs an explicit re-kick
     (0f-pipe-brief.md, CaptureCoordinator.swift:218-238). The native path's
     failure modes are whatever §2.5 above found (session failures reported
     via the engine, not a paused-file-player) — a **new, much simpler**
     "capture crashed / engine session failed → restart" policy replaces it,
     not a port of the existing one.
- **Size**: this is the **second-largest gap after discovery** — a new
  `NativeCaptureCoordinator`-shaped component, a new (probably small) wire
  protocol between `audiocap` and it (or an in-process capture rewrite,
  pending the Q2-rationale check), and PTS sourcing that doesn't exist in any
  form today. Do not estimate this as "port CaptureCoordinator" — structurally
  it's a rewrite with a different (simpler) state machine, not an edit.

---

## 3. Identity/type mismatches to resolve (small but load-bearing)

- **`Device.id: String` vs `OutputID` (`UInt64` wrapper).** `OutputBackend`'s
  whole contract is keyed on `String` ids (`Device.id`, every method's `for
  id: String` parameter — OutputBackend.swift, Device.swift:39). The engine's
  primitive is `OutputID` (AirPlayTypes.swift:15-19, a `UInt64` wrapping the
  parsed `deviceid` TXT value, printed as `0x%016llX`). `NativeBackend` needs a
  stable, **round-trippable** `String ⟷ OutputID` mapping — the obvious choice
  is `OutputID.description` (`"0x...016llX"`) as the `Device.id` string, or the
  raw `deviceid` colon-hex string from the TXT record verbatim (matches what a
  human/log would recognize, and is already what `DeviceDescriptor.parsedID`
  parses FROM — round-tripping through the original TXT string avoids a
  lossy/format-specific reconstruction). Recommend keeping the **original
  colon-hex TXT string** as `Device.id` (never reformat it), and maintain a
  private `[String: OutputID]` lookup table in `NativeBackend`, analogous to
  how `OwnToneBackend` treats OwnTone's numeric-looking-but-string `id` as an
  opaque string per the OwnTone brief's #1 footgun warning (p1-owntone-api-brief.md
  §1) — same lesson, different backend: **never let an internal numeric id
  leak into `Device.id` in a lossy/reformatted way.**
- **`Device.kind` heuristic** (`OwnToneBackend.kind(for:isAirPlay:)`,
  OwnToneBackend.swift:425-432) name-sniffs the OwnTone output's `name` string
  for "homepod"/"apple tv"/"sonos"/etc. `NativeBackend` has the **same** raw
  material available — `DeviceDescriptor.name` (the mDNS service instance name)
  and the TXT record's `model` key (already called out as present in the AP2
  TXT records per seam-map's own reading, and per AirPlayTypes.swift:53's doc
  comment: *"`model` is used for the reconnect/keep-alive heuristic"*) — model
  is actually **better** signal than `OwnToneBackend`'s name-substring hack, so
  this can likely be a straight (small) improvement, not just a port.
- **`Device.supportsAirPlay2`** — `OwnToneBackend` derives this from OwnTone's
  reported `type` field (`"AirPlay 2"` vs `"AirPlay 1"`, brief §1). Since
  `NativeBackend`'s whole engine IS an AirPlay-2 sender (per seam-map.md's
  scope), every device it can successfully `addOutput` to is by construction
  AirPlay-2-capable — **unless** AirPlay-1-only devices are in scope (see §2.2
  above's open question about raop.c). If AP1 is out of scope, this field is
  simply always `true` for `NativeBackend` devices — a simplification, not a
  gap.

---

## 4. Walls / risks, ranked

1. **Discovery ownership has no code yet (§2.2).** This blocks everything else
   — nothing can be added to the engine without a resolved `DeviceDescriptor`,
   and nothing in the repo produces one today. It's also the most likely place
   to hide real-world flakiness (Bonjour resolve races, stale TXT records,
   IPv4/IPv6 duplicate resolves) that neither backend has had to deal with,
   because `OwnToneBackend` inherited OwnTone's already-hardened mdns.c.
2. **The capture-side rewrite (§2.7), specifically `pts` sourcing and the
   subprocess/in-process fork.** This is the one place where "just implement
   the protocol" isn't enough — it's a design decision (in-process vs.
   subprocess+new-wire-protocol) that should probably be its own investigation
   or at least its own Open Question resolved before `T-BACKEND-1` starts, not
   discovered mid-implementation. Getting `pts` wrong doesn't fail loudly — it
   desyncs multi-room audio quietly, the worst kind of bug for exactly the
   PTP-synced-multi-speaker feature this whole engine exists for.
3. **The missing async device-state-change channel (§2.5).** Not filled by
   `NativeBackend` alone — needs an `AirPlayEngine` API addition (something
   like `makeStateStream()`) or `NativeBackend` regresses to polling
   `stateOf`-equivalent, undermining the "engine completion is ground truth"
   simplification that's otherwise a real win over `OwnToneBackend`'s
   poll-and-diff complexity. Flag to whichever investigation owns
   `AirPlayEngine`'s public surface before `T-BACKEND-1` is implemented, so the
   API exists to consume rather than being bolted on after.
4. **Volume curve fidelity (§2.4)** — lower severity than the above three
   because it fails *quietly good-enough* (some volume mapping will exist,
   just possibly not perceptually matched to OwnTone's), and is explicitly a
   deferred-until-real-hardware verification per project norms (Phase 0 already
   treats "audible on Sonos" as a separate checkpoint from "API call succeeds").
5. **`setOutputSet` partial-failure policy (§2.3)** — a real design gap but
   low blast radius (worst case: a group activation partially fails and the
   UI shows an accurate-if-ugly mixed state) and has an obvious-enough default
   (best-effort + per-device `deviceUpdated`) that it shouldn't block starting
   implementation, just needs an explicit decision recorded (see Open
   Questions).

---

## 5. Recommended approach (summary)

Build `NativeBackend` as a **fresh implementation of the `OwnToneBackend`
pattern** (own `known`/`order` state, `stateQueue`-style confinement,
`BackendEvent` emission), NOT a refactor of `OwnToneBackend` — the two share a
protocol, not an implementation shape. Reuse only: the mute-via-stashed-volume
shim (§2.4), the general "state machine + `onStateChange`" style of
`CaptureCoordinator` (as a pattern, not its code) for a new capture
coordinator, and the `Device.id`-as-opaque-string discipline. Do not reuse:
the poll loop, zombie detection, HTTP error handling, or FIFO/library-scan
machinery — none of it applies to an in-process engine.

---

## 6. Implementation checklist (dependency-ordered, sized)

1. **Resolve the capture architecture fork (§2.7.2) as an explicit decision**
   before writing code — read `dev/audiocap/` sources + whatever doc holds Q2's
   original subprocess rationale (check `PLAN-0e-0f.md`, `0e-taps-brief.md`) to
   confirm it still applies to the native path, then pick in-process vs.
   subprocess+wire-protocol. *(size: small — research/decision, not code;
   ideally resolved before or alongside this brief, not deferred into
   T-BACKEND-1's implementation.)*
2. **`NativeDiscovery` — NWBrowser wrapper for `_airplay._tcp`** producing
   `DeviceDescriptor`s and forwarding appear/disappear to
   `AirPlayEngine.updateDiscovery`/`removeDiscovery`. Own `OutputID ⟷ String`
   (colon-hex TXT id) mapping here since discovery is where both forms of the
   id are naturally in hand at once. *(size: medium-large — new component, no
   existing code to lean on beyond generic Network.framework patterns.)*
3. **Engine-side: add an async device-state-change stream** (or confirm/flag
   to the AirPlayEngine-owning investigation that this is needed) so
   `NativeBackend` doesn't have to poll. If genuinely out of scope for now,
   `NativeBackend` should poll `stateOf` on a timer as an explicit, documented
   fallback (mirroring `OwnToneBackend`'s poll loop) rather than silently
   having stale state. *(size: depends entirely on whether this is a
   NativeBackend-side workaround (small: a timer + diff) or an AirPlayEngine
   API addition (someone else's medium task) — flag and pick before
   proceeding.)*
4. **`NativeBackend` core**: `devices`/`start`/`stop`/`makeEventStream` +
   internal `known`/`order` state, wired to (2)'s discovery events and (3)'s
   state-change signal. *(size: medium — same shape as
   `OwnToneBackend`'s equivalent ~120 LOC, new wiring.)*
5. **`setOutputSet` diff-and-converge** over `addOutput`/`removeOutput`, with
   an explicit best-effort partial-failure policy (see Open Questions #1).
   *(size: small-medium.)*
6. **`setVolume`/`setMuted`** — unit conversion (0-100 int → 0.0-1.0 double) +
   ported mute-stash shim from `OwnToneBackend.swift:206-220`. *(size: small.)*
7. **`NativeCaptureCoordinator`** (new type, shaped by decision #1): spawn/attach
   capture, source `pts`, call `engine.write(pcm:pts:)` per buffer, surface
   crashes/failures as `Device`-level unavailability (no FIFO/rescan/pipe-track
   machinery to port — simpler state machine than `CaptureCoordinator`, see
   §2.7.3). *(size: medium-large — new component; size depends heavily on
   decision #1's outcome.)*
8. **Level metering pass-through**: whatever component ends up computing RMS
   (per playback-meter-research.md, likely (7)'s capture coordinator) emits
   `BackendEvent.level` into the same stream (4) drives. *(size: near-zero for
   NativeBackend; real work lives in the meter feature's own task — don't
   duplicate scope here.)*
9. **`BackendKind.native` + `AIRPLAY_BACKEND=native` + `makeBackend` case**
   (OwnToneBackend.swift:481-513's pattern) + `BackendKindResolutionTests`
   extension — already scoped as T-BACKEND-1b in PLAN-PHASE-2.md:415-416.
   *(size: haiku/low, per the plan's own estimate.)*
10. **Verification**: `AIRPLAY_BACKEND=native swift run mock-speakers-demo`
    against the harness from T-HARNESS-2, then the deferred real-hardware
    checkpoint (volume curve fidelity §2.4, AP1-scope question §2.2/§3) once
    speakers return (MEMORY.md: "speakers currently unavailable, mock rig
    primary"). *(size: n/a — verification, not a build task.)*

---

## Open questions for ahh

1. **`setOutputSet` partial-failure policy (§2.3, §4.5)**: when converging a
   group activation requires adding N outputs and one fails mid-way, should
   `NativeBackend` (a) apply what succeeded and surface the failed device as
   unavailable (recommended — matches how the UI already tolerates partial
   device state), (b) roll back everything it just added, or (c) something
   else? This wasn't a question `OwnToneBackend` ever had to answer (OwnTone's
   `outputs/set` is atomic server-side).
2. **AirPlay-1 device scope (§2.2, §3)**: does `NativeBackend` v1 need to
   support AirPlay-1-only receivers (the fake "Verify Receiver" fixture in the
   OwnTone brief is AP1) at all, or is v1 explicitly AirPlay-2-only, with AP1
   receivers simply not appearing as controllable devices until/unless a later
   task ports `raop.c`? Affects whether the discovery browser needs to watch
   `_raop._tcp` in addition to `_airplay._tcp`.
3. **Capture architecture (§2.7.2, checklist #1)**: in-process Core Audio tap
   calling `engine.write()` directly, or keep the existing `audiocap` subprocess
   shape with a new (FIFO-replacing) wire protocol into a new coordinator?
   This is a real fork with a real cost difference and probably deserves either
   a dedicated short investigation or a quick decision from whoever knows why
   Q2 (0e/0f phase) chose "subprocess" originally (TCC isolation? crash
   isolation? something else not visible in the files this brief read).
4. **Device-state-change channel (§2.5, checklist #3)**: should this land as
   an `AirPlayEngine` API addition (cleaner, but means `NativeBackend` depends
   on engine work outside T-BACKEND-1's own scope) or a `NativeBackend`-side
   poll loop (self-contained, but reintroduces the poll-and-diff pattern the
   native path was supposed to obsolete)? Worth flagging to whoever is running
   the `AirPlayEngine`-focused investigation in parallel with this one.
