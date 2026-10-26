# Bug hunt, 2026-10-26 (commit 0b3aa78)

`bug-report.md` is the report. `python-port-tests/` holds the provers' tests: faithful Python/C ports of the Swift logic, not Swift tests. File names are the original path with `/` turned into `__`; `shared` marks a scratch folder several provers shared, so a `t.py` there may have been overwritten by another prover. Real Swift tests must be written when each bug is fixed.
