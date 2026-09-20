# Handover: Audiout Remote App Store listing

2026-09-20, evening. Everything below is pushed unless it says otherwise. **Nothing is merged.**

Updated later the same evening: the phone branch is now at `baf8bfa`, everything in §7 is committed, and the slides are re-rendered with the corrected captions.

The job Alec asked for: finish the App Store listing for the iPhone companion app, screenshots included, and run a design discovery first into how the listing conveys visually that the phone is a remote for the Mac app rather than a standalone product.

Read these two first, they are the substance:
- `dev/notes/app-store-screenshots-discovery-2026-09-20.md` — the discovery, the rules, what the companion-app category does, four directions, tooling verdict, Alec's rulings, and §8, the outcome with its traps.
- `dev/notes/app-store-listing-copy.md` — every App Store Connect field with its character count, and the pre-submission gap list.

## 1. The two branches

**Mac repo**, `claude/app-store-listing-design-4604cc`, head `74304f2f`, clean:

| commit | what |
|---|---|
| `89a64ab0` | `AUDIOUT_MOCK_FLEET=store-shots` serves the popover the same six speakers the phone's demo seeds |
| `46bafbf6` | `ios.sh shot` builds Release and pins the status bar to 09:41 |
| `7218fb79` | the discovery brief's outcome section |
| `ae46f68b` | the membership rail becomes one colour per appearance (see §4) |
| `dd32e072` | the listing copy, and the submission kit rewritten for the in-app purchase |
| `1530db3b` | the Mac activates a licence key the phone bought (see §5) |
| `74304f2f` | corrects the false claim in `ios.sh` that the Simulator cannot find a Mac |

**Phone repo** (`/Users/alechenderson/Projects/audiout-remote`), `claude/store-shots`, head `baf8bfa`. `origin/main` is merged in, so it carries the in-app purchase. It has no uncommitted work. The phone's unit tests ran on the second Mac after these changes: "Test run with 394 tests in 24 suites passed".

Earlier commits on it add `-store-shots` (opens the demo shell directly, Mac named "MacBook Pro", three speakers playing, and `showsDemoAffordances = false` hiding the Demo strip, the Speakers coach mark and Settings' "Leave demo" row), `-store-shots-screen NAME`, the demo additions (Bedroom HomePod, Apple Music routed to it, Spotify routed to the Living Room scene, a second saved scene "Kitchen"), and `scripts/store-shots/`, the slide renderer.

Three more commits finish it: `f253271` adds the `approval` capture screen and a stand-in licence key store under `-store-shots` so Settings reads "Mac licence / Bought"; `ec72a93` brings the captions over from the listing copy, adds `build-all.sh dark|light`, renders both sync and both connect states, and gitignores `out-light/`; `baf8bfa` keeps slides 4 and 6 to two headline lines by moving the second sentence of each caption to the sub-line.

## 2. How a screenshot gets made

Two steps. Capture the phone, then render the slide around it.

```bash
# capture — run from the MAC worktree; it routes the work to the second Mac
cd "/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/app-store-listing-design-4604cc"
bash scripts/ios.sh shot \
  --root /Users/alechenderson/Projects/audiout-remote/.claude/worktrees/store-shots \
  --out  /Users/alechenderson/Projects/audiout-remote/.claude/worktrees/store-shots/scripts/store-shots/captures \
  --appearance both --screen speakers
```

Screens: `speakers apps scenes sync sync-listening sync-settled connect settings approval`. Output is `<screen>-<dark|light>.png` at 1320×2868. The script builds Release (Debug leaks a "Replay intro" row into Settings), pins the status bar to 09:41 twice, and copies `scripts/store-shots/app-icons/*.png` into the simulator's icon cache so Apple Music and Spotify show real artwork.

```bash
# render — from the phone repo
cd /Users/alechenderson/Projects/audiout-remote/.claude/worktrees/store-shots/scripts/store-shots
./build-all.sh                       # dark, into out/ — 8 files: 01 02 03 04a 04b 05a 05b 06
./build-all.sh light                 # the same 8 into out-light/
./build.sh out/03-scenes.png PAGE=slide3.html PHONE=captures/scenes-light.png
```

`scripts/store-shots/README.md` covers the rest. The Mac popover half of slide 1 comes from a separate recipe, §3.

## 3. The Mac popover capture

Slide 1 is a composite: the Mac popover on the left with its speaker names visible, the phone on the right in front, both showing the same three speakers playing, green ring crests between them.

```bash
APP_NAME="Audiout" BUNDLE_ID="com.audiout.Audiout.shots" bash scripts/make-app.sh
defaults write com.audiout.Audiout.shots setup.hasCompleted -bool true
defaults write com.audiout.Audiout.shots surface.pinned -bool true          # a real window, not a popover that dies on focus loss
defaults write com.audiout.Audiout.shots audio.mainOutVolume -int 65
defaults write com.audiout.Audiout.shots general.reconnectAtLaunch -bool true
defaults write com.audiout.Audiout.shots appearance.theme -string dark      # or light
AIRPLAY_BACKEND=mock AUDIOUT_MOCK_FLEET=store-shots build/Audiout.app/Contents/MacOS/AudioutApp &
open build/Audiout.app     # raises the running instance; does NOT start a second
# ~1.2 s, then: screencapture -x -R x,y,w,h -t png out.png
```

Traps, each paid for:
- **Read `"NSWindow Frame ControlPanelSurface"` fresh every launch.** It changes between launches; a stale height silently crops the bottom. It is `x y w h` bottom-left origin; convert with `y_top = 1050 - y - height` on this 1680×1050 screen.
- Selection does not come from the fleet. `GroupController.ensureDefaultSelection()` resets to local unless `general.reconnectAtLaunch` is set, and a seeded `routing.json` in the shots id's own Application Support folder holds the three device ids.
- The `.shots` bundle id has its own Application Support folder (per-id since 2026-08-06), so it cannot corrupt Alec's routes and needs no live-test slot. The old "never seed routing" rule no longer applies to non-default ids.
- `open`, then about 1.2 s, then capture. Longer and another window takes the front.

## 4. The rail fix

Alec, looking at the popover in light mode with the accent dial on Full gold: "it has a dark rail and the light member dots", and his ruling was that the wire, the filled dots and the hollow rings must all be one colour, with fill versus stroke carrying selection.

The two hues came from one flag meaning two things: nodes took `armed:` (the popover's rows are the live path) while the wire and rings took `isSpineLive` (is audio flowing right now). `ae46f68b` introduces a `railLive` token and routes every part of the instrument through `spineTone(armed:)`. Dark stays `#E8B84B` at 9.74:1; light becomes `#8F7B4A` at 3.95:1, chosen because it clears the 3:1 floor and still separates from light `ember` by 1.40 to 1.55:1. Full suite green, 3975 tests.

One behaviour moved with it: the popover's wire no longer drops to ember when the master is muted. Liveness is still reported by the route-armed dot, the row wash, the meters and the readout ink.

**Still open, deliberately not done**: the Groups editor can still show a node whose tone differs from its wire, for a row checked but not routed. Roadmap 076 already covers that question.

## 5. The purchase chain

The in-app purchase **shipped to the phone's main this morning** (PR #33, `deff0ca`) and nobody in this session knew until late, because the local checkout was six commits behind. StoreKit 2 buy and restore of `com.audiout.remote.maclicence`, a Keychain store, a Settings section, and `RemoteSession` sending the key to the Mac on every connection.

It was a dead end: the Mac answered `activateLicenseKey` with "Unknown command". `1530db3b` fixes that. A key from the phone now takes the same path as one typed into the Mac, with honest refusals for a bad key, an unreachable server, or a Mac already holding a paid key, and a bought key replaces a running trial. It fires the existing `license:key_submitted` event with `source: phone`; the new `already_licensed` outcome is on `claude/phone-key-outcome` (`ec5210d`) in `audiout-shared`, unmerged. Full suite green, 3983 tests.

**The purchase is still broken end to end, and the rest is Alec's:**
1. `AppSettings.remoteAppIsOffered = false` (`AppSettings.swift:396`), so a shipping Mac never starts the companion server and the key never arrives. One line, flipped on the release after the phone app is approved.
2. The licence server's Apple route answers 503 until `APPLE_ISSUER_ID` and `APPLE_KEY_ID` are filled into `wrangler.jsonc` and the private key secret is set. The code itself is merged (PR #9) and probably live on staging. **The phone treats 503 as permanent and stops asking**, so those ids must be right before the app ships, not after.
3. No App Store Connect in-app purchase record.
4. `PrivacyInfo.xcprivacy` declares Product Interaction only; the purchase needs a Purchase History line.
5. Nothing in the chain has been live-tested with a real phone.

One edge left alone: the phone gives up on a command after 5 s while the licence check allows 10, so a slow server shows "The Mac isn't responding" even though the Mac stores the key and unlocks at the next launch.

## 6. The Simulator can find a real Mac

The comment in `ios.sh` said it could not. It can, measured today and now corrected in `74304f2f`.

```bash
AIRPLAY_BACKEND=mock AUDIOUT_MOCK_FLEET=store-shots AUDIOUT_COMPANION=on \
  build/Audiout.app/Contents/MacOS/AudioutApp &
dns-sd -B _audiout._tcp        # advertises as "Alec's MacBook Pro"
```
Then on the mule: boot a simulator, install, `simctl spawn <udid> defaults write com.audiout.remote hasSeenConnectPrimer -bool true` to skip the intro, launch with no flags, wait about twelve seconds, screenshot. It finds the Mac. No local-network permission prompt appears, because the Simulator does not enforce that gate.

`AUDIOUT_COMPANION=on` overrides `remoteAppIsOffered`. `captures/connect-dark.png` and `connect-light.png` are live captures made this way and genuinely say "Alec's MacBook Pro".

This opens a path nobody has taken: capture every screen against a live Mac serving the curated fleet, instead of against demo mode. It needs a tap on Connect, which `simctl` cannot do, so it would go through the existing XCUITest harness, plus the Allow click on the Mac.

## 7. The approval capture (committed)

It was reviewed and committed as `f253271`. The approval capture parks the connection in the awaiting-approval state through `ConnectionController(initialConnectionState:)` and names "MacBook Pro".

## 8. What the slides look like now

`scripts/store-shots/out/` (dark phones) and `out-light/` (light phones on the same dark ground), plus `contact-sheet.png` in each and `compare-01.png` / `compare-03.png`.

| # | screen | caption as rendered | sub-line |
|---|---|---|---|
| 1 | Speakers + Mac popover | Your Mac's speakers. In your hand. | |
| 2 | Apps | Send one app to the kitchen. | |
| 3 | Scenes | Saved scenes. One tap to play. | |
| 4 | Sync, two versions `04a` listening and `04b` settled | Your iPhone is the ear. | It aligns a Bluetooth speaker. Stand where you listen. |
| 5 | Connect, two versions `05a` found and `05b` approval | Finds your Mac on the same Wi-Fi. Allow once. | Tap your Mac's name. It asks once, then remembers. |
| 6 | Settings | Talks to your Mac directly. | No account, no sign-in. |

Slides 4 and 6 could not hold the copy note's full caption on two headline lines at 107px, so each second sentence became the sub-line.

Measured, on slide 3: the dark phone body is 1.08:1 against the slide ground and reads as a floating list; the light phone is 17.45:1 and reads as a phone.

## 9. Open decisions, all Alec's

1. **Slide 4**, listening or settled. Both are rendered as `04a` and `04b` and were sent to him; no answer yet.
2. **Appearance.** He said he will shoot Speakers, Apps and Scenes himself because he wants to control exactly how they look, and to keep light for the others. **His iPhone 15 Pro captures at 1179×2556, the 6.1 inch class.** Apple needs a 6.9 inch set (1320×2868) or a 6.5 inch one; 6.1 alone is not accepted. His three would have to be scaled up 1.12×, or he directs the state and someone shoots it natively on the 6.9 inch simulator. He has been told and has not answered.
3. **Settled.** The capture now shows "Mac licence / Bought" via the stand-in key store, which the copy note's Guideline 2.3.7 constraint required anyway.
4. **The light connect capture has a black Dynamic Island pill** against a near-white status bar, measured at island `(0,0,0)` versus background `(249,249,250)`. It appears because that junction draws its field edge to edge under the status bar. The dark capture is clean. Whether it is wrong at all is a judgement call; it is not in other apps' listings.
5. **Slide 5**, the plain found-Mac screen or the approval screen. Both are rendered, as `05a` and `05b`. Alec described the approval screen from memory and liked it; it names the Mac and shows the one-time Allow, which is what the caption claims. §7 has the capture.
6. **The wizard's appearance.** Alec believes "the new design for the wizard is a light mode". The code and the design record disagree: `SyncSheet.swift:72` forces dark, landed in `55f39a9`, and `DESIGN.md` records `stagePlate` as "the alignment run page's dark ground, fixed in both light and dark appearance", with stageInk, stageRule, stageReference and fuseWhite all fixed the same way. The Mac's own stage says the same. No unmerged branch changes it. So either he is thinking of a proposal that never landed, or he wants a real design change. **Unresolved, and it blocks slide 4's appearance**: the light sync capture is a grey band above a black screen and is unusable as it stands.

## 10. Traps worth carrying forward

- **A main-mix speaker cannot be an app's redirect target.** `AppsView.redirectableDevices` excludes Main Out members, matching the Mac's one-role rule. Apple Music pointed at a playing HomePod rendered "Unavailable speaker". Hence Bedroom HomePod in the demo.
- **`ConnectionController.setOnMacsChanged` replays its own list to a newly installed handler**, and that empty replay erased an injected Mac. The connect screen skips it.
- **Headless Chrome renders fail under machine load.** The deadline is 90 real seconds in `build.sh`; a failure now names the page and the elapsed time, and a slow render warns. The machine was at load average 289 when three renders failed in a row.
- **`build-all.sh` deletes each target before rendering** so a failed slide cannot leave a stale image in `out/` looking complete, and it exits non-zero naming every failure.
- **`ios.sh test` exits 0 with "no iPhone simulator installed"** when the remote is unusable and it falls back locally. A green exit code that means nothing. Pass `AUDIOUT_IOS_REMOTE_ONLY=1` for a real verdict, and read the "Test run with N tests" line rather than the word "passed".
- **The real Apple Music and Spotify icons were an accident first.** They came from a stale icon cache on the mule's simulator. They are now seeded deliberately from `/Applications/Spotify.app` and `/System/Applications/Music.app` into `scripts/store-shots/app-icons/`, gitignored, rsynced to the mule with the tree, and copied into the app container before launch. Nothing third-party ships in the binary.
- **Two phone tests were stale against shipped copy** (`This iPhone` versus `Your phone`, from `a4de8e7`) and are fixed on the branch.

## 11. Suggested order for whoever picks this up

1. Get answers to §9.1, §9.2 and §9.6 before rendering anything again; 9.6 decides whether slide 4 can be light.
2. ~~Review and commit or discard §7.~~ Done.
3. ~~Re-render the set with the corrected captions from `app-store-listing-copy.md`.~~ Done.
4. Settle §9.4.
5. The purchase chain in §5 is separate work and mostly Alec's; do not let it block the listing.

## 12. Later the same night

The phone branch `claude/store-shots` is at `43d53c8`. It now carries a merge of
`claude/wizard-design-audit-9cab03` — the redesigned Align sheet, which follows
the system appearance; that branch is pushed but not merged to main — plus the
parked sync captures re-wired to the new sheet's `Verdict` and `State` shapes,
and 408 unit tests green on the mule.

The slides: the fields are gold, green, magenta, gold, green, magenta; every
emitter alpha is 0.9; the gold ramp is `#8A6A2F` / `#E8B84B` / `#FFF3D1`; the
phases on slides 1 and 6 sit at the swell peak; slide 1 reach is 1350. The
connect captures come from the demo path and say "MacBook Pro". The settings
captures show "Mac licence / Bought".

§9 status: 9.2 is answered, light is the pick. 9.6 is answered by the wizard
branch — the sheet no longer forces dark, so slide 4 light is usable. 9.1 (04a
vs 04b), 9.4 (the Dynamic Island pill) and 9.5 (05a vs 05b) are still open. The
crests touch the headline's edge on slides 3 and 6; it reads fine, but the owner
has not ruled on it.

The mule demo build: host `alechamilton@SUMUP-M9Y197RFVG.local`, simulator
`5B35AE36-A2AC-45EA-B371-6D31BEB6AE0B`. Relaunch it only with
`xcrun simctl launch <udid> com.audiout.remote -uitest-isolated -store-shots` —
a tap on the home screen drops those flags and the app then finds the real Mac.
On the Xcode 27 beta the simulator window belongs to DeviceHub, not Simulator.

Trap: `ios.sh shot --appearance both` set the appearance AFTER the app launched,
until this commit. A frozen screen repaints its content on the flip but keeps
the toolbar it was built with at launch, so the light capture came back with a
white title on a white header. Fixed in this commit.

Trap: a remembered Mac (`knownMacs`, `lastUsedMacID` in the simulator's copy of
the app defaults) leaks the owner's own Mac name into the connect capture. Clear
it with
`simctl spawn <udid> defaults delete <container>/Library/Preferences/com.audiout.remote knownMacs`.

## 13. 2026-09-21, early

The phone branch `claude/store-shots` is at `fd5c82a`, plus one `sheet.py`
commit that lands after it.

Owner rulings. The Apps capture drops the "Demo Music" and "Demo Browser" rows
and shows Google Chrome and Slack under Not running, with real icons seeded by
`app-icons.sh` — four icons now. The Scenes capture has Living Room playing and
Kitchen, Bedroom, Office and Everywhere saved. Slide 4 ships the settled
verdict, 04b, which answers §9.1. The connect capture is taken 2 seconds after
launch: the gate's field sweeps one broad crest across the screen, and the
script's 4-second wait lands in the trough. That was measured, and it needs no
code change.

Still open: §9.4, the Dynamic Island pill; §9.5, 05a vs 05b; and whether slide
5's field should read as thinner rings — that one is `GateField`'s
`ringScaleDeviation`, an app change rather than a capture change.
