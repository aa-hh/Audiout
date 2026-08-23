# Key generation & format — discovery result (2026-08-23)

Companion to `license-key-backend-brief-2026-08-23.md`. Question: since
Paddle Billing has no native key generation, what scheme generates ours?
Options compared: random opaque key, Ed25519-signed-payload key, hybrid
(short key + signed receipt on activation). **Recommendation: random opaque
key.** Alec sign-off pending.

## Why not signed keys

- Workers WebCrypto DOES support Ed25519 (Secure Curves API since 2023,
  `crypto.subtle.sign` with `{name: "Ed25519"}`; CryptoKit
  `Curve25519.Signing` verifies app-side) — feasibility isn't the problem.
- The length is: a 64-byte Ed25519 signature plus minimal payload lands at
  ~103–124 chars — paste-only, nobody types it (keygen.sh's Ed25519 keys are
  the same shape).
- The offline verification it buys is worthless here: the app's check is
  SOFT (banner, never blocks) and openly patchable under GPL, and the HARD
  gates (download, Sparkle feed) are server-side lookups regardless of
  format. You'd build all of Option 1's D1 machinery *plus* crypto, for
  nothing.
- Legacy tooling confirms the era is over: CocoaFob is obsolete 512-bit DSA
  (steal only its `://register?key=` URL-scheme idea), AquaticPrime is
  unmaintained.
- Hybrid (LicenseSeat/Keylight/keygen.sh pattern: short key → server issues
  signed receipt cached for offline hard checks) exists to serve hard client
  checks Audiout doesn't have. It layers cleanly on this key format later
  with no migration if a tamper-evident "Licensed to …" display is ever
  wanted — that is the only future reason to add it.

## Recommended spec

| Field | Choice |
|---|---|
| Key shape | `AUDR-XXXXX-XXXXX-XXXXX-XXXXX` — literal `AUDR` prefix + 20 random Crockford-base32 chars in four groups of five |
| Entropy | 100 bits via `crypto.getRandomValues(new Uint8Array(13))` mapped to Crockford alphabet (0-9 A-Z minus I L O U), truncated to 20 chars |
| Length | 29 chars with dashes — hand-typeable, phone-readable |
| Collisions | `UNIQUE` on canonical key column; retry on conflict |
| Canonicalization | uppercase, strip dashes/whitespace, map O→0 and I/L→1 on entry; store/compare canonical form only (`COLLATE NOCASE` or canonical uppercase in D1) |
| D1 row | `key` (canonical, UNIQUE), `paddle_transaction_id`, `paddle_customer_id`, `email` (for resend — NEVER in the key: PII + breaks on email change), `max_major` (int), `issued_at`, `revoked_at` (NULL = active), `activation_count`, `last_seen_at`, `last_seen_ip_hash` |
| Signing | none — no crypto in the key; do not derive the key from purchase data |
| Verification | Worker only: `/validate` (app soft check + usage telemetry), `/download` + appcast endpoint (hard gates: `revoked_at IS NULL` and `max_major` ≥ release major) |
| App behavior | POST key to `/validate`; on OK store key + registered flag in prefs, hide banner; on network failure keep last known state (soft check never blocks) |
| Major upgrades | versioned-license model (Dash-style, fits "one-time covers current major"): `max_major` lives in the ROW, not the key string; Sparkle feed serves ≤ max_major items; a v2 purchase issues a fresh key with `max_major = 2`. Optional cosmetic prefix (`AUDR2-…`) for support triage only — parser must never depend on it |
| Delivery | `transaction.completed` webhook → generate + insert + email; success page fetches by transaction id and offers an `audiout://register?key=…` one-click link (CocoaFob's URL-scheme pattern) |

## Sources

- Workers Ed25519: github.com/cloudflare/workerd PR #500; developers.cloudflare.com/workers/runtime-apis/web-crypto
- CocoaFob github.com/glebd/cocoafob (+ CleanCocoa/TrialLicensing); AquaticPrime github.com/bdrister/AquaticPrime (unmaintained)
- keygen.sh/docs/api/cryptography (Ed25519 key format precedent)
- keylight.dev/blog/how-license-keys-work; licenseseat.com/licensing-for-macos-apps (offline-token hybrid pattern; confirms Paddle Billing dropped native keys)
- sketch.com/blog/versioning-licensing-and-sketch-4-0 (time-boxed alternative, not chosen)
- Crockford base32: ietf.org draft-crockford-davis-base32-for-humans
