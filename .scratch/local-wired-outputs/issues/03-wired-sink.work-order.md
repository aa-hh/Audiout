Revised after team scoping: sink, ui, routing

## Work order — Ticket 03: a pinned synced sink per selected wired output

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cpi-consumption-analysis-2e6406` (branch `claude/handoff-local-wired-outputs-3b2085`). Depends on ticket 02 (on disk, uncommitted) AND amendment 02b (keep-while-used wired rows, `pruneUnusedWiredLocked()`, replug sets `isAvailable = true`). Start only from the commit that lands both. Paths below are relative to the worktree.

### Goal

Make a selected `.wired` row (headphone jack, USB, HDMI, built-in speakers when not the default) actually play, in time with everything else: each selected wired UID gets a pinned `AVAudioEngine` delay-line sink fed from the whole-system capture, delayed to the same reference the Bluetooth sinks use, with software gain (`Main × Group × Device`, mute = 0), per-device EQ, the reported Core Audio latency subtracted automatically, and the existing trim / measured-latency store on top. A selected wired row stays selected through an unplug (02b keeps the row greyed; the popover's deselect-on-loss edge stays Bluetooth-only, owner's call) and re-arms on replug. Design decision, final: reuse `BTSyncedSink` and `BTDeviceSink` unchanged as the manager and per-device sink for wired rows. They are keyed by UID, re-resolve UID → `AudioObjectID` on every apply, refuse aggregate/virtual transports, rebuild on rate change and sleep/wake, and already carry offset/trim/gain/EQ tables. The work is in `NativeBackend`: every site that decides "which UIDs the sink manager owns" widens from `isBluetooth` to `isBluetooth || isWired`, every site that identifies AirPlay by elimination excludes `isWired`, wired rows get a reported-latency seed, and wired rows become drift-correction targets. No new sink type, no composition term (wired-only or wired+Bluetooth = host-clock reference exactly as Bluetooth-only, decision 3), no rename.

### Verified facts

Ticket 02 (on disk): `Device.Kind.wired`, `Device.isWired`, `Device.wiredTransport`, `WiredOutputSnapshot(id:name:transport:)`, `WiredOutputEnumerating`; `NativeBackend.wiredEnumerator` `NativeBackend.swift:64`, init param `wiredEnumerator: WiredOutputEnumerating? = nil` `:1644`, wired in `start()` `:2079-2083` (`stateQueue.async { applyWiredSnapshots }`). `NativeBackend+Wired.swift:3` `extension NativeBackend`, `:14` `applyWiredSnapshots` on `stateQueue`; update branch `:16-19`, unplug loop `:31-40` (02b rewrites both: keep the row, `isAvailable = false`, `connectionState = .off` unless `.failed`, `commitKnownDevice`, then `pruneUnusedWiredLocked()`; replug sets `isAvailable = true` through `commitKnownDevice`). Test harness: `AudioutCore/Tests/AudioutCoreTests/NativeBackendWiredDevicesTests.swift` (`FakeWiredEnumerator` `:18-31`, fixtures `:149-150`; no spy sink, no capture double, so it cannot host `setOutputSet` tests).

Sink family (`AudioutCore/Sources/AudioutCore/`):
- `BTSyncedSink.swift:1-11` licence-clean header. `BTGroupComposition` `:22-43` (`usesPresentationReference = airPlayPresent || castPresent`). `BTReferenceTimeline.delayNanos` `:67-84` → `SyncTiming.totalDelayNanos(presentationDelayMs: roomDelay, localOutputLatencySeconds: offset/1000, safetyMarginMs: 0, userOffsetMs: trim)`, clamped ≥ 0.
- `BTDeviceSink` `:485`; `startLocked` `:758-814` refuses Aggregate/AutoAggregate/Virtual (`:760-766`), pins before start (`:771`), logs `bt_device_reported_latency` from `LocalOutputLatency.measure(deviceID:)` (`:772-780`) without using it in the delay. Rate listener + rebuild `:583-584`, `:844-859`.
- `BTSyncedSink` `:1334`: `DeviceSpec(deviceID:uid:)` `:1336-1341`; `setDevices` stops sinks whose UID is absent `:1427-1463`; `setOffsetMs(_:forDeviceUID:)` `:1525-1534` (stored per UID, applied live); `setTrimMs` `:1554`; `setGain(_:forDeviceUID:)` `:1611`; `setEQ` `:1626`; `renderingDeviceUIDs` `:1639`; tables survive disarm `:1378-1381`. `BTSyncedSinkControlling` `NativeBackend+Seams.swift:496-556`.
- `LocalOutputLatency.measure(deviceID:)` internal static, throws, `totalMilliseconds` (`LocalOutputLatency.swift:85-106`, `:48`). `CoreAudioAggregateDeviceControl.resolveDeviceID(forUID:)` returns `nil` for an untranslatable UID (`AggregateOutputDevice.swift:194-209`).
- `DriftCorrectionApplier.swift:176-178` refuses a correction unless `isBluetooth(uid)`, logging `not_bluetooth`.

`NativeBackend` sites:
- `NativeBackend.swift:613` `btDeviceIDForUID` test seam; `:621-635` `btSinkEnabled`, `btSelectedUIDs`, `btPerAppClaimedUIDs`, `btComposition`; `:876` `expectedSelected`; `:2808` `setVolume` BT arm, `:2872` `setMuted` BT arm (hardware branch gated by `btHardwareControlledUIDs.contains`); `:3065-3073` `btSinkGain(forUID:)`; `:3095` `btSinkGains(forUIDs:)`; `:3828-3832` `roomDelayLocked()` branches on `btSinkEnabled && !usesPresentationReference`; `:4404-4411` `desiredDeviceAudibleLocked` (`if isBluetooth { return isAvailable }`); `:4877` `commitKnownDevice`; `:5781` capture-gate intent = `isLocalDevice == false` (already admits wired).
- `NativeBackend+Tone.swift` (unchanged by 02): `:54-57` EQ push `if isBluetooth`; `:507` `btUIDs`; `:508` `wantBT`; `:518-528` connecting-hold loop; `:539-546` composition, `airPlayPresent` by elimination; `:553-562` first-mix intercept over `btUIDs`; `:572-610` commit + `applyBTSinkTransition` dispatch; `:999-1001` `airPlayPresent` for the pre-delay, same elimination; `:1029-1037` Bluetooth reconnect → `beginBTConnectingLocked` + `reapplyBTSinkLocked`.
- `NativeBackend+Bluetooth.swift` (unchanged by 02): `:178-182` `btOnlyReferenceMs`; `:189-207` `updateBTReferenceBufferLocked`; `:219-222` `btArmingLocked`; `:230-242` `reapplyBTSinkLocked`; `:402-471` `applyBTSinkTransition` (trims `:427-429`, stored latencies `:433-435`, gains `:446-448`, EQ `:452-454`, specs `:459-462`); `:525-530` `beginBTConnectingLocked` guard `isBluetooth`; `:568-593` render poll → `.connected`; `:653-656`, `:733`, `:747-750` the `desiredAvailabilityMoved` pattern (`reconcileSilenceWatchdog(); reapplyBTSinkLocked()`); `:1067-1070` `DriftCorrectionApplier` `isBluetooth` closure; `:1176-1194` `refreshDriftTrackingLocked` (baselines from `btSelectedUIDs` with measured latency; anchor loop `:1190` `!isBluetooth, !isCast, !isLocalDevice`); `:1285-1311` `setBTSyncTrim`, `:1321-1342` `resetBTAlignment` (zeroes offset + trim on the sink), `:2464` `btMeasuredLatencyMs` — no kind guards; `:1399` wizard arm gate `Set(self.btSelectedUIDs)`; `:1536-1540` `referenceIsBluetooth = known[referenceID]?.isBluetooth == true`.
- `NativeBackend+Metering.swift:157-161` `isMeterable`. `NativeBackend+PerAppRouting.swift:1751-1762` calls `applyBTSinkTransition` with the reference in force (filters `:30`, `:1747`, `:1781` are ticket 05's).
- `NativeCaptureCoordinator.swift:1909-1913`, `:1987-2004`: one Bluetooth feed; during a wizard run it carries the keep-alive bed and bright tick (`btPCM`).
- Harness for `setOutputSet` + spy sink: `AudioutCore/Tests/AudioutCoreTests/NativeBackendBTSelectionTests.swift` `makeBackend` `:390-421`, `SpyBTSink` `:177-236` (records `setPerAppClaimedUIDs` into `perAppClaimedUIDCalls` `:198-199`, `:238-239`), first test `:436-453`.

### Steps

Decisions, final: reuse the Bluetooth manager under its name; no `wiredPresent` term; a wired UID's offset is the stored measured latency when one exists, else the reported latency read at each arm (not re-read on a rate-change rebuild — a few ms, below the ~4 ms the ear resolves per `BTTrimStore.swift:15-17`; `razor:` comment naming the upgrade: re-read in `BTDeviceSink.startLocked`); wired rows share the Bluetooth feed and hear the bed + bright tick during a wizard run (`razor:` comment at `NativeCaptureCoordinator.swift:1909`, upgrade: a bed-free UID set through `fanOutSplitToBT`); no `wired_sink_*` telemetry; the first-mix intercept stays Bluetooth-only; wired rows ARE drift-correction targets but never drift anchors; the wizard arm gate waits only on available UIDs.

1. **Write the tests first, run them, paste the failing output.** New `AudioutCore/Tests/AudioutCoreTests/NativeBackendWiredSinkTests.swift`, `@Suite final class NativeBackendWiredSinkTests: IsolatedSuite`. Copy the doubles and `makeBackend` from `NativeBackendBTSelectionTests.swift:20-421` intact (including `SpyBTSink`'s `setPerAppClaimedUIDs` recording — ticket 05 adds its test here) and `FakeWiredEnumerator` from `NativeBackendWiredDevicesTests.swift:18-31`; `makeBackend` passes `wiredEnumerator:` and no `btEnumerator`. Extend the spy with `setOffsetMs(_:forDeviceUID:)` recording `(ms, uid)` into `offsets`. `btDeviceIDForUID` reads a locked `[String: AudioObjectID]` box the test edits. Fixture: `WiredOutputSnapshot(id: "BuiltInHeadphoneOutputDevice", name: "External Headphones", transport: .headphoneJack)`. Tests:
   - `selectedWiredRowArmsTheSinkManagerByUID` — defect: a selected wired row never reaches the sink manager, so it plays nothing. Start, fire, `setOutputSet([jack.id])`, wait for `sink.calls.contains("start")`; expect `sink.deviceSets.last?.map(\.uid) == [jack.id]`, `sink.compositions.last == BTGroupComposition(airPlayPresent: false, macLocalPresent: false)` (a wired row is not AirPlay), `engine.addedIDs.isEmpty`, row `connectionState == .connecting`; set `sink.renderingUIDs = [jack.id]`, wait for `.connected`.
   - `reportedLatencySeedsTheOffsetUnlessMeasured` — defect: a wired row scheduled at offset 0 plays late by its reported latency, and a wizard-measured chain latency would have the reported figure subtracted on top. `backend.wiredReportedLatencyMs = { _ in 9 }`; select; wait for the last offset for the uid == 9. Then `backend.btTrimLock.withLock { backend.btLatencyMsByUID[jack.id] = 600 }`, `setOutputSet([])`, `setOutputSet([jack.id])`; wait for the last offset == 600 and expect no 9 recorded after it.
   - `unpluggedWiredRowLeavesTheSinkSetAndReplugRearmsIt` — defect: after an unplug the manager keeps an engine pinned to an `AudioObjectID` the HAL reuses for the next device (`issues/01-hardware-verification.md:89-93`), and a replugged selected row stays silent. Select, wait for the device set; remove the uid from the box; fire `[]`; wait for `sink.deviceSets.last == []`; expect the row still present with `isAvailable == false` and `backend.devices` still containing it (do not wait for `.deviceRemoved`); put the uid back in the box; fire `[jack]`; wait for `sink.deviceSets.last?.map(\.uid) == [jack.id]` and `connectionState == .connecting`.
   - Run `bash scripts/run-tests.sh --filter NativeBackendWiredSinkTests` (timeout 600000); paste the compile failure (`wiredReportedLatencyMs` does not exist yet).

2. **`NativeBackend.swift`** — beside `btDeviceIDForUID` (`:613`) add `var wiredReportedLatencyMs: (@Sendable (AudioObjectID) -> Int?)?`, doc: test seam; `nil` (production) means `LocalOutputLatency.measure(deviceID:)`'s `totalMilliseconds` rounded, `nil` on throw. Beside `btSinkGains(forUIDs:)` (`:3095`) add `func wiredSinkUIDs(forUIDs uids: [String]) -> Set<String>` on `stateQueue`: the subset whose `known[$0]?.isWired == true`. Widen `:2808`, `:2872`, `:4406` to `isBluetooth == true || isWired == true`.

3. **`NativeBackend+Bluetooth.swift`** —
   - `applyBTSinkTransition` (`:402-406`): add `reportedLatencyUIDs: Set<String> = []` after `eqs:`. In the enable branch build the specs (`:459-462`) into a local BEFORE `setDevices`; for each spec whose uid is in `reportedLatencyUIDs` and absent from `latencies` (`:426`), read `wiredReportedLatencyMs?(deviceID)` or the production fallback and `sink.setOffsetMs(ms, forDeviceUID:)`; then `sink.setDevices(specs)`. Doc: measured wins, reported is the default, so a measured chain is never double-subtracted.
   - `reapplyBTSinkLocked` (`:230-242`): pass `reportedLatencyUIDs: wiredSinkUIDs(forUIDs: uids)`.
   - `beginBTConnectingLocked` (`:526`): guard `isBluetooth == true || isWired == true`.
   - `:1067-1070` `DriftCorrectionApplier` closure: `isBluetooth == true || isWired == true` (owner's call: wired rows are drift targets; the sink is the same delay line and `writeBTDriftLatency` is uid-keyed).
   - `:1190` anchor loop: add `!device.isWired` (a wired row is never an anchor).
   - `:1399` arm gate: `Set(self.btSelectedUIDs.filter { self.known[$0]?.isAvailable == true })`, comment: an unplugged-but-selected wired row is now an ordinary state and must not cost every run the `wizardArmCeilingSeconds` of bed.
   - `:1539` `referenceIsBluetooth`: `isBluetooth == true || isWired == true` (a wired reference renders inside the manager and needs the sweep-free feed).
   - `resetBTAlignment` (`:1335-1341`): inside the `stateQueue.async` block, after enqueuing the zeroing hop, `if known[id]?.isWired == true { reapplyBTSinkLocked() }` so the reported seed returns (zero lands first, seed after; both enqueued from `stateQueue`).

4. **`NativeBackend+Tone.swift`** — `setOutputSet`: at `:507` keep `btUIDs` Bluetooth-only (the intercept at `:553-562` reads it) and add `let sinkUIDs = ids.filter { known[$0]?.isBluetooth == true || known[$0]?.isWired == true }.sorted()`; `:508` `wantBT = !sinkUIDs.isEmpty`; `:518-519` loop `where isBluetooth == true || isWired == true`; `:542` and `:1000` add `&& !$0.isWired`; `:576-580` compare/assign `sinkUIDs` to `btSelectedUIDs`; `:590-593` pass `reportedLatencyUIDs: self.wiredSinkUIDs(forUIDs: armedUIDs)`; `:54` widen the EQ push guard. First sentence of the `:498-506` comment: the partition now covers `.bluetooth` and `.wired` ids.

5. **`NativeBackend+PerAppRouting.swift:1760-1762`** — pass `reportedLatencyUIDs: self.wiredSinkUIDs(forUIDs: armedUIDs)` (computed on `stateQueue` beside `gains`/`eqs`). No filter change (ticket 05).

6. **`NativeBackend+Metering.swift:158`** — `if device.isBluetooth || device.isWired { return device.connectionState == .connected }`; add "and wired" to the doc at `:141-147`.

7. **`NativeBackend+Wired.swift` `applyWiredSnapshots`** (as amended by 02b) — key on the availability edge, mirroring `NativeBackend+Bluetooth.swift:653-656`, `:733`, `:747-750`: a local `desiredAvailabilityMoved`; in the unplug loop set it when the row goes available→unavailable and `expectedSelected.contains(id) || btPerAppClaimedUIDs.contains(id)`; in the update branch set it when the row goes unavailable→available under the same test, and if 02b's update branch does not already call `beginBTConnectingLocked(id)` on that edge for a row in `expectedSelected`, add it there. After both loops and BEFORE `pruneUnusedWiredLocked()`: `if desiredAvailabilityMoved { reconcileSilenceWatchdog(); reapplyBTSinkLocked() }`. The unplugged UID no longer resolves, so the manager drops its sink; a replug re-enters it. Doc comment: name both halves.

8. **`.scratch/local-wired-outputs/issues/03-wired-sink.md`** line 3 → `Status: ready-for-human (built 2026-09-26; live check owed)`; replace the "Decide:" bullet's first sentence with the decision (reuse, no rename); delete the Telemetry bullet.

9. Run Verification.

### Interface for other tickets

Everything is keyed by `Device.id` (the Core Audio UID); nothing new is exported.

- **Arming.** Any wired id in the `setOutputSet` ids or in `btPerAppClaimedUIDs` gets a sink while it resolves. Ticket 05: widen `NativeBackend+PerAppRouting.swift:30`, `:1747`, `:1781` to `isBluetooth || isWired`; its test `routeToAWiredRowClaimsItForPerAppDelivery` goes in `NativeBackendWiredSinkTests.swift`, whose spy records `perAppClaimedUIDCalls`.
- **Trim / measured latency / reset / ranges / wizard (ticket 04):** `setBTSyncTrim`, `btSyncTrim`, `btHasSyncTrim`, `resetBTAlignment`, `btUsableTrimRangeMs`, `btMeasuredLatencyMs`, `btWizardLatencyRangeMs`, `setBTWizardLatencyPreview`/`endBTWizardLatencyPreview`, `setBTWizardTrimPreview`/`endBTWizardTrimPreview`, `setBTWizardTickActive`, `stageBTMicProbe`, `startCompanionAlignmentProbe` all accept a wired id unchanged; store file stays `bt-sync-trims.json`. A measured latency written for a wired id replaces its reported seed; reset restores the seed. Wired hears the bright tick during a run, so 04's `targetIsBluetooth: isBluetooth || isWired` is right.
- **Volume / mute / EQ:** `setVolume`, `setMuted`, `setEQ` on a wired id compose software gain / bake EQ. `btHardwareVolumeCapable` stays `nil` for wired.
- **Row state:** selected wired row `.connecting` → `.connected` when its delay gate opens; `isMeterable` follows `.connected`; an unplugged row reads `isAvailable == false`, `connectionState == .off`, stays selected, re-arms on replug. The companion snapshot reads the same fields.
- **Reference:** wired-only or wired+BT = host-clock reference (`btReferenceBufferMs`, floor 500 ms); AirPlay/Cast present = presentation reference. "This Mac" delays to the same `roomDelayLocked()` automatically.
- **Popover filters** at `PopoverController.swift:2145` and `PopoverController+BTWizard.swift:443-445` (section + reference ordering) are ticket 04's; `PopoverController.swift:924` stays Bluetooth-only.

### Out of scope — do not touch

- `BTSyncedSink.swift`, `SyncCore.swift`, `SyncedLocalSink.swift`, `LocalOutputLatency.swift`, `BTTrimStore.swift`, `DriftCorrectionApplier.swift`, `NativeCaptureCoordinator.swift` (one `razor:` comment only), `BTGroupComposition` — no fields, no rename, no sibling sink.
- The keep-while-used rule, `wiredRowIsUsedLocked`, `pruneUnusedWiredLocked()`, the replug `isAvailable = true`, `AppDelegate.swift:2753` — amendment 02b.
- `NativeBackend+PerAppRouting.swift` filters (`:30`, `:1747`, `:1781`), `AppRouteTargetEligibility`, `GroupStore` — ticket 05. `CompanionSnapshotBuilder`, `AudioutPopoverUI`, drawer, wizard UI — ticket 04.
- `WiredOutputEnumerator.swift`, `Device.swift`, `OutputBackend.swift` fixtures — ticket 02; `AggregateOutputDevice.builtInOutputDeviceUID`, `LocalPlaybackEngine` — ticket 06.
- No wired hardware-volume path, no analytics events, no `wired_sink_*` telemetry, no AGENTS.md line, no rename of `bt*` members, no cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims. Do not commit or push.

### Verification

Test seam: `NativeBackendWiredSinkTests.swift` (step 1; defects named there), run first and failing.

```
bash scripts/run-tests.sh --filter "NativeBackendWiredSinkTests|NativeBackendBTSelectionTests|NativeBackendBTAlignmentInterceptTests|NativeBackendSyncedLocalSelectionTests|NativeBackendBTHardwareVolumeTests|NativeBackendWiredDevicesTests"
```
→ all pass; `Test run with N tests` with N ≥ 3 + 38 + 48 + 19 + 10 + the wired-devices suite's count after 02b. A run listing 0 tests is a failure.

```
bash scripts/build.sh
```
→ exit 0.

Foreground, timeout 600000. On a timeout run `bash scripts/capacity.sh status` once, retry once, then stop and report `blocked on capacity` with that output.

### Execution plan

One track, all steps. Files: `NativeBackend.swift`, `NativeBackend+Bluetooth.swift`, `NativeBackend+Tone.swift`, `NativeBackend+PerAppRouting.swift` (one call site), `NativeBackend+Metering.swift`, `NativeBackend+Wired.swift`, `NativeCaptureCoordinator.swift` (comment), the new test file, the ticket file. Model: opus. Effort: medium — edits mirror cited code; the care points are the offset-seeding order in `applyBTSinkTransition`, the reset re-seed ordering, and step 7's placement relative to 02b's prune call. SERIAL after 02 + 02b land (consumes `Device.isWired`, `wiredEnumerator:`, the amended `applyWiredSnapshots`, `pruneUnusedWiredLocked`). Ticket 04 and 05 tracks may run in parallel with this one only if they avoid the files above; 05's `NativeBackend+PerAppRouting.swift` filter edits touch a file this track edits, so 05 runs after this merges. The branch currently holds ticket 02's uncommitted work.

### Executor rules (copy verbatim into the handoff prompt)
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.

### Cross-area questions

- [ticket-02b] The amended `applyWiredSnapshots`'s exact shape (where the unplug loop, update branch and `pruneUnusedWiredLocked()` call sit) and whether it already calls `beginBTConnectingLocked(id)` on the replug edge — step 7 edits inside it and adds the call only if absent (affects step 7).
- [ticket-05] Its `routeToAWiredRowClaimsItForPerAppDelivery` test lives in `NativeBackendWiredSinkTests.swift` after this track merges; the spy copied in step 1 must keep `perAppClaimedUIDCalls` (affects step 1).