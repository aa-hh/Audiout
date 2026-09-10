# Shape brief: the site's sync claim after the phone measures

2026-09-06. Impeccable `shape` with `clarify` guidance, mode Persuade, on the Audiouter Website (Astro). No code was written and no repo file edited; this file is the only output. Nobody could be interviewed, so every assumption is marked as one.

Sources read: the site's PRODUCT.md, DESIGN.md and BRAND-VOICE.md; the audiout-copy-review skill; PLAN-REMOTE-RELEASE.md (D2, D3, D4, D15, T20, T21); the glossary `audiout-shared/CONTEXT.md`; the research note `bt-latency-stability-research-2026-09-05.md`; every site file named below, plus the Mac and phone sources the claims depend on.

(A note on wording: this brief repeats "the switch that says whether the App Store link exists" instead of giving that switch a name, and says "a Bluetooth speaker that plays behind" every time instead of a shorthand. That is the no-invented-terms rule doing it. The code name for the switch is the builder's to pick.)

## 1. What is true, and what the site may say

Every claim below was checked in source. The site must not go past them.

- **The phone measures Bluetooth speakers only.** The Mac fills the phone's per-speaker sync state only for `device.kind == .bluetooth` (`AudioutCore/Sources/AudioutCore/CompanionSnapshotBuilder.swift`, `alignmentState(for:)`), and the phone shows its Sync control only when that state is present (`audiout-remote/AudioutRemote/UI/Speakers/DeviceRowView.swift:462`). AirPlay speakers are the reference and carry no sync control on the Mac either (`PopoverController.swift:2934`, `isTrimmable`). So every sentence that says "measured with your iPhone" has to sit next to the word Bluetooth, or it claims something the product does not do.
- **The test sound is one second long.** `ProbeAnalyzer.sweepSeconds = 1.0` in audiout-shared and `AlignmentTickInjector.probeSweepSeconds = 1.0` on the Mac. "In one second" is backed. The phone's own invite card says "Takes seconds." (`SyncInviteCard.swift:108`); the two surfaces should agree, see open decision 6.
- **How it works, in words a buyer can check:** the Mac plays a one-second test sound from the Bluetooth speaker and from a reference speaker at the same moment; the iPhone's microphone hears both; the gap between the two arrivals is how far behind the Bluetooth speaker plays; the Mac corrects it (glossary, "Measurement"; ProbeKit's type note).
- **It refuses rather than guesses.** A capture that cannot be read throws (`recordingTooShort`, `probeNotFound`); the phone's sheet puts the by-ear page beside every refusal (`SyncSheet.swift` header comment). "It never guesses a number" is a true and unusual trust claim. "It always works" is not.
- **What the research does not support:** no "perfectly", no "to the millisecond", no "set it once and it holds". Bluetooth latency lands in a 20 to 90 ms band around its mean each time a stream starts (SoundSeeder, SoundGuys, via the research note), and Apple's stack drifts about 60 ms over 20 to 30 minutes. The remembered-offset and re-check behaviour (plan D10, T14) is the answer to that; the site may describe it only once T14 has shipped, and in the app's own words ("Timing from last time", "first pass").
- **The Mac's fallback is called Align by ear** (D3, glossary). One clash to know about: in the Mac app the drawer button labelled "Align by ear" (`BTSyncDrawerView.swift:286`) toggles the metronome tick, while the guided click wizard's door is "Align speaker…" (`DeviceRowView.swift:2157`). The site follows D3 and the glossary: "Align by ear" means the paired-click wizard. The Mac repo owns that clash (see open decision 8).
- **Competitive facts** (verified by the caller today, not by me): Airfoil ($35) lines its outputs up to the slowest one and gives a manual slider per speaker; it has a free iPhone remote (Airfoil Satellite) and Bluetooth output. SoundSource ($49) has no remote and no measurement. Neither measures a speaker. The phone as a remote is parity and is never pitched as an advantage.
- **Vocabulary.** The glossary's word for the number is "offset" (avoid trim, delay, latency). The copy-review skill's table agrees ("sync offset" for the value, "Sync" for the control, never "sync calibration"). The copy below describes the problem as a speaker that "plays behind" and names the value "offset" only in support articles. Existing site copy says "delay" and "trim" throughout; only the lines this brief touches are changed.

## 2. Job and audience

A Mac owner with more than one speaker, arriving cold, mid-task, deciding whether to pay an unknown developer 30 euro. Mode Persuade. The site carries the whole trust burden: no reviews, no press. The buyer is Mac-first (D2); the phone is included, never sold, never the reason to buy on its own.

What changes: until now the site sold "every app on every speaker, in sync", and the Bluetooth fix was a by-ear wizard on the Mac. Now the differentiator against Airfoil and SoundSource is that Audiout measures a Bluetooth speaker that plays behind, with the buyer's own iPhone, in one second. Neither competitor measures anything. The phone is the ear, and the remote part is parity.

## 3. Outcome and proof

Primary action: Buy Audiout. Secondary: the visitor understands, before opening the app, that AirPlay speakers stay on one clock by themselves and a Bluetooth speaker that plays behind gets measured with the iPhone.

Proof on hand: the mechanism (one-second test sound, two arrivals, one gap), the refusal behaviour, the working demos already on the page. No numbers beyond "one second" and "30 euro". No user counts, no benchmarks.

## 4. Selected direction

Copy-led refinement inside the existing visual world. DESIGN.md is untouched: same hero, same marquees, same ledger, same pills. The measurement leads on every surface that states the sync claim, always scoped to Bluetooth, always with the Mac's Align by ear named as the fallback so nobody without an iPhone feels locked out.

The /remote page's job changes from "the faders in your hand" to "the remote that tunes your speakers" (D4's subtitle, the owner's words). It gets one new marquee for the measurement, its "Sync calibration from the phone" ledger row goes, and its FAQ answers the three questions the new lead raises: which speakers, how, and what about the microphone.

Comparison copy (the Airfoil FAQ, the blog table) states parity as parity. Airfoil has a free remote and Bluetooth output; so does Audiout. The one difference is measurement, and it is stated once, plainly, next to what Airfoil does instead.

## 5. Scope and boundaries

In scope: every line listed in section 7. The store-link switch and what each surface renders on either side of it. One new support article and the edits that point at it. Blog lines that describe the by-ear wizard as the only fix.

Out of scope, do not touch: DESIGN.md tokens and components; the Mac checkout switch and its "Coming soon" bar; the /buy funnel beyond one fine-print line; the licence email (licence-server repo, T21); the Mac app's own strings; the phone app's strings; the Phone demo component's internals (see open decision 3).

Anti-goals: no claim that AirPlay speakers are measured; no "coming soon" text left hard-coded once the switch exists; no new hue, no new pill style; no question-form headline (the /remote buy band's "Don't have Audiout yet?" stays the only one); no em dashes in new copy.

## 6. States: before and after the App Store link exists

Today only `remote.astro` reads `PUBLIC_APP_STORE_URL` (through the `unconfigured` helper from `src/lib/checkout.ts`). Every other "coming soon" about the phone is hard-coded: `Features.astro:128-130`, `index.astro:37`, `pricing.astro:33` and `:41`, `buy.astro:137-138`, `press.astro:31`, and the blog markdown.

Proposed mechanism, matching the existing pattern for the Mac checkout: export the phone's switch and the store URL from `src/lib/checkout.ts` next to `CHECKOUT_LIVE`, and have `remote.astro` import it instead of computing its own. Every `.astro` page then branches on that one export. Markdown pages cannot branch, so their phone sentences become time-neutral and link to /remote for the current status (section 7, blog).

Before the link (switch unset):

- Home hero subhead, phone cell, pricing bullet, buy fine print, press line, home FAQ: "Audiout Remote, the free iPhone app, is coming soon. It is included with Audiout for Mac and works with the Mac you allow it on." The pills stay where they are today.
- /remote: as today. Hero pill "Coming soon to the App Store", the email signup form as the primary action, no badge, the bottom install card's "Coming soon. Get an email when it ships." link, JSON-LD PreOrder.
- /thanks: no phone mention (assumption, see open decision 5).

After the link (switch set):

- Every pill is gone. Every phone sentence reads "free on the App Store, included with Audiout for Mac, works with the Mac you allow it on" (BRAND-VOICE rule 7).
- /remote: the badge takes the hero action slot, the form disappears, the install card shows badge plus QR, JSON-LD InStock with downloadUrl. All of this is already built; it only moves onto the shared switch.
- /thanks: the install card (badge plus QR) under the three steps. The QR is the invite a buyer sees on the Mac screen and scans with the phone; that is the whole point of a QR there.
- The QR image `public/appstore-qr.svg` does not exist yet. D15 says the QR target is `audiout.app/remote`, which redirects to the store once live; the site's own `.env.staging` comment expected the QR to encode the store URL directly. Open decision 1.

## 7. Proposed copy, line by line

Line numbers are the file as it is today. Where the plan or the request cited other numbers, the current ones are given and the drift noted.

### `src/pages/index.astro`

**:183, hero H1.** Now: `Every speaker in the house. Any app on your Mac.`

Recommended: `Every speaker in the house. Any app on your Mac. The one that plays behind, measured with your iPhone.`

This is the only version that is complete (the Mac, every app, every speaker) and true (only the speaker that plays behind is measured). Cost: three sentences at display size wrap to three or four lines at 1140px, and the OG card's headline column has to fit it. The builder checks both. Alternative if the owner wants two sentences: `Every speaker in the house. Measured with your iPhone.` It drops the core promise from the H1 and lets a reader join the two sentences into "every speaker is measured", which the subhead then has to correct. Open decision 2.

(The request cited :189-198 for the hero; those lines are the actions block. The plan's T20 cites :189-193, same drift.)

**:184-188, hero subhead.** Now: `Audiout plays Spotify, the browser, a game, anything your Mac plays, on all your AirPlay, Bluetooth and Chromecast speakers at once, with a fader per room.`

After the link: `Audiout plays Spotify, the browser, a game, anything your Mac plays, on all your AirPlay, Bluetooth and Chromecast speakers at once, with a fader per room. When a Bluetooth speaker plays behind the others, Audiout Remote measures how far behind with your iPhone's microphone. It takes one second, and your Mac corrects it. The remote is free on the App Store, included with Audiout for Mac, and works with the Mac you allow it on.`

Before the link: same first three sentences, then `The remote is a free iPhone app, coming soon, included with Audiout for Mac, and works with the Mac you allow it on.`

Rule 7 costs the hero a full sentence. If the owner would rather the hero carry only "included with Audiout for Mac" and leave "works with the Mac you allow it on" to the phone cell one screen down, that is open decision 4.

**:11-12, DESCRIPTION (meta).** Unchanged. It is at the length search results show; adding the measurement pushes it past. Note only.

**:172, title.** Unchanged.

**:28-30, the Airfoil FAQ.** Now: `Both send Mac audio to AirPlay speakers. Audiout is built for the whole house: every app, every speaker, in sync, with a fader per room in the menu bar, plus Bluetooth and Chromecast on the same mixer. It's a one-time €30 purchase. The source is public on GitHub under GPL-2.0, and what you're paying for is the signed, notarized, maintained build.`

Proposed: `Both send Mac audio to AirPlay and Bluetooth speakers, and both have a free iPhone remote. The difference is what happens when a speaker plays behind the others. Airfoil lines its outputs up to the slowest one and gives you a slider per speaker to set by hand. Audiout Remote measures how far behind a Bluetooth speaker plays with your iPhone's microphone, in one second, and your Mac corrects it. Audiout also puts every app on one mixer at once, with a fader per room in the menu bar, and Chromecast beside AirPlay and Bluetooth. It's a one-time €30 purchase. The source is public on GitHub under GPL-2.0, and what you're paying for is the signed, notarized, maintained build.`

Parity is stated as parity (remote, Bluetooth). The Airfoil description is specific and checkable (BRAND-VOICE rule 2), and the blog's existing note to check Rogue Amoeba's site for current details covers the rest. Prices of the competitors are not stated; they change, and the answer is not about price.

**:36-38, the per-speaker volume FAQ.** Now ends: `Audiout Remote, the free iPhone app, is coming soon. It is included with Audiout for Mac and puts the same faders on your phone.`

After the link: `Audiout Remote, the free iPhone app, is included with Audiout for Mac and puts the same faders on your phone. It works with the Mac you allow it on.` Before: as today. Branch on the switch; the `link` entry keeps working because "Audiout Remote" is still in the text.

**:49-51, the SoundSource FAQ.** Now contains: `...scenes bring a set of speakers back in one click, and a guided tool finds each speaker's delay by ear.`

Proposed replacement for that clause: `...scenes bring a set of speakers back in one click, and Audiout Remote measures a Bluetooth speaker that plays behind with your iPhone's microphone. SoundSource has no remote and no measurement.` The last sentence is the verified fact stated flat, not a put-down. (The plan's T20 cites :56 for this answer; it is :50.)

**:53-55, the out-of-sync FAQ.** Now ends: `...and if one room still sounds ahead or behind, a guided tool in the app finds that speaker's delay by ear and corrects it.`

Proposed: `...Audiout keeps the AirPlay speakers on its mixer playing in sync. A Bluetooth speaker plays behind by an amount of its own. Audiout Remote measures it with your iPhone's microphone in one second, and your Mac corrects it. Without an iPhone, the Mac's Align by ear finds it from paired clicks.` (Plan cites :60; it is :54.)

**New FAQ entry, after :55.** The new lead raises an objection the page must answer for anyone without an iPhone.

q: `Do I need an iPhone to keep my speakers in sync?`
a: `No. AirPlay speakers stay on one clock by themselves. A Bluetooth speaker that plays behind can be measured with an iPhone, or aligned by ear on the Mac from paired clicks. The iPhone is the faster way, not the only way.`

### `src/components/Features.astro`

**:17-19, the sync marquee support line.** Now: `Audiout keeps every speaker on the same clock. Walk from the kitchen to the bedroom and nothing drifts.`

Proposed: `Audiout keeps every AirPlay speaker on the same clock. A Bluetooth speaker that plays behind gets measured with your iPhone and corrected. Walk from the kitchen to the bedroom and nothing drifts.` Headline :15 stays.

**:127, phone cell headline.** Now: `Your phone is a remote.` Proposed: `Your iPhone is the remote and the microphone.`

**:128, the pill.** Render only while the switch is unset.

**:129-131, phone cell support.** Now: `Audiout Remote, the free iPhone app, is coming soon. It mirrors your Mac, fader for fader. Included with Audiout for Mac, and it works with the Mac you allow it on.`

After the link: `Audiout Remote mirrors your Mac, fader for fader, and measures a Bluetooth speaker that plays behind with the phone's microphone. Free on the App Store, included with Audiout for Mac, and it works with the Mac you allow it on.`

Before: `Audiout Remote mirrors your Mac, fader for fader, and measures a Bluetooth speaker that plays behind with the phone's microphone. The free iPhone app is coming soon. Included with Audiout for Mac, and it works with the Mac you allow it on.`

**:143-146, the shelf support line.** Now: `AirPlay, Bluetooth, Chromecast. Audiout speaks them all and keeps every speaker on the same clock.`

Proposed: `AirPlay, Bluetooth, Chromecast. Audiout speaks them all and keeps every speaker on the same clock. A Bluetooth speaker that plays behind is measured with your iPhone.`

**:182-183, ledger "Tune away the echo".** Title stays. Description now: `A guided tool with a metronome tick finds each speaker's delay by ear, so rooms stop echoing each other.`

Proposed: `Audiout Remote measures a Bluetooth speaker that plays behind with your iPhone's microphone, in one second, and your Mac corrects it. Without an iPhone, the Mac's Align by ear finds it from paired clicks.`

### `src/pages/remote.astro`

**:14-15.** Import the switch and URL from `src/lib/checkout.ts` instead of computing them here.

**:17-19, DESCRIPTION.** After the link: `Measure a Bluetooth speaker that plays behind with your iPhone's microphone, set each speaker's volume, and move an app to another room. Audiout Remote is free on the App Store and included with Audiout for Mac. It works with the Mac you allow it on.` Before: same first sentence, then `Audiout Remote, the free iPhone app, is coming soon. It is included with Audiout for Mac and works with the Mac you allow it on.`

**:100, title.** Now: `Audiout Remote — the free iPhone remote for Audiout for Mac`. Proposed: `Audiout Remote — the free iPhone remote that tunes your Mac's speakers`. (The title keeps its single dash; rule 16 exempts it.)

**:113, H1.** Now: `Every speaker, in your hand.` Proposed: `The remote that tunes your speakers.` This is D4's subtitle, so the store listing and the page say the same thing.

**:114, hero support.** After the link: `Audiout Remote puts every fader in your hand and uses your iPhone's microphone to measure a Bluetooth speaker that plays behind. Free on the App Store, included with Audiout for Mac, and it talks to your Mac over your own Wi-Fi.` Before: first sentence the same, then `Audiout Remote, the free iPhone app, is coming soon. It is included with Audiout for Mac, and it talks to your Mac over your own Wi-Fi.`

**:121-125, :135-179, :184-199.** Behaviour unchanged; only the switch's source moves.

**:211-240, "How it connects."** Unchanged. It is the rule-7 block for the whole page.

**New marquee, first inside `#features` (before :247).** Same `feat-marquee` markup as its siblings.

h3: `Measure the speaker that plays behind.`
p: `Both speakers play a one-second test sound at the same moment. Your iPhone's microphone hears both, and the gap between them is how far behind the Bluetooth speaker plays. Your Mac corrects it and keeps the number for that speaker.`

The visual is open (decision 3): the Phone component has speakers, apps and mainout tabs and no sync state.

**:249-255, :262-267, :274-280.** Unchanged.

**:289, "What else the remote does."** Unchanged.

**:359-367, the last ledger row.** Now: title `Sync calibration from the phone` with a pill; description `Today a guided by-ear wizard on the Mac times a lagging Bluetooth speaker. Running it from the phone is planned and not in the app yet.` "Sync calibration" is on the never list. Replace the row with two:

Title: `It says so when it can't hear.` Description: `If the phone can't pick out both test sounds, the app says so and offers to try again or to align by ear. It never guesses a number.`

Title: `Nudge it by ear.` Description: `After a measurement, a tick plays from both speakers while you nudge the number until they land together. Without an iPhone at all, the Mac's Align by ear finds it from paired clicks.`

Delete the `.ledger-item .soon-pill` rule at :704-710 once no ledger row carries a pill.

**:27-56, FAQ.** Add three entries after :51 ("What do I need to run Audiout Remote?"):

q: `Which speakers can Audiout Remote measure?`
a: `Bluetooth speakers. AirPlay speakers stay on one clock by themselves and need no measuring. Chromecast speakers are compensated on the Mac.`

q: `How does the measurement work?`
a: `Your Mac plays a one-second test sound from the Bluetooth speaker and from a reference speaker at the same moment. Your iPhone's microphone hears both. The gap between the two arrivals is how far behind the Bluetooth speaker plays, and your Mac corrects it. Your phone sends your Mac the number, not the sound.`

q: `Does Audiout Remote need the microphone?`
a: `Only for measuring. iOS asks once, before the first measurement. Volume, routing and scenes work without it.`

The last sentence of the second answer ("the number, not the sound") must be confirmed against the phone's report command before it ships; the protocol carries milliseconds, but the builder verifies nothing else rides with it.

**:385-396, buy band; :416-450, install card.** Unchanged apart from the switch's source.

### `src/pages/pricing.astro`

(The request cited :45-51; that is the schema block. The copy is :33 and :41.)

**:33, third feature bullet.** Now: `Free iPhone remote (coming soon). It works with the Mac you allow it on.` After the link: `Free iPhone remote that measures a Bluetooth speaker that plays behind. It works with the Mac you allow it on.` Before: `Free iPhone remote that measures a Bluetooth speaker that plays behind (coming soon). It works with the Mac you allow it on.` The `FEATURES` array's third entry becomes a ternary on the switch; the comment at :31-32 is rewritten to name the switch.

**:41, DESCRIPTION.** `...Audiout Remote, the free iPhone app, is coming soon.` becomes `...is included.` after the link, `...is coming soon.` before.

### `src/pages/buy.astro`

**:137-138, fine print.** After the link: `Audiout Remote, the free iPhone app, is included and works with the Mac you allow it on. It measures a Bluetooth speaker that plays behind with the phone's microphone.` Before: as today.

### `src/pages/press.astro`

**:31.** After the link: `Companion: Audiout Remote, the free iPhone app, measures a Bluetooth speaker that plays behind with the phone's microphone. Free on the App Store, included with Audiout for Mac.` Before: as today. **:71** (screenshot caption, "The by-ear wizard asking...") stays; it describes the Mac screenshot accurately.

### `src/layouts/Base.astro`

**:22, the OG image alt.** (The request cited :98-100; those lines are the font preload. :47 is a comment about the checkout switch.) Now describes the old H1. Proposed, matching the recommended H1: `Audiout — the words Every speaker in the house. Any app on your Mac. The one that plays behind, measured with your iPhone. beside the Audiout speaker mark, with green sound waves rippling out from it in the dark`. Whatever H1 the owner picks, the alt quotes it.

**:123, announce bar.** Unchanged; it is the Mac checkout state.

### `tools/og-card/card.html`

**:147, `headlineText`.** `"Every speaker in the house.\nAny app on your Mac.\nThe one that plays behind,\nmeasured with your iPhone."` at `headlineSize` 64. Four lines at 64px is about 264px from cap top 152, ending near 416; the sub's baseline is 423. The builder either drops `headlineSize` to 56 or moves the sub's baseline down, then re-renders with `build.sh` and reads the measurement dump. If the owner picks the two-sentence H1, none of this is needed.

**:98-99, the sub.** Now: `Spotify, the browser, a game.` / `On AirPlay, Bluetooth and Chromecast, in sync.` Proposed: `Spotify, the browser, a game, on every speaker.` / `A Bluetooth speaker that plays behind, measured with your iPhone.`

Rebuild `public/og.png` from the card after the change; the alt in Base.astro and the card must say the same words.

### Support articles

**New: `src/pages/support/measure-speaker-with-iphone.md`**, category Speakers, order 4. The by-ear article moves to order 5 so the measured path lists first. Frontmatter title: `Measuring a Bluetooth speaker with your iPhone`. Description: `Use Audiout Remote and your iPhone's microphone to find how far behind a Bluetooth speaker plays, in one second, and let your Mac correct it.`

Body, the claims it may make (the builder writes the page from these and nothing more):

- Bluetooth adds its own delay; left alone that speaker plays a fraction of a second behind the others and you hear an echo. Audiout fixes this with an offset, in milliseconds, kept per speaker.
- Open Audiout Remote on the same Wi-Fi, find the Bluetooth speaker's row, and open its Sync control. Both speakers have to be playing.
- iOS asks for the microphone once. The app uses it only while measuring.
- Take the phone to where you normally listen, somewhere both speakers reach you, and hold still.
- Tap Measure. Both speakers play a one-second test sound. The phone hears both, works out the gap, and your Mac applies it. The row shows the offset.
- If the speaker connected moments ago, the app may call the result a first pass and re-check once the speaker has settled (glossary; plan D9). Include only if T7 has shipped.
- On reconnect the speaker starts with "Timing from last time" until a new measurement replaces it (plan D10). Include only if T14 has shipped.
- If it cannot hear both test sounds clearly, it says so and offers to try again or to align by ear. It never guesses. Usual causes: a noisy room, or standing where only one speaker reaches you.
- Without an iPhone, use Align by ear on the Mac: link to the by-ear article.
- Related links as the sibling article has them.

**`src/pages/support/align-bluetooth-speaker.md`.** Title stays; it documents the by-ear path. **:4** description: append `This is the fallback for when no iPhone is in the room.` **:10** gains a first paragraph before the current one: `The fastest way to fix a Bluetooth speaker that plays behind is to measure it with your iPhone: [Measuring a Bluetooth speaker with your iPhone](/support/measure-speaker-with-iphone). This article covers the by-ear path on the Mac, for when no iPhone is in the room.` The rest of the article is unchanged; its "trim" wording is off the glossary (open decision 7) but rewriting it is not this brief.

**`src/pages/support/speaker-types.md:28`.** Now: `Bluetooth adds its own delay, so these rows carry a SYNC trim chip, and the row's context menu has "Align speaker…", a guided by-ear wizard that finds the right timing offset for you. [Aligning a Bluetooth speaker by ear](/support/align-bluetooth-speaker) walks through it.`

Proposed: `Bluetooth adds its own delay, so these rows carry a SYNC chip. The fastest fix is to measure the speaker with your iPhone: [Measuring a Bluetooth speaker with your iPhone](/support/measure-speaker-with-iphone). Without an iPhone, the row's context menu has "Align speaker…", which finds the offset by ear: [Aligning a Bluetooth speaker by ear](/support/align-bluetooth-speaker).`

**`speaker-types.md:55`**, table cell `Yes, with SYNC trim` becomes `Yes, measured with your iPhone or aligned by ear`.

**`src/pages/support/mixer-overview.md:36`.** `...(see [Aligning a Bluetooth speaker by ear](/support/align-bluetooth-speaker)).` becomes `...(see [Measuring a Bluetooth speaker with your iPhone](/support/measure-speaker-with-iphone), or [Aligning a Bluetooth speaker by ear](/support/align-bluetooth-speaker) without an iPhone).`

**`src/pages/support/speaker-eq.md:39`.** `For a Bluetooth speaker, use the SYNC chip on its row or the guided wizard instead: [Aligning...]` becomes `For a Bluetooth speaker, measure it with your iPhone, or use the SYNC chip on its row: [Measuring a Bluetooth speaker with your iPhone](/support/measure-speaker-with-iphone), [Aligning a Bluetooth speaker by ear](/support/align-bluetooth-speaker).`

### Blog posts

Markdown cannot read the switch, so these lines are written to stay true on both sides of it. Where the phone's availability matters, the line points at /remote.

**`src/pages/blog/airfoil-alternatives-mac.md`** (published 2026-10-02, likely before the store link exists):

- **:11** (FAQ answer). Now ends: `Audiout also has a guided wizard that finds a Bluetooth speaker's delay by ear and stores it per speaker.` Proposed: `Audiout also measures a Bluetooth speaker that plays behind with your iPhone's microphone, through its free Audiout Remote app, and keeps the result per speaker. Neither Airfoil nor SoundSource measures a speaker.`
- **:70**. `...and a guided by-ear wizard finds the delay a Bluetooth speaker adds so it lands with the rest.` becomes `...and a Bluetooth speaker that plays behind is measured with your iPhone, through the free Audiout Remote app, so it lands with the rest. Without an iPhone, the Mac aligns it by ear.`
- **:76**. Now: `**A phone remote, coming soon.** [Audiout Remote](/remote) will mirror the Mac's faders on your iPhone. It is not on the App Store yet.` Proposed: `**A phone that measures.** [Audiout Remote](/remote), the free iPhone app included with Audiout for Mac, mirrors the Mac's faders and measures a Bluetooth speaker that plays behind with the phone's microphone. Airfoil's free remote mirrors faders too; measuring is the difference. The /remote page says whether it is on the App Store yet.`
- **:90**, table row `Bluetooth speakers on the same mixer as AirPlay`: Audiout cell becomes `Yes` (parity, no adornment).
- **New row after :90**: `| Measures how far behind a speaker plays | No, a slider per speaker set by hand | No | No | Yes, with your iPhone's microphone |`
- **:93**, table row `Phone remote`: Airfoil cell `Airfoil Satellite (iOS), free`; Audiout cell `Audiout Remote, free` (availability is on /remote; the table does not date itself).
- **:108**. `...and Bluetooth speakers on the same mixer as AirPlay.` becomes `...and a Bluetooth speaker that plays behind measured with your iPhone.`
- **:110**. `...and by-ear alignment for the Bluetooth speaker that lags.` becomes `...and your iPhone measuring the Bluetooth speaker that plays behind.`

**`src/pages/blog/how-to-connect-multiple-bluetooth-speakers-mac.md`:**

- **:76**. Now describes the wizard as the whole fix and ends `The whole thing is done by ear, with no measurement gear.` Proposed: `**The speakers play together.** Bluetooth rows in the mixer carry a SYNC chip. The fastest fix is Audiout Remote, the free iPhone app included with Audiout for Mac: both speakers play a one-second test sound, the phone's microphone hears both, and the Mac corrects the gap. Without an iPhone, the row's Align speaker menu item opens a guided wizard that plays a click from two speakers and asks which you heard first, about fifteen rounds, and keeps the result. [Measuring a Bluetooth speaker with your iPhone](/support/measure-speaker-with-iphone) and [Aligning a Bluetooth speaker by ear](/support/align-bluetooth-speaker) walk through each.`
- **:82**. Now: `One limit, stated plainly. The trim is a fixed number. Most speakers add the same delay every time they connect, and the trim holds. A speaker whose own timing wanders from one session to the next will need re-aligning now and then, and the SYNC chip is there to nudge it.` The research note contradicts "most speakers add the same delay every time they connect" (a 20 to 90 ms band per stream start). Proposed: `One limit, stated plainly. A Bluetooth speaker does not add exactly the same delay every time it connects; the number lands somewhere in a band around its usual value. Audiout keeps the last measurement per speaker, and a re-measurement with the phone takes one second, so a speaker that has drifted is quick to bring back.` If T14 ships, add: `On reconnect it starts from the last timing and offers a re-check once the speaker has settled.`
- **:84**. `...the by-ear alignment is the piece macOS is missing...` becomes `...measuring the lagging one with your iPhone is the piece macOS is missing...`

**`src/pages/blog/multi-room-audio-mac.md:86`.** Now: `**In sync, correctable by ear.** AirPlay speakers are kept on the same clock. A Bluetooth speaker, which adds its own delay, gets a guided by-ear wizard that finds its timing offset and stores it per speaker.` Proposed: `**In sync, measured where it matters.** AirPlay speakers are kept on the same clock. A Bluetooth speaker, which plays behind by an amount of its own, is measured with your iPhone through the free Audiout Remote app, or aligned by ear on the Mac, and the result is kept per speaker.`

**`src/pages/blog/airplay-speakers-out-of-sync-fix.md`:**

- **:85**. Now describes the wizard only. Proposed: `For the stubborn cases, the pair of speakers that disagree no matter what, Audiout measures the gap. Audiout Remote, the free iPhone app included with Audiout for Mac, has both speakers play a one-second test sound, hears both through the phone's microphone, and hands your Mac the gap to correct. Without an iPhone, the Mac's Align by ear plays a click from two speakers and asks which you heard first, round after round, until it has the number. Either way the result is kept per speaker, and you can nudge it later from the speaker's row.` Note that this post's cases include a TV that delays its own audio; the phone measures Bluetooth speakers only, so the by-ear sentence has to stay for the TV case.
- **:99**. `...and closes a fixed gap between two speakers with a by-ear alignment wizard that stores a per-speaker delay.` becomes `...and closes a fixed gap between two speakers, measured with your iPhone or aligned by ear, kept per speaker.`

**`src/pages/blog/airplay-spotify-multiple-speakers-mac.md:85`.** `...covers the causes and the by-ear alignment wizard in depth.` becomes `...covers the causes, the iPhone measurement, and the by-ear fallback in depth.`

**`src/pages/blog/per-app-volume-mac.md`.** Named in the request; it has no by-ear sentence (checked: lines 13, 28, 30, 39, 52, 72, 91 are the only sync or phone mentions and none describe the wizard). No change.

### `src/pages/thanks.astro` (plan T21)

After the link, under the three steps at :101-110: the install card from /remote (icon, "Audiout Remote", "Free on the App Store", badge, QR) with one line above it: `Audiout Remote, the free iPhone app, is included. Scan to put it on your iPhone.` Before the link: nothing (open decision 5).

## 8. Design system delta

No token, colour, type or spacing change. Three notes for the builder:

- The install card markup (`.sheet` in `remote.astro:420-447`) already appears twice on /remote and would appear a third time on /thanks. Extracting it into one component is the builder's call; the styles at `remote.astro:561-645` move with it.
- The new /remote marquee reuses `feat-marquee` and `feat-copy` as its siblings do. No new layout.
- `.soon-pill` and `.soon-ribbon` stay as they are. The only pill change is which switch shows them.

## 9. Open decisions (the builder must not invent these)

1. **What the QR encodes, and what `/remote` does once the store link exists.** Plan D15 fixes the QR target as `audiout.app/remote`, "which redirects to the store once live", and T21 says `/remote` redirects when the switch is set. The site's own `.env.staging` note expected the QR to encode the store URL. If the whole `/remote` route redirects, the marketing page vanishes for every desktop visitor. Recommendation: every QR (site, Mac app, licence email) encodes `https://audiout.app/remote`; `worker.js` sends only iPhone user agents to the store when the switch is set and serves the page to everyone else. The owner decides; the redirect logic needs the store URL to reach the worker, which is a build or config detail once decided.
2. **The hero H1.** Three sentences (recommended, complete and true, taller) or two (shorter, drops "Any app on your Mac", leans on the subhead to scope the claim). Section 7 has both.
3. **The measurement visual.** The Phone demo component has no sync state, and the home page's phone cell and the new /remote marquee both want one. Building it is new work (a phone showing the sync sheet, or the ring art `StepAllow.astro` already draws for the Mac wizard). Until it exists, the /remote marquee can ship without art or reuse `Phone tab="speakers"`; the owner picks.
4. **Rule 7 in the hero.** Full compliance costs the home hero a fourth sentence. The owner may allow "included with Audiout for Mac" alone in the hero, with "works with the Mac you allow it on" in the phone cell one screen down.
5. **/thanks before the link.** No phone mention (recommended; the page is about the key) or one line pointing at the /remote signup.
6. **"One second" or "seconds".** The site says "in one second" (the sweep length); the phone's invite card says "Takes seconds." Pick one and apply it to both surfaces.
7. **Vocabulary drift already on the site.** The support articles say "trim" and "timing offset"; the glossary says "offset". BRAND-VOICE rule 12 still says "Main Out" while the glossary, the copy-review table and the shipped site say "Main Audio". The copy-review skill's open item (phone named Audiout or Audiout Remote) is closed by D4 and should be marked so. None of this is in the brief's changed lines; it needs one owner pass.
8. **The Mac's "Align by ear" label** names the tick toggle, not the wizard (`BTSyncDrawerView.swift:286` versus `DeviceRowView.swift:2157`). The site follows D3 and the glossary. The Mac repo owns the clash; flagging it so the support article's door names do not go stale.
9. **The site's PRODUCT.md is stale against D3.** Lines 176-180 say the phone "does not do sync calibration from the phone's microphone today" and the site may say it only "in one ledger row, never as a headline claim". Plan D3 (2026-09-05) supersedes that. The owner updates PRODUCT.md before the builder starts, or the builder is asked to break a binding rule.
10. **Support article claims gated on phone tasks.** The "first pass" and "Timing from last time" paragraphs in the new support article are true only once T7 and T14 have shipped. The builder includes them only after checking the shipped phone.
11. **Which speakers get measured, stated on the home page or not.** Every home-page line above says "Bluetooth". If the owner would rather the hero say "the one that plays behind" without the word Bluetooth, the FAQ entry "Do I need an iPhone" and the ledger row carry the scope instead. Recommendation: keep "Bluetooth" everywhere except the H1.

## 10. Verification the builder runs

- `npm run build` in both modes; confirm no `.astro` page prints "coming soon" about the phone when the switch is set, and every one does when it is unset. The existing `guard:production` check that asserts `/remote` still renders should be extended to the phone's switch.
- Grep the built `dist` for "by ear" and "wizard": every hit should be a line this brief names as staying (the by-ear support article, the press screenshot caption, the fallback sentences).
- Re-render the OG card and check the measurement dump against the mark's box.
- Run the Impeccable detector once over the changed targets, as the context script directed.
