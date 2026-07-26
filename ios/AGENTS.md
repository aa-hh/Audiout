# ios/AudiouterRemote

## Purpose

The iOS companion app: a SwiftUI client that discovers a Mac running
Audiouter's companion server on the local network and remote-controls it
(speakers, per-app routing, groups). It has no audio path of its own — it is
a thin remote.

## Rules

- **`AudiouterRemote.xcodeproj/project.pbxproj` is edited by hand exactly
  once (T10) and never touched again.** Both targets use a
  `PBXFileSystemSynchronizedRootGroup` for their source folder
  (`AudiouterRemote/`, `AudiouterRemoteTests/`): adding, removing, or
  renaming a `.swift` file in either folder is picked up automatically by
  Xcode/xcodebuild on the next build — no project file edit needed. If a
  change seems to require touching the `.pbxproj` (new target, new package
  dependency, new build setting), stop and reconsider; that is the one case
  this structure doesn't cover for free.
- **Local package dependency: `AudiouterProtocol` only.** Never depend on
  `AudiouterCore` from anything under `ios/` — its `Package.swift` shells out
  to `brew --prefix` to locate AirPlayEngine's C dependencies, which does not
  exist on iOS and will break the build in ways that look unrelated.
- **iOS 18.0 deployment target, iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`);
  iPad runs it in compatibility mode automatically, no separate iPad
  idiom/layout work.
- **Guard 4 (`.githooks/pre-commit`) does not run these tests.** It only
  triggers on `AudiouterCore/{Sources,Tests}` Swift files, and there is no
  equivalent iOS guard. Run the test command below explicitly before
  committing iOS changes.

## Build / test

Build for the simulator:

```
xcodebuild -project ios/AudiouterRemote/AudiouterRemote.xcodeproj -scheme AudiouterRemote -destination 'generic/platform=iOS Simulator' build
```

Run tests on the simulator — a working runtime IS installed on this Mac
(don't trust an earlier report that none was; that was a sandbox visibility
artifact). Pick an installed device with `xcrun simctl list devices
available`; today that's the iPhone 17 family:

```
xcodebuild test -project ios/AudiouterRemote/AudiouterRemote.xcodeproj -scheme AudiouterRemote -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Map

- `AudiouterRemote.xcodeproj` — hand-authored Xcode project (T10), modern
  `objectVersion 77` format.
- `AudiouterRemote/` — app target source (synchronized folder): entry point,
  `RootView` 4-tab shell, `Views/` placeholders, `Info.plist` (merged with
  `GENERATE_INFOPLIST_FILE` for the two privacy keys `xcodebuild` can't
  express as `INFOPLIST_KEY_*` build settings).
- `AudiouterRemoteTests/` — unit test target source (synchronized folder).
