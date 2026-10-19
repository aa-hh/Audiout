<!-- Revised after the Opus-mode spec check: wrong doc-comment target, an off-by-one line cite, a stray @MainActor, the setGroupMuted refusal literal (now applyUpdateGroup's), the clean-tree claim, and three missing scope fences. -->

# Work order — 07 Companion dispatcher: refuse unknown targets, clear the in-flight flag with `defer`

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-07-companion-dispatcher-refusals` (HEAD `a14ff11f`).

### Goal
In `CompanionCommandDispatcher`, `.setGroupMuted` and `.removeAppRoute` answer a LAN peer "applied" even when the target group or app route does not exist on the Mac — every neighbouring command in the same file refuses an unknown target instead. Make both guard first and refuse with string literals that already exist in the file. Separately, the `setStartBufferMs` apply task clears `startBufferApplyInFlight` only on its normal path; move the clear into a `defer` inside the `Task` so no exit can leave `setStartBufferMs` refused for the rest of the process's life.

### Verified facts
All paths relative to the worktree root.

1. `.setGroupMuted` returns `.ok` unconditionally — `AudioutCore/Sources/AudioutCore/CompanionCommandDispatcher.swift:234-236`:
   ```swift
   case .setGroupMuted(let id, let muted):
       groupController.setGroupMuted(muted, groupID: id)
       return .ok
   ```
2. `GroupController.setGroupMuted` silently no-ops for an unknown id — `AudioutCore/Sources/AudioutCore/GroupController.swift:1058-1061`: `guard let group = groups.first(where: { $0.id == groupID }) else { return }`.
3. `.removeAppRoute` returns `.ok` unconditionally — `CompanionCommandDispatcher.swift:241-243`:
   ```swift
   case .removeAppRoute(let bundleID):
       appRouting.removeRoute(bundleID: bundleID)
       return .ok
   ```
4. `AppRoutingController.removeRoute` silently no-ops for an unrouted bundle — `AudioutCore/Sources/AudioutCore/AppRoutingController.swift:113-118`: `guard let i = index(of: bundleID) else { return }`.
5. Neighbouring refusal for a write to a group id the Mac no longer has, exact literal `"That scene no longer exists on the Mac."` — `CompanionCommandDispatcher.swift:409-411`, in `applyUpdateGroup`, guarded by `groupController.groups.first(where: { $0.id == state.id })`. Its comment at `:405-408` states the reason: a peer working from a stale snapshot must not resurrect a group the Mac just deleted.
6. Neighbouring refusal for an unknown group used as a *read* target, exact literal `"Unknown scene."` — `CompanionCommandDispatcher.swift:578-581`, in `applySetMainOut`, guarded by `groupController.groups.contains(where: { $0.id == groupID })`.
7. Neighbouring refusal for an unknown speaker, exact literal `"Unknown speaker."` — `CompanionCommandDispatcher.swift:516-518` (`deviceWriteRefusal`) and `:597-599` (`applySetAppDestination`).
8. The only existing refusal literal about an app identifier is `"That app identifier isn't valid."` — `CompanionCommandDispatcher.swift:531-533`, in `applyAddAppRoute`. There is no existing literal in this file, or anywhere in `AudioutCore/Sources`, for "this bundle has no route" (searched `Unknown app`, `isn't routed`, `no longer routed`).
9. `applyAddAppRoute`'s membership expression is at `CompanionCommandDispatcher.swift:543`: `let alreadyRouted = appRouting.appRoutes.contains { $0.bundleID == bundleID }` (`:542` is the comment above it).
10. The in-flight flag is cleared only after the await — `CompanionCommandDispatcher.swift:275-279`:
    ```swift
    startBufferApplyInFlight = true
    Task {
        await applyStartBuffer(ms)
        startBufferApplyInFlight = false
    }
    ```
11. `applyStartBuffer` is declared `private let applyStartBuffer: (Int) async -> Void` — `CompanionCommandDispatcher.swift:134`. It cannot throw, and the `Task` at `:276` is unstructured with no stored handle, so no test in this suite can force an early exit from that body. The `defer` is hardening with no observable behaviour change.
12. `startBufferApplyInFlight` is declared at `CompanionCommandDispatcher.swift:144`; the refusal it drives is `"A buffer change is already being applied. Try again in a few seconds."` at `:272-274`.
13. The refusal-listing doc comment is at `CompanionCommandDispatcher.swift:171-179` and documents `execute(_ command: CompanionCommand)` at `:181`. `execute(_:clientID:)` at `:190` has its own separate comment at `:185-188`, which says nothing about refusals.
14. Test seam: `AudioutCore/Tests/AudioutCoreTests/CompanionCommandDispatcherTests.swift`. Existing happy-path tests: `setGroupMutedMutesEveryMember()` at `:364-370` (under the `// MARK: setGroupMuted` header at `:362`), `removeAppRouteRemovesIt()` at `:392-398` (under `// MARK: removeAppRoute` at `:390`).
15. The suite type carries `@MainActor` at `CompanionCommandDispatcherTests.swift:14`, so no individual test needs it; no existing test in the file carries the attribute.
16. The suite's harness is `makeContext()` at `CompanionCommandDispatcherTests.swift:78-109`, returning `Context` with `.dispatcher`, `.groupController`, `.appRouting`, `.settings`, `.spy`. Refusal assertions in this suite follow `addAppRouteRefusesExcludedBundle()` at `:381-388`: `#expect(!result.applied)` plus `#expect(result.refusalReason != nil)`.
17. The only in-repo senders of these two commands are the two tests above (`grep` for `.setGroupMuted(id:` / `.removeAppRoute(bundleID:` across `AudioutCore/Sources` and `AudioutCore/Tests`); the iPhone client lives in another repository.
18. `AudioutCore/Sources/AudioutCore/AGENTS.md` exists and must be read before editing; `AudioutCore/Tests/AudioutCoreTests/` has no AGENTS.md, so the root `AGENTS.md` and `AudioutCore/AGENTS.md` apply there.
19. Baseline, run in this session: `bash scripts/run-tests.sh --filter CompanionCommandDispatcher` ends with `Test run with 64 tests in 1 suite passed after 0.268 seconds.`

### Decision recorded (do not reopen)
- `.setGroupMuted` on an unknown group refuses with the existing literal `"That scene no longer exists on the Mac."` (fact 5) — **not** `"Unknown scene."`. `.setGroupMuted` is a write to an existing scene by id from a possibly stale phone snapshot, which is exactly the case `applyUpdateGroup`'s guard and its comment describe.
- `.removeAppRoute` on a bundle with no route refuses with the existing literal `"That app identifier isn't valid."` (fact 8). No literal for "no route for this bundle" exists in the file, and the settled decision forbids inventing wording; this is the only existing literal about an app identifier the Mac will not act on. One membership guard covers it — a bundle that has a route necessarily passed the shape check, so no separate `isPlausibleBundleID` call is added.

### Steps

1. **Write the first failing test.** In `AudioutCore/Tests/AudioutCoreTests/CompanionCommandDispatcherTests.swift`, directly after `setGroupMutedMutesEveryMember()` (ends `:370`), add a plain `@Test func setGroupMutedRefusesUnknownGroup()` — no `@MainActor` (fact 15) — styled identically to `addAppRouteRefusesExcludedBundle()` (`:381-388`): build a context with `makeContext()`, save no groups, execute `.setGroupMuted(id: "nope", muted: true)`, and expect `!result.applied` and `result.refusalReason == "That scene no longer exists on the Mac."`. Give it a one-line doc comment naming the defect: the dispatcher replied "applied" for a scene the Mac does not have, so the phone showed a mute that never happened. Run `bash scripts/run-tests.sh --filter CompanionCommandDispatcher` and paste the failure (it must fail on `result.applied` being true).

2. **Write the second failing test.** In the same file, directly after `removeAppRouteRemovesIt()` (ends `:398`), add a plain `@Test func removeAppRouteRefusesUnknownBundle()`, same style and no `@MainActor`: `makeContext()`, add no routes, execute `.removeAppRoute(bundleID: "com.apple.Music")`, expect `!result.applied` and `result.refusalReason == "That app identifier isn't valid."`. One-line doc comment naming the defect: a removal for a bundle with no route replied "applied" though nothing was removed. Run the same filtered command and paste the failure.

3. **Guard `.setGroupMuted`.** In `CompanionCommandDispatcher.swift:234-236`, before calling `groupController.setGroupMuted`, add a guard that the id is in `groupController.groups` — use the same membership expression shape as `applySetMainOut` (`:579-581`, `groupController.groups.contains(where: { $0.id == groupID })`) — returning `.refused("That scene no longer exists on the Mac.")` when it is not. Leave the call-through and `return .ok` otherwise. No comment beyond one short line if the file's style calls for it; the neighbouring cases carry comments only where the reasoning is non-obvious.

4. **Guard `.removeAppRoute`.** In `CompanionCommandDispatcher.swift:241-243`, before calling `appRouting.removeRoute`, add a guard that `appRouting.appRoutes` contains a route whose `bundleID` matches — the same shape as `applyAddAppRoute`'s existing membership check at `:543` (`appRouting.appRoutes.contains { $0.bundleID == bundleID }`) — returning `.refused("That app identifier isn't valid.")` when it does not.

5. **Move the in-flight clear into a `defer`.** In `CompanionCommandDispatcher.swift:275-279`, keep `startBufferApplyInFlight = true` outside the `Task`, and inside the `Task` body make the first statement a `defer` that sets `startBufferApplyInFlight = false`, with the `await applyStartBuffer(ms)` after it and the trailing assignment removed. Behaviour is unchanged on the normal path (fact 11) — this is so no future exit from that body can wedge the flag.

6. **Update the doc comment.** The doc comment at `CompanionCommandDispatcher.swift:171-179` — the one documenting `execute(_ command: CompanionCommand)` at `:181`, whose trust-boundary list runs from "plus the trust-boundary hardening: `Limits` caps, blank/overlong names, unknown-id `updateGroup`, …" — gains the two new refusals in the same voice: an unknown-group `setGroupMuted` and an unrouted-bundle `removeAppRoute`. One clause each, no new paragraph. Do not touch the separate `execute(_:clientID:)` comment at `:185-188`.

### Out of scope — do not touch
- `GroupController.setGroupMuted` and `AppRoutingController.removeRoute` — their silent guards stay; the fix is at the trust boundary only.
- The other unconditional-`.ok` arms in the same switch: `.setAppVolume` (`:249-257`), `.setConnectVolume` (`:259-263`), `.setDeviceSelected` (`:192-193`), `.requestAppIcons` (`:282-288`). Same shape, different tickets — leave every one exactly as it is.
- `applyDeleteGroup`'s deliberate idempotent `.ok` for an already-gone group (`:464-467`).
- This ticket's own file `.scratch/code-review-2026-09-17/issues/07-companion-dispatcher-refusals.md` — do not edit it, and in particular do not flip its `Status:` line.
- Any `AGENTS.md` or `AGENTS-HISTORY.md` entry. Read them, never write them; no documentation entry is wanted for this change.
- Every other refusal string, `Limits`, `CompanionServer`, `DACPServer`, `CastLiveAudioServer`, and the other findings in `.scratch/code-review-2026-09-17/`.
- No `Analytics.capture` or `Telemetry` calls added — no new user-facing action here.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims. No commits, no pushes, no branch work.

### Verification
```bash
bash scripts/run-tests.sh --filter CompanionCommandDispatcher
```
Expected: a line reading `Test run with 66 tests in 1 suite passed` (64 at baseline plus the two new tests). Trust only a `Test run with N tests` line — a filter that matches nothing reports green. If a cached pass is suspected, re-run with `AUDIOUT_TEST_NO_CACHE=1` prefixed.

Pre-change baseline observed in the scoping session: `Test run with 64 tests in 1 suite passed after 0.268 seconds.`

Test seam: `AudioutCore/Tests/AudioutCoreTests/CompanionCommandDispatcherTests.swift:362` (`// MARK: setGroupMuted`) and `:390` (`// MARK: removeAppRoute`). Defects the two new tests catch: the dispatcher replies "applied" to a phone for a scene mute and an app-route removal whose target does not exist on the Mac, so the phone shows a success for a change that never happened.

Step 5 (`defer`) gets no test: `applyStartBuffer` is non-throwing and the `Task` is unstructured with no handle, so nothing a test can see changes (fact 11). Its stand-in check is the existing `setStartBufferMsRefusesWhileApplyInFlight()` at `CompanionCommandDispatcherTests.swift:724`, which must still pass in the run above.

### Execution plan
One track, SERIAL only against itself; nothing else runs.

- **Track A — all six steps.** Files: `AudioutCore/Sources/AudioutCore/CompanionCommandDispatcher.swift`, `AudioutCore/Tests/AudioutCoreTests/CompanionCommandDispatcherTests.swift`.
- **Model:** sonnet. **Effort:** low. Six edits, every literal and guard expression named.
- **Concurrency:** single track — the tests and the source they test are one unit; splitting them buys nothing and the two files are the whole diff.
- Tracked files are unmodified at `a14ff11f`. The one untracked file is this work order itself, written by the scoping step of the pipeline; nothing in Track A depends on it.

### Executor rules (copy verbatim into the handoff prompt)
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
> - Never commit or push. No `.dev` bundle builds, no `scripts/livetest.sh`, no `scripts/make-app.sh`.
> - Only `bash scripts/run-tests.sh` and `bash scripts/build.sh`. Never a bare `swift test`, `swift build`, `swift run`, `xcodebuild`, or `swift package`.
> - A filtered test run that matches nothing reports green. Trust only a line reading `Test run with N tests ... passed`.
