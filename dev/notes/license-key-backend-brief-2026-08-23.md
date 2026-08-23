# License-key backend — discovery brief (2026-08-23)

Question from Alec: sell pre-built binaries behind a license key (source stays
free per GPL), generate/validate/track keys, see sharing, reduce sharing risk.
Posture chosen up front: **monitor + manual revoke** (no automatic caps).
Alec also asked to **revisit the runtime-lock ruling** in PRODUCT.md and to see
the **range of backend tiers** with a growth path.

Three research tracks ran 2026-08-23 (GPL legality, Paddle fulfillment, backend
tiers). This file is the synthesis; source URLs inline.

---

## 1. The GPL verdict — runtime lock re-examined

PRODUCT.md says a key lock is "neither enforceable nor permitted". Research
verdict: **half right.**

- **Not enforceable — still true.** Source must ship; anyone may legally strip
  the check and redistribute a keyless build. GPL-2.0-*or-later* means
  recipients can elect GPLv3, whose §3 anti-DRM clause waives any legal power
  to forbid circumvention. You could never sue over a patched-out check.
- **"Not permitted" — wrong as to the license text.** GPLv2 §6 forbids
  *license terms* that restrict use (no EULA, no "one machine" clause, no
  key-required-as-condition-of-use). It does not forbid the *program* from
  containing a key check as plain behavior, provided full source ships and
  nothing legally forbids removing it (SFLC compliance guide; FSF FAQ). The
  check's code must be open — but that's fine: verify keys with an Ed25519
  signature; the public key and verify code are open, the private signing key
  is not source code and stays secret. Nobody can forge keys; anybody can
  patch out the check.
- **Precedents.** Ardour (GPLv2, same no-dual-license position): paywalled
  full build + a free demo that goes silent after ~10 min — two binaries, no
  runtime key; ~15 years unchallenged, and its FAQ disavows key locks as
  against the GPL's spirit. RHEL: binaries + updates behind a subscription
  since ~2002 — contested at the edges by SFC but never lost a GPL case.
  grsecurity's trap to avoid: *retaliating* against a customer for
  redistributing is the widely-condemned line — never cancel a license
  because someone shared the binary.
- **Practical futility is mostly theoretical for a niche Mac app.** Free full
  Ardour builds are one `apt install` away on Linux, yet Mac/Windows buyers
  sustain the project — nobody bothers maintaining a signed, notarised free
  Mac mirror. The stripping risk scales with popularity and with how hostile
  the gate is: a hard "won't run" invites a spite-fork; a download gate or
  soft nag doesn't.
- **The real moat is trademark, not copyright.** A rebuild may legally exist
  but can't ship as "Audiouter" with the icon if the name is trademarked and
  branding assets are licensed separately (Mozilla/Iceweasel, Rocky/Alma
  debranding precedents).

**Options ranked by legal safety** (full analysis in the GPL track):
1. Paywalled download + key-gated Sparkle update feed — unambiguously legal, the proven model. *(Recommended.)*
2. Free demo build with a limitation + paid full build — Ardour has shipped exactly this for years.
3. Trademark registration + rebuild-must-rename policy + icon licensed separately from the code.
4. Soft in-app key (unregistered = nag, never dead) — textually permitted, no precedent either way, some "GPL-washing" flak risk.
5. Hard "won't run without key" — same legal analysis as 4 but zero precedent, worst optics, most likely to provoke a clean fork. Advise against.

Never: any EULA/terms on the binary, no-redistribution language, or cutting
off a customer for sharing.

## 2. Recommended architecture (Tier B)

**One Cloudflare Worker + D1 (SQLite) + R2 (DMG storage). ~$0–5/mo. ~3–7 days
build.** Rationale: Paddle Billing has **no native license keys** (that was
Paddle Classic; the migration docs say to build it yourself off webhooks —
https://developer.paddle.com/migrate/paddle-classic/features), so a webhook
endpoint must exist regardless — the marginal cost of a real backend over
"no server" is a few days, and it's the cheapest tier that delivers
monitor + manual revoke.

**Key format:** Ed25519-signed payload (email hash + purchase date + major
version). Verifiable fully offline with CryptoKit (`Curve25519.Signing`,
~20 lines, no dependency) — the app/feed never bricks if the Worker is down,
and keys survive any future backend migration without reissue.

**Flow:**
1. **Purchase.** Paddle checkout → `transaction.completed` webhook → verify
   `Paddle-Signature` (SDK `webhooks.unmarshal`), dedupe on `event_id`,
   **one key per `transaction_id`** (idempotent — Paddle retries up to 60×/3
   days, duplicates possible). Fetch email via `GET /customers/{id}`; email
   the key; also show it on the checkout success page (Paddle.js
   `checkout.completed` event carries `transaction_id`; success page verifies
   server-side via `GET /transactions/{id}`, polls briefly if the webhook
   hasn't landed).
2. **Download gate.** `/download?key=…` → validate + increment counter → 302
   to a ~15-min presigned R2 URL. R2 egress is free.
3. **Update gate.** Sparkle: set `SPUUpdater.httpHeaders` with a bearer token
   derived from the key — applies to both appcast fetch and update download,
   keeps the secret out of URLs (query-param feeds leak via logs/proxies).
   Worker serves the appcast after validating; counts fetches per key.
4. **Monitor.** Per-key counters: downloads, appcast fetches, check-in device
   IDs (ties into the inert `LicenseCheckIn.swift` from the 054 work — that
   client activates by gaining a `checkInURL`). Sharing = one key, many
   devices/IPs. Review by query; no automatic blocking.
5. **Revoke.** Admin endpoint or CLI flips `status = revoked`; key then fails
   download/appcast (existing installs keep running — that's the model).
   Auto-revoke on Paddle `adjustment.created/updated` with `action: refund`
   (approved) or `chargeback`; un-revoke on `chargeback_reverse`. Check
   partial vs full refund before killing a key.
6. **Lost key.** "Resend my key" form: email in → look up → email out (never
   display — avoids enumeration). Paddle's customer portal cannot serve
   vendor keys.

## 3. The tier ladder (what growing costs)

| Tier | What | Cost | Buys | Can't do |
|---|---|---|---|---|
| A — no server | Ed25519 keys signed by a stateless webhook function, emailed | ~$0, 1–2 days | Forgery-proof keys, offline forever | No tracking, no revocation (blocklist needs an app update), no download/feed gate |
| **B — own serverless** ← start | CF Worker + D1 + R2 | ~$0–5/mo, 3–7 days | Everything asked: counters, sharing visibility, instant revoke, gated download+feed | Dashboards/UI — admin is a CLI/query |
| C — licensing SaaS | Keygen Cloud (free dev tier → ~$49–79/mo; official Paddle integration + example repo; Sparkle-compatible distribution API on paid tier; self-hostable CE as exit) or LicenseSeat ($9/mo, Paddle + Swift SDK, but very young vendor) | fee + 1–3 days | Dashboards, activation limits, revocation UI | Doesn't remove the Paddle glue; Cryptlex/LicenseSpring ($99–100/mo) and Anystack (no Paddle) disqualified at this volume |

Tier A's key format is embedded in Tier B, and Tier B's data exports trivially
to Tier C — the ladder is climbable without reissuing keys. Open-source
self-host templates (Keygen CE, LicenseGate, keygate) were evaluated and all
lose to a hand-rolled Worker at this volume (ops weight, immaturity, or no
Paddle support).

## 4. Decision points for Alec

1. **Runtime behavior** — pick one; PRODUCT.md must be amended if not (a):
   (a) app never checks anything (current PRODUCT.md stance) — key gates
   download + updates only; (b) soft check: license field in Settings,
   unregistered builds show a "please buy" nag, never block *(legal, some
   community-optics risk)*; (c) hard lock *(advised against — worst optics,
   trivially stripped, zero precedent)*.
2. **Trademark** — register "Audiouter" and keep icon artwork licensed
   separately from the GPL code. The real anti-fork moat. Verify the icon
   isn't inside a GPL-covered target.
3. **Free demo build** (Ardour-style limited build) — orthogonal, legal,
   deferrable; a future funnel decision, not needed for v1.
4. **Cloudflare account** — backend lands on Alec's CF account; needs a
   credential handoff like the RELEASE.md list from 054.

## 5. Source highlights

- Paddle: developer.paddle.com — `migrate/paddle-classic/features`,
  `webhooks/transactions/transaction-completed`, `webhooks/signature-verification`,
  `webhooks/adjustments/adjustment-created`, `build/checkout/handle-success-post-checkout`
- GPL: gnu.org GPL FAQ (`DoesTheGPLAllowMoney`, `DoesTheGPLAllowDownloadFee`,
  `DoesTheGPLAllowNDA`), SFLC Guide to GPL Compliance, SFC RHEL analysis
  (sfconservancy.org/blog/2023/jun/23/rhel-gpl-analysis), ardour.org/faq.html
- Field report of exactly this stack (Mac app + Paddle Billing + self-built
  keys): blog.eternalstorms.at 2024-12 "Let's meddle with Paddle" parts II–III
- Sparkle: `SPUUpdater.httpHeaders`, `SPUUpdaterDelegate.feedURLString(for:)` —
  sparkle-project.org/documentation/api-reference
- Keygen: keygen.sh/integrate/paddle + github.com/keygen-sh/example-paddle-integration
