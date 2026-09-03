# Roadmap 074 — scoped work order (scope-and-run pipeline, Fable)

Status: **scoping complete, zero implementation done.** Working tree clean at `4d500023` on branch `claude/foreman-roadmap-074-scope-run-82246b`, already pushed. A resuming session should skip Step 1 (Scope) of `~/.claude/skills/scope-and-run/SKILL.md` and start directly at Step 2 (Execute), using this file verbatim as the work order.

---

## Goal

Land the seven items roadmap entry 074 lists: five stale prose/comment claims left behind when `AudioutCore/Tests` went Swift-Testing-only, the Xcode-path hint in `scripts/run-tests.sh` that would tell a Mac with both Xcodes to select the beta, and a `scripts/lib/remote.sh` change so a remote run that cannot work (Command Line Tools selected there) is refused up front, and a remote run that did fail says *what kind* of failure it was (which tests, a build that never finished, or a test process that died) instead of one anonymous "remote reported FAILURES — re-running locally". The audience is every agent whose build and test runs go through these two scripts; the full-suite baseline this session hit exactly the anonymous case (remote test process died with a signal after 3294 passes, transcript said only "FAILURES").

## Verified facts

Tree: branch `claude/foreman-roadmap-074-scope-run-82246b`, clean at `4d500023`. No uncommitted work anywhere; isolated worktrees forking from HEAD see everything.

Request claims that are WRONG (report these in the final message; the pipeline records them in the entry's notes):
- "both Macs are on 27A5252f": local is macOS 27.0 build 26A5388g; remote is macOS 26.5.2 build 25F84. Both run the identical compiler `Apple Swift version 6.4 (swiftlang-6.4.0.33.1)`; SDK targets differ (local `macosx27.0.0`, remote `macosx26.0`). Both select `/Applications/Xcode-beta.app`; neither has `/Applications/Xcode.app`.
- Every cited line number has drifted; current numbers are below.
- Item (4)'s proof recipe assumes `Xcode.app` is the installed one; here only `Xcode-beta.app` exists, so the fake directory to create is `/Applications/Xcode.app` (writable without sudo: `/Applications` is `drwxrwxr-x root:admin`, user is admin).

Prose/comment targets (all at HEAD `4d500023`):
- `docs/notes/swift-testing-conversion-cookbook.md:788-789` — "The two bases expose an **identical** member set over the same mechanism, so migrating is a base-class swap and nothing else:" under the one-base table at :781-784. BEFORE/AFTER code blocks follow at :790-806.
- `docs/notes/swift-testing-conversion-cookbook.md:826-827` — "**Done** (the T20 cleanup item): the legacy XCTest base and the file's `import XCTest` are deleted. `git grep IsolatedTestCase` finds nothing."
- `git grep -n IsolatedTestCase -- '*.swift'` → no matches (exit 1). `git grep -n IsolatedTestCase` (all files) → 34 lines in 14 files, all prose.
- `AudioutCore/Tests/AudioutCoreTests/AudioHardwareTestGate.swift:77-80` — the bullet beginning "`makeStartedEngine()` (and any other shared helper) moves into the nested suite ... its `try AudioHardwareTestGate.skipUnlessEnabled()` line is deleted". `skipUnlessEnabled` has no Swift declaration or caller anywhere (`git grep -n skipUnlessEnabled` → only comments/docs). Line 41 is past tense; leave it.
- `AudioutCore/Sources/AudioutCore/HeadlessRuntime.swift:32-38` — "This matters because this repo's suites are migrating from XCTest to swift-testing: today `swift test` still drags `XCTest` in as long as ANY file in the target imports it, but once the last `import XCTest` is gone ... Both checks are kept: mid-migration either one fires, end-state the swift-testing one does, and a legacy XCTest-only target still works."
- `AudioutCore/Tests/AudioutCoreTests/HeadlessRuntimeTests.swift:21-26` — "The migration-proofing case. While XCTest is still linked from the not-yet-converted suites ... only surface once the last `import XCTest` is deleted ...". Line 35's `#expect` message ends "since the migration removes it".
- `git grep -n 'import XCTest' -- '*.swift'` → only those three comment lines; no Swift file imports XCTest.

Shell targets:
- `scripts/run-tests.sh:55-73` — engine-pin comment claiming the two machines disagree on engines ("the remote's Swift 6.3.1 does not carry that engine"), with a `razor:` block at :68-72 saying the remote is "pinned to macOS 26, so it cannot reach a toolchain where swiftbuild exists". `engine="--build-system native"` at :73.
- `scripts/run-tests.sh:75-80` — CLT comment ending "Local check only — the remote path is out of scope."
- `scripts/run-tests.sh:81-96` — the local CLT fail-fast: `case "$selected_devdir"` on `/Library/Developer/CommandLineTools*`, `exit 78`. Line 87: `xcode_app=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)`; :88-93 print the Fix hint.
- `scripts/run-tests.sh:168-177` — rc=2 branch; comment at :170-174 says "A machine on a different Swift/SDK must never be what REFUSES a commit"; :175 prints `  suite: remote reported FAILURES — re-running locally to confirm.`
- `scripts/lib/remote.sh:38-43` — `remote_toolchain` (default `swift`); `scripts/ios.sh:292` sets it to `xcodebuild`.
- `scripts/lib/remote.sh:204-208` — "The toolchains differ (local Swift 6.4 / macOS 27 SDK vs remote 6.3.1 / macOS 26), so callers accept a remote PASS but re-confirm a remote FAILURE locally".
- `scripts/lib/remote.sh:230-233` — comment: "Exit 97 is a private sentinel for 'the remote ENVIRONMENT is wrong' (directory missing, no toolchain)".
- `scripts/lib/remote.sh:246` — `command -v $remote_toolchain >/dev/null 2>&1 || exit 97; \` inside the ssh command string (:243-256).
- `scripts/lib/remote.sh:263` echoes all remote output to stderr; :264 parses `REMOTE_EXIT:`; :266-269 handle rc 97 with message "environment not usable (missing dir or toolchain) — staying local."; :285-287 set `remote_status`, `return 0` on zero, else `return 2`. `remote_status` is read by `scripts/ios.sh:326,335-336` (only to test emptiness / print the code).
- `scripts/build.sh:49-55` — rc=2 comment with "the toolchains differ (local Swift 6.4 / macOS 27 SDK vs remote 6.3.1 / macOS 26)" at :50-51. `scripts/build.sh:31-38` is the native pin — leave.
- `scripts/make-app.sh:320-325` — rc=2 comment with the same stale text at :322-323. `scripts/make-app.sh:334+` is its native pin — leave.

Behaviour facts for the remote gate (probed on the remote this session):
- With `DEVELOPER_DIR=/Library/Developer/CommandLineTools`: `command -v swift` → `/usr/bin/swift` (the current gate passes); `xcrun --show-sdk-platform-path` → exit 1 (`unable to lookup item 'PlatformPath'`). Without it → prints `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform`, exit 0. Same on the local Mac.

Output-format facts (from this session's runner logs over the `ssh -tt` tty):
- Swift Testing per-test lines arrive as `<SF Symbols private-use glyph>  Test isActiveUnderXCTest() passed after 0.001 seconds.` and the summary as `Test run with 3 tests in 1 suite passed after 0.001 seconds.` No `✔`/`✘` characters. SwiftPM's own lines carry ANSI codes (`ESC[2K`, `ESC[33mESC[1mwarning: ESC[0m`), and the compile-failure `error: ` word is likewise colour-wrapped.
- `Build complete! (117.09s)` is printed by SwiftPM once compilation succeeds (string present in `swift-build` binary). A build that fails prints no such line.
- The full-suite baseline's remote arm: 3294 `passed after` lines, zero `failed after` lines, no `Test run with` summary, then `Note: Some test targets reported failures:` and `error: Process '.../swiftpm-testing-helper ...' exited with unexpected signal co...` — the test process died mid-run.
- Swift Testing's failure line is the counterpart of the passing one: `Test NAME failed after N seconds with M issue(s).` (not observed this session; the failing-test demo in Verification confirms it).

Runner/environment facts:
- `sh -n` on all four scripts → exit 0 (baseline).
- Hooks: a full-suite run needs `AUDIOUT_FULL_SUITE=1`; any command whose text contains a bare `swift test` or `swift build` is blocked, even inside an `ssh` string or outside the repo.
- Git config: `audiout.remoteHost=alechamilton@SUMUP-M9Y197RFVG.local`, `audiout.testPrefer=remote`, `remoteSlots=3`, `localSlots=3`. Remote disk 61 GB free; 24 remote trees.
- Local free disk: 15 GB (housekeeping is already reclaiming caches under the 15 GB floor). A cold local fallback build costs ~135 s and ~1.3 GB.
- Guard 7 (`.githooks/guard-self-review.sh:31-34,49-54`) scans added `*.swift` comment lines: hard-blocks `this session`, `(fixed|added|updated|revised|corrected) 20YY`, `// =====` banners; warns on `Previously`, `used to be/have/…`, `no longer exists/needed`, `replaces the old/removed/retired/deleted`, `as of 20YY`. Nobody commits here, but the merge will; keep the Swift comment rewrites clear of all of these.

Baselines observed:
- `DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/run-tests.sh --filter HeadlessRuntimeTests` → exit 78, hint `Fix: sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer`.
- `bash scripts/run-tests.sh --filter HeadlessRuntimeTests` → `suite: passed on remote ...`, 3 tests, exit 0.
- `AUDIOUT_FULL_SUITE=1 bash scripts/run-tests.sh` → remote arm died mid-run (above), `suite: remote reported FAILURES — re-running locally to confirm.`, local: `Test run with 3472 tests in 199 suites passed after 156.458 seconds.`, exit 0.

## Decisions (made by the scoper, not for the executor to re-decide)

- D1. On a remote failure, callers still re-run locally exactly as today (the SDKs still differ, so an API-availability error there can be skew). The change is one classification line printed by `remote_run` immediately before `return 2`, in the same `  remote: ...` voice as its other lines. `run-tests.sh:175`, `build.sh:55`, `make-app.sh:326` keep their existing fallback lines unchanged. No new return code.
- D2. The `xcrun --show-sdk-platform-path` probe is added beside `command -v $remote_toolchain`, not in place of it (`ios.sh` relies on `remote_toolchain=xcodebuild`).
- D3. Classification keys on plain text, never on glyphs or colour codes, in this order: (a) any `Test <name> failed after` line (excluding `Test run with ...`) → failing tests, names listed; (b) else no `Build complete!` anywhere in the output → build did not finish; (c) else → no test verdict, with the count of `passed after` lines.
- D4. Comments say "both Macs run Swift 6.4" and "SDK macOS 27 here, macOS 26 there"; never an OS build number.
- D5. Item (4): `/Applications/Xcode.app` is preferred when that directory exists; otherwise the existing glob-plus-`head -1` stays as the fallback.
- D6. Nobody edits `ROADMAP.jsonl`; discrepancies go in the executor's final message.
- D7. Test names and `@Test` bodies stay untouched; only the doc comment and the line-35 message string in `HeadlessRuntimeTests.swift` change.

## Steps

### Track A — prose (four files)

1. `docs/notes/swift-testing-conversion-cookbook.md:788-789`: replace the two-line sentence with past tense — `IsolatedSuite` exposed the same members as the legacy `IsolatedTestCase` base, so each migration was a base-class swap and nothing else. Keep the trailing colon and the BEFORE/AFTER blocks at :790-806 untouched.
2. Same file, :826-827: replace the last sentence "`git grep IsolatedTestCase` finds nothing." with: no Swift declaration named `IsolatedTestCase` remains — `git grep IsolatedTestCase -- '*.swift'` finds nothing; the name survives only in prose and plans. Keep the rest of the bullet.
3. `AudioutCore/Tests/AudioutCoreTests/AudioHardwareTestGate.swift:77-80`: delete that one bullet (four lines, from "///  - `makeStartedEngine()` (and any other shared helper)" through "already made that decision by the time the body runs."). The bullets before and after stay; line 41 stays.
4. `AudioutCore/Sources/AudioutCore/HeadlessRuntime.swift:32-38`: rewrite the part of the swift-testing bullet from "This matters because" to the end of the bullet (:38) in the present tense. Content to keep, in this order: the test target is Swift-Testing-only, so nothing in it imports XCTest and `swift test` does not load that framework; without this `dlsym` check a test run would go undetected and real, empty windows would flash on the developer's screen for the run's duration; the XCTest check stays so a legacy XCTest-only target still works. Do not claim `isXCTestLoaded` is false under `swift test` (unverified). Lines 28-31 stay.
5. `AudioutCore/Tests/AudioutCoreTests/HeadlessRuntimeTests.swift:21-26`: rewrite the doc comment's first paragraph in the present tense: the suites are Swift-Testing-only, so `isSwiftTestingLoaded` is the limb `isActive` must be able to stand on without XCTest; asserting it directly means a broken swift-testing check fails here rather than surfacing as real windows flashing on screen during every `swift test` run. Keep the "Mechanism:" paragraph (:28-32) as is. On line 35, change the message tail "since the migration removes it" to "since nothing in the test target imports it" (NOT "no longer removes it" — Guard 7 warns on "no longer"). Test names, attributes and `#expect` conditions unchanged.

### Track B — shell (four files)

6. `scripts/run-tests.sh:55-73`, the engine-pin comment: rewrite so the stated reason is (i) the same reason `scripts/build.sh:31-38` gives — the default `swiftbuild` engine does not forward a C target's `cSettings` unsafeFlags into the clang module scan, so `import CAirPlayEngine` fails — and (ii) the two engines keep separate `.build` trees (~1.3 GB each), so an unpinned test run beside the pinned `build.sh`/`make-app.sh` doubles every worktree's cache (10 of 33 worktrees once held both). Remove every claim that the machines disagree on engines or that the remote lacks one; both run Swift 6.4. Keep a `razor:` block: `native` is deprecated in Swift 6.4; the ceiling is `swiftbuild`'s unsafeFlags forwarding; upgrade path: when `swiftbuild` builds `AirPlayEngine`, move `run-tests.sh`, `build.sh` and `make-app.sh` together. Line 73 (`engine=...`) unchanged.
7. `scripts/run-tests.sh:79-80`: replace "Local check only — the remote path is out of scope." with a pointer that the remote twin is `remote_run`'s exit-97 gate in `lib/remote.sh`.
8. `scripts/run-tests.sh:87`: replace the single `ls ... | head -1` assignment with: if the directory `/Applications/Xcode.app` exists, `xcode_app` is `/Applications/Xcode.app`; otherwise `xcode_app` is the existing glob expression's first result. Plain `if [ -d ... ]`, POSIX `sh` only. Add a one-line comment saying why: the glob sorts `Xcode-beta.app` ahead of `Xcode.app` (`-` sorts before `.`), so a Mac with both was told to select the beta. Lines 88-95 unchanged.
9. `scripts/run-tests.sh:170-174`: in the rc=2 comment, replace "A machine on a different Swift/SDK must never be what REFUSES a commit" with wording that names the real reasons: the remote's SDK differs (macOS 26 there, 27 here) and that shared machine has been out of disk and starved before, so it must never be what refuses a commit. Line 175's echo unchanged.
10. `scripts/lib/remote.sh:205-206`: replace "The toolchains differ (local Swift 6.4 / macOS 27 SDK vs remote 6.3.1 / macOS 26), so" with: both Macs run Swift 6.4 but against different SDKs (macOS 27 here, macOS 26 there), and the remote has been out of disk and starved before, so. Rest of the paragraph unchanged.
11. `scripts/lib/remote.sh:246`: after the existing `command -v $remote_toolchain ... || exit 97; \` clause, add a sibling clause that runs `xcrun --show-sdk-platform-path >/dev/null 2>&1 || exit 97;` with the same line-continuation shape. Extend the comment at :230-233 with the reason: `/usr/bin/swift` exists under Command Line Tools, so `command -v` cannot see a CLT-selected remote; `xcrun --show-sdk-platform-path` is what SwiftPM calls before running any test bundle and it fails under CLT — the remote twin of `run-tests.sh`'s exit-78 check.
12. `scripts/lib/remote.sh:267`: change the exit-97 message to exactly `  remote: environment not usable (missing dir, no toolchain, or Command Line Tools selected instead of Xcode) — staying local.`
13. `scripts/lib/remote.sh:285-287`: between `remote_status="$_marker"` and the final `return 2`, classify `$_out` per D3 and print exactly one line, then return 2 as before. The three messages (literals are the decision; `<...>` filled in):
    - `  remote: ran and FAILED there — <N> test(s) failed: <names, space-separated>`
    - `  remote: ran and FAILED there — the build did not finish (no "Build complete!" line); the compiler errors are in the output above`
    - `  remote: ran and FAILED there — exit <remote_status>, no test verdict in the output (<P> tests passed, no failure lines, no summary line)`
    Name extraction: from each line containing ` Test ` and ` failed after `, take the text between `Test ` and ` failed after `; skip lines whose extracted text starts with `run with`. Match on those words only — the glyph bytes and ANSI codes before/around them must not be part of any pattern. `<P>` is the count of lines containing ` passed after `. POSIX `sh` + `grep`/`sed`/`wc` only; no arrays, no `[[ ]]`. Add a short comment above naming the observed case this exists for (test process died mid-run; the caller only saw "FAILURES").
14. `scripts/build.sh:50-51`: same substitution as step 10 in that comment. Lines 31-38 untouched.
15. `scripts/make-app.sh:322-323`: same substitution as step 10 in that comment. Lines 334+ untouched.

## Out of scope — do not touch

- `scripts/build.sh:31-38` and `scripts/make-app.sh:334+` (native-engine pins), `AudioHardwareTestGate.swift:41`.
- Any change to what tests run or do: no renaming `isActiveUnderXCTest`, no editing `#expect` conditions, no `--num-workers`, no change to `AUDIOUT_TEST_MODE=serial`, no change to the exit-78 check beyond step 8.
- No new `remote_run` return code; no change to the local re-run after a remote failure (D1). No edits to the fallback echo lines in the three callers.
- `scripts/ios.sh` (its "different Xcode versions" comment at :295-296 is stale too — leave it, say so in the final message). `scripts/housekeeping.sh`. `AudioutCore/AGENTS-HISTORY.md:721-723` (archive, never maintained). Cookbook lines :387-411 and :869-895 (migration record; they describe the conversion as it happened).
- `ROADMAP.jsonl`, any AGENTS.md, `docs/REVIEW-RUBRIC.md`.
- No cleanup, no abstractions, no shared helper functions for the classifier, no error handling for cases not listed, no backwards-compat shims, no reformatting of surrounding comment blocks.
- Never `sudo xcode-select` on either machine; never change the remote's selected developer directory.
- Nobody commits or pushes (the pipeline merges). If the runner must commit to merge: write the message to a file and use `git commit -F` (the hooks scan heredoc text).

## Verification

Cheap checks (also fine inside Track B before merge):

1. `sh -n scripts/run-tests.sh && sh -n scripts/lib/remote.sh && sh -n scripts/build.sh && sh -n scripts/make-app.sh; echo rc=$?` → no output, `rc=0`. Baseline: same.
2. `git grep -n IsolatedTestCase -- '*.swift'; echo rc=$?` → no matches, `rc=1`. Baseline: same.
3. Item (4), both branches. `mkdir /Applications/Xcode.app` (no sudo needed), then `DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/run-tests.sh --filter HeadlessRuntimeTests; echo rc=$?` → the CLT refusal, `Fix: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, `rc=78`. Then `rmdir /Applications/Xcode.app` and re-run the same command → `Fix: sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer`, `rc=78`. Baseline before the change: the beta path, `rc=78` (only Xcode-beta exists, so the bug is only visible with the fake directory present). Confirm `ls -d /Applications/Xcode.app` fails afterwards.
4. Item (6) gate predicate on the real remote, without changing its state (do not put the words "swift build"/"swift test" in this command; the hook blocks them):
   `ssh -o BatchMode=yes "$(git config --get audiout.remoteHost)" 'export DEVELOPER_DIR=/Library/Developer/CommandLineTools; command -v swift; xcrun --show-sdk-platform-path >/dev/null 2>&1; echo xcrun-under-clt-rc=$?; unset DEVELOPER_DIR; xcrun --show-sdk-platform-path >/dev/null 2>&1; echo xcrun-normal-rc=$?'`
   → `/usr/bin/swift`, `xcrun-under-clt-rc=1`, `xcrun-normal-rc=0`. Baseline: identical (this proves the old gate passes under CLT and the new clause refuses).

Once, on the combined tree (these take the machine-wide lock and the remote slots; do not duplicate per track):

5. `bash scripts/build.sh; echo rc=$?` → `build: compiled clean on remote ...` (or a local compile), `rc=0`.
6. Failing-test demo (proves the names line and confirms the `failed after` shape). Create `AudioutCore/Tests/AudioutCoreTests/ZZClassifierDemoTests.swift` containing one `@Suite struct ZZClassifierDemoTests` with one `@Test func failsOnPurpose()` whose body is `#expect(1 == 2)` (imports: `Testing`). Run `bash scripts/run-tests.sh --filter ZZClassifierDemoTests; echo rc=$?`. Expected transcript, in order: `suite: sending to remote ... (preferred)`, the remote's own output including a line ending `Test failsOnPurpose() failed after ... with 1 issue.`, then exactly `  remote: ran and FAILED there — 1 test(s) failed: failsOnPurpose()`, then `suite: remote reported FAILURES — re-running locally to confirm.`, then the local failure and `suite: FAILED — swift test exited 1`, `rc=1`. If the remote's failure line is shaped differently from `Test NAME failed after`, adjust step 13's pattern to what was actually printed and say so. Then `rm` the demo file.
7. Compile-error demo (proves the "build did not finish" line). Create the same file path containing only `import Testing` and one unterminated line, e.g. `@Suite struct ZZClassifierDemoTests {` with no closing brace. Run `bash scripts/run-tests.sh --filter HeadlessRuntimeTests; echo rc=$?`. Expected: compiler `error:` lines from the remote, no `Build complete!`, then exactly `  remote: ran and FAILED there — the build did not finish (no "Build complete!" line); the compiler errors are in the output above`, then `suite: remote reported FAILURES — re-running locally to confirm.`, the local compile error, `suite: FAILED — swift test exited 1`, `rc=1`. Then `rm` the demo file and confirm `git status --short` shows no `ZZ` file.
8. `AUDIOUT_FULL_SUITE=1 bash scripts/run-tests.sh; echo rc=$?` → a `Test run with 3472 tests in 199 suites passed after ...` line (exact count may move by a few) and `rc=0`. Baseline: remote arm died mid-run, local re-run passed 3472/199, `rc=0`. If the remote arm dies again, the new line `  remote: ran and FAILED there — exit 1, no test verdict in the output (<P> tests passed, no failure lines, no summary line)` must appear before the local re-run; that is the fix working, not a failure.
9. `git status --short` → exactly these eight modified files and nothing else: `docs/notes/swift-testing-conversion-cookbook.md`, `AudioutCore/Tests/AudioutCoreTests/AudioHardwareTestGate.swift`, `AudioutCore/Sources/AudioutCore/HeadlessRuntime.swift`, `AudioutCore/Tests/AudioutCoreTests/HeadlessRuntimeTests.swift`, `scripts/run-tests.sh`, `scripts/lib/remote.sh`, `scripts/build.sh`, `scripts/make-app.sh`.

If the remote is unreachable during 6-8 (`remote: unreachable ... staying local`), say so explicitly in the final message: items (6)'s demos are then unverified, not passed.

## Execution plan

No uncommitted work on the branch; worktrees fork from `4d500023`.

- Track A — prose. Steps 1-5. Files: `docs/notes/swift-testing-conversion-cookbook.md`, `AudioutCore/Tests/AudioutCoreTests/AudioHardwareTestGate.swift`, `AudioutCore/Sources/AudioutCore/HeadlessRuntime.swift`, `AudioutCore/Tests/AudioutCoreTests/HeadlessRuntimeTests.swift`. Model: sonnet. Effort: low. PARALLEL. In-track check: `git grep -n IsolatedTestCase -- '*.swift'` still empty; no other check needed (a comment-only Swift change is covered by the combined build/suite).
- Track B — shell. Steps 6-15, sliced by file so no shell file is shared with any other track: items (4)+(7) both land in `run-tests.sh` here, items (6)+(7) both land in `remote.sh` here. Files: `scripts/run-tests.sh`, `scripts/lib/remote.sh`, `scripts/build.sh`, `scripts/make-app.sh`. Model: opus. Effort: medium. PARALLEL. In-track checks: Verification 1, 3, 4 (cheap, no lock).
- Combined verification, once after merge: Verification 2, 5, 6, 7, 8, 9 (5-8 take the machine-wide lock and the remote slots; run them serially, 6 before 7 so the local `.build` is warm when the compile demo falls back). Local disk is at 15 GB free; check `df -g /` before step 8 and report if housekeeping cannot hold the floor.

## Executor rules (copy verbatim into the handoff prompt)

- Follow the steps in order. Do not add, merge, reorder, or skip steps.
- Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them. Here: `AGENTS.md`, `AudioutCore/AGENTS.md`, `AudioutCore/Sources/AudioutCore/AGENTS.md`; `scripts/` and `docs/` have none.
- Never run a bare `swift build` or `swift test`, in any directory or inside an `ssh` string — always `bash scripts/build.sh` / `bash scripts/run-tests.sh`; the full suite needs `AUDIOUT_FULL_SUITE=1`.
- Nobody commits or pushes. Leave every change uncommitted in the working tree. Never edit `ROADMAP.jsonl`.
- If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
- Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
- "Done" means the Verification commands were run in this session and passed. Paste their output.
- Touch nothing in the Out-of-scope list.
- Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
- Final message must list the request discrepancies found (OS builds 26A5388g local / 25F84 remote, not 27A5252f; drifted line numbers; `Xcode-beta.app` is the installed one) and the stale `scripts/ios.sh:295-296` comment left untouched.

---

## How to resume this (for the next agent/session)

1. Load `~/.claude/skills/scope-and-run/SKILL.md`.
2. Skip Step 1 (Scope) and Step 1.5 entirely — this file **is** the scoper's output.
3. Start at **Step 2 — Execute**, following this file's Execution plan: create `.claude/worktrees/<slug>` for Track A and Track B from HEAD `4d500023` (confirm HEAD hasn't moved first — `git log --oneline -1`), push each, launch two `work-order-executor` agents in one message with this file's content as their prompt plus "Your track: steps 1-5" / "Your track: steps 6-15" respectively, model/effort per the Execution plan.
4. Continue through Step 3 (Judge), Step 4 (Review — required here: 2 tracks + shared build/test infra) exactly as the skill describes.
5. On approval, mark roadmap entry 074 `done` per the standard staged-commit close (see the entry's own notes for the exact command), with `Foreman: 074` as the commit's final line.
