# Work order: withdraw and free a companion approval prompt when its connection dies

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-06-companion-approval-prompt-lifetime` (HEAD `a14ff11f`, clean).

## Goal

When a phone connects, sends `hello`, and is held for the "Allow X to control audio?" alert, and then disconnects (or the server's 180 s approval deadline reaps it), the alert stays on screen and `CompanionApprovalController.pendingDeciders[clientID]` is never removed. A LAN peer cycling fresh client IDs stacks alerts. Fix: `CompanionServer` tells the controller the last awaiting connection for a phone identity is gone; the controller drops its pending entry and asks the app layer (through a new callback beside `presentPrompt`) to close the alert. Core stays free of AppKit.

## Verified facts

- `CompanionServer.onApprovalRequest` declaration: `AudioutCore/Sources/AudioutCore/CompanionServer.swift:109`. All callbacks fire via a fresh `queue.async` hop, never inline (`:87-89`). `onClientDisconnected` at `:116` is the model for a "gone" callback.
- `Client.phoneClientID` (`:154`) is the phone identity string (canonical uppercase UUID); `Client.id` (`:147`) is the per-connection UUID. `awaiting: [UUID: Client]` at `:178`.
- `removeClient(_:)` at `:655-660`: an entry in `pending` OR `awaiting` is removed with `pending.removeValue(forKey: id) ?? awaiting.removeValue(forKey: id)` then `return` with no signal. Pending entries have `phoneClientID == nil`; awaiting entries always have it set (`:841`).
- `approvalWork` at `:844-848`: removes the client from `awaiting` and calls `refuse(held, reason: CompanionGoodbyeReason.approvalTimedOut)`. `phoneClientID` is set at `:841` before the work item is armed.
- `resolveApproval` (`:597`) removes from `awaiting` on `.approved` (via `promote`, `:577`) and `.denied` (`:616`) without `removeClient`; `refuse` cancels the connection, whose state handler later calls `removeClient(id)` (`:546`) which then finds nothing in `awaiting`. So the abandonment signal cannot fire for an answered request.
- `stopLocked` (`:366-390`) also empties `awaiting`; left out of scope (see below).
- Test seams on the server: `test_clientNames()` at `:943`, `test_awaitingCount()` at `:948`; `test_approvalTimeoutOverride` at `:217`.
- Controller: `AudioutCore/Sources/AudioutCore/CompanionApprovalStore.swift`. `pendingDeciders` at `:109`; `presentPrompt` at `:116` with signature `((_ clientName: String, _ respond: @escaping (Bool) -> Void) -> Void)?`; `dropClient` at `:121`; `handleRequest` at `:151-169` sets `pendingDeciders[clientID] = [decide]` at `:165` then calls `presentPrompt?(clientName) {...}` at `:166`; `resolvePrompt` at `:171-184` is the only place that removes the entry (`:180`). Class is `@MainActor` (`:101`).
- App layer: `AudioutCore/Sources/AudioutApp/AppDelegate.swift`. `onApprovalRequest` wired at `:3098-3104` (server queue → `DispatchQueue.main.async`, guarded by `!self.isTerminating`); `presentPrompt` wired at `:3105-3107`; `dropClient` at `:3109-3111`. `presentCompanionApprovalPrompt(clientName:respond:)` at `:3122-3137` presents with `alert.runModal()` and calls `respond(alert.runModal() == .alertFirstButtonReturn)` (`:3136`). No window, no sheet: it is a modal run loop, so `NSApp.abortModal()` is the handle that ends it, and `runModal()` then returns `.abort`.
- `presentPrompt` call sites that must change when its signature grows: `CompanionApprovalStoreTests.swift:56, :67, :84, :102, :124, :175`; `GeneralSettingsCompanionTests.swift:264, :298`; `AppDelegate.swift:3105`. No others (`git grep presentPrompt`).
- `CompanionServerTests` harness: `connectClient(via:to:)` at `:130`, `sendHello(over:name:clientID:)` at `:189`, `LockedBox`, `waitUntil`, `MessageLog.closed`; existing deadline test `awaitingApprovalTimesOutWithARetryableReason` at `:844-864` is the template (`test_approvalTimeoutOverride = 0.3`, `onApprovalRequest = { _, _, decide in decide(.pending) }`).
- `CompanionApprovalStoreTests` is `@MainActor @Suite final class ... : IsolatedSuite` (`:12-13`), `phoneID` constant at `:15`, `makeStore()` at `:17`.
- AudioutCore/AGENTS.md rules: `scripts/run-tests.sh --filter <Suite>` only (`:11`); tests must stay invisible (`:12`). AudioutApp/AGENTS.md: behaviour belongs in the library; the test suite cannot see AudioutApp.

## Decisions (made here, do not reopen)

- Server callback name and shape: `public var onApprovalAbandoned: (@Sendable (_ clientID: String) -> Void)?`, declared directly below `onApprovalRequest` (`CompanionServer.swift:109`). Carries the phone identity (`phoneClientID`), not the connection UUID, because the controller keys by phone identity.
- The server fires it only when NO other `awaiting` entry still has the same `phoneClientID` (a reconnect during an open prompt joins the waiter list, `CompanionApprovalStore.swift:159-163`, and must keep its prompt).
- Controller callback: `public var withdrawPrompt: ((_ clientID: String) -> Void)?`, declared directly below `presentPrompt` (`:116`). Controller method: `public func abandonRequest(clientID: String)`: remove `pendingDeciders[clientID]`; if nothing was there, return without calling `withdrawPrompt` (a remembered phone never prompted); otherwise call `withdrawPrompt?(clientID)`. The removed deciders are not called (their connections are gone; `resolveApproval` would no-op anyway).
- `presentPrompt` gains a leading `clientID` parameter: `((_ clientID: String, _ clientName: String, _ respond: @escaping (Bool) -> Void) -> Void)?`. The app layer needs a key to find the alert to close. Every existing call site adds one more ignored `_`.
- App layer keeps `private var companionApprovalAlerts: [String: NSAlert] = [:]` on `AppDelegate`, keyed by clientID. Withdraw: if an alert exists for that clientID AND `NSApp.modalWindow === alert.window`, call `NSApp.abortModal()`; otherwise do nothing. In the presenter, after `runModal()` returns, remove the dictionary entry; if the return value is `.abort`, return without calling `respond` (an abort is not the user's answer and must not persist a denial). razor ceiling: a withdrawn alert sitting UNDER a newer nested modal is left for the user to answer; their answer just records a remembered decision for that phone, which is today's behaviour and harmless.
- `stopLocked` is NOT changed: `presentCompanionApprovalPrompt` already skips on `isTerminating`, and a modal alert blocks the Settings checkbox that stops the server.

## Steps

1. **Failing tests first, server side.** In `AudioutCore/Tests/AudioutCoreTests/CompanionServerTests.swift`, after `awaitingApprovalTimesOutWithARetryableReason` (`:864`), add three tests in the T24 section, each built like that test (hub, `CompanionServer()`, `broadcast(makeSnapshot())`, `onApprovalRequest = { _, _, decide in decide(.pending) }`, `connectClient`, `sendHello`), recording `server.onApprovalAbandoned` into a `LockedBox<[String]>([])`:
   - `droppedAwaitingConnectionReportsAbandonment`: wait until `server.test_awaitingCount() == 1`, then `client.cancel()`; expect `waitUntil { abandoned.value == [Self.validClientID] }` and `waitUntil { server.test_awaitingCount() == 0 }`. Defect it catches: a phone that walks away mid-prompt leaves the alert up and the pending entry forever.
   - `approvalDeadlineReportsAbandonment`: `test_approvalTimeoutOverride = 0.3`; expect `waitUntil { abandoned.value == [Self.validClientID] }`. Defect: the 180 s reap closes the socket but never withdraws the alert.
   - `abandonmentWaitsForTheLastConnectionOfThatPhone`: connect two clients, hello both with the same `validClientID`, wait for `test_awaitingCount() == 2`, cancel one; expect `waitUntil { server.test_awaitingCount() == 1 }` and then `abandoned.value.isEmpty`; cancel the other; expect `waitUntil { abandoned.value == [Self.validClientID] }`. Defect: a reconnect that joined the open prompt would have its prompt yanked when its sibling connection dies.
   Run `bash scripts/run-tests.sh --filter CompanionServerTests`; expect a compile error on `onApprovalAbandoned`. Paste it.

2. **Failing tests, controller side.** In `AudioutCore/Tests/AudioutCoreTests/CompanionApprovalStoreTests.swift`, change the six `presentPrompt` closures (`:56, :67, :84, :102, :124, :175`) to take the extra leading `_`. Add after `differentPhonesPromptIndependently` (`:131`):
   - `abandonedRequestFreesTheEntryAndWithdrawsThePrompt`: record `withdrawPrompt` calls into an array; `handleRequest(clientID: Self.phoneID, ...)`; `abandonRequest(clientID: Self.phoneID)`; expect withdraw list `== [Self.phoneID]`, `approvals.isEmpty` (no decision persisted); then `handleRequest` again for the same phone and expect the prompt count to be 2 (proves the entry was freed, not just hidden). Defect: the entry lives forever so the phone's next connect silently joins a dead prompt and never re-prompts.
   - `abandonForAPhoneThatWasNeverPromptedIsANoOp`: `abandonRequest` for an unknown clientID; expect no withdraw call. Defect: a remembered phone that drops before its instant verdict lands would try to close an alert that does not exist.
   Also update `GeneralSettingsCompanionTests.swift:264` and `:298` closures to the three-parameter shape. Run `bash scripts/run-tests.sh --filter 'CompanionApproval|GeneralSettingsCompanion'`; expect compile errors on `withdrawPrompt`/`abandonRequest`. Paste them.

3. **Server: declare the callback.** `CompanionServer.swift`, below `:109`: add `onApprovalAbandoned` per Decisions with a doc comment stating: fires when the last awaiting connection carrying this phone `clientID` went away unanswered (dropped, or the approval deadline reaped it); never for an answered request; the wiring withdraws the prompt.

4. **Server: fire on drop.** `removeClient(_:)` (`:655-660`): split the combined `??` into two branches. `pending` removal stays silent. For an `awaiting` removal, after cancelling deadline and connection, if `phoneClientID` is set and `!awaiting.values.contains { $0.phoneClientID == phoneClientID }`, capture `onApprovalAbandoned` and fire it via `queue.async` (the discipline at `:87-89`), then return.

5. **Server: fire on deadline.** In `approvalWork` (`:844-848`), after `refuse(held, ...)`, apply the same "no sibling still awaiting" check on `held.phoneClientID` and fire via `queue.async`. Put the check in one small private queue-confined helper (e.g. `noteApprovalAbandoned(_ client: Client)`) called from both steps 4 and 5 so the rule lives once.

6. **Controller.** `CompanionApprovalStore.swift`: change `presentPrompt` (`:116`) to the three-parameter shape and update its doc line; add `withdrawPrompt` below it with a doc comment ("close the prompt shown for this clientID; its connections are gone; wired by the app layer"); update the call at `:166` to pass `clientID` first; add `abandonRequest(clientID:)` per Decisions, placed after `resolvePrompt`. Update the type doc at `:97-99` to mention `withdrawPrompt` in the same sentence as `presentPrompt`.

7. **App layer.** `AppDelegate.swift`:
   - Add `private var companionApprovalAlerts: [String: NSAlert] = [:]` near the other companion properties.
   - In `wireCompanionServer`, below the `onApprovalRequest` block (`:3104`), wire `companionServer.onApprovalAbandoned` with the identical `DispatchQueue.main.async` + `guard let self, !self.isTerminating` hop, calling `self.companionApprovals.abandonRequest(clientID:)`.
   - Change the `presentPrompt` wiring (`:3105`) to forward `clientID` too, and wire `companionApprovals.withdrawPrompt` to a new `@MainActor private func withdrawCompanionApprovalPrompt(clientID:)` implementing the Decisions rule.
   - `presentCompanionApprovalPrompt` gains `clientID:`; store the alert before `runModal()`, remove it after, and on `.abort` return without `respond`. Extend the existing doc comment with one sentence: an abort from `withdrawCompanionApprovalPrompt` is not an answer and records nothing.

8. Run the Verification command.

## Out of scope — do not touch

- `stopLocked`, `resolveApproval`, `promote`, `refuse`, the liveness reaper, caps, or any `test_*` visibility (finding #8 is another ticket).
- Corrupt-file quarantine and `noteWriteFailure` in `CompanionApprovalStore` (findings #5, #6, other tickets).
- Replacing `runModal()` with a sheet or non-modal presentation; any window/panel refactor.
- Calling the removed deciders with `.denied`; persisting anything on abandonment.
- Analytics: none exists on this path; add none.
- No new types, protocols, or helpers beyond the two callbacks, `abandonRequest`, the app-layer dictionary and withdraw method, and the one server-side helper in step 5. No comment rewrites outside the lines named.
- No commits, no pushes, no `.dev`/`make-app.sh`/`livetest.sh` builds, no bare `swift` commands.

## Verification

```
bash scripts/run-tests.sh --filter 'CompanionServer|CompanionApproval'
```
Expected: a line `Test run with N tests in 2 suites passed` with N = 44 (39 baseline + 3 server + 2 controller). Trust only the `Test run with` line. Also run `bash scripts/run-tests.sh --filter GeneralSettingsCompanion` (its two closures changed) and `bash scripts/build.sh` (AudioutApp is not covered by tests; the build proves the AppDelegate edit compiles).

Baseline observed before any change: `Test run with 39 tests in 2 suites passed after 2.080 seconds`.

Test seams: `AudioutCore/Tests/AudioutCoreTests/CompanionServerTests.swift:844` (T24 section, real loopback connections) and `AudioutCore/Tests/AudioutCoreTests/CompanionApprovalStoreTests.swift:100` (prompt funnel). The AppKit alert close itself is unseen by tests; `scripts/build.sh` stands in.

## Execution plan

One track, all steps, files: `CompanionServer.swift`, `CompanionApprovalStore.swift`, `AppDelegate.swift`, `CompanionServerTests.swift`, `CompanionApprovalStoreTests.swift`, `GeneralSettingsCompanionTests.swift`. The server and controller edits share one signature change and one verification run; splitting buys nothing. Model: sonnet. Effort: medium. Branch has no uncommitted work.

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them. Here: `AGENTS.md`, `AudioutCore/AGENTS.md`, `AudioutCore/Sources/AudioutCore/AGENTS.md`, `AudioutCore/Sources/AudioutApp/AGENTS.md`.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
> - Nobody commits or pushes. No `.dev` bundle builds, no `scripts/livetest.sh`, no `scripts/make-app.sh`. Only `scripts/run-tests.sh` and `scripts/build.sh`; never bare `swift test`/`swift build`.
> - Work only inside `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-06-companion-approval-prompt-lifetime`.
