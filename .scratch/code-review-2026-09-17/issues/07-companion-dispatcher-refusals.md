# 07 — Companion dispatcher: refuse unknown targets and never wedge the start-buffer apply

Status: ready-for-agent
Wave: 1
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings model #13, model #14

`.setGroupMuted` and `.removeAppRoute` reply `.ok` for targets that do not exist, unlike every neighbouring case; `startBufferApplyInFlight` is cleared only on the Task's normal path.

## Done when

Both commands guard membership first and return the same refusal strings their neighbours use. The in-flight flag clears via `defer` inside the Task. Two tests name the defects.

## Test seam

`CompanionCommandDispatcherTests`

## Verification

```bash
bash scripts/run-tests.sh --filter CompanionCommandDispatcher
```

## Findings (verbatim from the area reports)

### 13. [SUBSTANCE] Two commands reply "applied" for targets that do not exist, unlike every neighbouring case
- Where: `CompanionCommandDispatcher.swift:234-236`, `:241-243` (`.setGroupMuted`, `.removeAppRoute` return `.ok` unconditionally; `GroupController.setGroupMuted` :1058-1061 and `AppRoutingController.removeRoute` :113-118 guard silently). Neighbours refuse: `applyUpdateGroup` :409-411, `applySetMainOut` :578-581, `deviceWriteRefusal` :516-518.
- Fix: guard on membership first, return the neighbours' refusals.
- Confidence: high

### 14. [SUBSTANCE] A cancelled buffer-apply task wedges `setStartBufferMs` for the process lifetime
- Where: `CompanionCommandDispatcher.swift:272-280` — `startBufferApplyInFlight = true; Task { await applyStartBuffer(ms); startBufferApplyInFlight = false }`.
- Fix: `defer { startBufferApplyInFlight = false }` inside the Task.
- Confidence: medium
