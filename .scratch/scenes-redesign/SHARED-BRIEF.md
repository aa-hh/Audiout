# Scenes tab redesign — shared brief for the four direction agents

Owner's request (2026-10-06): reshape the Scenes tab so it reads as the sibling of the Mixer and Speakers tabs, starting from the design system and components already in place. Four divergent directions, each with its own creativity, each still unmistakably this app.

## What the owner said is wrong today (discovery round, 2026-10-06)
- Structure doesn't match: Speakers is sidebar + page header + card; Mixer is rows on a gold rail. Scenes is a lone card grid with nothing shared.
- The scene cards feel foreign: the tile grid and dashed "add" tile read like a different app from the row-based tabs.
- The editor drifts too: icon well, membership rail, delete band.

## Scope
Everything under the Scenes tab: the overview, the scene editor, the scene creation sheet, the icon picker, and the Main Audio destination menu's scene entries. Each direction may fold, drop or merge any of these as long as every job they do today still has a home.

## Deliverable per direction (write into your own folder, nothing else in the repo)
1. `brief.md` — the shape brief, in the structure `reference/shape.md` gives (job/audience, outcome, selected direction, scope, states, interaction/layout, constraints + open decisions). Mark every assumption you had to make. No code.
2. `mock.html` — one self-contained HTML file that draws the overview AND the editor at the real surface width (713 pt), dark and light side by side or stacked, using the DESIGN.md token hex values and SF Pro via `-apple-system`. Throwaway: a picture of the direction, not app code. Real speaker names from the fleet the code uses in snapshots (`window-snapshot/main.swift`), 3 scenes, one active.
3. `mock.png` — render it with `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=W,H --screenshot=<abs path mock.png> file://<abs path mock.html>`. Look at the PNG once and fix anything broken, then stop.

## Fixed truths (do not relitigate)
- Operate mode. Native AppKit structure, SF Symbols, the Warm Signal tokens. Read DESIGN.md for every component you reuse; name the component you reuse in the brief.
- The surface is 713 pt wide on every screen; sidebars are 210 pt; row body 42 pt; the toolbar strip, beak and pin are shared chrome and not yours to change.
- Scenes is configuration-only: nothing on it activates a scene or starts playback. Activation lives on the Mixer's Main Audio destination menu. Keep that line.
- Gold = audio state, calls to action, selection, completion. Green (`speakersAccent`) is the Speakers tab's own accent, not yours. `partyRampDeep` magenta is group identity (the glow behind group seats), never state. `railDormant` is the one dormancy tone.
- Voice: console flavour on fixed chrome labels only; anything a user acts on reads in plain speech. Bare numbers over presets.
- The UI never lies: unavailable members are counted and named, empty state is honest, no fabricated live data.
- Accessibility: 4.5:1 text, 3:1 non-text, VoiceOver parity, Reduce Motion.
- Design authority: this repo's DESIGN.md plus PRODUCT.md. `impeccable context` loads both.

## Where to look (read, don't edit)
- `AudioutCore/Sources/AudioutWindowUI/` — `GroupsOverviewViewController.swift`, `GroupEditorViewController.swift`, `GroupCreationSheetController.swift`, `GroupsPaneLayout.swift`, `MixerWindowController.swift`, `IconPickerViewController.swift`, `PageHeaderView.swift`, `GroupedSectionView.swift`, `MembershipRowView.swift`, `ListRowView.swift`, `SidebarViewController.swift`, `SpeakersPageViewController.swift`, `DeviceIconWellView.swift`, and the folder's `AGENTS.md`.
- `AudioutCore/Sources/AudioutPopoverUI/` — `PopoverPanelViewController.swift`, `MainOutRowView.swift`, `SurfaceToolbar.swift`, `AGENTS.md` (the Mixer's row grammar and gold rail).
- `AudioutCore/Sources/AudioutSharedUI/GroupIdentityGlowView.swift` and the shared tokens file (grep `enum Tokens`).
- `DESIGN.md` sections: Layout, Components (Speakers Sidebar and Pages, Grouped Section, Icon Well, Group Row and Membership Rail, Surface toolbar), Do's and Don'ts.
- Pictures: `dev/notes/popover-snapshots/popover-dark.png` (the Mixer, current). `dev/notes/window-snapshots/mixer-3-edit-group-dark.png` and `mixer-7-edit-active-group-dark.png` (the editor; chrome is older but the editor body is close). The checked-in overview snapshots predate the card grid, so read the overview from code. Note the headless renderer currently produces blank frames; do not try to fix it.
- `dev/notes/groups-speakers-split-direction-c-brief-2026-08-27.md` — the brief that produced today's layout; evidence and anti-reference.
