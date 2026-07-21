# Phase 3 Fix Execution — Progress

Started from the finalized, cost-checked, Alec-approved plan. 15 of 35 tasks
deferred (correction from the original 11 — a fuller pre-launch collision
check found DeviceRowView.swift and scripts/make-app.sh also genuinely dirty
in other active worktrees, and found several onboarding/AppDelegate files
that were dirty at checkpoint time are clean again now — likely committed by
the PTP-helper session in between). Deferred tasks: G-BUG, HEADER-NOOP,
MUTE-FEEDBACK, CONNECT-VOLUME, NATIVE-DIAG, EMPTY-NET, POPOVER-COPY, PICKER,
A11Y-DEVICEROW, HOUSEKEEPING, ICON-BRANCH, RELEASE-CONFIG, G2-NOTARIZE,
PERF-CODEC, G2-LIVE-VERIFY.

Each task appends one line here when it lands: `- [id] status — one line`.

---
- [DESIGN-FEATURE-INTRO] done — wrote docs/plans/phase-3-findings/proposals/feature-intro.md proposing 3 options (onboarding tour, contextual popover hints, in-app How-It-Works page) for teaching app capabilities, not just permissions; recommends contextual hints first + reference page, forced tour only if full-coverage guarantee is required.
- [DESIGN-CARDS] done — wrote docs/plans/phase-3-findings/proposals/cards.md proposing 3 options for the Devices/Applications card confusion (G1-N3); recommends Option B, tagging redirected devices right on their Devices-card row so the relationship between "Selected" membership and per-app redirects is visible where it happens, not just better-labeled.
- [DESIGN-LOCALMIX] done — wrote docs/plans/phase-3-findings/proposals/local-mix.md on the Current-Device-plus-AirPlay mix restriction (G1-N6); the engine's `localOutput`/`setLocalOutputEnabled` API is a confirmed 0%-implemented placeholder (`isImplemented` hard-coded false, unwired into NativeBackend), so recommends Option B (surface the existing refusal reason visibly in the UI instead of tooltip-only) now, with the real synced-local-output build (Option A) treated as a separate scoped project later.
- [DESIGN-SETTINGS] done — wrote docs/plans/phase-3-findings/proposals/settings.md brainstorming ~11 new paid-tier settings across General/Audio/Appearance/Advanced (grounded in today's 4-control Settings surface + G1-N15/N16 and other audit findings); top picks for pre-launch: About & Support, Check for updates, Resume previous speakers on launch, Automatically reconnect a dropped speaker, global keyboard shortcut, Restore Default Settings.
