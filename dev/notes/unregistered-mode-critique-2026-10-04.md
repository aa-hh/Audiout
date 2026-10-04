# Unregistered mode: critique findings, 2026-10-04

Critique pass over branch `claude/trial-expiration-conversion-c93563` (PR #231),
against `unregistered-mode-spec-2026-09-26.md` and
`thank-you-card-concept-2026-09-26.md`. Ranked; each carries the pass that
applies it. The spec's rulings stand; nothing here reopens one.

## To apply

1. **P1, polish.** "Play here instead" is drawn in `Tokens.Color.gold`, which in
   light mode is `#E8B84B` on the `#FAFAFB` ground, under 2:1. DESIGN.md puts
   text in the gold family on `goldText`. The row's older "Undo" link is set up
   in the same block of `DeviceRowView` and has the same defect; fix both.
2. **P1, harden + copy.** Settings › General tells an ended trial its key was
   refunded. The server answers an ended trial with `revoked` and reason
   `trial_expired`, and the pane special-cases only a saved `active`. Any limited
   install whose trial has ended (`TrialClock.hasEnded`) gets the spec's trial
   sentence; a revoked key gets the reason-named line the popover note already
   uses (refund, chargeback, otherwise revoked). `LicenseCopy.statusLine` is left
   alone: sibling PR #241 reworks it.
3. **P1, harden.** A refused second-speaker click says nothing to VoiceOver.
   Announce the note text through `postAnnouncement`, as the undo offer does.
4. **P2, harden.** A licence change while the popover is open leaves "Play here
   instead" up for up to 5 s and keeps greyed groups in the Main Out menu until
   the next open. Clicking the stale offer after buying cuts a legal
   multi-speaker selection to one. Changing the note clears the offer and the
   limit text and redraws the rows and the menu.
5. **P2, harden.** The consent ask can follow the thank-you card in the same
   open: Mixer → Settings counts as a hide (the card is recorded seen), and back
   to Mixer raises the consent alert seconds after the thanks. Ask only when the
   window opens onto the Mixer from closed.
6. **P2, copy.** Two notes say untrue things. An `unknown`/`invalid` key (a
   mistyped key saved from the sheet) reads "This key was revoked…"; a Mac with
   no key and no trial reads "Your trial has ended…". Add "This key isn’t
   recognized, so Audiout plays on one speaker at a time." and "Audiout plays on
   one speaker at a time until it has a license key."
7. **P2, harden.** Under Increase Contrast the note banner and the thank-you card
   have no edge (12 % tint, no border). Add a 1 pt border in the same tint under
   a high-contrast appearance. No new colour.
8. **P3.** VoiceOver reads the card's button as "Close": label it "Close this
   message" (harden). "I have a key" shows the arrow cursor: give it the
   pointing hand (polish).

## Needs the owner: ruled 2026-10-04

These override the spec where they differ; the spec, CONTEXT.md and PRODUCT.md
now say the same.

- The Main Out menu keeps its "Scenes" heading under the limit, lists the
  scenes dimmed, and adds one dimmed caption under the heading: "Buy Audiout to
  use scenes." The click still answers with the note.
- The user-facing word is "scenes", never "groups", in every label, note,
  caption and refusal. Analytics property values and code names keep "group".
- "Buy Audiout" drops its ellipsis wherever it opens the browser; an ellipsis
  stays only where a dialog follows.
- The thank-you card may appear in the same open the key lands in: kept as
  built.
