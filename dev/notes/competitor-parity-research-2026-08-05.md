# Competitor & feature-parity research — synthesis brief

*Roadmap item 003. Synthesized 2026-08-05 from 5 parallel researcher sweeps.
Raw findings (80, with per-finding evidence URLs): `dev/notes/competitor-sweeps-raw-2026-08-05.json`.*

---

## 1. Method + sources snapshot

Five families swept in parallel on 2026-08-05:

1. **Sonos app + ecosystem** — the 2024–2026 app-rewrite backlash, group/volume/room UX, Trueplay/EQ (community forums, press coverage, official support docs).
2. **Rogue Amoeba suite** — Airfoil, SoundSource (incl. SoundSource 6, Dec 2025), Loopback, Audio Hijack (product pages, release notes, KB, App Store reviews).
3. **Open-source multiroom** — OwnTone, shairport-sync, snapcast, LMS/squeezelite (GitHub issue trackers, wikis, community forums).
4. **Native platform baselines** — macOS/iOS AirPlay UI limits, Windows/Android equivalents, BubbleUPnP (Apple support docs, Apple/MacRumors discussion threads, developer statements).
5. **Small-vendor casting peers** — Google Home/Cast groups, AirParrot, TuneBlade, Porthole (release notes, help docs, reviews, Home Assistant community).

**Caveat:** all web findings are point-in-time as of 2026-08-05. Competitor release notes, forum threads, and shipped feature sets move; re-verify any specific claim before building against it. Audiout status below is verified against `docs/SPEC.md`, `ROADMAP.jsonl`, and project memory — not against the researchers' guesses (corrections noted inline, summarized in §6).

---

## 2. Deduped findings table

80 raw findings dedupe to the rows below (cross-family duplicates merged — e.g. per-device delay trim appeared in 4 of 5 families). Status column is spec-verified. Evidence cites the strongest one or two sources; the raw JSON has the full set.

**Demand key:** `table-stakes` = shipped broadly, users assume it · `differentiator` = shipped by some, marketed · `requested` = asked-for, unbuilt upstream · `complaint` = shipped badly or removed, users loud about it.

### Where Audiout already has parity (or better)

| Feature | Who ships / who asks | Demand | Audiout status | Evidence |
|---|---|---|---|---|
| Multi-speaker synced system audio from the menu bar | Nobody natively on macOS; Apple confirms the OS can't | complaint | **HAS — core premise** | support.apple.com/105068; macrumors 2350418; snapcast #688/#750 users beg for exactly this |
| Fast, reliable group/per-device volume | Sonos (badly, post-rewrite); SonoPhone won users by being fast | complaint | **HAS** — DACP absolute setproperty merged, speaker-input responsiveness live-verified | Sonos community 6905208 (3–20 s lag); techradar "biggest remaining problem" |
| Saved groups with remembered per-device volumes | Sonos shipped saved groups only in 2025 after years of requests | table-stakes | **HAS** — v1 core in SPEC §3; groups persist per-device volume + membership | support.sonos.com saved-groups; Sonos community 6905089 |
| Coherent master-volume model (no 100% blasts) | OwnTone gets this wrong and users complain | complaint | **HAS** — Main × Group × Device gain chain, merged (volume-decoupling) | owntone #1011, #1077, #1657 |
| Group master + per-speaker expansion | Sonos (patented the interaction) | table-stakes | **HAS** — group rows with master slider + animated expansion, SPEC §9 | docs.sonos.com/docs/volume; patent 12260064 |
| Speaker hardware buttons/remote adjust app volume | TuneBlade added a DACP server after complaints; OwnTone users still ask | complaint / requested | **HAS** — merged, live-verified | tuneblade.com/releaseNotes 1.6.0; owntone #1094 |
| Per-app routing (app → speakers, rest local) | SoundSource 6 shipped it Dec 2025 ($49); no native macOS support | requested → now differentiator | **HAS** — shipped, incl. mixing overlapping routes per speaker | weblog.rogueamoeba.com 2025/12/04; SPEC §3 v2 |
| System-wide selectable output group (aggregate device) | SoundSource 6 custom output groups | differentiator | **HAS** — Wave 3 public "Audiout" aggregate, live-verified; seamless AirPlay-exclusivity handoff built (unmerged) | rogueamoeba.com/soundsource/whatsnew.php |
| Fully local control, no cloud | Sonos rewrite's cloud round-trip drove users away | complaint | **HAS — inherent** | theregister.com 2024/05/20; Sonos community 6904138 |
| No driver/kext install friction | Rogue Amoeba's ACE was their biggest support burden for years | complaint | **HAS** — native process-tap API, TCC prompt only | rogueamoeba KB ACE-BigSur-Install-Troubleshooting |
| Lossless on the wire | Audiophiles loudly complain AirPlay 2 senders silently transcode to AAC-256 | complaint | **HAS (mechanism)** — vendored sender encodes ALAC (`airplay.c` `alac_encode`, send path). No user-facing codec indicator. | audiophilestyle.com "Lossless Mess Part 2"; darko.audio 2023/10 |
| Zero-config Spotify capture | Linux users accept librespot/named-pipe pain for the same outcome | requested | **HAS** — per-app tap of the Spotify app | owntone #295 + docs/integrations/spotify.md |
| Better-than-benchmark latency vs cast tools | BubbleUPnP admits 5–8 s (Chromecast) to 12–14 s (UPnP) delay | complaint | **HAS** — real-time AP2 path, ~2 s sync buffer | bubblesoftapps.com tips; groups.google.com YtGjIfxvzG0 |
| Synced local playback (Mac speakers in the group) | BubbleUPnP can't sync multiple renderers at all | complaint | **HAS (built)** — synced-local waves built; one live-blocking bug open | groups.google.com XKGGYl0FKVM |

### Gaps — candidates (assessed in §3)

| Feature | Who ships / who asks | Demand | Audiout status | Evidence |
|---|---|---|---|---|
| Per-device delay/latency trim | Google Home ships it; TuneBlade shipped ±500 ms; snapcast per-client latency is table stakes; Airfoil users ask; OwnTone users ask | table-stakes (4 of 5 families) | **MISSING** — global buffer-ms setting only, no per-device trim | support.google.com/googlecast/6318642; tuneblade releaseNotes 1.5.1; snapcast README; forked-daapd #560; rogueamoeba KB AudioDelaysAndSync |
| Per-device EQ (bass/treble/balance/loudness) | Sonos, SoundSource (per-app 10-band), Airfoil (10-band), TuneBlade (3-band); snapcast users beg (#917, offered a PR) | table-stakes in the niche + requested upstream | **MISSING — already SPEC v2** ("per-device EQ / L-R balance", full window) | rogueamoeba.com/soundsource controls-applications; snapcast #917/#1230; support.sonos.com bass-treble article |
| Shortcuts / automation actions | SoundSource 6 expanded Shortcuts actions; TuneBlade's HTTP API kept 3 community HA integrations alive for 4+ years; snapcast/OwnTone JSON APIs are load-bearing | requested (strongest small-vendor demand signal) | **MISSING** — companion protocol is private, no Shortcuts/App Intents, no public API | community.home-assistant.io/t/103642; rogueamoeba soundsource/whatsnew; snapcast README JSON-RPC |
| Sleep timer (+ fade) | Sonos stripped it in 2024; loudly mourned until restored | complaint | **MISSING — already SPEC "Later"** (sleep timer + fade in/out) | digitaltrends.com sonos-app-redesign; soundguys.com 123602 |
| Scenes / full-setup snapshots | SoundSource 6 "Quick Configs"; Sonos users have begged for volume-snapshot scenes for years (unbuilt) | differentiator + requested | **PARTIAL** — groups snapshot per-device volumes; per-app routes/EQ/whole-state not included | rogueamoeba soundsource/whatsnew; Sonos community 5107580, 6851053 |
| Per-speaker auto-connect on appearance | TuneBlade per-receiver auto-connect + force-reconnect for always-on setups | differentiator | **PARTIAL** — SPEC v2 auto-reconnect for groups; no per-speaker "connect when it appears" toggle | tuneblade releaseNotes 1.2.0, 1.3.1 |
| Manual add receiver by IP:port | TuneBlade (motivated by broken mDNS networks) | complaint (recurring support-load theme) | **MISSING** — Bonjour-only discovery | tuneblade releaseNotes 1.2.0 |
| Per-device max-volume limit / settings lock | SoundSource 6 | differentiator | **MISSING** — adjacent: roadmap 018's anti-blast open question | rogueamoeba soundsource/whatsnew |
| One-tap "everywhere" / select-all | Sonos party mode treated as baseline | table-stakes | **PARTIAL** — a saved all-speakers group does it; no built-in select-all control | Sonos community 5451386 |
| Discovery grace (speakers never silently vanish) | Sonos rooms vanishing daily was a top-3 backlash theme | complaint | **PARTIAL** — Bonjour discovery + sticky-failed states exist; no audited keep-visible-but-unreachable grace policy | Sonos community 6885456, 6890530 |
| Connection standby (silence → idle stream, resume on audio) | TuneBlade (refined over 4 releases) | differentiator | **MISSING** — and roadmap 017 shows the silence path currently has a *bug* (starvation skew) | tuneblade releaseNotes 1.2.0–1.3.2; ROADMAP 017 |
| Bluetooth outputs synced with network speakers | Airfoil ships BT-in-group; every OSS project has an open wound (BT drift unsolved upstream) | complaint / differentiator | **MISSING (planned)** — roadmap 004 + PLAN-UNIVERSAL-SYNC designed, zero BT code | owntone #543; snapcast #50/#912; rogueamoeba.com/airfoil |
| Chromecast / Google Cast output | Airfoil + AirParrot ship cross-protocol groups (fragile in practice per reviews) | differentiator | **MISSING (planned)** — roadmap 006 scoping brief | rogueamoeba.com/airfoil; airsquirrels.com/airparrot |
| iOS companion remote | Airfoil Satellite, TuneBlade remote, Porthole remote — all three peers shipped one | table-stakes | **PARTIAL** — built on branch, unmerged, live-gated | rogueamoeba.com/airfoil/satellite; tuneblade 1.2.0; ROADMAP 005 |
| Volume keys work everywhere (incl. aggregate output) | TidBITS notes dead volume keys on aggregates; Sonos friction threads | complaint | **PARTIAL** — Main mirrors system volume (merged); dead-keys-on-aggregate = A2 interceptor, queued | discussions.apple.com 255079124; TidBITS |
| Line-in / input-device as source | TuneBlade "Specific Endpoint" capture | differentiator | **MISSING** | tuneblade releaseNotes 1.2.0 |
| Glitch-free capture under CPU load | TuneBlade shipped dedicated work; AirParrot stutter complaints | complaint | **PARTIAL** — RT send-thread Stage 2 gated on live T10 measurement | tuneblade 1.5.1; askwoody AirParrot review |
| Password/passcode receivers | TuneBlade treated each Apple auth mode as must-fix | table-stakes | **PARTIAL** — AP1 auth-setup/MFi deferred (AirPort Express); AP2-password status unverified | tuneblade 1.7.7 |

### Recorded, deliberately not chased (see §4)

Queue/playlist management · room correction (Trueplay) · Windows port · notification/announcement ducking · Mac/other-devices as AirPlay *receivers* · volume normalization · Home Assistant integration (downstream of any public API) · pricing/trial mechanics (moot — Audiout is GPL open source, direct download, per SPEC §2).

---

## 3. THE SHORTLIST — parity candidates ranked for Audiout

Ranking = demand strength × fit with the native-macOS / audio-only / multi-room identity × feasibility on the existing engine. Recommendation first, upside and downside both stated.

### 1. Per-device delay trim (manual sync offset)

The only gap that showed up as *shipped table-stakes* in four of five families (Google Home, TuneBlade, snapcast) *and* as an explicit user request in the other (Airfoil forums, OwnTone #560). It fits the engine unusually well: the engine already owns a shared PTP presentation timeline per output, so a per-device ±ms offset is an adjustment to an anchor that already exists — and it becomes near-mandatory the moment Bluetooth outputs (roadmap 004) land, because BT hardware latency varies wildly and PLAN-UNIVERSAL-SYNC's auto-offset will need a manual escape hatch anyway. Fits the owner's bare-numbers-over-presets preference (a numeric ms field per device, like the existing global buffer setting).
**Upside:** closes a real sync complaint class cheaply; de-risks the BT plan; snapcast #476 shows users expect trims to persist — Audiout's per-device persistence pattern (DeviceIconStore) is ready to copy.
**Downside:** it's an escape hatch that can mask genuine sync bugs (a user "fixes" drift that the engine should have fixed); one more per-device control in an already dense row UI.

### 2. Per-device EQ — basic tone first (bass / treble / balance / loudness)

Already promised in SPEC v2 ("per-device EQ / L-R balance" in the full window), shipped by every direct competitor (SoundSource, Airfoil, TuneBlade, Sonos), and begged for upstream (snapcast #917 — a user offered to write the PR). It sits naturally on the existing render path: Audiout already does per-device gain staging before encode, and a biquad tone stage slots in at the same point. Recommend the Sonos-shaped floor (bass/treble/balance/loudness) rather than a 10-band graphic — loudness compensation is reportedly the most-toggled control.
**Upside:** fulfills an existing spec commitment; the one feature where Audiout can beat Sonos at its own hardware (Sonos refuses manual access to its DSP — Audiout EQs *before* the AirPlay send, so it works on any receiver).
**Downside:** DSP scope creep is real — the parametric/room-correction ceiling (shairport-sync convolution) is a rabbit hole; every filter adds CPU on the RT path that Stage-2 scheduling work hasn't been live-measured yet; badly-set EQ + high gain can clip before encode, needing a limiter conversation.

### 3. Shortcuts / App Intents automation actions

The strongest *unserved* demand signal in the small-vendor family: TuneBlade users kept three community Home Assistant integrations alive for 4+ years off a bare HTTP API, an Indigo plugin existed solely to script Airfoil, and SoundSource 6 just expanded its Shortcuts actions. For a native AppKit app, App Intents (select group, set device/Main volume, toggle per-app route) is the Mac-native answer and much cheaper than designing a public HTTP API — it also composes with macOS automations users already have.
**Upside:** cheap for what it buys; reaches the home-automation crowd that evangelizes these tools; no protocol/versioning commitment the way a public HTTP API would be.
**Downside:** Shortcuts-only leaves the Home-Assistant-on-a-Pi crowd unserved (they need a network API — a bigger, versioned commitment deliberately *not* recommended yet); intents surface area must track features or rot.

### 4. Sleep timer + fade in/out

Already in SPEC's "Later" list, so this is a promotion, not new scope. The Sonos natural experiment is unusually clean evidence: it was stripped in the 2024 rewrite and loudly mourned until restored — small feature, outsized goodwill. Maps cleanly to the domain ("stop streaming to the bedroom in 30 min, fade out").
**Upside:** small, well-understood, zero architectural risk; pairs naturally with fades the engine can do in the gain stage.
**Downside:** low differentiation (everyone understands it, nobody switches apps for it); per-device vs whole-output-timer scope needs a decision or it grows arms.

### 5. Scenes / full-setup snapshots (Quick Configs)

The step past saved groups that users beg Sonos for (multi-year threads, unbuilt) and SoundSource 6 just shipped. Audiout's groups already snapshot per-device volumes — this extends the same persistence pattern to the whole routing state (per-app routes, Main, mutes, future EQ) recalled by name. A natural superset of machinery that already exists.
**Upside:** differentiator against Sonos (they never shipped it); mostly persistence + apply logic, no engine work; composes with #3 (a scene as a Shortcut action is the killer combo).
**Downside:** apply-time edge cases are the real cost (missing devices, apps not running, conflicts with the active state) — the "silent fallback" rules need careful design; risks UI confusion between groups and scenes if not framed crisply.

### 6. Per-speaker auto-connect on appearance

TuneBlade's set-and-forget shape (per-receiver auto-connect + force-reconnect), and the OwnTone #1760 lesson: users benchmark reconnect behavior against iOS and blame the app that needs manual restarts. SPEC v2 already promises group auto-reconnect; this sharpens it to a per-speaker opt-in toggle.
**Upside:** turns Audiout into whole-home always-on infrastructure rather than a session tool; builds on existing reconnect/warm-signal machinery.
**Downside:** interacts with the open connect-volume-seed questions (roadmap 018's anti-blast decision) — auto-connecting at the wrong level is the worst version of the blast bug; surprise audio on speaker power-on can genuinely annoy households.

### 7. Manual add receiver by IP:port

Cheap insurance against the discovery-failure support load every peer documents (TuneBlade built it because "Zeroconf is disabled or doesn't work properly" on real networks; Sonos's vanishing-rooms backlash is the same failure class). A hidden-by-default power-user field, not a headline feature.
**Upside:** tiny; converts "app is broken" support cases into self-service; helps VLAN/mesh-network setups that are common among exactly this audience.
**Downside:** bypassing Bonjour means bypassing the TXT-record capability data discovery provides — the connect path needs a fallback for missing metadata; rarely used, easy to under-test.

### 8. Codec transparency ("lossless, and we say so")

Verified this sweep: the vendored sender encodes ALAC on the wire (`airplay.c` send path) — Audiout is already lossless where Apple's own AirPlay 2 path silently transcodes to AAC-256, which audiophiles loudly resent. The gap is purely surfacing it: a codec/bit-depth line in the device row or diagnostics panel.
**Upside:** near-zero engineering (the fact is already true); speaks directly to the forum crowd most likely to adopt a tool like this; honest-marketing material.
**Downside:** invites audiophile scrutiny of the whole pipeline (any future resample/EQ stage must then be disclosed too); a claim, once made, has to be kept true per-receiver-type (AP1 vs AP2 paths).

### 9. Per-device max-volume limit

SoundSource 6 ships it; Audiout's gain-staging architecture has the plumbing, and it dovetails with roadmap 018's anti-blast open question (a ceiling clamp is one of the three candidate answers there — building the limit answers 018's T-I2 for free).
**Upside:** small; protects ears and neighbor relations; one decision serves two roadmap items.
**Downside:** weak independent demand evidence (only Rogue Amoeba shipping it); another per-device setting to persist and surface without cluttering rows.

### 10. Cast-like output (already roadmap 006 — keep as research, rank last for building)

The one structural feature gap vs Airfoil/AirParrot (cross-protocol AirPlay+Cast groups). Kept on the shortlist because it's already the owner's roadmap 006 and the sweeps confirm it's a real differentiator — but ranked last on feasibility: it's an entire second sender protocol with its own sync domain, and AirParrot's reviews show cross-protocol sync is fragile even for a company that ships it full-time.
**Upside:** would make Audiout the only maintained macOS app spanning both ecosystems; unlocks Chromecast-only households.
**Downside:** the engine's PTP timeline doesn't extend to Cast — cross-protocol sync is a research problem, not a feature; large ongoing compat surface (two reverse-engineered/foreign protocols to chase instead of one).

---

## 4. Anti-candidates — explicitly not chasing

- **Queue / playlist management.** Sonos users mourned it, but Audiout routes *system/app* audio — the source app (Music, Spotify) owns the queue, and per-app routing keeps users in the app that already has a good queue UI. Chasing it would mean becoming a media player. Recorded so the skip is conscious.
- **Room correction / Trueplay-style tuning.** Marquee Sonos feature, but the loud user signal is about iOS/Android *parity lockout*, not demand for tuning itself; target speakers (Sonos, HomePod) already self-tune; mic-based correction is a large DSP project orthogonal to routing. If power users want it, shairport-sync-style convolution is their tool.
- **Windows port.** The market gap is real (TuneBlade discontinued 2018, Airfoil-for-Windows stagnant), but it forfeits the entire native-AppKit identity and the Core-Audio process-tap architecture. An expansion signal for someone else.
- **Public HTTP/WebSocket API (for now).** Real demand exists (TuneBlade/HA crowd), but it's a versioned protocol commitment plus a security surface on a LAN port. Shortcuts/App Intents (#3) serves most of the same jobs Mac-natively; revisit only if HA-style demand shows up for Audiout specifically. Home Assistant integration is downstream of this and inherits the skip.
- **Notification/announcement ducking (doorbell over music).** Recurring in snapcast's home-automation crowd; niche for a Mac menu-bar app. Audiout's per-speaker mixing means it's *closer* than competitors if this ever matters — which is exactly why it doesn't need building speculatively.
- **Mac/other devices as AirPlay receivers (Satellite-style).** Rogue Amoeba never achieved AirPlay-2-protocol receiving either; Audiout's synced-local playback already covers the host Mac, which is the case that matters.
- **Volume normalization across tracks.** Single-issue upstream signal; the source app owns it in a system-capture architecture. Legitimate skip.
- **Pricing/trial mechanics.** The Rogue-Amoeba-family findings (one-time $29–49 sweet spot, degradation-based trials) are largely moot: SPEC §2 decided open source (GPL-2.0-or-later), direct download. Kept in the raw JSON as context should distribution ever be revisited.

---

## 5. Open questions for the owner

1. **EQ scope ceiling (shortlist #2).** Basic tone (bass/treble/balance/loudness, recommended) vs 10-band graphic vs parametric? Decides the DSP investment and whether a limiter conversation happens now or later.
2. **Automation surface (shortlist #3).** Shortcuts/App Intents only (recommended), or is the Home-Assistant crowd worth a small local HTTP API despite the protocol commitment? Interacts with the companion app's private protocol — one control plane or two?
3. **Scenes vs groups framing (shortlist #5).** Extend saved groups into full-state scenes, or keep them separate concepts? The dedup/identity rules in SPEC §9 (groups identified by member set) don't transfer cleanly to scenes.
4. **Auto-connect × anti-blast (shortlist #6 + roadmap 018).** Per-speaker auto-connect makes 018's T-I2 decision (trust device-reported volume vs clamp vs ramp) more urgent — decide together?
5. **Codec claim (shortlist #8).** Comfortable publicly claiming lossless/ALAC? It's true today, but it commits future pipeline changes (EQ, resampling) to disclosure.
6. **Stereo-pair HomePods.** Unverified how discovery presents a stereo pair (single AP2 endpoint expected). Cheap live check next hardware session; if it just works, say so on the site.
7. **Sonos group-volume patents.** Group-volume mechanics are Sonos-patent territory (patent 12260064; they litigated Google over it). Likely irrelevant for a GPL personal tool, but worth a look before any commercial-flavored distribution.
8. **Sonos firmware-regression exposure.** Oct 2024: a Sonos firmware update broke multi-device AirPlay from third-party senders (hit Airfoil and Roon). Audiout inherits this class of risk; do we want a canary practice (test after Sonos firmware updates) as a standing rule?

---

## 6. Corrections made to researchers' status guesses

Spec/roadmap-verified changes from the raw JSON's `audiout_status_guess` fields:

| Finding | Guess | Corrected | Why |
|---|---|---|---|
| Scenes (group + volume snapshot recall) | partial | **partial, but narrower gap** | SPEC §2/§3: saved groups DO persist per-device volumes — the missing part is only whole-state (routes/mutes/EQ) snapshots |
| Group volume leveling / per-speaker trim persistence | partial | **has-it (mechanism)** | Same spec fact: per-device levels persist inside groups; only the "trim" framing is absent |
| Lossless codec path | unknown | **has-it (mechanism)** | Verified in source: vendored sender ALAC-encodes on the send path (`AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c`, `alac_encode`) |
| Bluetooth synced outputs | partial | **missing (planned)** | Roadmap 004: PLAN-UNIVERSAL-SYNC designed, but zero BT code exists |
| Sleep timer | missing | **missing — already spec'd** | SPEC §3 "Later": sleep timer + fade in/out (promotion, not new scope) |
| Per-device EQ | missing | **missing — already spec'd** | SPEC §3 v2: per-device EQ / L-R balance is a standing commitment |
| One-tap everywhere / party mode | unknown | **partial** | A saved all-speakers group + member-set dedup (SPEC §9) covers it; no dedicated select-all control |
| Connection standby (silence handling) | unknown | **missing, with an open bug** | Roadmap 017: the silence path currently has a producer-starvation skew bug — fix before feature |
| Chromecast output | missing | **missing (planned)** | Roadmap 006 already scopes the research |
| Trial/pricing findings | unknown | **N/A** | SPEC §2: GPL-2.0-or-later open source, direct download — pricing mechanics moot |
