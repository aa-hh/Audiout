# Core — model, routing brain, stores, licensing, companion, discovery — review

## Verdict
This area is in much better shape than its size suggests. There are no force unwraps, no `fatalError`, no `as!`, no TODO/FIXME and no empty `catch` in any of the 71 files, and the licensing and trial path is the strongest code here — every failure direction (no network, backwards clock, mid-flight key edit, trial-to-paid conversion) is reasoned about in the comments and handled in the code. The weaknesses are concentrated in two places. First, the network listeners are inconsistent with each other: `CompanionServer` bounds every pool and every deadline and explains why, while `DACPServer` accepts unlimited connections and `CastLiveAudioServer` serves the Mac's live system audio to any LAN peer that issues a GET, with no client check, no connection cap and no idle deadline. Second, `OwnToneBackend` and its client are ~1,500 source lines plus ~1,200 test lines driving an external server that `docs/SPEC.md` §3 says must be deleted and that is already gone from the repo. The single highest-impact change is bounding `CastLiveAudioServer` — a cap, an idle deadline, and a check that the peer is the receiver we handed the URL to — because that one is live system audio on the LAN today.

## Counts
BUG: 6 · SUBSTANCE: 11 · COSMETIC: 2 · files read: 22 / files in area: 71

## Findings

### 1. [BUG] `CastLiveAudioServer` serves the Mac's live system audio to any LAN peer, on any path, with no cap and no idle deadline
- Where: `AudioutCore/Sources/CastSender/CastLiveAudioServer.swift:122`, `:208-234`, `:169-180`; `AudioutCore/Sources/AudioutCore/CastOutputManager.swift:438`, `:652-655`
- Evidence: `serverBindsLoopbackOnly: Bool = false` (CastOutputManager.swift:438, production default); CastLiveAudioServer.swift:214-215 `case "GET", "HEAD": // Any path is served`. `accept(_:)` (:169) adds to `connections` with no count check and arms no deadline; `readRequest` only completes when data arrives.
- Why it matters: with `loopbackOnly` false the listener binds all interfaces, so anything on the network that finds the ephemeral port gets a continuous chunked WAV of whatever the Mac is playing. No path check, no URL secret. Unlimited idle connections exhaust file descriptors the AirPlay RTP, PTP and DACP paths also draw on.
- Fix: check the remote endpoint against the receiver's address before streaming (`streamHostOverride` sits beside the flag), and copy `DACPServer`'s idle `DispatchWorkItem` plus `CompanionServer`'s `pendingCap` pattern into `accept(_:)`.
- Confidence: high

### 2. [BUG] `DACPServer` accepts unlimited connections — the exact exhaustion `CompanionServer` guards against and names DACP in
- Where: `AudioutCore/Sources/AudioutCore/DACPServer.swift:196-229`; contrast `CompanionServer.swift:229-236`, `:530-535`
- Evidence: DACPServer.swift:196-198 `func accept(_ connection: NWConnection) { let key = ObjectIdentifier(connection); connections[key] = connection` — no cap. CompanionServer.swift:231-233 explains the opposite choice ("not exhausting this process's file descriptors (which AirPlay RTP, PTP, DACP and Bonjour also draw on)").
- Why it matters: the 30 s idle deadline bounds how long each socket lives but not how many exist at once.
- Fix: a `pendingCap`-style guard at the top of `accept(_:)`, matching `CompanionServer`.
- Confidence: high

### 3. [BUG] A DACP peer can drive a non-finite volume through the trust boundary
- Where: `DACPServer.swift:293-296`, `:347-351`, `:258-262`
- Evidence: `deviceVolumeDb` returns `Double(raw)` ("nan"/"inf" both parse); `level(fromDb:)` has `if db <= -30 { return 0 }; if db >= 0 { return 1 }; return (db + 30) / 30` — both comparisons false for NaN, NaN out.
- Why it matters: `onVolume?(token, .nan)` reaches the backend's volume write from an unauthenticated LAN request. `CompanionCommandDispatcher.swift:304` and `:311` guard `isFinite`; this path does not.
- Fix: `guard db.isFinite else { return 0 }` at the top of `level(fromDb:)`.
- Confidence: high

### 4. [BUG] An unanswered approval prompt is never withdrawn or freed, so a LAN peer cycling client IDs stacks alerts without limit
- Where: `CompanionApprovalStore.swift:158-169`, `:180`; `CompanionServer.swift:655-660`, `:844-848`
- Evidence: `pendingDeciders[clientID] = [decide]; presentPrompt?(clientName) { ... }` — `pendingDeciders` is emptied only in `resolvePrompt` (:180), which runs only when the user answers. `CompanionServer.removeClient` drops an awaiting connection with no callback ("never promoted: no disconnect signal", :659).
- Why it matters: a peer connects with a fresh UUID, gets prompted, disconnects, repeats — each round raises another NSAlert nothing withdraws and leaves a permanent closure. `awaitingCap` limits concurrency, not repetition.
- Fix: have `CompanionServer` signal approval timeout/disconnect back to the controller (`approvalWork` at :844 already knows); drop the `pendingDeciders` entry and withdraw the prompt.
- Confidence: high

### 5. [BUG] The companion approval file is the one store that does not quarantine a corrupt file
- Where: `CompanionApprovalStore.swift:67-73`, `:135`; contrast `AppRouteStore.swift:193-198`, `GroupStore.swift:138-142`, `RoutingStore.swift:84-88`, `DeviceEQStore.swift:49-53`, `DeviceIconStore.swift:46-50`, `HiddenSpeakersStore.swift:46-50`, `ExcludedAppsStore.swift:72-76`, `BTTrimStore.swift:218-222`, `BTHardwareVolumeStore.swift:100-102`
- Evidence: `let data = try Data(contentsOf: fileURL); let envelope = try decoder.decode(Envelope.self, from: data)` — no do/catch, no `StoreRecovery.quarantine`. The other nine stores do `catch { StoreRecovery.quarantine(fileURL); throw error }`.
- Why it matters: caller (:135) swallows into `[]`, every approved phone re-prompts, and the first new approval overwrites the evidence.
- Fix: same do/catch + quarantine as the others.
- Confidence: high

### 6. [BUG] A failed approval save is written to stderr instead of `StoreRecovery.noteWriteFailure`, so the user is never told
- Where: `CompanionApprovalStore.swift:195-203`
- Evidence: `catch { FileHandle.standardError.write(Data("[Audiout] companion approvals failed to save: \(error)\n".utf8)) }`. Thirteen other write sites use `StoreRecovery.noteWriteFailure(error)` (GroupController.swift:296, AppRoutingController.swift:62, ExcludedAppsController.swift:40, HiddenSpeakersController.swift:35, DeviceIcon.swift:155, eight in NativeBackend.swift).
- Fix: replace with `StoreRecovery.noteWriteFailure(error)`.
- Confidence: high

### 7. [SUBSTANCE] `OwnToneBackend` and its client are ~1,500 source + ~1,200 test lines driving a server the spec says to delete and that is no longer in the repo
- Where: `OwnToneBackend.swift` (1067), `OwnToneClient.swift` (268), `OwnToneWebSocketMonitor.swift` (128), `PlaybackController.swift` (49), `Tests/AudioutCoreTests/OwnToneBackendTests.swift` (842); selection arm at `OwnToneBackend.swift:796`, `:826`, `:884-897`
- Evidence: `docs/SPEC.md:115-122`: "OwnTone itself is spike scaffolding only. It never ships. … Decided 2026-07-13: the final product contains NO OwnTone references at all — naming included. The interim `OwnToneBackend` … and `dev/owntone/` are deleted when the native sender lands … and the `AIRPLAY_BACKEND=owntone` env value goes with it." `dev/owntone/` is already gone; `BackendKind.resolved` defaults to `.native`.
- Why it matters: reachable only via `AIRPLAY_BACKEND=owntone` against a server no longer present. ~15 comments in `NativeBackend.swift` cite it by file and line (`:17`, `:1176`, `:2964`, `:9682`, `:9939`, `:9978`, `:11030`).
- Fix: delete the three OwnTone files, `PlaybackController.swift`, the `.ownTone` case and `makeBackend` arm, and `OwnToneBackendTests.swift`; rewrite the NativeBackend comments to state the rule instead of the citation.
- Confidence: high

### 8. [SUBSTANCE] Seven security-relevant limits on `CompanionServer` are `public` and mutable, against the module's own convention
- Where: `CompanionServer.swift:201`, `:208`, `:217`, `:227`, `:239`, `:269`, `:276`
- Evidence: `public var test_maxClientsOverride: Int?` etc. Every other test seam in the module is internal (AlignmentTickInjector.swift:721-732, BTSyncedSink.swift:867, CastOutputManager.swift:253, LeveledAppInjector.swift:349, AirPlayHandoffWatcher.swift:242, and `test_clientNames()`/`test_awaitingCount()` at :943/:948 in this file).
- Fix: drop `public` from all seven.
- Confidence: high

### 9. [SUBSTANCE] A schema downgrade silently destroys the newer file on the next write
- Where: `AppRouteStore.swift:199`; same in `GroupStore.swift:144`, `RoutingStore.swift:89`, `DeviceEQStore.swift:54`, `DeviceIconStore.swift:51`, `HiddenSpeakersStore.swift:51`, `ExcludedAppsStore.swift:77`, `CompanionApprovalStore.swift:71`, `BTTrimStore.swift:223`
- Evidence: `/// A file from a newer schema is treated as missing rather than crashing an older build. guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }`
- Why it matters: caller falls back to empty; first mutation `save`s `.atomic` over the newer file. Newer build then older build = groups, routes, EQ, approvals gone, no quarantine copy.
- Fix: quarantine on the newer-schema branch, or refuse to save over a file whose stored schemaVersion exceeds current.
- Confidence: high

### 10. [SUBSTANCE] `GroupController` is 1,078 lines whose comments outweigh its code, including a git merge note
- Where: `GroupController.swift:185-206`, `:834-877`, `:70-91`
- Evidence: `// MERGE NOTE (2026-07-17, phase2b ← main): …`; :842-877 is 36 lines explaining four bugs in a deleted design; :70-91 is 22 lines of audit archaeology.
- Fix: cut to the one rule each states; leave history to git and AGENTS-HISTORY.md.
- Confidence: medium

### 11. [SUBSTANCE] `_ = routingStore` is a no-op statement guarding nothing
- Where: `GroupController.swift:206`
- Evidence: `routingStore` is a stored `let` used at :237 and :296. Delete the line.
- Confidence: high

### 12. [SUBSTANCE] Two "legacy shim" methods on `GroupController` have no callers
- Where: `GroupController.swift:496-502` — `isEnabled(_:)`, `setDeviceEnabled(_:_:)`. grep over Sources and Tests finds only unrelated `isEnabled` on NSSegmentedControl and BTHardwareVolumeStore.
- Fix: delete both and the MARK.
- Confidence: high

### 13. [SUBSTANCE] Two commands reply "applied" for targets that do not exist, unlike every neighbouring case
- Where: `CompanionCommandDispatcher.swift:234-236`, `:241-243` (`.setGroupMuted`, `.removeAppRoute` return `.ok` unconditionally; `GroupController.setGroupMuted` :1058-1061 and `AppRoutingController.removeRoute` :113-118 guard silently). Neighbours refuse: `applyUpdateGroup` :409-411, `applySetMainOut` :578-581, `deviceWriteRefusal` :516-518.
- Fix: guard on membership first, return the neighbours' refusals.
- Confidence: high

### 14. [SUBSTANCE] A cancelled buffer-apply task wedges `setStartBufferMs` for the process lifetime
- Where: `CompanionCommandDispatcher.swift:272-280` — `startBufferApplyInFlight = true; Task { await applyStartBuffer(ms); startBufferApplyInFlight = false }`.
- Fix: `defer { startBufferApplyInFlight = false }` inside the Task.
- Confidence: medium

### 15. [SUBSTANCE] 43 of 110 Core files carry no SPDX header, with only one documented exception
- Where: `GroupController.swift:1`, `Device.swift:1`, `OutputBackend.swift:1`, `NativeBackend.swift:1`, `ConnectionState.swift:1`, `MockBackend.swift:1`, `GroupStore.swift:1`, `NativeDiscovery.swift:1` and 35 others (38 in AudioutCore/ + 6 in CastSender/, the latter documented clean-room).
- Fix: add `// SPDX-License-Identifier: GPL-2.0-or-later` to the 37 non-clean-room files; note the clean-room set in the folder AGENTS.md beside the SyncCore rule.
- Confidence: high

### 16. [SUBSTANCE] A muted master fires one full repaint per member
- Where: `GroupController.swift:1050-1052`, `:1058-1061` — `for id in mainOutMemberIDs { setMuted(muted, for: id) }`, each firing `onStateDidChange?()` (:1034). `setMain` (:996) edge-gates for exactly this reason.
- Fix: mute members without announcing, fire once, like `AppRoutingController.clearRoutes(toDevices:)`.
- Confidence: medium

### 17. [SUBSTANCE] Unmuting a member the fleet has forgotten sets its volume to 0
- Where: `GroupController.swift:1073` — `let restored = state.priorVolume ?? device(id)?.volume ?? 0`. `MemberState` doc (:53-55) says "leave volume alone rather than guess."
- Fix: `guard let restored = state.priorVolume ?? device(id)?.volume else { return }`.
- Confidence: medium

### 18. [COSMETIC] `TrialClock.hasEnded` reads a bare server string, and a stale one outlives the trial it described
- Where: `TrialClock.swift:85` (`settings.licenseReason == "trial_expired"`); written at `LicenseValidator.swift:81`; cleared only when key set to nil (`AppSettings.swift:553-561`). Only `LicenseGateViewController.swift:153` reads it, for wording.
- Fix: clear `licenseReason` when `licenseKey` changes to a different non-nil value; name the string once in `LicenseCopy`.
- Confidence: high

### 19. [COSMETIC] `TrialReachability` never cancels its path monitor on deinit
- Where: `TrialReachability.swift:39`, `:53-74` — `NWPathMonitor` cancelled only in the `.stop` branch; no `deinit`.
- Fix: `deinit { monitor.cancel() }`.
- Confidence: high

## Also noted
- `CompanionServer.swift:677-685` — liveness timer created at first promotion, cleared only by `stop()`; ticks every 20 s over zero clients.
- `SetupModel.swift` — 1,340 lines, 52 functions, one class from :435 to end, eight protocols above it. Split the permission-probing seams (:234-421) into their own file.
- `CompanionCommandDispatcher.swift:338-343` — `activateLicenseKey` is a placeholder refusal with a `razor:` note; tracked ceiling, but it ships.
- `Analytics.swift:111` — event names are `StaticString`, property values plain `[String: String]`; the privacy fence on values is documented and enforced nowhere.
- `AppSettings.swift:396` — `remoteAppIsOffered` is `false`, so the companion surface is dark in shipping builds; lowers urgency of 4–6 and 8 without changing them.

(Files read in full or substantially: 22 of 71. Remaining 49 covered by pattern sweeps: SPDX, force unwrap/fatalError/as!/TODO, empty catch, @unchecked Sendable/nonisolated(unsafe), test_ seam visibility, store load/save shape.)
