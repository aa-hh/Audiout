#!/usr/bin/env python3
"""Guard 8's checker: no newly-staged line may put a window on a real screen.

The rule it enforces is AudioutCore/AGENTS.md, "Tests must stay invisible":
suites run on developer Macs and on the unattended remote test Mac, both with a
live WindowServer. Anything ordered in flashes on a real desktop and steals
focus mid-typing; a modal run loop on the remote Mac wedges the run until
someone walks over to it. The rule has been re-broken often enough by hand that
it now has a hook.

What is checked, and why the two halves differ:

  * LIBRARY sources (a target with no `main.swift`) may call these APIs — the
    shipping app has to show its windows — but only behind
    `HeadlessRuntime.isActive`, because tests reach those same presenters.
    So a hunk that mentions `HeadlessRuntime` anywhere passes. A hunk that
    reads a window's `isVisible` passes too: that is the sheet presenters'
    existing idiom (`if let host = view.window, host.isVisible`), and a test's
    ordered-out host really is not visible.

  * TEST sources must not call them at all, gate or no gate: a test has no
    "real app" branch to be on the other side of. Only an explicit
    `screen-ok` comment passes, and the only sanctioned reason is an
    assertion needing a render-server-backed layer tree, on a window parked
    off every NSScreen and ordered out again in a `defer`.

  * EXECUTABLE targets (`main.swift` present: the app itself, the harness and
    snapshot tools) are exempt. They are launched deliberately by a human and
    are not test dependencies.

Only ADDED lines are scanned, so pre-existing code is never nagged about —
this can only ever fire on something being written now.
"""

import os
import re
import subprocess
import sys

BANNED = re.compile(
    r"""\.orderFront\b
      | \.orderFrontRegardless\b
      | \.orderWindow\(
      | \.makeKeyAndOrderFront\b
      | setIsVisible\(\s*true\s*\)
      | \.popUp\(
      | \.runModal\(
      | \.beginSheetModal\(
      | \.show\(relativeTo:
      | \bpresentAsSheet\(
      | \bpresentAsModalWindow\(
      | \bshowWindow\(
      | activate\(ignoringOtherApps
      | \bNSStatusBar\b
    """,
    re.VERBOSE,
)


def staged_swift():
    out = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=AM", "--",
         "AudioutCore/", "AirPlayEngine/"],
        capture_output=True, text=True,
    ).stdout
    return [f for f in out.split("\n") if f.endswith(".swift")]


def is_exempt(path):
    """Executable targets only — identified by a `main.swift` beside the file."""
    parts = path.split("/")
    if "Sources" not in parts:
        return False
    target_dir = "/".join(parts[: parts.index("Sources") + 2])
    return os.path.isfile(os.path.join(target_dir, "main.swift"))


def hunks(path):
    """Yield (hunk_text, [(line_no_in_diff, added_line)]) for the staged diff."""
    diff = subprocess.run(
        ["git", "diff", "--cached", "-U4", "--", path],
        capture_output=True, text=True,
    ).stdout.split("\n")
    current, added = [], []
    for line in diff:
        if line.startswith("@@"):
            if current:
                yield "\n".join(current), added
            current, added = [line], []
            continue
        if not current:
            continue
        current.append(line)
        if line.startswith("+") and not line.startswith("+++"):
            added.append(line[1:])
    if current:
        yield "\n".join(current), added


def main():
    findings = []
    for path in staged_swift():
        if is_exempt(path):
            continue
        is_test = "/Tests/" in path or path.endswith("Tests.swift")
        for hunk_text, added in hunks(path):
            # `setIsVisible` is itself banned, so strip it before looking
            # for the `isVisible` gate token — otherwise it would excuse itself.
            gate_text = hunk_text.replace("setIsVisible", "")
            gated = (not is_test) and (
                "HeadlessRuntime" in gate_text or "isVisible" in gate_text
            )
            for line in added:
                if not BANNED.search(line) or "screen-ok" in line:
                    continue
                if gated:
                    continue
                findings.append((path, line.strip(), is_test))

    if not findings:
        return 0

    print("", file=sys.stderr)
    print("  REFUSED: staged code can put a window on a real screen.", file=sys.stderr)
    print("", file=sys.stderr)
    for path, line, is_test in findings:
        print(f"  {path}", file=sys.stderr)
        print(f"    {line}", file=sys.stderr)
        if is_test:
            print("    ^ a TEST may not present anything, gated or not.", file=sys.stderr)
        else:
            print("    ^ wrap the presentation in `if !HeadlessRuntime.isActive { … }`.", file=sys.stderr)
    print("", file=sys.stderr)
    print("  Suites run on this Mac and on the unattended remote test Mac, both", file=sys.stderr)
    print("  with a live WindowServer: an ungated presenter flashes a real window", file=sys.stderr)
    print("  on a real desktop, and a modal one wedges the run until someone walks", file=sys.stderr)
    print("  over to the machine. The rule, the approved seams (`test_*` hooks,", file=sys.stderr)
    print("  ordered-out layout hosts, `performClick`) and the one sanctioned", file=sys.stderr)
    print("  exception are in AudioutCore/AGENTS.md, \"Tests must stay invisible\".", file=sys.stderr)
    print("", file=sys.stderr)
    print("  `view.window != nil` is NOT a headless check — suites host panes in", file=sys.stderr)
    print("  real, ordered-out windows. Use HeadlessRuntime.isActive.", file=sys.stderr)
    print("", file=sys.stderr)
    print("  Genuinely needs to reach the screen? Append a trailing `screen-ok`", file=sys.stderr)
    print("  comment saying why, or `git commit --no-verify`.", file=sys.stderr)
    print("", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
