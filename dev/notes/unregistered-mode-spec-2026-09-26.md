# Unregistered mode: the trial ends, the app stays

Owner rulings taken 2026-09-26 in a scoping interview. This note replaces the
"returns to the welcome gate" lines in `trial-spec-2026-09-05.md` (15-16, 27-28,
202-206) and `PRODUCT.md:58-59`. Vocabulary is in `CONTEXT.md`: registered,
unregistered, trial, Selected Speakers, note.

## Why

Four customer trials have expired since launch and none bought. All four Macs
ran builds from before analytics defaulted on (12 Sept), so we cannot see what
they met. What the code shows they met: nothing at the expiry moment, then at a
later launch a blocking key window with the dead trial key pre-filled, a gold
"Register" button that answers "refunded or revoked", Buy as a faint corner
button, and Quit as the only other exit. Quit removes the menu-bar icon, and
with no email on file there is no way back to that person. No surveyed Mac
utility quits itself at trial end (`trial-end-ux-survey-2026-09-26.md`); the
only controlled study of late buyers found they are reached through the product
itself (`trial-end-conversion-evidence-2026-09-26.md`).

## The rule

An install is **unregistered** when the build has a licence server and holds no
key the server honours: the trial has ended, the key was refunded or revoked, or
there is no key. A trial that started offline and has not yet reached the server
is not unregistered. This is exactly the condition that used to open the gate
window (`LicenseGate.shouldPresent`); the limit replaces the window one for one.
Source builds have no licence server and are never limited.

While unregistered:

- The app runs, with every feature, on **one speaker at a time**: the Selected
  Speakers set holds at most one member. This Mac's own output counts as a member.
- **Groups are off.** A saved group has two or more members.
- **Bluetooth sync is off.** It aligns two outputs.
- **Per-app routes are free.** Any app may be routed to any speaker.
- Nothing else changes: volume, mute, EQ, the sync drawer's read-only chip,
  Settings, updates as the server allows.

## Journeys

### J1. The trial ends while the app is running

Nothing is interrupted. Audio keeps playing to every selected speaker until the
user changes the selection or relaunches. The days-left pill is gone at the next
popover open and the standing note (J2) takes its place.

### J2. Opening the popover while unregistered

The note slot shows the standing note. It appears on every open, has no dismiss,
and yields to every failure note above it in the existing precedence (capture
failed, routing blocked, takeover, double-audio), returning the moment they clear.

Copy, trial ended:

> Your trial has ended. Audiout plays on one speaker at a time until you buy.

Copy, key refunded or revoked:

> This key was refunded or revoked, so Audiout plays on one speaker at a time.

Actions, right-aligned, vertically centred to the note even when the text wraps
to two lines: an underlined text action **I have a key** to the left, then the
button **Buy Audiout**. No price on the note.

- **Buy Audiout** opens `AppSettings.buyURL` in the default browser. The URL
  keeps `?t=<trial key>` after expiry (today it drops it once the trial is not
  active), so the server marks the trial converted and counts the sale.
- **I have a key** opens the Settings licence sheet (the existing one).

### J3. Adding a second speaker

The user turns on a second row in the mixer while one is already selected. The
click does not take. Two things happen:

1. The clicked row shows a transient offer, in the same pattern as today's
   undo-removal offer: **Play here instead**. Clicking it deselects the current
   speaker and selects this one in one step, through the row's own delegate
   path, then clears the offer.
2. The note, for this popover open, reads:
   > Your trial has ended, so Audiout plays on one speaker at a time.
   with the same two actions as J2. It reverts to the standing note on the next
   open.

Refusal travels through `GroupController.SelectionResult.refused(reason)`, which
already exists; the mixer never learns a new way to say no.

### J4. Groups and sync

Groups in the sidebar stay visible, greyed, under one caption:

> Groups need more than one speaker. Buy Audiout to use them.

Clicking a greyed group shows the J3 note. Sync entry points (the untuned
Bluetooth chip, the "Align by ear…" menu item, the wizard doors) stay visible;
using one shows the J3 note instead of the wizard.

### J5. Launch while unregistered

- One speaker saved: it comes back and plays, as before.
- Two or more saved: the selection is replaced by This Mac, persisted, and the
  standing note shows on the first open. Nothing is kept aside for later; a
  buyer re-selects speakers by hand (owner's call, Q11).
- The gate window never opens for an unregistered install. The first-open
  welcome window for an install with no key and no trial is unchanged.
- The server is asked at launch as today. If the trial expired while the app was
  closed, the local clock already knows (`TrialClock.state`), so the limit is in
  force from the first open, not one launch later.

### J6. Buying

Buy opens the browser checkout (Paddle has no native Mac SDK; its own guidance
for Mac apps is the browser plus a redirect back). Two return paths, both
already built or nearly so:

1. The thanks page hands the key back through `audiout://register?key=`. With
   no gate window present, the app validates the key itself and, on `active`,
   leaves unregistered mode at once.
2. If the deep link is not used, the app re-validates its trial key at the next
   popover open and at launch; a converted trial answers with the paid key.

Nothing is pasted. Offline, Buy still opens the browser; the note does not
change.

### J7. The thank-you

The first popover open after the key is honoured shows a one-time thank-you card
in the note's place: Concept A in `thank-you-card-concept-2026-09-26.md` (owner's
pick, 2026-09-26). The ring artwork sits still on the left and pulses once on
appear (a still frame under Reduce Motion); headline "Thank you for buying
Audiout."; body "You paid once, and it's yours for good. Every update is
included. Your purchase pays for the work on the next ones, and that means a lot
to one small team."; a stock Close button, Escape also closes; 112 points tall.
The shown flag is written when the popover closes as well as on Close, so the
card is never seen twice. The next open shows the existing one-time analytics
consent ask (ADR 0002). After that the note slot is empty for a registered install.

### J8. Someone with a key

Bought on the website or another Mac: **I have a key** on the note, or Settings.
The Settings licence row already says "Buy Audiout…" while unregistered; its
copy gains no trial wording.

## Copy rules

Every string above goes through `audiout-copy-review` before it ships. No
invented terms: "unregistered", "trial", "speaker", "group" as in `CONTEXT.md`.

## Analytics

Existing events keep their names. New or changed, to be added to
`docs/analytics-events.md` in audiout-shared first:

| Event | When | Properties |
|---|---|---|
| `license:limit_hit` | a second speaker, a group or a sync door is refused | `attempted`: `speaker` / `group` / `sync` |
| `license:switch_offer_used` | the row offer "Play here instead" is clicked | none |
| `license:buy_link_opened` | existing | `source` gains `note` (the standing and J3 notes) |
| `license:enter_sheet_opened` | existing | gains `source`: `settings` / `note` |
| `license:thank_you_shown` | the J7 card appears | none |
| `license:thank_you_closed` | the J7 card is closed by its button or by Escape | none |
| `license:expired_gate_shown` | removed with the expired gate copy; the stream ends | |

`license:gate_shown` continues for the first-open welcome window only.

## Out of scope

Trial length, the pre-expiry banners, the first-open welcome window's layout,
the licence server, any change to per-app routing.

## Owner confirmation

Shared understanding confirmed by the owner on 2026-09-26 after four interview
rounds; the J5 replacement of a dropped multi-speaker selection is saved, not
kept aside.
