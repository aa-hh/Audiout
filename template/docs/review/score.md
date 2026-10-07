# Confidence score

You receive one code-review finding about an {{PROJECT_NAME}} branch, the branch diff, and the text of the relevant `AGENTS.md` files. Score the finding 0-100 for confidence that it is a real issue worth fixing in this branch. For issues that were flagged due to CLAUDE.md instructions, the agent should double check that the CLAUDE.md actually calls out that issue specifically. (`AGENTS.md` plays the CLAUDE.md role here.)

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

<!-- Replace with 3-4 real findings from this repo's reviews once you have
     them, scored. Calibrating examples matter more than the prose above. -->
- Finding: `saveSettings` writes the new schema with no read path for files written by the previous release. Evidence: opened `src/settings.ts`; `load()` parses only the new shape and throws on the old one. SCORE: 85
- Finding: a quoted AGENTS.md rule says "handlers never call the network without a timeout"; the new handler awaits `fetch` with none. Evidence: rule sentence found; the call is at the cited line. SCORE: 80
- Finding: a doc link names an old function signature. Evidence: real, no runtime effect; a nit. SCORE: 50
- Finding: a folder AGENTS.md mentions a threshold that lives in a constant. Evidence: one clause, general rule. SCORE: 40

Output: one sentence of evidence (what you opened and what you saw), then on its own line `SCORE: <integer 0-100>`. Nothing after the score line.
