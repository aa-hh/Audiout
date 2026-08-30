# Companion App — Full Live-Test Checklist (Mac + real iPhone, real Wi-Fi)

*T20. Run this only after the Mac-only gate (`dev/notes/companion-mac-live-gate.md`)
has already passed with a real iPhone instead of websocat. That doc owns
build/binary-identity/firewall/websocat/approval-via-websocat on the Mac alone — it is
not repeated here. This doc owns everything that needs a second physical device: real
Local Network permission prompts, real discovery, real two-way sync, and the
review-fix items that only show themselves with an actual phone in your hand.*

*Every mechanism appears exactly once, in the order you'll naturally hit it. Each item
states the expected result so a deviation is unmistakable.*

---

## 1. Getting the app onto the phone

No TestFlight build exists yet — Xcode direct-install is the only path today.

- [ ] **Cable the iPhone to the Mac** (or use wireless debugging if already paired),
  open `AudioutRemote.xcodeproj` in Xcode from a checkout of `aa-hh/audiout-remote`
  (private repo), select the iPhone as the run destination.
- [ ] **Set a signing team** in Signing & Capabilities. A free Apple ID works — it
  issues a 7-day provisioning profile, so re-install weekly during this test round.
  Expected: no paid Developer Program membership required for this phase.
- [ ] **Confirm the bundle id**: `com.audiout.remote`. Expected: this is still the
  working-name identifier — T23 (pre-App-Store rename) has not run yet, so don't be
  surprised it doesn't say the final product name.
- [ ] **Build & run to the device.** Expected: app installs and launches; you may need
  to trust the developer certificate once under iPhone Settings › General › VPN &
  Device Management.

---

## 2. First launch

- [ ] **Local Network permission prompt appears.** Expected wording: *"Audiout uses
  the local network to find and control the Audiout app on your Mac."* It should
  fire the first time the app actually tries to browse (on launch, or when you open
  the Connection tab) — not before, and not as a generic first-run interstitial.
- [ ] **Tap Allow.** Expected: prompt dismisses, browsing begins immediately.
- [ ] **With no Mac reachable yet** (Mac app not running, or its companion checkbox
  off), the Connection tab shows **"Looking for a Mac…"** with a spinner, plus a
  checklist (same Wi-fi, keep Mac app open, enable the Settings › General checkbox).
  Expected: this is `EmptyStateView(isSearching: true)` — never a bare blank screen.
- [ ] **The labelled "Demo system" row is visible** alongside the empty state, in every
  connection state. Expected: it is clearly labeled "Demo system" with a distinct
  entry point — confirm you are NOT dropped into it automatically just because no Mac
  was found. Demo is opt-in only, never a fallback (house rule).

---

## 3. Approval flow (D2 REVISED — the newest feature, most likely to surprise)

- [ ] **On the Mac**, open Settings › General, enable "Allow control from iPhone on
  this network" (mock or native backend, either is fine for this step).
- [ ] **On the phone**, tap the Mac in the discovered list. Expected: phone shows
  **"Waiting for Approval…"** (yellow, spinner icon) — a real "check your Mac" holding
  state, not an error.
- [ ] **A native alert appears on the Mac** naming the phone (its device name, e.g.
  "Alec's iPhone"). Expected: this fires only once per unknown identity.
- [ ] **Tap Allow on the Mac.** Expected: phone transitions straight to live (Speakers
  tab populates) within about a second — no re-tap needed on the phone.
- [ ] **Check Settings › General on the Mac**: the phone now appears under
  **"Remembered iPhones"** with a name and "Allowed" label, and an ✕ to revoke.
- [ ] **Quit and relaunch the phone app**, reconnect to the same Mac. Expected: **no
  re-prompt** on the Mac — this identity is remembered, straight to live. (This is the
  persistence guarantee the whole feature exists for; if it re-prompts, the identity
  isn't being persisted and that's a regression.)
- [ ] **Revoke from the Mac** (✕ on the "Remembered iPhones" row) while the phone is
  connected. Expected: the phone drops immediately — Connection tab settles back to
  "Looking for a Mac…" / empty state, no crash, no infinite spinner.
- [ ] **Reconnect from the phone.** Expected: back to "Waiting for Approval…", a fresh
  alert appears on the Mac (revoking really did forget the identity, not just hide the
  row).
- [ ] **This time tap Don't Allow on the Mac.** Expected: phone settles on a
  non-error, non-retrying state with guidance (its own copy, distinct from the
  transient "waiting" state) and **does NOT keep redialing** — a denied phone must not
  nag the Mac's user repeatedly. Confirm no further alert pops on the Mac from that
  same phone without the user reconnecting by hand.
- [ ] **On the Mac**, the row now shows "Denied". **Revoke it** to reset for the rest
  of this checklist.

---

## 4. State parity (snapshot vs. popover)

With the phone connected live and the Mac popover open side by side, eyeball every
field:

- [ ] **Speakers list + selection** — same devices, same checked/unchecked state on
  both.
- [ ] **Main Out target** — phone's Main Out picker (Selected Speakers vs. a named
  group) matches the popover's Main Out control.
- [ ] **Master volume** — phone's master slider value equals the popover's Main Out
  slider.
- [ ] **Per-device volumes** — each device row's volume matches.
- [ ] **Mutes at all three levels** — a device mute, a group mute, and the Main Out
  mute each reflect correctly on both sides.
- [ ] **Groups** — any saved group appears identically (name, members, icon) in the
  phone's Groups tab and the Mac's Groups window.
- [ ] **Per-app routes** — an app routed to a speaker (or "This Mac", or "No redirect")
  matches on the phone's Apps tab.
- [ ] **Connect volume + buffer** — Settings tab's two values match Settings › Audio on
  the Mac.

---

## 5. Two-way live sync

- [ ] **Change a value on the phone** (toggle a speaker, drag master volume). Expected:
  Mac popover updates within roughly the coalescing window (~50 ms perceptible as
  "instant").
- [ ] **Change a value in the Mac popover.** Expected: phone updates live.
- [ ] **Change a value in the Mac's Groups window** (rename a group, edit membership).
  Expected: phone's Groups tab reflects it — this exercises a different Mac-side
  change-hook path than the popover, so don't skip it.
- [ ] **Connect a second client alongside the physical phone** — another real iOS
  device if one is to hand; otherwise a simulator, purely as a stand-in body on the
  network. Expected: both clients converge on the same state; an action from either
  shows up on the other and on the Mac. This is the multi-client guarantee, not just
  phone-Mac. The phone remains the device under test — the second client is here to
  prove convergence, never to stand in for the phone's own verdict.

---

## 6. Review-fix verifications (highest-value items — each names what it proves)

These are the fixes that came out of the four adversarial reviews and are only
verifiable with a real device; each bullet says what would be broken if it fails.

- [ ] **Phone-set audio buffer actually updates the phone's own picker.** On the
  phone's Settings tab, pick a different buffer size and tap "Apply & Reconnect".
  Expected: brief audible gap (~3-5 s) on all playing speakers, button shows
  "Applying…", then re-enables once the Mac's new value round-trips back — the
  picker must show the NEW value, not silently keep showing the old one with a stale
  "applied" state. (This was a real bug: two independent reviewers found "applied"
  reported with the buffer picker still showing the old number.)
- [ ] **Volume/mute on a not-yet-connected speaker gets an honest refusal.** Add a
  speaker that hasn't finished connecting (or pick one mid-retry) and try to drag its
  volume or tap mute from the phone. Expected: a toast reading something like
  *"<name> isn't connected yet, so it can't take volume changes"* — not a silent
  no-op that pretends to have worked.
- [ ] **Slider drags feel smooth, not fought.** Drag a device volume slider or the
  master slider slowly on the phone while it's live. Expected: the thumb tracks your
  finger continuously; it must not jump or stutter back toward a stale server value
  mid-drag (local echo during the drag, real value only reconciled on release).
- [ ] **Unticking the Mac's companion checkbox settles the phone quietly.** With the
  phone connected, go to the Mac's Settings › General and untick "Allow control from
  iPhone on this network". Expected: the phone transitions to a calm waiting state
  (not an error banner, not a retry storm) and reconnects on its own once you retick
  the checkbox — no need to force-quit or relaunch the phone app.
- [ ] **Rate limiting never trips during normal use.** Do ordinary things quickly on
  the phone — drag several sliders back to back, toggle a few speakers, flip through
  tabs. Expected: no refusal toasts or stalls from rate limiting. (Budget is ~20
  commands/sec sustained with headroom to burst to 40; normal finger-driven use stays
  well under this — only a scripted flood should ever hit it.)

---

## 7. Lifecycle

- [ ] **Background the phone app** (swipe to home) while connected, then return.
  Expected: resyncs invisibly — no visible reconnect flicker, state is current when
  you look. *Known limitation, not a bug:* control from the phone stops entirely while
  backgrounded (no background mode) — that's by design, don't file it.
- [ ] **Lock and unlock the phone.** Expected: same invisible resync as backgrounding.
- [ ] **Toggle Wi-Fi off then on** on the phone while connected. Expected: phone shows
  a "not on Wi-Fi" state while off (cellular is deliberately prohibited for this
  connection), then reconnects automatically once Wi-Fi returns.
- [ ] **Walk out of Wi-Fi range and back** (or far enough that the AP roams/drops).
  Expected: same graceful drop-and-recover as the Wi-Fi toggle, within the app's
  reconnect backoff — no manual relaunch needed.
- [ ] **Put the Mac to sleep, then wake it.** Expected: phone drops the connection
  while the Mac sleeps and reconnects automatically once the Mac wakes and the
  companion server is listening again.
- [ ] **Quit and relaunch the Mac app.** Expected: phone treats it like the Mac
  temporarily disappearing — settles, then reconnects once the Mac app is back up with
  the companion checkbox still on.

---

## 8. Permission-denied path

Use a **fresh install** for this section — a re-grant on an already-decided app can be
flaky in ways that don't reflect a real first-run (see caveat below).

- [ ] **Fresh-install the phone app, deny the Local Network prompt** when it appears.
  Expected: Connection tab shows the honest denial-suspected copy — wording that
  explicitly hedges ("This app may not be allowed to find devices… if you haven't
  answered the prompt yet, this clears itself as soon as you do — otherwise, allow it
  in Settings"), plus an "Open Settings" button that deep-links to the app's page in
  the Settings app.
- [ ] **Follow the deep link, turn Local Network access ON**, return to the app.
  Expected: discovery recovers and the Mac appears.
- [ ] **Known iOS 18-era caveat:** a deny-then-grant cycle can occasionally need a
  **device reboot** before iOS actually honors the new grant — this is a platform
  quirk (no status API exists; the app can only guess from a `.waiting`/`dns(-65570)`
  timeout), not an app bug. If recovery doesn't happen immediately after granting,
  reboot the phone once before concluding something is broken. Only test this on
  fresh installs — a phone that's already answered the prompt once behaves
  differently.

---

## 9. Demo mode

- [ ] **Tap the "Demo system" row** from the Connection tab. Expected: enters a
  simulated fleet (Mac + HomePod + a Sonos pair) with a visible **"Demo"** badge/
  indicator somewhere persistent while active (not just at entry).
- [ ] **Interact with it** — toggle a speaker, adjust volume, create a group.
  Expected: behaves like a real Mac would (proportional master volume, mute stash,
  group CRUD) entirely in-memory; no real Mac is touched.
- [ ] **Exit Demo.** Expected: returns to the real Connection tab / empty state /
  live session, cleanly, with the Demo badge gone.
- [ ] **Confirm Demo was never entered automatically** at any point in sections 1-8 —
  it's reachable only from its own labeled row, never a fallback when a real Mac
  isn't found.

---

## 10. Wrap-up

- [ ] **Report to the session** before anything merges:
  - Which sections passed clean vs. which showed a deviation (quote the exact wording/
    behavior you saw).
  - Xcode signing team used, and whether the 7-day provisioning expired mid-test.
  - Any approval-flow surprise (section 3) — this is the newest, least-live-tested
    code path.
  - Result of each review-fix verification in section 6, by name.
  - Whether the iOS 18 reboot caveat (section 8) was needed.
- [ ] **Remember: `main` is merge-only.** Nothing from this branch merges to `main`
  without Alec's explicit go-ahead, even if every box above is checked clean.
