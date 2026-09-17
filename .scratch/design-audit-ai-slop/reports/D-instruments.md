# D — Instruments (alignment wizard, EQ editor and scope, Bluetooth sync drawer, Tokens.swift)

## 1. Verdict

This slice reads as a person's decisions, and by a wide margin: nearly every
constant, hue and string in it carries a written reason, a measured contrast
figure or a dated ruling, and several carry the rejected alternative as well.
The failures here are not template failures, they are execution failures in
things that were genuinely decided.

The single highest-impact change: the wizard's stage draws a second light for a
speaker that may not exist, and draws it differently in light and dark on the
screen the sheet opens on. Fix that first, because the stage is the one thing
on the sheet the user is asked to trust.

## 2. Findings

[P1] Alignment wizard, intro screen (the stage) — AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift:1080-1087 — 11-intro-no-option-light.png, 11-intro-no-option-dark.png, 1-intro-dark.png, 1-intro-light.png
  tell:  A scaffold (the layout's two slots filled whether or not there is data)
  now:   The armed stage always lays out a light at each end of the wire. The
         NAME under a light is gated on having one (AlignmentStageView.swift:770,
         `label.isHidden = !armed || name.isEmpty`); the light itself is not. With
         no comparison speaker chosen, 11-intro-no-option-light.png draws a full
         steel blue light at the right end with no name under it (sampled
         RGB 58,83,90 at x=884). The same screen in dark draws no second light at
         all, and neither does 1-intro-dark.png, where a reference IS chosen and
         named (brightest pixel in the right half of the plate is the wire itself,
         RGB 27,24,22). The reference light's colour is pinned to one hex for both
         appearances precisely so this cannot happen
         (AlignmentStageView.swift:1567-1577).
  why:   The composition has two ends, so two lights are drawn regardless of the
         data behind them. An instrument that shows a source that is not in the
         room, and shows a different thing in each appearance, is the machine
         filling a slot. It also breaks PRODUCT.md principle 2, "the UI never lies".
  fix:   Gate the reference halo on `session.reference != nil` exactly as the name
         stamp is gated, so a one-speaker intro shows one light on an unlit wire.
         Then check the armed screen live in both appearances: one of the two
         renders above is wrong, and the pinned colour says they must match.

[P2] Question screen, every one of the roughly 15 asks — AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:370-377 and 476-484 — 2-question-open-dark.png, 3-question-closing-light.png
  tell:  A endless whitespace, nothing leading the eye
  now:   The question screen's own chassis is 397 pt (18+16+132+12+15+28+88+12+36+16+24,
         line 374). The sheet opens on the intro, which needs 601 pt, and stays
         there for the rest of the run: every screen rendered in a run that began
         on the intro is 1282 px tall at 2x, while the same proposal screen
         rendered in a run that skipped the intro is 874 px
         (5-proposal-dark.png 1282 vs 5c-proposal-measured-dark.png 874). The
         leftover 200 pt is split evenly by `contentCentred` (line 481), so about
         100 pt of empty plate sits between the question and the two plates that
         answer it, on top of the 28 pt break the layout already calls for, and
         the same again under the corner row.
  why:   The screen the user sees fifteen times has a hole in the middle of it,
         with the ask floating in 11 pt type far above its answers. The centring
         was added to close a 58 pt hole on the intro (line 476-478) and at the
         real sheet height it now opens a larger one.
  fix:   Pin the question and proposal content to the top of the band the way the
         intro already is (`contentTopPinned`, line 483), so the slack collects
         under the corner row instead of between the question and its answers.
         Or let the sheet shrink back to the 397 pt chassis after Start.

[P2] First-join alignment note under a Bluetooth row — AudioutCore/Sources/AudioutPopoverUI/BTAlignmentNoteView.swift:42-47, 118-128, 157-162, 189-193 — no screenshot
  tell:  C reinvented control (an inline text link, web style)
  now:   The note is one sentence. Its tail, "Align it now.", is drawn in gold
         semibold inside the paragraph, and the pointer becomes a pointing hand.
         The click target is not the gold words: `PassThroughLabel` refuses every
         hit (line 46) so the whole sentence, device name and explanation
         included, is one `NSButton` that opens the wizard, and the cursor rect
         covers all of it (line 191).
  why:   A coloured phrase inside body text that is clickable, with a hand
         cursor and no platform affordance, is the web pattern; AppKit has no
         inline link like this outside a real `NSTextField` link. And the visible
         affordance and the hit area disagree, so clicking the explanation fires
         an action the user did not aim at.
  fix:   Leave the sentence plain and put a real trailing text button after it
         ("Align by ear…", the app's own name for that sheet, which is what the
         chip and the row menu already say). If the inline call stays, make only
         its own glyph range the hit target and the cursor rect.

[P2] "Mac is late" bow-out — AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:114-119 — 9-mac-is-late-dark.png, 9-mac-is-late-light.png
  tell:  D copy (the message repeats the button under it)
  now:   The sentence ends "...which shouldn't happen. Try again." and a gold
         "Try again" plate sits directly beneath it. The code comment three lines
         above the string says the opposite: "The screen now carries a real Try
         again button, so the copy no longer has to offer one in prose (spec §1)."
  why:   Prose that restates the button below it is the padding a generator adds
         to make an error message feel complete, and here the decision to remove
         it was already taken and only half applied.
  fix:   Drop the last two words: "Couldn't get a clean reading. This Mac sounded
         later than the speaker, which shouldn't happen."

[P3] Every wizard keycap chip — AudioutCore/Sources/AudioutPopoverUI/AlignmentPlateCell.swift:490-499 — 2-question-open-dark.png, 5-proposal-dark.png, 6-kept-dark.png
  tell:  B one radius applied uniformly
  now:   One constant, `Radius.control` (10 pt), rounds both chip sizes. On the
         22 x 22 glyph chip 11 pt would be a full circle, so at 10 the chip is a
         circle in practice, which is what the screenshots show around the arrows
         and the return glyph. On the 44 x 20 "SPACE" chip the same 10 is exactly
         half the height, so that one is a capsule. The comment calls the small
         one "a rounded square" and says "the wide chip reading as a key is the
         point".
  why:   The stated intent is a key; what renders is a circular badge beside a
         pill. Two shapes out of one constant, neither of them the one the
         decision named, is the shape you get when the ladder is applied rather
         than chosen.
  fix:   Give the chip its own radius (4 to 5 pt on the 22 pt square, the same on
         the wide one) so both read as one key family. That is a named exception
         in `AlignmentPlateCell`, not a new entry in the shared ladder.

[P3] Proposal screen instruction — AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:157 — 5-proposal-dark.png, 5c-proposal-measured-dark.png
  tell:  D copy (colon reveal)
  now:   "Listen: the clicks should land as one." above two buttons, "Sounds
         right" and "Still off".
  why:   The colon sets up a payoff, which is the construction the house writing
         rules single out. The line also states a fact where the screen is asking
         a question, so it does not pair with the two answers under it.
  fix:   "Do the clicks land as one?"

[P3] Sync drawer value field — AudioutCore/Sources/AudioutSharedUI/BTSyncDrawerView.swift:713-715 — no screenshot
  tell:  E typography inconsistency
  now:   The resting value is built as `"\(Int(BTSyncTrim.snap(ms))) ms"`, so a
         negative offset reads "-414 ms" with an ASCII hyphen. The wizard
         (BTAlignmentWizardView.swift:130-133) and the EQ readouts
         (EQEditorView.swift:722-729) both spend a line of comment on using
         U+2212 instead, because "-8 reads as a bug". The drawer's own header
         diagram at line 44 draws the field as "−414 ms" with the real minus, its
         stepper glyph falls back to "\u{2212}" (line 267), and the field editor
         already normalises U+2212 back to a hyphen when parsing
         (SyncValueFieldEditor.swift:206), so nothing blocks it.
  why:   The one place the app prints a negative number outside an instrument is
         the one place it forgot its own rule, which is what an interpolated
         string does when nobody looks at it.
  fix:   Format the resting text with U+2212; the editing form stays the plain
         signed number it already is.

[P3] EQ response scope — AudioutCore/Sources/AudioutSharedUI/EQResponseCurveView.swift:84-93 — mixer-4b-device-detail-eq-open-dark.png
  tell:  C size off the platform scale with no reason
  now:   The scope's corner is 6 pt, off the 10/16/26 ladder and off the two
         Mac-only radii. It sits in the file's one block of bare constants
         (`cornerRadius`, `plotInset`, `gridAlpha`, `shapedFillAlpha`,
         `shapedLineWidth`, `hairlineWidth`, the two dash patterns, the two ruler
         insets), none of which carry a doc comment, in a file where every
         constant above them does.
  why:   A shape value that no rule and no comment accounts for is the definition
         of an unspecified default, even when the surface around it is authored.
  fix:   Either take `Radius.control` (10) like every other inset box in the app,
         or keep 6 and say why in one line, the way the Equalizer door's own 6 is
         justified in DESIGN.md. Give the rest of that block one-line reasons too.

[P3] EQ scope band grid — AudioutCore/Sources/AudioutSharedUI/EQResponseCurveView.swift:372-386 — mixer-4b-device-detail-eq-open-dark.png, mixer-4b-device-detail-eq-open-light.png
  tell:  B unprompted colour (chosen, but reads as a tell)
  now:   The ten band gridlines are `Tokens.Color.gold` at 14% alpha. On a flat
         EQ, which is what both screenshots show, the gold grid is the only
         colour in the card, and the actual signal trace is the neutral
         `scopeFlatLine` hairline.
  why:   DESIGN.md's Scope Instrument Rule does name a gold gridline, so this is
         chosen. It still reads as warm decoration: the app's own rule is that
         gold means signal, and at rest the scope's gold is everything except the
         signal.
  fix:   Draw the grid in `scopeFlatLine` at the same alpha and let gold arrive
         only with the shaped trace. If the gold grid stays, it is worth a line in
         DESIGN.md saying the grid is the reference, not the signal.

[P3] Wizard sheet ground and the design record — AudioutCore/Sources/AudioutSharedUI/WarmCanvasView.swift:19-28, AudioutCore/Sources/AudioutPopoverUI/AlignmentWizardViewController.swift:155-274 — 2-question-open-dark.png (measured), 3-question-closing-light.png
  tell:  B texture and colour wash as atmosphere (chosen, but unrecorded)
  now:   Two treatments sit on the dark chassis and nowhere in DESIGN.md. The
         canvas carries a deterministic white-noise grain in dark mode only
         (measured on 2-question-open-dark.png: 72 distinct colours and a per
         channel standard deviation of about 3 in a flat 300 x 50 px region of
         background; the same region in light mode is one single colour). Behind
         the wizard plate, `RoomSpillView` paints two radial gradient washes,
         green on the left and steel blue on the right, peaking at 0.10 alpha in
         dark and off in light, its own comment marking it "Decorative only".
         Both cite `dev/notes/warm-signal-v3.md`, which root AGENTS.md demotes:
         "the historical spec, not the authority". `grep -n "grain\|texture\|spill"
         DESIGN.md` returns nothing.
  why:   Every colour in `Tokens.swift` carries a measured rationale, and the two
         treatments a viewer actually notices first on a dark screen carry none in
         the record that PRODUCT.md names as binding. That is exactly the gap a
         later pass reads as "somebody added atmosphere".
  fix:   Add both to DESIGN.md under Elevation and Depth, with their alphas, their
         dark-only scope and the accessibility switches that drop them (Reduce
         Transparency, Increase Contrast, Reduce Motion). They are defensible as
         written; the record just does not have them.

[P3] Three bow-out screens — AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift:8-11, AlignmentStageView.swift:95-96 — 7-unsettled-dark.png, 8-unreachable-dark.png, 9b-target-lost-dark.png
  tell:  B a soft rounded rectangle standing in for content (chosen, but reads as a tell)
  now:   On unsettled, unreachable, "Mac is late" and target lost, the stage goes
         dormant and becomes an empty black 132 pt panel with a faint rule across
         it, holding the top third of the sheet above a one-line apology.
  why:   The fixed chassis is deliberate and the reason is good (the stage must
         never jump under the user). The side effect on the failure screens is a
         large empty instrument panel, which is the shape of a placeholder.
  fix:   Keep the chassis, but let the dormant stage collapse its own height on
         the bow-out screens, or give the dormant plate one thing to say, for
         example the last interval it reached, so the panel is carrying
         information rather than reserving space.

## 3. Repeated patterns

**Three ways to print a keyboard shortcut.** Inside the wizard a shortcut is a
drawn, bevelled keycap chip on the plate (AlignmentPlateCell.swift:410-461);
two inches below it, on the same screen, "⌘Z" is bare 10 pt micro text beside
the word Undo (BTAlignmentWizardView.swift:1487-1499); one row away in the sync
drawer the same idea is a caption sentence, "hold ⇧ for 10 ms"
(BTSyncDrawerView.swift:367). Each has a reason on its own; together they are
three vocabularies for one idea on two surfaces the user reaches from the same
speaker row. Worth settling on two at most: the chip inside a control, plain
text everywhere else.

**The record trails the pixels.** `Tokens.swift` is the most disciplined file in
this slice: every colour has a measured contrast rationale, `Motion` holds one
duration, `Material` holds two forwarding aliases and no custom material. But
three things that are actually on screen are absent from DESIGN.md: the canvas
grain, the wizard's two colour washes, and the scope's 6 pt corner. All three
are the kind of thing a later reader assumes was never decided.

**The fixed chassis pays twice.** Holding the stage at one y so a run never
reflows is right, and it produces both the 100 pt hole on the question screen
and the empty instrument on the bow-outs. One fix serves both: let the slack
collect at the bottom of the sheet rather than around the content.

## 4. Positives

- The rung ladder is one source for both the look and the word, with hysteresis,
  so the picture and the caption cannot disagree and a belief hovering on a
  boundary cannot strobe the stage (AlignmentStageView.swift:99-206). Nothing
  auto-completes to this.
- The scope plots the response of the actual biquad sections the audio path
  runs, and the ten faders are positioned on the scope's own x-axis rather than
  distributed evenly, so the controls and the picture share one ruler
  (EQResponseCurveView.swift:140-161, EQEditorView.swift:422-449).
- Gold at rest is forbidden on the scope: a flat EQ draws a neutral hairline and
  only shaping earns the gold trace (EQResponseCurveView.swift:38-41, 410-414).
  The app's one accent rule survives contact with the one surface most likely to
  break it.
- Every keycap chip maps to a key that works, and the plate with no key ("Still
  off" on the proposal screen) carries no chip (BTAlignmentWizardView.swift:862,
  AlignmentPlateButton.swift:95-103). The decoration tracks the truth.
- The drawer's value field is a stock bezel after a custom cell was tried and
  reverted, with the four measured reasons written down
  (BTSyncDrawerView.swift:229-245). So are the stepper bezels, for the same
  reason (line 271-275). This is the opposite of reinventing a control for
  flavour.
- "Stop" is spelled out in the corner because a live run could not find the
  9.5 pt close glyph (BTAlignmentWizardView.swift:88-90), and the disabled Undo
  is dimmed explicitly with the contrast decision recorded and accepted
  (line 1463-1485).

## 5. Unverified impressions (screenshot only, no code anchor)

- 4b-question-pressed-dark.png is named for a pressed plate but no plate in it
  looks pressed. I could not tell from the image whether the pressed paint ran,
  so the press state is effectively unseen.
- On the intro the two panels are visibly unequal in length: the left column ends
  with the QR tile and the address at y ≈ 812 px while the right column's last
  line sits at y ≈ 608 px, leaving the right side visibly emptier. It may simply
  be the copy lengths, so I am not filing it.

## 6. Screens and states in my slice I could not see

- The Bluetooth sync drawer, in any state, in either appearance. Nothing in the
  snapshot set opens it, so the whole band, its caption line, and the two edge
  weights on the well are audited from source only.
- The drawer's inline value editor: the swap to the signed editing form, the
  select-all, the Escape revert, and the suggested-value state the wizard's
  "Set it manually" pushes into it.
- The drawer's variants: "Align again…" hidden and the band re-anchored, Reset
  hidden, and each caption (Measured / First pass / Timing from last time /
  Aligned by ear / the over-40 ms notice).
- The first-join alignment note under a device row, which finding 3 is about.
- The EQ editor with anything other than a flat curve. Both EQ screenshots are
  flat, so the gold shaped trace, its 13% fill, and the dashed hollow bypassed
  trace with its "Not applied" sentence are unseen, as is the editor with
  Advanced collapsed.
- Wizard plate states: hover, pressed, disabled beyond the intro's dimmed Start,
  and the keyboard focus ring.
- Increase Contrast and the Subtle accent dial, for every surface above.
