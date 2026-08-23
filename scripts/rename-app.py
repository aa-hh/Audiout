#!/usr/bin/env python3
"""Rebrand the whole checkout from "Audiout" to a new name.

The app name is baked into 380+ files and ~300 file/directory names: Swift
module names, the SwiftPM package, bundle identifiers, log subsystems, Bonjour
service types, docs prose, the icon assets. This does all of it in one pass, so
the code and the user-facing text can't end up disagreeing with each other.

    python3 scripts/rename-app.py Halcyon                 # dry run — prints what would change
    python3 scripts/rename-app.py Halcyon --apply         # rewrites the checkout
    python3 scripts/rename-app.py "Sound Bridge" --apply  # two-word brand, see below
    python3 scripts/rename-app.py Halcyon --also "Warm Signal=Northlight" --apply

Display name vs identifier
    Where the old name stands alone as a word ("Quit Audiout", the permission
    prompts, "Audiout.app") it becomes the new display name. Where it's glued
    to other characters (AudioutCore, com.audiout.Audiout,
    AUDIOUT_BUILD_LOCAL) it becomes the identifier form — the display name
    with spaces and punctuation stripped. When the brand is a single word the
    two are the same and the distinction never comes up.

Nothing outside this checkout is touched. The script prints a checklist at the
end covering what it can't do: your settings folder, the GitHub repo name, the
separate website and iOS repos.
"""

import argparse
import os
import re
import subprocess
import sys

OLD_DISPLAY = "Audiout"   # how the name appears standing on its own
OLD_IDENT = "Audiout"     # how it appears glued into identifiers
OLD_LOWER = "audiout"     # bundle ids, Bonjour service types, lowercase halves
OLD_UPPER = "AUDIOUT"     # env var prefixes, e.g. AUDIOUT_BUILD_LOCAL

# The name standing on its own — not touching an identifier character. This is
# what separates "Quit Audiout" and "Audiout.app" (display name) from
# AudioutCore and com.audiout.Audiout (identifier).
STANDALONE = re.compile(rf"(?<![A-Za-z0-9_-]){re.escape(OLD_DISPLAY)}(?![A-Za-z0-9_-])")


def git(*args, **kwargs):
    return subprocess.run(
        ["git", *args], check=True, text=True, capture_output=True, **kwargs
    ).stdout


def build_rules(new_display, new_ident, extras):
    """Ordered (pattern, replacement) pairs.

    Order matters. The --also terms run first because they may themselves
    contain the app name. Then the standalone-word display pass, then the
    glued-in identifier pass. Once an earlier rule has rewritten a site, the
    later rules no longer see it.
    """
    rules = [(re.compile(re.escape(old)), new) for old, new in extras]
    rules += [
        (STANDALONE, new_display),
        (re.compile(re.escape(OLD_IDENT)), new_ident),
        (re.compile(re.escape(OLD_LOWER)), new_ident.lower()),
        (re.compile(re.escape(OLD_UPPER)), new_ident.upper()),
    ]
    return rules


def rename(text, rules):
    for pattern, replacement in rules:
        # A function replacement keeps backslashes in the new name literal.
        text = pattern.sub(lambda _m, r=replacement: r, text)
    return text


def parse_also(value):
    if "=" not in value:
        raise argparse.ArgumentTypeError(f"--also wants OLD=NEW, got: {value!r}")
    old, new = value.split("=", 1)
    if not old:
        raise argparse.ArgumentTypeError("--also needs something on the left of the =")
    return old, new


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("new_name", metavar="NewName",
                        help='the new brand name, e.g. Halcyon or "Sound Bridge"')
    parser.add_argument("--identifier", metavar="Name",
                        help="code-safe form for module names, file names and bundle "
                             'ids (default: NewName with punctuation stripped, so '
                             '"Sound Bridge" becomes SoundBridge)')
    parser.add_argument("--also", metavar="OLD=NEW", type=parse_also, action="append",
                        default=[], help="rename another term too; repeatable, literal, "
                                         "case-sensitive")
    parser.add_argument("--apply", action="store_true",
                        help="write the changes (without this it's a dry run)")
    args = parser.parse_args()

    new_display = args.new_name
    new_ident = args.identifier or re.sub(r"[^A-Za-z0-9]", "", new_display)
    if not re.match(r"^[A-Za-z][A-Za-z0-9]*$", new_ident):
        parser.error(f"identifier must be letters and digits starting with a letter, "
                     f"got {new_ident!r} — pass --identifier to set it explicitly")

    root = git("rev-parse", "--show-toplevel").strip()
    os.chdir(root)

    if args.apply and git("status", "--porcelain").strip():
        sys.exit(
            "Working tree is dirty. Commit or stash first — a clean tree is what makes\n"
            "this reversible: afterwards `git diff` IS the review, and\n"
            "`git checkout . && git clean -fd` puts everything back."
        )

    rules = build_rules(new_display, new_ident, args.also)
    print(f"  display name : {OLD_DISPLAY} -> {new_display}")
    print(f"  identifier   : {OLD_IDENT} -> {new_ident}")
    print(f"  lowercase    : {OLD_LOWER} -> {new_ident.lower()}")
    print(f"  uppercase    : {OLD_UPPER} -> {new_ident.upper()}")
    for old, new in args.also:
        print(f"  also         : {old} -> {new}")
    print()

    tracked = set(git("ls-files").splitlines())
    paths = sorted(tracked | set(git("ls-files", "--others", "--exclude-standard").splitlines()))

    # Contents. Binary files are skipped: the icon PNGs and SVG assets carry
    # the name in their filenames only, and rewriting bytes inside a PNG would
    # corrupt it.
    edits = []          # (path, new_text)
    skipped_binary = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            if any(pattern.search(path) for pattern, _ in rules):
                skipped_binary.append(path)
            continue
        renamed = rename(text, rules)
        if renamed != text:
            edits.append((path, renamed))

    # Paths, deepest first — renaming a file must never invalidate a directory
    # path still queued behind it.
    moves = [(p, rename(p, rules)) for p in paths]
    moves = sorted((old, new) for old, new in moves if old != new)
    moves.sort(key=lambda pair: pair[0].count("/"), reverse=True)

    print(f"Files whose contents change: {len(edits)}")
    print(f"Files to rename:             {len(moves)}")
    if skipped_binary:
        print(f"Binary files renamed but not rewritten: {len(skipped_binary)}")
    print()

    if not args.apply:
        print("--- renames that would happen (first 40) ---")
        for old, new in moves[:40]:
            print(f"  {old}\n    -> {new}")
        if len(moves) > 40:
            print(f"  ... and {len(moves) - 40} more")
        print()
        if new_display != new_ident:
            print(f'--- sites that get the DISPLAY name ("{new_display}", not "{new_ident}") ---')
            shown = 0
            for path, _ in edits:
                with open(path, encoding="utf-8") as handle:
                    for lineno, line in enumerate(handle, 1):
                        if STANDALONE.search(line):
                            print(f"  {path}:{lineno}: {line.strip()[:100]}")
                            shown += 1
                            if shown >= 30:
                                break
                if shown >= 30:
                    break
            print("  (worth checking these still read right with a two-word name —")
            print("   repo names, URLs and shell paths in docs want the identifier)")
            print()
        print("Dry run. Re-run with --apply to write.")
        return

    for path, text in edits:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    for old, new in moves:
        if not os.path.lexists(old):
            continue        # already moved along with its parent directory
        os.makedirs(os.path.dirname(new) or ".", exist_ok=True)
        if old in tracked:
            git("mv", old, new)
        else:
            os.rename(old, new)
    prune_empty_dirs(root)

    leftover = subprocess.run(
        ["git", "grep", "-I", "-n", "--untracked", "-E",
         "|".join([OLD_IDENT, OLD_LOWER, OLD_UPPER] + [re.escape(o) for o, _ in args.also])],
        text=True, capture_output=True,
    ).stdout
    print("Still mentioning the old name — check by hand:\n" + leftover
          if leftover else "No occurrences of the old name left.")

    print(NEXT_STEPS.format(old=OLD_DISPLAY, new=new_display))


def prune_empty_dirs(root):
    """Directories the renames emptied out.

    Deepest first, re-checking with listdir as we go: emptying a child is what
    makes its parent removable, and os.walk's own directory listing is a
    snapshot taken before any of that happens.
    """
    found = []
    for dirpath, dirnames, _ in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        found.append(dirpath)
    for dirpath in sorted(found, key=lambda p: p.count(os.sep), reverse=True):
        if dirpath != root and not os.listdir(dirpath):
            os.rmdir(dirpath)


NEXT_STEPS = """
Next:
  1. rm -rf AudioutCore/.build .build   # stale module caches under the old name
  2. bash scripts/build.sh                # the real check that the rename is consistent
  3. bash scripts/run-tests.sh
  4. git diff — that's your review. `git checkout . && git clean -fd` undoes all of it.

Deliberately NOT touched:
  - Your settings and saved groups, in ~/Library/Application Support/{old}/. The
    renamed app looks in .../{new}/ and starts empty. Move the folder across by
    hand to keep them.
  - The bundle id changes, so macOS treats this as a brand new app: every
    permission (system audio, Bluetooth, local network) prompts again, and the
    old copy in /Applications stays behind under the old name.
  - Git branch names, the GitHub repo name, the worktree directory names.
  - The website repo (~/Projects/Audiout Website) and the iOS app on
    claude/ios-staging — run this script inside each of those too.
  - The artwork inside the icon PNGs, if it carries a wordmark.
"""


if __name__ == "__main__":
    main()
