# AudioutWindowUI

## Purpose

Configuration-only Speakers and Scenes content: no window, no backend.

## Rules

- Selection and editing never activate scenes or request playback.
- Global visibility never changes membership, routing or saved intent; membership controls never set visibility.
- Sidebars and pages share identity; remembered records stay outside backend collections and route pickers.
- Speakers sidebar groups express visibility; show reachability, never routing.
- Unavailable members stay editable; unknown IDs remain Missing speaker, without invented transport or playback.
- Keep hidden snapshots fresh; repaint only visible screens.
- Neither sidebar may collapse; nothing restores it.
- Panes fit shared surface geometry; never widen the shell.
- Gold means live audio, and membership on the scene page; magenta, group identity; green, a reachable speaker. Stock sidebar chrome remains native.
- Custom-drawn: `GroupedSectionView` (Equalizer recesses; light cards omit outlines), `DeviceIconWellView`, `IconPickerViewController` cells, `EqualizerMarkView`.
- Report persistence failures plainly; never swallow them.
- Preserve visible-host keyboard focus seeding; headless absence is not dead code.
- Never regenerate the unreproducible macOS 27 device-detail goldens.
- Device and group glyphs share `DeviceIcon` resolution.
- History: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `MixerWindowController` → Scenes and Speakers navigation.
- `ContentPaneHostViewController` → Swapped content and footer.
- `SpeakersPageViewController` → Overview; shimmer: AppKit has none.
- `ListRowView` → Outlined-list row.
- `SidebarViewController` → Speaker list; its cells and add button serve the scenes sidebar too.
- `ScenesSidebarViewController` → Scene list beside the scene page.
- `GroupEditorViewController` → Scene page: rename, membership, delete.
- `ScenesEmptyPageViewController` → No-scenes page with the one add action.
- `RollingCountLabel` → Count whose digits slide on a change.
- `GroupCreationSheetController` → Scene creation.
- `DeviceDetailViewController` → Speaker page.
- `MainOutDetailViewController` → Main Audio configuration.
- `PageHeaderView` → Every page's icon, name, caption.
- `FlippedView` → Top-down page document.
- `EqualizerMarkView` → Equalizer heading icon.
