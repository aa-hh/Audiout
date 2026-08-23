# Handoff — from "license server works" to "Audiout is on sale" (2026-08-23)

Self-contained. Read this before `handoff-2026-08-23-license-key-backend.md`
(history) and `docs/RELEASE.md` (the release runbook). Everything below is
current as of the merge of `claude/license-key-backend-cb2e78` into `main`.

## Where things stand

| Piece | State | Where |
|---|---|---|
| Product name | **Audiout** (decided 2026-08-23, roadmap 063). Bundle id `com.audiout.Audiout`, Bonjour `_audiout-pf._tcp`, env prefix `AUDIOUT_*`, key prefix `AUDT-` | this repo, renamed in one commit (a359aab8) |
| License server | **Live and verified** at `https://license.audiout.app` — simulated purchase → key → email received → validate/refund/revoke all proven | `~/Projects/Audiout License Server` = github.com/aa-hh/audiout-license-server (private). README = endpoint contract + setup log |
| Cloudflare | Worker + D1 + R2 + Email Sending on `audiout.app`, all secrets set. Resource names keep the old spelling (`audiouter-license`, `audiouter-releases`) — immutable, invisible | Alec's CF account |
| Paddle | **Sandbox only.** Product "Audiout", price `pri_01m0pkeeq1hw4wg7055aekgev6` (€29.95 one-time), webhook destination → the Worker | sandbox-vendors.paddle.com |
| App: soft license check | Built + tested: Settings › General key field with status line, "Buy Audiout…" button, lowest-priority "unregistered" note in the popover, Sparkle sends the key as a bearer header, check-in client live. All switched on by one Info.plist key (`AudioutLicenseServerURL`) that only a release build carries | `AudioutCore/Sources/AudioutCore/LicenseValidator.swift`, `LicenseCheckIn.swift`, `GeneralSettingsViewController.swift`, `PopoverController.swift`, `AppDelegate.swift` |
| Release pipeline | `scripts/make-release.sh` + `docs/RELEASE.md` exist, **never run end-to-end** (needs Apple credentials) | this repo |
| Website | Buy page + `/thanks` key handover built on branch `claude/buy-page-paddle-c3b002`, **unmerged**, all placeholders, still says "Audiouter" | `~/Projects/Audiouter Website` |
| iPhone app | Still looks for `_audiouter-pf._tcp` — **cannot find a renamed Mac build** until renamed | branch `claude/ios-staging` |

## Next steps, in order

Each step names who does it. "Agent" steps are safe to hand to a fresh
session with this file; "Alec" steps need credentials or a decision.

### 1. Rename the other two codebases (Agent, ~1 h)

1. **Website** (`~/Projects/Audiouter Website`): first merge
   `claude/buy-page-paddle-c3b002` into its `main` (Alec go-ahead), THEN run
   the rename on main — doing it the other way round means a 400-file merge
   conflict. The rename script lives in this repo and works on any git
   checkout: `cd` into the website repo and run
   `python3 "/Users/alechenderson/Projects/AirPlay Controller/scripts/rename-app.py" Audiout`
   (dry run), check the display-name sites it lists (marketing copy — the
   wordmark, `<title>`, package name), then `--apply`, `npm run build`,
   verify both pages in the browser. Rename the folder to `Audiout Website`.
2. **iOS** (`.claude/worktrees/ios-staging`, branch `claude/ios-staging`):
   `git merge main` first (brings the Mac rename in — expect a conflict-free
   merge since `ios/` is disjoint), then the same script inside the worktree
   for the `ios/` tree. The one thing that MUST match is
   `_audiout-pf._tcp` in the phone's Bonjour browser. Phone test on the real
   iPhone (never the Simulator — see memory) against an Audiout Mac build.
3. Update the website's `thanks.js` `razor:` comment: the lookup contract is
   real now (`GET /v1/license/by-transaction/<txn>` on the license server).

### 2. Website goes live-ready (Agent + Alec)

Placeholders in the website's `buy.astro` / `thanks.astro` / `index.astro`
(all marked `data-placeholder`):

| Placeholder | Value |
|---|---|
| `data-paddle-env` | `sandbox` until step 6 |
| `data-paddle-token` | Paddle client-side token (`test_…`) — Paddle dashboard → Developer tools → Authentication → client-side tokens (Alec creates; it's public-safe, fine to commit) |
| `data-paddle-price` | `pri_01m0pkeeq1hw4wg7055aekgev6` |
| `data-license-server` | `https://license.audiout.app` |
| `DOWNLOAD` | `https://license.audiout.app/download?key=` — the thanks page should append the key; or simply tell the buyer the link is in the email |
| `SUPPORT` | `support@audiout.app` — **Alec must set up receiving** for it: `npx wrangler email routing enable audiout.app` + a routing rule to his real inbox (Cloudflare Email Routing, free) |
| `GITHUB` | the public source repo URL once the repo is public (GPL obligation — the buy page links to it) |

Plus one new page: **"Resend my key"** — a one-field form that POSTs
`{"email"}` to `https://license.audiout.app/v1/resend` and shows "If we have
a license for that address, it's on its way" regardless of the answer
(the server always says 202; no enumeration). CORS is already open for
`https://audiout.app`.

**Hosting**: the site is static Astro; nothing is deployed yet. Cloudflare
Pages on the same account is the obvious home (`audiout.app` is already a
Cloudflare zone — one `wrangler pages deploy dist` or a Git-connected Pages
project). Paddle needs the live domain approved before live checkout works
(dashboard → Checkout → Website approval) — Alec.

### 3. First release build (Alec credentials, then Agent)

`docs/RELEASE.md` § "Alec's actions" a–c: Developer ID Application
certificate, `notarytool store-credentials audiout-notary`, Sparkle
`generate_keys` (keep the private key in the Keychain, put the public key in
`SPARKLE_ED_PUBLIC_KEY`). Then:

```bash
APP_VERSION=1.0.0 BUILD_NUMBER=1 \
AUDIOUT_LICENSE_URL="https://license.audiout.app" \
AUDIOUT_BUY_URL="https://audiout.app/buy" \
SPARKLE_ED_PUBLIC_KEY="<public key>" \
scripts/make-release.sh
```

Upload per the server README § "Release files in R2": the zip,
`releases/latest-v1.json`, `appcast-v1.xml` (enclosure URL is just
`https://license.audiout.app/download`). Then the first real check of the
download path: `curl -I "https://license.audiout.app/download?key=<a key>"`
→ 200 with the zip. Expect first-run fallout in `make-release.sh` — it has
never executed past the build step.

### 4. Live check of the app surface (Alec + Agent, one session)

Install the release zip (fresh bundle id → permissions prompt once; settings
start empty). Check: General pane shows the key field + "Unregistered…" +
"Buy Audiout…"; popover shows the unregistered note with "Buy…"; enter a
sandbox key → "Registered. Thank you." and both disappear; Check for
Updates… talks to the feed (no update yet → "up to date"). Then ship a
`1.0.1` to prove an update actually installs through Sparkle — that's the
one path no test covers.

### 5. Sandbox end-to-end with a real checkout (Alec)

On the deployed site: Buy → Paddle test card `4242 4242 4242 4242` → lands on
`/thanks?_ptxn=…` → key appears (polls the server) → email arrives → key
works in the app → download link in the email serves the zip. This is the
first time all three repos meet; budget an hour for small fixes.

### 6. Go live (Alec decisions + Agent config)

- Final price + currency (sandbox says €29.95; `docs/RELEASE.md` still says
  $35 — pick one and fix the other).
- Paddle live account: verify the business, recreate product + price +
  webhook destination on live (same shape as sandbox; the MCP `paddle-live`
  server or the dashboard), new live API key + webhook secret.
- Server: `wrangler secret put PADDLE_API_KEY` / `PADDLE_WEBHOOK_SECRET` with
  the live values, `PADDLE_ENV` → `production`, `PADDLE_PRICE_IDS` → the
  live price id, `npm run deploy`.
- Website: `data-paddle-env` → `production`, live client token, live price.
- Make the source repo public (GPL) and fill `GITHUB`.
- Trademark registration for "Audiout" (roadmap 063's second half) — the
  real anti-fork moat per PRODUCT.md; a lawyer or a filing service, not code.

### Housekeeping once `main` carries the rename

- The worktree `.claude/worktrees/foreman-roadmap-list-87195b` held the
  054 work uncommitted; it is now on `main` via this branch — `git checkout .`
  there and `touch .prunable` (or just delete the worktree).
- `scripts/purge-dev-installs.sh` and the TCC notes still talk about
  `com.audiouter.*` ids for OLD dev builds on Alec's Mac — leave them; they
  purge what was installed, which was the old id.
- Memory index (`~/.claude/projects/…/memory/MEMORY.md`) has the traps from
  the rename (`app-renamed-to-audiout.md`): guards were half-blind on the
  branch; not an issue on `main`.

## Traps learned this session (don't relearn)

- Keys pasted from TextEdit carry an invisible byte-order mark; it corrupts
  `Authorization` headers and shows up as Paddle 403 / "failed to connect".
  Paste from a plain-text editor or strip it.
- `wrangler secret put NAME` — the word after `put` is the label; the value
  is typed at the prompt. A value given as the name becomes a visible secret
  name (happened once; key rotated).
- Paddle sandbox MCP: `https://sandbox-mcp.paddle.com/mcp`, user-scope,
  bearer header. Sandbox retries a failed webhook only 3× / 15 min (live 60×
  / 3 days), so a broken handler is easy to miss in sandbox.
- The license server answers `/v1/license/by-transaction/:txn` by asking
  Paddle directly when the webhook hasn't landed — so `/thanks` works even
  if the webhook is slow, but it means the API key needs `transaction.read`.
- `AUDIOUT_FULL_SUITE=1 bash scripts/run-tests.sh` for a deliberate full run
  (the global hook blocks bare full runs mid-task; both spellings accepted).
