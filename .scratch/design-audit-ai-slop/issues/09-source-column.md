# Source column: shape it, don't just strip it

Status: ready-for-human
Closes: A8

`FeedPillView.swift:33-51, 105` — every value in the Source column is a bordered
capsule with a fill and an edge ("System", "Music", "+5"), up to three a row across
twelve rows. `hitTest` returns nil: none is pressable, and "+5" does not expand.
Carried over verbatim from the iPhone companion.

**Ruling:** neither "keep as is" nor plain text. Run a design pass with the
`impeccable` skill against the real popover screenshots and come back with options.
Two fixed constraints from the owner:

- The values stay non-interactive. Nothing in that column takes a click.
- Hovering "+N" must reveal the hidden items. Hover only — no click target.

Plain text is the floor to beat, not the answer.
