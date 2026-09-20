# Handover: Audiout Remote App Store listing

2026-09-20, evening. Everything below is pushed unless it says otherwise. **Nothing is merged.**

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

**Phone repo** (`/Users/alechenderson/Projects/audiout-remote`), `claude/store-shots`, head `a50b6af`. `origin/main` is merged in, so it carries the in-app purchase. It has **uncommitted work**, see §7.

Earlier commits on it add `-store-shots` (opens the demo shell directly, Mac named "MacBook Pro", three speakers playing, and `showsDemoAffordances = false` hiding the Demo strip, the Speakers coach mark and Settings' "Leave demo" row), `-store-shots-screen NAME`, the demo additions (Bedroom HomePod, Apple Music routed to it, Spotify routed to the Living Room scene, a second saved scene "Kitchen"), and `scripts/store-shots/`, the slide renderer.

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

Screens: `speakers apps scenes sync sync-listening sync-settled connect settings`, plus `approval` once §7 is committed. Output is `<screen>-<dark|light>.png` at 1320×2868. The script builds Release (Debug leaks a "Replay intro" row into Settings), pins the status bar to 09:41 twice, and copies `scripts/store-shots/app-icons/*.png` into the simulator's icon cache so Apple Music and Spotify show real artwork.

```bash
# render — from the phone repo
cd /Users/alechenderson/Projects/audiout-remote/.claude/worktrees/store-shots/scripts/store-shots
./build-all.sh                       # all six into out/
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

## 7. Uncommitted work in the phone worktree

`/Users/alechenderson/Projects/audiout-remote/.claude/worktrees/store-shots`:
- `AudioutRemote/RootView.swift` and `AudioutRemote/Networking/ConnectionController.swift` add `-store-shots-screen approval`, which parks the gate at `ConnectGateView.Junction.awaitingApproval` with the connection really in that state rather than the view forced. It seeds `lastUsedMacID` so the instruction names a Mac.
- `captures/approval-dark.png` and `approval-light.png` exist already.
- `scripts/store-shots/sheet.py` is modified and `scripts/store-shots/out-light/` is untracked.

An agent was told to finish and commit this and Alec cancelled it mid-task, so **it is unreviewed and untested**. Read it before trusting it. `out-light/` is not gitignored although `out/` is, so it would otherwise land as about 20 MB of PNGs.

## 8. What the slides look like now

`scripts/store-shots/out/` (dark phones) and `out-light/` (light phones on the same dark ground), plus `contact-sheet.png` in each and `compare-01.png` / `compare-03.png`.

| # | screen | caption as rendered |
|---|---|---|
| 1 | Speakers + Mac popover | Your Mac's speakers. In your hand. |
| 2 | Apps | Send one app to the kitchen. |
| 3 | Scenes | One tap plays the whole house. |
| 4 | Sync, two versions `04a` listening and `04b` settled | Your phone is the ear. |
| 5 | Connect | Finds your Mac. Allow once. |
| 6 | Settings | Included with Audiout for Mac. |

Captions 3 to 6 are **superseded** by `dev/notes/app-store-listing-copy.md`, which changed them for real reasons: caption 6 is both untrue now and a commercial term, which guideline 2.3.7 bars inside a screenshot. The slides still carry the old text. Re-render after reading that note.

Measured, on slide 3: the dark phone body is 1.08:1 against the slide ground and reads as a floating list; the light phone is 17.45:1 and reads as a phone.

## 9. Open decisions, all Alec's

1. **Slide 4**, listening or settled. Both are rendered as `04a` and `04b` and were sent to him; no answer yet.
2. **Appearance.** He said he will shoot Speakers, Apps and Scenes himself because he wants to control exactly how they look, and to keep light for the others. **His iPhone 15 Pro captures at 1179×2556, the 6.1 inch class.** Apple needs a 6.9 inch set (1320×2868) or a 6.5 inch one; 6.1 alone is not accepted. His three would have to be scaled up 1.12×, or he directs the state and someone shoots it natively on the 6.9 inch simulator. He has been told and has not answered.
3. **The Settings slide shows a disabled grey "Buy Mac licence" row**, because no StoreKit product loads in an isolated launch. It reads as broken, and its footer mentions a free trial under a headline that is changing anyway.
4. **The light connect capture has a black Dynamic Island pill** against a near-white status bar, measured at island `(0,0,0)` versus background `(249,249,250)`. It appears because that junction draws its field edge to edge under the status bar. The dark capture is clean. Whether it is wrong at all is a judgement call; it is not in other apps' listings.
5. **Slide 5**, the plain found-Mac screen or the approval screen. Alec described the approval screen from memory and liked it; it names the Mac and shows the one-time Allow, which is what the caption claims. §7 has the capture.
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
2. Review and commit or discard §7.
3. Re-render the set with the corrected captions from `app-store-listing-copy.md`.
4. Settle §9.3 and §9.4.
5. The purchase chain in §5 is separate work and mostly Alec's; do not let it block the listing.
