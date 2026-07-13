# Dummy setup for offline development

You don't need any AirPlay speakers to build and test most of this app. There are
two layers of "dummy," solving two different problems.

| Layer | Lives in | Exercises | Does **not** exercise |
|---|---|---|---|
| **In-app mock backend** | `../AirPlayControllerCore` | All UI + control logic: discovery, multiple devices, groups/output-sets, per-device volume/mute/solo, level meters, drop/reconnect | The wire/audio path (by design) |
| **shairport-sync fake speaker** | `fake-speakers.sh` | Real Bonjour discovery + AirPlay-1 send against a real receiver | AirPlay-2 **PTP sync**, Sonos quirks (need real hardware) |

**The mock backend is the primary tool.** The shairport receiver is an optional
sanity check for the real wire path — and on a single Mac it's limited to *one*
device (see below).

---

## Layer 1 — In-app mock backend (start here)

A `MockBackend` that fabricates a believable fleet (2× Sonos, an AirPort Express
that's AirPlay-1-only, an Apple TV, a HomePod, a generic speaker) and behaves the
way the real backend will: devices trickle in over ~2s, controls echo back as
events, and — optionally — devices drop off and reconnect.

The app links `AirPlayControllerCore` and talks only to the `OutputBackend`
protocol, so switching mock ↔ real is one line (`makeBackend(.mock)` /
`makeBackend(.ownTone)`).

```bash
cd ../AirPlayControllerCore
swift test            # 5 tests covering discovery, clamping, output-set, no-op
swift run mock-speakers-demo   # watch the backend behave, headless
```

`mock-speakers-demo` prints discovery + control echoes so you can see it work
before any UI exists. To develop the UI against fabricated devices, point the app
at `makeBackend(.mock)`. Options on `MockBackend.init`:
`staggerDiscovery`, `emitsLevels`, `simulatesDropouts`.

---

## Layer 2 — shairport-sync fake speaker (optional, one device)

A real AirPlay-1 receiver on this Mac, advertised over Bonjour, for occasionally
checking that real `NWBrowser` discovery and the AirPlay-1 send path work.

```bash
brew install shairport-sync   # already installed
./fake-speakers.sh            # launches one "Dev Speaker"
dns-sd -B _raop._tcp          # confirm it advertises
./stop-fake-speakers.sh
```

### The two single-machine limitations (both verified 2026-07-13)

1. **Only one instance.** The Homebrew shairport-sync 5.1 build is AirPlay-1 only
   and **ignores the RTSP port setting** (CLI `-p` *and* config `port`) in Classic
   AirPlay mode — every instance binds `:5000`, so a second one dies with
   "Address already in use." Multi-room / groups / sync testing therefore comes
   from the mock backend, not from multiple shairport instances.

2. **macOS holds `:5000`.** Your Mac's own AirPlay Receiver (`ControlCenter`) is
   already listening on 5000. Free it first, or even the single instance won't
   start:

   > System Settings ▸ General ▸ AirDrop & Handoff ▸ **AirPlay Receiver → Off**

   `fake-speakers.sh` runs a health check and tells you if the instance died on
   this collision.

### Why not run a real AirPlay-2 receiver locally?

That would need a source build of shairport-sync with `--with-airplay-2` + `nqptp`,
which binds the privileged PTP ports **319/320** — the exact ports the OwnTone
*sender* also needs. On one machine they fight. True AirPlay-2 PTP sync is the one
thing that genuinely needs your real Sonos + AirPort Express (or a second host);
nothing offline can stand in for it, so the mock backend covers it at the UI layer
instead.

---

## Files

- `fake-speakers.sh` — launch the shairport receiver(s). `SILENT=0` to hear audio.
- `stop-fake-speakers.sh` — stop them.
- `.run/` — generated pidfiles, per-instance configs, and logs (safe to delete).
