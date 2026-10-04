# AudioutWindowUI

## Purpose

Configuration-only Speakers and Scenes content. This target owns no window and never talks directly to a backend.

## Rules

- Selection configures; it never activates playback. Scene editing must not activate a scene or create playback intent.
- Speaker visibility applies globally and never changes scene membership, routing or saved intent. Membership controls must not double as visibility controls.
- The Speakers overview, sidebar, scene editor and details share identity; remembered records stay outside backend collections and route pickers.
- Unavailable members remain editable. Unknown IDs stay Missing speaker without invented transport or playback capabilities.
- Hidden hosts retain fresh snapshots; repaint only visible screens.
- Editor exits return through the host's existing dismissal path, including keyboard actions.
- Keep the sidebar available; no interaction can restore a collapsed sidebar.
- Fitting widths follow shared surface geometry; never widen the shell for a pane.
- Gold means live audio; magenta means group identity. Stock sidebar chrome remains native.
- Report persistence failures in plain words; never swallow them.
- Preserve keyboard focus seeding in visible hosts; headless absence is not dead code.
- Never regenerate the unreproducible macOS 27 device-detail goldens.
- Device and group glyphs share `DeviceIcon` resolution.
- Earlier decisions and traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `MixerWindowController` → Shared configuration screen content and navigation.
- `ContentPaneHostViewController` → Swapped content and footer.
- `SpeakersOverviewViewController` → Global speaker visibility controls; a row opens its speaker's detail.
- `GroupsOverviewViewController` → Saved-scene cards.
- `SidebarViewController` → Configuration destinations and speaker identity.
- `GroupEditorViewController` → Scene name, membership and deletion.
- `GroupCreationSheetController` → Scene creation without activation.
- `DeviceDetailViewController` → Speaker identity, visibility and settings.
- `MainOutDetailViewController` → Main Audio configuration.
