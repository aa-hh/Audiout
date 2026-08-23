# App Store submission kit — Audiout Remote (companion iOS app)

Working name: **Audiout Remote** (bundle id `com.audiout.remote`, target name
`AudioutRemote`). This whole doc is written under that working name — see §7 for the
rename gate (T23) before it can actually ship.

## 1. Review notes (paste into App Store Connect › App Review Information › Notes)

```
Audiout Remote is a free companion controller for Audiout, a free Mac app that
sends system audio to AirPlay 2 speakers. There is no account, no sign-in, and no
backend server — the phone talks directly to the Mac app over the local Wi-Fi network
via Bonjour discovery (service type _audiout._tcp) and a local WebSocket connection.
No data is collected, stored, or transmitted off the local network.

What the reviewer sees WITHOUT a Mac running Audiout on the network: the app opens
to a 4-tab layout (Speakers / Apps / Groups / Connection). The Connection tab shows a
"No Mac found" empty state with a short explanation, plus a clearly labeled "Demo
system" row. Tapping it connects the app to a built-in, fully interactive simulated
Mac (a HomePod + a Sonos-style pair) with no network activity at all — every control
in the app (speaker selection, volume, mute, per-app routing, group creation) is live
and functional against this demo fleet. This is not a stub screen; it is the same UI
the app uses against a real Mac.

What the reviewer sees WITH a Mac on the same Wi-Fi network running Audiout: the Mac
is discovered automatically and listed by name; tapping it (or auto-connect, if it's
the only Mac seen and the one last used) opens a live two-way session — speaker
selection, per-app routing, groups, and volume all mirror the Mac app's own popover in
both directions.

Demo video (attach before submitting): <VIDEO LINK PLACEHOLDER> — shows discovery,
connect, control, and reconnect end to end with both devices on screen.

Local Network permission: the app requests it on first launch to browse Bonjour and
open a local socket to the Mac. Declining it does not block the app — the Demo system
above remains fully usable.
```

## 2. Demo-video shot list

One take, under 60 seconds, both iPhone and Mac visible in frame (side-by-side rig,
or phone screen-recording + Mac screen-recording edited side by side — either is
acceptable, no cuts needed within each device's recording).

1. Launch Audiout Remote (cold launch, not resumed).
2. Local Network permission prompt appears — tap Allow.
3. Discovery finds the Mac by name within a few seconds.
4. Tap the Mac to connect.
5. Toggle a speaker on/off in the Speakers tab.
6. Drag the Main Out volume slider — cut to the Mac popover, visibly following in
   real time.
7. Create a group (2+ speakers, name it, save).
8. Kill the app on the phone (swipe up from app switcher), relaunch — reconnects to
   the same Mac automatically, state resynced.

Recording tips: record each device natively (QuickTime screen recording via cable for
the Mac, iOS screen recording for the phone) and edit into one side-by-side clip
rather than trying to frame both screens in one physical shot — sharper and easier to
review. No voiceover needed; the notes carry the explanation.

## 3. Screenshot checklist (iPhone-only)

Sizes: 6.9" and 6.5" display classes are the current baseline as of this writing —
**verify the exact required size list in App Store Connect at submission time**,
Apple revises these periodically.

One screenshot per tab, all driven by the **Demo system** (consistent, reviewable
content, no dependency on a live Mac being on screen):

1. Speakers tab — Demo fleet with 2+ speakers selected, Main Out slider mid-range.
2. Apps tab — at least one app redirected to a speaker.
3. Groups tab — one saved group shown.
4. Connection tab — connected state (or the empty/connect state showing the labeled
   Demo system entry — pick whichever reads better; either is legitimate to include
   since both are real, reachable app states).

## 4. App Privacy answers (App Store Connect › App Privacy questionnaire)

Answer **"No, we do not collect data from this app"** across every category Apple
lists (Contact Info, Health & Fitness, Financial Info, Location, Sensitive Info,
Contacts, User Content, Browsing History, Identifiers, Purchases, Usage Data,
Diagnostics, Other Data). Rationale for the nutrition label: the app has no backend —
all traffic is a direct LAN WebSocket to a Mac the user already owns and runs; nothing
is transmitted to Audiout's developer or any third party. Resulting privacy
"nutrition label": **Data Not Collected**.

## 5. Export compliance

The app uses only Apple's standard networking APIs (`Network.framework` WebSocket/TCP)
with no custom or proprietary encryption implemented by the app. Answer the standard
ASC export compliance question **"Does your app use encryption?"** as needed by the
current ASC wording, but qualify with: uses only standard OS-provided
encryption/exempt, no custom cryptography — this qualifies for the **exempt** path, no
annual self-classification report required.

## 6. Age rating

**4+**. No objectionable content categories apply (no violence, mature themes, gambling,
UGC, or unrestricted web access) — answer every questionnaire item "None."

## 7. Naming — placeholder, not decided

"Audiout Remote" (used throughout this doc, and as the current Xcode target name /
bundle id `com.audiout.remote`) is a **working name only**. The real App Store name,
subtitle, and bundle id are Alec's call and are executed by **T23 (pre-ASC rename)**
before this kit can be submitted — folder, scheme, display name, and bundle id all move
together in that one task.

App Store name/subtitle — TODO, options for Alec to pick from:
- **"Audiout Remote"** — leading candidate; matches the Mac app name directly, clear
  it's a companion, no invented branding.
- "Audiout Controller" — more literal about function, slightly more generic.
- "Audiout for iPhone" — platform-first framing, less idiomatic for a subtitle-bearing
  listing.

Subtitle suggestion (if "Audiout Remote" is chosen): "Control your Mac's AirPlay
speakers."

## 8. ASC execution notes (for later — delegated to the `lance` operator)

Do not attempt ASC upload from this worktree. The `lance` App Store Connect operator
builds and signs on its own Mac from source it can reach — it needs a **pushed
branch/commit** (git URL + branch or SHA), not a local working tree. When ready:

1. Merge the phone-app release branch (post T20 live test, post T22 checkbox-default
   flip, post T23 rename) to `main` on Alec's go-ahead, then push.
2. Hand `lance` the pushed commit plus this document's contents (review notes, privacy
   answers, export-compliance answer, age rating, screenshot list, demo video link) to
   populate the ASC listing and screenshots.
3. **TestFlight first** — internal/external beta, confirm the live-Mac and demo-mode
   paths both work from a real build. Only submit for App Store review after a
   TestFlight pass.

## 9. Guideline 2.1 (App Completeness) checklist

Per `dev/notes/companion-app-research.md` §7: Guideline 2.1 is the specific review
risk for a phone app whose host hardware/software (a Mac running Audiout) the
reviewer won't have — cited there as the majority failure mode for stuck reviews.
Mitigations, mapped:

- [ ] Review notes explain the no-Mac-found and demo-mode experience explicitly (§1
      above; per research doc §7.1).
- [ ] Demo video attached and linked in review notes — "the single most effective
      artifact" per the research doc (§7.2 there; §2 above).
- [ ] Demo system is reachable, clearly labeled, fully interactive, and never a silent
      fallback (built as T13; per research doc §7.3 and the Mac app's own
      `MockBackend`/`AIRPLAY_MOCK_SCENARIO` precedent).
- [ ] "No Mac found" empty state with help text is present without any host on the
      network (built as part of T17a; per research doc §7.4 — "effectively a review
      requirement, and good product anyway").
- [ ] Expect one review round-trip is possible regardless (research doc §7 notes this
      as normal precedent, e.g. a comparable Pi-hole companion resolved via notes +
      video) — do not treat a first rejection as a process failure.

**Landed-code note (2026-07-26, as of this worktree):** items 3 and 4 above (Demo
system / T13, empty state polish / T17a) are planned but **not yet built** — this
worktree has only the 4-tab skeleton (T10, placeholder views) and the networking/
discovery layer (T11). This doc describes the target end state per
`docs/plans/PLAN-COMPANION-APP.md`; do not submit until T13–T17b land and T20's live
test passes.
