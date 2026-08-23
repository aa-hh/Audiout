# G1 — Live UX Walkthrough Session Script

Facilitator-run, Alec-driven. ~40 minutes. Validates headless Phase 3 audit
suspects against the real, running app. Alec is the owner, not deeply
technical — read him the plain-language instruction verbatim, watch what he
does without prompting, then note confirm/refute.

**How to use this doc:** work top to bottom. Each item is `- [ ]ID — instruction. **Confirms bug if:** … **Refutes if:** … *Source: file — finding*`.
Check the box, jot one line (confirmed / refuted / unclear) next to it during
the session. Items marked **(if time allows)** are the first to cut.

---

## Setup (2 min)

Repo root = this worktree. Build once if `./build/Audiout.app` doesn't exist yet:

```
scripts/make-app.sh build
```

**Always launch with `open`, never by running the binary directly** — a
terminal-exec'd binary inherits the terminal's TCC identity and permission
grants won't attach to the app (bit the team before). Quit between relaunches
via the popover header's power-glyph button (or the app's own quit path,
which is itself one of the things we're testing).

A **bare launch has no env vars set** and resolves to the **mock backend**
(fake demo fleet — MacBook Pro Speakers, Sonos Move, Move 2, "Mixer",
Living Room TV, Bedroom HomePod, Office). This is deliberate: it's the right
backend for a UX session — no PTP port conflicts with other worktrees, no
real speakers needed, and every UI surface (popover, windows, onboarding)
behaves identically to the real backend. **Real-AirPlay-device checks
(actual connect/disconnect against Alec's Sonos/HomePod gear, real Wi-Fi-loss
behavior, the true native-backend "unknown cause" diagnosis gap, a real
downloaded-and-quarantined signed build's Gatekeeper/launch overhead) are
deliberately deferred to the G2 signed-build session** — nothing here
requires real hardware.

This script uses two more launch modes for specific sections, each requiring
a quit + relaunch (env vars are only read at process launch; `open` doesn't
forward shell env, so set session-wide first):

```
# Mode 2 — scripted connection failures (Pass 2 below)
launchctl setenv AIRPLAY_MOCK_SCENARIO connection-demo
open "./build/Audiout.app"
# … when done:
launchctl unsetenv AIRPLAY_MOCK_SCENARIO

# Mode 3 — the unified floating-panel shell (Pass 3 below)
launchctl setenv AIRPLAY_CONTROL_PANEL 1
open "./build/Audiout.app"
# … when done:
launchctl unsetenv AIRPLAY_CONTROL_PANEL
```

**Explicitly out of scope for G1** (can't be exercised in this session type at
all, not just deferred to G2): `crash-hang.md` M1 (declared macOS 13.0 vs.
compiled-for-14.0/needs-14.2 mismatch) needs separate OS versions/VMs — track
separately, not a G1 or G2 item.

---

## Pass 1 — Default launch (~24 min)

### Popover (~7 min)

- [ ] **P1-01** Open the popover fresh (nothing playing yet). Zoom in on any
  device row's little volume-level bar at the far left. **Confirms bug if:**
  a small green mark/sliver sits at the base of the bar even though nothing
  is playing (should be fully empty). **Refutes if:** the bar is completely
  blank at rest. *Source: visual.md C2.*

- [ ] **P1-02** Without explaining anything, ask: "Looking at the three small
  icons in the top corner of this popover — what do you think each one
  does?" Note his guesses, then reveal (Groups editor / Settings / Quit).
  **Confirms friction if:** he can't guess at least 2 of 3 without hovering.
  *Source: cold-user-ux.md Flow 4/Flow 8 (icon-only header); accessibility.md T2.*

- [ ] **P1-03** Ask: "What's the difference between checking a box next to a
  speaker in the Devices list, and picking something in the 'Audio Out'
  dropdown?" **Confirms bug if:** he can't articulate that the dropdown
  targets the *set* the checkboxes build. **Source of the exact term
  mismatch to listen for:** the dropdown says "Selected Devices (n)" but the
  card header just says "Devices." *Source: cold-user-ux.md Flow 3 (routing
  model unexplained); copy.md Issue 15.*

- [ ] **P1-04** With the Mac ("Current Device") selected, toggle ON an
  AirPlay speaker. Watch the Current-Device row — it silently un-toggles
  itself with only a one-time visual flash, no text. Ask: "Did you notice
  what just happened to the Mac's row, and do you know why?" **Confirms bug
  if:** he didn't notice or can't explain it. *Source: cold-user-ux.md Flow 3
  (auto-swap).*

- [ ] **P1-05** Select 2+ AirPlay speakers together (a mixed set), then hover
  the now-disabled "Current Device" checkbox and read the tooltip aloud:
  *"Synced everywhere-audio arrives with the new engine."* Ask if that
  makes sense. **Confirms bug if:** he's confused or the sentence sounds
  broken to him (it is — no verb agreement). *Source: cold-user-ux.md Flow 3
  (local-mix tooltip).*

- [ ] **P1-06** Open a per-app routing destination dropdown (± footer → add
  an app, or an existing routed app row). Point at "No Redirect" and
  "Current Device — [His Mac's name]." Ask: "What's the difference between
  these two?" **Confirms bug if:** he thinks they're different (they're
  functionally identical — differ only in internal UI state, not behavior).
  *Source: cold-user-ux.md Flow 5; copy.md Issues 11–13.*

- [ ] **P1-07** Try **Cmd+Q**. **Confirms bug if:** nothing happens. Then
  right-click the menu-bar icon. **Confirms bug if:** no menu appears. Only
  remaining path: the power-glyph button in the popover header — confirm
  that's the only way Alec would know to quit. *Source: cold-user-ux.md
  Flow 8 (no Cmd+Q, no right-click menu).*

- [ ] **P1-08** Turn Wi-Fi off (menu bar Wi-Fi icon) for ~15 seconds with the
  popover open, watch the Devices card, then turn Wi-Fi back on. **Confirms
  bug if:** nothing about the card changes to indicate a network problem
  (same "Looking for devices…"/unchanged state either way — there's no
  network-awareness code path at all, so this should look identical
  regardless of backend). *Source: cold-user-ux.md Flow 6 (no Wi-Fi
  awareness).*

### Groups window (~4 min)

- [ ] **P1-09** Open the Groups window (popover header icon). Click into
  Finder (or any other app) so Groups goes behind it. Click the menu-bar
  icon. **Confirms bug if:** only the small popover opens — Groups stays
  buried, with no way back short of quitting. **Refutes if:** Groups
  re-fronts. *Source: window-panel.md C1.*

- [ ] **P1-10** Move the Groups window to a different spot on screen (and/or
  resize it), then close it (Cmd+W) and reopen via the header icon.
  **Confirms bug if:** it snaps back to centered/default size instead of
  reopening where you left it. *Source: window-panel.md M2.*

- [ ] **P1-11** With the system in Dark mode (Settings ▸ Appearance, or
  System Settings), open Groups in its default empty "No groups yet" state.
  **Confirms bug if:** the text is hard to read (near-black on dark gray).
  *Source: visual.md C3a.*

### Settings window (~3 min)

- [ ] **P1-12** Repeat P1-09's buried-window test for the Settings window
  (same underlying bug, same fix). One line is enough — don't re-litigate.
  *Source: window-panel.md C1.*

- [ ] **P1-13** Before clicking, ask Alec what he thinks the Settings ▸
  General button **"Run Setup Again…"** does. Then click it together.
  **Confirms bug if:** his guess doesn't match "re-check my permissions."
  *Source: copy.md Issue 4.*

- [ ] **(if time allows) P1-14** In Settings ▸ Audio, exclude an app, then
  toggle it while nothing is streaming vs. while something is streaming —
  watch the button read "Apply" vs. "Apply & Reconnect." Ask if the
  difference is clear. *Source: copy.md Issue 10.*

### Onboarding re-run (~4 min)

Trigger via Settings ▸ General ▸ **"Run Setup Again…"**.

- [ ] **P1-15** Click through every row **without** clicking any "Allow…"
  button, then click **Done**. **Confirms bug if:** it closes immediately
  with no warning that nothing was granted. *Source: cold-user-ux.md Flow 1
  (Critical — Done never gates on grants).*

- [ ] **P1-16** Look at the Local Network permission row's description text.
  **Confirms bug if:** "Wi-Fi" wraps onto its own line as an orphaned "Fi."
  *Source: visual.md N2.*

- [ ] **P1-17** With onboarding open and the audio-permission row still not
  granted, Cmd+Tab away to another app and back. **Confirms bug if:** you
  hear the confirmation tone replay even though nobody clicked "Allow."
  *Source: window-panel.md M3.*

- [ ] **(if time allows) P1-18** Read the audio and Remote Control permission
  row descriptions aloud ("Send your Mac's sound to your speakers. Allowing
  plays a brief tone…" / "Let the speaker's buttons control playback.").
  Ask if either is confusing. *Source: copy.md Issues 1–2.*

### Multi-instance & crash check (~3 min)

- [ ] **P1-19** With the app already running, `open` the same `.app` bundle
  again. **Confirms bug if:** a second menu-bar icon appears and does
  nothing useful (dead second instance — its engine can't bind the ports
  the first instance holds). Quit the duplicate afterward.
  *Source: crash-hang.md m1.*

- [ ] **P1-20 — CAUTION, may crash the app (that's the point of the test).**
  Save/close anything else you care about first. Route an app to
  **"Current Device"** and start it playing, then change the Mac's default
  output device (System Settings ▸ Sound, or Option-click the volume menu
  bar icon) while it's playing. **Confirms bug if:** the app hard-crashes.
  A known, already-built fix exists but isn't wired in yet — this is
  checking whether the crash is still live. If it crashes, just relaunch
  and continue. *Source: crash-hang.md C1 (Critical, top-priority finding).*

### Performance feel (~2 min)

- [ ] **P1-21** Open Activity Monitor, filter for "Audiout." Open/close
  the popover ~10 times quickly, then open and close Groups and Settings a
  few times each. Watch the Memory column before/after. **Confirms bug if:**
  memory climbs noticeably and doesn't come back down. Also glance at CPU%
  while the popover sits open and idle vs. while you're actively
  dragging a volume slider. **Confirms bug if:** CPU sits noticeably above
  ~0% while idle. *Source: performance.md (open-popover CPU / repeated
  open-close memory — both `[confirm-in-G1]`).*

- [ ] **(if time allows) P1-22** Just eyeball it: does the popover fade in
  snappily when you click the menu-bar icon, or does it feel sluggish?
  *Source: performance.md (popover show — native fade, `[confirm-in-G1]`).*

---

## Pass 2 — Connection-failure scenario (~4 min)

Quit, then:
```
launchctl setenv AIRPLAY_MOCK_SCENARIO connection-demo
open "./build/Audiout.app"
```
This scripts three of the demo devices to behave specially: **"Mixer"**
fails once (~1.5s) then succeeds on retry; **"Move 2"** takes a long
(~4s) connect; **"Office"** connects, then drops and stays down.

- [ ] **P2-01** Toggle **"Mixer"** on. Watch for the failure at ~1.5s.
  **Confirms bug if:** the row just dims with "Couldn't connect" text and
  **nothing else** appears — no Retry button, no cause, no Copy Details (a
  whole panel is supposed to slide in under the row and doesn't). This is
  the single most-cited dead feature across two independent audits.
  *Source: visual.md C1 (Critical — the panel never attaches to the visible
  view tree) + cold-user-ux.md Flow 2 (Major — even if it did render, the
  shipping native backend only ever produces this same generic "unknown"
  cause, never the specific ones written in the code).*

- [ ] **P2-02** Toggle **"Move 2"** on and watch it during its ~4s connect
  window. **Confirms bug if:** you can't tell "still connecting" from
  "already connected" except by the dot's color/pulse — no "Connecting…"
  text anywhere. *Source: accessibility.md M1.*

- [ ] **P2-03** Toggle **"Office"** on, let it connect then drop (~8s
  later) and stay failed. **Confirms (documented, not urgent) gap:**
  nothing in the UI tells you it'll sit there until you retry — could read
  as "the app is stuck." *Source: cold-user-ux.md Flow 6.*

Quit, `launchctl unsetenv AIRPLAY_MOCK_SCENARIO`, relaunch default before Pass 3.

---

## Pass 3 — Control-panel shell (~5 min)

This is a built-but-off-by-default alternate window system
(`AIRPLAY_CONTROL_PANEL=1`) meant to fix the buried-window bug from P1-09.
Quit, then:
```
launchctl setenv AIRPLAY_CONTROL_PANEL 1
open "./build/Audiout.app"
```

- [ ] **P3-01** Click the popover's Groups header icon — it should open as a
  floating panel attached near the menu-bar icon instead of a normal
  window. Look for a visible close (X) button anywhere on it. **Confirms
  bug if:** there is none. Then click the menu-bar icon again while the
  panel is open. **Confirms bug if:** it just re-fronts the panel instead
  of closing it. Then try **Escape**. **Confirms bug if:** nothing closes
  it either (leaving app-switch-away or Quit as the only escapes).
  *Source: window-panel.md C3 (Critical) + accessibility.md M2 (Major) —
  same underlying bug, hidden close button with no confirmed keyboard
  alternative, flagged independently by both audits.*

- [ ] **P3-02** With Dark mode on, view Groups content hosted inside this
  panel. **Confirms bug if:** the sidebar is dark but the main content pane
  stays light-gray (half-dark-mode look). *Source: visual.md C3b.*

Quit, `launchctl unsetenv AIRPLAY_CONTROL_PANEL` when done with this pass
(leave it unset — do the multi-display check below before or after, either
launch mode works for it since the underlying bug is windows-generic).

---

## Multi-display / Spaces (only if a second display is available)

- [ ] **P3-03 (if a 2nd display or extra Space is available)** Open Groups
  (either launch mode) on one Space/display, then go fullscreen in some
  other app on a different Space. Click the menu-bar icon to reopen Groups.
  **Confirms bug if:** macOS yanks you out of the fullscreen app / does a
  full Space-switch animation just to show the config window, instead of
  something gentler. *Source: window-panel.md M1.*

- [ ] **(if time allows) P3-04** With a second display connected, note which
  screen the Groups window and the onboarding window each center on when
  first opened. Low priority — only worth a note if it visibly surprises
  Alec. *Source: window-panel.md T1.*

---

## VoiceOver spot-check (5 min)

Toggle VoiceOver: **Cmd+F5** (or System Settings ▸ Accessibility ▸
VoiceOver). Basic navigation: **VO = Control+Option**. **VO+Right/Left
Arrow** moves between items. **VO+Space** activates the focused item.
**VO+Shift+Down Arrow** enters a group, **VO+Shift+Up Arrow** exits it. Plain
**Tab** + **Space/Return** also works for the keyboard-only checks below —
VoiceOver isn't required for those two.

- [ ] **VO-01 — keyboard-only, VoiceOver optional.** In Groups (or Device
  Detail), **Tab** to the large device/group icon (don't click it), then
  press **Space** or **Return**. **Confirms bug if:** nothing happens — this
  is a full feature (changing a device's icon) with **zero** keyboard/VO
  path, the only such gap in an otherwise well-covered app. *Source:
  accessibility.md C1 (Critical).*

- [ ] **VO-02** With VoiceOver on, VO-navigate to a device row that's mid
  "Connecting…" (use Pass 2's "Move 2" scenario if still available, or any
  connecting device). **Confirms bug if:** VoiceOver either lands on a
  separate, unlabeled stop for the little status dot itself, or the row's
  spoken label doesn't distinguish "connecting" from "connected." *Source:
  accessibility.md M1.*

- [ ] **VO-03** VO-navigate to a Group row's outer body (not its child
  chevron/activate/mute buttons) in the Groups window and press **VO+Space**.
  **Confirms bug if:** nothing happens even though it's announced as a
  "button." *Source: accessibility.md N4.*

- [ ] **VO-04** In Settings ▸ Appearance, VO-navigate across the three theme
  tiles (Light/Dark/Match System). **Confirms bug if:** VoiceOver never
  says which one is currently selected — all three sound identical.
  *Source: accessibility.md N1.*

---

## New-issue capture (~3 min)

Open-ended — ask Alec directly, don't lead him. Write down anything new
verbatim, even if it doesn't map to an existing finding:

- "What annoyed you just now that I didn't specifically ask about?"
- "If you were showing this to a friend for the first time, what would you
  have to explain to them first?"
- "Was there any moment in the last 40 minutes where you weren't sure if
  something had worked or not?"
- "Anything you expected to be able to do that you couldn't find?"

---

## Session wrap

Quit the app, `launchctl unsetenv AIRPLAY_MOCK_SCENARIO AIRPLAY_CONTROL_PANEL`
(harmless if already unset) so the next session starts clean. File
confirm/refute notes back into the relevant `phase-3-findings/*.md` files'
`[confirm-in-G1]` tags (replace the tag with the live verdict) rather than
leaving them here.
