# Security policy

## Supported versions

The current release is the supported one. Releases are notarized builds that
ship through the app's own updater and the download link on audiout.app, not
through this repository's Releases page. A licence key is tied to a major
version, so "current" means the newest release of the major your key covers.
Fixes ship in the next release of that major rather than as patches to older
builds.

Audiout runs on Apple Silicon Macs on macOS 14.4 or later. Anything older is
not a supported configuration.

## Reporting a vulnerability

**Please don't open a public issue.** Email **support@audiout.app** with:

- what the flaw is and roughly how bad you think it is,
- the steps to reproduce it,
- the Audiout version, build number and macOS version you saw it on.

You'll get an acknowledgement within a few days. If it's a real issue you'll be
credited in the release notes unless you'd rather not be.

One address for the whole product: the same email covers the licence server,
the website, the iPhone companion and the `audiout-shared` package.

## Worth knowing

Audiout captures system audio, runs one privileged helper, updates itself and
listens on your local network. These are the areas that matter most:

- **The PTP helper is the only process that runs as root.** It is a small
  launchd daemon registered through `SMAppService`
  (`AirPlayEngine/Sources/ptp-helper/main.c`, `scripts/ptp-helper.plist`) whose
  only privileged job is binding the PTP ports. Anything that gains privilege
  through it, or through the way it is registered, is the most serious class of
  bug we know of. The rules it is built to are in
  [`docs/SPEC.md`](../docs/SPEC.md#security--trust-principles-added-2026-07-09-after-phase-0-findings).
- **The audio tap** runs against a TCC-gated macOS API and needs a signed build
  and your explicit permission. Anything that gets audio out of it without that
  grant is a serious bug — report it.
- **Updates** come through Sparkle: an EdDSA-signed appcast fetched over HTTPS,
  and the request carries your licence key as a bearer token. A signature
  bypass, a way to make the app accept an older or different feed, or a way to
  leak the key from that path is in scope.
- **The AirPlay sender** is vendored C derived from OwnTone, and parses network
  input from devices on your LAN. Memory-safety issues there are in scope.
- **The iPhone companion server** is a plain, unencrypted WebSocket on the
  local network, on by default, advertised over Bonjour. A phone gets in only
  after you click Allow for it once; that decision is remembered against an ID
  the phone chooses for itself
  (`AudioutCore/Sources/AudioutCore/CompanionServer.swift`,
  `CompanionApprovalStore.swift`, `CompanionCommandRateLimiter.swift`). The
  plaintext transport is a documented design choice — see
  [`PRODUCT.md`](../PRODUCT.md#data-collection). What is in scope: bypassing
  the approval prompt, impersonating an approved phone in a way the design does
  not already concede, getting the Mac to act on frames from a client it never
  approved, and anything reachable before a connection has completed `hello`.
- **The DACP server** (`AudioutCore/Sources/AudioutCore/DACPServer.swift`) is
  a second listening socket: a tiny HTTP endpoint speakers call to report volume
  changes. Same rules as the sender — it parses LAN input.

## Not in scope

- **The licence check.** It is a soft check, the source is public, and removing
  it in your own build is explicitly permitted by the licence — please don't
  file that as a vulnerability.
- **Reading companion traffic off the LAN.** The link is unencrypted by design
  and `PRODUCT.md` says so; that is a product decision, not a flaw to report.
- **Telemetry.** It is opt-in and off by default, and what it can and cannot
  contain is spelled out under
  [Data Collection](../PRODUCT.md#data-collection).
- **Issues that only exist in unsigned or self-built binaries.** The tap, the
  helper and the updater all depend on the signed release build; a bug you can
  only reach by building without a signature isn't one users are exposed to.
- **The `disable-library-validation` entitlement** in
  `scripts/Audiout.entitlements` is deliberate — it is what lets the bundled
  dylibs load — not a misconfiguration.
