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
# 1. Bump the version/build number for this release, then run the pipeline:
APP_VERSION=1.0.0 BUILD_NUMBER=3 \
AUDIOUT_LICENSE_URL="https://<license-server>" \
AUDIOUT_BUY_URL="https://<site>/buy" \
SPARKLE_ED_PUBLIC_KEY="<public key from Sparkle's generate_keys>" \
scripts/make-release.sh

# Produces build/Audiout-1.0.0.zip (notarised, stapled) and prints its
# shasum -a 256. scripts/make-release.sh requires APP_VERSION and BUILD_NUMBER
# to be set — it errors out immediately otherwise.
```

### Build-time env vars

| Variable | Info.plist key | What it turns on |
|---|---|---|
| `AUDIOUT_LICENSE_URL` | `AudioutLicenseServerURL` | The soft license check: key validation (`POST /v1/validate`), check-ins, and the unregistered note. Also supplies `SPARKLE_FEED_URL` when that isn't set. |
| `AUDIOUT_BUY_URL` | `AudioutBuyURL` | The "Buy Audiout" button on the first-open gate, in Settings and in the Mixer note. Absent ⇒ all hidden. `make-staging.sh` and `make-release.sh` default it to `https://audiout.app/buy`. |
| `SPARKLE_FEED_URL` | `SUFeedURL` | Where the updater checks. Defaults to `$AUDIOUT_LICENSE_URL/appcast.xml`. |
| `SPARKLE_ED_PUBLIC_KEY` | `SUPublicEDKey` | The EdDSA public key update archives are verified against. |

All four are optional **to `make-app.sh`**, and each absence is a real product
state, not a broken build: a build run from source has no license server, so it
validates nothing, prompts nothing and updates nothing — that is the free build.

`make-release.sh` is stricter: it requires `AUDIOUT_LICENSE_URL` and refuses to
build until that server answers. The artifact it produces is the one a buyer
pays for, and the address goes into Info.plist — every installed copy polls it
forever and cannot be redirected afterwards, so a wrong or unreachable value
costs buyers both key validation and the update channel that would deliver the
fix. Unauthenticated, the feed must answer `401 license key required`; anything
else fails the build before it starts. See "Pre-flight" in `make-release.sh`.

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

## Staging rehearsal

`APP_VERSION=… BUILD_NUMBER=… scripts/make-staging.sh` runs the same pipeline
against the staging license server and then goes further: wraps the stapled
app in a notarised, stapled DMG, signs it with `sign_update`, writes
`latest-vN.json` + `appcast-vN.xml`, and uploads everything to the
`audiout-releases-staging` R2 bucket. `SKIP_NOTARIZE=1` and `SKIP_DMG=1`
skip those steps for fast iteration. It never touches the production bucket.

## What the pipeline does *not* do

- No DMG. The zip `make-release.sh` produces is what both Paddle's file
  delivery and Sparkle's updater consume directly.
- No automatic upload anywhere. Paddle and the appcast are both manual steps
  below, on purpose — this pipeline builds and proves the artifact; it doesn't
  publish it.

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

### d. Paddle account + product setup

- Create the Paddle product: **€30, one-time**, matching the purchase terms
  stated above exactly.
- Upload each release's distributable zip (`build/Audiout-<version>.zip`
  from `make-release.sh`) as the thing Paddle delivers on purchase, or wire
  Paddle's delivery to fetch it from wherever it's hosted.
- No Paddle SDK or checkout script lives in either repo yet — the marketing
  site's buy button is still a placeholder link until this step is done.

### e. Per-release: sign the archive and upload it to the license server's R2

The download and the update feed are both served by the license server
(`~/Projects/Audiout License Server`, README there is the contract), gated on
a key — so publishing a release is an upload to its R2 bucket, not an edit to
the website. For every release meant to reach existing users via Sparkle, with
`N` the major version:

1. Sign the distributable zip with Sparkle's `sign_update` tool (same
   distribution as `generate_keys` above), using the private key from step c.
2. Write `appcast-vN.xml` listing only the N.x releases, each `<item>` carrying
   the version and the signature `sign_update` printed. Enclosure URLs are
   simply `<PUBLIC_BASE_URL>/download` — Sparkle sends the key as a bearer
   header on the enclosure fetch too, and the server resolves which file that
   key is entitled to.
3. Write `latest-vN.json`: `{"version": "<version>", "file": "releases/Audiout-<version>.zip"}`.
4. Upload all three. `--remote` and `-J eu` are both required: without
   `--remote` wrangler writes to the local simulator and still says "Upload
   complete", and the buckets live in the EU jurisdiction.


   ```bash
   wrangler r2 object put audiout-releases-live/releases/Audiout-1.0.0.zip --file build/Audiout-1.0.0.zip -J eu --remote
   wrangler r2 object put audiout-releases-live/releases/latest-v1.json --file latest-v1.json -J eu --remote
   wrangler r2 object put audiout-releases-live/appcast-v1.xml --file appcast-v1.xml -J eu --remote
   ```

### f. Choose the license server's public URL

`AUDIOUT_LICENSE_URL` (passed at build time, see above) has to be a real URL
that will keep serving `/v1/validate` and `/appcast.xml` for the life of every
copy of the app already installed — a one-time choice, not a per-release one,
because changing it later strands existing installs (they keep checking the OLD
URL forever unless a manual update ships a new one). Decide it before the first
public release, not after; it is the license server's `PUBLIC_BASE_URL`.
