# Handoff — license-key backend (2026-08-23)

Self-contained handoff for the next agent. Branch:
`claude/license-key-backend-cb2e78` (worktree
`.claude/worktrees/license-key-backend-cb2e78`, pushed to origin). Read
`dev/notes/license-key-backend-brief-2026-08-23.md` first — it is the full
discovery record; this file is state + plan.

## What happened this session

Discovery only — no product code written. Three research tracks (GPL
legality, Paddle fulfillment, backend tiers) synthesized into the brief.
The owner then decided:

1. **Runtime behavior = soft check.** License field in Settings; a build
   without a valid key keeps every feature working but shows a "please buy"
   prompt; a valid key silences it. Never blocks. PRODUCT.md was amended
   accordingly on this branch (commit f381e7f7) — both the "Why this and not
   a hard lock" and "The app never blocks…" bullets. Do not re-litigate.
2. **Backend = Tier B**: self-owned serverless — Cloudflare Worker + D1
   (SQLite) + R2 (DMG storage). ~$0–5/mo.
3. **Sharing posture = monitor + manual revoke.** No automatic caps.
4. **Name/trademark**: the owner is not sold on "Audiout"; roadmap entry 063
   tracks name decision + trademark registration. Not this workstream's job.
5. **Download links**: the emailed/thank-you-page link is the durable keyed
   endpoint `/download?key=…` (lives as long as the key is active, dies on
   revoke); it 302s to a ~15-min presigned R2 URL at click time. The owner
   explicitly rejected short-lived emailed links; this construction is the
   agreed answer — don't email presigned URLs.

## State after the build session (2026-08-23, later)

- Key scheme APPROVED by the owner as recommended; backend home = **separate
  repo**: `~/Projects/Audiout License Server` →
  github.com/aa-hh/audiout-license-server (private). Its README is the
  endpoint contract + the owner's setup checklist. Built and tested (22 tests in
  workerd). One swap from the plan below: `/download` streams the zip from R2
  through the Worker instead of 302-ing to a presigned URL — same property
  (no file URL outlives the key), no S3 signing.
- The website's unmerged `claude/buy-page-paddle-c3b002` branch polls
  `GET /v1/license/by-transaction/<txn>`; the server implements exactly that.
- App side: commit da337e3f folds the 054 work onto this branch; the soft
  check (validate, status line, buy button, popover note, Sparkle bearer
  header, make-app.sh plist keys) is specified in
  `work-order-2026-08-23-license-soft-check.md`.
- Still the owner's: Cloudflare/Paddle-sandbox/Resend setup per the server README,
  then a sandbox end-to-end (tunnel → webhook → /thanks), then merge go-ahead.

## Open item 1 — key generation scheme (APPROVED 2026-08-23)

Result in `dev/notes/license-key-generation-scheme-2026-08-23.md`.
Recommendation: **random opaque key** `AUDR-XXXXX-XXXXX-XXXXX-XXXXX`
(100 bits Crockford base32, server-side D1 lookup only, no crypto in the
key) — signed keys' offline verification is worthless under the GPL/soft-
check design, and the hard gates are server lookups regardless. `max_major`
lives in the D1 row for "updates until next major" semantics. Get the owner's
sign-off on that spec before building; the note has the full table
(canonicalization, D1 schema, delivery, URL-scheme registration).

## Open item 2 — the build (after scheme is chosen)

Backend (likely its own repo or a new top-level dir — ask the owner; the website
lives separately at `~/Projects/Audiout Website` and the buy button is
already there from the 054 work):

- One CF Worker, endpoints: Paddle webhook, `/download?key=`, appcast route,
  check-in receiver, resend-key form handler, admin revoke (protected
  endpoint or CLI against D1).
- **Paddle wiring** (Paddle Billing has NO native license keys — build it):
  fulfill on `transaction.completed`; verify `Paddle-Signature` via the
  official SDK (`webhooks.unmarshal` in Node); dedupe on `event_id`; ONE key
  per `transaction_id`, idempotent (Paddle retries up to 60×/3 days). Email
  via `GET /customers/{customer_id}`. Success page: Paddle.js
  `checkout.completed` carries `transaction_id`; server confirms via
  `GET /transactions/{id}`, polls briefly if the webhook hasn't landed.
  Auto-revoke on `adjustment.created/updated` `action: refund` (approved) or
  `chargeback`; un-revoke on `chargeback_reverse`; check partial vs full.
  ALL dev in Paddle sandbox (`_sdbx` keys, `test_` tokens) — house rule in
  CLAUDE.md, which also mandates checking current Paddle docs (the
  paddle-docs MCP server needs OAuth; if unavailable use
  developer.paddle.com).
- **Sparkle gating**: `SPUUpdater.httpHeaders` bearer auth (covers appcast
  fetch AND download; keeps secrets out of URLs); count fetches per key.
- **Counters** per key: downloads, appcast fetches, check-in device IDs.
- App side (this repo): Settings license field + soft prompt, offline
  signature verify via CryptoKit, and activate the inert check-in client —
  NOTE: `LicenseCheckIn.swift` + License Settings rows were built in the 054
  work which is UNCOMMITTED in worktree
  `.claude/worktrees/foreman-roadmap-list-87195b` (awaiting the owner's review,
  10+ days old — verify it still exists before depending on it).
- Credential handoffs the owner must do (pattern: "Owner's actions" checklist like
  docs/RELEASE.md from 054): Cloudflare account/API token, Paddle sandbox
  webhook secret + API key, email-sending provider choice, Ed25519 signing
  keypair generation.

## House rules that bind this work

- Nothing merges without the owner's explicit go-ahead. `main` is merge-only;
  work stays on this branch (or new worktree branches, each pushed to origin
  immediately).
- Never attach an EULA/no-redistribution terms to the binary; never revoke a
  key *because* someone shared the binary (grsecurity trap) — revocation is
  for leaked/refunded keys' access to downloads + updates.
- App-side work: `bash scripts/build.sh` / `bash scripts/run-tests.sh`
  wrappers only, never bare `swift build`/`swift test`. Read AGENTS.md
  before touching app code.
- Roadmap: the build slots under entry 054 (paid distribution) — record
  commits there as work lands; 063 is the separate name/trademark entry.

## Commits on this branch so far

- 5c9ece96 — discovery brief added
- f381e7f7 — PRODUCT.md amendments + roadmap 063 + brief updates
