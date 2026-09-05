# Website handoff — launch day, 2026-09-05

Everything outside the website repo is done. What is left is one command in
`audiout-website`, run by whoever owns that repo.

## State before you start

| | |
|---|---|
| Launch day | **2026-09-05** (Berlin calendar) |
| Version shipping | Audiout 1.0.0, build 4 |
| Release artifact | `Audiout-1.0.0.dmg`, notarized + stapled, in `audiout-releases-live` |
| Verified | `license.audiout.app/download` streams it; sha256 `ec9a0b43ab928652691f76f72ee50c29cb76ef0dc10843066518d3035be5a268` |
| Paddle live | product `pro_01m0tw6k36m435v94bbv1ta6ys`, price `pri_01m0tw8f7ww002hq054xs11mkh` (€30 one-time) |
| Checkout domain | `audiout.app`, approved, Apple Pay verified |
| Business verification | complete |
| Production D1 | empty (0 licences) |

## The four launch instants are already in place

`launch.sh` step 4 refuses to deploy until Paddle and the license server carry
these. Both sides are done — pass `LAUNCH_EXTERNAL_DONE=1`.

| | |
|---|---|
| `launchWeek50` expires | 2026-09-11T22:00:00Z |
| `weekTwo40` expires | 2026-09-18T22:00:00Z |
| `launchMonth20` expires | 2026-10-05T22:00:00Z |
| license server `REFUND_PROMO_UNTIL` | 2026-10-05T22:00:00Z (deployed) |

## The command

```bash
cd ~/Projects/Audiouter\ Website
git pull                                   # commit ab8aacb must be present
LAUNCH_EXTERNAL_DONE=1 bash scripts/launch.sh 2026-09-05
```

It flips `.env.production`, builds, checks the build is launch-shaped, commits,
deploys to audiout.app, and smoke-tests. Back it out with
`npx wrangler rollback --env production`.

A dry run of steps 1–4 passed on 2026-09-05 07:47 — the build is launch-shaped
and every assertion is green. Only steps 5–7 (commit, deploy, smoke) are left.

## One thing changed in your repo

Commit `ab8aacb` adds a cross-repo check. `/refund` states a 30-day window for
purchases made on or before the launch promo's last day; the license server
decides the real answer from its own `REFUND_PROMO_UNTIL`. Until now a human
copied that value across by hand, and a mismatch showed up as a declined refund
weeks later rather than a build error.

The build now publishes the instant it derived at `/refund-policy.json`, and
`guard:production` fetches `license.audiout.app/v1/refund-policy` and refuses
to release on a disagreement. An unreachable server warns; a reachable one that
disagrees is fatal. Nothing for you to do — it passes today.

`/refund` needed no copy edit: it already derives the date from
`PUBLIC_LAUNCH_DATE` and renders no date at all before launch.

## After you deploy

Tell whoever is running the Paddle test. There is a single-use 100% discount
waiting (`AUDIOUTLIVETEST0905`, expires 2026-09-06) for one real zero-cost
checkout, and it gets archived straight after.

## Not in scope

`PUBLIC_APP_STORE_URL` stays a placeholder — Audiout Remote launches on its own
day and `launch.sh` does not touch it.
