# AGENTS.md history: AudioutCore/Sources/CastSender

Archived verbatim from AGENTS.md on 2026-10-04 when that file was trimmed back to the root rule (three sections, at most 300 words). Not maintained: symbols named below may no longer exist. Orientation lives in AGENTS.md; grep this file for the long form of a trap and the dated decisions.

---

Protobuf is hand-rolled
  by decision 4 of `dev/notes/006-cast-output-scope-2026-08-22.md`: seven
  fields, cheaper than codegen.
- **`NSBonjourServices` carries `_googlecast._tcp`** (`scripts/make-app.sh`
  enforces it) — no bundled app can browse otherwise. A browse
  that works in the CLI but finds nothing in the app is this, not `CastBrowser`.
- **Cross-queue reads take a lock, never `queue.sync`** — `stateLock` in
  `CastChannel`, `portLock` in `CastLiveAudioServer`: callers read them from
  completions already on that queue, where a sync getter deadlocks.
- **Nothing owns a `CastSpikeRun` but its caller** — hold it strongly, because
  its callbacks are `weak self` and a dropped run stops silently. Its log lines
  are prefixed `+%.3fs `; keep new events in that shape.
