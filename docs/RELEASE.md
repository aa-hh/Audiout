# Release runbook

How a build goes from source on `main` to the notarised DMG a buyer downloads
and Sparkle updates deliver. Related: roadmap 054 (paid distribution, Ardour
model — see `PRODUCT.md` § Business Model on `origin/main`).

Live since 2026-09-05: 1.0.0 is published, sold through Paddle, and served by
`license.audiout.app`. Every release after it replaces a version people are
already running.

## Purchase terms (state once, exactly)

**€30, one-time. Covers the current major version and every update until the
next major release.**

Any other copy about price or what it includes (site, receipts, support
replies) restates this, not a variant of it.

## Cutting a release

```bash
scripts/release.sh 1.0.1
```

That is the whole thing. Run it from the **main checkout, on `main`** — it
refuses anywhere else. It builds, signs, notarises, staples, wraps the app in a
notarised DMG, signs the DMG with Sparkle's `sign_update`, writes
`latest-v1.json` and `appcast-v1.xml`, and uploads all three to the live R2
bucket, which is what publishing means. Expect two Apple notary waits of a few
minutes each.

Pass a live licence key to have it re-download the published artifact through
`/download` and check it the way a buyer's Mac will — Gatekeeper's verdict, the
stapled ticket, the `/Applications` drag target, the plist's licence URL:

```bash
VERIFY_KEY=AUDT-XXXXX-XXXXX-XXXXX-XXXXX scripts/release.sh 1.0.1
```

`release.sh` supplies the two values that define a live release
(`AUDIOUT_LICENSE_URL=https://license.audiout.app`,
`R2_BUCKET=audiout-releases-live`) and derives `BUILD_NUMBER` from the commit
count on `main`, so it can neither repeat nor go backwards. Typing those three
by hand is what went wrong on the first live release.

Before it builds anything it refuses on: a dirty tree, a branch that is not
`main`, a `main` that disagrees with `origin/main`, and any migration still
unapplied on the production D1 database — the deployed Worker writes columns
those migrations add, so a purchase would take the money and fail to issue a
key.

Two things stay manual, and neither is optional:

1. `scripts/verify-standalone-app.sh build/Audiout.app` — proves the bundle
   launches on a Mac with no Homebrew. It moves this machine's real Homebrew
   directories, so it is never run automatically.
2. Download through `/download?key=<a real key>` and open the app once from
   `/Applications`. `VERIFY_KEY` does the download half; opening it is yours.

### The layers underneath

`release.sh` publishes nothing itself. It is the gate in front of
`make-staging.sh`, which is and stays the only publish pipeline — a production
release is that same pipeline pointed at the live server and bucket.
`make-staging.sh` in turn calls `make-release.sh` (build → notarise → staple →
zip), which calls `make-app.sh` (compile → assemble → sign). Change how a
release is *built* in those; `release.sh` only decides whether one may run.

Running `make-staging.sh` bare is the staging rehearsal: same pipeline, staging
licence server, staging bucket, never the production one. `SKIP_NOTARIZE=1` and
`SKIP_DMG=1` cut the waits for fast iteration on the upload path.

`make-app.sh` counts the SwiftPM resource bundles the compile produced and
refuses if that count differs from `RESOURCE_BUNDLE_NAMES`. A bundle the build
emits but that list omits is left out of the `.app` silently, and its consumer
`fatalError`s at first launch on a user's Mac — that is how the notarised 1.0.0
shipped and crashed before drawing a window. Add a new one to the list; do not
delete the check.

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

## What the pipeline does *not* do

- **No GitHub Release asset, ever.** The paid model rests on `/download` being
  gated on a key. Assets on a public repo are public, and on a private repo one
  visibility change from it — an attached DMG routes around the gate
  permanently and cannot be un-published once mirrored. Cut a tag or a release
  for the *notes* if you want a record; never attach the artifact.
- **No notarisation in CI.** It would mean exporting the Developer ID `.p12`
  and an app-specific password into repo secrets. The keychain that holds them
  is on this Mac; the command runs here.
- **No test run.** The merge that put the commit on `main` already ran the full
  suite (Guard 4). Re-running proves the same thing and costs ~15 minutes.

---

## Owner's actions — credentials required

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
**Done — the key pair exists and 1.0.0 shipped against it. Never run bare
`generate_keys` again.** It would mint a new pair, and every copy already
installed verifies updates against the old public key baked into its
Info.plist; those copies could never be updated again. The public half is
`pTDAl+JJHH5ryMLZdPbUfSh0Ugq488O+Vjc1FURssQk=`.

The **private key stays in the login keychain** — it never leaves this Mac and
never enters the repo. The **public key** is a build input, `SPARKLE_ED_PUBLIC_KEY`,
which `make-app.sh` embeds as `SUPublicEDKey`. You do not normally pass it:
`make-staging.sh` derives it from the keychain with `generate_keys -p`, which
reads the existing pair rather than creating one.

### d. Paddle account + product setup

Done and live. **Paddle never holds the artifact** — it takes the money and
tells the license server to issue a key; the buyer downloads from
`/download?key=…`. So a release changes nothing on the Paddle side, and no
release step belongs there.

Paddle lives entirely in the license server (private repo
`aa-hh/audiout-license-server`). Neither this repo nor the app carries a Paddle
SDK.

### e. Per-release: publishing to R2

`scripts/release.sh` does all of this. Kept here because the rules still bite
anyone who reaches for `wrangler` by hand.

The download and the update feed are both served by the license server
(`~/Projects/Audiout License Server`, README there is the contract), gated on a
key — so publishing is an upload to its R2 bucket, not an edit to the website.
Three objects, with `N` the major version: `releases/Audiout-<version>.dmg`,
`releases/latest-vN.json` (`{"version": …, "file": "releases/…"}` — the pointer
`/download` reads, so writing it IS publishing), and `appcast-vN.xml`. Put the
artifact and the pointer before the appcast: if the appcast put fails, new
buyers still get a working download and nobody's installed copy is broken.

`--remote` and `-J eu` are both required on every put. Without `--remote`
wrangler writes to the local simulator and still prints "Upload complete", so
the release silently never leaves this Mac; the only tell is a
"Resource location: local" line. Both buckets live in the EU jurisdiction, and
without `-J eu` the bytes land in a bucket the Worker cannot read.

Do not try to confirm an upload with `wrangler r2 object get`. This Mac's
Cloudflare OAuth token has no `r2` scope and reports the permission failure as
"The specified key does not exist" — a successful upload reads back as a
missing one. `r2 bucket list` still works, which makes it more convincing.
Prove it through the Worker instead: `/download?key=…` with a real key.

### f. Choose the license server's public URL

`AUDIOUT_LICENSE_URL` (passed at build time, see above) has to be a real URL
that will keep serving `/v1/validate` and `/appcast.xml` for the life of every
copy of the app already installed — a one-time choice, not a per-release one,
because changing it later strands existing installs (they keep checking the OLD
URL forever unless a manual update ships a new one). Decide it before the first
public release, not after; it is the license server's `PUBLIC_BASE_URL`.
