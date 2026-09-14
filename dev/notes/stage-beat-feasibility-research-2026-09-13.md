# Beat-locked lights on the phone sync sheet: feasibility research

2026-09-13. Question: direction F of the stage discovery makes each light on the wire flash when its speaker's click reaches the listener, so a timing gap shows as two flashes and alignment as one. Can it be built, and would it show what it claims?

Four tracks, each against primary sources, appended in full below with citations. This first section is the verdict.

## Verdict

**Buildable, but the display cannot show its own subject in the range that matters.** Two flashes a few centimetres apart are seen as two events only when they are about 50 ms or more apart; between roughly 50 and 150 ms they read as one light moving. The app's whole working range after a measurement sits under 40 ms (the "tell the user" threshold) and the replace threshold is 10 ms. In that band the eye sees one flash while the ear still hears two clicks, and at 10 ms the ear hears two but cannot say which came first. So the by-ear page, where F puts its beat, would show a single flash for every gap the user is trying to close. The only time two flashes would be visible is before a Bluetooth speaker has been measured, when the Mac's latency estimate is 100 to 400 ms out, so the flashes would be visibly two and wrong.

**What it would cost to build anyway.** Three additions, none small:

1. A shared clock. Nothing exists today: the WebSocket ping/pong carries no timestamp on either side and the network framework's pong handler cannot carry one. A phone-driven four-timestamp exchange over the monotonic clock, twenty samples, keep the fastest five, gives ±1 to ±4 ms and needs refreshing every 30 s against 15 ppm crystal drift. That is a new command and a new message in audiout-shared.
2. Tick phase from the Mac. Tick onset is a sample counter with no host-time stamp, but the block it is mixed into carries a monotonic presentation time, so onset in host time is derivable. Per-speaker arrival is one formula the Mac already uses for sync (presentation delay minus own latency minus margin plus trim, with the Bluetooth latency store feeding it). A second additive message would publish period, anchor, and per-speaker arrival offset.
3. Precise drawing on the phone. SwiftUI's timeline view promises only "no more quickly than" its interval and Apple points apps needing accurate timing at CADisplayLink with its target timestamp. 120 Hz needs an Info.plist key. Haptics can be scheduled to an absolute time but on Core Haptics' own clock, which Apple says does not correlate with other frameworks' time, so the offset would have to be measured. Apple publishes no number for callback jitter, draw-to-photons, or haptic latency.

**The microphone alternative does not rescue it.** The phone's mic is idle on the by-ear page today (ticks run on the listen and by-ear pages; the mic runs on the run page, where ticks are stopped). The capture class hands samples back only at stop and self-stops at 15 s. Both are phone-side fixes. The blocker is attribution: one microphone hears both speakers' clicks, and on the companion tick path they carry the same timbre (flagged unverified by the Mac track; the Mac's own wizard splits timbre by transport). Without a way to tell which click came from which speaker, the phone cannot flash the right light.

**What survives of F.** A single pulse on every beat, both lights flashing together as one, is feasible and cheap. ITU-R BT.1359-1 puts sound-to-picture error under 45 ms inside the undetectable plateau, so even a rough clock estimate (half the ping round trip) would keep a fused flash in step with the clicks the user hears. That pulse can sit on the by-ear page of any direction, with the gap carried by position on the wire as F already proposed. What does not survive is the two-flash gap display, which is the direction's thesis.

**Recommendation.** Take plan B: direction E's full-bleed stage drawn with the Mac's own emitter rings, and fold in F's fused beat pulse on the by-ear page as an optional later addition once a clock exchange exists. Put the clock exchange and tick-phase message on the roadmap next to the A/B path, since the same two additions would also let the phone show the Mac's ticks honestly.

## Numbers to measure on the phone before anything ships

Apple publishes none of these: display-link callback jitter, draw-to-photons latency, Core Haptics latency in immediate and scheduled modes, the haptic clock's offset from host time, actual I/O buffer duration and input latency on the iPhone 15 Pro. Per the standing rule they get measured on Alec's device.

---

# Track 1: Mac tick clock and protocol

# Can the phone know when each speaker's click reaches the listener?

Short answer: the Mac *could* compute a per-speaker arrival instant, but nothing
computes it today, nothing carries it on the wire, and there is no clock shared
between Mac and phone. Paths in the Mac repo are relative to
`/Users/alechenderson/Projects/AirPlay Controller/AudioutCore/Sources/AudioutCore/`.

## 1. The tick's clock

- Onset is a **sample counter**, not a time. The injector holds `cursor` (frames
  consumed since injection began) and `tickEpochFrame`; a tick sounds where
  `(position - tickEpochFrame) % beatFrames < tickTable.count`
  — `AlignmentTickInjector.swift:686-694`. `beatFrames = sampleRate*60/bpm`
  (`AlignmentTickInjector.swift:283`), sample rate default 44100 (`:278`).
- Phone's by-ear page uses `Config.companion` — bpm 72, `armedAtStart` default
  `true`, budget 720 beats ≈ 10 min (`AlignmentTickInjector.swift:190,198,230`,
  `:109`). Armed at start means `tickEpochFrame = 0` (`:286`), i.e. the grid's
  origin is the first buffer the injector ever mixes. Nothing records the wall
  time of that buffer.
- The injector has **no notion of host time at all** — no `mach_absolute_time`,
  no `AudioTimeStamp`, no `Date` in the file.
- The caller does have a time. Each captured block carries a pts on
  `CLOCK_MONOTONIC`, rebased from the IOProc's `AudioTimeStamp.mHostTime` by
  `CoreAudioSystemTap.timespec(fromHostTime:)`
  (`NativeCaptureCoordinator.swift:3696-3697`, `:4063-4107`; mach↔monotonic
  caveat at `:4069-4072`). `deliver(_:pts:snapshot:)` passes that pts to every
  sink (`NativeCaptureCoordinator.swift:1745`, `:1864-1878`). So
  `tick onset pts = blockPts + (tickEpochFrame + n*beatFrames - cursorAtBlockStart)/sampleRate`
  is derivable — but `cursor` is private and no code pairs it with a pts today.
- Position in the chain: the tick is mixed **after** capture conversion, after
  the leveled-app injector and after the Main Out EQ, and **before** the engine
  write and both fan-outs (`NativeCaptureCoordinator.swift:1692-1714`, comment
  `:1706-1712`). So it is upstream of every per-sink delay — one tick, each sink
  renders it through its own delay. That is the property the whole by-ear page
  rests on.

## 2. Per-sink delay from injection to sound

All three sinks share one formula, `SyncTiming.totalDelayNanos` =
`max(0, presentationDelay − ownLatency − safetyMargin + userOffset)`
(`SyncCore.swift:53-65`), applied to the block's pts
(`SyncCore.swift:66-68`).

- **AirPlay**: delay is the live presentation delay,
  `currentStartBufferMs − AIRPLAY_AUDIO_LATENCY_MS`
  (`AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:345-347`); the
  vendored sender schedules playout off the same value (comment `:341-343`).
  Receiver-internal latency beyond that is unknown to the Mac.
- **Mac local output**: `presentationDelay − localOutputLatency − safetyMargin`
  (`SyncedLocalSink.swift:23`), with the latency measured from CoreAudio
  (`LocalOutputLatency.swift:13-26`, `totalSeconds`). Intent is that it lands
  level with AirPlay, so its arrival ≈ pts + presentationDelay.
- **Bluetooth**: `BTReferenceTimeline.delayNanos` — reference is the AirPlay
  presentation timeline when AirPlay is present, otherwise a fixed BT-only
  buffer; minus `deviceOffsetMs` (the speaker's own latency), plus the signed
  trim (`BTSyncedSink.swift:67-84`, rule at `:45-50`). `deviceOffsetMs` comes
  from `btLatencyMsByUID` (`NativeBackend.swift:411`), pushed to the sink as
  `setOffsetMs` (`NativeBackend.swift:4436-4448`); trims from `btTrimsByUID`
  (`:4437-4439`). Both live in the same lock, so both are readable per UID
  (`NativeBackend.swift:11230`, `:11702`).

So **yes**: "tick onset pts + this sink's delay" is computable per speaker, in
`CLOCK_MONOTONIC` nanoseconds, from values the Mac already holds. It is nowhere
computed today.

Shared clock with AirPlay speakers: the PTP helper exists but exposes only a
**boolean readiness** — `PTPClockProbe.isReady()`
(`AirPlayEngine/Sources/AirPlayEngine/PTPClockProbe.swift:20-25`), surfaced as
`ptpClockAvailable` (`NativeBackend.swift:708`). No clock value, no offset, no
API that returns PTP time. Nothing there for the phone.

## 3. The companion transport

- Plain `NWProtocolWebSocket`, JSON text frames
  (`CompanionServer.swift:308`, send at `:932`).
- **No message carries a timestamp.** The envelope is `{v, type, payload}` with
  a fixed key set (`audiout-shared/Sources/AudioutProtocol/CompanionMessage.swift:169-182`);
  no time field in any case (`:27-82`), none in `Snapshot`
  (`CompanionSnapshot.swift`, only `startBufferMs` and friends at `:250-251`).
- **Ping/pong exists but measures nothing.** The server pings every 20 s for
  liveness (`CompanionServer.swift:263-266`, `:701-712`) and only stamps
  `lastActivity = Date()` (`:579`, `:711`, `:739`). The phone pings too, and its
  pong handler only resets a missed-ping count — no timing
  (`AudioutRemote/Networking/MacConnection.swift:365-369`, `:609-616`).
- Mac time basis: `Date()` for liveness only; audio time is
  `CLOCK_MONOTONIC`/mach as in §1. These never meet.
- What a phone *could* use today: every command gets a `requestID` and a
  `commandResult` back (`CompanionMessage.swift:28,49`;
  `MacConnection.swift:247-252,348-352`; `RemoteSession.swift:286-288`). That is
  a round-trip the phone could time itself — nothing does, and no sent/received
  timestamps are recorded anywhere. Unverified whether the reply is prompt
  enough for half-round-trip to be a usable clock estimate.

## 4. What a protocol addition would need

Per `audiout-shared/AGENTS.md` (the AudioutProtocol section): add a **new case**,
never re-encode an existing one; **no `CompanionProto.version` bump**, since an
old peer decodes an unknown name as `.unknown`
(`CompanionProto.swift:10-16`). Tag `audiout-shared`, then bump both consumers'
pins in one session.

Minimal shape, as a Mac→phone message (`CompanionMessage`, plus a `TypeName`
entry and payload keys):

```
alignmentTickSchedule(deviceID: String,
                      periodMs: Double,          // 60000/72 ≈ 833.3
                      anchorMonotonicNanos: Int64,  // a tick onset, Mac CLOCK_MONOTONIC
                      arrivalOffsetMs: Double)   // that sink's delay, from §2
```

Needed on the Mac side to fill it: record the block pts at the moment
`tickEpochFrame` is set, and expose `cursor`/`tickEpochFrame` to the caller
(neither exists — `AlignmentTickInjector.swift:256,260` are private, the
`test_` seams at `:719-731` are reads only). Plus a per-UID delay read, which is
assembly of existing values.

What the Mac cannot know:

- **The map from Mac monotonic time to phone time.** Without it the anchor is
  useless. Nothing in the transport provides it (§3); it would need a second
  addition — an echo message the phone times, or a repeating tick-onset
  notification the phone can phase-lock to.
- **Bluetooth speaker latency is an estimate** until a measurement replaces it;
  a device with no measurement contributes nothing and is treated as within the
  floor (`NativeBackend.swift:4190-4196`), i.e. its arrival offset would be
  wrong by its whole unknown latency (~100–400 ms, `BTSyncedSink.swift:59-61`).
- **Clock settling.** A Bluetooth speaker's clock steps after link-up; the Mac
  publishes only `unknown`/`settling`/`steady`, deliberately no seconds
  (`BTSpeakerTiming.swift:59-73`, rationale `:28-32`). A phase published during
  settling drifts.
- **Receiver-internal latency** on AirPlay past the presentation delay, and the
  acoustic flight time from speaker to listener — neither is modelled anywhere.

## 5. Alternative: the phone's microphone

- **Not recording today on the by-ear page.** `didEnter` starts ticks on
  `.listen` and `.fineTune` and the microphone belongs to the separate
  `.microphone`/`.run` pages, where ticks are explicitly stopped
  (`AudioutRemote/UI/Sync/SyncSheetModel.swift:581-590`). The capture session is
  only built by the measurement run (`AudioutRemote/Model/ProbeSession.swift:93,141`).
- **Could it?** The machinery is there: `ProbeCaptureSession.start()` pins the
  built-in mic, `.record`/`.measurement` (AGC and noise suppression off — which
  matters for onset timing), input gain pinned to 1.0
  (`AudioutRemote/Model/ProbeCaptureSession.swift:106-133`), tap at 4096 frames
  (`:147`). Two obstacles: it accumulates into an array and hands it back only
  at `stop()` (`:219-226`) — no streaming callback — and it self-stops at
  `maxDuration` 15 s (`:51`, `:190-192`), against a ~10 min by-ear session.
  Both are phone-side changes, no protocol involved.
- **What an onset detector would look for**: ~30 ms woodblock transient,
  exponential decay τ ≈ 6 ms, 8-sample attack ramp, two partials mixed 0.7/0.3
  (`AlignmentTickInjector.swift:313-331`). The by-ear/companion path plays the
  **bright** click only — 1800 Hz + 2900 Hz (`:121`, `mix` at `:592-594`). The
  low knock, 900 + 1450 Hz (`:126`), is the wizard's engine-side timbre and does
  not appear in `.companion`. Under the ticks sits a keep-alive: a ~20 Hz sine
  at −40 dBFS RMS (`:226-227`), harmless to a high-band detector.
- Unverified: whether one microphone can separate two speakers' clicks of the
  **same** timbre. The measurement run only manages it because the two lanes use
  orthogonal sweeps (DOWN vs UP, `:460-462`) or are staggered in time (`:464-468`).
  Same-timbre clicks arriving ms apart have no such separation.

# Track 2: iOS display, haptic and microphone timing

# iOS timing precision: flash, haptic, mic onset (iPhone 15 Pro, iOS 18)

Sources are Apple only: developer.apple.com documentation and WWDC session transcripts.
Where Apple publishes no number, this says so instead of guessing.

## Short answer

| Thing | Best case Apple documents | Apple's own number? |
|---|---|---|
| Visual flash | Aim at a vsync boundary, 8.33 ms apart at 120 Hz. Callback timing is explicitly not guaranteed. | Grid spacing yes; jitter no |
| Haptic | Schedulable to an absolute time on Core Haptics' own clock, which Apple says does not correlate to other frameworks' clocks | No latency figure published |
| Mic onset | I/O buffer duration is the quantum; documented minimum 0.005 s (256 frames), "might be lower depending on the hardware". Plus `inputLatency`. | Buffer yes; total no |

---

## 1. Display

**`CADisplayLink.targetTimestamp` is the one to schedule against.** Apple: `timestamp` is "when the callback is scheduled to be invoked", `targetTimestamp` is "when the next frame will be composited by CoreAnimation"; "targetTimestamp should be used rather than timestamp to prepare your drawings" (WWDC21 session 10147, <https://developer.apple.com/videos/play/wwdc2021/10147/>). Doc abstract: "The time interval that represents when the next frame displays" (<https://developer.apple.com/documentation/quartzcore/cadisplaylink/targettimestamp>).

**No guarantee on when the callback actually runs.** Same session: "Usually, the callback will be invoked right at the scheduled wake-up time, but it's not always the case... the display link doesn't get a chance to run until a few milliseconds into the vsync interval." And: "the actual amount of time is not guaranteed. A higher priority thread may be scheduled on the CPU, or the runloop is busy... In the extreme case, callbacks may be skipped entirely." Apple gives no bound on this jitter. The mitigation Apple names is to compare `CACurrentMediaTime()` against `targetTimestamp` inside the callback to see how much time is left.

**120 Hz needs an Info.plist key on iPhone.** "Core Animation won't apply any refresh rate that's faster than the system's default" unless `CADisableMinimumFrameDurationOnPhone` is `true`; without it "Core Animation won't access higher frame rates (above 60Hz)" (<https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays>). ProMotion on supported iPhones ranges 10–120 Hz; at 120 Hz the display refreshes every 8 ms (WWDC21 10147). `UIScreen.maximumFramesPerSecond` returns up to 120 (<https://developer.apple.com/documentation/uikit/uiscreen/maximumframespersecond>).

**You cannot pin the rate.** "you can't force a ProMotion display to show your content at any specific rate" (same article). `preferredFrameRateRange` is a hint: "The display link makes a best attempt to invoke your app's callback within the frequency range you set" (<https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange>).

**SwiftUI `TimelineView` gives no timing guarantee.** `.animation` is described as "A pausable schedule of dates updating at a frequency no more quickly than the provided interval" — an upper bound on rate, not a promise of when (<https://developer.apple.com/documentation/swiftui/animationtimelineschedule>). The `TimelineView` overview says "The system might use a cadence that's slower than the schedule's update rate" (<https://developer.apple.com/documentation/swiftui/timelineview>). `.periodic` is "A schedule for updating a timeline view at regular intervals", with no accuracy statement (<https://developer.apple.com/documentation/swiftui/periodictimelineschedule>). Nothing in the SwiftUI docs ties `Canvas` redraw to a display link; `Canvas` is documented only as immediate-mode drawing that "might provide better performance for a complex drawing that involves dynamic data" (<https://developer.apple.com/documentation/swiftui/canvas>). Apple's ProMotion article says frame pacing is handled automatically for SwiftUI, and directs apps that "need to present custom content accurately" to `CADisplayLink` or `CAAnimation` instead.

**Draw-call-to-photons latency: Apple publishes no figure.** I found no Apple statement quantifying it for iOS. The nearest is the WWDC21 framing that a frame prepared in one callback is presented at the *next* vsync — i.e. at least one refresh interval (8.33 ms at 120 Hz) between preparing and displaying, plus unquantified panel time.

**Best-case scheduling jitter for a visual event:** Apple does not state one. What is documented is the grid: the event lands on a vsync boundary, 8.33 ms apart at 120 Hz, 16.67 ms at 60 Hz, and the app chooses which boundary via `targetTimestamp`.

## 2. Haptics

**Core Haptics can be scheduled to an absolute time, but on its own clock.** `start(atTime:)`: "If `time` is 0 or any value less than the haptic engine's [currentTime], the pattern starts playing immediately" (<https://developer.apple.com/documentation/corehaptics/chhapticpatternplayer/start(attime:)>). `CHHapticEngine.currentTime` is "The absolute time, in seconds, to use for scheduling haptic and audio events" — and carries the warning: "The Core Haptics engine time doesn't correlate to time used in media playback classes from other frameworks" (<https://developer.apple.com/documentation/corehaptics/chhapticengine/currenttime>). So there is **no documented mapping from a mach/host time to the haptic clock**; you would have to measure the offset yourself by sampling `currentTime` and `mach_absolute_time()` together, which Apple neither describes nor blesses.

WWDC19 session 520 describes the two modes: immediate mode "tells the system that you wish this pattern to play at the soonest possible moment with the minimal latency"; scheduled mode "you hand it an absolute timestamp which tells the system that you want to synchronize this event with some other systems" (<https://developer.apple.com/videos/play/wwdc2019/520/>). `CHHapticTimeImmediate` is "A time constant used to schedule a command immediately" (<https://developer.apple.com/documentation/corehaptics/chhaptictimeimmediate>).

**Event `relativeTime`** is seconds relative to the pattern start; zero means immediate (<https://developer.apple.com/documentation/corehaptics/chhapticevent/relativetime>). No precision figure is given.

**Latency: Apple publishes no number.** WWDC19 520 repeatedly says "low latency" and "designed for low latency and real-time modulation" without a millisecond figure. One concrete lever: `CHHapticEngine.playsHapticsOnly = true` "reduces latency of starting haptic playback" (<https://developer.apple.com/documentation/corehaptics/chhapticengine/playshapticsonly>) — and it only takes effect if set before the engine starts.

**`UIImpactFeedbackGenerator` has no scheduling at all.** Its only timing control is `prepare()`: "While the generator is prepared, you can trigger feedback with lower latency", but "Calling [prepare] and then immediately triggering feedback (without any time in between) does not improve latency"; the Taptic Engine returns to idle "after a short period of time... (typically seconds)" or once feedback fires (<https://developer.apple.com/documentation/uikit/uifeedbackgenerator/prepare()>). No amount of preparation lets you name an instant. WWDC19 520 notes UIKit feedback is built on Core Haptics and shares its latency characteristics.

## 3. Audio input

**Buffer quantum.** "The minimum I/O buffer duration is at least 0.005 seconds (256 frames) but might be lower depending on the hardware in use"; typical maximum 0.093 s (<https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferrediobufferduration(_:)>). The request is a preference — check `ioBufferDuration` to see what you actually got (<https://developer.apple.com/documentation/avfaudio/avaudiosession/iobufferduration>). Apple does not publish a figure for what an iPhone 15 Pro grants at 48 kHz. Preferred sample rate "typically from 8000 through 48000 hertz" (<https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredsamplerate(_:)>).

**Hardware input delay** is `AVAudioSession.inputLatency`, "The latency for audio input, in seconds" — no typical value given (<https://developer.apple.com/documentation/avfaudio/avaudiosession/inputlatency>). Node-level equivalent: `presentationLatency` (<https://developer.apple.com/documentation/avfaudio/avaudioionode/presentationlatency>).

**Sink node beats a tap for real-time work.** WWDC19 session 510: `AVAudioSinkNode`'s "block operates under real-time constraints"; it is useful "when the input needs to be processed in real time, in which case installing a regular tap would not be sufficient because the tap doesn't operate in a real-time context" (<https://developer.apple.com/videos/play/wwdc2019/510/>). The sink node's block receives the render timestamp directly (<https://developer.apple.com/documentation/avfaudio/avaudiosinknodereceiverblock>). Tap buffer size is only a request: "The size of the incoming buffers. The implementation may choose another size" (<https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)>), and the tap block runs off the main thread. Apple documents no minimum tap buffer size.

**Stamping an onset to host time works.** `AVAudioTime` "represents a single moment in time in two ways: As host time, using the system's basic clock with `mach_absolute_time()`" and as sample time at a sample rate (<https://developer.apple.com/documentation/avfaudio/avaudiotime>). Sample offset within the buffer converts to seconds at the sample rate and adds onto the buffer's host time; subtract `inputLatency` for the acoustic instant.

**`.measurement` mode** "minimize[s] the amount of system-supplied signal processing to input and output signals" and uses the primary microphone on multi-mic devices; it "disables some dynamics processing... resulting in a lower-output playback level" (<https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/measurement>). Apple states no latency effect.

**Bluetooth output:** if the phone only records, the Bluetooth *output* path is not in the measurement chain. But I found no Apple statement that selecting a Bluetooth route leaves input latency unchanged — and the audio session category/route governs input and output together, so treat the route as a variable to pin, not as proven irrelevant.

## 4. Clocks

- `CACurrentMediaTime()` returns "a `CFTimeInterval` derived by calling `mach_absolute_time()` and converting the result to seconds" (<https://developer.apple.com/documentation/quartzcore/cacurrentmediatime()>). So display-link timestamps and `AVAudioTime.hostTime` share one time base.
- `AVAudioTime.hostTime` uses that same base (<https://developer.apple.com/documentation/avfaudio/avaudiotime>).
- Core Haptics' clock is the odd one out — explicitly stated not to correlate with other frameworks (see section 2).
- Swift concurrency clocks give **no** wall-time or network guarantee. `ContinuousClock`: "The frame of reference of the `Instant` may be bound to process launch, machine boot or some other locally defined reference point. This means that the instants are only comparable locally" (<https://developer.apple.com/documentation/swift/continuousclock>). `SuspendingClock` says the same and stops while the system sleeps (<https://developer.apple.com/documentation/swift/suspendingclock>).
- **No public network-synchronised clock API on iOS.** I found no Apple documentation exposing NTP or a shared network clock to third-party apps. CoreMedia's `CMClockGetHostTimeClock()` is still the local host clock (<https://developer.apple.com/documentation/coremedia/cmclockgethosttimeclock()>). Phone-to-Mac alignment has to be measured over your own protocol.

## 5. Background / foreground

- `isIdleTimerDisabled` keeps the screen on: "apps that don't have user input except for the accelerometer — games, for instance — can, by setting this property to [true], disable the 'idle timer' to avert system sleep" (<https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled>). Apple also notes audio apps normally do *not* need it, since "playback and recording proceed uninterrupted when the screen turns off" with a correct audio session — relevant only if the visual half stops mattering.
- **Low Power Mode caps the refresh rate.** "the system disables faster refresh rates in low power mode or if a device gets hot" (<https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays>); `preferredFrameRateRange` doc names "Low Power Mode, critical thermal state, and accessibility settings" as things that change the available range (<https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange>). WWDC21 10147 adds the Accessibility "Limit Frame Rate" toggle, which "caps the maximum frame rate to 60Hz", and notes `UIScreen` still reports 120 Hz in Low Power Mode while `CADisplayLink` reports the real rate.
- A 72 BPM loop is 833 ms per beat — far coarser than any of these caps. A 60 Hz cap moves the vsync grid from 8.33 ms to 16.67 ms; it does not break the loop. Apple documents no other interruption source for a foreground app doing this.
- Interruptions Apple does document generally: the haptic server can be overridden — "the operating system could still override the request with system services, like haptics from system notifications" (<https://developer.apple.com/documentation/corehaptics/chhapticengine>).

## Gaps worth measuring on the device

Apple publishes no number for: display-link callback jitter, draw-to-photons latency, Core Haptics latency in either mode, the offset between the Core Haptics clock and `mach_absolute_time()`, the actual `ioBufferDuration` and `inputLatency` on an iPhone 15 Pro, and whether a Bluetooth route changes input latency. Every one of those is measurable on the phone.

# Track 3: Phone-to-Mac clock agreement

# Can the phone and the Mac agree on time well enough to predict a click?

Short answer: yes, to roughly ±1–4 ms, using about 20 request/response round
trips on the existing WebSocket and keeping only the fastest ones. Both wall
clocks being set from Apple's time servers is not a substitute — nothing
documents how close they are.

## What the code already has

No round-trip measurement and no timestamp exchange exist on either side.

- Phone: `AudioutRemote/Networking/MacConnection.swift:609` `sendPing` sends a
  WebSocket ping and hands the pong to a closure that takes no arguments and
  captures no send time. Its only caller,
  `MacConnection.swift:394`, uses the pong to zero a missed-ping counter
  (`MacConnection.swift:397`). Nothing records when the ping left.
- Mac: `AudioutCore/Sources/AudioutCore/CompanionServer.swift:708` sends its own
  ping; the pong handler at `:711` only stamps `lastActivity = Date()`
  (also `:579`, `:739`, `:755`, `:842`). `Date()` here is liveness bookkeeping,
  never a measurement.
- Monotonic clocks are already used on the phone, but only for local
  durations: `ProcessInfo.processInfo.systemUptime` at
  `MacConnection.swift:213/280/508`, `Model/ProbeSession.swift:146/160`,
  `Model/CommandSender.swift:16`.
- The wire protocol carries no time field. `audiout-shared`'s
  `Sources/AudioutProtocol/CompanionCommand.swift:67`
  (`reportAlignmentMeasurement(targetID:offsetMs:confidence:)`) is a speaker
  alignment result in milliseconds, not a clock reading.

So this would be new, in both apps and in the shared protocol.

## 1. Accuracy from N round trips

The standard four-timestamp exchange (RFC 5905 §8): the phone sends at T1, the
Mac receives at T2 and replies at T3, the phone receives at T4.

    offset = ((T2 - T1) + (T3 - T4)) / 2
    round-trip = (T4 - T1) - (T3 - T2)

The offset is exactly right only if the two directions take equally long. RFC
5905 §4 bounds the total error as `LAMBDA = EPSILON + DELTA/2` — half the
round-trip delay is the worst-case error from path asymmetry. So the shortest
round trip you can find sets the best bound you can claim.

That is also why RFC 5905 §10 keeps eight samples and sorts them by delay:
"Let i index the stages starting with the lowest delta." Lowest delay wins,
because a sample that took longer took longer in one direction or the other.

Jitter figures for Wi-Fi, measured (BLADE, arXiv 2603.16119, 802.11ax, 5 GHz,
40 MHz, four access-point/station pairs): once a device has the channel, the
transmission itself finishes within 3.5 ms 92.7% of the time, worst case
7.5 ms (§3.1.2, Fig. 7). Waiting for the channel is the problem — the
contention interval "exhibits an alarming heavy tail, exceeding 200 ms at the
99.99th percentile" (§3.2.1, Fig. 8).

Arithmetic. A round trip is two air hops plus two network-stack traversals. On
a quiet home network the floor is about 2–5 ms. Take 20 samples 50 ms apart
(1 second of wall time); the smallest round trip will land near that floor,
say 3 ms. The bound is then 3/2 = 1.5 ms. Allow that the fastest sample is not
perfectly symmetric and the honest range is **±1 to ±4 ms**. Do it the naive
way — average all 20 raw offsets — and one contention-tail sample drags the
answer out to ±10 ms or worse, which is why you keep the minimum rather than
the mean. A median of the best five is a reasonable middle.

By comparison RFC 5905 §1 puts wired NTP clients "within a few hundred
microseconds" on fast LANs. Wi-Fi costs you roughly an order of magnitude.

## 2. Does drift matter over 1–3 minutes?

RFC 5905 §7.2 sets `TOLERANCE = 15e-6` — 15 parts per million, the frequency
tolerance PHI, described in §4 as the maximum disciplined clock frequency
tolerance, about 1.3 s per day.

    15 ppm x  60 s = 0.9 ms
    15 ppm x 180 s = 2.7 ms

At 3 minutes the accumulated drift is the same size as the measurement error
itself, so it is not negligible. Two devices can drift in opposite directions,
which doubles it in the worst case. An undisciplined consumer crystal at
50 ppm would give 9 ms over 3 minutes, which would be audible for this purpose.

Fix: re-measure every 30 seconds. 15 ppm x 30 s = 0.45 ms, below the noise
floor, and drift never accumulates.

## 3. What the exchange would look like

The phone drives it, because the phone is the one that needs the answer.

The phone sends a small message carrying its own reading of
`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` and a sample number. The Mac replies
with two readings of its own clock — one taken on receipt, one taken as it
replies — echoing the sample number. The phone stamps arrival on the same
clock it sent from. Four numbers, one offset, one round trip.

Send about 20 of these roughly 50 ms apart when the tuning screen opens, which
costs a second. Discard every sample whose round trip is above the smallest
seen; keep the offsets from the fastest five and take their median. Repeat the
whole burst every 30 seconds while the screen is open, and again after any
gap in the connection, since a dropped socket or a backgrounded app invalidates
the estimate.

Use `CLOCK_UPTIME_RAW` (or `mach_absolute_time`, identical after timebase
conversion) on both sides, not `Date()`: the man page for `clock_gettime(3)`
says only `CLOCK_REALTIME` can be set, and a wall clock that jumps mid-session
destroys the estimate. `CLOCK_UPTIME_RAW` is "unaffected by frequency or time
adjustments" and does not advance during sleep, which is what you want.

## 4. Are the wall clocks already close enough?

No documented guarantee. macOS and iOS ship `timed`, whose man page says it
"maintains system clock accuracy by synchronizing the clock with reference
clocks via technologies like NTP" and that it "calculates uncertainty to
facilitate scheduling proactive time jobs" — but it publishes no accuracy
figure, is explicitly "aware of power/battery conditions" (so it backs off on
battery), and exposes that computed uncertainty through no public API. An app
can read `CLOCK_REALTIME`; it cannot read how wrong it is.

Two devices polling the same public server minutes apart, on a link whose
contention tail runs past 200 ms, can easily sit several tens of milliseconds
apart with both looking healthy. Measure the offset over your own connection
instead; you get a number you can bound, which is the whole point.

## Sources

- RFC 5905 (NTPv4), §1, §4, §7.2, §8, §10 — https://www.rfc-editor.org/rfc/rfc5905.txt
- BLADE: Adaptive Wi-Fi Contention Control, §3.1.2 Fig. 7, §3.2.1 Fig. 8, §6.3 — https://arxiv.org/abs/2603.16119
- `clock_gettime(3)` man page, Darwin 27.0.0 (on this machine)
- `timed(8)` man page, Darwin 27.0.0 (on this machine)
- `NWProtocolWebSocket.Metadata` — https://developer.apple.com/documentation/network/nwprotocolwebsocket/metadata — documents `init(opcode:)`, `opcode`, `closeCode`, `selectedSubprotocol`, `additionalServerHeaders`, `setPongHandler(_:handler:)`. No timestamp, no round-trip figure, no keepalive interval. The pong handler is the only round-trip hook and it reports nothing but an error, so the ping/pong path cannot carry this measurement — it needs app-level messages.

# Track 4: Perception thresholds

# Two-flash sync display: what the perception literature supports

Scope: direction F shows two lights, one flashing when each speaker's click arrives at the
listener. Question is whether a gap between speakers reads as two flashes.

## 1. Audio-visual synchrony — detection and acceptability

ITU-R BT.1359-1 (1998), *Relative timing of sound and vision for broadcasting*, considering g)
and Appendix 1 §3: "thresholds of detectability are about +45 ms to -125 ms and thresholds of
acceptability are about +90 ms to -185 ms on the average". NOTE 1: "A positive value indicates
that sound is advanced with respect to vision." So sound may lag the picture by up to 125 ms
before viewers notice, but only lead it by 45 ms. Appendix 1 §3 also names an "undetectability
plateau" between those limits, and a span of about 170 ms between the just-detectable limits.
Test material was a female newsreader at 2 m, i.e. speech, not a flash and a click (Appendix 2).

Psychophysics with a flash and a click gives the same asymmetry but with wide scatter and a task
dependence. van Eijk, Kohlrausch, Juola & van de Par, *Percept Psychophys* 70(6):955-968, 2008,
doi:10.3758/PP.70.6.955 — point of subjective simultaneity estimates from synchrony judgement and
from temporal order judgement tasks are uncorrelated, and they argue simultaneity should sit at an
auditory delay of 0 ms or more (sound arriving after the flash). For the flash/click pair they
found no significant difference between the two tasks' points of subjective simultaneity.

Love, Petrini, Cheng & Pollick, *PLOS ONE* 8(1):e54798, 2013, doi:10.1371/journal.pone.0054798,
Table 1, beep-flash condition: point of subjective simultaneity +67 ms (video leading) by synchrony
judgement, -33 ms (audio leading) by temporal order judgement; temporal integration window about
106 ms and 84 ms respectively.

**Disagreement:** the broadcast standard's numbers are much tighter than the laboratory windows,
and the sign of the point of subjective simultaneity flips with the task used (Love 2013 vs the
audio-delay direction argued by van Eijk 2008). All three agree that sound arriving *after* the
visual event is tolerated far better than sound arriving before it.

## 2. Seeing two flashes as two

Same location. Samaha & Postle, *Current Biology* 25(22):2985-2990, 2015,
doi:10.1016/j.cub.2015.10.007, used inter-stimulus intervals of 10-50 ms in a one-flash versus
two-flash discrimination and took the 75% point as the fusion threshold; individual thresholds
track occipital alpha rhythm speed, so this is a per-person number, not a constant. Reported
two-flash thresholds in this paradigm sit around 35-70 ms.

Flicker fusion, the related same-location limit: "The speed of sight: individual variation in critical
flicker fusion thresholds", *PLOS ONE* 19(4):e0298007, 2024, doi:10.1371/journal.pone.0298007 — critical flicker fusion
thresholds spanned roughly 47-67 Hz across 88 adults, group mean near 57 Hz (17.5 ms period), with
a between-participant spread of about 30 Hz. Individual differences accounted for ~80% of variance.

Different locations, a few centimetres apart. Two flashes separated in space produce apparent
motion, not two events, over an intermediate range. "The effect of visual apparent motion on audiovisual
simultaneity", *PLOS ONE* 9(10):e110224, 2014, doi:10.1371/journal.pone.0110224, summarising Getzmann 2007, Harrar et al. 2008, Strybel et al.
1990 and Briggs & Perrott 1972: apparent motion at inter-stimulus onset intervals of roughly
50-150 ms; below that the flashes are seen as simultaneous; two clearly successive events need
several hundred ms (their own successive condition used 300-500 ms). Korte's third law says the
usable motion range narrows as the spatial gap grows, so lights a few centimetres apart on a phone
sit at the short-distance end where motion is easiest to get and succession hardest.

## 3. Hearing two clicks as two

Hirsh, *J. Acoust. Soc. Am.* 31(6):759-767, 1959, doi:10.1121/1.1907782: a few milliseconds of
separation is enough to report two sounds rather than one, but 15-20 ms (his estimate 17 ms) is
needed to report correctly which came first. Reviewed in Divenyi, *Seminars in Hearing* 25, 2004
(PMC1363770), which also divides auditory time into 1-20 ms, 20-100 ms, and >100 ms ranges.

Gap detection converges on the same lower bound: Plomp 1964, with Penner 1977 and Green 1985,
gives a minimum detectable silent gap in broadband noise of about 2-3 ms (trained listeners 2-4 ms).

The ear is therefore roughly an order of magnitude faster than the eye at splitting two events.

## 4. Can the light mislead the ear?

Aschersleben & Bertelson, *Int. J. Psychophysiology* 50(1-2):157-163, 2003,
doi:10.1016/S0167-8760(03)00131-4, separated the two directions of temporal ventriloquism with a
tapping task. A to-be-ignored sound biased the perceived time of a flash strongly; a to-be-ignored
flash biased the perceived time of a sound "significantly here also... but to a much lesser
extent". Their conclusion: "audition plays a bigger role than vision in temporal ventriloquism and
is probably generally superior to vision for processing the temporal dimension of events."
Morein-Zamir, Soto-Faraco & Kingstone, "Auditory capture of vision: examining temporal
ventriloquism", *Cognitive Brain Research* 17(1):154-163, 2003 (PMID 12763201), show the strong direction: sounds flanking two lights pull the
lights apart in time and improve visual order judgements.

Neither paper gives a millisecond magnitude for the weak direction. What the sources support: a
light can bias perceived click timing, but less than the reverse.

## 5. Arithmetic at 72 BPM (833 ms period)

Beat period 60000/72 = 833.3 ms. App thresholds: tell the user above 40 ms; replace the
measurement below 10 ms. As a fraction of the beat: 40/833.3 = 4.8%, 10/833.3 = 1.2%.

Let g be the arrival-time gap between the two speakers at the listener.

- (a) **Two flashes seen as two.** Needs g above the two-flash/succession limit. Same location:
  ~35-70 ms (Samaha & Postle 2015). Two locations a few cm apart: above ~50 ms the pair reads as
  apparent motion, and unambiguous succession needs hundreds of ms (PLOS ONE e110224, 2014 and the
  sources it cites). Lower bound for "visibly two" is therefore ≈50 ms at best, and much higher
  if succession rather than motion is required.
- (b) **Flashes fuse, ear still hears two.** 2 ms ≲ g < ~50 ms (Hirsh 1959 lower bound; Plomp
  1964 gap detection; visual bound from (a)). Order of arrival becomes reportable by ear at
  15-20 ms (Hirsh 1959), still far below the visual limit.
- (c) **Both fuse.** g < ~2 ms.

Consequence of the numbers: the app's whole working range, 0-40 ms, falls inside band (b). At the
40 ms tell threshold, 40 < 50, so the two lights are below the two-event limit; at the 10 ms
replace threshold the ear can hear two clicks (10 > 2) but cannot reliably order them (10 < 17).
Separately, a light mistimed against its click by up to 45 ms is inside ITU-R BT.1359-1's
undetectability plateau, so the flashes' own timing error against the sound is invisible across
this entire range.

## Gaps in the evidence

No cited source measures two-flash discrimination at a centimetre-scale separation on a hand-held
emissive display, nor at the brightness and duration such a display would use. Both the two-flash
threshold (Samaha & Postle 2015) and flicker fusion (PLOS ONE 2024) vary ~2x between individuals.
No millisecond figure exists in these sources for vision biasing perceived click timing.
