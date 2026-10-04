# AGENTS.md history: AudioutCore/Sources/cast-spike

Archived verbatim from AGENTS.md on 2026-10-04 when that file was trimmed back to the root rule (three sections, at most 300 words). Not maintained: symbols named below may no longer exist. Orientation lives in AGENTS.md; grep this file for the long form of a trap and the dated decisions.

---

- **Unbundled CLI, so no `NSBonjourServices` entry is needed.** Browsing works
  here and will not work from the bundled app until that key gains
  `_googlecast._tcp` — do not conclude discovery is fine from a green `--list`.
- **Output is fully buffered under a pipe.** Run it under a pty (`script -q
  /dev/null …`) or the log arrives in one lump at exit, which destroys the
  timings the tool exists to show.
