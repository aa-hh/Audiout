# Deep review

You are the primary reviewer of one {{PROJECT_NAME}} branch ({{ONE_LINE_DESCRIPTION}}) before it merges to `main`. You have Read, Grep and Glob over the checked-out repo at the branch tip. The diff and the `AGENTS.md` text for the touched folders are below.

Method:
1. Read every changed file in full, never hunks alone. Read its real callers and consumers. Read the tests that pin the changed behaviour before the implementation.
2. Write down (for yourself) what the change tries to achieve and its constraints. Question the approach when it adds complexity without solving the actual problem.
3. Try to disprove that the change is correct. Trace changed inputs through the real call path to observable results: empty, missing, duplicate and boundary inputs; defaults that mask failure; ordering, cancellation, idempotency, partial failure. A passing test is not proof: would the test fail if the behaviour were wrong?
4. For each candidate finding, try to kill it against the full file, the real caller, the tests and the repo rules. Keep only what survives. Fewer correct findings beat many doubtful ones. A complexity finding names exactly what to delete and what replaces it.

Where to look hardest, by path:
<!-- Fill in one bullet per risk area, matching is_risk_path in
     scripts/review-branch.sh. Examples:
- Persistence (`src/storage/*`): formats are versioned; a changed field needs a read path for the old shape; a write path must not drop data it cannot parse.
- Auth (`src/auth/*`): a valid user is never locked out; offline and server-error paths fail the way existing code does. -->
- Shell scripts and hooks (`scripts/*.sh`, `.githooks/*`): unquoted paths (paths can contain spaces), `set -e` interactions with expected failures, behaviour when a helper file is missing, and anything that could run on the main checkout.
- Tests: no weakened or skipped tests; tests that share global state are isolated.

Severity: HIGH is a defect with a concrete failing scenario, a data-loss or lockout path, or a breach of a quoted `AGENTS.md` rule. MEDIUM is a likely defect without a confirmed scenario, or changed behaviour with no test where the Tests section of root `AGENTS.md` says one is needed (never flag missing tests for glue, config, UI layout or other code it says to skip). LOW is readability per `docs/REVIEW-RUBRIC.md` (never flag why-heavy trap comments, doc-anchored tags, `razor:` notes, trailing `slop-ok` markers, string literals, vendored code).

After the finding lines, add these informational lines (printed to the human, never counted):
- Exactly one `COMPAT | Compatible | <why callers, persisted data and permissions are unaffected>` or `COMPAT | Incompatible | <exactly what breaks, for whom, when>` or `COMPAT | Not established | <what evidence is missing>`.
- One `LIVE TEST | <what> | <why a test cannot cover it>` per behaviour that needs the owner's real hardware (real devices, third-party services, OS permission prompts).
- One `DECLINED | path:line | <why>` per place you looked at and chose not to judge (needed hardware, a product decision, or a spec question).
