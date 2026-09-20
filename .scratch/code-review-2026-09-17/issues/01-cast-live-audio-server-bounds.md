# 01 — Bound the Cast live-audio server: peer check, connection cap, idle deadline

Status: ready-for-agent
Wave: 1
Pipeline model: fable (normal mode)
Source: [REVIEW.md](../REVIEW.md), findings model #1

Today `CastLiveAudioServer` binds every interface by default and streams the Mac's system audio to any peer that sends a GET on any path, with no connection cap and no idle deadline.

## Done when

A GET from an address other than the receiver we handed the URL to is refused (closed, no body). More than N simultaneous connections are cancelled on arrival. A connection that sends nothing is closed after an idle deadline. Existing Cast playback tests still pass; new tests name these three defects.

## Test seam

`CastLiveAudioServerTests` / `CastOutputManagerTests` (extend; the server takes a loopback connection in tests)

## Verification

```bash
bash scripts/run-tests.sh --filter CastLiveAudioServer ; bash scripts/run-tests.sh --filter CastOutputManager
```

## Findings (verbatim from the area reports)

### 1. [BUG] `CastLiveAudioServer` serves the Mac's live system audio to any LAN peer, on any path, with no cap and no idle deadline
- Where: `AudioutCore/Sources/CastSender/CastLiveAudioServer.swift:122`, `:208-234`, `:169-180`; `AudioutCore/Sources/AudioutCore/CastOutputManager.swift:438`, `:652-655`
- Evidence: `serverBindsLoopbackOnly: Bool = false` (CastOutputManager.swift:438, production default); CastLiveAudioServer.swift:214-215 `case "GET", "HEAD": // Any path is served`. `accept(_:)` (:169) adds to `connections` with no count check and arms no deadline; `readRequest` only completes when data arrives.
- Why it matters: with `loopbackOnly` false the listener binds all interfaces, so anything on the network that finds the ephemeral port gets a continuous chunked WAV of whatever the Mac is playing. No path check, no URL secret. Unlimited idle connections exhaust file descriptors the AirPlay RTP, PTP and DACP paths also draw on.
- Fix: check the remote endpoint against the receiver's address before streaming (`streamHostOverride` sits beside the flag), and copy `DACPServer`'s idle `DispatchWorkItem` plus `CompanionServer`'s `pendingCap` pattern into `accept(_:)`.
- Confidence: high
