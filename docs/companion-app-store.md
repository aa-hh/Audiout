# App Store submission kit: Audiout Remote (companion iOS app)

**Audiout Remote** (bundle id `com.audiout.remote`, target name
`AudioutRemote`) is the shipping name, settled by decision D4 (see §7).
This kit describes the app as it stands on `origin/main` of
`aa-hh/audiout-remote` (commit `5a813e1`) as of 2026-09-20, which includes
the in-app purchase of the Mac licence.

The listing text itself, every field with its character count, is in
`dev/notes/app-store-listing-copy.md`.

## 0. Not submittable yet

The phone app sells the €30 Mac licence as a one-time in-app purchase
(`docs/adr/0001-sell-mac-licence-in-phone-app.md` in the phone repo, owner's
ruling 2026-09-20). Four things that purchase depends on are not finished.
Submitting before they are means a reviewer buys the licence and watches
nothing happen.

**Built and merged.**

- StoreKit 2 purchase and restore of the non-consumable
  `com.audiout.remote.maclicence`, the keychain that holds the key it buys,
  and the send to the Mac on every connection. Phone repo, commit `deff0ca`,
  on `origin/main`. `AudioutRemote.storekit` wires a local test product into
  the scheme.
- The wire message that carries the key, `CompanionCommand.activateLicenseKey`.
  `audiout-shared` released it in tag 0.11.0 and the Mac pins `from: "0.15.1"`,
  so the Mac already decodes it.

**Not done.**

1. **The Mac refuses the key.** `CompanionCommandDispatcher.swift:345` answers
   `activateLicenseKey` with `.refused("Unknown command: activateLicenseKey.")`,
   by a deliberate placeholder whose comment says the real handling comes with
   the licence-key work. Until that lands, a licence bought on the phone
   reaches the Mac and is turned away, and the lock screen waits forever for a
   confirmation that never comes. This is the one that makes the purchase a
   dead end.
2. **The licence server has no Apple route.** `POST /v1/apple/license` (trade
   the signed App Store transaction for an `AUDT-` key) and
   `POST /apple/notifications` (REFUND, REFUND_REVERSED, REVOKE from App Store
   Server Notifications v2) are written and tested on branch `claude/gl-apple`
   of `aa-hh/audiout-license-server`, commit `bebedb5`, 21 tests. Not merged,
   not deployed, and the four `APPLE_*` variables plus the `APPLE_PRIVATE_KEY`
   secret are not configured on either environment. The phone posts to that
   route today and gets a 404.
3. **The in-app purchase record does not exist in App Store Connect.** Product
   id `com.audiout.remote.maclicence`, non-consumable, priced to match
   audiout.app. It needs its own review submission alongside the app, and
   sandbox testing before that. Cannot be checked from the repo; the
   `.storekit` file's `_applicationInternalID` is empty, which is consistent
   with no App Store Connect app record linked yet.
4. **The privacy manifest does not declare the purchase.**
   `AudioutRemote/PrivacyInfo.xcprivacy` lists one collected type, Product
   Interaction. §4 below answers "Purchases: collected", so the manifest needs
   a `NSPrivacyCollectedDataTypePurchaseHistory` entry to match.

Two smaller items, not blockers but visible to a reviewer:

- The demo video (§2) is still unrecorded, and §9 names it the single most
  effective artifact for the Guideline 2.1 risk.
- `https://audiout.app/remote`, the marketing URL, renders its "coming soon"
  state. See the listing copy note.

## 1. Review notes (paste into App Store Connect › App Review Information › Notes)

```
Audiout Remote is a free companion app for Audiout, a paid Mac app (EUR 30,
one-time) that sends system audio to AirPlay 2, Bluetooth, and Chromecast
speakers. There is no account and no sign-in. For every control action the
phone talks directly to the Mac app over the local Wi-Fi network, using
Bonjour discovery (service type _audiout._tcp) and a local WebSocket
connection with no server behind it.

The app is free and sells one non-consumable in-app purchase,
com.audiout.remote.maclicence, which is the Audiout Mac licence at the same
price as on audiout.app. It is not a subscription and there is nothing else
to buy. What it unlocks is the Mac app, not this one: the purchase returns a
licence key, the phone keeps that key in the Keychain and hands it to
whichever Mac it connects to, and the Mac unlocks both itself and this phone.
A customer who already bought on the website buys nothing here; their Mac
already unlocks the phone. Buy and Restore purchase are both in Settings and
both work with no Mac on the network, so the purchase can be tested on its
own. The purchase surfaces show Apple's own price string and no other price.

Separately, the app sends anonymous product-interaction analytics (which
screens and features get used, never linked to your identity) and, only if
you agree to iOS's own "Share With App Developers" prompt, crash reports to
Apple. Both are covered under Section 4 below, and Settings has one switch,
"Share usage data," that turns the analytics off. The purchase itself sends
no analytics.

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
mirror the Mac app's own popover in both directions. If that Mac is not
linked to an Audiout licence, the three control tabs are replaced by one
screen headed "Unlock Audiout on this Mac": the Speakers tab visible behind a
veil, and the purchase above it. Buying there, or in Settings, sends the key
to that Mac and the tabs open.

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

If the licence purchase is working by the time this is recorded, add one shot
of the "Unlock Audiout on this Mac" screen before the connect, so the
reviewer sees what the in-app purchase is for without having to buy it.

## 3. Screenshots

Superseded by `dev/notes/app-store-screenshots-discovery-2026-09-20.md`: six
slides at 1320×2868, dark, rendered from real captures by
`scripts/store-shots/` in the phone repo, with Apple's size rules, the
category survey and the decisions of 2026-09-20 in §7 and §8 there. The
captions are in `dev/notes/app-store-listing-copy.md`.

One rule belongs here rather than there, because it comes from the purchase:
Guideline 2.3.7 bars prices inside screenshots, and both purchase surfaces
render Apple's price string in their Buy button. Capture Settings with a key
already on file, where the row reads "Mac licence / Bought", and keep the
lock screen out of the set.

## 4. App Privacy answers (App Store Connect › App Privacy questionnaire)

**Usage Data → Product Interaction: collected.** Anonymous counts of which
screens and features get used (`AudioutRemote/Model/Analytics.swift`), sent to
PostHog. Not linked to your identity (there is no account to link it to, and
the SDK's own anonymous id is joined to nothing else), and not used to track
you across other companies' apps or websites. Settings has one switch, "Share
usage data" (on by default per D12, `docs/plans/PLAN-REMOTE-RELEASE.md`), and
turning it off stops the next event: `Analytics.capture(_:)` checks consent
before every call.

**Purchases → Purchase History: collected, not linked to you, not used for
tracking.** This answer changed with the in-app purchase, and "not collected"
is no longer true. `LicenseServerClient.claim(jws:)` posts the signed App
Store transaction to the licence server, which asks Apple whether the purchase
is real and then writes a row recording that this transaction bought the Mac
licence and which key was issued for it. That row is purchase information the
developer holds, so the category is collected.

Not linked, on the evidence: the row carries Apple's original transaction id,
the word `apple` in place of a customer, an empty email and no name
(`src/apple.ts` on `claude/gl-apple`). There is no account in either app, the
App Store never tells the developer who bought, and nothing joins that row to
the analytics install id. Not used for tracking: the purchase path sends no
analytics event at all, and no purchase data reaches PostHog or any third
party other than Apple, who already has it.

Two things to keep true, because both would flip this answer to **linked**:
never attach an email or any account identifier to an Apple licence row, and
never send a purchase event through `Analytics.capture`, which would tie the
purchase to the install id.

`AudioutRemote/PrivacyInfo.xcprivacy` has to gain a matching entry
(`NSPrivacyCollectedDataTypePurchaseHistory`, `Linked` false, `Tracking`
false, purpose `AppFunctionality`) before this answer is truthful. It is item
4 of §0.

**Every other category**, Contact Info, Health & Fitness, Financial Info,
Location, Sensitive Info, Contacts, User Content, Browsing History,
Identifiers, Diagnostics, Other Data: **not collected.** Crash data, if the
user ever shares any, reaches Apple only through iOS's own "Share With App
Developers" setting; the app has no code path that sends or reads a crash
report, so that is Apple's opt-in, not this app's collection. Financial Info
stays "not collected" deliberately: the app never sees a card, an account or
an amount, only Apple's signed word that a purchase happened.

The rest of `PrivacyInfo.xcprivacy` is the source of truth the answer has to
match: `NSPrivacyTracking` false, the Product Interaction entry (`Linked`
false, `Tracking` false, purpose Analytics), and two required-reason API
declarations the app or the PostHog SDK it links touches: User Defaults
(reason `CA92.1`) and System Boot Time (reason `35F9.1`). Resulting nutrition
label once the purchase entry is added: **Data Not Linked to You: Usage Data,
Purchases.** No category qualifies as Data Linked to You or Data Used to
Track You.

## 5. Export compliance

The app uses only Apple's standard networking APIs (`Network.framework` WebSocket/TCP,
and standard HTTPS for the PostHog analytics calls in §4 and the licence-server
call in §1) with no custom or proprietary encryption implemented by the app.
This qualifies for the **exempt** path, no annual self-classification report
required.

The build already answers the question for itself:
`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` is set in the phone
project, so App Store Connect should not ask again per upload.

## 6. Age rating

**4+**. No objectionable content categories apply (no violence, mature themes, gambling,
UGC, or unrestricted web access); answer every questionnaire item "None."

## 7. Naming (settled: D4), and what the purchase changed

**Audiout Remote** is the name (`docs/plans/PLAN-REMOTE-RELEASE.md`, decision
D4, 2026-09-05). It matches the shipping Xcode target name and bundle id
(`com.audiout.remote`); the bundle's display name is the shorter `Audiout`,
which Apple permits. The recorded subtitle, "The remote that tunes your
speakers.", is 36 characters against a 30-character field and cannot ship.
Replacements are in `dev/notes/app-store-listing-copy.md`.

**Guideline 3.1.3(f) no longer carries the argument, and does not need to.**
That reader ("Free Stand-alone Apps") lets a free app unlock content bought
elsewhere without offering in-app purchase, and it was this kit's defence for
a phone app that sold nothing. The ADR took the other road for a reason the
guideline itself exposes: 3.1.3(f) is written about web tools and services,
not a Mac app sold direct, so a reviewer could fairly dispute it, and the
defence would have been the whole submission.

The app now offers the purchase through Apple, which is what Guideline 3.1.1
asks of any app unlocking features. Both readings are satisfied at once: a
customer who bought on audiout.app unlocks the phone with no purchase here
(3.1.3(f)), and a customer who has not can buy through Apple at the same price
(3.1.1). The app carries no link to the website's checkout, so 3.1.1's
anti-steering rule is not in play either.

What this removes from the kit: the old §1 sentence "Audiout Remote has no
purchase flow of its own (Guideline 3.1.3(f))", and the old neutral lock
screen it described, which had no price, no URL and no button by design. That
screen is now the purchase surface. The comment in
`AudioutRemote/UI/Shared/LockedView.swift` was rewritten with it.

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
- [ ] The in-app purchase works end to end for a reviewer with no Mac: buy in
      Settings, Restore purchase, and a clear account of what the key does
      next. Blocked on §0 items 2 and 3. A purchase that takes money and
      produces no visible result is a 2.1 rejection on its own terms.
- [ ] Expect one review round-trip is possible regardless (research doc §7
      notes this as normal precedent, e.g. a comparable Pi-hole companion
      resolved via notes + video); do not treat a first rejection as a
      process failure.

Not ready for T24's submission: §0 must clear first.
