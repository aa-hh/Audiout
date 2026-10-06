# AudioutWindowUI

## Purpose

Configuration-only Speakers and Scenes content: no window, no backend.

## Rules

- Selection and scene editing configure; neither activates a scene or creates playback intent.
- Speaker visibility is global and never changes scene membership, routing or saved intent; membership controls never double as visibility controls.
- The sidebar, scene editor and speaker pages share identity; remembered records stay outside backend collections and route pickers.
- The sidebar shows reachability, never routing; its two groups are the visibility setting.
- Unavailable members stay editable; unknown IDs stay Missing speaker, with no invented transport or playback.
- Hidden hosts retain fresh snapshots; repaint only visible screens.
- Every editor exit, keyboard included, uses the host's dismissal path.
- Never let the sidebar collapse; nothing can restore it.
- Panes fit the shared surface geometry; never widen the shell.
- Gold means live audio; magenta, group identity; green, a reachable speaker. Stock sidebar chrome remains native.
- `GroupedSectionView`'s custom-drawn `.well` recesses both Equalizer pages with a flat, clipped `Tokens.Color.shadow` band: in light, `raised` matches the pane, so a `.card` outlines nothing.
- Report persistence failures in plain words; never swallow them.
- Preserve keyboard focus seeding in visible hosts; headless absence is not dead code.
- Never regenerate the unreproducible macOS 27 device-detail goldens.
- Device and group glyphs share `DeviceIcon` resolution.
- Earlier decisions and traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `MixerWindowController` → Scenes and Speakers content and navigation.
- `ContentPaneHostViewController` → Swapped content and footer.
- `SpeakersPageViewController` → Overview; sanctioned custom shimmer.
- `ListRowView` → One outlined-list row.
- `GroupsOverviewViewController` → Saved-scene cards.
- `SidebarViewController` → The speaker list.
- `GroupEditorViewController` → Scene name, membership and deletion.
- `GroupCreationSheetController` → Scene creation without activation.
- `DeviceDetailViewController` → A speaker's page.
- `MainOutDetailViewController` → Main Audio configuration.
