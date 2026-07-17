#!/usr/bin/env python3
"""Warn when an AGENTS.md change names a code symbol the SAME COMMIT doesn't contain.

WHY THIS EXISTS
---------------
This repo's most expensive failure (f1f3e94, 2026-07-17) committed 5 AGENTS.md
files and zero .swift files straight onto main, documenting a feature whose code
was stashed twelve minutes later and never landed. For a day, main's docs
described `appRouteTargets` / `redirectOutputIDs()` / `reapplyRouting()` /
`routedAppNames(for:)` — symbols present in ZERO .swift files — and agents read
them as truth. Root AGENTS.md now carries the hard rule: docs never reach main
ahead of their code.

WHAT THIS COMPARES AGAINST — read before changing it
----------------------------------------------------
The oracle is THE COMMIT BEING CREATED (the staged index), and that choice is
load-bearing. The two obvious alternatives are both wrong:

  * Against `main`  — WRONG. Every worktree legitimately holding docs+code that
    hasn't merged yet would be told it's lying. That teaches agents the warning
    is noise, which is worse than having no check. Truth-in-an-unmerged-worktree
    is TRUE; this hook must never say otherwise.
  * Against the WORKING TREE — USELESS. It would have passed f1f3e94, whose code
    was sitting right there unstaged at commit time and got stashed afterward.

Against the staged index, f1f3e94 fires (it staged no .swift, so the symbols are
absent from the tree it created) and honest worktree work passes (it stages docs
and code together, so the symbols are present). That is exactly the line we want.

This NEVER blocks — it always exits 0. It is a nudge, not a gate. A false
positive costs one ignored line; a false negative costs a session.
"""

from __future__ import annotations

import re
import subprocess
import sys

# A backticked span is a candidate only if it survives all of these. The filters
# are deliberately conservative: this hook's credibility dies on false positives,
# so when in doubt we stay silent. Prose in backticks (`main`, `Selected`,
# `ENABLED`), shell (`swift test`), paths (`app-routes.json`) and env
# (`AIRPLAY_BACKEND=mock`) must all fall out here.
_DISQUALIFYING = set(" \t/=,<>\"'\\|$*#!?;{}[]&+%@~^")

_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_CAMEL_HUMP = re.compile(r"[a-z][A-Z]")
_BACKTICKED = re.compile(r"`([^`\n]+)`")

MIN_LEN = 4


def _normalize(raw: str) -> str | None:
    """Reduce a backticked span to a bare identifier, or None if it isn't one.

    `reapplyRouting()`        -> reapplyRouting
    `routedAppNames(for:)`    -> routedAppNames
    `.selectedDevices`        -> selectedDevices
    `GroupController.groups`  -> None (dotted paths are ambiguous; skip)
    """
    s = raw.strip()
    if not s or any(ch in _DISQUALIFYING for ch in s):
        return None
    # Drop a call suffix: name(...) / name()
    paren = s.find("(")
    had_parens = paren != -1
    if had_parens:
        if not s.endswith(")"):
            return None
        s = s[:paren]
    s = s.lstrip(".")
    if "." in s:  # dotted member paths and filenames (Device.swift) — skip
        return None
    if not _IDENT.match(s) or len(s) < MIN_LEN:
        return None
    # Must LOOK like code: a camelCase/PascalCase hump, or an explicit call form.
    # This is what rejects `main`, `Volume`, `Selected`, `ENABLED`, `System`.
    if not (had_parens or _CAMEL_HUMP.search(s)):
        return None
    return s


def added_symbols(diff_text: str) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for line in diff_text.splitlines():
        if not line.startswith("+") or line.startswith("+++"):
            continue
        for raw in _BACKTICKED.findall(line[1:]):
            sym = _normalize(raw)
            if sym and sym not in seen:
                seen.add(sym)
                out.append(sym)
    return out


def _run(args: list[str]) -> tuple[int, str]:
    p = subprocess.run(args, capture_output=True, text=True)
    return p.returncode, p.stdout


_STEMS_CACHE: dict[str, set[str]] = {}


def _tracked_stems(rev: str | None) -> set[str]:
    """Basenames (sans extension) of tracked files, so `Foo` matches Foo.swift."""
    key = rev or ":index:"
    if key in _STEMS_CACHE:
        return _STEMS_CACHE[key]
    if rev is None:
        _, out = _run(["git", "ls-files"])
    else:
        _, out = _run(["git", "ls-tree", "-r", "--name-only", rev])
    stems = set()
    for path in out.splitlines():
        base = path.rsplit("/", 1)[-1]
        stems.add(base.split(".", 1)[0])
    _STEMS_CACHE[key] = stems
    return stems


def _is_comment(text: str) -> bool:
    s = text.strip()
    return s.startswith("//") or s.startswith("*") or s.startswith("/*")


def exists_in_source(sym: str, rev: str | None) -> bool:
    """Does `sym` really exist in the tree this commit will create?

    rev=None -> the staged index (the real hook path).
    rev=SHA  -> that commit's tree (backtest path).

    Two things this got wrong on the first pass, both found by backtesting
    against real history — do not "simplify" them back out:

    1. Search ALL tracked source, not just *.swift, EXCLUDING *.md. Docs
       legitimately name things that live outside Swift (`PlistBuddy` and
       `NSHighResolutionCapable` are both in scripts/make-app.sh). Grepping only
       .swift flagged those as lies. Excluding *.md is what keeps the check
       honest: a doc naming a symbol cannot be its own evidence.

    2. A match that is ONLY inside a comment does not count as existence.
       d033466 wrote `setAppRoute`/`setAppVolume`/`removeAppRoute` into both
       AGENTS.md AND a /// doc comment in AppRowView.swift while the real
       methods were addRoute/setDestination/setVolume/removeRoute. A plain
       substring match found the comment and stayed quiet — the fiction
       vouching for itself. Requiring one non-comment occurrence catches it.

    Substring (not word-boundary) match on purpose: lenient, so we only flag a
    symbol appearing nowhere real.
    """
    # A doc may reference a FILE rather than an identifier (`AirPlayTypes` ->
    # AirPlayEngine/Sources/AirPlayEngine/AirPlayTypes.swift). git grep searches
    # CONTENT, so those looked like lies until this check existed. Match against
    # tracked filename stems too.
    if sym in _tracked_stems(rev):
        return True

    pathspec = [".", ":(exclude)*.md"]
    if rev is None:
        cmd = ["git", "grep", "-n", "-F", "--cached", sym, "--", *pathspec]
        maxsplit = 2  # path:lineno:content
    else:
        cmd = ["git", "grep", "-n", "-F", sym, rev, "--", *pathspec]
        maxsplit = 3  # rev:path:lineno:content
    code, out = _run(cmd)
    if code != 0:
        return False
    for line in out.splitlines():
        parts = line.split(":", maxsplit)
        if len(parts) <= maxsplit:
            continue
        if not _is_comment(parts[-1]):
            return True  # a real, non-comment occurrence
    return False  # only ever mentioned in comments — that is not an implementation


def agents_md_diff(rev: str | None) -> str:
    if rev is None:
        _, out = _run(
            ["git", "diff", "--cached", "-U0", "--diff-filter=ACM", "--", "*AGENTS.md"]
        )
    else:
        _, out = _run(
            ["git", "diff", f"{rev}^", rev, "-U0", "--diff-filter=ACM", "--", "*AGENTS.md"]
        )
    return out


def check(rev: str | None) -> list[str]:
    diff = agents_md_diff(rev)
    if not diff.strip():
        return []
    return [s for s in added_symbols(diff) if not exists_in_source(s, rev)]


def main() -> int:
    rev = None
    if len(sys.argv) > 2 and sys.argv[1] == "--commit":
        rev = sys.argv[2]

    missing = check(rev)
    if not missing:
        return 0

    where = "this commit" if rev is None else rev
    print("", file=sys.stderr)
    print(
        f"  AGENTS.md names symbols that exist nowhere in {where}'s source:",
        file=sys.stderr,
    )
    for s in missing:
        print(f"      - {s}", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "  Checked against THE COMMIT YOU ARE CREATING (staged index) — not main,\n"
        "  and not your working tree. So this is NOT complaining that your branch\n"
        "  hasn't merged yet; unmerged work in a worktree is fine and expected.\n"
        "\n"
        "  If the code is real but unstaged, STAGE IT — root AGENTS.md's hard rule\n"
        "  is that docs and their code land together, never docs first (f1f3e94).\n"
        "  If you renamed something, fix the doc to match the source.\n"
        "  If this is prose or an external API, ignore it — this never blocks.",
        file=sys.stderr,
    )
    print("", file=sys.stderr)
    return 0  # WARN ONLY. Never block a commit.


if __name__ == "__main__":
    sys.exit(main())
