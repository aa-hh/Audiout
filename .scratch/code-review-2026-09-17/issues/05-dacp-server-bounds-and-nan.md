# 05 — DACPServer: cap connections and reject non-finite volume

Status: ready-for-agent
Wave: 1
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings model #2, model #3

`DACPServer.accept` inserts without a cap; `level(fromDb:)` passes NaN/inf from an unauthenticated LAN request into the backend volume write.

## Done when

`accept` cancels on arrival past a cap, matching `CompanionServer`'s `pendingCap` pattern. `level(fromDb:)` returns 0 for a non-finite input (or `deviceVolumeDb` returns nil). Two tests name the defects.

## Test seam

`DACPServerTests`

## Verification

```bash
bash scripts/run-tests.sh --filter DACPServer
```

## Findings (verbatim from the area reports)

### 2. [BUG] `DACPServer` accepts unlimited connections — the exact exhaustion `CompanionServer` guards against and names DACP in
- Where: `AudioutCore/Sources/AudioutCore/DACPServer.swift:196-229`; contrast `CompanionServer.swift:229-236`, `:530-535`
- Evidence: DACPServer.swift:196-198 `func accept(_ connection: NWConnection) { let key = ObjectIdentifier(connection); connections[key] = connection` — no cap. CompanionServer.swift:231-233 explains the opposite choice ("not exhausting this process's file descriptors (which AirPlay RTP, PTP, DACP and Bonjour also draw on)").
- Why it matters: the 30 s idle deadline bounds how long each socket lives but not how many exist at once.
- Fix: a `pendingCap`-style guard at the top of `accept(_:)`, matching `CompanionServer`.
- Confidence: high

### 3. [BUG] A DACP peer can drive a non-finite volume through the trust boundary
- Where: `DACPServer.swift:293-296`, `:347-351`, `:258-262`
- Evidence: `deviceVolumeDb` returns `Double(raw)` ("nan"/"inf" both parse); `level(fromDb:)` has `if db <= -30 { return 0 }; if db >= 0 { return 1 }; return (db + 30) / 30` — both comparisons false for NaN, NaN out.
- Why it matters: `onVolume?(token, .nan)` reaches the backend's volume write from an unauthenticated LAN request. `CompanionCommandDispatcher.swift:304` and `:311` guard `isFinite`; this path does not.
- Fix: `guard db.isFinite else { return 0 }` at the top of `level(fromDb:)`.
- Confidence: high
