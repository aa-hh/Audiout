# Impeccable audit — App shell & system integration (Audiout, macOS)

Scope: `AudioutCore/Sources/AudioutApp/**`, the surface host in
`AudioutCore/Sources/AudioutSharedUI/` (ControlPanelWindowController,
ControlPanelBackingView, MenuBarStatus, StatusItemIcon, MenuTriggerImageView),
and `scripts/make-app.sh` + the Info.plist it generates.
Read-only audit. No builds, tests or edits were run.

## Score table

| # | Dimension | Score |
|---|---|---|
| 1 | Menu-bar citizenship | 2 / 4 |
| 2 | Global input handling (media/volume keys, Touch Bar) | 3 / 4 |
| 3 | Lifecycle (launch, relaunch, quit, single instance) | 3 / 4 |
| 4 | Bundle & metadata quality | 3 / 4 |
| 5 | Robustness (taps, status item, displays, Spaces) | 3 / 4 |
| | **Total** | **14 / 20** |

## Verdict

The shell is unusually well-engineered *inside* its own decisions: the event-tap
design is a thin shell over a pure, tested decision core; the status icon obeys
the template-image rule and carries state by shape, not colour; the quit path is
graceful and bounded; the signing and Info.plist generation are the most careful
part of the whole repo (plutil-with-assert on every permission string, hardened
runtime verified after the fact, inside-out nested signing).

What it lacks is the *outside* of the contract — the paths a user takes when
something is not where they expect it. There is exactly one way into this app
(one menu-bar icon), and no second door: no reopen handling, no remembered icon
position, no fallback if the icon is hidden behind the notch. Two shipped
behaviours also lie to the user: the menu-bar glyph ignores master mute (which
its own doc comment says it must not), and pressing the hardware mute key while
the app owns volume changes nothing visible on screen because the system HUD is
swallowed and nothing replaces it. Both sit directly on Product Principles 2
("the UI never lies") and 4 ("live audio is high-stakes").

One release blocker is metadata, not code: the About surface ships literal
`TODO(Alec)` placeholder text and an `example.com` "View Source Code" link, and
the bundle carries no copyright string — for a GPL binary being sold, that is
the source-availability offer.

Priorities: fix P0/P1 before any public build; P2 before charging money.

---

## Findings

### P0

None. Nothing here silently destroys user data or makes the app unusable on a
normal path.

---

### P1

#### P1-1. No way back into the app if the menu-bar icon is not visible
**Location:** `AudioutCore/Sources/AudioutApp/AppDelegate.swift:338-347` (delegate
methods present), `AudioutCore/Sources/AudioutApp/StatusItemController.swift:64-69`
**Impact.** The app is `.accessory` with `LSUIElement=true`: no Dock icon, no
⌘Tab entry, no window on launch. The status item is the only entry point. On a
notched MacBook with a busy menu bar, macOS silently drops the item behind the
notch — the item still exists, it is simply never drawn. The app implements no
`applicationShouldHandleReopen(_:hasVisibleWindows:)`, so double-clicking
`Audiout.app` in Finder, or launching it from Spotlight/Dock while it is already
running, does *nothing at all* — LaunchServices just activates the existing
process, which shows no UI. `⌘,` only works while the app is already frontmost,
which it cannot become without a window. The user's only recovery is to quit
other menu-bar apps or use a third-party menu-bar manager.
**Recommendation.** Implement `applicationShouldHandleReopen` → `showSurface(.mixer)`
(returning `false`). That single method turns "double-click the app again" into
the standard macOS recovery gesture and covers notch, full menu bar, and
"I forgot where the icon is". Consider also a user-assignable global hotkey later,
but reopen is the cheap fix and the conventional one.

#### P1-2. The menu-bar glyph does not reflect master mute — its own doc says it must
**Location:** `AudioutCore/Sources/AudioutApp/StatusItemController.swift:39-43`
(doc: "master-mute drains the volume arc … so the closed-popover glance never
lies"), vs. `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:1185-1188`
(`statusMasterVolume` returns `mainOutMasterVolume / 100` with no mute term),
consumed at `AppDelegate.swift:1678`
**Impact.** With Main Out muted, the status symbol still renders a filled
`speaker.wave.3` arc at (say) 80%. The documented anti-lying rule is written down
and not implemented. Combined with P1-3 this is the whole of the closed-panel
feedback surface.
**Recommendation.** Return `0` (or drain) from `statusMasterVolume` when
`groupController.isMainOutMuted`, and/or pass a mute flag into
`StatusItemIcon.make`. Add the muted state to the image's accessibility
description as the same doc comment promises.

#### P1-3. Volume/mute keys give no visible feedback while Audiout owns volume
**Location:** `AudioutCore/Sources/AudioutApp/VolumeKeyInterceptor.swift:114-126`
(`.defaultTap`, event consumed), `AudioutCore/Sources/AudioutCore/VolumeKeyInterception.swift`
(`VolumeKeyOutcome.consume` — "this is what suppresses the crossed-out HUD")
**Impact.** Swallowing the event is correct (it kills the crossed-out HUD), but
nothing replaces macOS's volume HUD. There is no HUD implementation anywhere in
the repo (grepped). With the panel closed, a volume-key press changes only the
few-pixel variable-value arc in the menu bar; a **mute** press changes nothing on
screen at all (see P1-2). The user's only confirmation that mute landed is the
sound stopping in another room — which is precisely the high-stakes,
time-pressured case Product Principle 4 names.
**Recommendation.** Show a small transient HUD on an intercepted press (Audiout's
own, matching the system's position/dismissal timing), or at minimum fix P1-2 so
mute visibly drains the arc and add a brief menu-bar-anchored readout. Honour
Reduce Motion.

#### P1-4. The Touch Bar takeover is system-wide, permanent while routing, and has no opt-out
**Location:** `AudioutCore/Sources/AudioutApp/TouchBarFullBar.swift:60-88`,
driven from `AppDelegate.swift:1639-1649` on `.systemVolumeOwnershipChanged`
**Impact.** `TouchBarPrivateAPI.presentFullWidth` presents a *system-modal*
full-width Touch Bar. Ownership is true whenever the Audiout aggregate is the
Mac's default output — i.e. for as long as the user has Audiout set up, not only
while audio plays. On a Touch Bar MacBook Pro that means the user loses their
Control Strip *and every other app's Touch Bar* (Safari, Xcode, Photos…) for the
entire time Audiout is installed and selected, with nothing on screen explaining
why, and no setting to turn it off (no Touch Bar preference exists in
`AudioutSettingsUI` or `AppSettings` — grepped). The quit path restores it
(`releaseTouchBar`, `AppDelegate.swift:322`, correctly also on `willPowerOff`),
so the failure is not permanent, but the everyday state is a hostile one.
**Recommendation.** Add a Settings ▸ General toggle ("Use Audiout's Touch Bar
controls", default on for a Touch Bar Mac), and/or scope the presentation to
"while audio is actually routing" instead of "while we own volume". Say what it
does in one line where the user can see it.

#### P1-5. About surface ships literal TODO placeholder copy and an example.com source link
**Location:** `AudioutCore/Sources/AudioutSettingsUI/AboutView.swift:52` and `:55`,
rendered at `:205` and opened at `:270`
**Impact.** A shipped build shows the user the string
`TODO(Alec): add a support email or contact link`, and "View Source Code" opens
`https://example.com/TODO-audiout-source`. For a GPL-2.0-or-later binary that is
being sold, the source link *is* the source-availability offer — a placeholder
there is both an embarrassment and a licence-compliance gap. (Overlaps the
settings audit's scope; filed here because it is bundle identity/metadata.)
**Recommendation.** Block the first public build on real values. If the repo is
not public yet, the honest interim is to state that in the UI rather than link a
reserved domain.

---

### P2

#### P2-1. Status item has no `autosaveName` — the user's icon position is lost every launch
**Location:** `AudioutCore/Sources/AudioutApp/StatusItemController.swift:66`
**Impact.** `NSStatusItem.autosaveName` is unset, so the position the user
established by ⌘-dragging the icon along the menu bar is not persisted; the item
reappears at the system's default slot on every relaunch. For an app whose icon
is its only entry point, "it moves on me" is worse than for most.
**Recommendation.** Set `statusItem.autosaveName = "AudioutStatusItem"` right
after creation. Keep `behavior` free of `.removalAllowed` (correct today — the
user must not be able to ⌘-drag away the only door).

#### P2-2. Panel clamping picks the wrong screen on a multi-display Mac
**Location:** `AudioutCore/Sources/AudioutSharedUI/ControlPanelWindowController.swift:542`
(`if let screen = panel.screen ?? NSScreen.main`)
**Impact.** The origin is computed from the anchor (the status item's frame on
the display that currently owns the menu bar), but the on-screen clamp is applied
against `panel.screen` — the display the *panel* was last on, or `nil` while it
is off-screen, falling back to `NSScreen.main` (the screen with the key window of
whichever app is frontmost — the app is not active yet at this point). On a
two-display setup the panel can be clamped into the previous display's
`visibleFrame` while the beak points at an anchor on the other one.
**Recommendation.** Resolve the screen from the anchor:
`NSScreen.screens.first { $0.frame.intersects(anchor) } ?? panel.screen ?? NSScreen.main`.
Needs live check on a two-display Mac to confirm the visible symptom.

#### P2-3. Status item creation has no failure path
**Location:** `StatusItemController.swift:75-82` and `:124-135` — both
`guard let button = statusItem.button else { return }`
**Impact.** If `button` is ever nil, the app installs no action, draws no image,
logs nothing, and is a running process with zero UI and no way to reach it (see
P1-1). Silent by construction.
**Recommendation.** Log the failure through `AppDelegate.log` and retry once on
the next run-loop turn; at minimum leave a breadcrumb so a support report is
diagnosable.

#### P2-4. No `NSHumanReadableCopyright` in the generated Info.plist
**Location:** `scripts/make-app.sh:599-625` (the PlistBuddy block)
**Impact.** Finder's Get Info shows no copyright line, and Sparkle's update UI
has no copyright to display. For a GPL binary this is the one place the licence
holder is normally named.
**Recommendation.** Add `NSHumanReadableCopyright` (e.g. "© 2026 <holder>.
Licensed under GPL-2.0-or-later."). Same plutil-with-assert treatment as the
usage strings — the prose will contain punctuation.

#### P2-5. Nothing detects a translocated / not-installed launch
**Location:** whole shell — grepped: no reference to app translocation or
`/Applications` for the app's own path
**Impact.** A user who runs the download straight from `~/Downloads` (or from a
mounted DMG) gets Gatekeeper path randomisation: a read-only random mount path.
`SMAppService.mainApp.register()` (Settings ▸ General "Open at login",
`AudioutCore/Sources/AudioutSettingsUI/LoginItem.swift:32`) and the PTP
LaunchDaemon registration both bind to that path, so login-at-start and the PTP
helper break in ways that look like app bugs. The `LoginItemManaging` doc already
anticipates the throw; nothing tells the user *why*.
**Recommendation.** On first launch, if `Bundle.main.bundleURL` is not under
`/Applications` (or the path looks translocated: `/private/var/folders/.../AppTranslocation/`),
offer the standard "Move to Applications folder?" step, or state plainly in Setup
that the app must be in Applications for login-at-start and the sync helper.

#### P2-6. No wake-time re-arm of the volume event tap
**Location:** `AppDelegate.swift:892-904` (wake observer kicks the permission
observer and the audit, never the interceptor), `VolumeKeyInterceptor.swift:84-90`
(`reenableIfDisabled` runs only from `installIfNeeded`, i.e. only on an ownership
change)
**Impact.** The tap self-heals for the common case — macOS delivers
`tapDisabledByTimeout` / `tapDisabledByUserInput` to the callback, which re-arms
(`VolumeKeyInterceptor.swift:193-196`, good). But a tap disabled without a
delivered event (login-window switch, some sleep/wake paths) stays dead until the
next ownership flip, and the failure mode is silent dead volume keys — the exact
symptom the whole feature exists to prevent.
**Recommendation.** Call `volumeKeyInterceptor.setOwnsVolume(currentOwnership)`
(or expose a `reassertIfOwned()`) from the existing `didWakeNotification`
observer and from `NSApplication.didBecomeActiveNotification`. Cheap, idempotent.

#### P2-7. Status-icon accessibility description is stale and stateless
**Location:** `AudioutCore/Sources/AudioutSharedUI/StatusItemIcon.swift:30`
(`accessibilityDescription: "AirPlay volume"`)
**Impact.** VoiceOver announces "AirPlay volume" — the old product name, and it
conveys neither the level, nor mute, nor streaming state. `StatusItemController`'s
doc comment (lines 41-43) promises the description appends "muted"/"routing";
the code does not.
**Recommendation.** Build the description from the same state the glyph draws:
e.g. "Audiout — 80%, streaming" / "Audiout — muted". Fixing it alongside P1-2
keeps one source of truth.

#### P2-8. Documented status-item behaviour that does not exist (routing dot)
**Location:** `StatusItemController.swift:33-43` describes a
`StatusRoutingIndicator` dot at the glyph's top-trailing corner; no such symbol
exists anywhere in the repo (grepped)
**Impact.** Not a user-facing bug on its own, but the doc comment is the design
record for this file, and a future reader will assume the dot ships. Documentation
that describes unbuilt behaviour is how P1-2 (the mute drain, described in the
same paragraph) came to be believed done.
**Recommendation.** Either build it or cut the paragraph, and reconcile the mute
claim at the same time.

---

### P3

#### P3-1. Quit cuts audio in other rooms with no warning
**Location:** `AppDelegate.swift:1469-1503`
**Impact.** ⌘Q or the status menu's "Quit Audiout" tears down every stream
immediately. The "Disconnecting…" indicator (shown only if the wait exceeds
~300 ms — a nice touch) explains the delay but not the consequence.
**Recommendation.** Probably correct as-is: a confirmation on Quit is un-Mac-like
and Quit is unambiguous intent. If anything, make the indicator's copy carry the
fact ("Disconnecting speakers…"). Flagging only so the decision is deliberate.

#### P3-2. No single-instance guard
**Location:** `AudioutCore/Sources/AudioutApp/main.swift` — no running-instance
check
**Impact.** LaunchServices prevents a second launch of the same bundle, so the
normal path is safe. Running the raw Mach-O directly (dev) or a second copy under
a different path yields two processes fighting over the aggregate device and PTP
ports — a hazard already recorded in the project's own notes.
**Recommendation.** Low priority for shipping. If cheap, a
`NSRunningApplication.runningApplications(withBundleIdentifier:)` check at
bootstrap that logs (not kills) would make the collision diagnosable.

#### P3-3. A missing Accessibility grant opens the whole first-run Setup window
**Location:** `AppDelegate.swift:270-283` (`onAccessibilityMissing` → `presentSetup()`)
**Impact.** Starting to route audio (the ownership flip that installs the tap)
can throw the full onboarding window on screen, mid-task, once per launch. It is
guarded and the reasoning (dead keys are otherwise invisible) is sound, but the
response is heavier than the cause and shows audio/network rows that are already
granted.
**Recommendation.** A quieter affordance first (a note in the Mixer with "Fix in
Settings…"), escalating to Setup only if the user acts on it.

#### P3-4. Status menu has no About / Check for Updates
**Location:** `AppDelegate.swift:1192-1205` (`makeStatusMenu`: Settings, Groups,
separator, Quit)
**Impact.** For a Dock-less app the status menu is the only always-available
menu. Updates and About are reachable only by opening the surface and finding
them in Settings.
**Recommendation.** Consider adding "About Audiout" and, when `updaterController`
exists, "Check for Updates…". Keep the menu short.

#### P3-5. `activate(ignoringOtherApps:)` is deprecated on the deployment target
**Location:** `ControlPanelWindowController.swift:523` and `:576`
**Impact.** Deprecated since macOS 14 (the app's floor) in favour of
`NSApplication.activate()`. Works today; will warn/behave differently later.
**Recommendation.** Move to `NSApp.activate()` when convenient.

#### P3-6. Version defaults are release-unaware
**Location:** `scripts/make-app.sh:39-40` (`APP_VERSION=0.1.0`, `BUILD_NUMBER=1`)
**Impact.** A release built without the env overrides ships "Version 0.1.0
(Build 1)" — and Sparkle compares `CFBundleVersion`, so a forgotten bump means
the updater never offers the new build.
**Recommendation.** Refuse to write Sparkle keys when `BUILD_NUMBER` is the
default, the same both-or-neither discipline the script already applies to
`SPARKLE_FEED_URL`/`SPARKLE_ED_PUBLIC_KEY`.

#### P3-7. Sparkle in an `LSUIElement` app — update UI focus unverified
**Location:** `AppDelegate.swift:366-370`
**Impact.** `SPUStandardUpdaterController` presents ordinary windows; a Dock-less
accessory app that is not active can show them behind other apps, and the
first-run "check automatically?" permission prompt can appear with no app context.
**Recommendation.** Needs live check on a build with a real feed. If it misbehaves,
activate the app before `checkForUpdates` and consider `SUEnableAutomaticChecks`.

---

## Systemic patterns

1. **Doc comments have drifted ahead of the code, in the one file where nobody
   can test it.** `StatusItemController` is in `AudioutApp`, deliberately outside
   the test target ("this target is invisible to the test suite" — its own
   AGENTS.md). Its doc describes a routing dot, a mute drain and spoken state,
   none of which exist. The project's own untestability rule is doing its job for
   *decisions* (they were moved to `MenuBarStatus`/`clickAction`) but not for
   *rendering* — `StatusItemIcon` was extracted to be testable and then never
   given the states the doc claims.

2. **One door, no spare key.** Every recovery affordance the app has assumes the
   status item is visible and clickable: reopen is unhandled, the icon position
   isn't remembered, there's no hotkey, no Dock icon, no ⌘Tab. Each individually
   is a small gap; together they mean a single system quirk (the notch) locks the
   user out of a running app.

3. **Feedback stops at the app's own window.** Inside the panel the app is
   scrupulous about not lying; outside it — menu bar glyph, volume HUD, Touch Bar
   — state changes land with no acknowledgement. This is where "live audio is
   high-stakes" is actually tested, because the panel is closed at exactly those
   moments.

4. **System-level takeovers are implemented thoroughly but exposed nowhere.**
   The event tap, the whole-Touch-Bar presentation, the `NSFunctionRow` swizzle
   and the aggregate default-output are all real, deliberate seizures of shared
   system resources. Every one is well-guarded in code; none is visible or
   controllable in Settings. The user cannot see what Audiout has taken over, nor
   give it back.

5. **`AppDelegate` is doing far too much** — 1,930 lines, ~40 closure wirings,
   the permission state machine, the licence state, the routing precedence and a
   temporary Cast diagnostic probe (`:1814-1929`). Not user-facing, but it is why
   items like "re-arm the tap on wake" have no obvious home. The BT/wizard hook
   block (`:554-668`) is a candidate for extraction into a `BackendHookInstaller`.

---

## Positive findings

- **Template-image discipline on the status icon is exemplary**, with the failed
  accent-colour experiment recorded in the doc so it can't be reintroduced
  (`StatusItemIcon.swift:10-20`). Idle vs. streaming is carried by symbol shape,
  never colour — correct on light, dark and tinted menu bars for free.
- **The event tap is the narrowest thing that could work.** Only
  `NX_SYSDEFINED` (mask `1 << 14`), explicitly *not* `.keyDown`
  (`VolumeKeyInterceptor.swift:114-118`); only key codes 0/1/7 decode, everything
  else — brightness, transport, illumination — passes straight through
  (`VolumeKeyInterception.swift:78-105`). The interceptor swallows nothing it
  shouldn't, and both halves of a press are consumed so downstream listeners
  never see an unpaired release.
- **Tap-disabled recovery is handled**: `tapDisabledByTimeout` /
  `tapDisabledByUserInput` re-arm inside the callback
  (`VolumeKeyInterceptor.swift:189-196`), with the "razor:" comment naming the
  ceiling and the upgrade path (a dedicated run-loop thread).
- **The missing-Accessibility case reaches the user** instead of dying in a log
  line (`AppDelegate.swift:270-283`), once per launch.
- **The `markActiveFunctionRowsAsDimmed:` swizzle is present and correct** —
  class method via `class_getClassMethod`, idempotent install, deliberately not
  calling through (would re-enter), plus screen-lock/unlock distributed
  notifications as a second signal (`TouchBarFullBar.swift:300-348`). This is the
  known trap and it is handled.
- **Touch Bar work is gated on real Touch Bar hardware** by a closed model list
  (`AudioutCore/Sources/AudioutCore/TouchBarHardware.swift`), and every private
  selector is `responds(to:)`-guarded so a future macOS degrades to "no custom
  bar" rather than crashing.
- **The user's Touch Bar is handed back before anything that can block on quit**,
  and also on `willPowerOff` (`AppDelegate.swift:322-324`, `:397-399`, `:1483`) —
  with the live incident that motivated it recorded in the comment.
- **Quit is graceful and bounded**: `.terminateLater`, `stopAndWait(timeout: 2s)`,
  a re-entrancy guard against a second ⌘Q, and a "Disconnecting…" panel that only
  appears if the wait exceeds ~300 ms (`AppDelegate.swift:1469-1503`).
- **The click policy is a pure, tested function** (`AppSurfaceController.clickAction`),
  including the genuinely hard `.ignore` case where the click that dismissed the
  panel would otherwise reopen it (`ControlPanelWindowController.consumeRecentResignDismissal`).
- **Panel manner profiles are coherent**: `.titled`/`.closable` never leave the
  style mask (the documented reason `performClose` would silently die), Escape is
  routed through the same close path, and pinned/unpinned differ only in manner
  bits.
- **Spaces and full-screen are handled deliberately** — `.moveToActiveSpace` +
  `.fullScreenAuxiliary` on the panel, the decorative backing window *and* the
  quitting indicator, so all three follow the user rather than yanking them to
  another Space.
- **Accessibility settings are honoured in the shell**: Reduce Motion flattens
  both the open and close fades; `ReduceTransparencyFallbackView` backs the
  vibrancy in the quitting indicator.
- **The permission usage strings are the best copy in the product** —
  `make-app.sh:45-51`. Written in the user's mental model ("send my audio to
  speakers", not "record"), each one states the limit explicitly, and each is
  inserted with `plutil` (never PlistBuddy — the apostrophe trap is documented at
  `:636-641`) *and* asserted afterwards, so a silently-empty rationale cannot
  ship.
- **`NSBonjourServices` is asserted per entry**, including the self-discovery
  type used to prove a Local Network grant and the Cast type — each with its own
  failure message naming the symptom.
- **Signing is thorough and self-verifying**: hardened runtime, inside-out
  signing of dylibs / Sparkle's nested XPC services / ptp-helper / tcc-probe, no
  `--deep` signing, and post-hoc assertions that the runtime flag *and* the
  entitlements actually embedded (AMFI can drop a malformed plist while codesign
  exits 0).
- **Sparkle is both-or-neither gated** (`make-app.sh:727-737`): a feed URL with
  no EdDSA key is refused outright rather than shipping an unverified update
  channel, and a build with no feed gets no updater object at all
  (`AppDelegate.swift:366`), which correctly hides the Settings button.
- **The app name is consistent**: no "AirPlay Controller" survives in any
  user-visible string (grepped across all Swift sources and scripts — the single
  hit is a path comment).
- **Crash-safety bootstrap runs at the very first instruction**: `SIGPIPE` masked
  process-wide and an uncaught-exception handler installed before anything can
  touch a pipe, with a `write(2)`-based logger that cannot itself raise
  (`main.swift:20-50`, `AppDelegate.swift:21-35`).
- **No window restoration, stated as policy and implemented consistently** —
  every window sets `isRestorable = false` and the app opts into secure
  restorable state, which is free and silences the macOS warning.
