# Handoff — rail connect-pulse: event-driven refactor

**Status: not started.** The design is done and reviewed (by me, and grounded
against the real code by a scoping pass). The execution agent that was supposed
to *implement* it hit its API session limit before writing a single line of
code — it was still re-deriving a test-harness precedent for the last step when
it died. **Nothing in this folder has been applied to source yet.** Everything
below is: what already shipped (unrelated, already verified), what's designed
but unbuilt, and the exact plan to build it.

Read this file top to bottom before touching anything. It's written for someone
with zero context on this conversation.

## Where things stand right now (verified moments before writing this)

Worktree: `.claude/worktrees/rail-animation-bugs-89dd1a`, branch
`claude/rail-animation-bugs-89dd1a`. **Uncommitted** changes in 4 files — these
are real, already-tested fixes from earlier in this session, NOT part of the
refactor below, and should NOT be reverted:

- `AudiouterCore/Sources/AudiouterSharedUI/BusRailOverlayView.swift`
- `AudiouterCore/Sources/AudiouterPopoverUI/PopoverPanelViewController.swift`
- `AudiouterCore/Tests/AudiouterCoreTests/BusRailCollapseResolveTests.swift`
- `AudiouterCore/Tests/AudiouterCoreTests/RailConnectPulseTests.swift`

Confirmed clean baseline just now:
```
bash scripts/run-tests.sh --filter 'RailConnectPulseTests|BusRailCollapseResolveTests|PopoverDeviceVisibilityTests|MembershipRailTests'
→ Test run with 91 tests in 4 suites passed after 8.182 seconds.
```
Full suite was also green (2543 tests) as of the last full run this session.

### What those 4 already-uncommitted files fix (already done, already tested — keep)

Three real bugs found via live testing on real hardware, fixed and verified
(each has a regression test proven to fail-without/pass-with the fix):

1. **Rail plays a connect-pulse animation on popover OPEN it shouldn't.**
   Fixed by settling the pulse baseline when a draw happens while the window
   isn't visible (the reopen ritual draws once off-screen before the real
   on-screen draw).
2. **Rail draws a spurious tail into empty space when a section is rapidly
   collapsed/expanded.** Fixed: the terminus cut now only fires when a
   collapsing section actually hides a *member* device, not any hidden row.
   Two sub-cases needed different signals (a card collapses its rows in place;
   a subsection collapse *drops* rows from the model entirely) —
   `RailPlan.dropsHiddenRows` distinguishes them.
3. **A staged multi-device connect (a fresh build's very first handshake,
   which lands several rooms across a few draws) stutters the pulse** — it
   used to cancel-and-restart on every room landing. Fixed: `runConnectPulse`
   now coalesces — a gain arriving while a bead is already in flight is
   skipped, not restarted (`guard pulseLayer == nil`).

These three fixes are good and live-verified by Alec on real hardware (test
builds "Audiouter Rail Fix v1/v2/v3"). **Do not touch or revert them** while
doing the refactor below — the refactor builds ON TOP of this state.

## Why we're refactoring instead of patching further

After fix #3, Alec hit a **fourth** false-positive: collapsing then expanding a
device *subsection* triggered a pulse, with no actual connection happening.
Root cause: subsection collapse drops the subsection's rows out of
`deviceRows` entirely, then re-adds them on expand — and the pulse-firing
logic (in `BusRailOverlayView`) works by **diffing the on-screen row list
between draws**. To that diff, "rows disappeared and reappeared" looks
identical to "a device joined." This is the same root cause as bug #2 above,
just a different trigger path we hadn't hit yet.

**The conclusion (Alec agreed): stop patching the diff.** The diff-based
approach is fundamentally unfixable by enumeration — there will always be
another layout event that looks like a membership change to a view-layer
diff. The fix is architectural: **fire the pulse from the actual model event
(a device becoming a connected member), not from inferring it by diffing
rendered rows.** A layout-only change then cannot trigger it *by
construction*, because layout changes don't touch the model-level connection
state at all.

This turns "patch bug #5, #6, #7 as they're found" into "delete the class of
bug." That's the refactor documented here.

## The two documents in this folder

- **`01-design-brief.md`** — the architecture I (the orchestrating session)
  wrote and Alec approved. Read this for the *why* and the target shape.
- **`02-work-order.md`** — a Fable-run scoping pass that read the actual
  current code and turned the brief into a paint-by-numbers, line-anchored
  execution plan: exact symbols to delete, exact line numbers (as of when it
  was written — **re-verify them, don't trust them blindly**, the file may
  have shifted slightly), the exact test rewrite plan, and a list of traps it
  already found by reading the code (see "Traps already found" below). This
  is the one to actually execute from.

**Important:** the work order's line numbers were correct against the worktree
state at scoping time. If anyone has touched these files since (they
shouldn't have), re-verify anchors before trusting them — search by symbol
name, not blindly by line number.

## Traps the scoping pass already found (do not re-derive, just obey)

These are the non-obvious things a naive read of the brief would get wrong.
Full detail is in `02-work-order.md`'s "Verified facts" and "Risks" sections;
summarized here so they aren't missed:

1. **Name collision.** `PopoverController` already has its own, completely
   unrelated `private func reconcileEnergize()` at line ~1662 (an item-9
   "energize pending beat" pruning system). The refactor deletes
   `BusRailOverlayView`'s **different** method also named
   `reconcileEnergize(with:)`. Do not touch the controller's one.
2. **The obvious "member" predicate is wrong for this purpose.** The row's
   own `.member` node predicate includes `ConnectionState.off` and keys off
   `isSpeakerSelected` (would you check a box), not "is this device actually
   in the live mix." Using it verbatim would double-fire across the
   `.off → .connecting → .connected` dip and would fire on a per-app-redirect
   connect that never touches the Main Audio wire. The correct predicate,
   worked out and justified in the work order, is:
   `isMainOutMember(id) ∧ connectionState == .connected`.
3. **The firing hook already has a diff precedent to copy.**
   `PopoverController.update(devices:)` already computes a similar
   Main-Out-membership diff (`lastMainOutMemberIDs`) for an unrelated purpose.
   The new `lastConnectedMemberIDs` diff should sit right next to it, same
   shape.
4. **The new state MUST persist across popover close/reopen and
   `rebuild()`/`rebuildForOpen()`**, and must **keep updating while the
   popover is hidden** — otherwise a device that connects while the popover
   is closed would look like a fresh join the moment you reopen, recreating
   exactly the open-time false-pulse bug we already fixed once. This is why
   the new set lives on the controller (model layer), not the overlay (view
   layer) — the overlay's state dies and resets with the view lifecycle; the
   controller's does not.
5. **`MainOutDetailViewController` hosts no rail overlay at all** (only the
   popover panel and `GroupEditorViewController` do, and the editor's
   `receiveRailPulse` is already a no-op). Nothing to change there.

## The shape of the change

- `BusRailOverlayView` becomes **render-only** for the pulse: delete the
  whole draw-time diff apparatus (`EnergySignature`, `energizeSignature`,
  `connectPulseFires`, `reconcileEnergize(with:)`, `lastEnergy`,
  `lastMemberYs`, `settleBaseline`, the occlusion observer, `RailPlan.memberYs`,
  `test_reconcileEnergize`). Add one new public entry point:
  `playConnectPulse(joinedDeviceIDs: Set<String>, cameToLife: Bool)`. It
  reuses the existing bead/bloom/coalesce machinery (`runConnectPulse`,
  `runHeaderDotBloom`, `cancelConnectPulse`, `fraction`/`length`) — none of
  that changes.
- `RailNodeProviding` gains `var railDeviceID: String? { get }` so the
  overlay can map a joined device id back to its on-screen node for the
  departure point.
- `PopoverPanelViewController` gains a one-line forwarder,
  `playRailConnectPulse(joinedDeviceIDs:cameToLife:)`, bridging controller →
  overlay.
- `PopoverController.update(devices:)` gains the actual diff: compute the
  current connected-member-id set, compare to the stored previous set, and if
  new ids appeared, call the forwarder (`cameToLife` = previous set was
  empty). Always store the new set, even while hidden.
- Test rewrite: delete ~11 tests that test the deleted diff machinery,
  rewrite ~9 to trigger via the new `playConnectPulse` call instead of the
  deleted `test_reconcileEnergize`/draw-diff sequences, keep the
  bead/bloom/ring tests as-is. **Add a new file**,
  `RailConnectPulseControllerTests.swift`, with 6 tests that exercise this
  end-to-end through `PopoverController` seams — these are the actual
  regression net for the bug class: connect fires once, second room joining
  fires once from its own node, **subsection collapse/expand fires nothing**,
  **card collapse/expand fires nothing**, **reopen after a hidden connect
  fires nothing**, mute/leave fire nothing.

Full step-by-step (8 steps, each with file/line/exact-edit) is in
`02-work-order.md`. Follow it in order; it already accounts for all the traps
above.

## Plan / next steps for whoever picks this up

1. Read `01-design-brief.md`, then `02-work-order.md` in full.
2. Re-verify the work order's line anchors are still accurate (a quick grep
   per symbol name is enough — the files haven't been touched since scoping,
   but confirm rather than assume).
3. Execute Steps 1–8 of the work order **in this worktree, on top of the
   existing uncommitted changes** — do NOT start a fresh worktree (it would
   fork from the last commit and lose the already-verified fixes above).
4. Verify per the work order's own Verification section:
   - `bash scripts/build.sh` clean
   - `bash scripts/run-tests.sh --filter 'RailConnectPulseTests|RailConnectPulseControllerTests|BusRailCollapseResolveTests|PopoverDeviceVisibilityTests|MembershipRailTests'` — all pass (count will differ from 91: ~11 deleted, ~2+6 added)
   - `bash scripts/run-tests.sh` — full suite, all green (baseline was 2543)
   - **Never** run bare `swift build`/`swift test` — always the `scripts/` wrappers (they route through the project's remote build mule and its concurrency/cache rules).
5. I'd recommend an independent review pass (a fresh reviewer, not the
   executor) before this gets built into a test app for Alec to live-verify —
   this is exactly the kind of "spec said do X, did the diff actually do X and
   nothing more" check that catches subtle drift.
6. Build a fresh-bundle-id test app (`APP_NAME=...`, `BUNDLE_ID=...`, see repo
   root `CLAUDE.md` / `AGENTS.md` for the exact pattern — every test build
   needs its own bundle id, never reuse one) and have Alec live-verify:
   - A real connect still plays exactly one clean pulse, arriving in Main
     Audio.
   - Opening the popover fresh (first-ever connect on a brand new bundle id,
     which is what surfaced the original stutter) is now clean — connect
     fires once, no stutter, no early pulse.
   - Rapidly collapsing/expanding both a **card** (e.g. Output Devices) and a
     **subsection** (e.g. AirPlay Devices / Bluetooth Devices) fires **no**
     pulse either way.
7. Once Alec confirms clean, this branch (`claude/rail-animation-bugs-89dd1a`)
   is ready to merge to `main` per the repo's normal merge-only-via-merge-commit
   rule — never commit directly to `main`.

## Do not

- Don't revert or "clean up" the 3 already-fixed bugs' code while doing this
  refactor — they're independent, already verified, and the work order is
  written assuming they're present.
- Don't touch `PopoverController`'s own `reconcileEnergize()` — different
  method, same name, unrelated system (item-9 energize pending beat).
- Don't add an event bus / new protocol / extra abstraction beyond what the
  work order specifies — it was scoped to the minimum shape that ends the bug
  class, not a general-purpose event system.
- Don't merge to `main` without a live hardware check from Alec — animation
  timing bugs like these don't show up in the test suite the same way they
  show up to a human watching the actual motion.
