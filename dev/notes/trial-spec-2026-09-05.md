# Spec: the 14-day free trial

Written 2026-09-05 from the owner's decisions in that day's session and a read-only
survey of the three repos (`audiout-shared/.claude/worktrees/attract-users-app-76a8c4/.scratch/growth/trial/current-state.md`
carries every file:line anchor referenced here). This file is the design authority for
the trial; PRODUCT.md § Business Model is amended by it.

## What the owner decided

| Question | Decision |
|---|---|
| Length | 14 days from first start. |
| Identity | One trial per Mac, keyed on a one-way hash of the Mac's hardware UUID. The server refuses a second trial for the same hash. |
| Offline | A trial may start offline. It registers with the server on the first connection. The server's record wins over the local clock. |
| After day 14 | The official build returns to the welcome gate (Buy, Enter key). Source builds never gate. |
| Nudges | A days-left pill in the popover from day one; one-time banner at 3 days left; one-time banner on the last day; then the gate. Buy always carries the trial id. |
| Purchase link | Trial id rides Paddle checkout custom data; the webhook marks the trial converted; the app activates on its next check without pasting a key. |
| Measurement | Server sends PostHog events (trial_started, trial_resumed, trial_refused, trial_converted, trial_expired, license_purchased) and the admin route reports counts and lookups. |
| Download | The current signed .dmg becomes a public download. Sparkle updates stay tied to a valid trial or paid key. |
| Refund | Stays 14 days. Unrelated to the trial. |

## The one idea

**A trial is a licence key.** The server issues `AUDT-…` keys for trials exactly as it does
for purchases, from a second table. Every downstream path the app already has (validate,
check-in, Sparkle bearer header, companion token, download) works on a trial key with no
new client concepts. A trial ends by the server answering `revoked` with
`reason: "trial_expired"`, which the app already treats as unregistered, so the gate
returns at next launch. A trial converts by the server answering the validate call with
the *paid* key in the `key` field, which `LicenseValidator` already stores back
(`LicenseValidator.swift:76-81`: status is written, then the returned key).

Only two things are new on the Mac: a local trial clock so a trial can start offline,
and the trial copy (gate button, pill, two banners, expired gate).

## Modules and their interfaces

Vocabulary per `/codebase-design`: a module is anything with an interface and an
implementation; the interface is everything a caller must know.

### Server: `trials` (new module, `src/trials.ts`)

Interface, four functions:

- `startTrial(env, {install_id, device_hash, client_started_at?}) → {key, started_at, expires_at, outcome}`
  `outcome` is `issued` (new row), `resumed` (this device already has a trial; its
  original row is returned, whatever the client said), or `refused` (device already
  converted or expired: return the existing row so the client learns its state).
  `client_started_at` is honoured only if it lies within `[now - 14d, now]`; otherwise
  `now`. Expiry is `started_at + 14d`, fixed at issue.
- `resolve(env, key) → LicenseRow | TrialRow | null`. Looks in `licenses`, then
  `trials`. Every existing route that does a `licenses` lookup calls this instead.
- `verdict(row: TrialRow, now) → ValidateBody`. Active: `{status:"active", key,
  max_major, kind:"trial", expires_at}`. Converted: the *paid* row's validate body
  (`key` = paid key). Expired: `{status:"revoked", key, reason:"trial_expired",
  expires_at}`.
- `markConverted(env, trialKey, paidKey, now)`. Called by `fulfil` when
  `custom_data.trial` names a trial that has not converted yet; an expired trial
  converts too, since buying after day 14 is still a conversion. Idempotent.

Invariants: one row per `device_hash`; `expires_at` never moves; a converted trial stays
converted through a refund (the paid key's revocation is what bites, via the swap).
Errors: `startTrial` never throws to the client; malformed input is 400, everything
else 200 with an outcome.

### Server: `posthog.ts` (new module)

`capture(env, event, distinct_id, properties)` posting to
`POSTHOG_HOST/capture/` with `POSTHOG_PROJECT_TOKEN`, in `ctx.waitUntil`, failure
swallowed and logged. `distinct_id` is the `install_id` for trial events (same UUID the
Mac app uses as its PostHog anonymous id, so client and server events join on one
person) and the paddle transaction id for purchase events without a trial. No email, no
IP, no key in properties.

### Server: `scheduled` handler (new)

Daily cron. `UPDATE trials SET expired_event_at = now WHERE expires_at < now AND
expired_event_at IS NULL AND converted_key IS NULL RETURNING …`, one `trial_expired`
capture per row. Nothing else runs on a schedule.

### Mac: `TrialClock` (new module, `AudioutCore/Sources/AudioutCore/TrialClock.swift`)

Interface:

- `state(now) → TrialState`: `.none`, `.active(daysLeft: Int, expiresAt: Date,
  registered: Bool)`, `.expired(expiresAt: Date)`.
- `start(now)`: records `trial.startedAt = now` locally, sets `trial.expiresAt = now +
  14d`, nothing else. Idempotent.
- `apply(serverStartedAt:, expiresAt:, key:)`: overwrites the local dates with the
  server's and stores the trial key as `licenseKey`. After this, the normal
  validate/check-in path owns the truth.

Storage: UserDefaults `trial.startedAt`, `trial.expiresAt`, `trial.registered`,
`trial.bannerThreeDaysShown`, `trial.bannerLastDayShown`, plus the existing
`license.key`. Clearing the licence key (`AppSettings.licenseKey = nil`) also clears
the trial fields.

Depth: callers ask one question, `state(now)`. Reconciliation between a local start and
the server's record is inside `apply`. The gate, the pill, the banners and the
analytics all read `state`.

### Mac: `LicenseGate.shouldPresent` (changed)

Gate when `licenseServerURL != nil && licenseUnregistered && !trialLocallyActive`, where
`trialLocallyActive` is `TrialClock.state(now)` being `.active` with no key yet. Once
the trial has a key, the existing rule already does the right thing (a stored key with a
`nil` or `active` verdict passes; `revoked` gates).

### Mac: `DeviceIdentity` (new, tiny)

`deviceHash() → String`: SHA-256 of `"audiout-trial:" + IOPlatformUUID`, hex. Read
via `IOServiceMatching("IOPlatformExpertDevice")`. The salt is public (GPL); the hash
still hides the UUID and is stable across reinstalls, which is the point.

### Mac: `TrialRegistrar` (new, small)

On every launch and on network reachability change, if `state` is `.active(registered:
false)`: `POST /v1/trial/start {install_id, device_hash, client_started_at}`; on 200
call `TrialClock.apply`, then run the normal `LicenseValidator.validate`. Stop retrying
once registered. Failure is silent.

### Website: `buy.js` (changed), download page (new), pricing row (changed)

- `buy.js`: read `?t=<trial key>` and pass `customData: {source, trial}` to
  `Paddle.Checkout.open`. Nothing else changes.
- New page `/download`: "Download Audiout for Mac" button to
  `<PUBLIC_LICENSE_SERVER>/download/latest`, system requirements, "14-day free trial,
  no card, no email" line, link to /pricing. Buy buttons across the site get a quieter
  "Download free trial" companion link.
- Pricing page: a "Free trial" row: "14 days, no card, no email. Every feature."

## Wire contract (AudioutProtocol is not involved; this is the licence server's HTTP)

New:

- `POST /v1/trial/start` body `{install_id, device_hash, client_started_at?}` →
  200 `{key, started_at, expires_at, outcome}`; 400 on malformed input. Rate limit:
  10/min per IP (a new Workers rate-limit binding, same pattern as `TXN_LOOKUP`).
- `GET /download/latest` → the current `latest-v<CURRENT_MAJOR>.json` file from R2,
  no key, counts `public_downloads` in a one-row `counters` table. Cache-Control 5 min.
- `GET /admin/trials` → `{started, active, expired, converted, conversion_rate,
  active_macs_30d}` (conversion_rate is worked out over the cohort started more
  than 14 days ago, numerator and denominator both) and `?key=|device=|install=` → one trial row.
- `GET /admin/active?month=YYYY-MM` → distinct `install_id` count from `devices`
  with `last_seen_at` in that month, split `{paid, trial, total}`. This is the
  monthly-active number the growth plan counts.

Changed:

- `POST /v1/validate`: for a trial key, returns the `verdict` body above. New optional
  fields `kind`, `expires_at`, `reason` (reason already exists for revoked). Existing
  clients ignore unknown fields; `status` values are unchanged, which is what keeps
  shipped 1.0 copies decoding (`LicenseValidator.swift:105-116`).
- `POST /v1/checkin`, `GET /download?key=`, `GET /appcast.xml`: use `resolve`, so a
  trial key counts a device and gets updates while active, and is refused (403) once
  expired.
- `POST /paddle/webhook` → `fulfil`: `TransactionLike` gains `customData: {trial?:
  string, source?: string}`. After issuing the paid key, if `customData.trial` resolves
  to a trial row that is not yet converted, `markConverted`. Capture
  `license_purchased {from_trial: bool, source}`.

Mac client reads: `LicenseValidator.parse` adds `reason`, `kind`, `expires_at` and
writes them to new settings fields unconditionally (the three traps from the 2026-08-30
handoff: write unconditionally, clear with the key, never touch the unreachable path).
The swap is safe as the code stands: `LicenseValidator` writes `licenseStatus` (line 76)
and then `licenseKey` (line 81), and the `licenseKey` setter (`AppSettings.swift:473-482`)
resets status and companion token only when assigned `nil`, not when assigned a
different key. Ticket M4 keeps a test on that ordering so it cannot regress silently.

## Schema (migration 0006)

```sql
CREATE TABLE trials (
  key TEXT PRIMARY KEY,
  device_hash TEXT NOT NULL UNIQUE,
  install_id TEXT NOT NULL,
  started_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  registered_ip_hash TEXT,
  converted_key TEXT REFERENCES licenses(key),
  converted_at TEXT,
  expired_event_at TEXT,
  last_seen_at TEXT
);
CREATE INDEX trials_install ON trials(install_id);
CREATE TABLE counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL DEFAULT 0);
```

`devices.key` today references `licenses(key)`; drop that foreign key in the same
migration (SQLite: rebuild the table) so check-ins from trial keys are stored.

## Copy (BRAND-VOICE rules apply; plain, no absolutes)

- Gate, new primary button: **Try Audiout free for 14 days**. Under it, one line: "No
  card, no email. Every feature. Buy any time." Buy and Enter key stay.
- Popover pill, from day one: **Trial · 9 days left**. Click opens /buy with `?t=`.
- Banner at 3 days left, once: "Your trial ends in 3 days. €30 once keeps everything,
  including updates." Button: Buy Audiout. Dismiss.
- Banner on the last day, once: "Last day of your trial. Tomorrow Audiout asks for a
  key." Button: Buy Audiout.
- Expired gate: headline "Your 14-day trial has ended." Body: "Buy Audiout for €30,
  once, and keep everything you set up. Your scenes and speaker settings are still
  here." Buttons: Buy Audiout, Enter key, Quit. No second trial button.
- Offline at start: no message. The trial starts locally and registers later. If the
  server later answers `refused` with an expired row, the app shows the expired gate.

## Measurement

- Trials started: count of `trials`. Offline starts show up late; the
  `offline_start` property on `trial_started` marks them.
- Active trials: `expires_at > now AND converted_key IS NULL`.
- Conversion: `converted_key IS NOT NULL` over all trials older than 14 days.
- Monthly active Macs: `/admin/active`, and in PostHog from the Mac's opt-in
  `app:launched` with `license_status`. The admin number is the authoritative one; it
  needs no consent because a check-in is abuse detection, not telemetry (PRODUCT.md
  stream 2).
- Funnel in PostHog: `trial_started` → (`license:buy_link_opened` from the Mac, same
  `install_id`) → `trial_converted`. `trial_resumed` and `trial_refused` count
  reinstalls and second attempts.

## What this does not do

- It does not stop someone building from source. Source builds have no gate; that is
  the GPL model, unchanged.
- It does not stop a determined person wiping the hardware UUID hash from the source
  and rebuilding. Same answer.
- It does not defeat a system clock set backwards while offline. The next successful
  validate corrects it, because the server's `expires_at` is authoritative.
- It does not email trialists. There is no address. The mailing-list prompt planned in
  the growth plan is separate and opt-in.

## Rollout order

1. Server (additive, deploy first): migration, `trials.ts`, `posthog.ts`, routes,
   cron, `fulfil` change, admin routes. Old clients are unaffected.
2. Website: `?t=` in buy.js, `/download` page, pricing row, "Download free trial" links.
   Deploy after the server's `/download/latest` exists.
3. Mac: `TrialClock`, `DeviceIdentity`, `TrialRegistrar`, gate button, validator
   fields, pill, banners, expired copy. Ship as 1.x. Until this ships, the site's
   "free trial" wording must not go live, so steps 2 and 3 release together; step 1 can
   go any time.

## Tickets (tracer bullets, blocking edges in brackets)

Server tickets S1 to S6 shipped on the licence server branch `claude/trial-server`
on 2026-09-06 (106 tests). The deviations above (event names, cohort conversion
rate, expired trials convert, no `registered` field) are what shipped.

Server
- S1 Migration 0006 and `resolve()` used by validate, checkin, download, appcast. Tests:
  a trial key validates active, checks in, downloads; an expired one is 403/revoked.
- S2 `POST /v1/trial/start` with the three outcomes and the started_at window. Tests for
  new, resumed, refused, clamped client date, malformed body, rate limit. [S1]
- S3 `GET /download/latest` and `counters`. [S1]
- S4 `fulfil` reads `customData.trial`, `markConverted`, validate swap to the paid key.
  Tests: converted trial validates as the paid key; refund of the paid key gates the
  device. [S1]
- S5 `posthog.ts`, events on start/register/convert/purchase, daily cron for expired.
  Tests: capture called with install_id, no email/IP/key in properties; cron marks each
  row once. [S2, S4]
- S6 `/admin/trials`, `/admin/active`. [S1]

Website
- W1 buy.js `customData.trial` from `?t=`; `/download` page; pricing "Free trial" row;
  "Download free trial" link beside Buy buttons; PRODUCT.md and BRAND-VOICE.md updated
  (the "no free trial" rule ends). Behind `CHECKOUT_LIVE` and a new
  `PUBLIC_TRIAL_LIVE` switch flipped when the Mac release ships. [S3]

Mac
- M1 `DeviceIdentity.deviceHash()` with a test that it is stable and 64 hex chars.
- M2 `TrialClock` with `state/start/apply` and the settings keys; tests for each state
  transition, the 14-day boundary, and clearing with the key. [M1]
- M3 `LicenseGate.shouldPresent` reads `TrialClock`; gate gets the Try button; expired
  gate copy from `reason`. Tests extend `LicenseGateTests`. [M2]
- M4 `LicenseValidator.parse` reads `reason`, `kind`, `expires_at`; a test pins the
  key-swap ordering (status written, then a different key, status survives). Tests extend
  `LicenseValidatorTests`. [M2]
- M5 `TrialRegistrar`: start call on launch and reachability, `apply` on 200, stop when
  registered. Tests with a fake transport. [M2, M4, S2]
- M6 Pill, two one-time banners, buy URL with `?t=`, analytics events
  `license:banner_shown {day}` and `license:expired_gate_shown`, matching the
  `license:*` naming M3 already shipped for `license:trial_started` (the
  Try-it button). Do not fire a second start event; M3's covers it. [M3]
- M7 PRODUCT.md § Business Model amended: trial exists, how it gates, the hardware
  hash under Data Collection stream 2. [M3]

Tests run: server `npm test`; Mac `bash scripts/run-tests.sh --filter <Suite>` (the
bare Swift test command is blocked by a hook in that repo).

## Open questions (defaults chosen, change if wrong)

1. Trial keys share the `AUDT-` prefix. A support email quoting a key cannot tell trial
   from paid by eye. Default: same prefix, the admin lookup answers it. Alternative:
   `AUDT-T…`, which costs one alphabet character of entropy and a `canonicalizeKey`
   change.
2. A converted trial's device row moves to the paid key on the next check-in; the trial
   row keeps its own history. Default: do not merge rows.
3. Should the expired gate offer "I lost my key" (resend by email)? Default: yes, the
   existing control stays; trialists never had a key emailed but a returning buyer
   might land here.
