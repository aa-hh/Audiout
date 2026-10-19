# 21 — Delete the OwnTone backend the spec retired

Status: ready-for-agent
Wave: 5
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings model #7

`OwnToneBackend`, its client, monitor, `PlaybackController` and 842 test lines drive a server `docs/SPEC.md` §3 says never ships and that is already gone from `dev/`.

## Done when

The four files, the `.ownTone` case, its `makeBackend` arm, the `AIRPLAY_BACKEND=owntone` value and `OwnToneBackendTests.swift` are gone; the ~15 `NativeBackend` comments that cite them state the rule instead. `AudioutCore/AGENTS.md` and root docs no longer mention OwnTone except in `dev/notes/` history. Full suite green.

## Test seam

full suite (deletion touches the backend seam)

## Verification

```bash
AUDIOUT_FULL_SUITE=1 bash scripts/run-tests.sh
```

## Findings (verbatim from the area reports)

### 7. [SUBSTANCE] `OwnToneBackend` and its client are ~1,500 source + ~1,200 test lines driving a server the spec says to delete and that is no longer in the repo
- Where: `OwnToneBackend.swift` (1067), `OwnToneClient.swift` (268), `OwnToneWebSocketMonitor.swift` (128), `PlaybackController.swift` (49), `Tests/AudioutCoreTests/OwnToneBackendTests.swift` (842); selection arm at `OwnToneBackend.swift:796`, `:826`, `:884-897`
- Evidence: `docs/SPEC.md:115-122`: "OwnTone itself is spike scaffolding only. It never ships. … Decided 2026-07-13: the final product contains NO OwnTone references at all — naming included. The interim `OwnToneBackend` … and `dev/owntone/` are deleted when the native sender lands … and the `AIRPLAY_BACKEND=owntone` env value goes with it." `dev/owntone/` is already gone; `BackendKind.resolved` defaults to `.native`.
- Why it matters: reachable only via `AIRPLAY_BACKEND=owntone` against a server no longer present. ~15 comments in `NativeBackend.swift` cite it by file and line (`:17`, `:1176`, `:2964`, `:9682`, `:9939`, `:9978`, `:11030`).
- Fix: delete the three OwnTone files, `PlaybackController.swift`, the `.ownTone` case and `makeBackend` arm, and `OwnToneBackendTests.swift`; rewrite the NativeBackend comments to state the rule instead of the citation.
- Confidence: high
