Revised 2026-09-20 after review: the peer match also admits an IPv4-mapped IPv6 peer (Decisions, peer check).

# Work order: bound the Cast live-audio server (ticket 01)

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cr-01-cast-live-audio-server-bounds`, HEAD `a14ff11f`, tree clean.

## Goal

`CastLiveAudioServer` streams the Mac's system audio as an endless WAV to any peer that opens a TCP connection to its ephemeral port and sends a GET, with no connection cap and no idle deadline. Bound it so only the receiver we handed the URL to is served, so a connect-flood cannot exhaust file descriptors shared with AirPlay RTP, PTP and DACP, and so a silent connection is closed after 30 s. The receiver's address comes from the control connection `CastChannel` already holds. This closes the highest-ranked finding in the 2026-09-17 review.

## Verified facts

- `CastLiveAudioServer.init(source:loopbackOnly:primeMilliseconds:)` — `AudioutCore/Sources/CastSender/CastLiveAudioServer.swift:98`. All work runs on `queue` (`:85`); `connections` and `timers` dictionaries keyed by `ObjectIdentifier` at `:95-96`.
- `accept(_:)` at `:171-183` adds to `connections`, sets the state handler, starts the connection on `queue`, calls `readRequest`. No cap, no deadline, no peer check.
- `drop(_:)` at `:185-189` cancels the timer and the connection; `stop()` at `:158-167` cancels timers and connections.
- `readRequest` at `:191-206` loops until `\r\n\r\n` then calls `respond(to:on:)` at `:208`; both run on `queue` because the connection was started on `queue` (`:181`).
- `respond` serves `GET`/`HEAD` on any path (`:212-214`).
- An accepted `NWConnection`'s remote address is `connection.endpoint` (Network framework: the endpoint of the peer). The repo's existing pattern for reading a peer host is `guard case let .hostPort(host, _) = ..., case let .ipv6(addr) = host` at `AudioutCore/Sources/AudioutCore/NativeDiscovery.swift:1077-1078`; the IPv4 counterpart `case let .ipv4(address) = host` with `"\(address)"` giving a dotted quad is at `AudioutCore/Sources/CastSender/CastChannel.swift:134-137`.
- `CastChannel` records only the local address: `_localIPv4Address` (`CastChannel.swift:42`), public getter `localIPv4Address` (`:66`), set in `recordLocalAddress()` (`:134-150`) called on `.ready` (`:108`). The comment at `:145-150` says the control connection may ride IPv6 while the stream URL is always IPv4.
- `CastOutputManager` creates the server at `AudioutCore/Sources/AudioutCore/CastOutputManager.swift:652-656` inside `afterReceiverStatus`, after the channel is connected (`session.channel?.localIPv4Address` is read at `:648`). Manager init at `:437-447` takes `serverBindsLoopbackOnly` (production default `false`) and `streamHostOverride`.
- `CastDeviceRecord.endpoint` is the Bonjour service endpoint (`AudioutCore/Sources/CastSender/CastBrowser.swift:19`); the receiver's IP is only known once the channel resolves it.
- Other `CastLiveAudioServer` constructors: `CastSpikeRun.swift:137-141` and `CastFakeReceiverLoopTests.swift:115` — both use only the existing three parameters; defaults on new parameters keep them compiling unchanged.
- Reference patterns: `DACPServer.swift:82-92` (`idleReceiveTimeout = 30`, `idleTimeouts: [ObjectIdentifier: DispatchWorkItem]`), `:214-231` (arm `DispatchWorkItem` in accept, `queue.asyncAfter`), `:239` (cancel on receive). `CompanionServer.swift:229-236` (`pendingCap = 32`), `:530-535` (guard count at top of accept, `connection.cancel()` on the over-cap arrival).
- Test harness: `CastLiveAudioServerTests.swift:42-52` `startServer(primeMilliseconds:)` builds a loopback-only server; `exchange(port:request:timeout:until:)` at `:57-94` opens a client `NWConnection` to `127.0.0.1`, sends `request` on `.ready`, collects bytes, returns `(data, completed)` where `completed` is true on EOF/error/cancel, and cancels the client before returning. `@testable import CastSender` at `:11`. Uses swift-testing (`@Suite`, `@Test`, `#expect`, `#require`).
- `CastOutputManagerTests` (`:87-95`) drives the manager against `FakeCastReceiver` bound to `127.0.0.1` (`FakeCastReceiver.swift:182,195`), so the channel's remote address and the fake's fetch source are both `127.0.0.1`.
- Baseline: `bash scripts/run-tests.sh --filter CastLiveAudioServer` → `Test run with 4 tests in 1 suite passed`; `bash scripts/run-tests.sh --filter CastOutputManager` → `Test run with 14 tests in 1 suite passed`.

## Decisions (settled here)

- Constants: `maxConnections = 32` (CompanionServer's `pendingCap`), `idleDeadline: TimeInterval = 30` (DACPServer's `idleReceiveTimeout`).
- Injection: three new `init` parameters with defaults on `CastLiveAudioServer`: `allowedPeer: String? = nil`, `maxConnections: Int = 32`, `idleDeadline: TimeInterval = 30`. No `test_` override vars (review finding #8 calls those out).
- Peer check runs at accept time, on `connection.endpoint`, before `connection.start`. A peer matches when its host is `.ipv4(addr)` with `"\(addr)" == allowedPeer`, or `.ipv6(v6)` whose `v6.asIPv4` (an IPv4-mapped IPv6 address) matches the same way. Anything else (a plain IPv6 peer, a `.name` host, a non-hostPort endpoint) is refused when `allowedPeer` is set. (Revised after review: a listener bound to all interfaces may report an IPv4 receiver as `::ffff:a.b.c.d`.)
- `allowedPeer == nil` means no peer check (today's behaviour). Reason: the manager can only learn the receiver's IPv4 address from the control connection, and `CastChannel.swift:145-150` documents that the control connection sometimes rides IPv6 on the owner's own network (live failure 2026-08-23). Refusing on nil would strand every such session. In loopback-only mode the listener is bound to `127.0.0.1` (`:125`), so nil there can only admit loopback peers anyway. This deviates from the ticket's suggested default; override if you disagree, the diff does not change.
- Idle deadline: armed in `accept`, cancelled when a complete request head reaches `respond` (not on first byte — a trickling peer stays bounded), and also cancelled in `drop`. Fires → `connection.cancel()`, which lands in the existing state handler → `drop`.
- Cap: checked at the top of `accept` against `connections.count`; an over-cap arrival gets `connection.cancel()` and is never stored.
- Refusal for a wrong peer: `connection.cancel()` without `start` and without storing — no body, no status line.
- `CastChannel` gains `remoteIPv4Address: String?`, the mirror of `localIPv4Address`. `CastOutputManager` passes it as `allowedPeer`. `CastSpikeRun` is left unchanged (dev tool).

## Steps

1. `AudioutCore/Sources/CastSender/CastLiveAudioServer.swift`, `init` at `:98` and stored properties near `:80-82`: add the three parameters `allowedPeer: String? = nil`, `maxConnections: Int = 32`, `idleDeadline: TimeInterval = 30`, stored as `private let`. Add `private var idleTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]` beside `timers` at `:96`. No behaviour yet. Run `bash scripts/run-tests.sh --filter CastLiveAudioServer` → still 4 passing.

2. `AudioutCore/Tests/AudioutCoreTests/CastLiveAudioServerTests.swift`: extend `startServer` (`:42`) to forward `allowedPeer`, `maxConnections`, `idleDeadline` with the same defaults. Add a helper that opens a raw client `NWConnection` to `127.0.0.1:port`, starts it on a test queue, spin-waits for `.ready` (same 2 s deadline idiom as `:48-49`), and returns it so a test can hold a slot open. Then add three tests, each with a one-sentence comment naming the code change that turns it red (root `AGENTS.md:146-149`):
   - `refusesAGetFromAnAddressOtherThanTheReceiver`: server with `allowedPeer: "10.0.0.1"`; `exchange` a `GET /live.wav` with timeout 2 and `until: { _ in false }`; expect `completed == true` and `data.isEmpty`. Then a second server with `allowedPeer: "127.0.0.1"`; same GET with `until: { self.split($0) != nil }`; expect the head starts with `HTTP/1.1 200 OK` (proves the check admits the real receiver).
   - `cancelsConnectionsBeyondTheCapOnArrival`: server with `maxConnections: 1`; open one raw connection and hold it; send it `GET /live.wav HTTP/1.1\r\nHost: x\r\n\r\n` and wait until at least one byte comes back (proves the server stored it); then `exchange` a second GET with timeout 2 and `until: { _ in false }`; expect `completed == true` and `data.isEmpty`. Cancel the held connection in a `defer`.
   - `closesAConnectionThatSendsNothingAfterTheIdleDeadline`: server with `idleDeadline: 0.3`; `exchange` with `request: ""` (an empty send is harmless; or skip the send when the request is empty), timeout 2, `until: { _ in false }`; expect `completed == true`.
   Run `bash scripts/run-tests.sh --filter CastLiveAudioServer` → the three new tests must FAIL (peer test receives a 200 from the wrong peer; cap test receives a 200 on the second connection; idle test times out with `completed == false`). Paste the failing output.

3. `CastLiveAudioServer.swift`, `accept(_:)` at `:171`: before anything else, (a) if `allowedPeer` is non-nil and the connection's `endpoint` does not match per the decision above, `connection.cancel()` and return; (b) if `connections.count >= maxConnections`, `connection.cancel()` and return. After the existing `readRequest` call, arm the idle deadline: a `DispatchWorkItem` that cancels the connection, stored in `idleTimeouts[key]`, scheduled with `queue.asyncAfter(deadline: .now() + idleDeadline, execute:)` — the shape at `DACPServer.swift:224-230`. Add a two-line comment stating why nil skips the check (the IPv6 control-connection fact above), so nobody "fixes" it.

4. Same file: in `drop(_:)` (`:185`) add `idleTimeouts.removeValue(forKey: key)?.cancel()` beside the timer removal; in `stop()` (`:158`) cancel and clear `idleTimeouts` beside `timers`; at the top of `respond(to:on:)` (`:208`) remove and cancel the connection's `idleTimeouts` entry. Run `bash scripts/run-tests.sh --filter CastLiveAudioServer` → 7 pass.

5. `AudioutCore/Sources/CastSender/CastChannel.swift`: add `private var _remoteIPv4Address: String?` beside `:42` and a public getter `remoteIPv4Address` beside `:66` with the same lock shape as `localIPv4Address` (`:66`). In `recordLocalAddress()` (`:134`), before the existing local-endpoint logic, read `connection?.currentPath?.remoteEndpoint`; if it is `.hostPort(host, _)` with `case .ipv4(let address) = host`, store `"\(address)"`. A one-line doc comment: the receiver's address, the only peer the audio server may serve.

6. `AudioutCore/Sources/AudioutCore/CastOutputManager.swift:652-656`: pass `allowedPeer: session.channel?.remoteIPv4Address` to the `CastLiveAudioServer` init. Nothing else changes. Run both verification commands.

## Out of scope — do not touch

- `DACPServer.swift` (ticket 02), `CompanionServer.swift`, `NativeDiscovery.swift`.
- `CastSpikeRun.swift`, `FakeCastReceiver.swift`, `CastFakeReceiverLoopTests.swift`, `CastOutputManagerTests.swift` (no new manager test: the fake receiver and the channel are both on 127.0.0.1, so a manager-level test cannot see a wrong peer; the existing 14 tests are the regression net proving the real receiver is still served).
- No path check, no URL secret, no IPv6 stream support, no change to how the channel picks IPv4 vs IPv6, no `test_` override properties, no telemetry or analytics events, no rate limiter, no cleanup of surrounding comments, no shared helper between the three servers.
- No commits, no pushes, no `.dev` builds, no `livetest.sh`, no `make-app.sh`; never bare `swift test`/`swift build`.

## Verification

```
bash scripts/run-tests.sh --filter CastLiveAudioServer ; bash scripts/run-tests.sh --filter CastOutputManager
```
Expected: `Test run with 7 tests in 1 suite passed` and `Test run with 14 tests in 1 suite passed`. Baseline observed before any change: 4 and 14, both passing. Trust only the `Test run with N tests` line, never a bare "passed" (a non-matching filter reports green). If the runner skips as cached, prefix `AUDIOUT_TEST_NO_CACHE=1`.

Test seam: `AudioutCore/Tests/AudioutCoreTests/CastLiveAudioServerTests.swift:133-202` (the three existing wire tests; new ones sit beside them). Defects caught: a GET from a peer other than the receiver gets a 200 and audio; a connection past the cap is stored and served; a connection that never sends stays open forever.

## Execution plan

One track, SERIAL by nature (steps 2-6 consume step 1's init parameters; step 6 consumes step 5's `remoteIPv4Address`). Files: `CastLiveAudioServer.swift`, `CastLiveAudioServerTests.swift`, `CastChannel.swift`, `CastOutputManager.swift`. Model: sonnet. Effort: medium. The branch has no uncommitted work; fork from `a14ff11f`.

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
