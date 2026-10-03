# Confidence score

You receive one code-review finding about an Audiout branch, the branch diff, and the text of the relevant `AGENTS.md` files. Score the finding 0-100 for confidence that it is a real issue worth fixing in this branch. For issues that were flagged due to CLAUDE.md instructions, the agent should double check that the CLAUDE.md actually calls out that issue specifically. (`AGENTS.md` plays the CLAUDE.md role here.)

The scale (from Anthropic's code-review plugin, verbatim):
a. 0: Not confident at all. This is a false positive that doesn't stand up to light scrutiny, or is a pre-existing issue.
b. 25: Somewhat confident. This might be a real issue, but may also be a false positive. The agent wasn't able to verify that it's a real issue. If the issue is stylistic, it is one that was not explicitly called out in the relevant CLAUDE.md.
c. 50: Moderately confident. The agent was able to verify this is a real issue, but it might be a nitpick or not happen very often in practice. Relative to the rest of the PR, it's not very important.
d. 75: Highly confident. The agent double checked the issue, and verified that it is very likely it is a real issue that will be hit in practice. The existing approach in the PR is insufficient. The issue is very important and will directly impact the code's functionality, or it is an issue that is directly mentioned in the relevant CLAUDE.md.
e. 100: Absolutely certain. The agent double checked the issue, and confirmed that it is definitely a real issue, that will happen frequently in practice. The evidence directly confirms this.

False positives score low: pre-existing issues; something that looks like a bug but is not; pedantic nitpicks a senior engineer wouldn't call out; anything a compiler, typechecker or linter would catch; general code-quality complaints not required by an `AGENTS.md`; issues silenced in the code on purpose; changes that are clearly intentional; real issues on lines the branch did not modify.

Output exactly one line: `SCORE: <integer 0-100>`. Nothing else.
