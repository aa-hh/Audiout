# Handoff 2026-09-26: unregistered mode (trial end no longer gates)

Read first: `AGENTS.md`, `CLAUDE.md`, then `dev/notes/unregistered-mode-spec-2026-09-26.md`
(the owner-confirmed spec, every ruling in it stands) and `CONTEXT.md` (glossary:
registered, unregistered, trial, Selected Speakers, note).

## Where things are

| What | Where | State |
|---|---|---|
| Mac build | branch `claude/trial-expiration-conversion-c93563`, commit `a4b63d74`, worktree `.claude/worktrees/trial-expiration-conversion-c93563` | committed, pushed, NOT merged, no PR yet |
| Shared analytics rows | `aa-hh/audiout-shared` branch `claude/unregistered-mode-analytics`, commit `ad21c35`, worktree `~/Projects/audiout-shared/worktrees/unregistered-mode-analytics` | committed, pushed, NOT merged, no PR yet |
| Spec | `dev/notes/unregistered-mode-spec-2026-09-26.md` | final |
| Card concept | `dev/notes/thank-you-card-concept-2026-09-26.md`, Concept A built | final |
| Research | `dev/notes/trial-end-ux-survey-2026-09-26.md`, `dev/notes/trial-end-conversion-evidence-2026-09-26.md` | committed (2fa2e287) |
| Work order + executor reports | scratchpad of the old session, not in the repo; the commit message and spec carry everything needed | gone with the session |
| Staging test copy | mule `alechamilton@SUMUP-M9Y197RFVG.local`, `~/AudioutStaging/Audiout Staging.app`, bundle id `com.audiout.Audiout.staging`, licence server `license-staging.audiout.app`, buy page `staging.audiout.app/buy` | running since 13:43 CEST; trial seeded to expire 13:49 CEST |
| Dev build on this Mac | not built; live-test slot was held by `claude/aggregate-wraps-speakers` | n/a |

## What the build does (one paragraph)

An unregistered install (trial ended, key refunded or revoked, or no key) keeps
running with every feature but one speaker in Selected Speakers; groups and
Bluetooth sync are off; per-app routes are free. The gate window opens only for
a first open with no key and no trial (`LicenseGate.shouldPresent`); the limit
is `LicenseGate.limitsToOneSpeaker` → `GroupController.limitsToOneSpeaker`, set
from `AppDelegate.applyLicenseState`. Clicking a second speaker is refused
(`SelectionResult.refused(GroupController.oneSpeakerLimitReason)`); the row
shows "Play here instead", which calls `GroupController.switchSelection(to:)`
(one routing apply). The popover note reads "Your trial has ended. Audiout plays
on one speaker at a time until you buy." with an underlined "I have a key"
(opens the Settings licence sheet) left of "Buy Audiout" (browser; `buyURL`
keeps `?t=<trial key>` after expiry). A one-time thank-you card
(`ThankYouCardView`, rings via `AudioutField`) shows on the first popover open
after the key is honoured; its shown flag is written on Close, on popover hide
and on quit; the analytics consent ask moves to the open after it. Launch with a
saved set of two or more falls back to This Mac and saves it.

## Owed, in order

1. **Live look by Alec on the mule** (the staging copy). Checklist: pill before
   13:49, standing note after; second speaker refused + row offer; group in the
   Main Out menu greyed under its caption; a sync door shows the note; quit and
   relaunch with two saved → This Mac; Settings › General shows Buy and the
   trial-ended line; Buy → staging site → Paddle sandbox test card → return via
   `audiout://register` or next popover open → thank-you card (fade + ring
   pulse are GPU-only, untested until now) → consent ask on the open after.
   If the pill said "14 days left" at first open, the staging server refused the
   seeded start date (it must be within 14 days); reseed with
   `defaults write com.audiout.Audiout.staging trial.startedAt/expiresAt` (ISO
   8601 strings, start = now − 14 d + a few minutes) with the app quit, then
   relaunch.
2. **Fixes from the live look**, if any, on this branch through `/scope-and-run`
   or a small direct edit; the spec is the authority.
3. **Merge.** Mac: open a PR from the branch, and land locally with
   `git merge --no-ff` onto `main` (never commit on main; the pre-merge-commit
   hook runs the full suite uncached). Shared: PR from
   `claude/unregistered-mode-analytics`. Then `touch .claude/worktrees/trial-expiration-conversion-c93563/.prunable`.
4. **PostHog**: the `license:expired_gate_shown` stream ends; four new events
   (`license:limit_hit`, `license:switch_offer_used`, `license:thank_you_shown`,
   `license:thank_you_closed`); `license:buy_link_opened` source `mixer_note` is
   now `note`. Update any insight that filters on the old value.

## Traps met today

- **Guard 4's full suite is load-sensitive.** Five commit attempts each failed
  on a different clock-reading test (`firstWindowRunsAtTheStartDelay…`,
  OnboardingUITests, PopoverControllerRowRevealTests, SetupFlowModelTests) while
  other sessions loaded both Macs (local load average peaked at 48). Each suite
  passed alone and the whole suite passed in 275 s once quiet. Do not read those
  as this branch. `AUDIOUT_TEST_PREFER=local` keeps a run off the mule;
  `AUDIOUT_FULL_SUITE=1` is needed for a deliberate full run mid-task.
- **A `work-order-executor` cannot create files in a sibling worktree** (the
  write guard refuses); editing existing files worked. Run any track that adds
  new files in the session's own worktree.
- **A licence-server build needs Sparkle's public key and a build number**:
  `SPARKLE_ED_PUBLIC_KEY=$(AudioutCore/.build/artifacts/sparkle/Sparkle/bin/generate_keys -p)`
  and `BUILD_NUMBER=<n>` alongside `AUDIOUT_LICENSE_URL`, or `make-app.sh` stops
  after compiling. `AUDIOUT_BUNDLE_DYLIBS=1` makes the app self-contained for a
  Mac without Homebrew.
- **The mule's app process is named `AudioutApp`**, not the app name; check with
  `pgrep -lf "<App>.app"`.
- **The live-test slot only protects this Mac's running dev copy.** A copy for
  the mule can be built with `AUDIOUT_NO_LIVETEST_LOCK=1`; a staging id needs no
  slot at all.

## Analytics read (for context)

PostHog, 60 days to 2026-09-26: 7 customer trials started, 4 expired, 0 bought.
All four expired Macs ran builds from before analytics defaulted on (12 Sept,
commit 685bd651), so they sent nothing; the trials from 12 and 19 Sept will
report. Machine `7DC24692…` is Alec's own trial Mac.
