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
