# Handoff — companion-app marketing, trademark, pricing (2026-08-24)

Self-contained handoff for the next agent. Branch
`claude/companion-app-marketing-strategy-360a05` (worktree
`.claude/worktrees/companion-app-marketing-strategy-360a05`, pushed to
origin, **NOT merged**). One commit: `9f7a8ae6`.

**READ THE REPORT FIRST — it is the deliverable, not this file:**
**https://claude.ai/code/artifact/075989d7-c824-47ff-8289-6fa53b65ca11**
("Audiout Remote Playbook"). It holds the App Store listing spec, the full
`audiout.app/remote` page outline, the launch sequence, and the pre-flight
trap list. This file is state + what is owed.

## What happened this session

Research only — no product code. Alec asked how to market the iOS companion
app given it is useless without the separately-purchased Mac app. That
expanded into five research threads (~35 agents/sources sweeps total, all
web-grounded with URLs):

1. **Companion-app marketing** — 6 lenses + adversarial gap-check. → artifact.
2. **Ardour-model conversion numbers** — "what % compile it themselves?"
3. **Trademark** — route, cost, and a real clearance search.
4. **Pricing model** — is a subscription worth it?
5. **EU DSA trader status** — how to avoid setting up a company.

Full detail lives in memory (`~/.claude/projects/.../memory/`), which is the
authoritative record — this handoff is a map, not a substitute:
`companion-app-marketing-discovery` · `ardour-model-conversion-numbers` ·
`trademark-audiout-plan` · `pricing-model-update-window` ·
`eu-dsa-trader-po-box`.

## Committed on this branch

`9f7a8ae6` — new `TRADEMARKS.md` at repo root + 2 lines in README's License
section pointing at it. GPL covers the code, not the name/icon;
redistributors of built binaries must rebrand; **nominative reference stays
explicitly allowed** (a policy forbidding truthful reference is unenforceable
and hostile — do not "tighten" this). Contact listed as
`trademarks@audiout.app`, which **does not route yet** — Alec owes a
Cloudflare Email Routing rule or a one-line change.

Nothing merged. Roadmap deliberately untouched — see Traps.

## Decisions Alec MADE this session

- **EU-based** (answered directly). Settles the trademark route and the DSA question.
- **Defer the paid trademark filing until sales exist.** Free hedges owed now.
- **Create TRADEMARKS.md** (done, above).

## Decisions OWED — do not proceed past these without asking

1. **iOS app free vs IAP.** Research says **FREE, no IAP** — this REVERSES
   Alec's earlier IAP plan. Revenue math: 1 Mac sale ≈ 7-8 iOS unlocks after
   Apple's 15%. Every high-rated companion is free (Logic Remote, Camo, Luna,
   Plex, Airfoil Satellite 4.4-4.8*); every paid one is the failure cohort
   (Alfred Remote 3.1* abandoned). Not yet accepted by Alec.
2. **Pricing model.** Research recommends switching from version-bound updates
   to a **12-month update window + perpetual fallback + optional ~EUR 15
   renewal**. This CHANGES a decision recorded as settled in PRODUCT.md
   ("updates bound to major version, v2 = separate paid upgrade"). Price
   itself does not move. Cheaper to start this way than to retrofit.
3. **Final iOS app name** ("Audiout Remote" is a working title). Gates the
   App Store listing spec, the name reservation, and roadmap 063.
4. **iPad posture** — real layout vs letterboxed iPhone compatibility mode
   (no opt-out exists for the latter).
5. **Whether to act on the P.O. Box** for DSA trader status.

## Load-bearing findings (short form; detail in memory + artifact)

**Apple rules.** The whole shape is precedent-proven: Rogue Amoeba's free
Airfoil Satellite has paired with a paid, off-store Mac audio app since 2015,
and its listing links their own site. Guideline 3.1.3(f) is the shelter but is
**precedent-backed, not text-backed** (it literally says "paid web based
tool") — so budget 1-2 extra review cycles, pre-write the appeal citing
3.1.3(f) + 4.2.7 + named precedents, and never tie a press date to a first
submission. Reviewer will have no Mac on their network: promote the debug-only
demo to a shipping Demo Mode (doubles as the no-Mac empty state and the
screenshot source) + 60s video + review notes.

**Self-compilers are noise.** Background Music (GPL macOS menu-bar
system-audio app — same category) ships 0.08-0.4% build-artifact downloads vs
prebuilt installer. Ardour: "most DAW users are not interested in this," and
they clear $220-240k/yr with source free. The GATE drives revenue, not source
secrecy: Ardour converted <3% when paying was voluntary, then 5-10x'd revenue
after adding a $1 pay tunnel. Audiout's usage-metered trial IS that pay tunnel.

**Trademark.** Register is CLEAN — "AUDIOUT" has zero live registrations
worldwide and no app/product/company uses it. Verdict AMBER for two reasons:
(a) "Audiout" is phonetically "audio out", a plain description of the
function — descriptiveness refusal is ~a coin flip, and EUIPO takes the EUR
850 first and refunds nothing; (b) Audi AG holds an all-class EUTM covering
Class 9 and does attack AUDI-prefixed marks (beat AUDIMAS to the General
Court) — but hundreds of AUDIO- marks coexist with them and no case was found
of Audi opposing one. Low risk, not paranoia. Plan: EUR 150-300 opinion, then
EUR 850 (or ~EUR 213 via the SME Fund, which reopens ~February).

**EU DSA trader.** Much cheaper than first framed: **Apple accepts a P.O. Box
from INDIVIDUALS** (organizations cannot — D-U-N-S auto-fills and is
uneditable), plus a VoIP number and a role email. ~EUR 25-80/yr total.
Incorporating would make this WORSE. Non-trader is not safely available (the
free app supports a paid product = "in connection with trade"; Apple's own
forums answered a near-identical case as trader). Separately, the website
imprint obligation under e-Commerce Directive Art. 5 is PRE-EXISTING and
Paddle's Merchant-of-Record status does not shift it.

## Traps / invariants

- **The iOS target must NEVER import AirPlayEngine/OwnTone sources.** That code
  carries GPL-2.0+ copyrights from multiple third parties (see
  `AirPlayEngine/docs/license-inventory.md`), so the "sole copyright holder
  self-licenses for the App Store" escape is permanently unavailable for it —
  the unsolvable VLC-2011 problem. Today's remote is clean (pure remote
  control). Any future phone-as-receiver feature must be clean-room non-GPL.
  This belongs in `ios/AGENTS.md` as a written invariant; **not yet added**
  (the iOS tree lives on `claude/ios-staging`, not in this checkout).
- **Never put a license-key field or Paddle-license awareness in the iOS app**
  — guideline 3.1.1 bans license-key unlock mechanisms. The phone knows only
  "found a running Audiout on the LAN."
- **No tappable "buy the Mac app" button in v1.** US zero-fee steering is
  unstable (Ninth Circuit restored link-out fees Dec 2025; Supreme Court hears
  it in the Oct 2026 term) and the ban still stands everywhere else. One
  global binary, informational text only.
- **Opt out of Apple Silicon Mac + Vision Pro availability at first
  submission** — the default would put a free Audiout app INTO the Mac App
  Store, contradicting the never-on-MAS positioning.
- **Never ship an official free prebuilt binary beside the paid one.** That is
  Krita's structure and it converts at 0.42%. Source-only is a different shape.
- **ROADMAP.jsonl on this branch diverges from origin/main on entry 054.**
  This is pre-existing, not created here. Roadmap 063 ("Decide the product
  name + register the trademark") now has real substance behind it but was
  deliberately NOT updated to avoid compounding that conflict. Do any roadmap
  write on a branch carrying the post-merge roadmap.
- **Price inconsistency to resolve:** `staging-production-env-split` memory
  says EUR 30 FINAL; PRICING/RELEASE and the pricing research say EUR 29.95.
  Only affects the renewal figure (EUR 15 vs EUR 14.95).

## Next actions, cheapest first

1. Route `trademarks@audiout.app` (Cloudflare Email Routing, minutes).
2. Register `audiout.io` and `audiout.net` — both currently unregistered.
3. Rent a P.O. Box + VoIP number; declare trader in App Store Connect.
4. Reserve the final iOS app name in App Store Connect (first-come-first-served).
5. Get Alec's calls on the two open model decisions (free iOS app; update window).
6. Hand the `/remote` page outline (in the artifact) to the website person —
   see the standing `feedback-backend-lane-only` rule: the website belongs to
   its own person, hand them specs.
7. Trademark filing only once sales exist, or a copycat appears. EU is
   first-to-file — do not still be waiting 6 months after the first press day.
