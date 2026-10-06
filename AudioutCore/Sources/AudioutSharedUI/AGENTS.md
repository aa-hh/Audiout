# AudioutSharedUI

## Purpose

Shared AppKit rows, pages and chrome. Hosts own models, routing and persistence; views draw and report gestures, never touching models, backends or stores.

## Rules

- Visibility is presentation-only. Membership nodes control playback; unavailable names request host recovery and never select.
- Unknown speakers gain no invented transport or recovery.
- Visibility menu actions preserve existing ones; rebuild from identity.
- Row geometry belongs to `PopoverColumnGrid`; columns anchor to the trailing edge.
- Failure preserves selection intent; availability, selection and controllability are separate.
- The rail governs spine and ring; failed speakers go unreached; content below rows stays outside its gutter.
- Local fallback audio may light a node without changing selection.
- Equalizer controls open editors; rows hold no tone. Names reserve equal accessory space.
- Test hooks use the real action path.
- Reusable views treat `NSApp` as optional.
- Permission prompts suspend transient dismissal across pin changes; restore manners before raising windows.
- Respect accessibility-display changes. Warm ink means `isRouteArmed`, never a wash; instruments stay flat; pending Cast glows.
- Muted ink belongs only to an engaged mute.
- `Tokens.Color.shadow` draws flat clipped bands, never `NSShadow`.
- The invitation QR stays black-on-white for cameras.
- "Removed, Undo" and "Play here" offers are host state; rows draw, never decide.
- Custom-drawn: `GroupedSectionView` and `DeviceIconWellView`.
- History: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `DeviceRowView` → Speaker row.
- `PopoverColumnGrid` → Row columns.
- `BusRailOverlayView` → Playback rail.
- `ControlPanelBackingView` → Panel bubble.
- `ProminentButton` → Gold call-to-action.
- `RemoteInviteView` → Companion invitation.
- `RowVolumeFader` → Row fader.
- `HoverTracker` → Hover tracking.
- `RuleView` → Divider.
- `TintedNoteBackgroundView` → Note ground.
- `TextLinkButton` → Link.
- `FoldingClipView` → Disclosure fold.
- `PageHeaderView` → Page header.
- `ListRowView` → Outlined-list row.
- `GroupedSectionView` → Card or well box.
