# Handoff: Audiout Remote release, 2026-09-10 (evening)

Every agent task in `docs/plans/PLAN-REMOTE-RELEASE.md` is built, merged into its branch, tested on a machine, and sitting in six draft pull requests that all merge cleanly against `main` as of 23:15. What remains is the owner's: the merges, App Store Connect, TestFlight, one session at the speakers, and the release itself. The first pass of this note (morning) got three things wrong; they are corrected below.

## Where everything is

| Repo | Branch | Pull request | Head | Proof |
|---|---|---|---|---|
| audiout-shared | `claude/ftu-optimization-differentiation-5b027d` | [#9](https://github.com/aa-hh/audiout-shared/pull/9), docs only | 81040da | 65 tests green; tag 0.9.0 already on `main` |
| audiout-remote (phone) | `claude/remote-release` | [#21](https://github.com/aa-hh/audiout-remote/pull/21) | 8f9612c | 278 unit tests + the UI walk pass on the second Mac's iPhone 17 Pro Max simulator, iOS 26.4 |
| Audiout (Mac) | `claude/remote-release` | [#162](https://github.com/aa-hh/Audiout/pull/162) | 0e8742bc | full suite, 3,761 tests, green under the commit guard |
| Audiout (Mac) | `claude/test-false-failures` | [#165](https://github.com/aa-hh/Audiout/pull/165), infra | 10ad248e | three false-failure fixes, see below |
| audiout-website | `claude/remote-release` | [#36](https://github.com/aa-hh/audiout-website/pull/36) | 2e9fce1 | builds and `guard:production` pass in both launch states |
| audiout-license-server | `claude/remote-release` | [#4](https://github.com/aa-hh/audiout-license-server/pull/4) | c29f844 | 109 tests green |

Integration worktrees: `<repo>/.worktrees/integration` on the branch, in every repo. The Mac's is `/Users/alechenderson/Projects/AirPlay Controller/.worktrees/integration`. Main checkouts still hold the owner's own uncommitted work; do not edit there.

Merge order: shared #9, server #4, site #36, Mac #162, phone #21. #165 is independent. Merging changes nothing live: the site stays in its pre-launch state until `PUBLIC_APP_STORE_URL` is set, and the Mac release is a separate `scripts/release.sh` run.

## What changed today

- Every branch merged `main` back in. The Mac side took the 14-day free trial (five conflicts, resolved by union: the setup flow now has four skippable steps, and the consent card names both the settle timing and the diagnostic log). The site side had two implementations of the iPhone launch switch; the owner ruled the branch's `src/lib/remote.ts` wins and main's `REMOTE_LIVE` in `checkout.ts` is gone. The email-me signup form from main stays and reads the branch's switch.
- The phone's five never-run suites ran for the first time and found two app defects: a refused run reporting "Stopped." because a cancelled recording re-entered the completion, and the shell's top strip drawing over each tab's header so the Apps tab's add button took no taps. Both fixed. A read-only review then found the analytics opt-out switch left the PostHog SDK running (fixed: `config.optOut`, no feature-flag preload, the toggle calls opt in/out), `speaker_kind` reporting AirPlay speakers as Bluetooth (fixed via `SpeakerTransport.of`), a refused verdict carrying a fake "0-9" bucket (fixed: both properties optional), about 25 literals bypassing the String Catalog (wrapped), and the Demo badge drawn twice on Settings (row's copy removed).
- Owner rulings applied: "Diagnose" stays on the failed row; "Add app" stays; `sync:by_ear_nudged` fires once per slider nudge (phone capture moved to `SyncSheetModel.nudge`, vocabulary doc row rewritten on shared #9); a by-ear Keep while settling stays a first pass; the phone shares the Mac's PostHog project, token in `Info.plist`, EU host; the home headline keeps "measured with your iPhone"; the Settings row's connection lamp is now a flat 8 pt `WarmSignal.wire` dot 4 pt before the word "Connected", only while live, Settings row only; the two sync sheet sentences say "on last time's timing".
- Mac: the four `remote_invite:*` events the vocabulary doc names are captured (the doc lists four, not five). Review screenshots of the wizard page, Settings row and seventh card were rendered, not committed.
- Site: /remote's three measurement FAQs hide until launch; the App Store badge has 16 px above and below like the pill; the dead `.feat-cell h3 .soon-pill` rule is gone; the phone mockup in the features cell was redrawn (Settings is the fourth tab, no Connection tab); /remote no longer says the demo lives on a Connection tab; two `.env` comments corrected.
- Infra (#165): `scripts/run-tests.sh` exited 1 after a passing local run (the exit trap's `kill` on a reaped process group), `CompanionServerTests` raced by sending a command before `welcome`, and `scripts/lib/remote.sh` probed the second Mac with a bare `xcrun --show-sdk-platform-path`, which that Mac's stray Command Line Tools SDK fails; the probe now names the macOS SDK and runs route to the second Mac again.

## Corrections to the morning note

- Migration `0005_remote_signups.sql` was already applied to production D1 on 2026-09-05 (and 0006 for the trial on 09-06). The release script's gate passes.
- The simulator runtime on the owner's Mac was deleted on purpose (7.5 GB). Phone tests run on the second Mac: from the Mac repo, `AUDIOUT_IOS_REMOTE_ONLY=1 bash scripts/ios.sh test --root <phone worktree>` (needs #165's probe fix, or run it from that worktree). The physical iPhone is still the only place the app counts as verified.
- The signing team is a command-line override documented in the phone's `AGENTS.md`; nothing to set in the project.

## Owner steps, in order

1. Merge the six pull requests in the order above (local `git merge` plus the GitHub merge, per the Mac repo's rule).
2. Phone on the iPhone 15 Pro: `scripts/ios.sh device --root <phone checkout>`. Judge on the device: Skip on the intro cards (bare text vs a panel), the QR at 96 pt on the Mac's seventh card, the Settings row dot, and the shell strip over the tabs (a layout change that only ran in the simulator).
3. App Store Connect record, `DEVELOPMENT_TEAM=TGT8D69RZ4` archive, TestFlight to three outside phones (T22), per `docs/companion-app-store.md`.
4. One session at the speakers with the Mac dev build (`APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev"`, slot held) and a fresh bundle id for the onboarding card: listen to the sweeps at 0.175 (`AlignmentTickInjector.probeAmplitude`, fallback 0.25); connect one Bluetooth speaker with `log stream --predicate 'process == "bluetoothaudiod"'` open and paste the codec line into the settle record's codec closure in `BTSpeakerTiming`; one full measurement with the before-and-after; a reconnect for "Timing from last time"; a measure-while-settling for "First pass. Check again"; then twenty reconnects each on the Sonos Move 2, the Sony and a third speaker (`brew install blueutil` makes the loop scriptable), and the log join `bt_link_settled` to `bt_align_measurement` on `uid` against the 10 ms threshold (T23). Confirm in PostHog project "Audiout" that the phone's nine events and the Mac's settle event arrive with no device names.
5. Cut the Mac release (T19), submit (T24). Launch day on the site is the runbook in the website's `HANDOFF-releases-2026-08-27.md`: generate `public/appstore-qr.svg`, set `PUBLIC_APP_STORE_URL`, one commit, `npm run guard:production`, `CONFIRM_PROD=yes npm run deploy:production`.

## Open, not blocking

- `SyncInviteCard.swift` has a sentence with "timing from last time" and two code comments use the phrase; the owner's ruling named only the two sync sheet sentences.
- The Mac's `endCompanionTickSession` still records a by-ear Keep's alignment twice (harmless, noted by the T14 agent).
- `CompanionEndToEndTests` show six timeouts under a heavily loaded full parallel run on this Mac only; a separate session was spawned for it. The Bluetooth speaker list for T23 and the three TestFlight testers were never named.

## Things that will bite the next agent

- The Mac repo's write guard asks before any Edit or Write outside `.claude/worktrees/` or `.worktrees/`; the merge hook asks before any `git merge` (subagents in bypass mode get through; a non-interactive session may not).
- `ios.sh` reads `audiout.remoteHost` from the git config of the current directory: run it from a Mac repo worktree with `--root` pointing at the phone checkout.
- Two xcodebuild runs on the same second-Mac simulator at once reset each other's app state and look like a flaky UI test. Serialize them.
- The in-app browser pane does not paint while hidden; screenshots of the built site come from headless Chrome (`scratchpad/shot-grid.mjs` pattern: DevTools protocol, scroll in steps so the reveal observers fire).
- Site and server builds in a worktree need a `node_modules` symlink to the main checkout's, removed before committing.
