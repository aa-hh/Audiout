# objc-exception-shim-handoff — ObjCExceptionShim: infrastructure to adopt in per-app-routing

Written from `claude/crash-freeze-audit-d27718` (this worktree, post-rename:
`AudioutedCore/*` paths) for the session owning the per-app-routing worktree
(`per-app-routing-engine-73f40c`, pre-rename target names, uncommitted
`LocalPlaybackEngine.swift`). We cannot read that file — everything below
about your code is inference from the audit, flagged as such. This is
**infrastructure to adopt**, not a diff to apply to your tree.

## 1. Why

Four real crashes on 2026-07-18 03:18–03:22: `AVAudioPlayerNode.play()`
raised `NSException` after `AVAudioEngine` asynchronously stopped itself
following a `setDeviceID` call. Swift cannot catch `NSException` at all —
`try`/`catch` only sees Swift/NSError errors, never ObjC exceptions. An
`isRunning` re-check right before the call narrows the window but can't
close it (classic TOCTOU: the engine can stop between the check and the
call). `scheduleBuffer` on a just-detached node raises the same way, same
root cause.

## 2. What exists now, commit `3760b2a`

`3760b2a` — "Phase 1 stability: null-session stop guard, process crash
safety, ObjC exception shim, audit ledger" — verified present in this
worktree's `git log`. It carries, all main-bound:

- `ObjCExceptionShim` target + Swift wrapper (this handoff's subject)
- the A2 engine guard
- D1/D2 bootstrap work
- the audit ledger (`dev/notes/stability-audit-2026-07-18.md`)

**Adoption options, in order of recommendation:**

1. **(Recommended) Wait for this branch to merge to main, then take the
   shim via your next merge-from-main.** No path translation needed — by
   the time you merge, your worktree will already be post-rename or the
   merge will do it for you. Lowest risk, standard cross-session
   convention here.
2. Cherry-pick/merge `3760b2a` directly now. Your worktree predates the
   `AudioutedCore` rename, so this commit's paths (`AudioutedCore/Sources/...`)
   won't line up with your tree's pre-rename layout — you'd need to adapt
   paths by hand (and Package.swift target wiring) as part of the
   cherry-pick. Only worth it if you need the shim before the merge lands.

## 3. Public API (verbatim from committed source)

`AudioutedCore/Sources/ObjCExceptionShim/include/ObjCExceptionShim.h`:

```objc
extern NSString *const AUDObjCExceptionErrorDomain;
extern NSString *const AUDObjCExceptionNameKey;
extern NSString *const AUDObjCExceptionReasonKey;
extern NSString *const AUDObjCExceptionCallStackSymbolsKey;

NSError *_Nullable AUDCatchObjCException(void (NS_NOESCAPE ^_Nonnull block)(void));
```

`AudioutedCore/Sources/AudioutedCore/ObjCExceptionCatching.swift`:

```swift
public struct ObjCExceptionError: Error, CustomStringConvertible {
    public let name: String
    public let reason: String
    public let callStackSymbols: [String]
}

public func catchingObjCException<T>(_ body: () throws -> T) throws -> T
```

Usage:

```swift
do {
    try catchingObjCException {
        player.play()
    }
} catch let error as ObjCExceptionError {
    // treat like a soft engine-not-running failure
} catch {
    // Swift error from body(), rethrown unchanged
}
```

**Documented convention (from the header, follow it):** wrap only the
specific ObjC call that can throw — `player.play()`, one call — never a
wider scope. `AUDCatchObjCException` can't distinguish "this line raised"
from "something else inside the block raised," so a wide wrap misattributes
the exception.

## 4. Recommended adoption sites in your `LocalPlaybackEngine`

We can't read your file, so these are audit-derived guesses at call sites,
not line numbers:

- `player.play()`
- `player.scheduleBuffer(...)`
- `engine.connect(...)`
- optionally `engine.start()`

Wrap each individually in `try catchingObjCException { ... }` and treat a
caught `ObjCExceptionError` the same way you already treat your
`engineNotRunning` soft-fail path — it's the same underlying race
(engine stopped out from under you), just a different exception vs.
error-return surface.

## 5. Second missing piece — yours to build

No `AVAudioEngineConfigurationChange` observer exists yet anywhere. You'll
need one on your engine instance: on notification, hop to your serial
graph queue, mark your engine-running flag false, rebuild (reconnect nodes
with the current `connectionFormat`, restart the engine, re-play through
the shim from §3).

Sketch only — adapt to your actual types/queue/flag names:

```swift
NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange,
    object: engine,
    queue: nil
) { [weak self] _ in
    self?.graphQueue.async {
        self?.isEngineRunning = false
        // reconnect nodes with connectionFormat, engine.start(),
        // re-play via catchingObjCException { player.play() }
    }
}
```

Without this, a device configuration change (e.g. `setDeviceID`, output
device swap) leaves playback silently dead and buffers accumulate at
roughly **1.3 GB/hour** since nothing ever re-primes the graph.

## 6. Full context

See `dev/notes/stability-audit-2026-07-18.md` for the complete crash/freeze
audit ledger this handoff was extracted from.
