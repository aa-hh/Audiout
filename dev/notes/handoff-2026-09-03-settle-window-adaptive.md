# Handoff — replacing the 60 s alignment settle countdown (2026-09-03)

Self-contained. The question: the phone's sync sheet makes the user wait up to
60 seconds before the Measure button goes live, showing only `Ready in 47s`
with no reason. Alec wants that wait gone, and proposed a specific mechanism
for removing it entirely. This file is the evidence, the mechanism's one
untested assumption, and the experiment that settles it.

Everything below is current as of `origin/main` — Mac `0c075e13`, phone
`c5266d6`, `audiout-shared` `2d87474` (tag `0.6.0`). Nothing here is started.

## Where the gate is

| Piece | Where |
|---|---|
| The constant | `AudioutCore/Sources/AudioutCore/BTAlignmentFreshness.swift:47` — `settleSeconds: TimeInterval = 60` |
| Countdown computed | same file, `settleRemainingSeconds(lastConnectedAt:now:)` :141 — rounds **up**, returns `nil` once past |
| Connect time recorded | same file, `lastConnectedAtByUID` :59, written :78 |
| Put on the wire | `AudioutCore/Sources/AudioutCore/CompanionSnapshotBuilder.swift:249` |
| Rendered | phone `AudioutRemote/UI/Sync/SyncSheet.swift` — `settleRemaining` :38, `ctaTitle` :197 (`"Ready in \(remaining)s"`), local tick-down `tickSettle()` :211 |
| Tests | `AudioutCore/Tests/AudioutCoreTests/BTAlignmentFreshnessTests.swift:51-82` |

**The phone is the only consumer.** `CompanionSnapshotBuilder` is the sole
non-test reader of `settleRemainingSeconds`, and nothing in the Mac's own
alignment wizard gates on connect age at all. So today the same speaker can be
measured immediately from the Mac and not for a minute from the phone. Whatever
you build should close that gap or deliberately decide not to.

## Why the gate exists — the measured evidence

`dev/notes/bt-spike-findings-2026-08-07.md` ("Pacing-clock probe"), a 120 s
passive sample of the CoreAudio device clock:

- **Sonos Move 2 — t=0–42 s after connect is chaotic.** 32 re-anchor jumps of
  ±5–100 ms as the BT stack re-buffers; **net accumulated shift ≈ −353 ms**
  before it settles. From t=42–119 s deviation pins to ±0.01 ms, steady drift
  +21.7 ppm.
- **Sony WH-1000XM3 — zero jumps, +0.4 ppm over 118 s.** No settling chaos at
  all. The note's own conclusion: "The settling window is strongly
  brand-dependent."

So the gate is not superstition: a probe fired at t=10 s on the Sonos measures
the re-buffering, not the speaker, and writes a latency that can be wrong by
tens to hundreds of milliseconds. That is worse than no calibration, because
the number looks plausible and then gets stored.

Equally: **60 is a rounded margin over a single observed 42 s worst case, from
two speaker brands.** It is not a measured universal, and for the Sony it is
pure dead time.

Related: `dev/notes/mic-probe-calibration-brief.md:116` restates the finding;
the spike tool that produced it is `AudioutCore/Sources/core-audio-diagnostic/`.

## Alec's proposal, and the one thing that has to be tested first

> Go straight to adaptive, and then after those 60 seconds, measure whatever
> the difference was and adapt what you had from the adaptive to the measured
> difference from the wizard.

That is: let the user measure immediately, watch how far the device clock moves
between the measurement and the settled state, and correct the stored latency by
that delta. No waiting at all, on any speaker.

The signal it needs exists — sampling the device clock is exactly what the spike
did to observe the jumps, so the Mac can integrate the shift over the window.

**The untested assumption: that the device-clock delta the Mac can observe
equals the acoustic delta the microphone would have heard.** The spike measured
the clock during settling; it never measured *sound* during settling. A
re-anchor step could change buffer depth without moving the reported clock by
the same amount, or move the clock without changing when audio actually leaves
the speaker. If the assumption holds, the countdown disappears completely. If it
does not, the scheme produces a confidently wrong latency — the exact failure the
gate exists to prevent, now silent.

Do not ship the compensation on the strength of the mechanism sounding right.
It is cheap to test.

## The experiment that decides it

Needs a real Sonos Move 2 (the brand that actually exhibits settling) and Alec
in the loop; a Sony or similar makes a useful negative control.

1. Reconnect the speaker. At t≈5 s run an alignment measurement; record the raw
   result **and** the device clock's position at that instant.
2. Let it settle. At t≈90 s measure again — that is ground truth.
3. Compare `early measurement + observed clock delta` against the settled
   measurement.
4. Repeat across a handful of reconnects, and on a second brand.

Agreement within a few milliseconds → the compensation is sound, the gate goes
away entirely. Scatter → the clock is not a proxy for acoustics; fall back to
adaptive release (below) and keep a real wait for speakers that need one.

## Build the stability detector regardless

Either outcome needs it, so it is the first piece of work either way:

- It is the fallback if compensation fails: release the gate as soon as the
  clock is genuinely stable (the bt-spike note prescribes the shape — "wide
  low-pass, jump rejection, re-anchor on steps > ~2 ms") instead of waiting a
  fixed minute. A Sony waits ~0 s, a Sonos waits as long as it truly needs.
- It is also required *by* the compensation scheme, which needs to know when to
  stop correcting.

Wire-wise: `DeviceState.alignment.settleRemainingSeconds` is already on the
wire and already rendered, so an adaptive value can ship without a protocol
change — the field just stops being a countdown from a constant and starts
being the detector's own estimate (or `nil` the moment it is stable). Changing
its *meaning* while keeping its shape is additive on the wire; per
`audiout-shared/AGENTS.md` an additive change does not bump
`CompanionProto.version`, but both consumers' pins still ship together.

## The UX bug, which is separate and cheap

Whatever happens to the timing, `Ready in 47s` never says why. Alec hit this
before he hit any accuracy question. One line under the button — the speaker's
clock is still settling after reconnecting, and measuring now would measure the
settling — fixes the confusion on its own and is worth doing even if the wait
later disappears. Copy rules: `.claude/skills/audiout-copy-review`, and the
phone's `DESIGN.md` for where sheet text lives.

## Watch out for

- **This is Mac-side work in the drift/pacing path**, which is the same
  machinery `SyncCore.swift` / `SyncedLocalSink.swift` use for live playback.
  Breaking it breaks audio for everyone, not just calibration.
- **The Mac repo is GPL and the phone repo is proprietary.** Never move code
  between them; shared code goes through `audiout-shared` (MIT) — see the root
  `AGENTS.md`.
- **Guards on commit:** the Mac repo runs the full suite (Guard 4) and requires
  a readability self-review receipt (Guard 7, `scripts/self-review.sh`) — stage,
  run the script, actually read the diff, then commit.
- **`scripts/make-app.sh` needs a `.env`** (PostHog keys) that does not
  propagate to new worktrees; without it the script exits before codesigning and
  leaves a half-built, unentitled `.app` that still launches. See
  `dev/notes/make-app-worktree-env-gap.md`.
- **Device verification is the standing rule** for the phone (its `CLAUDE.md`):
  a Simulator pass proves nothing about Bonjour, permissions, latency or a real
  room. The mic path in particular was broken on device for the app's whole life
  and no Simulator run or unit test caught it — see
  `dev/notes/handoff-2026-09-02-speaker-sync-calibration.md` and the phone
  commit `ca458b3`.

## State of the surrounding feature

Round 2 of the sync calibration merged today: Mac `0c075e13`, phone `c5266d6`,
protocol `0.6.0`. Phone unit tests pass on iOS 18.5 (mule simulator) and iOS
27.0 (Alec's iPhone 15 Pro), 225 tests each. The feature has still never
completed a real measurement against a real speaker — Alec's first attempt is
what surfaced the missing microphone string. The settle gate is what he hit
next.
