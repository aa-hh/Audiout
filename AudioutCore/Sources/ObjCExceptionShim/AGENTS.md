# ObjCExceptionShim

## Purpose

A tiny Objective-C target that exists for one reason: Swift's `try`/`catch`
cannot observe `NSException`, but several AVFAudio APIs
(`AVAudioPlayerNode.play`/`scheduleBuffer`/`connect`) and `NSThread.start`
raise `NSException` instead of returning `NSError` — a confirmed crash class
in this app. This is the one place `@try`/`@catch` is allowed to bridge that
gap: a single block-based catcher with no AudioutCore/AVFAudio-specific
knowledge and no dependency on AudioutCore or AirPlayEngine (deliberate, to
keep it minimal and reusable).

**Keep this file up to date** if the catcher's signature changes, if a second
bridging function is added, or if the Swift-facing wrapper moves out of
`AudioutCore/Sources/AudioutCore/ObjCExceptionCatching.swift`.

## Rules

- `AUDCatchObjCException(_:)` in [ObjCExceptionShim.m](ObjCExceptionShim.m)
  converts a caught `NSException` to an `NSError` (domain
  `AUDObjCExceptionErrorDomain`) — treat those key names as a public
  contract.
- **Do not widen the wrapped scope.** Callers must wrap only the specific
  ObjC call that can throw, not a larger block — a wide block risks
  misattributing an exception from unrelated code.
- Swift code never calls `AUDCatchObjCException` directly. The sole call
  site is `catchingObjCException<T>(_:)` in
  `AudioutCore/Sources/AudioutCore/ObjCExceptionCatching.swift`. Add any new
  use of this shim through that function, not by importing
  `ObjCExceptionShim` elsewhere.
