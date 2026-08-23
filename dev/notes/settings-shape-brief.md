# Settings — design brief (shape, 2026-08-11)

Confirmed with ahh. Plan only; no code written under this brief.

## Job

Operate mode. Audio is already playing; someone opens Settings to change one
thing and leave. Success is the setting found and changed in under ten seconds
without reading a paragraph. Settings is never a place to browse.

## Problems this fixes

1. **Audio pane is a wall of text.** Five unrelated sections, and the sync-offset
   explanation is a static five-line paragraph — not a live hint. That paragraph
   is the actual offender, not the hint mechanism.
2. **Visually inert.** Every row's control lands at a different x (switch,
   button, slider, popup), so nothing aligns down the pane. Section headers carry
   no weight separation from row titles.
3. **Missing settings.** No updater, no keyboard shortcuts, no reconnect-at-start,
   no diagnostics export, no remote-access control anywhere in the app.
4. **`AppSettings.density` is dead.** Persisted, two test assertions, no UI and no
   consumer. **Delete it** (the enum `InterfaceDensity`, the property, the key,
   and the assertions in `AppSettingsTests`).

## Structure — three tabs, held

Owner held the three-tab rule (LOCKED 2026-07-22) against six new items. That
only works because the rare and the expert controls stop being full rows:
one **footer button strip** and two **disclosure groups** carry nine items in
three slots. Target is **five visible rows per tab, ~320pt**.

### General

| | Row |
|---|---|
| 1 | Launch at login |
| 2 | Reconnect last speakers when Audiout starts |
| 3 | Check for updates *(with an automatic-checks toggle)* |
| 4 | **Shortcuts & remote** — disclosure |
| 5 | Footer strip: `Setup…` · `Diagnostics…` · `About Audiout…` |

Row 4 discloses three related things — all the ways Audiout is reached from
outside the panel:

- Keyboard shortcuts: **open the panel**, **mute everything**. (Kill-switch one
  gesture away, product principle 4.)
- Shortcuts.app actions — a pointer only. Settings must not restate what the
  App Intents already expose; one line and a button that opens Shortcuts.
- Allow control from iPhone, plus the list of paired devices and a way to revoke
  one.

Row 5 replaces three full title+subtitle rows with one quiet strip. Setup,
About and Diagnostics are rare-use; they do not deserve equal weight with
Launch at login.

### Audio

| | Row |
|---|---|
| 1 | Apps that stay on this Mac *(the excluded list)* |
| 2 | Volume when connecting a speaker |
| 3 | Restore Mac audio if speakers don't reconnect |
| 4 | **Advanced** — disclosure, collapsed by default: Audio buffer · Local speaker sync offset |

### Appearance

Theme, Accent. Deliberately thin — it is the rarest tab, and thin is not a
problem to solve.

## Copy

- **Keep the live hint line.** The owning pane re-writing the hint on every value
  change is the good part and stays (module rule, spec §5.2).
- **Kill static explanation paragraphs.** Sync offset gets a one-line live hint
  (`Your Mac plays 0 ms behind your speakers.`) plus a stock help button that
  opens the long explanation. Native, and it is the only place that paragraph
  belongs.

## Visual

- **One control column.** Every switch, popup, button and slider ends at the same
  right edge across all three panes.
- **Section headers** get real weight separation from row titles.
- **Value readouts** (`35%`, `1,000 ms`, `0 ms`) get monospaced digits and the
  panel's well treatment, so they read as instrument and rhyme with the Mixer.
- **No gold in Settings.** Gold means *signal* — meters, dots, rings. A settings
  row is not signal. The only gold pixels stay inside the theme preview tiles,
  where they depict an appearance rather than decorate one. Brand comes from
  structure, type, and the warm ground. This preserves the module's existing
  "controls stay stock" rule rather than overriding it.

## Engineering notes for whoever builds this

- **Four of the six additions are new features, not UI.** No updater, no hotkey
  registration, no diagnostics export and no remote-access control exist in the
  codebase today. `ConnectionDiagnostics` is the seed for the export; everything
  else is greenfield. Scope them separately from the layout work.
- **Shortcuts.app actions are unmerged** (roadmap 035). Row 4's pointer should
  degrade to nothing when the intents are absent, the way the Audio pane already
  omits its Advanced section when `LatencyConfigurable` is nil.
- **Disclosures change pane height at runtime with no tab switch** — exactly the
  `rebuildList()` case the module already handles via KVO on
  `preferredContentSize`. Publish through that path; do not add a second one.
- **The four sizing traps in `AudioutSettingsUI/AGENTS.md` still bind.** In
  particular every new view sets `translatesAutoresizingMaskIntoConstraints =
  false`, and the footer strip and disclosure content are no exception.
- Re-run the `settings-snapshot` target after the layout lands; the checked-in
  PNGs under `dev/notes/settings-snapshots/` are the visual record.
