# PLAN: User-facing latency setting (Settings › Audio › Advanced) — IMPLEMENTED

Status: **implemented 2026-07-17 on `claude/lucid-cori-044f0e`** (ahh
approved 2026-07-17: "makes sense to me"). Companion to the latency work in
`AirPlayEngine/docs/latency-analysis.md` (commit 5313cc1): the sender start
buffer is now configurable (engine knob + `AIRPLAY_START_BUFFER_MS` env) AND
a user setting with a safe floor and an explicit apply step. Remaining:
the gated by-ear checklist (latency-analysis.md, step 4 — the Settings
apply-flow round trip) needs ahh + the real fleet.

**Relation to the earlier "no latency slider" decision (2026-07-17, settings
window pass):** SoundSource's *Audio Processing latency slider* was explicitly
NOT adopted — a raw, silent-failure-prone processing knob. This plan is a
different thing and honors that decision's reasoning: the *AirPlay start
buffer*, exposed as three tested presets with a hard floor and an explicit
apply step — it cannot be set to a non-working value.

## 1. What ships

An **Advanced** sub-section at the bottom of the **Audio** section (the
settings window is ONE screen — `SettingsRootViewController` with
General/Appearance/Audio as bold-labeled sections + hairline dividers; the
Audio section is built by `AudioSettingsViewController`):

```
Advanced ────────────────────────────────────────────────
Audio buffer                             [ 1000 ms ▾ ]
  A smaller buffer reacts faster to play and pause. A
  larger buffer resists Wi-Fi hiccups and dropouts.

                              [ Apply & Reconnect ]
```

- **Numeric options, not named presets (ahh, 2026-07-17 mockup review —
  LOCALIZATION):** dropdown items are bare millisecond values ("1000 ms",
  via `NumberFormatter` for locale digit grouping) — named presets with
  embedded delay descriptions ("Balanced (about 2 seconds)") don't survive
  translation length-wise. The one localizable sentence is the caption.
  The row is titled **"Audio buffer"**, not "Audio delay": the number IS the
  buffer size, and total perceived delay is larger (receiver adds its own
  share) — labeling it "delay: 1000 ms" would promise a 1 s delay the user
  doesn't get.

  | Option | expected click-to-sound* |
  |---|---|
  | 1000 ms (default, lowest) | ~2.2 s |
  | 1500 ms | ~2.7 s |
  | 2250 ms | ~3.5 s (old behavior) |

  *Assumes the receiver-applied share measured in the gated run. Values live
  as named constants in one place.

- **User floor = 1000 ms** (ahh, 2026-07-17: dropped the 500 ms option).
  1000 ms leaves receivers a 750 ms jitter buffer — comfortably safe on
  ordinary Wi-Fi (see risk note in §6). The gated floor sweep (via the env
  knob, which still accepts 300–5000) can justify ADDING a lower option
  later; it no longer gates shipping. The engine shim keeps its own hard
  clamp at 300 ms (below ~250 the vendored sender rejects every session), so
  even a corrupted default can't produce a non-working value.

- **Explicit CTA applies the change** (ahh, this thread): changing the popup
  arms the button; nothing changes until it's clicked.
  - Streaming → button reads **"Apply & Reconnect"**; clicking causes ~3–5 s
    of silence (session re-handshake + new buffer fill), then **streaming
    auto-resumes to the same speakers** — no manual re-toggling.
  - Idle → button reads **"Apply"**, applies instantly and silently.
  - While reconnecting: button disabled, inline label "Reconnecting
    speakers…"; popover rows show the normal connecting → connected
    transitions (existing event stream, no new UI).

- AppKit only (standing rule): `NSPopUpButton` for the preset, push-button
  CTA, `SettingsForm` labels — same idiom as the existing panes.

## 2. Why no engine restart (the mechanism)

Verified in the vendored source: the buffer is read at **stream-session
creation** (`airplay.c master_session_make` → `outputs_buffer_duration_ms_get()`),
and the master session is freed when its last speaker session ends. So apply =

1. `engine.setStartBufferMs(ms)` — new actor method, marshals
   `outputs_set_buffer_duration_ms()` onto the engine thread.
2. Remove **ALL** currently-streaming outputs, **await completion**, then
   re-add the previous set.

The all-then-readd ordering is an invariant: if any speaker stays attached,
the old master session (old buffer) survives and the re-added speakers join
it. This is a dedicated awaited method on `NativeBackend`, NOT two racing
`setOutputSet` calls. Capture keeps running throughout (engine drops writes
while no session exists — no TCC re-prompt, no tap churn). PTP, discovery,
and the engine thread are untouched.

## 3. Data model & resolution order

- `AppSettings.startBufferMs: Int` (UserDefaults scalar, key
  `audio.startBufferMs`, default 1000) — the scalar half of the persistence
  split, exactly like `theme`/`density`. Unknown/out-of-range stored values
  resolve to the default.
- Resolution at backend construction (`nativeStartBufferMs`):
  **env `AIRPLAY_START_BUFFER_MS` (valid) → user setting → 1000.**
  Env wins because it's a deliberate per-launch dev override; when it's set,
  the Advanced section renders disabled with a note
  ("Overridden by AIRPLAY_START_BUFFER_MS").
- **Capability seam, not a protocol change:** `OutputBackend` stays as-is. A
  narrow protocol
  `LatencyConfigurable { var startBufferMs: Int get; func applyStartBuffer(ms:) async }`
  is adopted by `NativeBackend`. The settings pane shows the Advanced section
  only when `backend as? LatencyConfigurable` exists — so the mock and
  OwnTone backends simply never show a knob they can't honor.
  (Option: `MockBackend` conforms with a fake 1 s reconnect so the UI is
  developable without hardware — cheap, included.)

## 4. Work items

| # | Task | Files |
|---|------|-------|
| 1 | `AirPlayEngine.setStartBufferMs(_:)` (actor method, engine-thread marshal; also updates the latency probe's logged lead, which is currently fixed at init) | `AirPlayEngine.swift` |
| 2 | `NativeBackend.applyStartBuffer(ms:)` — snapshot selected set + volumes/mutes → awaited remove-all → engine set → re-add via existing converge → re-push volumes/mutes; per-device failures keep D4 best-effort semantics (marked unavailable) | `NativeBackend.swift` |
| 3 | `AppSettings.startBufferMs` + the option list as named constants (values only — no user-facing preset names) | `AppSettings.swift` |
| 4 | `nativeStartBufferMs` resolution: env → setting → default | `OwnToneBackend.swift` (makeBackend) |
| 5 | Audio pane Advanced section: popup + CTA + reconnecting state + env-override note; hidden unless backend is `LatencyConfigurable` | `AudioSettingsViewController.swift`, `SettingsForm.swift` |
| 6 | App wiring: pane → backend capability, main-actor plumbing | `AppDelegate.swift` / settings window controller |
| 7 | Tests (below) + `settings-snapshot` light/dark re-render (the established verification path for Settings UI — computer-use cannot see this app) | tests, `settings-snapshot` |

## 5. Tests (headless)

- `AppSettings.startBufferMs` roundtrip + garbage-value fallback (throwaway
  `UserDefaults` suite, existing pattern).
- Resolution order: env beats setting beats default; invalid env falls
  through to setting.
- `applyStartBuffer` sequencing against the spy engine: every removeOutput
  completes before the engine set-call, which precedes the first re-add;
  volumes re-pushed after re-add; a failing re-add marks that device
  unavailable and doesn't block the rest.
- Probe lead reflects the new value after apply.
- Pane logic: section hidden for non-conforming backend; CTA arms on change,
  disables while applying; env override renders disabled state.

## 6. Gated (user present, real fleet) + the 1000 ms risk assessment

**Why 1000 ms as the lowest option is safe (ahh asked, 2026-07-17):** the
receiver's protection against network trouble is `start_buffer − 250 ms` of
buffered audio — 750 ms at the 1000 ms option. Ordinary Wi-Fi disturbances
(channel scans, interference bursts, contention with other traffic) stall
delivery for ~100–500 ms; 750 ms absorbs those AND leaves room for the
sender's retransmit round-trips (lost-packet recovery via the control
channel needs a few RTTs before the deadline). The genuinely risky territory
starts below ~500 ms, where a single bad Wi-Fi moment can outrun the
cushion. 1000 ms was this plan's *default* all along — making it the floor
removes the one risky option rather than adding risk. Residual risk to
verify by ear only: many-room fleets on congested 2.4 GHz.

- Gated checks: 10 min dropout-free music at 1000 ms on ≥ 2 rooms
  (latency-analysis.md steps 2–3); the optional env-knob sweep below 1000
  (750/500) is now purely reconnaissance for a possible FUTURE lower option.
- Apply-flow by ear: while streaming to 2 rooms, click Apply & Reconnect →
  ≤ ~5 s silence → both rooms resume **in sync** at the new latency; popover
  states transition cleanly; volumes/mutes preserved.

## 7. Non-goals

- No continuous slider / raw ms field. No per-device buffer. No OwnTone-path
  buffer control. Volume mapping untouched (regression tripwire only).

## 8. Sequencing / integration note

This plan needs BOTH parents: the Settings window (on `main`, ce49103) and
the latency knob (`claude/lucid-cori-044f0e`, 5313cc1, based on the Phase 2b
branch). Implement on a branch containing both — cleanest is after Phase 2b +
the latency commit merge to main; otherwise merge `main` into the latency
branch first. The gated floor sweep can happen in the same live session that
closes Phase 2b (runbook D7 step 6).
