# AudioutSharedUI

## Purpose

AppKit rows and window chrome shared across surfaces. Hosts own models, routing and persistence; views draw pushed snapshots and report gestures.

## Rules

- Views never read shared model state or call a backend/store directly.
- Visibility is presentation-only. Membership nodes control playback; unavailable names request recovery through the host and never select implicitly.
- Presentation-only unknown speakers must not gain invented transport, sync or recovery capabilities.
- Preserve existing menu actions when hosts add visibility actions; rebuild menu items from current identity.
- Row geometry belongs to `PopoverColumnGrid`; columns anchor to the trailing edge.
- Failure preserves selection intent. Availability, selection and controllability are separate concerns.
- The rail governs both spine and ring; failed speakers are not reached. Content below rows stays outside its gutter.
- Local fallback audio may light a node without changing selection.
- Equalizer controls open editors; rows edit and store no tone. Names reserve equal accessory space.
- Test hooks must use the real delegate/control action path.
- Use optional `NSApp` access in reusable views; missing applications must not crash.
- Permission prompts suspend transient dismissal across pin changes; restore manners before bringing the window forward.
- Respect accessibility-display changes. Keep instruments flat; no layer blooms.
- Muted ink stays confined to the engaged device mute control.
- Panel beak drawing is sanctioned because stock panels have no arrow.
- The invitation QR tile remains fixed black on white; cameras require that contrast.
- Earlier decisions and traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `DeviceRowView` → Shared speaker identity, playback and accessory controls.
- `PopoverColumnGrid` → Shared row columns.
- `BusRailOverlayView` → Playback rail and reached-node rendering.
- `ControlPanelBackingView` → Panel bubble and menu-bar beak.
- `ProminentButton` → Primary action control.
- `RemoteInviteView` → Companion invitation.
