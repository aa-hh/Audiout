# v2 small work — Auto-reconnect + EQ/L-R balance — Design Brief

Task T-p2b (combined, light). Two independent SPEC.md §3 v2 items designed
together so implementation later is mechanical. Neither needs new
infrastructure; both slot into existing seams (`GroupController`,
`OutputBackend`, `MixerViewController`). Read alongside the sibling
`p2b-multistream-brief.md` for the per-app mix architecture referenced in
Part 2 — not duplicated here.

---

## Part 1 — Auto-reconnect

### The question

SPEC.md §3 v2: "**Auto-reconnect** a group when its devices come back
online." When does this fire, what does it do, and where does the logic
live so it doesn't fight the user's own manual choices?

### Findings (with evidence)

**Availability is already a first-class, event-driven concept.**
`Device.isAvailable` (`AirPlayControllerCore/Sources/AirPlayControllerCore/Device.swift:46`)
is documented explicitly for this: *"A dropped device stays in the model
(greyed out) rather than vanishing, so groups keep their membership."* The
model was built with auto-reconnect in mind — it just isn't wired up yet.

**The backend already emits the exact edge we need.** `OwnToneBackend`
flips `isAvailable` false→true and true→false purely through
`BackendEvent.deviceUpdated` (`OwnToneBackend.swift:9`, enum doc: *"Any
field of a device changed — volume, mute, availability, selection."*).
Concretely:
- Drop: `markUnreachable()` sets every known device's `isAvailable = false`
  and emits `.deviceUpdated` (`OwnToneBackend.swift:317-330`).
- Reconnect: `merge(existing:polled:)` is where a device becomes available
  again — `mapOutput` always stamps `isAvailable: true` for anything the
  current poll actually sees, and merge lets the polled value win for
  availability precisely so "a successful poll means the device IS
  reachable" (`OwnToneBackend.swift:403-413`, `437-444`). `applyPoll` diffs
  against `self.known` and only emits `.deviceUpdated` when the merged
  device differs from the existing one (`OwnToneBackend.swift:296-300`) —
  so the false→true transition is a real, singular event, not a poll-storm
  of repeats.
- There is no separate `deviceAdded` on reconnect — a device that was
  merely unavailable, not removed, stays in `known`/`order` the whole time,
  so the transition always arrives as `.deviceUpdated`, never
  `.deviceAdded`. (`deviceAdded` is reserved for genuinely new ids,
  `OwnToneBackend.swift:301-305`.)

**Where group activation already lives.** `GroupController.activateGroup(id:)`
(`GroupController.swift:424-434`) is the single existing choke point that
sets the output set to exactly a group's members and re-applies remembered
per-member volumes. Auto-reconnect's job is simply to decide *when* to call
something equivalent to this again — it should not duplicate that logic.

**Main Out already distinguishes "pointed at a group" from "ad hoc
selection".** `mainOut: MainOutTarget` (`GroupController.swift:72`,
`262-284`) is persisted (`RoutingStore`, referenced at
`GroupController.swift:88,124`) and is the *only* thing that routes audio
(§9b model, `GroupController.swift:55-72` doc block). This means "last
active group" is not a new concept to invent — if `mainOut == .group(id:)`,
that group id already survives an app relaunch. The gap is only: when
`mainOut` is `.group(id:)` and some members are currently unavailable, nothing
currently re-applies `setOutputSet` when they come back — `applyRouting()`
is called only on explicit `setMainOut`/`setDeviceSelected`
(`GroupController.swift:262-284`), never in response to a `BackendEvent`.

**No listener currently exists for `BackendEvent` inside `GroupController`
at all.** `GroupController` is a pure model driven by explicit method calls
from the UI layer (menu/window), not a `BackendEvent` subscriber itself —
the app (`AppDelegate`/harness) owns the `makeEventStream()` loop and calls
UI-refresh methods. Confirmed by grep: `GroupController.swift` has no
`makeEventStream` or event-loop code. So today, if a group member reconnects
mid-session, the backend fixes `isAvailable` (row un-greys), but the output
set is not re-applied — the device shows as available yet may not be
receiving audio again (OwnTone won't auto-resume a stream to an output
that quietly dropped and came back, since Q7's zombie-recovery path
(`OwnToneBackend.swift:355-397`) only fires for *unexpected* silent drops
of *currently expected-selected* outputs, not for a `.deviceUpdated`
availability flip from `markUnreachable`/poll miss).

**User-intent must not be overridden.** SPEC.md §9b: Selected Devices is a
persistent user-composed set; Main Out is the explicit routing decision.
Auto-reconnect must never re-add a device the user manually removed from
`selectedDeviceIDs` or manually deselected from a group's membership (that
would fight `setDeviceSelected(_:false)`). It should ONLY restore the
*routing/output-set* for a target the user has already told the app to
route to (`mainOut`) — the group's own membership is unaffected, only
whether currently-`isSelected` reality matches `mainOut`'s intended member
set.

### Recommended approach

1. **Trigger surface: `GroupController` gains an event-consuming method**,
   e.g. `handleBackendEvent(_ event: BackendEvent)`, called by whoever
   already owns the `makeEventStream()` loop (the app/harness), right next
   to (or folded into) the existing device-refresh call. `GroupController`
   stays a pure model — it does not itself own an `AsyncStream` subscription
   — consistent with how it's built today (no async infra inside the
   class; `backend` is just an `OutputBackend` it calls methods on).

2. **Debounced re-apply, not per-event re-apply.** A flaky device can
   bounce available→unavailable→available within a poll cycle or two.
   Naive "re-apply routing on every `.deviceUpdated` where `isAvailable`
   flipped true" risks redundant/rapid `setOutputSet` calls when several
   group members reconnect in the same poll batch (very likely — OwnTone
   polls the whole outputs list and reconnect after a network blip tends to
   bring back multiple speakers together, see `applyPoll`,
   `OwnToneBackend.swift:267-314`, which already batches all adds/updates
   from one poll before returning). Debounce: collect availability-flip
   events for the current group's members within one poll batch and
   re-apply once, not per-device. In practice this is nearly free since
   `applyPoll` already processes a whole poll synchronously under
   `stateQueue.sync` — `GroupController` just needs to batch anything
   arriving in the same run-loop turn (e.g. a `Task`-coalesced trailing
   re-apply after a very short debounce window, ~200-500ms, rather than
   reacting inside the tight `stateQueue.sync` callback).

3. **The re-apply condition** (only fires when ALL of these hold):
   - `mainOut == .group(id:)` for some group `g` (i.e. the user is actively
     routed to a saved group — do nothing for `.selectedDevices`, since
     that's an ad hoc set the user built by hand and reconnect there would
     be surprising/unrequested — SPEC doesn't ask for "auto-reconnect
     Selected Devices", only "a group").
   - The event's device id is a member of `g.memberIDs`.
   - The device's `isAvailable` flipped false→true (compare against the
     previously known snapshot — `GroupController` would need to track
     "was this member unavailable last time we looked", mirroring the
     backend's own `wasSilent`-style edge-detection pattern already used
     for mute, `GroupController.swift:616-628`).
   - The device is NOT currently `isSelected` in the backend's live output
     set (i.e. it really did drop out of the actual output set — if OwnTone
     itself silently kept it selected the whole time, e.g. a brief network
     blip that didn't touch selection state, there's nothing to reconnect).
   - Re-apply = re-call the equivalent of `activateGroup(id: g)`'s output-set
     half: `backend.setOutputSet(Set(g.memberIDs))` intersected with
     whatever is *currently available* (do not attempt to select a device
     that's still down) — plus re-push `g.memberVolumes` for the
     newly-rejoined member only (not clobber a volume the user changed on a
     still-connected sibling member mid-session). This is a narrower
     re-apply than a full `activateGroup` — it should not reset volumes
     for members that never dropped.

4. **"Last active group" persistence — already exists, reuse it.** Do NOT
   add a new persisted field. `mainOut`'s `.group(id:)` case persisted via
   `RoutingStore` (`GroupController.swift:88, 121-125`) already IS "last
   active group that the app should keep routed to," including across app
   relaunch. Auto-reconnect is just: keep honoring that persisted intent
   when availability changes, instead of only reacting to explicit user
   actions. No new store, no new schema version.

5. **Don't fight manual deselection.** Because the trigger only fires for
   ids in `g.memberIDs` (the group's *saved* membership, edited only via
   `saveGroup`/`createGroup`), and never touches `selectedDeviceIDs`, a user
   who used `setDeviceSelected(id, false)` to manually drop a device from
   the *ad hoc* Selected Devices set is completely unaffected (different
   code path, `mainOut != .group` in that flow). Within an active group,
   there is currently no "temporarily exclude this one member without
   editing the saved group" affordance exposed in the model — if one gets
   added later, auto-reconnect must check it before re-adding a member (an
   open question below).

### Interaction with per-app routing / multistream (v2)

Per SPEC §3 v2, Main Out coexists with per-app routing in the destination
picker (`NSPopUpButton` offering groups + individual speakers + "This Mac").
Auto-reconnect's scope here is still just Main Out's group target — the
per-app routing table (app → destination) is a separate mapping the
multistream brief owns; if a per-app route points at a group whose member
reconnects, the same reasoning applies but through whatever seam
`p2b-multistream-brief.md` designs for re-resolving a per-app destination's
live output set. Flag this explicitly as a follow-up once that brief lands
— don't design it twice.

### Walls / risks (ranked)

1. **Debounce window tuning is a guess without real hardware.** Phase 0
   notes flag speakers are currently unavailable for live testing (memory:
   "speakers currently unavailable, mock rig primary"). A 200-500ms window
   is a reasonable starting point (matches typical Bonjour/AirPlay
   re-announce timing) but needs validation against a real flaky-Wi-Fi
   scenario, not just the mock rig's synthetic drop/reappear.
2. **Partial-group reconnect ordering.** If a group has 3 members and they
   reconnect across 2 separate poll cycles (not simultaneously), a naive
   debounce could either (a) fire twice — extra `setOutputSet` churn but
   harmless — or (b) fire once too early and miss the second member. Needs
   an explicit test (see checklist) rather than assuming poll batching
   always coalesces cleanly; OwnTone's poll interval and real-world
   multi-device drop/reconnect timing are exactly the kind of thing that
   won't show up until live-hardware testing per Phase 0 notes.
3. **Ambiguity between "device reconnected" and "device newly added to the
   network for the first time" isn't fully pinned.** `deviceAdded` (a
   never-before-seen id) should almost certainly also trigger reconnect
   logic if that id happens to already be a persisted group member (e.g.
   app restarted, backend cold-starts and everything looks like
   `deviceAdded` since `known` is empty on launch, `OwnToneBackend.swift:127`
   in `makeEventStream`'s initial dump). The recommended approach above
   only discusses `.deviceUpdated`; on cold start ALL group members arrive
   as `.deviceAdded`, and — per SPEC's persisted `mainOut` — the app should
   just re-`activateGroup` once on startup after the initial device dump
   settles, which is arguably simpler than reconnect-during-a-session and
   worth handling as its own (easier) case first.

### Implementation checklist (dependency-ordered)

1. Add a small "last known availability per member id" cache inside
   `GroupController` (parallel to existing `memberState`, e.g.
   `private var lastKnownAvailability: [String: Bool] = [:]`) — needed to
   detect the false→true edge without asking the backend for history.
2. Add `GroupController.noteDeviceEvent(_ device: Device)` (or fold into an
   existing per-device refresh call if the app already has one) that
   updates the cache and, when the edge condition in step 3 of "Recommended
   approach" is met for a member of the currently-`.group`-targeted
   `mainOut`, schedules a debounced re-apply.
3. Add the debounce primitive — a simple `Task`-based trailing-edge
   coalescer keyed by group id (cancel-and-reschedule pattern), since
   `GroupController` has no existing timer infra to reuse.
4. Add the narrower re-apply function (distinct from full `activateGroup`)
   that only touches rejoined member ids' selection + volume, leaving
   already-connected siblings alone.
5. Wire cold-start reconnect: after the initial `deviceAdded` burst settles
   (app already must have a "discovery settled" moment for `
   ensureDefaultSelection()` to be safe to call, `GroupController.swift:110`
   doc — reuse that same settling signal) and `mainOut == .group(id:)`,
   call the full `activateGroup` once.
6. Call the new event hook from wherever the app currently forwards
   `BackendEvent` to the UI (this brief doesn't touch that call site — it's
   outside `AirPlayEngine/` and outside this brief's one-file scope, but
   note it for the implementer: search for where `makeEventStream()` is
   consumed in the app target).

### Tests to pin behavior (3-5)

1. `testAutoReconnectReappliesOutputSetWhenGroupMemberBecomesAvailableAgain`
   — mock backend: group active via `.group(id:)`, one member goes
   unavailable (`deviceUpdated` isAvailable=false) then available again;
   assert `setOutputSet` (or the narrower re-apply) is called with that
   member included, without touching a sibling member's volume.
2. `testAutoReconnectDoesNotFireForSelectedDevicesTarget` — same
   available→unavailable→available cycle but `mainOut == .selectedDevices`;
   assert no re-apply happens (ad hoc set is never auto-touched).
3. `testAutoReconnectDoesNotRestoreManuallyRemovedMember` — a device is
   removed from the group's *saved* membership (or, if that's not exposed,
   simulate via a member that was never part of `g.memberIDs`) and confirm
   it's untouched even if it reconnects.
4. `testAutoReconnectDebouncesMultipleMemberReconnectsIntoOneReapply` —
   two members flip false→true within the debounce window; assert exactly
   one re-apply call, containing both.
5. `testAutoReconnectOnColdStartReactivatesPersistedGroup` — fresh
   `GroupController` with `mainOut` persisted as `.group(id:)`, backend
   emits the initial `deviceAdded` dump for all members; assert
   `activateGroup` semantics are applied once discovery settles.

### Open questions for Alec

- Should auto-reconnect ever apply to `.selectedDevices` (ad hoc set), or
  is "only for saved groups" definitely correct per SPEC's wording ("a
  group")? Recommended approach above assumes groups-only.
- Is there a desired user-facing signal (toast/log line) when auto-reconnect
  fires, or should it be silent (matches "it just works" framing of groups
  as presets)?
- Debounce window: any preference vs. "pick something in the 200-500ms
  range and revisit once real hardware is available" placeholder?

---

## Part 2 — EQ / L-R balance

### The question

SPEC.md §9 "Balance (v2)" row (line 557): `NSSlider` with `neutralValue` at
center is the *UI* spec — settled. The open design question is **where the
DSP actually runs**, given the app owns the PCM pipeline pre-encode and
balance/EQ must be applied **per destination**, not globally.

### Findings (with evidence)

**The UI side is already fully specified and low-risk.** SPEC.md:557 —
`NSSlider` `neutralValue` is literally the documented API for a centered
rest point; this is a solved UI problem, not a design question. The mixer
window already has the toolbar/pane structure to host it (`MixerWindowController.swift`
docs — `ToolbarController` for the master-volume slider, `MixerViewController`
for per-device rows) — a balance slider slots in per-row or per-master
exactly like the existing volume `NSSlider`, no new AppKit pattern needed.

**Architecture requires per-destination DSP, which means per-stream, not
global.** SPEC §4 architecture diagram (SPEC.md:75-83): the AirPlay 2
sender engine does **"per-device RTP streams"** and **"per-stream volume"**
— volume is already a per-stream concept in the intended architecture, not
a single global fader. Balance (L-R) and any per-speaker EQ are the same
shape: a per-destination parameter that must be realized on that
destination's own stream, because two speakers can want different balance/
EQ settings simultaneously (mismatched speaker tonality is explicitly
called out as a *related, separate* v3 idea — "Volume calibration
(loudness-match mismatched speakers)," SPEC.md:59 — reinforcing that
per-speaker audio shaping is a recognized, intentional axis of variation,
not a bug to unify away).

**Where "per-stream" has to physically happen, given our pipeline.** Per
SPEC §4's block diagram, PCM frames flow: capture → **AirPlay 2 sender
engine** (per-device RTP streams) → devices. The engine's own seam
(`AirPlayEngine/docs/seam-map.md:108`) documents the hot path as
`airplay_write` — "feed one `output_buffer` of PCM; packetizes + sends RTP.
Void, synchronous." This is **per-output-already** at the point the Swift
layer calls in (`PLAN-PHASE-2.md:351`: `setVolume(_:for:)`, `writePCM` are
both per-output-scoped seam methods). Crucially: **today there appears to
be one shared PCM buffer written to potentially multiple outputs** (all
receiving the "master mix," §4 diagram: one PCM stream in, fanned out to N
per-device RTP streams with only *volume* varying per stream so far). To
add balance/EQ per destination, the PCM must be processed **once per
destination, right before that destination's `writePCM`/`airplay_write`
call** — i.e., N copies of the (possibly EQ'd/balanced) buffer where today
there's conceptually one buffer fanned out. This is exactly the same
"per-destination processing before the engine write" shape that the
concurrent multistream brief (`p2b-multistream-brief.md`) is designing for
per-app mixing — **reference, don't duplicate**: whatever seam that brief
proposes for "N per-speaker mixed buffers, computed pre-encode, one per
destination, right before its `writePCM` call" is the SAME insertion point
balance/EQ needs. Balance/EQ should be implemented as an additional
per-destination processing stage at that seam, not a separate pipeline.

**Existing per-stream volume precedent tells us the API shape.** `setVolume(_:for:)`
already exists as a per-output engine call (`PLAN-PHASE-2.md:351,396-399`;
`OutputBackend.setVolume(_:for:)`, `OutputBackend.swift:51`). Balance and
per-band EQ are naturally modeled the same way: `setBalance(_:for:)` /
`setEQ(_:for:)` per device id, mirrored up through `GroupController` (which
already stores/echoes per-member volume via `Device.volume` — a per-member
`Device.balance`/`Device.eq` field would follow the identical pattern:
value type field, backend call, echoed `deviceUpdated`).

### DSP primitive recommendation

**Recommend vDSP-based biquad filtering / gain, applied directly to the
PCM buffer in the per-destination processing stage — NOT `AVAudioUnitEQ`
via an `AVAudioEngine` offline render.**

Reasoning:
- **Latency/CPU**: `AVAudioEngine` + `AVAudioUnitEQ` is built for a
  real-time graph with its own render callback / thread and I/O node
  assumptions; wiring N parallel offline `AVAudioEngine` instances (one per
  destination, since each needs independent balance/EQ) to process the
  *same* input buffer N different ways is exactly the kind of multi-engine
  contortion `AVAudioEngine` is not designed for, and each engine carries
  non-trivial fixed overhead (graph render quantum, format
  conversion nodes) that adds up per destination in a fan-out architecture.
  `AirPlayEngine/docs/seam-map.md` and `PLAN-PHASE-2.md` are already
  explicit that the hot path (`airplay_write`/`writePCM`) is a
  **synchronous, tight per-buffer call** — the existing project bias is
  toward small, direct, allocation-free per-buffer processing (see the
  Core Audio taps brief's realtime-IOProc rules, `0e-taps-brief.md:233-236`
  and `:320-321`: "no blocking, no locks, no allocation... in the hot
  path" — the same realtime discipline applies to whatever runs just
  before `writePCM`).
- **vDSP (Accelerate)** gives balance (a pure per-channel gain multiply —
  `vDSP_vsmul`, trivially cheap, no filter state) and a biquad EQ
  (`vDSP_biquad`/`vDSP_biquadm` for per-band shelving/peaking filters) as
  tight, allocation-light, well-understood primitives that operate
  directly on the Float32 planar buffers the capture layer already produces
  (per the taps brief, tap format is Float32 non-interleaved — `0e-taps-brief.md:16-21`
  — which is exactly the layout `vDSP_biquad`/`vDSP_vsmul` want, no format
  conversion needed). Cost is O(samples) per destination per buffer with no
  engine/graph overhead, and it composes cleanly with "N copies, one per
  destination" fan-out: for each destination, copy (or process-in-place
  into a per-destination scratch buffer) → apply gain (balance) → apply
  biquad (EQ) → hand to that destination's `writePCM`.
- Balance specifically is simpler than general EQ: L-R balance is just
  independent per-channel gain (attenuate one channel as the slider moves
  off center), which is `vDSP_vsmul` on each channel with a computed
  coefficient (SPEC's `neutralValue`-centered slider maps directly to
  "gain L = min(1, 1 - 2*(v-0.5)), gain R = min(1, 1 + 2*(v-0.5))" or
  equivalent pan-law formula) — no filter state, no latency, trivial CPU.
  EQ (peaking/shelving bands) is the part that actually needs biquads and
  therefore small persistent per-destination filter state (coefficients +
  delay-line values) that must be carried buffer-to-buffer per destination
  — another reason this has to be a per-destination stage, not a shared one.
- If per-band EQ turns out to be deferred/cut for v2 scope and only
  balance ships first, that's a strict subset of the same design (gain-only,
  drop the biquad stage) — no rework needed either way.

### Recommended approach summary

1. Treat balance + EQ as **per-destination stream parameters**, modeled the
   same way `volume` already is: a `Device`-level value (or values),
   pushed via a backend method (`setBalance(_:for:)`), applied at the
   per-destination pre-`writePCM` processing stage that the multistream
   brief is designing for per-app mixing.
2. Use **vDSP** (`vDSP_vsmul` for balance gain, `vDSP_biquad`/`vDSP_biquadm`
   for EQ bands) operating on the Float32 planar buffers already in hand
   post-tap, not `AVAudioEngine`/`AVAudioUnitEQ`.
3. UI: `NSSlider` with `neutralValue`, one per device row in the mixer
   pane (and/or a master balance in the toolbar) — SPEC.md:557, no new
   research needed there.
4. Persistence: extend `Group.memberVolumes`-style storage (or a sibling
   dict) with per-member balance/EQ settings if they should be remembered
   per saved group, following the exact pattern `memberVolumes` already
   uses (`Group.swift:18`, `GroupStore` schema — would bump
   `schemaVersion` if added to the persisted `Group` struct).

### Walls / risks (ranked)

1. **This is entirely gated on the multistream/per-destination mixing
   architecture landing first.** There is currently (per `seam-map.md` /
   `PLAN-PHASE-2.md`) no confirmed "N independent per-destination buffers,
   processed individually before `writePCM`" seam in the engine yet — that
   is exactly what `p2b-multistream-brief.md` is designing concurrently.
   Balance/EQ cannot be implemented in isolation; it rides on whatever
   insertion point that brief settles on. Treat this brief's DSP
   recommendation as "here's what to bolt onto that seam once it exists,"
   not an independently schedulable task.
2. **Realtime-safety of the biquad stage is unverified against actual
   engine thread constraints.** The engine's hot path is documented as
   synchronous and thread-marshaled (`seam-map.md:550,558`) — vDSP calls
   are CPU work with no locks/allocation if buffers are pre-allocated
   per-destination, which fits, but this needs to be validated once the
   real per-destination fan-out point is chosen (buffer allocation
   strategy, whether scratch buffers are reused across calls to avoid
   per-buffer `malloc`).
3. **No live-hardware validation possible yet** (Phase 0 note: speakers
   currently unavailable) — audible correctness of balance/EQ (does a
   shelving filter actually sound right on a HomePod vs. a generic AirPlay
   receiver with different inherent tonality) can only be checked once
   real speakers are back in the loop; the mock rig can validate the code
   path (gain math, buffer shapes) but not perceptual correctness.

### Open questions for Alec

- Is per-band parametric EQ actually in scope for v2, or is "balance only"
  the real v2 target with EQ pushed to a later phase? (SPEC.md:33 lists
  "EQ/balance" together in the summary table but the v2 feature bullet at
  SPEC.md:53 says "EQ / L-R balance" — worth confirming scope before
  building biquad infra that might not be needed yet.)
- Should balance/EQ settings be per-group (saved with `Group`, like
  `memberVolumes`) or purely per-device-global (one setting per device
  regardless of which group it's in)? Affects whether `GroupStore`'s schema
  needs a version bump now or later.

---

## Source references

- `AirPlayControllerCore/Sources/AirPlayControllerCore/Device.swift`
- `AirPlayControllerCore/Sources/AirPlayControllerCore/OutputBackend.swift`
- `AirPlayControllerCore/Sources/AirPlayControllerCore/OwnToneBackend.swift`
- `AirPlayControllerCore/Sources/AirPlayControllerCore/GroupController.swift`
- `AirPlayControllerCore/Sources/AirPlayControllerCore/GroupStore.swift`
- `AirPlayControllerCore/Sources/AirPlayControllerWindowUI/MixerViewController.swift`
- `AirPlayControllerCore/Sources/AirPlayControllerWindowUI/MixerWindowController.swift`
- `AirPlayControllerCore/Tests/AirPlayControllerCoreTests/GroupControllerTests.swift`
- `SPEC.md` §3 (v2 feature list, lines 48-54), §4 (architecture + security
  principles, lines 63-145), §9 (device row / full window, lines 537-558)
- `PLAN-PHASE-2.md` (engine seam status, lines 351, 396-399, 607)
- `AirPlayEngine/docs/seam-map.md` (hot-path `airplay_write`/`writePCM`,
  lines 108, 550-558)
- `dev/notes/0e-taps-brief.md` (tap format is Float32 non-interleaved;
  realtime-IOProc discipline)
- Sibling brief (reference, not duplicated): `dev/notes/p2b-multistream-brief.md`
