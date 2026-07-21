# G1 — Live UX Walkthrough Findings (session in progress)

**Method:** Alec drove a genuine first-run session (user prefs/Application
Support backed up and cleared to force true first-launch state — see backup
path note at end) against a freshly built mock-backend `Audiouter.app`.
Session ran as free-form narrated reactions rather than strictly walking the
prepared checklist top-to-bottom — this surfaced a large amount of net-new
material the checklist didn't anticipate, at the cost of not yet exercising
several of the checklist's highest-priority scripted checks (see "Still
open" at the end). This file is the primary record for the session; verdicts
get back-filled into each source finding's `[confirm-in-G1]` tag once the
session is complete.

---

## New findings (not previously in any audit file)

### Critical

- **G1-N1 — Volume can blast the user on connect.** Connecting to an AirPlay
  speaker currently matches/inherits whatever volume level the Mac was
  already at. Computer speakers are typically played much louder than a
  home AirPlay system needs; a user connecting at high Mac volume could be
  startled/hurt by sudden loud output. No safety default exists today.
  Alec's suggested direction: default to a lower volume on connect (user
  raises it themselves), and/or expose "default connect volume" as a
  Settings option. Needs a product decision, not just a copy fix.
- **G1-N2 — Dead "+" button in the Devices card header.** A "+" button sits
  to the right of the "SELECTED" column header and does nothing when
  clicked; its purpose is unclear even on inspection. Screenshot evidence
  captured during session. Likely either leftover/unwired UI or a
  misplaced affordance that belongs elsewhere (e.g., "add a device
  manually"?) — needs a code-level look to determine intent before deciding
  fix vs. removal.
- **G1-N3 — Applications card and Devices/Selected card do two
  disconentangled jobs that look like one system.** Checking a device's
  "Selected" checkbox affects live system audio routing; the Applications
  card below can independently redirect a specific app to a *different*
  device regardless of the Selected set. Two different routing mechanisms,
  visually stacked as if they were one flow. Alec explicitly asked for a
  **design discovery pass** here — flagged as "messy no matter what," not a
  quick copy/spacing fix. Recommend this become its own scoped sub-phase
  task, not a punch-list item.
- **G1-N4 — Groups has no discoverable "create one" path for new users.**
  The only way to create a group is one small, unlabeled icon in the
  popover header. Alec's proposed fix: even the *empty* Groups section
  should visibly say "No groups — click here to create one," teaching the
  feature rather than hiding it behind an icon a new user is unlikely to
  ever click.
- **G1-N5 — Onboarding's framing and copy need a full pass, not spot
  fixes.** Compound finding, several parts:
  - Onboarding window shows a generic system icon, not the app's real icon.
  - Subtitle ("Play your sound on any AirPlay speaker") reads as a
    description of baseline functionality, not a compelling first
    impression.
  - The permission-rationale block reads as a wall of text and doesn't
    visually register as something requiring attention — easy to skim
    past entirely.
  - "System audio" and similar internal terms are used without explaining
    what they mean in outcome terms. Alec's proposed direction: state each
    permission as a plain first-person outcome — "I need to send your
    Mac's sound to your speakers," "I need to find AirPlay devices on your
    network," "I want to hear your speaker's buttons" — rather than
    labeling by permission-system name.
  - Row **titles** don't convey much on their own either — needs a title
    pass alongside the description pass.
- **G1-N6 — Current Device and an AirPlay device cannot be selected
  together.** (Note: this is the documented Phase-1 "local-mix block" from
  `docs/SPEC.md` §9, deferred pending synced local output — not a new bug,
  but Alec is flagging it fresh as a real rough edge worth reconsidering
  for release, either by building the deferred synced-local-output
  capability or by being more deliberate about how the restriction is
  communicated.) Cross-reference: this is squarely the AP-local/multi-room
  capability gap the original SPEC always intended to lift with the native
  engine.
- **G1-N7a — There is no feature introduction anywhere in the app, not just
  weak onboarding copy.** Broader than G1-N5/G1-N4 individually: onboarding
  only ever walks through *permissions*, never *capabilities*. A first-time
  user finishes setup having never been told groups exist, that per-app
  routing exists, what the popover's sections mean, or what any of it is
  for — they're dropped straight into the UI with zero guided
  introduction. G1-N4 (no discoverable "create a group" path) and G1-N5
  (permission-only onboarding) are both **symptoms of this one root gap**,
  not separate problems. Alec's framing: the app needs an actual feature
  tour/introduction step, not just clearer permission copy. Recommend the
  master plan treat this as one root-cause item feeding both symptoms,
  rather than fixing each symptom in isolation.
- **G1-N7 — Switching outputs via macOS's own Sound menu is untested and
  has no cross-surface indication.** If a user picks an AirPlay device
  directly from the system output picker (bypassing Audiouter) that
  Audiouter already has active, behavior is unknown/untested. Alec wants
  the system's own output picker to show that a device is "in use by
  Audiouter" so switching away from there doesn't silently break routing.
  Needs both a live behavior test (candidate for G2) and a design answer.

### Major

- **G1-N8 — Dropdown "header" rows are clickable.** In both the System and
  Applications destination dropdowns, the non-interactive-looking label row
  (e.g. "Destination") can actually be selected from the pop-up menu,
  which shouldn't be selectable at all.
- **G1-N9 — Per-app picker is incomplete.** The "add an application" list
  only shows recently-opened apps, not necessarily ones that can play
  audio, and there's no way to search for an app that isn't already in
  that list.
- **G1-N10 — Mute gives no feedback, and the color language contradicts
  itself.** Clicking mute on the System/Main-Out row does mute audio, but
  the icon shows no muted-state indicator. Worse: the icon fills **blue**
  on click — blue elsewhere in the app means "active/engaged," so muting
  visually reads as turning something *on*.
- **G1-N11 — Settings and Groups don't even open consistently with each
  other.** Settings currently opens attached below the popover; Groups
  opens as its own separate window. Distinct from (and in addition to) the
  "buried window, no way back" bug already tracked in `window-panel.md`
  C1 — this is about the two surfaces not sharing one opening behavior at
  all.
- **G1-N12 — Recurring empty-state misalignment (systemic, not one-off).**
  Both the Applications card's empty-state text and the Groups sidebar's
  "no groups" line item are visibly not left-aligned with the rest of
  their sections. Same underlying pattern in two places — worth fixing as
  one design-system-level rule rather than two separate patches.
- **G1-N13 — Group-creation view shows a scrollbar with nothing to
  scroll.**
- **G1-N14 — Group/device icon picker isn't obviously interactive.** The
  button used to change an icon at group-creation time doesn't read as
  clickable/purposeful to a first-time user.
- **G1-N15 — Settings doesn't feel comprehensive.** General impression
  that the current Settings surface is thin relative to what a paid
  product should offer; Alec wants a dedicated brainstorm of what settings
  *should* exist, not just fixes to what's there.
- **G1-N16 — "Restore Mac audio after wake if speakers don't ___" setting
  is unclear even to its own team.** Title text gets visually cut off, the
  title itself is too long, and Alec wasn't fully sure what the feature
  does on reading it live. Needs a copy pass and possibly a conceptual
  rework, not just a truncation fix.

### Minor

- **G1-N17 — No Dock icon at first launch reads as slightly odd** to a
  brand-new user, even though the app is intentionally dockless
  thereafter. Low priority per Alec — not asking for a permanent Dock
  icon, just noting the first-moment impression.
- **G1-N18 — Volume-percentage label sits too far from the slider,**
  asymmetric with how close the speaker icon sits on the opposite side.
- **G1-N19 — Sidebar "+ New Group" button looks underdesigned** ("a little
  sad") — references a previously stated intent to give it more visual
  treatment that doesn't appear to have landed.
- **G1-N20 — "Set up here, play from the menu bar icon" disclaimer isn't
  prominent enough,** especially for a first-time user who needs that
  mental model (config happens in this window, playback control happens
  from the menu bar) established clearly, not as a small aside.
- **G1-N21 — General aesthetic reads as bland** ("the gray is a bit
  bland... not a very pretty app to look at"). Alec explicitly flagged this
  as low priority relative to everything else and in tension with the
  house rule of sticking to stock AppKit/system colors — noted for the
  synthesis to weigh, not to action reflexively.

---

## Checklist verdicts (live, confirmed in-session)

- **P1-07a — CONFIRMED.** Cmd+Q does not quit the app. Matches
  `cold-user-ux.md` Flow 8 (no Cmd+Q). Second half (right-click the
  menu-bar icon) pending Alec's next check.
- **P1-08 — "works as expected" (Alec's words).** Reading against the
  checklist's own stated criterion ("confirms bug if nothing about the
  card changes to indicate a network problem"): this means the Devices
  card showed no change during the Wi-Fi off/on cycle, which CONFIRMS
  `cold-user-ux.md` Flow 6 (no network-awareness code path) — "expected"
  here means "matched the audit's prediction," not "good behavior." Worth
  a quick re-confirm with Alec at synthesis time if this reading is wrong.
- **P1-09 — REFINED, not a clean confirm/refute.** Alec: "not as bad as
  described, but it is bad." Two distinct observations:
  1. Clicking anywhere else makes the Groups window disappear entirely —
     frustrating on its own, independent of recoverability.
  2. Clicking the menu-bar icon opens the popover ON TOP of Groups, and in
     this instance Groups happened to visually "poke out" slightly from
     behind the popover, so it WAS clickable back into focus — but Alec
     explicitly caveats this only works "if the group's window does
     happen to be positioned there." This is positional luck (window
     location relative to the popover), not a real/designed recovery
     path — a different window position (e.g. after P1-10's confirmed
     repositioning, a second display, or a maximized/moved window) would
     likely NOT poke out and would leave Groups genuinely unreachable.
     **Net verdict: `window-panel.md` C1 is real but the failure mode is
     "unreliable, luck-of-position recovery," not "100% permanently
     stuck" as originally worded** — arguably still Critical (a paying
     customer shouldn't need to get lucky to find a window again) but the
     master plan should describe it accurately rather than overstate it.
- **P1-10 — REFUTED.** "P1-10 passes" — Alec confirms the Groups window
  DOES reopen in the position/size he left it, contradicting
  `window-panel.md` M2 (which claimed `setFrameAutosaveName` was dead code
  silently overridden by `center()`). **Needs reconciliation**: either the
  M2 finding was wrong, or Alec's specific test conditions didn't trigger
  the code path the audit found — flag for a source re-check before the
  master plan cites M2 as confirmed.
- **P1-11 — CONFIRMED, milder than audit severity.** Dark-mode empty-state
  text contrast is a real issue ("could be improved") but Alec's framing
  is less severe than `visual.md` C3a's "unreadable, near-black on dark
  gray" — log as confirmed-but-recalibrate-severity (Major, not Critical).

- **P1-20 — INVALID AS RUN, checklist scoping error, MUST re-run in G2.**
  Alec astutely questioned why changing the real Mac's output device would
  affect a mock-backend app at all. Verified in code: `LocalPlaybackEngine`
  — the exact class the crash (`crash-hang.md` C1, the unwired exception
  shim) lives in — is only ever constructed inside `makeBackend()`'s
  native-backend branch (`OwnToneBackend.swift` ~line 884); `MockBackend`
  never creates one. The vulnerable code path cannot execute under mock at
  all, so tonight's "no crash" result confirms nothing either way. **The
  G1 checklist wrongly scoped this as mock-safe — correct scoping: this is
  a G2-only test (needs the real native backend).** Re-run during the
  signed-build session, not before.
- **P2-01 — BLOCKED, stale test-tooling bug (not customer-facing).**
  `MockBackend.connectionDemoScripts()` scripts device id `airport-mixer`
  ("Mixer") to fail once then succeed on retry — but the same fixture is
  permanently flagged `supportsAirPlay2: false`, and the app correctly,
  consistently disables interaction with AirPlay-1-only devices everywhere
  (confirmed live: Mixer's checkbox is disabled, hovering shows "AirPlay 1
  support is coming soon"). The two features conflict: Mixer can never
  actually be toggled, so this scripted fail-then-retry demo path has been
  unreachable since AP1 dimming shipped. Not a paying-customer bug (nobody
  ships with `AIRPLAY_MOCK_SCENARIO` set) — just needs the demo script
  repointed at a real AirPlay-2 fixture so this test is usable again.
  **Substituting a different device to still exercise the real question
  (does the failure/diagnosis UI render at all) — see next entries.**
- **P2-01 (via "Office" substitute) — CONFIRMED LIVE, no longer just a
  headless suspicion.** "Office" connected, then dropped ~8s later per its
  script; the row simply shows "Couldn't connect" — no Retry button, no
  cause, no Copy Details. Directly confirms `visual.md` C1 (the diagnosis
  panel never attaches to the visible view tree) and `cold-user-ux.md`
  Flow 2 in real, live use, not just offscreen snapshots. This was the
  single most-cited dead feature across two independent headless audits —
  now fully confirmed, not just suspected.
- **P2-02 — CONFIRMED LIVE.** "Move 2" during its slow ~4s connect: no
  "Connecting…" text anywhere in the row, only the status dot's
  pulse/color to distinguish connecting from connected. Directly confirms
  `accessibility.md` M1 (color/pulse-only state signaling) in real use.
- **P2-03 — effectively answered by the same test above.** Office sits
  permanently in the failed state post-drop with nothing indicating it'll
  stay there until manually retried — matches `cold-user-ux.md` Flow 6.
- **P1-21/22 — CONFIRMED GOOD, and the mock-validity concern was checked
  and doesn't apply here (unlike P1-20).** CPU rises during interaction
  and returns to idle; memory stays flat across repeated popover/window
  open-close cycles — matches `performance.md`'s headless numbers (0.0%
  idle CPU, stable ~17MB). Alec again asked whether mock invalidates this;
  verified this time it does NOT: the metering on/off gate that produces
  this behavior lives in `PopoverController` and is wired identically
  regardless of which backend is active, so this result should generalize
  to the real native backend. **Caveat that DOES still apply:** none of
  this exercises the cost of real ongoing work (actual Core Audio capture
  + AirPlay streaming to a real device) — that's invisible under mock,
  same class of gap as P1-20, and remains untested until G2/real hardware.
- **P1-19 — REFUTED, audit's underlying assumption was wrong.** Opening
  the same `.app` bundle a second time produced only ONE menu-bar icon;
  verified via `pgrep` that only a single process was ever running — macOS
  Launch Services itself declined to start a second instance, rather than
  the app having (or needing) its own single-instance guard logic.
  `crash-hang.md` m1 assumed a second process would start and produce a
  dead/useless second icon; that scenario doesn't occur for the realistic
  customer case (double-click / `open` on the same installed app). Not
  fully ruled out: launching two separate COPIES of the app bundle from
  different paths might behave differently (untested, low priority — an
  unusual thing for a real customer to do).

- **P3-01 — CONFIRMED, but less severe than the worst-case framing.** No
  visible ✕ close button (confirmed, matches `window-panel.md` C3 +
  `accessibility.md` M2). Clicking the menu-bar icon while the panel is
  open just re-fronts it rather than closing it (confirmed bug). BUT:
  **Escape DOES close it** — the audit's feared worst case ("nothing
  closes it except quitting/switching away") does NOT hold. A real
  keyboard escape hatch exists, it's just undiscoverable (no visible
  affordance suggests trying Escape). Recalibrate severity: still needs a
  visible close control before the flag ships, but "the panel can trap
  you with no way out" is not accurate — soften that framing in the
  master plan.
- **P3-02 — CONFIRMED LIVE.** Dark mode inside the control-panel shell:
  sidebar turns dark, main content pane stays stuck light-gray. Directly
  confirms `visual.md` C3b (half-dark-mode look) in real use.
- **VO-01 — CONFIRMED, and WORSE than the original finding's scope.**
  `accessibility.md` C1 specifically flagged the device/group icon well as
  keyboard-unreachable. Alec's live test: Tab does **nothing at all**
  anywhere in the Groups view — not scoped to just the icon, the whole
  window may have no keyboard focus traversal. This generalizes C1 from
  "one feature is mouse-only" to "this entire window may be
  keyboard-unusable" — a much larger accessibility gap than originally
  scoped. Needs a fuller keyboard-navigation audit of the Groups window
  specifically before the master plan sizes the fix.

## Naming/terminology feedback (P1-02/P1-03 area, design opinion not a bug)

- **G1-N23 — Question the "(n)" count suffix on "Selected Devices (n)"
  entirely.** Alec doesn't think the live count needs to be spelled out in
  the label — the checkbox column already shows at a glance how many are
  selected. If the count was originally added/abbreviated ("Selected (n)"
  on the collapsed button) because of truncation/space pressure, his
  preference is to just make the control wider rather than sacrifice a
  clearer label for a few pixels. Revisit whether "Selected Devices (n)"
  vs. plain "Selected Devices" is worth the space cost at all.
- **G1-N24 — Naming: consider renaming the "Devices" card header and the
  "Audio Out" row label.** Idea: rename the Devices card's header (or the
  destination dropdown's framing) toward something like "Target"/"Output"
  so it's immediately clear that "Selected Devices" or an active Group
  literally IS the current output destination — reinforcing the mental
  model rather than leaving "Devices" and "Selected"/"Output Groups" to
  read as unrelated lists. If "Output" gets used there, rename "Audio Out"
  (the Main Out row) to something like "Main Audio" so "out"/"output"
  doesn't appear in two different UI spots with two different meanings.
- **P1-04 (auto-swap silent un-toggle) — downgraded.** Alec doesn't
  consider this a significant issue; deprioritize relative to other
  findings.

## Live-discovered bug: selecting a saved group from Main Out does nothing

- **G1-N22 — Critical, root cause NOT fully found, handed to another agent
  for deeper investigation.** In the "System"/Audio Out row's Destination
  dropdown, picking a saved group ("tester") under the "OUTPUT GROUPS"
  section does not switch the dropdown's displayed name, does not connect
  the group's devices, and no audio plays. Reproduced twice: once via
  mis-click on the (incorrectly still-clickable) "OUTPUT GROUPS" header
  itself, and once via a precise click directly on the real "tester" entry
  — the second attempt ALSO failed, ruling out the header-click theory as
  the sole cause.
  - **Confirmed separately, real bug in its own right:** the "OUTPUT
    GROUPS" and "DESTINATION" header rows in this dropdown are meant to be
    inert section labels (`NSMenuItem.isEnabled = false` in
    `MainOutRowView.apply`, `AudiouterPopoverUI/MainOutRowView.swift`) but
    visibly highlight and are clickable in the real running app (Alec
    screenshot, confirmed live). Because `Option.init`'s `target` parameter
    defaults to `.selectedDevices` when omitted (`MainOutRowView.swift`
    line ~56) and both header options never set it explicitly, clicking a
    header silently resolves to "Selected Devices" with zero visible
    change and zero error — this alone is a real, confirmed, silent-no-op
    bug regardless of the deeper group-activation issue below.
  - **Not yet explained:** why the real "tester" group entry also fails.
    Traced as far as: `MainOutRowView.selectionChanged` →
    `PopoverController.mainOutRow(_:didSelect:)` →
    `GroupController.setMainOut(.group(id:))` → `applyRouting()` →
    `activateGroup(id:)` → `backend.setOutputSet(Set(group.memberIDs))`.
    `activateGroup(id:)` silently returns if the id isn't found in
    `groups` (`GroupController.swift` ~line 501) — a plausible silent-fail
    point, unconfirmed. Was mid-way through reading `MockBackend
    .setOutputSet` (does it actually flip `device.isSelected`/
    `connectionState` the way the UI expects?) when this investigation was
    handed off. **Next agent should pick up from here**: confirm/rule out
    (a) an id mismatch between the group's stored `memberIDs` and the
    live device fleet's ids, (b) whether `PopoverController.rebuild()`
    (called immediately after `didSelect`) does anything that could
    re-derive/clobber `mainOut` back before it visibly applies, (c) whether
    `MockBackend.setOutputSet` correctly emits `deviceUpdated` events that
    the popover's device rows actually consume and repaint from.
  - This is a **headline-feature-breaking, paying-customer-facing bug** —
    activating a saved group via the primary System/Audio Out control path
    does not work at all, with no error shown. Should be treated as
    top-priority once the master plan sequences fixes.

## Reconciliation needed against headless audit findings

- **VU meter "sliver at rest" (visual.md Critical C2) — LIVE REFUTED.**
  Alec explicitly did not observe the fake-signal sliver the offscreen
  snapshot audit reported as present on every device row, every theme,
  every open. The visual auditor itself flagged a risk that its capture
  method (`cacheDisplay` layer capture, inactive-window rendering) could be
  exaggerating something invisible in real live use — this may be exactly
  that case. **Recommend a quick source-level re-check (not another live
  session) before the master plan carries this forward as Critical** —
  confirm whether the sliver is a genuine at-rest rendering bug or an
  artifact of the offscreen capture technique.

---

## Still open — checklist items not yet executed this session

The session so far has been organic reaction-gathering, which surfaced 21
new findings the prepared checklist didn't anticipate — genuinely
high-value. But several of the checklist's **highest-severity, most
targeted** checks haven't been run yet. Highest priority to still cover,
in order:

1. **P1-20 (crash test)** — the single top-priority pending item. Tests
   whether the Current-Device-mid-playback crash (`crash-hang.md` C1,
   Critical, a fix already exists but isn't wired in) is still live.
2. **P1-09 / P1-12 (the actual buried-window recovery test)** — the
   session surfaced a *related* but different finding (G1-N11, Settings
   vs. Groups opening inconsistently) without yet directly testing
   whether a buried Groups/Settings window can be recovered at all via the
   menu-bar icon. This is the single most-cited window bug across the
   audit and still needs its direct test.
3. **Pass 2 (connection-failure scenario, 3 checks)** — validates whether
   the dead diagnosis panel (visual.md C1 + cold-user-ux.md Flow 2, "the
   single most-cited dead feature across two independent audits") is
   really dead live, not just in the offscreen snapshots.
4. **Pass 3 (control-panel shell)** — this is the *built fix* for the
   buried-window bug (item 2 above); worth running once item 2 confirms
   the bug, to see whether flipping the flag actually solves it.
5. **P1-07 (quit path: Cmd+Q, right-click menu)** — untested this session.
6. **P1-19 (duplicate-instance launch)** — untested.
7. **P1-08 (Wi-Fi-off network awareness)** — untested.
8. **P1-15/16/17/18 (formal onboarding re-run via Settings ▸ "Run Setup
   Again…")** — the very first launch covered onboarding informally, but
   the specific re-run checks (Wi-Fi text wrap, audio-tone replay on
   app-refocus, "Done" gating — already informally confirmed per above)
   haven't been run via the dedicated re-run path.
9. **P1-21/22 (performance / Activity Monitor)** — untested.
10. **VoiceOver spot-check (all 4 items)** — accessibility remains fully
    unverified live; VO-01 (icon picker keyboard-unreachability) is the
    single Critical accessibility finding still needing live confirmation.
11. **Multi-display/Spaces check** — only relevant if a second display is
    available.

**Not a gap, just a note:** the four open-ended "new issue capture"
prompts were effectively already answered by the free-form nature of this
session.

---

## Session housekeeping

User preferences and Application Support state were backed up before
clearing to force a true first-run (see
`~/Library/Application Support/Audiouter.g1-backup-<timestamp>/` — restore
after the full session concludes, do not leave the user's real groups/
settings cleared).
