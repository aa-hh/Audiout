# PLAN — Volume control while the aggregate owns the output

**Status:** re-planned 2026-08-08 after live disproof; W1–W4+W6 built and green,
W5 pivoted. This revision supersedes the 2026-08-07 one, whose §2 mechanism
claim for the Touch Bar was **disproven on real hardware** — kept below as §2
with the correction, because the wrong inference and how it fell is exactly
what the next agent must not repeat.

Self-contained handoff — verify each `file:line` citation against current
source before relying on it (docs orient, code decides); line numbers drift.

---

## 1. Why this is needed (proven live)

When the public **"Audiouter" aggregate device** is the macOS default output,
macOS refuses to move the system volume: the hardware volume keys draw the
crossed-out HUD, every volume slider (menu bar, Control Center, Touch Bar)
greys out, and the only way to change volume is opening the app.

**Trap (cost us once already):** the aggregate *advertises* volume capability
(`vmvc=true scalarMain=true muteMain=true`) but does not deliver it. Never
gate on capability — see §4.

**Second trap (cost us a false "it doesn't work" live test 2026-08-08):**
every test build creates its own aggregate with its own UID. A stale build
from another worktree ("Audiouter Sync v7") held the default output, so this
build's identity gate never matched and nothing installed. Quit other
Audiouter builds before any live test.

## 2. The mechanism — CORRECTED by live probe 2026-08-08

The 2026-08-07 revision inferred from `ControlStrip.app`'s imported symbols
(`_DFRFoundationPostHIDUsage` vs `_AudioObjectSetPropertyData`) that the Touch
Bar's **discrete** volume buttons post a HID usage a `CGEventTap` can catch
even while greyed. **Live probe disproved this** (`dev/spikes/volume-key-tap/
probe.swift`, dual session+HID `.listenOnly` taps, Alec pressing keys):

- **Greyed Touch Bar volume buttons post NOTHING** — at either tap level.
  Other Touch Bar buttons printed; volume did not. ControlStrip checks
  `AudioObjectIsPropertySettable` on the default output and disables the
  buttons *before any event exists*. Symbol presence proved the posting path
  exists, not that greyed buttons take it. No tap anywhere can catch them.
- **Physical volume keys and external keyboards still emit real events** —
  the interception half stands for those, and SoundSource's "Super Volume
  Keys" (Accessibility-gated event tap, confirmed from their docs) is
  independent convergence on the same design. SoundSource's Touch Bar never
  *looks* dead only because their admin-installed HAL driver publishes a
  settable volume control — the driver route Alec rejected.
- The probe also cleared the plumbing: both taps install and receive events,
  Accessibility behaves, `.cgSessionEventTap` sees everything the HID tap sees.

So the Touch Bar cannot be fixed by interception **at all**. It is fixed by
the app drawing **its own button** in the Control Strip region — §7.

## 3. Scope and locked decisions

1. **No virtual/HAL driver** (Alec): requires an admin-password install. Not
   revisited even though it is how SoundSource keeps every surface alive.
   Research preserved at `dev/spikes/virtual-device/SPIKE-REPORT.md`
   (worktree `agent-a8f62fddcb614b153`).
2. **Dead sliders are acceptable** (Alec): menu bar, Control Center, Touch
   Bar slider stay greyed. The app and its shortcuts are the volume surface.
3. **Touch Bar gets OUR button, reversibly, driven by the current output**
   (Alec, 2026-08-08): while Audiouter is the output the user keeps their own
   non-audio buttons, dead audio controls go, our working control appears; the
   moment they switch away, everything restores exactly. Never permanent.
4. **No HUD** (Alec): consuming a key kills the crossed-out HUD and we post
   nothing in its place; the app's UI reflects the change. No `OSDUIHelper`.
5. **Mute key toggles Main mute** — `GroupController.setMainOutMuted(_:)`
   (`GroupController.swift:873`), no new entry point.
6. **Step feel matches macOS**: 1/16 per press, 1/64 with ⇧⌥, snap to
   sixteenths. (Built and pinned, `VolumeStep`.)

Deployment target macOS 14 (`AudiouterCore/Package.swift:60`). The Touch Bar
model list is closed forever (2018 → 13" M2 2022), which keeps the hardware
check a literal set (`CoreFoundationControlStripControl.touchBarModels`).

## 4. The design — ONE "we own volume" mode  *(BUILT, green)*

Interception (input) and applying Main to the Mac's own output (output) are
two halves of one condition — *"the system volume isn't ours to write, so we
take the wheel"* — behind one predicate:

```
weOwnVolume ==  default output UID == AggregateOutputDevice.productUID
             || systemOutputVolume == nil          // genuine HDMI etc.
```

Identity, never capability (the aggregate lies — §1). Published as
`BackendEvent.systemVolumeOwnershipChanged` from `NativeBackend` at `start()`
**and** on every default-output change (the `start()` emit is load-bearing: an
aggregate left as default by a prior session never fires a change event).
Pinned by `NativeBackendTests` in both directions, including the
aggregate-reporting-a-readable-volume regression.

## 5. Part A — the interceptor  *(BUILT, green — W1–W3)*

Physical volume keys and external keyboards only, per §2.

- Pure decision core `AudiouterCore/VolumeKeyInterception.swift`: ownership
  predicate, subtype-8 decode (`data1` layout, `deviceIndependentFlagsMask`
  trap), sixteen-detent step math, consume/pass decision. 24 tests.
- Shell `AudiouterApp/VolumeKeyInterceptor.swift`: `.cgSessionEventTap`,
  `.headInsertEventTap`, `.defaultTap`, mask `1<<14` only (never `.keyDown`),
  lock-guarded state for the C callback, re-enable on `tapDisabledByTimeout`,
  installed only while `weOwnVolume`.
- Drives `GroupController.applyExternalSystemVolume(_:)`
  (`GroupController.swift:846`, writes no hardware) and `setMainOutMuted`.
- **Never double-drives:** when macOS owns the volume the tap passes
  everything through; the existing `.systemVolumeChanged` path carries keys
  into Main as before.

**Possible follow-up found via MediaKeyTap research:** MonitorControl's fork
also masks `NX_KEYDOWN` to catch F-row keys on some keyboards. Not needed for
the standard aux-key path; revisit only if a live keyboard misses.

## 6. Part B — Main must attenuate the Mac  *(BUILT, green — W4)*

`syncedLocalGain` (`NativeBackend.swift`) folds Main in **iff** `weOwnVolume`
(else the system volume already applies Main and it would double-apply); a
Main-only move re-pushes in that state; ownership flips re-push. Also:
`SystemVolumeControlling.setVolume` now reports whether the write landed, and
`lastSeenSystemVolume` memoises only on success (readable-but-unwritable USB
DAC edge). All pinned.

## 7. Part C — the Touch Bar: OUR button in the Control Strip  *(the pivot — TO BUILD)*

### 7a. Mechanism, live-proven 2026-08-08 (33 taps delivered, macOS 27)

`NSCustomTouchBarItem` registered via the private system-tray path:

```
NSTouchBarItem.addSystemTrayItem(item)              // private class method
DFRElementSetControlStripPresenceForIdentifier(id, false)  // stale-entry flush
DFRElementSetControlStripPresenceForIdentifier(id, true)
```

`DFRElementSetControlStripPresenceForIdentifier` is dlopen/dlsym'd from
`/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation`
(no link-time framework exists on disk). Same route BetterTouchTool, Pock,
MTMR ship; MTMR proves it maintained through macOS 26; our spike is the first
known proof on 27. Spike: `dev/spikes/touchbar-tray-item/bundled-spike.swift`.

**Three requirements, each live-bitten before it was met:**
1. Real `.app` bundle with a bundle identifier — a bare binary registers
   nothing, no error anywhere.
2. **Launched via `open`** — direct exec of the bundled binary RENDERS the
   button but delivers NO taps (the cruelest failure; it looks like it
   works). Production launches via `open` already; dev/live-test docs must
   say so. Applies to every future live test.
3. Renders **only** in "App Controls with Control Strip" mode
   (`com.apple.touchbar.agent` → `PresentationModeGlobal =
   appWithControlStrip`); invisible in `fullControlStrip` (Alec's own mode)
   and in Apple's *expanded* strip generally — a foreign identifier in the
   `FullCustomized` layout array is not rendered by ControlStrip (it draws
   only its own catalog).

**Unproven within the mechanism:** only a single plain `NSButton` has
rendered. A −/+ pair inside one item view (e.g. `NSStackView` of two
`NSButton`s) is the first build step and gets verified live before anything
is wired to it. Fallback if a pair won't render: two separate tray items
(risk: only one third-party slot may exist system-wide — TouchSwitcher docs)
or a single mute-style button plus press-and-hold. Do not build past this
until the pair is proven.

### 7b. Behavior (Alec's decision, 2026-08-08, "keep theirs, remove the dead
audio, add ours")

On `weOwnVolume` becoming true AND Touch Bar hardware present:

1. Persist the user's current `PresentationModeGlobal` and `MiniCustomized`
   (crash-safe: persist BEFORE writing, restore-on-launch marker — the same
   store shape `AppSettings.controlStripOriginalLayouts` already implements).
2. If mode is `fullControlStrip`: set `appWithControlStrip` so the region our
   item renders in exists. Their expanded layout stays untouched and remains
   one chevron-tap away.
3. Remove audio items (`volume`, `group.volume`, `volume-up/down`, `mute`)
   from `MiniCustomized` — they are dead weight while we own volume, and a
   greyed Apple volume next to a working ours reads as a bug. Every non-audio
   item keeps its exact position; unknown identifiers survive.
4. Register our tray item; `killall ControlStrip` to reload (user-owned
   LaunchAgent, no privilege).

On `weOwnVolume` becoming false (or at quit, or at next launch if a crash
stranded the marker): remove the tray item, restore layout and mode **only if
still what we wrote** (a user edit during the swap wins; drop the marker),
reload.

Prefs via `CFPreferencesSetAppValue`/`AppSynchronize` only — never the plist
file (cfprefsd owns it).

### 7c. What our item does

−/+ buttons drive Main exactly like the interceptor does: `VolumeStep.next`
→ `applyExternalSystemVolume`. Same step feel, same repaint
(`repaintFromCurrentState`). No slider (the tray slot is button-sized), no
HUD (decision 4).

## 8. Part D — permissions  *(BUILT — W6; now Touch-Bar-free)*

The tray item needs NO permission at all — Accessibility is required only by
the interceptor's tap. `RemoteControlPriming` seam
(`SetupModel.swift:221`) is the single grant path; onboarding row copy leads
with the volume keys; a missing grant while `weOwnVolume` surfaces the
permission rows once per launch instead of dying silently
(`AppDelegate.didSurfaceAccessibilityGap`). cdhash-pinning gotcha during dev
testing: REMOVE (−) + re-add, toggling does not fix.

## 9. What of the old W5 (layout swap slider→buttons)

**Dead — its premise was disproven** (Apple's discrete buttons are inert
while greyed, so making them appear buys nothing). The pure transform
functions (`ControlStripLayout.swappingSliderForButtons`) go; the
**store/restore/crash-recovery machinery and its tests stay** — §7b reuses it
for the mode + audio-item removal (`ControlStripSwapStoring`,
`CoreFoundationControlStripControl`, the decline-to-clobber-user-edits rule,
the restore-if-stale launch hook). Rework, don't rewrite.

## 10. Testing

**Headless:** everything decision-shaped stays pure and pinned — ownership
predicate, decode, step math, layout transforms (now: remove-audio-items and
mode-swap plans), restore-declines-on-user-edit, crash-marker recovery. The
tray registration itself and the tap shell are thin and not headlessly
testable; keep them dumb.

**Live (owed to Alec, in one session, ONE build, launched via `open`, all
other Audiouter builds quit):**
1. −/+ pair renders as one tray item (7a's open question) — FIRST; stop if not.
2. Aggregate active → our buttons appear, taps move Main, Mac's own speakers
   and AirPlay members both follow; Apple's dead audio controls are gone from
   the strip; non-audio buttons untouched.
3. Physical keys (other MacBook or external keyboard) move Main; normal
   output remains untouched by the tap (no double-move).
4. Switch output away → strip, layout, and mode restore exactly.
5. Force-quit while swapped → next launch restores.
6. Revoked Accessibility → permission rows appear once; volume via Touch Bar
   button still works (it needs no grant).
7. No-HUD feel check.

## 11. Sequencing

| Wave | Work | State |
|---|---|---|
| W1–W4, W6 | mode, interceptor, decode/step, local gain, permissions | **DONE, 1775 green** |
| W5.1 | −/+ pair in one tray item — spike extension, live check | to build, FIRST |
| W5.2 | `TouchBarVolumeTrayItem` app component (register/remove on ownership; taps → Main) | after W5.1 |
| W5.3 | Rework swap machinery: mode swap + audio-item removal + restore paths | parallel with W5.2 |
| W5.4 | Wire into `AppDelegate` ownership handler (replacing the dead layout-swap call) | after W5.2+W5.3 |
| W7 | Live checklist (§10) | last |

## 12. Definition of done

Volume changes without opening the app while the aggregate is the default
output: physical keys via the interceptor, Touch Bar via our own Control
Strip buttons; the Mac's own output actually attenuates; the user's Touch Bar
setup is never permanently altered and survives crashes; normal outputs
behave exactly as before; a revoked Accessibility grant is visible and only
degrades the keys, never the Touch Bar buttons; Alec's live checklist passes.
Do NOT merge to main — hand back a committed, pushed branch (house rule).
