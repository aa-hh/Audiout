# Bluetooth latency stability and audible offset thresholds — research, 2026-09-05

Three questions for the remembered-offset decision: how much A2DP output latency
changes between reconnects of the same speaker, how much it moves within one session,
and how big an offset between two speakers in one room a normal listener hears. Primary
sources only; forum posts are marked as hearsay. Internal measurements are cited, not
repeated: `dev/notes/bt-spike-findings-2026-08-07.md` (Sonos Move 2 and Sony WH-1000XM3
pacing-clock traces) and `dev/notes/sync-sheet-wait-discovery-2026-09-04/synthesis.md`
line 30 (AirPods warm-up, SoundSeeder re-roll claim).

## 1. Across reconnects of the same speaker

**No published per-reconnect distribution exists for one speaker on one host.** Nobody
(vendor, lab, or OS) publishes "connect N times, measure each". The closest datasets
measure repeated playbacks, which is the same event from the sink's side (fresh buffer
fill at stream start).

- **SoundGuys 2019 (measured, Android)**: 100 runs per phone per codec, four phones,
  one receiver, 2,800 data points, WALT + Teensy timing. Means: SBC 308 ms, aptX 316,
  LDAC 324, AAC 369. Run-to-run spread ("variance" in their wording): aptX 25.7 ms, SBC
  41.9 ms, AAC 45 ms average with 90 ms on the OnePlus 6T and Galaxy S10. Pixel 3 XL:
  244 ms mean and the smallest spread; Huawei Mate 20 Pro 484 ms mean.
  https://www.soundguys.com/android-bluetooth-latency-22732/
  The spread happens inside a fixed codec, so codec choice moves the mean by tens of ms
  but does not explain the per-run scatter.
- **SoundSeeder docs (vendor claim, verified at source)**: "On most speakers this delay
  varies between 20ms and 70ms each time you start your playback." "This means that the
  playback of your speakers can not be adjusted by adding a constant offset." "Synced
  playback via Bluetooth speakers can not be guaranteed!" No method given.
  https://soundseeder.com/help/using-soundseeder-with-bluetooth-speakers-via-a2dp/
  Their sync page separately says a tuned offset "will be saved for further connections"
  and to walk it in 10 ms steps after a ±100 ms probe.
  https://soundseeder.com/help/sync-playback/
- **Rogue Amoeba (Airfoil KB)**: Bluetooth is "a variable delay, depending on their
  connection, generally not exceeding two seconds"; "If a device has a fluctuating amount
  of latency, these sliders won't be able to correct things permanently"; the per-speaker
  adjustment is "a constant latency adjustment, and [is] remembered between launches".
  https://rogueamoeba.com/support/knowledgebase/?showArticle=Airfoil-AudioLatency
- **Apple's own stack changes latency per connection state** (Apple Developer Forums,
  developer measurements, not Apple statements):
  - Thread 679274: AirPods measured 215–220 ms right after connecting, falling to
    155–160 ms after 20–30 min; if already used for a while before measuring, it starts
    near 180 ms and still falls. "It feels like bluetooth connection needs to 'warm up'".
    https://developer.apple.com/forums/thread/679274
  - Thread 764070: `kAudioDevicePropertyLatency` "seems to always report 160ms for
    AirPods" while system logs during Game Mode show "latency 151MSec" then "Request JBL
    Down by 81Msec" then "latency 60MSec", with "audio delivery speed ... multiplier
    1.100000" (the stack shortens the buffer by playing 10% fast). The reported property
    does not follow. https://developer.apple.com/forums/thread/764070
  - Apple support: "Game Mode doubles the Bluetooth sampling rate, which reduces input
    latency and audio latency for wireless accessories like game controllers and
    AirPods." https://support.apple.com/en-us/105118
  Net: on Apple's stack the same device can sit anywhere in roughly 60 to 220 ms
  depending on how long the link has been up and what mode the OS is in.
- **Where the number comes from** (so what can re-roll): SEARAN's SBC breakdown puts
  source-side sampling plus encode at about 3 ms (48 kHz) to 9 ms (16 kHz), air time at
  one 0.625 ms slot, and blames the rest on sink buffers: a 1 kB buffer is 5.3 ms at
  48 kHz, 2 kB at 16 kHz is 32 ms; "some Bluetooth speakers have higher latency not
  because of SBC codec they use but ... much larger audio buffers than they should".
  https://searanllc.com/audio-latency-using-sbc-codec/
  ESP-IDF's sink API: "The delay value of sink is caused by buffering (including protocol
  stack and application layer), decoding and rendering", default 120 ms, refuses smaller.
  https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/bluetooth/esp_a2dp.html
  Google's Oboe note for Android: "Android itself has a latency between 30-100 ms. Most
  of the latency comes from buffering on various headsets."
  https://github.com/google/oboe/wiki/TechNote_BluetoothAudio
  Codec algorithmic delay is small: "SBC, aptX and aptX HD ... about 3-6 ms"; AAC and
  LDAC more (Habr survey, secondary). https://habr.com/en/articles/456182/
  So the per-connection number is mostly the sink's start-of-stream buffer fill, which is
  what SoundSeeder's 20–70 ms and SoundGuys' 26–90 ms spreads are measuring.
- **What macOS negotiates**: Apple documents nothing. Apple devices offer SBC and AAC
  (developer forum reply, hearsay: https://developer.apple.com/forums/thread/660855).
  Apple's Bluetooth Explorer (Additional Tools for Xcode) exposed "Enable AAC" and "Force
  use of aptX" options (how-to guides, e.g. https://www.howtogeek.com/425605/how-to-force-macos-to-use-the-aptx-or-aac-codecs-for-bluetooth-headphones/);
  user reports say aptX was removed and the switches stopped working from Monterey
  (MacRumors forum, hearsay), and that AAC-capable devices sometimes get SBC (Apple
  Community threads 250137744 and 256151211, hearsay). Whether the choice is stable
  across reconnects of one device is not documented anywhere found; the only way to know
  is to read the `bluetoothaudiod` codec line from the unified log per connection.
- **AVDTP Delay Reporting** exists (AVDTP 1.3, signal `AVDTP_DELAY_REPORT` 0x0D). In
  BlueZ the value is printed as `delay / 10 . delay % 10 ms`, i.e. units of 0.1 ms, and
  the sink sends it when the stream reaches the configured state.
  https://android.googlesource.com/platform/external/bluetooth/bluez/+/5f8a274%5E!/
  BlueZ 5.82 debug shows a real sink value of 1498 (149.8 ms); 5.83 regressed the feature.
  https://github.com/bluez/bluez/issues/1541
  PipeWire 1.3.81 and 1.4.0 changelogs: "Delay reporting in A2DP sources was improved",
  "Delay reporting and configuration in Bluetooth was improved".
  https://raw.githubusercontent.com/PipeWire/pipewire/master/NEWS
  Support is "many headphones, Android 9+ and Linux with PulseAudio 12.0+" (Habr,
  secondary). The number a sink reports is a firmware constant (the ESP-IDF API is a
  set-once value), not a live measurement; no dataset comparing reported to measured
  latency was found. macOS exposes no delay-report value to apps; CoreAudio reports a
  fixed 160 ms for AirPods (thread 764070 above). The Bluetooth SIG spec text itself is
  behind registration and was not fetched; the units and trigger above come from the
  BlueZ implementation.

**Answer to Q1**: latency is neither fixed per device+codec nor freely re-rolled. The
mean is set by the sink's buffer design (and shifts by tens of ms with codec); each
stream start lands somewhere in a 20 to 90 ms band around it (SoundSeeder 20–70,
SoundGuys 26–90 by codec and phone); on Apple's stack there is an additional slow
warm-up of about 60 ms over 20–30 min plus mode-driven steps of 70–90 ms. No source
gives a shape for the distribution.

## 2. Within one session

- **Internal, cite**: Sonos Move 2 pacing clock: 32 re-anchor jumps of ±5–100 ms in the
  first 42 s, net minus 353 ms, then pinned within 0.01 ms (+21.7 ppm). Sony WH-1000XM3:
  zero jumps, +0.4 ppm over 118 s (`bt-spike-findings-2026-08-07.md`). AirPods 220 to
  160 ms over 20–30 min (`sync-sheet-wait-discovery-2026-09-04/synthesis.md` line 30,
  source thread 679274 above).
- **Reported-latency wobble**: "within 1 min, the latency can change from 193ms to
  260ms" (iOS `AVAudioSession.outputLatency`, developer measurement, hearsay-grade).
  https://developer.apple.com/forums/thread/126277
- **OS-driven steps**: Apple's Game Mode path moves target latency by 70–90 ms and slews
  at 1.1x speed (thread 764070). Android's controller can resize the A2DP buffer live:
  the HCI vendor spec lists "dynamic audio buffer in the Bluetooth controller" with
  per-codec masks, "to reduce audio glitching by changing the audio buffer size".
  https://source.android.com/docs/core/connect/bluetooth/hci_requirements
  Both are latency steps mid-session with no notification to the app.
- **Sniff mode**: Bluetooth SIG white paper: latency is "imposed by the sniff interval";
  a missed anchor makes the slave "wait another full sniff interval"; the worked example
  puts a sensible interval at 80–100 ms.
  https://www.bluetooth.com/wp-content/uploads/2019/03/Sniff-and-Sniff-Sub-rating-Modes_WP_V10.pdf
  Silicon Labs AN986: with sniff during A2DP "clipping is more likely".
  https://www.silabs.com/documents/public/application-notes/AN986.pdf
  Sniff matters at stream start and after silence, not during steady streaming.
  Linux shows the shape: PipeWire suspends the A2DP transport after silence and the
  first sounds after that arrive late or are lost (blueman issue 2976).
  https://github.com/blueman-project/blueman/issues/2976
- **Sink clock recovery**: the A2DP link is asynchronous; the sink buffers and consumes
  on its own clock and must drop or insert samples when the source clock differs (typical
  spread about 100 ppm). Sink buffers are commonly 150–200 ms (Google Technical
  Disclosure "Eliminating Bluetooth Audio Glitches Caused by Clock Drift", seen only
  through a search excerpt; the PDF did not fetch, so treat the 150–200 ms as unverified).
  This is the mechanism behind the Move 2's early jumps: the sink re-centres its buffer
  until its recovery loop locks.
- **Packet loss**: retransmission delays a packet but the sink plays from its buffer, so
  loss shows up as a dropout or a re-buffer, not a lasting offset change. No paper with
  step magnitudes was found.

**Answer to Q2**: after settle, the two internal traces show either no movement (XM3)
or sub-0.1 ms pinning (Move 2). Movement within a session comes from discrete events:
sink buffer re-centring in the first tens of seconds (up to hundreds of ms net), OS mode
changes (70–90 ms), stream restart after silence (a fresh 20–90 ms roll), and the Apple
warm-up (about 60 ms over 20–30 min). Frequencies are not published; our own data says
once at start for one speaker and never for the other.

## 3. What offset between two speakers is audible

- **Summing localisation, under 1 ms**: both arrivals form one image whose direction is
  between the speakers; "at very brief delays of <1 ms and especially <0.5 ms, listeners
  tend to perceive a fused image intermediate to the lead and lag" (Brown, Stecker,
  Tollin 2015 review, Trends in Hearing). https://pmc.ncbi.nlm.nih.gov/articles/PMC4310855/
  Blauert, Spatial Hearing (MIT Press) is the standard reference for the 1 ms boundary.
- **Localisation dominance, about 1 to 10 ms**: the image snaps to the earlier speaker;
  "localization dominance extends from 400 μs to ~10 ms" (same review). An offset in this
  band is heard as the pair collapsing onto whichever speaker is early.
- **Fusion breaks (echo threshold)**: Wallach, Newman and Rosenzweig 1949: fusion up to
  1–5 ms for clicks and up to about 40 ms for speech and music
  (https://pubs.aip.org/asa/jasa/article/21/4_Supplement/468/621106/A-Precedence-Effect-in-Sound-Localization;
  figures as reported in the Wikipedia summary, original behind paywall). The 2015 review:
  click fusion thresholds 4–7 ms for four of six subjects; realistically decaying piano
  tones 15–26 ms; longer for running speech and music. Litovsky, Colburn, Yost and Guzman
  1999 (JASA 106:1633, https://pubs.aip.org/asa/jasa/article-abstract/106/4/1633/557441/The-precedence-effect)
  is the reference review; its PDF was not reachable, numbers above are via the 2015 review
  that restates it.
- **Haas 1951/1972** (speech): a reflection 5–35 ms late can be up to 10 dB louder than
  the direct sound without being heard as a separate event; delayed sound is heard as an
  echo above roughly 30–50 ms depending on signal (DPA dictionary gives 5–7 dB and
  32–50 ms; the AES reprint is JAES 20(2):146–159,
  https://aes2.org/publications/elibrary-page/?id=2093; the dictionary is
  https://www.dpamicrophones.com/dict/haas-effect/). SFU handbook: suppression up to
  about 40 ms, echo at 40–50 ms.
  https://www.sfu.ca/sonic-studio-webdav/handbook/Precedence_Effect.html
- **Comb filtering / colouration** (Brunner, Maempel, Weinzierl, AES 122nd Convention
  2007, paper 7047): delays 0.1–15 ms, three stimuli, trained listeners, 3-AFC adaptive.
  Colouration audible with the delayed copy 20 dB below the direct sound. Minimum
  threshold at 0.8 ms: 18.2 dB level difference for snare, 13.2 dB for piano, single
  listeners 27 dB and 21.5 dB. Speech threshold rises with delay and was still 16 dB at
  15 ms (no minimum found below 15 ms). Best audible at 0.5–3 ms for broadband content.
  https://www2.users.ak.tu-berlin.de/akgroup/ak_pub/2007/Brunner%20Maempel%20Weinzierl%202007_On%20the%20audibility%20of%20comb%20filter%20distortions%20TMT.pdf
  Two speakers at equal level are 0 dB apart, so by these numbers colouration is audible
  at every offset in 0.1–15 ms (in practice each listener's seat already has a path
  difference; the offset moves the notches, it does not create them).
- **Onset asynchrony and order** (Hirsh 1959, JASA 31:759): about 2 ms onset difference
  is detectable as not simultaneous; about 17–20 ms is needed to say which came first.
  https://pubs.aip.org/asa/jasa/article-abstract/31/6/759/617964/Auditory-Perception-of-Temporal-Order
  (numbers via https://hearinghealthmatters.org/pathways-society/2023/temporal-ordering-hirsh-revisited/).
- **Flam**: Wessel and Wright 2001 (NIME): "Timbral changes in the flams begin to become
  audible when the variations in the time between the grace note and the primary note
  exceed 1 ms"; percussionists control that gap to under 1 ms; they set 10 ms as the
  upper bound on acceptable latency and 1 ms on jitter.
  https://arxiv.org/pdf/2010.01570
  The often-quoted "30 ms flam threshold" has no primary source found; the drumming term
  describes a grace note intentionally 10–30 ms early, which lines up with the
  localisation-dominance to click-echo band above, not with a measured threshold.
- **Time offset audibility, aggregate** (for two equal-level speakers in one room):
  - under 1 ms: image shifts between speakers, comb notches move; not heard as "two".
  - 1–10 ms: image collapses onto the earlier speaker; colouration; still one event.
  - 10–40 ms: transients thicken (clicks separate from about 5–10 ms, piano 15–26 ms);
    listeners hear order from about 20 ms; speech still fused.
  - above 40–50 ms: separate echo on speech; music later still.

## Recommendation

On reconnect, apply the remembered per-speaker offset immediately and re-check once
the link has settled (the spike's jump-free gate), then replace or keep. The remembered
number is the best estimate available: the same speaker on the same host lands within
a 20 to 90 ms band of its last value (SoundSeeder, SoundGuys), which is far closer than
the 100 to 400 ms brand spread, and discarding it means starting from the wrong hundred.
Mark it stale when the re-measured offset disagrees by 10 ms or more: below 10 ms the
pair is still one auditory event whose image merely pulls toward one speaker (summing
and localisation-dominance windows, Hirsh's 2 ms onset threshold is well inside the
comb-filter band that exists at any offset anyway), 10 ms is the by-ear step SoundSeeder
documents and the spike adopted, and above 10 ms transients begin to separate; treat a
disagreement over 40 ms as certainly stale and worth telling the user (speech echo
threshold). Keep the old value when the disagreement is under 10 ms so the number does
not churn. Unknown: the actual per-reconnect spread on macOS for any given speaker,
whether macOS keeps the same codec across reconnects, how often the Apple warm-up and
mode steps occur on a Mac rather than iOS, and what any sink's delay report says. All
four are measurable without anyone's help: on every Bluetooth connection log the speaker
identifier, the codec line from the `bluetoothaudiod` unified-log entry, the pacing-clock
jump count and time-to-settle, and the settled probe offset; after twenty connections of
the owner's Move 2, XM3 and JBL Flip 5 the spread and the staleness rate are known
numbers instead of a vendor's "20 to 70".
