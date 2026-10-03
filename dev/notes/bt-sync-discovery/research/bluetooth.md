# Bluetooth transport behaviour as it bears on sync

Researcher: bluetooth. Written 2026-09-26. Read-only against `/home/claude/Audiout`
(main checkout), `audiout-shared`, `audiout-remote`.

This file extends, and does not repeat, four in-repo briefs. Read them for what
is already established:

- `dev/notes/bt-latency-stability-research-2026-09-05.md`: per-reconnect spread
  (SoundGuys 26–90 ms by codec, SoundSeeder 20–70 ms), Apple warm-up (215 → 155 ms
  over 20–30 min), Game Mode steps, sniff mode, AVDTP delay-report units,
  audibility thresholds. Cited below as **[stab]**.
- `dev/notes/bt-output-research-2026-08-07.md`: Airfoil / PairPods prior art,
  CoreAudio latency junk, concurrent-sink ceiling, Auracast absent. **[out]**
- `dev/notes/bt-spike-findings-2026-08-07.md`: Move 2 pacing clock 32 jumps /
  −353 ms in 42 s then +21.7 ppm; XM3 zero jumps, +0.4 ppm; connect 2.4–4.4 s;
  unreachable horizon 15.4 s. **[spike]**
- `dev/notes/bt-absolute-volume-detection.md`: the n/127 read-back signature, SDP
  category-2 check, private driver properties that crash coreaudiod. **[absvol]**

Also read and built on: `/mnt/project-files/sync-architecture/sync-clock-architecture.md`
(**[clock]**, esp. §2, §5.1, Gap 3), the lead's crosstalk entries 00:41–00:49, and
`research/journey.md` §3.8b.

Inferred statements are marked *(inferred)*. Vendor claims are marked *(vendor)*.

---

## 1. Key findings

### 1.1 The central question: does a sink servo to the host's delivery rate, and what is the common-mode slide?

The lead's framing (crosstalk 00:49): BT-to-BT drift is closed (PR #200, ≤2 ms over
3 min). The open question is **common-mode drift of all Bluetooth speakers against
the Mac clock / AirPlay**, seen once as a ~1 ms/min shared slide over 9 min
(567 → 556 ms, [clock] Gap 3). 1 ms/min is **16.7 ppm**.

**Finding A: A2DP sinks do servo to the rate the source delivers.** They do it with a
deadband, and the deadband is where latency wanders. Evidence:

- **The protocol forces it.** A2DP has no rate feedback from sink to source: no
  clock-recovery field, no feedback endpoint like USB async audio. RTP timestamps are
  in the stream, but the source paces delivery on its own clock. A sink that
  free-ran its DAC on its own crystal (±20–50 ppm) against a source at a different
  rate would over- or under-run a 150–250 ms buffer within tens of minutes to a few
  hours. So every shipping sink must follow the arrival rate on average. It does
  this either by adaptive resampling or by trimming its audio PLL.
- **Open implementations show both the method and the deadband.**
  - BlueKitchen BTstack `a2dp_sink_demo.c` keeps 60–80 SBC frames buffered
    (`OPTIMAL_FRAMES_MIN 60`, `OPTIMAL_FRAMES_MAX 80`). At 128 samples/frame and
    44.1 kHz that is **174–232 ms**. Outside the window it switches the resampling
    factor by ±0x100/0x10000 = **±0.39 % (±3,900 ppm)**, and inside it does
    nothing. With `HAVE_BTSTACK_AUDIO_EFFECTIVE_SAMPLERATE` it runs a continuous
    rate estimate instead.
    https://github.com/bluekitchen/btstack/blob/master/example/a2dp_sink_demo.c
  - PipeWire's BlueZ decode buffer (used when Linux is the A2DP *sink*) tracks buffer
    level against nominal time and corrects the rate by at most
    `BUFFERING_RATE_DIFF_MAX = 0.005` (5,000 ppm). It uses a 1 s short window and a
    2 min long window. On overrun (`level > max(4·target, 3·samples)`) it drops data
    ("Lagging too much: drop data"). On underrun it re-enters buffering. Target =
    max(1.5 × observed spike, duration), rounded to rate/50 (20 ms).
    https://raw.githubusercontent.com/PipeWire/pipewire/master/spa/plugins/bluez5/decode-buffer.h
  - Google's Technical Disclosure on Bluetooth clock-drift glitches lists how deployed
    sinks cope: packet dropping at thresholds, reconnecting, and ASRC in software.
    It proposes clocking the audio path from the Bluetooth controller clock.
    https://www.tdcommons.org/context/dpubs_series/article/7899/viewcontent/Eliminating_Bluetooth_Audio_Glitches_Caused_by_Clock_Drift.pdf
  - Commercial SoC datasheets (Qualcomm CSRA64215, CSR8670) publish crystal trim, not
    their rate-matching algorithm. No vendor datasheet describing sink rate matching
    was found online. **Unverified for any specific speaker brand.**
- **The repo's own acoustic evidence agrees.** The 2026-08-12 drift meter (commit
  `b35b8737`, live result in `efb67775`) recovered each speaker's tone phase slope and
  classified the track as a line or a staircase. Two different speakers (Sonos Move,
  Sony WH-1000XM3) came out at −0.02 ppm of each other. Two independently free-running
  crystals landing within 0.02 ppm is implausible. Both following one delivery rate is
  the simple explanation.

**Correction to how that evidence is cited.** `BTSyncedSink.swift:469-471`,
`per-device-trim-spec.md:46-49` and [clock] §5.1 all say "−0.02 ppm over 30 min". The
commit that recorded the result says **"clean 120s run … (~0 ms over 30 min)"**
(`efb67775`). The 30 minutes is an extrapolation from 120 seconds. It is also a
**BT-vs-BT** comparison through one Mac Bluetooth stack. It shows the two sinks follow
the same delivery rate. It says **nothing** about whether that delivery rate equals
host time.

**Finding B: what reaches the air is the Mac's *pacing* rate, and that can differ from
host time.** *(Inferred, but it predicts both observations.)*

- `BTDeviceSink` renders in the Bluetooth device's own IO cycle. After release it
  drains its ring "at unity rate" (`BTSyncedSink.swift:463-471`). So it consumes
  samples at whatever rate the BT HAL device's clock runs (the pacing clock,
  `BTClockStability.swift:13-20`), not at host rate.
- The spike measured that pacing clock against host time at **+21.7 ppm** (Move 2,
  after settle) and **+0.4 ppm** (XM3) [spike]. If the sink servos to delivery (A),
  a speaker whose pacing clock runs at ε ppm against host drifts acoustically
  against AirPlay (PTP = host) at ε. That is +21.7 ppm ≈ 1.3 ms/min ≈ 78 ms/h for
  the Move 2 case.
- The observed common-mode slide of ~1 ms/min (16.7 ppm) is the same order as
  +21.7 ppm. If the pacing rate comes from something shared by all links (the Mac's
  Bluetooth controller crystal, or a stack-wide rate scalar), all BT speakers slide
  together against host while holding ~0 against each other. That is exactly
  "BT-BT closed, common-mode open". *(inferred)*
- Bluetooth Core requires ±20 ppm native-clock accuracy on an active BR/EDR device,
  so a 17–22 ppm offset between the BT controller's crystal and the Mac's host clock
  is within spec *(inferred from the Core spec requirement, not fetched)*.
  Against that: the XM3's +0.4 ppm on the same Mac the same evening shows the pacing
  rate is **not** a single per-controller constant. The stack can also change delivery
  speed deliberately. Apple forum thread 764070 logs "audio delivery speed …
  multiplier 1.100000" while Game Mode slews latency down
  (https://developer.apple.com/forums/thread/764070). So the pacing rate is
  per-link and adjustable, and a slow slew toward a latency target would look like a
  few ppm to tens of ppm for minutes. *(inferred)*
- An alternative explanation exists. The Mac mic's own clock (built-in audio, ~30 ppm
  vs host per [clock] §2) can produce an apparent common slide ("or mic" in the
  handoff). The AirPlay arrival in the same window separates the two. If the AirPlay
  peak also moves, it is the mic. If only BT peaks move, it is BT vs host.

**Precision on which two clocks.** The producer side is not host time either. The
capture aggregate is clocked by the default output device, with the tap
drift-compensated onto it (`NativeCaptureCoordinator.swift:3654-3684`; code.md §1.1).
So the ring is filled at the *capture device's* sample rate and emptied at the *BT
pacing* rate. The acoustic slide of BT against a pts-true output (AirPlay via PTP, the
Mac via its PI loop) is **ε_pacing − ε_capture**, both taken against host. The
+21.7 ppm figure is ε_pacing alone. With built-in speakers as the capture clock,
ε_capture is typically a few to ~30 ppm ([clock] §2), so the net slide can be larger
or smaller than 21.7 ppm. This also answers code.md Q5. The HAL `mSampleTime` rate
*is* the pull rate, because AVAudioEngine pulls once per device IO cycle, and the
+21.7 vs +0.4 ppm difference is most simply read as per-link stack behaviour: the Move 2
was sampled only 77 s after a −353 ms settle, possibly still slewing. *(inferred)*
The servo in 3.1 should therefore steer against the **pts timeline** (content position
vs host time, as `SyncedLocalSink` does), with the pacing clock only as the
continuous observable of the consumer side.

**Consequence.** The claim "BT needs no rate servo" is true between BT sinks and
unproven between BT and the timebase. The measurement that settles it already exists
in the code: the 30 s `bt_clock_deviation` line (`BTClockStability.swift:74-76`
comment; [clock] Gap 3). Prediction: in steady state, **the slope of
`bt_clock_deviation` equals the BT-vs-AirPlay acoustic slide.** If it does, the fix is
cheap and continuous. Steer the BT ring's resampler with the existing `PhaseController`
against the *pacing-deviation-vs-host* error, so the ring is consumed at host rate.
That is **not** the removed `BTDriftCorrector`, which compared the pacing clock to
itself (`per-device-trim-spec.md:49`). If the slide shows up acoustically while the
pacing deviation is flat, the sink is not following delivery rate. The mic is then the
only instrument, at ~20 ms precision per window.

### 1.2 Where the latency lives in an A2DP/AVDTP pipeline

Stage by stage for a Mac source. Numbers are typical; sources on each line.

| Stage | What it is | Typical size | Varies? | Visible to the Mac? |
|---|---|---|---|---|
| Core Audio IO buffer + safety offset | HAL device buffer of the BT device | 5–20 ms *(inferred from HAL formula, `LocalOutputLatency.swift:35-41`)* | Fixed per session | Yes (but see 1.4) |
| Host encoder | SBC: 128-sample frames = 2.9 ms at 44.1 kHz, filterbank a few ms. AAC-LC: 1024-sample frames = 23.2 ms; Fraunhofer lists **55 ms** algorithmic delay at 48 kHz without bit reservoir (https://www.iis.fraunhofer.de/content/dam/iis/de/doc/ame/conference/AES-116-Convention_guideline-to-audio-codec-delay_AES116.pdf) | SBC ~3–6 ms, AAC ~50 ms | Fixed per codec | Codec only via unified log [stab] |
| Packetisation | Several SBC frames or one AAC frame per AVDTP media packet | 10–25 ms | Fixed-ish | No |
| Host → controller queue | HCI ACL buffers, L2CAP | a few ms, grows under congestion | Yes: under RF contention it grows until retransmits clear | No public API |
| Air + retransmissions | ACL, ARQ; 2-DH5/3-DH5 slots of 625 µs; AFH | <2 ms per clean packet; each lost packet re-sent in the next slot pair, 1.25 ms+, and bursts under Wi-Fi contention | Yes, it jitters. Absorbed by the sink buffer, so it shows as dropout or re-buffer, not as a lasting offset [stab] | No |
| **Sink jitter buffer** | The dominant term. BTstack demo 174–232 ms; ESP-IDF default sink delay 120 ms; PipeWire ≥20 ms granular; SEARAN: "much larger audio buffers than they should" | **100–300 ms** | Refills on every stream start (the 20–90 ms re-roll [stab]) and wanders inside its deadband (1.1) | Only via AVDTP delay report, which macOS does not expose (1.5) |
| Sink decode + DSP | EQ, loudness, DRC, TWS relay, crossover | 5–50 ms *(inferred)*; TWS relay adds a second hop | Can change with volume/EQ mode on some speakers *(inferred, no measurement found)* | No |
| DAC + amp | Filters, class-D | <2 ms | No | No |

So 70–90 % of a BT speaker's latency is a sink-side buffer whose depth is a firmware
decision, re-rolled at each stream start. The host-side parts (codec, packetisation)
are fixed per session and matter only when the codec changes.

### 1.3 Codecs on macOS

- **What macOS offers: SBC and AAC only.** aptX was removed. The old
  `defaults write bluetoothaudiod "Enable AptX codec"` / "Enable AAC codec" keys and
  Bluetooth Explorer's force-codec switches stopped working from Monterey (gist
  comment, May 2023: "none of these commands have any affect … starting with macOS
  Monterey"; https://gist.github.com/florianpasteur/27837c1545a7edec9dfdd4ea1b8f359c;
  also [stab]). LDAC was never supported. LE Audio LC3 is not offered for A2DP-class
  playback (1.8).
- **The choice is Apple's and cannot be influenced.** AAC-capable devices sometimes
  get SBC. For example, Sequoia 15.5 put hearing aids on SBC only; the user found it
  "through the console" (https://discussions.apple.com/thread/256151211).
- **Why it matters for sync.** SBC and AAC differ by roughly 45–50 ms of host-side
  algorithmic delay (55 ms AAC-LC vs ~3–6 ms SBC). A speaker that lands on AAC one
  connection and SBC the next steps by that amount, and nothing tells the app.
  SoundGuys measured a 61 ms mean difference, SBC 308 vs AAC 369 ms on Android [stab].
  **Detection path:** the `bluetoothaudiod` unified-log codec line. `OSLogStore`
  cannot read other processes from a normal app ([absvol] §5). So the only in-app
  signal is a latency step at reconnect of about that size, which the reconnect
  re-check already catches. *(inferred)*
- **Sample rate:** macOS runs A2DP at 44.1 kHz on the tested speakers (the drift meter
  hard-codes `a2dpRate = 44_100`, `efb67775`). Audiout's sink builds at the device's
  nominal rate, and an HFP collapse shows up as ≤24 kHz (`BTSyncedSink.swift:787-792`).

### 1.4 What Core Audio reports as latency for BT devices

- The app logs it once per sink start as `bt_device_reported_latency`
  (`BTSyncedSink.swift:772-780`), using the HAL formula (safety offset + device +
  stream latency + buffer, `LocalOutputLatency.swift:35-41`). Nothing consumes it.
- External evidence that it is a constant, not a measurement: AirPods read a flat
  160 ms while the stack moved between 60 and 220 ms
  (https://developer.apple.com/forums/thread/764070). The iOS output latency
  "can change from 193ms to 260ms" within a minute
  (https://developer.apple.com/forums/thread/126277) [stab]. JUCE users report
  `kAudioStreamPropertyLatency` = 0 [out].
- **Open and cheap to answer from existing telemetry:** does the reported value differ
  *between speaker models*? If it does, macOS is probably folding in something
  device-specific, and the most likely source is an AVDTP delay report. If every BT
  device reports the same number, it is a stack constant. Either way, correlate it
  against the acoustically measured latency already stored per speaker.
- **Related trap (new, for code):** Apple forum thread 770218 reports that a process
  tap gains **300–400 ms** of delay when the system default output is a Bluetooth
  device, even when the tapping app does not use that device. Apple's answer ties it
  to the BT device being in the tap's aggregate
  (https://developer.apple.com/forums/thread/770218). Audiout's tap aggregate uses
  the **default output as its main sub-device**
  (`NativeCaptureCoordinator.swift:3654-3679`: `kAudioAggregateDeviceMainSubDeviceKey:
  outputUID`, `kAudioSubTapDriftCompensationKey: true`). If a user's default output is
  a BT speaker, the whole capture timeline is clocked by that speaker's pacing clock,
  and it may carry that extra delay and every pacing-clock jump (32 jumps in 42 s on
  the Move 2). *(inferred; see crosstalk to code)*

### 1.5 AVDTP Delay Reporting (A2DP 1.3)

- **What it is:** the sink sends `AVDTP_DELAY_REPORT` (signal 0x0D) with its
  playout delay in 0.1 ms units. It sends it at stream configuration and may send it
  again [stab]. Linux (BlueZ + PipeWire/PulseAudio 12+) and Android 9+ use it. Those
  media stacks expose it as a presentation timestamp, so video players delay the
  picture ("I haven't encountered a single application on desktop Linux that doesn't
  support this properly", HN 38401452 via
  https://hn.algolia.com/api/v1/items/38401452). A BlueZ 5.82 sink value of 1498
  (149.8 ms) is on record, and 5.83 regressed it (https://github.com/bluez/bluez/issues/1541).
- **Microsoft's accessory guideline** requires A2DP ≥1.3 and AVRCP ≥1.6.2 but does not
  mention delay reporting
  (https://learn.microsoft.com/en-us/windows-hardware/design/accessory-guidelines/bluetooth-accessory-guidelines/bluetooth-accessory-guidelines-classic-audio).
- **Accuracy:** the value is a firmware constant (the ESP-IDF sink API sets it once,
  default 120 ms [stab]). It does not track the 20–90 ms per-start re-roll or the
  deadband wander in 1.1. Best case, it is a prior within tens of ms.
- **macOS:** no public API exposes a delay-report value, and no Apple document says
  whether bluetoothd honours one. Whether it feeds `kAudioDevicePropertyLatency` is
  the question in 1.4. **Treat it as unobservable.** Never reach for it through the
  BT HAL plugin's custom properties: reading them crashed coreaudiod three times
  ([absvol] §2).

### 1.6 Latency variability over a session

Established in [stab] and [spike]: connect-time re-anchoring (Move 2: −353 ms in
42 s), Apple warm-up (~60 ms over 20–30 min), Game Mode steps (70–90 ms, at 1.1×
speed), stream restart after silence (a fresh 20–90 ms roll), sniff-mode wake. This
file adds:

- **Deadband wander inside a running stream** *(inferred from 1.1)*. A sink with a
  BTstack-style 60–80-frame window lets its buffer, and so its latency, float by up
  to ~58 ms without correcting. Where it sits depends on the source/sink rate
  difference and the arrival jitter. PipeWire-style continuous control holds it
  tighter. The drift meter's "line vs staircase" classifier (`b35b8737`) can tell
  the two kinds of sink apart, and it should be run per speaker model.
- **RF interference** delays packets. The sink buffer absorbs short bursts. A long
  burst underruns it, the sink re-buffers, and latency comes back re-rolled. A
  PipeWire-class sink that overruns drops data, which steps latency *down*. So steps
  can go either way. *(inferred from the decode-buffer code)*
- **Pause/resume:** macOS suspends the AVDTP stream after silence. The keep-alive
  exists for this ([clock] §5.2, 10 min default). A resume after suspend re-rolls.
- **Volume changes:** no measurement found of latency moving with AVRCP volume.
  Speakers whose loudness/DRC mode changes with volume could change DSP path length
  *(inferred, unverified)*. Cheap to test: step volume during a passive-drift run.
- **Game Mode on a Mac** (any full-screen game) moves every BT link by 70–90 ms, at
  1.1× delivery speed. `BTClockStability` sees that as a string of 100 ms/s "jumps"
  (threshold 2 ms/s, `BTClockStability.swift:49`), which marks the speaker as moved.
  That is the right outcome. *(inferred)*

### 1.7 Multiple simultaneous BT sinks on one Mac

- **Airtime:** SBC at high quality ≈ 328–345 kbps per link (Sendspin BT Bridge:
  "~345 kbps"; https://trudenboy.github.io/sendspin-bt-bridge/bluetooth-adapters/);
  AAC ≈ 250 kbps (https://www.bluetoothgoodies.com/a2dp/faq/). EDR 2-DH5 carries
  ~1.4 Mbps and 3-DH5 ~2.1 Mbps before retransmissions *(standard figures, inferred)*.
  So 2 links use ~50 % of a clean 2-DH5 piconet and 3 links ~75 %, with little room
  left for retransmits. That matches field reports: 2 fine, 3–4 fragile [out].
  Sendspin's guidance is 1–3 speakers per adapter and one adapter per 2–3 speakers
  beyond that. It notes 7 active ACL links is the protocol ceiling, and a Pi's
  built-in combo chip supports only one A2DP stream.
- **Wi-Fi coexistence:** every Mac uses a Wi-Fi/BT combo radio. When Wi-Fi is on
  2.4 GHz, the radios time-share, and AirPlay traffic to other speakers competes
  on the same chip. Pi guidance: contention causes "Tx excessive retries … audio
  dropouts"; mitigation: "prefer 5 GHz WiFi on the host". Apple's own support
  article covers 2.4 GHz interference (https://support.apple.com/en-ph/102319).
  *(inferred: a Mac on 2.4 GHz Wi-Fi streaming AirPlay plus 2–3 BT sinks is the
  worst case, and a diagnostic should flag the Wi-Fi band.)*
- **Per-link scheduling** is invisible. Each link has its own pacing clock and its
  own HAL device (the repo already pins one `AVAudioEngine` per device).

### 1.8 Speaker-side behaviours

- **Auto-standby / amp parking.** The Sonos Move "parks its amp when idle and rejected
  the first engine start outright" (`efb67775`). The drift meter needed retries and a
  warm-up. That is a strong mechanism candidate for the owner's first-sync silence
  (crosstalk 00:46), but another thread owns that diagnosis. Many portables power
  down after 10–30 min of no signal *(vendor manuals, not fetched per model)*. The
  keep-alive covers the idle case only while Audiout is feeding.
- **Fade-in / clipped onset** after silence: sniff-mode wake plus amp gating clips the
  first 100–500 ms *(inferred; [stab] sniff 80–100 ms interval; blueman issue 2976)*.
  Consequence: a probe sweep that starts the stream clips its first part. Precede
  every probe with ≥1 s of low-level signal.
- **TWS / stereo-pair / party modes.** In TWS the primary relays to the secondary over
  its own link and delays itself to match, which adds latency and time slots ("Earbuds
  need to communicate with each other … using the Bluetooth time slots otherwise used
  to receive the streaming packets", bluetoothgoodies FAQ). **JBL Auracast
  (Go 4, Clip 5, Xtreme 4, Charge 6, Flip 7) and PartyBoost groups are synced by the
  speakers themselves.** To Audiout the group is one A2DP sink with one (larger)
  latency, which is good: treat it as one sink and measure the group. But JBL Auracast
  speakers "only accept Auracast signals from another compatible JBL speaker", not a
  third-party transmitter
  (https://support.avantree.com/hc/en-us/articles/51047209598105).
- **Multipoint** headphones and speakers can be taken by a phone mid-session. That is a
  device pull, which the 1.2.0 re-time fix addresses (crosstalk 00:41).

### 1.9 LE Audio / LC3 / Auracast: the one transport with a defined render time

- **Why it matters.** LE Audio's BAP gives every stream a **Presentation Delay** in
  microseconds (Zephyr `bt_bap_qos_cfg.pd`: "Presentation Delay in microseconds";
  https://docs.zephyrproject.org/latest/doxygen/html/structbt__bap__qos__cfg.html).
  It is measured from the CIG/BIG sync point, and every sink renders at *sync point +
  PD*. Connected streams stagger CIS offsets so all sinks "present to their Hosts at
  the same time" (https://cloud2gnd.com/fundamentals-of-le-audio-connected-isochronous-streams/).
  This is the property A2DP lacks: a source-defined, speaker-honoured render instant.
  Sink-side clock recovery rides the isochronous channel's timing, not a buffer-level
  guess.
- **macOS status, September 2026: none for third parties.** Apple said nothing on
  Auracast or LE Audio at WWDC26 (Aurahear, June 2026,
  https://aurahear.com/2026/06/apple-disappoints-on-auracast-support-at-wwdc26-keynote-event/),
  and nothing earlier ([out]; HearingTracker thread
  https://forum.hearingtracker.com/t/apple-mfi-bluetooth-le-audio/96247). The HAL does
  define a BLE transport type (`'blea'`, [absvol] §1). Apple's MFi hearing-aid LEA
  is proprietary and not a general sink path *(inferred)*.
- **Numbers (from priorart.md §1.5, not re-fetched):** the Bluetooth SIG says all
  Auracast receivers must meet a 40 ms presentation delay, the BAP default; HAP/TMAP
  devices support 20–40 ms. A commercial assistive-listening system quotes 31 ms end
  to end. The FlooGoo FMA120 (Qualcomm QCC3086) USB dongle works on macOS, quotes
  ~19.5–21.5 ms in LE gaming mode, and has an MIT Mac sender app
  (https://github.com/napthemax/auracast-sender).
- **Routing around it (see 3.3):** a USB Auracast *transmitter* such as the Sennheiser
  BTD 700 is "a class-compliant USB audio device" that works with Macs (June 2025,
  $59.95; https://www.techradar.com/audio/sennheisers-new-usb-hi-res-audio-dongle-can-upgrade-your-mac-iphone-or-pc-with-aptx-lossless-and-bluetooth-auracast).
  The Mac sees a USB output with a stable HAL latency. The dongle broadcasts LC3 with
  a PD, and every Auracast *receiver* that joins renders in lockstep. The limit is
  receivers: JBL refuses third-party broadcasts; hearing aids, Galaxy Buds and some
  speakers accept them. Not yet a mass-market speaker path.

### 1.10 HFP and the speaker's microphone as a measurement channel

- **Band limits (answers journey's crosstalk (5)).** CVSD samples at 8 kHz, a
  ~300–3,400 Hz pass band. mSBC samples at 16 kHz, a ~7 kHz band (HN 24774912,
  "mSBC … supports 16 kHz sampling rates"). Apple's AAC-ELD for HFP (AirPods Pro
  2021+, AirPods 3/Max, Beats Fit Pro) runs "at 24,000 Hz (+ SBR) in mono in both
  directions", about 12 kHz, over a 64 kbit/s SCO link
  (https://medium.marco.zone/apple-implemented-the-biggest-improvement-to-bluetooth-audio-since-2009-2079abc607af).
  Third-party speakers get CVSD or mSBC. **So in HFP the ProbeKit UP sweep
  (3.2–10 kHz) is cut off entirely on CVSD and above ~7–8 kHz on mSBC, and the DOWN
  sweep (0.5–2 kHz) survives both.** Confirmed.
- **As a measurement channel it is useless for A2DP sync.** Opening the speaker's mic
  switches the speaker's *output* to HFP (repo roadmap 019: 44.1 → 16 kHz, 1.18 s
  lost per toggle). So the path being measured is no longer the A2DP path, and its
  latency is unrelated (SCO/eSCO is a fixed-slot, low-latency path). It also
  degrades every other speaker through the tap rebuild. Keep the rule already in
  code (`hfpDegraded`, `BTSyncedSink.swift:785-792`): never open a BT mic during
  playback.

### 1.11 USB / external Bluetooth dongles as a controllable path

A USB A2DP transmitter (Creative BT-W5 / BT-W6, Sennheiser BTD 700, Avantree) is a
class-compliant USB audio device to macOS:

- **Gains.** No bluetoothd in the path, so no Apple warm-up, no Game Mode steps, no
  HFP collapse (the dongle does not offer HFP to the Mac as an output mode change),
  no macOS codec choice. It can negotiate aptX / aptX Adaptive (vendor low-latency
  modes; Qualcomm claims aptX LL "<40 ms" end to end *(vendor)*) when the speaker
  supports them, which few speakers do. Its own radio can sit on a USB extension away
  from the Mac's Wi-Fi. The HAL latency of a USB device is honest in a way BT's is
  not. It could go through the `SyncedLocalSink` path with the PI loop, since it is a
  crystal-clocked USB device *(inferred)*.
- **Does not gain.** The speaker's own sink buffer, re-roll and deadband wander are
  unchanged. The dongle's USB-in to BT-out is a second clock domain, and it
  presumably servos to USB SOF or its own crystal *(unknown)*. One dongle drives one
  or two sinks.
- **Verdict.** A good "pro" recommendation for users with 3+ BT speakers or on a Mac
  with busy 2.4 GHz Wi-Fi. It does not solve sync by itself.

### 1.12 AVRCP absolute volume from the transport side (owner requirement, crosstalk 00:45)

What the transport **guarantees**:

- A 7-bit value, 0x00–0x7F, set by the controller (Mac) via `SetAbsoluteVolume` and
  reported back via `EVENT_VOLUME_CHANGED`. It is mandatory for AVRCP 1.4+ category-2
  targets. macOS forwards the Core Audio device volume to it and reads back exact
  multiples of 1/127 ([absvol] §3, verified on Move and Move 2).
- The *number* only. The spec defines 0x7F as maximum and 0 as minimum. The mapping
  from step to acoustic level is the sink's own curve: step count, dB per step and
  where it saturates are all per vendor. Two brands at 80/127 can differ by 10 dB or
  more *(inferred from the spec leaving the curve undefined; no cross-brand SPL
  dataset found)*.

What it **does not** guarantee (evidence):

- **Speakers that advertise it and ignore or mishandle it.** No stack detects this;
  all trust the SDP record ([absvol] §4). Android ships a "Disable absolute Bluetooth
  volume" developer switch because devices cause "volume spikes, drops, and
  inconsistency" and a phone "on volume 9 while the Bluetooth device is on volume 7"
  (https://www.androidpolice.com/android-disable-absolute-bluetooth-volume/).
- **Speakers with no category-2 support.** macOS then scales digitally before
  encoding, and the speaker's own knob stays independent. A software-volume device's
  read-back is continuous (unverified, [absvol] §3).
- **Speaker-side clamps** *(inferred, not measured)*: firmware volume limiters, reduced
  maximum on low battery or in outdoor/eco modes on some portables, loudness/DRC
  compressing the top of the range, and the speaker's own buttons changing the value
  mid-run (they do fire the Core Audio volume listener on absolute-volume devices,
  [absvol] §5).
- **Two volume stages multiply.** Audiout's per-device engine gain (`mainMixerNode
  .outputVolume`, `BTSyncedSink.swift:797`) is digital and applied before the encoder.
  The AVRCP value is the speaker's analog/DSP stage. The sweep level at the speaker =
  engine gain × macOS device volume (digital if not absolute) × speaker stage.

**Can the Mac verify the speaker's real output level? Yes, acoustically, and it
should, whether or not AVRCP control exists.** A pre-sweep level probe is feasible
with what exists:

1. Keep the link warm (≥1 s of low-level signal) so the amp is awake and the first
   part of the sweep is not clipped (1.8).
2. Measure the phone's noise floor in the two ProbeKit bands (0.5–2 kHz reference,
   3.2–10 kHz target) for ~0.5 s.
3. Play band-limited noise, or a short sweep, on each lane in turn for ~1.5 s. The
   window must be longer than the largest plausible BT latency (≤1 s), because the
   arrival time is not yet known. Measure band RMS.
4. Require per-band SNR above a floor, and the two lanes within ProbeKit's tested
   ~23 dB separation margin (`audiout-shared` CLAUDE.md, ProbeKit tests). If AVRCP
   control is present (SDP category-2 plus n/127 read-back, [absvol]), step the
   device volume by about +8/127, re-check, cap at a ceiling (for example 100/127),
   and restore the user's value afterwards. If it is absent, raise Audiout's own
   engine gain to 1.0 for the probe, which is fully under app control, and otherwise
   ask the user to turn the speaker up, then re-check.
5. A band that stays silent is the "speaker not playing" case. Report it as that, not
   as a failed measurement, which also covers the first-sync silence symptom
   (crosstalk 00:46).

Cost: about 3–4 s added to a calibration. The level probe also catches HFP collapse
(the target band vanishes) and a speaker that has gone to sleep.

---

## 2. Failure modes and gaps relevant to reliable sync

| # | Failure mode | Size | Detectable from the Mac? | Status |
|---|---|---|---|---|
| F1 | Common-mode BT-vs-host rate offset: sink follows the pacing clock, pacing ≠ host | 0.4–22 ppm seen on the pacing clock; ~1 ms/min acoustic once | Yes, continuously: `bt_clock_deviation` slope vs host | Not corrected; claim of "no drift" rests on a 120 s BT-vs-BT run (1.1) |
| F2 | Sink deadband wander | up to ~58 ms in a BTstack-style sink | Mic only | Unmeasured per model; drift-meter classifier exists |
| F3 | Stream-start re-roll | 20–90 ms | Mic only; pacing clock shows re-anchor | Keep-alive prevents; reconnect re-check |
| F4 | Codec change across reconnects (SBC↔AAC) | ~45–60 ms | Only as a latency step; unified log unreadable in-app | Caught by the reconnect re-check if it runs |
| F5 | Tap aggregate clocked by a BT default output | +300–400 ms tap delay reported; pacing jumps enter the capture timeline | Yes: transport type of the main sub-device | Unhandled *(inferred)*; see crosstalk to code |
| F6 | Speaker asleep / amp parked at probe start | silent sweep, or first part clipped | Mic level probe | No level probe today (1.12) |
| F7 | HFP collapse | output drops to 16 kHz; UP sweep lost | Yes, nominal rate ≤24 kHz | Detected (`hfpDegraded`), not gated in the probe path *(inferred)* |
| F8 | Game Mode / OS latency mode | 70–90 ms, at 1.1× | Pacing-clock jumps | Marks moved; mic re-check |
| F9 | 3+ sinks or 2.4 GHz Wi-Fi contention | dropouts, re-buffers (re-rolls) | Pacing jumps plus the Wi-Fi band | No user-facing hint |
| F10 | AVRCP volume ignored or clamped | sweep too quiet | Mic level probe only | No check |
| F11 | `kAudioDevicePropertyLatency` used anywhere as truth | 60–160 ms error | n/a | Logged only; the clock doc's Gap 4 (BT as default output via `SyncedLocalSink`) is the risk |

---

## 3. Options and novel ideas

### 3.1 Close F1 with a pacing-clock rate servo (cheap, continuous)

- **What:** in `BTDeviceSink`, drive the existing `FractionalResampler` ratio from a
  `PhaseController` whose error is content position (anchor pts + frames consumed)
  against host time at the device boundary. That is the same loop `SyncedLocalSink`
  runs. Low-pass it, and treat steps over 2 ms as re-anchors using the jump rejection
  `BTClockStability` already has. The ring is then consumed at the capture timeline's
  rate, so a sink that follows delivery follows pts. This is code.md's O1 seen from
  the transport side. O1 also fixes the pause holes.
- **Feasibility:** high. Every part exists (`SyncCore.swift` PI loop ±200 ppm, the
  resampler already in the BT render path, the per-second pacing sampler).
- **Gate first:** one live session with AirPlay plus BT, checking that the
  `bt_clock_deviation` slope equals the BT-vs-AirPlay acoustic slide (1.1 prediction).
  If it does, build. If the acoustic slide is there without a deviation slope, do not
  build: the sink is not following delivery.
- **Risk:** servoing to a clock the stack is deliberately slewing (Game Mode 1.1×)
  would fight the stack. Freeze the servo while `BTClockStability` is not steady.

### 3.2 Measure the sink, not just the host: per-model sink profiles

- **What:** run the drift meter's line/staircase classifier and a 10-minute passive
  run per speaker model, and record the deadband width and the re-roll spread. Feed
  that as the prior for the settle gate and the drift-policy thresholds (a BTstack-like
  sink needs a wider "leave it" band than 10 ms).
- **Feasibility:** medium. Tools exist on `claude/bt-multi-spike`, and data collection
  is the cost.

### 3.3 Novel: route around A2DP's missing render time

1. **USB Auracast transmitter as a "sync bus"** (1.9). The Mac feeds one USB device.
   Every Auracast receiver renders at the BIG sync point + PD, so they are in sync with
   each other by construction, and Audiout aligns *one* latency (the dongle chain)
   against AirPlay. Feasibility: works today on hardware that exists, but receiver
   support is thin (JBL closed, hearing aids and earbuds open). Risk: niche. Worth a
   bench test with a BTD 700 and one open Auracast speaker, to measure how repeatable
   the dongle chain's latency is across restarts. If it is fixed to within 1–2 ms,
   that is the first BT-class path where "calibrate once" is literally true.
2. **Speaker-native groups as one sink.** Detect a JBL PartyBoost/Auracast or Bose
   SimpleSync group (the user tells us, or a mic run shows one arrival for N
   speakers) and treat it as one BT sink. Halves the airtime problem and the
   calibration count. Feasibility: high, UX only.
3. **Inaudible, continuous presence tracking.** The Google/Tap Sound patent
   US11089496 measures receiver latency with test signals **above 19 kHz** after a
   40 s clock-settle wait (https://patents.google.com/patent/US11089496). A2DP
   SBC/AAC at typical bitrates low-pass around 16–20 kHz *(inferred)*, so ultrasonics
   may not survive encoding. A band at 17–19 kHz at −30 dBFS might, and would give a
   per-speaker marker that passive music correlation lacks (attribution). Feasibility:
   low to medium. Needs a codec pass-band test per codec, since AAC at 256 kbps
   typically cuts ~16–18 kHz *(inferred)*. Risk: audible to young listeners and pets.
   Note the prior art for the priorart researcher.
4. **Delay-report prior via the one allowed channel.** If telemetry (1.4) shows the
   HAL latency varies by model, use it as the wizard's starting prior (it narrows a
   2000 ms search), never as truth.

### 3.4 Level-probe-before-sweep (1.12)

Feasible now, about 3–4 s per calibration. It closes F6, F7 and F10 and gives the
owner's volume requirement a closed loop that works with or without AVRCP.

### 3.5 Hygiene that removes whole failure classes

- Warn when the Mac is on 2.4 GHz Wi-Fi with ≥2 BT sinks plus AirPlay (F9).
- Recommend ≤2 BT sinks per Mac, and a USB dongle per extra 1–2 (1.11).
- Refuse to build the tap aggregate on a BT main sub-device, or at least log its
  transport (F5); pick a wired/built-in clock master for capture when one exists.
- Never open a BT mic during a session (F7), and never touch BT HAL custom properties
  ([absvol]).

---

## 4. Open questions needing a live test or the owner

1. **Common-mode slide:** in one AirPlay plus 2 × BT session of ≥30 min, does the
   `bt_clock_deviation` slope per BT device equal the BT-vs-AirPlay acoustic slide?
   Does the AirPlay peak stay still, ruling out the mic clock? This single test
   decides 3.1.
2. Is the pacing-clock rate per-controller (shared) or per-link? Log both speakers'
   deviation slopes in the same session. The spike's +21.7 vs +0.4 ppm came from
   separate runs.
3. Re-run the drift meter for 30 min, not 120 s, and correct the "30 min" wording in
   `BTSyncedSink.swift:469-471` and the trim spec.
4. Does `bt_device_reported_latency` differ between speaker models (delay-report
   hint)? Existing telemetry answers this.
5. Per speaker model: line or staircase, and deadband width (3.2).
6. Does latency move with AVRCP volume steps? One passive run while stepping volume.
7. The codec per connection: read `bluetoothaudiod`'s codec line from Console across
   20 reconnects of the owner's Move 2 / XM3 / Flip 5 (the [stab] plan, still owed).
8. Bench a USB Auracast transmitter plus one open receiver: latency repeatability
   across restarts (3.3.1).
9. Owner: acceptable volume ceiling for an automatic pre-sweep raise (1.12 step 4),
   and whether the raise may happen without a prompt.

---

## 5. What can and cannot be controlled or observed from a Mac

| | Control | Observe |
|---|---|---|
| Codec | No (Apple picks SBC/AAC; aptX gone) | Only in the unified log (not in-app) |
| Host buffer, packetisation | No | HAL buffer yes; the rest no |
| Delivery (pacing) rate | Indirectly: what we feed and when | **Yes**, `AudioDeviceGetCurrentTime` against host time |
| Controller queue, retransmits, AFH, Wi-Fi coexistence | No (Wi-Fi band: user-level) | No; symptoms only as pacing jumps and dropouts |
| Sink buffer depth, deadband, re-roll | No | **Only acoustically** (mic) |
| Sink's own latency claim (delay report) | No | Not exposed on macOS |
| Speaker volume | Yes when AVRCP category-2 is honoured | Value yes (n/127); real level only by mic |
| Stream suspend / resume | Yes, by keeping the stream fed | Yes |
| HFP collapse | Avoid by never opening the mic | Yes, nominal rate |
| Render instant | **No, on A2DP. Yes on LE Audio (PD), which is unavailable on macOS except through a USB Auracast dongle** | — |

Gaps a novel design can route around:

- **The rate is observable where it matters.** The sink follows what the Mac delivers,
  and the Mac can see and set the delivery rate. So common-mode drift is a
  host-side servo problem (3.1), not an acoustic one.
- **The render instant is not observable on A2DP.** Route around it by measuring
  acoustically on events (existing design), with a level probe so each measurement
  can succeed (3.4). Or leave A2DP: a USB Auracast transmitter gives a defined PD
  (3.3.1). Or let a speaker-native group do the in-group sync (3.3.2).
- **Codec and stack mode steps** cannot be prevented from Apple's stack. A USB A2DP
  dongle removes bluetoothd from the path entirely (1.11).

---

## Sources (external)

- BTstack A2DP sink demo: https://github.com/bluekitchen/btstack/blob/master/example/a2dp_sink_demo.c
- PipeWire BlueZ decode buffer: https://raw.githubusercontent.com/PipeWire/pipewire/master/spa/plugins/bluez5/decode-buffer.h
- Google TD Commons, clock drift glitches: https://www.tdcommons.org/context/dpubs_series/article/7899/viewcontent/Eliminating_Bluetooth_Audio_Glitches_Caused_by_Clock_Drift.pdf
- Fraunhofer, codec delay guideline (AES 116): https://www.iis.fraunhofer.de/content/dam/iis/de/doc/ame/conference/AES-116-Convention_guideline-to-audio-codec-delay_AES116.pdf
- macOS codec switches gone since Monterey: https://gist.github.com/florianpasteur/27837c1545a7edec9dfdd4ea1b8f359c
- Sequoia forces SBC: https://discussions.apple.com/thread/256151211
- Apple forums 764070 (flat 160 ms, 1.1× multiplier): https://developer.apple.com/forums/thread/764070
- Apple forums 126277 (193 → 260 ms): https://developer.apple.com/forums/thread/126277
- Apple forums 770218 (tap +300–400 ms with a BT default output): https://developer.apple.com/forums/thread/770218
- HN on delay reporting: https://hn.algolia.com/api/v1/items/38401452 ; Arch forum: https://bbs.archlinux.org/viewtopic.php?id=287046
- BlueZ delay-report regression: https://github.com/bluez/bluez/issues/1541
- Microsoft classic audio accessory guideline: https://learn.microsoft.com/en-us/windows-hardware/design/accessory-guidelines/bluetooth-accessory-guidelines/bluetooth-accessory-guidelines-classic-audio
- Sendspin BT bridge adapter guidance: https://trudenboy.github.io/sendspin-bt-bridge/bluetooth-adapters/
- Bluetooth Goodies A2DP FAQ: https://www.bluetoothgoodies.com/a2dp/faq/
- Apple Wi-Fi/BT interference: https://support.apple.com/en-ph/102319
- Zephyr BAP QoS (PD in µs): https://docs.zephyrproject.org/latest/doxygen/html/structbt__bap__qos__cfg.html
- CIS sync mechanics: https://cloud2gnd.com/fundamentals-of-le-audio-connected-isochronous-streams/
- WWDC26, no Auracast: https://aurahear.com/2026/06/apple-disappoints-on-auracast-support-at-wwdc26-keynote-event/
- HearingTracker on Apple LE Audio: https://forum.hearingtracker.com/t/apple-mfi-bluetooth-le-audio/96247
- Sennheiser BTD 700: https://www.techradar.com/audio/sennheisers-new-usb-hi-res-audio-dongle-can-upgrade-your-mac-iphone-or-pc-with-aptx-lossless-and-bluetooth-auracast
- JBL Auracast closed to third-party transmitters: https://support.avantree.com/hc/en-us/articles/51047209598105-Can-Avantree-Auracast-devices-work-with-JBL-Auracast-speakers
- JBL Auracast models: https://www.soundguys.com/goodbye-jbl-partyboost-hello-auracast-134004/
- Apple AAC-ELD for HFP: https://medium.marco.zone/apple-implemented-the-biggest-improvement-to-bluetooth-audio-since-2009-2079abc607af
- Android absolute volume switch: https://www.androidpolice.com/android-disable-absolute-bluetooth-volume/
- Google/Tap Sound latency patent: https://patents.google.com/patent/US11089496
- Qualcomm CSRA64215 datasheet (no rate-matching detail published): https://www.tinyosshop.com/datasheet/CSRA64215%20QFN%20Data%20Sheet.pdf
