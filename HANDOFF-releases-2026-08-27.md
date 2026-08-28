# Handoff: release flow — upload, then promote

Scope: **the publish half of the release pipeline.** No Swift changes, no
product behaviour. `scripts/make-release.sh` and `docs/RELEASE.md` already do
the build/notarise/staple half correctly and are not being rewritten.

Sister docs with the same name exist in `~/Projects/Audiouter Website` and
`~/Projects/Audiout License Server`. Read the website one for the general
"upload a candidate, look at it, then promote" pattern; this doc is that same
pattern expressed in this repo's terms, which are not Cloudflare's.

Per `CLAUDE.md`: do this in a worktree branch pushed to origin, not in the
`main` checkout. This handoff touches `scripts/` and `docs/` only — no Swift —
so the test and self-review guards will not fire, but the merge-only rule on
`main` still applies.

## The question this answers

"How do I see a pre-production build and then trigger the move to production
afterwards?" On Cloudflare that is `versions upload` then `versions deploy`.
**This repo already has the same split — it just is not written down as one.**

A release is three separate objects in R2 (`audiouter-releases`), and the
license server reads them independently:

| Object | Who reads it | What it does |
|---|---|---|
| `releases/Audiout-<version>.zip` | `GET /download` streams it | Present but unreferenced = **invisible to everyone** |
| `releases/latest-vN.json` | `GET /download` resolves the current build for the key's major | Flipping this = **new buyers get the new build** |
| `appcast-vN.xml` | `GET /appcast.xml` serves it to Sparkle | Adding the `<item>` = **existing users get the update** |

So the promote gate already exists, in two stages:

```
upload the zip          → nothing changes for anyone      (the "versions upload")
flip latest-vN.json     → new downloads get it            (promote, reversible)
add the appcast item    → installed copies get it         (promote, one-way)
```

Uploading the zip first and leaving it unreferenced is the exact analogue of a
Cloudflare version at 0% traffic. Nothing in `docs/RELEASE.md` says the order
matters. It does, and getting it wrong is user-visible: an appcast item
pointing at a zip that is not in R2 yet makes every running copy of the app
show a failed update.

## Write the order into a script

Add `scripts/publish-release.sh` — a sibling to `make-release.sh`, same house
style (paste-proof one-liners, `set -euo pipefail`, fail fast on missing
inputs). Two modes, because the whole point is that they are separate events:

```bash
# Stage 1 — upload only. Nothing is reachable afterwards.
APP_VERSION=1.0.0 scripts/publish-release.sh upload

# Stage 2 — promote. Run after the smoke test below passes.
APP_VERSION=1.0.0 scripts/publish-release.sh promote
```

`upload` must:

1. Refuse unless `build/Audiout-$APP_VERSION.zip` exists.
2. Refuse unless the app inside it is notarised **and stapled** —
   `xcrun stapler validate` on the extracted bundle, or `spctl -a -vvv -t
   install`. `make-release.sh` staples, but the zip in `build/` can be stale
   from an earlier run; the check costs a second and catches the whole class of
   "shipped the wrong artifact" mistakes.
3. `wrangler r2 object put audiouter-releases/releases/Audiout-$APP_VERSION.zip --file build/Audiout-$APP_VERSION.zip`
4. Print the `shasum -a 256` and stop. **Do not touch `latest-vN.json` or the
   appcast.**

`promote` must:

1. Refuse unless the zip is already in R2 (`wrangler r2 object get … --pipe >
   /dev/null`, or head it) — this is the ordering guard, and it is the reason
   the script exists.
2. Require the Sparkle signature as an argument or env var. The private key
   lives in your keychain and `sign_update` is run by hand (`docs/RELEASE.md`
   step c/e); the script must never try to hold or derive it.
3. Write and put `releases/latest-vN.json`, then `appcast-vN.xml`, **in that
   order** — downloads before updates. If the appcast put fails, new buyers
   still get a working download and nobody's installed copy is broken.

Derive `N` from `APP_VERSION`'s major rather than asking for it separately;
two inputs that must agree is a bug waiting to happen.

## Derive the version from the git tag

`make-release.sh` requires `APP_VERSION` and `BUILD_NUMBER` and errors without
them — correct, keep it. But the release then exists in three places that can
disagree: the tag, `APP_VERSION`, and the appcast item.

Make the **git tag the single source of truth**: `v1.0.0` → `APP_VERSION=1.0.0`,
and `BUILD_NUMBER` from the commit count or a monotonic counter. Have
`publish-release.sh` verify that `git describe --tags --exact-match` matches
`APP_VERSION` and refuse otherwise. Publishing from a dirty or untagged tree is
the mistake this prevents.

## The GitHub Release: metadata only

Cutting a GitHub Release in this repo is a good record of what shipped and a
natural home for the notes that become the appcast item's `<description>`.

**Never attach the distributable zip to it.** GitHub release assets on a public
repo are public; on a private repo they are one visibility change away from
public. The entire paid-distribution model rests on `/download` being gated on
a key (`README.md` in the license server). An attached zip routes around the
gate permanently, and you cannot un-publish something that has been mirrored.

If you want the tag to *do* something, have it open a checklist issue or post
the notes — not upload the artifact. Notarisation cannot run in GitHub-hosted
CI without exporting the Developer ID `.p12` and an app-specific password into
repo secrets, which for a one-person shop is a worse trade than typing one
command on the Mac that already holds the keychain. Keep `make-release.sh`
local. Revisit only if release cadence makes that painful.

## Sparkle: the gradual-rollout knob

The appcast promote is the one-way step — a user whose copy already updated
cannot be rolled back by editing XML. Sparkle's answer is a phased rollout:

```xml
<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>
```

Seconds between groups. Sparkle uses seven hardcoded groups, so `86400` spreads
the update over roughly a week, one group per day after the item's `pubDate`.
The group id is generated locally and never sent anywhere. It does not apply to
manual update checks or to items marked critical — so early adopters checking
by hand still get it immediately, which is usually what you want.

Use it on 1.0.x. It converts "every installed copy at once" into something with
a week of signal before full exposure, and pulling the item mid-rollout limits
the blast radius to the groups already served.

Sparkle 2 also supports `sparkle:channel` for a beta feed. Not recommended
right now: the appcast here is served per-major from R2 keyed off the key's
`max_major`, and adding a channel dimension means the license server has to
learn about it. Note it as an option; do not build it in this pass.

## What "staging" means in this repo

Not a second deployment target — a second **identity**. `CLAUDE.md`'s rule
stands and is the pre-production step: every build handed over for testing gets
its own `APP_NAME`/`BUNDLE_ID` via `scripts/make-app.sh`, because macOS pins TCC
grants to bundle id plus code signature and a reused id fails in ways that look
like product bugs.

And per `docs/RELEASE.md`: a release build must never be launched on this Mac.
The one exception the runbook allows —
`scripts/verify-standalone-app.sh` — is a Homebrew-less launch check, and it
moves real Homebrew directories, so it stays a deliberate manual step. Do not
wire it into `publish-release.sh`; make the script *ask* whether it has been
run and refuse without an explicit acknowledgement flag.

## Where this sits in the cross-repo order

`docs/LAUNCH.md` in the license server sequences the whole launch, and the app
is not first: the website must be live before Paddle will approve the checkout
domain (5–7 business days), and a notarised build must be in R2 before the
license server's `/download` stops returning 404. So the first real run of this
flow is `upload` early — the zip can sit unreferenced in R2 for as long as you
like — and `promote` only once the other two repos are ready.

That is the flow working as designed, not a delay.

## Acceptance

1. `publish-release.sh upload` with a build in `build/`: the zip appears in R2,
   `GET /download?key=<valid staging key>` against
   `license-staging.audiout.app` still 404s. Nothing became reachable.
2. The script refuses an un-notarised or un-stapled zip, and refuses when
   `APP_VERSION` does not match the exact git tag.
3. `publish-release.sh promote` on staging: `/download` now streams the zip,
   and `GET /appcast.xml` with a valid bearer key lists the new item.
4. Sparkle actually applies the update from that feed — the signature verifies
   against the `SUPublicEDKey` baked into a test build.
5. Rollback: re-put the previous `latest-vN.json` and remove the new appcast
   item; `/download` serves the old build again and the feed no longer offers
   the new one.

Step 4 is the one that cannot be skipped. A bad Sparkle signature is invisible
until a user's copy silently refuses to update.

## Out of scope

- Swift, product behaviour, the build/notarise half of the pipeline.
- The iOS companion (`claude/ios-staging`) — it has its own distribution story
  and none of this applies to it.
- Paddle setup, the website, the license server's own deploy flow.
