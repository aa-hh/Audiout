# Prior art: keeping heterogeneous speakers, Bluetooth especially, in sync

Researcher: priorart. Written 2026-09-26. Read-only survey; nothing in any repo was changed.

**Scope.** Everything outside Audiout that has tried to keep mixed speakers in time:
products, open source, standards, papers and patents. For each: the mechanism, the
accuracy anyone measured, whether it follows drift continuously, **what it does that
Audiout does not**, and what Audiout can borrow. Then the gap nobody has filled.

**What this extends, not repeats.** Prior in-repo research already covers a lot.
Where a point is settled there, this file cites it and adds only what is new:

- `dev/notes/competitor-parity-research-2026-08-05.md`: the feature-parity sweep
  (Airfoil, SoundSource, Sonos, OSS multiroom, TuneBlade, Cast peers).
- `dev/notes/bt-output-research-2026-08-07.md`: Airfoil and PairPods mechanics, the
  per-device offset UX pattern, macOS Multi-Output drift correction.
- `dev/notes/bt-latency-stability-research-2026-09-05.md`: per-reconnect re-roll
  (SoundSeeder 20–70 ms, SoundGuys 26–90 ms), Apple warm-up, AVDTP delay reports,
  audibility thresholds.
- `dev/notes/sync-sheet-wait-discovery-2026-09-04/bluetooth-precedent.md`: UX
  catalogue of 27 alignment products (Apple TV Wireless Audio Sync, Roku, WiiM,
  JBL, UE, Bose, Sony, Samsung, Auracast on Galaxy).
- `dev/notes/drift-tde-algorithms-brief.md` and `drift-ensemble-design-brief.md`:
  GCC/PHAT/SCOT literature for music-as-probe.
- `dev/notes/mic-probe-calibration-brief.md`: BeepBeep difference trick, the
  seed-database idea.

**Audiout's design, for the comparison column.** From
`/mnt/project-files/sync-architecture/sync-clock-architecture.md` (§1–§5): the Mac
host clock is the only timebase; AirPlay follows it by PTP; each output plays at
`pts + R` with `R` the room delay (delay-to-worst, except Gap 1: with AirPlay present
`R` ignores BT); BT latency is measured acoustically (phone mic, Mac mic, or by ear),
never read from the HAL; after release the BT sink does **no** rate correction (by
decision); drift is handled as discrete events by a passive Mac-mic tracker
(`.scratch/passive-drift-tracking/spec.md`, decisions 1–18) that has never landed a
correct live correction (`/mnt/project-files/bt-sync-version-comparison/report.md` §1–3).

---

## 1. Key findings

### 1.0 The one-paragraph answer

Every system that keeps speakers reliably in sync does it by **owning or observing
the playout clock of every speaker**: Sonos, AirPlay 2, Cast, Snapcast, Roon, Bose
and LE Audio all run firmware at the receiver that timestamps against a shared clock
and resamples locally. Every system that includes a **stock A2DP speaker it does not
control** falls back to one of three things: a constant offset the user sets by ear
(Airfoil, Google Home, SoundSeeder, Roon, Snapcast), a constant the vendor assumes
per device (Google Nest to BT, Bose SimpleSync, PipeWire via AVDTP delay reports), or
nothing (Samsung Dual Audio, JBL/UE party modes across brands, Windows, macOS
Multi-Output). **No shipped product measures a stock Bluetooth speaker acoustically
and then keeps it in sync with network speakers over a session.** Two companies
patented the one-shot acoustic measurement for BT speakers (Tap Sound System 2017,
Clear Peaks), and one shipped phone-mic sync for phones (AmpMe), then retreated to a
device-profile database. Academic work on tracking unsynchronised loudspeakers from
the music itself (Fraunhofer IIS, 2025) needed a four-mic array and a solo
initialisation per speaker. Audiout's design is already further along this road than
any product; the missing pieces are named in §3.

### 1.1 Summary table

"Continuous" means drift or latency changes are followed during playback without the
user. "Stock BT" means an unmodified third-party A2DP speaker.

| System | How speakers are timed | Stock BT? | Accuracy (measured or claimed) | Continuous? | What it does that Audiout does not |
|---|---|---|---|---|---|
| Airfoil (Rogue Amoeba) | Delay-to-slowest; manual per-speaker slider | Yes | None published; RA says sync "may be impossible" when BT fluctuates | No | Nothing on BT; ships Cast+AirPlay+BT in one group today |
| SoundSource 6 | Per-app routing and output groups (aggregate) | Yes | None published | No | Nothing on sync |
| macOS Multi-Output | Aggregate device, resample to clock source | Yes | Rate only; static offset untouched (BT members ~150–250 ms off) | Rate yes, offset no | Nothing useful |
| Sonos | Own clock-sync protocol, timestamped frames, own firmware | No (BT is input only) | Not published | Yes | Owns the DAC clock of every speaker |
| AirPlay 2 | PTP, ~2 s buffered audio | No | Sub-ms class (inferred from shairport-sync's 2 ms drift tolerance) | Yes | Receiver firmware servos to PTP |
| Google Cast / Nest groups | Own sync; ±200 ms manual "group delay correction" | Via a Nest speaker paired to BT | Nest Mini + BT speaker plays ~500 ms early, slider cannot fix | No for BT | Nothing on BT; evidence that a vendor-assumed constant fails |
| Amazon Echo multi-room | Own sync; patents on acoustic drift | No (not verified this session) | Not published | Yes (own devices) | Patented inaudible-sine drift measurement |
| Bose SimpleSync | Bose smart speaker is the A2DP source to a Bose BT speaker; "optimized" models play in sync with video | Only Bose models | Not published | Unknown | Knows the sink's latency because Bose wrote both firmwares |
| Apple Share Audio | iPhone to two AirPods/Beats | Apple chips only | Not published | Unknown | Firmware on both ends |
| JBL PartyBoost / Connect+ | Proprietary relay from one A2DP leader | JBL only | Not published | Inside the relay | One A2DP link feeds N speakers |
| UE PartyUp | Proprietary, up to 150 speakers | UE only | Users report audible delay (iFixit) | Unknown | Same |
| JBL/Sony/others on Auracast | LE Audio broadcast, BAP presentation delay | LE Audio sinks | Receivers render at a shared SDU reference + 20–40 ms | Yes, by the standard | Deterministic latency, synced receivers |
| Samsung Dual Audio | Two independent A2DP links | Yes | No compensation at all; users toggle until it lands | No | Nothing |
| Tempow / "TAP" (Tap Sound System) | Replaced Android BT stack; patent on mic-measured per-speaker latency with server upload | Yes | Not published | One-shot | A crowd latency database (patent claim) |
| Snapcast | NTP-like time sync, timestamped chunks, sample insert/drop | Only as a local client output | "Typically below 0.2 ms" between clients | Yes | Servos every client continuously to its own playout clock |
| shairport-sync | NQPTP, stuffing / soxr | Discouraged | Drift tolerance 2 ms, resync at 50 ms | Yes | Same |
| PipeWire combine-stream | `combine.latency-compensate` delay lines from reported latency; BT latency includes AVDTP delay report | Yes | Only as good as the sink's report | Rate yes (DLL resampler); latency follows report changes | Reads the sink's own delay report |
| Sendspin (Music Assistant) | 2-D Kalman time filter (offset + drift), per-client calibrated `output_delay` | No mention | Not quantified | Yes | Kalman time filter; manufacturer-provisioned output delay |
| Roon RAAT | Clock master zone in pull mode; others push and compensate internally | No | Not published; Android endpoints fail to report clock | Yes | Pull model from the DAC |
| SoundSeeder | Wi-Fi time sync; manual per-device offset, 10 ms steps | Yes, "cannot be guaranteed" | Documents 20–70 ms re-roll per start | No | Nothing |
| AmpMe | Phone mic hears host, server-side matching; later "Predictive Sync" from device profiles | Phones (and their BT speakers) | Not published | One-shot | Device-profile seed database |
| Apple TV Wireless Audio Sync | iPhone mic hears tones from the TV's speaker path | AirPlay speakers | Not published | One-shot | OS-level phone-mic calibration |

### 1.2 Mac host apps

**Airfoil (Rogue Amoeba).** Delay-to-slowest: "Airfoil will delay all playback to
match the highest delay required." Bluetooth is "a variable delay, depending on their
connection, generally not exceeding two seconds." Manual "Sync" sliders in Advanced
Speaker Options; for Bluetooth "Added delay only, up to +1.00s." Their own caveat: "If
a device has a fluctuating amount of latency, these sliders won't be able to correct
things permanently … it may be impossible to sync multiple outputs."
https://rogueamoeba.com/support/knowledgebase/?showArticle=Airfoil-AudioLatency
(also `bt-output-research-2026-08-07.md` §1).
- *Accuracy:* none published. *Continuous:* no.
- *Does what Audiout does not:* nothing on BT timing. It already ships AirPlay + Cast +
  BT in one group; Audiout's Cast path is still being fixed.
- *Borrow:* the honesty. Rogue Amoeba publicly says a constant cannot fix a
  fluctuating link. Audiout's design exists precisely to go past that line; the UX copy
  should say what Audiout does instead ("re-checks after reconnects").

**SoundSource 6.** Per-app routing and custom output groups, which are aggregate
devices under the hood; no timing features (`competitor-parity-research` §2). Nothing
to borrow on sync.

**macOS Multi-Output / aggregate devices.** Drift correction resamples non-master
members to the clock source; it does nothing about static offsets, so a BT member
sits 150–250 ms off (`bt-output-research-2026-08-07.md` §1; Apple:
https://support.apple.com/guide/audio-midi-setup/set-aggregate-device-settings-ams094c7edb4/mac).
PairPods wraps this with no latency handling. *Borrow:* nothing; it confirms rate
correction alone is not sync.

### 1.3 Vertically integrated ecosystems (firmware at both ends)

**Sonos.** Every speaker runs Sonos firmware, disciplines to a group coordinator's
clock and plays timestamped frames (patent family "System and method for synchronizing
operations among a plurality of independently clocked digital data processing
devices", US9195258B2, https://patents.google.com/patent/US9195258B2/en; title only,
claims not read). Bluetooth is an *input* on Move/Roam/Era, never an output to a
foreign speaker. Relevant twist: **Automatic Trueplay uses "microphones built into the
product … and uses the actual music playing rather than special test tones"** and
"automatically re-tunes as you play new content", in Wi-Fi and Bluetooth mode
(https://tech-blog.sonos.com/posts/trueplay-spectral-correction/,
https://support.sonos.com/en-gb/article/automatic-trueplay-tm). That is music-as-probe
in a shipping product, but for spectrum, not timing, and with the mic inches from the
driver. Manual Trueplay uses a periodic tone, ~1/3 s period, 45 s, >150 periods,
averaged while walking, with a per-iPhone-model mic calibration curve.
- *Does what Audiout does not:* owns every playout clock; calibrates each phone model's
  mic.
- *Borrow:* (a) per-phone-model mic response curves, if ProbeKit ever weights by band
  SNR from the phone; (b) the "walk around, average periods" trick for a seat-robust
  one-shot; (c) proof that users accept a mic listening during music when it is framed
  as tuning.

**AirPlay 2.** PTP-disciplined receivers and ~2 s buffered audio (shairport-sync
`AIRPLAY2.md`, https://github.com/mikebrady/shairport-sync/blob/master/AIRPLAY2.md).
shairport-sync corrects past a 2 ms error and hard-resyncs past 50 ms
(`drift_tolerance_in_seconds = 0.002`, `resync_threshold_in_seconds = 0.050`,
https://raw.githubusercontent.com/mikebrady/shairport-sync/master/scripts/shairport-sync.conf).
Its own docs: "Shairport Sync does not work very well with Bluetooth" because of
realtime timing requirements. Audiout already is an AirPlay 2 grandmaster; nothing
missing here.

**Google Cast / Nest groups.** Cast devices sync among themselves; the user gets a
per-device "group delay correction" slider (±200 ms). A Nest speaker can pair to a BT
speaker as its output. Field evidence that a vendor-assumed constant fails: a Nest
Mini paired to a BT speaker played **~500 ms early** against wired Chromecasts, while
a JBL Link with the same BT speaker was ~200 ms late; the slider could not cover it
and the thread ended unresolved
(https://www.googlenestcommunity.com/t5/Speakers-and-Displays/Chromecast-Audio-Group-Bluetooth-Speaker-inverse-delay/m-p/128960;
also
https://www.googlenestcommunity.com/t5/Speakers-and-Displays/Group-Delay-Correction-Bluetooth-Speaker/td-p/77017).
*Inferred:* the Cast firmware pre-compensates BT with a per-platform constant.
- *Does what Audiout does not:* nothing on BT.
- Cast-sender prior art (OwnTone's open-loop mirroring path with an experimentally found
  100 ms start delay, Music Assistant/Sendspin's "set Static playback delay (ms) … by
  hand", MA universal groups explicitly not synced) is in the cast researcher's
  `cast.md` §1.6 and not repeated here. It fits the same pattern: across transports
  nobody closes the loop on a receiver they do not own.
- *Borrow:* the negative lesson. A per-model constant (Audiout's planned seed database)
  must only ever be a *proposal* that a measurement confirms, which matches the
  existing flat-prior fence in `mic-probe-calibration-brief.md`.

**Amazon Echo.** Multi-room music between Echo devices; Bluetooth-paired speakers are,
to my recollection, excluded from multi-room groups (Amazon's help page refused the
fetch; **not verified**). Amazon's patents are the relevant part:
- US9219456B1, "Correcting clock drift via embedded sin waves" (Amazon, 2015): insert
  inaudible sinusoids into the program, detect them in the mic signal, read the phase
  rotation to get the ppm offset; AEC suppression held 22–26 dB with correction vs
  14 dB uncorrected at 40 ppm (https://patents.google.com/patent/US9219456).
- US11336424B1, "Clock drift estimation" (Amazon, 2022): raise the timestamp-exchange
  rate when temperature, CPU, battery or network load suggest crystals will move
  (https://patents.google.com/patent/US11336424).
- *Borrow:* the second one is cheap and directly applicable: schedule extra
  verification windows when a *predictor* says a link is likely to move (for Audiout:
  reconnect, sleep/wake, Game Mode, a second BT device joining, Wi-Fi load), which the
  event-driven cadence (decision 18) already half does.

**Bose SimpleSync.** A Bose smart speaker or soundbar becomes the A2DP *source* for a
Bose Bluetooth speaker or headphones: "connect a Bluetooth speaker or pair of
headphones to play along with your Bose smart speaker" (https://www.bose.com/help/using-groups).
Older SoundLink models are "optimized for audio"; newer ones are "optimized for
SimpleSync" and "play in sync … while listening to audio or watching video" (same
page). Two Bose patents show the machinery:
- US11678005B2 / US12120376B2, "Latency negotiation in a heterogeneous network of
  synchronized speakers": each device reports its processing latency to the master,
  the master picks the maximum and issues a "play at" time; clocks are synced to a
  common reference with updates "every few seconds"
  (https://patents.google.com/patent/US11678005). That is delay-to-worst with
  *reported* latencies.
- US10706872 / US20170069338, "Wireless audio synchronization": master re-timestamps
  packets from a BT source; per-frame time offsets; clock updates every 1–6 s; **an
  ASRC on every device** keeps output rate constant against oscillator drift; latency
  adapts to jitter by comparing send and receive spans (e.g. three 20 ms packets over
  61.2 ms gives a ratio of 1.02 and a 20.4 ms playback period)
  (https://patents.google.com/patent/US10706872B2/en).
- *Inferred:* "optimized for SimpleSync" means the BT speaker's firmware latency is a
  known constant to the Bose source, which is only possible because Bose writes both
  ends.
- *Does what Audiout does not:* trusts reported latency (can, because it owns it);
  ASRC on the sink.
- *Borrow:* the heterogeneous negotiation shape is exactly Audiout's `R = max(...)`
  (the architecture doc's Gap 1 fix is Bose's claim 1 with a measured term in place of
  a reported one). Worth a freedom-to-operate look before marketing it (see §2.4).

**Apple Share Audio (two AirPods/Beats).** Works only with Apple W1/H1/H2-chip
headphones; Apple publishes no mechanism (https://support.apple.com/102526).
*Inferred:* Apple firmware at both ends, so latency is known. Nothing Audiout can
reach from a Mac.

**Spotify Connect.** No multi-device synced playback of its own; the "Connect to
multiple speakers" idea has run to 89+ pages of requests
(https://community.spotify.com/t5/Live-Ideas/Connect-Multiple-Speakers-Devices-simultaneously/idi-p/614088/page/89).
Grouping happens only through Cast groups or Sonos. Relevant only as demand evidence.

### 1.4 Bluetooth party modes and multi-A2DP

**JBL PartyBoost / Connect+, UE PartyUp, Soundcore PartyCast, Sony Party Connect.**
One speaker takes the A2DP stream and relays it to followers over a proprietary link
(older generations on CSR/Qualcomm "Broadcast Audio", built on Connectionless Slave
Broadcast; Qualcomm patent US11375578B2,
https://patents.google.com/patent/US11375578B2/en; the product-to-chip mapping is
**inferred**, not documented by JBL or UE). None interoperate across brands
(https://www.speakerranking.com/multi-speaker-pairing-explained/); JBL's own support
for sync trouble offers only "move closer, restart"
(`bluetooth-precedent.md`). UE PartyUp claimed 50+ then 150 speakers
(https://ir.logitech.com/press-releases/press-release-details/2016/Ultimate-Ears-Turns-the-Party-Up-with-PartyUp/default.aspx);
users report audible delay between Double Up speakers
(https://www.ifixit.com/Answers/View/407261/The+Double+Up+Feature+Still+Has+Sound+Delay.+Why+is+that).
JBL moved its new models to Auracast, not backwards compatible with PartyBoost
(https://www.soundguys.com/goodbye-jbl-partyboost-hello-auracast-134004/).
- *Does what Audiout does not:* feeds N speakers from one A2DP link, so only one link's
  latency re-rolls and 2.4 GHz airtime is one stream.
- *Borrow:* **treat a party-mode group as one sink.** A user with two JBLs in
  PartyBoost/Auracast gives Audiout one A2DP device; Audiout calibrates only the
  leader. The follower's offset to the leader is the speaker vendor's problem and is
  usually within a few ms (**unmeasured**; open question 4.6). This is free and sidesteps
  Audiout's "BT-vs-BT pairs never probe" limitation for same-brand pairs.

**Qualcomm TrueWireless Mirroring / TWS.** Earbuds sync left and right by one bud
sniffing or relaying the other's link. Microsecond-class sync, but only inside one
vendor's chip family
(https://www.qualcomm.com/products/features/truewireless). Nothing for a host.

**Samsung Dual Audio (Android).** Two independent A2DP links, no delay control; users
"uncheck and re-check one speaker until a connection happens to land in sync"
(`bluetooth-precedent.md`;
https://eu.community.samsung.com/t5/other-galaxy-s-series/dual-audio-not-in-sync/td-p/3350639).
It is the baseline of doing nothing, and the per-connection re-roll it exposes is the
same 20–90 ms Audiout measured.

**Tempow / Tap Sound System.** A French startup that replaced the Android Bluetooth
driver to "send music to multiple Bluetooth devices at once", licensed to TCL as the
"Tempow Audio Profile (TAP)", bought by Google in 2021
(https://techcrunch.com/2017/04/30/tempow-turns-your-dumb-bluetooth-speakers-into-a-connected-sound-system,
https://techcrunch.com/2019/09/05/tcl-adopts-tempows-multi-device-bluetooth-streaming-tech,
https://musically.com/2022/03/03/google-four-audio-startups-last-15-months/). The
applicant **Tap Sound System** (Girardier, Goupy, Ruffieux; that it is Tempow's legal
entity is **inferred** from the TAP name and dealroom listing) filed EP3402220A1 (2017),
"Wireless audio system latency determination": send a test signal, have the speaker
play it, record it with a clock-synchronised recorder, compute latency; a second
embodiment compares **two receivers' latency difference, so the recorder's own latency
cancels**; high-frequency edge detection; results "stored locally or uploaded to remote
servers for other devices"; it cites ">20 ms desynchronization can be perceived"
(https://data.epo.org/publication-server/rest/v1.2/patents/EP3402220NWA1/document.html).
- This is the closest prior art to Audiout's BT calibration: the BeepBeep difference
  trick applied to BT speakers from a phone, plus a crowd latency database.
- *Does what Audiout does not:* the server-side per-model database.
- *Borrow:* the database, with the Google Cast lesson attached (proposal only). Risk:
  the patent is now presumably Google's; the EP application's grant status and any US
  family member were **not checked**.

### 1.5 LE Audio and Auracast

**Mechanism.** A broadcast source sends a BIG (Broadcast Isochronous Group). Each
receiver knows the SDU Synchronization Reference (the end of the last BIS in the BIG
event) and renders every SDU a fixed **Presentation Delay** after it. "All Auracast
receivers must be able to complete these tasks within a value of 40ms (the default
defined in BAP)"; HAP/TMAP devices support 20–40 ms
(https://www.bluetooth.com/wp-content/uploads/2024/05/2403_Auracast_Earbuds.pdf;
https://cloud2gnd.com/fundamentals-of-le-audio-broadcast-isochronous-streams/). End to
end, a commercial assistive-listening Auracast system quotes 31 ms
(https://www.listentech.com/audio-latency-in-assistive-listening/).
- This is the first **standard** Bluetooth mechanism in which every receiver, from any
  vendor, renders in lock-step with a known, source-chosen delay. It removes both of
  Audiout's BT problems (unknown latency, per-start re-roll) by construction.
  *Inferred caveat:* the rendering instant is "implementation specific" past the
  presentation point, so a speaker's own DSP (bass extension, lookahead limiter) may
  add a constant; still a constant, not a re-roll.

**Where it ships (Sept 2026).**
- Android 16 "Audio sharing" over Auracast on Pixel and more Android devices
  (https://blog.google/products-and-platforms/platforms/android/le-audio-auracast-support/,
  https://9to5google.com/2025/09/03/auracast-le-audio-sharing-coming-to-pixel/).
- Samsung Galaxy: Auracast broadcast from Settings (`bluetooth-precedent.md`).
- Windows 11 "Shared audio (preview)", LE Audio broadcast to two accessories, Copilot+
  PCs only (https://blogs.windows.com/windows-insider/2025/10/31/extending-bluetooth-le-audio-on-windows-11-with-shared-audio-preview/).
- JBL Flip 7, Charge 6, Xtreme 4 and others as Auracast speakers (SoundGuys above).
- **Apple: no broadcast-source API** through WWDC26 (`bt-output-research-2026-08-07.md`
  §3.5).
- **Workaround that exists today on a Mac:** a USB Auracast transmitter dongle is a
  class-compliant USB audio device, "Auracast happens inside it." The FlooGoo FMA120
  (Qualcomm QCC3086; shows up as "QCC3086 USB Dongle") works on macOS, is configured by
  a vendor app on Mac/Windows/Linux, quotes ~19.5–21.5 ms in LE gaming mode, and its
  maker says multi-stream broadcasts are "precisely synchronized"
  (https://www.flairmesh.com/Dongle/FMA120.html,
  https://aurahear.com/2025/05/review-floogoo-fma120/). An MIT-licensed Mac app already
  drives one (https://github.com/napthemax/auracast-sender).
- *Does what Audiout does not:* deterministic, standard, multi-receiver sync.
- *Borrow:* see §3.3. This is the most concrete route to "every BT speaker in sync,
  every time" that needs no DSP breakthrough.

### 1.6 Open-source multiroom and OS mixers

**Snapcast.** "Each client does continuous time synchronization with the server";
"Time deviations are corrected by playing faster/slower, which is done by
removing/duplicating single samples (a sample at 48kHz has a duration of ~0.02ms)";
"Typically the deviation is below 0.2ms"; ALSA `buffer_time` 80 ms default
(https://github.com/badaix/snapcast/blob/develop/README.md). Bluetooth: open issues
with no maintainer fix (#50 "bluetooth speaker lag", #1117 stutter;
https://github.com/snapcast/snapcast/issues/50,
https://github.com/snapcast/snapcast/issues/1117), manual per-client latency; #476
shows the latency was forgotten after a volume change.
- *Does what Audiout does not:* **servos every output continuously against the rate
  at which that output consumes audio.** Audiout's BT sink, after release, is a plain
  FIFO with no such servo (version report §1 bug 1; architecture doc §5.1). Snapcast
  on a BT client would still carry the wrong static latency, but it would never
  accumulate offset from the device pulling short or long.

**PipeWire combine-stream.** `combine.latency-compensate`: "use delay buffers to match
stream latencies" (module-combine-stream.c line 56). The BT sink reports its latency
as "(packet delay) + (codec internal delay) + (transport delay) + (latency offset)",
where *transport delay* is the AVDTP delay report the sink sent
(`spa/plugins/bluez5/media-sink.c`, `set_latency()`, lines 471–497; it re-emits when
`transport_delay_changed` fires). So Linux is the only mainstream desktop stack that
**automatically** compensates a BT member of a combined output, and it does so by
trusting the sink's self-report. Delay reports are firmware constants
(`bt-latency-stability-research` §1: ESP-IDF default 120 ms, BlueZ shows 149.8 ms on
one sink) and do not include the per-start re-roll. PipeWire's rate matching uses a
DLL-driven adaptive resampler (`bt-output-research` §3).
- *Does what Audiout does not:* reads AVDTP delay reports (macOS does not expose them
  to apps); continuous rate servo per sink.
- *Borrow:* the rate servo idea (§3.1). The delay report itself is unavailable on macOS
  unless it appears in the unified log (open question 4.3).

**Sendspin (Music Assistant, 2025).** Clients "MUST use the time-filter algorithm … a
two-dimensional Kalman filter that tracks both clock offset and drift"; each client
reports a manufacturer-calibrated `output_delay`; no Bluetooth
(https://www.sendspin-audio.com/build/spec/). *Borrow:* a 2-D Kalman (offset + rate) is
a better estimator than a single PI loop when observations are sparse and noisy, which
is exactly Audiout's mic-window regime (few windows per session). See §3.4.

**Roon RAAT.** "For multi-zone, we run in pull mode with the zone that has been
elected as clock master and push to the other zones, which are forced to compensate
for drift internally" by adjusting the clock, stuffing/dropping samples, or ASRC; "there
is no way to force multiple independent clock sources to agree"
(https://community.roonlabs.com/t/raat-and-clock-ownership/6915). Android endpoints
"fail to properly report their clock position", so Roon says it is "not possible to
make them synchronize perfectly every time"
(https://help.roonlabs.com/portal/en/kb/articles/android-grouped-zone-synchronization).
That is the Roon version of Audiout's "the HAL latency is junk" finding.

### 1.7 Phone-app sync (the closest consumer precedent)

**SoundSeeder.** Wi-Fi time sync between phones plus a manual per-device offset in
10 ms steps; for A2DP it says delay "varies between 20ms and 70ms each time you start
your playback … can not be adjusted by adding a constant offset … Synced playback via
Bluetooth speakers can not be guaranteed!"
(https://soundseeder.com/help/using-soundseeder-with-bluetooth-speakers-via-a2dp/).

**AmpMe.** Guest phone's mic hears the host, with "server-centric proprietary audio
matching technology" (`bluetooth-precedent.md`, not verified in detail), later
supplemented by "Predictive Sync" from device profiles (`bt-output-research` §2 item 4).
A related acoustic-sync patent, US11727950B2 (assignee Clear Peaks LLC; not AmpMe),
cross-correlates the RF-received signal with the mic capture after downsampling to
8 kHz and reports the delay in ms, with **no accuracy disclosed**
(https://patents.google.com/patent/US11727950).

**SynBa (ETH Zürich semester thesis, 2015).** Wi-Fi Direct clock sync plus acoustic
sine-tone latency measurement between phones; clock sync ~5 ms std; playback offsets
"below 10 ms"; measured drift ~8 ms per 1000 s (8 ppm), handled by periodic re-sync
(https://pub.tik.ee.ethz.ch/students/2015-FS/SA-2015-02.pdf). A useful floor: an
undergraduate project reaches <10 ms with a one-shot acoustic measurement, which is
where Audiout's one-shot already is.

**Apple TV Wireless Audio Sync.** iPhone mic hears tones through the TV path, one
calibration stored on the Apple TV (`bluetooth-precedent.md`). Also a
microphone-equipped-speaker variant is patented by Waves Audio (US11778409B2): three
calibration sounds (one at the listener, one from each speaker), each device timing
arrivals on its own clock, `Δt = Δt2 − Δt3 − Δt1`, no clock sync or positions needed
(https://patents.google.com/patent/US11778409).

### 1.8 Research: acoustic ranging and delay estimation

**BeepBeep** (Peng et al., SenSys 2007). Two-way sensing: each device records both its
own beep and the peer's and counts **samples** between them, so send/receive latency
and clock offset cancel; 2–6 kHz linear chirp, 50 ms; ~1 cm indoors, ~2 cm outdoors,
~4 m indoor range (multipath-limited); drift "negligible in practice" for short sessions
(https://www.cs.purdue.edu/homes/chunyi/pubs/sensys106-beepbeep.pdf). Audiout's probe
already uses the one-mic, two-arrival half of this.
- *Does what Audiout does not:* the second half. The mic's own latency cancels only if
  both arrivals are in one recording. Audiout's passive tracker instead calibrates the
  Mac mic's offset from an AirPlay arrival (decision 13). With no AirPlay or Cast in the
  room there is no anchor, so every window is relative. BeepBeep says: use the Mac's
  **own built-in speaker** as the anchor lane (a quiet reference in the Mac's output,
  known latency from the HAL, a few cm from the mic). That is already the preferred
  measurement reference (`CompanionSnapshotBuilder.swift:220`) for the probe; it is not
  used as the passive tracker's anchor. See §3.5.

**GCC family** (Knapp and Carter 1976; Cobos et al. 2020; Donohue et al. 2007).
Covered in `drift-tde-algorithms-brief.md`; Audiout ships partial whitening 0.7 and a
sub-band vote (shared 0.15.x).

**Audio watermarks that survive a loudspeaker-to-mic path.**
- Spread-spectrum watermarking with psychoacoustic shaping (Kirovski and Malvar, IEEE
  TSP 2003,
  https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/KirovskiMalvarTSPApr03.pdf).
- A watermark designed for **synchronisation after analog playback** (Nadeau et al.,
  IEEE TIFS 2017): 370 ms blocks, ~5 s segments, survives AAC 8–128 kbps, ODG around
  −0.87 (perceptible, not annoying), 70% correct resynchronisation over 58 tracks
  played through a loudspeaker; detection latency ~1.5 s
  (https://hajim.rochester.edu/ece/sites/gsharma/papers/NadeauAnalogPlaybkAudioWMSynchTIFS2017.pdf).
  Its time resolution is frame-level, not sample-level: good enough to identify
  *which* speaker, not to time it to 1 ms.
- Nielsen's broadcast watermark is decoded through the air by pocket meters in real
  homes at scale (https://en.wikipedia.org/wiki/Portable_People_Meter): proof that a
  masked watermark survives rooms, but for identity, not timing.
- Inaudible tones for clock skew: US8750494B2 inserts a masked tone between fs/4 and
  fs/2 (about 6 kHz at 16 kHz sampling) and counts cycles over 1–2 s to get the
  resampling ratio for an echo canceller (https://patents.google.com/patent/US8750494);
  Amazon's US9219456B1 does the same with phase rotation (above).
- **Watermark for multi-device latency, patented:** InterDigital US20190116395A1 embeds
  a different inaudible identifier in the audio sent to each rendering device, captures
  both with a mic, and derives each device's latency from arrival times; it can run
  "nearly continuously" or every 5 s to 15 min
  (https://patents.google.com/patent/US20190116395A1/en). This is the journey file's
  §5.2 tier 2 almost word for word. **FTO flag**, see §2.4.

**Drift between unsynchronised audio clocks (wireless acoustic sensor networks).**
- DXCP (double cross-correlation processor), online, closed loop: SRO RMSE <0.1 ppm on
  noise, 0.30 ppm on speech, 16 kHz, 128 ms frames, IMC time constant 8 s, ~12.7 s to
  re-acquire after a large SRO change; ASRC by windowed sinc
  (https://arxiv.org/abs/2105.13743).
- Online comparison on real recordings (Raspberry Pis, T60 ≈ 700 ms, packet loss up to
  50%): RMSE RBI 7.29 ppm, WACD 2.19, WACD with sampling-time-offset compensation 0.47,
  DXCP 0.86, DXCP with PHAT 0.45 ppm (EUSIPCO 2021,
  https://eurasip.org/Proceedings/Eusipco/Eusipco2021/pdfs/0001110.pdf).
- These estimate **rate**, sub-ppm, from a minute of speech. Audiout's problem is
  mostly **offset steps** (tens of ms, event-shaped), for which they are the wrong tool.
  BT-to-BT rate drift is closed (≤2 ms over 3 min, ~0 over 30 min after PR #200; lead
  correction, crosstalk 00:49). What stays open is **common-mode** drift of all BT
  speakers against the host/AirPlay: a 9-minute slide of ~1 ms/min (~17–20 ppm) on
  2026-09-14, which matches the Move 2's +21.7 ppm pacing clock and would be ~72 ms/h
  against AirPlay (code researcher, crosstalk item 5). If that is real, it is a rate
  problem these estimators solve, but the cheaper observable is the host pacing clock
  itself (§3.1), not the mic.

**The closest academic analogue: unsynchronised wireless loudspeakers tracked from the
music.** Korse, Walther and Habets (Fraunhofer IIS / AudioLabs Erlangen, 2025),
"Stereo Reproduction in the Presence of Sample Rate Offsets": two wireless loudspeakers
with independent clocks, a primary device with a **4-mic circular array (10 cm
radius)** that isolates each loudspeaker by LCMV beamforming and then runs DWACD against
the original playback signals; tested at (10, −10), (10, −50) and (10, −100) ppm;
needs an initialisation in which **each loudspeaker plays alone**; MUSHRA with 11
listeners: uncompensated SRO damages ITD/IC cues and compensation "significantly
reduces this effect, though it does not eliminate it entirely"
(https://arxiv.org/html/2507.05402). A companion paper does SRO-compensated echo
cancellation from 0.512 s segments, converging for SROs within ±75 ppm, and leaves
"sampling time offset, variable SRO, and packet loss" out of scope
(https://arxiv.org/html/2507.05399v1).
- This is the state of the art for exactly Audiout's continuous goal, and it needed
  (a) a mic array to separate speakers playing the same program and (b) solo
  initialisation. It does not handle offset jumps at all. That is the honest bar.

### 1.9 Patents on BT latency compensation and multi-speaker sync (index)

| Patent | Assignee | Idea | Relevance |
|---|---|---|---|
| US11678005B2, US12120376B2 | Bose | Devices report latency; master takes max, issues play-at time | Same shape as `R = max(...)` |
| US10706872B2 (US20170069338) | Bose | Re-timestamp a BT source over Wi-Fi; ASRC per device; jitter-adaptive latency | Sink-side ASRC Audiout cannot do; source-side equivalent is §3.1 |
| US11282546B2 | Sony | TWS primary measures delay to secondary by ACK round trip /2, updates when it moves past a threshold, reports to source for lip sync (https://patents.google.com/patent/US11282546) | Continuous latency by protocol feedback; not reachable over stock A2DP from macOS |
| TD Commons 6769 (refs US11039411, Google) | Google | Clock drift glitches: drive encoding from the BT controller clock (GPIO/HCI), single clock source, or ASRC (https://www.tdcommons.org/dpubs_series/6769/) | Confirms the host-side pacing clock is the clock that matters at the source |
| US11375578B2 | Qualcomm | CSB burst mode for broadcast audio | Party-mode lineage |
| EP3402220A1 | Tap Sound System | Mic-measured BT speaker latency, two-receiver difference, server upload | Closest prior art to Audiout's BT calibration |
| US11778409B2 | Waves Audio | Three calibration sounds, no clock sync needed | Alternative geometry-free calibration |
| US11727950B2 | Clear Peaks | RF-vs-mic cross-correlation delay | Generic |
| US20190116395A1 | InterDigital | Per-device inaudible watermark + mic → latency, near-continuous | **Directly covers the watermark tier** |
| US9219456B1, US11336424B1 | Amazon | Embedded sines for drift; sensor-predicted drift | Drift measurement; predictive cadence |
| US8750494B2 | (see link) | Masked tone for clock skew in AEC | Drift measurement |
| US9195258B2 | Sonos | Independently clocked devices synchronised | Background; Sonos litigates in this area (`competitor-parity-research` §5 q7) |

---

## 2. Failure modes and gaps (what prior art teaches about reliability)

### 2.1 Every constant fails on stock Bluetooth

Three independent vendors say so in writing (Rogue Amoeba, SoundSeeder, Roon for
Android), and Google shows it by accident (Nest Mini 500 ms early). The cause is the
per-start re-roll and mid-session steps documented in
`bt-latency-stability-research-2026-09-05.md`. Audiout's remembered latency
(`fromLastTime`, ADR 0001) is a constant too; it is safe only because a re-check
follows. **If the re-check does not run or does not land, Audiout is Airfoil.** The
version report says the passive tracker has not landed a correct live correction and
scored below 1 against a gate of 3 in the customer's room
(`bt-sync-version-comparison/report.md`, crosstalk 00:41). So today, in the field,
Audiout is in the "constant" class.

### 2.2 Every system that stays in sync servos each output to that output's consumption

Snapcast (sample insert/drop against the client's playout), shairport-sync (stuffing
past 2 ms), PipeWire (DLL resampler), Roon (slaves compensate internally), Bose (ASRC),
Sendspin (Kalman offset+drift), macOS aggregates (resample to clock source). The
common element is not an acoustic measurement; it is **a closed loop between "audio
the device has consumed" and "time"**, running continuously.

Audiout has that loop for local outputs (`PhaseController`, ±200 ppm) and for AirPlay
(PTP), but **not for Bluetooth**: after release the BT sink "drains at unity rate"
(architecture §5.1) and "each second the device pulls short or long leaves a
permanent offset" (version report bug 1: ~240 ms apart during a 77 s clock-jump storm,
290 ms slow creep). The unmerged fix `ed6f00a` re-seeks once wall-time-since-release
and frames-pulled differ by 20 ms. Prior art says the same loop, but as a **gentle
continuous servo** (resample or single-sample insert/drop, error band of ~2 ms) rather
than a 20 ms threshold and a seek. Note what this loop can and cannot fix:
- It fixes **host-side** divergence: the pacing clock pulling at a rate that is not the
  timebase, stack re-buffers seen as pulls, dropped or doubled callbacks.
- It cannot see anything downstream of the host stack (the speaker's own buffer
  re-centring, a new codec negotiation, Apple warm-up). Only a microphone sees those.
The code researcher also predicts (inferred, needs a 2-minute live test) that after a
long pause the BT ring drains and nothing re-anchors on resume, while AirPlay gets idle
fill (code.md A1/Q1). Prior art handles resume explicitly: shairport-sync hard-resyncs
past 50 ms, Snapcast re-times every chunk against its timestamp. A continuous servo
with a resync threshold covers this case for free.
So prior art splits the problem the same way Audiout's design does (servo continuously
on the observable clock, measure acoustically on events), but Audiout has built the
hard half (acoustic) and left out the easy half (servo).

### 2.3 Continuous acoustic tracking of same-program speakers has never been shown in a real room without special hardware

- Sonos Auto Trueplay: continuous, but spectral, and the mic is on the speaker.
- Korse et al. 2025: continuous rate tracking, but a 4-mic array plus solo
  initialisation per speaker, and rate only.
- Audiout's own live record: three accepted windows within 1 ms at normal level, many
  refused (`HANDOFF.md`); score <1 in a customer room (version report).
- The watermark literature: identity survives rooms (Nielsen, Nadeau 70%), sample-level
  timing through a room from a masked watermark is **not demonstrated** in any source
  found.
Conclusion: "continuous" in Audiout's promise should mean *event-driven re-verification
plus a continuous host-side servo*, not *always-listening acoustic tracking*. The
latter remains research-grade.

### 2.4 Legal and platform gaps

- **Freedom to operate (not legal advice).** InterDigital US20190116395A1 (per-device
  inaudible watermark + mic → latency, near-continuous) and Bose US11678005B2 (latency
  negotiation → max → play-at) read closely onto the journey's watermark tier and the
  architecture doc's Gap 1 fix respectively. Tap Sound System EP3402220A1 reads onto
  mic-measured BT speaker latency with a two-receiver difference. Grant status,
  jurisdiction and claim scope were not checked. Audiout is now a paid product
  (`CLAUDE.md` Paddle section), so the owner should decide whether a patent search is
  warranted before marketing "continuous watermark sync".
- **Platform.** macOS exposes no AVDTP delay report, no codec choice, no LE Audio
  broadcast source, and a HAL latency that is wrong for BT
  (`bt-latency-stability-research` §1; architecture §3.2). Every Linux-side trick that
  reads the sink's report is unavailable.
- **Mic separation.** Prior art that separates same-program speakers acoustically uses
  either a mic array (Korse) or a distinct signal per speaker (watermark, BeepBeep).
  Audiout today uses neither; it relies on prior baselines and the merged-peak rule
  (decision 14).

---

## 3. Options and novel ideas

Ordered by leverage per unit of risk. Each says what prior art it borrows and what is
new.

### 3.1 Continuous host-side servo on every BT sink (borrow: Snapcast, PipeWire, Bose ASRC)

- **What:** after release, compare frames the BT device has pulled against the
  timebase continuously and steer the existing `FractionalResampler` through a
  `PhaseController`-style loop, with a small dead band (shairport-sync uses 2 ms) and a
  seek only past a large threshold (shairport-sync: 50 ms). This is `ed6f00a`'s
  detector with the local-sink loop as the actuator instead of a 20 ms seek.
- **Why:** it is the one mechanism every working system has and Audiout's BT path
  lacks; it directly addresses the 1.2.0 customer's 240 ms and 290 ms failures, which
  were host-side.
- **Feasibility:** high; both halves exist in `SyncCore.swift` (PI loop, ±200 ppm
  resampler). **Risk:** the pacing clock steps during settle (0–42 s on the Move 2);
  the loop must freeze while `BTClockStability` says settling, and treat a step as a
  re-anchor, not as rate (the lesson `bt-output-research` §3 item 3 already wrote down).
  Must not fight the acoustic tracker: the servo owns host-side error, the mic owns
  downstream latency, and they write different variables (servo: resample ratio; mic:
  measured latency).

### 3.2 Per-model latency seed database (borrow: Tap Sound System patent, AmpMe Predictive Sync; counter-lesson: Google Nest)

- **What:** from accepted measurements, aggregate latency by BT vendor ID + product ID
  (not by device name, which users set and which the analytics privacy fence forbids:
  `CLAUDE.md` "Privacy fence") and by codec if the unified log yields it. Ship the
  aggregate in the app; use it only as the wizard's opening proposal, never as the
  applied value without a confirming measurement.
- **Feasibility:** medium; needs an analytics event carrying vendor/product ID and a
  rounded latency, which must first be added to `audiout-shared`
  `docs/analytics-events.md`. Whether VID/PID counts as a "device identifier" under the
  fence is the owner's call. **Risk:** the Nest Mini case shows a model constant can be
  hundreds of ms wrong on a different host platform; macOS numbers must only come from
  macOS measurements. Patent: Tap Sound System's server upload claim (§2.4).

### 3.3 An Auracast lane via a USB transmitter (borrow: LE Audio BAP; FlooGoo FMA120; auracast-sender)

- **What:** treat a USB Auracast dongle as a local Core Audio output with a
  **deterministic** latency: USB + dongle encode + BIG scheduling + presentation delay
  (20–40 ms), identical for every receiver. Audiout would measure it once per dongle
  model and configuration, slave the dongle's USB clock with the existing local-output
  PI loop, and let any number of Auracast speakers join. They render in lock-step with
  each other by the standard; Audiout aligns the group to AirPlay once.
- **What is new:** no product anywhere puts Auracast receivers into a synced group with
  AirPlay (or with anything but other Auracast receivers). Apple offers no Auracast
  source; this bypasses the OS Bluetooth stack entirely.
- **Feasibility:** medium. Audiout's `SyncedLocalSink` path already handles a USB audio
  device (HAL latency is honest for USB, unlike BT). Unknowns: whether the dongle's
  internal buffering is constant across restarts (**measure**, open question 4.1);
  whether consumer speakers (JBL Flip 7, Charge 6) join a third-party broadcast (**not
  verified**; cross-brand interop "not guaranteed", speakerranking above); receiver-side
  DSP constants per model; the dongle's own mode switching re-enumerates the device
  (auracast-sender resolves by name for this reason). **Risk:** small market today
  (needs Auracast speakers and a ~US$50-class dongle, price **unverified**); it is a
  bridge until Apple ships a source API. It does nothing for the owner's existing A2DP
  speakers. Cost to try: one dongle and one Auracast speaker on the desk.

### 3.4 A 2-D Kalman estimator for sparse acoustic observations (borrow: Sendspin time-filter)

- **What:** replace "two agreeing windows then apply" with a per-speaker state
  (latency, latency rate) and covariance, updated by each accepted window and by
  pacing-clock steps as process-noise events. Corrections apply when the posterior is
  confident; a clock step inflates variance and schedules a window.
- **Why:** the observations are few (event-driven, decision 18) and noisy (scores 2.5
  to 4.5). A filter carries evidence across windows properly instead of a fixed
  1.5 ms agreement rule, and gives the "sync health" lamp the journey proposes (§5.3
  there) a principled number.
- **Feasibility:** high, small code; pure math fits ProbeKit's rules or the Mac side.
  **Risk:** tuning without field data; ticket 06/11's field logging is the dataset.

### 3.5 An anchor lane from the Mac's own speaker for passive windows (borrow: BeepBeep)

- **What:** when no AirPlay or Cast arrival is available to calibrate the Mac mic's
  offset (decision 13's anchor), use the Mac's built-in speaker as the anchor. It is
  centimetres from the mic, its latency is honest from the HAL, and it is already the
  preferred probe reference. It need only carry program audio at a low level during a
  window, or be one of the room's outputs anyway.
- **Why:** without an anchor, "everything moved by the same amount" (mic moved) and "one
  speaker moved" are separable only by baselines (decision 8). An anchor makes each BT
  arrival absolute, which is what BeepBeep's two-arrival trick buys.
- **Corroborated by the other researchers:** passive-drift baselines are the model
  (`room + trim`), never an acoustic observation, so the laptop-to-speaker path
  difference (2.9 ms/m) reads as error and can "correct" a seat calibration toward the
  laptop; and a Mac-speakers + one-BT room never runs drift tracking at all because the
  Mac's local output is not an anchor (`NativeBackend+Bluetooth.swift:1189-1191`; journey
  crosstalk items 1 and 4). An honest Mac-speaker anchor fixes the second directly and
  gives the first an absolute reference. Desktop Macs have no built-in mic that
  `BuiltInMicRecorder` accepts (`MicProbeSession.swift:231-252`, journey item 2), so
  this helps laptops only.
- **Feasibility:** medium; the Mac speaker playing during a window is a UX question
  (most users will have it muted when AirPlay speakers are on). **Risk:** the anchor's
  arrival dominates the capture at close range, masking the far speakers; the capture's
  dynamic range and whitening handle ~20 dB, which needs a test.

### 3.6 Per-speaker masked spread-spectrum code (the journey's tier 2) — prior art and numbers

The journey file (`journey.md` §5.2 tier 2) proposes it and computes a 44 dB processing
gain over 4 s. Prior art adds:
- **Nobody has shipped it for timing.** InterDigital patented it for lip sync; Amazon and
  US8750494 used masked tones for **rate**, not offset; Nielsen and Nadeau show
  masked marks survive rooms for **identity** at ODG ≈ −0.87 with 70% success, with
  frame-level (hundreds of ms) not sample-level resolution.
- **Codec survival is the crux.** A2DP SBC/AAC are perceptual coders designed to discard
  what is masked; Nadeau's mark survived AAC 8–128 kbps only because it was designed
  with magnitude-only embedding at a deliberately perceptible level. A pseudo-noise code
  meant for sub-ms timing needs phase fidelity, which a coder is freer to destroy below
  threshold. **Inferred:** expect to run the code at or slightly above the masking
  threshold, i.e. a faint hiss in quiet passages, which the owner has ruled out
  (decisions 1 and 7).
- **Recommendation:** keep it opt-in and experimental, as journey suggests, and test
  code survival through SBC and AAC offline first (encode with a reference coder,
  decode, correlate) before any live trial. Flag the InterDigital patent to the owner
  before building.

### 3.7 Use the MacBook's microphone array for spatial separation (borrow: Korse et al. 2025)

- **What:** MacBooks have a three-mic array. If Core Audio exposes the raw channels
  (unknown; the built-in input usually presents a processed channel), beamforming toward
  each speaker's direction separates arrivals that share a program, the one thing
  Korse et al. needed and Audiout lacks.
- **Feasibility:** low to unknown. Open question 4.4. **Risk:** Apple's voice processing
  may not be bypassable; `.measurement` mode "uses the primary microphone on multi-mic
  devices" (`stage-beat-feasibility-research-2026-09-13.md:247`), which suggests the
  array is not exposed in that mode.

### 3.8 Predictive re-check scheduling (borrow: Amazon US11336424)

- **What:** add predictors to decision 18's triggers: a second BT device connecting
  (2.4 GHz airtime), Game Mode toggling (70–90 ms steps, thread 764070), wake from
  sleep, Wi-Fi throughput spikes, 20–30 min after connect (the Apple warm-up window).
- **Feasibility:** high, cheap. **Risk:** more mic-light events; rate-limit as the clock
  step trigger is.

### 3.9 Party-mode groups as one sink (borrow: JBL/UE relays, Auracast relays)

- **What:** document and support "put your two JBLs in PartyBoost/Auracast and select
  the leader in Audiout." One A2DP link, one latency to track.
- **Feasibility:** high, zero code, needs one live check of leader-to-follower offset.
  **Risk:** vendor relays add their own delay to followers (the UE Double Up
  complaint); if it is above ~10 ms the pair smears
  (`bt-latency-stability-research` §3).

### 3.10 What has never been done (the market gap), with honest feasibility

**The gap:** a host application that takes *arbitrary, unmodified* Bluetooth speakers,
the kind people already own, and keeps them in sync with network speakers (AirPlay,
Cast) and the computer's own output **for a whole session, without the user
re-tuning**, and **verifies acoustically** that they are in sync. Every product in §1.1
either owns the speaker firmware, assumes a constant, asks the user, or does nothing.
Tempow and AmpMe got closest and stopped at a one-shot measurement on phones.

**What is feasible now (build, high confidence):**
1. One-shot acoustic calibration to about ±1–3 ms. Proven by BeepBeep (cm-level), by
   Audiout's own converging runs (+242.7 → −25.4 → −0.1 ms at confidence 1668–3425,
   `handoff-2026-09-03-bt-airplay-alignment-blockers.md`), and by the ETH thesis (<10 ms).
2. Keeping it through the session on the host side: the continuous servo (§3.1). Every
   working system has it.
3. Catching event-shaped jumps: reconnect, silence→audio, clock steps, predicted events
   (§3.8), each followed by a short acoustic verification that the design already has.
   The keep-alive (decision 4) prevents the most common one.
4. Being honest in the UI when verification fails: the journey's sync-health lamp.

Items 1–4 together would already be a first: no product combines them. Estimated
accuracy: 1–5 ms after a verified check, with excursions up to one event's size
(10–90 ms) until the next verification lands (seconds when the mic hears the room,
indefinitely when it does not).

**What is feasible with new hardware (build, medium confidence):** the Auracast lane
(§3.3). Deterministic latency and µs-class receiver sync make "every speaker in sync,
every time" true by construction for LE Audio speakers. Nobody has combined Auracast
with AirPlay in one synced group. Main uncertainty: third-party speaker interop.

**What is still research (do not promise):** always-on acoustic tracking of several
same-program speakers from one laptop mic at normal listening level. The only
published demonstration needed a mic array and solo initialisation and tracked rate,
not offset jumps; the watermark route runs into codecs and the owner's audibility
rule; Audiout's own passive tracker has not closed the loop live. Frame it as a
long-term track fed by the field logs (ticket 06), not a launch claim.

---

## 4. Open questions (need a live test or the owner)

1. **Auracast dongle constancy.** With an FMA120 (or similar) on the Mac: is the
   end-to-end latency to a receiver the same across 20 restarts (spread in ms)? Do a
   JBL Flip 7 / Charge 6 join its broadcast? Receiver-to-receiver offset between two
   different brands?
2. **Owner: FTO.** Commission a patent check on InterDigital US20190116395A1 (watermark
   tier), Bose US11678005B2 (delay-to-worst with negotiated latency) and Tap Sound
   System EP3402220A1 (mic-measured BT latency) before marketing claims?
3. **Delay reports on macOS.** Does `bluetoothaudiod` log the sink's AVDTP delay report
   in the unified log on connect? If yes, it is a free per-connection prior that PipeWire
   already trusts. `log stream --predicate 'process == "bluetoothaudiod"'` during a
   connect answers it.
4. **Mic array.** Does any Core Audio or AVAudioSession configuration on a MacBook
   expose more than one raw built-in mic channel?
5. **Servo vs acoustic split.** With the §3.1 servo running, how much of the 1.2.0
   customer's drift remains? (Replay the logged storm as `ed6f00a`'s test did, then a
   live listen on two Moves.)
6. **Party-mode followers.** Leader-to-follower offset for PartyBoost, PartyUp and a JBL
   Auracast pair, measured with the existing probe (leader as reference lane is not
   possible in one fan-out, so use the Mac speaker as reference and measure each
   separately).
7. **Seed DB and the privacy fence.** May an analytics event carry BT vendor/product ID
   plus a rounded latency? Owner ruling.
8. **Watermark survival offline.** Before any owner reversal of decisions 1/7: encode a
   masked PN code with reference SBC and AAC encoders at A2DP bitrates and measure the
   correlation peak loss. Pure offline test, no hardware.

---

## Sources (external, consolidated)

Products: https://rogueamoeba.com/support/knowledgebase/?showArticle=Airfoil-AudioLatency ·
https://support.apple.com/guide/audio-midi-setup/set-aggregate-device-settings-ams094c7edb4/mac ·
https://tech-blog.sonos.com/posts/trueplay-spectral-correction/ ·
https://support.sonos.com/en-gb/article/automatic-trueplay-tm ·
https://github.com/mikebrady/shairport-sync/blob/master/AIRPLAY2.md ·
https://raw.githubusercontent.com/mikebrady/shairport-sync/master/scripts/shairport-sync.conf ·
https://www.googlenestcommunity.com/t5/Speakers-and-Displays/Chromecast-Audio-Group-Bluetooth-Speaker-inverse-delay/m-p/128960 ·
https://www.googlenestcommunity.com/t5/Speakers-and-Displays/Group-Delay-Correction-Bluetooth-Speaker/td-p/77017 ·
https://www.bose.com/help/using-groups · https://support.apple.com/102526 ·
https://community.spotify.com/t5/Live-Ideas/Connect-Multiple-Speakers-Devices-simultaneously/idi-p/614088/page/89 ·
https://www.soundguys.com/goodbye-jbl-partyboost-hello-auracast-134004/ ·
https://www.speakerranking.com/multi-speaker-pairing-explained/ ·
https://ir.logitech.com/press-releases/press-release-details/2016/Ultimate-Ears-Turns-the-Party-Up-with-PartyUp/default.aspx ·
https://www.ifixit.com/Answers/View/407261/The+Double+Up+Feature+Still+Has+Sound+Delay.+Why+is+that ·
https://www.qualcomm.com/products/features/truewireless ·
https://eu.community.samsung.com/t5/other-galaxy-s-series/dual-audio-not-in-sync/td-p/3350639 ·
https://techcrunch.com/2017/04/30/tempow-turns-your-dumb-bluetooth-speakers-into-a-connected-sound-system ·
https://techcrunch.com/2019/09/05/tcl-adopts-tempows-multi-device-bluetooth-streaming-tech ·
https://musically.com/2022/03/03/google-four-audio-startups-last-15-months/ ·
https://github.com/badaix/snapcast/blob/develop/README.md ·
https://github.com/snapcast/snapcast/issues/50 · https://github.com/snapcast/snapcast/issues/1117 ·
PipeWire `src/modules/module-combine-stream.c`, `spa/plugins/bluez5/media-sink.c` (master, fetched 2026-09-26) ·
https://www.sendspin-audio.com/build/spec/ ·
https://community.roonlabs.com/t/raat-and-clock-ownership/6915 ·
https://help.roonlabs.com/portal/en/kb/articles/android-grouped-zone-synchronization ·
https://soundseeder.com/help/using-soundseeder-with-bluetooth-speakers-via-a2dp/ ·
https://pub.tik.ee.ethz.ch/students/2015-FS/SA-2015-02.pdf

LE Audio: https://www.bluetooth.com/wp-content/uploads/2024/05/2403_Auracast_Earbuds.pdf ·
https://cloud2gnd.com/fundamentals-of-le-audio-broadcast-isochronous-streams/ ·
https://www.listentech.com/audio-latency-in-assistive-listening/ ·
https://blog.google/products-and-platforms/platforms/android/le-audio-auracast-support/ ·
https://9to5google.com/2025/09/03/auracast-le-audio-sharing-coming-to-pixel/ ·
https://blogs.windows.com/windows-insider/2025/10/31/extending-bluetooth-le-audio-on-windows-11-with-shared-audio-preview/ ·
https://www.flairmesh.com/Dongle/FMA120.html · https://aurahear.com/2025/05/review-floogoo-fma120/ ·
https://github.com/napthemax/auracast-sender

Research: https://www.cs.purdue.edu/homes/chunyi/pubs/sensys106-beepbeep.pdf ·
https://arxiv.org/abs/2105.13743 ·
https://eurasip.org/Proceedings/Eusipco/Eusipco2021/pdfs/0001110.pdf ·
https://arxiv.org/html/2507.05402 · https://arxiv.org/html/2507.05399v1 ·
https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/KirovskiMalvarTSPApr03.pdf ·
https://hajim.rochester.edu/ece/sites/gsharma/papers/NadeauAnalogPlaybkAudioWMSynchTIFS2017.pdf ·
https://en.wikipedia.org/wiki/Portable_People_Meter

Patents: https://patents.google.com/patent/US11678005 · https://patents.google.com/patent/US12120376 ·
https://patents.google.com/patent/US10706872B2/en · https://patents.google.com/patent/US11282546 ·
https://www.tdcommons.org/dpubs_series/6769/ · https://patents.google.com/patent/US11375578B2/en ·
https://data.epo.org/publication-server/rest/v1.2/patents/EP3402220NWA1/document.html ·
https://patents.google.com/patent/US11778409 · https://patents.google.com/patent/US11727950 ·
https://patents.google.com/patent/US20190116395A1/en · https://patents.google.com/patent/US9219456 ·
https://patents.google.com/patent/US11336424 · https://patents.google.com/patent/US8750494 ·
https://patents.google.com/patent/US9195258B2/en
