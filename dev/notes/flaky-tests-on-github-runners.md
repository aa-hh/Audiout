# Fixing tests that fail only on GitHub's macOS runners

## 1. Root-cause fixes, most valuable first

1. **Pass the clock in; never read wall time in the code under test.** Wrap the system clock so tests can swap it ([Fowler](https://martinfowler.com/articles/nonDeterminism.html)). For `Task.sleep` code, take `any Clock<Duration>` in the initializer: `ContinuousClock` in the app, `TestClock` in tests, moved forward with `advance(by:)` ([swift-clocks](https://github.com/pointfreeco/swift-clocks)). For `DispatchQueue.asyncAfter` code, inject a scheduler (`AnySchedulerOf<DispatchQueue>`, with `.test` or `.immediate` in tests) ([combine-schedulers](https://github.com/pointfreeco/combine-schedulers)). A 100 ms grace timer then becomes "advance 100 ms, assert".
2. **Wait for the condition, not for a fixed time.** No bare sleeps ([Fowler](https://martinfowler.com/articles/nonDeterminism.html)). Best: make the work awaitable (return a `Task` or expose an `async` method) and await it. Next best: poll the condition with a ceiling of seconds, so a slow runner makes the test slower, not red. Swift Testing's `confirmation()` checks its count when the closure returns and does not wait for late events ([source](https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Issues/Confirmation.swift)), so the closure must itself await the callback.
3. **Make ordering explicit.** When queues or actors race, the test picks the order: drain the queue with `sync {}`, await the actor, or step the injected scheduler. `.serialized` only orders tests inside one suite; it does nothing across suites or across the 3 shard processes.
4. **Remove shared state.** Singletons, `UserDefaults.standard`, temp paths with fixed names and static caches let one test change another's result ([Fowler](https://martinfowler.com/articles/nonDeterminism.html)). Give each test its own copy.
5. **Shrink big tests.** Google found flakiness rises with test binary size and memory use ([Google, 2017](https://testing.googleblog.com/2017/04/where-do-our-flaky-tests-come-from.html)). A 150 s test is almost certainly waiting on real time; an injected clock fixes speed and flakiness together.

## 2. What the free macOS runner implies

- macOS arm64 runners for public repositories (`macos-14`, `macos-15`, `macos-26`): 3 cores (M1), 7 GB RAM, 14 GB SSD; no nested virtualization ([GitHub docs](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)). 3 shard processes on 3 cores compete for CPU, so background queues start late.
- Timers never fire early but can fire late, even with no tolerance set ([Apple energy guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)).
- This project's runners have Reduce Motion on and 1x pixel density (found during the #258 work); tests should set these explicitly.
- Swift Testing's `.timeLimit` is in whole minutes only and fails the test when exceeded ([source](https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Traits/TimeLimitTrait.swift)). A hang guard, not a speed check.

## 3. When quarantine or retry is acceptable

- Google: 1.5% of results flaky, 16% of tests flaky at some point, 84% of pass-to-fail transitions were flakes; they rerun and mark failures only after repeated fails ([Google, 2016](https://testing.googleblog.com/2016/05/flaky-tests-at-google-and-how-we.html)). Cost: people learn to ignore red, and real bugs hide behind it.
- Fowler: quarantine only with a cap on its size (his example: 8) or a time limit.
- Acceptable: quarantine with a dated reason and an issue (current repo rule) while a fix is scheduled. Not acceptable: automatic retries that hide failures, or quarantine with no owner. `withKnownIssue(isIntermittent: true)` keeps the test running and recorded, which beats skipping it.

## 4. Checklist for a flaky test

1. Does the code under test read real time or sleep? Inject a clock or scheduler.
2. Does the test sleep, then assert? Await the event, or poll with a ceiling of seconds.
3. Do two queues or actors race? Make the test choose the order.
4. Does it touch shared state? Give it its own copy.
5. Quarantined? Dated reason, issue, and a cap on the quarantine list.
