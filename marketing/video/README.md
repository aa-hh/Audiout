# Marketing videos

Short vertical videos (1080×1920, 30 fps) that show the Mac app off, built with
[Remotion](https://remotion.dev) — React components rendered frame by frame.

| Composition | What it shows |
|---|---|
| `Scenes` | Pick speakers, set their levels, save the set as a scene, recall it with one click. 30 s. |

## The app in these videos is a rebuild, not a recording

`src/mixer.tsx` rebuilds the Mixer panel in React. Its colours and point metrics
are copied from the app's [`DESIGN.md`](../../DESIGN.md) and its copy from
`PopoverController.swift`, but it is a likeness: it leaves out the mute control
and the App Routing card, and it lays itself out with its own arithmetic so the
routing rail can be drawn from the same numbers as the rows.

**When the real panel changes, this does not follow automatically.** Check it
against a fresh `docs/media/popover-dark.png` before publishing anything.

## Working on one

```bash
npm install
npx remotion studio
```

The studio opens at `http://localhost:3000`; a composition has its own URL, e.g.
`http://localhost:3000/Scenes`. Scrub the timeline, edit a file, watch it update.

Every moment in a video is a frame number in the `BEAT` object at the top of its
file. Retiming means changing numbers there and nothing else.

## Rendering

Push the branch and let GitHub Actions do it —
[`.github/workflows/marketing-video.yml`](../../.github/workflows/marketing-video.yml)
renders every composition on a macOS runner and uploads the MP4s as artifacts.
It runs on any pull request touching `marketing/video/`, or on demand from the
Actions tab, where the `composition` input renders just one.

It has to be macOS: the panel is set in SF Pro, which only exists on a Mac. A
Linux runner falls back to DejaVu Sans and every frame comes out wrong.

Locally, if you want it now:

```bash
npx remotion render Scenes out/scenes.mp4
```
