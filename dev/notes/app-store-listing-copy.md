# App Store listing copy: Audiout Remote

2026-09-20. Every field App Store Connect asks for, with its character count
against Apple's limit. Companion to `docs/companion-app-store.md` (the
submission kit) and `dev/notes/app-store-screenshots-discovery-2026-09-20.md`
(the six slides).

Written against the app as it stands on `origin/main` of `aa-hh/audiout-remote`
(commit `5a813e1`), which includes the in-app purchase of the Mac licence
(`deff0ca`, 2026-09-20). Terminology follows the `audiout-copy-review` table:
scene (never group), Main Audio (never Main Out), volume (never level),
Wi-Fi network, Favourites, align / Sync for the Bluetooth timing feature.

## Fields at a glance

| Field | Limit | Chars | Status |
|---|---|---|---|
| App name | 30 | 14 | settled |
| Subtitle | 30 | 28 | **replaced**, the recorded one is 36 |
| Promotional text | 170 | 164 | |
| Description | 4000 | 2667 | |
| Keywords | 100 | 94 | |
| What's New | 4000 | 14 | |

Nothing exceeds its limit.

## App name (30)

```
Audiout Remote
```
14 characters. Settled by decision D4 (2026-09-05) and unchanged.

The bundle's own display name is `Audiout`, not `Audiout Remote`
(`INFOPLIST_KEY_CFBundleDisplayName`), so the home-screen icon reads
"Audiout" while the store reads "Audiout Remote". Apple allows the shorter
on-device name; the kit's §7 claim that the name "already matches" the target
is true of the target and bundle id, not of the display name.

## Subtitle (30)

The recorded subtitle, "The remote that tunes your speakers.", is 36
characters and cannot be used. It survives as the headline of the website's
/remote page, where there is no limit.

**Recommended.**
```
Your Mac's speakers, in hand
```
28 characters. Carries the Mac dependency, which is the one thing the
subtitle has to do, and it is the same sentence as the first screenshot
caption, so the listing and the images say one thing.

**Alternative.**
```
Tune your Mac's speakers
```
24 characters. Keeps the verb of the recorded subtitle and of the website
headline. Weaker: "tune" does not say the Mac is required, only that it is
involved.

Both avoid spending subtitle words on "Audiout" and "Remote", which the app
name already indexes. A third option, "Remote for Audiout on your Mac" (30),
is the clearest sentence of the three and the worst use of the field.

## Promotional text (170)

Sits above the description, and can be changed without shipping a build.

```
The remote for Audiout on your Mac. Set each speaker's volume from the next room, send one app to the kitchen, play a scene with one tap, align a Bluetooth speaker.
```
164 characters.

**Alternative**, if the free price should lead (168):
```
Free. The remote for Audiout on your Mac. Every speaker's volume from the next room, one app sent to the kitchen, a saved scene in one tap, a Bluetooth speaker aligned.
```

## Description (4000)

2667 characters. The dependency is the first sentence and the last line of
the first paragraph, because burying it is what gets companion apps rejected
under Guideline 2.1 and one-starred by buyers who did not read.

```
Audiout Remote is the iPhone remote for Audiout, a separate app you buy for your Mac. Audiout sends everything your Mac plays to your AirPlay and Bluetooth speakers at once. This app controls it from another room. Without a Mac running Audiout on the same Wi-Fi network, there is nothing here to control.

The app itself is free. There is no account and no sign-in. Your iPhone finds your Mac over the Wi-Fi network you are both on already, and talks to it directly.

SPEAKERS
Every speaker your Mac can play to gets a row, and the row is the fader. Drag it to set that speaker's volume. Main Audio sits at the bottom and sets the ceiling for all of them. Mute changes only after your Mac confirms it, so the app never shows a room silent while it is still playing. Speakers sort themselves into Playing, Ready and Unavailable, and the ones you reach for most go in Favourites.

APPS
Give one app its own speaker. Music in the kitchen while a call stays on your desk. Each app playing on your Mac gets a row and a speaker to point at.

SCENES
Save a set of speakers under a name, then play to it with one tap. Scenes are made and edited from here as well as on the Mac.

SYNC
A Bluetooth speaker arrives late and plays behind the rest. Take your iPhone to where you listen. Audiout plays a few short test sounds, the phone's microphone hears how far behind that speaker is, and the offset goes to your Mac. The recording is analysed on the phone and thrown away.

WHAT YOU NEED
- A Mac running Audiout, with a licence or inside its free 14-day trial.
- This iPhone and that Mac on the same Wi-Fi network.
- "Allow control from iPhone on this network" turned on in Audiout's Settings on the Mac.

BUYING AUDIOUT
If you do not own Audiout yet, you can buy the Mac licence here as a one-time purchase, and this app hands it to your Mac. One licence covers your Mac and every iPhone that connects to it, so a licence bought on audiout.app needs nothing bought again here. Restore purchase is in Settings. Audiout on your Mac also starts a free 14-day trial the first time it opens.

NO MAC YET
The search screen offers a demo. It is a pretend Mac with a pretend set of speakers, and every control works. Nothing plays out loud.

PRIVACY
Discovery, control and volume never leave your Wi-Fi network. The app sends anonymous counts of which screens and features get used, and Settings has one switch that turns that off. Speaker names, app names, and what you are playing are never sent. The microphone is used only while measuring a Bluetooth speaker.

ACCESSIBILITY
Every control is labelled for VoiceOver, Reduce Motion is honored throughout, and Dynamic Type is supported everywhere.
```

Every claim in it is in the shipping code: the row-as-fader and Favourites in
`AudioutRemote/UI/Speakers/DeviceRowView.swift`, Main Audio in
`SpeakersView.swift:600`, the mute-waits-for-the-Mac rule in PRODUCT.md's
product principles, the demo in `ConnectGateView.swift:781`, the purchase and
restore in `LicenseStore.swift` and `SettingsTabView.swift`, the microphone
sentence in `INFOPLIST_KEY_NSMicrophoneUsageDescription`.

## Keywords (100)

No spaces after commas, and no word already in the name or the recommended
subtitle (audiout, remote, your, mac's, speakers, in, hand).

```
airplay,bluetooth,multiroom,volume,mute,routing,scene,sync,audio,music,sound,mixer,wifi,stereo
```
94 characters.

Shorter version without `stereo` if a word has to come out, 87 characters:
```
airplay,bluetooth,multiroom,volume,mute,routing,scene,sync,audio,music,sound,mixer,wifi
```

Deliberately absent: **sonos**, **homepod**, **airfoil**. Other companies'
marks in a keyword field are a Guideline 5.2.1 rejection, and Apple's own
product names are refused as keywords for apps that are not Apple's.

## What's New (first release)

```
First release.
```

App Store Connect requires this field on 1.0 even though there is nothing to
report. Anything longer duplicates the description, and the version history
keeps it forever.

## Support URL and Marketing URL

- **Support URL: `https://audiout.app/support`.** The page exists, with 18
  articles under `src/pages/support/`, two of which are about the phone
  (`measure-speaker-with-iphone.md`, `align-bluetooth-speaker.md`). Nothing
  there yet covers buying the Mac licence in the phone app or restoring that
  purchase, which is the first thing an App Store buyer will look for. That
  article is owed before submission, and it belongs to the website's owner.
- **Marketing URL: `https://audiout.app/remote`.** The page exists but
  currently renders in its "coming soon" state: `const soon = !storeConfigured`
  in `src/pages/remote.astro` swaps every heading to future tense ("How it
  will connect") and shows a notify-me form. A reviewer opening the marketing
  URL sees a page saying the app is not out yet. Flip `storeConfigured` when
  the listing goes live. The same page's meta description still calls the app
  "the free iPhone app included with Audiout for Mac", which stopped being the
  whole truth when the in-app purchase landed.

Both URLs are on the website, which is another person's lane; these are specs
for them, not edits to make from here.

## Screenshot captions

The six slides are in
`dev/notes/app-store-screenshots-discovery-2026-09-20.md` §8.

| # | Slide | Caption | Change |
|---|---|---|---|
| 1 | Speakers, phone + Mac popover | Your Mac's speakers. In your hand. | kept |
| 2 | Apps | Send one app to the kitchen. | kept |
| 3 | Scenes | Saved scenes. One tap to play. | changed |
| 4 | Sync sheet | Your iPhone is the ear. It aligns a Bluetooth speaker. | changed |
| 5 | Connect gate | Finds your Mac on the same Wi-Fi. Allow once. | changed |
| 6 | Settings | Talks to your Mac directly. No account, no sign-in. | changed |

Why each one changed:

- **3 was "One tap plays the whole house."** The slide shows two scenes named
  Living Room and Kitchen. "The whole house" claims a room count the picture
  does not show, and a scene is whatever speakers the user saved into it. The
  replacement uses the product's own word, which is also the word the App
  Store search index sees.
- **4 was "Your phone is the ear."** Two problems. It is a mood, not a claim:
  a reader who has never heard of aligning a Bluetooth speaker learns nothing
  from it. And the copy rules call the phone "this iPhone" or "your iPhone",
  never "your phone". The app's own intro card is the drift, not the
  standard, and `IntroCardsTests` still expects the compliant string.
- **5 was "Finds your Mac. Allow once."** The Wi-Fi network is the whole
  mechanism and the commonest reason discovery fails; dropping it saved six
  words and lost the fact.
- **6 was "Included with Audiout for Mac."** It is now false as written: the
  app is free, but it also sells the Mac licence, so "included with" describes
  a relationship that no longer holds on its own. It is also a commercial term
  inside a screenshot, which Guideline 2.3.7 bars. The replacement states what
  the Settings slide actually shows.

**A capture constraint that follows from the purchase.** Settings now carries
a "Buy Mac licence for €30.00" button whenever no key is on file
(`LicenseStore.buyTitle`). Guideline 2.3.7 bars prices inside screenshots, so
the Settings slide has to be captured with a key already stored, where the row
reads "Mac licence / Bought", or framed to exclude that section. The same
applies to the lock screen, which is now a purchase panel with the price on
its button; it must not appear in any slide.

## Copy-review findings outside this document

Three strings that the `audiout-copy-review` rules flag, all in other repos:

```
[warn] iPhone app — AudioutRemote.xcodeproj/project.pbxproj:451 (NSMicrophoneUsageDescription)
  now:  "…analysed on your iPhone and thrown away — nothing is saved or sent anywhere."
  rule: prose rules, "Em dashes: none in UI strings"
  fix:  "…analysed on your iPhone and thrown away. Nothing is saved or sent anywhere."

[warn] iPhone app — AudioutRemote/UI/Connect/ConnectGateView.swift:554,559
  now:  "Your phone is the remote" / "Your phone is the ear"
  rule: terminology, the phone is "this iPhone", never "phone"
  fix:  "This iPhone is the remote" / "This iPhone is the ear" (which is what
        IntroCardsTests already expects, and the failing test named as still
        open in the screenshots note)

[warn] Mac app — PRODUCT.md, "Capabilities and Constraints"
  now:  "\"groups\" (saved named speaker sets)"
  rule: terminology, a saved speaker set is a scene
  fix:  "scenes". The shipping phone app labels the tab "Scenes"
        (RootView.swift:529) and the website says scenes; the Mac's own
        PRODUCT.md and its Groups seat button are the last holdouts.
```
