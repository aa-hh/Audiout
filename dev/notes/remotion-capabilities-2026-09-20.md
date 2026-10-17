# What Remotion can do for the Audiout videos

Survey taken 2026-09-20 against Remotion 4.0.526 (the version `marketing/video`
is pinned to), from the vendor's own agent skills under
`~/.claude/skills/remotion-best-practices/` plus the live type definitions in
`node_modules/remotion`.

Sources split two ways, and the split matters:

- **Verified** — the export or prop was read out of the installed package, or
  the command was run here.
- **Documented** — the vendor skill describes it and it is not installed yet.
  Believe it, but check the types before writing against it.

Look anything up with the Algolia index the `remotion-docs` skill names, then
fetch the page with `.md` appended to its URL — `https://www.remotion.dev/docs/sequence.md`
is the Markdown source of the Sequence page and costs a fraction of the HTML.

---

## Already spent

| What | Where |
|---|---|
| `interpolate()` + `Easing.bezier` / `Easing.spring` | every animated value |
| `<Sequence from durationInFrames premountFor>` | caption timing in `ScenesVideo.tsx` |
| `Interactive.Div` with inline literal styles | `CaptionCard` |
| `npx remotion still --frame` | checking layout without rendering 900 frames |
| `npx remotion compositions --quiet` | the CI loop over every video |
| `npx remotion browser ensure` | CI fetches its own headless Chrome |

## Worth spending next

**Sound.** `@remotion/sfx` ships hosted one-shots, including
`https://remotion.media/mouse-click.wav`, `switch.wav`, `ding.wav` and
`whoosh.wav`. The Scenes video has seven clicks and a save with nothing under
them. *(Documented.)*

**Burned-in captions.** `@remotion/captions` does word-level highlighting from a
`Caption[]`. Most feed viewing is muted, so if a voiceover is ever added the
captions are not optional. *(Documented.)*

**Voiceover.** The vendor pattern is an ElevenLabs script writing MP3s into
`public/`, then `calculateMetadata` measuring them and sizing the composition to
the audio rather than the other way round. *(Documented.)*

**`<Still>` for thumbnails.** Same components, one frame, no fps or duration.
A YouTube thumbnail per video, rendered by the same CI job. *(Verified: `Still`
is exported.)*

**`<Folder>`.** Groups compositions in the Studio sidebar. Earns its place at
three or four videos, not at one. *(Verified.)*

**`<TransitionSeries>`** with `fade()`, `slide()`, `wipe()`, `clockWipe()`, and
`<TransitionSeries.Overlay>` for an effect over a cut without shortening the
timeline. The Scenes video fakes its one cut by dipping opacity; a real video
built from separate scenes should use this instead. Note transitions *shorten*
total duration by their own length. *(Documented.)*

**Zod schema + `zColor()`** from `@remotion/zod-types` puts typed controls in the
Studio sidebar. The moment a video needs to exist in more than one
configuration — a light-mode cut, a different fleet of speakers — this beats
copying the file. *(Documented.)*

**`calculateMetadata`** can also set `defaultOutName` per composition, which
would let CI name its own files instead of the loop doing it. *(Documented.)*

## Available, probably not for us

- **`@remotion/effects`** — around fifty WebGL effects (`glow`, `vignette`,
  `lightLeak`, `zoomBlur`, `dropShadow`, `halftone`, `scanlines`). They apply to
  canvas-backed components (`<Solid>`, `<CanvasImage>`, `<Video>`,
  `<HtmlInCanvas>`), not to plain DOM, so using one on the rebuilt panel means
  routing it through `<HtmlInCanvas>` first. Renders then need `--gl=angle` or
  `Config.setChromiumOpenGlRenderer("angle")`. A lot of machinery for gloss that
  the app's own restraint argues against. *(Verified: `createEffect` and
  `HtmlInCanvas` are exported.)*
- **`<HtmlInCanvas>`** needs Chrome 149+ with `chrome://flags/#canvas-draw-element`
  on. Not something CI should depend on. *(Verified export.)*
- **Transparent output** — ProRes 4444 or VP9 with alpha, for handing a cut to
  an editor or overlaying on the website. Worth knowing, no use today.
- **`@remotion/media`'s `<Video>` / `<Audio>`, `@remotion/gif`, Lottie, Three.js,
  maps, Mediabunny** — all real, none of them describe anything these videos do.
- **`@remotion/player` and Lambda/Cloudflare rendering** — for a SaaS that renders
  per user. We render in CI; this is the wrong axis.

## Traps found the hard way

- `premountFor` is only on the absolute-fill layout. Passing it alongside
  `layout="none"` is a type error, not a silent no-op.
- The Studio greys out any value it cannot read as a literal inside `style`.
  Hoisting an `interpolate()` into a variable, spreading a base style, or
  referring to a colour constant each cost editability. This is a real tension
  with a tokens file, and the two layers in `marketing/video` resolve it in
  opposite directions on purpose — see that folder's `AGENTS.md`.
- `npx create-video --no-tailwind` still wrote Tailwind into `package.json` and
  `remotion.config.ts`. Harmless, but do not read its presence as a decision.
- `npm i` under npm 11 leaves esbuild's postinstall unrun until the package is
  approved (`npm install-scripts approve esbuild`). Without it the bundler has
  no binary. `npm ci` in CI does not hit this.
- CSS `transition` and `animation` produce their final frame in a render. Every
  motion must read `useCurrentFrame()`.
