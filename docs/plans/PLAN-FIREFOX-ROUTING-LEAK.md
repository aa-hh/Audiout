# Plan — Firefox per-app routing leak + Bluetooth current-device fix

Status: **APPROVED, not yet executed** · Branch: `claude/firefox-audio-routing-bug-14ba63` · Backend: **native only**

## Symptom (user report)
- SYSTEM AUDIO "Main Audio" → "Selected Devices" = AirPlay "Mixer" (feed = System). Local "MacBook Pro Speakers" is Current Device but not a selected feed.
- APP EXCEPTIONS: Firefox → REDIRECT = "MacBook Pro Speakers".
- Observed: Firefox is **not** audibly reaching its redirect target, AND the Main/"Selected Devices" output plays the **same** audio as Firefox — i.e. Firefox leaks into the system mix instead of being separated out. Separation of concerns is broken.
- Secondary: no handling for the case where the "current"/main output device is **Bluetooth** headphones.

## Root cause (grounded in code)
1. **The leak.** App resolves an app to a *single* PID — the main application process (`AudioutCore/Sources/AudioutApp/AppDelegate.swift:42-44`, via `NSRunningApplication…first?.processIdentifier`). Multi-process browsers (Firefox, Chrome) emit audio from a **child** process (media/RDD/utility) with a different PID. So:
   - the whole-system tap's exclusion (`NativeCaptureCoordinator.swift:314-329,347-356,873-882`) misses Firefox's real audio process → Firefox leaks into "Mixer"/Main Out;
   - the per-app capture (`PerAppCaptureCoordinator.swift:735-801`) taps the silent main process → the redirect target hears nothing.
2. **Bluetooth gap.** `.currentDevice` redirect is *labeled* from the real default output (`kAudioHardwarePropertyDefaultOutputDevice`, house rule) but `LocalPlaybackEngine` hard-pins the **built-in speakers** (`LocalPlaybackEngine.swift:103-116,631-648`). A Bluetooth/AirPods/USB current device plays out the wrong hardware.

## Decisions (confirmed with the owner)
- **Q1 — app matching:** match **all** of a bundle's audio child processes (enumerate live audio-process list, keep any whose owning/responsible app resolves to the target bundle). One rule for both capture and exclusion.
- **Q2 — current device:** local playback **follows the real default output device**, with an **anti-feedback guard** that refuses to follow when that default is itself an AirPlay/virtual Selected Device we're streaming to.
- **Q3 — sequencing:** **fix everything in one batch** (leak fix + Bluetooth/local-playback fix together, one live test). Note: T3's leak fix must remain shippable independently if the AVAudioEngine local-playback path stalls.
- **Q4 — scope:** **native backend only** (OwnTone out of scope).
- **Q5 — diagnostic first:** yes — silent no-audio process-object dump (T7) so the owner confirms the child-process theory on their macOS before T1 commits.

## Tasks

| ID | Task | Files | Model · Effort | Depends |
|----|------|-------|----------------|---------|
| T7 | Silent process-object diagnostic (dump `kAudioHardwarePropertyProcessObjectList` w/ bundle/PID/responsible-PID; env-gated, no audio) | `AudioDiag.swift` and/or `scripts/` probe | haiku · low | — |
| T1 | Core Audio primitive: resolve the **full set** of audio process objects for a bundle ID | new `AudioProcessResolver.swift` | opus · high | Q1, T7 |
| T2 | Per-app capture targets the full process-object set (mixdown of all bundle processes; keep `.processNotYetAudible`) | `PerAppCaptureCoordinator.swift:735-801` | opus · high | T1 |
| T3 | Whole-system tap **exclusion** uses the full process-object set — **fixes the leak** | `NativeCaptureCoordinator.swift:314-329,347-356,873-882` | sonnet · medium | T1 |
| T5 | `.currentDevice` playback follows real output + anti-loop guard | `LocalPlaybackEngine.swift:103-116,631-648` | opus · high | Q2, Q3 |
| T4 | Thread the resolver seam through backend wiring (owns all `NativeBackend.swift` edits) | `AppDelegate.swift:42-45,61`, `NativeBackend.swift:516-574` | sonnet · medium | T1 |
| T6 | Tests: multi-process resolution, empty-set→not-yet-audible, T5 device-selection branches | `PerAppCaptureCoordinatorTests`, `NativeCaptureCoordinatorTests`, `NativeBackendTests`, `LocalPlaybackEngineTests` + new T1 tests | sonnet · medium | T1,T2,T3,T5 |
| T8 | Docs + memory: supersede single-PID assumption; record Q2 device decision | `AGENTS.md`, memory note | haiku · low | T2,T3,T5 |

## Parallelization
- **Wave 0:** resolve Q1–Q5 (done); run **T7** independently.
- **Wave 1:** **T1** (new file) lands before consumers.
- **Wave 2 (parallel, disjoint files):** **T2**, **T3**, **T5**. **T4** owns all `NativeBackend.swift` edits; **T5** confined to `LocalPlaybackEngine.swift` to avoid clobbering the hot file.
- **Wave 3:** **T6** (single serial task across test files), **T8** (docs).
- **Critical path:** T7 → T1 → T2/T3 → T6. T5 trails on Q2/Q3 without blocking the leak fix.

## Execution mode
Watched **agents** (not a workflow) — judgment-heavy, correctness/privacy-sensitive live-audio code; mid-course correction likely after T7.

## Risks / guardrails
- **Load-bearing unknown:** the exact Core Audio property mapping a helper audio process → parent app must be confirmed live via T7 **before** T1 commits.
- `.currentDevice` AVAudioEngine local playback is historically flaky (dies "through the mic"); batching verifies it live this round — T3 leak fix must stand alone if it stalls.
- Feedback-loop hazard in T5 if the default output *is* the AirPlay target — guard essential.
- Check `.mutedWhenTapped`: once capture targets the real child, confirm the child is muted at its normal output (no double-play).
- **Live audio is owner-only** — build silently (`swift build`), no tones/selftests; the owner runs all heard/not-heard tests on real Firefox + real BT hardware.
- **No merge without the owner's explicit go-ahead** (standing rule). Docs/AGENTS.md land in the worktree as a merge, never ahead of code on main.

## Key files
`AudioutApp/AppDelegate.swift` · `AudioutCore/PerAppCaptureCoordinator.swift` · `AudioutCore/NativeCaptureCoordinator.swift` · `AudioutCore/NativeBackend.swift` · `AudioutCore/LocalPlaybackEngine.swift` · `AudioutCore/AppRouteMixer.swift` · `AudioutPopoverUI/PopoverController.swift`
