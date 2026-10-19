# Shared context: nicer-sounding sync stimulus for the Audiout wizard

Owner's complaint (2026-10-06): the two high-pitched sounds the sync wizard plays are unpleasant and a bad first impression. Sonos's room tuning plays a soft "whoosh". Find every realistic alternative and its limits.

## What the wizard plays today (from source, read these files, do not guess)

Repo (Mac app worktree): /Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/wizard-sync-tone-research-000c03
Shared DSP package: /Users/alechenderson/Projects/audiout-shared

Two separate stimuli, both heard by the user in one wizard run:

1. MIC PROBE (automatic measurement, played first). Two 1.0 s exponential sine sweeps (Farina), played SIMULTANEOUSLY on two lanes, recorded by the Mac's built-in mic or the iPhone's mic, matched-filtered, arrival DIFFERENCE = offset.
   - Reference/Mac lane: DOWN sweep 2000 -> 500 Hz. Bluetooth lane: UP sweep 3200 -> 10000 Hz. 80 ms raised-cosine fades. Amplitude 0.175 full scale (-6 dB from original; the near Mac lane another x0.5).
   - Why disjoint bands: the mic is inches from the Mac speaker and metres from the BT speaker (23 dB imbalance measured). Opposite sweep directions on a shared band only separate ~33 dB; disjoint bands measured -134 dB. A guard gap between bands is required.
   - Why 500 Hz-10 kHz: small speakers roll off low; A2DP codecs (SBC/AAC) roll off 14-18 kHz unpredictably.
   - Why the BT lane is high: room noise floor 12 dB lower above 3 kHz.
   - Confidence = weaker lane's peak-to-sidelobe ratio; SNR-weighted correlation (ambient spectrum division), not PHAT. Reverb shadow after the peak excluded from sidelobe search.
   - Code: audiout-shared Sources/ProbeKit/SyncProbeCorrelator.swift (synthesis + correlator), ProbeAnalyzer.swift; Mac staging in AudioutCore/Sources/AudioutCore/AlignmentTickInjector.swift (stageProbe, ~line 380-490, constants probeSweepSeconds=1.0, probeLeadSeconds=0.5, probeStaggerSeconds=2.0, probeAmplitude=0.175).
   - Design history: dev/notes/mic-probe-calibration-brief.md; audiout-shared docs/adr/0001-quieter-sweeps.md (fade 10->80 ms, level -6 dB, judged by a live listen).
   - Hard constraint: the phone app recreates the sweep locally from the same ProbeKit code; a stimulus change ships as a package tag to both apps. That is fine, just note it.
   - Hard constraint: the measurement rides the device's own volume, nothing normalises level.

2. BY-EAR TICKS (confirmation step / fallback questionnaire). A metronome of 30 ms clicks: two decaying sine partials 0.7 sin(f1) + 0.3 sin(f2), tau = 6 ms, 8-sample attack, amplitude 0.35. Bluetooth side "bright" 1800 + 2900 Hz; Mac/AirPlay side "low" 900 + 1450 Hz, loudness matched by A-weighting. 20 BPM search, 72 BPM blocks. The user judges which side sounded first (temporal order judgement), so sharp identical onsets matter. Existing brief: dev/notes/wizard-tick-stimulus-brief.md (read it; it already argues the two timbres should differ only in colour, not shape).

Also relevant: dev/notes/wizard-stage-v2-spec.md, dev/notes/bt-sync-handoff-2026-10-04.md (the wizard is live and used with real Sonos Move speakers). The passive drift tracker (ProbeKit PassiveDriftCorrelator) tracks drift from the music itself later; it is NOT the wizard stimulus and is out of scope.

## Fixed constraints every proposal must respect
- Bluetooth A2DP path: SBC or AAC lossy codec, 14-18 kHz roll-off, 100-300 ms latency, plays whatever PCM the Mac sends. AirPlay path is lossless ALAC.
- Two speakers must be measurable from one mic at once (or staggered by 2 s, the existing `staggered` shape) with up to ~25 dB level imbalance between lanes.
- Timing accuracy wanted: a few ms (the blend bar is +/-6 ms). Resolution of a correlation peak ~ 1/bandwidth, so a narrow-band pleasant signal costs accuracy; quantify that trade.
- Room noise, reverb, small speakers, user volume unknown.
- Total wizard stimulus time should stay around what it is now (1 s probe + 0.5 s lead; ticks for ~15-20 answers). Longer is possible if justified.
- Taste: the owner wants something a listener would describe as pleasant, branded or musical, or unobtrusive like Sonos's whoosh. Brand colours are gold primary; the app is a native Mac menu-bar app. No ultrasonic (codec roll-off, and it is not "inaudible" for everyone).

## Output
Write your report as Markdown to the path named in your prompt. Cite sources with URLs. Be concrete: numbers, frequencies, durations, dB figures. Say plainly what is unknown. No invented terms: use the standard name for every technique and define it on first use.
