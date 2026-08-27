# Release runbook

How a build goes from source to the notarised, distributable zip that Paddle
sells and Sparkle updates deliver. Related: roadmap 054 (paid distribution,
Ardour model — see `PRODUCT.md` § Business Model on `origin/main`).

**Nothing described here is public yet.** No download exists, no Paddle
product exists, no appcast has a real release item. This is the pipeline for
when that changes, not a claim that it has.

## Purchase terms (state once, exactly)

**€30, one-time. Covers the current major version and every update until the
next major release.**

Any other copy about price or what it includes (site, receipts, support
replies) restates this, not a variant of it.

## Pipeline command sequence

```bash
# 1. Tag the commit that is the release. The tag is the single source of truth
#    for the version — publishing refuses to run from an untagged or dirty tree.
git tag v1.0.0 && git push origin v1.0.0

# 2. Build it. APP_VERSION comes off the tag; BUILD_NUMBER just has to increase,
#    and the commit count is a fine monotonic source for it.
APP_VERSION=1.0.0 BUILD_NUMBER="$(git rev-list --count HEAD)" \
AUDIOUT_LICENSE_URL="https://<license-server>" \
AUDIOUT_BUY_URL="https://<site>/buy" \
SPARKLE_ED_PUBLIC_KEY="pTDAl+JJHH5ryMLZdPbUfSh0Ugq488O+Vjc1FURssQk=" \
scripts/make-release.sh

# Produces build/Audiout-1.0.0.zip (notarised, stapled) and prints its
# shasum -a 256. scripts/make-release.sh requires APP_VERSION and BUILD_NUMBER
# to be set — it errors out immediately otherwise.
```

**Why the tag comes first:** a release otherwise exists in three places that can
drift apart — the git tag, `APP_VERSION`, and the appcast item. Making the tag
authoritative collapses that to one, and `scripts/publish-release.sh` enforces
it: `git describe --tags --exact-match` must equal `v$APP_VERSION`, and the tree
must be clean, or it refuses to upload.

### Build-time env vars

| Variable | Info.plist key | What it turns on |
|---|---|---|
| `AUDIOUT_LICENSE_URL` | `AudioutLicenseServerURL` | The soft license check: key validation (`POST /v1/validate`), check-ins, and the unregistered note. Also supplies `SPARKLE_FEED_URL` when that isn't set. |
| `AUDIOUT_BUY_URL` | `AudioutBuyURL` | The "Buy Audiout…" button in Settings and the Mixer note's "Buy…" action. Absent ⇒ both hidden. |
| `SPARKLE_FEED_URL` | `SUFeedURL` | Where the updater checks. Defaults to `$AUDIOUT_LICENSE_URL/appcast.xml`. |
| `SPARKLE_ED_PUBLIC_KEY` | `SUPublicEDKey` | The EdDSA public key update archives are verified against. |

All four are optional, and each absence is a real product state, not a broken
build: a build run from source has no license server, so it validates nothing,
prompts nothing and updates nothing — that is the free build.

`SPARKLE_FEED_URL` / `SPARKLE_ED_PUBLIC_KEY` are consumed by `make-app.sh`
(which `make-release.sh` calls internally). Setting only one is a hard error —
a feed with no key (or a key with no feed) is a broken updater, not a degraded
one. That check applies to the feed URL derived from `AUDIOUT_LICENSE_URL`
too, so a license-server build still needs the signing key.

**A release build must never be launched on this Mac for testing.** It carries
the real Developer ID signature and the real `SUFeedURL`/`SUPublicEDKey` — the
same identity every user's copy will carry. Launching it here mixes this
machine's TCC grants and Login Items into the one identity real users share,
and a bundled-dylibs build (`AUDIOUT_BUNDLE_DYLIBS=1`, which this pipeline
always sets) is the slow, self-contained path — not what you want for
iteration anyway. For live testing, use a throwaway `APP_NAME`/`BUNDLE_ID` via
`scripts/make-app.sh` directly, per CLAUDE.md's every-build-new-bundle-id rule.
The one manual proof this runbook does call for —
`scripts/verify-standalone-app.sh` — is a Homebrew-less *launch* check, not a
live-testing session; do it, then don't keep using that copy.

## What the pipeline does *not* do

- No DMG. The zip `make-release.sh` produces is what both Paddle's file
  delivery and Sparkle's updater consume directly.
- No upload. `make-release.sh` builds and proves the artifact; publishing is a
  separate command run later, by hand — see the next section.

---

## Publishing: upload, then promote

Publishing is **two separate events**, and they are separate on purpose. A
release is three independent objects in R2 (bucket `audiouter-releases` — note
the "er"), and the license server reads each one on its own:

| Object | Who reads it | What it does |
|---|---|---|
| `releases/Audiout-<version>.zip` | `GET /download` streams it | Present but unreferenced = **invisible to everyone** |
| `releases/latest-vN.json` | `GET /download` resolves the current build for the key's major | Flipping it = **new buyers get the new build**. Reversible. |
| `appcast-vN.xml` | `GET /appcast.xml` serves it to Sparkle | Adding the `<item>` = **existing users get the update**. One-way. |

`N` is the major version, derived from `APP_VERSION` — never given separately.

```bash
# Stage 1 — upload. Nothing becomes reachable; smoke-test at your leisure.
APP_VERSION=1.0.0 scripts/publish-release.sh upload

# ...then run scripts/verify-standalone-app.sh by hand, and sign the zip with
# Sparkle's sign_update (step c/e below).

# Stage 2 — promote. This is what users see.
APP_VERSION=1.0.0 SPARKLE_ED_SIGNATURE="<sign_update output>" \
  scripts/publish-release.sh promote --verified-standalone
```

**The order is not a style preference.** An uploaded-but-unreferenced zip is the
exact analogue of a deployment sitting at 0% traffic: it exists, it costs
nothing, nobody can reach it, and it can sit there for weeks. Do it the other
way round — publish an appcast item pointing at a zip that is not in R2 yet —
and every running copy of the app shows a **failed update** until you fix it.
For the same reason `promote` writes `latest-vN.json` *before* `appcast-vN.xml`:
if the appcast put fails, new buyers still get a working download and no
installed copy is broken.

`upload` also refuses a zip whose app is not notarised **and** stapled — `build/`
is never cleaned, so the zip sitting there can be a stale artifact from an
earlier attempt, and that check is the one that catches it.

`promote` refuses without an explicit `--verified-standalone`. That is an
acknowledgement, not a check: `scripts/verify-standalone-app.sh` moves real
Homebrew directories on this Mac, so it stays a deliberate manual step and is
never invoked from the publish script. It also refuses if the object in R2 is
not byte-identical to the local zip, since the appcast item's length and version
fields are read from the local copy.

### Phased rollout

Every appcast item carries
`<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>` —
seconds between groups. Sparkle uses **seven hardcoded groups**, so 86400
spreads the update over roughly a week, one group per day after the item's
`pubDate`. The group id is generated on the user's machine and never sent
anywhere. Manual "Check for Updates…" and items marked critical bypass the
phasing entirely, so anyone checking by hand gets it immediately.

This is the only brake on the one-way step: a copy that has already updated
cannot be rolled back by editing XML, but pulling the item mid-rollout limits
the blast radius to the groups already served.

Sparkle 2's `sparkle:channel` (a separate beta feed) is deliberately **not**
built — the appcast is served per-major off the key's `max_major`, so a channel
dimension would mean teaching the license server about channels.

### Rollback

Re-put the previous `releases/latest-vN.json` and remove the new `<item>` from
`appcast-vN.xml`. `/download` serves the old build again and the feed stops
offering the new one. Copies that already updated stay updated.

### The GitHub Release: metadata only

Cutting a GitHub Release is a good record of what shipped and a natural home for
the notes. **Never attach the distributable zip to it.** This repo is public, so
a release asset is public the moment it is uploaded — and the entire paid model
rests on `/download` being gated on a key. An attached zip routes around that
gate permanently, and you cannot un-publish something that has been mirrored.

Notarisation also cannot run in GitHub-hosted CI without exporting the Developer
ID `.p12` and an app-specific password into repo secrets, which for a one-person
shop is a worse trade than typing one command on the Mac that already holds the
keychain. `make-release.sh` stays local.

---

## Alec's actions — credentials required

Everything below needs credentials or accounts this pipeline cannot hold
(nothing here belongs in the repo, in CI config, or in any script). One-time
setup unless noted "per release."

### a. Developer ID Application certificate

A "Developer ID Application" identity must be in the login keychain on this
Mac before `make-release.sh` (or `make-app.sh` with
`CODESIGN_REQUIRE_IDENTITY=1`) will produce a signable release build.
`make-app.sh` auto-detects it by name — no config needed once it's installed.

### b. One-time notarytool credential storage

```bash
xcrun notarytool store-credentials audiout-notary \
  --apple-id "<your Apple ID>" \
  --team-id "<your Team ID>" \
  --password "<an app-specific password, not your Apple ID password>"
```

Stores the credentials in the keychain under the profile name
`audiout-notary` — the name `make-release.sh` looks for by default
(override with `NOTARY_PROFILE`). Generate the app-specific password at
appleid.apple.com; it is not your account password.

### c. One-time Sparkle EdDSA keygen

Sparkle 2 signs each update archive with an EdDSA key pair, generated by the
`generate_keys` tool that ships in the Sparkle distribution (see
`AudioutCore/Package.swift`'s Sparkle dependency for the pinned version).
The **private key stays in your keychain** — it never leaves this Mac and
never enters the repo. The **public key** is a build input: pass it as
`SPARKLE_ED_PUBLIC_KEY` (see Pipeline command sequence above), which
`make-app.sh` embeds as `SUPublicEDKey` in Info.plist so every shipped copy of
the app can verify update signatures against it.

**Done 2026-08-27.** The key pair lives in the login keychain on this Mac and
its public half is the value baked into the Pipeline command sequence above:
`pTDAl+JJHH5ryMLZdPbUfSh0Ugq488O+Vjc1FURssQk=`. Reprint it anytime with
`generate_keys -p`. Never run a bare `generate_keys` again once a release has
shipped — a second key pair would strand every installed copy, which verifies
updates against this one forever.

### d. Paddle account + product setup

- Create the Paddle product: **€30, one-time**, matching the purchase terms
  stated above exactly.
- Upload each release's distributable zip (`build/Audiout-<version>.zip`
  from `make-release.sh`) as the thing Paddle delivers on purchase, or wire
  Paddle's delivery to fetch it from wherever it's hosted.
- No Paddle SDK or checkout script lives in either repo yet — the marketing
  site's buy button is still a placeholder link until this step is done.

### e. Per-release: sign the distributable archive

The download and the update feed are both served by the license server
(`~/Projects/Audiout License Server`, README there is the contract), gated on a
key — so publishing a release is an upload to its R2 bucket, not an edit to the
website. `scripts/publish-release.sh` does that upload (see **Publishing**
above); the one part it cannot do is the signature.

Sign the distributable zip with Sparkle's `sign_update` tool (same distribution
as `generate_keys` above), using the private key from step c, and hand the
output to `promote` as `SPARKLE_ED_SIGNATURE`:

```bash
./bin/sign_update build/Audiout-1.0.0.zip
```

The private key stays in the keychain. No script here holds it, derives it, or
asks for it — a signature is pasted in per release, on purpose.

For reference, the three objects `publish-release.sh` writes (bucket
`audiouter-releases`; `N` is the major version):

```bash
# Stage 1: upload
wrangler r2 object put audiouter-releases/releases/Audiout-1.0.0.zip --file build/Audiout-1.0.0.zip
# Stage 2: promote — latest first, appcast second
wrangler r2 object put audiouter-releases/releases/latest-v1.json --file latest-v1.json
wrangler r2 object put audiouter-releases/appcast-v1.xml --file appcast-v1.xml
```

Enclosure URLs in the appcast are simply `<PUBLIC_BASE_URL>/download` — Sparkle
sends the key as a bearer header on the enclosure fetch too, and the server
resolves which file that key is entitled to. `latest-vN.json` is
`{"version": "<version>", "file": "releases/Audiout-<version>.zip"}`.

### f. Choose the license server's public URL

`AUDIOUT_LICENSE_URL` (passed at build time, see above) has to be a real URL
that will keep serving `/v1/validate` and `/appcast.xml` for the life of every
copy of the app already installed — a one-time choice, not a per-release one,
because changing it later strands existing installs (they keep checking the OLD
URL forever unless a manual update ships a new one). Decide it before the first
public release, not after; it is the license server's `PUBLIC_BASE_URL`.
