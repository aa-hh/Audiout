# Core — capture and native backend — review

## Verdict
The audio maths, the Core Audio error handling and the concurrency choreography are stronger than almost any codebase of this size: every `AudioObjectGetPropertyData`/`SetPropertyData` result is checked, NaN and zero sample rates are guarded, listener add/remove is symmetric, and the lock-ordering rules are stated and kept. The comment density is the opposite problem — a cold reviewer reads ~1,400 lines of prose in `NativeBackend.swift` before the first executable statement, and several of those comments are now false. The real defects cluster in two places: persisted user state is loaded with `try?` and silently reset on any read failure (five stores, including measured speaker latencies), and the real-time contract is asserted but contradicted inside a single buffer — `handleBuffer` refuses to block on a two-instruction `NSLock` and drops audio instead, then three lines later takes a plain blocking `lock.lock()` around an `AVAudioConverter` run. The single highest-impact change is splitting `NativeBackend.swift` (13,222 lines, 234 stored properties, 8 protocol conformances on one type) along the partition seams it already names.

## Counts
BUG: 9 · SUBSTANCE: 11 · COSMETIC: 5 · files read: 20 / files in area: 20

## Findings

### 1. [BUG] Every persisted user setting is loaded with `try?` and silently reset to defaults on read failure
- Where: `NativeBackend.swift:1785`, `:1788`, `:1791`, `:1798`, `:1804`
- Evidence: `if let loaded = (try? btTrimStore?.load()) ?? nil { … }` / `if let latencies = (try? btTrimStore?.loadLatencies()) ?? nil { … }`
- Why: a truncated store silently drops measured BT latencies, sync trims, Cast offsets and per-device EQ to zero. Every WRITE on the same stores is handled (`StoreRecovery.noteWriteFailure`, `eq_save_failed`).
- Fix: `do/catch` each through `StoreRecovery.noteWriteFailure`; keep defaults-on-failure.
- Confidence: high

### 2. [BUG] `DefaultOutputDeviceMonitor` leaks one `DispatchWorkItem` per notification (retain cycle)
- Where: `DefaultOutputDeviceMonitor.swift:383-395`
- Evidence: `var item: DispatchWorkItem!; item = DispatchWorkItem { [weak self] in guard let self, !item.isCancelled else { return }` — block captures `item` strongly, item owns block.
- Why: one per default-output/rate notification (BT connect burst = four per connect), on the single process-wide monitor.
- Fix: drop the `!item.isCancelled` check (DispatchWorkItem already skips a cancelled block).
- Confidence: high

### 3. [BUG] `MixTimeline.add` allocates before the pending-frames cap is applied
- Where: `AppRouteMixer.swift:614-617` (allocation), `:641-643` (cap)
- Evidence: `if neededEnd > endFrame { acc.append(contentsOf: [Int32](repeating: 0, count: Int(neededEnd - endFrame) * 2)) }`; `firstFrame` from `mHostTime` rebase which clamps negative to 0.
- Why: one buffer whose pts clamps to 0 while the accumulator sits at boot-scaled frames asks for a multi-gigabyte append; `maxPendingFrames` only acts in `drainReady`, after this.
- Fix: clamp `neededEnd` to `startFrame + maxPendingFrames` inside `add`.
- Confidence: medium

### 4. [BUG] The real-time contract is asserted, then broken three lines later in the same buffer
- Where: `NativeCaptureCoordinator.swift:1683-1688`, `:1696`, `:4419-4420`, `:3766`; same label at `PerAppCaptureCoordinator.swift:1346`
- Evidence: `if snapshotLock.try() { … } else { return }` (drops the buffer rather than park), then `converter.convertToAirPlayPCM(buffer)` whose body is `lock.lock(); defer { lock.unlock() }` around an AVAudioConverter run and two AVAudioPCMBuffer allocs. Block labelled `// ---- REALTIME THREAD ----` while registered on an explicit `.userInitiated` serial DispatchQueue.
- Fix: settle the question in one comment at the IOProc registration site and make both sites agree.
- Confidence: high (inconsistency); medium (which side is right)

### 5. [BUG] "Play everywhere" and per-app local playback fail silently — `try?` on every engine start
- Where: `NativeBackend.swift:4474`, `:5243-5244`, `:5348-5349`, `:10217-10218`
- Evidence: `try? sink.start()`; `SyncedLocalSink.start()` / `LocalPlaybackEngine.start()/addApp` throw via `catchingObjCException`.
- Why: Mac stays silent in a play-everywhere selection, or a "This Mac"-routed app stops playing, no telemetry, no retry.
- Fix: `do/catch` with `Telemetry.fail(.localPlayback, "local_playback:start_failed", …)`.
- Confidence: high

### 6. [SUBSTANCE] `NativeBackend.swift` is 13,222 lines and one 234-property type — unreviewable cold
- Where: `NativeBackend.swift:64`, whole file. One class conforming to OutputBackend, LatencyConfigurable, MeteringControlling, AppRouteConfiguring, BTOutputControlling, LocalSyncOffsetControlling, CastSyncOffsetControlling, @unchecked Sendable. Correctness rules are per-property queue confinements across four locks and three queues.
- Fix: extract the Bluetooth surface (~2,500 lines) and Cast (~400) into `NativeBackend+Bluetooth.swift` / `NativeBackend+Cast.swift` (already `extension NativeBackend`); per-app routing (`updateAppRoutes` → `performBindOp` → `enqueueRebindRecovery`, ~1,800) next.
- Confidence: high

### 7. [SUBSTANCE] `PerAppCaptureCoordinator`'s header states two things that are false today
- Where: `PerAppCaptureCoordinator.swift:32-40`, `:68-71`
- Evidence: header says `CoreAudioSystemTap` uses the wrong selector with "fix pending" — `CoreAudioSystemTap.defaultOutputDeviceID()` (`NativeCaptureCoordinator.swift:4243`) already uses the correct one with a build-failing guard. Header says "Not wired in yet … Nothing else in the app calls it" — `NativeBackend` owns two live instances (`perAppCapture`, `meteringCapture`).
- Fix: delete both paragraphs.
- Confidence: high

### 8. [BUG] The quit-time restore of the user's prior default output is unchecked and unlogged
- Where: `NativeBackend.swift:2799` — `_ = self.aggregateControl.setDefaultOutputDevice(priorID)` then `sweepOrphans()` destroys the aggregate one line later. Sibling path `restoreWriteReturned` → `verifyRestoreLanded` (`:8452-8494`) exists because "the documented failure mode in this area is acceptance without effect".
- Fix: capture the Bool, emit the existing `aggregate_default_restore` line with outcome.
- Confidence: high

### 9. [BUG] `DefaultOutputObserver` overwrites an ARC-managed `CFString` with a raw HAL write
- Where: `DefaultOutputObserver.swift:129-138` — `var name: CFString = "" as CFString; … AudioObjectGetPropertyData(…, &name)`. Siblings do it correctly with `CFString?` + `withUnsafeMutablePointer` (`NativeCaptureCoordinator.swift:4256`, `AggregateOutputDevice.swift:262`, `AudioProcessResolver.swift:566`).
- Fix: copy the sibling shape.
- Confidence: medium

### 10. [BUG] Both mixers block the tap delivery thread on a default-QoS serial queue
- Where: `AppRouteMixer.swift:389-390`, `LeveledAppInjector.swift:264-266` — `handleBuffer` does `queue.sync {` on an unqualified `DispatchQueue(label: "AppRouteMixer.state")` that `updateRoutes`/`removeApp`/`flush`/`destinationSets` take from main. Same priority inversion the T8 refactor (`NativeCaptureCoordinator.swift:1660-1681`) removed from the whole-system path. `LeveledAppInjector.handleBuffer` runs an AVAudioConverter inside the held queue.
- Fix: T8 pattern — immutable snapshot published under the queue, `try()`-guarded read on delivery.
- Confidence: high (blocking); medium (audibility)

### 11. [SUBSTANCE] `AudioDiag`'s live-handle counters are dead code, and a test asserts it
- Where: `AudioDiag.swift:71-134` — `handleCreated`/`handleDestroyed`/`dumpLiveHandles` referenced only by AudioDiag.swift and AudioDiagTests.swift; the test says nothing calls them.
- Fix: wire from the four real sites (`CoreAudioSystemTap.createTapAndReadFormat`/`createAggregate`/`startIOProc`/`teardown` + per-app twins) or delete `HandleCounter`, its statics and the test.
- Confidence: high

### 12. [BUG] `CaptureCoordinator` can re-enter its own serial queue synchronously
- Where: `CaptureCoordinator.swift:271-282`, `:299-302` — `spawnCapture` runs `proc.start(… onStderrLine: { self?.handleStderrLine(line) })` inside `queue.sync`; `handleStderrLine` does `queue.sync`. A `CaptureProcess` delivering a line synchronously from `start` traps. Same shape: `transition(to:)` calling `onStateChange` inside `queue.sync` while `state` getter is `queue.sync`.
- Fix: hoist `proc.start` out of the sync block (the claim/act-outside shape `NativeCaptureCoordinator.start()` uses).
- Confidence: medium

### 13. [SUBSTANCE] Two identical no-op `AudioProcessEnumerating` types
- Where: `NativeBackend.swift:58-62` (`NoAudioProcesses`), `NativeCaptureCoordinator.swift:2776-2780` (`EmptyAudioProcessEnumerator`).
- Fix: keep `EmptyAudioProcessEnumerator`, delete `NoAudioProcesses`, update three NativeBackend defaults plus `OwnToneBackend.swift:852`.
- Confidence: high

### 14. [BUG] `DefaultOutputObserver.currentDeviceName` is an unsynchronised cross-thread `String`
- Where: `DefaultOutputObserver.swift:17-19`, `:56-57` — doc says "Readable from any thread (only mutated on queue)"; that orders the write, not the read. Carries a `STABILITY(D6)` accepted-risk marker; flagged because the doc asserts safety it does not have.
- Fix: NSLock pattern from `SystemOutputVolume._onExternalChange`, or `queue.sync` getter.
- Confidence: medium

### 15. [SUBSTANCE] 22 test-only members on the shipping backend type, three of them load-bearing
- Where: `NativeBackend.swift:540-542`, `:1517-1582`, `:7740-7786` — `var test_companionAuditionPreparationSeconds: TimeInterval = 4`, `test_companionAuditionLeaseSeconds = 600` consumed at `:12072-12073` for the real deadline and lease.
- Fix: rename the three timing knobs; move read-only accessors to `NativeBackend+TestSupport.swift`.
- Confidence: high

### 16. [SUBSTANCE] `AudioProcessResolver` allocates 16 KB per process object per resolve
- Where: `AudioProcessResolver.swift:425-432` — `[CChar](repeating: 0, count: 4 * Int(PATH_MAX))` inside the per-process loop, on every tap rebuild / exclusion diff / per-app start.
- Fix: `withUnsafeTemporaryAllocation`, or resolve each pid once into a dictionary.
- Confidence: high

### 17. [SUBSTANCE] The `mHostTime → CLOCK_MONOTONIC` trio is copied between the two taps
- Where: `NativeCaptureCoordinator.swift:4190-4224`, `PerAppCaptureCoordinator.swift:1419-1446` — `machNanoseconds(fromHostTime:)`, `cachedTimebase`, `currentMonotonicNanos()`, `sampleMachToMonotonicOffsetNanos()` byte-identical; comment says duplicated because originals are `private`.
- Fix: make the four `internal` on `CoreAudioSystemTap`, delete the copies.
- Confidence: high

### 18. [SUBSTANCE] `PCMDelayLine.exchange(_:)`'s `Data` round-trip contradicts its own header contract
- Where: `PCMDelayLine.swift:28-33` (header: "REAL-TIME (no allocation …)"), `:125-135` (`var delayed = pcm; exchange(&delayed)` = COW heap alloc; the `razor:` note admits it).
- Fix: move the admission into the thread-contract paragraph, or take the preallocated-scratch upgrade.
- Confidence: high

### 19. [COSMETIC] `let channels = …; _ = channels` — leftover scaffolding in the IOProc setup
- Where: `NativeCaptureCoordinator.swift:3748`, `:3812`. Delete both lines.
- Confidence: high

### 20. [SUBSTANCE] `handleBuffer` is ~140 lines doing seven things
- Where: `NativeCaptureCoordinator.swift:1659-1801` — snapshot → wizard gate → convert → failure sampling → leveled mix → Main EQ → tick mix → rebuild-gap fill → dropped-cycle fill → fallback-clock stamp → deliver; two gap-arithmetic blocks inline (`:1739-1791`).
- Fix: extract `patchFeedGapIfNeeded(buffer:pcmByteCount:snapshot:)` — both share `fillFeedGap`.
- Confidence: high

### 21. [SUBSTANCE] `NativeBackend.stop()` is a 350-line teardown with no structure
- Where: `NativeBackend.swift:2463-2812`; teardown order is load-bearing (`captureControlQueue` FIFO relied on at `:2665-2684`).
- Fix: `stopCallbacksAndSources()`, `stopAudioPaths()`, and the `stateQueue.async` reset block.
- Confidence: medium

### 22. [COSMETIC] Force unwrap on a dictionary lookup in the binding diff
- Where: `NativeBackend.swift:6461` — `let outputID = self.outputIDs[deviceID]!`; safe today because of a `where` four lines up in a different loop.
- Fix: carry the id in `newBindings` as `[String: (OutputID, UInt32)]`.
- Confidence: high

### 23. [SUBSTANCE] `AppRouteMixer.assignStreamIDs` force-unwraps and mutates shared state inside a nested function
- Where: `AppRouteMixer.swift:323-350` — `func take(_ index: Int) -> Int { reusable.remove(at: index).streamID }` + `devicesBySignature[signature]!`.
- Fix: inline `take`, iterate `devicesBySignature` as pairs.
- Confidence: high

### 24. [COSMETIC] `PerAppCaptureError.appNotRunning` is unreachable and documented as such
- Where: `PerAppCaptureCoordinator.swift:905-910`. Delete the case and its two switch arms.
- Confidence: high

### 25. [COSMETIC] `TapReanchor`'s rate-only initializer has no caller
- Where: `TapRebuildLifecycle.swift:150-156`; both call sites (`NativeCaptureCoordinator.swift:2442`, `PerAppCaptureCoordinator.swift:585`) use the four-argument init. Delete it.
- Confidence: high

## Also noted
- `NativeBackend.swift:2082` — `_ = self.publicAggregate.adoptOrCreate()` at launch: a failed create is invisible.
- `NativeBackend.swift:1971`, `:1976`, `:3616-3617`, `:5038` — `stateQueue.sync` from main, self-labelled `STABILITY(C8)`; `setOutputSet`'s critical section is ~350 lines incl. `Telemetry.log` formatting.
- `NativeCaptureCoordinator.swift:4401-4417` — `sampleConversionFailuresIfDue` reads `failureCounts` without the lock `failed(_:)` writes under.
- `LeveledAppInjector.swift:391-402` — `SampleRing.write` does two `%` per sample; masked power-of-two ring would be free.
- `NativeBackend.swift:10058` — `connectVolumeSeed`: 40 lines of code under 100 lines of doc comment.
- `NativeCaptureCoordinator.swift:2568-2598` — `fanOutSplitToBT` allocates two fresh `[Float]` per buffer on the delivery path.
- `AudioProcessResolver.swift:414-421` — `dlsym(RTLD_DEFAULT)` `-2` bit-pattern deserves a named constant.
- `CaptureCoordinator.swift:171-181` — `defaultAudiocapBinaryPath` / `defaultLibraryDirectory` hardcode `dev/` paths as `public static var` on a shipping type.
