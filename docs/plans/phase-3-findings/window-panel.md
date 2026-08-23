# Window & panel mechanics — discovery audit (Task A1)

> **LARGELY SUPERSEDED — historical record.** Written at `bcd6086`. C1 (partly),
> C2, C3, M1, M2 and M3 have since shipped, and C2 is now inverted: the control
> panel is the default chrome in every bundled build. For the current state see
> [`docs/plans/PLAN-UI-CONSISTENCY-PUNCHLIST.md`](../PLAN-UI-CONSISTENCY-PUNCHLIST.md).

Audiout is a menu-bar-only (`.accessory`) app: no Dock icon, no main menu,
no `Cmd+Tab` safety net. Every window it owns has to be recoverable through
the status item alone, or it strands the user. This audit traces every
surface (popover, Groups window, Settings window, onboarding window, and the
flag-gated "control panel" shell) for exactly that failure mode, plus
Space/fullscreen and multi-display behavior, and quit/relaunch state.

## Method

Read (not run, except where noted):
- `AGENTS.md` (repo root), `AudioutCore/AGENTS.md`, and the AGENTS.md in
  `AudioutApp`, `AudioutPopoverUI`, `AudioutSettingsUI`,
  `AudioutSharedUI`, `AudioutWindowUI`.
- Full source of `AppDelegate.swift`, `StatusItemController.swift`,
  `ControlPanelWindowController.swift`, `ControlPanelBackingView.swift`,
  `OnboardingWindowController.swift`, `OnboardingViewController.swift`
  (partial), `MixerWindowController.swift`, `SettingsWindowController.swift`,
  `SetupModel.swift` (partial), `AudioCapturePermissionProbe.swift`,
  `HeadlessRuntime.swift`.
- `PopoverController.swift` (show/hide, delegate, popover-close paths;
  ~1870 lines, read in targeted sections, not linearly).
- `docs/SPEC.md` §9 (UI design) for any Spaces/fullscreen/window-recovery
  product decisions — found none; this is an unaddressed gap, not a
  deliberate call.
- `dev/notes/onboarding-setup-brief.md` (first-run live-test findings from
  2026-07-17b) — cross-checked against current source; one section is stale
  (noted below).
- `ControlPanelWindowControllerTests.swift`, `PopoverControllerTests.swift`
  (targeted greps) to confirm what's test-covered vs. not.
- `git log`/`git merge-base` to confirm the control-panel rollout
  (`f0fc877`, `6d62c42`, plus later polish commits through `2a98843`) is
  genuinely merged to `main` (verified: `main` == this worktree's `HEAD`,
  `bcd6086`) — the earlier assumption that it was still an unmerged branch
  prototype is out of date.
- `grep` sweeps for `collectionBehavior`, `AIRPLAY_CONTROL_PANEL`,
  `isRestorable`, `applicationSupportsSecureRestorableState`,
  `NSApp.activate`, `mainMenu`/`keyEquivalent` — all repo-wide, all files
  read in full where a hit mattered.

Ran: `swift run window-harness` (headless, `AIRPLAY_HEADLESS=1` set
internally before touching AppKit — confirmed no window flashed). **Exit
0, 48/48 structural checks passed.** This harness only exercises
`MixerWindowController`'s content-pane logic (sidebar selection, create
sheet, editor) — it has zero coverage of window positioning, focus,
Space/fullscreen behavior, or the control-panel shell, which is exactly the
gap this audit fills.

Did not launch the app or open any real window/popover/AirPlay session.

---

## Critical

### C1 — A buried Groups or Settings window has no way back, in the version that ships today

**Plain language:** If you open the Groups or Settings window and then click
into another app (or it just ends up behind something), clicking the
menu-bar icon does **not** bring it back — it only opens the little dropdown.
Since this app has no Dock icon and no menu bar of its own, there is no other
obvious way to find that window again.

**Evidence:** `AudioutCore/Sources/AudioutApp/AppDelegate.swift:195-211`
— the status item's click handler:
```swift
statusItemController.onButtonClicked = { [weak self] button in
    guard let self else { return }
    if let onboarding = self.onboardingWindowController {
        onboarding.present()
        return
    }
    if self.useControlPanel, self.controlPanelSessionActive,
       let shell = self.controlPanel {
        shell.show(anchorRect: self.statusAnchorRect())
        return
    }
    self.popoverController.toggle(relativeTo: button)
}
```
It only special-cases the onboarding window and the (flag-gated,
off-by-default — see C2) control-panel shell. `mixerWindowController` and
`settingsWindowController` are never consulted here, so in the shipping
default the click always just toggles the popover. Neither
`MixerWindowController` (`AudioutCore/Sources/AudioutWindowUI/MixerWindowController.swift`)
nor `SettingsWindowController` (`AudioutCore/Sources/AudioutSettingsUI/SettingsWindowController.swift`)
implements any re-front-on-reactivate logic the way `OnboardingWindowController`
does (`OnboardingWindowController.swift:76-83`, `appDidBecomeActive`).

This is the exact "orphaned-window seam" the control-panel rollout was built
to fix (see C2/C3) — but that fix doesn't reach the shipping build.

**Mitigating factor, unverified:** an `.accessory` app with a visible
ordinary window sometimes still appears in Mission Control (⌃↑ / F3) even
without a Dock icon; whether `Cmd+Tab` also picks it up is inconsistent
across macOS versions and not something this app controls either way. Given
the target user is explicitly non-technical, Mission Control isn't a
reliable enough safety net to downgrade this. [confirm-in-G1]

**Fix direction:** make the status-item click check `mixerWindowController`/
`settingsWindowController` for an open-but-not-key window and re-front it
(mirror `OnboardingWindowController`'s pattern), independent of whether the
control-panel flag is on.

---

### C2 — `AIRPLAY_CONTROL_PANEL` — the fix for C1 — defaults off, with nothing in the release pipeline to turn it on

**Plain language:** There's already a more polished, unified window system
built (and merged to `main`) that was specifically designed to solve the
"lost window" problem in C1. It's switched off by default, and nothing in
the packaging script turns it on. So the paid release ships with the old,
broken behavior even though the fix already exists in the codebase.

**Evidence:** `AudioutCore/Sources/AudioutApp/AppDelegate.swift:139-143`:
```swift
/// Control-panel prototype (design review 2026-07-18): route Groups through a
/// sticky floating `NSPanel` anchored under the menu-bar item instead of a
/// standalone window, gated by `AIRPLAY_CONTROL_PANEL=1`. Off by default, so
/// the shipping window path is untouched. See `dev/notes/`.
private let useControlPanel = ProcessInfo.processInfo.environment["AIRPLAY_CONTROL_PANEL"] == "1"
```
Confirmed no other file sets this: `grep -rn "AIRPLAY_CONTROL_PANEL"` across
the repo (excluding `.build`) returns only doc comments and this one
read-site — `scripts/make-app.sh` never sets `LSEnvironment` or any
`AIRPLAY_*` var. Confirmed on `main`: `git merge-base --is-ancestor <rollout
commits> main` succeeds, and `main`'s `HEAD` (`bcd6086`) is this worktree's
`HEAD` — this is not a stale branch-only feature, it's merged and dormant.

**Fix direction:** this is a real product decision, not just a bug — but for
a paid release it needs to be a *chosen* default, not an accidental one.
Either flip the default on (after fixing C3 below) or explicitly decide to
ship the old window path for v1 and file the flip as a tracked follow-up —
right now it reads as leftover prototype wiring nobody revisited.

---

### C3 — If the control panel ships, there's no mouse-clickable way to close it

**Plain language:** The new unified panel (see C2) that's supposed to fix
the lost-window problem has its own bug: there is no visible close button on
it at all. The only way to truly dismiss it — as opposed to it just hiding
behind another app and popping back later — is to press the Escape key,
which nobody discovers by looking at the screen.

**Evidence:** `AudioutCore/Sources/AudioutSharedUI/ControlPanelWindowController.swift:100-102`:
```swift
panel.titlebarAppearsTransparent = true
panel.titleVisibility = .hidden
panel.standardWindowButton(.closeButton)?.isHidden = true
```
`NSView.isHidden = true` removes a view from hit-testing as well as drawing
— a hidden `NSButton` cannot be clicked, not merely invisible. The doc
comments in this same file (lines 20, 32, 75-77, 293-296) repeatedly cite
"✕ / Esc / performClose" as the three close paths, but the ✕ they mean is
this hidden standard button — there is no substitute close control drawn
anywhere else (`ControlPanelBackingView.swift` is purely decorative and
`ignoresMouseEvents`; neither `MixerWindowController`'s nor
`SettingsWindowController`'s hosted content draws its own close button —
they've always relied on the window chrome's native one).

Compounding this: clicking the status item while the panel is open does
**not** toggle/close it either — `AppDelegate.swift:205-208` always calls
`shell.show(anchorRect:)`, which re-summons/re-fronts the panel, never
closes it. And `hidesOnDeactivate = true` (line 92) means switching to
another app only tucks it away — it comes right back the next time the app
is activated (by design, for the "restore in place" behavior), so that's
not a close either.

Net effect: once a user opens Groups or Settings in this mode, the *only*
mouse-only ways to make it go away are switching apps (temporary tuck-away,
not a real close) or quitting the whole app. A genuine close requires
knowing to press Escape while the panel is focused.

**Fix direction:** draw a real, visible close affordance consistent with the
bubble's look (a small circular button in a corner, matching the
already-approved custom-drawn exception for `DeviceIconWellView`'s edit
badge), or un-hide the native traffic light and style around it instead of
under it.

---

## Major

### M1 — No window ever sets `collectionBehavior` — reopening a config surface can yank the user out of a fullscreen app

**Plain language:** If someone is in a fullscreen app (a video call, a game,
anything fullscreen) on one virtual desktop, and they'd previously opened
Groups or Settings on a different desktop, clicking the menu-bar icon to
reopen it will make macOS switch the whole screen away from what they were
doing, back to wherever that window last lived. That's a jarring, unexpected
interruption for what should be a quick glance at a menu-bar utility.

**Evidence:** `grep -rn "collectionBehavior\|canJoinAllSpaces\|moveToActiveSpace" AudioutCore/Sources`
returns zero hits across the entire app. Every window/panel — the reused
singleton `MixerWindowController`/`SettingsWindowController` windows
(`MixerWindowController.swift:178-187`, `SettingsWindowController.swift:95-98`),
the `ControlPanelWindowController` panel + its decorative backing window
(`ControlPanelWindowController.swift:83-139`), and `OnboardingWindowController`'s
window — uses AppKit's default `collectionBehavior`, which pins a window to
whatever Space it was last shown on rather than following the user. Because
every one of these is lazily built **once** and reused/re-shown thereafter
(not recreated per-open), a window opened once on Space 1 stays affiliated
with Space 1 for the rest of the session; showing it again from a different
Space forces the OS to switch Spaces instead of moving the window.
`docs/SPEC.md` §9 has no product decision on Spaces/fullscreen behavior —
this looks like an unconsidered gap rather than a deliberate choice.

The popover itself is unaffected (it's a fresh, ephemeral `NSPopover` shown
relative to the always-on-screen status item, not a persisted window), so
the *first* click after launch is fine; the problem only shows up once one
of these windows has been shown at least once and the user has since
switched Spaces/gone fullscreen.

[confirm-in-G1] — the exact on-screen effect (full Space-switch animation
vs. something gentler) needs a live multi-Space check; the underlying
mechanism (no collection behavior set, reused window objects) is confirmed
from source.

**Fix direction:** set `.moveToActiveSpace` (or `.canJoinAllSpaces` for the
control panel, given it's meant to behave like a Control-Center-style
overlay) on every one of these windows/panels.

---

### M2 — The Groups window's frame-autosave is silently dead code — position never actually persists

**Plain language:** The Groups window looks like it's set up to remember
where you last put it (and what size you last resized it to), but that
setup is immediately overwritten every time the window is (re)built, so in
practice it always opens centered at the same fixed size on every relaunch.
The code that looks like it saves your window placement doesn't actually do
anything.

**Evidence:** `AudioutCore/Sources/AudioutWindowUI/MixerWindowController.swift:177-187`
(`makeContainer()`) calls `window.setFrameAutosaveName("MixerWindow")` —
which, per `NSWindow` semantics, immediately applies any previously-saved
frame for that name if one exists. But the caller, `init()` at
lines 124-127, runs right after:
```swift
let window = Self.makeContainer()
window.contentViewController = splitViewController
window.setContentSize(NSSize(width: 720, height: 460))
window.center()
```
`setContentSize` + `center()` unconditionally override whatever the autosave
restore just applied, every single time a fresh `MixerWindowController` is
built (which happens once per app launch, since the controller is a lazy
singleton — `AppDelegate.swift:373-381`). So the autosave name is doing
nothing functionally beyond auto-*saving* a value that gets discarded on the
next launch anyway.

Contrast with `SettingsWindowController.swift:95-98` + `showWindow()`
(lines 111-124): it also calls `setFrameAutosaveName("SettingsWindow")`, but
`showWindow()` only calls `setContentSize` (not `center()`), and
`setContentSize` preserves the window's existing top-left origin — so
Settings' position genuinely does persist across relaunches. Groups is the
odd one out.

**Fix direction:** either drop the dead `setFrameAutosaveName` call (be
honest that Groups always centers) or drop the `center()` call so the
autosave actually restores position, matching Settings' behavior. Pick one
on purpose — right now it reads like the `center()` call was left over from
before frame autosave was added.

---

### M3 — The onboarding audio-permission tone can replay on simple app refocus, not just on the explicit "Allow…" tap the UI promises

**Plain language:** The setup screen warns the user "allowing this will play
a brief tone" — implying it happens once, when they click Allow. But the
same tone-playing check also runs quietly every time the app comes back to
the foreground while that permission hasn't been confirmed granted yet — so
a user who leaves the setup window open and switches around could hear that
"known beep" replay unexpectedly, with no button-click to explain it.

**Evidence:** `AudioutCore/Sources/AudioutCore/AudioCapturePermissionProbe.swift:100-119` —
`CoreAudioTonePermissionProbe.probe()` unconditionally starts an audible
`TonePlayer` every time it's called; there is no "silent" or "verify-only"
mode. `AudioutCore/Sources/AudioutCore/SetupModel.swift:286-300`
(`refreshStatuses()`) calls this exact same `audioProbe.probe()` — the
method's own doc comment says "do it SILENTLY (no `isProbingAudio` spinner)"
(line 295-296), but that only suppresses the UI spinner; the underlying
probe still plays the tone every time, regardless of caller. The guard
(`if audioStatus == .denied || audioStatus == .requested`) means this only
*stops* firing once status reads `.granted` — and `dev/notes/onboarding-setup-brief.md:109-115`
already documents that the audio probe can race the real TCC prompt and
misreport `.denied` right after a genuine grant, i.e. exactly the stuck
state that would keep re-triggering this.

`refreshStatuses()` is invoked from `OnboardingWindowController.appDidBecomeActive()`
(`OnboardingWindowController.swift:76-83`), which fires on **every**
`NSApplication.didBecomeActiveNotification` while the setup window is open
— not just returning from a permission prompt, but any ordinary app-switch
back to Audiout.

[confirm-in-G1] — needs a live check of how often this genuinely re-fires
in practice (in particular whether audio TCC gets stuck the way Accessibility
TCC does on ad-hoc builds, per the existing memory note on that exact
pattern) — but the code path that would cause a repeat, unexplained beep is
confirmed from source, not speculation.

**Fix direction:** either make `refreshStatuses()`'s audio re-check truly
silent (a non-audible verification path, if one is achievable) or don't
re-probe audio automatically at all — require an explicit re-tap of
"Allow…" to re-check it, same as the row already requires for a first
attempt.

---

## Minor

### N1 — Standalone Groups/Settings windows never explicitly close the popover; they rely on implicit dismissal

**Plain language:** When the app is in its default (non-control-panel)
mode, opening Groups or Settings from the popover doesn't explicitly tell
the popover to close — it's counting on the popover closing itself because
a new window took over. That usually works, but it's implicit, and the
newer control-panel code path was written to NOT take that chance.

**Evidence:** `AppDelegate.swift:368-385` (`openMixer()`, non-control-panel
branch) and `:463-489` (`openSettings()`, non-control-panel branch) call
`controller.showWindow()` with no `popoverController.popover.performClose(nil)`
anywhere in either path. Compare to the control-panel branch,
`presentInControlPanel(...)` at `AppDelegate.swift:417-439`, which explicitly
does `popoverController.popover.performClose(nil)   // hand off from the popover`
(line 437) before showing the shell. `PopoverController`'s `.transient`
behavior (`PopoverController.swift:362`) should auto-dismiss when another
window in the same app takes key status, so this likely works fine in
practice — but the asymmetry (one path added an explicit close, the other
never got the same treatment) suggests the team already learned this needed
to be explicit and didn't back-port the fix. [confirm-in-G1]

**Fix direction:** add the same explicit `performClose(nil)` to the
non-control-panel `openMixer()`/`openSettings()` paths for consistency and
to remove the reliance on implicit AppKit behavior.

### N2 — Inconsistent window-restoration hygiene

**Plain language:** One of the four windows (onboarding) explicitly says
"never try to restore my state"; the other three don't say anything either
way, and the app never tells macOS whether it supports state restoration at
all. Harmless today, but it's an unfinished corner.

**Evidence:** Only `OnboardingWindowController.swift:56` sets
`window.isRestorable = false`. `MixerWindowController` and
`SettingsWindowController` never touch `isRestorable`, and
`grep -rn "applicationSupportsSecureRestorableState"` across
`AudioutCore/Sources` returns nothing — `AppDelegate` never overrides it,
so it defaults to `false` (state restoration effectively inert) on modern
macOS. The net behavioral risk is low, but the inconsistency (one window
opting out explicitly, others not deciding) reads as unfinished rather than
deliberate.

**Fix direction:** either implement
`applicationSupportsSecureRestorableState() -> Bool` explicitly (even if it
returns `false`) so the choice is visible in code, or set `isRestorable =
false` consistently on every window if restoration is never wanted.

### N3 — `dev/notes/onboarding-setup-brief.md` is stale about the onboarding window's level

**Plain language:** An old design note still says the setup window was made
"floating for the whole run" to survive permission prompts stealing focus.
That was tried and then deliberately undone — the current code uses a
normal window level instead, for good reason (a floating window sat on top
of every other app and looked like a nag). A future agent reading only the
old note could reintroduce the reverted behavior.

**Evidence:** `dev/notes/onboarding-setup-brief.md:86-93` describes the
`.floating` fix as shipped. Current code,
`OnboardingWindowController.swift:57-62`, explicitly does the opposite:
```swift
// NOTE: deliberately a NORMAL window level. An earlier version made this
// `.floating` to keep it recoverable after a permission prompt stole focus,
// but floating means always-on-top over EVERY other app...
```
and `AudioutCore/Sources/AudioutApp/AGENTS.md:103-110` documents the
reversion explicitly. The AGENTS.md is authoritative and correct; the
`dev/notes/` brief was never updated after the reversion.

**Fix direction:** add a short "superseded, see AGENTS.md" note at the top
of that section of the brief, per the repo's own docs-orient/code-decides
convention.

### N4 — "Run Setup Again…" can stack the onboarding window on top of the control panel with no coordination

**Plain language:** If someone reopens the first-run setup flow from
Settings while the new unified panel (control-panel mode) is showing that
same Settings pane, the app just pops a second, independent window on top —
it doesn't tuck away or hand off the panel first the way opening Groups/
Settings from the popover does.

**Evidence:** `AppDelegate.swift:477` wires `onRunSetupAgain` straight to
`presentSetup()` (line 349-361), which builds `OnboardingWindowController`
and calls `.present()` unconditionally — no check against `controlPanel`/
`controlPanelSessionActive`, unlike `presentInControlPanel` which explicitly
closes the popover first. Not necessarily broken (both can coexist as
separate windows), but it's an un-thought-through seam between two "modal-
feeling" surfaces that can now both be on screen at once.

**Fix direction:** decide deliberately whether Setup should tuck away the
control panel when it opens, or leave both up — either is fine, but it
should be a choice, not a gap.

---

## Nit

### T1 — Unanchored `center()` calls leave exact multi-display placement implicit

**Plain language:** A few small/utility surfaces (the "Disconnecting…" quit
indicator, the Groups window's initial position, onboarding's initial
position) just call the generic "center on screen" API without saying which
screen. On a single-display Mac this is invisible; on multi-display rigs the
exact screen AppKit picks is implicit default behavior, not a deliberate
choice.

**Evidence:** `AppDelegate.swift:744` (`QuittingIndicatorPanel.showCentered()`
→ `panel.center()`), `MixerWindowController.swift:127` (`window.center()`),
`OnboardingWindowController.swift:93` (`window?.center()`). None pass an
explicit target screen. [confirm-in-G1] for whether the resulting screen
choice ever surprises a real multi-display user — likely low-impact since
these are all short-lived or one-time-per-launch surfaces.

**Fix direction:** no action needed unless G1 turns up a real complaint;
noted for completeness.

---

## Top 5 by user impact

1. **(C1)** Open the Groups or Settings window, let it get buried behind
   another app, and there is no way back except quitting and relaunching —
   clicking the menu-bar icon only opens the small dropdown, never the lost
   window.
2. **(C2)** The fix for #1 already exists in the codebase (a unified
   floating panel) but ships switched off, with nothing in the build script
   that ever turns it on for a real user — so the paid release ships with
   the known-bad behavior by default.
3. **(C3)** That same fix-in-waiting has no visible close button of its own
   — once it ships, users would need to know to press Escape to truly
   dismiss it, since even clicking the menu-bar icon just re-opens it.
4. **(M1)** Reopening Groups/Settings while inside a fullscreen app (a video
   call, a game) can force macOS to switch away from that fullscreen app
   entirely, just to show a config window — no window in the app tells
   macOS "follow me to whatever Space I'm on."
5. **(M3)** The setup screen's "we'll play a quick tone when you click
   Allow" promise can be broken — the same audible tone can replay just
   from switching back to the app, with no click at all, if the granted
   status hasn't been confirmed yet.
