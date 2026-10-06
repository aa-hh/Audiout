# AudioutPopoverUI

## Purpose

Menu-bar Mixer and shared surface host; Core owns routing.

## Rules

- React to connection-state edges, never poll; failure keeps wanted playback intent.
- Speaker visibility is display-only. Current Main Audio, app-route, live-feed and recovery use stay visible; inactive scenes alone force nothing.
- Remembered records stay out of backend collections and route pickers; a hidden available network speaker never triggers the discovery-empty message.
- Unavailable names request host recovery, never selection or routes; membership nodes stay playback actions.
- Manage opens Speakers; Pair opens Bluetooth settings and stays reachable when Bluetooth collapses.
- Hidden surfaces stay idle: opens refresh; preference changes never build hidden screens.
- One bounded output-list scroll area; row columns and rail order survive collapse. `updateRailRows` names each collapsed subsection hiding a reached speaker (DESIGN.md "Membership rail extent").
- Publish height through the content-size channel; screen swaps never resize the session frame.
- One sync drawer; scrubs sound immediately, persist only when committed.
- Permission answers restore window manners; abandoned alignment runs never reopen the surface.
- The tab capsule (`SurfaceToolbarTabCapsule`) and Pin are custom-drawn: AppKit's toolbar hover and selection are two unsettable shapes. No cue sits behind `#available`.
- Group-route membership stays live; exclusivity never hides saved-group choices.
- The alignment note may carry one underlined text action left of its button, both centred.
- Under the limit the note is session state (`limitNoteRaised`) a wizard door shows, not the wizard; the thank-you card is marked shown on Close or hide, not raise.
- Earlier decisions and traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `PopoverController` → Mixer presentation and actions.
- `PopoverPanelViewController` → The Mixer panel.
- `AppSurfaceController` → Shared shell and four screens.
- `SurfaceToolbarController` → Header strip: screen tabs and Pin.
- `CardMessageRow` → A card's empty or permission row.
