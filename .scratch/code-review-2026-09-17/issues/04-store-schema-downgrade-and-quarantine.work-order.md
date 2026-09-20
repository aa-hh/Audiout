_Revised after the spec check: the approvals store's newer-schema path now has its own test, a second verification command covers the two regression suites the headline filter cannot see, the `BTTrimStore` doc-comment contradiction is resolved, and the two tracks are merged into one because both edit the same test file._

# Work order — ticket 04: quarantine a newer-schema store file before falling back to empty

## Goal
Ten JSON stores in `AudioutCore` read a `schemaVersion` higher than the build understands, return "missing" (nil/empty), and leave the file in place — so the caller's first mutation `save`s over it with `.atomic` and the newer build's groups, routes, EQ, approvals and Bluetooth settings are gone with no copy. Make every one of those guards call `StoreRecovery.quarantine(fileURL)` before returning, which moves the file to `<base>.corrupt-<unix-seconds>.json` beside it, so the next save writes a fresh file and the newer data survives. Separately, `CompanionApprovalStore` is the one store whose `load` has no do/catch around the decode (so a corrupt approvals file is silently destroyed instead of set aside) and whose save-failure path writes to stderr instead of `StoreRecovery.noteWriteFailure`; give it both.

## Verified facts

All paths relative to the worktree root `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-04-store-schema-downgrade-and-quarantine`.

**`StoreRecovery`'s real API** — `AudioutCore/Sources/AudioutCore/StoreRecovery.swift`:
- `public enum StoreRecovery` (`:18`), three members.
- `public static func quarantine(_ fileURL: URL)` (`:60`). It **moves** (`FileManager.default.moveItem`, `:66`), it does not copy. Destination is `<base>.corrupt-<Int(Date().timeIntervalSince1970)>.json` in the same directory (`:61-64`). A failed move returns silently and records nothing (`:67-69`). On success it appends `fileURL.lastPathComponent` to a process-global list (`:70`).
- `public static var quarantinedFileNames: [String]` (`:28`) — what a test can observe; the doc says it accumulates and never clears, so ask `contains`, not equality (`:24-27`).
- `public static func noteWriteFailure(_ error: Error)` (`:47`) — calls `onWriteFailure` if the app installed one; a no-op with none installed (`:32-34`).
- `public static var onWriteFailure: ((Error) -> Void)?` (`:39`) — one process-global slot.

**The ten newer-schema guards**, one line each:

| File (`AudioutCore/Sources/AudioutCore/`) | Guard line | Current text tail | On-disk file name |
|---|---|---|---|
| `AppRouteStore.swift` | `:199` | `else { return nil }` | `app-routes.json` (`:180`) |
| `GroupStore.swift` | `:144` | `else { return [] }` | `groups.json` (`:94`) |
| `RoutingStore.swift` | `:89` | `else { return nil }` | `routing.json` (`:70`) |
| `DeviceEQStore.swift` | `:54` | `else { return nil }` | `device-eq.json` (`:36`) |
| `DeviceIconStore.swift` | `:51` | `else { return nil }` | `device-icons.json` (`:32`) |
| `HiddenSpeakersStore.swift` | `:51` | `else { return nil }` | `hidden-speakers.json` (`:32`) |
| `ExcludedAppsStore.swift` | `:77` | `else { return nil }` | `excluded-apps.json` (`:58`) |
| `BTTrimStore.swift` | `:223` | `else { return nil }` | `bt-sync-trims.json` (injected, `:137`; tests use `bt-sync-trims.json`, `StoreRecoveryTests.swift:99`) |
| `CompanionApprovalStore.swift` | `:71` | `else { return nil }` | `companion-approvals.json` (`:56`) |
| `BTHardwareVolumeStore.swift` | `:104` | `else { return [] }` | `bt-hardware-volume.json` (`:22`) |

**`BTHardwareVolumeStore` is IN scope.** It has the same guard — `BTHardwareVolumeStore.swift:104` `guard envelope.schemaVersion <= currentSchemaVersion else { return [] }` (no `Self.`, inside `private static func loadDisabled`, `:92`) — and the same destructive write, `write(disabled:)` at `:108-115` ending in `try data.write(to: fileURL, options: .atomic)` (`:114`). It already quarantines on decode failure (`:98-103`), so only the downgrade branch is missing. Its load is not throwing and runs inside `init` (`:58`).

**`CompanionApprovalStore` is the one store with no do/catch:** `CompanionApprovalStore.swift:69-70` is `let data = try Data(contentsOf: fileURL)` then `let envelope = try decoder.decode(Envelope.self, from: data)`. The pattern every other store uses is `AppRouteStore.swift:192-198`: declare `let envelope: Envelope`, `do { envelope = try decoder.decode(Envelope.self, from: data) } catch { StoreRecovery.quarantine(fileURL); throw error }`.

**Its save-failure path:** `CompanionApprovalController.persist()` at `CompanionApprovalStore.swift:195-203` — `catch { FileHandle.standardError.write(Data("[Audiout] companion approvals failed to save: \(error)\n".utf8)) }` (`:198-201`).

**`CompanionApprovalStore.init(directory:)`** exists with a default argument (`:55`), and `load()` is `public func load() throws -> [CompanionApproval]?` (`:67`).

**Doc comments that say a newer file reads as missing**, per store: `AppRouteStore.swift:186-188`, `GroupStore.swift:126-133`, `RoutingStore.swift:76-78`, `DeviceEQStore.swift:42-43`, `DeviceIconStore.swift:38-40`, `HiddenSpeakersStore.swift:38-40`, `ExcludedAppsStore.swift:64-66`, `CompanionApprovalStore.swift:62-66`, and **`BTTrimStore.swift:143-145`** — the comment on the public `load()` (`:146`), even though the guard itself lives in the private `loadEnvelope()` (`:213`, guard at `:223`). `BTHardwareVolumeStore` has no such sentence anywhere.

**Where the existing quarantine tests actually live.** The ticket's Test-seam line names `AppRouteStoreTests` / `GroupStoreTests`; neither contains a quarantine test, and there is no `GroupStoreTests.swift` (the group store tests are inside `GroupControllerTests.swift`). The real seam is `AudioutCore/Tests/AudioutCoreTests/StoreRecoveryTests.swift`, which holds one quarantine test per store at `:43-104` (`groupStoreQuarantinesCorruptFile` `:43`, routing `:52`, app-routes `:61`, excluded-apps `:70`, device-icons `:79`, device-eq `:88`, bt-trim `:97`) plus the helpers `directory(_:)` `:18`, `writeGarbage(_:in:)` `:24`, `expectSetAside(_:in:)` `:30`, and the write-failure test `writeFailureFiresHandler` `:132` with its `FailureCounter` box `:153`. **Assumption recorded:** the new tests go in this file, not in the two the ticket names, because that is where the behaviour is already tested; the verification filter's `StoreRecovery` term runs it either way.
- That suite is `extension SerializedSharedState { @Suite final class StoreRecoveryTests: IsolatedSuite }` (`:10-12`); the doc at `:7-9` says it is nested there because `StoreRecovery`'s handler and quarantine list are process-global and `onWriteFailure` is one slot two concurrent tests would tear out from under each other. Any new test touching `onWriteFailure` must live here for that reason.
- `IsolatedSuite` supplies `scratchDir` (`AudioutCore/Tests/AudioutCoreTests/IsolatedSuite.swift:209`) and is `@MainActor` (`:195`).
- **What actually makes a new table entry fail before the change:** `expectSetAside`'s three assertions are the file-gone check (`:31-32`), the exactly-one-set-aside-copy check (`:34-36`), and `StoreRecovery.quarantinedFileNames.contains(fileName)` (`:37`). The third is already satisfied for seven of the ten file names, because that list is process-global and never clears and the existing corrupt-file tests at `:43-104` have already put those names in it. So the assertion that proves the new behaviour is the file-moved one at `:31`, and the one-copy count at `:34`.

**Existing newer-schema tests that must keep passing** — each writes a newer file, calls `load()` exactly once, and asserts only the return value, so quarantining the file does not break them: `AppRouteStoreTests.swift:90-100`, `GroupControllerTests.swift:1181-1191`, `DeviceEQStoreTests.swift:55-60`, `DeviceIconStoreTests.swift:49-55`, `ExcludedAppsTests.swift:40-46`, `BTTrimStoreTests.swift:103-109`, `CompanionApprovalStoreTests.swift:42-48`. None asserts the file still exists.
- `CompanionApprovalStoreTests.swift:42-48` (`newerSchemaFileIsRefusedNotGuessedAt`) asserts only `try makeStore().load() == nil` (`:47`) — it passes with or without the quarantine call, so it cannot serve as the seam for the approvals downgrade path.

**The filter is a regex over test names, not a file selector.** `run-tests.sh` passes its arguments straight through to `swift test` (`scripts/run-tests.sh:171`). Two regression tests this work touches match none of `StoreTests|CompanionApprovalStore|StoreRecovery`:
- `GroupControllerTests.loadUnknownFutureSchemaVersionReturnsEmptyRatherThanCrashing` (`GroupControllerTests.swift:1181`), in `@Suite struct GroupControllerTests` (`:5`) — covers `GroupStore`, which step 2 edits.
- `ExcludedAppsTests.newerSchemaLoadsNil` (`ExcludedAppsTests.swift:40`), in `@Suite final class ExcludedAppsTests` (`:10`) — covers `ExcludedAppsStore`, which step 2 edits.

**Envelope shapes:** `AppRouteStore.swift:162-165` `{schemaVersion, routes}`; `GroupStore.swift:77-80` `{schemaVersion, groups}`; `RoutingStore.swift:54-57` `{schemaVersion, state}` where `State` is `{selectedDeviceIDs: [String], mainOutKind: String, mainOutGroupID: String?}` (`:31-34`); `DeviceEQStore.swift:19-23` `{schemaVersion, mainOut?, devices}`; `DeviceIconStore.swift:16-19` `{schemaVersion, icons}`; `HiddenSpeakersStore.swift:16-19` `{schemaVersion, deviceIDs}`; `ExcludedAppsStore.swift:42-45` `{schemaVersion, apps}`; `BTTrimStore.swift:99-106` `{schemaVersion, trims, latencyMs?, …}`; `BTHardwareVolumeStore.swift:24-29` `{schemaVersion, disabledUIDs}`; `CompanionApprovalStore.swift:40-43` `{schemaVersion, approvals}`. No custom `CodingKeys` and no decoder key strategy anywhere; every field the payloads below omit is optional.

**Folder rules:** `AudioutCore/Sources/AudioutCore/AGENTS.md` exists and must be read before editing there. There is no `AGENTS.md` under `AudioutCore/Tests/AudioutCoreTests/`; the root `AGENTS.md` still applies.

**Worktree state:** clean, HEAD `a14ff11f`.

## Decision — no save-side refusal guard

Quarantine-on-load alone satisfies the Done-when, and it is the smaller change. `StoreRecovery.quarantine` *moves* the file (`StoreRecovery.swift:66`), so after the guard fires the newer file no longer sits at `fileURL` and the next `.atomic` write creates a new one beside the preserved copy — the destruction the finding describes cannot happen. A save-path refusal guard would require each `save` to re-read and re-decode the file it is about to replace, and buys nothing once the file has been moved. **Do not add one.**

Noted, not to act on: `quarantine` names the set-aside file `.corrupt-<timestamp>.json` even though a newer-schema file is not corrupt. Reusing the existing name is the settled call; do not add a second naming scheme.

No user-facing feature is added, so no new `Analytics.capture` event is needed.

## Steps

One executor, steps 1–4 in order.

**Step 1 — write the failing table-driven test.**
In `AudioutCore/Tests/AudioutCoreTests/StoreRecoveryTests.swift`, insert a new `// MARK:` section and one `@Test` function immediately after `btTrimStoreQuarantinesCorruptFile` ends at `:104`, before the existing `// MARK: Nothing to set aside` at `:106`.

The test is a local array literal of one entry per store, each entry carrying three things: the on-disk file name, a newer-schema JSON payload string, and a closure taking the directory `URL` that constructs that store and triggers its load, discarding the result. Loop the array; for each entry create a fresh subdirectory via the existing `directory(_:)` helper named after the file's base, write the payload to `<dir>/<fileName>`, run the closure, then call the existing `expectSetAside(fileName, in: dir)`. Do not write your own assertions — `expectSetAside` (`:30-39`) already checks all three things that matter.

Cover **nine** stores in the table (the approvals store is step 3's, because it needs its own load-returns-nil assertion alongside the quarantine check). Use exactly these payloads — each is the minimum that decodes cleanly into that store's `Envelope`, so the *schema guard* fires rather than the decode catch (getting this wrong makes the test pass for the wrong reason):

```
app-routes.json       {"schemaVersion": 999, "routes": []}
groups.json           {"schemaVersion": 999, "groups": []}
routing.json          {"schemaVersion": 999, "state": {"selectedDeviceIDs": [], "mainOutKind": "selected"}}
device-eq.json        {"schemaVersion": 999, "devices": {}}
device-icons.json     {"schemaVersion": 999, "icons": {}}
hidden-speakers.json  {"schemaVersion": 999, "deviceIDs": []}
excluded-apps.json    {"schemaVersion": 999, "apps": []}
bt-sync-trims.json    {"schemaVersion": 999, "trims": {}}
bt-hardware-volume.json  {"schemaVersion": 999, "disabledUIDs": []}
```

Load closures: eight of the nine are `try SomeStore(directory: $0).load()` — copy the construction shape from the neighbouring tests, e.g. `AppRouteStore(directory: dir)` (`:64`), `BTTrimStore(directory: dir)` (`:100`). `BTHardwareVolumeStore` is the exception: its load runs inside `init` and does not throw, so its closure just constructs the store and discards it (`init(directory:fileName:)`, `BTHardwareVolumeStore.swift:52-53`). Make the closure type throwing so the other eight can use `try`.

Give the test a doc comment naming the defect in one sentence: an older build that reads a newer-schema file leaves it in place, and the caller's first save atomically overwrites it, destroying the newer build's data.

Run `bash scripts/run-tests.sh --filter 'StoreRecovery'` and paste the failing output before editing any source file. It must fail on all nine entries — the failure to expect is the file-moved assertion at `StoreRecoveryTests.swift:31` (and the one-copy count at `:34`), not the name-list check, which is already satisfied for most names by the existing corrupt-file tests.

**Step 2 — add the quarantine call to nine guards.**
In each of these nine files, at exactly the line listed, change the single-line `guard envelope.schemaVersion <= … else { … }` into a multi-line `else` block that first calls `StoreRecovery.quarantine(fileURL)` and then performs the same `return` the line already has. Do not change the guard condition, the return value, or anything else in the function. Copy the call shape verbatim from the do/catch two lines above it in the same file — e.g. `AppRouteStore.swift:196` `StoreRecovery.quarantine(fileURL)`.

- `AudioutCore/Sources/AudioutCore/AppRouteStore.swift:199` (`return nil`)
- `AudioutCore/Sources/AudioutCore/GroupStore.swift:144` (`return []`)
- `AudioutCore/Sources/AudioutCore/RoutingStore.swift:89` (`return nil`)
- `AudioutCore/Sources/AudioutCore/DeviceEQStore.swift:54` (`return nil`)
- `AudioutCore/Sources/AudioutCore/DeviceIconStore.swift:51` (`return nil`)
- `AudioutCore/Sources/AudioutCore/HiddenSpeakersStore.swift:51` (`return nil`)
- `AudioutCore/Sources/AudioutCore/ExcludedAppsStore.swift:77` (`return nil`)
- `AudioutCore/Sources/AudioutCore/BTTrimStore.swift:223` (`return nil`, inside `private func loadEnvelope()`)
- `AudioutCore/Sources/AudioutCore/BTHardwareVolumeStore.swift:104` (`return []`, inside `private static func loadDisabled(fileURL:decoder:)` — `fileURL` is the parameter, and the guard reads `currentSchemaVersion` with no `Self.` prefix; leave that as it is)

Then append this one sentence, verbatim, to the end of the doc comment listed for each file below:

> The file is moved aside first (`StoreRecovery.quarantine`) so the next save cannot overwrite a file this build cannot read.

**Eight files get the sentence**, at these comments: `AppRouteStore.swift:186-188`, `GroupStore.swift:126-133`, `RoutingStore.swift:76-78`, `DeviceEQStore.swift:42-43`, `DeviceIconStore.swift:38-40`, `HiddenSpeakersStore.swift:38-40`, `ExcludedAppsStore.swift:64-66`, and **`BTTrimStore.swift:143-145`** — the doc comment on the public `load()`, which is the one that says a newer file is treated as missing, even though the guard you edit sits in the private `loadEnvelope()` below it. Do not add a doc comment to `loadEnvelope()`.

**One file gets no sentence:** `BTHardwareVolumeStore.swift`. Its `loadDisabled` (`:92`) has no doc comment and no "treated as missing" sentence exists anywhere in that file — do not invent a doc block.

**Step 3 — write the three failing `CompanionApprovalStore` tests.**
In `AudioutCore/Tests/AudioutCoreTests/StoreRecoveryTests.swift`, insert three `@Test` functions immediately after `writeFailureFiresHandler` ends at `:150` and before the `FailureCounter` class at `:153`. All three go in this file, not in `CompanionApprovalStoreTests.swift`, because the save-failure one installs `StoreRecovery.onWriteFailure`, a single process-global slot, and only this suite is serialized for that reason (`StoreRecoveryTests.swift:7-9`).

- **Test one, newer schema.** This is the tenth store's downgrade test, kept here rather than as a tenth table row in step 1 so that it lands after step 2 and fails only on the change step 4 makes. Use `directory("companion-approvals-newer")`, write the exact payload `{"schemaVersion": 999, "approvals": []}` to `companion-approvals.json` in it, expect `try CompanionApprovalStore(directory: dir).load() == nil`, then `expectSetAside("companion-approvals.json", in: dir)`. Defect it catches: a newer-schema approvals file is left in place, and the first approval this build records overwrites it atomically, losing every phone the newer build had approved. (`CompanionApprovalStoreTests.swift:42-48` asserts only `load() == nil` and passes either way, which is why this test is needed.)
- **Test two, corrupt file.** Mirror `groupStoreQuarantinesCorruptFile` (`:43-50`) exactly — `directory("companion-approvals")`, `writeGarbage("companion-approvals.json", in: dir)`, expect `CompanionApprovalStore(directory: dir).load()` to throw, then `expectSetAside("companion-approvals.json", in: dir)`, then expect a second `load()` returns nil. Defect it catches: a corrupt approvals file is left in place and the first new approval overwrites the evidence, with every approved phone re-prompting and no record of why.
- **Test three, failed save.** Mirror `writeFailureFiresHandler` (`:132-150`) — create a plain FILE at `scratchDir/blocker-approvals` so `createDirectory` underneath it must fail, build a `CompanionApprovalController(store: CompanionApprovalStore(directory: <that file>/x))`, install a counting `StoreRecovery.onWriteFailure` with `defer { StoreRecovery.onWriteFailure = nil }` and the existing `FailureCounter` box (`:153`), then drive one persist and expect the count to be 1. To drive a persist, use a public controller method that reaches `persist()` — `revoke(clientID:)` returns early unless the id is already in `approvals` (`CompanionApprovalStore.swift:189`), so use the prompt-answer path instead: set `presentPrompt` to respond immediately and call `handleRequest(clientID:clientName:decide:)`, the shape used at `CompanionApprovalStoreTests.swift:56-61`. Also expect the in-memory approval list still holds the new entry, matching the assertion at `StoreRecoveryTests.swift:148-149`. Defect it catches: a failed approvals save goes only to stderr, so the user is never told their phone approval did not reach disk.

Run `bash scripts/run-tests.sh --filter 'StoreRecovery'` and paste the failing output before editing the source. All three must fail; the nine from step 1 must now pass.

**Step 4 — three edits in `AudioutCore/Sources/AudioutCore/CompanionApprovalStore.swift`.**
1. `:70` — replace the single `let envelope = try decoder.decode(...)` line with the declare-then-do/catch form copied from `AppRouteStore.swift:192-198`: `let envelope: Envelope` followed by `do { envelope = try decoder.decode(Envelope.self, from: data) } catch { StoreRecovery.quarantine(fileURL); throw error }`.
2. `:71` — the newer-schema guard gets the same treatment as step 2's nine: `StoreRecovery.quarantine(fileURL)` then `return nil`. Append to the `load()` doc comment at `:62-66` the same verbatim sentence given in step 2.
3. `:198-201` — replace the `FileHandle.standardError.write(...)` catch body with the single call `StoreRecovery.noteWriteFailure(error)`. Leave `onChange?()` at `:202` where it is, outside the do/catch.

## Out of scope — do not touch
- Every other finding in `.scratch/code-review-2026-09-17/areas/model.md` — in particular finding 4 (unanswered approval prompts are never withdrawn), which lives in the same file at `CompanionApprovalStore.swift:158-180`. Do not fix it here.
- Any `save` / `write` function in any store. No refusal guard, no read-before-write.
- `StoreRecovery.swift` itself — no new function, no rename, no second quarantine naming scheme.
- `AppRouteStoreTests.swift:148-166` (`unknownKindLeavesTheRestOfTheFileIntact`) and every existing newer-schema test listed in Verified facts: they must keep passing unchanged. Do not "update" them.
- `GroupControllerTests.swift`, `CompanionApprovalStoreTests.swift`, `DeviceEQStoreTests.swift`, `DeviceIconStoreTests.swift`, `ExcludedAppsTests.swift`, `BTTrimStoreTests.swift`, `BTHardwareVolumeStoreTests.swift` — no edits in any of them. They are run as regression checks only.
- Do not add `Analytics.capture` or `Telemetry.fail` calls; do not change the existing `Telemetry.fail(.localPlayback, "bt_volume:store_write_failed", …)` at `BTHardwareVolumeStore.swift:85-86`.
- Do not bump any `currentSchemaVersion`.
- No cleanup, no abstractions (do not factor the ten guards into a shared helper), no error handling for impossible cases, no backwards-compat shims.

## Verification

Both commands run at the end, on the finished working tree. Both must pass.

Headline — the new and existing quarantine behaviour:

```
bash scripts/run-tests.sh --filter 'StoreTests|CompanionApprovalStore|StoreRecovery'
```

Regression — the two suites this filter cannot see, both covering stores step 2 edits (`GroupStore` and `ExcludedAppsStore`):

```
bash scripts/run-tests.sh --filter 'GroupControllerTests|ExcludedAppsTests'
```

Expected from each: a line reading `Test run with N tests … passed`, zero failures. **Proof that a run happened is the `Test run with N tests` line** — a `--filter` that matches nothing exits green. If a repeat run prints a cache skip, force a real run with `AUDIOUT_TEST_NO_CACHE=1`.

Pre-change baseline: **not obtained** (test capacity permits were held by other agents during scoping). The baseline is the executor's own step 1 / step 3 runs: the new tests must fail, for the reasons stated, before the matching source file is edited.

Test seam: `AudioutCore/Tests/AudioutCoreTests/StoreRecoveryTests.swift:43-104` (per-store quarantine tests, where step 1 inserts) and `:132-150` (write-failure test, where step 3 inserts).

## Execution plan

**Single track, one executor. Steps 1–4 in order. Model: sonnet. Effort: medium.**

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-04-store-schema-downgrade-and-quarantine`, HEAD `a14ff11f`, working tree clean apart from this untracked work-order file. No other track, no merge.

Not split into parallel tracks: both halves of the work insert into the same file, `AudioutCore/Tests/AudioutCoreTests/StoreRecoveryTests.swift`, so they cannot run in isolated worktrees without a conflicting merge.

Files touched: `AudioutCore/Sources/AudioutCore/{AppRouteStore,GroupStore,RoutingStore,DeviceEQStore,DeviceIconStore,HiddenSpeakersStore,ExcludedAppsStore,BTTrimStore,BTHardwareVolumeStore,CompanionApprovalStore}.swift` and `AudioutCore/Tests/AudioutCoreTests/StoreRecoveryTests.swift`.

## Executor rules
- Follow the steps in order. Do not add, merge, reorder, or skip steps.
- Before editing in any folder, read the nearest AGENTS.md above it (and the root one). `AudioutCore/Sources/AudioutCore/AGENTS.md` exists; there is none under the tests folder.
- If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
- Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
- If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
- Build and test only through the wrapper scripts: `bash scripts/build.sh` and `bash scripts/run-tests.sh`. Never run a bare `swift build`, `swift test`, `swift run`, `swift package`, or `xcodebuild` — filtered runs included.
- A filtered run is proof only if its output contains a `Test run with N tests` line. If the output says the run was served from cache, re-run with `AUDIOUT_TEST_NO_CACHE=1`.
- Never `git commit`, `git push`, `git merge`, `git stash`, `git checkout` or `git restore`. Leave the work in the working tree.
- No live-hardware work: no `.dev` build, no `scripts/make-app.sh`, no `scripts/livetest.sh`, no `scripts/make-staging.sh`.
- "Done" means both Verification commands were run in this session and passed. Paste their output.
- Touch nothing in the Out-of-scope list.
- Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
