# Cast: how it is sent, how it is timed, where sync breaks, and how to make it first-class

Researcher: cast. Written 2026-09-26 against `/home/claude/Audiout` at `add4251` (main),
read-only. `path:line` is relative to `AudioutCore/Sources/` unless it starts with
`dev/`, `docs/` or `/mnt/`. "Inferred" marks anything I reasoned from code or sources
but did not see measured. Builds on, and does not repeat:

- `dev/notes/006-cast-output-scope-2026-08-22.md` (scope + hardware spike log, "scope brief")
- `dev/notes/006-cast-sync-architecture-2026-08-22.md` (N-way room delay design, "sync brief")
- `dev/notes/006-cast-live-diagnosis-2026-08-22.md`, `006-cast-live-fix-handoff-2026-08-22.md`,
  `006-cast-live-telemetry-2026-08-22.jsonl` (first live test)
- `/mnt/project-files/sync-architecture/sync-clock-architecture.md` ("SCA"): §2 Cast column,
  §3.1, §5.1 Cast row, Gap 1. SCA already states the Cast term in `R` (~5.5 s self-reported
  lead, settle gate, 150 ms skip/insert, AirPlay pre-delay through `PCMDelayLine`). This
  file goes below that: the protocol's real timing controls, the receiver's buffering,
  whether 5.5 s can be cut, and whether it can be observed precisely.

---

## 0. The answer in brief

1. **Today's Cast leg is an open-loop HTTP pull.** The receiver fetches an endless chunked
   WAV (44.1 kHz/16/2, 176,400 B/s) from a server on the Mac, paced by the Mac's wall clock,
   and plays it through the stock Default Media Receiver (`CC1AD845`) with its own buffer
   policy. The sender has no way to say *when* a sample should sound. All it can do is
   measure how deep the receiver's buffer is (`secondsSent − currentTime`) and delay
   everything else to match.
2. **The ~5.5 s cannot be cut on this path.** It is the receiver player's buffer *target*,
   not a network or codec cost. Priming, codec, `streamType`, a custom CAF receiver with
   buffer knobs, and HTTP variants all left it at 5.1–5.9 s. Only `autoplay:false` moved it
   (7.9 → 5.5 s). Section 1.3 has the evidence.
3. **The lead is observable to about ±10 ms, but it is the wrong quantity.** It measures the
   receiver's buffer depth only. It misses the Mac-side hand-off ring (~500 ms by
   construction), any change in that ring (capture clock vs Mac clock, pauses) and the
   receiver's output stage. **I believe the code therefore plays a Cast speaker about
   500 ms later than the room today**, and no negative trim can reach it. This is inferred
   from code (§2.1) and needs one mic measurement to confirm. It is the most important
   concrete finding in this file.
4. **Cast has no acoustic loop at all.** It is excluded from mic calibration and from
   passive-drift baselines. Its only correction for the output stage is a by-ear ±1000 ms
   offset.
5. **A first-class synced Cast exists in the protocol, just not on the path Audiout uses.**
   Cast Streaming (the mirroring apps `85CDB22F` / `0F5096E8`, RTP + RTCP, Opus) schedules
   every frame at *sender capture time + target playout delay*. The receiver maps the
   sender's clock through RTCP Sender Reports with a 30 s IIR drift smoother. Default delay
   is 400 ms, and the sender can change it mid-stream. That is an AirPlay-like
   presentation timeline. It would make Cast *not* the slowest output (400 ms < S = 1000 ms),
   remove the whole-house silence on join, and remove the drift loop. OwnTone ships
   exactly this path for Google Home devices, synced to AirPlay by open-loop scheduling
   plus a 100 ms fudge. The scope brief called it "path C, unproven for third-party
   senders", and the owner's own spike already showed a third-party sender can launch
   those apps. This is the single most important missing piece.

---

## 1. Key findings with evidence

### 1.1 How Cast audio is sent today

| Step | Evidence | What happens |
|---|---|---|
| Discovery | `CastSender/CastBrowser.swift:32`; `NativeBackend+Cast.swift:23-53` | `_googlecast._tcp` Bonjour. Groups appear as one virtual device (scope brief). Rows are debounced by a 3 s absence grace. |
| Control | `CastSender/CastChannel.swift`, `CastClient.swift` | TLS to :8009, hand-rolled CASTV2 protobuf, clean-room (no GPL). |
| Recipe | `CastOutputManager.swift:431-440, 700-810` | connect → `GET_STATUS` → start server → LAUNCH `CC1AD845` → LOAD `audio/wav`, `streamType: LIVE`, **`autoplay: false`** (`:794`) → explicit PLAY. Play deadline 20 s (`:446`). |
| Capture fan-out | `AudioutCore/NativeCaptureCoordinator.swift:2005-2014` | The fourth consumer of the converted S16LE 44.1 kHz block. **`pts` is passed but ignored** (`CastOutputManager.swift:409`). |
| Hand-off ring | `CastFeedRing`, `CastOutputManager.swift:118-406` | 2 s ring (`:145`). The IOProc pushes with a bounded `try()` retry (`:201-216`), and underruns are zero-filled on render (`:305-330`). The optional per-leg `PCMDelayLine` (10 s capacity) sits *before* the ring (`:229`). Fixed-volume receivers get feed gain with a 20 ms ramp. |
| HTTP server | `CastSender/CastLiveAudioServer.swift` | `200 OK`, `Transfer-Encoding: chunked`, `Accept-Ranges: none`, WAV header with 0xFFFFFFFF sizes (`:301-313, 392-419`). On GET: **reset the ring to the live edge** (`CastOutputManager.swift:713-716, 394-406`), send a **1000 ms prime** (`:450`, `CastLiveAudioServer.swift:315-319`) rendered from the just-emptied ring (= silence), then **wait for a 500 ms cushion** (`:331-337, 352-361`), then send 882-frame chunks every 20 ms **paced by `DispatchTime` (mach) elapsed time** (`:339-372`). Only the receiver's IP is served; max 32 connections; 30 s idle deadline (`:229-264`, PR #217 2026-09-20). |
| Lead poll | `CastOutputManager.swift:862-940` | `GET_STATUS` 1 Hz once PLAYING. `lead = secondsSent − currentTime`, kept if RTT < 100 ms (`:884`). The kept sample goes to `CastRoomDelay`. |
| Room policy | `AudioutCore/CastRoomDelay.swift` | Default 5500 ms until measured. Settles on 10 samples within ±100 ms, then takes the median. The term only rises while the receiver stays selected. A 150 ms correction threshold. Refused above 9500 ms. |
| Application | `NativeBackend+Tone.swift:886-1006`; `NativeBackend.swift:3815-3834` | `R = max(today, castTerm)`. AirPlay is pre-delayed by `R − S`. BT and Mac re-anchor. Each Cast feed gets `room − settledLead` (`:928-950`), plus the user offset clamped at ≥ 0 (`CastOutputManager.swift:627-636`). |
| Trim | `NativeBackend+Cast.swift:93-166`; `BTTrimStore.swift:43` | By-ear only, ±1000 ms, persisted per receiver id. |

The encoding is WAV/LPCM, with no encoder. Buffering is the 2 s ring on the Mac, a ~500 ms
standing cushion and a 1 s silent prime. On the receiver, the player's own ~5 s target
applies (§1.3).

### 1.2 What timing control exists

Everything the sender can *act on* is on the Mac side of the socket:

- **Lengthen only.** Zeros inserted ahead of the ring (`PCMDelayLine`) delay content
  without starving the receiver. A shorter delay would need audio that has not been captured
  yet (`CastOutputManager.swift:43-51, 623-636`).
- **Volume.** `SET_VOLUME` round trip is 17 ms settled and ~1 s mid-stall. For `fixed`
  receivers the volume is applied as feed gain, so it lands `lead` seconds later
  (`onVolumeLagChange`).
- **No start-time, no presentation timestamp, no rate control** is used. Nothing in the
  Default Media Receiver's media namespace accepts one. MEDIA_STATUS carries `currentTime`,
  `playbackRate` and `playerState`, and **no timestamp of when `currentTime` was sampled**
  ([Cast media messages](https://developers.google.com/cast/docs/media/messages)). Google's
  own sender SDK deprecates `currentTime` for `getEstimatedTime()`, which extrapolates from
  the last status using the local receipt time
  ([chrome.cast.media.Media](https://developers.google.com/cast/docs/reference/web_sender/chrome.cast.media.Media)),
  and pychromecast does the same (`adjusted_current_time = current_time + playback_rate ×
  (now − last_updated)`, pychromecast `controllers/media.py:145-160`). CAF also defines a
  `SET_PLAYBACK_RATE` request
  ([SetPlaybackRateRequestData](https://developers.google.com/cast/docs/reference/web_receiver/cast.framework.messages.SetPlaybackRateRequestData)).
  It is meant for 0.5–2× user speed. Whether a stock receiver honours 1.00005 is
  unknown; I found no evidence either way.

### 1.3 Receiver buffering: the numbers, and why 5.5 s is a floor on this path

Measured on the owner's Google TV Streamer (Android TV, Ethernet), scope brief spike log:

| Recipe | Lead (sent − currentTime) |
|---|---|
| autoplay, WAV, prime 0–4 s | 7.45–7.9 s |
| autoplay, prime 8 s | 8.4–8.5 s |
| **no-autoplay + PLAY, WAV (shipping)** | **5.10 s** (live app: 5.47 s steady, telemetry below) |
| no-autoplay FLAC / MP3 / AAC | 5.4–5.9 s |
| no-autoplay Opus/Ogg | 8.88 s |
| 8-bit mono 22 kHz (1/8 bytes) | 13.6 s |
| custom CAF receiver, `autoPauseDuration 0.5`, `autoResumeDuration 0.25` | 7.9 / 5.5 s, the same as stock (path B closed for progressive WAV) |
| 206 / `Content-Range: bytes 0-/*` | error in 250 ms (malformed header, confounded) |

Other readings: launch 2.6–2.8 s. The first GET has been seen up to 12 s after PLAY. There
are 2–3 stalls in the first ~12 s, and the lead is flat after that. The live 2026-08-22
telemetry (`dev/notes/006-cast-live-telemetry-2026-08-22.jsonl`) shows the steady lead at
5.46–5.48 s in 1 s polls for 16 s, with two outliers of 5.55 and 5.57 s. Both outliers
arrived 80–100 ms off the 1 s grid, which is consistent with a late reply inflating the
lead (§1.5).

Interpretation (inferred, consistent with every row). The Android TV player starts at
~2.5 s buffered and, after any stall, resumes only with ~5 s. These are the classic
ExoPlayer `DefaultLoadControl` defaults `bufferForPlaybackMs = 2500` and
`bufferForPlaybackAfterRebufferMs = 5000`. A live source paced at exactly 1× can never
refill faster than it plays, so the buffer sits wherever the last rebuffer left it.
Priming pushes it higher but never lower. That makes ~5 s a **floor set by the player's
rebuffer rule**, not a transport cost. The same 1× trap is described generically by
AirConnect's author: an HTTP player "expects to receive an initial large portion of audio
as the response to its GET", which a real-time bridge cannot provide, and clock differences
then add delay over time
([AirConnect README](https://github.com/philippe44/AirConnect/blob/master/README.md),
"Latency parameters explained"). Other senders report the same class of number:
mkchromecast "up to 8 seconds", BubbleUPnP "5–8 s" (competitor-parity note). Airfoil's
stated 2 s dates from Chromium-era Chromecast Audio.

**Not measured:** any Nest speaker, Chromecast Audio, or GC4A third-party speaker. The
scope brief expects the Chromium-era devices to be "the 2 s class". That is plausible but
untested; it is the first open question in §4.

### 1.4 Google's own sync, for comparison

- **Multizone groups: leader and followers with their own clock sync.** Google's patent
  US11871067B2 (filed 2022-08-19) describes the scheme. A leader chosen by network quality
  receives the stream and redistributes it. Followers run a UDP request/response clock
  sync, `offset = ((now − t2) − (t2 − t1))/2`, with an error of RTT/2 per sample, a
  weighted moving average, and linear regression for drift over ~5–10 min windows. Buffers
  play "at the time indicated by the audio buffer's timestamp". A typical 500 ms playback
  delay is used, up to 5 s buffered, and initial sends are rate-limited to 1.5× real time
  ([patent](https://patents.google.com/patent/US11871067)). Scope note (inferred): this is
  internal between Google receivers. A third-party sender casting to a group URL just feeds
  the leader's HTTP fetch.
- **Group delay correction** is a per-device manual slider in the Home app (±200 ms per priorart.md, which also records a Nest Mini paired to BT playing ~500 ms early that the slider could not fix). Google's guide
  lists typical device residues of speakers 0–40 ms, soundbars 0–80 ms and AV receivers
  0–70 ms
  ([Google help 6318642](https://support.google.com/googlehome/answer/6318642?hl=en)).
  Google itself does not measure the output stage acoustically. Those are the residues
  Audiout's lead metric also cannot see.

### 1.5 Can the playback position be observed accurately enough to close a loop?

**Lead (status polling): precise but incomplete.**

- **Resolution.** The live telemetry holds at 5.46–5.48 s, so about ±10 ms steady jitter,
  matching the spike's "`currentTime` granularity ~10 ms".
- **Bias.** `secondsSent` is read after the reply arrives and after a queue hop
  (`CastOutputManager.swift:862-876, 899-914`), while `currentTime` was stamped on the
  receiver roughly RTT/2 earlier. The bias is +RTT/2 plus the hop: ~10 ms typically, up to
  ~100 ms at the admission limit. The 5.55/5.57 outliers are this bias. Cheap fix: read
  `secondsSent` at the request/reply midpoint and admit only samples near the window's
  minimum RTT.
- **Drift resolution.** With σ ≈ 10–15 ms per 1 Hz sample, a least-squares slope over
  10 min (N = 600) has σ ≈ 15 ms · √(12/N³) ≈ 3.5 µs/s, so **±3.5 ppm per 10 minutes**
  (inferred arithmetic). A typical ±20–50 ppm receiver/Mac offset is resolvable within a
  few minutes. That is enough to drive a resampler (§3, option C3).
- **Blind spots.** The lead sees only the receiver-side buffer. It cannot see:
  1. the Mac hand-off ring backlog (~500 ms, §2.1);
  2. the receiver's output stage: DAC, the Android AudioTrack, and on a TV/HDMI chain the
     soundbar (Google's own guide: 0–80 ms);
  3. anything that changes the ring without changing bytes sent (pauses, capture-clock
     drift, §2.2).

**Acoustic measurement: complete but not wired.** ProbeKit's sweeps work against any
output that plays the mix. But Cast is excluded as a calibration reference
(`AudioutCore/CompanionSnapshotBuilder.swift:209-231`, whose comment says a Cast receiver
"plays seconds behind live, which no ±500 ms correction can resolve against" — stale since
the room delay aligns Cast), gets no alignment state (`:233-236`, "nil for every
non-Bluetooth device"), and is **excluded from passive-drift baselines entirely**
(`AudioutCore/NativeBackend+Bluetooth.swift:1183-1194`, `!device.isCast`). The folder
`AGENTS.md:28` and `PassiveDriftSampler.swift:23` describe a Cast arrival as "read-only …
room reference clock", and SCA §5.2 repeats that, but the code does not list Cast at all.
A Cast receiver is *not* on the room clock. It free-runs.

**Verdict.** Polling can close a *rate* loop (ppm) well. It cannot close an *absolute*
latency loop, because two of the three terms are invisible to it. The absolute term needs
either (a) accounting for the Mac-side terms exactly (C1 below) plus one acoustic
measurement per receiver for the output stage, or (b) a transport where the receiver is
told when to play (Cast Streaming, C4).

### 1.6 What other senders do

| Project | Path | Timing | Licence (for Audiout's clean-room rule) |
|---|---|---|---|
| **OwnTone** `src/outputs/cast.c` | **Mirroring app** `85CDB22F` (Google Home), falling back to `0F5096E8`. OFFER on `urn:x-cast:com.google.cast.webrtc` with Opus 48 kHz, 20 ms packets, `targetDelay: 400`, `storeTime: 400`, 128 kbit/s, RTP PT 127, Cast RTP header with the adaptive-latency extension. | Holds each session until `start_pts = obuf.pts + outputs_buffer_duration + CAST_DEVICE_START_DELAY_MS (100)`, then sends ping-pong (one packet per RTCP ack). The comment reads "how much extra delay is required to start at the same time as Airplay. The value was found experimentally". Per-device `offset_ms` ±1000. **RTCP sync packets are commented out** ("This does not currently work"), so the alignment is open-loop. | GPL: behaviour reference only, never code. |
| **Chromium / openscreen** (`cast/streaming`) | The same Cast Streaming protocol, receiver and sender. | The receiver estimates each frame's capture time on its own clock as `SR.reference_time + smoothed_offset + (rtp_ts − SR.rtp_ts)` and schedules it at `+ target_playout_delay − player_processing_time` (`impl/receiver_impl.cc:253-255, 353-367`). The offset comes from SR arrivals through a `ClockDriftSmoother` with a 30 s time constant (`impl/clock_drift_smoother.h`, `receiver_impl.cc:433-444`). It ignores SR network delay, biasing late by one-way LAN delay (~1–5 ms, inferred). `kDefaultTargetPlayoutDelay = 400 ms` ("the window of time between capture from the source until presentation at the receiver"); `kDefaultMaxDelayMs = 1500` (`public/constants.h`). Chrome allows 1–65535 ms via `CHROME_MIRRORING_PLAYOUT_DELAY`; min = max = target because adaptive latency is disabled (`components/mirroring/service/mirror_settings.cc`, `media/cast/cast_config.h`). A per-frame `new_playout_delay` can change it mid-stream (`receiver_impl.cc:369-372`). | BSD-3: may be read and vendored with notices (scope brief). |
| **Sendspin / Music Assistant** | Custom Cast web receiver (`github.com/Sendspin/cast`, Apache-2.0) plays through Web Audio with a WebSocket clock sync (a 2-D Kalman offset+drift filter per priorart.md). | Claims cross-protocol sync with AirPlay and Sonos, but "Playback is rarely in sync straight away … set Static playback delay (ms) … by hand". **GC4A 2.0 devices** (Bose, JBL, Samsung, LG, B&O, KEF, WiiM…, and Google Nest firmware cast 20251119) "do not implement the audio APIs we require" ([MA Cast docs](https://www.music-assistant.io/player-support/google-cast/), [support #5297](https://github.com/music-assistant/support/issues/5297)). MA's "universal groups" are explicitly **not** synced ([MA groups FAQ](https://www.music-assistant.io/faq/groups/)). | Apache-2.0 |
| AirConnect (aircast) | HTTP pull, like Audiout | `latency <rtp:http>` silence-burst knobs; the author states HTTP players' play instant "cannot be controlled" and delay grows with clock mismatch (README above). | MIT |
| mkchromecast, go-chromecast, pychromecast | HTTP pull / control only | mkchromecast: "lag … up to 8 seconds". pychromecast: position extrapolation only. | MIT / Apache |

---

## 2. Failure modes and gaps relevant to reliable sync

### 2.1 (Likely bug) The ~500 ms ring cushion is not counted in the room delay

Chain (inferred from code, needs one mic run):

1. On GET the ring is emptied (`CastOutputManager.swift:713-716`). The 1 s prime is
   rendered from the empty ring, so it is silence (`CastLiveAudioServer.swift:315-319`;
   also documented at `CastOutputManager.swift:94-96`). The pacing clock then waits until
   the ring holds ≥ 22,050 frames = 500 ms (`CastLiveAudioServer.swift:331, 352-361`). From
   then on it drains at 1× while the IOProc fills at 1×, so **~500 ms stays queued in the
   ring**.
2. Audio heard at stream time `currentTime` was sent at `now − lead` and captured about
   500 ms before that. So Cast sounds at `pts + feedDelay + ringBacklog(~500) + lead +
   outputStage`.
3. The controller sets `feedDelay = room − settledLead` (`NativeBackend+Tone.swift:946`).
   Therefore Cast sounds at **`room + ~500 ms + outputStage`**, while AirPlay, BT and Mac
   sound at `room`.
4. The user offset cannot pull it back: `applied = max(0, roomDelay + userOffset)`
   (`CastOutputManager.swift:628`). For the receiver that set the term, `roomDelay` is
   tens of ms (live example: 5500 − 5470 = 30 ms), so at most −30 ms of the −1000 ms trim
   range is usable.
5. The server's own comment assumes the opposite: "the room-delay controller MEASURES
   whatever lead this produces and takes it out of the other outputs, so a cushion costs
   nothing in sync terms" (`CastLiveAudioServer.swift:326-330`). `lead` is taken *after*
   the ring, so the cushion is invisible to it. The one metric that includes it,
   `CastFeedStats.achievedDelayMs` (feed delay plus ring backlog, `CastOutputManager.swift:79-84,
   278-296`), is logged in `cast_lead_sample` but never fed into the controller.

Size: ~480–520 ms (the cushion gate plus one 20 ms tick). That is an echo, not a subtle
offset. A second, smaller Cast receiver is affected the same way. Caveat: on 2026-08-29 the
owner heard a Cast leg running 454 ms *ahead* because of a missing feed insert (comment at
`NativeBackend+Tone.swift:919-927`), so the live history is mixed. One Mac-mic recording of
AirPlay + Cast with the current build settles it.

### 2.2 The ring backlog is unobserved and can move silently

- **Pauses.** Both taps auto-start and sleep when no app plays
  (`NativeCaptureCoordinator.swift:3673-3678`; `AudioutCore/AGENTS.md:23`). During a sleep,
  the server keeps draining at 1×: first the 500 ms backlog, then zero-fill underruns
  (`CastOutputManager.swift:305-330`). When audio resumes the backlog is ~0 and nothing
  re-waits for the cushion. **So after the first pause longer than ~0.5 s, the Cast leg's
  end-to-end latency drops by ~500 ms, and its jitter cushion is gone** (inferred). Cast is
  bimodal: ~500 ms late before the first pause, roughly on time but stutter-prone after.
  The lead metric cannot see either state.
- **Capture clock vs Mac clock.** The ring's producer runs on the aggregate device's clock,
  whose main sub-device is the default output (`NativeCaptureCoordinator.swift:3665-3685`).
  Its consumer runs on mach time. There is no rate matching. At 30 ppm the backlog walks
  108 ms/h: the cushion empties in ~4.6 h (then underrun dropouts), or the ring fills its
  2 s in ~14 h (then dropped blocks). The Cast end-to-end latency walks with it, invisible
  to the lead (inferred; the ppm between built-in audio and mach on Apple Silicon is
  unmeasured).
- **Re-GET.** A mid-session re-fetch discards the backlog (`reset()`, `:394-406`). This is
  logged, and it shows up as a lead step, so the controller re-settles (handled).

### 2.3 Receiver clock drift is handled by audible steps, and `R` only ratchets up

- There is no rate correction. At the SCA's assumed ~50 ppm (unmeasured for any receiver),
  the error reaches the 150 ms threshold every ~50 min
  (`CastRoomDelay.swift:56-62`).
- If the receiver runs **slow**, the lead grows, the term is raised, and every other output
  (AirPlay pre-delay, BT, Mac) takes a gap of ≥150 ms. Because "the term never falls"
  (`CastRoomDelay.swift:27-31`), a 10 h session at 50 ppm adds ~1.8 s to `R` for good.
- If it runs **fast**, the lead shrinks and zeros are inserted into the Cast feed, a
  150 ms gap on Cast only. But inserting zeros does not refill the receiver buffer
  (`CastRoomDelay.swift:150-155`). At +50 ppm the ~5 s buffer drains in ~28 h, and then
  the receiver stalls and rebuffers: seconds of silence.
- 150 ms is itself "echo-level" by the project's audibility table (journey.md:176-178, citing
  `bt-latency-stability-research-2026-09-05.md` §3). Within the dead band, Cast can sit up
  to ±150 ms off with no correction.

### 2.4 The output stage is invisible, and the only fix is by ear

- The lead sees none of the receiver's output stage. A TV/HDMI/soundbar chain adds 0–80 ms
  by Google's own figures, and more on some TVs.
- The sole remedy is the by-ear ±1000 ms offset (`NativeBackend+Cast.swift:93-116`).
  Because of §2.1 it can only add delay for the dominant receiver.
- There is no mic calibration for Cast (`CompanionSnapshotBuilder.swift:226, 233-236`;
  popover `canAlignAgain: !device.isCast`, `PopoverController+SyncDrawer.swift:104, 128`).
- There is no passive-drift observation either (§1.5).

### 2.5 Join and leave cost the whole house

- A Cast join costs every other output one gap of `R − S` ≈ 4.5 s (AirPlay line grows by
  zeros; BT and Mac re-anchor). A leave jumps them ahead the same amount (sync brief §5;
  owner-approved as silence).
- The Cast leg itself is silent for ~10–13 s: launch 2.7 s, buffering ~5.5 s, a 10-sample
  settle.
- This is a direct consequence of Cast being the *slowest* output. Any transport with a
  receiver-side schedule under `S` removes it entirely (C4).

### 2.6 Smaller gaps

- **Refusal is invisible.** A receiver refused for sync (>9.5 s) plays unsynced with
  nothing in the UI: `refusedIDs` is read only at `NativeBackend+Tone.swift:943`, plus
  telemetry (answers journey.md:392).
- **Sample rate is fixed at 44.1 kHz** (`CastLiveAudioServer.swift:76`). Cast receivers are
  48 kHz-native in the streaming path. Whether the Default Media Receiver resamples
  internally on the HTTP path is unknown and irrelevant to timing.
- **Groups.** A Google group is one virtual device. Its leader's buffering is unmeasured.
  Per the patent, the internal delay is ~500 ms on top of the leader's own player buffer
  (inferred).
- **GC4A 2.0 speakers** (a large share of third-party Cast speakers, and 2025+ Nest
  firmware) run a reduced receiver: no CSS/iframe/dynamic import, and per MA, no Web Audio
  scheduling ([Cast audio devices](https://developers.google.com/cast/docs/audio);
  MA #5297). Whether they still accept the mirroring apps is unknown and must be tested
  before C4 is promised for them.
- **Status-poll starvation.** Control replies queue behind stalls (~1 s RTT mid-stall), so
  the loop goes blind exactly when the receiver misbehaves. The RTT filter discards those
  samples correctly.

---

## 3. Options and novel ideas

Ordered by value per effort.

### C1. Count what the Mac holds: stamp stream positions with capture `pts` (fix §2.1–2.2)

- **What.** The ring already receives `pts` and throws it away (`CastFanOut.write`,
  `CastOutputManager.swift:420-427`). Carry it: keep a small side table of `(streamFrameIndex
  → capture pts)` per chunk served, including prime and zero-fill (map those to "no pts").
  Then define the observable as **`E2E(now) = now − pts(streamIndex = currentTime × 44100)`**,
  sampled at the request/reply midpoint. This single number contains feed delay, ring
  backlog, prime, pauses, re-GETs and receiver buffer. The controller then drives
  `feedDelay += room − E2E − outputStage_i`.
- **Feasibility.** High. Pure Swift, no protocol change, no new dependency. One table on
  the server's queue, one change in `reportLead`, and `CastRoomDelay` ingesting `E2E`
  instead of `lead`.
- **Risk.** Low. The settle and hysteresis logic is unchanged. It also removes the need for
  the "cushion costs nothing" assumption.
- **Stop-gap if C1 waits.** Subtract `achievedDelayMs − feedDelay` (the ring backlog) in
  `pushCastFeedDelaysLocked`. That is one line, but it still misses pauses between samples.

### C2. Tighten the observation

- Read `secondsSent` (or the C1 `E2E`) at the midpoint of `asked` and the reply.
- Keep only samples within ~5 ms of the window's minimum RTT (the NTP min-filter trick)
  instead of a flat < 100 ms.
- Expect ±5–10 ms per sample, versus up to +100 ms bias today. Trivial effort.

### C3. Rate-match the Cast leg (replace the 150 ms steps)

- **What.** Put the existing license-clean `FractionalResampler` + `PhaseController`
  (`SyncCore.swift`, already ±200 ppm, used by `SyncedLocalSink`) on the Cast feed. Drive it
  from the slope of `E2E` (C1) regressed over 5–10 min (±3.5 ppm per 10 min, §1.5). The
  sync brief's Phase 3 already names this.
- **Effect.** It also absorbs capture-clock-vs-mach drift, because `E2E` sees both. `R`
  never ratchets up, and there are no hourly 150 ms gaps.
- **Feasibility.** High. The pieces exist. Resample in the ring's render (consumer) so the
  IOProc is untouched.
- **Risk.** Low to medium. The loop must be slow (minutes) and must freeze while stalls or
  re-settles are in progress. Stalls must never be read as rate.
- **Alternative actuator.** `SET_PLAYBACK_RATE` on the receiver (CAF defines it). Untested
  for sub-percent rates, and it would time-stretch on the receiver. Sender-side
  resampling is the safer choice.

### C4. Cast Streaming (mirroring) output: make Cast a presentation-timeline transport

- **What.** Launch `85CDB22F` (audio mirroring, Google Home class) or `0F5096E8`. Negotiate
  OFFER/ANSWER on `urn:x-cast:com.google.cast.webrtc` for a single audio stream: Opus 48 kHz
  stereo, 10–20 ms frames, AES-128 key/IV as the protocol requires, and `targetDelay` of
  our choice. Send RTP with the Cast header over UDP. **Send RTCP Sender Reports whose NTP
  time is the Mac timebase (`CLOCK_MONOTONIC` via `pts`) and whose RTP time is the frame
  position.** The receiver then plays each frame at `capture_pts + targetDelay −
  processing`, on its own clock slaved to ours through the 30 s drift smoother
  (openscreen `receiver_impl.cc:353-367, 433-444`). Set `targetDelay = R − outputStage_i`,
  and Cast then **joins the room like AirPlay does**: no pre-delay of AirPlay, no house
  gap, no drift loop, and join-to-sound in well under a second after launch (inferred from
  the mechanism, since OwnTone's "quick startup" is the stated reason it chose this path).
- **Evidence it works for a third-party sender.**
  - OwnTone ships it for Google Home devices (above).
  - The owner's own spike launched `0F5096E8` and `674A0243` from `cast-spike` on AirServer
    and got `senderConnected: true` with `webrtc`/`remoting` namespaces (scope brief spike
    log). The OFFER was never sent.
  - OwnTone's +100 ms fudge and its dead RTCP-SR code suggest its devices lock to packet
    arrival rather than to SRs. A sender that *does* send SRs before the first RTP packet
    matches what openscreen's receiver requires ("drop packet 0 … until the Receiver has
    processed at least one Sender Report", `receiver_impl.cc:317-329`). Inferred:
    SR-correct senders should land without a fudge.
- **What it takes.**
  - An Opus encoder. libopus is BSD. Apple's AudioToolbox Opus *encode* availability on
    the deployment target must be checked (I did not verify it; treat it as unknown).
    AudioToolbox FLAC/AAC would not do, because the mirroring receiver negotiates the
    codecs in the OFFER and OwnTone and Chromium use Opus.
  - AES-CTR via CommonCrypto.
  - RTP/RTCP packetiser, retransmit buffer and RTCP feedback (ACK/NACK) handling.
  - OFFER/ANSWER JSON.
  - All clean-room from openscreen (BSD-3, may be vendored with notices) and Chromium's
    `media/cast`, never from OwnTone (GPL).
  - It fits the existing seams: a new `CastStreamingSession` beside `CastOutputManager`'s
    HTTP session, the fan-out slot unchanged, and `pts` finally used.
  - Estimate (inferred): comparable to Phase (i): ~1.5–2.5k lines plus tests.
- **Risk.**
  1. **Device coverage.** Unknown on Android TV and on GC4A 2.0 speakers. It must fall
     back to today's HTTP path per device.
  2. **Undocumented protocol.** Chromium is the only spec. Google changes mirroring
     internals, as the OwnTone comments show (app id switched `0F5096E8` → `85CDB22F`).
  3. **Session semantics.** The receiver may show a "casting tab" UI or stop on idle.
     OwnTone manages; unknown for TVs.
  4. **Output stage.** Still invisible, so a per-device acoustic measurement stays
     necessary (C5). OwnTone's per-device `offset_ms` ±1000 is the same admission.
  5. **Adaptive latency** (`new_playout_delay`) is disabled in Chrome itself. Don't rely
     on changing `targetDelay` mid-stream until tested. Pick it at OFFER, and re-OFFER if
     `R` moves.
- **Spike plan (half a day to two days, on hardware).**
  1. `cast-spike --mirror`: launch the app, OFFER audio-only Opus with `targetDelay` 400,
     SR at 2 Hz, and a click every 1 s at known `pts`.
  2. Measure with the Mac mic the click-to-sound delay against `pts`, and against an
     AirPlay speaker playing the same click at `pts + S`.
  3. Repeat with `targetDelay` 200, 1000 and 2000 to confirm it is honoured; run a 30 min
     soak for drift.
  4. Test on the Google TV Streamer, a Nest Mini/Audio, and one GC4A 2.0 speaker.
  - **Exit criterion:** click-to-sound = `targetDelay + c` with `c` stable within ±5 ms
    over 30 min on at least the Nest class.

### C5. Close the absolute loop acoustically for Cast (both paths)

- **What.**
  - Allow Cast as a calibration *target*, with an AirPlay or Mac reference. Remove the
    `!isCast` guard for targets. The reference exclusion can stay.
  - Inject the probe's target lane into the Cast feed only. The render side of
    `CastFeedRing` is the Cast analogue of BT's sweep split (`fanOutSplitToBT`,
    `NativeCaptureCoordinator.swift:1984-2002`).
  - Write the result as the Cast `outputStage` term, not as the by-ear offset.
  - Add Cast to passive-drift baselines as an **observed-and-corrected** output while it
    has a measured stage. It is not a PTP-clocked anchor, contrary to the AGENTS text.
- **Feasibility.** Medium. ProbeKit is transport-agnostic. The wizard range needs ±1000 ms
  (Cast's residue on a TV chain can exceed BT's ±500), or better, measure after C1 so the
  residue is small.
- **Risk.** Medium. It needs C1 first, or the probe measures the moving ring. With the HTTP
  path the Cast leg's own start is ~10 s, so a run must wait for settle.

### C6. Try to cut the HTTP lead with SEEK-within-buffer (cheap spike, low confidence)

- **What.** If the player keeps the rebuffer target only after a stall (§1.3), then a
  `SEEK` to `currentTime + (lead − 2.5 s)` inside the already-buffered range might leave it
  at ~2.5 s without refetching.
- **Risk.** With `Accept-Ranges: none` a seek may force a re-GET (a reset, back to 5 s) or
  an error. Any stall afterwards returns to 5 s.
- **Effort.** An hour in `cast-spike`. Only worth it because C4 may not cover every device.

### C7. Keep the HTTP path, but make it honest in the product

- Surface "refused for sync".
- Show the Cast leg's measured end-to-end delay (C1) in the Sync drawer.
- Warn when a Cast join will cost the house ~5 s.
- Offer "Cast joins unsynced (no house gap)" as an explicit per-device choice for users
  who care more about the other speakers than about alignment. That is the Music
  Assistant "universal group" posture, made explicit.

---

## 4. Open questions for a live test or the owner

1. **Is Cast ~500 ms late today?** Record AirPlay + Cast with the Mac mic on the current
   build, before any pause and again after a 5 s pause. This confirms or refutes §2.1 and
   §2.2 in one session. `cast_lead_sample.achieved_delay_ms` minus the feed delay should
   read ~500 before the pause and ~0 after.
2. **Does a Nest speaker (Chromium stack) have a 2 s lead or a 5 s one?** Nothing but the
   Google TV Streamer has been measured. The owner planned "one speaker + a second for a
   group" (scope brief decision 2).
3. **Receiver drift in ppm.** A 30 min soak with 1 Hz leads is enough to run the §1.5
   regression. It decides whether C3 is needed hourly or daily.
4. **Mirroring spike (C4) go/no-go**, and on which device classes. The owner's decision on
   an Opus encoder dependency (libopus, BSD) if AudioToolbox cannot encode Opus.
5. **Capture clock vs mach on the owner's usual default output** (built-in, USB DAC, HDMI).
   `achievedDelayMs` over an hour answers it for free.
6. **Owner's call.** For users with Cast, is a ~5 s house delay acceptable as the permanent
   HTTP-path cost, or should Cast default to "unsynced" until the mirroring path exists?

---

## 5. Sources

Repo (read-only): files cited inline; `dev/notes/006-cast-*.md`, `006-cast-live-telemetry-2026-08-22.jsonl`;
`/mnt/project-files/sync-architecture/sync-clock-architecture.md`.

Online:
- OwnTone Cast output: https://github.com/owntone/owntone-server/blob/master/src/outputs/cast.c
- openscreen Cast Streaming (BSD-3): https://chromium.googlesource.com/openscreen/+/HEAD/cast/streaming/README.md ; mirror used for source: https://github.com/chromium/openscreen (`cast/streaming/impl/receiver_impl.cc`, `impl/clock_drift_smoother.h`, `public/constants.h`, `public/receiver.h`)
- Chromium mirroring: https://github.com/chromium/chromium/blob/main/components/mirroring/service/mirror_settings.cc ; https://github.com/chromium/chromium/blob/main/media/cast/cast_config.h
- Google multizone patent: https://patents.google.com/patent/US11871067
- Group delay correction: https://support.google.com/googlehome/answer/6318642?hl=en
- Media messages: https://developers.google.com/cast/docs/media/messages ; sender Media: https://developers.google.com/cast/docs/reference/web_sender/chrome.cast.media.Media ; SetPlaybackRate: https://developers.google.com/cast/docs/reference/web_receiver/cast.framework.messages.SetPlaybackRateRequestData
- Audio devices / GC4A 2.0: https://developers.google.com/cast/docs/audio
- AirConnect README: https://github.com/philippe44/AirConnect/blob/master/README.md
- Sendspin Cast receiver: https://github.com/Sendspin/cast ; MA Cast: https://www.music-assistant.io/player-support/google-cast/ ; MA #5297: https://github.com/music-assistant/support/issues/5297 ; MA groups: https://www.music-assistant.io/faq/groups/
- mkchromecast README: https://github.com/muammar/mkchromecast ; pychromecast media controller: https://github.com/home-assistant-libs/pychromecast/blob/master/pychromecast/controllers/media.py
