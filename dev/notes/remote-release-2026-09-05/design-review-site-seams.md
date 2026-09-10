# Design review: site and server seams for the Remote release (T20, T21, cross-repo)

*2026-09-06. Read against the website at `Audiouter Website` (commit fe0bbd0 on main), the licence server at `Audiout License Server`, the Mac repo, the phone repo, and `audiout-shared` `CONTEXT.md`. Vocabulary from the codebase-design skill: module, interface, seam, adapter, depth, leverage, locality. Site paths are relative to the website repo, server paths to the licence server repo, unless said otherwise.*

## 1. Is there one module for "is the phone app live yet"?

No. There is one constant and one reader, and five pages that ignore both.

### What exists

- The switch is `PUBLIC_APP_STORE_URL` in `.env.production` and `.env.staging`, both holding `PLACEHOLDER_SET_AT_LAUNCH`. The env comment says that once a real URL lands "the badge links, the pills disappear, the QR image renders, and the JSON-LD flips to InStock".
- Exactly one file reads it: `src/pages/remote.astro:14-15` (`appStoreURL`, `storeConfigured`), through `unconfigured` from `src/lib/checkout.ts:9-10`. On that page everything hangs off it: the description `:17-19`, the JSON-LD availability and `downloadUrl` `:83-85`, the hero sentence `:114`, the "Coming soon to the App Store" pill `:121-125`, the signup form `:136`, the hero badge `:185-195`, and the bottom sheet `:427-445` (badge plus `/appstore-qr.svg`, a file that does not exist in `public/` yet).
- "Coming soon" hard-coded with no switch: `src/components/Features.astro:128-130` (pill and sentence), `src/pages/index.astro:37` (FAQ answer), `src/pages/pricing.astro:33` (feature bullet) and `:41` (meta description), `src/pages/buy.astro:137-138`, `src/pages/press.astro:31`, `src/pages/blog/airfoil-alternatives-mac.md:76` and `:93`. Plus a second, different claim: `src/pages/remote.astro:364-365` says measurement from the phone is "Coming soon" and that "today a guided by-ear wizard on the Mac" does the job. After this release that row is the lead claim, not a coming-soon row.
- So flipping the env line today changes /remote and leaves the homepage, pricing, buy, press and one blog post saying coming soon. The env comment's promise is false for five pages.
- `scripts/launch.sh:86-87` and `:133` assert that `/remote` still carries `soon-pill` and `PreOrder`. The Mac launch ran on 2026-09-05 (commit f075f37), so that script has done its job, but it is documented as re-runnable and would fail after the phone flip. `.env.production:5` still says the Mac switch "is OFF"; it is on.

### The model to copy is already in the repo

The Mac's launch switch is a deep module. Interface: one boolean, `CHECKOUT_LIVE` (`src/lib/checkout.ts:12-14`). Implementation: the env read and the placeholder test, once. Adapters at the seam: `BuyButton.astro:16-27` (a link when live, a span with a ribbon when not), the announce bar `Base.astro:122-124`, the pricing island `pricing.astro:18`, the FAQ sentence `index.astro:42`, the JSON-LD `index.astro:132`, the sitemap `sitemap.xml.ts:11-16`, and the build prune `prune-prelaunch.mjs:54-57` reading the same test off the built page. Leverage: seven surfaces flip on one env line. Locality: launch.sh checks one artifact shape and nobody greps for pills.

The phone switch has the constant but not the module. `storeConfigured` is computed inside one page, so no other page can read it, which is why the other pages hard-code the words.

### Proposed seam and interface

`src/lib/remote.ts`, sibling of `checkout.ts`:

- `APP_STORE_URL: string | null`, the env value or null, tested with `unconfigured` imported from `checkout.ts` (do not copy the predicate again; `src/AGENTS.md` documents the duplicate in `buy.js`/`analytics.js` as deliberate for client scripts, but this is build-time Astro code where an import works).
- `REMOTE_LIVE: boolean`, true iff `APP_STORE_URL` is non-null. That invariant is the whole interface.
- `APP_STORE_ID: string | null`, the numeric id parsed from the URL (`/id(\d+)/`), for the Smart App Banner meta below.
- `REMOTE_SENTENCE: string`, the one sentence five pages already repeat word for word: "Audiout Remote, the free iPhone app, is coming soon." before, "Audiout Remote is free on the App Store." after. Pages compose around it.

`src/components/RemoteBadge.astro`, the phone twin of `BuyButton.astro`: live, Apple's badge inside a link to `APP_STORE_URL`; not live, the `soon-pill` (or a quiet link to `/remote#notify-email` where the signup form is on the same page). Two adapters, both shipped (staging can preview the live state by setting its own env line), so the seam is real, not hypothetical.

Callers that move onto it: `remote.astro` (hero `:114,121-125,185-195`, sheet `:427-445`, description `:17-19`, JSON-LD `:83-85`, signup form `:136`, and the meta tag), `Features.astro:128-130`, `index.astro:37`, `pricing.astro:33,41`, `buy.astro:137-138`, `press.astro:31`, and the new `/thanks` step. `remote.astro` keeps its `data-notify` wrapper and status line in both states (`src/AGENTS.md`, "Remote signup").

Markdown cannot read a constant. Reword `blog/airfoil-alternatives-mac.md:76` and `:93` now to be true in both states ("Audiout Remote, the free iPhone app, mirrors the Mac's faders" with the link to `/remote`, no "not on the App Store yet"), so the flip touches no markdown.

Deletion test on the proposal: remove `remote.ts` and the same env read plus copy branch reappears in seven files. It earns its place.

### How the site deploys, and what that means for a /remote redirect

- The site is a Cloudflare Worker with static assets, not Pages: `wrangler.jsonc` envs `staging` and `production`, `assets.directory: ./dist`, `run_worker_first: true` on both, custom domains `audiout.app` and `www.audiout.app`. `worker.js:38-67` runs on every request: the www to apex 301 (`:26-36`) and the `Accept: text/markdown` negotiation. Env values are build-time `PUBLIC_*` from `.env.production`; the site worker has no runtime `vars`. `public/_headers` exists; there is no `_redirects`.
- Cloudflare's own docs on `_redirects` for Workers static assets: "Redirects defined in the `_redirects` file are not applied to requests served by your Worker code, even if the request URL matches a rule." With `run_worker_first: true` every request is served by `worker.js` through `env.ASSETS.fetch`, so a `_redirects` file is not a safe mechanism here. A redirect would have to be code in `worker.js`, and `worker.js` cannot read `.env.production`, so it would need the URL from a wrangler `vars` entry (a second copy of the switch in a second file) or from a small asset the Astro build writes into `dist/` (a build hook like `prune-prelaunch.mjs`, plus an extra asset fetch per hit).
- A blanket redirect on `/remote` also breaks two things that already exist. The licence server's confirm and unsubscribe links land on `/remote?subscribed=1` and `/remote?unsubscribed=1` (server `src/index.ts:396,405`; site `remote.astro:127-134`, `notify-remote.js`), so a person unsubscribing would be bounced to the App Store with no confirmation. And `/remote` is in the sitemap with FAQ JSON-LD; a redirect drops the page from search the week the phone launches.
- Recommendation: no redirect. `/remote` stays a page in both states. Once live, the badge links to the store (already built at `remote.astro:185-195` and `:432-440`) and the page adds Apple's Smart App Banner, `<meta name="apple-itunes-app" content="app-id=APP_STORE_ID">`, rendered by `Base.astro` from a new optional prop or directly in `remote.astro` when `REMOTE_LIVE`. Safari on iPhone then shows the native "Open in App Store" banner at the top of the page, which is what the QR arrival gets. The Mac's QR (T16) and the licence email point at `audiout.app/remote` and never change. This amends D15 from "redirects to the store once live" to "carries the store badge and Safari's App Store banner once live".
- If the owner wants a true redirect anyway: give it its own path with no page behind it (for example `/remote/app`), handle it in `worker.js` next to the www redirect, read the URL from an asset the build writes, and point the QR at that path. Never redirect `/remote` itself. T16 bakes the QR target into a Mac release, so this choice must be made before T16 ships.

### /thanks

`src/pages/thanks.astro:101-111` is "Up and running in three steps." The badge goes in as a fourth step ("Put the faders on your phone"), rendered by `RemoteBadge`, with `REMOTE_SENTENCE` beside it. `thanks.astro` imports no switch today; it gets `remote.ts` like the others. It is noindexed (`:17`) and no longer pruned (checkout is live), so nothing else changes.

### The licence email

- Template: server `src/email.ts:136-309`, `licenseEmail(env, key)`. HTML at `:153-269`; the three steps are built by the `step()` helper `:147-151` and listed at `:241`; the plain-text twin is `:273-297` and is mandatory (`:4-6`, a client that refuses HTML still has to read the key). Links come off `env.SITE_ORIGIN`'s first entry (`:141-144`) and `env.PUBLIC_BASE_URL` (`:137`). The one image is the mark, inlined as a `cid:` attachment from `src/mark.ts` (`:299-307`).
- Sent from three places: fulfilment on the Paddle webhook, `/v1/resend` (`src/index.ts:323`), and `/admin/resend` (`:611`). Tests assert the HTML's contents in `test/webhook.test.ts:46-66` (key, download link, `cid:audiout-mark`, privacy and impressum hrefs, no www).
- No App Store or remote value exists on the server: `src/env.ts:10-58` and both `wrangler.jsonc` env `vars` blocks have nothing of the kind.
- `email.ts:125-130` records the legal line: keep the body free of anything promotional (that is what keeps § 7 UWG off it). A "get the remote" row has to read as a setup step for a part of the purchase, which it is ("included with Audiout for Mac"), never as an advert.
- Recommendation: no server-side switch at all. Add a fourth step to the `step()` list at `:241` and to the text twin at `:284`: "Audiout Remote, the free iPhone app, puts the same faders on your phone: `${origin}/remote`". That sentence is true before and after launch; `/remote` itself shows the signup or the badge. No badge image: Apple's SVG badge does not render in Outlook or Gmail, a PNG would mean a second `cid:` attachment and a switch to hide it pre-launch, and Apple's badge rules want it linked straight to the store. One test line in `webhook.test.ts`: `expect(emails[0].html).toContain('href="https://audiout.app/remote"')`. The server drops out of the flip; the release-day change is one env line in one repo.
- Upgrade path if the graphic is wanted later: `APP_STORE_URL` in both `wrangler.jsonc` env `vars` and in `Env`, a PNG badge beside `mark.ts`, `licenseEmail` rendering the badge only when the var is set, and a test per state. Three moving parts for a picture in an email.

## 2. Cross-repo seams

### (a) PostHog on the phone (T11) and the Mac (T15)

What each end does today:

- Mac: `AudioutCore/Sources/AudioutCore/Analytics.swift`, a consent-gated facade; `Analytics.capture(StaticString, [String: String])` (`:70`), properties are strings only. Names follow `category:object_action` in snake_case (Mac `CLAUDE.md:178`); the forty live names include `bt_sync:wizard_started`, `bt_sync:wizard_finished`, `connection:connected` (a speaker connection, not a phone), `onboarding:setup_completed`. Privacy fence: no speaker names, bundle ids, network identifiers, free text; counts, enum-like strings and booleans only (`CLAUDE.md:179`). Consent is opt-in and off by default (`CLAUDE.md:180`); the ask is the usage-counts card at `OnboardingViewController.swift:784-811` ("Share Usage Counts"). Distinct id is the per-install `installID` (`AppDelegate.swift:107`, `identify` at `:2245`), with super properties `license_status` and `license_max_major` (`:2246-2254`).
- Site: cookieless PostHog, `person_profiles: "never"`, bare snake_case names (`remote_signup_requested`, `license_key_delivered`), single-session only, no join to anything (`src/scripts/analytics.js:9-14`).
- Phone, as T11 is written: bare names `intro_card_seen, find_mac_tapped, connected, demo_entered, sync_opened, measure_tapped, verdict, recheck_accepted, by_ear_nudged`, an anonymous id, on by default with one opt-out (D12). The phone repo has no analytics code today.
- Identity across the pair: the phone sends its per-install `clientID` in `hello` (`audiout-shared` `Sources/AudioutProtocol/CompanionMessage.swift:21-27`); the Mac's `welcome` carries `serverName` and nothing that identifies the Mac (`:36`). Two devices, two distinct ids, and a PostHog funnel is per distinct id. So today no single query can follow "Mac invited, phone connected, measurement applied, Mac settled".

What the two schemas must share for one funnel to work:

1. Event name form. The phone adopts the Mac's `category:object_action`. Rename T11's list: `intro:card_seen`, `intro:find_mac_tapped`, `connect:connected`, `demo:entered`, `sync:opened`, `sync:measure_tapped`, `sync:verdict`, `sync:recheck_accepted`, `sync:by_ear_nudged`. The Mac's T15 settle log is `sync:settled`; the Mac's applied-offset event is `sync:offset_applied`. One category for the measurement on both ends, with `source: mac | phone` on every `sync:` event so the same step from either end is one series. The Mac's existing `bt_sync:wizard_*` stays as it is; that is Align by ear.
2. Property names and values, taken from `CONTEXT.md` so the data uses the glossary's words: `offset_source` in {`measured`, `first_pass`, `from_last_time`} (the same three T2 adds to `AlignmentState`); `verdict` in {`applied`, `first_pass`, `refused`}; `settled` true/false; `speaker_kind` in {`airplay`, `bluetooth`, `chromecast`, `mac`}; `offset_ms_bucket` (bucketed, never the raw number, to stay inside the Mac's counts-and-enums fence); `codec`, `jump_count`, `settle_seconds_bucket` on `sync:settled`.
3. A join key. `mac_id`, the Mac's `installID`, carried to the phone as an optional additive field on `welcome` (additive case, no `CompanionProto.version` bump per the AudioutProtocol rule) and set by the phone on every event, as a property or as a PostHog group `mac` on both ends. With PostHog group analytics (a paid add-on) one funnel can aggregate by unique `mac` groups across both devices; without it, one HogQL query joins on `mac_id`. Without the key, "one funnel" is two funnels read side by side. Sending the Mac's anonymous install id to the phone is a privacy call for the owner; it is a random UUID, but it is the Mac's analytics identity leaving the Mac.
4. Consent is asymmetric and the plan misstates it. T15 says "same opt-out as the usage-counts card"; that card is an opt-in ask, off by default. The phone is opt-out, on by default (D12). A joined funnel covers only the Macs that said yes. Either the plan says so, or T15 decides the settle log rides a separate consent, which PRODUCT.md would have to record.

Where to write it down: a data-only doc in the shared package, `audiout-shared/docs/analytics-events.md` beside `docs/adr/`, one table: event, which end sends it, properties, allowed values, with the values pointing at `CONTEXT.md` entries. Not `CONTEXT.md` itself: the glossary is the user-facing words and should stay that. Both apps' instruction files already say event names are an external contract (Mac `CLAUDE.md:175`); each points at the shared doc as the place names are decided. The site's events stay listed in its own `src/AGENTS.md`; they never join anything.

### (b) Every sentence the "measured with your iPhone" claim makes wrong

The task list gave nine anchors; three are wrong and the real list is longer. Everything below has to move in the one T20 pass, or the site contradicts itself on launch day.

Pages (`.astro`):

- `src/components/Features.astro:17-18` ("keeps every speaker on the same clock"; a sync claim, no "by ear"), `:145` (same claim), `:183` ("finds each speaker's delay by ear").
- `src/pages/index.astro:28-29` (the Airfoil FAQ; says nothing about measurement yet, and D3 puts the lead claim here), `:50` (SoundSource FAQ, "by ear"), `:54` (out-of-sync FAQ, "by ear"), `:37` (phone FAQ, "coming soon"), `:183-188` (hero, no sync claim).
- `src/pages/remote.astro:364-365` ("Sync calibration from the phone", "Coming soon", "by-ear wizard on the Mac"). This row inverts: the phone measures, Align by ear is the Mac's fallback.
- `src/pages/press.astro:71` (screenshot caption "The by-ear wizard"), `:31` ("coming soon").
- `src/layouts/Base.astro:22` (default og:image alt; describes the current card), `tools/og-card/card.html:98-99` (sub line) and `:147` (headline).

Support articles (`.md`):

- `src/pages/support/align-bluetooth-speaker.md:3-4` (title "Aligning a Bluetooth speaker by ear", description) and `:10` ("using nothing but your ears"). The article stays true, D3 keeps Align by ear, but it needs a lead line that offers the iPhone measurement first and names this as the fallback.
- `src/pages/support/speaker-types.md:28` ("a guided by-ear wizard that finds the right timing offset for you"), `:55` (table, "Yes, with SYNC trim").
- `src/pages/support/mixer-overview.md:36` and `src/pages/support/speaker-eq.md:39`: link text only, "Aligning a Bluetooth speaker by ear".
- There is no support article for measuring with the iPhone. `src/pages/support.astro:24` already lists an "Audiout Remote" category and no article carries it. T20 has to add one, or the support index says nothing about the lead claim.

Blog posts (`.md`):

- `src/pages/blog/airfoil-alternatives-mac.md:11` (FAQ frontmatter, "by ear"), `:70`, `:90` (table, "with a by-ear delay wizard"), `:110` ("by-ear alignment"). The plan's `:99` is a paragraph about Rogue Amoeba's prices. Plus `:76` and `:93` for "coming soon".
- `src/pages/blog/airplay-speakers-out-of-sync-fix.md:85`, `:99`.
- `src/pages/blog/multi-room-audio-mac.md:86` ("correctable by ear").
- `src/pages/blog/airplay-spotify-multiple-speakers-mac.md:85` ("the by-ear alignment wizard").
- `src/pages/blog/how-to-connect-multiple-bluetooth-speakers-mac.md:76` ("The whole thing is done by ear, with no measurement gear", the direct contradiction), `:82`.

Product record:

- Site `PRODUCT.md:174-178` says the phone "does not do sync calibration from the phone's microphone today" and that the site may say "coming soon" in one ledger row, never as a headline. The copy-review skill enforces that file. It changes first, or every rewrite above gets reverted by the next review. Site `CLAUDE.md` makes the Mac repo's `PRODUCT.md` the upstream authority, so that one moves with it.

## 3. Anchor check on T20 and T21

| Plan text | Actual | Fix |
|---|---|---|
| hero `src/pages/index.astro:189-193` | `:189-194` is the Buy button row; the headline and sentence are `:183-188` | `:183-188` |
| sync claims `Features.astro:17, 145, 183` | correct; 17 and 145 are "same clock" claims, 183 is the by-ear one | keep |
| sync claims `index.astro:56, 60` | `:56` opens the HomePod FAQ, `:60` opens the different-rooms FAQ; the by-ear answers are `:50` and `:54` | `:50, 54` |
| Airfoil FAQ `index.astro:34-35` | `:34-35` is the "What speakers" answer; the Airfoil FAQ is `:28-29` | `:28-29` |
| `/remote` page `remote.astro:112-122` | hero copy is `:113-125` (h1, sentence, pill); the measurement row `:364-365` and the description `:17-19` are not cited | `:113-125, 364-365, 17-19` |
| OG card `card.html:147` | correct (`headlineText`); the sub line at `:98-99` also carries the claim | add `:98-99` |
| stale alt `Base.astro:98-100` | `:94-100` is the font preload; the alt is the `imageAlt` default at `:22` | `:22` |
| "Coming soon pills gated on a store-link constant" | the constant exists and is read once, `remote.astro:14-15`; pills at `Features.astro:128`, `pricing.astro:33,121-123` (the Mac one), `buy.astro:137`, `press.astro:31`, `index.astro:37` are hard-coded | see plan change T20 |
| T21 "`/remote` redirects to the App Store when the constant is set" | no redirect exists; `worker.js:38-67` has no such branch; `_redirects` is not applied under `run_worker_first` per Cloudflare's docs; `/remote?subscribed=1` and `?unsubscribed=1` are landing pages | see plan change T21 |
| T21 "email template in the licence server, `src/`" | `src/email.ts:136-309` (`licenseEmail`), steps `:241`, text `:273-297`, tests `test/webhook.test.ts:46-66` | cite these |
| T21 "`/thanks` carries the badge" | `src/pages/thanks.astro:101-111` is the step list | cite it |
| T15 "same opt-out as the usage-counts card (`OnboardingViewController.swift:784-811`)" | that card is opt-in, off by default (Mac `CLAUDE.md:180`) | say opt-in |
| D15 "QR target is `audiout.app/remote`, which redirects to the store once live" | see section 1 | amend |

Two more facts the plan does not know: `public/appstore-qr.svg` does not exist yet (the runbook `HANDOFF-releases-2026-08-27.md` § "Audiout Remote (iPhone) launch" steps 1-2 says to generate and commit it with the env flip), and `remote.astro:423` still carries a TODO that the sheet icon is the Mac's artwork, not the phone's.

## Plan changes

1. T20, anchors: hero `index.astro:189-193` becomes `:183-188`; sync FAQ `index.astro:56, 60` becomes `:50, 54`; Airfoil FAQ `index.astro:34-35` becomes `:28-29`; `remote.astro:112-122` becomes `:113-125` plus `:17-19` and `:364-365`; `Base.astro:98-100` becomes `:22`; add `card.html:98-99`. Why: the cited lines are the button row, the wrong FAQs and the font preload.
2. T20, the full one-pass list: add `press.astro:31, 71`; `support/align-bluetooth-speaker.md:3-4, 10` (new lead paragraph, title kept); `support/speaker-types.md:28, 55`; `support/mixer-overview.md:36`; `support/speaker-eq.md:39`; `blog/airfoil-alternatives-mac.md:11, 70, 76, 90, 93, 110` (not `:99`); `blog/airplay-speakers-out-of-sync-fix.md:85, 99`; `blog/multi-room-audio-mac.md:86`; `blog/airplay-spotify-multiple-speakers-mac.md:85`; `blog/how-to-connect-multiple-bluetooth-speakers-mac.md:76, 82`; a new support article in the existing "Audiout Remote" category (`support.astro:24`, empty today) on measuring with the iPhone; and site `PRODUCT.md:174-178` first, with the Mac repo's `PRODUCT.md` in step. Why: nine anchors were listed, twenty-six sentences say by ear or coming soon, and the product record would revert the rewrite.
3. T20, the switch: add `src/lib/remote.ts` (`APP_STORE_URL`, `REMOTE_LIVE`, `APP_STORE_ID`, `REMOTE_SENTENCE`, reading `PUBLIC_APP_STORE_URL` once through `checkout.ts`'s `unconfigured`) and `src/components/RemoteBadge.astro` on the `BuyButton.astro` pattern; move `remote.astro:14-15` and every hard-coded phone mention onto it: `Features.astro:128-130`, `index.astro:37`, `pricing.astro:33, 41`, `buy.astro:137-138`, `press.astro:31`, `remote.astro:364-365`. Reword `blog/airfoil-alternatives-mac.md:76, 93` now to be true in both states. Why: today the constant flips one page and five keep saying coming soon; markdown cannot read a constant.
4. T21, drop the redirect: `/remote` stays a page in both states; once live the badge links to the store (already built) and the page carries Apple's Smart App Banner meta from `APP_STORE_ID`. QR and email target `audiout.app/remote` unchanged. Amend D15's "redirects to the store once live" to "carries the store badge and Safari's App Store banner once live". If a redirect is kept anyway, give it its own path in `worker.js` (never `/remote` itself) and fix that path before T16 ships. Why: `_redirects` is not applied under `run_worker_first` (Cloudflare docs), `worker.js` cannot read the env switch, and `/remote?unsubscribed=1` is the licence server's landing page (`src/index.ts:396, 405`).
5. T21, the email: a fourth setup step in `licenseEmail` (`src/email.ts:241` and the text twin `:284`) linking to `${origin}/remote` with wording that is true before and after launch, no badge image, no server-side switch; one assertion in `test/webhook.test.ts`. Why: the server then plays no part in the flip, the SVG badge does not render in mail clients, and `email.ts:125-130` needs the row to read as setup, not promotion.
6. T21, `/thanks`: fourth step at `thanks.astro:101-111` using `RemoteBadge` and `REMOTE_SENTENCE`. Why: the badge only appears there once the page reads the switch.
7. T21, release-day mechanics: the flip is the runbook already in `HANDOFF-releases-2026-08-27.md` § "Audiout Remote (iPhone) launch" (generate `public/appstore-qr.svg`, set `PUBLIC_APP_STORE_URL` in `.env.production`, one commit, `npm run guard:production`, `CONFIRM_PROD=yes npm run deploy:production`), plus a launch-shape check: no `soon-pill` in `dist/*.html`, `downloadUrl` and `InStock` in `dist/remote.html`, the banner meta present. Remove `scripts/launch.sh:86-87, 133` (they assert the phone is still coming soon), fix `.env.production:5` ("it is OFF" is stale since f075f37), and resolve `remote.astro:423` (sheet icon is the Mac's artwork). Why: the plan says "site flips the same day" without naming the command, and the old script would fail on re-run.
8. T11, names and properties: phone events take the Mac's `category:object_action` form (`intro:card_seen`, `intro:find_mac_tapped`, `connect:connected`, `demo:entered`, `sync:opened`, `sync:measure_tapped`, `sync:verdict`, `sync:recheck_accepted`, `sync:by_ear_nudged`); every `sync:` event carries `source: phone`, and the shared properties `verdict`, `offset_source`, `settled`, `speaker_kind`, `offset_ms_bucket` with the glossary's values; every event carries `mac_id` once T2 provides it. Why: the Mac's `CLAUDE.md:178` fixes the naming form, and the planned bare names cannot be queried beside the Mac's.
9. T15, consent and names: replace "same opt-out as the usage-counts card" with "same opt-in as the usage-counts card, off by default"; name the events `sync:settled` (`codec`, `jump_count`, `settle_seconds_bucket`, `speaker_kind`, `source: mac`) and `sync:offset_applied` (`offset_source`, `offset_ms_bucket`). State that a joined funnel covers only Macs that opted in, or decide a separate consent for the settle log and record it in PRODUCT.md. Why: `OnboardingViewController.swift:784-811` is an opt-in ask (Mac `CLAUDE.md:180`), and D12 makes the phone opt-out.
10. T2, join key (owner's call): add an optional `serverID` (the Mac's `installID`) to `welcome`, additive, no version bump. Why: without a shared key a PostHog funnel cannot span two devices; with it, group analytics or one HogQL join gives the one query T22 wants to watch. Privacy note: the Mac's anonymous analytics id would reach the phone.
11. New Phase 0 task, T2a: `audiout-shared/docs/analytics-events.md`, data only, one table of event, sending end, properties, allowed values, values referencing `CONTEXT.md`; both apps' instruction files point at it. Why: event names are an external contract on the Mac already and the phone is about to add nine more with no shared list.
12. D15: reword "QR target is `audiout.app/remote`, which redirects to the store once live" to "QR target is `audiout.app/remote`, a page in both states; once live it carries the store badge and Safari's App Store banner". Why: item 4.
