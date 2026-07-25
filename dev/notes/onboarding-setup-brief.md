# First-run onboarding / permission priming — brief + gated-verify recipe

Status: BUILT 2026-07-17 on `claude/onboarding-permission-priming` (off main
a8f4eb5). Everything is unit-tested and offscreen-snapshotted EXCEPT the audio
self-test tone, which needs one live TCC session on a signed build (recipe
below). Public-release-readiness item — irrelevant to the sole dev (already
granted everything), essential before anyone else runs the app.

## Why this exists

Users get alarmed granting "audio recording" access — in their heads they're
*sending* audio to a speaker, not recording. macOS files the process-tap grant
under **Screen & System Audio Recording**, next to real screen recorders, and
frames it as "record." The flow reframes that in the user's words BEFORE any
system prompt fires (the standard priming pattern), and covers all THREE
grants the app needs (or will need): System Audio (the Core Audio tap), Local
Network (Bonjour), and Remote Control (Accessibility — primed ahead of the
not-yet-merged speaker-side transport-control feature on branch
`claude/speaker-input-responsiveness-b8123f`, so the grant is already in place
when it ships rather than a cold third prompt later; see ahh's decision,
2026-07-18).

## The resolved open question (don't re-litigate)

**There is no public request-or-check API for the process-tap TCC permission.**
Verified against the 14.5 SDK: `AudioHardwareTapping.h` has exactly
`AudioHardwareCreate/DestroyProcessTap`; no permission API anywhere in CoreAudio
(cf. CoreGraphics `CGRequestScreenCaptureAccess`, AVFoundation
`requestAccessForMediaType:` — taps have no equivalent). AudioCap's
`TCCAccessPreflight/Request` are PRIVATE SPI, ruled out.

**A denied tap does not fail** — `AudioHardwareCreateProcessTap` returns `noErr`
and the IOProc delivers correctly-sized ALL-ZERO buffers
(`dev/audiocap/README.md`, empirically confirmed Phase 0e). So a probe can't read
the answer from a return code; the only public signal is whether captured audio
is silent. We supply our own known audio and check for it → the self-test tone.

## How the audio self-test works (`CoreAudioTonePermissionProbe`)

1. Play a quiet sine **in our own process**, rendered to the default output.
2. Tap **only our process** (`CATapDescription(stereoMixdownOfProcesses:)`) with
   `muteBehavior = .muted` → captured but never sent to the speakers (silent to
   the user; nobody else's audio touched — a *global* tap would capture ambient
   audio, risk a false "granted," and contradict the privacy promise).
3. Read the tap ~300 ms, take the peak sample. Above threshold ⇒ **granted**;
   ~zero ⇒ **denied** (the denied-tap zeros). Tear down promptly (tap lives
   < 0.5 s), so no lingering tap or mute.

`.muted` matters: `CATapUnmuted` is the default, and even `.mutedWhenTapped` only
mutes while read — a probe that sets `.muted` (or is never read) can't mute the
user. The muting worry in the original ask was over-stated.

Local Network has NO verify API (TN3179): `LocalNetworkPrimer` just starts a
brief `NWBrowser` for `_airplay._tcp` to fire the prompt, and the model marks it
`.requested`. Remote Control (Accessibility) is the odd one: `AXIsProcessTrusted()`
IS a real, public, synchronous status API — but a grant only ever flips later,
when the user manually toggles it in System Settings, and macOS doesn't
reliably push that flip back to an already-running process without a relaunch.
So `RemoteControlPrimer` gets the same `.requested`-only treatment as Local
Network, on purpose — reading a stale `false` and confidently reporting
`.denied` would be worse than admitting we can't verify. The denial fallback
for all three is a System Settings deep link.

## Architecture (files)

- Core (AppKit-free, unit-tested): `SetupModel.swift` (statuses, seams,
  `SystemSettingsPane`, launch gate, `complete()`), `AppSettings.hasCompletedSetup`.
- Core (gated Core Audio / Network / ApplicationServices, `#if canImport`):
  `AudioCapturePermissionProbe.swift`, `LocalNetworkPrimer.swift`,
  `RemoteControlPrimer.swift`.
- UI (`AudiouterOnboardingUI`): `OnboardingWindowController`,
  `OnboardingViewController`, `PermissionRowView`, `SystemSettingsOpener`.
  Offscreen render: `swift run onboarding-snapshot` → `dev/notes/onboarding-snapshots/`.
- App wiring (`AppDelegate`): first-run gate defers `backend.start()` (so the LN
  prompt is primed, not sprung) until the window is dismissed; "Run Setup Again…"
  in Settings ▸ General re-presents it.
- Packaging (`scripts/make-app.sh`): `NSAudioCaptureUsageDescription` (already
  present on main), plus NEW `NSLocalNetworkUsageDescription` + `NSBonjourServices`
  — all via `plutil` (never PlistBuddy — apostrophes) with a landed-assert each.

## Live-test findings — 2026-07-17b (first real launch)

Two problems surfaced the first time this ran on a real Mac (macOS 14.4), both
now fixed in code; a third is a thing to WATCH on the next run.

1. **Setup window got buried by the permission prompt.** This app is `.accessory`
   (no Dock icon, absent from Cmd-Tab), so when the system TCC / Local Network
   prompt stole focus we resigned active and the setup window slid behind other
   apps with no way back except the menu-bar icon. Fix (`OnboardingWindowController`
   + `OnboardingViewController`): the setup window is now `.floating` for the whole
   run (system permission alerts sit at a higher level, so they still appear on
   top), we re-front + re-activate on `didBecomeActive`, and we explicitly re-front
   after the audio probe's `await` returns.

2. **"Open Settings" for Local Network landed on the Privacy & Security ROOT, not a
   Local Network pane.** Root cause is NOT a wrong anchor: verified by scrolling
   the entire Privacy list on 14.4 — there is **no "Local Network" category at all
   until some app has actually registered local-network access**. The
   `?Privacy_LocalNetwork` anchor roots itself when the category is absent (same as
   `?Privacy_ScreenCapture` would if Screen Recording had never been used). The
   bundle DID carry `NSLocalNetworkUsageDescription` + `NSBonjourServices`, so the
   likely reason nothing registered is that problem #1 blocked the user before they
   ever completed the LN step. Expectation after the fix: click LN **Allow…** →
   prompt fires → (allow or deny) → the "Local Network" category now exists → the
   deep link lands on it. **Still to confirm live** (couldn't, category was absent):
   that `?Privacy_LocalNetwork` actually lands on the pane once it exists, and that
   the `NWBrowser` prime reliably fires the prompt for an ad-hoc-signed build.

3. **FIXED: the audio probe raced the first-run TCC prompt.** It used to create
   the tap and then judge from a fixed ~300 ms tone window — but
   `AudioHardwareCreateProcessTap` does NOT block until the user answers, so on a
   fresh grant the window elapsed while the prompt was still up, the tap delivered
   zeros, and the row flashed **Denied** even though the user had just clicked
   Allow. `CoreAudioTonePermissionProbe.runProbe()` reads the live TCC decision up
   front (`TCCAccessPreflight` on `kTCCServiceAudioCapture`, 14.4+) — already-decided
   → reported immediately (no tone, no beep on a re-confirm). For an undecided grant
   it surfaces the prompt (creating the tap) and then **watches for our tone to come
   through the still-open tap**: a granted tap delivers the sine, a denied one zeros,
   so the peak flips true the instant the user allows. NOTE: an intermediate version
   *polled* `TCCAccessPreflight` in a loop and HUNG — that read serves a **stale
   in-process cache**, so after the grant it kept returning "undetermined", the
   spinner ran the full `promptAnswerTimeout`, and it reported Denied. The functional
   tone read has no such cache dependency. **CONFIRMED 2026-07-25 by measurement —
this "stale in-process cache" note was RIGHT, and two other places in the repo
that claimed otherwise were wrong.** On a signed build the in-process read stayed
`2`/undetermined for 177 consecutive ticks over 203 s after the user granted,
while a freshly spawned helper process read `0`/granted in the same second; only
a NEW process ever sees the change. Consequence, now load-bearing: **any
in-process poll of that read is dead on arrival** — which is why detection is
event-driven (`PermissionStateObserver`) and reads through a short-lived helper
(`TCCProbeRunner`) rather than polling. An explicit TCC `denied` short-circuits;
   an ignored prompt ends in `.denied` at the timeout. **Still wants a signed-build
   live-verify** (drives real Core Audio / the prompt), but the grant should now
   register the moment you click Allow.

## Live-test findings — 2026-07-22 (cold prompt before Setup)

**The audio-capture prompt fired at LAUNCH, before Setup ever showed.** Root
cause was NOT the onboarding flow (which correctly defers discovery and only
probes on the explicit "Allow…"): it was a **restored per-app route**. With
`setup.hasCompleted = 1`, launch skips Setup and runs the normal path, and
`AppDelegate.applicationDidFinishLaunching` calls `pushAppRoutesToBackend()`
unconditionally (before the setup gate). A persisted route (Firefox → an AirPlay
device) pushed into the per-app capture coordinator, which created a process tap
on the running routed app → `AudioHardwareCreateProcessTap` → the TCC prompt,
cold, with no Setup screen. (The whole-system gate was NOT the trigger here — the
persisted whole-system selection was just `local-mac`, so `reconcileCaptureGate`
kept it closed.)

**Fix — a cold-prompt guard at every capture-tap site.** New `SystemAudioCaptureTCC`
exposes a silent, prompt-free `isGranted()` (**undetermined counts as
not-granted**, so the gate can never trigger a cold prompt). *Superseded
2026-07-25:* it now reads BOTH `kTCCServiceAudioCapture` and
`kTCCServiceScreenCapture` through `TCCAccessPreflight` and combines them
(any-granted wins; denied only when both agree), and resolves through
`effectiveStatus()` so a freshly confirmed grant is honoured. The old
`CGPreflightScreenCaptureAccess` fallback was removed from the decision path:
it reads the Screen Recording list, which an audio-only app is never in, so it
could only ever manufacture false denials — it survives solely as a last-resort
rescue when the private symbol is unresolvable, where a `false` maps to
undetermined rather than denied. Both real tap classes —
`NativeCaptureCoordinator` (whole-system) and `PerAppCaptureCoordinator` (per-app
routing AND the `.unmuted` metering tap, which reuses it) — now `guard
SystemAudioCaptureTCC.isGranted()` before creating the tap and throw
`tapCreationFailed` otherwise. The ONLY tap allowed to prompt is the Setup
probe's own `SelfProcessTap`, a separate class that is deliberately not gated.
After the user grants and closes Setup, `onFinished` re-pushes routes so the
now-permitted taps start.

**Also done (ahh's follow-up): per-app routes now RESET when the routed app quits.**
Previously a `.device` redirect persisted across the routed app's own quit/relaunch
(the thing that let a stale Firefox→speaker route re-tap at launch). Now the
`didTerminateApplicationNotification` observer calls
`AppRoutingController.resetDeviceRoute(bundleID:)` — reverts a `.device` redirect to
`.noRedirect` (no-op for `.currentDevice`/`.noRedirect`/unrouted), reusing the same
un-route path a manual change takes, so the per-app tap is torn down and a relaunch
never auto-resumes streaming. `NativeBackend.handleAppTerminated` is now UNUSED
(dead) — left in place for a later tidy-up rather than widening this diff into the
`AppRouteConfiguring` protocol + conformances.

**Open follow-up:** whole-system capture resume on the `.permissionLost` path
(backend already started, so no re-`reconcile`) — minor, happens on the next
selection change. And the dead `handleAppTerminated`/`handleAppLaunched` T4
machinery could be removed.

## ⚠️ Gated live-verify recipe (ahh, signed build)

The self-test tone can't be exercised in CI / an agent shell: an unsigned/ad-hoc
binary has no stable TCC identity, and a shell-launched process inherits the
terminal's grant. Verify on a real launch:

```bash
# 1. Reset the grant so the prompt fires fresh (un-scoped — ad-hoc identity is
#    per-binary, so a bundle-id-scoped reset won't match). Optional but honest.
tccutil reset AudioCapture
# 2. Build + launch the REAL bundle (never `swift run` — identity drift). `open`
#    so the app doesn't inherit the terminal's TCC identity.
scripts/make-app.sh && open "./build/Audiouter.app"
```

Because the shipping default backend must be `native` for setup to present,
launch native (see runbook §3 for the env-forwarding options, e.g. run the
bundle's binary directly with `AIRPLAY_BACKEND=native`).

**Testing knob — `AIRPLAY_SETUP`** (sibling of `AIRPLAY_BACKEND`, so forward it
the same way): `skip` keeps the flow out of the way during repeated dev launches
(don't depend on the persisted `hasCompletedSetup` — a ✕ dismissal doesn't set
it); `force` re-shows it every launch to iterate on the flow without resetting
anything; unset = normal gate. Then:

1. First launch → onboarding window appears BEFORE the backend starts (no Local
   Network prompt yet).
2. Click **Allow…** on System Audio → the macOS "…would like to record this
   computer's audio" prompt appears, carrying our usage string. Approve it.
   → the row should flip to **Allowed** (green check). This is the bit to
   confirm: the tone probe must report `.granted` ONLY after the real toggle is
   on. Deny it (or toggle off in System Settings) and re-run setup → the row
   should read **Denied** with an Open Settings button.
3. Click **Allow…** on Local Network → the LN prompt appears → row shows
   **Requested**.
4. Click **Allow…** on Remote Control → macOS shows the Accessibility alert
   ("…would like to control this computer") → row shows **Requested**. Nothing
   in the shipped app uses this grant yet (the feature it's for isn't merged),
   so there's no downstream behavior to verify here — just confirm the prompt
   fires and the row updates.
5. Click **Done** → the backend starts (discovery runs) and setup won't reappear.
   Close with ✕ instead → backend still starts, but setup reappears next launch.

Known signing caveat: the prompt reportedly fires only for a properly signed
binary, and TCC keys off a stable identity (ad-hoc grants reset every rebuild).
For a real public release this needs Developer ID + notarization — which also
makes the macOS Application Firewall auto-allow the app, removing the PTP
`socketfilterfw` step (why the firewall step is deliberately NOT in onboarding).

If `.granted` never shows even with the toggle on: check `AIRPLAY_DEBUG_LEVELS=1`
RMS logging on a real stream to separate "tap denied → zeros" from a probe bug,
and confirm the tone engine started (the probe returns `.denied` if it can't
produce its own audio). The whole Core Audio path is isolated in
`AudioCapturePermissionProbe.swift` — fixes land in that one file.
