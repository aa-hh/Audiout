# Companion — Remote Testing Without an AirPlay Device (and on public Wi-Fi)

*For an ~8-hour remote session with two Macs + an iPhone, on public Wi-Fi, and no
AirPlay speaker. The short version: you never needed a speaker — the Mac's mock backend
is a full fake fleet — but public Wi-Fi will fight the LAN discovery, so make your own
private network.*

## The one thing that will bite you: public Wi-Fi

The companion app finds the Mac via Bonjour/mDNS on the **same LAN** (the Sonos model).
Public networks (hotels, cafes, airports) routinely:
- enable **client isolation** — devices on the network literally cannot reach each other;
- **block multicast/mDNS**, so Bonjour discovery finds nothing.

Result: discovery hangs at "Looking for a Mac…" and it *looks* like our bug. It isn't.
**Do not judge the app on public Wi-Fi.** Make a private link instead:

### Recommended: macOS Internet Sharing (a private LAN you control)

On the Mac that will run the companion Mac app:
1. System Settings → General → Sharing → **Internet Sharing**.
2. Share from your active connection (public Wi-Fi, or Ethernet), **to Wi-Fi**.
3. Set a network name + WPA2 password (Wi-Fi Options…).
4. Turn Internet Sharing **on**.
5. Join that new Wi-Fi network from your **iPhone** (and the second Mac if used).

Now the Mac + iPhone are on a private subnet with no isolation and working mDNS. This is
independent of whatever the venue's Wi-Fi does.

*Avoid iPhone Personal Hotspot for this* — mDNS over Personal Hotspot is historically
flaky/restricted on iOS and will give you false failures. Mac Internet Sharing is the
reliable one.

## Getting the app onto the phone (network-independent)

TestFlight is a download from Apple — it works over **any** internet, public Wi-Fi fine.
Two paths:
- **TestFlight** (preferred remote): a signed build is delivered to your iPhone; install
  the TestFlight app, accept the invite, download. Lasts 90 days. Setup is the
  App-Store-prep task; it needs a pushed branch (done) and one go-ahead to create the
  App Store Connect record.
- **Xcode direct-install**: only if a Mac with the repo + Xcode is cabled to the phone;
  free Apple ID works, 7-day expiry.

## Running the Mac side without a speaker

Always launch the Mac app with the mock backend — a deterministic fake fleet (This Mac +
HomePod + a Sonos pair + one offline device), no AirPlay hardware touched:
```bash
AIRPLAY_BACKEND=mock AUDIOUTER_COMPANION=1 open build/Audiouter.app
```
`AUDIOUTER_COMPANION=1` forces the companion server on regardless of the checkbox. The
phone then discovers "…'s MacBook Pro", you approve it once, and drive everything:
select speakers, volumes, mutes, groups, per-app routing, the two remote settings. The
only thing you can't see is audio physically leaving a speaker — which the phone app
never controls anyway.

You'll need the built `Audiouter.app` on whichever Mac acts as the server. If that Mac
isn't this dev machine, copy over the Developer-ID-signed build (or I can hand you one).

## Fidelity ladder — what proves what, with zero AirPlay hardware

| Level | Setup | Exercises | Confidence |
|---|---|---|---|
| 1. Automated | this dev Mac | unit + protocol + iOS + UI-smoke suites, Python protocol poke, loopback end-to-end | Logic + wire format, fully deterministic |
| 2. Simulator + mock Mac | this dev Mac | real WebSocket/Bonjour on localhost: discovery, approval, live two-way sync, every command | The whole protocol, repeatable, no real network |
| 3. Real iPhone + mock Mac over Mac-shared Wi-Fi | your remote Macs + phone | genuine two-device: real Bonjour across devices, the **iOS Local-Network permission prompt** (only appears on a real device), backgrounding, Wi-Fi transitions | Everything except audio-to-a-speaker |

Level 3 is the one that adds what a simulator can't: the real iOS permission prompt, real
cross-device Bonjour, real backgrounding. That's why the private-LAN setup is worth the
five minutes.

## What genuinely still needs a real AirPlay speaker (deferred, do not fake)

- Audio actually playing on a physical speaker.
- Real AirPlay device quirks (a real HomePod/Sonos reporting its own volume back via DACP
  — note the DACP `NoAuth` fix from the live gate wants a real speaker to confirm end to
  end).
- Multi-speaker sync timing.

These wait until you're back with hardware. The two-device live checklist
(`companion-live-test-checklist.md`) covers them; everything above it can be signed off
remotely.
