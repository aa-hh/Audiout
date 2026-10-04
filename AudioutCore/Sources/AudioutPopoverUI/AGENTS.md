# AudioutPopoverUI

## Purpose

Menu-bar Mixer and shared surface host. It renders presentation; Core owns routing decisions.

## Rules

- Consume live snapshot edges, never poll connection state; failure retains wanted playback intent.
- Speaker visibility is display-only. Current Main Audio, app-route, live-feed and recovery use stay visible; inactive scenes alone force nothing.
- Remembered presentation records never enter backend collections or route pickers. A hidden available network speaker must not trigger the discovery-empty message.
- Unavailable names request host recovery; membership nodes remain playback actions. Recovery never creates selection or routes.
- Manage opens Speakers; Pair opens Bluetooth settings and stays reachable when Bluetooth collapses.
- Hidden surfaces stay idle: opens refresh state; preference changes never construct hidden screens.
- Keep one bounded output-list scroll area; shared row columns and rail order survive collapse.
- Publish height through the content-size channel; screen swaps never resize the session frame.
- One sync drawer; scrubs affect audio immediately but persist only when committed.
- Permission answers restore window manners; abandoned alignment runs never reopen the surface.
- AppKit owns toolbar chrome; screen cues work on every supported macOS version.
- Group-route membership stays live; exclusivity never hides saved-group choices.
- Equalizer buttons open editors; the Mixer contains no tone editor.
- The alignment note may carry one underlined text action left of its button, both centred.
- Under the limit the note is session state (`limitNoteRaised`), shown by a wizard door, not the wizard; the thank-you card's shown flag is written on Close or hide, never on raise.
- Earlier decisions and traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `PopoverController` → Mixer presentation and host action dispatch.
- `PopoverPanelViewController` → Hosted Mixer panel content.
- `AppSurfaceController` → Shared shell and the four screens' lifecycle.
- `SurfaceToolbarController` → Native toolbar screen and pin actions.
