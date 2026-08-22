# Google Cast output support — scoping brief (roadmap 006)

Date: 2026-08-22. Sources: five parallel research sweeps (codebase seams, CASTV2
protocol, live-audio delivery + OSS licenses, competitors/sync, legal/ToS).
Point-in-time web findings; re-verify specific claims before building against them.

## Verdict

**Feasible, legally clean, and it fits the app's existing fixed-delay (Bluetooth)
sync model — but it is the single largest feature on the roadmap.** Cast is a
second full sender protocol with a *pull* streaming model (the speaker fetches an
HTTP stream from us) instead of AirPlay's push model. The realistic latency floor
with the stock receiver is **~1–2 s** (Airfoil ships exactly 2 s), which the
delay-to-worst sync model absorbs the same way Bluetooth's 500 ms does — but it
makes Cast the *latest* output, which inverts the reference-timeline logic.

Three cost centers, in order:
1. **An outbound media-server leg that doesn't exist**: local HTTP server +
   live audio encoder (nothing in the repo streams audio out to a pulling client).
2. **Generalizing two-transport hard-coding**: fan-out slots, output-set
   partitioning, trim store/UI, reference timeline, popover sections are all
   pairwise (AirPlay + BT) today — §Codebase below.
3. **Ongoing maintenance**: reverse-engineered protocol; Google historically
   breaks things technically (not legally); OSS ecosystem patches within
   weeks-to-months.

## Direction check — SETTLED (Alec, 2026-08-22)

Roadmap 006's text mentioned two directions; Alec confirmed **output only**
(casting TO Cast devices). The receiver direction (other apps casting into
Audiouter) is out of scope and not planned.

## The protocol (all confirmed, no blockers)

- Discovery: plain Bonjour `_googlecast._tcp` browse. Device model comes from
  the `md` TXT field (free-text: "Chromecast", "Nest Audio", …); friendly name
  in `fn`. Speaker groups advertise as their own virtual device.
- Control: TLS to port 8009 (self-signed certs — `Network.framework` custom
  trust verify block handles this), 4-byte-length-prefixed protobuf
  `CastMessage` frames carrying JSON payloads. Namespaces: connection,
  heartbeat (~5–10 s ping), receiver (launch/stop/volume), media
  (LOAD/PLAY/PAUSE/status), multizone (groups).
- **No Google credential needed.** Device auth runs receiver→sender only (the
  speaker proves it's genuine; checking is optional). Unofficial senders are
  fully functional with zero registration.
- Volume: `SET_VOLUME` level 0.0–1.0 + mute, per device; the official SDK also
  exposes per-member volume inside a group (multizone). Round-trip speed is
  undocumented — measure in the spike.
- Playback: LAUNCH the Default Media Receiver (well-known app id `CC1AD845`,
  no registration), then LOAD a URL we serve locally with
  `streamType: LIVE`.
- Codecs the receiver plays: WAV/LPCM, FLAC, AAC, MP3, Opus, Vorbis. Google's
  own docs conflict on the audio ceiling (96 kHz/24-bit FLAC on one page,
  48 kHz/16-bit implied for audio devices on another) — irrelevant for us, we
  send 44.1/16/2 (the engine's `PCMFormat.airplay`).

## Delivery paths (the real decision)

| Path | Latency | Cost | Risk |
|---|---|---|---|
| **A. Default Media Receiver + local HTTP stream** | ~1–2 s achievable (AirConnect, MIT-licensed C bridge, ships ~2 s; Airfoil ships 2 s). Naive implementations get 8–30 s — delivery details are the whole game. | Local `NWListener` HTTP server + live encoder. | None registered with Google; nothing to revoke. |
| **B. Custom Web Receiver** | Potentially sub-second (CAF buffer knobs, or raw MSE/WebSocket pipeline). | $5 registration + Google Cast Developer Console; receiver is a hosted web app we must serve/maintain. | Google can de-register the app id at sole discretion, breaking all users at once; binds us to Play content policies. No shipped OSS precedent for the MSE-audio hack. |
| **C. Cast mirroring (WebRTC/Opus)** | Lowest in principle (Chrome tab-cast path). | Chromium `openscreen` lib is BSD but drags in GN/Ninja/depot_tools; alternatively clean-room the WebRTC namespace. | **Unproven for third-party senders** — no source confirms a non-Chrome sender can launch the mirroring receiver (`0F5096E8`). Research spike only. |

**Recommendation: A.** It's what Airfoil ships, the 2 s it costs is exactly what
the delay-to-worst model handles, and it carries zero Google-relationship risk.
B/C are latency upgrades to investigate later, not v1.

Encoder for path A, using only Apple frameworks (no ffmpeg): **AAC (ADTS over
chunked HTTP)** or **WAV/LPCM** (dumbest, ~1.4 Mbps, LAN-fine) — both native via
AudioToolbox. FLAC encode also native. MP3 encode: not available (needs LAME —
skip). Opus encode: probably not native (would need libopus, BSD — skip for v1).
Spike should measure WAV vs AAC receiver-side buffering; AirConnect's buffering
notes suggest the receiver's BUFFERING→PLAYING flip is what dominates, not codec.

## Sync model

- Airfoil precedent: treat Cast as a **fixed ~2 s delay** and delay every other
  output to match (their KB: local ≈0, AirPlay 2 s, Cast 2 s, BT ≤2 s; per-device
  trim ±1.00 s for Cast/AirPlay). Once playing, Cast latency is front-loaded
  buffer, not drift — same failure shape as our BT model (re-buffer risk, not
  clock drift), so the fixed-delay + per-device trim approach holds.
- **Structural consequence in our code**: `SyncTiming.totalDelayNanos` clamps at
  ≥0 — an output can only be delayed, never pulled earlier. Today AirPlay is
  always the latest output (start buffer up to 5 s, default 1 s effective
  ~750 ms) and BT/local are delayed to meet it. A 2 s Cast leg becomes the new
  latest output, which means **AirPlay itself must be delayed** — either by
  raising `startBufferMs` (clamped 300–5000 ms, applied only at `start()`, so a
  mid-session change is a 3–5 s audible teardown) or by accepting Cast running
  ~1 s late in mixed groups (Airfoil's imperfect-mixed-sync reports suggest they
  partially accept this). This is the hardest design problem in the feature.
- Cast **groups**: the group is one virtual device; Google handles intra-group
  sync (~50–200 ms member precision). Treat a group as a single output; expose
  member volumes later via multizone if wanted.
- No usable sender-visible clock API — latency must be measured/assumed, exactly
  like BT. The existing alignment-wizard bisection (`BTAlignmentBisection` is
  pure/transport-free) reuses directly for a Cast trim wizard.

## Legal / ecosystem (clean, risks are technical)

- Cast SDK ToS binds **SDK users only**; a clean-room protocol implementation
  never accepts it. Airfoil, VLC, AirParrot, JustStream, pychromecast have
  shipped unofficial senders for ~a decade with zero known legal action.
- `cast_channel.proto` and Chromium's `openscreen` are **BSD-3** — fine to
  vendor in a proprietary binary (keep notices). SwiftProtobuf is Apache-2.0.
  **Never copy code from**: stream2chromecast (GPL-3), browser-castv2-client
  (GPL-2), VLC's module (LGPL — reference-only). Safe references: AirConnect
  (MIT), pychromecast (MIT), node-castv2 (MIT), rust-cast (MIT), go-chromecast
  (Apache-2), OpenCastSwift (MIT, unmaintained), ChromeCastCore (BSD-2, archived).
- Unlike the AirPlay sender, **no GPL source is needed anywhere** — the Cast leg
  can be a license-clean in-app module (follow the `SyncCore.swift`
  LICENSE-CLEAN banner precedent), no separate package required for licensing
  (a separate target may still be nice for hygiene).
- Marketing: no Cast badge without SDK registration; plain nominative wording
  only ("works with Chromecast and Google Cast-compatible speakers", plus
  "Google Cast is a trademark of Google LLC").
- Real risks: Google broke a third-party sender via firmware once (AllCast,
  2013); routine protocol drift (pychromecast patches within weeks); the
  March 2025 cert expiry bricked device-auth ecosystem-wide for weeks. Budget
  for ongoing chase, and make Cast degrade gracefully (never take the AirPlay
  path down with it).

## Codebase integration (from the seam map)

The Bluetooth integration is the paint-by-numbers template. Cast = a third
transport **inside `NativeBackend`** (BT precedent — NOT a new `BackendKind`):

Direct-reuse seams: `Device.Kind` new case; Bonjour browse (add
`_googlecast._tcp` to `NSBonjourServices` in `make-app.sh` — silently blocked
otherwise); snapshot-ingest shaped like `applyBTSnapshots`; a third
`setOutputSet` partition arm; a fourth capture fan-out slot shaped like
`setBTSink` (with the render/server pid excluded from the tap — echo rule);
composed gain Main × Group × Device; `SyncCore` timing math; capture gate and
retry/failure plumbing; popover section.

Things that need **new abstraction** (the hidden half of the estimate):
1. Reference-timeline model is binary (AirPlay-present or not) — a Cast leg
   that's *later* than AirPlay has no expression today.
2. Fan-out (`BufferSnapshot`, `CaptureControlling`) and output-set partitioning
   are hard-coded pairwise; third arm is either more copy-paste in an
   8,400-line file or a small generalization pass first.
3. Trim store/UI, alignment-wizard hosting, "is it audible" predicate,
   connection manager, failure causes are all BT-named/typed; Cast needs
   generalized or parallel versions (and `ConnectionFailure.Cause` needs
   Cast-shaped cases: receiver busy, app unavailable, TLS/cert failure).
4. Nothing streams audio out over HTTP; no protobuf, no TLS-client code, and
   both packages currently have **zero external dependencies** — adding
   SwiftProtobuf is a policy decision (alternative: hand-roll the ~6-field
   CastMessage framing; it's small enough that this is genuinely viable).
5. Metering for non-engine transports is already an open defect (roadmap 038,
   BT); Cast inherits it.
6. Per-app routing: recommend excluding Cast devices in v1 like AP1/BT
   (the exclusion pattern exists; a Cast device would need its own HTTP stream
   per app-mix otherwise).

## Suggested phasing

- **Phase 0 — hardware spike (gates everything):** clean-room CASTV2 connect on
  real hardware: discover, TLS+auth-skip, launch Default Media Receiver, serve
  WAV and AAC live streams, measure BUFFERING→PLAYING latency + its variance
  + volume round-trip. Exit criterion: reproducible ≤2.5 s latency with a known
  recipe. (Requires owning a Cast device — see open questions.)
- **Phase 1 — unmixed output:** Cast devices listed + selectable, stream +
  volume/mute, no sync promise with other transports (Cast-only selections, or
  visibly-late in mixed). Groups appear as single devices.
- **Phase 2 — sync integration:** reference-timeline generalization, delay
  everything to the Cast leg, per-device trim + wizard reuse.
- **Phase 3 — polish:** multizone member volumes, metering, per-app routing
  decision, latency-upgrade research (paths B/C).

## Open questions for Alec

1. ~~Output only, or also the receiver direction?~~ **Answered: output only.**
2. **Do you own Cast hardware to test on?** (Chromecast Audio is discontinued;
   current targets are Nest Audio/Mini, Cast-enabled TVs/soundbars.) Phase 0 is
   blocked without at least one real device — ideally one speaker + one group.
3. **Sync promise for v1**: Airfoil-style "everything delayed ~2 s when a Cast
   device is in the mix", or Phase-1-style "Cast works, mixed sync comes later"?
4. **Dependency policy**: is SwiftProtobuf (Apache-2.0, Apple-maintained)
   acceptable as the packages' first external dependency, or hand-roll framing?
5. **TVs in scope?** Audio-only devices are the clean case; Cast TVs add
   wake/CEC/standby weirdness and a visible on-screen player for marginal value.
