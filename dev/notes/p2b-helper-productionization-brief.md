# PTP Helper Productionization Brief — from design doc to installed, running, firewall-passing daemon

**This brief REVIEWS `AirPlayEngine/docs/ptp-helper-design.md` (482 lines,
T-HELPER-DESIGN-1) against real-world `SMAppService`/codesign/firewall/TCC
behavior and fills the gap between "design is sound" (it is — the gating
T-PTP-PROBE already passed, see `dev/notes/p2-ptp-bind-probe.md`) and "ships as
a working signed daemon on Alec's Mac." It does not re-derive the privilege
boundary, IPC choice, or lifecycle design — those stand as written. Citations:
`ptp-helper-design.md:NNN` for the existing design, URLs for web research,
`SPEC.md`/`PLAN-PHASE-2.md` §refs for project decisions.

---

## The question

`ptp-helper-design.md` §2–§6 sketches the SMAppService packaging, plist shape,
approval UX, and firewall/signing as a paragraph each ("Sign +
firewall-register at install", `ptp-helper-design.md:194-199`). None of that is
wrong, but none of it is *actionable* yet — there's no confirmed answer to:
does this personal, ad-hoc/self-signed open-source app even support
`SMAppService.daemon()` at all, or does it hard-require a paid Developer ID?
What exact bundle/build-phase layout makes Xcode/SwiftPM produce a daemon
`SMAppService` will register? What triggers the firewall to allow it, in what
order relative to the first `bind()`? What was that EPERM burst on first sends
we saw tonight, and is it a durable risk? And what's the uninstall/revoke
story for a tool a user might delete or an app they might reject?

---

## Findings, with evidence

### 1. Code signing — ad-hoc does NOT work; this needs a real (if solo) Developer ID

**This is the single biggest gap in the existing design doc**, which only says
"Developer-ID-signed" in passing (`ptp-helper-design.md:194`, `:367`) without
flagging it as a hard requirement with a cost attached.

- Apple DTS is explicit that `SMAppService` "imposes no additional constraints"
  over ordinary distribution — but ordinary direct (non–App-Store) distribution
  **already requires Developer ID signing**: "Direct distribution, outside of
  the Mac App Store, requires Developer ID signing. `SMAppService` imposes no
  additional constraints." — Apple DTS engineer, Apple Developer Forums
  ([thread](https://developer.apple.com/forums/thread/751439)).
- Independent confirmation: "Ad-hoc signing ('Sign to Run Locally') is not
  supported [for `SMAppService` helpers] as it would result in code signing
  requirements which cannot securely identify the app and helper tool."
  ([alienator88/HelperToolApp](https://github.com/alienator88/HelperToolApp),
  a from-scratch `SMAppService`-based privileged-helper sample explicitly
  written to replace `SMJobBless`).
- The daemon and the container app must share a **code-signing identity /
  team identifier**: "Make sure your daemon is signed with the same
  code-signing identity as the container app" — this is how `smd`
  (the system daemon behind `SMAppService`) verifies the bundled daemon
  belongs to the registering app
  ([theevilbit.github.io](https://theevilbit.github.io/posts/smappservice/);
  cross-referenced against Apple's [TN3127 code-signing-requirements
  technote](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
  on team-identifier library-validation semantics).
- Local Network privacy (relevant below, §4) independently confirms the same
  bias against ad-hoc: "Local network privacy…relies on tracking apps by their
  code signature, so works best with code signed with certificates issued by
  Apple, rather than ad hoc signatures"
  ([eclecticlight.co](https://eclecticlight.co/2026/01/14/how-local-network-privacy-could-affect-you/)).

**Consequence for SPEC.md §6 pt 3 ("lightweight signing acceptable" for a
personal direct-download tool):** "lightweight" cannot mean *ad-hoc*. It means
a **single, cheap Apple Developer Program membership** ($99/yr, one person,
one Developer ID Application certificate) used to sign the app + the bundled
daemon with the same identity — no notarization-service infra, no team
management, no App Store review. This is still by far the lightest signing
tier that actually works, but the design doc should say so explicitly rather
than imply "signed, whatever that costs" is free. **This is a real, small,
recurring cost decision for Alec** (see Open Questions).

### 2. Bundle layout and build-phase mechanics (fills `ptp-helper-design.md` §2.2's gap)

The design doc gives the plist shape but not how it physically gets into the
app bundle from an Xcode/SwiftPM build. Concrete, verified mechanics
([dev.to/brysontyrrell](https://dev.to/brysontyrrell/macos-apps-with-embedded-daemons-333a),
a from-scratch embedded-LaunchDaemon walkthrough; cross-checked against
[theevilbit.github.io](https://theevilbit.github.io/posts/smappservice/)):

- Plist → a Copy Files build phase, destination **"Wrapper"**, subpath
  `Contents/Library/LaunchDaemons`, **"Code Sign On Copy" checked**.
- Daemon binary → a separate Copy Files phase (or Copy Bundle Resources),
  destination `Contents/MacOS/` (or a subdir), **also code-signed on copy**.
  This matches `ptp-helper-design.md:149`'s `BundleProgram` path
  (`Contents/MacOS/ptp-helper`).
- **`BundleProgram` is genuinely `SMAppService`-only** — if the daemon is ever
  installed a different way (a `.pkg` postinstall script, `sudo cp` to
  `/Library/LaunchDaemons`), `BundleProgram` does not resolve and the plist
  must instead use the classic `Program`/`ProgramArguments` with an absolute
  path (theevilbit.github.io, dev.to). **Do not build any fallback installer
  path around the same plist** — it needs a different plist shape entirely.
  Not a concern now (SMAppService is the only planned path) but worth a code
  comment so nobody "fixes" the plist later without realizing this.
- `Label` in the plist **must match the plist's filename** (e.g.
  `com.<team>.airplaycontroller.ptphelper.plist` ↔
  `Label: com.<team>.airplaycontroller.ptphelper`) — standard launchd
  convention, and `SMAppService.daemon(plistName:)` takes the filename, not
  the Label, as its lookup key.
- Since this project is a **SwiftPM package** (`AirPlayEngine/`) consumed by an
  app target, the actual app shell (menu-bar app, per SPEC §9) is presumably a
  thin Xcode app target that depends on `AirPlayEngine` — the Copy Files
  phases above belong to **that app target's Xcode project**, not to
  `AirPlayEngine`'s `Package.swift` (SwiftPM has no bundle/plist-embedding
  concept). This is a Phase-1-app-target concern to flag now so the eventual
  app scaffolding budgets for it.

### 3. Registration/approval flow, in practice (confirms + sharpens `ptp-helper-design.md` §2.3)

- Confirmed: `SMAppService.daemon()` **does run as root**
  ([Apple DTS, forums.apple.com/thread/751439](https://developer.apple.com/forums/thread/751439)).
- Confirmed: registration is interactive on first run — "users will be
  prompted to approve the background process, and daemons need admin
  authentication" (installing any daemon requires root, so the OS surfaces an
  authentication dialog on top of the Login Items toggle the design doc already
  describes) (theevilbit.github.io; dev.to). This matches
  `ptp-helper-design.md:179-192` (`.requiresApproval` → deep-link to Login
  Items) — no correction needed, just confirmed by two independent sources.
- **New gotcha not in the design doc: re-registration doesn't re-prompt.**
  Calling `register()` again for an already-approved daemon is a no-op from the
  user's perspective — useful for idempotent "ensure registered" calls at every
  launch (theevilbit.github.io).
- **New gotcha: a known Ventura 13.6 bug** where disabling the daemon in Login
  Items doesn't actually stop the launchd job (FB13206906,
  theevilbit.github.io). Not applicable at our macOS 14.4 floor, but worth a
  code comment citing the feedback ID in case of a future OS-version bug hunt.
- **`unregister()` behavior, not covered in the design doc at all**: it stops
  the daemon and flips status back to `.notRegistered`, but **the Login Items
  UI entry can persist across reboots and after the app is deleted** — macOS
  preserves user intent even with the app gone
  ([forums.apple.com](https://developer.apple.com/forums/thread/736272);
  theevilbit.github.io). See §7 Uninstall below.

### 4. Gatekeeper / app translocation — a real footgun for "personal direct-download," independent confirmation of tonight's dev-testing pattern

- App translocation triggers whenever a **quarantined** app (the
  `com.apple.quarantine` xattr Safari/Mail/etc. set on downloads) is launched
  **without first being moved by Finder** — it then runs from a randomized
  path like `/private/var/folders/.../AppTranslocation/<UUID>/d/AppName.app`
  rather than its real location
  ([lapcatsoftware.com](https://lapcatsoftware.com/articles/app-translocation.html);
  [eclecticlight.co](https://eclecticlight.co/2022/09/09/app-first-run-quarantine-and-translocation/)).
- **A translocated app's bundle path is unstable across launches** — this
  directly threatens `SMAppService`'s `BundleProgram` (a bundle-relative path)
  and any code-signing-requirement string baked around a specific install
  location. The practical mitigation (standard Mac app advice, reinforced by
  the Sequoia forum thread below) is: **instruct the user to drag the app to
  `/Applications` before first launch** — this is also exactly the SPEC §9
  menu-bar-app norm, not an extra ask.
  - Removing the quarantine xattr (e.g. testing via `xattr -d
    com.apple.quarantine`) also prevents translocation — useful for dev-loop
    testing but not the shipped user path (lapcatsoftware.com).
- **Directly explains tonight's dev-loop pattern and reinforces "must run from
  /Applications" as a real, not theoretical, constraint**: a macOS 15 Local
  Network / daemon thread found that a root daemon binary produced
  **"No route to host" UDP errors when run from anywhere other than
  `/Applications`**, even as root, and that this was independent of the
  daemon-Local-Network-exemption fix
  ([developer.apple.com/forums/thread/763753](https://developer.apple.com/forums/thread/763753)).
  This is strong circumstantial support for treating tonight's EPERM burst
  (§5 below) as environment/location-sensitive, not a fundamental blocker.

### 5. Application Firewall — order-of-operations, confirms SPEC 0c empirically, no contradiction found

- SPEC.md §6 pt 3 / §8 0c gotcha 2 (our own Phase-0 primary source, already the
  strongest evidence available) established: the Application Firewall silently
  drops inbound PTP, and **the allow/deny verdict sticks to already-bound
  sockets** — allowlisting after the daemon has bound 319/320 does not retroactively
  fix a session in progress; the daemon must be **restarted** after allowlisting.
  Tonight's finding ("firewall must allowlist BEFORE bind") is consistent with
  and sharpens this: don't just restart-after-allowlist reactively, **allowlist
  proactively before the daemon's first bind** wherever the install sequence
  allows it.
- Auto-allow mechanism confirmed: macOS's Application Firewall has a setting
  to "automatically allow downloaded signed software"
  ([kolide.com](https://www.kolide.com/features/checks/mac-firewall)) —
  i.e. a **properly Developer-ID-signed** daemon is auto-allowlisted by default
  firewall settings with **no `socketfilterfw` call needed at all**, provided
  the user hasn't disabled that global toggle. This means:
  - The install-time `socketfilterfw --add`/`--unblockapp` step
    (`ptp-helper-design.md:194-199` implies doing this manually) is a
    **belt-and-suspenders fallback for users who've turned off
    auto-allow-signed**, not the primary mechanism. Primary mechanism = sign
    correctly and let auto-allow do its job.
  - `socketfilterfw --getglobalstate --getallowsigned` at install time can
    detect whether the user has this off, and only then explicitly
    `--add`/`--unblockapp` the daemon path + prompt for a restart.
- No web source contradicts SPEC 0c's core empirical finding (verdict sticks
  to bound sockets); no additional primary source with more detail was found
  beyond our own Phase-0 test — SPEC 0c remains the best evidence and should
  stay the citation of record.

### 6. Local Network privacy (TCC-adjacent, but NOT actually TCC) — very likely explanation for tonight's EPERM burst

This is the most important new finding for tonight's observed symptom.

- **Local network privacy is a Network Extension packet filter, not TCC** — it
  cannot be reset with `tccutil` and doesn't appear in the `AudioCapture`-style
  TCC database at all
  ([eclecticlight.co](https://eclecticlight.co/2026/01/14/how-local-network-privacy-could-affect-you/)).
  The brief's task description calling it "TCC propagation" is a reasonable
  guess but technically imprecise — worth correcting in any follow-up
  implementation notes.
- **Root processes and launchd daemons are exempt by design**: "any daemon
  (except agents) started by launchd" and "any process running as root" get
  automatic local-network access with no prompt
  (eclecticlight.co, same article). Confirmed a second way: "If you run an
  executable as a launchd daemon, it runs as root and local network privacy
  does not apply to code running as root"
  ([developer.apple.com/forums/thread/763753](https://developer.apple.com/forums/thread/763753)).
- **Terminal-spawned processes are also exempt**: "command tools run from
  Terminal or using SSH, including their child processes" are exempt too
  (eclecticlight.co). This matters for the *interim* dev workflow
  (`ptp-helper-design.md §6.3`, `osascript`-elevated `airptpd` runs) — those
  runs should never see a Local Network prompt/EPERM from this mechanism
  either, since they're both root **and** Terminal/osascript-spawned.
- **A real, documented bug exists in exactly this space**: macOS 15.0 had a
  bug where **launchd daemons (which should be exempt) still triggered Local
  Network prompts**, traced to a DNS-resolution interaction (`NSHost
  hostWithAddress:`, WebSocket libs doing localhost lookups) — **fixed in
  macOS 15.1**
  ([developer.apple.com/forums/thread/763753](https://developer.apple.com/forums/thread/763753)).
  Our floor is 14.4 (SPEC §4/macOS-minimum), so this specific bug shouldn't
  apply directly, but it establishes that **the daemon/root exemption is not
  airtight across macOS point releases** — treat any first-run network
  hiccup as "maybe transient OS-version-specific enforcement," not as "our
  design is wrong."
- **Best-fit explanation for tonight's EPERM burst**, synthesizing the above
  three findings: most likely **not** Local Network privacy at all (root +
  loopback/LAN UDP should be exempt outright), and instead one of:
  1. the daemon was run from a non-`/Applications` path during dev testing
     (§4's directly-documented "No route to host"/EPERM-adjacent pattern for
     non-`/Applications` daemons), or
  2. a **firewall race** — first sends landing in the window before the
     Application Firewall's per-socket verdict was established (SPEC 0c: the
     verdict "sticks" once a socket is bound, implying there's a decision
     point right after bind where a transient reject is plausible), or
  3. an ordinary **kernel/BSD "burst of EPERM until the process's firewall/ALF
     classification settles"** pattern that several forum threads describe
     impressionistically but no primary source fully documents at the
     packet level.
  No primary source gives an authoritative "yes, that's a known first-N-packets
  EPERM window" — this remains **empirically observed, not yet root-caused**.
  Recommendation: **re-run the observation with `sudo lsof -i :319 -i :320`
  and `log stream --predicate 'process == "socketfilterfw" OR sender ==
  "ALF"'` active** the next time it's reproduced, from `/Applications`, to
  distinguish cause 1 vs 2 vs 3. Flagged as an open risk, not resolved here.

### 7. Uninstall story (absent from the design doc entirely — new)

- `SMAppService.unregister()` is the API-level uninstall: stops the daemon,
  flips `.status` back to `.notRegistered`
  ([theevilbit.github.io](https://theevilbit.github.io/posts/smappservice/)).
  The app should call this from an in-app "quit/uninstall helper" action, not
  rely on the user finding Login Items themselves.
- **But the Login Items entry can outlive both the unregister call and the
  app's deletion** — macOS persists the user's approval intent even after the
  app bundle is gone
  ([forums.apple.com/thread/736272](https://developer.apple.com/forums/thread/736272)).
  For a personal tool this is a minor UX wart (a phantom "AirPlay Controller"
  entry in Login Items after a full uninstall), not a functional problem — the
  daemon itself is gone/unregistered, just the list entry lingers. Document
  this in a user-facing "how to fully remove" note rather than trying to
  engineer around it (there's no public API to force-clear the Login Items
  list entry).
- No installer/pkg uninstall story is needed given `ptp-helper-design.md §2`'s
  correct choice of `SMAppService` over a `.pkg`+`postinstall` approach — this
  is one of the concrete advantages of SMAppService the design doc doesn't
  explicitly call out as a plus: **no separate uninstaller script to write and
  maintain**, `unregister()` + app deletion is the whole story (modulo the
  Login Items cosmetic wart above).

### 8. IPC choice — no new information changes the design doc's verdict

- Re-confirmed nqptp's SMI (Shared Memory Interface) as real prior art for the
  shm approach `ptp-helper-design.md §4` already leans on: nqptp publishes PTP
  clock state via a versioned POSIX shared-memory segment
  (`/nqptp` on Linux) that shairport-sync reads, with **matching SMI version
  numbers required between the two** (currently smi10) —
  ([mikebrady/nqptp](https://github.com/mikebrady/nqptp),
  [nqptp release 1.2.4 notes](https://github.com/mikebrady/nqptp/releases/tag/1.2.4)).
  This is the same shape as `/airptp_shm` (versioned, single-writer) the
  design doc already specifies (`ptp-helper-design.md:271-291`) — no change
  needed.
- **New, mildly relevant data point**: nqptp 1.2.4's "security updates" made
  nqptp run as a **restricted (non-root) user on Linux** while retaining
  special permission for ports 319/320, specifically to harden "the
  communication path between NQPTP and Shairport Sync…resistant to outside
  interference" (nqptp 1.2.4 release notes, linked above). This is the
  Linux-specific `CAP_NET_BIND_SERVICE`-style privilege-drop nqptp uses that
  macOS has no equivalent for in the same shape (macOS ports <1024 are a
  binary root/non-root gate, not a capability system) — it does **not**
  suggest our helper should try to drop privileges after bind. It **does**
  reinforce that the upstream project itself considers the loopback control
  channel a real (if historically low-severity) hardening target, lending
  extra weight to `ptp-helper-design.md §5.3`'s "accepted limitation, revisit
  if it ever matters" framing — which already correctly declines to
  over-engineer this for a personal single-user tool. No design change
  recommended, just corroboration that this was the right call and the right
  place to stop.
- No web source suggests XPC is meaningfully better here for our use case; if
  anything, the alienator88/HelperToolApp XPC sample confirms XPC's ceremony
  (`NSXPCConnection`, designated-requirement security strings on the
  connection, `MachServices` plist keys) is real added complexity that buys
  nothing our minimal, secret-free, data-plane-free control channel needs
  (`ptp-helper-design.md §4` reasoning stands unchanged).

---

## Recommended approach

Adopt `ptp-helper-design.md` as-is for the privilege boundary, IPC, and
lifecycle (§1, §4, §5 — unchanged, still correct). Layer the following
productionization decisions on top, in dependency order:

1. **Get a Developer ID Application certificate now, not later.** This is a
   blocking prerequisite for everything else in this brief (signing, bundle
   layout, firewall auto-allow, Local Network exemption tracking all key off
   it) — see Open Questions §1.
2. **Build the app-target bundle plumbing** (Copy Files phases, Code-Sign-on-Copy,
   matching `Label`/plist-filename) once there's an actual Xcode app target to
   attach it to (Phase 1, per PLAN-PHASE-2.md end-state) — not blocking for
   engine work today, but budget it into the Phase-1 app-shell task list.
3. **Ship an explicit "AirPlay Receiver must be off" + "install to
   /Applications" onboarding check** before first daemon registration — both
   are now evidenced requirements (T-PTP-PROBE's own finding for the former;
   §4 above for the latter), not just nice-to-haves.
4. **Treat firewall allowlisting as auto-allow-by-signing first, manual
   `socketfilterfw` fallback second** — check `--getallowsigned` at install,
   only shell out if it's off, and always restart-after-allowlist per SPEC 0c.
5. **Defer root-causing the EPERM burst** until it's reproducible outside
   tonight's ad-hoc dev conditions — rerun from `/Applications` with a signed
   binary before spending more time on it; it may simply disappear once causes
   1 and 2 in §6 above are controlled for.
6. **Write the uninstall path as `unregister()` + a one-line "you may see a
   stale Login Items entry" doc note** — do not attempt to engineer around the
   persistent-Login-Items-entry cosmetic wart; there is no API for it.

---

## Walls / risks, ranked

1. **Code signing cost/process is a real, non-optional dependency the design
   doc undersells.** "Lightweight signing acceptable" (SPEC §6 pt 3) is true
   relative to notarized-App-Store-grade process, but false relative to zero
   cost — ad-hoc signing is confirmed **not** to work for `SMAppService`
   daemons at all. Until Alec has a Developer ID cert, no helper build can be
   registered/tested in its real (non-`osascript`-interim) form. This is the
   single highest-leverage unblock for the rest of this brief.
2. **Bundle-path sensitivity (translocation + non-`/Applications` launches)
   is a plausible root cause for tonight's live EPERM anomaly and a real
   production risk for a personal direct-download app** — a quarantined
   download run without a drag-to-`/Applications` step can translocate to an
   unstable path, and independent evidence shows daemons launched from
   non-`/Applications` paths see UDP failures. Needs an explicit onboarding
   guard, not just user goodwill.
3. **The EPERM burst is unresolved and probably not simply "TCC/Local Network
   propagation."** Root processes and launchd daemons are supposed to be
   exempt from Local Network privacy outright (it isn't even TCC), and a
   same-shaped bug (daemons wrongly prompted) was already fixed upstream by
   15.1 — meaning our floor (14.4) predates that whole bug class. The likelier
   explanations are firewall-verdict timing or launch-path hygiene, both
   addressed above, but this is marked **open** until reproduced under
   controlled conditions.
4. (Lower severity) **The Login-Items-entry-outlives-uninstall cosmetic wart**
   and the **Ventura-13.6 disable-doesn't-take-effect bug** are both
   acceptable-as-is for a personal tool at our macOS 14.4+ floor, but worth a
   one-line code comment each so a future self doesn't waste time
   "fixing" unfixable OS behavior.

---

## Concrete implementation checklist (dependency-ordered)

- [ ] **Decide + obtain Developer ID Application certificate** (Alec —
      Open Question §1). Blocks everything below that needs a real signed
      build.
- [ ] **Confirm AirPlay Engine's eventual app target exists** (Phase 1 app
      shell, per PLAN-PHASE-2.md end-state) — the bundle/build-phase work
      below has nowhere to attach until then; can be stubbed against a
      throwaway Xcode app target in the interim if useful for early testing.
- [ ] Add the daemon binary as its own build product (small Mach-O target;
      `ptp-helper-design.md §6.1` — mostly-verbatim `libairptp` + `airptpd.c`
      minus `daemonize()`).
- [ ] Add two Copy Files build phases on the app target: plist →
      `Contents/Library/LaunchDaemons` (Wrapper dest), binary →
      `Contents/MacOS/` — both "Code Sign On Copy" checked.
- [ ] Write the launchd plist per `ptp-helper-design.md §2.2`, with `Label`
      exactly matching the plist filename.
- [ ] Implement the app-side registration/approval flow per
      `ptp-helper-design.md §2.3` (register → poll `.status` →
      `.requiresApproval` explainer → `openSystemSettingsLoginItems()` →
      poll to `.enabled`).
- [ ] Implement `unregister()` behind an in-app "remove helper" action; add a
      one-line doc note about the persistent Login Items entry (§7 above).
- [ ] Add first-run onboarding checks: (a) macOS AirPlay Receiver is off
      (T-PTP-PROBE finding), (b) app is running from `/Applications`, not a
      translocated/Downloads path (§4 above).
- [ ] Add install-time firewall check: `socketfilterfw --getallowsigned`; if
      off, `--add`/`--unblockapp` the daemon path explicitly, then
      restart-after-allowlist per SPEC 0c.
- [ ] Once a signed build exists: re-run the EPERM-burst observation from
      `/Applications` with `lsof`/`log stream` capturing (§6 above) to
      root-cause or close it out.
- [ ] Re-run the full `ptp-helper-design.md §6.4` verification checklist
      (T-PTP-PROBE already ✅; SMAppService registration, KeepAlive respawn,
      two-host sync test) once the above lands.

---

## Open questions for Alec

1. **Developer ID Application certificate — get one now?** This is a genuine
   cost/logistics decision only Alec can make: ~$99/yr, one Apple ID, no team
   management needed for a solo project. Nothing past this brief's §1 finding
   can be tested in its real (non-interim-`osascript`) form without it. If
   the answer is "not yet," the interim `osascript`-elevated dev workflow
   (`ptp-helper-design.md §6.3`) remains the only path, and this whole brief's
   checklist stays blocked.
2. **Is there budget/interest in root-causing the EPERM burst properly**, or
   is "defer until reproduced under controlled conditions" (this brief's
   recommendation) good enough for now? It's not gating (the design stands
   either way), but it's an open loose end from tonight's session.
3. **Onboarding copy for the two new first-run checks** (AirPlay Receiver off,
   /Applications install location) — both are now evidenced requirements, not
   optional polish; do they belong in Phase 1's UI scope or is a plain
   `NSAlert`-style explainer fine for now given the personal-tool bar
   ("works well for me," SPEC §7 pt 4)?
