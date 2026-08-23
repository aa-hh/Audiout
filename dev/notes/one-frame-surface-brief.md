# One frame, three screens — design brief (shape, 2026-08-22)

Confirmed with Alec 2026-08-22 ("perfect"). Plan only; no code written under this brief.
Full discovery + research: https://claude.ai/code/artifact/be7614a9-b197-4a70-b690-3865760194cc

## Problem

Every screen of the one-surface window (`AppSurfaceController`) asks for its own
frame and the shell animates to it on each tab switch: Mixer 623 × exact-fit
(~780 with 8 speakers + 2 apps), Groups 623 → 708 × ~580 (widens once a group is
selected; sidebar minimum is 210, the "623 holds" comment assumed 200), Settings
460 × ~245–345 per pane. Unpinned, every resize re-centres on the menu-bar icon,
so a WIDTH change slides the toolbar tab strip up to ~82 pt out from under the
cursor. Width is the whole defect; top-anchored height changes never moved the
toolbar. Owner already ruled once (2026-08-12) that a width change on a screen
switch "reads as the surface twitching".

## Decision: A — one frame, sections fill it

- **One frame.** 623 wide. Height fixed for the session: the Mixer's exact fit at
  open, floored at 600, capped to the screen's visible frame. No screen switch,
  fold, drawer or pane change ever resizes or moves the window after open.
  Pinned and unpinned behave identically.
- **Mixer.** Fills the frame; folds and drawers move rows INSIDE it — the
  existing surplus shield (`contentContainer <= view`, inert canvas below the
  last card) absorbs the gap. `surfaceResizer` no longer resizes the window.
  Content taller than the frame is roadmap 039's call (scroll) — out of scope,
  but it must not clip silently (at minimum: log/assert, and the frame's
  fit-at-open already covers the opening state).
- **Groups.** Fills the frame. Sidebar minimum drops so the split never asks for
  more than 623 total. Session drag-memory (`rememberedGroupsFrameSize`) and
  per-screen user resizability (`setUserResizable`) are removed — nothing in
  the surface resizes.
- **Settings.** Fills the frame at 623 (`SettingsForm.contentWidth` stops being
  a window width). Replace the in-content tab row (`.segmentedControlOnTop`)
  with the Groups screen's own layout: a sidebar of sections on the left, one
  pane on the right — same sidebar width, same type, same selection treatment
  as Groups. One system across both arrangement screens; one tab level in the
  app. New sections planned by the owner (AirPlay / Bluetooth / Chromecast
  per-output-type settings, delay trim, what's connected, the roadmap-050
  list) become sidebar rows, not tabs. Pane content top-aligned; short panes
  leave calm canvas — never centred, never stretched.
- **Untouched.** Toolbar (tabs, centred title, Pin, Quit), pin/unpin manners,
  ⌘1/⌘2/⌘3, the fold clock (`FoldAnimator`), the Mixer's rail and row
  mechanics, Reduce Motion behaviour, the "no NSScrollView" rule.
- **Anti-goals.** No re-centring on the anchor after open; no per-screen sizes;
  no second tab level anywhere; no new window.

## Assumed defaults (owner may override)

1. Height policy = Mixer fit-at-open, floor 600 (vs. one hard constant).
2. Groups loses its drag memory.

## Verification owed

- Full `swift test` green; `*-snapshot` targets regenerated (popover, window,
  settings) and checked in.
- Live: switch Mixer → Groups → Settings → Mixer unpinned and pinned; the tab
  strip, Pin and Quit must not move a single point; the window frame must not
  change. Collapse/expand a card and open a sync drawer on the Mixer: window
  frame unchanged.
