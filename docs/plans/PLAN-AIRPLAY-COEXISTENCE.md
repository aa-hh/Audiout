# Plan — AirPlay Coexistence: share the timing ports with macOS, take over cleanly, show up in Sound settings

Status: **PLAN ONLY — no code written.** All 3 decisions locked by Alec 2026-07-26 (see "Decisions locked").
Author in a dedicated worktree/branch off `main`; `main` is merge-only. Merge only after Alec live-tests and explicitly says go (standing rule — doubly so here: this rewrites the lifecycle of the one root component and adds a driver-class component).

Problem being fixed: Audiouter's root PTP helper binds UDP 319/320 at boot (`RunAtLoad` + `KeepAlive`) and holds them forever, even when the app isn't running. macOS's own AirPlay 2 sender needs the same ports, so **installing Audiouter permanently breaks the system AirPlay dropdown** (confirmed live 2026-07-26: `ptp-helper` PID 618 held `*.319`/`*.320` with Audiouter not even running). Users will use both paths; they must coexist.

---

## Decisions locked (2026-07-26)

1. **Core principle = "last intent wins," automatically.** The PTP ports are a turn-taking resource — the two senders can never hold them simultaneously. Whoever the user touched last (system dropdown vs. Audiouter device row) gets the ports, with no error states and no manual cleanup in either direction.
2. **Takeover is automatic, no confirmation dialog.** Clicking a device in Audiouter while macOS AirPlay is playing ends the system session and starts ours, with a brief "Taking over from AirPlay…" transient state. The click *is* the consent.
3. **Sound-settings presence = virtual output device, spike-gated, shipped in this same combined effort.** Audiouter appears as an output device in System Settings › Sound while active: users can see that's where audio goes and unselect it there (that's the off switch); the app re-selects it automatically on next use — the user never has to re-select manually. Built as an AudioServerPlugIn (BlackHole-style), gated on G2 proving install + capture cleanly. One combined plan, ships together (Alec chose combined over port-fix-first).

**Known asymmetry — INVESTIGATED AND CLOSED 2026-07-26, do not re-open without new evidence.** We can yield the ports only when idle. If the user clicks the *system* dropdown while an Audiouter stream is active, macOS loses the bind race and its connect fails. Alec asked whether this could be made symmetric ("if something tries to take it from us, we give it up"). Three independent findings say no:

1. **No yield signal exists — measured TWICE, in both configurations.** (a) With built-in speakers as the default output and the ports held, macOS's failed AirPlay connect did **not** change the default output device; it left all audio state untouched behind a "Could not connect" dialog. (b) Alec then raised the sharper case: with **our own aggregate as the selected output**, would macOS deselect us *first* and then connect — giving us the signal in time? Tested directly (aggregate created and set default via the G2b `aggtool`, ports held by the probe, Alec picked the Sonos): `aggtool watch`, an event-driven listener on `kAudioHardwarePropertyDefaultOutputDevice`, recorded **zero** change events. macOS goes straight to the bind, fails, and touches nothing. So the listener (`SystemOutputVolume.swift:198`) never fires in either configuration — there is nothing to subscribe to. The kernel likewise offers no notification to a port holder that another process attempted a bind; a failed `bind()` is private to the loser.
2. **Port sharing is impossible.** Tested directly with a purpose-built probe (`scratchpad/reuseport-probe.c`) that bound 319 and 320 on both IP families **with `SO_REUSEPORT`**, i.e. permissively inviting a co-bind. macOS's AirPlay connect **still failed**. Since BSD only permits a concurrent bind when *every* holder sets the flag, this proves Apple's PTP endpoint binds exclusively. Coexistence is not achievable at the socket layer. (This appears to be untested elsewhere — worth keeping recorded.)
3. **Prior art agrees the wall is real.** Shairport Sync — the reference open-source AirPlay 2 implementation — cannot run in AirPlay 2 mode on macOS *at all* for exactly this reason, and its maintainers document no workaround: AirPlay 2 mandates PTP and "the AirPlay source will only send and respond to signals on ports 319 and 320". No port sharing, forwarding, or substitute-daemon solution exists.

**Remaining unexplored option, deliberately not built:** watching the unified log for macOS's AirPlay failure, then releasing the ports so a *second* user click succeeds. Rejected as a shipping mechanism — it depends on private log formats Apple can change in any update, and it still costs the user a second click. Revisit only if the accepted mitigation proves insufficient in practice.

**Accepted mitigation (unchanged, and now the considered answer rather than a fallback):** the helper holds the ports *only while actually streaming* (Wave 1's idle-exit — verified live on real ports: bound 09:10:51, self-released 09:11:36, exactly the 30 s grace + 15 s idle window), so the system dropdown works in every case except during active Audiouter playback. Wave 3 then makes that remaining case *explicable* rather than mysterious: Sound settings shows "Audiouter" as the selected output, with deselecting it as the off switch.

**The half of Alec's idea that DOES work — build it in Wave 3 (T9).** Switching to a **non-AirPlay** output (speakers, headphones, USB) needs no PTP, so that switch genuinely succeeds, the default output really changes, and our listener *does* fire. Use it: on losing the default-output selection, end the session and release the ports **immediately**, rather than waiting out the 15 s idle window. Same off-switch semantics T9 already planned, but prompt instead of delayed. Only the direct system-dropdown-to-AirPlay case is unreachable.

**RESOLVED RISK — volume on the aggregate. Decision (Alec, 2026-07-26): keep the aggregate, add real media-key interception.**

The problem, measured then explained by the code: with the aggregate as default output, **volume keys do nothing** (confirmed live). The device *advertises* volume capability (`aggtool status`: `vmvc=true scalarMain=true muteMain=true`) but does not deliver it — **do not trust that flag**. Worse, there is no app-side fallback, because today's volume path is deliberately NOT interception: `GroupController.swift:814-842`'s system-volume mirror works by hearing the **default output device's** volume change (via `SystemOutputVolume`'s listener) and mirroring it onto Main Out, with an explicit note at `:828` — *"NOT via CGEventTap/media-key interception — that needs an Accessibility grant."* An aggregate that swallows the volume change breaks that chain at step one, so nothing reaches the mirror. This would re-break the exact bug the mirror was written to fix (live session 2026-07-17: "when i use the volume keys only the current device slider moves").

**Wave 3 therefore gains a task: intercept the volume keys directly** (CGEventTap on `NX_SUBTYPE_AUX_CONTROL_BUTTONS`) and drive `mirrorSystemVolumeToMainOut`'s target set from that, whenever the aggregate is the default output. Keep the existing `SystemOutputVolume` mirror as the path for every other output device — do not replace it; the two coexist, selected by whether our aggregate currently holds the default.

**Cost, honestly:** this needs the **Accessibility** grant. That is NOT a new permission — `MediaKeyController` (live at `AppDelegate.swift:229`) already owns a one-time Accessibility prompt for posting media keys, and onboarding already has a row for it. What changes is its **weight**: Accessibility moves from optional polish (Now Playing control) to **required for volume control while Audiouter is the selected output**. Consequences to design for: (a) the app must detect a missing/revoked grant and say so plainly rather than silently losing volume; (b) Accessibility grants are cdhash-pinned, so rebuilt dev binaries silently lose them (remove + re-add, don't toggle) — expect this during live testing; (c) Accessibility cannot be verified on ad-hoc builds at all, so this needs a Developer ID pass.

**Fallback if interception proves unworkable:** the HAL driver (branch `claude/g2-virtual-device-spike`) can implement a real volume control in ~80 lines and needs no Accessibility — at the cost of the installer, admin password, and code inside `coreaudiod`.

---

## Wave 0 — gates (both cheap, both before any Wave-2/3 code)

- **G1 — live port probe. DONE 2026-07-26, best-case results.** With our daemon booted out, the system dropdown connected (root cause confirmed: it was us). macOS binds 319/320 (v4+v6, wildcard, exclusive — same shape as ours) **at session start only**, holds them while playing, and **releases them ~1–3 s after the default output is switched away** — no Control Center disconnect needed. Timeline: 07:45:03 connect→bound; 07:45:39 switch-away; 07:45:42 free. **Consequences:** T5's switch-away mechanism is sufficient on its own; expected takeover latency ~2–4 s click-to-audio; the 10 s helper retry has wide margin; R1 downgraded — T6's fallback message is belt-and-braces, not a primary path.
- **G2 — virtual-device spike. DONE 2026-07-26: GO-WITH-CAVEATS, then SUPERSEDED by G2b.** The HAL-driver route builds and signs (branch `claude/g2-virtual-device-spike`, `dev/spikes/virtual-device/SPIKE-REPORT.md`) but costs an installer + admin password + Developer ID *Installer* cert + code inside `coreaudiod`, with a silent-Mac crash mode. Kept as fallback only.
- **G2b — aggregate-device spike. DONE 2026-07-26: GO — ADOPTED by Alec as the Wave 3 basis.** A programmatic aggregate named "Audiouter" (branch `worktree-agent-ae99ad2727f8097a1`, `dev/spikes/aggregate-device/SPIKE-REPORT.md`, all claims measured live) delivers the Sound-settings feature with zero install friction and a benign crash mode (coreaudiod owns the I/O; audio keeps flowing). Accepted trade: **no volume slider in the Sound pane, unfixable** — volume keys still work via the app's Main Out handling while running. Blocking caveat A1 for Wave 3: aggregates can't nest — `NativeCaptureCoordinator.createAggregate()` over an aggregate default silently builds a zombie (0 ch, rate 0.0); fix = one shared resolve-through-to-sub-device resolver at both build and listener-guard sites. (A1 is reachable *today* by users with Audio-MIDI-created aggregate defaults — the Wave 3 fix covers that pre-existing hole too.) Wave 3's T8 (driver bundle + installer) is replaced by aggregate lifecycle (create/adopt-by-UID/destroy); T9/T10 semantics unchanged. Alec's ~5-min hands-on checklist from the spike report still runs before Wave 3 code lands.

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

- **R1 — RESOLVED by G1 (2026-07-26):** default-output switch-away alone frees the ports in ~1–3 s. T6's guided message stays as a timeout backstop only (third-party PTP holders, R6, can still trigger it).
- **R2 — root-component lifecycle change.** Plist changes to an approved `SMAppService` daemon can behave differently under re-registration; ad-hoc builds can't test it at all (Developer ID only). Budget a dedicated live pass.
- **R3 — driver-class component is new surface.** Signing/notarization/install of a HAL plugin has its own failure modes; that's exactly what G2 de-risks before any Wave-3 build.
- **R4 — idle-exit vs. warm-signal.** The helper exiting between sessions means first-connect gains helper-spawn + bind latency (~sub-second expected). If warm-signal work assumes a standing clock, reconcile there (measure in Wave 4, don't pre-optimize).
- **R5 — branch coordination.** Synced-local (built, unmerged) and universal-sync (planned) both lean on the PTP/grandmaster machinery and the session-start path this plan edits. Sequence merges deliberately; don't let two unmerged branches edit `ptp-helper`/session-start concurrently.
- **R6 — 319/320 are also contested by third parties** (shairport-sync/nqptp, corporate PTP). The T2 bind-retry + T6 messaging handle "ports busy" generically, not just for macOS — no special-casing needed, but test wording covers it.

## Cross-references

- `AirPlayEngine/docs/ptp-helper-design.md` — §2.2/§2.4 (plist, KeepAlive rationale this plan supersedes), §4 (IPC decision: shm + loopback-UDP stay; the Mach service is a demand-start trigger only, not a new transport), §5.1 (startup order, amended by T4).
- `scripts/ptp-helper.plist`, `scripts/make-app.sh` — T3/T8 build wiring.
- Memory: `ptp-helper-daemon-built`, `native-live-test-single-instance` (single-instance port exclusivity now extends to macOS itself), `tap-follows-default-output-device` (T10's governing rule).
