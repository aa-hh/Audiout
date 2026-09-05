# Groups screen redesign — Direction C brief (2026-08-27)

The owner's decision from a four-direction discovery (mock-ups in the "The
Groups–Speakers Split" artifact; the chosen direction's mock-up is saved
beside this file as `groups-direction-c-mockup.html`). Rejected: A (two
peer screens in the header capsule), B (sidebar mode toggle), D (outline
hierarchy).

**Prerequisite, also decided:** the group editor becomes a scrolling pane
FIRST (roadmap 039). The editor's back band rides on that; the 600 pt
surface floor does NOT move for this work.

## Job

The Groups screen's sidebar mixes System Audio, Groups, and Speakers; a
growing fleet pushes groups off the top, and per-device EQ has given
speakers a reason to live on their own. Direction C separates them:
devices own the sidebar, groups move into the content pane as a card
overview.

## Selected direction — interaction model

- **Sidebar = the fleet only.** Pinned, non-device **Groups** row on top
  (trailing chevron; gold `speaker.wave.2` marker when a group is
  playing), hairline, then System Audio, then every Speaker. The bottom
  add bar stays, including the multi-select "New Group from N Speakers…"
  retitle — that affordance is anchored to the device list and does not
  move.
- **Groups row → card overview in the content pane.** One card per saved
  group: group glyph, name (13.5/600), meta line "5 speakers · Playing
  now" (live half gold), bottom edge = up to four 24 pt member device
  chips + dashed `+N` overflow chip. Card ≈ 182×118, two columns in the
  413 pt pane (16 pt margins/gutter). Live card wears a gold border +
  wave — the only gold beyond the editor's armed rail; gold still means
  LIVE, never decoration.
- **Card → editor as an in-pane push.** A ~20 pt "‹ Groups" band above
  the identity card (Escape and ⌘[ also go back). The sidebar keeps the
  Groups row selected throughout — the fleet list never moves under the
  pointer. Arrow keys move the grid in 2D, Return/Space opens, Tab
  enters the grid as one focus target.
- **Right-click:** card → Rename… / Delete Group… (relocated from the
  old sidebar group rows); Groups row → New Group….
- **New Group has two doors, one sheet:** the dashed "+" tile as the
  grid's last cell, and the sidebar's multi-select bar (prefilled name,
  as today).
- **Empty state:** no separate pane. With zero groups the overview IS
  the canvas — headline, teaching subtitle, and the New Group tile
  promoted to centre. `GroupsEmptyStateViewController` is deleted.
- Selection still never activates playback; the Mixer keeps playback.
  Header capsule stays at three slots.

## Scope and boundaries

- Fidelity: production. Breadth: the Groups screen only — Mixer,
  Settings, popover untouched.
- Anti-goals: no drag-and-drop membership; no growth of
  `SurfaceLayout.width`; no new gold sites beyond the card/row live
  markers; device detail pane and Main Audio pane unchanged.
- Stress case: ~10 speakers, 2–4 groups. Past ~8 groups the grid
  scrolls; accepted.

## Implementation delta (from the direction agent; verify at build time)

- **New:** `GroupsOverviewViewController` — card grid over
  `GroupController.groups`, absorbing the empty state. Needs its own
  layout constants (the card grid sits outside `GroupsPaneLayout`'s
  editor/detail parity grammar — do not force it in).
- `SidebarSelection` gains `.groupsOverview`; `.group(id:)` survives,
  set by the overview, and maps the sidebar highlight onto the Groups
  row.
- `SidebarViewController` loses its Groups section (rows, header, group
  context menu — the menu moves to the cards); keeps the add bar and
  multi-select retitle unchanged. AGENTS.md's three-flat-sections rule
  becomes two.
- `GroupEditorViewController` gains the back band + `onBack` (after 039
  makes it scroll); `MixerWindowController` routes it and the
  auto-select rule becomes "the Groups row" instead of "first saved
  group".
- **Delete:** `GroupsEmptyStateViewController`.
- Tests: sidebar section-count assertions change; header-parity tests
  untouched; `theSevenDeviceEditorFitsTheMinimumFrame` is superseded by
  whatever guard 039 introduces for the scrolling editor.

## Known risks (accepted at decision time)

- Group→group editing becomes 3 clicks (back, other card) vs 1 today.
- The overview must be opened — cold-launch live-group visibility hangs
  on the gold marker on the Groups row.
