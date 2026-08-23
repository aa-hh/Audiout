# Payments & Licensing Research — Audiout (Phase 3, Task R1)

Grounding: Audiout's AirPlayEngine sender is derived from OwnTone and is
**GPL-2.0-or-later** end to end (per `LICENSE`, `NOTICE`, and
`AirPlayEngine/docs/license-inventory.md` in this repo). Copyright on the
GPL sender cluster (`airplay.c`, `airplay_events.c`, `rtp_common.c`) is held
by "Espen Jürgensen and the OwnTone Project," not by this project — that
fact matters a lot below.

## The GPL reality in plain words

Selling GPL software is completely legal. The GPL is a *copyleft* license,
not an anti-commercial one — its preamble says explicitly that you may
"distribute copies of free software (and charge for this service if you
wish)." What the GPL requires is that anyone you sell or give a copy to
also gets the complete source code and the right to redistribute it
(including for free, including to people who never paid you). So the shape
of the business is fixed by the license: you cannot stop someone who buys
a copy from sharing it further, and you cannot add DRM that blocks that
right. What you're actually selling is **convenience, trust, and support**
— a signed, notarized, ready-to-run build; timely updates; and the
knowledge the money supports development — not exclusivity of access.

Successful GPL/FOSS desktop apps that charge money lean into exactly that:

- **Ardour** (GPL-2.0, audio DAW): keeps the whole app GPL and free-as-in-
  source forever. Pre-built binaries are "pay what you want," with a
  suggested minimum of about $1, plus optional subscriptions (from $1/mo,
  or a one-time $45) that the project explicitly frames as smoothing out
  revenue between releases rather than gating features. Ardour does not use
  license or activation keys at all — the FAQ states this plainly, because
  a technical lock would conflict with the GPL's spirit even though it
  wouldn't literally violate the license text. The project reports most
  payments are small (under $10, most around $1), i.e. the model is
  volume/goodwill-driven, not high-ARPU. ([Ardour FAQ](https://ardour.org/faq.html), [Ardour "paywall" discussion](https://discourse.ardour.org/t/the-paywall-and-related-matters/105989))
- **Krita** (GPL-3.0, painting app): the Windows/Linux/macOS direct
  download is free and feature-complete — there is no crippled free tier.
  Store builds (Windows Store, Steam) cost money for the *same* app; the
  purchase is framed as a convenience purchase (auto-updates via the store)
  and a donation to the Krita Foundation, with store commission deducted
  before the rest goes to development. No public conversion-rate numbers
  were found, but the pattern — identical features, paid channel sold as
  "support + convenience" — is well documented. ([Krita installation docs](https://docs.krita.org/en/user_manual/getting_started/installation.html))
- **Aseprite** is the cautionary counter-example, and it is instructive
  for exactly the reason the task flagged: in August 2016 (v1.1.8) Aseprite
  dropped GPLv2 for a proprietary EULA. Source is still visible/buildable
  for personal use, but redistributing built copies is now forbidden. The
  developer's own stated reasoning was frustration that distro packagers
  (Debian in particular) were shipping free binaries of a program he
  wanted to live off selling. **This move was only legally possible
  because Aseprite's copyright was concentrated enough in the original
  author's hands that he could relicense his own code.** Audiout cannot
  do this: the GPL sender cluster's copyright belongs to Espen Jürgensen
  and the OwnTone Project (third parties this project has no relicensing
  agreement with — see `NOTICE` and `license-inventory.md`), so relicensing
  away from GPL is not on the table here, full stop. ([Aseprite devblog: "New source code license"](https://dev.aseprite.org/2016/09/01/new-source-code-license/), [Aseprite FAQ](https://www.aseprite.org/faq/), [GitHub issue #1666, "Relicense Aseprite back under GPL"](https://github.com/aseprite/aseprite/issues/1666))

Bottom line: the two GPL playbooks that are actually open to Audiout are
Ardour's (free/honor-system, monetize convenience+goodwill) and Krita's
(identical builds, paid channel = support + auto-update convenience). Both
are covered as licensing-model options below.

## Provider comparison

| Provider | Take rate (real numbers) | Merchant of Record? | Handles VAT/sales tax? | License keys | Trials | Chargeback handling | Integration effort (solo, non-technical-ish founder) |
|---|---|---|---|---|---|---|---|
| **Paddle** | 5% + $0.50/transaction, all-in advertised; note the underlying merchant agreement adds ~2-3% currency-conversion on cross-currency sales, so the effective rate can run higher than the headline 5% | Yes | Yes — full tax registration, filing, remittance | Paddle *Classic* had native key issuance; current **Paddle Billing does not** — a real solo Mac developer (Eternal Storms Software, selling outside the App Store) had to hand-build his own signed license-key system on top of Paddle's webhooks, and said the docs "assume subscription familiarity" and don't make the end-to-end flow obvious | Supported via checkout config | Handled by Paddle as MoR | **Days, not hours** — webhook plumbing + you write the actual key-signing code yourself. Real quote from that developer: a task "a professional [would do] in fifteen minutes takes me three hours." |
| **Gumroad** | 10% + $0.50/transaction on direct sales; **30%** if a buyer finds you via Gumroad's own Discover marketplace (avoid that channel) | Yes, since Jan 1, 2025 | Yes — "we manage sales tax collection and remittance worldwide" per Gumroad's own copy | **Native**, first-party: one key per sale, plus a license-verification API (`product_id` + `license_key` → valid/uses-count). No entitlements/feature-flags — a key is just valid or not. | Basic (pay-what-you-want / discount codes); no formal trial-period primitive | Gumroad-handled (MoR) | **Hours** — hosted product page, license keys auto-generated, no backend required for a simple check |
| **Lemon Squeezy** | **5% + $0.50/transaction**, all-inclusive advertised. Add-ons stack on top: **+1.5%** international cards, **+1.5%** PayPal, **+0.5%** subscription payments (not relevant for a one-time sale), +3% if using affiliates | Yes | Yes — EU VAT + global sales tax handled | **Native, first-party, and more capable than Gumroad**: auto-issued per sale, with activation-limit and license-length controls, deactivate/reissue from the dashboard, ties key validity to subscription status automatically if you ever go subscription | Supported (pay-what-you-want, discount codes; time-limited trial patterns via subscription plans) | Lemon Squeezy-handled (MoR) | **Low** — hosted checkout + first-party license-key API means little to no custom backend for a one-time-purchase key-gated app |
| **Stripe (direct, not Managed Payments)** | Card processing only, ~2.9% + $0.30/transaction — the cheapest headline rate of the group | **No** — Stripe itself is a payment processor, not a Merchant of Record; you remain the legal seller | **No, by default** — you (the developer) stay legally responsible for registering, calculating, and remitting sales tax/VAT/GST in every jurisdiction you sell into; Stripe Tax can *calculate* amounts but doesn't take on the legal liability. Stripe's new **Managed Payments** product (rolled out through 2025-2026, in expanding preview covering 35+ countries as of mid-2025) *does* add MoR-style tax handling, but it's a newer, still-expanding product, not the default "just add Stripe" integration | None built in — you'd build your own (e.g. via Keygen or hand-rolled) | You build it | You own disputes directly | **Lowest processing fee, highest hidden effort** — for a solo, non-technical-ish founder selling worldwide, self-administering VAT/sales-tax registration in every country you get a sale from is a real, ongoing compliance burden that the MoR options above make disappear for a few extra points of fee |
| **itch.io** (dark horse) | **Pay-what-you-want revenue share you set yourself**, 0-100%, defaulting to 10%; plus unavoidable payment-processor fees (~2.9% + $0.30) | Not built for this — itch.io is not positioned or marketed as a tax-compliance Merchant of Record the way Paddle/Lemon Squeezy/Gumroad are | Unclear/no | None built for software licensing (it's an assets/games storefront) | PWYW is itch.io's whole model; real data shows PWYW buyers pay ~30% more than the set minimum on average | N/A | Only worth mentioning for the PWYW cultural fit with a GPL project's ethos — not a serious licensing/tax backbone for a paid utility |
| **FastSpring** (dark horse) | No published self-serve rate; sales-assisted custom quotes; independent estimates put effective cost around **~$0.95 + ~5.9%** per transaction, with some analyses citing 9-11% effective take on recurring revenue once everything is bundled | Yes | Yes | Yes (enterprise-oriented) | Yes | Handled (MoR) | **High** — built for B2B/mid-market software with a sales process, not a fast solo-developer self-serve signup; overkill here |

Sources: [Paddle pricing](https://www.paddle.com/pricing) · [Gumroad pricing](https://gumroad.com/pricing) · [Gumroad license keys help](https://gumroad.com/help/article/76-license-keys) · [Lemon Squeezy pricing](https://www.lemonsqueezy.com/pricing) · [Lemon Squeezy license-key docs](https://docs.lemonsqueezy.com/help/licensing/generating-license-keys) · [Stripe vs MoR explainer](https://dodopayments.com/blogs/is-stripe-a-merchant-of-record) · [Stripe Managed Payments docs](https://docs.stripe.com/payments/managed-payments) · [itch.io creator payments docs](https://itch.io/docs/creators/payments) · [FastSpring pricing breakdown](https://dodopayments.com/blogs/fastspring-pricing-explained) · [Eternal Storms Software — solo dev's real Paddle integration](https://blog.eternalstorms.at/2024/12/18/selling-outside-of-the-mac-app-store-part-ii-lets-meddle-with-paddle/)

### Lemon Squeezy / Stripe acquisition status (verified current)

Stripe acquired Lemon Squeezy in **July 2024** (terms undisclosed). As of
Lemon Squeezy's own **2026 update post**, the product is still operating
standalone — existing and new Lemon Squeezy merchants are told "no changes
or action needed" — while Stripe simultaneously scales its own **Managed
Payments** product (Lemon Squeezy's spiritual successor, built directly
into Stripe, in expanding public preview through 2025-2026). Read this as:
Lemon Squeezy is safe to build on *today*, but a solo founder starting a
new integration in 2026 should expect that Stripe's roadmap eventually
converges the two products, and budget a small amount of future
migration risk (not a reason to avoid it, but worth knowing going in).
([Stripe acquires Lemon Squeezy — Lemon Squeezy's own post](https://www.lemonsqueezy.com/blog/stripe-acquires-lemon-squeezy) · [2026 Update: Lemon Squeezy + Stripe Managed Payments](https://www.lemonsqueezy.com/blog/2026-update) · [TechCrunch coverage](https://techcrunch.com/2024/07/26/stripe-acquires-payment-processing-startup-lemon-squeezy/))

## Licensing-model options

### (a) Honor-system paid download (no in-app check)
- **What it is:** sell a download page; the app never checks anything.
  This is Ardour's actual model.
- **Upside:** essentially zero engineering effort (hours, not days) —
  just a checkout page and a download link. Fully GPL-clean with no
  awkward "how honest is our check" conversation, because there is no
  check to defend. Matches the ethos GPL/FOSS buyers respect, which can
  help word-of-mouth and reviews.
- **Downside:** zero enforcement of any kind. Anyone with a copy — paid
  or passed along — has the full app forever, and since the source is
  GPL and public, anyone who wants a completely free build can also just
  compile it themselves regardless. There is no "checkpoint" moment that
  nudges a casual, non-technical user toward paying, which is the exact
  moment that converts casual users into buyers for products like
  SoundSource or Airfoil. Works well for an already-trusted, decade-old
  project with a donor community (Ardour); risky as the *sole* model for
  a brand-new commercial launch that needs predictable early revenue.

### (b) License key with offline validation (e.g., Ed25519-signed keys)
- **What it is:** a payment provider (Lemon Squeezy or Gumroad, both
  natively) issues a signed key per purchase; the app verifies the
  signature offline (no server round-trip needed after purchase) before
  unlocking or before dismissing a "please register" nag.
- **Say this plainly:** because Audiout is GPL, the verification code
  itself ships in the open source. Anyone technical enough can read
  exactly where the check branches and patch a binary to skip it, or
  build their own copy from source with the check ripped out entirely.
  Ed25519 does stop someone from *forging* a valid-looking key without
  your private key — but it does not, and cannot, stop someone from
  disabling the check altogether in a GPL app. **This is a DRM-shaped
  UX, not DRM.** It's an honesty nudge for the large majority of users
  who will never open a disassembler, exactly like SoundSource's or
  Airfoil's own key checks are today (those apps aren't GPL, but their
  checks are just as bypassable by a sufficiently motivated user — the
  difference here is only that the GPL makes that fact transparent
  up front instead of hidden).
- **Effort estimate:** roughly **1-3 days** for a solo, non-technical-ish
  founder if using Lemon Squeezy's or Gumroad's first-party key issuance
  (generate a keypair, add a "license" screen/menu item, bundle the
  public key, verify on launch, wire the purchase flow to the provider's
  hosted checkout). Building your own signing/issuance server from
  scratch (the path the Eternal Storms developer took with Paddle) is
  more like a week of solo effort.
- **Downside:** modest ongoing support burden (lost keys, device
  swaps/reactivation asks), and a small credibility risk if a customer
  points out that "GPL + license key" looks contradictory unless the
  copy is careful to frame it as support/registration, not access
  control.

### (c) Update-entitlement model ("pay for convenience" — Ardour/Krita pattern)
- **What it is:** the app is free and fully functional for everyone,
  including non-paying users. What paying unlocks is **signed automatic
  updates** — free users can still always manually download the latest
  build (nothing in the GPL lets you prevent that), but only paying users
  get the one-click Sparkle auto-update experience.
- **Why it's cheap here specifically:** any Mac app distributed outside
  the App Store already needs an updater, and **Sparkle** (the standard
  choice) already signs its update feed with **EdDSA/Ed25519** by
  default — this is the same cryptographic primitive proposed for
  option (b), just reused for a different purpose. Concretely: run
  Sparkle's `generate_keys` once, sign releases with `sign_update`, and
  gate which appcast feed URL a build points to based on license state.
  ([Sparkle EdDSA docs](https://sparkle-project.org/documentation/eddsa-migration/))
- **Effort estimate:** **~1-2 days** on top of Sparkle integration the
  app needs anyway for direct distribution — genuinely the *cheapest*
  of the three options once you account for work that has to happen
  regardless.
- **Upside:** the most PR-safe and GPL-honest of the three — nobody
  running the free build is "pirating" anything, they're just declining
  to pay for update convenience, which sidesteps the whole "is this
  DRM" conversation with users entirely. Ardour has run this model for
  over a decade without collapsing.
- **Downside:** what's being sold is a soft convenience, not a feature —
  for a *brand-new* product with no installed base and no existing
  goodwill/reputation to lean on (unlike Ardour after 20 years), it's
  a real open question whether "pay for auto-update" converts well
  enough on day one. Also adds moving parts (two build/feed channels
  to maintain) versus a single gated key check.

## Price-point evidence

Direct comparables, verified current prices:

| App | Model | Price | Notes |
|---|---|---|---|
| **SoundSource** (Rogue Amoeba) | One-time, license key | **$49** | $25 upgrade price for owners of v4/v5. Closest positioning to a "serious paid Mac audio utility." ([buy page](https://rogueamoeba.com/soundsource/buy.php)) |
| **Airfoil** (Rogue Amoeba) | One-time, license key | **$35** | $15 upgrade price. Older/simpler product (streaming redirection), around since 2006. ([buy page](https://rogueamoeba.com/airfoil/mac/buy.php)) |
| **Bartender** | Was one-time ($22, later $20); **shifted toward subscription** after a June 2024 ownership change to Applause Group | **$20 one-time OR $15/year "Bartender Pro"** | The ownership change and subscription push drew visible user trust concerns — relevant cautionary data point on how a pricing-model change reads to an existing paid userbase. ([macbartender.com](https://www.macbartender.com/pro/)) |
| **CleanShot X** | One-time + optional paid updates (Krita/Ardour-adjacent hybrid) | **$29 one-time**, then **$19/year optional** to keep receiving updates (app keeps working forever either way) | This is effectively option (c) above, already proven in the wild at this exact price band. Separate $8/user/month tier exists only for a cloud/team add-on, not the core app. ([cleanshot.com/pricing](https://cleanshot.com/pricing)) |
| **Ice** | Free, open source | **$0** | Direct free/OSS competitive pressure exists in the *menu-bar management* category generally, but Ice is a Bartender-class menu-bar-hiding tool, not an AirPlay/multi-room audio router — Audiout doesn't have a free, feature-equivalent OSS competitor in its own category today. |

**What the market bears for this category:** paid Mac audio/menu-bar
utilities from a credible small studio cluster tightly around **$20-$49
one-time**, with $25-$35 being the common "upgrade" price for major
version bumps (roughly half of the new-purchase price). Nobody in this
specific comparable set has successfully normalized a pure subscription
for a single-purpose local utility without pushback — Bartender's
subscription pivot is the one case that did it, and it generated visible
community friction. An AirPlay multi-room router with per-app/group
routing is a *more* differentiated, technically harder feature set than
either SoundSource (device output picker) or Airfoil (basic redirection),
which supports pricing at or above the SoundSource anchor ($49) rather
than below it.

## What about the App Store — closing that door

Not viable, for three independent reasons:

1. **GPL vs. the App Store's Terms of Service are legally incompatible.**
   Apple's App Store terms impose restrictions on redistribution and use
   (DRM/FairPlay wrapping, resale/transfer limits) that the GPL explicitly
   forbids adding on top of GPL-covered code. This isn't theoretical —
   Apple pulled **VLC** (also GPL) from the App Store in 2011 over exactly
   this conflict; it only returned years later under a specific,
   negotiated arrangement that doesn't generalize to a new small project.
   ([FSF: "More about the App Store GPL Enforcement"](https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement))
2. **Sandboxing/entitlements friction.** The App Store requires the App
   Sandbox. Audiout's core functionality depends on Core Audio process
   taps and broad TCC permissions (Local Network, Accessibility, audio
   capture) that sit exactly in the category Apple has historically
   restricted or scrutinized hardest for sandboxed apps — this is a
   second, independent blocker even setting the GPL issue aside.
3. **Reverse-engineered protocol invites discretionary human review
   risk.** Per this project's own prior finding (Apple Developer ID
   review checklist memory), Developer ID notarization is only an
   automated malware/bundle scan and does not itself flag a
   reverse-engineered AirPlay implementation. **App Review is different**
   — it's a human/policy review, and unlike notarization it could
   subjectively flag the legitimacy of a reverse-engineered protocol
   implementation even if nothing is technically malicious. Direct
   Developer-ID distribution avoids that discretionary layer entirely.

Direct-download, Developer-ID-notarized distribution (the current plan)
is the only realistic path, and it's also the path every GPL desktop
comparable above (Ardour, Krita's non-store build) actually uses.

## Recommendation

**Primary: Lemon Squeezy, as merchant of record, selling a one-time
license-key purchase (offline Ed25519 verification, licensing model (b))
priced at $39-$49.**

- **Upside:** Lemon Squeezy is the *lowest total integration effort*
  option that still gets a solo, non-technical-ish founder out of doing
  their own global sales-tax/VAT compliance — its native license-key
  issuance API means there's little to no custom backend to write (a real
  contrast with Paddle, where a solo developer had to hand-build his own
  signing server because Paddle Billing dropped Classic's native key
  support). $39-$49 sits right at the proven market anchor set by
  SoundSource ($49) and above Airfoil ($35), which is justified because
  Audiout's actual AirPlay-2 multi-room + per-app routing is a harder,
  more differentiated feature set than either of those apps offers.
- **Downside — the number that most drove this pick down to a caveat
  rather than a blocker:** Lemon Squeezy's fee is **5% + $0.50 per
  transaction**, plus stacking surcharges (+1.5% international cards,
  +1.5% PayPal) that push the *effective* rate meaningfully above the
  advertised headline on a chunk of real-world sales. And because Stripe
  acquired Lemon Squeezy in July 2024 and is actively building its own
  "Managed Payments" successor product, there's a real (if currently
  low) chance of a forced migration down the road — worth budgeting a
  small amount of future integration risk for, not a reason to avoid it
  today.

**Runner-up: Gumroad**, same licensing model, if the priority is *zero*
setup friction over lowest fee. Gumroad's flat **10% + $0.50** (avoid its
30% Discover-marketplace channel) is a materially bigger cut, but its
hosted product page plus first-party license-key API requires essentially
no backend work at all — the fastest path to a first sale for a
non-technical-ish founder, at the cost of giving up roughly 5 extra
percentage points versus Lemon Squeezy on every sale.
