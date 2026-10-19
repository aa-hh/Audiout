# Thank-you card for a honoured purchase: concepts

2026-09-26. Design discovery only; nothing built.

Shared facts for every concept:

- Takes the popover's single note slot (the place `SystemAirPlayNoteBannerView` sits below the mixer). The mixer rows above never move; the popover grows downward by the card's height for this one open.
- Width: 653 pt popover minus the 14 pt insets each side (`leadingInset`, `trailingInset`) = 625 pt card.
- Ground: `gold` at 12 % on `Tokens.Layout.Radius.control` (10 pt), no border. This is the note banner's own recipe with the `ring` tint swapped for `gold`, which the design record allows because completion is one of gold's jobs.
- Close: a stock `NSButton`, `.rounded` bezel, `.small` control size, title "Close", trailing, the same way the banner's `Action` button sits. Escape also closes.
- Shown once. The flag is written on Close, or when the popover closes with the card visible, so a user who never clicks Close does not see it twice. The consent popover follows on the next open, as today.
- VoiceOver: the card is one accessibility group (`NSAccessibilityElement` role `.group`, label = headline + body) followed by the Close button. On appear, post `NSAccessibility.Notification.announcementRequested` with the headline so the thanks is read without the user hunting for it.
- Analytics: `license:thanks_shown` on appear and `license:thanks_closed` on Close, added to `docs/analytics-events.md` in `audiout-shared` first. No properties.

## Concept A: the rings, still, beside the words

The card's leading 96 pt holds a small rendering of the emitter field: the three rings from the licence window, drawn in their settled state with the shader the popover already links (`AudioutField`, used by the alignment stage's lights). They sit still. The words sit to the right. The rings tie this moment to the one the buyer saw when their key verified in the licence window, so the card reads as the same brand speaking, not a new component.

- Headline (16 pt semibold, `heading`, `labelColor`): "Thank you for buying Audiout."
- Body (13 pt regular, `body`, `label2`): "You paid once, and it's yours for good. Every update is included. Your purchase pays for the work on the next ones, and that means a lot to one small team."
- Button: "Close"
- Layout: height 112 pt. Rings well 96 x 96 pt at leading 8 pt, vertically centred, clipped to the card radius. Text column starts at 118 pt, 12 pt gap between headline and body, body wraps at 380 pt. Close pinned trailing 14 pt, aligned to the headline's first baseline.
- Motion: on appear the card fades 0 to 1 over 0.25 s, ease out, through `FoldAnimator` (the popover's one reveal clock). The rings then play one surge: fast attack, about 1.4 s decay, the same envelope as `EmitterFieldView.surgeEnvelope`, then rest. One pulse, never a loop. Reduce Motion: no fade, no surge; the settled rings are drawn as one still frame.
- Reuse: settled-field shader from `AudioutField` (already a `AudioutPopoverUI` dependency in `AudioutCore/Package.swift`); envelope numbers from `AudioutOnboardingUI/EmitterFieldView.swift`; `EmitterFieldView` itself is in `AudioutOnboardingUI`, which the popover target does not depend on, so the popover redraws the rings through `AudioutField` rather than importing that view.

## Concept B: the brand mark as a signature

No moving field. The brand mark (the speaker-with-halo render from `BrandMark`) sits at 44 pt on the leading edge, the way a signed letter carries a letterhead. The copy is longer and warmer, and the card is closer to a short letter than a notice.

- Headline: "Thank you. Audiout is yours."
- Body: "You bought it once, so there is nothing more to pay, and every update comes with it. Buying it directly keeps Audiout independent and pays for the work still to come. We're glad you're here."
- Button: "Close"
- Layout: height 104 pt. Mark 44 x 44 pt at leading 14 pt, top 14 pt. Text column at 72 pt, body wraps at 440 pt.
- Motion: card fades in 0.25 s ease out; the mark scales 0.96 to 1.0 over 0.35 s ease out alongside it. Reduce Motion: fade only, no scale.
- Reuse: `AudioutSharedUI/BrandMark.swift`; fade through `AudioutSharedUI/FoldAnimator.swift`.

## Concept C: the plain note, grown

The existing banner, taller, with a `checkmark.seal.fill` glyph in `gold` instead of `info.circle.fill`. No artwork. Lowest cost: a new `Severity` case on `SystemAirPlayNoteBannerView` plus a headline line.

- Headline: "Thank you for buying Audiout."
- Body: "It's yours for good, with every update included."
- Button: "Close"
- Layout: height 72 pt; glyph 15 pt semibold as the banner draws it today.
- Motion: none beyond the slot's usual appearance. Reduce Motion: identical.
- Reuse: `AudioutPopoverUI/SystemAirPlayNoteBannerView.swift` as is.

## Recommendation: Concept A

The buyer's last sight of the licence window was the rings surging when the key verified, so one quiet surge of the same rings in the popover finishes that moment instead of starting a new visual idea. It stays inside the rules: gold at 12 % is the banner recipe, the rings already live in the popover's dependencies, the motion is one pulse with a still fallback, and nothing above the slot moves. Concept C is too close to the one-line message the owner called not appreciative enough, and Concept B brings the brand mark into the mixer surface, where the design record keeps it out (About, onboarding header, demo finale only).

## Sketch of Concept A at 653 pt

```
|<------------------------------- 653 pt popover ------------------------------->|
|                                  (mixer rows, unchanged)                       |
|                                                                                |
|  +------------------------------------------------------------------------+    |
|  | .------.                                                               |    |
|  |( .--.  )   Thank you for buying Audiout.                     [ Close ] |    |
|  |( (()) )                                                               |    |
|  |( '--'  )   You paid once, and it's yours for good. Every update is     |    |
|  | '------'   included. Your purchase pays for the work on the next       |    |
|  |            ones, and that means a lot to one small team.              |    |
|  +------------------------------------------------------------------------+    |
|  ^ 14 pt inset     card 625 x 112 pt, gold 12 %, 10 pt radius    14 pt inset ^ |
|                                  (footer, unchanged)                           |
```

## Tokens and components it depends on

- `Tokens.Color.gold`, `Tokens.Color.label2`, system `labelColor`: `AudioutCore/Sources/AudioutSharedUI/Tokens.swift`
- `Tokens.Layout.Radius.control` (10 pt), insets 14 pt: `AudioutCore/Sources/AudioutSharedUI/Tokens.swift`
- `heading` (16 pt semibold) and `body` (13 pt) type: `DESIGN.md` front matter
- Accent dial: `gold` resolves quieter at Subtle; the card must observe `Tokens.accentStyleDidChangeNotification` and `NSView.redrawOnAccessibilityDisplayChange()` (Increase Contrast), both in `AudioutCore/Sources/AudioutSharedUI/`
- Note banner layout and button recipe: `AudioutCore/Sources/AudioutPopoverUI/SystemAirPlayNoteBannerView.swift`
- Reveal clock and Reduce Motion answer: `AudioutCore/Sources/AudioutSharedUI/FoldAnimator.swift`
- Settled rings shader: `AudioutField` product of `audiout-shared`, already linked by `AudioutPopoverUI` in `AudioutCore/Package.swift`
- Surge envelope numbers: `AudioutCore/Sources/AudioutOnboardingUI/EmitterFieldView.swift` (`surgeEnvelope`)
- Current one-line copy it replaces: `AudioutCore/Sources/AudioutCore/LicenseGate.swift:102`
