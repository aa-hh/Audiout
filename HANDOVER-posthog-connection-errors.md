# Handover — PostHog `connection:failed` flood

Written 2026-09-10. Branch `claude/postfog-connection-errors-85597b`, worktree
`.claude/worktrees/postfog-connection-errors-85597b`, clean at `5815803a`.
**No code has changed yet.** The investigation is finished and verified; the
three fixes are specified but not built.

## What was asked

The owner saw one install whose PostHog events were almost entirely
`connection:failed`, after releasing 1.1.1, and suspected the app was ignoring
a user's decision to decline tracking. A four-agent investigation ran on
2026-09-09. Then the owner asked for a team to build the fixes, with the
coordinator holding final sign-off and adversarial review of the team's own
work. The `/scope-and-run` pipeline was invoked and the scoping agent was
interrupted twice before it returned anything. Nothing from those runs
survives. **Restart at Step 1 of the pipeline** using the scoper brief in the
appendix below, which is the interrupted prompt verbatim.

## What the investigation found

Every claim below was read in this worktree or pulled from PostHog with a
read-only query. Do not re-derive them.

### The flood is a real defect, but not a privacy one

`connection:failed` does not mean "the user's connection failed". It fires
whenever any AirPlay 2 speaker on the network drops its `_airplay._tcp`
advert for more than three seconds, whether the user selected it or not, and
whether the app window is open or not.

- `NativeBackend.merge(existing:discovered:)`
  ([NativeBackend.swift:9171](AudioutCore/Sources/AudioutCore/NativeBackend.swift:9171))
  sets `.failed(ConnectionFailure(cause: .vanished))` at line 9192 for any
  sticky-AirPlay-2 device that loses that advert. `markDisappeared` (~8521)
  turns a full disappearance into `.off`, and discovery rebuilds a clean entry
  on return, so every lapse-and-return is a fresh edge.
- `PopoverController.handleConnectionTransitions`
  ([PopoverController.swift:3453](AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:3453))
  captures the event at 3468-3470 on every not-failed-to-failed edge.
  `connection:connected` is at 3479-3481. Neither checks that the user wants
  the speaker.
- `AppDelegate` calls `popoverController.update(devices:)` unconditionally
  ([AppDelegate.swift:3236](AudioutCore/Sources/AudioutApp/AppDelegate.swift:3236)),
  so a closed window changes nothing.
- The right predicate already exists in the same file:
  [PopoverController.swift:3514](AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:3514)
  uses `wantsAudio(id)` to drop the diagnosis-panel intent for rows that do
  not want audio. Reuse it. Do not invent a new one.

### Consent is honoured — the owner's hypothesis was wrong

The install in question opted in. It sent `onboarding:usage_stats_opted_in`
seconds after install and sends `app:launched` on every launch, which only
fires with consent true. Both decline paths (`Don't Share` on the Setup card,
and the Settings toggle) write `telemetryOptIn = false` and call the SDK's
`optOut()`
([SetupModel.swift:1088](AudioutCore/Sources/AudioutCore/SetupModel.swift:1088),
[GeneralSettingsViewController.swift:596](AudioutCore/Sources/AudioutSettingsUI/GeneralSettingsViewController.swift:596)).
PostHog SDK 3.69.12 drops capture, logs, lifecycle events, identify and crash
reports while opted out. Two production installs exist in PostHog against
eight downloaders and seven trials in the same window; the rest sent nothing,
which is what a working decline looks like.

### The numbers

| Fact | Value |
|---|---|
| Person id | `a9062f9e-cb4d-55e3-999f-e71cad1ed1a4` |
| Install id (log attribute `posthogDistinctId`) | `7DC24692-8C26-43E9-A065-99B3CD44F95B` |
| `connection:failed` events | 357 |
| of which cause `vanished` | 356 |
| largest burst | 16 events in 20 ms |
| user actions during the bursts | 0 |
| pattern on 1.1.0 vs 1.1.1 | identical |

### Release facts (no tags exist — identify a release by commit count)

- 1.1.1 is `f7cde25c`. Build 1603 is `git rev-list --count HEAD`, which
  `scripts/release.sh:64` sets.
- 1.1.0 is `c3584c8a`, hand-numbered build 7, cut through `make-staging.sh`.
- PR #163 (`ccecb19a`, the onboarding Speaker Sync gate the owner was thinking
  of) is **not** in 1.1.1 and is about the PTP helper, not AirPlay.
- The logs bridge (`54cdfea8`) and the three-second advert debounce
  (`2632ad41`, PR #151) both **are** in 1.1.1.

## The three fixes to build

### Fix 1 — gate the two connection captures on intent

Capture `connection:failed` and `connection:connected` only for a device that
wants audio. Keep the event names and property names exactly as they are;
CLAUDE.md treats event names as an external contract. `connection:diagnosis_shown`
and `connection:retry_clicked` are already user-driven; leave them alone.
Decide explicitly whether `connection:connected` keeps its current exclusion of
`device.isLocalDevice`.

### Fix 2 — the two privacy gaps

These are the part that affects users, because they break the promise the
consent card makes.

**(a) The diagnostic-log bridge.** `Analytics.log`
([Analytics.swift:84](AudioutCore/Sources/AudioutCore/Analytics.swift:84))
strips only `deviceKeys = ["device", "deviceID", "uid", "name", "host", "address"]`.
Live PostHog logs right now carry, from the owner's own Mac:

| Field | Example value seen | Source |
|---|---|---|
| `bundleID` | `org.mozilla.firefox`, `com.spotify.client` | several `capturePA` lines |
| `excluded` | `org.mozilla.firefox` | `captureWS.exclusion_changed` |
| `processes` | `27455:own` | `capturePA.process_resolved` |
| `error` | `processNotYetAudible(bundleID: "com.apple.Music")` | `capturePA.transition` |
| `desiredOn`, `added`, `removed`, `kicked` | speaker names | `NativeBackend.telemetryDeviceList` renders `known[$0]?.name ?? $0` at ~3244 |
| `aggregateUID`, `target` | `7EA124FC-…`, `Optional(85)` | needs a ruling |

The fence in PRODUCT.md "Data Collection" and CLAUDE.md forbids speaker and
device names, bundle ids, network identifiers and free text. There are roughly
120 `Telemetry.log` call sites; the scoper must inventory every field key and
hand the executor a finished allow-or-deny list, not the job of deciding. The
local telemetry file may keep everything — only the bridge to PostHog needs
narrowing.

**(b) The feature-flag request.** Add `config.preloadFeatureFlags = false` in
`configurePostHog()`
([AppDelegate.swift:78](AudioutCore/Sources/AudioutApp/AppDelegate.swift:78))
before `setup(config)`. The pinned SDK posts to `/flags` at every launch
regardless of opt-out, carrying the install id, bundle id and OS and app
version (`PostHogRemoteConfig.swift:196-214` in
`AudioutCore/.build/checkouts/posthog-ios`, revision `4cf77c21`, 3.69.12). It
is dormant only because the project has zero feature flags and the live
`/config` reply says `hasFeatureFlags:false`. The day anyone creates a flag,
every declined install starts sending identifiers.

### Fix 3 — the Setup spine copy

[OnboardingViewController.swift:799](AudioutCore/Sources/AudioutOnboardingUI/OnboardingViewController.swift:799)
still promises `"No audio, speaker names, network details or license key ever
leave your Mac."` Network type is sent (PRODUCT.md ~line 69). The consent card
body was already corrected
([UsageStatsConsentCard.swift:145](AudioutCore/Sources/AudioutOnboardingUI/UsageStatsConsentCard.swift:145));
match its wording.

## Deliberately out of scope

- A replacement "advert lapsed" event. If the owner wants network-flakiness
  data, that is a separate ask with its own privacy review.
- The SDK's persisted opt-out overriding `config.optOut` at setup
  (`PostHogSDK.swift:214-217`). The two stores only diverge if preferences are
  reset without the SDK folder. Noted, not fixed.
- Crash reports written after a runtime opt-out, which upload at the next
  opt-in. Same reasoning.
- Anything about PR #161 (the Wi-Fi blip auto-resume, unmerged on
  `origin/claude/wifi-blip-path-recovery`). It is the real user-facing half of
  this area and it is somebody else's branch.

## Traps

- **A `--filter` that matches nothing exits 0 and prints "passed."** Verify by
  grepping for a `Test run with N tests` line, never for the word "passed".
- **Never a bare `swift build` or `swift test`.** Use `bash scripts/build.sh`
  and `bash scripts/run-tests.sh --filter <Suite>`; only those know about the
  second Mac, the concurrency cap and the cache.
- **The Agent tool's `isolation: "worktree"` forks from `main`, not from this
  branch.** Create each track's worktree by hand from the branch HEAD.
- **The `AudioutApp` target is invisible to the test suite**, so Fix 2b and
  anything else in `AppDelegate.swift` verifies with a build plus a grep, not
  a test.
- **Row-selection tests bypass AppKit dispatch.** Check how the existing tests
  drive `update(devices:)` before writing a new one.
- **In PostHog, logs and events cannot be joined in one query** — different
  clusters. The `read-data-schema` tool is missing a scope on this connection;
  use `execute-sql` instead.
- The owner's word "logs" in the original request meant the person's event
  feed, not PostHog Logs.

## Pipeline the owner asked for

`/scope-and-run`, with the coordinator holding final sign-off and adversarial
review of the team's own output. Nobody commits or pushes; work stays
uncommitted until the owner has seen the report. Proposed track split, to be
confirmed by the scoper as non-overlapping:

| Track | Work | Files |
|---|---|---|
| A | Fix 1 | `PopoverController.swift` and its test file |
| B | Fix 2a | `Analytics.swift`, possibly `NativeBackend.telemetryDeviceList`, `AnalyticsTests.swift` |
| C | Fix 2b and Fix 3 | `AppDelegate.swift`, `OnboardingViewController.swift` |

Review is required regardless of diff size: more than one track runs, and the
change touches device lifecycle and a privacy boundary.

## Appendix — the scoper brief, verbatim

Hand this to `fable-scoper` (or `opus-scoper` if Fable is unavailable) as-is.
It is the prompt that was interrupted, and it already carries every citation
above.

> Produce a paint-by-numbers work order for Opus executors. Repo worktree
> (work ONLY here, never the main checkout):
> `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/postfog-connection-errors-85597b`,
> branch `claude/postfog-connection-errors-85597b`, clean at HEAD `5815803a`.
> Read CLAUDE.md, AGENTS.md at root and the nearest AGENTS.md of every folder
> you cite. Nobody commits or pushes; all work stays uncommitted.
>
> Background, the three fixes, and the constraints are the body of this
> handover — sections "What the investigation found", "The three fixes to
> build", "Deliberately out of scope" and "Traps". Additional scoping
> requirements:
>
> - For Fix 1, read `wantsAudio` and confirm its semantics (selected versus
>   desired-on) before citing it. Find the existing PopoverController
>   analytics tests (grep Tests for `connection:failed`,
>   `handleConnectionTransitions`, `lastConnectionStates`, `Analytics.install`)
>   and specify the exact tests to add: an unselected device entering `.failed`
>   captures nothing; a selected one captures once; a transition that captured
>   before still captures. Follow the "tests buy their place" rule — name the
>   defect each test catches, one varying axis, extend existing tables.
> - For Fix 2a, inventory every `Telemetry.log` field key across
>   `AudioutCore/Sources` and classify each as safe or must-strip. Rule on
>   `aggregateUID` and `target`. Choose the mechanism (an allow-or-deny list in
>   `Analytics.swift` is preferred) and leave the local telemetry file
>   untouched. Extend the existing strip-and-consent table in
>   `AnalyticsTests.swift` (~lines 28-106).
> - For Fix 3, give the exact replacement string and check for a snapshot or
>   copy test pinning the old one (grep Tests for "network details").
> - Give exact suite names and a "Verification" section with the exact
>   commands and the line to grep for in each output.
> - Add a Docs step if any AGENTS.md or PRODUCT.md row must change — at
>   minimum the doc comment in `Analytics.swift` describing what is stripped.
> - Executor rules must include: read the nearest AGENTS.md before editing a
>   folder; report spec-versus-reality discrepancies instead of improvising;
>   never commit.
>
> Return the complete work order.

## Related memory

`posthog-connection-failed-flood-investigated.md` in the project memory
directory holds the same findings in compressed form, plus links to
`posthog-error-tracking-built`, `usage-stats-onboarding-card`,
`wifi-blip-path-recovery-built` and `pr151-removal-grace-reshaped`.
