# Mobile device-list + EQ surfacing — research brief

*Researched 2026-08-23 from public docs, support articles, release notes and press coverage. Every app claim carries a URL. Point-in-time: app UIs move; re-verify before building against a specific detail.*
*Prior brief `dev/notes/competitor-parity-research-2026-08-05.md` covers **feature** parity (delay trim, EQ scope, scenes, Sonos backlash timeline). This one covers **list and EQ presentation** only, and does not repeat it.*

---

## Q1 — Keeping a long device list usable

### The table

| App | Ordering | Favourites / pins | Offline / unavailable | Grouped by room / zone / type | Search / filter | Personalisation | First screen "at a glance" |
|---|---|---|---|---|---|---|---|
| **Sonos, current (87.x, Jul 2026)** | User choice: alphabetical, manual, by frequency of use, or by what's currently playing | Yes — pin rooms to top; can pin all in a custom order | Not documented in the notes; 88.00.43 (Aug 2026) shipped "improved settings experience when players are offline"; products offline **3 months** vanish from the app entirely | Rooms + groups; group icon shows the room count | Dedicated Search tab (returned in 87.00.35) | Sort-by-frequency-of-use and sort-by-playing are explicit options | Bottom tabs Home / System / Search; System tab is the device list | [ecoustics](https://www.ecoustics.com/news/sonos-app-update-2026/) · [Sonos release notes](https://support.sonos.com/en-us/article/release-notes-sonos-app-updates) · [Sonos: products missing](https://support.sonos.com/en-us/article/products-missing-from-the-sonos-app) |
| **Sonos, 2024 redesign (the mistake)** | Fixed; no sorting | No | Rooms silently disappeared/reappeared — a top complaint class | Rooms/Grouping screen reached by tapping the system name top-left, or swiping up the Now Playing bar | Search on home screen; local-library search removed | None | One home screen, "everything at a glance"; tabs deleted | [Sonos: S1/S2 vs new](https://en.community.sonos.com/the-new-sonos-app-229144/differences-between-s1-s2-and-the-new-sonos-app-6891763) · [Sonos: rooms screen](https://en.community.sonos.com/the-new-sonos-app-229144/rooms-grouping-screen-introduction-6891766) · [speakers disappearing](https://en.community.sonos.com/controllers-and-music-services-229131/speakers-keep-disappearing-and-coming-back-6885456) |
| **Sonos, pre-2024 (S1/S2)** | Fixed alphabetical-ish | No | — | Bottom tab bar with a dedicated System tab holding the room list; grouping floated on the Now Playing bar | Own tab | None | Tab bar: you were always one tap from the room list | [Sonos: S1/S2 vs new](https://en.community.sonos.com/the-new-sonos-app-229144/differences-between-s1-s2-and-the-new-sonos-app-6891763) |
| **Apple Home** | Manual — drag to reorder sections, items inside sections, and rooms | Yes — Favorites section on the Home tab, hand-picked | Not documented; unresponsive accessories are shown, not hidden (see Hue) | Rooms, plus a category row (Lights, Security, Climate, Speakers, Water) | Categories act as filters; no prominent search | None automatic — all curation is manual | Home tab: category row, cameras, then Favorites → Scenes → Rooms | [Apple: intro to Home](https://support.apple.com/en-vn/guide/iphone/iph22d98bbca/ios) · [MacRumors: reorganize home view](https://www.macrumors.com/how-to/reorganize-home-view-home-app/) · [MacRumors: favorites](https://www.macrumors.com/how-to/set-homekit-favorites/) |
| **Google Home (2024→Gemini redesign)** | By type inside "Spaces"; favourites in user order | Yes — pin devices, actions, automations to Favorites; Favorites is the **first** thing you see; also a home-screen widget | Devices show an explicit Offline status; no hide-offline control found | Auto-grouped "Spaces" (lights, cameras, Wi-Fi, climate); categories collapsible | Filter chips at the top of feeds (replaced a full-screen filter sheet); "Ask Home" type-ahead: type "lights" or "living room" | Favourites are manual, not learned | Home tab = Favorites, swipe sideways to all devices / dashboards | [blog.google redesign](https://blog.google/products-and-platforms/devices/google-nest/google-home-app-gemini-redesign/) · [9to5: activity filter chips](https://9to5google.com/2024/07/08/google-home-activity-filters-redesign/) · [9to5: Favorites widget](https://9to5google.com/2024/05/28/google-home-favorites-widget-enabled/) · [Nest community tour](https://www.googlenestcommunity.com/t5/Blog/Take-a-visual-tour-of-the-new-Google-Home-app/bc-p/470555) |
| **iOS Control Center AirPlay picker** | Fixed; **no user sort** ("there isn't an option to change the order") | No | Only reachable devices are listed | Selecting 2+ auto-collapses them into one group row labelled with names + "N speakers", with a disclosure arrow to expand | None | None | This device selected at top, then a "Speakers & TVs" heading and the list | [Macworld](https://www.macworld.com/article/344914/how-to-add-multiple-airplay-2-destinations-for-streaming-audio-on-iphone-or-ipad.html) · [Apple discussions: sorting AirPlay list](https://discussions.apple.com/thread/254856365) |
| **Apple Music multi-speaker** | Same picker as above — the AirPlay sheet, with per-device volume sliders that **auto-hide after a few seconds** | No | Same | Same auto-grouping | None | None | Same | [Macworld](https://www.macworld.com/article/344914/how-to-add-multiple-airplay-2-destinations-for-streaming-audio-on-iphone-or-ipad.html) |
| **Spotify Connect picker** | Not documented as user-sortable | No | A device with the app fully closed simply is not listed | No room grouping; Google speaker **groups appear alongside** their member speakers on mobile (desktop hides members) | None documented | Yes — the list is "devices available right now… **plus ones you connected to recently**"; current device highlighted green | Flat device sheet | [Spotify: Using Connect](https://community.spotify.com/t5/FAQs/Using-Connect/ta-p/4964156) · [Spotify: device not listed](https://community.spotify.com/t5/iOS-iPhone-iPad/Spotify-Connect-only-sees-devices-that-have-the-app-open/m-p/5360650/highlight/true) · [Cast group vs members](https://community.spotify.com/t5/Desktop-Windows/Google-Cast-Speakers-Missing-in-Desktop-App-s-Device-List/td-p/5482113) |
| **Denon HEOS** | Rooms tab; no documented reorder | No | Not documented | Rooms; **drag one room onto another to group** (press-hold-drag) | None documented | None | Rooms tab = the device list | [Denon: grouping](https://support-eu.denon.com/app/answers/detail/a_id/24637/~/grouping-denon-home-speakers-in-the-heos-app) |
| **Bose (Bose Music → "Bose app")** | Product list you add/remove products from | No pins documented | Not documented | Per-product screens; group support varies by product | None documented | None | Product list / last product | [Bose app, App Store](https://apps.apple.com/us/app/bose/id1364986984) |
| **Bluesound / BluOS** | Player Drawer lists players and groups; no documented reorder | No | Not documented | Players + Groups + **Fixed Groups** (persistent named groups); GROUP ALL / PAUSE ALL buttons | None documented | None | Player Drawer is a slide-over list of every player/group | [BluOS: player drawer](https://support.bluos.net/hc/en-us/articles/360000206107-How-do-I-view-all-my-BluOS-players-in-the-BluOS-Controller-app-accessing-the-Player-Drawer) · [BluOS: fixed groups](https://support.bluos.net/hc/en-us/articles/360000220107-Creating-Fixed-Groups) · [BluOS: group all](https://support.bluos.net/hc/en-us/articles/360000303468-How-do-I-group-all-my-Players-simultaneously) |
| **Roon Remote** | Zone picker in the footer (bottom-right on phone, next to volume) | No pins documented | Not documented | Zones; grouping only between zones of the same transport (RAAT, AirPlay, Sonos, Chromecast, KEF…) | None documented | None | Zone picker is a persistent footer control, not a screen | [Roon: zones](https://help.roonlabs.com/portal/en/kb/articles/zone) · [Roon: grouping FAQ](https://help.roonlabs.com/portal/en/kb/articles/faq-how-do-i-link-zones-so-they-play-the-same-thing-simultaneously) |
| **Philips Hue** | Rooms on the Home tab | Home tab is room-first | Unreachable lights are shown as **"unreachable"**, not hidden — and the state is laggy, so users see false unreachables | Rooms / zones | Not documented | None | Home tab = rooms | [Hue unreachable, TrustedReviews](https://www.trustedreviews.com/how-to/fix-philips-hue-lights-unreachable-error-3631990) · [online-tech-tips](https://www.online-tech-tips.com/philips-hue-lights-unreachable-7-things-to-try/) |
| **Home Assistant Companion** | Dashboard-defined | User-built dashboards are the favourites mechanism | Unavailable entities stay visible and clutter dashboards; hiding is unreliable and users resort to `auto-entities` cards to list them | Areas exist, but **you cannot filter a dashboard view by area or by device/entity** | Per-dashboard, hand-built | None | Whatever the user built | [HA frontend #28480](https://github.com/home-assistant/frontend/issues/28480) · [hidden entities not hidden #22040](https://github.com/home-assistant/frontend/issues/22040) · [listing unavailable entities](https://community.home-assistant.io/t/list-unavailable-entities-sometimes-not-working/722094) |
| **Amazon Alexa (2023 redesign)** | Devices page sorts by **newest, oldest, or alphabetically** | Yes — Favorites on the Home tab (Echos, lights, plugs, switches, locks, cameras, thermostats, sensors) | Not documented | Filter by device type; groups; **Map View** — pin devices onto a scanned floor plan | Both: type filter **and** search by name/keyword | Pre-redesign home was "Most Relevant"/"Recently Used"; the redesign replaced that with explicit Favorites | Home tab: Favorites + a Home Shortcuts category bar; goal stated as "one to two taps" | [aboutamazon](https://www.aboutamazon.com/news/devices/alexa-app-redesign) · [9to5google](https://9to5google.com/2023/12/01/amazon-alexa-new-app/) |
| **Airfoil Satellite (iOS)** | Not documented | No | No | Airfoil for Mac has Speaker Groups; the remote's own grouping UI is not documented | No | No | "Toggle outputs on and off, adjust volumes, and even switch sources" — a remote for the Mac's list. Old separate *Airfoil Remote* app was retired and folded into Satellite | [Rogue Amoeba: Satellite iOS](https://rogueamoeba.com/airfoil/satellite/ios/) · [Airfoil Remote retired](https://rogueamoeba.com/company/lists/archives.php?showArticle=20130716-airfoilremote-400) |
| **Tailscale iOS** (non-audio fleet) | Device list; sort/limit exposed via the filter API | No | **Explicit filter by connection status: Is Online / Is Offline**, plus filter by name | No | Yes — name filter | No | Machine list; **long-press a machine → context menu** (copy IPv4, ping) | [Tailscale iOS blog](https://tailscale.com/blog/reimagining-tailscale-for-ios) · [Tailscale shortcuts docs](https://tailscale.com/docs/features/mac-ios-shortcuts) |
| **UniFi iOS** (non-audio fleet) | *Thin evidence — could not verify the in-app list UI from public docs.* Verified only: the app added **Spotlight search for sites and devices**; the web/tools side filters by type, model, site, status (online/offline/adopting), firmware | — | — | — | Spotlight + type/status filters on the tools side | — | — | [UniFi iOS 10.37 release](https://community.ui.com/releases/UniFi-iOS-10-37-0/89f1b094-15dc-46da-b65d-1a1573e5259a) · [Art of WiFi search tool](https://artofwifi.net/unifi-device-search-tool) |

### What the Sonos 2024 redesign got wrong (the loudest natural experiment)

1. **It deleted the tab bar.** One "everything at a glance" home screen replaced dedicated tabs; the room list moved behind a system-name button top-left or a swipe-up on the Now Playing bar ([Sonos](https://en.community.sonos.com/the-new-sonos-app-229144/differences-between-s1-s2-and-the-new-sonos-app-6891763)). Tabs came back in July 2026 as Home / System / Search ([release notes 87.00.35](https://support.sonos.com/en-us/article/release-notes-sonos-app-updates)).
2. **Volume moved.** Per-room volume was no longer on the room row; you hold the group volume slider to reveal per-room sliders. Users filed it as missing ([Sonos community](https://en.community.sonos.com/controllers-and-music-services-229131/volume-control-missing-from-rooms-in-new-app-6894573)), and slider precision drew its own complaints ([too sensitive](https://en.community.sonos.com/controllers-and-music-services-228995/slider-in-ios-far-too-sensitive-and-lower-volumes-are-impossible-6923087)).
3. **Ordering was fixed and unsortable** in a screen that scales with household size — press called finding a speaker "sorting through airport departure boards" ([ecoustics](https://www.ecoustics.com/news/sonos-app-update-2026/)).
4. **Rooms vanished and reappeared**, so users could not trust the list ([Sonos community](https://en.community.sonos.com/controllers-and-music-services-229131/speakers-keep-disappearing-and-coming-back-6885456)).
5. Removed features (queue edit, alarms, local-library search) and no screen-reader support ([Digital Trends](https://www.digitaltrends.com/home-theater/sonos-app-redesign-2024-work-in-progress/), [What Hi-Fi](https://www.whathifi.com/news/sonos-ceo-apologises-for-the-app-redesign-that-deleted-key-features)); the CEO apologised and the CEO later resigned ([What Hi-Fi](https://www.whathifi.com/news/sonos-boss-resigns-following-disastrous-app-redesign)).

The 2026 repair is exactly the list of things this brief recommends stealing: tabs back, sorting (alphabetical / manual / **frequency of use** / **currently playing**), pinning, better volume ([ecoustics](https://www.ecoustics.com/news/sonos-app-update-2026/), [Engadget](https://www.engadget.com/2216827/sonos-app-update-tab-navigation-speaker-sorting-and-more/)).

---

## Q2 — Where EQ lives without crowding the control screen

| App | Where EQ lives | Depth of control | "Modified" indicator on the row? | Per-device vs global |
|---|---|---|---|---|
| **Sonos** | Settings → pick a product under *Your System* → **Sound → EQ**. Optional **"EQ Shortcut"** in App Preferences puts EQ one tap from the volume slider during playback | Bass, Treble, Balance (only Five, Port, Amp, Play:5 g2, Play:3, Connect, Connect:Amp, Amp Multi), Loudness toggle (on by default) | None found | Strictly per product; no group EQ documented — [Sonos](https://support.sonos.com/en-us/article/adjust-the-bass-treble-balance-and-loudness) |
| **Bose (smart speakers)** | Bose app → **Audio** button → Audio Settings | Bass / Treble ± in steps of 10, range −100…100. Many Bose speakers have **no EQ at all** ("Equalization, like bass or treble, is not adjustable on your product") | None found | Per product — [Bose HS500 tone controls](https://www.bose.ie/en_ie/support/articles/HC2475/productCodes/bose_home_speaker_500/article.html.search.html) · [SoundLink Micro: none](https://support.bose.com/s/article/soundlink-microbluetooth-speaker-too-much-bass-or-too-little-treble-from-product?language=en_US) |
| **Bose (earbuds/headphones)** | Main settings screen → **"EQ" tile** | Presets + 3 movable bands (5-band on QC Ultra) | None found | Per product — [Bose Ultra Open EQ](https://www.boseapac.com/en_in/support/articles/HC2718/productCodes/ULT-HEADPHONEOPN/article.html) · [SoundGuys](https://www.soundguys.com/what-do-the-bose-quietcomfort-ultra-earbuds-2nd-gens-eq-presets-sound-like-140870/) |
| **Sony Headphones / Sound Connect** | My Device tab → **Settings → Sound tab → Equalizer** (scroll) | 5 bands + Clear Bass, presets, **two custom slots**; menu varies by model | Not verified | Per connected device — [Sony](https://www.sony.ca/en/electronics/support/audio-video-headphones/articles/00286844) |
| **JBL Portable / JBL One** | A dedicated EQ section/icon in the product screen | 3-band (bass / mid / treble) + presets on Flip 6, Charge 5, Xtreme 3, Boombox 3 | None found | Per product — [JBL One custom EQ](https://support.jbl.com/howto/jbl-one-app-custom-equalization-settings-us/000037155.html) |
| **Apple Music** | **Not in the app at all** — iOS Settings → Music → Playback → EQ | 23 fixed presets, no manual bands, no custom saves | n/a | Global to the Music app; does not affect other apps — [Apple discussions](https://discussions.apple.com/thread/253610219) · [MacObserver](https://www.macobserver.com/news/best-apple-music-equalizer/) |
| **Spotify** | In-app **Settings → Playback → Equalizer** (never on the player) | On/off toggle, presets, plus manual 6-band (16 Hz–15 kHz) on iOS | No | Global to the app, not per Connect device — [Spotify](https://support.spotify.com/us/article/equalizer/) |
| **Bluesound / BluOS** | Players tab → the player's **⋯ context menu → Audio Settings → Tone Controls** (toggle to reveal sliders) | Bass + Treble sliders, real-time, "Reset All" returns to 0 dB and disables. Enabling drops volume slightly for headroom | The toggle state is the indicator, inside the sheet only | Per player — [BluOS tone controls](https://support.bluos.net/hc/en-us/articles/360000303168-How-do-I-adjust-Bass-and-Treble-tone-controls) |
| **Denon HEOS** | Settings → **My Devices** → speaker → **EQ**; Denon also documents reaching tone controls **from the Now Playing screen** so you don't walk the settings tree | Treble + Bass sliders + Reset | None found | Per speaker — [HEOS manual](https://manuals.denon.com/HEOS1/ALL/en/OKNRSYzzmhmttk.php) · [Denon support](https://support-uk.denon.com/app/answers/detail/a_id/3759/~/how-to-adjust-the-bass-&-treble-of-my-heos-device-using-the-heos-app.) |
| **Roon** | **Long-press / right-click the zone picker** → zone settings, device setup, DSP | Full DSP engine (parametric EQ, convolution, headroom, volume levelling, limits) per zone | **Yes — the signal-path light**: purple = lossless/untouched, **blue = "Enhanced", i.e. user DSP is active**, green = high quality, yellow = lossy. Tap it for the full chain | Per zone — and **DSP is disabled while a zone is grouped** for AirPlay/Sonos/Chromecast/KEF/Squeezebox/Meridian/Devialet zones — [Roon: zones](https://help.roonlabs.com/portal/en/kb/articles/zone) · [signal path](https://blog.roonlabs.com/signal-path/) · [DSP disabled in groups](https://help.roonlabs.com/portal/en/kb/articles/dsp-engine-disabled-during-zone-grouping) |
| **Marshall Bluetooth** | Preset picker in the product screen; **"Custom"** opens the bands. The hardware **M-button** cycles three EQ presets | Presets + custom 5-band | Not verified | Per product — [Marshall](https://www.marshall.com/us/en/support/speakers/learn/app-marshall-bluetooth) · [Major V custom preset](https://www.manualslib.com/how-to/4066297/guide-to-creating-a-custom-equalizer-preset-for-marshall-major-v.html) |
| **Ultimate Ears BOOM** | In-app EQ screen | Presets (Bass Jump, Game/Cinema, Cramped spaces…) + custom 5-band | Not verified | Per speaker — [Ultimate Ears apps](https://www.ultimateears.com/en-us/discover/c/apps) |
| **Beats (Beats Pill app)** | **No EQ** — reviewers/users request one | n/a | n/a | n/a — [Beats Pill on the App Store](https://apps.apple.com/us/app/beats-pill/id1005829608) |

**The three shapes, generalised:** (a) EQ is *always* one level down from the control surface — a settings tree, a per-device detail sheet, or a context menu; nobody puts bands on the list row. (b) The depth ladder is presets → 2–3 knobs → N bands, and mass-market speaker apps stop at 2–3 knobs. (c) Only Roon signals "this output is being processed" outside the EQ screen, and it does it with a **one-glyph colour state**, not a badge full of numbers.

**Honest gap:** I could not verify *any* surveyed app showing a per-row "EQ modified" badge in a device list. Roon's signal-path light is the closest verified analogue, and it lives on the now-playing footer, not on a device row.

---

## Q3 — Patterns worth stealing, ranked

Fit key: **✅ take** · **🟡 take with changes** · **⛔ skip**.

### 1. Sort control with "recently used" and "currently playing" as options ✅
- **Who:** Sonos 87.x (alphabetical / manual / frequency of use / currently playing) — [ecoustics](https://www.ecoustics.com/news/sonos-app-update-2026/); Alexa (newest/oldest/alphabetical) — [aboutamazon](https://www.aboutamazon.com/news/devices/alexa-app-redesign); Spotify Connect implicitly (available + recently connected) — [Spotify](https://community.spotify.com/t5/FAQs/Using-Connect/ta-p/4964156).
- **Solves:** a list that scales with household size stops being a fixed alphabetical wall.
- **Failure mode in the wild:** Sonos shipped *no* sort for two years and users compared the list to airport departure boards.
- **Fit:** Audiouter already sorts PLAYING first structurally — the missing half is ordering *inside* READY. Phone-local preference, no protocol change.

### 2. Pin / favourite to the top ✅
- **Who:** Sonos (pin rooms, or pin all in a custom order) — [ecoustics](https://www.ecoustics.com/news/sonos-app-update-2026/); Google Home Favorites as the first screen — [blog.google](https://blog.google/products-and-platforms/devices/google-nest/google-home-app-gemini-redesign/); Alexa Favorites — [aboutamazon](https://www.aboutamazon.com/news/devices/alexa-app-redesign); Apple Home Favorites — [MacRumors](https://www.macrumors.com/how-to/set-homekit-favorites/).
- **Solves:** the 3 speakers you actually use stay above the fold when Cast doubles the list.
- **Failure mode:** Apple Home's favourites are *entirely* manual, so a household that never curates gets no benefit.
- **Fit:** pin state is a pure UI preference — phone-local, no protocol change. Trailing accessory or long-press to set. Pins must sort *within* PLAYING/READY, never above a playing speaker.

### 3. Long-press row → detail sheet (EQ, delay, info) ✅
- **Who:** Roon (long-press the zone picker → zone settings / device setup / DSP) — [Roon](https://help.roonlabs.com/portal/en/kb/articles/zone); Tailscale (long-press machine → context menu) — [Tailscale](https://tailscale.com/blog/reimagining-tailscale-for-ios).
- **Solves:** puts a whole second control surface behind a gesture that costs zero pixels.
- **Failure mode:** discoverability — long-press is learned by accident; guidance says pair it with a visible affordance ([context-menu discoverability](https://www.mikegopsill.com/posts/swiftui-context-menus/)).
- **Fit:** long-press is one of Audiouter's three free gestures and the row is already a fader, so a *tap* target for detail is unavailable. Pair it with pattern 4 so it is not the only way in.

### 4. Trailing ⋯ accessory → per-device sheet ✅
- **Who:** BluOS: Players tab → player's ⋯ → Audio Settings → tone controls — [BluOS](https://support.bluos.net/hc/en-us/articles/360000303168-How-do-I-adjust-Bass-and-Treble-tone-controls).
- **Solves:** the visible half of pattern 3 — a discoverable door to per-device settings that does not steal the row's drag area.
- **Failure mode:** a trailing control on a full-width fader row can steal drag-start touches; needs a real hit-target carve-out.
- **Fit:** the trailing accessory is explicitly free in Audiouter's gesture budget. This is the single best-fit pattern in the brief.

### 5. Opt-in EQ shortcut from the volume control ✅
- **Who:** Sonos "EQ Shortcut" — a toggle in App Preferences that puts EQ one tap from the volume slider during playback — [Sonos](https://support.sonos.com/en-us/article/adjust-the-bass-treble-balance-and-loudness); HEOS documents tone controls reachable from Now Playing "so you no longer need to go through the entire Settings menu" — [Denon](https://support-uk.denon.com/app/answers/detail/a_id/3759/~/how-to-adjust-the-bass-&-treble-of-my-heos-device-using-the-heos-app.).
- **Solves:** power users get EQ in one tap; everyone else never sees it. Opt-in means the default stays uncluttered.
- **Failure mode:** none observed; it is off by default, which is the whole trick.
- **Fit:** ✅ — a Settings toggle is cheap and matches "tone lives one level down, unless you asked otherwise".

### 6. A processing indicator that is one glyph, not a readout ✅
- **Who:** Roon's signal-path light: purple = untouched/lossless, **blue = user DSP active** — [Roon](https://blog.roonlabs.com/signal-path/).
- **Solves:** answers "why does this room sound different?" without spending a row on EQ values.
- **Failure mode:** Roon's colours need a legend — users ask in the forums what blue means ([community](https://community.roonlabs.com/t/signal-path-not-purple/127989/2)).
- **Fit:** 🟡 → ✅ with a change: use one small mark plus an accessible label, not a colour code. Non-flat EQ **and** the Cast ~2 s delay are both "this output is not the plain path" states this glyph can carry. Note: no surveyed app was verified doing this on a *device row* — this would be a considered extension, not a copy.

### 7. Offline devices: keep visible, mark clearly, prune only after a long grace ✅
- **Who:** Sonos removes a product only after **3 months** offline — [Sonos](https://support.sonos.com/en-us/article/products-missing-from-the-sonos-app); Hue marks lights "unreachable" instead of hiding — [TrustedReviews](https://www.trustedreviews.com/how-to/fix-philips-hue-lights-unreachable-error-3631990); Spotify silently drops a device the moment its app closes, which reads as broken — [Spotify](https://community.spotify.com/t5/iOS-iPhone-iPad/Spotify-Connect-only-sees-devices-that-have-the-app-open/m-p/5360650/highlight/true).
- **Solves:** users trust a list that does not rearrange itself behind their back.
- **Failure mode:** both extremes are bad — vanishing rooms were a top Sonos complaint; permanently visible dead entities are the top Home Assistant dashboard complaint ([#28480](https://github.com/home-assistant/frontend/issues/28480)).
- **Fit:** Audiouter already has an UNAVAILABLE section — this validates it. The refinement is a grace policy owned by the Mac, not by the phone (the phone renders the snapshot).

### 8. Collapse (don't delete) the section you rarely need ✅
- **Who:** Google Home collapses device categories "instead of scrolling" — [Nest community](https://www.googlenestcommunity.com/t5/Blog/Take-a-visual-tour-of-the-new-Google-Home-app/bc-p/470555).
- **Solves:** UNAVAILABLE stops eating a screenful once Cast doubles the list.
- **Failure mode:** a collapsed section that hides *state changes* (a speaker coming back) needs a count in the header.
- **Fit:** ✅ — collapse UNAVAILABLE by default with "UNAVAILABLE (4)" in the header; phone-local state. Fits the fixed-label console voice.

### 9. Filter chips ✅
- **Who:** Google Home replaced a full-screen filter sheet with three chips at the top of the feed — [9to5google](https://9to5google.com/2024/07/08/google-home-activity-filters-redesign/); Alexa filters devices by type — [aboutamazon](https://www.aboutamazon.com/news/devices/alexa-app-redesign); Tailscale filters by **Is Online / Is Offline** — [Tailscale](https://tailscale.com/docs/features/mac-ios-shortcuts).
- **Solves:** "show me only the Cast boxes" / "only what's playing" in one tap, no mode change.
- **Failure mode:** chips are a header that never scrolls away — real cost on a tight screen; and a filter left on silently is a lie about the system.
- **Fit:** 🟡 — transport chips (AirPlay / Bluetooth / Cast) are the natural axis once Cast lands, but only if the chip row is scroll-away and resets each launch.

### 10. Search that appears only past N devices 🟡
- **Who:** Sonos gave search its own tab in 87.x — [release notes](https://support.sonos.com/en-us/article/release-notes-sonos-app-updates); Alexa searches devices by name/keyword — [aboutamazon](https://www.aboutamazon.com/news/devices/alexa-app-redesign); Google Home's "Ask Home" type-ahead surfaces devices by name or room — [blog.google](https://blog.google/products-and-platforms/devices/google-nest/google-home-app-gemini-redesign/); UniFi indexes devices into iOS Spotlight — [UniFi iOS](https://community.ui.com/releases/UniFi-iOS-10-37-0/89f1b094-15dc-46da-b65d-1a1573e5259a).
- **Solves:** the 20-speaker household; useless for the 5-speaker one.
- **Failure mode:** a permanent search field on a short list is pure overhead (and iOS `.searchable` reserves vertical space).
- **Fit:** 🟡 — worth it only gated on device count (say ≥12), and it competes with pinning for the same job. Rank below pins.

### 11. Auto-collapse a multi-device selection into one group row 🟡
- **Who:** iOS AirPlay picker collapses 2+ selected speakers into one row labelled "…N speakers" with a disclosure arrow to expand — [Macworld](https://www.macworld.com/article/344914/how-to-add-multiple-airplay-2-destinations-for-streaming-audio-on-iphone-or-ipad.html); Sonos shows the room count on the group icon — [release notes](https://support.sonos.com/en-us/article/release-notes-sonos-app-updates).
- **Solves:** the PLAYING section stays short no matter how many speakers are live.
- **Failure mode:** hides exactly the per-device volume users came for — the Sonos "hold the group slider to reveal room sliders" complaint class ([Sonos community](https://en.community.sonos.com/controllers-and-music-services-229131/volume-control-missing-from-rooms-in-new-app-6894573)).
- **Fit:** 🟡 — Audiouter's Mac already owns the group concept; a *collapsible* group row is fine, an auto-collapsing one that buries faders is not.

### 12. GROUP ALL / one-tap everywhere as a header action ✅
- **Who:** BluOS GROUP ALL / PAUSE ALL on the Players screen — [BluOS](https://support.bluos.net/hc/en-us/articles/360000303468-How-do-I-group-all-my-Players-simultaneously); Google Home's device sheet has large "Select all" / "Clear all" — [Nest community](https://www.googlenestcommunity.com/t5/Blog/Take-a-visual-tour-of-the-new-Google-Home-app/bc-p/470555).
- **Solves:** the two most common bulk intents without a multi-select mode.
- **Failure mode:** a destructive "stop everything" next to a constructive "play everywhere" invites mis-taps.
- **Fit:** ✅ for a **stop-all** affordance (it is the panic button live audio needs, and it is already Audiouter's mute/master ethos); 🟡 for play-everywhere, which the Mac's saved groups already cover.

### 13. Drag one row onto another to group 🟡
- **Who:** HEOS: press-hold a room, drag onto a playing room, release — [Denon](https://support-eu.denon.com/app/answers/detail/a_id/24637/~/grouping-denon-home-speakers-in-the-heos-app).
- **Solves:** grouping with no extra screen.
- **Failure mode:** collides with every other gesture on a scrolling list of faders.
- **Fit:** ⛔ for Audiouter — horizontal drag is the fader, vertical is the scroll. No room.

### 14. Spatial / map view of devices ⛔
- **Who:** Alexa Map View — scan a floor plan, pin devices onto it — [aboutamazon](https://www.aboutamazon.com/news/devices/alexa-app-redesign).
- **Solves:** "which speaker is the one in the kitchen" without naming discipline.
- **Failure mode:** requires LiDAR-class scanning and constant upkeep; the payoff is recognition, which a good name already gives.
- **Fit:** ⛔ — enormous for the benefit; Audiouter's names come from the Mac's snapshot anyway.

### 15. Show a group *and* its members in the same list ⛔
- **Who:** Spotify mobile lists a Google speaker group alongside its member speakers; desktop hides the members — [Spotify community](https://community.spotify.com/t5/Desktop-Windows/Google-Cast-Speakers-Missing-in-Desktop-App-s-Device-List/td-p/5482113).
- **Solves:** nothing — it is the artefact of two device sources being merged.
- **Failure mode:** doubles the list and makes "which one do I tap" ambiguous.
- **Fit:** ⛔ — a live warning for Cast: a Cast speaker group and its members must not both appear as rows.

---

## Anti-patterns to avoid (evidence-backed)

| Anti-pattern | Evidence | Why it burns |
|---|---|---|
| **Deleting the tab bar for one "at a glance" screen** | Sonos 2024 removed tabs and buried the room list behind a system-name button / swipe-up; tabs returned July 2026 — [Sonos](https://en.community.sonos.com/the-new-sonos-app-229144/differences-between-s1-s2-and-the-new-sonos-app-6891763), [release notes](https://support.sonos.com/en-us/article/release-notes-sonos-app-updates) | "Fewer screens" measured on the happy path becomes "more taps" on the frequent one. Sonos's own defence — that the new flow "takes less tapping" — did not survive contact with users |
| **Moving per-device volume behind a hold gesture** | Sonos: hold the group slider to reveal per-room sliders; users reported volume as *missing* — [Sonos community](https://en.community.sonos.com/controllers-and-music-services-229131/volume-control-missing-from-rooms-in-new-app-6894573) | Volume is the reason the screen was opened. Directly contradicts Audiouter's "mute and master stay one gesture away" |
| **Letting devices silently vanish** | Sonos rooms disappearing/reappearing — [community](https://en.community.sonos.com/controllers-and-music-services-229131/speakers-keep-disappearing-and-coming-back-6885456); Spotify drops a device the instant its app closes — [community](https://community.spotify.com/t5/iOS-iPhone-iPad/Spotify-Connect-only-sees-devices-that-have-the-app-open/m-p/5360650/highlight/true) | A list that reorders itself unprompted destroys trust faster than any missing feature. Cast's ~8 s first-play wait makes flicker-then-vanish especially likely — hold, mark, then prune |
| **Unavailable items with nowhere to go** | Home Assistant: unavailable entities stay on dashboards, hiding is unreliable, and views can't be filtered by area — [#28480](https://github.com/home-assistant/frontend/issues/28480), [#22040](https://github.com/home-assistant/frontend/issues/22040) | The mirror image of vanishing: dead rows accumulate until the list is noise. Needs a collapsed section with a count, not a hide-forever switch |
| **Fixed ordering on a list that scales with the household** | Sonos had no sort until 87.x — "airport departure boards" — [ecoustics](https://www.ecoustics.com/news/sonos-app-update-2026/) | Alphabetical is fine at 5 devices and hostile at 20. Cast roughly doubles the list — this is the anti-pattern most likely to bite Audiouter next |
| **Auto-hiding controls on a timer** | The iOS AirPlay picker's per-speaker volume sliders disappear after a few seconds — [Macworld](https://www.macworld.com/article/344914/how-to-add-multiple-airplay-2-destinations-for-streaming-audio-on-iphone-or-ipad.html) | Time-based disappearance is unpredictable and unreachable for slow interaction; a state that vanishes on its own can't be relied on mid-adjustment |

---

## Not verified / open

- **Per-row "EQ modified" badge:** no surveyed app verified doing it. Roon's signal-path light is the nearest analogue and lives on the footer.
- **UniFi iOS list UI:** public docs cover the tools/web side and one release note (Spotlight search); the in-app list, filters and offline handling could not be verified.
- **Sonos offline presentation today:** release notes cite an "improved settings experience when players are offline" (88.00.43, 11 Aug 2026) but do not describe the list treatment.
- **Bose product-switcher UI:** the App Store listing confirms a product list; no public description of a carousel or switcher was found.
- **HEOS / BluOS / Roon room ordering:** no evidence of user-controlled reordering in any of them.
- **Airfoil Satellite iOS list layout:** the product page states outputs can be toggled and volumes adjusted, but does not describe list ordering, favourites or offline handling.
