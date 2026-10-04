# AudioutWindowUI

## Purpose

Configuration-only Speakers and Scenes content. Owns no window; never talks to a backend.

## Rules

- Selection configures; it never activates playback. Scene editing must not activate a scene or create playback intent.
- Speaker visibility applies globally and never changes scene membership, routing or saved intent. Membership controls must not double as visibility controls.
- The sidebar, scene editor and speaker pages share identity; remembered records stay outside backend collections and route pickers.
- The sidebar's dot shows presence, never routing; its two groups are the visibility setting.
- Unavailable members remain editable. Unknown IDs stay Missing speaker without invented transport or playback capabilities.
- Hidden hosts retain fresh snapshots; repaint only visible screens.
- Editor exits return through the host's existing dismissal path, including keyboard actions.
- Never let the sidebar collapse; nothing can restore it.
- Panes fit the shared surface geometry; never widen the shell.
- Gold means live audio; magenta means group identity. Stock sidebar chrome remains native.
- Report persistence failures in plain words; never swallow them.
- Preserve keyboard focus seeding in visible hosts; headless absence is not dead code.
- Never regenerate the unreproducible macOS 27 device-detail goldens.
- Device and group glyphs share `DeviceIcon` resolution.
- Earlier decisions and traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `MixerWindowController` → Scenes and Speakers content and navigation.
- `ContentPaneHostViewController` → Swapped content and footer.
- `SpeakersPageViewController` → Speakers landing: search result, kinds, Bluetooth, lost, Pair.
- `ListRowView` → one outlined-list row: glyph, title, caption, accessory.
- `GroupsOverviewViewController` → Saved-scene cards.
- `SidebarViewController` → Speaker list: presence dots, two visibility groups, menu, drag.
- `GroupEditorViewController` → Scene name, membership and deletion.
- `GroupCreationSheetController` → Scene creation without activation.
- `DeviceDetailViewController` → Speaker identity, visibility and settings.
- `MainOutDetailViewController` → Main Audio configuration.
