# HANDOVER — Remotion demo videos, and the mixer-fidelity pass

Written 2026-09-20 for someone with NO access to the working conversation.
Everything you need is in this worktree. Read this file top to bottom before
touching anything.

## Where you are

- Worktree: `.claude/worktrees/trusting-liskov-371f2b`, branch
  `claude/remotion-demo-videos-726553`, HEAD **`c30732c6`**, pushed, open as
  [PR #216](https://github.com/aa-hh/Audiout/pull/216).
- Four commits are landed; the first three are **green in CI**. On top of them sits
  **uncommitted working-tree state** — one finished track of a four-track work
  order. **The tree is the truth. Do not restore from HEAD.**
- Nobody has committed the uncommitted part on purpose: the work order says the
  owner sees the final report before anything is committed.
- `main` is merge-only. Work stays on this branch until Alec merges.
- Read `AGENTS.md` (root) and `marketing/video/AGENTS.md` before editing. They
  are binding. `marketing/video/AGENTS.md` is itself stale in two places —
  Track D below fixes it.

## 1. What this is

`marketing/video/` is a [Remotion](https://remotion.dev) project — React
components rendered frame by frame into MP4s. It is **the only JavaScript in
this repo** and ships nothing to users. Its job is short vertical videos
(1080x1920) that show the Mac app off on YouTube Shorts and similar.

One composition exists, `Scenes` (30 s): arm three speakers, set a level, save
the set as a scene, recall it the next morning with one click.

`.github/workflows/marketing-video.yml` renders every composition on a
`macos-latest` runner and uploads the MP4s as artifacts. It runs on any pull
request touching `marketing/video/`, or on demand from the Actions tab. It must
be macOS: the panel is set in SF Pro, and a Linux runner falls back to DejaVu
Sans without saying so. Measured: 900 frames in about 10 s, whole job 74 s.

**The app on screen is rebuilt in React, not screen-recorded.** `src/mixer.tsx`
reproduces the Mixer panel. That was a deliberate choice and it is re-argued in
§4 — do not undo it without reading that section.

## 2. Alec's verdict, and the job in front of you

> "the video was fine except for the fidelity of the design."

So: story, pacing, captions and timings are APPROVED and must survive
unchanged. The work is making the panel match the real app **measurably**.

Alec's ruling, 2026-09-20: the panel goes to its real **653 pt** width and the
camera fits the whole panel with no panning. On-screen text gets about 21 %
smaller as a result. That trade was put to him explicitly and accepted.

## 3. The work order, and what is done

**`dev/notes/work-order-2026-09-20-mixer-fidelity.md`.** Read it, *including the
APPENDIX at the end, which overrides the steps above it where they conflict.*

It cost two full research passes and two adversarial spec-checks, which between
them caught 17 defects in earlier drafts. **Do not re-scope it.**

| Track | Files | State |
|---|---|---|
| **A — tokens + panel** | `src/tokens.ts`, `src/mixer.tsx` | **DONE**, uncommitted, `tsc` exit 0 |
| **B — measuring harness** | `src/MixerStill.tsx` (new), `src/Root.tsx`, `scripts/fidelity.sh` (new), `.gitignore` | **OWED** |
| **C — the video** | `src/ScenesVideo.tsx` | **OWED** |
| **D — folder rules** | `marketing/video/AGENTS.md` | **OWED** |

B and C run in parallel; both read from A and touch no shared file. D is
independent of everything. Then: one combined verification, then a review.

`git diff --stat` on the uncommitted part should show exactly:

```
 marketing/video/src/mixer.tsx | 786 ++++++++++++++++++-------------
 marketing/video/src/tokens.ts | 131 +++++--
```

plus one untracked path: `marketing/video/reference/` (four PNGs, see §5).

## 4. Why the panel is rebuilt rather than captured

This gets proposed every time someone sees the fidelity problem, so here is why
it was rejected, with the evidence:

1. **`popover-snapshot` has no state argument.** Every scenario is a hardcoded
   function selected by `AIRPLAY_SNAPSHOT_MODE`
   (`AudioutCore/Sources/popover-snapshot/main.swift:1069-1123`); the fixture's
   selection, volumes and routes are literals (`:161-184`). Driving the video's
   states means editing app code to serve the video, which is forbidden.
2. **The panel animates on roughly 130 of its 900 frames** — speakers ramp over
   14 frames, a slider drags over 54, the hint fades over 14. A still carries
   none of it.
3. **CI is Node-only** (`.github/workflows/marketing-video.yml:28`). Captures in
   CI would mean a full `AudioutCore` build on every pull request.

The capture is therefore the **reference and the measuring stick**, never a
video asset.

## 5. How fidelity is measured — this is the whole point

No eyeballing. There is a number.

**Render the reference** (from the repo root):

```bash
AUDIOUT_RUN_PRODUCT=popover-snapshot bash scripts/run-app.sh "$PWD/marketing/video/reference"
```

This builds the **real** `PopoverController` against `MockBackend` and renders
it offscreen — headless, no TCC grant, no signed app, no live-test slot. About
35 s. Output: 653x758 pt at a pinned 2x backing scale = **1306x1516 px**.

**Compare with ffmpeg's `ssim` filter.** ImageMagick is NOT installed on this
machine; ffmpeg is, at `/opt/homebrew/bin/ffmpeg`. It prints nothing below
`-loglevel info`.

**The gate: blurred SSIM (`boxblur=4:1`) >= 0.95.** That floor is calibrated,
not invented — against this same reference, a uniform 2 pt shift scores 0.956
and a 4 pt shift scores 0.925, so 0.95 means every column and row lands within
about 2 pt. Report the unblurred number alongside it; it sits lower because
Chrome and AppKit antialias text differently, and that gap is expected.

Track B writes `marketing/video/scripts/fidelity.sh` to do all of this. It does
not exist yet.

## 6. THE RULE THAT OUTRANKS EVERY DOCUMENT

**Where a document and the rendered reference disagree, the render wins.**

Two review passes disagreed with each other about individual constants. Direct
measurement settled it in both directions — the divider really is
`rgb(174,179,187)` as the work order said, but its span is 38.5 → 653, not the
14 → 639 the work order claimed.

Track A then found **14 more** discrepancies the same way. Measure anything
described as "measured", use your measurement, and **name the discrepancy in
your report**. Python 3 with Pillow is available:

```python
from PIL import Image
im = Image.open('marketing/video/reference/popover-dark.png').convert('RGB')
GROUND = (0x15, 0x17, 0x1A)   # the panel's own background
xs = [x for x in range(im.size[0]) if im.getpixel((x, y)) != GROUND]  # px; /2 for pt
```

### What Track A found and already corrected

Worth knowing, because the work order still carries the old numbers:

- **Panel top inset is 23.0, not 22.75** — this alone was putting every row
  0.25 pt low. Rule gaps are 15.0 and 14.0, not 15.25 / 13.75. Meter offsets
  are +7.5 and +6.0, not +7.75 / +6.25.
- **Meters appear only on live rows.** Idle rows have no meter track at all.
- **The Main Audio row draws no selection wash**, despite being live.
- **Unselected rail node rims are `ember` `#8A6A2F`**, and the stroke's
  centreline radius is 4.75 — the 11 pt diameter is the outer edge.
- **The fader thumb genuinely overhangs its track by 2 pt at each end.** The
  fitted formula is `centre = 300 + 1.44 x value`. That is what AppKit draws.
- **Subsection titles sit at x 74.5, not 54.5** — 54.5 is the chevron's leading.
- **The "Source"/"Offset" legend collision does not exist** — they are on
  different card headers. Only "Output" moved.
- The armed fill gradient starts at `rgb(187,147,62)`, not pure ember; the thumb
  is translucent (`raised` at ~0.4 alpha); the popup's top lip is 0.5 pt, not 1.

### One open question Track A raised

The reference draws **three disclosure chevrons** (card headers at x 38.5, the
subsection at x 54.5, ~11.5 pt of ink each) that the rebuild omits. No step asks
for them. They will cost a little on the SSIM number. Track A estimated ten
lines to add. **Ask Alec, or just add them and report the delta.**

## 7. Verification for the combined tree

Run from `marketing/video` unless stated. All of it, once, after B, C and D are in.

| Command | Expected |
|---|---|
| `git status --porcelain` (repo root) | no entry under `AudioutCore/`, `scripts/`, `docs/`, `.github/` |
| `npx tsc --noEmit` | exit 0, no output |
| `bash scripts/fidelity.sh` | both SSIM numbers; **blurred >= 0.95** |
| `npx remotion render Scenes out/Scenes.mp4 --log=error` | exit 0, 900 frames, 1080x1920 |

## 8. Traps

- **`popover-snapshot` with no argument overwrites `dev/notes/popover-snapshots/`**,
  which is committed reference material. The output-directory argument is
  mandatory. A default run writes FOUR PNGs, not two.
- The recorded "snapshot goldens are unreproducible" trap is **`window-snapshot`
  alone**. `popover-snapshot` reproduces byte-for-byte — different capture call
  (`cacheDisplay(in:to:)` vs `displayIgnoringOpacity`). Do not let the older
  note talk you out of using it.
- **Remotion Studio only keyframes values it can read inline.** Hoisting an
  `interpolate()` into a variable, spreading a base style, or pulling a colour
  from `tokens.ts` each grey out the control. This is why `CaptionCard` in
  `src/chrome.tsx` hardcodes its styles while the panel reads tokens — the two
  layers resolve the tension in opposite directions on purpose. **Do not "tidy"
  the captions into tokens.**
- **`premountFor` exists only on the absolute-fill layout.** Passing it
  alongside `layout="none"` is a type error, not a silent no-op.
- CSS `transition` and `animation` render as their final frame. Every motion
  must read `useCurrentFrame()`.
- `npx create-video --no-tailwind` installs Tailwind anyway. It was removed in
  commit `0f3800e4`; do not let a scaffold put it back.
- npm 11 leaves esbuild's postinstall unrun until the package is approved
  (`npm install-scripts approve esbuild`). Without it the bundler has no binary.
  `npm ci` in CI does not hit this.
- Never run bare `swift build` / `swift test` / `swift run` / `xcodebuild` /
  `swift package` — a hook denies them. The only Swift command in this whole
  body of work is the `run-app.sh` line in §5.

## 9. Do not touch

- **Anything under `AudioutCore/`, `AirPlayEngine/`, `scripts/`, `.github/`,
  `DESIGN.md`, `docs/`.** The video reads from the app; the app never bends to
  the video. If a metric seems missing, it is missing from the work order —
  stop and report rather than adding a snapshot mode.
- `dev/notes/popover-snapshots/` and `docs/media/popover-dark.png` — read-only,
  and both are stale in their copy ("Output Devices", "Selected Devices").
  Neither is the reference. Render a fresh one.
- `marketing/video/remotion.config.ts` — a scale or image-format change there
  also changes the video render.
- `marketing/video/package.json` / `package-lock.json` — **no new dependency.**
  ffmpeg and Node cover the whole measurement.
- `BEAT`, caption text, caption `<Sequence>` boundaries, cursor frame timings,
  the click list, the time-cut, the outro. Alec approved the pacing.

## 10. Where the other videos were going

Alec's brief was a series. Video 2 was to be **Bluetooth sync**: a speaker
lagging, the alignment wizard measuring it with the Mac's microphone, the offset
landing, everything in step. Its real copy lives in
`AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift` and
`AudioutCore/Sources/AudioutSharedUI/BTSyncDrawerView.swift` — quote it, never
invent it.

`dev/notes/remotion-capabilities-2026-09-20.md` lists what Remotion offers that
this project has not spent yet: sound effects under the clicks (there are seven
silent ones), burned-in captions, voiceover sized by `calculateMetadata`,
`<Still>` thumbnails, real scene transitions. Each entry is marked either
verified against the installed package or merely documented by the vendor.
