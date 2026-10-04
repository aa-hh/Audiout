# AudioutPopoverUI

## Purpose

Menu-bar Mixer and shared surface host; it renders, Core owns routing.

## Rules

- React to connection-state edges, never poll; failure keeps wanted playback intent.
- Speaker visibility is display-only. Current Main Audio, app-route, live-feed and recovery use stay visible; inactive scenes alone force nothing.
- Remembered presentation records stay out of backend collections and route pickers; a hidden available network speaker never triggers the discovery-empty message.
- Unavailable names request host recovery, which never creates selection or routes; membership nodes stay playback actions.
- Manage opens Speakers; Pair opens Bluetooth settings and stays reachable when Bluetooth collapses.
- Hidden surfaces stay idle: opens refresh; preference changes never build hidden screens.
- One bounded output-list scroll area; row columns and rail order survive collapse. `updateRailRows` names each collapsed subsection hiding a reached speaker (DESIGN.md "Membership rail extent").
- Publish height through the content-size channel; screen swaps never resize the session frame.
- One sync drawer; scrubs sound immediately, persist only when committed.
- Permission answers restore window manners; abandoned alignment runs never reopen the surface.
- AppKit owns toolbar chrome; screen cues work on every supported macOS.
- Group-route membership stays live; exclusivity never hides saved-group choices.
- Equalizer buttons open editors; the Mixer contains no tone editor.
- The alignment note may carry one underlined text action left of its button, both centred.
- Under the limit the note is session state (`limitNoteRaised`) shown by a wizard door, not the wizard; the thank-you card's shown flag is written on Close or hide, not raise.
- Earlier decisions and traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `PopoverController` → Mixer presentation and host actions.
- `PopoverPanelViewController` → Hosted Mixer panel content.
- `AppSurfaceController` → Shared shell and four screens' lifecycle.
- `SurfaceToolbarController` → Native toolbar screen and pin actions.
