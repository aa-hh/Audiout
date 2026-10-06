# AudioutWindowUI

## Purpose

Speakers and Scenes configuration: no window or backend.

## Rules

- Selection and editing never activate scenes or request playback.
- Global visibility never changes membership, routing or saved intent; membership controls never set visibility.
- Sidebars and pages share identity; remembered records never enter backend collections or route pickers.
- Speakers sidebar groups express visibility; show reachability, never routing.
- Unavailable members stay editable; unknown IDs remain Missing speaker, without invented transport or playback.
- Keep hidden snapshots fresh; repaint only visible screens.
- Neither sidebar may collapse; nothing restores it.
- Panes fit shared surface geometry; never widen the shell.
- Gold means live audio, and membership on the scene page; magenta, group identity; green, a reachable speaker. Stock sidebar chrome remains native.
- Custom-drawn: `GroupedSectionView` (Equalizer recesses, no light outlines), `DeviceIconWellView`, `IconPickerViewController` cells, `EqualizerMarkView`. `RollingCountLabel` draws transitions because AppKit has no rolling-count control.
- Report persistence failures plainly; never swallow them.
- Preserve visible-host keyboard focus; headless absence is not dead code.
- Never regenerate the unreproducible macOS 27 device-detail goldens.
- Device and group glyphs share `DeviceIcon` resolution.
- History: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `MixerWindowController` → Scenes and Speakers navigation.
- `ContentPaneHostViewController` → Swapped content and footer.
- `SpeakersPageViewController` → Overview; shimmer: AppKit has none.
- `ListRowView` → Outlined-list row.
- `SidebarViewController` → Speaker list; cells and add button also serve Scenes.
- `ScenesSidebarViewController` → Scene list beside the scene page.
- `GroupEditorViewController` → Scene page: rename, membership, delete.
- `ScenesEmptyPageViewController` → Empty page with one add action.
- `RollingCountLabel` → Count with sliding digits.
- `GroupCreationSheetController` → Scene creation.
- `DeviceDetailViewController` → Speaker page.
- `MainOutDetailViewController` → Main Audio configuration.
- `PageHeaderView` → Every page's icon, name, caption.
- `FlippedView` → Top-down page document.
- `EqualizerMarkView` → Equalizer heading icon.
