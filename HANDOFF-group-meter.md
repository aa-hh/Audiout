# Device meter never populates on a GROUP redirect — PAUSED 2026-08-29

Paused mid-flight because the machine was overloaded. **No fix exists. No root
cause was ever confirmed.** Three agents worked here; two were stopped by
accident, the third on purpose when work stopped.

## The live bug (Alec, 2026-08-29)

An app redirected to a saved GROUP plays correctly out of the group's members,
but the device rows' level meters stay empty: "the meter never gets populated on
devices when we're doing the redirect now to a group."

## State of this worktree

Branch `claude/group-device-meter` at `ec5b318e` — **nothing committed.**
Uncommitted:
- `AudioutCore/Tests/AudioutCoreTests/NativeBackendTests.swift` — a reproduction
  attempt. The third agent reviewed it and judged it structurally sound (it
  mirrors the existing `groupRouteCarriesAudioToEveryMemberThroughFullPipeline`,
  and it verified the helpers it uses exist). **It was never seen to run to
  completion**, so treat it as unproven.
- `AudioutCore/AGENTS.md` — a doc edit describing intended behaviour.

The third agent reported "root cause identified in source, fix approach settled,
not yet applied" but was stopped before it said WHAT either was. Do not assume
it had it right.

## The one thing to do first

**Establish the control.** Does a redirect to a SINGLE device (`.device(id:)`)
populate the device meter, while a GROUP redirect does not? That comparison IS
the diagnosis. If both fail (or both pass in test) the bug is not where everyone
has been assuming, and the hunt starts over. Nobody has completed this run.

## Prime suspect

The same mistake has now been found THREE times on this lineage: code that asks
"is this device the target of a `.device` route?" never matches a group member.
Commit `6dfdd0e9` added `NativeBackend.routesTargetDeviceLocked(_:)`
(NativeBackend.swift:4264) after two route-recovery guards made it; the
connection-ring path made it a third time. Grep the metering path for anything
keying on `.device(` or on a single device id.

Also: `AppRouteMixer.streamIDs(for:)` is PLURAL — one app can feed several
streams when group members carry different gains — so anything assuming one
stream per app is suspect.

Architecture per the code's own comments (verify, don't trust):
`AppRouteMixer.onAppLevel` fires an app's PRE-volume source RMS gated on the
mixer's `meteringActive`; `NativeBackend.emitAppLevel(bundleID:rms:)` consumes
it; the mixer wiring claims "the per-device meter is driven by the apps'
PRE-volume SOURCE levels, NOT this post-volume mixed buffer." Find how an app's
level maps onto the device(s) it feeds. Also confirm metering is even ARMED for
group members (`setMeteringActive` / `meteringActive`) — if arming keys on
devices the code believes are routed, a group member may never arm.

## ⚠️ Warning carried over from the sibling ring bug

There, a reproduction test **passed against unmodified source** — a green run
that proved nothing, and a fix was nearly built on top of it. Before trusting
any fix here: confirm the repro actually FAILS first, then mutation-check by
reverting only the source change.

## Working notes (three agents lost turns to this)

Use `bash scripts/run-tests.sh --filter <tight filter>` with
`AUDIOUT_TEST_NO_CACHE=1` for anything conclusive — the unchanged-sources cache
returns exit 0 having executed NOTHING and has already produced a false green.
Do not run the full suite while iterating; the commit guard runs it anyway.
