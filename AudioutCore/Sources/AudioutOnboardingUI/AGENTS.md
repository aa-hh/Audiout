# AudioutOnboardingUI

## Purpose

The first-run Setup window, pure AppKit: a spine of status rows beside one hero
panel that asks for the six grants one at a time.

## Rules

- Setup is a GATE, not guidance (2026-08-11): Done absent until the final check passes.
- Both on-screen paths gate on `HeadlessRuntime`; ungated, tests park this window over your screen.
- The window is `.floating` while open (2026-08-07); reversing that buries it after a grant.
- Local Network proves BOTH answers via `LocalNetworkPrimer`; never dead-end the step.
- Two-mode Allow: `offersSettingsFallback` stays lockstep with the model preflight, or the button lies.
- THE WHOLE ROW IS THE PRESS TARGET; locked and auto-passed rows refuse silently.
- Five steps are skippable; a skipped one stays out of the gate.
- Seven steps, six kinds of thing: Speaker Sync is Login Items, not TCC, and the iPhone card asks macOS for nothing at all.
- Nothing expands: the spine selects, the hero shows.
- Locked steps READ locked (2026-08-11): dimmed, lock in the checkmark slot.
- Three title tables; the hero copy is owner-verbatim (2026-08-12). Change one, check the others.
- Grant choreography fires on the transition into complete, never on a repaint.
- `SetupFlowModel` is built in the controller's `init`; building it later opens the wrong card.
- `DemoPaneView` is an approved custom-drawn exception; draw everything, never bundle screenshots.
- `EmitterFieldView` generates its shader from the shared field; never retype those numbers.
- Field scenes are uniform-driven, never CAAnimation, so Reduce Motion keeps stills.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `OnboardingWindowController` → owns the Setup window and its floating level.
- `DemoPaneView` → custom-drawn rehearsal of the prompt each step raises.
- `EmitterFieldView` → Metal emitter field behind the licence window.
