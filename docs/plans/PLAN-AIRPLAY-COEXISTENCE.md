# Plan — AirPlay Coexistence: share the timing ports with macOS, take over cleanly, show up in Sound settings

Status: **PLAN ONLY — no code written.** All 3 decisions locked by Alec 2026-07-26 (see "Decisions locked").
Author in a dedicated worktree/branch off `main`; `main` is merge-only. Merge only after Alec live-tests and explicitly says go (standing rule — doubly so here: this rewrites the lifecycle of the one root component and adds a driver-class component).

Problem being fixed: Audiouter's root PTP helper binds UDP 319/320 at boot (`RunAtLoad` + `KeepAlive`) and holds them forever, even when the app isn't running. macOS's own AirPlay 2 sender needs the same ports, so **installing Audiouter permanently breaks the system AirPlay dropdown** (confirmed live 2026-07-26: `ptp-helper` PID 618 held `*.319`/`*.320` with Audiouter not even running). Users will use both paths; they must coexist.

---

## Decisions locked (2026-07-26)

1. **Core principle = "last intent wins," automatically.** The PTP ports are a turn-taking resource — the two senders can never hold them simultaneously. Whoever the user touched last (system dropdown vs. Audiouter device row) gets the ports, with no error states and no manual cleanup in either direction.
2. **Takeover is automatic, no confirmation dialog.** Clicking a device in Audiouter while macOS AirPlay is playing ends the system session and starts ours, with a brief "Taking over from AirPlay…" transient state. The click *is* the consent.
3. **Sound-settings presence = virtual output device, spike-gated, shipped in this same combined effort.** Audiouter appears as an output device in System Settings › Sound while active: users can see that's where audio goes and unselect it there (that's the off switch); the app re-selects it automatically on next use — the user never has to re-select manually. Built as an AudioServerPlugIn (BlackHole-style), gated on G2 proving install + capture cleanly. One combined plan, ships together (Alec chose combined over port-fix-first).

**Known asymmetry (accepted, recorded):** we can yield the ports only when idle. If the user clicks the *system* dropdown while an Audiouter stream is active, macOS loses the bind race and its connect fails — we cannot detect their intent to yield proactively. Mitigation is Decision 3: Sound settings visibly shows "Audiouter" as the active output, so "why won't the dropdown work" has a discoverable answer and a one-click off switch right there.

---

## Wave 0 — gates (both cheap, both before any Wave-2/3 code)

- **G1 — live port probe (Alec + agent, ~5 min).** Boot out our daemon (`sudo launchctl bootout system/com.audiouter.Audiouter.ptphelper`), connect a Sonos via the **system** dropdown, watch `netstat`/`lsof` on 319/320. Answers: (a) does macOS actually bind 319/320 during a system-dropdown session; (b) after switching default output away from the AirPlay device, how fast are the ports released — instant, seconds, or only on Control Center disconnect. **Decides T5's mechanism and timeout, and R1's fallback wording.** Also confirms Direction A: with our daemon out, the system dropdown works (root-cause proof).
- **G2 — virtual-device spike (~half day).** Minimal "Audiouter" AudioServerPlugIn: installs under Developer ID + notarization, appears in Sound output list, can be set default programmatically, our process-tap capture path reads from it (house rule "tap follows default output" unchanged — the default *is* the virtual device), uninstalls cleanly, survives `coreaudiod` restart. **Decides Wave 3 build vs. fallback (menu-bar-only visibility).**

## Wave 1 — on-demand helper lifecycle (Direction A: system dropdown works whenever we're idle)

- **T1 — libairptp: expose daemon idle state.** Add `airptp_peer_count(hdl)` (or equivalent idle-since query) to the MIT-side library so the helper can see its own peer table (which already self-prunes at 15 s). Small, in-repo, MIT file.
- **T2 — helper: demand-start + bind-retry + idle-exit.** Add a Mach service check-in (launchd demand-start trigger; XPC listener held open, serves nothing — shm + loopback-UDP stay the only data transport per ptp-helper-design.md §4). Bind loop: retry 319/320 for ~10 s before giving up (this is the helper's half of takeover — the app frees the ports in parallel, T5). Idle-exit: peer table empty for ~30 s → clean `airptp_end` + exit; launchd releases the ports. Grace period covers session-start's peers==0 window.
- **T3 — plist: on-demand shape.** Drop `RunAtLoad`/`KeepAlive`, add `MachServices`. Same label → Login Items approval should persist across the re-registration; verify live (R2). KeepAlive's crash-respawn role is replaced by demand-start: a crashed helper is simply re-launched on next touch, and per-session `find()` (design §2.4) already catches mid-session death.
- **T4 — app: touch at session start.** Connect to the Mach service when a session starts (demand-starts the helper), then `find()` with a short retry window instead of assuming the helper is already up (startup-order change vs. design §5.1). Status/approval UX (`PTPHelperService.swift`) unchanged.

## Wave 2 — automatic takeover (Direction B: our click wins even when macOS is playing)

- **T5 — detect + free.** On connect-click: if the current default output device's transport is AirPlay (`kAudioDeviceTransportTypeAirPlay`), switch default output away (to the virtual device once Wave 3 lands; built-in speakers before that) using the existing default-output-switching machinery. macOS tears its session down and frees the ports (latency per G1); the helper's T2 retry loop then wins the bind.
- **T6 — takeover UI.** Transient "Taking over from AirPlay…" state on the device row while T5+T2 race runs; on timeout (ports never freed — G1 tells us if this can happen), a plain-language fallback pointing at Control Center disconnect. Never a raw error.
- **T7 — yield-back verification.** Our session ends (last device disconnected, or app quits) → peers drop → helper idle-exits ≤ ~45 s → system dropdown works again. App-quit path must remove peers / stop the session so idle-exit actually triggers.

## Wave 3 — virtual output device (gated on G2)

- **T8 — driver bundle + lifecycle.** "Audiouter" AudioServerPlugIn in `/Library/Audio/Plug-Ins/HAL`, one-time admin install step (installer or in-app privileged copy — spike decides), uninstall hygiene, notarization wired into `make-app.sh`.
- **T9 — default-output semantics.** Session starts → set default output to the Audiouter device (shows selected in Sound settings). User unselects it there (picks any other device) → that's the off switch: end the session gracefully, helper idles out, ports free. Next connect in-app → re-select automatically. Respect/merge with existing reverse auto-swap semantics.
- **T10 — capture-path integration.** Tap-follows-default now taps the virtual device during sessions; verify per-app routing, excluded apps, volume-keys→Main-Out, and synced-local/LocalPlaybackEngine interplay all hold. Regression risk is here, not in the driver itself.

## Wave 4 — combined live checklist (Alec, before merge)

Fresh boot →
1. System dropdown → Sonos: works with Audiouter installed but unused (Direction A).
2. While system-AirPlay plays: click a device in Audiouter → auto-takeover, "Taking over…" shown, audio moves, Sound settings now shows Audiouter selected.
3. Unselect Audiouter in Sound settings → our session ends; ≤ ~45 s later the system dropdown works again.
4. Reconnect in Audiouter → virtual device re-selected automatically, no manual re-pick.
5. Regression: per-app routing, excluded apps, volume keys, group connect, rapid toggle.
6. Approval persistence: Login Items still shows the helper approved after the plist change (no re-approval trap).

## Risks

- **R1 — macOS may not free the ports on default-output switch alone** (keeps the session warm until Control Center disconnect). G1 measures; fallback = T6's guided message. Worst case, takeover is "switch + a few seconds," not instant.
- **R2 — root-component lifecycle change.** Plist changes to an approved `SMAppService` daemon can behave differently under re-registration; ad-hoc builds can't test it at all (Developer ID only). Budget a dedicated live pass.
- **R3 — driver-class component is new surface.** Signing/notarization/install of a HAL plugin has its own failure modes; that's exactly what G2 de-risks before any Wave-3 build.
- **R4 — idle-exit vs. warm-signal.** The helper exiting between sessions means first-connect gains helper-spawn + bind latency (~sub-second expected). If warm-signal work assumes a standing clock, reconcile there (measure in Wave 4, don't pre-optimize).
- **R5 — branch coordination.** Synced-local (built, unmerged) and universal-sync (planned) both lean on the PTP/grandmaster machinery and the session-start path this plan edits. Sequence merges deliberately; don't let two unmerged branches edit `ptp-helper`/session-start concurrently.
- **R6 — 319/320 are also contested by third parties** (shairport-sync/nqptp, corporate PTP). The T2 bind-retry + T6 messaging handle "ports busy" generically, not just for macOS — no special-casing needed, but test wording covers it.

## Cross-references

- `AirPlayEngine/docs/ptp-helper-design.md` — §2.2/§2.4 (plist, KeepAlive rationale this plan supersedes), §4 (IPC decision: shm + loopback-UDP stay; the Mach service is a demand-start trigger only, not a new transport), §5.1 (startup order, amended by T4).
- `scripts/ptp-helper.plist`, `scripts/make-app.sh` — T3/T8 build wiring.
- Memory: `ptp-helper-daemon-built`, `native-live-test-single-instance` (single-instance port exclusivity now extends to macOS itself), `tap-follows-default-output-device` (T10's governing rule).
