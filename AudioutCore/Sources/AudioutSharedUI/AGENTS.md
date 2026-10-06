# AudioutSharedUI

## Purpose

Shared AppKit rows and window chrome. Hosts own models, routing and persistence; views draw snapshots and report gestures.

## Rules

- Views never touch shared model state, backends or stores.
- Visibility is presentation-only. Membership nodes control playback; unavailable names request host recovery, never select.
- Unknown speakers gain no invented transport, sync or recovery.
- Hosts adding visibility menu actions preserve existing ones; rebuild items from current identity.
- Row geometry belongs to `PopoverColumnGrid`; columns anchor to the trailing edge.
- Failure preserves selection intent. Availability, selection and controllability are separate.
- The rail governs spine and ring; failed speakers go unreached; content below rows stays outside its gutter.
- Local fallback audio may light a node without changing selection.
- Equalizer controls open editors; rows hold no tone. Names reserve equal accessory space.
- Test hooks use the real action path.
- Reusable views use optional `NSApp` access; no application, no crash.
- Permission prompts suspend transient dismissal across pin changes; restore manners before raising windows.
- Respect accessibility-display changes. Warm ink means `isRouteArmed`, never a row wash; instruments stay flat; only pending Cast holds glow.
- Muted ink belongs only to the engaged device mute control.
- `Tokens.Color.shadow`'s four consumers stay flat, clipped, never an `NSShadow`: `WarmFaderCell`, `AlignmentPlateCell`, `GroupedSectionView`'s `.well`, `SetupPreviewFrameView`.
- Panel beak drawing is sanctioned: stock panels have no arrow.
- The invitation QR tile stays black on white for cameras.
- Both transient offers ("Removed, Undo", "Play here") are host state; rows draw, never decide.
- Earlier decisions and traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `DeviceRowView` → The shared speaker row.
- `PopoverColumnGrid` → Shared row columns.
- `BusRailOverlayView` → The playback rail.
- `ControlPanelBackingView` → Panel bubble and beak.
- `ProminentButton` → Primary action control.
- `RemoteInviteView` → Companion invitation.
