# BT Wave-0 spike findings — live run 2026-08-07

Hardware: Alec's Mac (macOS 27.0), Sonos Move 2 (powered, on WiFi, BT-paired), JBL Flip 5
(paired, powered OFF). Harness: `claude/bt-multi-spike` @ c40e2cce, run via the ad-hoc
`.app` wrapper (`make-spike-app.sh`), launched with `open`. Raw logs in the session
scratchpad; numbers below are the durable record. BT-SPIKE-OFFSET was CUT (mic
auto-offset dropped from the product by Alec earlier the same day — see
PLAN-UNIVERSAL-SYNC Decision 4 amendment).

## BT-SPIKE-CONNECT — **GO**

- **TCC**: a bare CLI is KILLED on first Bluetooth access (`__TCC_CRASHING_DUE_TO_
  PRIVACY_VIOLATION__`, no prompt) — the `.app` wrapper with
  `NSBluetoothAlwaysUsageDescription` is REQUIRED, not a fallback. After the one-time
  grant, status reads "allowed" and sticks. Production consequence: none extra —
  Audiouter ships as a signed .app already; add the usage string + expect the prompt.
- **`IOBluetoothDevice.pairedDevices()`**: works pre-grant (12 devices, incl. name/
  address/connected/A2DP-SDP flags). First call 2.55s (cold), 0.02s warm.
- **Reconnect (powered, paired speaker — Sonos Move 2)**: `openConnection()` →
  baseband up in **1.81s**; CoreAudio output device appeared **0.6s** later
  (uid `C4-38-75-0E-BF-4A:output`). **Total 2.4s** connect → usable endpoint. Well
  inside the plan's "a few seconds" bar. Note: the Move was on WiFi/idle — no
  speaker-side BT-mode button press needed.
- **Disconnect**: `closeConnection()` returned success in ~0s; CoreAudio device
  vanished in **0.2s**. Clean release path for the reconnect state machine.
- **Unreachable device (JBL Flip 5, powered off)**: `openConnection()` FAILED in
  **15.39s** (IOReturn 0xe00002d6). UX consequence: the row's `.connecting` spinner
  must NOT block on the OS attempt — surface the Bluetooth-Settings fallback
  affordance after ~5s while the attempt continues; treat ~16s as the natural
  failure horizon.
- Second-brand success case still unproven (JBL/Sony were powered off) — validate
  opportunistically during BT-DOCS-LIVE; mechanism + failure path are proven.

## Pacing-clock probe (the research question) — **usable, with a settling window**

120s passive sample of the Move 2's CoreAudio device clock (query path worked —
no IOProc fallback needed on Sonos):

- **t=0–42s after connect: chaotic.** 32 jumps of ±5–100ms ("re-anchor" steps) as the
  BT stack re-buffers — the warm-up behavior the 2026-08-07 research predicted, now
  confirmed and quantified. Net accumulated shift ≈ −353ms before settling.
- **t=42–119s: excellent.** Deviation pinned within ±0.01ms; steady drift
  **+21.7 ppm** — same order as built-in (~30 ppm), trivially inside the
  PhaseController PI loop's operating range.
- **Design consequence (BT-DRIFT):** the per-device drift loop must run a
  distrust/settling window (~60s post-connect: wide low-pass, jump rejection,
  re-anchor on steps > ~2ms) before tightening; after settling the pacing clock is a
  first-class servo source. Mirrors the FLUSH re-anchor lesson.

## Second brand — Sony WH-1000XM3 (added later the same evening)

- **Power-on auto-reconnect**: the XM3 reconnected itself to the Mac the moment it was
  powered on (last-host memory) — our reconnect flow is for devices that DON'T do this.
  While unpowered it failed identically to the JBL (15.38s, 0xe00002d6) — the ~15s
  unreachable horizon is consistent across brands.
- **Fresh programmatic connect** (after closeConnection round-trip): baseband **3.76s**
  + CoreAudio endpoint **0.6s** = **4.4s total** (vs Sonos 2.4s). Disconnect: instant,
  device gone in 0.4s. **BT-SPIKE-CONNECT ≥2-brands criterion: satisfied. GO.**
- **Pacing clock: ZERO jumps, +0.4 ppm over 118s** — no settling chaos at all, unlike
  the Sonos's ~40s. The settling window is strongly brand-dependent.
- **Design refinement for BT-DRIFT**: replace the fixed ~60s distrust window with an
  ADAPTIVE settle gate — treat the clock as trustworthy once it has been jump-free
  (steps < ~2ms) for ~10s, with re-entry into the distrust state on any later jump.
  Sony-class devices then lock in seconds while Sonos-class devices get the full
  protection.

## Net

Both Wave-0 gates cleared same-day. No plan changes required beyond: (a) BT-CONNECT
timeout split (UI affordance ~5s, OS horizon ~16s), (b) BT-DRIFT settling window,
(c) entitlement/usage-string checklist confirmed. Production Waves 1+ unblocked.
