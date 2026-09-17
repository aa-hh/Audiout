# AirPlayEngine package — review

## Verdict (3–5 sentences)
The Swift host layer is the most carefully reasoned code in this area — `CompletionRegistry`'s three-way
resolve, the backpressure guard and the op-timeout path all hold up under close reading, and the comments
explain constraints a cold reviewer could not infer. The defects that remain are concentrated at two seams:
the lifetime of the raw libevent base across the teardown boundary (a real use-after-free window on the hot
write path), and ordering inside `bind()`, where the C `stream_id` write and the idempotency read both happen
outside the per-`OutputID` gate that exists to make them atomic. The C shims are solid except for
`uuid_make`, which re-seeds `srand()` per call and therefore hands every AirPlay session an identical
`sessionUUID` and `groupUUID`. The single highest-impact change is to put `EngineThread.base` behind the
lock that already exists next to it, so a late `write` cannot hand a freed `event_base` to
`event_base_once`. Separately, four vendored files carry local edits that the ledger does not record, which
breaks the rule the ledger exists to enforce.

## Findings

### 1. [BUG] `uuid_make` re-seeds `srand()` on every call, so a session's `session_uuid` and `group_uuid` are always identical
- Where: `AirPlayEngine/Sources/CAirPlayEngine/shims/misc.c:778-807`; call site `AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c:1624-1625`
- Evidence:
  ```c
  uuid_make(char *str)
  {
    ...
    now = time(NULL);
    srand((unsigned int)now);
    for (i = 0; i < ARRAY_SIZE(uuid); i++)
      uuid[i] = (uint16_t)rand();
  ```
  and in the sender:
  ```c
  uuid_make(session->session_uuid);
  uuid_make(session->group_uuid);
  ```
- Why it matters: the second call re-seeds the global PRNG with the same `time(NULL)` second and replays the
  identical sequence, so `sessionUUID` and `groupUUID` — both sent to the receiver in SETUP
  (`airplay.c:2874`, `airplay.c:2878`) — are the same string, and any two sessions created in the same second
  on this Mac advertise the same pair. It also clobbers the process-wide `rand()` stream for every other
  caller.
- Fix: seed once (a `static bool`/`dispatch_once`), or drop the PRNG entirely and fill the 16 bytes with
  `arc4random_buf` — it is in libSystem, so this adds no dependency and the "dependency-free variant"
  rationale in the file header still holds.
- Confidence: high

### 2. [BUG] `EngineThread.base` is read from any thread and freed on the engine thread with no synchronization — the write path can call `event_base_once` on a freed base
- Where: `AirPlayEngine/Sources/AirPlayEngine/EngineThread.swift:23`, `:221`, `:244-245`, `:264-306`; caller `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:1348`
- Evidence:
  ```swift
  private(set) var base: OpaquePointer?           // :23, no lock
  ...
  event_base_dispatch(b)                          // :238 returns on loopbreak
  if let ka = keepAlive { event_free(ka); keepAlive = nil }
  event_base_free(b)                              // :244  engine thread
  base = nil                                      // :245
  ```
  against, on any producer thread:
  ```swift
  func enqueue(_ work: @escaping () -> Void, tracked: Bool = true) -> Bool {
      guard let base else { return false }        // :265
      ...
      event_base_once(base, -1, EngineThread.evTimeout, { ... }, box, nil)   // :294
  ```
- Why it matters: `write(streams:pts:)` is `nonisolated` and calls `enqueue` with no actor hop
  (`AirPlayEngine.swift:1348`). A frame that reads a non-nil `base` just before line 244 hands that pointer to
  `event_base_once` after `event_base_free` — a use-after-free on the audio path during every stop, plus an
  unsynchronized read/write of the pointer itself. `startedFlag` does not close this: it is stored at
  `AirPlayEngine.swift:558`, long before the thread frees the base at `:591`.
- Fix: guard `base` with one `NSLock` — take it in `enqueue` across the nil-check and the `event_base_once`
  call, and in `threadMain` across the free plus the `base = nil`. `EngineThreadHolder` right below already
  uses exactly this shape.
- Confidence: high

### 3. [BUG] `bind()` writes the C `stream_id` and reads the live state before taking the per-`OutputID` op gate
- Where: `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:853-895` (gate is taken later, at `:1504`)
- Evidence:
  ```swift
  private func bind(_ id: OutputID, streamId: UInt32, serialize: Bool) async throws -> OutputBindResult {
      ...
      let live = await liveBinding(id)                       // :873  suspension, no slot held
      ...
      await applyStreamIdOnDevice(id: id, streamId: streamId) // :889  suspension, no slot held
      let terminal = try await startOp(id: id, serialize: serialize) { ... }   // acquireOp happens in here
  ```
- Why it matters: the doc above this method says the `stream_id` write "MUST land before `device_start`" and
  that `rebindOutput` holds the slot "across BOTH halves … so no concurrent `addOutput`/`removeOutput` can
  slip between". It can: a concurrent `addOutput(id, streamId:)` writes `device->stream_id` while a
  `rebindOutput` holds the slot, and two concurrent binds on one id both pass the `liveBinding` idempotency
  check and can interleave so the session is created on the other caller's stream. Audio written to the
  requested stream then never reaches the device, which is the exact symptom `OutputBindResult` was added to
  make visible.
- Fix: take the gate at the top of `bind`/`unbind` (`await acquireOp(id)` + `defer releaseOp(id)` when
  `serialize`), and pass `serialize: false` down to `startOp`, the way `rebindOutput` already does.
- Confidence: high on the ordering; medium on live reachability (the app layer may serialize today)

### 4. [BUG] The root PTP daemon shuts down on request from any local process — the XPC peer is never validated
- Where: `AirPlayEngine/Sources/ptp-helper/main.c:463-478`; service registration `scripts/ptp-helper.plist:51-55`
- Evidence:
  ```c
  xpc_connection_set_event_handler((xpc_connection_t)peer, ^(xpc_object_t event) {
    if (xpc_get_type(event) == XPC_TYPE_DICTIONARY &&
        xpc_dictionary_get_bool(event, "release"))
    {
      ptp_helper_logmsg("ptp-helper: release requested - exiting so the PTP ports are freed");
      ptp_helper_should_run = 0;
    }
  });
  ```
- Why it matters: the Mach service is registered by a system-domain launchd job, so any process on the machine
  can look it up, connect, and send `{"release": true}`. Repeating that kills the PTP clock as fast as launchd
  demand-starts it, and every PTP-only receiver (Sonos et al.) stops streaming. This is the one root process
  in the product; its only input needs the strongest check in the package, and it has none.
- Fix: before honoring `release`, require the peer to be the app — `xpc_connection_set_peer_code_signing_requirement`
  with the app's designated requirement (macOS 12+), or check the peer's audit token / euid. One call, at the
  top of the peer handler.
- Confidence: high

### 5. [SUBSTANCE] Four vendored files carry local edits that `VENDORED-DIFFS.md` does not record
- Where: `AirPlayEngine/Sources/CAirPlayEngine/sender/airplay_events.c` (+295/−5), `sender/airplay_events.h:1`,
  `pair_ap/pair_fruit.c`, `pair_ap/pair_homekit.c`; ledger `AirPlayEngine/docs/VENDORED-DIFFS.md:30-36`
- Evidence: `git diff 7549cb66 -- <those paths>`:
  ```
  airplay_events.c | 300 ++++++++++++++++++++-   (295 insertions, 5 deletions)
  -airplay_events_listen(const char *name, const char *address, ...
  +airplay_events_listen(const char *name, uint64_t device_id, const char *address, ...
  +  free_ng(usr->ng);        (pair_fruit.c)
  +  free_ng(usr->ng);        (pair_homekit.c)
  ```
  while the ledger states: **Total vendored files touched: 7** — `airplay.c`, `raop.c`, `ptp_msg_handle.c`,
  `libairptp/airptp.h`, `libairptp/src/airptp.c`, `airptp_internal.h`, `daemon.c`. None of the four above
  appear, and `airplay_events.c` carries no in-file `[AirPlayEngine vendored change …]` marker either.
- Why it matters: the AGENTS.md rule is "vendored sources change only as a last resort, marked in place and
  ledgered as an exception". Eleven files, not seven, now differ from upstream, so the next re-vendor or
  upstream merge will silently drop the speaker-input event path and two real leak fixes.
- Fix: add ledger entries for the speaker-input change (commit `83dc9483`), the two `free_ng` leak fixes
  (`a10defd3`), the `raop.c` double-free null-out (`5c1f5969`), the libairptp shm-name override (`b961398e`)
  and the stream-cap raise (`ffd89914`), and put the dated in-file markers on `airplay_events.c`/`.h` the
  other entries use. Update the "Total vendored files touched" line.
- Confidence: high

### 6. [SUBSTANCE] Shim headers still announce "STUB STATUS" for code that has been the real implementation for a year
- Where: `AirPlayEngine/Sources/CAirPlayEngine/shims/logger.h:19-25`, `shims/outputs.h:38-46`,
  `shims/misc.h:26-35`, `shims/outputs.c:1-25` and `:42-43` and `:1058`, `shims/conffile.c:30-33`,
  `AirPlayEngine/Package.swift:10-14`
- Evidence:
  ```c
  // STUB STATUS (T-BUILD-1): the .c bodies (logger.c) are MINIMAL stubs so the
  // link succeeds — DPRINTF/DVPRINTF/DHEXDUMP currently no-op (or write to stderr).
  // TODO(T-SHIM-1): implement real logging in logger.c
  ```
  (logger.c is 368 lines of os_log + file-rotation routing), and
  ```c
  /* ... For T-BUILD-1 (compile+link only) it is NULL.
   * TODO(T-API-1): set this to the engine thread's event_base before airplay_init runs */
  ```
  (`AirPlayEngine.swift:419` sets it on every start), and Package.swift: "STATUS (T-PKG-1 — scaffold only):
  … the C target does NOT compile yet."
- Why it matters: a reviewer opening the load-bearing shim layer cold is told, at the top of each file, that
  none of it works — so they either distrust correct code or go looking for the real implementation elsewhere.
- Fix: delete the STUB STATUS blocks and the completed `TODO(T-BUILD-1/T-SHIM-1/T-API-1)` markers; keep only
  the two that name genuinely open work (`outputs.c:1058` quality tracking, `transcode.c:22-27` the ffmpeg
  swap), and say what is missing rather than naming a finished task id.
- Confidence: high

### 7. [BUG] `O_CLOEXEC` passed to `fcntl(F_SETFL)` does nothing — the sockets are not close-on-exec despite the comment
- Where: `AirPlayEngine/Sources/CAirPlayEngine/shims/misc.c:188-197`, `:238`, `:358`
- Evidence:
  ```c
  // For Linux we could just give SOCK_CLOEXEC to socket(), but that won't work
  // with MacOS, so we have to use fcntl()
  flags = fcntl(fd, F_GETFL, 0);
  ret = fcntl(fd, F_SETFL, flags | O_NONBLOCK | O_CLOEXEC);
  ```
- Why it matters: `F_SETFL` only sets file *status* flags; close-on-exec is a *descriptor* flag set with
  `F_SETFD`/`FD_CLOEXEC`, so every RTSP/data socket stays open across any `exec` this process makes. The
  comment states the opposite of what the code achieves, which is worse than no comment.
- Fix: keep the `F_SETFL` call for `O_NONBLOCK` only and add `fcntl(fd, F_SETFD, FD_CLOEXEC);` next to it.
- Confidence: high

### 8. [SUBSTANCE] A second `AirPlayEngine` silently steals the C hooks from the first
- Where: `AirPlayEngine/Sources/AirPlayEngine/CompletionRegistry.swift:36`, `:87-92`;
  `AirPlayEngine.swift:1750`, `:1758-1763`; `:1816`, `:1823-1828`
- Evidence:
  ```swift
  static private(set) var shared: CompletionRegistry?
  func install() {
      CompletionRegistry.shared = self
      outputs_engine_completion_set({ callbackId, _, state, _ in
          CompletionRegistry.shared?.deliver(callbackId: callbackId, state: state)
      }, nil)
  ```
- Why it matters: `AirPlayEngine` is a public actor with a public `init`, and nothing prevents a second one.
  The second `start()` (or any `enterHeadlessTestMode()`) overwrites all three `shared` slots, after which the
  first engine's armed ops can only resolve by the 12 s timeout and its state/remote streams go silent, with
  no log line anywhere. The "one engine instance per process in practice" comment is the only guard.
- Fix: make the invariant enforced rather than assumed — in `install()`, log `fault` (or refuse) when
  `shared` is already set to a different instance, so the condition is visible instead of appearing as
  mysterious op timeouts.
- Confidence: high

### 9. [BUG] The arm-collision recovery in `startOp` clears the *other* op's C callback slot
- Where: `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:1554-1560`
- Evidence:
  ```swift
  guard armed else {
      // B5.3: a waiter was already armed for this id ...
      outputs_callback_remove(device)
      cont.resume(throwing: AirPlayEngineError.operationRejected)
      return
  }
  ```
  and the C side (`shims/outputs.c:748-762`): "Match OwnTone: clear EVERY slot for this device."
- Why it matters: this branch runs precisely when a waiter for that id already exists, i.e. when per-id
  serialization was bypassed (finding 3 is one way there). `outputs_callback_remove` then wipes the in-flight
  op's registration too, so its completion arrives at a cleared slot, logs "illegal callback id", and the
  other caller hangs until its 12 s timeout. The recovery path damages the op it was written to protect.
- Fix: clear only the slot this call took — `outputs_callback_clear(cbId)` (already available,
  `outputs.c:764-773`) instead of `outputs_callback_remove(device)`.
- Confidence: high

### 10. [SUBSTANCE] `StreamLevelTracker.snapshot`'s doc contradicts the code: streams never drop out
- Where: `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:2622-2639`
- Evidence:
  ```swift
  /// Reports every stream written since the last call and resets each
  /// window peak; the silence run and write count persist. A stream that
  /// stopped being written drops out on the next call.
  ...
  for id in streams.keys { streams[id]?.windowPeak = 0 }
  return out
  ```
  Nothing removes a key; the dictionary only ever grows.
- Why it matters: the telemetry poller keeps reporting dead streams at the −120 dBFS floor with a frozen
  silence run, which reads as "this stream went silent" forever. The comment is what a reader would trust.
- Fix: either drop entries whose `writes` did not advance since the previous snapshot, or correct the comment
  to say entries persist for the engine's lifetime.
- Confidence: high

### 11. [SUBSTANCE] `engine-probe --password` is parsed, documented, and then thrown away
- Where: `AirPlayEngine/Sources/engine-probe/main.swift:159`;
  `AirPlayEngine/Sources/EngineProbeParsing/ProbeArgParsing.swift:129`, `:251-254`
- Evidence:
  ```swift
  if let pw = d.password { txt["pw"] = "true"; _ = pw }
  ```
  with usage text: `--password <str>        RTSP password, if required`
- Why it matters: the flag advertises a capability the probe does not have — it only marks the device as
  password-protected, which makes `addOutput` throw `passwordRequired`. The `_ = pw` is leftover scaffolding
  standing in for the missing call.
- Fix: either pass the password through to the engine, or delete the flag from the parser and the usage text
  and set `txt["pw"]` from a boolean `--password-protected`.
- Confidence: high

### 12. [SUBSTANCE] `AirPlayEngine.swift` is 2641 lines holding ten types
- Where: `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:1-2641`
- Evidence: the actor plus `StateStreamHub` (:1747), `RemoteEventHub` (:1813), `WriteCadenceTracker` (:1935),
  `WriteBacklogGuard` (:2137), `WriteLatencyProbe` (:2264), `MetricRing` (:2369), `percentileStats` (:2410),
  `WriteSchedulingProbe` (:2457), `StreamLevelTracker` (:2584).
- Why it matters: the actor itself ends at line 1730; everything after is independent, self-contained
  instrumentation with its own locking. A cold reviewer has to page past 900 lines of diagnostics to see the
  lifecycle they came for.
- Fix: move the four diagnostic types plus `MetricRing`/`percentileStats` into `WriteDiagnostics.swift` and
  the two hubs into `EventHubs.swift`, matching how `CompletionRegistry` and `EngineThread` already sit in
  their own files.
- Confidence: high

## Also noted
- `AirPlayEngine.swift:1348-1364` — a `write` whose `enqueue` succeeds but whose body never runs (loop broken
  between schedule and fire) leaks its PCM buffer: untracked closures are not swept by `EngineThread.stop()`.
  Bounded to a few frames per teardown.
- `AirPlayEngine.swift:1079`, `:1092`, `:334` — `try? await t.run(apply)` drops the failure on the volume,
  `stream_id` and start-buffer writes; the op then proceeds against un-applied state rather than failing.
- `AirPlayEngine.swift:2629` — `streams[id]!` inside `snapshot()`; safe today (iterating its own keys under
  the lock) but the only force-unwrap in the package.
- `AirPlayEngine/Sources/CAirPlayEngine/shims/logger.c:221-228` — `engine_log()` caches its `os_log_t` in a
  plain static with no `dispatch_once`; benign double-create, but every neighbour in this file uses the same
  unguarded idiom (`log_threshold`, `mirror_to_stderr`).
- `AirPlayEngine/Sources/ptp-helper/main.c:510-516` — the `gethostname` fallback iterates to `'\0'` on a
  buffer POSIX does not promise is terminated when truncated.
- `AirPlayEngine/Package.swift:50-70` — the manifest shells out to `brew --prefix` at evaluation time;
  deliberate and documented, but it makes package resolution depend on Homebrew being installed and on PATH.

## Counts
BUG: 6 · SUBSTANCE: 6 · COSMETIC: 0 · files read: 22 / files in area: 37
