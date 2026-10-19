# Core — sync, Bluetooth timing and local playback — review

## Verdict

This is the most carefully documented area of the codebase I have seen: the lock-free rings, the
sign conventions and the release gate all carry the reasoning a cold reviewer needs, and the two
licence-clean files (`SyncCore.swift`, `BTSyncedSink.swift`) are clean — no GPL header, no
GPL-shaped code, the DSP derived from the project's own spike and the file-top notes say so.
The defects that remain are the ones long comments cannot catch: a strong reference where the
comment says "unowned", a restart failure swallowed by `try?`, unsynchronized reads behind a
generation counter, and — the one with the widest blast radius — two real-time render callbacks
calling a clock-rebase helper whose own doc comment says production must never call it per buffer.
The single highest-impact change is fixing that rebase: give `SyncedLocalSink` and `BTDeviceSink`
the cached per-instance mach-to-monotonic offset the capture path already uses, instead of
resampling both clocks inside every render cycle. Readability of the statistical code
(`BTAlignmentPosterior`, `DriftCorrectionPolicy`) is genuinely good — the constants carry their
measured provenance — though `BTSyncedSink.swift` at 1772 lines and four types is past what anyone
can hold at once.

## Findings

### 1. [BUG] Both synced render callbacks resample two clocks per cycle through a helper marked "test/convenience"
- Where: `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift:650`,
  `AudioutCore/Sources/AudioutCore/BTSyncedSink.swift:1128`, contract at
  `AudioutCore/Sources/AudioutCore/NativeCaptureCoordinator.swift:4177`
- Evidence:
  ```swift
  // NativeCaptureCoordinator.swift:4177
  /// Test/convenience entry point: derives a fresh offset every call (no
  /// caching) ... Production code must go through the instance path
  /// (seeded in `startIOProc`, healed in the IOProc block) instead, since
  /// resampling both clocks on every single call is not something we want to
  /// pay for on every real captured buffer.
  static func timespec(fromHostTime hostTime: UInt64) -> timespec {
  ```
  ```swift
  // BTSyncedSink.swift:1128 — inside `render`, every cycle
  let cycleStart = SyncTiming.monotonicNanos(
      CoreAudioSystemTap.timespec(fromHostTime: timestamp.pointee.mHostTime))
  ```
- Why it matters: every render cycle on every Bluetooth sink and on the Mac's own sink pays a fresh
  `mach_absolute_time` + `clock_gettime` pair, and the sampling error between those two reads lands
  directly in the value the release gate compares against and that `PhaseController` reads as phase
  error — so the PI loop is fed per-cycle noise it will try to null.
- Fix: seed a per-sink offset at `startLocked()`/`start()` and rebase with the cached
  `CoreAudioSystemTap.timespec(machNanos:offset:)`, re-seeding on the same rebuild edges that
  already void the session anchor.
- Confidence: high (that the per-cycle call happens and contradicts the helper's contract); medium
  on how audible the added jitter is.

### 2. [BUG] `SyncedLocalSink`'s render-block box is a strong reference, so the sink never deinits
- Where: `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift:190`
- Evidence:
  ```swift
  // Render block built with an unowned box so `self` can wire it in the same
  // init; it is only ever invoked between `start()` and `stop()`.
  var boxed: SyncedLocalSink?
  self.sourceNode = AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, audioBufferList in
      boxed?.render(...) ?? noErr
  }
  boxed = self
  ```
- Why it matters: the comment says "unowned box" but `boxed` is a strong optional captured by the
  escaping render closure, so `self -> sourceNode -> closure -> box -> self` is a cycle. `deinit`
  (line 199) — which removes the process-wide `kAudioHardwarePropertyDefaultOutputDevice` listener
  and frees the deinterleave scratch — can never run. The sibling `BTDeviceSink.makeSourceNode`
  (`BTSyncedSink.swift:1102`) does this correctly with `[weak self]`.
- Fix: capture `[weak self]` in the source-node block exactly as `BTDeviceSink` does, and drop the
  box.
- Confidence: high

### 3. [BUG] A failed engine restart after a device change or wake is swallowed and never logged
- Where: `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift:372`
- Evidence:
  ```swift
  restartEngine: { [weak self] in try? self?.start() })
  ```
- Why it matters: `performLifecycleRebuild()` runs on every default-output change, sleep and wake.
  If `start()` throws (the new device rejects the format, a config change is mid-flight), the Mac's
  own speakers stay silent until the next lifecycle event and nothing anywhere records why. The
  Bluetooth twin logs it — `BTSyncedSink.startSink` emits `bt_sink_start_failed`
  (`BTSyncedSink.swift:1751`).
- Fix: `do/catch` around `start()` and emit `Telemetry.fail(.localPlayback, "sync:restart_failed",
  local: ["error": ...])`, matching `startSink`'s posture.
- Confidence: high

### 4. [BUG] `ReferenceAudioRing.slice` reads plain Swift properties with no synchronization
- Where: `AudioutCore/Sources/AudioutCore/ReferenceAudioRing.swift:150`, fields at 43-48, writer at
  90-131
- Evidence:
  ```swift
  for _ in 0..<4 {
      let before = generationPtr.pointee
      guard before % 2 == 0 else { continue }
      OSMemoryBarrier()
      let candidate = sliceUnsynchronized(fromNanos: fromNanos, toNanos: toNanos)
  ```
  `sliceUnsynchronized` reads `retainedFrames`, `writeFrame`, `endPtsNanos` and `ring` — ordinary
  `private var`s — while `append` mutates all four under `lock`.
- Why it matters: the generation counter discards a torn RESULT, but the reads themselves are a
  data race on non-atomic properties; TSan flags it and the compiler is free to reorder or cache
  them. Every other ring in this area (`BTFrameRing`, `InterleavedFloatRing`, `BTDelayLine`) puts
  its cross-thread words in dedicated aligned heap cells for exactly this reason and says so.
- Fix: move the three counters into `UnsafeMutablePointer<Int>`/`<Int64>` cells like the sibling
  rings, or take the lock for the bookkeeping read and copy outside it.
- Confidence: medium (memory safety holds — every index is masked; the defect is the undefined
  reads and the mismatch with the neighbours' stated discipline)

### 5. [BUG] `fatalError` on a sample rate that comes from the OS
- Where: `AudioutCore/Sources/AudioutCore/BTSyncedSink.swift:656`,
  `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift:186`
- Evidence:
  ```swift
  guard let format = AVAudioFormat(
      standardFormatWithSampleRate: renderSampleRate,
      channels: AVAudioChannelCount(channels))
  else {
      fatalError("BTDeviceSink: no standard \(renderSampleRate)/\(channels)ch format")
  }
  ```
  `SyncedLocalSink`'s rate is read from the default output device
  (`OwnToneBackend.swift:966`: `LocalOutputLatency.defaultOutputDeviceNominalSampleRate()`).
- Why it matters: a device reporting a rate `AVAudioFormat` will not build aborts the whole app.
  Every other construction failure in these two files fails soft (`BTDeviceSinkError`,
  `LocalPlaybackError.unsupportedFormat`).
- Fix: make both inits failable (or throwing) and let the factory fall back to 48 kHz, the way
  `OwnToneBackend` already falls back when the rate read itself fails.
- Confidence: medium (the rate is validated `isFinite, > 0` upstream and the channel count is 2, so
  the nil case is narrow — but the input is still OS-supplied)

### 6. [BUG] A microphone recorder whose `start()` throws late leaks itself and its installed tap
- Where: `AudioutCore/Sources/AudioutCore/MicProbeSession.swift:164`,
  `AudioutCore/Sources/AudioutCore/PassiveDriftSampler.swift:706`
- Evidence:
  ```swift
  // MicProbeSession.swift:164 — strong `self`, released only by removeTap in stop()
  engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { [self] buffer, when in
  ...
  try engine.start()     // line 193: throws AFTER the tap is installed
  ```
  ```swift
  // PassiveDriftSampler.swift:706 — the recorder is dropped without stop()
  let recorder = makeRecorder()
  ring.setArmed(true)
  guard let captureRate = try? recorder.start(), captureRate > 0 else {
      ring.setArmed(false)
      ... return false
  ```
- Why it matters: the tap closure captures `self` strongly and the engine holds the closure, so a
  recorder that never reaches `stop()` is retained forever along with its `AVAudioEngine` and its
  configuration-change observer. One per failed window.
- Fix: `[weak self]` in the tap closure, and roll the tap back in `tapAndStart`'s throwing path
  (`engine.inputNode.removeTap(onBus: 0)` before rethrowing).
- Confidence: high

### 7. [SUBSTANCE] Stale comment: the clock rebase is claimed to be pre-roll only, but runs every cycle
- Where: `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift:643`
- Evidence:
  ```swift
  // Called only while still gated: once `released`, `renderInterleaved`
  // short-circuits before this timeline read, so the two `clock_gettime`
  // calls the helper resamples are paid during pre-roll only, not steady state.
  ```
  The rebase at line 650 runs before `renderInterleaved` is called at all, and the T-CORRECTION
  phase loop inside it needs `cycleStartMonotonicNanos` on every cycle (line 750).
- Why it matters: the comment is the reason a reader would believe finding 1 is not a problem.
- Fix: delete the claim; if finding 1 is fixed the cost question goes away with it.
- Confidence: high

### 8. [SUBSTANCE] `LocalPlaybackEngine.receive` allocates twice per buffer on the thread its own doc calls real-time
- Where: `AudioutCore/Sources/AudioutCore/LocalPlaybackEngine.swift:703`, allocations at 734 and 737
- Evidence:
  ```swift
  guard let src = Self.makeBuffer(buffer, format: node.sourceFormat) else { return }   // AVAudioPCMBuffer alloc
  let pcm: AVAudioPCMBuffer
  if let converter = node.converter {
      guard let out = AVAudioPCMBuffer(                                                 // second alloc
          pcmFormat: node.connectionFormat, frameCapacity: src.frameLength) else { return }
  ```
  The class header says "`receive(buffer:for:)` runs on the real-time IO callback thread and only
  ever takes `stateLock` (non-blocking `try()`)".
- Why it matters: the whole reason `BTDeviceSink` stashes telemetry records instead of formatting
  them is that this thread must not allocate; this file allocates two PCM buffers and runs an
  `AVAudioConverter` on it every buffer.
- Fix: pre-allocate a small pool of `AVAudioPCMBuffer`s per `AppNode` at `addApp` time (format and
  maximum frame count are both known there) and refill them in place.
- Confidence: medium (the buffers must outlive the call for `scheduleBuffer`, so a pool is needed
  rather than one reused buffer — but the current code is unambiguously allocating)

### 9. [SUBSTANCE] Leftover diagnostic scaffolding, marked temporary, still shipping
- Where: `AudioutCore/Sources/AudioutCore/LocalPlaybackEngine.swift:774`
- Evidence:
  ```swift
  // Diagnostic buffer counters (every 100th buffer logged), temporary.
  private static let diagLock = NSLock()
  private nonisolated(unsafe) static var scheduledCounts: [String: Int] = [:]
  private nonisolated(unsafe) static var dropCounts: [String: Int] = [:]
  ```
- Why it matters: two process-global mutable dictionaries plus a lock taken on the tap delivery
  thread for every scheduled buffer whenever `AudioDiag.isEnabled`, and the comment itself says it
  was never meant to stay.
- Fix: delete both counters and the two `tick*` helpers, or fold the numbers into the existing
  `Telemetry.log(.localPlayback, ...)` lines this file already emits.
- Confidence: high

### 10. [SUBSTANCE] `readActiveOutputStreamLatency` reads the first stream, not the active one
- Where: `AudioutCore/Sources/AudioutCore/LocalOutputLatency.swift:124`
- Evidence:
  ```swift
  private static func readActiveOutputStreamLatency(_ deviceID: AudioObjectID) throws -> UInt32 {
      ...
      guard err == noErr, let activeStream = streams.first else { ... }
      return try readUInt32(activeStream, selector: kAudioStreamPropertyLatency, ...)
  ```
- Why it matters: the name (and the local `activeStream`) promise a check against
  `kAudioStreamPropertyIsActive` that the body never makes; on a multi-stream device this silently
  measures the wrong stream, and that latency goes straight into the Mac's release delay.
- Fix: either filter on `kAudioStreamPropertyIsActive`, or rename to
  `readFirstOutputStreamLatency` and say in one line why the first stream is good enough.
- Confidence: high

### 11. [SUBSTANCE] `BTDeviceEnumerator` invokes its snapshot handler while holding its own serial queue, and its accessors `queue.sync`
- Where: `AudioutCore/Sources/AudioutCore/BTDeviceEnumerator.swift:127`, `234`, `254`
- Evidence:
  ```swift
  var onSnapshot: (@Sendable ([BTDeviceSnapshot]) -> Void)? {
      get { queue.sync { _onSnapshot } }
      set { queue.sync { _onSnapshot = newValue } }
  }
  ...
  func refresh() { queue.sync { refreshLocked() } }
  ...
  _onSnapshot?(merged)      // called from refreshLocked, on `queue`
  ```
- Why it matters: any handler that reads `onSnapshot`, sets it, or calls `refresh()` deadlocks.
  The sibling `BTConnectionManager.startObservingConnections`
  (`BTConnectionManager.swift:219`) carries a comment about having been live-hit by exactly this
  shape and moved its call outside the critical section.
- Fix: snapshot the handler under the queue and invoke it after returning, the way
  `BTSpeakerTiming` returns `_onChange` from its `lock.withLock` and calls it outside.
- Confidence: medium (no current caller proven to re-enter; the hazard is structural)

### 12. [SUBSTANCE] `BTSyncedSink.swift` is 1772 lines and four types
- Where: `AudioutCore/Sources/AudioutCore/BTSyncedSink.swift:1` (whole file)
- Evidence: `BTReferenceTimeline` (45-107), `BTFrameRing` (122-244), `BTDelayLine` (260-444),
  `BTDeviceSink` (485-1306), `BTSyncedSink` (1323-1772).
- Why it matters: a cold reviewer has to hold a wait-free ring, a crossfading delay line, a
  per-device engine and an N-instance manager at once; the lock-order rule spans three of them.
- Fix: split the two ring types into `BTDelayLine.swift` — they depend on no `AVAudioEngine` and
  are the pieces most worth reading in isolation — leaving the sink and its manager together.
- Confidence: high

### 13. [SUBSTANCE] The resampler's prime-time underrun silently drops already-consumed frames
- Where: `AudioutCore/Sources/AudioutCore/SyncCore.swift:235`
- Evidence:
  ```swift
  // Only mark primed once all three land, so a (near-impossible, given the
  // seconds of pre-roll) prime-time underrun just retries next cycle.
  for ch in 0..<cc { d0[ch] = 0 }
  if !pullFrame(d1) { break }
  inputFramesConsumed &+= 1
  if !pullFrame(d2) { break }
  ```
- Why it matters: a break after the first or second pull has already removed those frames from the
  ring and counted them in `inputFramesConsumed`, but the next cycle re-seeds `d1` from a fresh
  pull — so 1-2 frames of audio are dropped and `consumedContentFrames` (the phase loop's input)
  is off by that much. The comment says the cycle simply retries.
- Fix: pull into the scratch slot first and only commit `d1/d2/d3` once all three succeed, the way
  the steady-state shift loop below it already does.
- Confidence: high

### 14. [SUBSTANCE] Wizard enters `.listening` before the host has answered, on the mic-retry path
- Where: `AudioutCore/Sources/AudioutCore/BTAlignmentWizardSession.swift:501`
- Evidence:
  ```swift
  setTick(true)
  enterListening()                       // transitions to .listening
  Analytics.capture("bt_sync:mic_retried")
  requestListening { [weak self] granted in
      guard let self, !self.ended, granted == false, case .listening = self.screen else { return }
      self.endListening()
  }
  ```
- Why it matters: `AudioutCore/AGENTS.md` states "`BTAlignmentWizardSession` enters `.listening`
  only when its host's `requestListening` answers true". Here it enters first and backs out. It is
  safe in practice (a retry only exists after a granted first pass) but the rule and the code now
  disagree, and `bt_sync:mic_retried` fires before the retry is known to have started, against the
  success-gating rule in the project's analytics guidance.
- Fix: move `enterListening()` (and the analytics capture) into the granted branch of the
  `requestListening` callback, matching `start()` at line 359.
- Confidence: high (the doc wins; the code is not broken, only out of step)

### 15. [SUBSTANCE] A loop-invariant condition written as a per-element `where` clause
- Where: `AudioutCore/Sources/AudioutCore/DriftCorrectionPolicy.swift:280`
- Evidence:
  ```swift
  for uid in guessedThisWindow where guessedThisWindow.count > 1 {
      outstanding[uid]?.guessedGroup = guessedThisWindow
      held[uid]?.group = guessedThisWindow
  }
  ```
- Why it matters: the condition does not depend on `uid`, so it reads as a per-element filter while
  meaning "skip the whole loop" — a reader has to stop and check.
- Fix: `if guessedThisWindow.count > 1 { for uid in guessedThisWindow { ... } }`.
- Confidence: high

### 16. [COSMETIC] Dead fallback in a constant that cannot be nil
- Where: `AudioutCore/Sources/AudioutCore/BTAlignmentPosterior.swift:148`
- Evidence:
  ```swift
  private static let lutMarginMs = Int(candidateStepsMs.last ?? 900)
  ```
  `candidateStepsMs` is a literal array ending in `900` seventeen lines above (line 131).
- Why it matters: the `?? 900` implies the array might be empty and duplicates the real value, so a
  future edit to the array can leave the two disagreeing.
- Fix: drop the fallback (`candidateStepsMs[candidateStepsMs.count - 1]`).
- Confidence: high

### 17. [COSMETIC] A `CharacterSet` built once per character
- Where: `AudioutCore/Sources/AudioutCore/BTDeviceEnumerator.swift:328`
- Evidence:
  ```swift
  String(s.uppercased().unicodeScalars.filter { CharacterSet(charactersIn: "0123456789ABCDEF").contains($0) })
  ```
- Why it matters: `normalizedHex` runs for every device and every paired record on every Core Audio
  device-list change, and allocates a fresh `CharacterSet` per scalar.
- Fix: hoist it to `private static let hexScalars = CharacterSet(charactersIn: "0123456789ABCDEF")`.
- Confidence: high

## Also noted

- `BTSyncedSink.swift:1169` — `var processor: EQProcessor?` is declared, then unconditionally
  assigned inside the lock; `let processor = eqProcessor` reads straighter.
- `BTSyncedSink.swift:1170` — a missed `stateLock.try()` returns `false` (silence) even inside the
  keep-alive window, so that cycle is reported as silence to the A2DP transport the keep-alive
  exists to hold open. One cycle, so harmless today; worth a line of comment saying so.
- `BTSyncedSink.swift:1714` — `enqueue(sweepFrames:...)` fans to every sink and ignores
  `perAppClaimedUIDs`, unlike the two `enqueue` overloads above it; the difference is not explained.
- `PassiveDriftSampler.swift:706` — `takeWindow` captures `[self]` strongly in its `asyncAfter`,
  while every other timer in the same type uses `[weak self]`.
- `PassiveDriftSampler.swift:290` — the trailing `for (baseline, peak) in nearestPeak where ...`
  loop exists only to set `contended = true`; `nearestPeak.contains(where:)` says it in one line.
- `MicProbeSession.swift:380` — the debug dump writes into `Logs/Audiout/` without creating the
  directory and swallows the failure with `try?`, so the hatch can silently write nothing.
- `SyncedLocalSink.swift:552` — `stopObservingLifecycleEvents()` does `lifecycleQueue.sync` and is
  called from `deinit`; if `deinit` ever runs on that queue it deadlocks (unreachable today only
  because of finding 2).

## Counts
BUG: 6 · SUBSTANCE: 9 · COSMETIC: 2 · files read: 25 / files in area: 25
