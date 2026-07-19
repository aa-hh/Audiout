# Per-app routing live-verification runbook — T11

A copy-paste checklist for ahh to verify per-app AirPlay routing works end-to-end
against real hardware and real apps. Unit tests (476+ core / 108 engine, 0 failures)
prove the logic; this runbook proves the audio actually moves to the right speaker
and the UI correctly shows what's happening.

Companion docs: `first-light-report.md` (the engine's gated live-test, six bugs found
and fixed), `dev/notes/p2b-nativebackend-runbook.md` (Phase 2b native backend setup
and the D7 gated-session checklist), `SPEC.md` (the product spec, sections on per-app
routing), and `PLAN-POPOVER-ROUTING.md` (the design decisions behind the Applications
card and tri-state picker).

---

## Setup preconditions

- [ ] Real AirPlay 2 receivers on the LAN (at least two for the multi-device tests
      below; Sonos speakers confirmed; AirPlay-capable Mac speakers work).
- [ ] The app built, signed, and launched per `dev/notes/p2b-nativebackend-runbook.md`
      §3 (stable `.app` bundle, TCC system-audio-recording permission granted).
- [ ] `AIRPLAY_BACKEND=native` active (environment variable or hardcoded for this
      manual test run).
- [ ] OwnTone (and any other process holding UDP 319/320) **stopped** — the native
      PTP clock needs those ports exclusively.
- [ ] Firewall allowlisted the app binary **before** it bound any socket (see
      `first-light-report.md`'s "Operational gotchas").
- [ ] At least one audio source ready to play: music app (Music, Spotify, etc.),
      video/call app (browser, FaceTime), or a second tone-generation utility if
      available.

---

## Scenario 1: Basic per-app isolation (audio stays local while one app routes)

**Procedure:**

1. Launch the app and confirm the popover shows at least one AirPlay speaker.
2. Start audio playback on the Mac with a non-routed app (e.g. Music, browser video):
   the Mac's speakers should emit the audio, and no AirPlay speaker plays anything.
3. Open the popover's "Applications" card (collapsed by default if no apps are routed
   yet; click the row or use keyboard nav to expand).
4. Click the ➕ button and add the audio-playing app (e.g. "Music") to the routing
   table.
5. Click on the app's row and select a different speaker from the destination picker
   (e.g. speaker #1). The picker shows three options: "No Redirect" (first, default),
   "Current Device" (explicit "play locally"), and device names (the available AP2
   receivers).
6. **Listen**: the Mac's speakers should **stop** playing that app's audio
   (audio was muted from the Mac), and speaker #1 should **now play** only that app's
   stream (not the whole system, not other apps — just the routed app's audio).
7. **Verify the Mac is NOT muted**: try playing audio through a different non-routed
   app (browser, another music source, or macOS's built-in alert sounds). That audio
   should still emit from the Mac's local speakers — the system is not muted, only
   the routed app was redirected.

**Pass criteria:** the routed app's audio moved to the remote speaker, the Mac plays
non-routed audio normally (not muted), and the popover correctly shows the app routed
to speaker #1.

**Failure indicators:** the Mac is muted after routing (original bug — audio-signal
mute was incorrectly applied); the speaker plays audio from other apps or the whole
system mix (per-app isolation not working); audio drops or cuts out mid-redirect.

---

## Scenario 2: Two apps, two speakers, simultaneous dual-stream

**Procedure:**

1. Ensure at least two distinct AirPlay speakers are visible in the popover and on the
   network.
2. Start audio on two different apps that can play simultaneously (e.g. Spotify on
   one speaker route, a browser playing video on a second speaker route; or Music
   playing from one routed app + a YouTube tab in another routed app).
3. Add both apps to the Applications card.
4. Route app #1 to speaker #1 and app #2 to speaker #2 (using the destination
   picker for each row).
5. Confirm audio playback on both apps starts/continues.
6. **Listen carefully:** speaker #1 should play **only** app #1's audio (not app #2's),
   and speaker #2 should play **only** app #2's audio. Walk between them and confirm
   audible isolation — no cross-talk.

**Pass criteria:** two speakers play two different audio streams in sync, each app's
audio reaches exactly its routed target with no drift or audible phase issues after
one minute of playback.

**Failure indicators:** both speakers play the same audio; one speaker plays a mix of
both apps; audio is out of sync between speakers (one lags the other noticeably);
engine errors in logs or a crash.

---

## Scenario 3: Overlap — same speaker, two apps, mixed audio

**Procedure:**

1. Route two different apps to the **same** speaker (e.g. Music + Spotify both routed
   to speaker #1).
2. Start playback on both apps (each will emit distinct audio — different songs,
   different volumes, etc.).
3. **Listen to speaker #1:** confirm both audio streams are audibly mixed together
   (you hear both songs at once, not one silently muted or dropped).
4. Adjust the volume slider for one app in the Applications card (click the row and
   drag the volume slider) and listen for the mix balance change on the speaker.

**Pass criteria:** both apps' audio is heard simultaneously at the speaker, and per-app
volume sliders actually affect the mix balance in real time.

**Failure indicators:** one app's audio is muted/silent (per-app volume to 0 is expected,
but explicitly muting via the app itself or UI should not drop the stream); the speaker
plays only one app's audio and the other is silently dropped; volume slider changes don't
affect the mix.

---

## Scenario 4: Tri-state picker — "No Redirect" vs. "Current Device"

**Procedure:**

1. Add an app to the Applications card (defaults to "No Redirect").
2. Click the app's row. The destination picker should show exactly three options:
   - "No Redirect" (first, the default for a newly-added app)
   - "Current Device" (explicit, labeled "Play on this Mac")
   - Device names (each AirPlay receiver on the network)
3. Click on the app's row and observe: initially, the radio button / checkmark /
   indicator points to "No Redirect" (the default, unset state).
4. Select "Current Device" from the picker. The row should update to reflect this
   choice.
5. Start audio playback on the app. The app should play on the Mac's local speakers
   (NOT captured for remote streaming).
6. Switch back to "No Redirect". The app should still play locally (no audible change
   in output).

**Pass criteria:** both "No Redirect" and "Current Device" result in the app playing
locally on the Mac. The three options are visually distinct in the picker and respond
immediately to selection. The UI clearly marks the current choice.

**Failure indicators:** selecting "Current Device" captures the app for remote streaming
(it should not — it's the explicit "play locally" choice); "No Redirect" and
"Current Device" behave differently in audio output (they should be engine-equivalent);
the picker is missing an option or shows the app as routed when both options should
mean "local."

---

## Scenario 5: Live status indicator — device row shows active routed apps

**Procedure:**

1. With one or more apps routed to speakers, look at the device row for each speaker
   in the popover or window mixer view.
2. For a speaker that has routed apps, the device row should display a **sublabel**
   (below the speaker name) showing which apps are streaming to it (e.g. "System ·
   Spotify · Music" if the system is selected AND Spotify and Music are routed to it;
   or just "Spotify · Music" if only those apps are routed).
3. Change a route (e.g. move Spotify from speaker #1 to speaker #2). Watch the
   sublabels update in real time — Spotify should disappear from speaker #1's row and
   appear in speaker #2's row.
4. Stop playback on one of the routed apps and restart it. Confirm the sublabel and
   device row remain accurate (shows which apps are **routed**, not necessarily which
   are currently playing audio).

**Pass criteria:** device rows show an accurate, real-time sublabel listing which apps
are routed to each speaker, including the "System" token if the whole-system output
is also selected for that speaker. Sublabels update immediately when routes change.

**Failure indicators:** sublabel is missing or blank on a device with routed apps;
sublabel shows stale/outdated app names after a route change; the label doesn't update
when a route is removed.

---

## Scenario 6: Live re-routing gap — drag an app from speaker A to speaker B while playing

**Procedure:**

1. Start audio playback on an app routed to speaker #1.
2. While audio is streaming, open the Applications card and change the destination
   from speaker #1 to speaker #2 (click the row, select a different speaker).
3. **Expected behavior:** there will be a brief (~1 second) silence or audio gap on
   both speakers as the stream disconnects from speaker #1 and reconnects to speaker
   #2. This is **EXPECTED and ACCEPTED** — it's a known engineering tradeoff (clean
   per-device state machine) that was explicitly approved. Do NOT report this gap as
   a bug.
4. After the reconnect gap, audio should resume on speaker #2, and speaker #1 should
   be silent.

**Pass criteria:** a ~1 second audio gap occurs during re-routing (this is expected);
audio resumes cleanly on the new speaker afterward; no crashes or stuck/looping audio.

**Failure indicators:** the gap is longer than ~2 seconds (possible capture/reconnect
issue); audio gets stuck looping on one speaker or both; audio doesn't resume on the
new speaker; a crash or engine error occurs.

---

## Scenario 7: App quits mid-stream

**Procedure:**

1. Start audio playback on an app that is routed to a speaker.
2. Confirm audio is audibly streaming to the speaker (e.g. music playing, video call
   active).
3. Force-quit the app (Cmd-Q, Activity Monitor, etc.).
4. **Listen to the speaker:** the audio stream should stop cleanly — no stuck/looping
   audio, no squealing, no corruption.
5. Relaunch the app. The route you set earlier should still be in the Applications
   card (persisted via `AppRouteStore`). The app should resume routing to the same
   speaker if you press play again.

**Pass criteria:** the speaker's stream stops cleanly when the app quits; the route
persists across app launches; relaunching the app and playing audio resumes routing
to the same stored destination.

**Failure indicators:** audio loops or gets stuck on the speaker after the app quits;
the route is lost (Applications card is empty or the destination resets); audio doesn't
route on relaunch even though the route is still listed.

---

## Scenario 8: Device disappears — speaker goes offline mid-route

**Procedure:**

1. Route an app to a speaker and start playback (audio streaming to that speaker).
2. While playback is active, make the speaker unavailable:
   - **Turn off the speaker** (power it down), or
   - **Disconnect it from the network** (unplug Ethernet, disable WiFi on the device)
3. **Listen to the speaker:** the audio stream stops (expected, it's now offline).
4. **Check the app's route in the Applications card:**
   - The route's destination should **reset to "No Redirect"** (the neutral/unset
     state), NOT "Current Device". A device disappearing isn't a deliberate choice to
     switch to "play locally" — it's a loss of connection, and the app reverts to
     unset.
   - The device's row in the main device list should transition to "Unavailable"
     (greyed out, no selection state).
5. **Listen to the Mac:** the app's audio should **resume on the Mac's local speakers**
   without user intervention. The fallback is automatic.
6. Turn the speaker back on or reconnect it. It should reappear in the device list
   (possibly after a brief discovery delay).

**Pass criteria:** the routed app's destination resets to "No Redirect" (persisted via
`AppRoutingController.handleDeviceUnavailable`); the device is marked unavailable in
the UI; the app's audio falls back to local playback automatically; no crash or hung
state.

**Failure indicators:** the destination resets to "Current Device" instead of "No
Redirect" (would misrepresent the automatic fallback as a deliberate choice); the app
stops playing audio entirely (should fall back to local, not silence); the device row
hangs or crashes when it disappears; the route is lost (should persist with a reset
destination, not vanish).

---

## Scenario 9: Sync check — two speakers, different apps, no drift over time

**Procedure:**

1. Route two apps to two different speakers (per Scenario 2 setup).
2. Start playback on both apps at roughly the same time. Both speakers should begin
   playing their respective audio streams in sync (within ~2.3 seconds, the AirPlay 2
   sync buffer — this is normal latency, not drift).
3. **Listen carefully for the first 60–90 seconds:** confirm the two speakers do NOT
   drift audibly out of phase with each other. If one is playing a song and the other
   is playing a different song, they should stay in sync (each at its own tempo, but
   time-aligned to within ~100 ms).
4. **If you have a way to measure timing** (e.g. a metronome or click track on both
   apps, or audio-level monitoring of the speaker outputs): confirm both streams stay
   synchronized over several minutes.

**Pass criteria:** no audible drift between the two speaker streams over at least one
minute of playback; if a metronome or reference click is available, the clicks stay
phase-aligned within ~100 ms.

**Failure indicators:** one speaker audibly lags the other by more than ~500 ms over
one minute (a sign of drift, not sync-buffer latency); audio sounds "rushed" or
"lagging" in an oscillating pattern (possible clock-skew or buffer underrun); speakers
stop playing together or require a manual resync.

---

## Scenario 10: Excluded apps — respecting the Settings ▸ Audio excludelist

**Procedure:**

1. Add an app to the exclusion list in Settings ▸ Audio ▸ Excluded Applications.
2. In the Applications card, try to add the same app via the ➕ picker. It should
   **not appear** in the available-apps list (or if it does, attempting to add it
   should fail silently or show an error).
3. If the app was already routed before being excluded, re-launching the app should
   **remove it from the Applications card** (the route is auto-pruned by
   `AppDelegate.pushAppRoutesToBackend` when an excluded app's route exists).

**Pass criteria:** excluded apps cannot be added to routing; previously-routed
excluded apps are removed from the card; the exclusion is respected at the capture
level (an excluded app is never captured, even if someone manually edits the
`app-routes.json` file).

**Failure indicators:** an excluded app can still be added to the routing table; an
excluded app's audio is captured and routed despite exclusion; excluded apps remain
in the card after being added to the excludelist.

---

## Pass / Fail summary

Each scenario above is a self-contained test. An overall **PASS** on this runbook
means:

- All 10 scenarios complete as described, with audio behaving as expected.
- No crashes, hangs, or error states.
- UI accurately reflects the routing state in real time.
- Routed apps' audio reaches exactly their assigned speakers, never the whole system.
- Local playback is never muted by routing (original bug fixed).

An overall **FAIL** means any scenario exhibits the failure indicators listed, or
raises a new issue not anticipated by this checklist.

---

## After the session

Update `first-light-report.md`'s "What's next" section or create a new dated addendum
(follow the same forensic style) with:

- **Pass/fail per scenario** (1–10 above)
- **Any new bugs found** (with reproduction steps and suspected cause)
- **Outstanding tasks** (e.g. if T9 live-status wasn't yet landed, note the
  workaround or skip)

If all scenarios pass, per-app routing is ready for shipping on this branch.
If any fail or raise a new issue, file a task with the reproduction steps and this
runbook's scenario number as a reference.
