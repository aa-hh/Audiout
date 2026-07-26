# PLAN — Volume-key interception on the aggregate device

**Status:** not started — **QUEUED BEHIND the Sound-settings aggregate (coexistence
Wave 3), Alec's call 2026-07-26.** Do not start this until the aggregate is built: its
trigger IS the aggregate being the default output, so it can only be fully live-tested
once the aggregate is real (the `aggtool` spike reproduces the dead-keys state for
build-time work, but not the shipped path). Self-contained handoff otherwise — an agent
should be able to execute this without the originating conversation; everything it needs
is below or cited by `file:line`. Verify each citation against current source before
relying on it (docs orient, code decides); line numbers drift.

**Origin:** follow-up owed by the volume-decoupling workstream (branch
`claude/audio-volume-device-caps-f4ece7`, commits `7a3ed14..a85cc43`). Alec chose
"follow-up run, right after" when asked whether to fold it into that run. See memory
`volume-decoupling-main-as-ceiling.md` and `airplay-coexistence-plan.md`.

---

## Why this is needed (proven live, not hypothetical)

The AirPlay-coexistence work (merged to main, `34655b8`) introduces a **Sound-settings
aggregate device** ("Audiouter", wrapping the built-in speakers) as a Wave-3 basis.
When that aggregate is the macOS default output, **the hardware volume keys do
nothing** — Alec confirmed this on real hardware. macOS shows the crossed-out volume
HUD on each press.

**The trap that wasted time before, do not repeat it:** the aggregate *advertises*
volume capability — `aggtool status` reports `vmvc=true scalarMain=true muteMain=true`
— but does **not** deliver it. A capability check is NOT a safe gate. Test the actual
behaviour (attempt a write, read back, or just treat "the default output is our
aggregate" as the signal), never the advertised flags.

macOS's own key handling being dead means the normal volume path (below) never fires
on the aggregate. Closing that gap needs the app to intercept the keys itself.

## Why it belongs to THIS workstream, not coexistence

The coexistence plan assumed it could keep the old `GroupController` volume-key
**mirror**. The volume-decoupling refactor **deleted that mirror entirely** (commit
`7098868`, ~160 lines). So the gap the mirror used to paper over is now this
workstream's to close. Do not go looking for the mirror — it is gone by design.

---

## What already exists (build on it; do not re-invent)

### The normal (non-aggregate) volume path — WORKS, leave it alone
On a normal output, macOS moves the system volume itself, and the app follows:

```
volume key → macOS moves system volume
           → SystemOutputVolume listener fires
           → NativeBackend emits .systemVolumeChanged(volume:)
           → AppDelegate.swift:1241  groupController.applyExternalSystemVolume(volume)
           → Main moves; every device follows via Main × Group × Device at the write boundary
```

This path is intact and tested (`NativeBackendTests`, `GroupControllerTests`). The
interceptor must NOT double-drive it — see "only intercept when the keys are dead".

### `GroupController.applyExternalSystemVolume(_ volume: Int)` — the seam to call
`GroupController.swift:830`. Contract, written deliberately **source-agnostic** exactly
so a key interceptor can call it: *"the system output volume is already at `volume`;
bring Main into agreement and re-push every dependent gain. Writes NO hardware."* It is
the read-back arm — it never writes the system volume, so it cannot feed back. This is
almost certainly the right entry point for the interceptor (the aggregate can't take a
hardware volume write anyway), but see the open question on mute below.

### `systemOutputVolume: Int?` — the "keys are dead" signal
`OutputBackend.swift:297` (protocol), `:315` (default `nil`). `NativeBackend` returns
the Mac's readable system volume, or **`nil` when the default output exposes no
settable volume** — which is exactly the aggregate/HDMI case. `nil` is a strong
candidate for the gate: "if `systemOutputVolume == nil`, macOS can't move it, so we
must." Confirm this holds for the specific aggregate (the spike proved the scalar is
unsettable despite `scalarMain=true`).

### `MediaKeyController` — an EMITTER, not the interceptor you need
`AudiouterApp/MediaKeyController.swift`. It POSTS Now-Playing keys (play/pause/next) to
the HID tap to drive Now Playing from the menu bar. It does NOT intercept volume keys.
Do not confuse the two. **But reuse its two assets:**
- The Accessibility grant seam: `RemoteControlPriming` (injected, not a raw
  `AXIsProcessTrusted()` — see `MediaKeyController.swift:38-58`). The onboarding flow
  already uses it, so the grant plumbing and the once-per-launch prompt exist. Wire the
  interceptor through the same seam rather than adding a second Accessibility path.
- The systemDefined/subtype-8 aux-key encoding recipe (`postAux`, `:72-95`) — the same
  event shape you will be *reading* in the tap.

---

## The work

### 0. Prerequisite bug — ALREADY FIXED on the decoupling branch
The write-boundary review found **`lastSeenSystemVolume` goes stale after a mirrored
Main drag** (`NativeBackend.swift`, the `.systemVolumeChanged` emit basis): after a Main
drag, a later external change back to the *exact pre-drag value* was compared equal and
silently dropped, desyncing Main from the system. This is **fixed on the decoupling
branch** — `setMasterGain`'s `mirrorToSystemVolume` arm now sets
`lastSeenSystemVolume = main` on `stateQueue`, before the gain-changed guard. Since the
interceptor branch bases on the decoupling tip, it inherits the fix on rebase; nothing
to do here beyond confirming it's present.

### 0b. The Mac's own output isn't capped by Main on an unsettable default (decision #8)
Alec's ruling (2026-07-26): fix this **in this follow-up**, because it shares the same
`systemOutputVolume == nil` gate as the dead-keys work and needs the same aggregate/HDMI
hardware to verify.

The gap: `SyncedLocalSink`'s gain deliberately **excludes Main** on the assumption that
"the Mac's system volume already applies Main to its own output"
(`SyncedLocalSink.swift` gain doc; `NativeBackend.syncedLocalGain` = `group × device`
only). That assumption breaks when the default output exposes no settable volume:
`setMasterGain`'s `mirrorToSystemVolume` arm calls `systemVolume.setVolume(main)`, which
**silently no-ops** on such a device (every write is behind `isWritable`). So pulling
Main down attenuates the AirPlay members but leaves the Mac's own output at full — the
master control silently fails for the Mac on exactly the aggregate the coexistence work
introduces (and on plain HDMI today).

Fix direction: when `systemOutputVolume == nil` (the same "keys are dead" signal),
**fold Main into the sink gain** — `syncedLocalGain` becomes `main × group × device` in
that state, and stays `group × device` when the system volume is settable (so Main isn't
double-applied). Gate on the same nil-check the interceptor already needs. Test: with a
`nil`-systemOutputVolume backend, dragging Main must move the `SpySyncedLocalSink` gain;
with a settable one, it must not (the existing gap-6 test
`syncedLocalSinkGainCarriesGroupButExcludesMain` pins the settable case). Live-verify on
the aggregate: Main down actually quiets the Mac, not just the AirPlay speakers.

**Also fold in here (same writability question):** `NativeBackend.setMasterGain`'s
`lastSeenSystemVolume = main` memo (the `.systemVolumeChanged` emit basis) optimistically
trusts the mirror write landed. On a **readable-but-unwritable** default output (some USB
DACs — non-nil `systemOutputVolume`, so NOT caught by the nil-gate above), the write
no-ops but the memo says `main`, so a later external change *to `main`* is dropped. The
common settable case is already correct on the decoupling branch. The clean fix needs to
know whether the write landed, which `SystemOutputVolume.setVolume` (fire-and-forget
`queue.async`, self-heals its OWN `lastKnownVolume` on failure) doesn't currently report
— so make it report success (or have the backend memo from a confirmed read), and only
then update `lastSeenSystemVolume`.

### 1. The interceptor
A `CGEventTap` (session or annotated-session tap) that observes systemDefined events,
filters to the aux volume-up / volume-down / mute keys (subtype 8, key codes
`NX_KEYTYPE_SOUND_UP` / `_DOWN` / `MUTE` — the down transition, `0xA`, as in
`MediaKeyController.postAux`). On a matching key **when the gate says the keys are
dead**:
- compute the target Main (current `mainOutMasterVolume` ± one step; pick a step that
  matches macOS's 16-per-range feel, and honour the ⇧⌥ quarter-step modifier if cheap),
- drive Main via `applyExternalSystemVolume(target)` (no hardware write — correct for
  an unsettable output),
- **consume the event** (return `nil` from the tap callback) so macOS doesn't also show
  the crossed-out HUD.

### 2. The gate — ONE "we own volume" mode, not two bolt-ons (Alec, 2026-07-26)
Reframe: #0b (apply Main to the Mac's own output) and this key interception are the
OUTPUT and INPUT halves of the SAME condition — "the system volume isn't ours to write,
so we take the wheel." Build them as one mode keyed off one predicate, not two features
with two gates. When the mode is ON: intercept + consume the volume keys AND fold Main
into `syncedLocalGain`. When OFF (normal settable output): do neither — let macOS handle
the keys and let the system-volume write carry Main to the Mac, exactly as today.

**Detecting the mode is the crux, and the obvious gate is WRONG.** Do NOT gate on
`systemOutputVolume == nil` or any capability probe: Alec's live session proved the
aggregate LIES — `aggtool status` reports `vmvc=true scalarMain=true muteMain=true` while
delivering none of it, so it reads as a settable device and slips through a nil/capability
gate, and the takeover silently never fires (volume just dies). Reliable detection:

> **default output is OUR OWN aggregate (match by the UID/name we created it with)**
> **— OR — a genuinely unreadable output (`systemOutputVolume == nil`, real HDMI).**

We own the aggregate's identity because we create it (coexistence Wave 3 / `aggtool`),
so a direct identity match is exact where a behavioral/capability test is fragile. Re-
evaluate on default-device change (`SystemOutputVolume` already watches
`kAudioHardwarePropertyDefaultOutputDevice`). Getting this wrong is a SILENT failure in
both directions — double-moving Main on a normal output, or dead volume on the aggregate.

### 3. Accessibility grant — now MANDATORY, was optional
`MediaKeyController`'s posting degraded gracefully without the grant (`post` just
no-ops). A CGEventTap **cannot be created at all** without Accessibility trust, so the
grant stops being optional. Therefore:
- surface a **revoked-grant state** in the UI (the keys silently die otherwise). The
  onboarding permission rows are the natural home.
- **cdhash-pinning gotcha** (memory `tcc-grants-cdhash-pinned-on-adhoc-builds.md`):
  ad-hoc dev rebuilds silently lose the grant even though Settings shows it "on".
  Toggling doesn't fix it; REMOVE (−) and re-add does. Expect this during live testing;
  it is not a code bug.

### 4. The HUD (open question — decide with Alec or by ear)
Consuming the event kills the crossed-out HUD, but also means **no volume HUD at all**
unless the app posts its own. Options: (a) live without a HUD on the aggregate; (b)
post a synthetic volume HUD; (c) show the change in the app's own UI only. Flag this
rather than silently shipping (a).

### 5. Mute
Decide whether the mute key maps to Main mute, or to the existing per-device/Main mute
semantics. `applyExternalSystemVolume` carries no mute concept, so mute likely needs its
own small entry point on `GroupController`. Do not overload the volume path for it.

---

## Testing

- **Headless:** the interceptor's decision logic (gate on/off by
  `systemOutputVolume` nil-ness; key → target-Main math; step size; modifier handling)
  should be pure and unit-tested with an injected backend, the way the rest of this
  codebase injects `OutputBackend`. The CGEventTap plumbing itself is not headlessly
  testable — keep it a thin shell over the tested decision function.
- **Live (owed to Alec, cannot be automated):**
  - reproduce the dead keys with the aggregate active, then confirm the interceptor
    moves Main and every routed device follows;
  - confirm a normal output is UNAFFECTED (macOS handles the keys, Main still follows
    via the existing path, the tap does not double-move);
  - revoked-Accessibility state is visible, not silent;
  - the HUD decision feels right.

### Reproduction tooling (exists)
`aggtool` in the aggregate-device spike: worktree
`.claude/worktrees/agent-ae99ad2727f8097a1`, `dev/spikes/aggregate-device/aggtool.swift`
(+ `build.sh`, `SPIKE-REPORT.md`). Verbs: `create | set-default | restore | destroy`
(and `status`, which is what shows the misleading `vmvc=true` flags). Use it to put the
machine into the dead-keys state without depending on the coexistence feature being
wired up.

---

## Definition of done
Volume keys move Main (and therefore every routed device) when the aggregate is the
default output; normal outputs are untouched; a revoked Accessibility grant is visible
rather than a silent failure; the `lastSeenSystemVolume` prerequisite is fixed; decision
logic is unit-tested; Alec's live checklist above passes. Do NOT merge to main — hand
back a committed branch for Alec to live-test (house rule).
