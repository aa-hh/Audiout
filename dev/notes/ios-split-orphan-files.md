# iOS split: two files with no home in this repo

Two files touched by the iOS split have no counterpart in the repo they
belong in. Both moves are into external repos — no agent may perform them;
Alec does the moves.

## `ios/AudioutRemote/DESIGN.md` → `aa-hh/audiout-remote`

Goes at that repo's root, as `DESIGN.md` — the repo is flat
(`AudioutRemote.xcodeproj`, `AudioutRemote/`, `AGENTS.md` all at root).
`audiout-remote` has no design document today.

Retrieval:

```
git show origin/claude/ios-staging:ios/AudioutRemote/DESIGN.md
```

## `AudioutProtocol/AGENTS.md` → `aa-hh/audiout-shared`: almost nothing to move

`audiout-shared/AGENTS.md` already carries the zero-dependencies rule, the
protocol-break rule, the version-bump rule, and refuse-forward, under its own
`### AudioutProtocol` heading — and its Guard 4 note is already obsolete
there by that file's own text.

The one rule it does not carry, to forward verbatim:

> Icons ride OUTSIDE `Snapshot` on purpose, so identical-snapshot suppression
> is never defeated by icon churn.

Retrieval:

```
git show origin/claude/ios-staging:AudioutProtocol/AGENTS.md
```

## Neither file is at risk

Both are byte-identical to their scratchpad backups on
`origin/claude/ios-staging` already, so no rescue step is needed.
