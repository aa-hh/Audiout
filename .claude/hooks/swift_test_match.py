#!/usr/bin/env python3
"""Decide whether a shell command is a BARE `swift test` invocation.

Used by swift-test-nudge.sh (PreToolUse/Bash). Reads the raw command on
stdin, prints DENY or ALLOW.

Earlier version matched "swift" and "test" as a word-boundary regex against
the RAW command string — which matched the phrase anywhere it appeared,
including inside a quoted string (`grep "swift test" file`), a git log
message, an echo, or a comment. That false-positive fired on ordinary
diagnostic commands and caused a flood of spurious denials in every session
working in this checkout (2026-07-22 incident).

The fix: blank out everything the shell would NOT treat as a literal command
word before matching — single/double-quoted regions, heredoc bodies, and
`#` comments — then split on shell command separators (;, &&, ||, |, `(`, `)`,
newline) and check whether an actual simple command's first two words (after
any leading VAR=value assignments) are literally `swift` and `test`.

This is not a full shell parser (command substitution `$(...)`/backticks and
a bare word deliberately single-quoted, e.g. `swift 'test'`, are not
specially handled) — those residual gaps fail OPEN (allow), which is the
safe direction: `.githooks/pre-commit` Guard 4 runs the full suite at commit
regardless, so an under-caught bare invocation only misses a speed nudge, it
can never let untested code land. Over-blocking (the original bug) is what
actually harms — denying a command that never invoked `swift test` at all —
so every design choice here favors "when unsure, allow."
"""
import re
import sys


def strip_noise(cmd: str) -> str:
    out = []
    i, n = 0, len(cmd)
    in_squote = in_dquote = False
    heredoc_terms = []  # stack of (terminator, strip_leading_tabs)

    def is_line_start(pos: int) -> bool:
        return pos == 0 or cmd[pos - 1] == '\n'

    while i < n:
        c = cmd[i]

        if heredoc_terms and is_line_start(i) and not in_squote and not in_dquote:
            term, strip_tabs = heredoc_terms[-1]
            line_end = cmd.find('\n', i)
            line = cmd[i:line_end if line_end != -1 else n]
            probe = line.lstrip('\t') if strip_tabs else line
            if probe == term:
                heredoc_terms.pop()
            out.append(' ' * len(line))
            i = line_end if line_end != -1 else n
            continue

        if in_squote:
            out.append(' ' if c != '\n' else '\n')
            if c == "'":
                in_squote = False
            i += 1
            continue
        if in_dquote:
            if c == '\\' and i + 1 < n:
                out.append('  ')
                i += 2
                continue
            out.append(' ' if c != '\n' else '\n')
            if c == '"':
                in_dquote = False
            i += 1
            continue

        if c == "'":
            in_squote = True
            out.append(' ')
            i += 1
            continue
        if c == '"':
            in_dquote = True
            out.append(' ')
            i += 1
            continue
        if c == '#' and (i == 0 or cmd[i - 1] in ' \t;&|(\n'):
            line_end = cmd.find('\n', i)
            span = cmd[i:line_end if line_end != -1 else n]
            out.append(' ' * len(span))
            i = line_end if line_end != -1 else n
            continue
        m = re.match(r'<<-?\s*(["\']?)(\w+)\1', cmd[i:])
        if m:
            heredoc_terms.append((m.group(2), cmd[i:i + 3].startswith('<<-')))
            out.append(' ' * len(m.group(0)))
            i += len(m.group(0))
            continue

        out.append(c)
        i += 1

    return ''.join(out)


def is_bare_swift_test(raw_cmd: str) -> bool:
    clean = strip_noise(raw_cmd)
    segments = re.split(r'(\;|\&\&|\|\||\||\n|\(|\))', clean)
    for seg in segments:
        seg = seg.strip()
        if not seg or seg in (';', '&&', '||', '|', '(', ')'):
            continue
        tokens = seg.split()
        idx = 0
        while idx < len(tokens) and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', tokens[idx]):
            idx += 1
        rest = tokens[idx:]
        if len(rest) >= 2 and rest[0] == 'swift' and rest[1] == 'test':
            allowed_flag = any(
                any(f in t for f in ('--filter', '--parallel', '--list-tests', '--help', '--version'))
                for t in rest[2:]
            )
            escape = 'AIRPLAY_SERIAL_TEST=1' in raw_cmd
            if not allowed_flag and not escape:
                return True
    return False


if __name__ == '__main__':
    try:
        raw = sys.stdin.read()
        print('DENY' if is_bare_swift_test(raw) else 'ALLOW')
    except Exception:
        # Never let a bug in this matcher block an unrelated command.
        print('ALLOW')
