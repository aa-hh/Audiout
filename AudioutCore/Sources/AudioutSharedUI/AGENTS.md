# AudioutSharedUI

## Purpose

Shared AppKit rows and window chrome. Hosts own models, routing and persistence; views draw snapshots, report gestures, and never touch model state, backends or stores.

## Rules

- Visibility is presentation-only. Membership nodes control playback; unavailable names request host recovery and never select.
- Unknown speakers gain no invented transport, sync or recovery.
- Hosts adding visibility menu actions preserve existing ones; rebuild items from current identity.
- Row geometry belongs to `PopoverColumnGrid`; columns anchor to the trailing edge.
- Failure preserves selection intent. Availability, selection and controllability are separate.
- The rail governs spine and ring; failed speakers go unreached; content below rows stays outside its gutter.
- Local fallback audio may light a node without changing selection.
- Equalizer controls open editors; rows hold no tone. Names reserve equal accessory space.
- Test hooks use the real action path.
- Reusable views treat `NSApp` as optional.
- Permission prompts suspend transient dismissal across pin changes; restore manners before raising windows.
- Respect accessibility-display changes. Warm ink means `isRouteArmed`, never a row wash; instruments stay flat; pending Cast glows.
- Muted ink belongs only to an engaged mute.
- `Tokens.Color.shadow` draws flat clipped bands, never an `NSShadow`.
- The invitation QR stays black-on-white for cameras.
- "Removed, Undo" and "Play here" offers are host state; rows draw, never decide.
- Earlier decisions and traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `DeviceRowView` → Shared speaker row.
- `PopoverColumnGrid` → Row columns.
- `BusRailOverlayView` → Playback rail.
- `ControlPanelBackingView` → Bubble and beak; stock panels lack arrows.
- `ProminentButton` → Gold call-to-action.
- `RemoteInviteView` → Companion invitation.
- `RowVolumeFader` → Row volume slider.
- `HoverTracker` → Pointer-checked hover.
- `RuleView` → Divider line.
- `TintedNoteBackgroundView` → Notice card ground.
- `TextLinkButton` → Underlined link.
- `FoldingClipView` → Advanced-disclosure fold.
