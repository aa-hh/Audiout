# Settings brainstorm: what a paid Audiouter should offer

Today's Settings window has exactly three sections and one control each that
really matters: **General** (launch at login, a button to re-run the
permission flow), **Appearance** (a light/dark/system theme picker), and
**Audio** (an excluded-apps list, a "restore Mac audio after wake" delay, and
an advanced audio-buffer size). That's it — four real, tunable choices in the
whole app. Alec's own reaction during the live walkthrough was that Settings
"doesn't feel comprehensive" for something people are expected to pay for
(`gated-ux-walkthrough.md` G1-N15). This document is a curated brainstorm of
what a paid, general-public AirPlay-routing utility should offer instead —
grounded in what comparable paid Mac audio/menu-bar utilities (SoundSource,
Bartender-style tools) treat as baseline, and in gaps the phase-3 audits
already surfaced. It is a proposal, not a spec — nothing here is committed,
and it deliberately stays short of "add every imaginable toggle."

## Proposed settings

### General
*(today: Launch at login · Run Setup Again…)*

- **Launch at login** — *(EXISTS)* starts Audiouter automatically at login.
- **Run Setup Again…** — *(EXISTS)* re-opens the first-run permission flow.
- **Global keyboard shortcut to open Audiouter** — *(NEW)* lets the customer
  assign a hotkey (e.g. ⌥Space) that opens the popover from anywhere, no
  mouse required. Every comparable paid menu-bar utility (Bartender, Alfred,
  Raycast) treats an instant-recall shortcut as table stakes — someone paying
  for a faster way to control their speakers shouldn't have to go hunting
  for a small icon in a crowded menu bar.
- **Resume previous speakers on launch** — *(NEW)* a toggle to automatically
  reconnect the last-selected devices or group whenever the app starts.
  Today this never happens by design (`AudiouterCore/AGENTS.md`: "the live
  routing set is not auto-resumed at launch"). A customer who set up their
  evening listening setup expects it to just come back after a reboot or
  relaunch, the way a real smart-home product would.
- **Check for updates** — *(NEW)* "Automatically check for updates" toggle
  plus a "Check Now" button, with the current version shown alongside. A
  paid, direct-download Mac app (outside the App Store) is expected to keep
  itself current and to let the customer control when that happens — this
  row is the natural home for the auto-update work already being scoped
  separately (`commercial-wrapper.md` §1, Sparkle).
- **About & Support** — *(NEW)* version number, a release-notes/changelog
  link, and a "Contact Support" or "Send Feedback" link, all in one place.
  Today there is no in-app way to see what version you're running or how to
  get help at all (`cold-user-ux.md` Flow 8) — for a paid product that's the
  first thing a frustrated customer looks for before they email you.
- **Menu bar icon shows connection status** — *(NEW)* a toggle for whether
  the status-bar glyph visibly indicates "actively streaming" vs. idle, so a
  customer can confirm audio is really going to their speakers without
  opening the popover.

### Audio
*(today: Excluded applications · Restore Mac audio after wake · Advanced ›
Audio buffer)*

- **Excluded applications** — *(EXISTS)* apps whose audio is never captured
  or routed.
- **Restore Mac audio after wake if speakers don't return** — *(EXISTS,
  needs a copy/clarity pass per `gated-ux-walkthrough.md` G1-N16 — not
  redesigned here.)*
- **Advanced › Audio buffer** — *(EXISTS)* trade-off between reaction speed
  and Wi-Fi resilience.
- **Default connect volume** — *(NEW, out of scope here)* what level a
  speaker starts at when it connects belongs conceptually in this tab, but
  it's already being scoped as its own task (CONNECT-VOLUME per
  `gated-ux-walkthrough.md` G1-N1) — mentioned for completeness only, not
  redesigned in this document.
- **Maximum volume per speaker** — *(NEW)* an optional ceiling that clamps
  how loud a given AirPlay target can ever be pushed from this Mac,
  independent of the source app's or the Mac's own volume. Genuinely useful
  in shared spaces — a kid's room, a shared office — where the owner wants a
  hard safety ceiling that isn't just "quieter by default," it's "can never
  get this loud, period."
- **Automatically reconnect a dropped speaker** — *(NEW)* a toggle so a
  speaker that drops mid-stream (a Wi-Fi hiccup) gets retried in the
  background instead of sitting dead. The live walkthrough found exactly
  this failure mode with nothing recovering it (`gated-ux-walkthrough.md`
  P2-01/P2-03) — a paying customer will read a dropped, un-retried
  connection as "the app is broken," not "the network blipped."
- **Play a sound on connect/disconnect** — *(NEW)* a short, optional chime
  so a customer without the popover open still knows a speaker joined or
  dropped. A common, cheap convenience in this category of utility.

### Appearance
*(today: Theme)*

- **Theme (Match System / Light / Dark)** — *(EXISTS)*.
- **Popover density (Comfortable / Compact)** — *(NEW, but half-built
  already)* the underlying model for this — `InterfaceDensity` in
  `AppSettings.swift`, with `.comfortable`/`.compact` cases — already exists
  in code, but no control anywhere in the UI sets it today. Finishing it lets
  a customer with many speakers see more rows at once, while someone who
  prefers more breathing room keeps today's spacing. Closer to "wire up
  something already scoped" than "invent something new."

### Advanced
*(today: nothing — this is a new grouping)*

- **Copy Diagnostic Info** — *(NEW)* one button that copies a small text
  bundle — app version, macOS version, which backend is active, the recent
  connection log — to the clipboard, ready to paste into a support email.
  Turns "what version are you on, what exactly happened" into one click
  instead of a back-and-forth, which matters once real paying customers are
  emailing in with problems.
- **Restore Default Settings** — *(NEW)* resets every choice in the Settings
  window back to its default (buffer size, wake-restore delay, theme, etc.)
  without touching saved groups or devices. The standard safety net every
  System Settings-style pane offers, and it lowers the risk of shipping the
  more fiddly settings above — a customer who breaks something by
  experimenting can always get back to a known-good state without
  reinstalling.
- **Manual sync offset per speaker** — *(NEW, niche)* a small per-speaker
  timing nudge (a few milliseconds either way) for the rare case where two
  rooms sound subtly out of step over real Wi-Fi. Advanced and low-volume,
  but the kind of knob a serious multi-room customer eventually goes looking
  for.

## Priority tiers

**Obviously worth building before launch:**

- **About & Support** (version + a way to reach you) — directly named as
  flat-out missing by two independent audits, essentially free to build, and
  the first thing any paying customer looks for when something goes wrong.
- **Check for updates** — table stakes for a paid app sold outside the App
  Store; should land in lockstep with the auto-update infrastructure already
  being scoped elsewhere (`commercial-wrapper.md`).
- **Resume previous speakers on launch** — closes a real behavioral gap
  ("nothing reconnects after a restart" today) that undercuts the core "it
  just works" promise of a paid routing app.
- **Automatically reconnect a dropped speaker** — the live walkthrough
  showed this failing today with zero recovery; it reads as a broken app,
  not a network blip, which is exactly the kind of thing that generates
  refund requests and bad reviews.
- **Global keyboard shortcut** — cheap, high perceived value, and the
  expected baseline for this whole category of Mac utility.
- **Restore Default Settings** — cheap safety net that makes every other new
  setting above lower-risk to ship, since a confused customer always has a
  way back to a known-good state.

**Nice to have later:**

- **Menu bar icon status indicator** — a pleasant touch, not a gap anyone's
  complained about yet.
- **Maximum volume per speaker** — genuinely useful, but secondary to
  getting default connect volume (already its own task) right first.
- **Play a sound on connect/disconnect** — a small convenience, easy to add
  once the core reliability items above are solid.
- **Popover density** — worth finishing since the model already exists, but
  no one has asked for it yet; low urgency.
- **Copy Diagnostic Info** — valuable once there's real support volume to
  justify it; not needed for a first release with a small customer base.
- **Manual sync offset per speaker** — advanced/niche, safe to defer well
  past launch.
