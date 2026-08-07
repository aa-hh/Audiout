# Shortcuts / App Intents — implementation research (roadmap 035)

*2026-08-07. Written against Xcode 27.0 (27A5228h), Swift 6.4, macOS 27.
The build-wiring findings are from a spike run today, not from documentation —
see §2. Everything sourced from the web is dated and may move; re-check before
building.*

---

## 1. Verdict

**Build it, tier 1 only. The one thing that could have killed it doesn't.**

The risk was never the intents — it was the build. App Intents only work if the
app bundle contains a `Metadata.appintents` directory, and that is normally
produced by an **Xcode-only build phase** ("Extract App Intents Metadata").
Audiouter has no Xcode project: it is `swift build` plus a hand-rolled bundle in
`scripts/make-app.sh`. Apple's own DTS answer to "my intents are in an SPM
package and don't show up" is that SPM does not perform the metadata extraction
step at all.

Spiked it today. It can be done from `make-app.sh` in two added steps, and I
verified each one produced the real artifact. Details in §2.

The remaining unknown is narrow: whether Shortcuts.app *lists* actions from a
hand-rolled, ad-hoc-signed bundle. Everything up to that point is confirmed
working. That is a five-minute live check, not a research question — do it
first, before writing any real intents.

---

## 2. Build wiring — what the spike actually proved

A scratch SwiftPM package with one `AppIntent` and one `AppShortcutsProvider`,
built and bundled exactly the way `make-app.sh` does it.

**Step 1 — make the compiler emit const values.**
The metadata processor's input is `.swiftconstvalues` files, which the Swift
compiler only writes when asked.

- The **default** build system (`swiftbuild`, the Xcode engine) already passes
  `-emit-const-values-path` and generates its own protocols list. Free.
- **`--build-system native` does not** — zero `.swiftconstvalues` files. This
  matters, because `make-app.sh:182` pins `native` deliberately: the new engine
  does not forward `CAirPlayEngine`'s Homebrew `-I` paths into the clang module
  scan, so `swiftbuild` cannot build this package at all today.
- Confirmed working: `native` **plus** explicit flags. One `.swiftconstvalues`
  file appeared for the target.

```
swift build --build-system native -c release --product AudiouterApp \
  -Xswiftc -emit-const-values \
  -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
  -Xswiftc -Xfrontend -Xswiftc "$REPO/scripts/appintents-protocols.json"
```

`appintents-protocols.json` is a checked-in JSON array of the protocol names to
gather conformances for — `AppIntent`, `AppEntity`, `AppEnum`,
`AppShortcutsProvider`, `EntityQuery`, `EntityStringQuery`,
`DynamicOptionsProvider`, `PersistentlyIdentifiable`, and friends. Xcode
generates this file itself; here it is ours to maintain, which is a small
standing cost — a new App Intents protocol Apple adds later will be silently
ignored until someone adds it to the list.

**Step 2 — run the processor and drop the result in the bundle.**
`appintentsmetadataprocessor` ships in the toolchain and takes plain arguments,
so it runs fine outside Xcode:

```
"$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor" \
  --output "$APP/Contents/Resources" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name AudiouterApp \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | tail -1 | awk '{print $3}')" \
  --platform-family macOS --deployment-target 14.0 \
  --target-triple arm64-apple-macos14.0 \
  --source-file-list srcs.txt --swift-const-vals-list consts.txt --force
```

It wrote `Metadata.appintents/{extract.actionsdata,version.json}`. The JSON
contains the intent under its fully qualified name, its parameter with resolved
types, `openAppWhenRun`, and the App Shortcut — i.e. real metadata, not a stub.

**Step 3 — bundle and register.** Copied `Metadata.appintents` into
`Contents/Resources/`, ad-hoc signed the bundle, ran `lsregister -f`.
LaunchServices picked the app up cleanly. This must run **before** the codesign
pass in `make-app.sh` (~line 613 onward), or the signature won't cover it.

**Two consequences worth knowing up front:**

- Intents will exist only in bundled builds. `swift run AudiouterApp` won't have
  them. Same shape as the TCC constraint, so it is a familiar rule, but it means
  every intent change needs a `make-app.sh` round trip to test.
- The processor step is another place `make-app.sh` can fail on an Xcode
  upgrade. Keep it non-fatal-with-a-loud-warning rather than hard-failing the
  bundle, so a toolchain change can't block shipping an unrelated fix.

---

## 3. Constraints that shape the design (not negotiable)

- **`AppShortcutsProvider` and every intent backing an App Shortcut must live in
  the main app target.** Apple DTS is explicit: intents in a framework or
  package cannot back App Shortcuts. So the intent types go in
  `Sources/AudiouterApp/`, calling into `AudiouterCore` — not in `AudiouterCore`
  itself. `AudiouterApp` is currently 5 files; this roughly doubles it.
- **Maximum 10 App Shortcuts per app**, and every trigger phrase must contain
  the `\(.applicationName)` placeholder. (There is also a 1000-phrase ceiling
  where each parameter option counts — irrelevant at our scale.)
- **Intents run inside the app's process**, so macOS launches Audiouter if it
  isn't running. For a menu-bar app that is the behaviour you want anyway.
- The controllers the intents will call (`GroupController`,
  `AppRoutingController`, `PopoverController`) are `@MainActor`. Intent
  `perform()` is async — hopping to the main actor is the normal pattern, but
  every intent becomes a new entry point into main-actor state that previously
  only the UI touched. Worth a look for reentrancy against the existing
  single-owner rules.
- macOS 14 minimum is already well past App Intents' macOS 13 floor. No gate.

---

## 4. How deep to go — recommended scope

### Tier 1 — ship this

Six verbs, two entity types. Everything here is a thin wrapper over a controller
call that already exists.

| Intent | Parameters |
|---|---|
| Activate Group | group |
| Set Main Volume | 0–100 |
| Set Speaker Volume | speaker, 0–100 |
| Mute / Unmute Speaker | speaker, on/off |
| Select / Deselect Speaker | speaker, on/off |
| Disconnect All Speakers | — |

Two `AppEntity` types with an `EntityQuery` each — `SpeakerEntity` and
`GroupEntity` — so Shortcuts shows the user's **real** speakers and saved groups
in a picker instead of asking them to type a name. This is the single biggest
quality difference between an App Intents integration that feels native and one
that feels like a scripting hack, and it is most of the work in tier 1.

Plus, **decided into v1** (§7): **Route App to Speakers**, taking an app and a
set of speakers. Needs a third `AppEntity` for running apps.

### Tier 2 — after the matching features land

"Apply Scene" (one intent, needs 037) · set per-device trim (033) · set
per-device EQ (034) · start sleep timer (036).

### Not doing

A public HTTP/WebSocket API. Already an explicit anti-candidate in the parity
brief: it is a versioned protocol commitment plus a LAN security surface, and
App Intents serves most of the same jobs Mac-natively. Revisit only if
Home-Assistant-style demand shows up for Audiouter specifically.

---

## 5. "Should we ship sample shortcuts?" — yes, but they're two different things

**App Shortcuts (`AppShortcutsProvider`) — do this. It IS the sample-shortcuts
answer.** These are canned shortcuts the system creates for you: they appear in
the Shortcuts app under Audiouter automatically, need no user setup, are
Siri-speakable, and show up in Spotlight. Free once the intents exist.

Pick 3–5 of the 10 allowed, one line each, e.g.:

- "Play everywhere with Audiouter"
- "Set Audiouter volume to 30"
- "Turn off Audiouter speakers"

**Bundled `.shortcut` files — skip at v1.** Multi-step recipes ("movie night:
kitchen + living room at 40%") cannot be embedded and auto-installed. Apple's
distribution paths are iCloud share links (Apple notarizes them) or `.shortcut`
files the user opens by hand. If it is ever wanted, it's a Settings pane with a
few links plus a docs page — a content task, not code. Don't gate v1 on it.

---

## 6. The companion-app instinct is right, with one caveat

App Intents is the surface Apple actively pushes (Shortcuts, Spotlight, Siri,
Action Button), and adopting it is a genuine positive signal for an App Store
submission rather than just a feature.

Caveat on reuse: shared *logic* can live in a package, but because App
Shortcut-backing intents must be in each app's main target, the iOS companion
needs its own thin intent wrappers rather than importing Audiouter's. And an iOS
intent has to reach the Mac over the existing private companion protocol, so it
is downstream of 005, not free with it.

---

## 7. Decisions — settled by Alec, 2026-08-07

1. **Verb list: tier-1 six PLUS per-app routing.** "Route this app to these
   speakers" is in v1. That pulls in a third entity type for running apps, and
   with it three questions the other entities don't have: how an app is
   identified (bundle id, presumably, matching `AppRouteStore`), what the intent
   does when the named app isn't running, and how it interacts with the
   exclusion rules in `AppRoutingController`. Budget for this being the largest
   single piece of the work, not a seventh easy verb.
2. **Siri phrases: none — Shortcuts app only.** So **no
   `AppShortcutsProvider`**, no canned shortcuts, no spoken phrases, and the
   10-shortcut and phrase ceilings stop mattering. Plain App Intents still
   appear as actions in the Shortcuts app under Audiouter, which is the target.
   Consequence: the actions are *not* discoverable — nobody finds them unless
   they open Shortcuts and look, so this needs a line in the docs or Settings
   pointing at it, or it effectively ships invisible.
   Keep the intents in the main app target anyway (§3): dropping
   `AppShortcutsProvider` technically relaxes that rule, but intents in a
   statically-linked SPM library are exactly the configuration Apple DTS
   describes as not working, and splitting them out would mean merging metadata
   across modules via `--static-metadata-file-list` for no benefit.
3. **Engine not running: auto-start capture, and the intent carries the
   volume.** The intent connects and starts streaming rather than failing.
   Auto-start alone would have made roadmap 018 (connect-volume seed /
   anti-blast) a hard prerequisite — an automation pulling audio to speakers
   with nobody present, at whatever level the connect path seeds, is how you get
   a 3 a.m. full-volume incident. Alec's answer: **give the intent a required
   volume parameter**, so the automation states its own level and never inherits
   a default. See §7a — the plumbing already exists, and this removes the 018
   dependency for the automation path.
4. **Speaker identity: stable device id, display name as the title.** Taken as
   the obvious default rather than asked — a name-keyed shortcut silently breaks
   the moment a speaker is renamed. Cost is a stale picker entry when hardware
   is replaced, which is the better failure.

## 7a. The volume parameter — verified, and it's a small change

The idea only works if the level lands **at** the connect, not after it.
Set-the-volume-afterwards would leave a window where audio plays at the seeded
level and then drops, which is exactly the blast you were trying to avoid.

Checked the code. It lands at the connect:

- `NativeBackend.connectVolumeSeed` (`NativeBackend.swift:6624`) runs on
  `stateQueue` during the connect and `pushVolume()`s the level as part of it.
  No window.
- Its source is already injectable — `connectVolumeProvider`, a `@Sendable`
  closure (line 93), reading `AppSettings.connectVolume` in production — and
  there is already a per-id marker for "the user asked for this connect",
  `userConnectSeed` (line 683), a `Set<String>`.
- Values are already clamped to `AppSettings.minConnectVolume ...
  maxConnectVolume` (5…100), so an intent's number inherits the same safety net.

**The whole change:** make `userConnectSeed` a `[String: Int]` so a caller can
attach a level to a specific pending connect, and have `connectVolumeSeed`
prefer that over `connectVolumeProvider()`. One edit in the shared function
rather than a guard at every caller. A per-connect value also avoids the race a
global mutation would create between two concurrent intents, or an intent and a
UI click.

**Hard condition:** the volume parameter must be **required** on every intent
that can auto-start. Optional-and-omitted falls straight back to the global
default and the hazard returns.

**What this does and doesn't do for 018.** It resolves the automation path, so
035 no longer depends on 018 (dependency removed). 018 still owns the ordinary
case — the user clicks a speaker in the popover and nobody specified a level —
and stays open on its own merits.

## 7b. This also buys scenes early (roadmap 037)

Once the per-speaker verbs exist, a user can hand-author a shortcut that *is* a
scene — "kitchen 30, living room 40, activate Movie Night" — with no app support
at all. That covers replaying a known state, which is most of what people want
from profiles, and it is a good reason to ship the granular verbs rather than
only coarse ones.

It does not cover **snapshotting**: save what I have set up right now, under a
name. That is 037's actual value and no amount of hand-authoring substitutes for
it. So this defers 037 rather than closing it, and the snapshot half is what is
left to build. Recorded on the entry.

---

## 8. Live check to run first

Build any throwaway intent through the §2 wiring, put the bundle somewhere
normal (`/Applications`, not `/tmp`), and confirm Shortcuts.app lists it under
Audiouter. Forum reports say a **Mac restart** is sometimes needed before a
newly built app's intents appear the first time — so a blank Shortcuts list is
not proof of failure until after a restart. If it doesn't appear even then, the
fallback is adding a minimal Xcode project for the app target, which is a much
bigger change to the build and would reset this recommendation.

---

## Sources

- [App Intents (Apple)](https://developer.apple.com/documentation/appintents) ·
  [AppShortcutsProvider](https://developer.apple.com/documentation/appintents/appshortcutsprovider) ·
  [Adopting App Intents for system experiences](https://developer.apple.com/documentation/AppIntents/adopting-app-intents-to-support-system-experiences)
- [DTS: App Intents in an SPM package don't show in Shortcuts](https://developer.apple.com/forums/thread/759160) — the main-target and metadata-extraction constraints
- [App Intents do not appear in macOS Shortcuts app](https://developer.apple.com/forums/thread/743121) — restart-required reports
- [App Shortcuts limitations](https://developer.apple.com/forums/thread/807411) · [AppShortcuts limit](https://developer.apple.com/forums/thread/795383) — 10-shortcut and phrase ceilings
- [appintentsmetadataprocessor in Xcode 16 (Marc Palmer)](https://marcpalmer.net/changes-in-app-intents-pre-processing-causing-confusing-errors-in-xcode-16/)
- [Develop for Shortcuts and Spotlight with App Intents — WWDC25](https://developer.apple.com/videos/play/wwdc2025/260/)
- [Share shortcuts on Mac (Apple Support)](https://support.apple.com/guide/shortcuts-mac/share-shortcuts-apdf01f8c054/mac)
