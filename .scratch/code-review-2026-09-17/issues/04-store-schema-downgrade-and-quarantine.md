# 04 — Stores: never overwrite a newer-schema file; give the approval store the same recovery path as the other nine

Status: ready-for-agent
Wave: 1
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings model #9, model #5, model #6

All nine JSON stores treat a newer-schema file as missing and then `save` over it on the next mutation. `CompanionApprovalStore` additionally decodes without quarantine and reports a failed save to stderr instead of `StoreRecovery.noteWriteFailure`.

## Done when

A store that reads a `schemaVersion` above its own quarantines the file (via `StoreRecovery.quarantine`) before returning empty, so the next save cannot destroy it. `CompanionApprovalStore.load` quarantines on decode failure and its save failure goes through `StoreRecovery.noteWriteFailure`. One table-driven test over the stores proves quarantine on downgrade; the approval store's two paths each get one test.

## Test seam

`AppRouteStoreTests` / `GroupStoreTests` (extend the existing quarantine tests as a table), `CompanionApprovalStoreTests`

## Verification

```bash
bash scripts/run-tests.sh --filter 'StoreTests|CompanionApprovalStore|StoreRecovery'
```

## Findings (verbatim from the area reports)

### 9. [SUBSTANCE] A schema downgrade silently destroys the newer file on the next write
- Where: `AppRouteStore.swift:199`; same in `GroupStore.swift:144`, `RoutingStore.swift:89`, `DeviceEQStore.swift:54`, `DeviceIconStore.swift:51`, `HiddenSpeakersStore.swift:51`, `ExcludedAppsStore.swift:77`, `CompanionApprovalStore.swift:71`, `BTTrimStore.swift:223`
- Evidence: `/// A file from a newer schema is treated as missing rather than crashing an older build. guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }`
- Why it matters: caller falls back to empty; first mutation `save`s `.atomic` over the newer file. Newer build then older build = groups, routes, EQ, approvals gone, no quarantine copy.
- Fix: quarantine on the newer-schema branch, or refuse to save over a file whose stored schemaVersion exceeds current.
- Confidence: high

### 5. [BUG] The companion approval file is the one store that does not quarantine a corrupt file
- Where: `CompanionApprovalStore.swift:67-73`, `:135`; contrast `AppRouteStore.swift:193-198`, `GroupStore.swift:138-142`, `RoutingStore.swift:84-88`, `DeviceEQStore.swift:49-53`, `DeviceIconStore.swift:46-50`, `HiddenSpeakersStore.swift:46-50`, `ExcludedAppsStore.swift:72-76`, `BTTrimStore.swift:218-222`, `BTHardwareVolumeStore.swift:100-102`
- Evidence: `let data = try Data(contentsOf: fileURL); let envelope = try decoder.decode(Envelope.self, from: data)` — no do/catch, no `StoreRecovery.quarantine`. The other nine stores do `catch { StoreRecovery.quarantine(fileURL); throw error }`.
- Why it matters: caller (:135) swallows into `[]`, every approved phone re-prompts, and the first new approval overwrites the evidence.
- Fix: same do/catch + quarantine as the others.
- Confidence: high

### 6. [BUG] A failed approval save is written to stderr instead of `StoreRecovery.noteWriteFailure`, so the user is never told
- Where: `CompanionApprovalStore.swift:195-203`
- Evidence: `catch { FileHandle.standardError.write(Data("[Audiout] companion approvals failed to save: \(error)\n".utf8)) }`. Thirteen other write sites use `StoreRecovery.noteWriteFailure(error)` (GroupController.swift:296, AppRoutingController.swift:62, ExcludedAppsController.swift:40, HiddenSpeakersController.swift:35, DeviceIcon.swift:155, eight in NativeBackend.swift).
- Fix: replace with `StoreRecovery.noteWriteFailure(error)`.
- Confidence: high
