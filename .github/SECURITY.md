# Security policy

## Supported versions

The current release is the supported one. Fixes ship in the next release rather
than as patches to older versions.

## Reporting a vulnerability

**Please don't open a public issue.** Email **support@audiout.app** with:

- what the flaw is and roughly how bad you think it is,
- the steps to reproduce it,
- the version and macOS version you saw it on.

You'll get an acknowledgement within a few days. If it's a real issue you'll be
credited in the release notes unless you'd rather not be.

## Worth knowing

Audiout captures system audio and talks to devices on your local network, so
there are two areas that matter most:

- **The audio tap** runs against a TCC-gated macOS API and needs a signed build
  and your explicit permission. Anything that gets audio out of it without that
  grant is a serious bug — report it.
- **The AirPlay sender** is vendored C derived from OwnTone, and parses network
  input from devices on your LAN. Memory-safety issues there are in scope.

The licence check is **not** a security boundary. It is a soft check, the source
is public, and removing it in your own build is explicitly permitted by the
licence — please don't file that as a vulnerability.
