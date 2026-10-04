# Confidence score

You receive one code-review finding about an Audiout branch, the branch diff, and the text of the relevant `AGENTS.md` files. Score the finding 0-100 for confidence that it is a real issue worth fixing in this branch. For issues that were flagged due to CLAUDE.md instructions, the agent should double check that the CLAUDE.md actually calls out that issue specifically. (`AGENTS.md` plays the CLAUDE.md role here.)

The scale (from Anthropic's code-review plugin, verbatim):
a. 0: Not confident at all. This is a false positive that doesn't stand up to light scrutiny, or is a pre-existing issue.
b. 25: Somewhat confident. This might be a real issue, but may also be a false positive. The agent wasn't able to verify that it's a real issue. If the issue is stylistic, it is one that was not explicitly called out in the relevant CLAUDE.md.
c. 50: Moderately confident. The agent was able to verify this is a real issue, but it might be a nitpick or not happen very often in practice. Relative to the rest of the PR, it's not very important.
d. 75: Highly confident. The agent double checked the issue, and verified that it is very likely it is a real issue that will be hit in practice. The existing approach in the PR is insufficient. The issue is very important and will directly impact the code's functionality, or it is an issue that is directly mentioned in the relevant CLAUDE.md.
e. 100: Absolutely certain. The agent double checked the issue, and confirmed that it is definitely a real issue, that will happen frequently in practice. The evidence directly confirms this.

Verify before you score. Open the cited file at the cited line with Read (paths in the diff are relative to the worktree you are running in) and read the functions the finding names, including ones the diff does not show. A line being absent from the diff is not evidence against the finding; "the lines are not visible in the diff" is never a reason for a low score. When the finding quotes an `AGENTS.md` rule, find that sentence in the `AGENTS.md` text below.

False positives score low: pre-existing issues; something that looks like a bug but is not; pedantic nitpicks a senior engineer wouldn't call out; anything a compiler, typechecker or linter would catch; general code-quality complaints not required by an `AGENTS.md`; issues silenced in the code on purpose; changes that are clearly intentional; real issues on lines the branch did not modify.

Findings at 75 or above are kept; below 75 they are dropped.

## Examples

Four findings from the 2026-10-03 reviews, scored.

- Finding: `BTSyncedSink.realignToDevicePulls` applies a forward seek with no `seekSafetyMarginMs` clamp, while `applyTrimDelta` clamps every forward seek 100 ms short of the write pointer. Evidence: both functions read; the unclamped call is `delayLine.shift(byFrames:)`; a stall can drain the ring and drop out. SCORE: 85
- Finding: `reanchorIfTrimClamped()` rebuilds the sink on a committed trim. Evidence: `AudioutCore/Sources/AudioutCore/AGENTS.md` says "A Bluetooth trim is a ring seek and must never clear session state"; the function calls `requestRebuild(cause: "trim_clamped")`. SCORE: 80
- Finding: doc links ``btOnlyReferenceMs(latencies:uids:)`` no longer resolve after the signature became `latencies:trims:uids:`. Evidence: real, no runtime effect; a nit a senior engineer might fix in passing. SCORE: 50
- Finding: a folder `AGENTS.md` is over its word budget and hard-codes a 20 ms threshold that lives in a constant. Evidence: the budget rule exists but is general; the number is one clause. SCORE: 40

Output: one sentence of evidence (what you opened and what you saw), then on its own line `SCORE: <integer 0-100>`. Nothing after the score line.
