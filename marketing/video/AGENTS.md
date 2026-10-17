# marketing/video

## Purpose

Remotion videos that show the Mac app off — vertical, caption-led, for YouTube
Shorts and the other feeds. The only JavaScript in this repo. It ships nothing
to users and no app code may ever import from here.

The app on screen is **rebuilt**, not recorded, so no build, speaker or TCC
grant is in the loop. That makes it a likeness that can silently go stale:
check it against a fresh `docs/media/popover-dark.png` before publishing.

## Rules

- Copy on screen is quoted from the Swift source, never invented. Card titles
  and menu items live in `PopoverController.swift`; colours and point metrics
  in [`DESIGN.md`](../../DESIGN.md). If it is not in one of those, it is wrong.
- The rebuild is deliberately partial (no mute control, no App Routing card) so
  the panel stays narrow enough to read on a phone. Adding a column costs
  camera zoom — see the next rule.
- The camera scales and never pans: at 2.0× the panel already fills the frame's
  width, so any sideways move slices a column off the edge.
- `layout()` gives rows and rail one set of y values. The rail is drawn from the
  row positions, so a height in `H` moves both or neither.
- The first-run hint fades but keeps its slot (`hintOpacity`). Unmounting it
  reflows the whole panel mid-shot.
- Studio only keyframes values it can read inline, so `CaptionCard` hardcodes
  its styles while the panel reads `tokens.ts`. Do not "tidy" the captions into
  tokens — it greys out every control in the Studio.
- Caption timing is its `<Sequence>`'s `from`/`durationInFrames`, so the
  timeline can drag it. Nothing else may own a caption's timing.
- TRAP: `premountFor` exists only on the absolute-fill layout. With
  `layout="none"` it is a type error, so captions take the wrapper.
- TRAP: CSS `transition` and `animation` render as their final frame. Every
  motion reads `useCurrentFrame()`.
- Renders must run on macOS — the type is SF Pro. Linux falls back to DejaVu
  Sans and says nothing.
- What Remotion offers that this project has not spent yet:
  [dev/notes/remotion-capabilities-2026-09-20.md](../../dev/notes/remotion-capabilities-2026-09-20.md).

## Map

- `tokens.ts` — the app's colours and point metrics, copied from DESIGN.md.
- `mixer.tsx` — the rebuilt Mixer panel; `layout()` places it, `Mixer` draws it.
- `chrome.tsx` — pointer, click ripple, AppKit menu, `CaptionCard`.
- `ScenesVideo.tsx` — the Scenes video; `BEAT` holds every moment in frames.
- `Root.tsx` — composition registry.
