# Handoff: Audiout Remote release, 2026-09-10

Every task an agent could do in `docs/plans/PLAN-REMOTE-RELEASE.md` is built, merged, verified and sitting in five draft pull requests. What remains is the owner's: a simulator runtime, signing, a database migration, a log capture, a listen, and the release itself.

## Where everything is

| Repo | Branch | Pull request | State |
|---|---|---|---|
| audiout-shared | `main` at tag 0.9.0 (pushed) | [#9](https://github.com/aa-hh/audiout-shared/pull/9), docs only | 65 tests green |
| audiout-remote (phone) | `claude/remote-release` | [#21](https://github.com/aa-hh/audiout-remote/pull/21) | app and test-target builds green; tests never ran |
| Audiout (Mac) | `claude/remote-release` | [#162](https://github.com/aa-hh/Audiout/pull/162) | full suite green, last 3,691 tests |
| audiout-website | `claude/remote-release` | [#36](https://github.com/aa-hh/audiout-website/pull/36) | 40 pages build in both states, guard green in both |
| audiout-license-server | `claude/remote-release` | [#4](https://github.com/aa-hh/audiout-license-server/pull/4) | 56 tests green |

Each repo keeps an integration worktree at `<repo>/.worktrees/integration` checked out on that branch. The Mac repo's is at `/Users/alechenderson/Projects/AirPlay Controller/.worktrees/integration`. The main checkouts of the site, server and Mac hold the owner's own uncommitted work; do not edit there.

Specs and tickets: one spec issue per repo (shared #4, Mac #152, phone #11, site #21) with one ticket per task, all labelled `ready-for-agent`. The Mac spec has a correction comment on the first-pass status rule; read it with the spec.

The reasoning: the plan, the two ADRs (`docs/adr/0001-remembered-offset-on-reconnect.md` here, `docs/adr/0001-quieter-sweeps.md` in the shared package), the glossary `audiout-shared/CONTEXT.md`, the research note `dev/notes/bt-latency-stability-research-2026-09-05.md`, and eight design reviews and briefs in `dev/notes/remote-release-2026-09-05/`.

## Owner steps, in order

1. Install an iOS simulator runtime (`xcrun simctl list runtimes` is empty on Xcode 27.0), then run the phone suite on the integration branch. Expect first-run failures: every phone test is compile-verified only. `SyncSheetModelTests`, `AnalyticsTests`, `EmptyStateRuleTests`, `IntroCardsTests` and the rewritten `CompanionSmokeUITests` have never executed.
2. Fill the PostHog key placeholder `REPLACE_WITH_POSTHOG_PROJECT_API_KEY` in the phone's `Info.plist`. The sink refuses to start while the placeholder stands.
3. Set the phone's `DEVELOPMENT_TEAM` or pass it per `AGENTS.md:118-124`; TestFlight per `docs/companion-app-store.md`.
4. Apply licence-server migration `0005_remote_signups.sql` to production D1. `scripts/release.sh` refuses to cut a Mac release until then.
5. Listen to the quieter sweeps on a real speaker. The Mac stages them at 0.175 (was 0.35); the fallback named in the code is 0.25.
6. Connect one Bluetooth speaker with `log stream --predicate 'process == "bluetoothaudiod"'` open and paste the codec line into the settle record's codec closure in `BTSpeakerTiming`, or strike codec. It sends nil today.
7. Reconnect the Sonos Move 2, the Sony and a third speaker twenty times each; review `~/Library/Logs/Audiout/` (`bt_link_settled` joined to `bt_align_measurement` on `uid`) against the 10 ms threshold (T23).
8. Cut the Mac release (T19), TestFlight (T22), submit (T24). Launch day on the site is the runbook in the website's `HANDOFF-releases-2026-08-27.md`: generate `public/appstore-qr.svg`, set `PUBLIC_APP_STORE_URL`, one commit, `npm run guard:production`, `CONFIRM_PROD=yes npm run deploy:production`.

## Decisions still open, with the default that shipped

- Bluetooth is named in every sync claim except the home page headline. The owner never answered this one; D3 records it as assumed.
- "Diagnose" became "Details" on the failed speaker row, and Apps' empty state gained an "Add app" button. Both were the brief's assumptions.
- `sync:by_ear_nudged` fires when a run cannot get a confident answer, per the vocabulary doc, not on each slider nudge. The design review had read it the other way.
- A by-ear Keep made while the speaker is still settling publishes a first pass, so the phone row says "First pass. Check again" for it. Consistent with the stale rule; the ADR did not say it.
- Skip on the intro cards is a bare quiet text word over the field. The brief's author wanted a panel behind it. Judge on a device.
- QR symbol sizes: the integer-scale rule gives 54 pt of code at both the 72 and 96 pt tiles. If the 96 looks thin, retune the three nominal sizes, not the scale rule.

## Things that will bite the next agent

- **The Mac repo's write guard.** `~/.claude/hooks/protect-main-checkout.py` asks before any Edit or Write inside the Mac repo that is not under `.claude/worktrees/` or `.worktrees/`. Bypass-permissions mode does not silence it. Create a worktree under one of those two folders before any agent writes.
- **Agent worktree isolation follows the shell's cwd.** Spawning an agent with `isolation: "worktree"` gives it a worktree of whatever repo the parent shell was last in. Three agents were lost to this. Either reset cwd first or have the agent make its own worktree with `git worktree add`.
- **Mac commits go through three guards.** Guard 7 refuses any commit staging Swift until `scripts/self-review.sh` has run against those exact bytes; Guard 4 runs the affected suites (the full suite on a merge); build and test only through `scripts/build.sh` and `scripts/run-tests.sh`, never bare `swift build` or `swift test`. `run-tests.sh` can exit non-zero after printing a pass when the remote build Mac is busy, which makes Guard 7 print a spurious refusal; retry.
- **Two Mac tests are flaky under the parallel shared-slot fallback**: `AggregateOutputDeviceTests.blockedAttemptLineReleases` and `NativeBackendTests.stopStopsCapture`. They pass alone and in every gate run. Not touched.
- **Site and server builds in a worktree** need `node_modules`; a symlink to the main checkout's works (`ln -sfn ../../node_modules node_modules`) but remove it before committing, since the ignore pattern only matches a real directory. The server's `scripts/remote-run.sh npm test` fails on the remote (no vitest there); run `../../node_modules/.bin/vitest run` locally instead.
- **The production guard greps built HTML for the pill's class name once the store URL is set**, so a stylesheet selector that names `soon-pill` counts as a survivor. `/thanks` was caught this way once.
- **Phone tests cannot run on this Mac** until a simulator runtime exists. "Compile-verified" is the ceiling every phone report claims, and it is the truth.

## Not done, and why

- Crowd registry on the licence server: deferred until the owner's own settle log says a per-model median would help.
- `bluetoothDeviceClassMinor` is in the local settle record and log line only, not the release event, because the vocabulary doc lists no such property.
- The five Mac invite analytics events the brief proposed (`remote_invite:*`) are in the vocabulary doc but not sent; adding them is a small Mac change.
- The `endCompanionTickSession` path on the Mac records an alignment twice (a by-ear Keep), the same shape as the defect fixed for phone measurements. Out of scope, harmless, noted by the T14 agent.
- The T16 screenshots of the wizard, Settings row and seventh card were rendered by the snapshot tools but not committed (16 MB). Regenerate with `onboarding-snapshot` and the wizard and settings snapshot renderers.
- The site's "Main Out" mentions outside BRAND-VOICE rule 12 (site `PRODUCT.md:28, 35, 280`, `BRAND-VOICE.md:55, 131, 258`) still say Main Out; the brief called that a separate owner pass.

## If the plan is picked up again

Read the plan's task table for the file anchors, the brief named in each row for copy and layout, and the ticket for verify and dependencies. Every ticket is closed by its repo's pull request when merged. After merging, delete the integration worktrees (`git worktree remove .worktrees/integration`) and the per-repo `claude/remote-release` branches; the shared package's session branch `claude/ftu-optimization-differentiation-5b027d` can go once #9 merges.
