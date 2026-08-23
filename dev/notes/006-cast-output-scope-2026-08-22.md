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
Audiout) is out of scope and not planned.

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

## Phasing (v1 = Phases 0–2, per decision 3)

- **Phase 0 — hardware spike (gates everything):** clean-room CASTV2 connect on
  real hardware: discover, TLS+auth-skip, launch Default Media Receiver, serve
  WAV and AAC live streams, measure BUFFERING→PLAYING latency + its variance
  + volume round-trip. Exit criterion: reproducible ≤2.5 s latency with a known
  recipe. (Blocked until Alec's Cast device arrives.)
- **Phase 1 — output plumbing:** Cast devices listed + selectable, stream +
  volume/mute; groups appear as single devices.
- **Phase 2 — sync integration (completes v1):** reference-timeline
  generalization, delay everything to the Cast leg, per-device trim + wizard
  reuse.
- **Phase 3 — post-v1 polish:** multizone member volumes, metering, per-app
  routing decision, TV wake/standby handling, latency-upgrade research
  (paths B/C).

## Decisions (Alec, 2026-08-22)

1. **Output only.** The Cast-receiver direction is out of scope, not planned.
2. **Hardware**: Alec doesn't own a Cast device yet, **will get one**. Phase 0
   stays blocked until it arrives; ideally one speaker + a second for a group.
3. **Sync ships in v1.** v1 = Phases 0–2 (spike, output, sync integration) —
   the Airfoil model: everything delayed ~2 s when a Cast device is in the mix,
   per-device trim on top.
4. **Protobuf framing: hand-rolled** (Claude's call — one 7-field message type;
   keeps the packages' zero-external-dependency policy; SwiftProtobuf remains
   the swap-in if the surface grows).
5. **All findable Cast devices supported**, TVs included — same protocol, no
   filtering. TV wrinkles (visible on-screen player, wake-from-standby delay)
   are polish items, not scope.

## Spike log

**2026-08-22 — software receivers on the test Mac (SUMUP-M9Y197RFVG).**
Phase-0 prep built (`CastSender` / `CastFakeReceiver` / `cast-spike`, see
`AudioutCore/Sources/CastSender/AGENTS.md`). Two Cast services were on the LAN:

- **"Mac Cast Receiver"** (`~/Projects/googlecast-receiver`, Python) — discovery-only
  stub by its own README; answers CONNECT/PING/GET_STATUS, never LAUNCH. Spike:
  TLS + status OK, launch timed out. Not a target.
- **"casty" = AirServer** (port 8010). `GET_APP_AVAILABILITY` over 18 known ids:
  only `0F5096E8` (Chrome Mirroring) and `674A0243` (Android Screen Mirroring)
  available; Default Media Receiver `CC1AD845` **unavailable** — matches AirServer's
  docs ("no content casting from apps"). So AirServer cannot measure path A.
  **New fact for path C:** a third-party sender CAN launch both mirroring apps;
  they report namespaces `media`, `remoting`, `webrtc`, `debug` and
  `senderConnected: true` after a virtual CONNECT. AirServer closed the virtual
  connection within ~1 s when no OFFER followed. WebRTC/Cast-Streaming negotiation
  itself untested (big clean-room spike; openscreen is the BSD reference).
- Sender side proven over a real network: TLS to another host, local IPv4
  detection, stream server bound on the LAN, volume status parsed
  (`stepInterval` 0.05, `controlType` attenuation observed).

**Path A numbers still need real Google hardware** (Nest Mini / Chromecast).

**2026-08-22 — REAL HARDWARE: Google TV Streamer (4K, 2024), 192.168.4.54, Ethernet.**
Bonjour note: its announcement reached the Mac only intermittently (wired device,
Mac on Wi-Fi, same router) — `cast-spike --host <ip>` added to bypass discovery;
also a 10 s connect timeout (an advertised-but-unreachable host hung forever).

Path A (Default Media Receiver + chunked live WAV 44.1/16/2, `streamType` LIVE):

| run | first audio after LOAD | stalls in first ~12 s | steady lead (sent − receiver currentTime) |
|---|---|---|---|
| prime 0 | 3.7 s | 3 | ~7.9 s |
| prime 1 s | 0.8–0.9 s | 3 (one ~5.8 s long) | 7.9 s, flat for 60 s |
| prime 2 / 3 / 4 s | ~0.7 s | 3 (long stall shrinks by the prime) | ~7.9 s |
| prime 8 s | 0.7 s | 1 (0.5 s) | 8.4–8.5 s |
| `streamType` BUFFERED / NONE, prime 1 s | 0.8–0.9 s | 3 | ~7.9 s (no change) |
| `--wav-lite` 8-bit mono 22.05 kHz (1/8 bytes), prime 1 s | 10.0 s | 3 | **13.6 s** |

Readings:
- Launch DMR ≈ 2.6–2.8 s every time. Volume round trip **17 ms** when the player is
  settled (the ~1 s readings coincide with a stall — control replies queue behind it).
  Pause 34–150 ms, resume 45–175 ms. Receiver reports `stepInterval` 0.05,
  `controlType` attenuation.
- **The receiver's player insists on ~8 s of buffered audio before steady playback**
  and builds that lead itself by stalling (~0.5 s at a time, one long one) while we
  keep streaming. Priming only moves the stalls earlier; the lead target is unchanged.
  Cast `streamType` is irrelevant. So naive path A = **~8 s latency**, matching the
  "8–30 s" reports, NOT Airfoil's 2 s.
- Lower byte rate made it worse (13.6 s) — so not a pure time target. First-play gate
  ≈ 250 KB in both formats; afterwards a download-rate-vs-playback-rate heuristic
  (Chromium progressive playback) decides when it dares to play through. For a live
  source the two rates are equal by definition, which is the pathological case.
- Lead drifts down slowly (7.88 → 7.53 over ~60 s in one run) — watch for sender timer
  slip vs receiver clock in a long soak; not yet characterised.
- Open: what AirConnect/Airfoil do differently (research in flight) — candidates:
  finite/fake `Content-Length`, different container (FLAC/MP3/AAC), faster-than-real-time
  delivery with a short declared duration, or a custom receiver.

**2026-08-22 — AirConnect-recipe and codec matrix on the Google TV Streamer** (Sonnet ran
the matrix; `cast-spike` gained `--no-autoplay`, `--app-id`, `--http10`, `--pipe <ffmpeg cmd>`,
`--content-type`, wall-clock pacing, lead logging; pink-noise source via ffmpeg so byte
rates are realistic — a sine compresses to nothing and skews byte-gated buffering).

Single-variable results (WAV unless noted, prime 1 s): receiver app id `46C1A819`
(AirConnect's) → 7.9 s, no change. HTTP/1.0 raw body → 7.9 s, no change. `streamType`
BUFFERED/NONE → no change. **`autoplay:false` + explicit PLAY → 5.5 s** (the only lever).

| codec (pink noise) | B/s | autoplay lead | no-autoplay lead |
|---|---:|---:|---:|
| WAV 44.1/16/2 | 176,400 | 7.45 s | **5.10 s** |
| FLAC | 110,111 | 9.01 s | 5.79 s |
| MP3 192k / 320k | 24,000 / 40,000 | 10.84 / 8.87 s | 5.43 / 5.70 s |
| AAC-ADTS 192k / 320k | 24,000 / 40,000 | 10.92 / 10.51 s | 5.66 / 5.92 s |
| Opus/Ogg 192k | 24,000 | 15.05 s | 8.88 s |

Every run stalls once ~0.5 s after first audio, then once more; lead is flat afterwards
(wall-clock pacing fixed the earlier sender slip). Receiver sends `Range: bytes=0-` for
every content type. Volume round trip 17 ms when settled.

**Conclusion for this device class:** no-autoplay lead is ~5–6 s for every codec = a
TIME target, consistent with Android media-player defaults (play after 2.5 s, resume
after a stall only with 5 s buffered). The Streamer is an Android TV box; Airfoil's 2 s
figure (2016) was measured on Chromium-era Chromecast/Chromecast Audio. Codec buys
nothing — WAV is the best and simplest. Stock Default Media Receiver floor here ≈ 5 s.
Open: 206/Content-Range reply to the Range request (AirConnect does this); custom
receiver with CAF `PlaybackConfig` buffer knobs (path B, needs Alec's Google account +
$5); a Nest speaker for comparison (likely the 2 s class).

**2026-08-22 — 206/Content-Range experiment: inconclusive, not pursued further.** Answering
the Streamer's `Range: bytes=0-` with `206 Partial Content` + `Content-Range: bytes 0-/*`
made it error within ~250ms every time (never buffered, never played) — control (plain 200)
played normally at the established ~5.5s. Confound: `bytes 0-/*` omits the required
last-byte-pos (RFC 7233); AirConnect sends a real end offset from its 2MB replay cache.
Could be "TV hates 206 for a live stream" or "TV hates a malformed Content-Range" — not
distinguished. Not chasing further: path B (custom receiver, Alec mid-registration
2026-08-22) is the more promising next step for going below the ~5s stock-receiver floor.

**2026-08-22 — Custom Web Receiver (path B), Google TV Streamer: NEGATIVE RESULT, closes
path B for this device class.** Registered a Cast developer account, a throwaway CAF v3
custom receiver (`playbackConfig.autoPauseDuration=0.5`, `autoResumeDuration=0.25`), and
the Streamer as a test device — hosted at
https://aa-hh.github.io/audiout-cast-receiver-spike/ (public repo aa-hh/audiout-cast-
receiver-spike; app id `F10823C5`, unpublished; delete/unpublish once this spike closes).
Setup traps hit along the way: registration needs BOTH the device's ~15min propagation +
reboot AND (found empirically) the app's own ~15min propagation, else `LAUNCH_ERROR
NOT_FOUND`; the device's *Cast* serial (get it by casting the Developer Console page to
the TV) is a different number from the hardware serial in Settings, using the wrong one
fails silently the same way. A real bug on our side masqueraded as a device problem: a
guessed `cast.framework.events.EventType.PLAYER_STATE_CHANGED` constant doesn't exist,
threw before `context.start()`, and produced `LAUNCH_ERROR CAST_INIT_TIMEOUT` — caught by
loading the page in a normal browser and reading the console (Chrome DevTools-style),
not obvious from the device-side error alone.

Once genuinely working: **autoplay → 7.9s lead, no-autoplay → 5.5s lead — both
statistically identical to the stock Default Media Receiver's numbers for the same
modes** (§ above: 7.45s / 5.10s). `playbackConfig`'s buffer knobs bought nothing.
Consistent with Google's own doc caveat that `autoPauseDuration` is "not supported by
Shaka Player" — our plain progressive `audio/wav` URL evidently rides the native
media-element path, not Shaka's segmented pipeline, so CAF's tuning surface doesn't
reach it. **Path B is closed for a plain-WAV live stream on Android-TV-class Cast
devices.** Untested and still open: whether MSE/a segmented container (fMP4, DASH) run
through Shaka would respond to these knobs — meaningfully more engineering for
uncertain payoff, not recommended before testing on a non-Android-TV device (Nest
speaker) first.

**Where this leaves the feature**: the ~5s floor via no-autoplay + explicit PLAY is
the best number found on this hardware, using nothing but the stock, zero-registration
Default Media Receiver. That's the v1 number for TV-class Cast devices unless a Nest
speaker (older/different playback stack, likely closer to Airfoil's Chromium-era 2s)
tests meaningfully better.
