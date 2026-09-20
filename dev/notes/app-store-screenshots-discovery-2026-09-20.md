# App Store screenshots for Audiout Remote: design discovery

2026-09-20. Companion to `docs/companion-app-store.md` (the submission kit), whose §3 screenshot checklist this replaces.

The problem: the phone app is a remote for Audiout on the Mac. The listing has to say that in the first screenshot, before anyone reads a word. Nothing in the phone app itself pictures a Mac (the Mac is a `desktopcomputer` glyph and a name in text), and the only place the whole brand shows phone and Mac together is one 220×110 SVG tile on the website's /remote page (`src/components/remote-steps/StepPhone.astro`).

## 1. Apple's rules that shape this

- One 6.9-inch set (1320×2868 portrait) covers every iPhone size. 1 to 10 per language. PNG or JPEG, no alpha.
- Guideline 2.3.3: screenshots "should show the app in use, and not merely the title art, login page, or splash screen. They may also include text and image overlays." So the phone content must be real captures of the app, not the website's hand-drawn phone.
- Guideline 2.3.7 bars prices and terms inside screenshots. "Free" stays out of the pictures; it lives in the subtitle and description.
- A Mac inside an iPhone screenshot is fine. 2.3.10 bans other mobile platforms, not other Apple devices. Duet Display ships a MacBook in its first two shots today. No rejection reports found for a Mac or macOS screen in iPhone screenshots.
- App preview video: 15 to 30 s, 886×1920, up to 3. Optional. The review-notes demo video in the kit §2 is a different, unlisted artefact.

## 2. What the companion-app category does

Viewed the live listings of Sonos, Steam Link, Remote Mouse, Screens 5, Astropad, Jump Desktop, Duet Display, Home Assistant, Philips Hue, Stream Deck Mobile, Apple TV Remote, Roon, Plexamp.

Common: the caption names the other device ("Control Macs, PCs and more", "Companion app for your Home Assistant installation"); the controlled hardware appears as a photographed room behind the phone (Sonos, Hue); the other machine's screen is mirrored inside the phone (Screens, Remote Mouse).

Rare: a real phone-and-Mac composite (Duet only); an explicit connection line (Steam Link only, drawn in the app UI); the same state visible on both screens at once (Duet only).

Rare is good here. The site already draws the phone-and-Mac composite with matching state and ring crests between them, so the listing can carry a visual the category does not use.

## 3. Assets that already exist

| Asset | Where | Use |
|---|---|---|
| Mac popover screenshots, 1398×1690 and up | website `public/screenshots/01-popover.png`, `02-per-app-dropdown.png`, `03-scene-routing.png`, `04-wizard.png` | the Mac half of a composite |
| Phone-and-Mac step tiles, ring crests between them | website `src/components/remote-steps/Step{Mac,Phone,Allow}.astro` | the composition grammar to enlarge |
| Emitter field, static render path | website `tools/og-card/` (headless Chrome, exact SVG evaluation, 2× then downsample) | background per slide, brand-locked |
| Clash Display, self-hosted | website `public/fonts/` | captions (one word of it in the app; captions are the marketing surface) |
| Demo mode fleet | phone `Model/DemoMacSession.swift` | consistent on-screen content, no hardware |
| Four XCUITest screenshot attachments (Speakers, Apps, Scenes, Settings) | phone `AudioutRemoteUITests/CompanionSmokeUITests.swift:180-228` | raw captures, exported with `xcparse` |
| Apple's Product Bezels (iPhone 17, MacBook Air/Pro M5), Figma and Sketch | developer.apple.com/design/resources | optional chassis; Sketch is installed |

Two facts that constrain the phone captures:
- The site's phone mockup is dark only, drawn from source, not a capture. It fails 2.3.3 for the store; it stays a site asset.
- Demo mode paints a "Demo" strip above every tab and the Mac is named "Demo Mac". A store screenshot should not read "Demo". Options: a UI-test-only flag that hides the strip and names the Mac something real ("Alec's MacBook Pro" style), or capture against a live Mac. The flag is the reproducible one.

## 4. Four directions for the first screenshot

Each shows Speakers, two rows warm gold (playing), Main Audio mid-fader.

**A. Mirror.** Phone large in front, the Mac popover behind at about 60 % scale, upper right, both showing the same two speakers lit and the same fader position. Green ring crests (the connect colour) run from phone to Mac, taken straight from `StepPhone.astro`. Caption: "Your Mac's speakers. In your hand." This is the category's rarest device and the brand already owns it.
Cost: highest. Needs one Mac capture matched to the phone state.

**B. Menu bar.** The Mac menu bar runs across the top of the slide with the Audiout mark in it and the popover dropping from it; the phone rises from the bottom. Says "it lives in your Mac's menu bar" without a caption. Same content as A but the Mac reads as a Mac even cropped.
Cost: same as A plus a menu-bar strip capture (`08-menu.png` exists at 400×200, too small; recapture).

**C. Room.** The site's shelf illustration (three speaker glyphs over the field) behind the phone. Sonos and Hue pattern. Says "speakers", not "Mac"; the Mac has to come from the caption.
Cost: low. Fails the brief's core ask on its own.

**D. Caption only.** Bare phone on the emitter field, headline does the work: "The remote for Audiout on your Mac." Home Assistant pattern.
Cost: lowest. Weakest.

Recommendation: A for slide 1, with B's menu-bar strip folded into A if the Mac half reads as "some window" at 60 % (test at real size before deciding; flat sketches lie). D's caption formula is the fallback for every later slide.

## 5. Proposed set (six slides, dark appearance)

| # | Screen | Composite | Caption (draft) |
|---|---|---|---|
| 1 | Speakers | phone + Mac popover, matched state | Your Mac's speakers. In your hand. |
| 2 | Apps | phone + Mac per-app dropdown (`02-per-app-dropdown.png`) | Send Spotify to the patio. Your Mac follows. |
| 3 | Scenes | phone only, magenta field | One tap plays the whole house. |
| 4 | Sync sheet (dark stage, two emitters) | phone only | Your phone is the ear. Bluetooth speakers fall into sync. |
| 5 | Connect gate, Mac found by name | phone only, green field | Finds your Mac on the same Wi-Fi. Allow once. |
| 6 | Settings, Connected dot | phone only | Included with Audiout for Mac. |

Captions reuse the app's and site's own words (intro cards: "Your phone is the remote" / "Your phone is the ear"; site: "Your Mac's mixer, row for row"). Slide 6 avoids "free" (2.3.7).

Light appearance: skip for the first submission. One set, dark, matches the site and the field.

## 6. Tooling verdict

Nothing off the shelf does arbitrary layout, a Mac beside a phone, and a locked brand. Every templated tool (Screenshots.pro, AppScreens, LaunchMatic, AppMockUp, Previewed) assumes one device class. fastlane frameit has no iPhone 17 frames and needs ImageMagick (not installed). The Claude Code skills found (adamlyttleapps, UmeshOnAI, hypersocialinc) either push the picture through an image-generation model or scaffold their own Next.js app; none fit.

Least work: a slide renderer in the same shape as the website's `tools/og-card/` (an HTML page per slide at 1320×2868, headless Chrome, the field evaluated exactly, Clash Display local, raw phone PNGs dropped in). Raw captures come from the existing XCUITest attachments via `xcparse` on the mule simulator. Mac halves are the site's existing popover PNGs.

Where it lives is a lane question. The renderer, fonts and field code sit in the website repo, which is another person's lane. Two clean options: (1) the website person adds `tools/app-store/` next to `tools/og-card/` from a spec; (2) it lives in the phone repo under `scripts/store-shots/` and copies the field evaluator and the font in. (2) keeps it in this seat's lane at the cost of a second copy of `emitters.js`.

Second choice: Sketch with Apple's bezel file, manual per slide. Fine for six slides once; painful per locale.

Upload and metadata: App Store Connect by hand (owner's ruling: ASC is Alec's), or `fastlane deliver` for the folder-to-ASC step only. Limits: name 30, subtitle 30, keywords 100.

## 7. Decisions (Alec, 2026-09-20)

1. First slide: **A, Mirror.** Fold B's menu-bar strip in only if the Mac half reads as "some window" at real size.
2. Phone chassis: **bare rounded screen**, no bezel.
3. Captures: **UI-test-only launch flag** that hides the Demo strip and names the Mac. Reproducible on the mule simulator.
4. Renderer: **phone repo**, `scripts/store-shots/`, with its own copy of the field evaluator and Clash Display.
5. Still open. Listing text conflict: the kit says the phone has no purchase flow; the unmerged `claude/app-store-decisions` ADR says the phone sells the Mac licence as an in-app purchase. Which is true for this submission decides the review notes and the App Privacy "Purchases" answer, not the screenshots.

## 8. Outcome (same day)

Six slides rendered at 1320×2868, dark, from real captures. Slide 1 is the Mirror composite with the Mac on the left (names visible), the phone on the right in front, and no menu bar strip (Alec's pick after seeing both at real size; version 1 with the phone on the left hid the Mac's names, the failure §4 predicted).

What was built to get there:
- Phone repo, branch `claude/store-shots`: `-store-shots` launch argument (demo fleet, Mac named "MacBook Pro", HomePod + Sonos pair playing, no Demo strip, no coach mark, no "Leave demo" row; the flag is `showsDemoAffordances` on the session) and `-store-shots-screen speakers|apps|scenes|sync|connect|settings`. Demo fleet gained "Bedroom HomePod", Apple Music (routed there) and Spotify (routed to the Living Room scene), and a second saved scene "Kitchen". The renderer lives at `scripts/store-shots/`.
- Mac repo, this branch: `AUDIOUT_MOCK_FLEET=store-shots` serves the same fleet to the mock backend for the popover capture; `ios.sh shot --screen NAME` builds Release, pins the status bar to 9:41, and names the PNG after the screen.
- The Mac popover capture is the pinned surface window (red close dot, no arrow), captured with `screencapture` from a `com.audiout.Audiout.shots` build; selection seeded in that id's own Application Support folder (per-id since 2026-08-06, so the old "never seed" trap no longer applies to non-default ids).

Traps met:
- A speaker in the main mix cannot be an app's redirect target (the Mac's one-role rule); Apple Music pointed at a playing HomePod read "Unavailable speaker". Hence Bedroom HomePod.
- `ConnectionController.setOnMacsChanged` replays its empty list to a new handler, wiping an injected Mac; the connect screen skips that replay.
- Headless Chrome renders time out under machine load (load average 289 that afternoon); the deadline in build.sh is 90 s and build-all fails loudly on a missing output.
- Real Apple Music and Spotify icons in the Apps capture came from a stale icon cache on the mule's simulator, not from the app. A clean simulator gives a generic music-note glyph. Shipping real logos needs deliberate seeding, and Spotify's is theirs.

Still open for Alec: hide the two "Not routed" demo rows on the Apps slide under the flag; a gold field for slide 5 (the connect screen paints its own green); the icon question above; the one pre-existing phone test failure (`IntroCardsTests` expects "This iPhone is the ear", shipping copy says "Your phone is the ear"); merging both branches.

## Sources

Apple screenshot specs: https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/ · preview specs: https://developer.apple.com/help/app-store-connect/reference/app-preview-specifications/ · guidelines 2.3.3, 2.3.7, 2.3.10: https://developer.apple.com/app-store/review/guidelines/ · bezels: https://developer.apple.com/design/resources/ · xcparse: https://github.com/ChargePoint/xcparse · frameit iPhone 17 gap: https://github.com/fastlane/fastlane/issues/29920 · skills reviewed: https://github.com/adamlyttleapps/claude-skill-aso-appstore-screenshots, https://github.com/UmeshOnAI/claude-skill-app-store-screenshots, https://github.com/Kronop/vibe-aso
