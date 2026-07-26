# ObjCExceptionShim

## Purpose

A tiny Objective-C target that exists for one reason: Swift's `try`/`catch`
cannot observe `NSException`, but several AVFAudio APIs
(`AVAudioPlayerNode.play`/`scheduleBuffer`/`connect`) and `NSThread.start`
raise `NSException` instead of returning `NSError` — a confirmed crash class
in this app. This is the one place `@try`/`@catch` is allowed to bridge that
gap. It has no AudiouterCore- or AVFAudio-specific knowledge; it is a single
block-based catcher.

**Keep this file up to date** if the catcher's signature changes, if a second
bridging function is added, or if the Swift-facing wrapper moves out of
`AudiouterCore/Sources/AudiouterCore/ObjCExceptionCatching.swift`.

## Notable Patterns

- `AUDCatchObjCException(_:)` in [ObjCExceptionShim.m](ObjCExceptionShim.m)
  runs a `NS_NOESCAPE` block inside `@try`/`@catch` and converts any caught
  `NSException` into an `NSError` (domain `AUDObjCExceptionErrorDomain`),
  carrying the exception's name, reason, and call stack symbols under
  `AUDObjCExceptionNameKey` / `AUDObjCExceptionReasonKey` /
  `AUDObjCExceptionCallStackSymbolsKey`. Returns `nil` on normal completion.
- **Do not widen the wrapped scope.** Callers must wrap only the specific
  ObjC call that can throw, not a larger block — `AUDCatchObjCException`
  can't tell which line inside the block raised, so a wide block risks
  misattributing an exception from unrelated code.
- Swift code never calls `AUDCatchObjCException` directly. The sole call
  site is `catchingObjCException<T>(_:)` in
  `AudiouterCore/Sources/AudiouterCore/ObjCExceptionCatching.swift`, which
  wraps the ObjC result into `ObjCExceptionError` (a Swift `Error`) and
  rethrows Swift errors from `body` unchanged. Add any new use of this shim
  through that function, not by importing `ObjCExceptionShim` elsewhere.

## External Dependencies

None beyond `Foundation`. This target has no dependency on AudiouterCore or
AirPlayEngine — that's deliberate, per the header comment, to keep it
minimal and reusable.

## Tests

No tests live in this folder. Coverage is in
`AudiouterCore/Tests/AudiouterCoreTests/ObjCExceptionCatchingTests.swift`,
which exercises the Swift-facing `catchingObjCException` wrapper rather than
this target directly.
