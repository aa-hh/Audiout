# AudioutPopoverUI

## Purpose

Menu-bar Mixer and shared surface host. This target renders presentation; Core owns routing decisions.

## Rules

- Consume live snapshot edges; never poll connection state. Failure must retain wanted playback intent.
- Speaker visibility is display-only. Current Main Audio, app-route, live-feed and recovery use must remain visible; inactive scenes alone do not force visibility.
- Remembered presentation records must never enter backend collections or route pickers. Hidden available network speakers must not produce a false discovery-empty message.
- Unavailable names request host recovery; membership nodes remain playback actions. Recovery must never create selection or routes.
- Manage opens Speakers; Pair opens Bluetooth settings. Pair remains reachable when Bluetooth collapses.
- Hidden surfaces remain idle. Opens refresh current state; preference changes must not construct hidden screens.
- Keep one bounded output-list scroll area; preserve the shared row columns and rail order through collapse.
- Publish height through the existing content-size channel. Screen swaps must not resize the session frame.
- Keep one sync drawer. Scrubs affect audio immediately but persist only when committed.
- Equalizer buttons open editors; the Mixer contains no tone editor.
- Permission answers restore window manners; abandoned alignment runs must not reopen the surface.
- AppKit owns toolbar chrome; screen cues must work on every supported macOS version.
- Group-route membership stays live; exclusivity must not hide saved-group choices.
- Earlier decisions and traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `PopoverController` → Mixer presentation and host action dispatch.
- `PopoverPanelViewController` → Hosted Mixer panel content.
- `AppSurfaceController` → Shared shell and screen lifecycle.
- `SurfaceToolbarController` → Native toolbar screen and pin actions.
