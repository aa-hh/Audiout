#!/usr/bin/env python3
"""Guard 9's checker: no newly-staged line may put a window on a real screen.

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
    `screen-ok` comment passes, and the only sanctioned reason is an assertion
    that needs AppKit's own layout passes, which a window that is never
    ordered in does not get.

    Parking that window off every screen is harder than it looks, and getting
    it wrong is how this rule was last broken on main:

      - `.borderless` is the easy case. AppKit never constrains a borderless
        frame, so `NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, …))`
        stays at -10_000 and ordering it in shows nothing. Prefer this.
      - A TITLED window is NOT parked by its `contentRect`. AppKit constrains a
        titled frame onto a real display twice — inside `init(contentRect:…)`
        and again when the window is ordered in. Measured on a 1680x1050
        screen: a frame asked for at -10_000 is already at (80, 816) straight
        out of `init`, and `orderFrontRegardless()` draws it at (80, 620), in
        the corner of the developer's display.
      - What does work for a titled window: subclass `NSWindow`, override
        `constrainFrameRect(_:to:)` to return the rect unchanged, AND call
        `setFrameOrigin` after `init` — the override is not consulted during
        init, so the constructor's own constraint has to be undone afterwards.
        A toolbar out there still reports `isVisible` and still gets AppKit's
        layout passes, which is the whole point.

    The working example is `makeParkedWindow` in
    AudioutCore/Tests/AudioutCoreTests/SurfaceToolbarTests.swift. A test taking
    this route asserts the window intersects no `NSScreen`, and orders it out
    again in a `defer`.

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
    """Yield (hunk_text, [added_line, …]) for each hunk of the staged diff."""
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
    print("  A test that genuinely needs AppKit's layout passes may order a window", file=sys.stderr)
    print("  in, parked off every screen, with a trailing `screen-ok` comment saying", file=sys.stderr)
    print("  why. Park it correctly:", file=sys.stderr)
    print("    - `.borderless` is never constrained: a contentRect at -10_000 stays", file=sys.stderr)
    print("      there. Prefer it.", file=sys.stderr)
    print("    - a TITLED window is constrained onto a real display twice, inside", file=sys.stderr)
    print("      `init(contentRect:)` and again when ordered in, so its contentRect", file=sys.stderr)
    print("      parks nothing. Subclass NSWindow, override", file=sys.stderr)
    print("      `constrainFrameRect(_:to:)` to return the rect unchanged, AND call", file=sys.stderr)
    print("      `setFrameOrigin` after init — the override is not consulted during", file=sys.stderr)
    print("      init. Working example: `makeParkedWindow` in", file=sys.stderr)
    print("      AudioutCore/Tests/AudioutCoreTests/SurfaceToolbarTests.swift.", file=sys.stderr)
    print("  Then assert the frame intersects no NSScreen, and order it out in a", file=sys.stderr)
    print("  `defer`. Or `git commit --no-verify`.", file=sys.stderr)
    print("", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
