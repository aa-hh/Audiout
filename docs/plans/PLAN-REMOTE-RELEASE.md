# PLAN — Audiout Remote release

*2026-09-05. Grilled with the owner across 31 decisions; every code fact below was read in source this session. Target: Audiout Remote submitted to App Store review by 3 October 2026, a matching Mac release, one audiout-shared tag pinned in both, the website flipped the day the store link exists. Decisions recorded in `docs/adr/0001-remembered-offset-on-reconnect.md`, `audiout-shared/docs/adr/0001-quieter-sweeps.md`, and the glossary `audiout-shared/CONTEXT.md`. Research: `dev/notes/bt-latency-stability-research-2026-09-05.md`.*

Four repos: **shared** (audiout-shared), **phone** (audiout-remote), **mac** (this repo), **site** (Audiouter Website). Paths are relative to each repo's root.

## Decisions

| # | Decision |
|---|---|
| D1 | Scope: phone first launch through first measurement, the sync sheet, the Mac's invites, the website, the listing. All of it gates submission except the crowd registry. |
| D2 | Buyer is Mac-first. The listing says the phone needs Audiout for Mac. |
| D3 | Lead claim everywhere: measured with your iPhone. Airfoil and SoundSource measure nothing; Airfoil's free remote and Bluetooth output are parity, never pitched as advantages. The Mac's click wizard stays as "Align by ear". |
| D4 | Name: Audiout Remote. Subtitle: "The remote that tunes your speakers." Closes T23. |
| D5 | Intro: three cards. Mac plays, phone remotes, phone listens. Skippable. Ends on Find My Mac. |
| D6 | Demo ships, reachable from the search checklist after the 8 s timeout, labelled on every screen. A pill offers the real Mac when one appears, never forces it. |
| D7 | Sound only from the speakers being synced. Verdict plays the before-and-after unprompted. Sweeps 6 dB down, 80 ms fades (shared ADR 0001). |
| D8 | Haptics: measurement lands, level drag detents at 0/50/100, connected. Motion: rings converge on connect, rings settle on the verdict, field pulses with the sweeps. Emitter field otherwise calm. |
| D9 | Measure as soon as both speakers play. An unsettled reading is a "first pass", applied and labelled. Walk-there and can-you-hear-both merge. Met conditions skip their page. By-ear page runs the click throughout. |
| D10 | Reconnect: apply "Timing from last time", one-tap re-check banner once settled, replace at 10 ms, tell the user over 40 ms (mac ADR 0001). |
| D11 | Per-connection settle log: speaker, codec, jump count, time to settle, settled offset. Local in debug, PostHog in release. Crowd registry deferred until the log says it helps. |
| D12 | Apple crash reports plus PostHog, anonymous, on by default, one opt-out switch in Settings. Privacy label becomes "Product Interaction, not linked to you". |
| D13 | Fix all four mirroring gaps. One empty-state component, one gold button, one error-copy rule, 44 pt targets, DESIGN.md corrected to the code. |
| D14 | English only, strings in a String Catalog. |
| D15 | Mac invites the phone in four places: untuned Bluetooth chip, beside the Allow switch, a seventh first-run card, licence email plus /thanks. QR target is `audiout.app/remote`, which redirects to the store once live. |
| D16 | Wire field stays `groups`. User-facing word is Scene everywhere, including the Mac's leftover strings. |

## Owner-only prerequisites

Nothing below can be verified end to end until these are done.

- Install an iOS simulator runtime. `xcrun simctl list runtimes` is empty on this Mac (Xcode 27.0), so the phone's 13 test files compile but never run.
- Set `DEVELOPMENT_TEAM` (phone `project.pbxproj:423` is empty) or pass it per `AGENTS.md:118-124`, and stand up TestFlight per `docs/companion-app-store.md:119-133`.
- Bring a Sonos Move 2, the Sony, and a third speaker to the D11 log for twenty reconnects each before the threshold review (T23).

## Phase 0 — shared package (week 1)

| # | Task | Where |
|---|---|---|
| T1 | Sweeps: level −6 dB, fade 0.08 s in `SweepDesign` defaults (`Sources/ProbeKit/SyncProbeCorrelator.swift:69-85`). Run `swift test`; if peak-over-background margin drops in `ProbeKitTests`, fall back to −3 dB / 40 ms and amend the ADR. | shared |
| T2 | Add to `DeviceState.AlignmentState` a source for the applied offset: measured, first pass, from last time. Additive case, no `CompanionProto.version` bump. Add a `settleLog` command or message for T8 if the phone is to display it (else Mac-only, skip). | shared |
| T3 | Tag `0.9.0`, push tags. Both pins bump in T4 and T13 the same day. | shared |

## Phase 1 — phone (weeks 1–3)

| # | Task | Where |
|---|---|---|
| T4 | Pin shared 0.9.0. Compile check per `AGENTS.md`. | phone |
| T5 | Intro: replace the single primer (`ConnectGateView.swift:198-212`) with three cards, page dots, Skip on cards 1–2, Find My Mac on card 3. Static field under Reduce Motion (`:133-135`). Flag stays `hasSeenConnectPrimer` (`RootView.swift:42`). | phone |
| T6 | Demo in release: drop `#if DEBUG` around `DemoMacSession` entry (`RootView.swift:15-18`, `ConnectGateView.swift:380-398`); add "No Mac nearby? Try the demo" to the checklist (`ConnectGateView.swift:353-357`); persistent Demo pill in the shell that becomes "Your Mac is here" when `handleMacsChanged` sees one (`RootView.swift:195-206`); `enterDemo` must not set the primer flag on its own (`RootView.swift:135`). `playAlignmentDemo` stops being a no-op in demo (`DemoMacSession.swift:537`). | phone |
| T7 | Sync sheet rework (D9): opening page logic `SyncSheet.swift:126-130`; merge pages C and D (`:373-411`); Measure live on both-playing, not on clock verdict (`:537`, `:953-959`); first-pass verdict copy and label; tick runs on the by-ear page (`:1101-1250`, `setAlignmentTick` as on `:408`); verdict calls `playAlignmentDemo` on `.applied` (`:757`); re-check banner replaces the silent second run (`:588-596`, `:620-648`). | phone |
| T8 | Delight: haptics on `.applied`, on connect at the 800 ms hold (`RootView.swift:47`), detents in the level drag (`DeviceRowView.swift:291`); field pulse during `AlignmentRunController` phases (`:33-52`); field settle on verdict; ring convergence on the connected junction (`ConnectGateView.swift:256-261`). | phone |
| T9 | Reliability (D13): visible refusal for sends while not live (`MacConnection.swift:241-249`, `ConnectionController.swift:326-330`, timeout check `RemoteSession.swift:309`); one reconnecting banner and one empty state across tabs (`SpeakersView.swift:31-36`, `AppsView.swift:168-173`, `GroupsView.swift:39-46`); sync refusals with no sheet go to the toast (`RemoteSession.swift:80-85`); Main Audio slider expiry like the rows (`SpeakersView.swift:820-826` vs `DeviceRowView.swift:367-371`). | phone |
| T10 | Consistency: one gold button (fold `GoldCTA` `SyncSheet.swift:1262-1293` and `GoldAction` `ConnectGateView.swift:757-775` into `GoldCTALabel`); one empty-state view; error copy rule applied to the toast (`RemoteSession.swift:286`) as the sheet already does (`AlignmentRunController.swift:351-364`); `hittable(drawn:)` values corrected at `SyncSheet.swift:485, 764, 810, 860, 1153, 1168, 1183`, `DeviceRowView.swift:695`, `SyncInviteCard.swift:126`; stock `.bordered` at `DeviceRowView.swift:726-732` replaced; DESIGN.md fixed at `:479, 655, 691, 744` (Main Audio), `:881-899` (Scenes), `:860`, `:1165`, `:1119-1121`, and the sheet's 20 pt gutter and third button documented or removed. | phone |
| T11 | Data (D12): PostHog iOS SDK, anonymous id, events: intro_card_seen, find_mac_tapped, connected, demo_entered, sync_opened, measure_tapped, verdict (applied / first pass / refused), recheck_accepted, by_ear_nudged. Opt-out switch in `SettingsTabView`. `PrivacyInfo.xcprivacy` added. Apple crash sharing needs nothing in code. | phone |
| T12 | Strings to a String Catalog (D14); `MacCopyTripwireTests.swift:26-33` still pins the five shared sentences. Remove the UI test's hardcoded scratch path (`CompanionSmokeUITests.swift:28-33`). Run the tests once the runtime is installed and paste output into the PR. | phone |

## Phase 2 — Mac (weeks 2–3)

| # | Task | Where |
|---|---|---|
| T13 | Pin shared 0.9.0; the Mac's staged sweep follows the package, `AlignmentTickInjector.probeSweepSeconds` unchanged. | mac |
| T14 | Reconnect (D10): on Bluetooth reconnect apply the stored `BTTrimStore` value instead of flagging stale (`BTAlignmentFreshness.swift`, snapshot builder `CompanionSnapshotBuilder.swift:236-250`), publish source "from last time" via T2; accept a re-measurement and replace at ≥10 ms; surface >40 ms. | mac |
| T15 | Settle log (D11): per connection write speaker UID, codec (from the `bluetoothaudiod` line if readable), jump count and time-to-settle from `BTClockStability`, settled probe offset. Debug: local file. Release: PostHog event from the Mac, same opt-out as the usage-counts card (`OnboardingViewController.swift:784-811`). | mac |
| T16 | Invites (D15): untuned Bluetooth chip offers "Measure with your iPhone" with QR before "Align by ear" (`PopoverController.swift:4640-4646`); link plus QR under the Allow switch (`GeneralSettingsViewController.swift:216-219`); seventh first-run card (`OnboardingViewController.swift:675-811`); Allow switch default ON (T22 in `PLAN-COMPANION-APP.md:370-371`). | mac |
| T17 | Vocabulary (D16): "‹ Groups", "New Group", "Delete Group…" → Scene wording across `AudioutCore/Sources`. | mac |
| T18 | Review kit rewrite (`docs/companion-app-store.md`): demo path from the checklist (`:16-22`), current four tabs (`:17`, `:67-75`), licence lock and €30 Mac app stated (`:9`), name and subtitle per D4 (`:101-118`), privacy answers per D12. Mark `PRICING.md:3` settled. | mac |
| T19 | Cut the Mac release with the notarized-build workflow (`c96f2901`). | mac |

## Phase 3 — site and server (week 3)

| # | Task | Where |
|---|---|---|
| T20 | Copy (D3): hero `src/pages/index.astro:189-193`, sync claims `Features.astro:17, 145, 183` and `index.astro:56, 60`, the Airfoil FAQ `index.astro:34-35`, `/remote` page `remote.astro:112-122`, OG card `tools/og-card/card.html:147` and its stale alt `Base.astro:98-100`. Phone remote framed as the ear, not the differentiator. "Coming soon" pills gated on a store-link constant. | site |
| T21 | `/remote` redirects to the App Store when the constant is set; `/thanks` and the licence email carry the badge (email template in the licence server, `src/`). | site, server |

## Phase 4 — verify and submit (week 4)

| # | Task |
|---|---|
| T22 | TestFlight to three outside phones. Watch PostHog for intro and sync drop-off. |
| T23 | Owner reviews the settle log against the 10 ms threshold; amend ADR 0001 if the measured spread says otherwise. |
| T24 | Submit. Review notes from T18. Mac release ships the same day as approval; site flips the same day. |

## Order and dependencies

T1→T3→(T4, T13). T2 before T7 and T14. T6 before T18. T15 before T23. T16 and T21 need only the `/remote` URL. Everything in Phase 1 except T4 and T7 can start today on shared 0.8.1.

## Out of scope

Crowd registry on the licence server. Localisation beyond English. iPad layout. Automatic re-checks with no tap.
