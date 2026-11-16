# Bug report — Audiout @ 0b3aa78b95906320c04bea3826ee3686aa61d255

## Scope
Not the whole repo: it is ~189k lines. To keep to 20 slices of ~1,500 lines, only **102 hand-written, non-UI Swift files (32,363 lines)** were read: `AudioutCore/Sources/AudioutCore/` (minus the 16 largest/OS-glue files listed below) and `AirPlayEngine/Sources/AirPlayEngine/`. Not read: all UI targets, vendored C, tests, scripts, and these files: NativeBackend*.swift, NativeCaptureCoordinator, BTSyncedSink, PerAppCaptureCoordinator, LocalPlaybackEngine, NativeDiscovery, CastOutputManager, SyncedLocalSink, CompanionServer, PTPHelperService, MockBackend, SystemOutputVolume, MicProbeSession, DefaultOutputDeviceMonitor, AudioCapturePermissionProbe.

**Caveat on "failing tests":** this container has no Swift toolchain. "Demonstrated" means a faithful Python/C port of the Swift logic fails as claimed (and passes with the fix). Ports are not the Swift code itself; the fix PRs must add real Swift tests. Several provers shared the scratch folder `tests/p[object Object]` (a brief-templating slip), so some files named `t.py` may have been overwritten by another prover; named test files are intact. Tests are copied to `/mnt/session/outputs/tests/`.

Severity: High = ordinary input → silent wrong result / data loss / never finishes. Medium = crash on ordinary input or wrong result on unusual input. Lower label chosen when torn. Two provers' High/Medium (browseOne, probe) are the same root cause class (continuation never resumed on `.cancelled`).

## 1. [High] AudioutCore/ConnectionDiagnostics.swift:273 — browseOne
- **Status:** demonstrated
- **Input:** Device not advertising, so the 2s sleep task wins the task group
- **Should happen:** After the 2s timeout, browseOne cancels the browser and returns nil. bonjour() and diagnose() finish in about 2s per service type.
- **Happens:** The task group never finishes. browseOne, bonjour() and diagnose() hang forever whenever the device is not advertising.
- **Failing test:** `/tmp/hunt/p[object Object]/test_browse.py` (Python port; fix checked on a copy: True)
- **Fix:** In the stateUpdateHandler, resume on .cancelled as well as .failed: `if case .failed = state { box.resume(with: nil) } else if case .cancelled = state { box.resume(with: nil) }`. Alternatively wrap the continuation in withTaskCancellationHandler and call browser.cancel() in onCancel. The same pattern exists in probe() with connection state handling; probeVerdict should be checked for .cancelled there.

## 2. [High] AudioutCore/ConnectionDiagnostics.swift:318 — probe
- **Status:** demonstrated
- **Input:** Endpoint whose port never answers, so the 3s sleep task wins
- **Should happen:** After 3s with no answer, probe returns .timedOut, so diagnose reports .notResponding.
- **Happens:** probe never returns, so tcpProbe and diagnose hang forever when the port is silent.
- **Failing test:** `/tmp/hunt/pX/t.py` (Python port; fix checked on a copy: True)
- **Fix:** In probeVerdict add `case .cancelled: return .timedOut`. The box is one-shot, so a late .cancelled after .ready or .failed is harmless. The outer result is already taken from group.next(), so the child's value is discarded.

## 3. [Medium] AudioutCore/DACPServer.swift:365 — parse(_:)
- **Status:** demonstrated
- **Input:** GET /ctrl-int/1/x?= HTTP/1.1 (or ?a&=&b). The pair "=" is split with split(separator: "=", maxSplits: 1). Split omits empty subsequences by default, so it returns an empty array.
- **Should happen:** parse returns a DACPRequest (or nil) for "GET /ctrl-int/1/x?= HTTP/1.1" without crashing.
- **Happens:** kv is empty, kv[0] traps, and the whole app dies from one unauthenticated LAN request.
- **Failing test:** `/tmp/hunt/p[object Object]/test_parse.py` (Python port; fix checked on a copy: True)
- **Fix:** After line 364 add: guard let first = kv.first else { continue }. Then use String(first) for the key on line 365 in place of kv[0].

## 4. [Medium] AirPlayEngine/AirPlayEngine.swift:560 — stop() vs start() interleave
- **Status:** demonstrated
- **Input:** Call stop(), and while it awaits engineThread.run (started already false at line 561), call start() from another task
- **Should happen:** After stop() followed by start(), the engine is started, the new thread is in the holder, and the new session's config strings and known outputs are intact.
- **Happens:** The port ends with started=True and holder=None, so the engine thread is gone. start() returned without error. Every later write and op finds no thread.
- **Failing test:** `/tmp/hunt/p[object Object]/port.py` (Python port; fix checked on a copy: True)
- **Fix:** Capture the thread before the await. After the await, return early if engineThreadHolder.current is no longer that thread or if started/starting is true, so a newer start() keeps its state. Alternatively, serialise the two: have start() await any in-flight stop() Task, or add a `stopping` flag to the guard at line 383. The port's `--fixed` mode (`python3 port.py fixed`) checks the thread-identity guard and passes.

## 5. [Medium] AudioutCore/CompanionCoordinator.swift:846 — handleAlignmentTick (stop path) / onReleased / monitorAuditionOwner
- **Status:** confirmed by reading
- **Input:** Phone starts audition (engage selects target and reference not previously in Main Out), then sends setAlignmentTick active=false (the normal stop), or the pair changes and monitorAuditionOwner calls stopAudition.
- **Should happen:** After the phone stops the audition (setAlignmentTick active=false), the target and reference speakers that the audition selected are deselected and the engagedByTarget entry is removed, as the doc at lines 191-196 says.
- **Happens:** The speakers stay selected in Main Out and engagedByTarget keeps the entry until the phone disconnects. The reference speaker keeps playing the user's audio meanwhile.
- **Failing test:** `/tmp/hunt/p[object Object]/test_audition.py` (Python port; fix checked on a copy: True)
- **Fix:** Call releaseEngaged(forTarget:) on the stop path. In the explicit-stop branch (~line 846), call it when the caller owns the audition. In the lease-expiry stop closure, pass a stop closure that also releases. Do the same in the monitorAuditionOwner and samePair-false stop closures: stop: { id in self?.releaseEngaged(forTarget: id); self?.stopAudition(targetID: id) }.

## 6. [Medium] AudioutCore/StoreRecovery.swift:79 — quarantine / preserveCopy / corruptCopyURL
- **Status:** demonstrated
- **Input:** Two quarantine or preserveCopy calls for the same file within one second. The name is base.corrupt-<Int seconds>.json, so both get the same destination.
- **Should happen:** Both corrupt files are set aside under distinct names, the second is recorded in quarantinedFileNames, and the original path is free before the next save.
- **Happens:** The second move fails silently. The corrupt file stays at its path, is not recorded, and the next atomic save overwrites it, destroying the evidence.
- **Failing test:** `/tmp/hunt/p[object Object]/t.py` (Python port; fix checked on a copy: True)
- **Fix:** In corruptCopyURL, if the candidate exists, append a counter: base.corrupt-<secs>-1.json, -2.json and so on, until the name is free. Alternatively use a millisecond or UUID suffix. A copy of the test with a counter loop passes (run with the `fix` argument).

## 7. [Medium] AudioutCore/GroupController.swift:913 — saveCurrentSetupAsGroup / createGroup default volumes
- **Status:** demonstrated
- **Input:** A selected AirPlay member is muted (mute is volume-based: backend volume 0, real level stashed in priorVolume), then Save current setup as scene
- **Should happen:** The scene stores the member's real level (for example 60), taken from priorVolume while the member is muted.
- **Happens:** The scene stores 0 for the muted member. Activating it sets that speaker to 0, so the member's level is lost with no error. It needs a muted member at save time, so I rated it Medium rather than High.
- **Failing test:** `/tmp/hunt/p[object Object]/t.py` (Python port; fix checked on a copy: True)
- **Fix:** Add a helper in GroupController, `savedLevel(id) = memberState[id]?.explicitMute == true ? (memberState[id]?.priorVolume ?? device(id)?.volume) : device(id)?.volume`. Use it in place of `$0.volume` at line ~913 and in the createGroup default at line ~892. Local-device mute is a hardware flag with priorVolume nil, so it falls back to device.volume as before.

## 8. [Medium] AudioutCore/AppRouteMixer.swift:731 — MixTimeline.drainReady / MixTimeline.add
- **Status:** demonstrated
- **Input:** Any stream. readyFrames = frameCount - 441 is always greater than frameCount - 44100, so max(readyFrames, frameCount - maxPendingFrames) never changes the value. The cap is dead code. Also, add() pads the tail with zeros up to firstFrame+frames BEFORE drain runs.
- **Should happen:** Pending timeline stays bounded (about 1 s, or the far-ahead buffer is dropped or restarts the run). No giant allocation or giant emission.
- **Happens:** add() zero-pads the accumulator to the +10 min buffer (26.46M frames; +1 h would be 158M, ~1.27 GB). drainReady then emits one 26.46M-frame buffer, mostly silence.
- **Failing test:** `/tmp/hunt/p/t.py` (Python port; fix checked on a copy: True)
- **Fix:** In MixTimeline.add, before the `!hasData` check: if hasData and firstFrame - endFrame > maxPendingFrames (pass the cap in), reset the run (acc = [], hasData = false, hasEmitted = false) so the buffer starts a fresh head. This drops at most the 441 held frames. The dead max() in drainReady can then be removed.

## 9. [Medium] AudioutCore/DiagnosticsBundle.swift:142 — stage(into:snapshot:logsDirectory:storesDirectory:home:)
- **Status:** demonstrated
- **Input:** A decision log (Telemetry file), engine.log or a store JSON such as app-routes.json or groups.json that contains /Users/<name>/... paths. snapshot.json can also contain a home path inside a device name.
- **Should happen:** No file in the bundle contains the home directory; each shows ~ instead.
- **Happens:** snapshot.json, decision log, engine.log, app-routes.json and groups.json keep /Users/alice/... verbatim.
- **Failing test:** `/tmp/hunt/pbug/t.py` (Python port; fix checked on a copy: True)
- **Fix:** Redact snapshot.json and the copied files before writing. For snapshot.json, write redacted(String(decoding: try encoder.encode(snapshot), as: UTF8.self), home: home). For each log or store file, replace copyItem with: if let s = try? String(contentsOf: from, encoding: .utf8) { try redacted(s, home: home).write(to: dest, atomically: true, encoding: .utf8) }. A file that is not valid UTF-8 is skipped or copied as before.

## 10. [Medium] AudioutCore/CompanionCommandDispatcher.swift:668 — applySetAppDestination
- **Status:** demonstrated
- **Input:** setAppDestination(bundleID, kind device, deviceID of a Cast receiver or the local Mac)
- **Should happen:** The remote setAppDestination command is refused with an error for a Cast receiver or the local Mac, matching the popover's picker and resolveGroupTargets.
- **Happens:** The command returns .ok and the Cast or local-Mac id is saved as the app's route destination. For Cast the route is later silently demoted and does nothing.
- **Failing test:** `/tmp/hunt/p0/t.py` (Python port; fix checked on a copy: True)
- **Fix:** In the "device" case, after the existing lookup and before the Main Out check, add: guard device.canBePerAppRouteTarget() else { return .refused("\(device.name) can't be used as an app destination.") }

## 11. [Medium] AudioutCore/CompanionCommandDispatcher.swift:559 — applyUpdateGroup / groupShapeRefusal
- **Status:** demonstrated
- **Input:** updateGroup (or createGroup) with memberIDs containing duplicate ids, or an updateGroup whose member set equals another group's
- **Should happen:** updateGroup (and createGroup) refuse memberIDs with duplicate ids. updateGroup also refuses a member set equal to another existing group's.
- **Happens:** The update is saved and returns ok, giving two groups with the same member set or a group with repeated ids. In the port, updating B to ["x"] when A has ["x"] returns ok, and updating B to ["y","y"] returns ok.
- **Failing test:** `/tmp/hunt/p/t.py` (Python port; fix checked on a copy: True)
- **Fix:** In groupShapeRefusal, refuse when Set(memberIDs).count != memberIDs.count. In applyUpdateGroup, after that check, refuse when groupController.groups.contains { $0.id != state.id && Set($0.memberIDs) == Set(state.memberIDs) } with "A scene with those exact speakers already exists."

## 12. [Medium] AudioutCore/CompanionLicenseActivation.swift:89 — activate(key:completion:)
- **Status:** demonstrated
- **Input:** The Mac holds an active key A. The phone sends a new key B and the server is unreachable.
- **Should happen:** Unreachable server: key B is kept (the comment says "saved either way") and the reply is applied:true.
- **Happens:** Reply is applied:true, but settings.licenseKey is put back to A and B is discarded.
- **Failing test:** `/tmp/hunt/p[object Object]/test_activate.py` (Python port; fix checked on a copy: True)
- **Fix:** Line 89: restore only on a definite refusal. Change `result != .verified(.active)` to `result != .verified(.active), result != .unreachable`.

## 13. [Medium] AudioutCore/DACPServer.swift:146 — startLocked(dacpID:)
- **Status:** confirmed by reading
- **Input:** dacpID whose top nibble(s) are zero, e.g. 0x00001A2B3C4D5E6F
- **Should happen:** For dacpID 0x00001A2B3C4D5E6F, the service name is iTunes_Ctrl_1A2B3C4D5E6F, equal to the unpadded DACP-ID header.
- **Happens:** The service name is iTunes_Ctrl_00001A2B3C4D5E6F, so the receiver cannot find the DACP server and speaker-side volume callbacks never arrive.
- **Failing test:** `/tmp/hunt/p1/t.py` (Python port; fix checked on a copy: True)
- **Fix:** Use String(dacpID, radix: 16, uppercase: true) or String(format: "%llX", dacpID) at lines 146 and 163. The padded format is only correct if airplay.c is changed to pad too.

## 14. [Low] AirPlayEngine/AirPlayEngine.swift:482 — start() init-failure rollback
- **Status:** confirmed by reading
- **Input:** output_airplay.init succeeds (rc 0) but output_raop.init fails (nonzero), or the raop init fn is nil (-103)
- **Should happen:** After a failed init, start() undoes everything it set up: output_raop.deinit, output_airplay.deinit (which joins the events thread) and ptpd_deinit run first, then the hub uninstalls, dispatcher deinit and registry clear, with evbase_player reset to nil. A retry then starts clean.
- **Happens:** The airplay sender, its "airplay events" thread and the PTP binding stay alive. remoteHub.uninstall() runs while that thread can still fire, the config strings are freed while still referenced, and evbase_player stays set. A retry runs airplay_init a second time.
- **Failing test:** `/tmp/hunt/p[object Object]/t.py` (Python port; fix checked on a copy: True)
- **Fix:** In the rollback closure, before completions.uninstall(), add: if let f = output_raop.deinit { f() } (only if raop init was reached; deinit is safe if it is a no-op when uninitialised), if let f = output_airplay.deinit { f() } (only when airplay init returned 0, so skip it when airplay_init itself failed), and ptpd_deinit(). Then, after outputs_registry_clear(), add evbase_player = nil. This mirrors stop(). Make the deinit calls conditional on how far init got, which means carrying that state out of the init closure.

## 15. [Low] AudioutCore/CompanionCoordinator.swift:1127 — makeAlignmentActions cancelProbe
- **Status:** demonstrated
- **Input:** Phone A has a running audition (speaker clicks) on target T, then sends cancelAlignmentProbe for T. Owner is A, kind .audition.
- **Should happen:** Cancel from the audition's owner is refused as busy and leaves the engaged target and reference speakers selected.
- **Happens:** The target and reference speakers are deselected (selected={'T': False, 'R': False}) and the command still returns busy, while the audition keeps running.
- **Failing test:** `/tmp/hunt/p[object Object]/t.py` (Python port; fix checked on a copy: True)
- **Fix:** Move the releaseEngaged block below the legacyAlignmentRefusal guard, or add a check that the owner is not an .audition before releasing.

## 16. [Low] AudioutCore/AppSettings.swift:469 — allowRemoteControl getter
- **Status:** demonstrated
- **Input:** AppSettings(defaults: freshSuite, isDevBuild: true).allowRemoteControl, with the process bundle id not a dev id (e.g. the test runner or the shipping app)
- **Should happen:** AppSettings(isDevBuild: true).allowRemoteControl is false when nothing is stored, and isDevBuild: false gives true.
- **Happens:** The result follows the process bundle id. In a non-dev process, isDevBuild: true returns true. In a dev-id process, isDevBuild: false returns false.
- **Failing test:** `/tmp/hunt/p/t.py` (Python port; fix checked on a copy: True)
- **Fix:** At line 469, change Self.isDevBuild to devBuild, so it reads defaultAllowRemoteControl(isDevBuild: devBuild).

## 17. [Low] AudioutCore/VolumeKeyInterception.swift:155 — VolumeStep.next
- **Status:** demonstrated
- **Input:** current=4 (or 5), up=true, coarse. Also current=7 (or 8), up=false.
- **Should happen:** From an off-grid volume, up moves to the next stop above and down to the next stop below (4 or 5 up gives 6; 7 or 8 down gives 6).
- **Happens:** The index is rounded to the nearest detent before the +/-1, so the nearest stop in the pressed direction is skipped (4 up gives 13, 7 down gives 0). The same applies to fine steps.
- **Failing test:** `/tmp/hunt/p/t.py` (Python port; fix checked on a copy: True)
- **Fix:** Do not round to the nearest index. Build the integer stops [Int((k*stepSize).rounded()) for k in 0...Int(detents)]. Going up, return the smallest stop strictly greater than current, or 100 if none. Going down, return the largest stop strictly less than current, or 0 if none.

## 18. [Low] AudioutCore/DriftCorrectionApplier.swift:206 — apply(_:kind:recordEvent:) / stepSlews
- **Status:** demonstrated
- **Input:** Two or more slew corrections applied in one batch (swapAndRecorrect with 2 corrections, or handle() returning several .correct actions). Each apply() calls startTimerIfNeeded() and then stepSlews().
- **Should happen:** Each device moves 1 ms in the first window (A 1, B 1, C 1).
- **Happens:** A moves 3 ms, B 2 ms and C 1 ms at once, which breaks the 2 ms/s inaudible cap for the first device.
- **Failing test:** `/tmp/hunt/p/t.py` (Python port; fix checked on a copy: True)
- **Fix:** In apply(_:kind:recordEvent:) .slew case, replace the stepSlews() call with a step of only that uid (factor the loop body into stepSlew(uid)). Alternatively drop the immediate step and let the timer's first tick do it. The fix is also in the test port.

## 19. [Low] AudioutCore/AppRouteMixer.swift:442 — handleStateChange
- **Status:** demonstrated
- **Input:** Two-app stream; one app's tap goes to .stopping, .idle or .failed with frames still in the timeline.
- **Should happen:** After an app's tap goes to .stopping/.idle/.failed, its pending frames are emitted or dropped, leaving 0 pending in the stream.
- **Happens:** Pending stays at 441 frames (about 10 ms) in the timeline until another buffer or flush() arrives. The test exits 1 on the current code.
- **Failing test:** `/tmp/hunt/p[object Object]/test_state_flush.py` (Python port; fix checked on a copy: True)
- **Fix:** In the non-capturing branch, drain or drop that stream's timeline under timelineLock. The simplest is to call flush() (or emit drainAll for the app's streams) after removing the converter, then send the emissions to onMixedBuffer outside the lock. In the port, a flush on non-capturing state leaves 0 pending and the test passes.

## 20. [Low] AudioutCore/AppRouteMixer.swift:600 — scaledStereoSamples
- **Status:** demonstrated
- **Input:** sample = -7, volumePercent = 20 (exact -1.4, should round to -1). Also sample -3 at 50 (-1.5) gives -1 while +3 gives 2.
- **Should happen:** -7 at volume 20 scales to -1 (exact -1.4, nearest integer)
- **Happens:** 0 (the port fails on the current code, assertion error, exit 1)
- **Failing test:** `/tmp/hunt/p[object Object]/test_round.py` (Python port; fix checked on a copy: True)
- **Fix:** Round symmetrically by using the sign of the sample for the bias, e.g. `let p = sample * Int32(volume); out[i] = (p >= 0 ? p + 50 : p - 50) / 100` (rounds half away from zero). Floor division `(p + 50) >> 2`-style alternatives also work. I tested floor division `(p+50)//100` in the port, which passes (run with the `fix` argument). I did not run the sign-aware Swift form itself.

## 21. [Low] AudioutCore/BTClockStability.swift:90 — BTClockStability.observe
- **Status:** demonstrated
- **Input:** clock stable 11 s, one stale identical sampleTime tick, then normal samples
- **Should happen:** The .frozen doc says the stable-for count holds, so stableForSeconds stays at 11 across the stale tick and the .ignored sample that follows it.
- **Happens:** The .ignored sample after the freeze zeroes stableForSeconds, so isStable goes false and the clock must be jump-free for 10 s again. This delays the Measure button after any one stale tick.
- **Failing test:** `/tmp/hunt/p[object Object]/test.py` (Python port; fix checked on a copy: True)
- **Fix:** Delete `stableForSeconds = 0` at line 104 in the `guard let base = baseline` else-branch. A fresh detector already starts at 0.

## 22. [Low] AudioutCore/SetupFlowModel.swift:484 — finalCheckState / reopen / skip
- **Status:** demonstrated
- **Input:** The final check passes, so finalCheck = .passed. The user then calls reopen(.bluetooth) and then skip(.bluetooth). Alternatively a required permission is revoked and later re-granted without runFinalCheck running.
- **Should happen:** After reopen(.bluetooth) then skip(.bluetooth), finalCheckState is .pending and isDoneAvailable is false until runFinalCheck() runs again.
- **Happens:** finalCheckState returns the stale .passed and isDoneAvailable is true without a new audit. The Python port asserts "stale passed without new audit" on the current logic.
- **Failing test:** `/tmp/hunt/p[object Object]/t.py` (Python port; fix checked on a copy: True)
- **Fix:** In reopen(), after skippedSteps.remove(step), add `finalCheck = .pending`. This covers the reopen path. The revoke and re-grant path would need the same reset wherever a required permission's status drops, or the check made to run on every regression from ready.

## 23. [Low] AirPlayEngine/CompletionRegistry.swift:110 — CompletionRegistry.uninstall
- **Status:** demonstrated
- **Input:** Registry A is installed, then registry B is installed (displacing A), then A.uninstall() runs.
- **Should happen:** A.uninstall() leaves B's C completion hook installed, so B's waiters still get deliveries.
- **Happens:** A.uninstall() unsets the process-wide hook that B owns. B's in-flight ops are never delivered and only resolve by timeout.
- **Failing test:** `/tmp/hunt/p[object Object]/test_uninstall.py` (Python port; fix checked on a copy: True)
- **Fix:** Move outputs_engine_completion_set(nil, nil) inside the `if CompletionRegistry.shared === self { ... }` block, and set shared to nil there. Cancelling this registry's own waiters stays unconditional. Run with the `fixed` argument, the port passes.

## 24. [Low] AudioutCore/CompanionSnapshotBuilder.swift:162 — build (groupStates memberNames)
- **Status:** demonstrated
- **Input:** A Group whose memberIDs contains the same id twice (hand-edited groups.json or duplicate-add bug), with that id in deviceNames
- **Should happen:** memberNames is {"a":"A","b":"B"}, with no failure.
- **Happens:** The port raises "Fatal error: Duplicate values for key: a", which in the app is a crash trap on the next snapshot build.
- **Failing test:** `/tmp/hunt/p[object Object]/dupmembers/test_dup.py` (Python port; fix checked on a copy: True)
- **Fix:** Replace Dictionary(uniqueKeysWithValues:) with Dictionary(_:uniquingKeysWith: { first, _ in first }), or dedupe memberIDs when decoding the group.

## 25. [Low] AudioutCore/ConnectionDiagnostics.swift:248 — browse
- **Status:** demonstrated
- **Input:** Device absent from both service types
- **Should happen:** Absent-device browse finishes in about 2s, as the type doc says.
- **Happens:** Absent-device browse takes about 4s because the two service types are browsed one after the other.
- **Failing test:** `/tmp/hunt/p/t.py` (Python port; fix checked on a copy: True)
- **Fix:** Browse both service types concurrently, e.g. a task group over serviceTypes returning the first non-nil endpoint. Alternatively, share one 2s deadline across both types.

## 26. [Low] AudioutCore/AirPlayHandoffWatcher.swift:99 — AirPlayHandoffWatcher.start / LogStreamProcess.start
- **Status:** demonstrated
- **Input:** stop() then start() soon after, while the old child is still exiting after SIGTERM (stop() deliberately does not nil `process`)
- **Should happen:** After stop() then start(), a new log stream child is running, or a launch happens once the old child exits.
- **Happens:** The second start() returns without launching, launches=1 in total, and no respawn follows. The watcher stays dead and never detects a handoff, with no error, until the next stop/start.
- **Failing test:** `/tmp/hunt/pX/t.py` (Python port; fix checked on a copy: True)
- **Fix:** In LogStreamProcess.stop(), set process and outputPipe to nil after calling terminate(). The old launch's fireTermination already checks `process === proc`, so its late exit cannot clobber a newer child. A second child may briefly overlap the dying one, which the identity check makes harmless. The edit is checked only in /tmp/hunt/pX/t_fixed.py, a copy of the Python port that nils the process slot in stop(); the test passes there. I did not run it against the Swift code.

## Rejected

- CompanionCommandDispatcher.swift:277 execute(.setAppVolume) (rejected twice or finally): The dispatcher does pass the raw Int at CompanionCommandDispatcher.swift:284. But the only real actuator, NativeBackend.setLocalPlaybackVolume (NativeBackend+PerAppRouting.swift:661-668), clamps with .clampedToVolume before both localPlaybackEngine.setVolume and leveledInjector.setVolume. CompanionCoordinator.swift:257 is the only production wiring of the closure. The other conformer is the no-op default at OutputBackend.swift:612. grep found no other setLocalPlaybackVolume implementer. So 500 or -40 reaches the stream as 100 or 0, matching the stored route. I tried other inputs (other values, a LEVELED route, a backend without local playback) and found no unclamped path. The dispatcher not clamping itself is only a defence-in-depth gap, and the actuator's contract covers it. I wrote no test, because no Swift runs here and a port would only repeat the clamp.

- LocalNetworkPrimer.swift:89 probe() / probeFoundSpeakers() (rejected twice or finally): The behaviour is documented and deliberate. The protocol doc at SetupModel.swift:295 says "probe() is exactly count > 0", and SetupModel.swift:346 says "preserving count > 0 ⇔ probe()". LocalNetworkPrimer.probe() (line 89) follows that contract. Nothing in the app calls the Bool probe() on the primer. SetupModel uses prime(), which returns .granted(foundSpeakers: 0) for the empty-network case, so the self-discovery guarantee in the class doc holds on the path the app uses. The only .probe() call found, SetupModel.swift:610, is on audioProbe, which is a different protocol. Remaining mismatch: SimulatedLocalNetworkPrimer.probe() (PermissionMode.swift:167) returns `reachable`, so it differs from the real primer on an empty network. That is a minor inconsistency in a simulated type and nothing reads it. I did not write a test, because the code does what its contract says.


## Read / not checked
- 20 readers + 20 reviewers all returned (no failures); line counts per file are in the run journal. 181 suspicions total; 28 rated >=3 were all proven or rejected (23 demonstrated, 3 confirmed by reading, 2 rejected).
- **153 suspicions rated 2 (below the cut) were not checked.** Candidate list capped at confidence >=3.
- The 2 rejected: the setAppVolume raw-volume claim (actuator clamps downstream) and the LocalNetworkPrimer probe claim (documented intent).

## Fixes
The scope-and-run skill (`scope-and-run:scope-and-run`) and its agent types (fable-scoper, work-order-executor, work-order-reviewer) are **not available in this session** (not in the skill list; the plugin directory exists at /home/user/scope-and-run-plugin but is not installed). Per instructions, nothing was fixed and no PRs were opened. Every High/Medium bug above has no PR for that reason. aa-hh/audiout was also not attached.
