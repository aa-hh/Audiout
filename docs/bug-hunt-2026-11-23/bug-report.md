# Bug report — Audiout @ 8c910affd65f8a3a6299336490b75e76f07dab41 (2026-11-23)

## Scope
The repo is about 206k lines, too much for 20 slices of about 1,500 lines. This run read the 23 files in `AudioutCore/Sources/AudioutCore/` that the 2026-10-26 hunt left out: 33,597 lines in 16 slices. Those files are all `NativeBackend*.swift`, NativeCaptureCoordinator, BTSyncedSink, PerAppCaptureCoordinator, LocalPlaybackEngine, NativeDiscovery, CompanionServer, CastOutputManager, SyncedLocalSink, PTPHelperService, MockBackend, SystemOutputVolume, MicProbeSession, DefaultOutputDeviceMonitor and AudioCapturePermissionProbe. Six files over 1,500 lines got a slice each; `NativeBackend.swift` alone is 6,889 lines. Every reader and reviewer reported reading every line of its slice (per-slice counts are at the end).

**Caveat:** this container has no Swift toolchain. "Demonstrated" means a faithful Python or C port of the Swift logic fails as claimed and passes with the fix. A port is not the Swift code, so the fix PRs must add real Swift tests. Port tests are copied to `tests/p<N>/` next to this report.

**Run:** 87 agents (16 readers, 16 reviewers, 50 provers, 5 second provers), and none failed. The run took 43 minutes against a 30-minute target, because the engine had no clock to stop it. There were 121 suspicions; the 50 most confident at 3 or higher were proved, 47 were confirmed and 3 rejected. Two of the confirmed ones (#27, #36) were rejected by the first prover and demonstrated by the second.

**Severity:** High means ordinary input gives a silent wrong result, loses data, or never finishes. Medium means a crash on ordinary input, or a wrong result on unusual input; that includes most races that need a particular thread interleaving. Low covers the rest. When torn between two labels, the lower one was chosen.

## 1. [High] AudioutCore/NativeBackend.swift:5711 — applyDacpVolumeStep / setSpeakerVolume  (candidate #1)
- **Status:** demonstrated
- **Claim:** A relative DACP volumeup or volumedown step is dropped forever when the master gain (Main x Group) is 0.25 or lower, because the 2-point stored step rounds to the same wire percent and the guard `wirePct != effectiveVolume(of:)` rejects it as an echo.
- **Input:** mainOutGain=50, groupGain=50 (gain 0.25), or 10×100 (gain 0.1); device volume 50; 5× DACP volumeup
- **Should happen:** Volume goes 52, 54, 56, 58, 60 and each level is pushed to the speaker
- **Happens:** Volume stays 50 and nothing is pushed; every step is dropped as an echo
- **Why:** The step adds 2 to the stored volume and then sends a wire level (target × gain) into setSpeakerVolume. That function checks wirePct against effectiveVolume(of:) to drop echoes. At gain 0.25, 50 and 52 both round to wire 13. Swift's .rounded() rounds halves away from zero, so 12.5 becomes 13. The step is therefore taken for an echo and returns early. known[id].volume never changes, so every later press rebuilds the same target and is dropped too: the speaker's buttons stay stuck for good. At gain 0.1 it is the same, since 5.2 rounds to 5, which equals round(5.0). Even when the guard does pass, stored = round(wire/gain) can snap back to the old value. Real callers reach this: the DACP volumeup/volumedown handler at NativeBackend.swift:2476 calls applyDacpVolumeStep, and Main 50 × Group 50 gives gain 0.25. At gain 1.0 the steps work.
- **Failing test:** `/tmp/hunt/p1/test_step.py` (copy: `tests/p1/`). Output: FAIL gain=0.25 after 5x volumeup: volume=50 (expected 60), pushes=[]  (full output: /tmp/hunt/p1/out_current.txt; fixed run: /tmp/hunt/p1/out_fixed.txt, all PASS, exit 0). Fix checked on a copy: True
- **Fix:**

```swift
// setSpeakerVolume: accept the already-known stored level from the step path
private func setSpeakerVolume(id: String, outputID: OutputID, level: Double, storedLevel: Int? = nil) {
    let gain = masterGainFraction
    guard gain > 0 else { return }
    let wirePct = Int((level * 100).rounded()).clampedToVolume
    let stored = storedLevel ?? Int((Double(wirePct) / gain).rounded()).clampedToVolume
    if muted.contains(id) { stashedVolume[id] = stored; return }
    if storedLevel == nil {
        guard wirePct != effectiveVolume(of: id) else { return }   // echo guard, absolute reports only
    } else {
        guard stored != known[id]?.volume else { return }
    }
    ... // unchanged
}
// applyDacpVolumeStep:
self.setSpeakerVolume(id: id, outputID: match.value,
                      level: Double(target) * self.masterGainFraction / 100.0,
                      storedLevel: target)
```

## 2. [High] AudioutCore/NativeBackend+Bluetooth.swift:2183 — applyCompanionAlignmentMeasurement  (candidate #4)
- **Status:** demonstrated
- **Claim:** When the phone's re-check agrees with what is stored, the code keeps `applied` (the stored LATENCY, or 0 if there is none) and then runs the Keep, which zeroes the trim. A speaker tuned only by trim, or by latency plus trim, loses its trim, and the phone is told correctedMs == 0 ('the number stood').
- **Input:** Trim 150, no stored latency. The phone run suspends the trim, so the phone reports offsetMs 150. The stored offset is 150 (the trim), so the decision is keepStored.
- **Should happen:** On keepStored, the stored tuning stays as it was: trim 150 (total 150 ms) put back on the sink.
- **Happens:** keptMs = applied = 0. The Keep writes latency 0 and trim 0, so the speaker's delay drops from 150 to 0 ms, and the phone gets correctedMs 0 ('the number stood').
- **Why:** The claim is right. btStoredAlignmentOffsetMs (line 1820) returns `latency ?? trim`, so for a speaker tuned only by trim, recordMeasurement compares the measurement against that trim. When the two agree, the decision is keepStored. But keptMs = applied = btLatencyMs ?? 0 = 0, and the unconditional Keep (endBTWizardLatencyPreview) then writes latency 0 and trim 0. The speaker's 150 ms is wiped, and the phone is still told correctedMs == 0 ('the number stood'). The real caller is CompanionCoordinator.swift:1176. A speaker with both a latency and a trim also loses its trim on keepStored, because the Keep always zeroes it.
- **Failing test:** `/tmp/hunt/p4/test_keep_trim.py` (copy: `tests/p4/`). Output: decision=keepStored correctedMs=0 delay before=150.0 after=0 sinkTrim=0 / AssertionError: FAIL: re-check that agreed moved the speaker 150.0 -> 0 (see /tmp/hunt/p4/out_current.txt; with the fix: /tmp/hunt/p4/out_fixed.txt PASS). Fix checked on a copy: True
- **Fix:**

```swift
In applyCompanionAlignmentMeasurement, replace the unconditional `endBTWizardLatencyPreview(forDevice: targetID, keepMs: keptMs, recordsAlignment: false)` with:

if decision == .replace {
    endBTWizardLatencyPreview(forDevice: targetID, keepMs: value, recordsAlignment: false)
} else {
    // The stored number stood: leave both halves as stored, put the suspended trim back on the sink.
    endBTWizardLatencyPreview(forDevice: targetID, keepMs: nil, recordsAlignment: false)
    setBTWizardTrimPreview(run.trimAtSessionStartMs, forDevice: targetID)
}
```

## 3. [Medium] AudioutCore/NativeCaptureCoordinator.swift:726 — start()  (candidate #2)
- **Status:** demonstrated
- **Claim:** start()'s commit never calls rebuildCoalescer.takePending(). If a device change arrives while the initial start() is in .creatingTap, it is marked pending and then dropped, so the tap stays on the stale device or rate. The leftover pending flag then fires a spurious .deviceOrRateChange replay, with an AirPlay session reset, after some unrelated later rebuild.
- **Input:** Call start(). createAndStart reads 44100 and subscribes to the default-output monitor. The default output then moves to a 48 kHz device, and onDefaultDeviceChanged fires before start() commits; recreateTap sees .creatingTap and calls markPending. Later, call updateRouting (an exclusion change) on the unchanged device.
- **Should happen:** start()'s commit takes the pending flag and replays one rebuild right away, so the tap ends on the 48000 device. A later exclusion rebuild then triggers no replay.
- **Happens:** start() commits .capturing(44100) and leaves the flag pending, so the tap stays on the stale device and rate. The next unrelated rebuild consumes the stale flag and replays a .deviceOrRateChange rebuild, which resets the AirPlay session again.
- **Why:** The claim holds. During a rebuild, recreateTap calls markPending whenever the state is .creatingTap, and that includes the .creatingTap set by start(). start()'s commit (around lines 726-740) never calls takePending; only recreateTap's commit at line 2454 does. The trigger can really happen: CoreAudioSystemTap.createAndStart calls subscribeToDefaultOutput() before it returns, so the default-output monitor can fire onDefaultDeviceChanged, which calls handleDeviceChange and then recreateTap, while start() is still in .creatingTap. updateRouting can do the same through recreateTap(.exclusionChange). Nothing clears the flag, stop() included. So the change is dropped, and the leftover flag later forces an extra .deviceOrRateChange replay with onDeviceRateRebuild at the end of some unrelated rebuild. The Python port of start(), recreateTap() and TapRebuildCoalescer fails on the current logic: the tap stays at 44100 while the device is at 48000, and the later exclusion rebuild produces extra resets. With the fix it passes.
- **Failing test:** `/tmp/hunt/p2/port.py` (copy: `tests/p2/`). Output: FAIL: after start + mid-create device change, tap stuck on ('capturing', 44100) (device now 48000)
FAIL: unrelated exclusion rebuild caused 2 spurious AirPlay reset(s) via stale pending replay. Fix checked on a copy: True
- **Fix:**

```swift
In start(), make the commit return the replay flag and replay it after the commit:

let commit: (orphan: SystemAudioTap?, replay: Bool) = queue.sync {
    guard case .creatingTap = _state else { return (newTap, false) }
    self.tap = newTap
    self.converter = makeConverter(format)
    self.publishBufferSnapshot()
    self.lastExcludedObjects = claim.excludedProcessObjectIDs
    self.transition(to: .capturing(format))
    return (nil, rebuildCoalescer.takePending())
}
commit.orphan?.teardown()
if commit.orphan == nil, let id = newTap.workgroupDeviceID { workgroup?.join(deviceID: id) }
if commit.replay {
    Telemetry.log(.captureWS, "rebuild_replay", [:])
    recreateTap(cause: .deviceOrRateChange)
}
```

## 4. [Medium] AudioutCore/NativeCaptureCoordinator.swift:873 — updateRouting(appRoutes:excludedBundleIDs:)  (candidate #3)
- **Status:** demonstrated
- **Claim:** An exclusion change that arrives while the state is .creatingTap (initial start or an in-flight recreate) only stores currentExcludedBundleIDs and returns false. The tap being built uses the exclusion set resolved at claim time, and nothing marks the coalescer or rebuilds afterwards, so the routed-away app leaks into the whole-system mix until some unrelated rebuild. setSyncedLocalSink, setBTSink, setCastSink, refreshExcludedProcessSet and rebuildIfExclusionObjectsChanged have the same capturing-only gate.
- **Input:** The state is .creatingTap (start() in flight, or recreateTap in flight) when updateRouting(appRoutes: [com.spotify.client -> .device], excludedBundleIDs: []) is called.
- **Should happen:** Once the in-flight create commits, a rebuild should follow so the live tap excludes Spotify.
- **Happens:** currentExcludedBundleIDs becomes {spotify}, but the tap that gets committed excludes {} and nothing triggers a rebuild, so Spotify stays in the whole-system mix.
- **Why:** updateRouting stores currentExcludedBundleIDs and only calls recreateTap when the state is .capturing. In .creatingTap it neither marks rebuildCoalescer nor rebuilds, and the tap being built uses the exclusion set taken at claim time. The rebuildCoalescer doc comment (line ~257) says an exclusion change during .creatingTap is coalesced, but the code does not do that. Real callers can hit it: start() runs async on captureControlQueue (NativeBackend+PerAppRouting.swift:1473), and updateRouting is called from the route-update path (line 554) on another thread. start()'s commit also never calls takePending. I have not ported or tested the other setters the claim lists. The port is /tmp/hunt/p3/port.py. Output on the current logic is in /tmp/hunt/p3/out_current.txt (fails in both cases) and output with the fix is in /tmp/hunt/p3/out_fixed.txt (passes).
- **Failing test:** `/tmp/hunt/p3/port.py` (copy: `tests/p3/`). Output: start-in-flight: tap excludes Spotify=False (current=['com.spotify.client'], tap=[]) / recreate-in-flight: tap excludes Spotify=False; exit=1. Fix checked on a copy: True
- **Fix:**

```swift
// updateRouting, inside queue.sync after `currentExcludedBundleIDs = union`:
if case .creatingTap = _state { rebuildCoalescer.markPending() }

// start(), commit block: return the pending flag along with the orphan
let commit: (orphan: SystemAudioTap?, replay: Bool) = queue.sync {
    guard case .creatingTap = _state else { return (newTap, false) }
    ... // existing commit
    self.transition(to: .capturing(format))
    return (nil, rebuildCoalescer.takePending())
}
commit.orphan?.teardown()
... // workgroup join uses commit.orphan
if commit.replay { recreateTap(cause: .exclusionChange) }
```

## 5. [Medium] AudioutCore/PerAppCaptureCoordinator.swift:431 — beginStart(bundleID:)  (candidate #5)
- **Status:** demonstrated
- **Claim:** A device-change notification that arrives during the initial start is marked pending, but the start never consumes it, so it is lost.
- **Input:** The fake tap's createAndStart pins the tap to the current default device (A). After the point where it subscribes, it moves the default to B and fires onDefaultDeviceChanged, while the coordinator is still inside start(bundleID:) and before beginStart commits.
- **Should happen:** The pending device change is replayed once the slot reaches .capturing. The tap is rebuilt against B and the pending flag is cleared.
- **Happens:** The slot commits to .capturing with the tap pinned to A while the default is B. rebuildCoalescer.pending stays true, so no rebuild happens.
- **Why:** The claim holds. The tap's onDefaultDeviceChanged is wired before createAndStart, and createAndStart subscribes to the monitor at line 1120 before beginStart commits at about line 425. A notification in that window reaches handleDeviceChange while the slot is in .creatingTap, so it calls markPending. beginStart's commit never calls takePending, so the notification is lost. The tap stays pinned to the old device or rate, and the flag stays set until some later rebuild replays it for no reason. handleDeviceChange's own commit consumes the flag at line 607; the initial start is the only path that skips it. Port: /tmp/hunt/p5/port.py. Test: /tmp/hunt/p5/test_p5.py.
- **Failing test:** `/tmp/hunt/p5/test_p5.py` (copy: `tests/p5/`). Output: state ('capturing', 48000) tap device A default B pending True
FAIL: device change during initial start lost; tap pinned to stale device. Fix checked on a copy: True
- **Fix:**

```swift
In beginStart's success commit:
let replay: Bool = queue.sync {
    guard let slot = slots[bundleID], case .creatingTap = slot.state else { tap.teardown(); return false }
    slot.tap = tap
    slot.lastTappedProcessObjects = Set(processes.map(\.objectID))
    transition(slot, bundleID: bundleID, to: .capturing(format))
    return slot.rebuildCoalescer.takePending()
}
if replay {
    Telemetry.log(.capturePA, "device_change_replay", ["bundleID": bundleID])
    handleDeviceChange(bundleID: bundleID)
}
```

## 6. [Medium] AudioutCore/NativeDiscovery.swift:1036 — NetworkFrameworkBrowser.probeIPv4First / handleResolve self-filter  (candidate #7)
- **Status:** demonstrated
- **Claim:** The production browser sets ResolvedService.hostname to the Bonjour instance name, never to the mDNS host, so the self-receiver filter (normalizedHostname(service.hostname) == '<LocalHostName>.local') can never match
- **Input:** localHostname "my-mac.local". This Mac's receiver resolves as _airplay "My Mac" and _raop "AABBCCDDEEFF@My Mac" at 192.168.1.20 (an address on this Mac).
- **Should happen:** Both services are dropped as this Mac's own AirPlay receiver.
- **Happens:** Both services pass the self filter and become discovery entries (results=['surfaced','surfaced']).
- **Why:** The bug is real. NativeDiscovery uses NetworkFrameworkBrowser by default (line 345, `browser ?? NetworkFrameworkBrowser()`), and NativeBackend.swift:1724 creates `NativeDiscovery()` with that default. Both probe paths (lines 1036 and 1095) build the result with `hostname: name`, which is the Bonjour instance name, not the mDNS host. handleResolve (line 412) compares `normalizedHostname(service.hostname)` with "<LocalHostName>.local". "my mac" and "aabbccddeeff@my mac" can never equal "my-mac.local", so the filter only ever works with the test doubles. This Mac's own receiver shows up as a device row for both _airplay and _raop. The port is in /tmp/hunt/p7/port.py and the test in /tmp/hunt/p7/test_self_filter.py. It fails on the current logic (/tmp/hunt/p7/out_current.txt) and passes with the fix (/tmp/hunt/p7/out_fixed.txt).
- **Failing test:** `/tmp/hunt/p7/test_self_filter.py` (copy: `tests/p7/`). Output: FAIL: self receiver results=['surfaced', 'surfaced'], expected both dropped. Fix checked on a copy: True
- **Fix:**

```swift
NWBrowser .service endpoints carry no mDNS host, so the filter should key on the resolved address. In NativeDiscovery.handleResolve, extend the self check:

if (localHostname != nil && Self.normalizedHostname(service.hostname) == localHostname)
    || Self.localInterfaceAddresses().contains(service.address) { ...log once...; return }

static func localInterfaceAddresses() -> Set<String> {
    var out = Set<String>(); var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
    defer { freeifaddrs(ifap) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { out.insert(String(cString: host)) }
    }
    return out
}

The alternative is to resolve the real host target with DNSServiceResolve or NetService and pass it as `hostname` instead of `name` at lines 1036 and 1095.
```

## 7. [Medium] AudioutCore/NativeBackend+Tone.swift:1003 — pushCastFeedDelaysLocked  (candidate #8)
- **Status:** demonstrated
- **Claim:** When a receiver's remainder (room - settledLead) falls to 0 or below, the code skips it and never resets the delay set earlier. CastOutputManager keeps session.roomDelayMs, so the old delay line of up to seconds stays in place and that Cast leg plays late.
- **Input:** Cast A and B are both selected. A settles at 7000, so term and room are 7000. B settles at 5800, so B's feed delay is 1200. Deselecting A gives setReceivers([B]): the term moves to 5800 and roomDelayChangedLocked calls push.
- **Should happen:** B's feed delay is set to 0, so the leg meets the 5800 ms room.
- **Happens:** B's remainder is 5800 - 5800 = 0, so push skips B. session.roomDelayMs stays 1200, and the B Cast leg plays 1200 ms late.
- **Why:** The bug is real. In pushCastFeedDelaysLocked, `guard remainder > 0 else { continue }` skips a receiver whose remainder has dropped to 0 or below, so it never sends a smaller value. CastOutputManager keeps session.roomDelayMs on B's session, which survives A's removal. The ring therefore keeps its old 1200 ms delay line, and the B Cast leg plays 1200 ms behind the room. The real caller reaches this: setDevices → updateCastRoomDelayLocked (setReceivers returns termMoved) → roomDelayChangedLocked("cast_selection") → push. The comment says the skip exists to avoid allocating a delay line. That goal does not need the skip: CastRingBuffer.setDelayMs(0) with no existing line returns without allocating, and with an existing line it sets the line to 0. Port: /tmp/hunt/p8/port.py. Test: /tmp/hunt/p8/test_stale_delay.py. Outputs: /tmp/hunt/p8/out_current.txt (fails) and /tmp/hunt/p8/out_fixed.txt (passes).
- **Failing test:** `/tmp/hunt/p8/test_stale_delay.py` (copy: `tests/p8/`). Output: after deselect:  room 5800 B settled 5800 B applied 1200
AssertionError: FAIL: B keeps stale feed delay 1200 ms (expected 0). Fix checked on a copy: True
- **Fix:**

```swift
In NativeBackend+Tone.swift pushCastFeedDelaysLocked, replace
    let remainder = room - settled
    guard remainder > 0 else { continue }
    castOutputManager?.setCastRoomDelayMs(remainder, forDeviceID: id)
with
    castOutputManager?.setCastRoomDelayMs(Swift.max(0, room - settled), forDeviceID: id)
(setDelayMs(0) allocates no line when none exists, so the bypass is preserved.)
```

## 8. [Medium] AudioutCore/CastOutputManager.swift:1105 — live / setDevices / Session.generation  (candidate #9)
- **Status:** demonstrated
- **Claim:** Generation counters restart at 0 for every new Session object, so a late completion from a deselected session's attempt passes `live()` for a re-selected session of the same id and acts on it (for example, it fails it).
- **Input:** setDevices([A]), with the connect still pending; then setDevices([]) followed by setDevices([A]); then the old channel's connect failure is delivered.
- **Should happen:** A completion from the torn-down attempt is dropped and the re-selected session stays connecting.
- **Happens:** After A is deselected and re-selected, the old channel's connect failure carries gen 1 and the new session also holds gen 1, so `live()` accepts it and the new session ends up failed(cancelled).
- **Why:** The claim is real. Each new Session starts its generation at 0, and `live()` only compares `sessions[id].generation` with the generation a completion captured. Re-selecting A builds a new Session whose `startRecipe` hands out gen 1 again, which is the same value the deselected attempt captured. So when that old connect (or receiver-status) completion arrives after the new recipe starts, it passes `live()`. `afterConnect` then calls `fail()` on the new session: it tears the session down and marks it failed even though it is a fresh attempt. The awaitingTeardown wait does not prevent this. `teardownFinished` is queued during `teardown` and starts the new recipe, and the old channel's completion only reaches the queue after that. One assumption, since CastChannel is not in the copy: closing a channel with a connect still pending makes that connect complete asynchronously with an error. If it does not, the old connect or status request runs until its 10 s requestTimeout and lands on the new session even later. The port is /tmp/hunt/p9/port.py.
- **Failing test:** `/tmp/hunt/p9/port.py` (copy: `tests/p9/`). Output: AssertionError: FAIL: late completion of the deselected attempt acted on the re-selected session -> failed(cancelled)   (/tmp/hunt/p9/out_current.txt; with --fix: PASS, /tmp/hunt/p9/out_fixed.txt). Fix checked on a copy: True
- **Fix:**

```swift
Draw generations from one counter shared by all sessions in the manager, so a new Session can never reuse an old Session's value. Add `private var nextGeneration = 0` (queue-confined) to CastOutputManager. In `startRecipe` replace `session.generation += 1` with `nextGeneration += 1; session.generation = nextGeneration`, and in `teardown` replace `session.generation += 1` with the same two statements.
```

## 9. [Medium] AudioutCore/NativeBackend.swift:4295 — applyStartBuffer / convergeToTarget  (candidate #11)
- **Status:** demonstrated
- **Claim:** Phase 3 calls convergeToTarget(on: true), which unconditionally sets desiredOn[id] = true. That overwrites a user deselect (setOutputSet) that lands during the phase 1 or phase 2 awaits, so the device is re-added and streams although the user turned it off.
- **Input:** A is selected and streaming. applyStartBuffer(ms: 300) runs. While engine.setStartBufferMs is awaited, setOutputSet([]) deselects A.
- **Should happen:** A stays off: not in added, desiredOn[A]=false, because the user's newer deselect wins, as the doc comment promises ("whichever intent is newest is chased").
- **Happens:** A is re-added and streams. Final state: expectedSelected={}, added={A}, desiredOn[A]=true, and the engine output is live.
- **Why:** Phase 1 leaves A with desiredOn=false, not in added, and not converging. A setOutputSet that drops A during the `await engine.setStartBufferMs` therefore sees previous == wantOn (false), so it kicks nothing and only clears expectedSelected. Phase 3's convergeToTarget(on: true) then sets desiredOn[A]=true without checking expectedSelected, and convergeDevice re-adds A. convergeDevice reads only desiredOn, never expectedSelected. A deselect during phase 1 is overwritten the same way. Real callers reach this through CompanionCommandDispatcher/CompanionCoordinator, which call applyStartBuffer. Test: /tmp/hunt/p11/port.py, outputs in out_current.txt and out_fixed.txt.
- **Failing test:** `/tmp/hunt/p11/port.py` (copy: `tests/p11/`). Output: expectedSelected= set() added= {'A'} desiredOn= {'A': True} engine= {1}
AssertionError: FAIL: deselected A re-added and streaming. Fix checked on a copy: True
- **Fix:**

```swift
In convergeToTarget's stateQueue.sync block, as its first line:
    if target, !self.expectedSelected.contains(id) { return false } // user deselected mid-apply: don't resurrect
(the existing lines `if target { self.failedGate.remove(id) }` and `self.desiredOn[id] = target` follow unchanged)
```

## 10. [Medium] AudioutCore/NativeBackend.swift:4348 — applyStartBuffer / convergeToTarget  (candidate #12)
- **Status:** demonstrated
- **Claim:** The 'hard barrier' is not enforced. If an id in `added` already holds its converging slot (a whole-system rebind recovery, or a requeued converge), convergeToTarget returns at once without awaiting the removal, so phase 2's setStartBufferMs and the phase 3 re-adds can run while that device's old session (old master session, old buffer) is still alive.
- **Input:** A and B are streaming. A whole-system rebind recovery holds A's converging slot, and its remove-then-add is queued on bindTail behind an earlier op. applyStartBuffer(300) is then called with the old buffer at 100.
- **Should happen:** All removals finish before setStartBufferMs. After the apply, every re-added output is on a new master session using 300 ms.
- **Happens:** convergeToTarget(A, off) returns without awaiting anything, and phase 1 finishes while A is still attached to the old session. B is re-added into A's old session. After the apply, A and B are both on the session with the 100 ms buffer.
- **Why:** The claim holds. In convergeToTarget, `guard !self.converging.contains(id) else { return false }` sends a held slot back with nothing awaited. resetAirPlaySessionForWholeSystem claims A's slot (converging plus rebindConverging) and queues its remove-then-add on bindTail. If that chain is still waiting behind an earlier bindTail op, phase 1 does not tear A down, so A keeps the old master session alive. Phase 2 sets the new buffer, and phase 3 re-adds B, which joins A's old session. The chain then does its own remove and add for A, and A rejoins that old session. When the chain releases the slot, desiredOn[A]=true and A is in `added`, so nothing is requeued. applyStartBuffer then returns with every device on the old buffer. Two independent real triggers can overlap: a sample-rate tap rebuild and a buffer change from Settings. The port is in /tmp/hunt/p12/test_barrier.py (outputs in out_current.txt and out_fixed.txt).
- **Failing test:** `/tmp/hunt/p12/test_barrier.py` (copy: `tests/p12/`). Output: attached: {'B': 100, 'A': 100} added: ['A', 'B']
AssertionError: FAIL: outputs still on old-buffer session: {'B': 100, 'A': 100}. Fix checked on a copy: True
- **Fix:**

```swift
func convergeToTarget(id: String, outputID: OutputID, on target: Bool) async {
    while true {
        let claimed: Bool = stateQueue.sync {
            if target { self.failedGate.remove(id) }
            self.desiredOn[id] = target
            self.setConnectionState(target ? .connecting : .off, for: id)
            guard !self.converging.contains(id) else { return false }
            self.converging.insert(id)
            return true
        }
        if claimed { break }
        // Barrier: wait for the current holder (rebind recovery / requeued converge) to release.
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    await convergeDevice(id: id, outputID: outputID)
}
```

## 11. [Medium] AudioutCore/NativeBackend.swift:4315 — applyStartBuffer  (candidate #13)
- **Status:** demonstrated
- **Claim:** The final volume re-push calls engine.setVolume directly, bypassing the volumeInFlight/volumePending serialization. A concurrent pushVolume for the same output (a user slider drag, setMasterGain, unmute) can then have two setVolume calls in flight at once.
- **Input:** The start buffer is applied and its final volume re-push for output A is in flight. During that push the user moves A's slider, so `setVolume(70)` calls `pushVolume`.
- **Should happen:** At most one `setVolume` per output is in flight. The user's push should queue in `volumePending` behind the re-push and land after it.
- **Happens:** Two `engine.setVolume` calls for the same output are in flight at once: the re-push 0.5 and the user's 0.7. The per-output serialization is bypassed.
- **Why:** The bug is real. In `applyStartBuffer` (`NativeBackend.swift` ~4311), the final loop calls `try? await engine.setVolume(outputID, value)` directly and never touches `volumeInFlight`/`volumePending`. A user `setVolume`, `setMuted` or `setMasterGain` on `stateQueue` during that await sees the output as not in flight and issues its own `engine.setVolume` for the same output. That puts two calls in flight at once, which is the exact hazard the `volumeInFlight` doc comment describes: the C dispatcher keeps one waiter per device, so the second call clobbers the first, the continuation leaks, and the session can die. The input is reachable because `outputIDs[id]` and `added` are set again by the time the re-push runs, and nothing gates user pushes on `bufferReAdding`. Test: `/tmp/hunt/p13/test_startbuffer_volume.py`, a Python asyncio port of the re-push loop plus `pushVolume`/`issueVolumePush`.
- **Failing test:** `/tmp/hunt/p13/test_startbuffer_volume.py` (copy: `tests/p13/`). Output: AssertionError: FAIL: two setVolume calls in flight for one output (/tmp/hunt/p13/out_current.txt); with --fix: max concurrent 1, log [(1,0.5),(1,0.7)] PASS (/tmp/hunt/p13/out_fixed.txt). Fix checked on a copy: True
- **Fix:**

```swift
// in applyStartBuffer: carry the id in toPush, then route the re-push through pushVolume and await its completion
let toPush: [(OutputID, String, Double)] = stateQueue.sync { streaming.compactMap { item in
    guard self.added.contains(item.id) else { return nil }
    let intended = self.stashedVolume[item.id] ?? self.known[item.id]?.volume ?? 0
    let effective = self.muted.contains(item.id) ? 0 : intended
    return (item.outputID, item.id, self.engineVolume(forID: item.id, uiVolume: effective)) } }
for (outputID, id, value) in toPush {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        stateQueue.async { self.pushVolume(outputID, id: id, engineValue: value, uiLevel: nil) { _ in c.resume() } }
    }
}
// pushVolume calls a superseded completion with false, so the continuation resumes exactly once either way.
```

## 12. [Medium] AudioutCore/NativeBackend.swift:5705 — setSpeakerVolume  (candidate #14)
- **Status:** demonstrated
- **Claim:** The muted branch saves the reported level into stashedVolume before any echo check. When a receiver reflects our own mute write back, that write was 0.0, which is -30 dB on the wire and DACP level 0. The reflection overwrites the stashed level with 0, so unmuting restores 0 instead of the user's level.
- **Input:** AP2 device at volume 70, gain 1.0. Mute it: stash = 70, wire 0.0 = -30 dB. The receiver reflects that over DACP: level(fromDb: -30) = 0, and setSpeakerVolume(level 0) runs while the device is muted. Then unmute.
- **Should happen:** The echo of our own mute write is ignored, so unmute restores 70 (wire 0.7).
- **Happens:** The reflection overwrites stashedVolume with 0, so unmute restores volume 0 and pushes 0.0 to the wire.
- **Why:** The claim is real. In setSpeakerVolume, the muted branch writes stashedVolume[id] = stored before the same-value echo guard ever runs. The doc comment on that function says receivers do reflect our own writes, and it relies on that guard to drop them. Muting an AP2 device puts engineVolume(0) = 0.0 (-30 dB) on the wire and sets known[id].volume to 0. The receiver's DACP reflection maps back to level(fromDb: -30) = 0, and the muted branch saves that 0 as the stash. restoreEffectiveVolume then unmutes the device to 0 instead of 70. AP1 hits the same problem: its -144 dB mute sentinel also maps to 0. Reachable from real callers through applyDacpVolume and applyRemoteVolume. The port in /tmp/hunt/p14/port.py fails on the current logic (/tmp/hunt/p14/out_current.txt) and passes with the fix (/tmp/hunt/p14/out_fixed.txt). A second check in the same test confirms that a real knob turn while muted is still stashed. One trade-off: after the fix, a real speaker-side turn to exactly 0 while muted is indistinguishable from the echo and is ignored. It would be inaudible anyway.
- **Failing test:** `/tmp/hunt/p14/port.py` (copy: `tests/p14/`). Output: after unmute volume = 0 wire = 0.0
AssertionError: FAIL: unmute restored 0 instead of 70. Fix checked on a copy: True
- **Fix:**

```swift
if muted.contains(id) {
    // While muted the wire carries 0 and known[id].volume is 0, so this drops
    // the receiver's echo of our own mute write instead of stashing it.
    guard wirePct != effectiveVolume(of: id) else { return }
    stashedVolume[id] = stored
    return
}
```

## 13. [Medium] AudioutCore/NativeCaptureCoordinator.swift:1797 — handleBuffer(_:) rebuild-gap branch / recreateTap(cause:) arm  (candidate #16)
- **Status:** demonstrated
- **Claim:** The rebuild feed-gap arm has no time bound. It stays armed while the tap sits idle, and the first post-rebuild buffer fills the whole hole back to the last pre-pause buffer. That hole includes the user's pause, up to 2 s. So a rebuild during a short pause injects that much silence, and every later block plays late.
- **Input:** Steady playback in 512-frame blocks, then a pause. An exclusionChange recreateTap runs 300 ms into the pause with wizard off. Playback resumes 1.5 s after the pause starts and the new tap's first buffer arrives.
- **Should happen:** Nothing is filled, the same as a pause with no rebuild, because the tap was already idle and there is no feed hole for the rebuild to patch.
- **Happens:** The rebuild arm fills 1500 ms of silence, the pause plus the rebuild hole. Every later block reaches the sender 1.5 s late.
- **Why:** recreateTap arms FeedGapTracker with no time check. consume() measures from lastEndPts, which is the last buffer before the pause, because a TapAutoStart tap delivers nothing while idle. So the first buffer after resume gets the whole pause plus the rebuild hole filled with silence, as long as it is at most 2 s. Without a rebuild, the dropped-cycle arm caps at 50 ms and never fills a pause. The code's own comment says padding a pause pushes later blocks late, and the sender shim already feeds silence to a starving session. The port shows 1500 ms of extra silence for a 1.5 s pause with an exclusionChange rebuild, against 0 ms with no rebuild.
- **Failing test:** `/tmp/hunt/p16/port.py` (copy: `tests/p16/`). Output: AssertionError: FAIL: rebuild during pause injected 1500.0 ms of extra silence (later blocks play that late)  (full output in /tmp/hunt/p16/out_current.txt; fixed run in /tmp/hunt/p16/out_fixed.txt prints PASS). Fix checked on a copy: True
- **Fix:**

```swift
In recreateTap(cause:)'s claim, arm only while the tap is actually delivering:

let lastEnd = self.feedGap.lastDeliveredEndPtsNanos
let tapIdle = lastEnd != 0 && Self.monotonicNanos() &- lastEnd > Self.maxDroppedCycleFillNanos
if !self.wizardActive && !tapIdle { self.feedGap.arm(cause, fromEpoch: self.tapEpoch + 1) }

The port's sanity case checks that a rebuild during playback still gets its ~200 ms hole filled.
```

## 14. [Medium] AudioutCore/NativeBackend+Bluetooth.swift:879 — applyBTSnapshots  (candidate #17)
- **Status:** demonstrated
- **Claim:** When a speaker claimed only by a per-app route comes back up, it is set to .off instead of beginBTConnectingLocked(perApp:true). desiredAvailabilityMoved is only set for expectedSelected ids, so reapplyBTSinkLocked never runs and the speaker's sink is not rebuilt on the fresh device id.
- **Input:** X is known and available. btPerAppClaimedUIDs = [X], and X is not in expectedSelected. Then applyBTSnapshots([X disconnected]) runs, followed by applyBTSnapshots([X connected]).
- **Should happen:** X should go to .connecting through beginBTConnectingLocked(perApp: true), and reapplyBTSinkLocked should run with X in the armed uids.
- **Happens:** X's connection state becomes .off. reapplyBTSinkLocked is never called, so no sink is built for X on its new device id and the per-app audio stays silent.
- **Why:** applyBTSnapshots (NativeBackend+Bluetooth.swift ~L849-883) only looks at expectedSelected. When a speaker claimed only by a per-app route comes back up, it goes to .off with no connect hold, and desiredAvailabilityMoved stays false, so reapplyBTSinkLocked never runs. btArmingLocked would now include X, but nothing calls it. The sibling path finishBTReconnect (NativeBackend+Tone.swift ~L1088) already handles btPerAppClaimedUIDs, which shows the intended behaviour. The real caller is the enumerator callback at NativeBackend.swift:2193.
- **Failing test:** `/tmp/hunt/p17/port.py` (copy: `tests/p17/`). Output: state: off reapplies: []
FAIL: per-app speaker back up but state=off, sink never rebuilt   (with --fix: state: connecting reapplies: [[], ['X']] PASS). Fix checked on a copy: True
- **Fix:**

```swift
In applyBTSnapshots:
-   if availabilityMoved, expectedSelected.contains(id) {
+   if availabilityMoved, expectedSelected.contains(id) || btPerAppClaimedUIDs.contains(id) {
        desiredAvailabilityMoved = true
    }
...
    if expectedSelected.contains(id) {
        beginBTConnectingLocked(id)
+   } else if btPerAppClaimedUIDs.contains(id) {
+       beginBTConnectingLocked(id, perApp: true)
    } else {
        setConnectionState(.off, for: id)
    }
(and the same `|| btPerAppClaimedUIDs.contains(id)` in the vanished-device loop at ~L925)
```

## 15. [Medium] AudioutCore/NativeBackend+Bluetooth.swift:1608 — resetBTAlignment(forDevice:source:)  (candidate #18)
- **Status:** demonstrated
- **Claim:** A reset deletes the speaker's measured latency and trim but never calls refreshDriftTrackingLocked(). The drift tracker keeps the speaker's old baseline (room + old trim), even though btDriftBaselines is supposed to drop any speaker with no measured latency.
- **Input:** Selected BT speakers A (latency 120, trim 15) and B (latency 80), no anchors, room 200, tracker running; then resetBTAlignment(forDevice: "A", source: "drawer")
- **Should happen:** Baselines are rebuilt as [B=200]. That leaves one measured BT speaker and no anchor, so the tracker gets setBaselines([]) and stop().
- **Happens:** The tracker keeps running with baselines A=215 and B=200. A's stale baseline stays in place and A can be drift-corrected even though it has no measured latency.
- **Why:** resetBTAlignment(forDevice:source:) removes A's latency and trim, then only calls updateBTReferenceBufferLocked(). That function and roomDelayChangedLocked never call refreshDriftTrackingLocked(). Both real callers skip the refresh: the drawer at line 1582 and the phone's Clear at line 2866. The tracker therefore keeps baseline A = room + old trim, and with only B measured it keeps running when it should stop, because one Bluetooth speaker with no anchor does not run (driftTrackingRuns). It can then 'correct' A through writeBTDriftLatency and write a latency for a speaker that has no measurement, which btDriftBaselines is meant to prevent. The other places that change latency or trim do call the refresh: Keep (line 3110), trim persist (line 1568) and selection change (Tone line 610). Test: /tmp/hunt/p18/port.py. Output: /tmp/hunt/p18/out_current.txt (fails), /tmp/hunt/p18/out_fixed.txt (passes with the fix).
- **Failing test:** `/tmp/hunt/p18/port.py` (copy: `tests/p18/`). Output: after reset: True [('A', 215.0), ('B', 200.0)] expected baselines: [('B', 200.0)] expected running: False
FAIL: tracker still running with stale baseline for reset speaker A. Fix checked on a copy: True
- **Fix:**

```swift
In resetBTAlignment(forDevice:source:), inside the existing stateQueue.async block, call refreshDriftTrackingLocked() after updateBTReferenceBufferLocked(), as the Keep path does:
stateQueue.async {
    self.updateBTReferenceBufferLocked()
    self.refreshDriftTrackingLocked()
    self.captureControlQueue.async { [weak self] in
        self?.btSink?.setOffsetMs(0, forDeviceUID: id)
        self?.btSink?.setTrimMs(0, forDeviceUID: id)
    }
}
```

## 16. [Medium] AudioutCore/NativeBackend+PerAppRouting.swift:1797 — handleDestinationSetsChanged (also resetAirPlaySessionForRoutedApp line 836)  (candidate #20)
- **Status:** demonstrated
- **Claim:** Per-app paths cancel a pending rebind-recovery DispatchWorkItem and drop its gen without releasing the whole-system `converging`/`rebindConverging` slot. If a whole-system chain for that device is waiting out a backoff, the slot leaks and the device is wedged.
- **Input:** D is in `added`, `desiredOn[D] == true` and `streamBindings[D] == 2`. resetAirPlaySessionForWholeSystem runs, attempt 1 fails and the backoff is armed. Then one of three triggers fires: handleDestinationSetsChanged drops D (sets []), handleDestinationSetsChanged moves D to stream 3, or resetAirPlaySessionForRoutedApp runs for stream 2. After that the engine recovers and every queued op drains.
- **Should happen:** The whole-system chain ends through releaseRebindConverging, either by its backoff retry firing or by its own ownership exit, so the slot is freed and the requeue/settle runs.
- **Happens:** The `converging` slot and the `rebindConverging` entry for D are never released. D stays wedged: setOutputSet, the wake re-kick and the whole-system reset all skip it, and the deferred unbind settle is never re-driven.
- **Why:** Three per-app paths clear `rebindRecoveryGen[D]` and cancel `pendingRebindRecoveries[D]` without checking `rebindConverging`: the unbind loop and the stream-move branch of handleDestinationSetsChanged (about L1781/1796), and resetAirPlaySessionForRoutedApp (L834-836). If D is in `added` and still in `streamBindings` (the roadmap-008 window) while a whole-system chain waits out a backoff, the cancelled DispatchWorkItem never runs, so the chain never reaches a terminal exit that calls releaseRebindConverging. The per-app chain that replaces it ends with `.none`, because only the `.wholeSystem` scope releases the slot. The deferred `.unbind` sees `converging` held and parks in `pendingScopeSettles`, and nothing else re-drives it. After that, setOutputSet, the wake re-kick and the whole-system reset all skip D until the next sleep or a restart. The Python port in /tmp/hunt/p20/port.py drives all three triggers. On the current logic the slot stays held in every case (/tmp/hunt/p20/out_current.txt). With the fix it is released (/tmp/hunt/p20/out_fixed.txt).
- **Failing test:** `/tmp/hunt/p20/port.py` (copy: `tests/p20/`). Output: drop/move/recapture: converging slot still held after everything settled: True
FAIL: slot leaked, device wedged. Fix checked on a copy: True
- **Fix:**

```swift
// At each of the three per-app cancel sites, leave a whole-system chain alone; it keeps its own gen, timer and slot:
// handleDestinationSetsChanged, stream-move branch (old != stream):
    ops.append(.rebind(outputID, stream))
    if !self.rebindConverging.contains(deviceID) {
        self.rebindRecoveryGen.removeValue(forKey: deviceID)
        self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
    }
// handleDestinationSetsChanged, unbind loop:
    if !self.rebindConverging.contains(deviceID) {
        self.rebindRecoveryGen.removeValue(forKey: deviceID)
        self.pendingRebindRecoveries.removeValue(forKey: deviceID)?.cancel()
    }
// resetAirPlaySessionForRoutedApp, first line inside the loop:
    for (deviceID, bound) in self.streamBindings where streams.contains(bound)
        && !self.rebindConverging.contains(deviceID) { ... }
```

## 17. [Medium] AudioutCore/NativeBackend+PerAppRouting.swift:769 — handlePerAppCaptureHealthChange  (candidate #21)
- **Status:** demonstrated
- **Claim:** The `.processNotYetAudible` retry is gated on routedBundleIDs only. A LEVELED (`.noRedirect`, volume < 100) or `.currentDevice` app whose tap fails because the app is not playing yet is marked dead and never retried.
- **Input:** Route a paused app as `.noRedirect` with volume 40 (leveled), or as `.currentDevice`. updateAppRoutes calls perAppCapture.start, which returns `.failed(.processNotYetAudible)`.
- **Should happen:** The same open-ended backoff retry a `.device`-routed app gets, for as long as the per-app capture is still wanted.
- **Happens:** The app goes into deadBundleIDs, no retry is scheduled, and its pendingRetries entry is cancelled. The tap is never retried, so the app is never intercepted once it starts playing.
- **Why:** routedBundleIDs holds only `.device`/`.group` routedApps (line 325). `.currentDevice` and leveled apps live in localBundleIDs/leveledBundleIDs, and updateAppRoutes starts a per-app tap for those too (union, lines 419-445). When the app is paused, beginStart finds no processes and goes to `.failed(.processNotYetAudible)`. The `.failed` guard at line 769 checks only routedBundleIDs, so the app is marked dead and no retry is scheduled. The only other restart paths are handleAppLaunched, which needs a relaunch, and a route-table change that adds the app to the set. A paused app that later starts playing is never tapped, so its slider level or This Mac routing silently does nothing. The `.capturing` branch already accepts local and leveled apps through wantsPerAppCaptureLocked, which shows the retry gate is the odd one out.
- **Failing test:** `/tmp/hunt/p21/port.py` (copy: `tests/p21/`). Output: leveled: dead=['com.app.paused'] retryScheduled=False -> FAIL; currentDevice: ... retryScheduled=False -> FAIL (device control passes). See /tmp/hunt/p21/out_current.txt; fixed run in /tmp/hunt/p21/out_fixed.txt. Fix checked on a copy: True
- **Fix:**

```swift
In handlePerAppCaptureHealthChange `.failed` (NativeBackend+PerAppRouting.swift:769), replace `guard self.routedBundleIDs.contains(bundleID),` with `guard self.wantsPerAppCaptureLocked(bundleID),`.
```

## 18. [Medium] AudioutCore/NativeBackend+PerAppRouting.swift:1589 — handleAppLaunched / updateAppRoutes (leveled injector)  (candidate #22)
- **Status:** demonstrated
- **Claim:** A leveled app that relaunches stays silent. While it was quit, any updateAppRoutes call (a route edit, or rerunAppRoutesForReachabilityChange) removes it from leveledInjector because leveledRoutes filters deadBundleIDs. The whole-system exclusion uses plan.leveled, which is not filtered by dead, so it stays excluded there. handleAppLaunched clears dead and restarts the muted tap, but it only republishes the mixer, so the injector never gets the app back.
- **Input:** Route L as .noRedirect at volume 40 with whole-system capture running. Call handleAppTerminated(L), then updateAppRoutes with the same routes, then handleAppLaunched(L).
- **Should happen:** After relaunch the injector gets L back at volume 40, and L is heard in the program at that level.
- **Happens:** L is still excluded from the system tap and its per-app tap is muted, but the injector's volume table is empty. All of L's audio is dropped, so the app is silent.
- **Why:** The claim holds. Only updateAppRoutes (around line 530) ever adds a bundle to LeveledAppInjector.updateLeveled. If updateAppRoutes runs while L is in deadBundleIDs (a route edit, or rerunAppRoutesForReachabilityChange after a speaker's reachability changes), plan.leveledRoutes filters L out and the injector drops it. plan.leveled keeps L (the sticky leveledBundleIDs), so the whole-system tap still excludes it. On relaunch, handleAppLaunched (line 1557) clears dead, restarts the muted tap (.mutedWhenTapped) and calls only republishMixerTopology(). handleBuffer then drops every buffer because volumeForBundle has no entry for L. L stays silent until something else calls updateAppRoutes. While whole-system capture is off the app is not affected, because the local-player path (leveledLocalRoutes and handleLocalCaptureStateChange) does not filter dead apps. The AppKit caller is not in the copy, so I could not check whether a launch notification also pushes a fresh route table later. A push that arrives before handleAppLaunched clears dead would still drop L.
- **Failing test:** `/tmp/hunt/p22/port.py` (copy: `tests/p22/`). Output: L excluded from system tap: True | L muted-tapped: True | injector volumes: {}
FAIL: relaunched leveled app silent  (exit 1; /tmp/hunt/p22/out_current.txt). Fix checked on a copy: True
- **Fix:**

```swift
In handleAppLaunched, after `republishMixerTopology()`:

let leveled: [(bundleID: String, volume: Int)] = stateQueue.sync {
    self.lastRoutes
        .filter { self.leveledBundleIDs.contains($0.bundleID) && !self.deadBundleIDs.contains($0.bundleID) }
        .map { (bundleID: $0.bundleID, volume: $0.volume) }
}
captureControlQueue.async { [weak self] in self?.leveledInjector.updateLeveled(leveled) }
```

## 19. [Medium] AudioutCore/NativeBackend+PerAppRouting.swift:1279 — performRebindRecovery (.perApp arm) / enqueueRebindRecovery  (candidate #23)
- **Status:** demonstrated
- **Claim:** Per-app rebind recovery checks whole-system ownership only once, before the PTP takeover wait. After the wait it runs removeOutput then addOutput(stream) with no re-check. performBindOp re-gates (perAppOpMayFire) after that same wait because it is the widest window. The two awaited engine calls also leave a gap between them.
- **Input:** D is bound per-app to stream 1 and the engine has it on stream 1. A tap rebuild enqueues a `.perApp(stream: 1)` recovery, whose preflight passes. While the recovery waits in `ensurePTPTakeover`, `setOutputSet({D})` runs and `convergeDevice` starts. Then the PTP clock becomes ready.
- **Should happen:** After the PTP wait the recovery should step aside, as `performBindOp` does through `perAppOpMayFire`. Then only the converge's `rebindOutput(D, 0)` runs, and D ends up on its home stream 0.
- **Happens:** The recovery runs `removeOutput(D)` then `addOutput(D, 1)` against a device whole-system already claims. The engine log is remove, add(1), add(0); the converge's `add(0)` is a silent no-op because the session is already bound. Final state: engine has D on stream 1 while `added` contains D.
- **Why:** The claim is real. The per-app recovery checks `stillOwnsRebind` (which includes the whole-system-claim conjunct) once, in `enqueueRebindRecovery`'s preflight, before `performRebindRecovery` awaits `ensurePTPTakeover`. After that wait, nothing checks again before `removeOutput` and `addOutput(stream)`. If the user selects D during the wait (`setOutputSet` sets `desiredOn` and `converging`, and `convergeDevice` runs on its own task), the recovery still tears down D's session and re-adds it on per-app stream 1. That is the I4 teardown of a fresh whole-system session that the `stillOwnsRebind` and `perAppOpMayFire` comments say must not happen. In the port, D ends up in `added` while the engine has it on stream 1. Mitigation (not modelled in the port): the route demotion enqueues a `.unbind` on `bindTail` behind the recovery, and its verify-first settle most likely moves D back to its home stream afterwards. So the damage is a needless teardown, an audible gap and a short astray window, not a permanent strand.
- **Failing test:** `/tmp/hunt/p23/test_rebind.py` (copy: `tests/p23/`). Output: engine log: [('remove', 7), ('add', 7, 1), ('add', 7, 0)] | bound: {7: 1} | added: {'D'}
AssertionError: FAIL: per-app recovery fired [('remove', 7), ('add', 7, 1)] on a whole-system-claimed device (claimed at fire=True)   (with --fix: PASS, see /tmp/hunt/p23/out_fixed.txt). Fix checked on a copy: True
- **Fix:**

```swift
In performRebindRecovery, right after `guard gate == .ready else { ... }` and before `try? await engine.removeOutput(outputID)`:

if case .perApp = scope, let id = deviceID(for: outputID) {
    let owns = stateQueue.sync { self.stillOwnsRebind(deviceID: id, scope: scope) }
    guard owns else { return false }   // completion's guard takes the `superseded` exit
}
```

## 20. [Medium] AudioutCore/BTSyncedSink.swift:1423 — BTDeviceSink.renderInterleaved / realignToDevicePulls  (candidate #25)
- **Status:** demonstrated
- **Claim:** realignToDevicePulls counts every cycle as pulled, and it runs before stateLock.try(). A cycle that the lock turns away (return false) drains nothing from the ring, and an underrun cycle drains less than frameCount. Both leave extra audio in the ring that the wall-vs-pulled measure never sees, so each one adds lateness that stays for the session.
- **Input:** Released session, 512-frame cycles at 48 kHz, 200 ms held in the ring, capture writing 512 frames per cycle on wall time. Five of 6000 render cycles find stateLock held.
- **Should happen:** Lateness stays below pullRealignThresholdMs (20 ms), because the realign step should catch it once it builds up. With the fix it ends at 10.7 ms.
- **Happens:** Each turned-away cycle adds one cycle of lateness that is never measured or corrected. At the end of the run the ring is 53.3 ms late.
- **Why:** The bug is real for the lock part of the claim. `realignToDevicePulls` adds `frameCount` to `framesPulledSinceOrigin` before `stateLock.try()` runs. A cycle the lock turns away reads nothing from the ring, while capture keeps writing on wall time. Each such cycle leaves one cycle of extra audio in the ring (10.7 ms at 512 frames and 48 kHz), and the wall-minus-pulled measure never sees it, so nothing corrects it. The lock is contended for real: enqueue takes it with `try`, and callers take it blocking through `withLock` (`hasStartedRendering`, `hasAnchored`, `applyTrimDelta` and others). In the port, five lockouts leave 53 ms of lateness for the rest of the session, well past the 20 ms realign threshold. The underrun part of the claim is only partly right. A late chunk does leave lateness behind, but in a real capture stall the ring holds less, not more, so counting underrun frames as not pulled would skip forward wrongly. The fix below covers only the lockout case.
- **Failing test:** `/tmp/hunt/p25/test_lockout.py` (copy: `tests/p25/`). Output: lateness at end: 53.3 ms (bound 20.0 ms) -> AssertionError: FAIL (current, /tmp/hunt/p25/out_current.txt); with fix: lateness at end: 10.7 ms, PASS (/tmp/hunt/p25/out_fix.txt). Fix checked on a copy: True
- **Fix:**

```swift
In BTDeviceSink.renderInterleaved, replace
    guard stateLock.try() else { return false }   // no snapshot → silent cycle
with
    guard stateLock.try() else {
        // Nothing was read from the ring, so this cycle does not count as pulled.
        if pullOriginNanos != nil { framesPulledSinceOrigin -= frameCount }
        return false
    }
```

## 21. [Medium] AudioutCore/BTSyncedSink.swift:1910 — BTSyncedSink.setOffsetMs / BTDeviceSink.applyTrimDelta  (candidate #27)
- **Status:** demonstrated
- **Claim:** Offset and trim changes are applied live as a linear delta. The real delay is max(0, ref - offset + trim), clamped at zero inside totalDelayNanos. While the clamp is active, a change moves the read position even though the formula's delay does not change. Example: offset 600 to 700 to 500 with a 500 ms reference: the formula stays at 0, but the ring replays 200 ms.
- **Input:** Per-app-only BT speaker (not whole-system selected) with stored latency 700 ms, BT-only reference 500 ms (the default; selected speakers' latency ≤ 400 ms). The user presses Reset alignment, so setOffsetMs(0) runs. The claim's own sequence (600→700→500 on a 500 ms reference) also fails in the port.
- **Should happen:** The ring delay should equal the clamped formula max(0, ref - offset + trim), which is 500 ms here.
- **Happens:** The ring delay becomes 700 ms. The formula delay is 500 ms. The speaker plays 200 ms late and stays that way until an unrelated rebuild.
- **Why:** The linear delta is wrong whenever the delay sits on the zero clamp. The previous prover found no real caller that reaches the clamp, but one exists: a per-app-only Bluetooth speaker. It is fed by the same btSink (armedUIDs = btSelectedUIDs ∪ btPerAppClaimedUIDs). The BT-only reference is derived from btSelectedUIDs alone (btOnlyReferenceMs), and the per-app path says on purpose that it does not move the reference. So a per-app speaker whose stored latency is above the reference (for example 700 ms against the 500 ms default) anchors clamped at 0. The wizard allows latencies up to 1500 ms, so such a value can be stored while the speaker was whole-system selected. resetBTAlignment then calls setOffsetMs(0). Its updateBTReferenceBufferLocked does not move the floor, because the speaker is not in btSelectedUIDs, so nothing is rebuilt. applyTrimDelta(+700) seeks the read pointer back by the full 700 ms (a backward seek is never clamped), while the formula only goes from 0 to 500. That leaves a lasting 200 ms error until some unrelated rebuild. The claim's own sequence (600→700→500) also fails in the port, but no real caller produces it.
- **Failing test:** `/tmp/hunt/p27b/port.py` (copy: `tests/p27/`). Output: FAIL per-app reset 700->0, ref 500: ring=700.0ms formula=500.0ms (/tmp/hunt/p27b/out.txt; with --fix both cases PASS, /tmp/hunt/p27b/out_fixed.txt). Fix checked on a copy: True
- **Fix:**

```swift
// BTSyncedSink: apply the change in the CLAMPED formula delay, not the raw term delta.
func setOffsetMs(_ ms: Int, forDeviceUID uid: String) {
    let before = delayNanos(forUID: uid)
    let sink = tableLock.withLock { () -> BTDeviceSink? in
        let previous = offsetMsByUID[uid] ?? 0
        guard previous != ms else { return nil }
        offsetMsByUID[uid] = ms
        return sinksByUID[uid]
    }
    guard let sink else { return }
    sink.applyTrimDelta(ms: Double(delayNanos(forUID: uid) - before) / 1_000_000)
}
// setTrimMs: same shape (before/after delayNanos(forUID:) around the trimMsByUID write).
```

## 22. [Medium] AudioutCore/BTSyncedSink.swift:229 — BTFrameRing.seek / BTDelayLine.shift (backward), reached from applyTrimDelta and realignToDevicePulls  (candidate #28)
- **Status:** demonstrated
- **Claim:** A backward seek reaches capacity - used frames, but it never checks how much this session has written. Soon after an anchor, or after any rebuild (reset only moves readCounter and never clears samples), the history behind the read pointer is the previous session's audio, or zeros on a fresh ring. A positive trim or negative offset change right after release then replays stale music from before the rebuild.
- **Input:** Ring (min capacity 64). Session 1 writes and plays 40 frames tagged 1.0. Then reset(). Session 2 writes a 16-frame pre-roll tagged 2.0, reads 4, then writes 8 more. Then shift(byFrames: -20), which is what applyTrimDelta(+20 frames) requests.
- **Should happen:** A backward seek stops at this session's first written frame. Here that allows -4, and every frame read afterwards belongs to session 2.
- **Happens:** seek applies the full -20. The next 16 frames read are session-1 audio (1.0), followed by session-2 audio.
- **Why:** The bug is real for the trim path. `BTFrameRing.seek` limits a backward move only by `capacity - used`. `reset()` moves `readCounter` and leaves the samples in place, so right after release the area behind the read pointer still holds the previous session's frames, or zeros on a fresh ring. `applyTrimDelta` sends positive trims after release unclamped (`requestShift(-frames)`), and `BTDelayLine.shift` then seeks back past this session's first frame. `realignToDevicePulls` moves back only by an over-pull, and the device has already pulled those frames, so it is not a realistic trigger. Severity is low. The replayed frames are the newest audio session 1 captured before the reset (session 1 never played them, since the reset drops the buffered delay). When capture ran without a gap, those frames are roughly the right audio. After a capture gap or pause they are old music, and on a fresh ring they are a short dropout. One more gap: `applyTrimDelta` adds the full positive delta to `sessionDelayNanos` and never checks how much the seek actually applied. With the fix, a clamped backward seek therefore books more delay than it moved.
- **Failing test:** `/tmp/hunt/p28/port.py` (copy: `tests/p28/`). Output: applied -20 next frames [1.0 x16, 2.0 x4] / AssertionError: FAIL: 16 frames from session 1 replayed after trim (full output: /tmp/hunt/p28/out_current.txt; with --fix: /tmp/hunt/p28/out_fixed.txt shows applied -4, PASS). Fix checked on a copy: True
- **Fix:**

```swift
In BTFrameRing, add a consumer-owned floor word: `private let floorCounter: UnsafeMutablePointer<Int>`, initialized to 0. In reset(), after `readCounter.pointee = writeCounter.pointee`, add `floorCounter.pointee = writeCounter.pointee`. In seek, change the backward clamp to `-min(-frames, min(capacityFrames &- used, r &- floorCounter.pointee))`. Optionally, make applyTrimDelta book only the delta the seek actually applied for positive trims as well.
```

## 23. [Medium] AudioutCore/PerAppCaptureCoordinator.swift:352 — stop(bundleID:)  (candidate #30)
- **Status:** demonstrated
- **Claim:** Two concurrent stop() calls for the same bundle ID both take the same slot.tap and both call teardown() on it at the same time, off the queue.
- **Input:** x is .capturing. Thread A runs stopAll() (or stop("x")) and blocks inside teardown(). Thread B then calls stop("x").
- **Should happen:** Only the stop() that claimed the slot tears the tap down. A second stop() that finds the slot already .stopping does nothing.
- **Happens:** Thread B passes the guard because the state is .stopping, not .idle. It takes the same slot.tap and calls teardown() while thread A is still inside it: 2 calls, 2 running at once.
- **Why:** The claim is real. The first stop() moves the slot to .stopping but leaves slot.tap set until after teardown. A second stop() only skips .idle, so it passes the guard, reads the same slot.tap, and calls teardown() on it while the first teardown is still running, outside the queue. Real callers can do this. NativeBackend.stop() calls perAppCapture.stopAll() on the caller's thread, and handleAppTerminated calls stop(bundleID:) on its caller's thread. Meanwhile the route-update stops and the orphan stop run on captureControlQueue. CoreAudioProcessTap.teardown() is idempotent but not thread-safe: it reads and clears ioProcID, aggregateID, tapID, lastAggregateUID and monitorToken without a lock, so two concurrent runs can stop and destroy the same IOProc, aggregate and tap twice. The Python port is /tmp/hunt/p30/port.py.
- **Failing test:** `/tmp/hunt/p30/port.py` (copy: `tests/p30/`). Output: teardown calls=2 max concurrent=2 slots=[] / FAIL: same tap torn down by two concurrent stop() calls (/tmp/hunt/p30/out_current.txt; the fixed copy prints calls=1 PASS in /tmp/hunt/p30/out_fixed.txt). Fix checked on a copy: True
- **Fix:**

```swift
public func stop(bundleID: String) {
    let claim: (owned: Bool, tap: ProcessAudioTap?) = queue.sync {
        guard let slot = slots[bundleID] else { return (false, nil) }
        switch slot.state {
        case .idle, .stopping: return (false, nil) // another stop() owns this teardown
        default: break
        }
        let t = slot.tap
        transition(slot, bundleID: bundleID, to: .stopping)
        return (true, t)
    }
    guard claim.owned else { return }
    claim.tap?.teardown()
    queue.sync { /* unchanged commit block */ }
}
```

## 24. [Medium] AudioutCore/LocalPlaybackEngine.swift:403 — addApp / startEngineOnGraphQueue  (candidate #32)
- **Status:** demonstrated
- **Claim:** After a recovery leaves engineRunning=false while nodes still exist (replay/connect/restart failure in reestablishGraphOnGraphQueue), a later addApp restarts the engine but only plays the NEW player; existing players stay stopped while receive() now schedules buffers into them without limit
- **Input:** addApp(A); config change whose replay play() raises; addApp(B); receive(A) x1000
- **Should happen:** After addApp brings the engine back, A is reconnected and playing too, so its scheduled buffers are rendered
- **Happens:** engineRunning=true, B plays, A.playing=false, and 1000 buffers are queued on A's stopped player
- **Why:** The claim is real. When the replay play() in reestablishGraphOnGraphQueue raises (lines 535-541), or the reconnect or restart fails, engineRunning is set to false but A stays in nodes, and A's player was stopped along with the engine. A later addApp(B) goes through startEngineOnGraphQueue, which starts the engine and sets engineRunning=true, then calls play() only on B's new player. Nothing replays A. Once engineRunning is true again, receive() lets A's buffers through, and scheduleBuffer keeps queueing them into A's stopped player with no limit. A stays silent until another config change or a device repoint happens. A Python port of the Swift logic shows this in /tmp/hunt/p32/port.py.
- **Failing test:** `/tmp/hunt/p32/port.py` (copy: `tests/p32/`). Output: engineRunning=True A.playing=False A.queued=1000 B.playing=True / FAIL: A stopped while receive() queued 1000 buffers into it (/tmp/hunt/p32/out_current.txt). Fix checked on a copy: True
- **Fix:**

```swift
In addApp, take a snapshot before attaching the new player:
    let (wasRunning, existing) = stateLock.withLock { (engineRunning, nodes) }
Then, after the new player's play() succeeds, bring the older players back:
    if !wasRunning {
        for (_, n) in existing {
            try? catchingObjCException {
                engine.connect(n.player, to: engine.mainMixerNode, format: n.connectionFormat)
                n.player.play()
            }
        }
    }
```

## 25. [Medium] AudioutCore/NativeDiscovery.swift:578 — NativeDiscovery.buildDevice / descriptor(from:)  (candidate #37)
- **Status:** demonstrated
- **Claim:** An AP1-only receiver that also advertises _airplay._tcp without the AP2 bits, such as an Apple TV 3, gets its engine descriptor built from the airplay leg with kind .airplay. The engine then sends it to the AP2 backend, which rejects it, and never to the raop backend that could drive it.
- **Input:** _airplay._tcp "Living Room" with deviceid=58:55:CA:00:11:22 and features=0x5A7FFFF7,0x1E, then _raop._tcp "5855CA001122@Living Room"
- **Should happen:** For a device that is not AP2, the descriptor should come from the _raop._tcp leg (kind .raop) so the raop backend can drive it.
- **Happens:** The merged device has isAirPlay2Supported=false but descriptor.kind=.airplay, built from the airplay leg, so it is fed to the AP2 backend.
- **Why:** The claim holds. buildDevice always takes the descriptor from `entry.airplay ?? entry.raop!`, so whenever an `_airplay._tcp` leg exists the descriptor gets kind .airplay, even when classify() says the device is not AP2. The two legs merge into one entry because the airplay deviceid TXT and the raop name prefix give the same id. NativeBackend.feedEngineIfAvailable then passes discovered.descriptor to engine.updateDiscovery for any available device, and AP1-only devices are available. By the descriptor(from:) doc comment, a .airplay descriptor goes to the AP2-gated airplayengine_feed_device, so the device never reaches output_raop. The AirPlayEngine package is not in the copy, so that last routing step comes from the comment, not from engine code. Port and test: /tmp/hunt/p37/port.py, output in /tmp/hunt/p37/out.txt.
- **Failing test:** `/tmp/hunt/p37/port.py` (copy: `tests/p37/`). Output: isAP2= False descriptor.kind= airplay / AssertionError: AP1-only device routed with kind .airplay (to AP2 backend). Fix checked on a copy: True
- **Fix:**

```swift
In NativeDiscovery.buildDevice, replace `let source = entry.airplay ?? entry.raop!` with:
let source = (classify(airplay: entry.airplay) ? entry.airplay : nil) ?? entry.raop ?? entry.airplay!
```

## 26. [Medium] AudioutCore/NativeDiscovery.swift:1026 — NetworkFrameworkBrowser.resolve / probeIPv4First .ready  (candidate #38)
- **Status:** demonstrated
- **Claim:** resolve() overwrites probes[resultKey] without cancelling a probe that is still in flight, and the older probe's .ready then sets probes[resultKey]=nil, which orphans the newer probe. The .ready block also never checks resultTXT[resultKey], so a probe that is orphaned, or whose .ready block was queued before remove(), still calls onResolve after onRemove.
- **Input:** Browse .added, then .changed before probe A is ready. A becomes ready, then .removed arrives, then probe B becomes ready.
- **Should happen:** No onResolve after onRemove for that result key. A superseded probe is cancelled and emits nothing.
- **Happens:** onResolve fires for probe B after onRemove. NativeDiscovery then cancels the pending removal, and the departed device stays known.
- **Why:** The bug is real. When `.changed` arrives, `probeIPv4First` overwrites `probes[key]` with a new probe B and does not cancel the old probe A. When A becomes ready, its `.ready` block sets `probes[key]=nil`, so B is no longer tracked. `remove()` then has nothing to cancel, clears `resultTXT` and calls `onRemove`. When B becomes ready, its `.ready` block calls `onResolve` without checking that the result still exists. Downstream this matters: `NativeDiscovery.handleResolve` cancels the pending removal for that leg (`pendingRemoves...removeValue(...).cancel()`), so a speaker that has gone away stays in `known` as a ghost entry until it is removed again. Port: /tmp/hunt/p38/test_probe.py. Output on the current logic: /tmp/hunt/p38/out_current.txt. Output with the fix: /tmp/hunt/p38/out_fixed.txt.
- **Failing test:** `/tmp/hunt/p38/test_probe.py` (copy: `tests/p38/`). Output: log: [('resolve', 'v4_1'), ('remove',), ('resolve', 'v4_2')]
FAIL: onResolve after onRemove: [('resolve', 'v4_2')]. Fix checked on a copy: True
- **Fix:**

```swift
In probeIPv4First (and the same in probeUnconstrainedFallback):
  probes[resultKey]?.cancel()          // before `probes[resultKey] = connection`
  probes[resultKey] = connection
  ...
  case .ready:
    self.queue.async {
      guard self.probes[resultKey] === connection else { connection.cancel(); return }
      ... onResolve / logIPv6Only ...
      connection.cancel(); self.probes[resultKey] = nil
    }
  case .failed, .cancelled:
    self.queue.async {
      guard self.probes[resultKey] === connection else { return }
      self.probes[resultKey] = nil
      self.probeUnconstrainedFallback(...)   // fallback branch: just the nil
    }
```

## 27. [Medium] AudioutCore/CompanionServer.swift:489 — stopLocked(reason:)  (candidate #39)
- **Status:** demonstrated
- **Claim:** stop()/restart clears `awaiting` without firing onApprovalAbandoned, and the later .cancelled handler finds nothing, so an open Allow prompt is never withdrawn
- **Input:** The phone's hello is accepted, so it waits in `awaiting` and the approval prompt is on screen. The user then turns remote control off, which calls stop(reason: disabled), or start(identity:) restarts the server.
- **Should happen:** onApprovalAbandoned("PHONE-A") should fire. The on-screen prompt should then be withdrawn and the cooldown started.
- **Happens:** onApprovalAbandoned never fires, so approvals.abandonRequest never runs. activePromptClientID stays "PHONE-A" and withdrawPrompt is never called, so the prompt stays open.
- **Why:** The bug is real. stopLocked() (CompanionServer.swift around lines 489-499) copies `awaiting` and empties it, then cancels each connection. When the `.cancelled` handler later calls removeClient(id), the id is no longer in `awaiting`, so it is never removed from there and noteApprovalAbandoned is never called. Nothing else withdraws the prompt either. CompanionCoordinator.updateServerState's off branch only calls server.stop(reason: .disabled), and nothing else touches `approvals`. The restart path, startLocked, runs stopLocked as its first step, so it loses the prompt the same way. As a result CompanionApprovals keeps activePromptClientID and the held deciders, and the Allow prompt stays on screen for a phone that has already been disconnected.
- **Failing test:** `/tmp/hunt/p39/test_stop_abandon.py` (copy: `tests/p39/`). Output: current active prompt: PHONE-A withdrawn: [] -> FAIL   (fixed copy: `--fix` -> PASS; see /tmp/hunt/p39/out.txt). Fix checked on a copy: True
- **Fix:**

```swift
In stopLocked, after `awaiting.removeAll()` and the loop that sends goodbyes and cancels, add:
for (_, client) in droppedAwaiting { noteApprovalAbandoned(client) }
(`awaiting` is already empty at that point, so the shared-identity guard lets each phone identity through. If two connections share an identity the callback fires twice, and the second abandonRequest does nothing.)
```

## 28. [Medium] AudioutCore/NativeBackend+Tone.swift:397 — setOutputSet  (candidate #40)
- **Status:** demonstrated
- **Claim:** Every edge test is `previous != wantOn` with `previous` an Optional<Bool>. For any known AirPlay id whose desiredOn is nil (discovered after the last setOutputSet, or cleared at :461 when it vanished and came back), a call that leaves it out of the set counts as an edge: nil != false. The call clears failedGate, writes `.off` over the row's connection state (:437) and claims `converging` with a kick. A per-app-only speaker that is `.connected`, `.connecting` or `.awaitingPassword` through its per-app bind gets its row reset to `.off` while its session keeps playing, and a parked failure loses its park.
- **Input:** A and P are known AirPlay ids. P was discovered later and never selected, so desiredOn[P] is nil. A per-app bind sets P's row to .connected through setPerAppConnectionStateLocked. Then setOutputSet([A]) is called.
- **Should happen:** P is not in the selection before or after the call, so there is no edge. Its per-app .connected state and any park should be left alone.
- **Happens:** P counts as an edge. Its row is set to .off, any failedGate park is cleared, it is put in converging and kicked, and the converge does nothing. The row stays .off while the per-app session plays.
- **Why:** desiredOn is only ever written by setOutputSet, convergeToTarget and removeAll, so a speaker discovered later starts with desiredOn == nil. setOutputSet([A]) treats nil != false as a membership edge for P. That clears failedGate, calls setConnectionState(.off) directly and skips the per-app claim guard, so P's per-app .connected row goes to .off. It also puts P in converging. The converge then finds want == isOn and does nothing. On release, redrivePerApp needs streamBindings[P] == nil, which is false while P is bound, so nothing sets the row back while the per-app session keeps playing.
- **Failing test:** `/tmp/hunt/p40/port.py` (copy: `tests/p40/`). Output: P state: off kicked P: True / AssertionError: FAIL: per-app-connected P reset to .off by unrelated setOutputSet([A]) (with --fix: P state: connected kicked P: False / PASS). Fix checked on a copy: True
- **Fix:**

```swift
In NativeBackend+Tone.swift setOutputSet, treat "never desired" the same as "desired off":
    let previous = self.desiredOn[id] ?? false
```

## 29. [Medium] AudioutCore/CastOutputManager.swift:597 — retry(deviceID:)  (candidate #41)
- **Status:** demonstrated
- **Claim:** retry() calls teardown and then startRecipe straight away. It ignores teardownsInFlight and leaves awaitingTeardown set. So it sends LAUNCH while the receiver is still processing STOP. And if the session was waiting on a teardown, teardownFinished later calls startRecipe a second time. startRecipe overwrites channel, client and server without closing them, so the first connection and server leak.
- **Input:** select, deselect, then reselect the device (awaitingTeardown=true), retry(deviceID:) while STOP is unanswered; or fail(), then retry() at once
- **Should happen:** The recipe starts exactly once, after the last teardown for that id has finished. No channel or server is orphaned.
- **Happens:** The recipe starts while teardownsInFlight is 2 (LAUNCH lands during STOP). When STOP answers, teardownFinished starts a second recipe, and the first channel is left open, never closed.
- **Why:** The claim is real. retry() runs teardown and then startRecipe right away. It never looks at teardownsInFlight and never clears awaitingTeardown. Real callers can reach it: retryOutput has no state gate (retryConnection, requestReconnect, the launch restore), and a failed row's own teardown STOP chain is still running when the user clicks retry. The setDevices/teardownFinished comment states the invariant: no LAUNCH while the receiver is still on STOP. Scenario A (retry on a row with awaitingTeardown set) starts a recipe while 2 teardowns are in flight. The old teardown's completion then calls startRecipe again, which overwrites ch2 without closing it, so ch2 leaks, along with its server if one was set. Scenario B (retry straight after fail) connects while STOP is in flight. handleDrop's 2 s reconnect has the same gap.
- **Failing test:** `/tmp/hunt/p41/port.py` (copy: `tests/p41/`). Output: FAIL A: leaked channel(s) ['ch2'] / FAIL A: recipe started while STOP in flight: ['LAUNCH-path connect ch2 (tif=2)'] / FAIL B: ... ['LAUNCH-path connect ch5 (tif=2)'] (/tmp/hunt/p41/out_current.txt; fixed run /tmp/hunt/p41/out_fixed.txt prints PASS). Fix checked on a copy: True
- **Fix:**

```swift
In retry(deviceID:):
    session.autoRetryCount = 0
    self.teardown(session)
    if self.teardownsInFlight[deviceID] != nil {
        session.awaitingTeardown = true
        self.setState(session, .connecting)
    } else {
        self.startRecipe(session)
    }
Make the same change in handleDrop's asyncAfter closure: if teardownsInFlight[id] != nil, set session.awaitingTeardown = true instead of calling startRecipe(session). teardownFinished then starts the recipe once.
```

## 30. [Medium] AudioutCore/CastOutputManager.swift:1001 — handleDrop / fail  (candidate #42)
- **Status:** demonstrated
- **Claim:** After a drop, a reconnect attempt that fails at connect, launch or the deadline goes through fail(), which sets .failed and never retries. So the promised run of up to three attempts ends after one failed attempt. handleDrop's asyncAfter reconnect also skips the teardown-in-flight wait.
- **Input:** The receiver plays, then drops (onClose fires). The first reconnect's connect fails (receiver still rebooting). The second would succeed.
- **Should happen:** The run keeps going up to 3 automatic attempts. The second reconnect succeeds and the row returns to playing.
- **Happens:** After the drop the state goes to connecting, the reconnect's connect fails, fail() runs and the row stays .failed(connect). Only one reconnect attempt is made (2 connects in total).
- **Why:** The bug is real. `autoRetryCount` only goes up in `handleDrop` (from `onClose`, or IDLE after playing). A reconnect that fails at connect, receiver status, server start, launch, load or the play deadline goes to `fail()` instead, which tears down and sets `.failed` with no retry. So when a rebooting receiver refuses the first reconnect, the "run of at most three attempts" stops after one attempt. A count of 2 or 3 only happens if a reconnect connects and then drops before PLAYING. The second part of the claim also holds by reading: the reconnect `handleDrop` schedules runs after the fixed 2 s `reconnectDelay` and never checks `teardownsInFlight`. That is the exact LAUNCH-during-STOP race the `teardownsInFlight` comment warns about. It is not in the port or the fix.
- **Failing test:** `/tmp/hunt/p42/port.py` (copy: `tests/p42/`). Output: states: ['connecting', 'playing', 'connecting', ('failed', 'connect', 'connectionFailed: refused (rebooting)')] connects: 2 -> AssertionError: run ended after one failed reconnect (out_current.txt). With the fix (port.py --fixed): states end at 'playing', connects: 3, PASS (out_fixed.txt). Fix checked on a copy: True
- **Fix:**

```swift
// CastOutputManager.swift, fail(_:_:stage:): while an automatic reconnect run is under way, a failed attempt counts as the next drop instead of ending the run
private func fail(_ session: Session, _ error: Error, stage: Stage) {
    if (1..<3).contains(session.autoRetryCount) {
        handleDrop(id: session.record.id, generation: session.generation, reason: String(describing: error))
        return
    }
    teardown(session)
    setState(session, .failed(Self.failure(for: error, stage: stage)))
}
```

## 31. [Medium] AudioutCore/CastOutputManager.swift:739 — afterReceiverStatus (server.onRequest) / teardown  (candidate #43)
- **Status:** demonstrated
- **Claim:** Session.loggedHTTPRequest is set on the first GET and never reset by teardown or startRecipe, so after a drop-reconnect or a user retry the new attempt's first GET does not re-arm the play deadline.
- **Input:** The first attempt reaches PLAYING. Then retry(deviceID:) runs. On the second attempt LAUNCH is at t=103, the first GET at t=115 and PLAYING at t=125, with playDeadline=20.
- **Should happen:** The first GET of the new attempt should re-arm the deadline to t=135, as it does on the first attempt, so the session reaches PLAYING at t=125.
- **Happens:** The second attempt's GET is not treated as the first, so the deadline is not re-armed. The deadline armed at launch fires at t=123 and the session ends in failed(timeout) before PLAYING arrives.
- **Why:** The bug is real. The Session object stays alive across retry(deviceID:) and handleDrop, since both call teardown and then startRecipe on the same object. Neither teardown nor startRecipe resets loggedHTTPRequest. On the second attempt the onRequest handler returns at `guard !session.loggedHTTPRequest` before it reaches armPlayDeadline. That leaves only the deadline armed in afterLaunch (launch + 20 s) running. A receiver that sends its GET about 12 s after launch and reaches PLAYING about 22 s after launch is therefore failed with a timeout. The first attempt with the same timing succeeds. Test: /tmp/hunt/p43/test_rearm.py, a Python port of the logic. It fails on the current logic (/tmp/hunt/p43/out_current.txt) and passes with the fix (/tmp/hunt/p43/out_fixed.txt).
- **Failing test:** `/tmp/hunt/p43/test_rearm.py` (copy: `tests/p43/`). Output: second attempt state: failed(timeout)
AssertionError: FAIL: second attempt timed out at t=123 (GET at 115 did not re-arm). Fix checked on a copy: True
- **Fix:**

```swift
In CastOutputManager.teardown(_:), next to `session.wasPlaying = false`, add:
    session.loggedHTTPRequest = false
```

## 32. [Medium] AudioutCore/SyncedLocalSink.swift:329 — clearSessionState  (candidate #44)
- **Status:** demonstrated
- **Claim:** anchored=false is published before ring.reset(); the tap thread keeps enqueueing during a rebuild/reanchor, so it can re-anchor on a chunk that reset() then discards. The session then starts with a pts one chunk or more off, and the phase loop never sees the error.
- **Input:** Stream 5 chunks. Then call requestReanchor, which runs clearSessionState: its locked section sets anchored=false, a tap enqueue of chunk 5 lands next, and ring.reset() runs after it. Then enqueue chunk 6.
- **Should happen:** The anchor pts should be the pts of the chunk at ring sample 0.
- **Happens:** The anchor pts is chunk 5's (50 ms), but ring sample 0 is chunk 6 (60 ms). Local playback stays 10 ms off for the whole session.
- **Why:** The bug is real. clearSessionState sets anchored=false under stateLock at line 329, then runs the overflow Telemetry.log, and only calls ring.reset() at line 347. Nothing stops the tap thread's enqueue during requestReanchor (the control queue), a device change or sleep/wake. If an enqueue lands in that window, it takes the lock, anchors on its own pts and writes its chunk, and reset() then throws that chunk away. The next chunk becomes ring sample 0 while the anchor still holds the pts of the discarded one. The phase loop measures error as audioStart − target − consumedFrames, which only compares the timeline with itself, so it cannot see this offset. The whole session stays one chunk or more off, 10 ms for a 480-frame chunk at 48 kHz. The test is a deterministic Python port of enqueue, clearSessionState and the ring's write/reset, run with that interleaving.
- **Failing test:** `/tmp/hunt/p44/test_reanchor_race.py` (copy: `tests/p44/`). Output: anchor pts=50000000 chunk-at-ring-sample-0=6 pts=60000000 error=10.00 ms / AssertionError: FAIL: session anchored 10.00 ms off (anchor chunk discarded by reset)  (/tmp/hunt/p44/out_current.txt; fixed run in /tmp/hunt/p44/out_fixed.txt). Fix checked on a copy: True
- **Fix:**

```swift
// 1) clearSessionState: reset the ring before anchored=false is published, inside the lock
stateLock.withLock {
    ring.reset()            // moved from after Telemetry.log (old line 347)
    anchored = false
    ...
}
// 2) enqueue, in the `if !anchored {` branch under stateLock: drop leftovers an old-session
//    enqueue wrote after the reset (render does not drain while !anchored)
if !anchored {
    ring.reset()
    let delay = ...
    anchored = true
    ...
}
```

## 33. [Medium] AudioutCore/SyncedLocalSink.swift:947 — applyUserOffsetDelta / InterleavedFloatRing.seekRoomSamples+applyPendingShift  (candidate #45)
- **Status:** demonstrated
- **Claim:** Backward seek room is all non-used slots (capacity-1-used), but only the audio played since this session's anchor is valid history. After reset() (tail=head) the area behind tail holds the previous session's audio or initial zeros, and a backward shift that fits the room replays it.
- **Input:** The ring holds 10 s at 1 kHz mono. Session 1 writes and plays 3000 samples of value 1.0, then reset() runs. Session 2 writes a 2000-sample pre-roll of value 2.0, releases and reads 100 samples. Then applyUserOffsetDelta(+300) is called and the next 300 samples are read.
- **Should happen:** The backward room should be limited to what this session has consumed (100 samples). The +300 ms request should fall through to requestReanchor("offset_change"), or at most replay only this session's audio.
- **Happens:** The room check passes because the backward room is 16383-1900, so the shift of -300 is applied in full. The next read returns 200 samples of session 1's audio (1.0) before session 2's first sample.
- **Why:** The bug is real. clearSessionState() calls ring.reset(), which sets tail = head, so every slot behind tail still holds the previous session's audio (or zeros on the first session). seekRoomSamples.backward and applyPendingShift both allow a backward move into all capacity-1-used slots. Once released, applyUserOffsetDelta trusts that bound, and NativeBackend.applyLocalSyncOffsetLive calls it on every stepper step. A delta larger than what this session has consumed therefore passes the room check and replays audio from before this session's anchor, when it should re-anchor. The port is /tmp/hunt/p45/ring_port.py. It fails on the current logic (/tmp/hunt/p45/out_current.txt) and passes with the fix (/tmp/hunt/p45/out_fixed.txt).
- **Failing test:** `/tmp/hunt/p45/ring_port.py` (copy: `tests/p45/`). Output: fix=False action=shift stale_samples_replayed=200 -> AssertionError: replayed previous-session audio from behind the session anchor. Fix checked on a copy: True
- **Fix:**

```swift
Add a consumer-owned counter to InterleavedFloatRing, `private let sessionConsumedPtr: UnsafeMutablePointer<Int>`, initialised to 0. It counts how far tail has moved since the last reset(). Update it in these places:
- read(): `sessionConsumedPtr.pointee &+= count`
- skipForward(): `sessionConsumedPtr.pointee &+= applied`
- applyPendingShift(): `sessionConsumedPtr.pointee &+= applied`. A backward shift is negative, so this lowers the counter.
- reset(): `sessionConsumedPtr.pointee = 0`

Then cap the backward room in both places that compute it:
- seekRoomSamples: `backward: min(capacity - 1 - used, sessionConsumedPtr.pointee)`
- applyPendingShift: `delta < 0 ? -min(-delta, min(capacity - 1 - used, sessionConsumedPtr.pointee)) : min(delta, used)`
```

## 34. [Medium] AudioutCore/SyncedLocalSink.swift:468 — applyUserOffsetDelta(ms:) / enqueue  (candidate #46)
- **Status:** demonstrated
- **Claim:** An offset change made while the sink is started but not yet anchored is dropped. The early return assumes the anchor will read userOffsetMs itself, but enqueue anchors with cachedTotalDelayNanos, which start() measured with the old offset. The backend has already advanced lastAppliedLocalOffsetMs, so the change is lost until the next rebuild.
- **Input:** start() with offset 0, then the offset is set to +200 (delta 200 is sent before any enqueue), then enqueue(pts=1s)
- **Should happen:** targetReleaseNanos = pts + delay measured with offset 200
- **Happens:** targetReleaseNanos = pts + delay measured with offset 0, so the +200 ms is silently dropped
- **Why:** start() caches cachedTotalDelayNanos using the old offset. applyUserOffsetDelta returns early when the sink is not anchored, and the cache is left as it was. enqueue's anchor then uses `cachedTotalDelayNanos ?? measure`, so it takes the stale cached delay and never reads the new userOffsetMs. NativeBackend.applyLocalSyncOffsetLive has already set lastAppliedLocalOffsetMs to the new value, so no later call resends the delta. The offset is lost until the next rebuild. The same window opens after every rebuild, because start() fills the cache again right after clearSessionState.
- **Failing test:** `/tmp/hunt/p46/port.py` (copy: `tests/p46/`). Output: target=1100000000 expected=1300000000 lastApplied=200.0 / FAIL: +200 ms offset lost (target off by 200 ms)  (/tmp/hunt/p46/out_current.txt; with FIX=1, PASS in /tmp/hunt/p46/out_fixed.txt). Fix checked on a copy: True
- **Fix:**

```swift
In applyUserOffsetDelta, clear the stale cache under the same lock take when the sink is not anchored:
    stateLock.lock()
    let isAnchored = anchored, hasReleased = released
    if !isAnchored { cachedTotalDelayNanos = nil }  // the anchor then re-measures with the live offset
    stateLock.unlock()
    guard isAnchored else { return }
```

## 35. [Medium] AudioutCore/SyncedLocalSink.swift:776 — renderInterleaved  (candidate #47)
- **Status:** demonstrated
- **Claim:** When the render thread's stateLock.try() fails while the session is released, the code zero-fills the whole cycle and drains nothing from the ring or the resampler. That is an audible ~10 ms dropout plus a one-cycle content slip. The PI loop is clamped to 200 ppm, so it needs at least 53 s to pull that slip back. Contention comes from routine off-thread callers: setGain, hasStartedRendering (polled by the wizard arm gate), latestPhaseErrorNanos, and applyUserOffsetDelta.
- **Input:** Released session at 48 kHz with 512-frame cycles, after the loop has converged. The lock is held by another caller (for example setGain or hasStartedRendering) during cycle 400.
- **Should happen:** A released session keeps draining through a missed try(), using the last cycle's target and gain. There is no dropout and no phase slip.
- **Happens:** All 512 frames of the contended cycle are zeros. The next cycle's phase error is 512 frames, and the loop needs 53.3 s to bring it back under 1 frame.
- **Why:** The bug is real. In renderInterleaved, when stateLock.try() fails, the else branch zero-fills the whole cycle and returns. It does this even when the session is already released, so it drains nothing from the ring or the resampler. After that cycle the content position is 512 frames behind the output timeline. The PI loop is clamped to 200 ppm, so pulling the slip back takes about 53 s, while the speakers play out of sync by about 10.7 ms. Real callers do take the lock off the render thread: NativeBackend:3204 calls setGain on captureControlQueue, NativeBackend+Bluetooth:3162 polls hasStartedRendering for the wizard arm gate, and latestPhaseErrorNanos and applyUserOffsetDelta also take it. Each hold is short, so contention is rare, but it can happen, and a priority inversion on a preempted holder makes it more likely. The doc comment on `gain` says a missed try() "just replays the previous cycle's gain". The code does something else: it outputs silence and causes a phase slip. The test is a faithful Python port of renderInterleaved, FractionalResampler and PhaseController (/tmp/hunt/p47/port.py, test /tmp/hunt/p47/test_contention.py, output /tmp/hunt/p47/output.txt). With the fix (FIX=1) the cycle plays audio and the slip is 0.
- **Failing test:** `/tmp/hunt/p47/test_contention.py` (copy: `tests/p47/`). Output: slip after contended cycle: 512.0 frames; recovery to <1 frame: 53.3 s
FAIL: dropout: 512/512 zero samples in released cycle; content slip 512.0 frames. Fix checked on a copy: True
- **Fix:**

```swift
// Snapshot that only the render thread uses. Reset it in clearSessionState(), next to resampler.reset(); the engine is stopped there.
private var renderReleasedTarget: Int64?
private var renderGain: Float = 1.0
// in clearSessionState(): renderReleasedTarget = nil; renderGain = 1.0

// in renderInterleaved, just before the first stateLock.unlock():
renderGain = gainSnapshot
renderReleasedTarget = shouldDrain ? target : nil

// replace the try()-failed else branch:
} else if let cachedTarget = renderReleasedTarget {
    // Released session: keep draining with last cycle's snapshot rather than slip a whole cycle.
    target = cachedTarget; gainSnapshot = renderGain; silentFrames = 0; shouldDrain = true
} else {
    base.update(repeating: 0, count: total)
    return false
}
```

## 36. [Medium] AudioutCore/PTPHelperService.swift:773 — PTPHelperSelfHealingActivator.activate(timeout:)  (candidate #48)
- **Status:** demonstrated
- **Claim:** The in-flight guard is checked only once, before the cycle starts. A second device's activate() that begins while the unregister/drain/register cycle is running is not blocked: it reads status mid-teardown (.notRegistered) and returns .needsApproval(.notRegistered) at once. A wait that is already mid-flight during the teardown is not protected either.
- **Input:** A's inner.activate returns .timingPortsUnavailable, so A starts the cycle. B calls activate() after unregister() has run (status .notRegistered) but before register().
- **Should happen:** B waits for the cycle in progress, then runs its own attempt against the newly registered helper and gets .ready. It never reports needsApproval for a helper that is already approved.
- **Happens:** B returns ('needsApproval', 'notRegistered') at once. A's cycle succeeds and A ends .ready.
- **Why:** Real and reachable. NativeBackend shares one PTPHelperSelfHealingActivator across devices, and convergeDevice and the per-app bind paths call ensurePTPTakeover concurrently. activate() checks othersInFlight == 0 only once. While the cycle runs it holds no in-flight count and sets no 'cycling' flag, so a new activate() goes straight to inner.activate. Inner reads status first (line 317). Mid-teardown that status is .notRegistered, so B gets .needsApproval(.notRegistered) at once. B's connect then fails with timingUnavailable: the device is deselected and the takeover banner shows 'needs approval', even though A's cycle then registers again and recovers. A wait that starts between A's endAttempt/arm check and unregister() is also left unprotected: it sees .enabled, and then the daemon is torn down under it.
- **Failing test:** `/tmp/hunt/p48/test_p48.py` (copy: `tests/p48/`). Output: A: ready  B: ('needsApproval', 'notRegistered')
FAIL: device B got ('needsApproval', 'notRegistered') mid-cycle (helper is approved; cycle succeeded). Fix checked on a copy: True
- **Fix:**

```swift
// PTPSelfHealState: add a cycle gate. Arm only when inFlight == 0, checked under the same lock.
private var cycling = false
private var waiters: [CheckedContinuation<Void, Never>] = []
func beginAttempt() async {
    while true {
        let mustWait: Bool = { lock.lock(); defer { lock.unlock() }
            if !cycling { inFlight += 1; return false }; return true }()
        if !mustWait { return }
        await withCheckedContinuation { c in
            lock.lock()
            if cycling { waiters.append(c); lock.unlock() } else { lock.unlock(); c.resume() }
        }
    }
}
func armCycleIfEligible(now: Date, window: TimeInterval) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard inFlight == 0 else { return false }
    let rateLimitClear = lastCycleAt.map { now.timeIntervalSince($0) > window } ?? true
    guard rateLimitClear else { return false }
    lastCycleAt = now; cycling = true
    return true
}
func finishCycle() {
    lock.lock(); cycling = false; let w = waiters; waiters = []; lock.unlock()
    w.forEach { $0.resume() }
}
// activate(timeout:): use `await state.beginAttempt()` in both places. Right after a
// successful arm, add `defer`-style handling: call state.finishCycle() once
// unregisterDrainAndReregister returns (on every outcome), before the retry's beginAttempt.
```

## 37. [Low] AudioutCore/NativeDiscovery.swift:1048 — probeIPv4First  (candidate #6)
- **Status:** demonstrated
- **Claim:** A successful IPv4 probe calls connection.cancel(), whose .cancelled state lands in the same branch as .failed and starts the 'IPv6-only' unconstrained fallback probe for every resolved service
- **Input:** A dual-stack AirPlay service is resolved. The IPv4-forced probe reaches .ready, and its own cancel() then delivers .cancelled while resultTXT[resultKey] is still set.
- **Should happen:** One probe and one onResolve per resolved service. The fallback probe should start only when the IPv4-forced probe actually fails (.failed).
- **Happens:** A second, unconstrained NWConnection probe starts for every resolved service. Depending on which address the path picks, the service is either reported twice through onResolve, or a false "IPv6-only" error is logged for a device that has IPv4.
- **Why:** The claim is real. In NativeDiscovery.swift, probeIPv4First's `.ready` branch calls `connection.cancel()`. NWConnection then delivers `.cancelled`, and that lands in the shared `case .failed, .cancelled:` branch. That branch calls probeUnconstrainedFallback. Its guard (`resultTXT[resultKey] != nil`) still passes, because the service has not been removed. So every successfully resolved service starts a second, unconstrained probe. That second probe either emits onResolve a second time (when the path picks IPv4) or writes a false "resolved ONLY to an IPv6 address" log for a dual-stack device (when it picks IPv6). The test is a faithful Python port, since there is no Swift toolchain here; it is /tmp/hunt/p6/port.py. Output on the current logic is in /tmp/hunt/p6/out_current.txt and output with the fix in /tmp/hunt/p6/out_fixed.txt.
- **Failing test:** `/tmp/hunt/p6/port.py` (copy: `tests/p6/`). Output: prefer=v4: probes started=[('start', 'v4'), ('start', 'any')], onResolve count=2, IPv6-only logs=0 / prefer=v6: ... onResolve count=1, IPv6-only logs=1 -> FAIL. Fix checked on a copy: True
- **Fix:**

```swift
In probeIPv4First, split the state switch so only `.failed` starts the fallback:

case .failed:
    self.queue.async {
        self.probes[resultKey] = nil
        self.probeUnconstrainedFallback(endpoint: endpoint, resultKey: resultKey, name: name, serviceType: serviceType, txt: txt)
    }
case .cancelled:
    self.queue.async { self.probes[resultKey] = nil }
```

## 38. [Low] AudioutCore/MockBackend.swift:228 — start()  (candidate #10)
- **Status:** demonstrated
- **Claim:** With staggerDiscovery (default true), updateLocalDeviceName(observer.currentDeviceName) runs before local-mac is live, so it is a no-op; the device is then discovered with the hardcoded name and stays wrong until the default output changes
- **Input:** MockBackend(outputObserver: obs) with the default staggerDiscovery=true, obs.currentDeviceName = "External Headphones", start(), then run the delayed discovery items
- **Should happen:** local-mac is named "External Headphones", the current default output
- **Happens:** local-mac is discovered and stays named "MacBook Pro Speakers"
- **Why:** The bug is real. In start(), staggerDiscovery only schedules local-mac's discovery with a delay, so `live` is still empty when start() reaches its last line, `updateLocalDeviceName(observer.currentDeviceName)`. That call finds no local device and does nothing. Later the delayed work item adds the fleet copy, which still has the hardcoded name "MacBook Pro Speakers". It only gets renamed when observer.onChange fires. A real caller hits this: OutputBackend.swift:712 builds the mock backend with the default staggerDiscovery=true and a DefaultOutputObserver(). The test is /tmp/hunt/p10/port.py, a Python port of the Swift logic. It fails on the current logic (/tmp/hunt/p10/out_current.txt) and passes with the fix (/tmp/hunt/p10/out_fixed.txt).
- **Failing test:** `/tmp/hunt/p10/port.py` (copy: `tests/p10/`). Output: local-mac name after discovery: MacBook Pro Speakers
AssertionError: FAIL: expected 'External Headphones', got 'MacBook Pro Speakers'. Fix checked on a copy: True
- **Fix:**

```swift
In start(), inside the stagger work item (and likewise in the non-stagger branch), apply the observer's current name before inserting the device:
    guard self.started, self.live[device.id] == nil else { return }
    var device = device
    if device.isLocalDevice, let observer = self.outputObserver { device.name = observer.currentDeviceName }
    self.live[device.id] = device
    self.emit(.deviceAdded(device))
```

## 39. [Low] AudioutCore/NativeBackend+Bluetooth.swift:2209 — playCompanionAlignmentDemo / applyCompanionAlignmentMeasurement  (candidate #19)
- **Status:** demonstrated
- **Claim:** The A/B demo's 'before' value is recorded as the stored LATENCY alone (`applied`, 0 when none). The trim in force before the measurement is left out, and the demo then plays both legs with the trim zeroed. So the 'before' leg does not reproduce what the speaker actually played before.
- **Input:** Speaker with trim -150 and no stored latency. The phone measures 150, the Keep writes latency 150 and trim 0, then playCompanionAlignmentDemo runs.
- **Should happen:** The before leg should reproduce what the speaker played before: shift -150, the same as the after leg.
- **Happens:** The demo's before leg pushes latency 0 with trim 0 (shift 0) and its after leg pushes latency 150 (shift -150). It plays a 150 ms change.
- **Why:** The sink's delay term is reference − latency + trim (BTSyncedSink setOffsetMs applies −Δ, setTrimMs applies +Δ). The apply step saves only `applied`, the stored latency, as the demo's "before" value. The trim that was in force (run.trimAtSessionStartMs) is left out. Keep sets the trim to 0, and the demo then only pushes latencies. So with trim −150 and no latency, the speaker actually played at shift −150, but the demo's "before" leg plays at shift 0. The A/B demo shows a 150 ms difference that never existed: before and after should both be at −150. Port and test: /tmp/hunt/p19/port.py. Output: /tmp/hunt/p19/out_current.txt (fails) and /tmp/hunt/p19/out_fixed.txt (passes with --fix).
- **Failing test:** `/tmp/hunt/p19/port.py` (copy: `tests/p19/`). Output: shift before measurement: -150 demo legs (before, after): [0, -150]
AssertionError: demo 'before' leg 0 != what played before -150. Fix checked on a copy: True
- **Fix:**

```swift
In applyCompanionAlignmentMeasurement (NativeBackend+Bluetooth.swift ~2209), save the before value as a latency-equivalent that includes the trim, since latency and trim are the same linear term:
btTrimLock.withLock { companionPreMeasurementLatencyMsByUID[targetID] = applied - run.trimAtSessionStartMs }
```

## 40. [Low] AudioutCore/BTSyncedSink.swift:1160 — BTDeviceSink.enqueue  (candidate #24)
- **Status:** demonstrated
- **Claim:** When stateLock.try() fails on the first buffer, that buffer is still written to the ring but the anchor takes the next buffer's pts. The ring's head is therefore one whole buffer older than the anchor, and the device plays late by a full buffer (about 11.6 ms at 512/44.1k) for the whole session.
- **Input:** 512-frame buffers at 44.1 kHz with a 200 ms delay. The first enqueue sees stateLock busy (try fails). Later enqueues take the lock, and the render cycles run on the same grid.
- **Should happen:** Each frame plays at its capture pts + delay. The error should be 0 ms, as the fixed port shows.
- **Happens:** Every released frame plays 11.610 ms (one 512-frame buffer) after its capture pts + delay, for the whole session.
- **Why:** Real. When `try()` fails, `enqueue` still calls `delayLine.write`, so that buffer goes into the ring. The next successful `try()` anchors on that later buffer's pts. Release fires at `anchorPts + delay`. `catchUpToTargetLocked` only skips the render overshoot past the target, and `realignToDevicePulls` only follows the device's pull rate. Neither checks the ring's own pts, so the FIFO's oldest (unanchored) buffer plays at the anchored buffer's time. The device stays one buffer late (k buffers if k `try()` calls fail) for the whole session. The doc comment above `enqueue` calls this a "sub-ms pts shift", which is wrong. The trigger can happen in real use: the render thread runs before audio arrives and takes `stateLock` via `try` every cycle, and graphQueue reads like `hasAnchored`, `setEQ` and the health check use `withLock`. It is rare, but it is a race in production, not a test-only path.
- **Failing test:** `/tmp/hunt/p24/port.py` (copy: `tests/p24/`). Output: current: max |playout - (pts+delay)| = 11.610 ms over 21388 frames / AssertionError: FAIL: device plays late by 11.610 ms (one buffer)   (fixed: 0.000 ms, PASS — /tmp/hunt/p24/out_fixed.txt). Fix checked on a copy: True
- **Fix:**

```swift
In BTDelayLine add `var bufferedFrames: Int { ring.usedFrames }`. In BTDeviceSink.enqueue, inside `if !anchored {`, back-date the anchor by whatever is already buffered:
    let backlogNanos = Int64((Double(delayLine.bufferedFrames) / renderSampleRate * 1e9).rounded())
    anchorPtsNanos = SyncTiming.monotonicNanos(pts) &- backlogNanos
(The ring is empty after reset, so this is a no-op on the normal path.) Also correct the doc comment: a missed try() costs a whole buffer, not a sub-ms shift.
```

## 41. [Low] AudioutCore/BTSyncedSink.swift:1140 — BTDeviceSink.clearSessionStateLocked  (candidate #26)
- **Status:** demonstrated
- **Claim:** anchored is cleared under stateLock, but delayLine.reset() runs afterwards, outside the lock, while the tap thread is still enqueuing. An enqueue in that window anchors on its pts and writes its buffer, and reset() then discards it. The first frame released then belongs to a later pts, so the device plays early. reset() is also documented as 'only while neither thread is active', yet the producer is live here.
- **Input:** Music is playing and the session is anchored. A rebuild (for example config_change) runs clearSessionStateLocked. The tap's enqueue(pts=3) lands after stateLock.withLock and before delayLine.reset(). Further enqueues (pts 4, 5) follow.
- **Should happen:** The first frame released belongs to the anchor's pts, which is 3.
- **Happens:** The session anchors on pts 3, but the first frame released is from pts 4, so the device plays one buffer early.
- **Why:** The bug is real. rebuildLocked runs on graphQueue and calls stopLocked, then clearSessionStateLocked. Nothing stops the tap thread during this, so it keeps calling enqueue (BTSyncedSink.swift:2083/2098/2121, NativeCaptureCoordinator:2590). clearSessionStateLocked clears `anchored` inside stateLock, then calls delayLine.reset() after the lock is released (line 1140). An enqueue that lands between the two takes the lock with try(), anchors on its own pts and writes its buffer. reset() then sets readCounter to writeCounter, which throws that buffer away. When the gate opens, the first frame comes from the next buffer, so the device plays early by one capture chunk for the whole session. The call also breaks reset()'s own contract ('only while neither thread is active'), because the producer is still running here. The test is a deterministic Python port with the interleaving forced: /tmp/hunt/p26/port.py, output in /tmp/hunt/p26/out.txt and, with the fix, /tmp/hunt/p26/out_fix.txt.
- **Failing test:** `/tmp/hunt/p26/port.py` (copy: `tests/p26/`). Output: anchorPts=3 first released frame from pts=4
FAIL: first frame released belongs to a later pts than the anchor -> device plays early by one buffer. Fix checked on a copy: True
- **Fix:**

```swift
// clearSessionStateLocked: move the reset into the critical section, so the next anchor cannot happen before it
stateLock.withLock {
    ...
    anchored = false
    ...
    steadyRoomFramesPtr.pointee = 0
    delayLine.reset()          // was after the withLock block
}
resampler.reset()
pullOriginNanos = nil

// enqueue: the anchoring buffer starts an empty ring. This also drops a write whose try() failed and that landed after the reset.
if !anchored {
    delayLine.reset()          // render thread does not read while !anchored/!released
    anchored = true
    ...
}
```

## 42. [Low] AudioutCore/PerAppCaptureCoordinator.swift:545 — handleDeviceChange(bundleID:) failure paths / beginStart  (candidate #29)
- **Status:** demonstrated
- **Claim:** The pending flag is cleared only on a successful rebuild commit. After a failed rebuild, or a start that did not consume it, the stale flag survives and triggers a spurious extra rebuild later.
- **Input:** Capturing slot. A device change starts a rebuild. A second device change fires during `createAndStart` (marked pending). The rebuild then throws, or the resolve comes back empty, and the slot lands in `.failed`. `start(bundleID:)` brings it back to `.capturing`. Then exactly one real device change arrives.
- **Should happen:** One device change should cause exactly one rebuild.
- **Happens:** The single device change rebuilds the tap twice (2 `createAndStart` calls), because the stale pending flag is replayed.
- **Why:** The bug is real. `markPending()` runs whenever a device change arrives while the slot is in `.creatingTap`. The new tap arms its device listener inside `createAndStart`, so this can happen during a rebuild. The flag is cleared only by `takePending()`, which runs on a successful commit in `handleDeviceChange`. Two failure paths go to `.failed` and leave the flag set: an empty resolve, and a throw caught in the catch block. A `.failed` slot is not removed. It is restarted through `start` (backoff or the process-list listener), and the `beginStart` commit never consumes the flag either. On the next real device change, the commit's `takePending()` returns the stale true value and replays `handleDeviceChange`, so a healthy tap is torn down and rebuilt a second time.
- **Failing test:** `/tmp/hunt/p29/test_stale_pending.py` (copy: `tests/p29/`). Output: throw: one real device change -> 2 tap rebuild(s) (expected 1) -> FAIL
empty: one real device change -> 2 tap rebuild(s) (expected 1) -> FAIL   (output in /tmp/hunt/p29/out_current.txt; with fix /tmp/hunt/p29/out_fixed.txt: both PASS). Fix checked on a copy: True
- **Fix:**

```swift
In PerAppCaptureCoordinator.transition(_:bundleID:to:), after `slot.state = newState`, add:
    if case .failed = newState { _ = slot.rebuildCoalescer.takePending() } // a failed slot owes no replay
(Equivalently, call `_ = slot.rebuildCoalescer.takePending()` next to each `transition(..., to: .failed(...))` in handleDeviceChange and beginStart.)
```

## 43. [Low] AudioutCore/LocalPlaybackEngine.swift:645 — addApp (failure rollbacks) / start  (candidate #34)
- **Status:** demonstrated
- **Claim:** addApp's failure paths (unsupportedFormat, connect failure, engine-not-running, play failure) detach the player but never stop an engine that has no nodes. Every caller runs start() before addApp, so a failed first addApp leaves the engine running with zero players and the output device held open. removeApp for that bundle returns early, so nothing ever stops the engine.
- **Input:** start(), then addApp("com.x") fails (bad format, connect raises, or play raises) with no other players attached, then removeApp("com.x")
- **Should happen:** After a failed add leaves no players, the engine stops, just as removeApp does when the last app leaves
- **Happens:** nodes is empty but the engine is still running and holds the output device until the whole backend stops
- **Why:** The bug is real. Both callers (NativeBackend+PerAppRouting.swift:515 and :632) call start() and then addApp. When addApp throws on its unsupportedFormat, connect-failure or play-failure path, it only detaches the new player. Nothing stops the engine, so it keeps running with zero nodes and holds the output device open. removeApp for that bundle returns early because the bundle is not in nodes. The only other thing that stops the engine is the full backend teardown (NativeBackend.swift:2626, localPlaybackEngine?.stop()). One part of the claim is wrong: on the engine-not-running path the engine is already stopped, so nothing is held open there. The triggers are rare (a tap format AVAudioFormat rejects, a connect NSException, or a play() race with a config change), but real callers can reach them.
- **Failing test:** `/tmp/hunt/p34/port.py` (copy: `tests/p34/`). Output: {'fmt_ok': False} nodes= 0 engine running= True FAIL (same for connect_ok/play_ok; rc=1, /tmp/hunt/p34/out.txt). With --fix, all 3 PASS and rc=0 (/tmp/hunt/p34/out_fix.txt). Fix checked on a copy: True
- **Fix:**

```swift
In LocalPlaybackEngine, add a helper that runs on graphQueue:
private func stopEngineIfIdleOnGraphQueue() {
    let (isEmpty, running) = stateLock.withLock { (nodes.isEmpty, engineRunning) }
    if isEmpty, running { engine.stop(); stateLock.withLock { engineRunning = false } }
}
In addApp, call it before each failure throw: both unsupportedFormat guards, the connect-failure catch (after engine.detach(player)), the engine-not-running guard, and the play-failure catch (after the nodes removal and detach). The cleaner way to do the same thing is to wrap the body of the graphQueue.sync block in do { ... } catch { stopEngineIfIdleOnGraphQueue(); throw error }.
```

## 44. [Low] AudioutCore/NativeDiscovery.swift:724 — identity / parseDeviceID vs deriveIDFromInstanceName  (candidate #35)
- **Status:** demonstrated
- **Claim:** The TXT deviceid is used verbatim, but the name-derived id is canonical uppercase colon-hex, so a device whose deviceid TXT is lowercase or has no colons splits into two `known` entries
- **Input:** _airplay "Kitchen" with TXT deviceid='aa:bb:cc:dd:ee:ff', then _raop "AABBCCDDEEFF@Kitchen" with no deviceid TXT
- **Should happen:** One `known` entry, keyed 'AA:BB:CC:DD:EE:FF', holding both the airplay and raop legs.
- **Happens:** `known` gets two entries: 'aa:bb:cc:dd:ee:ff' (airplay) and 'AA:BB:CC:DD:EE:FF' (raop). The one device is listed twice.
- **Why:** This is real. Both services go through identity(for:), and `known` is keyed on the id it returns. parseDeviceID returns the TXT deviceid string unchanged. deriveIDFromInstanceName returns uppercase colon-hex. So a lowercase or colon-less deviceid on _airplay and an instance-name-derived id on _raop for the same device produce two different keys and two entries. The doc comment promises they collapse "regardless of arrival order", but they do not. How much this matters in practice depends on whether real devices publish lowercase deviceid. Apple gear publishes uppercase.
- **Failing test:** `/tmp/hunt/p35/test_identity.py` (copy: `tests/p35/`). Output: known: {'aa:bb:cc:dd:ee:ff': {'airplay'}, 'AA:BB:CC:DD:EE:FF': {'raop'}} / AssertionError: FAIL: one device split into 2 known entries. Fix checked on a copy: True
- **Fix:**

```swift
In parseDeviceID, after parsing `value`, canonicalize a 12-digit hex id the same way deriveIDFromInstanceName does:
    guard let value = UInt64(hex, radix: 16) else { return nil }
    if hex.count == 12 {
        let upper = hex.uppercased()
        let id = stride(from: 0, to: 12, by: 2).map { i -> String in
            let s = upper.index(upper.startIndex, offsetBy: i)
            return String(upper[s..<upper.index(s, offsetBy: 2)])
        }.joined(separator: ":")
        return (id, OutputID(rawValue: value))
    }
    return (idStr, OutputID(rawValue: value))
(Simpler alternative: build `known` keys from the OutputID value instead of the string.)
```

## 45. [Low] AudioutCore/NativeDiscovery.swift:371 — NativeDiscovery.start  (candidate #36)
- **Status:** demonstrated
- **Claim:** The started guard runs only inside queue.async and browser.start() runs unconditionally, so a second start() creates a second pair of NWBrowsers. NetworkFrameworkBrowser.makeBrowser overwrites browsers[type] without cancelling the old one
- **Input:** NativeBackend.start(); NativeBackend.stop(); NativeBackend.start() while the first engine.start() is still awaiting. Both engine starts then resolve, so NativeDiscovery.start() runs twice, followed by a final stop().
- **Should happen:** After stop(), no NWBrowser is still running.
- **Happens:** 4 NWBrowsers are created. After the final stop(), 2 are still running and are no longer referenced from `browsers`, so stop() can never cancel them.
- **Why:** Reached through NativeBackend's public start()/stop(), not by calling discovery directly. NativeBackend.start runs discovery.start() in a Task after `await engine.start()` (NativeBackend.swift:2435-2482), and nothing re-checks `started` after that await. The code says "A later start() after stop() retries", so start after stop is meant to work. Input: backend.start(); backend.stop(); backend.start(), with the first engine.start() still pending. Both Tasks then call discovery.start(). NativeDiscovery.start runs browser.start() even when the `started` guard returns. makeBrowser overwrites browsers[type] without cancelling the old browser, so one NWBrowser pair is orphaned. The final stop() never cancels that pair, and it keeps delivering browse results. The port is in /tmp/hunt/p36b/port.py. I could not check how often the app layer actually does this quick stop/start, because those callers are not in this copy.
- **Failing test:** `/tmp/hunt/p36b/port.py` (copy: `tests/p36/`). Output: browsers created=4 still running after stop=2 / AssertionError: FAIL: NWBrowsers leaked past stop()  (/tmp/hunt/p36b/out_current.txt). Fix checked on a copy: True
- **Fix:**

```swift
In NetworkFrameworkBrowser.makeBrowser, cancel the old browser before replacing it:
-        browsers[type] = browser
+        browsers[type]?.cancel()
+        browsers[type] = browser
(Optional hardening: in NativeDiscovery.start/stop, move browser.start()/browser.stop() inside the queue.async block, after the `started` check.)
```

## 46. [Low] AudioutCore/SystemOutputVolume.swift:690 — handleDeviceChangeLocked / setVolume  (candidate #49)
- **Status:** demonstrated
- **Claim:** Echo suppression compares exact Int equality against the requested value; a device that quantises the scalar (dB steps) reads back a different 0-100 value, so our own write's notification is reported as an external gesture (defaultDeviceChanged:false)
- **Input:** setVolume(1) on the default output, which has 64 hardware volume steps and reads back 2
- **Should happen:** The echo of our own write is suppressed, so nothing fires.
- **Happens:** The HAL echo of our own write reads 2, which differs from lastKnownVolume (1), so it fires (volume:2, muted:false, defaultDeviceChanged:false). That is reported as an external gesture and NativeBackend emits .systemVolumeChanged(2).
- **Why:** The claim holds. When the default output is written directly (resolvingTarget gives nil, e.g. macOS owns the volume on the built-in device), setVolume stores the requested Int in lastKnownVolume. handleDeviceChangeLocked then compares a fresh read-back against that stored value with exact Int equality. On a 64-step device, writing 0.01 snaps to 1/64 = 0.0156, which reads back as 2, so 2 != 1. The echo of our own write therefore fires onExternalChange(2, false, false). In NativeBackend the stored lastSeenSystemVolume is 1 (set by didWrite), so 2 counts as a change and it emits .systemVolumeChanged(2). The volume-key mirror then pushes that onto Main Out, which is a feedback write.
- **Failing test:** `/tmp/hunt/p49/port.py` (copy: `tests/p49/`). Output: readback 2 fired [(2, False, False)]
AssertionError: own write echo reported as external gesture: [(2, False, False)]. Fix checked on a copy: True
- **Fix:**

```swift
In SystemOutputVolume.setVolume(_:resolvingTarget:didWrite:), after the write, store the level the hardware actually landed on instead of the requested one:

let wrote = Self.writeVolume(clamped, to: deviceID)
if isDefaultDevice {
    // Store what the device actually holds; a quantising device snaps `clamped` to its nearest step.
    self.lastKnownVolume = wrote ? (Self.readVolume(deviceID) ?? clamped) : Self.readVolume(deviceID)
}
```

## 47. [Low] AudioutCore/SystemOutputVolume.swift:688 — handleDeviceChangeLocked  (candidate #50)
- **Status:** demonstrated
- **Claim:** The device-listener handler reads currentVolume()/currentMuted() of the CURRENT default, not the device it is registered on; if the old device's notification is delivered on the queue after the default switched but before the system-object listener retargets, the new device's pair is reported as a gesture with defaultDeviceChanged:false
- **Input:** Speaker is the default at volume 30 and the headphones are at 80. The headphones are plugged in: the default switches, and the speaker's device notification is queued ahead of the system-object default-device notification.
- **Should happen:** Only (80, false, defaultDeviceChanged:true) should fire.
- **Happens:** onExternalChange fires (80, false, defaultDeviceChanged:false), so the headphones' level is reported as a user gesture. Then (80, false, true) follows.
- **Why:** The bug is real. Each device-listener block calls handleDeviceChangeLocked() without saying which device it was registered on, and that handler reads currentVolume()/currentMuted(), which look up whatever device is the default right now. Suppose a notification from the old device is already on the queue after the HAL has switched the default, but before the system-object listener's retargetLocked has run. Then the handler compares the new device's values with the old device's lastKnown values. They differ, so it fires (newVol, newMute, defaultDeviceChanged:false). The doc at SystemOutputVolume.swift:79-90 says the volume-key path acts on false, so this would set every AirPlay speaker to the headphones' level, which is the exact case that doc warns about. Removing the listener does not cancel a block that is already queued, and both notifications go to the same queue in no guaranteed order.
- **Failing test:** `/tmp/hunt/p50/test_plug.py` (copy: `tests/p50/`). Output: current [(80, False, False), (80, False, True)] -> FAIL: headphone level reported as gesture (defaultDeviceChanged:false): [(80, False, False)]; fixed [(80, False, True)] -> PASS (see /tmp/hunt/p50/out.txt, port in /tmp/hunt/p50/port.py). Fix checked on a copy: True
- **Fix:**

```swift
// addDeviceListenersLocked: capture the registered device
let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
    self?.handleDeviceChangeLocked(on: deviceID)
}
// handler: drop notifications from a device that is no longer the default;
// the default-device listener will retarget and report with defaultDeviceChanged:true
private func handleDeviceChangeLocked(on deviceID: AudioObjectID) {
    guard Self.currentDefaultOutputDevice() == deviceID else { return }
    let volume = Self.readVolume(deviceID)
    let muted = Self.readMuted(deviceID)
    guard volume != lastKnownVolume || muted != lastKnownMuted else { return }
    lastKnownVolume = volume
    lastKnownMuted = muted
    fire(volume: volume, muted: muted, defaultDeviceChanged: false)
}
```

## Rejected

- #15 NativeCaptureCoordinator.swift:1213 rebuildIfExclusionObjectsChanged(): The snapshot and re-resolve leave out castRenderPID, but lastExcludedObjects comes from resolveExcludedProcessObjectIDs(), which includes it. So setCastSink with a new (non-self) render pid never triggers a rebuild. Once any rebuild includes the cast objects, every later membership or relaunch diff sees newObjects != lastExcludedObjects and rebuilds again (an endless stream of rebuilds).
  - Rejected twice. No real caller can trigger it. The code does match the claim: rebuildIfExclusionObjectsChanged (NativeCaptureCoordinator.swift:1212) leaves castRenderPID out of its snapshot and re-resolve, while resolveExcludedProcessObjectIDs (line 1112) adds it. But every caller passes getpid() or nil. Cast is set at NativeBackend+Bluetooth.swift:597/614, Bluetooth at line 711 and synced-local at NativeBackend+Metering.swift:109. resolveExcludedObjectIDsLoggingAttribution always adds getpid()'s objects too (line 1163), looked up fresh on each call. So the cast pid's objects are already in both sets on both paths, and the comparison never drifts because of the cast pid. The Seams protocol has no other conforming caller that passes a different pid. A helper pid other than getpid() only exists in the hypothetical, and another input I tried (sink set to nil, then the pid set back to getpid()) also leaves the two sets equal. It is a latent inconsistency, not a reachable bug.
- #31 PerAppCaptureCoordinator.swift:336 start(bundleID:): A start() that arrives while the slot is in .stopping is treated as 'already in flight' and dropped. stop then deletes the slot, so the requested start never happens.
  - Rejected twice. The coordinator does behave as claimed. start() returns false while the slot is in .stopping, and stop's second queue.sync then removes the slot. But no real caller loses a start it still wanted.

1. The plan is a diff of route-set unions. captureToStart is newUnion minus previousUnion, and captureToStop is previousUnion minus newUnion. Moving an app to a different device keeps it in the union, so a re-route never stops it.
2. A de-route followed by a quick re-route sends stop and then start through the serial captureControlQueue, so stop finishes before start runs.
3. The callers that can overlap a stop from another thread are handleAppLaunched on main, the retry timer on a global queue, and the resume listener. Each one only meets a bundle that is being de-routed (a re-route start is queued behind that stop), orphaned, or whose app just quit (start would fail, and handleAppLaunched restarts it later).

The port in /tmp/hunt/p31b/port.py shows both points: with the real caller order the final state is capturing, and only a hand-made direct overlap drops the start.

Side observation, a different bug: the orphan stop is dispatched to captureControlQueue after the orphan check. If a re-route's start is queued on that queue in between, the start runs first as a no-op and the late orphan stop then tears down a capture the app now wants.
- #33 LocalPlaybackEngine.swift:706 removeApp / stop: Engine stop is gated on the engineRunning flag, not engine.isRunning; reestablishGraphOnGraphQueue's replay-failure path sets the flag false after engine.start() succeeded, so the last removeApp/stop never stops the running engine
  - Rejected twice. I agree with the earlier rejection after checking it myself. I wrote no test, because a port that fails would have to model play() raising while the engine keeps running, and that contradicts what makes play() raise. The snapshot in reestablishGraphOnGraphQueue is taken in the same graphQueue item. Every node in it is attached and was just connected. addApp, removeApp and stop are serialized on that queue. So play() can only raise because the engine is not running, meaning a config change stopped it after start(). Then skipping engine.stop() changes nothing. I also tried the case where a second config change follows. That stop posts a new notification. Its debounced handler either restarts the engine, setting the flag from engine.isRunning, or, if removeApp already emptied the nodes, sets the flag false and starts nothing. In every order, the engine is stopped whenever the flag is false. The case the code comment guesses at, play() raising while the engine stays running, does not happen with real AVAudioEngine.

## Not checked (confidence below 3)

- [2] NativeBackend.swift:5703 setSpeakerVolume: The loop-breaking echo guard assumes the wire level is linear in the stored level (`level*100` compared with stored*gain). For an AirPlay 1 receiver the pushed value is engineVolumeAP1 (a curve), so a reflected echo of our own write reads as a knob turn: it is stored as the new level and pushed again through the curve, and the level ratchets toward 100. (reader)
- [2] NativeBackend.swift:6056 issueVolumePush: When the volume generation has moved on (stop() ran while the push was in flight), the completion closure is never called (and neither is a queued pending push's). Callers that wait on the completion, such as the audition preparation hold, wait forever. (reader)
- [2] NativeBackend.swift:3088 setMuted / engineVolume(forID:uiVolume:): For AirPlay 2 receivers, mute and zero gain (Main, Group or the device fader at 0) send engine value 0.0. The file's own comments say 0.0 is -30 dB, 'the quietest non-muted level'. Only AP1 gets the -1.0 (-144 dB) true-mute sentinel, so a muted or zeroed AP2 speaker still plays faintly. (reviewer)
- [2] NativeCaptureCoordinator.swift:1916 pumpLeveledFallbackIfDue(): The leveled fallback clock is a third producer that can run deliver() at the same time as handleBuffer. When lastTapDeliveryNanos==0 (just after start or stop) or the tap wakes from idle, both threads touch the non-thread-safe streaming resamplers, PCMDelayLine.exchange, feedGap.noteDelivered and the sink writes at once. (reader)
- [2] NativeCaptureCoordinator.swift:2531 recreateTap(cause:): An ABA race on .creatingTap. If stop() and then start() run while recreateTap is off-lock, recreateTap's commit or catch sees start()'s .creatingTap and takes it over. A failing recreate sets .failed and makes start() orphan the tap it successfully built. (reader)
- [2] NativeCaptureCoordinator.swift:706 start(): A start() that arrives while stop() is tearing down off-lock (state .stopping) is silently dropped. The claim only proceeds from .idle/.failed, so the coordinator ends .idle even though start() was the last call. The claim also calls startLeveledClockLocked() unconditionally, so the 100 Hz fallback timer stays armed in .idle with no stop() to cancel it. (reviewer)
- [2] NativeBackend+Bluetooth.swift:2897 playCompanionAlignmentDemo / endCompanionDemo: The demo's 2 s and 4 s timers are keyed only by device id. A demo that is cancelled and restarted for the same speaker within 4 s gets cut short by the old 4 s timer, and its 'before' leg is overwritten early by the old 2 s push. (reader)
- [2] NativeBackend+Bluetooth.swift:921 applyBTSnapshots (unseen-device loop): A BT device that disappears from the list entirely (unpaired) is marked unavailable without the rest of markBTDeviceLostLocked: its btConnectingDeadlines entry stays, its connection state is not set to .off, and the speaker-timing disconnect is the only cleanup. (reader)
- [2] NativeBackend+Bluetooth.swift:74 reevaluateBTHardwareControlLocked / handleBTSinkDead: If a uid is already in btHardwareControlledUIDs, the function returns early, so the device-side volume watch stays bound to the old AudioObjectID. handleBTSinkDead's rebuild on a fresh object id (UID still resolves) never re-evaluates, so the speaker's own volume buttons stop being reflected. (reader)
- [2] NativeBackend+Bluetooth.swift:295 updateBTRoomTermLocked: Because of max(btRoomTermMs, candidate), the room term never falls while it stays above the start buffer. Deselecting the slow speaker, or resetting its latency, leaves every output delayed by a speaker that is no longer in the room. (reader)
- [2] NativeBackend+Bluetooth.swift:1821 btStoredAlignmentOffsetMs(forDevice:): The store answer that the replace/keep decision compares a measured LATENCY against is `latency ?? trim`. It returns the raw trim for a trim-only speaker, but a trim stands in for a latency with the opposite sign (delay = ref - latency + trim; line 200 counts a negative trim as latency). For a latency+trim speaker it ignores the trim altogether. (reviewer)
- [2] NativeBackend+Bluetooth.swift:894 applyBTSnapshots (new-device branch): A BT device that first enters `known` through a snapshot, already connected and already in expectedSelected (for example a selection restored before the first enumeration), never gets beginBTConnectingLocked or desiredAvailabilityMoved. The setOutputSet path (Tone.swift:516/530) also filters ids by known[id]?.isBluetooth, so an id that was unknown at selection time never entered btSelectedUIDs. Nothing re-runs the BT sink decision when it appears. (reviewer)
- [2] NativeBackend+PerAppRouting.swift:1205 performRebindRecovery (verifyFirst arm): The verify-first settle reports success with zero engine ops when the engine has no live session at all (live == nil) for a device that is in `added`, so a whole-system device with no session is never re-added. (reader)
- [2] NativeBackend+PerAppRouting.swift:2192 handleBindFailure: handleBindFailure does not check that the failed op's stream is still the device's current binding. When a bind queued for an older topology fails, it clears the newer topology's streamBindings entry (with clearBinding) and its routedAppNames/.routedApps. The next queued .rebind then succeeds, but reportPerAppConnectionState writes nothing because streamBindings is nil. (reviewer)
- [2] BTSyncedSink.swift:1559 BTDeviceSink.catchUpToTargetLocked / renderInterleaved: If capture stops after the anchor (the Mac goes silent, so no enqueue), the gate still opens at the target and the ring runs dry. Once audio resumes, the plain FIFO plays each frame as soon as it arrives, about the capture lag after capture instead of at pts + D. The pull realign sees no deficit, so the device plays roughly D early until something re-anchors. (reader)
- [2] BTSyncedSink.swift:427 BTDelayLine.shift / BTFrameRing.seek: shift peeks crossfadeFrames, which frees room, and then rewinds. The producer can refill the freed slots in between, so the rewind clamps short and the peeked frames are lost. More generally, a backward seek can move the read pointer into slots the producer is writing to under a stale readCounter it already checked. (reader)
- [2] BTSyncedSink.swift:1315 BTDeviceSink.applyTrimDelta: When released, sessionDelayNanos books the full backward (positive-trim) move. Only the forward direction is clamped and flagged, but ring.seek clamps a backward move at capacity - used. A clamped backward seek is never recorded in trimClampedSinceAnchor, so a later carry and reanchorIfTrimClamped work from a delay the ring does not hold. (reader)
- [2] BTSyncedSink.swift:1305 BTDeviceSink.applyTrimDelta: A pre-release trim recomputes the delay from the provider, which discards a carried config_change delay. The carry exists so that a lineup change keeps the alignment the user set by ear. (reader)
- [2] BTSyncedSink.swift:1288 BTSyncedSink.setTrimMs / BTDeviceSink.applyTrimDelta: Each trim delta is rounded to whole frames on its own, while trimMsByUID stores the exact sum. A drag of many small steps therefore drifts the ring away from the stored trim. Steps under half a frame are lost entirely, and steps just over half a frame are applied double. Nothing flags the gap (frames == requestedFrames, so trimClampedSinceAnchor stays false), and a later carry or re-anchor jumps to a different delay. (reviewer)
- [2] BTSyncedSink.swift:2118 BTSyncedSink.enqueue(sweepFrames:sweepFreeFrames:frameCount:pts:ownerUID:): The sweep fan-out feeds every sink in the table. It does not skip perAppClaimedUIDs the way the whole-system enqueue does, so during a phone-driven sync run a speaker already fed by per-app routing also gets the whole-system mix. That double-feeds its ring. (reviewer)
- [2] PerAppCaptureCoordinator.swift:295 deinit: deinit calls membershipQueue.sync (and queue.sync). If the last strong reference is released on that same queue, this is a dispatch_sync onto the current queue, which deadlocks or crashes. (reader)
- [2] PerAppCaptureCoordinator.swift:1383 startIOProc IOProc block: In the non-interleaved path, an empty or null channel buffer is skipped with continue. The remaining channels shift down an index and the channel count shrinks, so a later channel is delivered as the wrong one. (reader)
- [2] PerAppCaptureCoordinator.swift:935 PerAppCaptureError.isRetryable / handleProcessListChanged: A slot refused by the TCC gate (.tapCreationFailed(notAuthorizedReason)) counts as retryable. So the system-wide process-list listener runs start() on it again after every unrelated process-list change on the machine, and each retry repeats the gate check and logs. (reviewer)
- [2] PerAppCaptureCoordinator.swift:1386 CoreAudioProcessTap.startIOProc IOProc block: When mBytesPerFrame is 0, the two layouts compute frameCount differently. Non-interleaved delivers a buffer with data but frameCount 0. Interleaved uses max(1, bytesPerFrame), so frameCount equals the byte count, 4-8x too many frames. (reviewer)
- [2] LocalPlaybackEngine.swift:468 handleConfigurationChangeOnGraphQueue: The debounced handler assumes the engine already stopped, but it runs 300 ms after the notification. If addApp's own setDeviceID raised the notification and the engine has since started, the handler flips engineRunning false, calls setDeviceID on a running engine, and reconnects live players without engine.stop(). That can trigger another config change and loop. (reader)
- [2] LocalPlaybackEngine.swift:935 handleDefaultOutputChange: configuredTargetDevice is committed before the async repoint runs. If setDeviceID then fails, or the engine was briefly not running (a config-change handler mid-flight), later notifications for the same target are skipped and the engine stays on the old device. (reader)
- [2] LocalPlaybackEngine.swift:613 addApp: If AVAudioConverter(from:to:) returns nil for formats that differ, converter is nil and treated as 'identical'. receive then schedules source-format (e.g. interleaved) buffers on a player connected with the deinterleaved format, scheduleBuffer raises, and every buffer is dropped. (reader)
- [2] LocalPlaybackEngine.swift:816 avFormat(from:): Integer taps with 8 or 24 bits, and 16-bit float taps, fall to .pcmFormatFloat32. Their raw bytes are then copied as Float32, so the output is noise or garbage, and rmsOfFloat32 metering (line 747) is also wrong for any non-Float32 tap. (reader)
- [2] LocalPlaybackEngine.swift:732 receive / reestablishGraphOnGraphQueue: After AVAudioEngine stops itself on a config change, engineRunning stays true for the whole 300 ms debounce, so receive keeps scheduling buffers into the stopped players. Recovery calls play() without first calling player.stop()/reset, so that backlog plays first and adds at least 300 ms of latency to the live stream for good. Every later config change adds more. The repoint path has the same gap for its own stop window. (reviewer)
- [2] LocalPlaybackEngine.swift:470 handleConfigurationChangeOnGraphQueue: When the snapshot is empty, the handler sets engineRunning=false without calling engine.stop(). If the engine is in fact still running (a spurious or late notification after an explicit start(), e.g. one raised by start's own setDeviceID), the flag desyncs. The engine is then never stopped, and the next start re-runs configureOutput/setDeviceID on a running engine. (reviewer)
- [2] LocalPlaybackEngine.swift:549 stop: stop() resets outputSuppressed to false and sets mainMixer outputVolume to 1, dropping a suppression the Bluetooth wizard or companion audition asked for. A later start/addApp then plays at full outputGain while the backend still believes local output is suppressed. (reviewer)
- [2] NativeDiscovery.swift:938 scheduleRecreate / makeBrowser: When a failed NWBrowser is recreated, its results are dropped with no .removed. Devices that left during the outage are never reported removed, and their resultTXT and known entries stay (reader)
- [2] NativeDiscovery.swift:374 stop: stop() clears known asynchronously, while probe .ready blocks already queued on the browser queue can still call onResolve, so the device comes back and .appeared fires after stop() (reader)
- [2] NativeDiscovery.swift:795 descriptor(from:): When the deviceid TXT is present but cannot be parsed, identity falls back to the name-derived id, but descriptor() injects the derived id only when deviceid is absent. The bad value stays, parsedID is nil, and updateDiscovery throws (reader)
- [2] NativeDiscovery.swift:741 deriveIDFromInstanceName: An instance name with no '@' that is exactly 12 hex characters gets an id invented from it, although the docstring says the function returns nil unless 12 hex digits come before an '@'. (reviewer)
- [2] CompanionServer.swift:804 dropClient(clientID:) / resolveApproval: dropClient's refuse() leaves the revoked awaiting connection in `awaiting` (only isClosing set), so an .approved verdict arriving before the async cancel lands promotes the revoked phone into `clients` (counted, welcomed, command-eligible) until the 250 ms backstop (reader)
- [2] CompanionServer.swift:973 handle(_:from:) hello branch: A hello refused with goodbye (protoMismatch/invalidClientKey/authFailed/serverFull) leaves the client in `pending` until the goodbye send completes; a second hello already queued in the receive loop is re-evaluated and can move the doomed connection into `awaiting` and raise an approval prompt, which is then dropped as abandoned when the first goodbye's completion cancels it (reader)
- [2] CompanionServer.swift:801 dropClient(clientID:) / handle(_:from:) .command branch / broadcastLocked: When a promoted phone is revoked, dropClient only calls refuse(), which sets isClosing. The client stays in `clients` until the goodbye send completes or the 250 ms backstop fires. During that window the .command guard (`clients[client.id] != nil`) still passes, so command frames from the revoked phone are still sent to onCommand and answered. broadcastLocked, sendAppIcons and sendCompanionToken also keep sending to it after its goodbye. None of these paths checks isClosing. This is the promoted-client version of the reader's awaiting-pool suspicion, which it does not cover. (reviewer)
- [2] NativeBackend+Tone.swift:461 setOutputSet: For an id that vanished from `known`, the code clears desiredOn but never releases wholeSystemStreamByDevice. The selection loop skips unknown ids (`guard let device = self.known[id]`), so the release branch at 419-425 never runs. The stale home keeps counting in connectTargetStreamLocked's `owned` budget until stop(). (reader)
- [2] NativeBackend+Tone.swift:927 applyCastSessionState: The `.connecting` and `.playing` arms are guarded by expectedSelected.contains(id) so a late state from a session being torn down cannot write to a deselected row. The `.failed` arm has no such guard. A failure that arrives after a deselect (for example a timeout or dropped error from the session being torn down on captureControlQueue) overwrites the `.off` the deselect just wrote with `.failed`. (reviewer)
- [2] NativeBackend+Tone.swift:1000 pushCastFeedDelaysLocked: A receiver in refusedIDs is skipped without being told delay 0. If it had settled earlier with a remainder and got setCastRoomDelayMs(remainder), then re-settles and is refused for exceeding R_max, its old feed delay stays in the manager. The reader already reported the remainder<=0 skip at :1003; this is a different branch with the same missing reset. (reviewer)
- [2] CastOutputManager.swift:424 CastFanOut.write: When lock.try() fails, the fan-out drops the whole capture buffer for every ring without retrying and without counting it, so droppedBlocks and droppedLockBusy never show this loss. (reader)
- [2] CastOutputManager.swift:1064 teardown: teardownsInFlight is decremented only when the client's stopMedia or stopApplication completion runs. If that completion never fires (the channel is already closed after a drop, and onClose has been set to nil), the count stays up, and any later re-select of this id waits in connecting forever. (reader)
- [2] CastOutputManager.swift:1019 failure(for:stage:): Errors at stage .connect or .media other than timeout and connectionFailed fall through to .dropped. That includes a receiverError on GET_STATUS or LOAD and the default branch. The backend then shows these as 'Connection dropped' (droppedMidStream) for a stream that never started. For receiverError, the detail also carries the error type rather than the reason. (reviewer)
- [2] SyncedLocalSink.swift:615 enqueue: If stateLock.try() fails on the session's first chunk, that chunk is written to the ring without an anchor, and the next chunk's pts anchors ring sample 0. The error is a whole chunk (~10 ms), not the 'sub-ms' the comment claims, and it is permanent because the PI loop measures against the same wrong anchor. (reader)
- [2] SyncedLocalSink.swift:974 InterleavedFloatRing.applyPendingShift: The backward clamp uses the current head, but the producer may already be writing into [head, head+count) after checking free space against the old tail. A backward shift that fills the ring then lets the producer overwrite the exposed history and push head past tail, so used wraps to a small value and the ring is corrupted. (reader)
- [2] SyncedLocalSink.swift:481 applyUserOffsetDelta: The room check ignores shifts that were requested but not yet applied. Several deltas that each fit get summed and then silently clamped in applyPendingShift instead of triggering the reanchor, so the applied delay drifts away from the stored userOffsetMs. (reader)
- [2] SyncedLocalSink.swift:251 start (via lifecycle rebuild): An enqueue between clearSessionState and restartEngine anchors with a lazily measured delay. start() then overwrites cachedTotalDelayNanos with a fresh measurement while anchored, so movePreReleaseGate later recovers anchorPts = target - (a different delay), which is wrong. (reader)
- [2] NativeBackend+Cast.swift:137 setCastUserOffsetMs / clearCastUserOffset: The dict snapshot is taken under castOffsetLock, but save and push run outside it. Two concurrent calls can save an older snapshot last (losing the other entry on disk) or push out of order. (reader)
- [2] SyncedLocalSink.swift:617 enqueue: When cachedTotalDelayNanos is nil, the lazy anchor calls presentationDelayMs() and localOutputLatency() while holding stateLock on the tap thread. In production presentationDelayMs() does stateQueue.sync and localOutputLatency() is a Core Audio probe. movePreReleaseGate measures off the lock for exactly this reason, so here the tap thread blocks on stateQueue and the render thread's try() misses (silent cycles) for the whole measurement. (reviewer)
- [2] PTPHelperService.swift:583 PTPHelperReconciler.unregisterDrainAndReregister: If unregister() succeeds but the drain is never observed within about 10 polls x 0.5 s (5 s), or register() runs out of attempts, the helper stays unregistered. The self-heal wrapper still returns the original .timingPortsUnavailable as if nothing changed, but from then on every activate returns .needsApproval(.notRegistered). (reader)
- [2] PTPHelperService.swift:583 PTPHelperReconciler.unregisterDrainAndReregister: The drain loop waits only for status == .notRegistered. If the torn-down daemon reads .notFound after unregister (launchd no longer knows the label), the loop spends its whole budget and returns .drainNeverObserved even though the teardown did finish, so every heal and cycle fails. (reviewer)
- [2] PTPHelperService.swift:224 PTPHelperReleaser.release: release() sends only when PTPClockProbe.isReady() is true. A helper that is alive but stale (process running, holding 319/320, clock record not ready, which is the incident the self-heal doc describes) is never asked to exit, so the ports stay held for the whole idle window this releaser exists to cut short. (reviewer)
- [2] SystemOutputVolume.swift:583 stop() / device listener block: Device listener block has no isStarted guard (unlike the default-device block); a notification already dispatched to queue before stop() removed listeners runs afterwards with lastKnown reset to nil, so it always fires onExternalChange after stop (reader)
- [3] MockBackend.swift:243 stop(): outputObserver?.stop() runs synchronously on the caller thread while start()'s observer.start() is inside queue.async, so start(); stop() leaves the observer started (and stop-then-start ordering is inverted) (reader)
- [2] MockBackend.swift:179 init / setOutputSet: expectedSelected is seeded from fleet isSelected, so a scripted device that starts selected (sonos-move-2 in connection-demo) never runs its script on first setOutputSet; the 'slow connect' demo never plays (reader)
- [2] MockBackend.swift:233 stop(): stop() does not reset expectedSelected/attemptCounts/generations; after stop+start devices are re-added with fleet isSelected but expectedSelected keeps the pre-stop set, so setOutputSet edges are computed against stale state (reader)
- [3] MockBackend.swift:288 setOutputSet: setOutputSet skips ids not yet in `live` without recording them in expectedSelected. With staggered discovery (the default), any device that is requested before it is discovered is dropped for good, and a fleet-selected device that is removed before discovery still turns up selected. (reviewer)
- [2] SystemOutputVolume.swift:516 start / stop: start() and stop() use queue.sync on the same private queue that onExternalChange is invoked on, through fire() from the listener blocks. A handler that calls stop() or start() synchronously, for example to tear down when the device goes away, deadlocks. The class explicitly guards this hazard for the onExternalChange getter (callbackLock) and for deinit, but not for these two methods. (reviewer)
- [3] DefaultOutputDeviceMonitor.swift:351 handleNotification: Leading-edge delivery only covers a transition that is the FIRST notification of a window. A transition that lands inside an open window gets coalesced, and if the reading then returns to the tracked value, the trailing edge delivers nothing. The window can be opened by a same-value notification or by an earlier lone change. (reader)
- [2] MicProbeSession.swift:449 start (onStarted lane scheduling) / listeningTailSeconds: Both the lane-check tail and the final tail are capped at the same 10 s ceiling. For pipeline delay >= 8.5 s the gap shrinks below 1 s and reaches 0 at >= 9.5 s, so the engine lane's check runs at or after finish and its verdict is dropped. (reader)
- [2] MicProbeSession.swift:501 checkLane: The lane check searches with SyncProbe.samples(.probe(...)), but each lane plays SyncProbe.lane(...) (AlignmentTickInjector.stageProbe). If .probe renders the whole two-lane probe, it is longer than a single-lane window, so the guard window.count >= template.count fails and every lane reports not heard. (reader)
- [2] MicProbeSession.swift:419 start: A second start() while a run is active, or a start() after cancel()/finish, returns silently and never calls the completion it was given. (reader)
- [2] DefaultOutputDeviceMonitor.swift:355 handleNotification / stop: A notification block already queued when stop() removes the listeners, or a subscriber's onChange calling stop() reentrantly, still lets handleNotification deliver and run scheduleTrailingFanout. That re-arms a pending fan-out on a stopped monitor and can deliver to subscribers after stop. (reader)
- [3] MicProbeSession.swift:597 measure / finish (timeout path): When the probe never armed (onStarted never ran, so startedAt is nil), the 40 s timeout still calls finish(analyze: true). measure then searches the whole capture with ambientEnd=0 and searchFrom=0 instead of returning nil. (reviewer)
- [2] DefaultOutputDeviceMonitor.swift:199 start: start() re-reads the device and sets lastDelivered = latest but never delivers to subscribers. A device or rate change that happens between stop() and a later start() is never fanned out, because the HAL listeners were removed while it happened and start() treats the new reading as already delivered. (reviewer)
- [3] NativeBackend+AggregateOutput.swift:105 pointDefaultAtAggregate(current:): aggregateDefaultActive (and priorDefaultUID) are set true before the set-default write and never rolled back when the write is refused (or aggregate already default but never written), so the flag claims we won the takeover when we did not (reader)
- [2] NativeBackend+AggregateOutput.swift:261 verifyRestoreLanded(target:attempt:): Delayed read-back cannot tell 'restore did not land' from 'user re-selected Audiout in the 0.5 s window and the takeover landed'; it logs did_not_land and nils expectedDefaultWriteUID, clobbering the takeover's armed echo guard (reader)
- [2] NativeBackend+Metering.swift:53 applyMeteringGates / emitCombinedLevel: When levels start flowing again, only systemRMSDirty is cleared. latestSystemRMS keeps the value from before metering paused (it is reset only in stop()), and emitCombinedLevel, reached through emitAppLevel or reconcileLocalMeterTapLocked, replays that old system level as a floor on meterable devices. (reviewer)
- [2] NativeBackend+AggregateOutput.swift:306 reselectAggregateAsDefault: reselectAggregateAsDefault calls takeOverDefaultAndReflect without checking expectedSelected. A click on the 'Use Audiout' button after the last speaker was deselected (the popover still shows the button) takes the Mac's default for the aggregate while nothing is routing. Nothing hands the default back until the next reconcileAggregateDefault. (reviewer)
- [2] AudioCapturePermissionProbe.swift:287 functionalGrantProbe: When TCC preflight already reads .granted but the stored identity is missing or mismatched (for example the first run of a rebuild), the tone probe runs with no prompt to answer. If that grant is stale, the tap stays silent and preflight keeps saying granted, not denied, so the loop runs the full 60 s promptAnswerTimeout before it reports .denied. (reviewer)

## Lines read

- Slice 1: reader: NativeBackend.swift 1-6889 of 6889 (every line, sequential chunks); reviewer: NativeBackend.swift 1-6889 of 6889 (all lines). Also checked for context: DACPServer.swift 370-410, GroupController.swift 550-630.
- Slice 2: reader: NativeCaptureCoordinator.swift 1-4576 of 4576; reviewer: NativeCaptureCoordinator.swift 1-4576 of 4576 (all lines; also glanced at PCMDelayLine.swift setDelayFrames/exchange and TapRebuildLifecycle.swift TapRebuildCoalescer/TapReanchor to confirm clamping/semantics)
- Slice 3: reader: NativeBackend+Bluetooth.swift 1-3200 of 3200; reviewer: NativeBackend+Bluetooth.swift 1-3200 of 3200 (plus the helpers it calls, for context: NativeBackend.swift btSinkGain/masterGainFraction/stashedVolume sites, BTSpeakerTiming.swift decision/recordMeasurement, NativeCaptureCoordinator.swift setAlignTick, NativeBackend+Tone.swift refreshDriftTracking/beginBTConnecting callers)
- Slice 4: reader: NativeBackend+PerAppRouting.swift 1-2199 of 2199 (plus grep of NativeBackend.swift for releaseRebindConverging / sleep-path slot release, for context); reviewer: NativeBackend+PerAppRouting.swift 1-2199 of 2199 (plus OutputBackend.swift 186-203 and NativeBackend.swift 4425-4445 to check the streamHealth contract and the sleep release)
- Slice 5: reader: BTSyncedSink.swift 1-2191 of 2191; reviewer: BTSyncedSink.swift 1-2191 of 2191 (plus SyncCore.swift totalDelayNanos 55-70, BTClockStability.swift:56, NativeCaptureCoordinator.swift 2615-2642 for context)
- Slice 6: reader: PerAppCaptureCoordinator.swift 1-1658 of 1658 (also TapRebuildLifecycle.swift 83-107 for TapRebuildCoalescer); reviewer: PerAppCaptureCoordinator.swift 1-1658 of 1658 (all lines). For context I also read parts of AudioProcessResolver.swift (150-260, 430-470), TapRebuildLifecycle.swift (TapRebuildCoalescer, TapReanchor), and NativeCaptureCoordinator.swift (reconciledFormat, shouldRebuildForNominalRate, isRetryable, and the IOProc frameCount lines of the sibling tap).
- Slice 7: reader: LocalPlaybackEngine.swift 1-1243 of 1243; reviewer: LocalPlaybackEngine.swift 1-1243 of 1243 (plus callers NativeBackend+PerAppRouting.swift 505-530, 625-650; NativeCaptureCoordinator.rmsOfFloat32/TapFormat)
- Slice 8: reader: NativeDiscovery.swift 1-1236 of 1236; reviewer: NativeDiscovery.swift 1-1236 of 1236 (plus NativeBackend.swift 2170-2215, 5025-5055, 5745-5775 for caller context)
- Slice 9: reader: CompanionServer.swift 1-1183 of 1183; reviewer: CompanionServer.swift 1-1183 of 1183 (all). Also read CompanionApprovalStore.swift 215-360 and CompanionCoordinator.swift 485-515 to check how callers use it.
- Slice 10: reader: NativeBackend+Tone.swift 1-1130 of 1130 (also skimmed for context: CastRoomDelay.swift 100-175, CastOutputManager.swift 595-640, NativeBackend.swift 4151-4166, 3425-3447, 4430-4445); reviewer: NativeBackend+Tone.swift 1-1130 of 1130 (plus context reads: NativeBackend.swift 615-660, 3435-3455, 3555-3620, 4140-4175, 4515-4535, 6129-6142; NativeBackend+PerAppRouting.swift 55-92; NativeBackend+Bluetooth.swift 233-305)
- Slice 11: reader: CastOutputManager.swift 1-1125 of 1125; reviewer: CastOutputManager.swift 1-1125 of 1125 (also PCMDelayLine.swift 100-160 and NativeBackend+Tone.swift 900-935 to check callee and caller promises)
- Slice 12: reader: SyncedLocalSink.swift 1-1062 of 1062; NativeBackend+TestSupport.swift 1-133 of 133; NativeBackend+Cast.swift 1-170 of 170; reviewer: SyncedLocalSink.swift 1-1062 of 1062; NativeBackend+TestSupport.swift 1-133 of 133; NativeBackend+Cast.swift 1-170 of 170 (plus callers checked: SyncCore.swift totalDelayNanos/plan, BTTrimStore.swift quantise, NativeBackend.swift 6841-6890 and 4151-4177, OutputBackend.swift 800-830, NativeBackend+Bluetooth.swift 355-395 and 3140-3170)
- Slice 13: reader: PTPHelperService.swift 1-871 of 871; NativeBackend+Seams.swift 1-618 of 618; reviewer: PTPHelperService.swift 1-871 of 871; NativeBackend+Seams.swift 1-618 of 618 (plus NativeBackend.swift 1780-1800, 3325-3375 for callers)
- Slice 14: reader: MockBackend.swift 1-779 of 779; SystemOutputVolume.swift 1-718 of 718; reviewer: MockBackend.swift 1-779 of 779; SystemOutputVolume.swift 1-718 of 718
- Slice 15: reader: MicProbeSession.swift 1-690 of 690; DefaultOutputDeviceMonitor.swift 1-621 of 621; reviewer: MicProbeSession.swift 1-690 of 690; DefaultOutputDeviceMonitor.swift 1-621 of 621
- Slice 16: reader: AudioCapturePermissionProbe.swift 1-573 of 573; NativeBackend+AggregateOutput.swift 1-386 of 386; NativeBackend+Metering.swift 1-346 of 346 (also NativeBackend.swift 2325-2400 for listener context); reviewer: AudioCapturePermissionProbe.swift 1-573 of 573; NativeBackend+AggregateOutput.swift 1-386 of 386; NativeBackend+Metering.swift 1-346 of 346
