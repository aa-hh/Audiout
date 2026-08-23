# Visual Consistency Audit (Task A4)

## Method

Ran all four offscreen snapshot generators from `AudioutCore/` (`swift build` cold
build first, ~17s; each `swift run` thereafter incremental):

- `swift run popover-snapshot` — default mode: 4 PNGs (`popover-{light,dark}.png`,
  `popover-meters-{light,dark}.png`).
- `AIRPLAY_SNAPSHOT_MODE=connection-states swift run popover-snapshot` — 2 PNGs
  (`popover-connection-{light,dark}.png`).
- `AIRPLAY_SNAPSHOT_MODE=live-routing swift run popover-snapshot` — 2 PNGs
  (`popover-live-routing-{light,dark}.png`). Not explicitly named in the task brief,
  but it's a third mode the same executable supports and the checked-in tree already
  carried its output, so it was regenerated too for a complete comparison.
- `swift run window-snapshot` — 10 PNGs (`mixer-{1-default,2-create-sheet,
  3-edit-group,4-device-detail,5-panel-chrome}-{light,dark}.png`).
- `swift run settings-snapshot` — 2 PNGs (`settings-{light,dark}.png`).
- `swift run onboarding-snapshot` — 6 PNGs (`onboarding-{light,dark}-{initial,
  resolved,denied}.png`).

Total: **26 PNGs**, matching the expected count. All were read with vision (not just
diffed), light/dark pairs compared side by side, and several were pixel-sampled
(cropped with `sips`, sampled with a scratch-venv Pillow script) to turn a visual
hunch into a measured RGB/geometry claim before writing it up.

**Evidence check (`git status` / `git diff --stat` on the snapshot dirs):**
20 of 26 regenerated PNGs differ from the checked-in versions — every `popover-*.png`
(8/8), `settings-*.png` (2/2), and `mixer-*.png` (10/10). The 6 `onboarding-*.png`
files are byte-identical to what's committed (fully deterministic). This split is
itself Finding 4 below — the mismatch isn't uniform noise, and for the mixer window
it's a real pixel-dimension change, not just re-encoding jitter.

All 26 regenerated PNGs were copied to
`docs/plans/phase-3-findings/snapshots/` (flat, original surface-prefixed filenames
retained: `popover-*`, `mixer-*`, `settings-*`, `onboarding-*`).

---

## Findings

### Critical

**C1. The failed-device "diagnosis panel" (retry / cause / copy-details) never
actually appears — it's a confirmed dead feature, not just a rare edge case.**

The popover is documented (`PopoverController.swift:878-888`, and the snapshot
tool's own comment at `popover-snapshot/main.swift:21-27`) to auto-expand an inline
panel under any device row that transitions to `.failed`, showing a cause, a
suggestion, and Retry/Copy Details/dismiss controls. In the regenerated
`popover-connection-light.png` / `popover-connection-dark.png`, the "Failed Speaker"
row shows the dimmed name and amber "Couldn't connect" subtitle — and then the very
next row starts immediately. No panel, no Retry button, nothing.

Root cause, confirmed by reading the call chain: `PopoverPanelViewController
.insertRow(_:after:animated:)` (`AudioutCore/Sources/AudioutPopoverUI/
PopoverPanelViewController.swift:546-562`) locates the failed device's row by
searching `card.contentStack.arrangedSubviews.contains(sibling)`. But device rows are
never direct arranged subviews of `contentStack` — they're added via `addBodyRow`
(`PopoverPanelViewController.swift:463-467` → `CardView.swift:195-199`), which places
them inside `bodyStack`, and `bodyStack` is a plain `addSubview` child of `bodyClip`
(`CardView.swift:137`), with only `bodyClip` itself being an arranged subview of
`contentStack` (`CardView.swift:207`). So the `.first(where:)` lookup never matches,
`card` resolves to `nil`, the guard fires, and `insertRow` silently returns having
done nothing — for every failed device, unconditionally. `removeRow` isn't
independently broken; it's just never asked to remove anything that was ever added.

This is called from `PopoverController.mountDiagnosisPanel`
(`PopoverController.swift:963-972`) via `reconcileDiagnosisPanels`
(`PopoverController.swift:945-959`), itself driven by the `.failed` case in
`handleConnectionTransitions` (`PopoverController.swift:894-930`) — so the bug fires
on the real, product-level "connection failed" path, not just this snapshot's
synthetic fixture.

Existing tests don't catch it because they assert on internal state, not the actual
view tree: `PopoverControllerTests.swift`'s `test_diagnosisPanel(for:)` reads
`diagnosisPanelsByID[id]` (`PopoverController.swift:1563`), which gets populated
*before* the broken `insertRow` call runs — so the dictionary says "mounted" even
though the view was never attached to anything visible.

Secondary, once the attachment is fixed: `insertRow`/`removeRow`
(`PopoverPanelViewController.swift:546-584`) don't gate their `NSAnimationContext`
slide on Reduce Motion themselves (unlike the sibling method `setCardCollapsed`,
which explicitly re-derives `wantsAnimation = animated && !reduceMotion` at
`PopoverPanelViewController.swift:492-513`), and both call sites
(`PopoverController.swift:438`, `983`) always pass `animated: true`. So the slide-in
would currently ignore Reduce Motion too.

Evidence: `popover-connection-light.png`, `popover-connection-dark.png`.
Fix direction: make the sibling lookup search into `card.bodyStack` (or add a
`CardView` helper that finds a row's true containing stack), then add the same
`!reduceMotion` gate `setCardCollapsed` already has.

---

**C2. Every VU meter shows a persistent green mark even when it should be
completely empty (silence/at rest).**

All 10 rows in the default `popover-light.png`/`popover-dark.png` (System's Audio
Out, Current Device, all 6 AirPlay devices, both Applications rows) show a small
green mark at the base of their leading meter pill, despite `snapshot()` never
calling `setLevel`/`test_setDisplayedLevel` on any row — `displayed` should be `0`,
literally a zero-height `CALayer`, invisible. Pixel-sampled: the mark is
`systemGreen`-colored (measured RGB ≈ `(92,192,77)`), a lens/"bowtie" shape roughly
6pt tall, present at **identical y-positions in both light and dark** renders (cross-
checked cluster detection: 10/10 rows in both).

Crucially, this isn't "state was never initialized": `popover-meters-light.png`
explicitly pushes `homepod-bed`'s level to `0.0` via `test_pushLevel` **and** settles
it with `test_setDisplayedLevel(0)` (`popover-snapshot/main.swift:229-239, 260-265`)
— the same `redrawFill()` code path (`LevelMeterView.swift:112-122`) the live
`CVDisplayLink` tick calls every frame at rest — and the mark is still there
(confirmed via a 4x-zoomed crop of that exact row). All three `LevelMeterView`
instantiation sites are affected identically: `DeviceRowView.swift:145`,
`MainOutRowView.swift:71`, `AppRowView.swift:161`.

`[confirm-in-G1]` — this could conceivably be specific to the offscreen
`bitmapImageRepForCachingDisplay`/`cacheDisplay` capture technique rather than the
live on-screen `CVDisplayLink`-driven render, so it's worth a quick live look at an
idle popover before treating it as 100% certain in the shipping app. But since the
exact same `redrawFill()`/`displayed=0` code path is exercised, it's very likely
real.

Evidence: `popover-light.png`, `popover-dark.png`, `popover-meters-light.png`
(Bedroom HomePod row specifically), `popover-connection-*.png`,
`popover-live-routing-*.png` — universal across every popover snapshot.
Fix direction: add a regression test asserting the rendered fill has zero height (or
`fillLayer.isHidden`) when `displayed <= 0` after a forced `cacheDisplay`-style
render; if it reproduces live too, look for a stray non-zero write to `displayed`/
`target` or a `cornerRadius` vs. near-zero-height rendering quirk in `LevelMeterView`.

---

**C3. The Groups/mixer window is largely illegible in dark mode in its default
empty state, and half-broken (light content pane on a dark shell) when hosted in
the new control-panel shell.**

Two distinct, both-measured issues:

- `mixer-1-default-dark.png` (the window's actual default "No groups yet" state):
  sampled sidebar/body text pixel values are near-black (`(0,0,0)`) against a
  `(40,40,40)` background — a ≈1.6:1 contrast ratio, well under WCAG AA's 4.5:1 floor
  for normal text. By contrast, `mixer-3-edit-group-dark.png` — same window
  construction (`snapshotWindow`, same sidebar, same traffic-light chrome), just a
  populated state — renders crisp white-on-dark text throughout. So this isn't a
  blanket "dark mode is broken" issue; it's specific to the empty-state code path.
- `mixer-5-panel-chrome-dark.png` (the newer `ControlPanelWindowController` shell
  hosting the Groups content, `AudioutCore/Sources/window-snapshot/main.swift:
  134-240`): the sidebar correctly turns dark (`(30,30,30)`), but the content pane on
  the right stays at `(231,231,231)` — the *light*-mode background color — even
  though `panelContent.appearance = appearance` is set explicitly
  (`window-snapshot/main.swift:222`) right before rendering. Text throughout the
  panel also reads as heavily washed out/low-contrast compared to the light render
  of the exact same scenario (`mixer-5-panel-chrome-light.png`, which is fully
  consistent). Likely cause: the hosted `MixerWindowController` content
  (`windowController.contentController`) was already attached to its *own* window
  earlier in the same run (`window-snapshot/main.swift:275-286`, used for
  mixer-1/3/4) and some of its materials cache/pin colors from that first window
  rather than re-resolving after being reparented into the panel.

`[confirm-in-G1]` for both — mixer-1's issue may be an artifact of the snapshot
window never becoming "key" (AppKit dims inactive-window chrome, and dark mode's
version of that dimming can crush contrast much harder than light mode's does), and
the panel-chrome integration is recent/adjacent-to-WIP, so a live look at the actual
running app (window frontmost, then defocused) would settle which parts are real.

Evidence: `mixer-1-default-dark.png` vs `mixer-3-edit-group-dark.png` (contrast);
`mixer-5-panel-chrome-dark.png` vs `mixer-5-panel-chrome-light.png` (half-dark
window).
Fix direction: for C3a, check whatever code path renders the empty-state placeholder
for a hardcoded/mis-scoped color instead of `.labelColor`/`.secondaryLabelColor`, and
compare a live key vs. non-key window. For C3b, make sure content re-resolves its
appearance (e.g., a recursive `viewDidChangeEffectiveAppearance` nudge, or avoid
reusing a content controller across two live windows in one process) whenever it's
reparented into the control-panel shell.

### Major

**M1. Regenerated snapshots don't match checked-in ones — and for the mixer window,
the difference is a real resolution change, not noise.**

`git diff --stat` on the snapshot dirs shows 20/26 files changed byte-for-byte:
all 8 `popover-*.png`, both `settings-*.png`, all 10 `mixer-*.png`. The 6
`onboarding-*.png` are untouched (fully deterministic re-render).

For `popover-*`/`settings-*`, pixel dimensions match the old files exactly (already
`@2x`) — the diffs are presumably font-hinting/anti-aliasing timing noise, low risk.

For `mixer-*.png` it's not noise: `sips -g pixelWidth -g pixelHeight` on
`mixer-1-default-light.png` reports the checked-in baseline at **720×460px** (`@1x`)
but the freshly regenerated file at **1440×920px** (`@2x`) — exactly why every
mixer PNG's file size roughly tripled in the `git diff --stat` output. The
`window-snapshot` tool doesn't pin a backing scale factor, so the committed
"reference" images silently depend on whatever display/environment last ran `swift
run window-snapshot`. That makes this particular baseline unreliable for spotting
real visual regressions via `git diff` across machines or CI runners — a resolution
change would swamp any real content change in the diff, and vice versa a real
regression on a `@1x`-generating machine wouldn't show up against a `@2x` baseline
at all.

Evidence: `git diff --stat dev/notes/*-snapshots/` (see Method); `sips` output on
`mixer-1-default-light.png` old vs. new.
Fix direction: force a deterministic render scale in `window-snapshot` (explicit
`@2x` bitmap regardless of `NSScreen.main.backingScaleFactor`), matching whatever the
other three generators already do correctly (their dimensions were stable).

### Minor

**N1. Reduce Transparency / Increase Contrast are never explicitly handled anywhere
in the codebase.**

`git grep -n "ReduceTransparency\|shouldIncreaseContrast\|
accessibilityDisplayShouldIncreaseContrast"` returns zero hits in
`AudioutCore`. Reduce Motion is handled carefully and consistently (7 call sites:
`PopoverPanelViewController.swift:203-220,489-513`, `ControlPanelWindowController
.swift:269`, `DeviceRowView.swift:1059`, `LevelMeterView.swift:156`, `StatusDotView
.swift:159`, `DeviceIconWellView.swift:127`) — but nothing in the app reacts to the
other two accessibility display settings at all.

The app leans heavily on `NSVisualEffectView` materials for its primary surface (the
popover's `CardView`/`PopoverPanelViewController` background, plus Settings/
Onboarding/the control-panel shell), which do get an automatic opaque fallback from
AppKit under Reduce Transparency for standard materials — so this is likely fine by
default. But `CardView` masks its backing view with a *custom* rounded mask
(`CardView.swift:111-113`, `maskImage`/`roundedMask`) rather than relying on plain
`cornerRadius`/material clipping, which is exactly the kind of custom compositing
that can silently opt a view out of AppKit's automatic Reduce-Transparency fallback.
`[confirm-in-G1]` — worth an explicit manual check with both settings on, given how
central vibrancy is to the popover's whole visual identity.

Evidence: code search only (no PNG shows this — it can't be seen without the actual
system setting on during capture).
Fix direction: manually test with Increase Contrast + Reduce Transparency enabled;
if the masked `CardView` backing loses its automatic opaque fallback, add an explicit
solid-color swap for that state.

**N2. "Local Network" permission row wraps into an orphaned "Fi." on its own line.**

`Find AirPlay speakers on your Wi-Fi.` wraps as `Find AirPlay speakers on your Wi-` /
`Fi.` — the compound word splits at the hyphen, leaving a two-character orphan line.
Present identically in all 6 onboarding PNGs (not appearance-specific): `onboarding-
{light,dark}-{initial,resolved,denied}.png`.

Evidence: any `onboarding-*.png`, e.g. `onboarding-light-initial.png`.
Fix direction: shorten the copy slightly or force "Wi-Fi" to stay together (e.g. a
non-breaking hyphen) so it doesn't become the line-wrap point.

### Nit

**T1. Card corner radius differs by 1pt between the popover's cards and the new
control-panel shell's backing, which are meant to read as one continuous shape.**

`AudioutPopoverUI/CardView.swift:82` — `cornerRadius: CGFloat = 13` — vs.
`AudioutSharedUI/ControlPanelBackingView.swift:31` — `cornerRadius: CGFloat = 12`.
The control-panel controller's own comment
(`ControlPanelWindowController.swift:152`) says the backing's corner radius is
chosen "so the two windows read as one continuous shape," which makes the 1pt gap
worth a second look — though a deliberate outer/inner radius offset is also a
completely normal design choice, so confidence this is a real bug is low.

Evidence: code only; not independently visible at the pixel level in these PNGs.
Fix direction: confirm intentional; if not, share one constant.

**T2. A demo device is literally named "Mixer," which is confusing in screenshots
of the app's own Groups/mixer window.**

`MockBackend.demoFleet`'s fixture list includes an AirPlay device named "Mixer" —
visible dimmed/unavailable in `popover-light.png`, `popover-meters-light.png`, and
selectable in `mixer-3-edit-group-light.png`'s speaker list, sitting right next to
the app's own "Groups"/mixer-window terminology. Demo-fixture-only, not shipping
content, purely cosmetic for anyone reading these snapshots (including this audit).

Evidence: `popover-light.png`, `mixer-3-edit-group-light.png`.
Fix direction: rename the fixture device in `MockBackend.demoFleet`.

---

## Top 5 by user impact

1. **VU meters always show a fake green sliver at rest (C2)** — the single most-seen
   glitch: it's in the app's default idle state, every time the popover opens, on
   every row, both themes.
2. **The failed-device help panel (Retry / cause / Copy Details) never renders (C1)**
   — a real troubleshooting feature is silently dead; a user whose speaker fails to
   connect sees "Couldn't connect" and nothing else actionable.
3. **Groups window text is near-unreadable in dark mode in its default state, and
   half-broken when hosted in the new control-panel shell (C3)** — first impression
   of the app's secondary window, in the theme roughly half of macOS users run.
4. **The mixer snapshot baseline silently drifts resolution by machine (M1)** — not
   user-facing directly, but it means this exact kind of visual regression can slip
   past `git diff` on the snapshot PNGs going forward.
5. **"Wi-Fi" wraps into an orphaned "Fi." on the very first screen a new user sees
   (N2)** — small, but it's on the first-run onboarding screen for a paid app.
