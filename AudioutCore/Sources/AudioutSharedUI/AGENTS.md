# AudioutSharedUI

## Purpose

Shared AppKit rows and window chrome. Hosts own models, routing and persistence; views draw pushed snapshots and report gestures.

## Rules

- Views never read shared model state or call backends or stores directly.
- Visibility is presentation-only. Membership nodes control playback; unavailable names request host recovery and never select.
- Presentation-only unknown speakers gain no invented transport, sync or recovery.
- Hosts adding visibility menu actions preserve existing ones; rebuild items from current identity.
- Row geometry belongs to `PopoverColumnGrid`; columns anchor to the trailing edge.
- Failure preserves selection intent. Availability, selection and controllability are separate.
- The rail governs spine and ring; failed speakers are not reached. Content below rows stays outside its gutter.
- Local fallback audio may light a node without changing selection.
- Equalizer controls open editors; rows edit and store no tone. Names reserve equal accessory space.
- Test hooks use the real action path.
- Reusable views use optional `NSApp` access; no application, no crash.
- Permission prompts suspend transient dismissal across pin changes; restore manners before raising windows.
- Respect accessibility-display changes. Warm ink means `isRouteArmed`, never a row wash; instruments stay flat, no layer blooms.
- Muted ink stays confined to the engaged device mute control.
- Panel beak drawing is sanctioned: stock panels have no arrow.
- The invitation QR tile stays black on white; cameras need it.
- Both transient offers ("Removed, Undo" and "Play here") are host state; rows draw, never decide.
- Earlier decisions and traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `DeviceRowView` → Shared speaker identity, playback and accessory controls.
- `PopoverColumnGrid` → Shared row columns.
- `BusRailOverlayView` → Playback rail and reached-node rendering.
- `ControlPanelBackingView` → Panel bubble and menu-bar beak.
- `ProminentButton` → Primary action control.
- `RemoteInviteView` → Companion invitation.
