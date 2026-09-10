# App Store submission kit: Audiout Remote (companion iOS app)

**Audiout Remote** (bundle id `com.audiout.remote`, target name
`AudioutRemote`) is the shipping name, settled by decision D4 (see §7).
This kit describes the app as it stands on the phone repo's `integration`
branch as of 2026-09-06.

## 1. Review notes (paste into App Store Connect › App Review Information › Notes)

```
Audiout Remote is a free companion app for Audiout, a paid Mac app (€30,
one-time) that sends system audio to AirPlay 2, Bluetooth, and Chromecast
speakers. There is no account and no sign-in. For every control action the
phone talks directly to the Mac app over the local Wi-Fi network, using
Bonjour discovery (service type _audiout._tcp) and a local WebSocket
connection with no server behind it.

Separately, the app sends anonymous product-interaction analytics (which
screens and features get used, never linked to your identity) and, only if
you agree to iOS's own "Share With App Developers" prompt, crash reports to
Apple. Both are covered under Section 4 below, and Settings has one switch,
"Share usage data," that turns the analytics off.

What the reviewer sees WITHOUT a Mac running Audiout on the network: a
three-card intro (Skip is offered on the first two cards; the third card's
button reads "Find my Mac"), then a search screen reading "Looking for your
Mac…". After about 8 seconds with no Mac found, a numbered checklist unfolds
(same Wi-Fi network; Audiout running on the Mac; "Allow control from iPhone"
turned on in the Mac's own Settings) and a "Try the demo" row appears under
it. Tapping it opens a fully interactive session against a pretend Mac
("Demo Mac") and its own pretend fleet: a HomePod, a stereo pair already
saved as a scene, a Bluetooth speaker wired up to demonstrate the sync
(iPhone-measures-the-room) feature, and a speaker shown offline to
demonstrate the failure state, across all four tabs (Speakers, Apps,
Scenes, Settings). Every control works: speaker selection, volume, mute,
per-app routing, scene creation, and the Bluetooth speaker's sync
measurement. No audio plays anywhere in the demo. It is silent by design,
and every screen labels it "Demo." Settings' "Leave demo" button returns to
the search screen.

What the reviewer sees WITH a Mac on the same Wi-Fi network running Audiout:
the Mac is discovered automatically and listed by name; tapping it (or
auto-connect, if it's the only Mac seen and the one last used) opens a live
two-way session. Speaker selection, per-app routing, scenes, and volume all
mirror the Mac app's own popover in both directions. If that Mac's Audiout
is not linked to a licence, the three control tabs show one neutral screen
instead ("This Mac isn't linked to an Audiout licence") with no price and no
purchase link. Audiout Remote has no purchase flow of its own (Guideline
3.1.3(f)).

Demo video (attach before submitting): <VIDEO LINK PLACEHOLDER>. Shows
discovery, connect, control, and reconnect end to end with both devices on
screen.

Local Network permission: iOS's system prompt appears once the reader
leaves the three-card intro (by tapping "Find my Mac," or Skip) and the app
starts looking for a Mac. Declining it does not block the app; the demo
above remains fully usable, and the app's own guidance screen explains how
to turn it on later in Settings.
```

## 2. Demo-video shot list

One take, under 60 seconds, both iPhone and Mac visible in frame (side-by-side rig,
or phone screen-recording plus Mac screen-recording edited side by side, either is
acceptable, no cuts needed within each device's recording).

1. Launch Audiout Remote (cold launch, not resumed).
2. Tap through the three-card intro (or Skip) to "Find my Mac."
3. Local Network permission prompt appears, tap Allow.
4. Discovery finds the Mac by name within a few seconds.
5. Tap the Mac to connect.
6. Toggle a speaker on/off in the Speakers tab.
7. Drag the Main Audio volume slider, cut to the Mac popover, visibly following in
   real time.
8. Create a scene (2+ speakers, name it, save) in the Scenes tab.
9. Kill the app on the phone (swipe up from app switcher), relaunch: it reconnects to
   the same Mac automatically, state resynced.

Recording tips: record each device natively (QuickTime screen recording via cable for
the Mac, iOS screen recording for the phone) and edit into one side-by-side clip
rather than trying to frame both screens in one physical shot, sharper and easier to
review. No voiceover needed; the notes carry the explanation.

## 3. Screenshot checklist (iPhone-only)

Sizes: 6.9" and 6.5" display classes are the current baseline as of this writing.
**Verify the exact required size list in App Store Connect at submission time**;
Apple revises these periodically.

One screenshot per tab, all driven by the demo (consistent, reviewable content, no
dependency on a live Mac being on screen):

1. Speakers tab: demo fleet with 2+ speakers selected, Main Audio slider mid-range.
2. Apps tab: at least one app redirected to a speaker.
3. Scenes tab: the pre-seeded "Living Room" scene shown.
4. Settings tab: connected state, showing "Demo Mac" and the "Leave demo" button.

## 4. App Privacy answers (App Store Connect › App Privacy questionnaire)

**Usage Data → Product Interaction: collected.** Anonymous counts of which
screens and features get used (`AudioutRemote/Model/Analytics.swift`), sent to
PostHog. Not linked to your identity (there is no account to link it to, and
the SDK's own anonymous id is joined to nothing else), and not used to track
you across other companies' apps or websites. Settings has one switch, "Share
usage data" (on by default per D12, `docs/plans/PLAN-REMOTE-RELEASE.md`), and
turning it off stops the next event: `Analytics.capture(_:)` checks consent
before every call.

**Every other category**, Contact Info, Health & Fitness, Financial Info,
Location, Sensitive Info, Contacts, User Content, Browsing History,
Identifiers, Purchases, Diagnostics, Other Data: **not collected.** Crash
data, if the user ever shares any, reaches Apple only through iOS's own
"Share With App Developers" setting; the app has no code path that sends or
reads a crash report, so that is Apple's opt-in, not this app's collection.

`AudioutRemote/PrivacyInfo.xcprivacy` is the source of truth this answer has
to match: `NSPrivacyTracking` false, one `NSPrivacyCollectedDataType` entry
(Product Interaction, `Linked` false, `Tracking` false, purpose Analytics),
and two required-reason API declarations the app or the PostHog SDK it links
touches: User Defaults (reason `CA92.1`) and System Boot Time (reason
`35F9.1`). Resulting nutrition label: **Data Not Linked to You: Usage Data.**
No category qualifies as Data Linked to You or Data Used to Track You.

## 5. Export compliance

The app uses only Apple's standard networking APIs (`Network.framework` WebSocket/TCP,
and standard HTTPS for the PostHog analytics calls in §4) with no custom or
proprietary encryption implemented by the app. Answer the standard ASC export
compliance question **"Does your app use encryption?"** as needed by the current ASC
wording, but qualify with: uses only standard OS-provided encryption/exempt, no custom
cryptography. This qualifies for the **exempt** path, no annual self-classification
report required.

## 6. Age rating

**4+**. No objectionable content categories apply (no violence, mature themes, gambling,
UGC, or unrestricted web access); answer every questionnaire item "None."

## 7. Naming (settled: D4)

**Audiout Remote**, subtitle **"The remote that tunes your speakers."**
(`docs/plans/PLAN-REMOTE-RELEASE.md`, decision D4, 2026-09-05). This already
matches the shipping Xcode target name and bundle id (`com.audiout.remote`);
the name used throughout this doc is the real one, and no rename is
pending before this kit can be submitted.

## 8. ASC execution notes

Superseded by `docs/plans/PLAN-REMOTE-RELEASE.md` (T19 through T24) and `docs/RELEASE.md`; see those for how this kit reaches Apple from here.

## 9. Guideline 2.1 (App Completeness) checklist

Per `dev/notes/companion-app-research.md` §7: Guideline 2.1 is the specific
review risk for a phone app whose host hardware/software (a Mac running
Audiout) the reviewer won't have, cited there as the majority failure mode
for stuck reviews. Mitigations, mapped to the shipping app:

- [x] Review notes explain the no-Mac-found and demo experience explicitly
      (§1 above; per research doc §7.1).
- [ ] Demo video attached and linked in review notes ("the single most
      effective artifact" per the research doc, §7.2 there; §2 above).
- [x] The demo is reachable, clearly labeled, fully interactive, and never a
      silent fallback (per research doc §7.3 and the Mac app's own
      `MockBackend`/`AIRPLAY_MOCK_SCENARIO` precedent).
- [x] A "Looking for your Mac…" state with a help checklist is present
      without any host on the network (per research doc §7.4: "effectively
      a review requirement, and good product anyway").
- [ ] Expect one review round-trip is possible regardless (research doc §7
      notes this as normal precedent, e.g. a comparable Pi-hole companion
      resolved via notes + video); do not treat a first rejection as a
      process failure.

Ready for T22's TestFlight pass and T24's submission once the demo video
(§2) is recorded and attached.
