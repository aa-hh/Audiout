# Pricing & licensing model — research and recommendation

Status: **Settled**. The €30 one-time price (Recommendation §3 below, confirmed 2026-08-24) stands.
Date: 2026-08-12. Related roadmap item: 051. Grounds the question the owner raised:
how to charge for Audiout given the GPL-2.0-or-later constraint the vendored
OwnTone sender forces on the whole work.

## The question

Audiout is `GPL-2.0-or-later` because `AirPlayEngine` vendors GPL sender code
derived from OwnTone (see [NOTICE](../NOTICE)). We want to charge for the app.
Two things need to be true at once: we respect the GPL, and we still capture
revenue. This note surveys how the closest competitors handle their free trial
and their price, then recommends a model that fits a GPL app specifically.

## What the GPL does and does not allow

The GPL does **not** stop us charging money. We can sell Audiout and charge a
license fee. What it forbids is adding "further restrictions" on top of the
license: anyone we hand a binary to is entitled to the corresponding source, and
is free to modify it and redistribute it — including for free.

Three consequences shape everything below:

1. **A hard technical paywall is not enforceable in our source.** A trial timer,
   a nag, or a license-key gate can legally ship, but because our source is
   public and lawfully redistributable, anyone may delete the check, recompile,
   and give the unlocked build away. We cannot use license terms to stop them.
   Rogue Amoeba's noise-after-N-minutes trial works because they are
   closed-source; the same code in our tree is trivially removable.
2. **We cannot dual-license into a proprietary edition.** We do not own the
   OwnTone GPL code in the sender, so the combined work must stay GPL. (Only the
   severable MIT `libairptp` PTP helper could ever be relicensed standalone —
   see NOTICE.)
3. **The Mac App Store stays foreclosed.** Its terms add GPL-incompatible
   restrictions — but we already ship Developer ID only for unrelated reasons
   (system-audio TCC needs a private path), so this changes nothing for us.

The upshot: we sell **convenience, not permission**. People pay for a
ready-to-run, signed, notarized, Homebrew-free build plus updates and support —
never for "the right to use the software," which the GPL already grants.

## Competitor survey

Prices in USD, captured 2026-08-12. The two axes the owner asked about — trial
duration/mechanics, and what they charge — plus a licensing column because the
free open-source options set our real price floor.

| App | Trial — how it works | Price | Model |
|---|---|---|---|
| **Airfoil** (Rogue Amoeba) — closest competitor | No time limit, no account, all features on. Noise overlaid on audio **after 10 min of streaming** per session; reset by relaunch. | **$35** one-time (upgrade $15) | Closed-source, one-time, single user covers multiple owned Macs |
| **SoundSource** (Rogue Amoeba) | Same model — noise **after 20 min** of adjusted audio. | **$49** one-time (upgrade $25) | Closed-source, one-time |
| **Audio Hijack** (Rogue Amoeba) | Noise **after 10 min** of capture. | **$69** (upgrade $29) | Closed-source, one-time |
| **Loopback** (Rogue Amoeba) | Noise **after 20 min** on any active virtual device. | **$99** (upgrade $49) | Closed-source, one-time |
| **Boom 3D** (Global Delight) | Time-limited **15-day** trial (listed 30-day on Setapp). | ~$40 one-time list, heavily/regionally discounted; **$8.99/mo via Setapp** | Closed-source |
| **eqMac** | Freemium — free basic tier, no expiry; Pro behind a paywall. (Was open source; went proprietary.) | **$3/mo, $30/yr, or $40 lifetime** | Closed-source freemium |
| **AirParrot 3** (Squirrels) | Time-limited **7-day** full-featured trial with **watermarks**; 30-day money-back. | One-time license (exact figure not confirmed) | Closed-source |
| **JustStream** (Electronic Team) | **20 min** of uninterrupted streaming/mirroring per session, then stops. | **$12.99/yr** (lifetime via resellers) | Closed-source; more video/mirroring than pure audio |
| **Background Music** | n/a — free. | **$0** | Open source (GitHub) |

Two patterns:

- The **direct audio-routing competitors (all Rogue Amoeba) use usage-limited,
  not time-limited, trials**: unlimited days, every feature on, no account — but
  the audio is sabotaged with noise after 10–20 minutes of continuous use. This
  lets someone prove the app works on their exact hardware (which matters a lot
  for flaky AirPlay) while making daily use impractical until they pay.
- The **video/mirroring-adjacent tools lean on calendar-day trials or
  watermarks** (Boom 15/30-day, AirParrot 7-day watermark, JustStream 20-min).
- **Pricing is one-time, not subscription**, across the core category. Airfoil
  at **$35** and SoundSource at **$49** are the anchors.
- **A $0 option already exists** (Background Music, open source; eqMac free
  tier). That is our real price floor, and — being open source ourselves — it is
  also our natural free tier.

## The applicable precedent: Ardour

Ardour is a GPL desktop audio app (a DAW) that makes real money without fighting
its own license. The software is free; they charge for **convenience and
support**:

- Build from source yourself → free.
- Want the pre-built, signed binary + updates + nightly access + support → pay.
- Options: one-time (as little as $1; **$45+ gets updates through the next major
  version**), a **subscription** (their preferred choice, purely to smooth
  income — it never disables the app), or pay-what-you-want.
- No license keys, no activation. "Once you have Ardour it will continue to work
  regardless of the status of your subscription."

This maps onto Audiout almost exactly, because we **already** ship a signed
Developer ID `.app` and already have the `AUDIOUT_BUNDLE_DYLIBS=1` release
path that bundles the Homebrew libraries so end users need no Homebrew. That
bundled, notarized, double-click build **is** the thing people will pay for —
the alternative for our stated audience ("a Mac user with two AirPlay speakers")
is installing Homebrew and running a build script, which they will never do.

## Recommendation

1. **Free tier = build-it-yourself from the public repo.** That is our
   GPL-native "trial": full functionality, zero enforcement burden, satisfies
   the license by construction.
2. **Paid product = the notarized, Homebrew-free `.app` + updates + support.**
   Frame the charge as paying for the ready-to-run build and updates, never as a
   usage license.
3. **Price: €30, one-time** (SETTLED 2026-08-24), sitting under Airfoil ($35)
   and well under SoundSource ($49). Undercutting the incumbent is defensible for
   a new entrant that also offers a free source path. Copy Ardour's "updates
   through the next major version" wrinkle if we want a soft recurring hook.
4. **Optional subscription for revenue smoothing**, Ardour-style — but it must
   never disable the app. Only if we want predictable income; the category norm
   here is one-time.
5. **If we still want an in-app trial**, treat noise-after-N-minutes (Rogue
   Amoeba flavor) as a *soft nudge*, not a wall — most honest users will not go
   patch source, but we accept it is bypassable and do not engineer against that.
6. **Distribution channels to consider later:** Setapp (Boom 3D and JustStream
   both ship there) as an additional subscription surface; the marketing site as
   the primary paid-download point.

## Open questions for owner

- One-time vs one-time-plus-optional-subscription?
- ~~Exact price point in the $25–35 band?~~ SETTLED 2026-08-24: **€30**, one-time.
- Do we ship an in-app soft trial at all, or lean entirely on "free from source,
  paid binary"?
- Setapp as a second channel, yes/no?

## Sources

- Rogue Amoeba — how trials work: https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-AboutAppTrials&product=General
- Airfoil pricing: https://rogueamoeba.com/airfoil/mac/buy.php
- SoundSource pricing: https://rogueamoeba.com/soundsource/buy.php
- Audio Hijack pricing: https://rogueamoeba.com/audiohijack/buy.php
- Loopback pricing: https://rogueamoeba.com/loopback/buy.php
- Boom 3D: https://www.globaldelight.com/boom/
- SoundSource vs Boom 3D / eqMac / Background Music: https://blog.apps.deals/soundsource-vs-boom-3d-eqmac-background-music-mac
- AirParrot trial: https://www.airsquirrels.com/airparrot/try
- JustStream: https://mac.eltima.com/juststream.html
- Ardour FAQ (GPL monetization): https://ardour.org/faq.html
