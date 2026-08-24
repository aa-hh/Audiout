# Website ↔ license server integration spec

For whoever builds the website. The backend (license server, Paddle, email,
downloads) is live and owned by the app project — the site only has to talk
to it correctly. This document is the complete contract; the license server's
README (`github.com/aa-hh/audiout-license-server`, private) is the source of
truth if the two ever disagree.

## The three systems

| System | What it is | State |
|---|---|---|
| Website | Static Astro site, repo `aa-hh/audiouter-website` | Buy funnel built on branch `claude/buy-page-paddle-c3b002`, unmerged, not deployed |
| License server | Cloudflare Worker at `https://license.audiout.app` | **Live and verified** — purchase → key → email proven on sandbox |
| Paddle | Merchant of record (checkout, receipts, VAT) | **Sandbox only.** Product "Audiout", price `pri_01m0pkeeq1hw4wg7055aekgev6` (€30 one-time; per-market overrides $30 USD / £25 GBP) |

## What each page must do

### /buy — checkout

- Paddle.js inline checkout. Config comes from data attributes on the page:
  - `data-paddle-env` — `sandbox` now, `production` at go-live.
  - `data-paddle-token` — Paddle **client-side** token. Public-safe by
    design (it ships in page source), fine to commit. Sandbox value:
    `test_92006632f7790eba19aa4c6a1b7` (the "Purchase Page" token). The
    other active sandbox token ("Hosted Checkout") is Paddle-managed for a
    hosted checkout page — don't use it for the site's inline checkout.
  - `data-paddle-price` — the price id above.
- On success Paddle redirects to `/thanks?_ptxn=<transaction id>`.
- Before live checkout works, Paddle must approve the domain: dashboard →
  Checkout → Website approval (Alec).

### /thanks — key handover

- Gate on the transaction reference format before showing any purchase
  content: `/^txn_[a-z0-9]{26}$/`. No match → an "oops, nothing to see"
  view (this must be the no-JS default too).
- With a well-formed `_ptxn`, poll the license server:

  ```
  GET https://license.audiout.app/v1/license/by-transaction/<txn>
    200 {"key": "AUDT-XXXXX-XXXXX-XXXXX-XXXXX"}   key exists
    404                                            not yet / not a purchase
  ```

  The server falls back to asking Paddle directly when its webhook hasn't
  landed, so the poll usually resolves in seconds. Poll ~3s for ~2 minutes,
  then fall back to "it's in your email" copy.
- **404 is deliberately ambiguous** — it means *pending* AND *unknown*. Never
  tell a visitor their purchase is invalid: a real buyer with a slow webhook
  must not see that. A forged txn just polls out to the email-fallback view,
  which contains nothing to harvest.
- Once the key is shown, the download link must carry it:
  `https://license.audiout.app/download?key=<key>` — the bare `/download`
  URL 403s. The same link is in the buyer's email; it is durable (works as
  long as the key is active).

### /resend — lost keys

- One email field. `POST https://license.audiout.app/v1/resend` with body
  `{"email": "..."}`.
- The server **always answers 202**, whatever the address (rate-limited to
  3 per address per day). The page must show the same neutral copy on every
  outcome, including network failure: "If we have a license for that
  address, it's on its way." Anything more specific lets someone test which
  emails have bought.

### Every page

- CORS: the server allows origin `https://audiout.app` (`SITE_ORIGIN`,
  server-side setting). If the site ever serves from a different origin,
  the backend must be told — the fetches above will fail otherwise.
- The GPL notice links: the source repo URL is still a placeholder until the
  repo goes public (a go-live step).

## Values

| Placeholder | Value | Who supplies it |
|---|---|---|
| `data-license-server` | `https://license.audiout.app` | done |
| `data-paddle-env` | `sandbox` (→ `production` at go-live) | website |
| `data-paddle-token` | `test_92006632f7790eba19aa4c6a1b7` ("Purchase Page") | done (→ live token at go-live) |
| `data-paddle-price` | `pri_01m0pkeeq1hw4wg7055aekgev6` (→ live id at go-live) | done / Alec |
| `DOWNLOAD` | `https://license.audiout.app/download` (+ `?key=` via JS) | done |
| `SUPPORT` | `support@audiout.app` | value done; **Alec** sets up receiving (Cloudflare Email Routing) |
| `GITHUB` | public repo URL | **Alec** (when the repo goes public) |

## Current state of the branch (2026-08-23)

`claude/buy-page-paddle-c3b002` already implements all of the above.
Commit `4659848` (backend side, 2026-08-23) filled the live values, updated
the `/thanks` lookup to the real contract, added the `?key=` link upgrade and
built `/resend` — keep it or replace it, but keep the behaviors above either
way. The checkout flow itself was card-submit-verified against sandbox
earlier. Note: the local worktree's `buy.astro` has uncommitted copy edits
from another session.

**Rename**: the product is now **Audiout** (was Audiouter). Merge the branch
into the website `main` FIRST, then run the rename on main — the other order
is a 400-file conflict:

```bash
python3 "/Users/alechenderson/Projects/AirPlay Controller/scripts/rename-app.py" Audiout          # dry run
python3 "/Users/alechenderson/Projects/AirPlay Controller/scripts/rename-app.py" Audiout --apply
```

Check the display-name sites it lists (wordmark, `<title>`, copy), rebuild,
eyeball both pages.

## Go-live switch list (website side)

In order, after Alec's live-Paddle setup:

1. `data-paddle-env` → `production`.
2. `data-paddle-token` → the live client-side token.
3. `data-paddle-price` → the live price id.
4. Fill `GITHUB` once the repo is public.
5. Deploy (Cloudflare Pages on the `audiout.app` zone is the intended home)
   and get the domain approved in Paddle.

## Sandbox test script

On the deployed (or locally served) site with sandbox values:

1. `/buy` → checkout renders inline → card `4242 4242 4242 4242`, any
   future expiry, any CVC.
2. Redirects to `/thanks?_ptxn=…` → key appears within seconds → email
   arrives with the same key + download link.
3. `/thanks` with no or malformed `_ptxn` → oops view.
4. `/resend` with the purchase email → 202, mail arrives; with a random
   email → identical page behavior, no mail.
5. Download link 404s until the first release zip is uploaded — expected
   until release day.
