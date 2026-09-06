# Design review: Mac and shared-package tasks of PLAN-REMOTE-RELEASE

2026-09-06. Scope: T1, T2, T3, T13, T14, T15, T16, T17, T18, T19. Vocabulary is the codebase-design skill's (module, interface, seam, adapter, depth, leverage, locality) and the glossary in `audiout-shared/CONTEXT.md`. Paths are relative to each repo root: `mac` is this repo, `shared` is audiout-shared (the branch `claude/ftu-optimization-differentiation-5b027d`, one commit past `main`), `phone` is audiout-remote. Every line number below was read in source this session.

## 1. Task by task

### T1 (shared): sweeps 6 dB down, 80 ms fades

**Anchor.** `Sources/ProbeKit/SyncProbeCorrelator.swift:64-87` is `SweepDesign`; the two factories `upSweep` (`:76-79`) and `downSweep` (`:83-86`) carry `fadeDuration: 0.01`. That is the right seam for the fade.

**The level is not in the package and should not be.** `SweepDesign` has no amplitude field (`:64-73`); `samples(_:)` renders at unit amplitude (`:116-125`). The level is set where the sweep is staged, on the Mac: `AlignmentTickInjector.stageProbe(amplitude: Double = 0.35, ...)` at `mac AudioutCore/Sources/AudioutCore/AlignmentTickInjector.swift:432-447`, and both callers take the default (`NativeCaptureCoordinator.swift:1427` for the Mac's own wizard, `:1459-1462` for the phone-driven run). The phone never plays the sweep; it only recreates the two templates to correlate against (`ProbeAnalyzer.swift:102-105`, called from `phone AudioutRemote/Model/ProbeSession.swift:241-242`). The confidence gate is a ratio of peak to expected sidelobe (`SyncProbeCorrelator.swift:254-257`), and both terms scale linearly with template amplitude, so a template level is invisible to the measurement. A package `amplitude` field would have exactly one real consumer: a hypothetical seam.

**The fade does belong here, and one edit covers every renderer.** Three places render the templates and all take the factory defaults: the Mac's staging (`AlignmentTickInjector.swift:438-447`), the Mac's own microphone analysis (`MicProbeSession.swift:311-314`), and the phone's (`ProbeAnalyzer.swift:102-105`). Deletion test on the two factories: remove them and the band edges and fade get typed at three call sites in two repositories, which is the hand-copy the package exists to prevent. Deep module, correctly placed.

**The test fallback cannot fire.** `ProbeKitTests` place arrivals at their own gains (`SyncProbeCorrelatorTests.swift:249-260`: 0.0395 and 0.00268) and assert PSR at or above 5 with peaks in the hundreds (`:270-271`); the level never enters the package. The fade moves about 8 percent of the sweep's energy into the taper (80 ms raised-cosine each end of 1 s), well under a decibel, so `swift test` will pass either way. The 6 dB versus 3 dB decision is a live listen on the Mac with a real speaker, not a package test. The one package test that touches the fade, `sweepSamplesMatchTheAnalyticFormAndStayBounded` (`:84-95`), uses a private 10 ms design and is unaffected.

**ADR 0001 (shared) needs an amendment**: "in this package, so the phone's local copy of the sweep and the Mac's staged sweep stay identical by construction" is true of the fade and false of the level. The level change ships in the Mac (see T13).

### T2 (shared): a source for the applied offset

**Anchor.** `Sources/AudioutProtocol/CompanionSnapshot.swift:43-81`, `DeviceState.AlignmentState`. Correct.

**Additive, confirmed.** `AlignmentState` is synthesized `Codable`. An `Optional` field with a defaulted `init` parameter is what every earlier addition did (`alignment` at `:97-100`, `memberNames` at `:142-149`, `masterVolume` at `:150-155`, `clockState` at `:66`). An older peer ignores the unknown key; a newer peer decodes a missing key as `nil`. The compatibility test to copy is `deviceStateWithoutAlignmentKeyDecodes` at `Tests/AudioutProtocolTests/CompanionMessageTests.swift:251-258`.

**No `CompanionProto.version` bump.** `CompanionProto.swift:10-16` bumps only when an existing case's meaning changes in a way an old peer misreads. Two `staleReason` values stop being sent (`"reconnected"` becomes `source: "fromLastTime"`, `"measuredWhileSettling"` becomes `source: "firstPass"`); `"moved"` stays. No value changes meaning; two retire. An older phone would render a reconnected speaker as a plain tuned row, which is what the Mac is doing. No phone has shipped, so there is no older peer anyway.

**Shape.** See section 3 for the exact proposal. The phone consumers to move in T7: `SyncSheet.swift:891-921`, `DeviceRowView.swift:772-778`, `DemoMacSession.swift:69, 453-530`.

**Drop the `settleLog` sentence.** D11 puts the log on the Mac (local file in debug, PostHog in release). T8 is haptics and motion; nothing on the phone displays a settle record. A message with no renderer is a seam with one adapter. Skip it.

### T3 (shared): tag 0.9.0

The branch is one commit ahead of `main` (`3979365`, glossary and ADR); `main` sits at `3f20742` which is tag `0.8.1`. The tag must be cut on `main` after the T1 and T2 commits merge. Pins today: Mac `AudioutCore/Package.swift:176` `from: "0.8.1"` and `Package.resolved` revision `3f20742`; phone `AudioutRemote.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` at `0.8.0` (`723399b`), so T4 moves the phone two tags, picking up the `AudioutField` resource-bundle fix too (harmless for the phone). The fade change is a measurement change: both pins bump the same day or the two ends correlate against different signals.

### T13 (mac): pin 0.9.0; sweep length unchanged

Anchors correct: `AudioutCore/Package.swift:176`, `Package.resolved:9-10`, `AlignmentTickInjector.probeSweepSeconds` at `:370`. The length has three copies, all 1.0 and all unchanged: that one, `MicProbeSession.sweepSeconds` (`:181`, pinned equal by `MicProbeSessionTests.swift:145`), and `ProbeAnalyzer.sweepSeconds` in the package.

**Add the level here.** The 6 dB drop is the `amplitude` default at `AlignmentTickInjector.swift:432` (0.35 to 0.175), best as a named constant beside `probeEngineLaneScale` (`:470`) so the number is stated once. Both staging calls take the default. The Mac's own wizard stacks the existing lane scale on top (`:440-445`, near lane at 0.5), so its Mac lane lands at 0.0875 peak; the 2026-08-28 capture measured that lane 57 dB over the floor with 14 needed (`:419-420`), so the headroom holds. The fallback to 3 dB is decided by ear on hardware, not by `swift test`.

### T14 (mac): reconnect applies the remembered offset

**The plan's premise is off.** The stored offset is already applied on reconnect. `NativeBackend.swift:1641-1646` loads both maps at init, and every arm re-pushes them to the sink (`:8670-8673`). `BTAlignmentFreshness` never decides what plays; it decides what the phone is told (`report(uid:hasStoreEntry:now:)` at `BTAlignmentFreshness.swift:309-327`, the pure `status(...)` at `:344-352`: store entry plus `lastConnectedAt > alignedAt` is `.stale`). So T14 is a change to what the Mac publishes and to the replace rule, not to what it applies. Rewrite the first clause.

**Where each piece lives today.**
- Reconnect edge: `noteConnected` from three sites (`NativeBackend.swift:3925`, `:8643`, `:8682`); the freshness store collapses echoes (`:133-149`).
- "First pass" already exists as `measuredWhileSettlingUIDs`, decided inside `noteAligned` from the clock verdict (`:196-209`). It becomes `source: "firstPass"` with `status: "tuned"`.
- "Moved" (`:256-269`) stays a `staleReason`.
- The apply path: `applyCompanionAlignmentMeasurement` at `:11112-11178` computes `corrected = snap(applied + (offsetMs - stagger))` and clamps (`:11128-11131`), then writes through `endBTWizardLatencyPreview(forDevice:keepMs:)` (`:11456-11490`), which the Mac's own wizard Keep also uses.
- The wire builder: `CompanionSnapshotBuilder.alignmentState(for:...)` at `:237-252` (the plan's `:236-250` is inside it).

**The 10 ms rule** belongs at the one point a measurement becomes a stored value, before `endBTWizardLatencyPreview` at `:11171`: if `|corrected - applied| < 10` keep `applied` and return `correctedMs: 0`. **The 40 ms line needs no wire field**: `alignmentApplied` already carries `correctedMs` (`CompanionMessage.swift:59-66`), and the phone's verdict copy reads `abs(correctedMs) >= 40`. The 10 ms constant is the Mac's; the 40 ms constant is the phone's; the ADR is the one source for both.

**Piecemeal or deep.** As written the task names three files and lands as edits in four places (freshness report, snapshot builder, apply path, plus the phone). It becomes one module change if `BTAlignmentReport` gains the source and the replace rule sits behind the same interface the apply path already calls. Section 2 designs that module. The test surface is already the interface: `BTAlignmentFreshnessTests.swift` has 26 tests and 89 calls through `report`/`noteConnected`/`noteAligned`/`noteClockOutcome`; the ones asserting `.stale` with `"reconnected"` are rewritten, not layered (DEEPENING.md, replace don't layer).

### T15 (mac): per-connection settle log

**What exists.** The local half is mostly there. `Telemetry.log` (`Telemetry.swift:35-66`) is an always-on JSON-lines file under `~/Library/Logs/Audiout/`, and the apply path already writes `bt_align_measurement` (`NativeBackend.swift:11142-11155`), `bt_align_recheck_after_early` (`:11162-11167`) and `wizard_keep` (`:11484-11490`). The release half has its port: `Analytics.capture` (`Analytics.swift:70-76`) is a no-op without consent and the PostHog adapter is installed only in the executable (`AppDelegate.swift:118-129`). Event naming precedent is `bt_sync:*` (`PopoverController.swift:4788, 4948, 5131, 5152`).

**What is missing per field.**
- Jump count: nothing counts jumps. The freshness store keeps a seen-jump flag (`:111`), seconds of jump-free advance (`:104`) and a summed magnitude since the last alignment (`:106`). A per-link counter goes beside them, reset in `noteConnected` (`:139-144`), incremented in the `.jumped` branch (`:256-259`).
- Time to settle: `lastConnectedAt` (`:136`) to the first sample where `stableForSeconds` reaches `BTClockStability.stableAfterSeconds` (`:252-255`).
- Settled offset: the first measurement applied while the verdict is steady. It only exists when someone re-checks, so a connection record is assembled over time and emitted once.
- Codec: no reader exists. `AirPlayHandoffWatcher.swift:1-60` is the precedent for tailing the unified log through an injectable subprocess seam. This Mac's unified log holds no `bluetoothaudiod` line at all over 14 days (`log show --last 14d --predicate 'process == "bluetoothaudiod"'` returned nothing), so the line the research note relies on is unverified. Keep `codec` optional, prove the line on a live connection before writing a subprocess, and drop the field if the line is private.
- Speaker: the Core Audio UID is derived from the MAC address (`BTTrimStore.swift:84`). Fine in the local file; not fine on the wire to PostHog.

**Consent.** The plan's "same opt-out as the usage-counts card" is the right switch but the wrong word: on the Mac it is opt-in, off by default (`GeneralSettingsViewController.swift:235-245`, `PRODUCT.md:66`); D12's on-by-default is the phone. Two consequences the plan must state. First, T23's twenty reconnects come from the owner's own local log, never from PostHog. Second, the card's promise (`UsageStatsConsentCard.swift:151-154`: "It counts which features get used, and notes your Mac, macOS version, city, and whether Audiout is licensed. What you play, and what your speakers are called, never leave this Mac.") was audited against a real ingested event (`:140-142`). A settle event adds a codec, an offset and a speaker identifier. Send a per-install salted hash of the UID (CryptoKit SHA-256 over `installID + uid`, truncated) plus `bluetoothDeviceClassMinor` (`NativeBackend.swift:8675`) as the model hint, and amend the card body and `consentHintLine` in the same change, or the promise and the payload part company again.

**Seam.** The three inputs already meet in two places (the freshness store for jumps and settle, the apply path for the offset). One module owning the per-connection record, its local line and its anonymised event is the deep shape; section 2 places it. Deletion test: without it, record assembly spreads over the connect edge, the clock-outcome fold and the apply path, with the emit rule copied into each.

### T16 (mac): invites in four places

**Chip anchor is wrong.** `PopoverController.swift:4640-4646` is the delegate hop `deviceRow(_:didRequestAlignmentWizardFor:door:)`. The chip is in `AudioutSharedUI/DeviceRowView.swift:1974-1992` (`updateSyncChip`: title `"Align"` when `chipOffersWizard`) and `:2080-2086` (`syncChipTapped`, door `.chip`); the wizard starts in `PopoverController.startBTAlignmentWizard(deviceID:door:)` at `:4799`. The menu item reads `"Align speaker…"` (`:2157`). D3's "Align by ear" wording applies to both and is in neither T16 nor T17: add it.

**The chip is one `NSButton`.** Offering "Measure with your iPhone" ahead of "Align by ear" makes the tap open a small menu or popover rather than a wizard. Build the invite once: a single view with the QR, the link and the copy, hosted three times (chip popover, under the Allow switch, first-run card). That is the module for T16; three hosts are three adapters at one seam. No QR generator exists in the Mac (`CIQRCode` appears nowhere); `CIFilter.qrCodeGenerator()` from CoreImage is the platform feature and needs no dependency. `import CoreImage` appears nowhere yet, so it lands in that one view in a UI target.

**Allow switch anchor is right** (`GeneralSettingsViewController.swift:217-220`), **but its default is already ON.** `AppSettings.swift:328-341` returns `true` when unset, dated 2026-08-06 as the T22 flip. Delete that clause; `PLAN-COMPANION-APP.md:370-371` describes work that landed.

**Seventh first-run card.** `OnboardingViewController.swift:668-813` is `content(for:)`; the plan's `:675-811` is inside it. A new `SetupStep` case (`SetupFlowModel.swift:9-15`) is switched exhaustively at 14 sites (4 in `SetupFlowModel.swift`, 8 in `OnboardingViewController.swift`, 2 in `DemoPaneView.swift`) plus `isComplete` (`:207-214`), a stage rehearsal view, and a `Tokens.Color.permission*` hue. That spread is the existing design and the compiler enforces every site, so it is the right seam, but the plan should size it: model the card on `.usageStats` (skippable, complete once seen), and have its rehearsal host the same invite view.

### T17 (mac): Scene wording

**Stale.** The strings named do not exist. `GroupEditorViewController.swift:388` `backButton.title = "Scenes"`, `:360` `"Delete scene…"`, `SidebarViewController.swift:217` `"Add scene"`, `GroupCreationSheetController.swift:214` `"Add scene"`, `GroupsOverviewViewController.swift:65` `"Scenes"`, `PopoverController.swift:2317` `"Scenes"` header, `AppDelegate.swift:1884` menu `"Scenes"`, `DeviceDetailViewController.swift:655` `"Not in any scene"`, `CompanionCommandDispatcher.swift:368` "maximum of 64 scenes". A sweep of quoted strings across the six UI targets finds no user-facing "Group" left; what remains is doc comments and harness messages (`window-harness/main.swift:244`). Two things stay in scope: the tooltip at `DeviceRowView.swift:1899` ("the rest of the group", about a set of speakers, arguably fine) and the D3 rename of `"Align"` and `"Align speaker…"` to "Align by ear" (`DeviceRowView.swift:1982, 2157`). Retitle T17 accordingly or fold it into T16.

### T18 (mac): review kit rewrite

Anchors mostly right: demo path `:16-23`, the tab list `:17` (its "Groups" becomes Scenes under D16), screenshots `:67-75`, naming `:101-117`. Two are off: the free-Mac claim is `:10-11`, not `:9`; and `PRICING.md:3` is `docs/PRICING.md:3`. Two are missing: `:14` "No data is collected" and §4 `:77-85` "Data Not Collected" both contradict D12 and must become "Product Interaction, not linked to you"; §8 `:119-133` cites the companion plan's T20, T22, T23 and reads as future work that is done or superseded.

### T19 (mac): cut the Mac release

`c96f2901` added `scripts/release.sh`, the `make-app.sh` bundle-count guard and rewrote `docs/RELEASE.md`. Cite the script and `docs/RELEASE.md:20-45` rather than a hash. **Hidden prerequisite:** gate 2 of the script (`scripts/release.sh:77-93`) refuses while any production D1 migration is unapplied, and the commit message records `0005_remote_signups.sql` as unapplied in production today (the file exists at `Audiout License Server/migrations/0005_remote_signups.sql`). Applying it is owner-only and belongs with T21's licence-server work. The script also refuses on a dirty tree or a `main` behind `origin/main`, so T13 to T16 must be merged and pushed first.

## 2. Design it twice: the Mac's remembered-offset and settle-log module

### The problem space

One module has to own four things the ADR ties together: what the Mac publishes about a Bluetooth speaker's applied offset (measured, first pass, from last time) and when the phone may offer a re-check; the rule that a re-measurement replaces the stored offset at 10 ms or more and keeps it below; the per-connection settle record (speaker, codec, jump count, time to settle, settled offset) and its two destinations; and the read the snapshot builder makes per device on every rebroadcast.

Constraints any interface must meet: the stored offset is already applied on reconnect, so the module publishes and decides, it never pushes audio; the phone's Measure button, the first-pass mark and the re-check offer all key off one clock verdict (`BTAlignmentFreshness.clockState`, `:335-340`), so that verdict must stay the single source; writers arrive on three queues (`NativeBackend.stateQueue`, the main actor, each sink's clock-watcher queue) behind one lock (`:96`); two link-up observers report the same link and must collapse to one instant (`:125-149`); nothing may run on the render thread; and the release event may carry no speaker name and no raw UID (`UsageStatsConsentCard.swift:151-154`; the UID is MAC-derived, `BTTrimStore.swift:84`).

Dependencies, classified per DEEPENING.md: the clock detector `BTClockStability` and the per-speaker timestamps are in-process (category 1), merged and asserted directly. `BTTrimStore` is local-substitutable (category 2, injectable directory, `:127`). `Telemetry` is category 2 through `_installTestSink` (`Telemetry.swift:98`). `Analytics` is true external (category 4) and already sits behind the `Analytics.Sink` port (`Analytics.swift:28-37`) with the PostHog adapter installed only in the executable and a closure adapter in tests: a real seam by the two-adapter rule. The codec reader is category 4 (the OS's unified log); the port exists as `LogStreamSpawning` (`AirPlayHandoffWatcher.swift`) with a production adapter and test doubles in eight test files, so a codec tailer reuses it rather than defining a second port. `Date` is a parameter on every recording call, as today.

Illustrative sketch, not a proposal:

```swift
timing.noteConnected(uid: id)                                  // link edge
timing.noteClockOutcome(uid: id, outcome: outcome)            // once a second
let decision = timing.recordMeasurement(uid: id, correctedMs: value)  // apply path
let report = timing.report(uid: id)                            // snapshot builder
```

### Design A: minimise the interface

`BTSpeakerTiming`, absorbing and renaming `BTAlignmentFreshness`, with three entry points: `record(_ event: Event, for uid: String, at: Date) -> Verdict`, `timing(for uid: String, hasStoredOffset: Bool, now: Date) -> SpeakerTiming`, and `onChange`. `Event` has six cases (`connected`, `disconnected`, `clockSample(Outcome)`, `measurementReported(offsetMs:appliedMs:candidateMs:confidence:)`, `offsetSetByHand(valueMs:)`, `offsetCleared`); `Verdict` is `recorded`, `replaceOffset(newOffsetMs:differenceMs:tellUser:)` or `keepOffset(differenceMs:)`. One settle record per link-up, emitted at the first of the verdict reaching steady or the link dropping. The apply path's two `Telemetry` lines move inside the module (the measurement event carries stagger, range and confidence for that purpose); `bt_align_recheck_after_early` and the `earlyAlignmentJumpSumMs` read that feeds it are deleted. Thresholds go in `AudioutProtocol`. The speaker key is a truncated SHA-256 over `installID + uid`. On the wire it keeps `status: "stale"` with `staleReason: "reconnected"` for a reconnected speaker and adds `source: "fromLastTime"` beside it, so an older phone behaves exactly as today.

Strong: the apply path collapses six statements into one call and the 10 ms rule cannot be applied in one place and forgotten in another. Thin: `Event` is wider than `Verdict` earns (three cases always answer `recorded`), the ordering rule "record before the store write" is a fact the caller must hold, and keeping `stale`/`reconnected` on the wire contradicts the glossary, where "Timing from last time" is an applied, labelled offset and not a speaker that needs tuning. A phone reading `status == "stale"` in `needsTuning` (`SyncSheet.swift:891-893`) would keep chaining a reconnected speaker as work to do.

### Design B: maximise flexibility

`BTAlignmentTracker`, the same file renamed, every existing signature kept so no call site churns. Additions: a pure `static func decide(measuredMs:appliedMs:) -> ReplaceDecision` (`replace(deltaMs:tellUser:)` or `keep(deltaMs:)`) reading `AudioutProtocol.AlignmentThresholds.replaceMs` and `.tellUserMs`; `noteAligned` gains `source:` and `offsetMs:`; `report` returns a `BTAlignmentReport` with `source: OffsetSource?`; a `BTSettleRecord` value type with two projections, `telemetryFields()` (includes the UID) and `analyticsFields()` (structurally cannot); a `BTSettleRecordSink` protocol with an array of sinks injected at init; a `codec` closure and a `speakerKey` closure. The speaker key is a per-install monotonic index persisted as one more optional map in the `BTTrimStore` envelope (`:99-107`), the same read-modify-write every writer there does. `secondsToSettle` is `nil` when the 60 s floor made the verdict, so no invented 60 enters the spread. Extension points not built, each marked as a ceiling: the learned per-speaker settle prior, the crowd median (a third sink), a declined re-check, a fourth source (the open string set already allows it).

Strong: `decide` is pure and shared by any caller; the type-level exclusion of the UID turns the consent promise into something a test can assert; the sink array is justified by two adapters on day one. Thin: `BTSettleRecordSink` is a protocol whose two adapters are one-line forwarders; B's claim that the Mac's by-ear Keep should also pass through `decide` is a second adapter nobody wants, because a value the user confirmed by ear must be kept as pressed.

### Design C: optimise for the common caller

The common caller is the snapshot builder, which reads every Bluetooth row on every rebroadcast. `BTSpeakerTiming`, the same file renamed, whose `report(uid:now:)` takes the UID only: the store read moves behind an injected `storedOffsetMs` closure so `NativeBackend.btAlignmentReport(forDevice:)` (`:10944`) drops its `hasStoreEntry:` argument and the builder gains one line, `source: report.source?.rawValue`. `recordMeasurement(uid:correctedMs:at:) -> MeasurementDecision` (`replace(keepMs:)` or `keepStored`) decides and records the alignment instant in one call and hands back the caller's own value untouched; the arithmetic, the clamp, the store write and the sink push stay in `NativeBackend`. Four pure statics (`status`, `clockState`, `source`, `decision`) stay assertable with no clock, device or store. The settle record is built inside `noteClockOutcome` at the first steady verdict after a link-up. `BTSpeakerTimingReport` carries the invariants: `source` is non-nil exactly when `status != .notSet`; `staleReason` is non-nil exactly when `status == .stale`, and only `"moved"` survives; a reconnect beats a first pass. The 10 ms constant is the Mac's; the 40 ms constant is the phone's. C also proposes an optional `replacedStoredOffset: Bool?` key on `alignmentApplied`, following the `companionToken`-on-`welcome` precedent (`CompanionMessage.swift:36`), so the phone can tell "kept, the number agreed" from "the clamp ate it".

Strong: highest leverage at the most frequent read, the cleanest wire semantics, and two live defects found in passing (below). Thin: a settle record emitted only at steady loses every link that drops before settling, which is exactly the data the research note wants; the injected store closure invites a lock-order inversion (the module's lock held while the closure takes `btTrimLock`) unless the closure is called outside the lock; and the extra `alignmentApplied` key is an encoding change to an existing case that the phone can do without.

### Comparison

**Depth.** C wins at the read: one method, one argument, a value that maps field-for-field onto the wire struct, with the store-existence question hidden. A wins at the apply path: one call carries the rule, the record and the instruction to write. B keeps the widest interface (new parameters, a record type with two projections, a sink protocol) for the least new hiding; its depth is in `decide`, which is one pure function. Against the skill's test ("can I reduce the methods, simplify the parameters, hide more"): C reduces a parameter every reader must remember; A reduces methods but moves their variety into an enum the caller still has to learn.

**Locality.** All three put the ADR in the one file that already owns three of its four parts, and all three keep the single lock. Where they differ is the Telemetry lines: A pulls `bt_align_measurement` into the module and so widens the measurement event with stagger, range and confidence; B and C leave it in `NativeBackend`, where those inputs live, and add a `replaced` field. B's and C's choice keeps the module free of the staging arithmetic, which is the same split ProbeKit draws (the caller reports raw, the Mac owns trim semantics).

**Seam placement.** The settle record's emit point matters: A and B emit once per link-up at the first of steady or link drop; C emits only at steady. A dropped link with four jumps and no settle is data. On the speaker key, A and C hash with a known salt (`installID`, which PostHog already holds as the distinct id at `AppDelegate.swift:2245`); a MAC address space is small enough that a hash with a known salt is reversible by enumeration, so either a secret random salt or B's index is needed, and B's index carries no information by construction. On thresholds, A and B put both numbers in `AudioutProtocol`; C splits them. The phone needs the 10 ms number to render "kept" from `correctedMs == 0` and `abs(measuredMs) < 10`, so both peers read it, and the package is where constants both peers read already live (`CompanionGoodbyeReason`). On the wire, B and C retire `"reconnected"` and `"measuredWhileSettling"`; A keeps them. The glossary decides this: a speaker under "Timing from last time" is tuned and labelled, not stale.

### Recommendation: C's base, with three pieces from A and B

Rename `BTAlignmentFreshness` to `BTSpeakerTiming` in place (mechanical: the property at `NativeBackend.swift:419`, about twelve call sites, one forwarding line in `OwnToneBackend.swift:985`, the test file). Interface:

```swift
public final class BTSpeakerTiming: @unchecked Sendable {
    public enum Status: String { case notSet, tuned, stale }
    public enum ClockState: String { case unknown, settling, steady }
    public enum Source: String { case measured, firstPass, fromLastTime }
    public enum MeasurementDecision: Equatable { case replace, keepStored }

    public init(storedOffsetMs: @escaping @Sendable (String) -> Double?,
                speakerKey: @escaping @Sendable (String) -> String,
                codec: @escaping @Sendable (String) -> String? = { _ in nil },
                floorRebroadcastDelay: TimeInterval = settleSeconds)
    public var onChange: (@Sendable () -> Void)?

    public func noteConnected(uid: String, at: Date = Date())
    public func noteDisconnected(uid: String, at: Date = Date())
    public func noteClockOutcome(uid: String, outcome: BTClockStability.Outcome, at: Date = Date())
    public func noteAligned(uid: String, at: Date = Date())      // by-ear Keep, persisted nudge
    public func clearAligned(uid: String)
    /// The phone's automatic apply only. Decides keep-or-replace against the stored
    /// offset at AlignmentThresholds.replaceMs and records the alignment instant either way.
    public func recordMeasurement(uid: String, correctedMs: Double, at: Date = Date()) -> MeasurementDecision
    public func report(uid: String, now: Date = Date()) -> BTSpeakerTimingReport

    public static func status(hasStoredOffset:lastConnectedAt:alignedAt:) -> Status
    public static func clockState(stableForSeconds:seenJump:lastConnectedAt:now:) -> ClockState
    public static func source(hasStoredOffset:lastConnectedAt:alignedAt:measuredEarly:) -> Source?
    public static func decision(correctedMs: Double, storedMs: Double?) -> MeasurementDecision
}

public struct BTSpeakerTimingReport: Equatable, Sendable {
    public let status: Status
    public let source: Source?          // non-nil exactly when status != .notSet
    public let clockState: ClockState
    public let staleReason: String?     // "moved" or nil; the other two reasons retire
    public let settleRemainingSeconds: Int?   // always nil; wire compatibility
}
```

Invariants and ordering. `noteConnected` before any `noteClockOutcome` for that link. `recordMeasurement` before the store write (it reads the stored value through the closure). The injected closures are called outside the module's lock, never inside it. A reconnect beats a first pass. `keepStored` still records the alignment instant, so a confirmed number moves the row to `measured`. Nothing throws; a `nil` from a closure degrades a field, never the call. Same three writer queues, same lock, `onChange` and the settle record both fire after the lock drops, never on the render thread.

Taken from A: one settle record per link-up, emitted at the first of steady or link drop, with `secondsToSettle` absent when the 60 s floor produced the verdict (B's honesty rule). Taken from B: `AlignmentThresholds.replaceMs = 10` and `.tellUserMs = 40` in `AudioutProtocol` beside `CompanionGoodbyeReason`, read by the Mac's `decision` and by the phone's verdict copy; the speaker key as a per-install index in the `BTTrimStore` envelope (one optional map, no schema bump, like `latencyMs` at `:102-106`); and reuse of `LogStreamSpawning` for the codec tailer once the line is proven, with `codec` defaulting to `nil` until then. Not taken: A's move of the Telemetry lines into the module (they need stagger, range and confidence; they stay at `:11142-11155` and `:11484-11490` and gain a `replaced` field); B's sink protocol (the module writes the local line through `Telemetry.log` and the release event through `Analytics.capture`, and one test asserts the release dictionary holds neither a `uid` key nor the raw UID as a value); C's extra `alignmentApplied` key (the phone renders "kept" from `correctedMs == 0 && abs(measuredMs) < AlignmentThresholds.replaceMs`; the half-millisecond rounding edge changes one sentence, never the number applied).

The settle record, once per link-up: local `Telemetry.log(.localPlayback, "bt_link_settled", [uid, speakerKey, codec, jumps, secondsToSettle, offsetMs, source])`; release `Analytics.capture("bt_sync:link_settled", [speaker: speakerKey, codec, jumps, secondsToSettle, offsetMs, source, deviceClass])`. `Analytics.capture` already refuses without consent, so the module holds no consent logic. The settled offset is the offset in force when the record emits; a re-measurement after steady emits its own `bt_align_measurement` line with `replaced`, and T23 joins the two on `uid` in the local file.

Tests, at the interface (DEEPENING.md, replace don't layer): `BTAlignmentFreshnessTests` becomes `BTSpeakerTimingTests`; the tests asserting `.stale`/`"reconnected"` are rewritten to assert `.tuned`/`.fromLastTime`; new cases for `recordMeasurement` at 9, 10 and 11 ms against a stored value, for `source` precedence (reconnect over first pass), for one record per link-up on both emit paths, and for the release dictionary's exclusion of the UID through an `Analytics.Sink` closure and `Telemetry._installTestSink`. `NativeBackendBTAlignmentInterceptTests` covers the apply path's branch on the decision.

Two live defects to fix in the same change, found by two of the three designers and confirmed in source: `applyCompanionAlignmentMeasurement` calls `noteAligned` at `:11172` immediately after `endBTWizardLatencyPreview` already called it at `:11478`, so every phone measurement records the alignment instant twice; and both `bt_align_measurement` (`:11153-11154`) and `wizard_keep` (`:11488-11489`) log `settleRemainingS` from a report whose `settleRemainingSeconds` is documented always `nil` (`BTAlignmentFreshness.swift:325`), so both have written the literal string `"nil"` since the clock-state change. Replace that field with `clockState`.

## 3. Cross-repo seams

### T2: the additive `source` field

Additive and bump-free for the reasons in section 1. The package's convention for enum-like wire fields is a `String` with the allowed values in the doc comment (`status` `:44-45`, `staleReason` `:46-47`, `clockState` `:55-66`), with the Mac mapping its own `String`-backed enum's `rawValue` in the builder (`CompanionSnapshotBuilder.swift:245, 251`) and the phone switching on the strings (`SyncSheet.swift:891-921`). Following that:

```swift
// CompanionSnapshot.swift, inside DeviceState.AlignmentState
/// Where the applied offset came from, so the row can say so:
/// `"measured"`: a measurement taken after the Mac called the speaker settled;
/// `"firstPass"`: a measurement taken before it settled, applied and labelled,
///   re-checked once `clockState` reads `"steady"`;
/// `"fromLastTime"`: the offset this speaker had when last measured, applied
///   again on reconnect until a new measurement replaces it.
/// Only meaningful when `status` is `"tuned"`. `nil` means the Mac does not
/// report it (an older Mac); treat as `"measured"`. A value this phone does
/// not recognise is a newer Mac's; render it as `"measured"` too.
public var source: String?
```

with `source: String? = nil` appended to the memberwise `init` (`:68-80`), and a constants enum beside `CompanionGoodbyeReason` (`CompanionMessage.swift:80-100`) so neither side types the strings:

```swift
public enum AlignmentSource {
    public static let measured = "measured"
    public static let firstPass = "firstPass"
    public static let fromLastTime = "fromLastTime"
}
```

Unknown tolerance is by construction: a `String` decodes anything, and the phone's `switch` has a `default` that renders like measured. If a typed enum is wanted instead, it must not be a `String`-raw enum with synthesized `Codable`, because an unknown value throws and the whole snapshot fails to decode. The shape that tolerates the future is the one `CompanionCommand` uses (`CompanionCommand.swift:114-120`):

```swift
public enum Source: Equatable, Sendable, Codable {
    case measured, firstPass, fromLastTime
    case unknown(String)
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "measured": self = .measured
        case "firstPass": self = .firstPass
        case "fromLastTime": self = .fromLastTime
        default: self = .unknown(raw)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .measured: try c.encode("measured")
        case .firstPass: try c.encode("firstPass")
        case .fromLastTime: try c.encode("fromLastTime")
        case .unknown(let raw): try c.encode(raw)
        }
    }
}
```

The `String` plus constants matches every sibling field and is the recommendation; the typed enum is the alternative if the owner wants the compiler to hold the phone's switch exhaustive. Either way: two new tests in `CompanionMessageTests.swift`, one round trip with `source` set, one decode of an `AlignmentState` JSON object without the key, and (for the typed enum) one with an unrecognised value.

Retiring wire values, stated for the record: after T14 the Mac never sends `staleReason: "reconnected"` or `"measuredWhileSettling"`. Leave the doc comment at `:46-47` listing them as historical so a reader of an old capture can decode it.

### T1: one `SweepDesign` covers both ends

Confirmed for the fade. The phone recreates both templates from the package's factories at the capture's own sample rate (`ProbeAnalyzer.swift:102-105`, `ProbeSession.swift:241-242`); the Mac stages from the same factories (`AlignmentTickInjector.swift:438-447`) and analyses its own microphone from them too (`MicProbeSession.swift:311-314`). Change `fadeDuration` in the two factories and every renderer follows on the next pin. The level is the Mac's staging amplitude and never reaches the phone; it moves to T13.

### T15: PostHog on the Mac through the usage-counts consent

Reuse is right: `Analytics.capture` (`Analytics.swift:70-76`) gates on the same `telemetryOptIn` the card (`OnboardingViewController.swift:779-811`, `UsageStatsConsentCard.swift`) and the Settings row (`GeneralSettingsViewController.swift:235-245`) flip, and the executable is the only place the PostHog adapter is installed (`AppDelegate.swift:78-130`, note `geoipDisableKey` and `installID` handling at `:117, 2245`). Two corrections the plan must carry: the Mac stream is opt-in and off by default, so release data arrives only from opted-in Macs; and the event's fields go beyond the card's audited sentence, so the card body and hint change with the event, and the speaker identifier is a per-install salted hash, never the UID.

## Plan changes

Apply verbatim. Task id, what changes, why.

- **T1.** Replace the task text with: "Sweeps: fade 0.08 s in the `upSweep`/`downSweep` defaults (`Sources/ProbeKit/SyncProbeCorrelator.swift:76-86`). Run `swift test`. The level is not in this package; it moves to T13." Why: `SweepDesign` has no amplitude (`:64-73`); the phone only correlates, and the confidence ratio is invariant to template level, so a package amplitude would have one consumer. The `ProbeKitTests` fallback trigger is deleted because the tests place arrivals at their own gains and cannot see a level change.
- **T1 (ADR).** Amend `audiout-shared/docs/adr/0001-quieter-sweeps.md`: the fade lands in the package and reaches all three renderers on the next pin; the 6 dB is the Mac's staging amplitude (`AlignmentTickInjector.stageProbe`), decided by a live listen, with the 3 dB fallback decided the same way. Why: the ADR's "in this package" is true of the fade and false of the level.
- **T2.** Replace with: "Add `source: String?` to `DeviceState.AlignmentState` (`Sources/AudioutProtocol/CompanionSnapshot.swift:43-81`), values `measured` | `firstPass` | `fromLastTime`, nil treated as `measured`, appended to the memberwise init; add `public enum AlignmentSource` constants and `public enum AlignmentThresholds { replaceMs = 10; tellUserMs = 40 }` beside `CompanionGoodbyeReason` in `CompanionMessage.swift`; document that `staleReason` `reconnected` and `measuredWhileSettling` are no longer sent and only `moved` remains; two tests in `CompanionMessageTests.swift` (round trip with `source`, decode without the key). No `CompanionProto.version` bump. No settle-log message." Why: additive optional field is the file's own pattern; both peers read the thresholds; nothing on the phone renders a log.
- **T3.** Add: "Merge the shared branch to `main` first (it is one commit ahead); tag from `main`. The phone pins 0.8.0, the Mac 0.8.1, so T4 moves two tags." Why: `main` is at `3f20742` = 0.8.1; the ADR and glossary commit is unmerged.
- **T13.** Add: "Sweep level: `AlignmentTickInjector.stageProbe` default amplitude 0.35 to 0.175 as a named constant beside `probeEngineLaneScale` (`:432, :470`); both callers use the default (`NativeCaptureCoordinator.swift:1427, 1459`). Confirm by ear on a real speaker; fall back to 0.25 (3 dB) if the far lane reads thin." Why: the level lives on the Mac (see T1).
- **T14.** Replace the first clause with: "On Bluetooth reconnect the stored offset is already applied (`NativeBackend.swift:1641-1646`, re-pushed on every arm); change what the Mac publishes: `status: tuned`, `source: fromLastTime` instead of `stale`/`reconnected`; a measurement made while settling publishes `tuned`/`firstPass` instead of `stale`/`measuredWhileSettling`; `moved` stays." Replace the module reference with: "Rename `BTAlignmentFreshness` to `BTSpeakerTiming` in place; `report(uid:)` takes the UID only with the store read injected; add `recordMeasurement(uid:correctedMs:) -> replace | keepStored` called from `applyCompanionAlignmentMeasurement` before `endBTWizardLatencyPreview` (`:11171`), deciding at `AlignmentThresholds.replaceMs`; `keepStored` returns `correctedMs: 0`. No new wire message: the phone renders 'kept' from `correctedMs == 0 && abs(measuredMs) < replaceMs` and 'over 40 ms' from `abs(correctedMs) >= tellUserMs` on `alignmentApplied`." Add: "Delete the duplicate `noteAligned` at `:11172`; replace the `settleRemainingS` field in `bt_align_measurement` and `wizard_keep` with `clockState`; rewrite the freshness tests that assert `stale`/`reconnected` rather than adding beside them." Why: section 2's recommendation; two confirmed defects.
- **T15.** Replace with: "One settle record per link-up, emitted by `BTSpeakerTiming` at the first of the verdict reaching steady or the link dropping: speaker key (a per-install index kept as one optional map in the `BTTrimStore` envelope, never the UID), codec (optional, nil until the `bluetoothaudiod` line is proven; then a tailer on the existing `LogStreamSpawning` port), jump count (new per-link counter beside `seenJumpSinceLinkUIDs`), seconds to settle (absent when the 60 s floor made the verdict), offset in force, source, `bluetoothDeviceClassMinor`. Debug and release both go through the module: `Telemetry.log(.localPlayback, "bt_link_settled", ...)` with the UID, `Analytics.capture("bt_sync:link_settled", ...)` without it. `Analytics.capture` already refuses without consent. Amend the consent card body (`UsageStatsConsentCard.swift:151-154`) and `GeneralSettingsViewController.consentHintLine` to name the new fields in the same change." Add a note: "The Mac's analytics are opt-in and off by default (`PRODUCT.md:66`); D12's on-by-default is the phone. T23 reads the owner's local log file." Why: the consent promise is audited against the payload; the UID is MAC-derived; the codec line is unverified on this Mac (no `bluetoothaudiod` line in 14 days of unified log).
- **T16.** Replace the chip anchor with `AudioutSharedUI/DeviceRowView.swift:1974-1992, 2080-2086` and `PopoverController.startBTAlignmentWizard` (`:4799`); the plan's `:4640-4646` is the delegate hop. Add: "Build one invite view (QR via CoreImage `CIFilter.qrCodeGenerator()`, link, copy) hosted three times: a popover from the chip tap offering 'Measure with your iPhone' then 'Align by ear', under the Allow switch (`GeneralSettingsViewController.swift:217-220`), and the seventh first-run card's rehearsal. Rename `"Align"` (`DeviceRowView.swift:1982`) and `"Align speaker…"` (`:2157`) to 'Align by ear' (D3). The seventh card is a new `SetupStep` case (`SetupFlowModel.swift:9-15`) modelled on `.usageStats`: skippable, complete once seen, 14 exhaustive switch sites plus `isComplete`." Delete: "Allow switch default ON" (already true when unset, `AppSettings.swift:328-341`). Why: wrong anchor; the invite is one module with three hosts; the default flip landed on 2026-08-06.
- **T17.** Replace with: "Scene wording is done (`GroupEditorViewController.swift:360, 388`, `SidebarViewController.swift:217`, `GroupsOverviewViewController.swift:65`, `PopoverController.swift:2317`, `AppDelegate.swift:1884`). Remaining: the tooltip at `DeviceRowView.swift:1899` ('the rest of the group'), harness message text (`window-harness/main.swift:244`), and any 'Groups' in `docs/SPEC.md`. The 'Align by ear' rename moves to T16." Why: the three strings the task names do not exist.
- **T18.** Correct anchors: the free-Mac claim is `:10-11`; add `:14` ("No data is collected") and §4 `:77-85` ("Data Not Collected"), both replaced per D12; `PRICING.md:3` is `docs/PRICING.md:3`; mark §8 `:119-133` (companion-plan T20/T22/T23 handoff) as superseded. Why: read against the file.
- **T19.** Replace the commit hash with `scripts/release.sh` and `docs/RELEASE.md:20-45`. Add: "Prerequisites the script refuses without: `main` clean and pushed with T13 to T16 merged; production D1 fully migrated, and `0005_remote_signups.sql` is unapplied today (`scripts/release.sh:77-93`, licence server `migrations/`)." Why: the gate refuses on an unapplied migration and that one is known unapplied.
- **Owner-only prerequisites.** Add two lines: "Apply licence-server migration `0005_remote_signups.sql` to production D1 (T19 refuses until then; pair it with T21)." and "Connect one Bluetooth speaker with `log stream --predicate 'process == \"bluetoothaudiod\"'` running and paste the codec line into T15, or strike codec from the log." Why: both block a task and only the owner can do them.
- **T23.** Replace "reviews the settle log" with "reviews `~/Library/Logs/Audiout/` (`bt_link_settled` joined to `bt_align_measurement` on `uid`)". Why: release analytics are opt-in and the owner's data is local.
- **Order and dependencies.** Add "T2 before T14 and T7 (both read `AlignmentThresholds` and `source`); T14 before T15 (the settle record lives in the renamed module); T21's server work before T19." Why: the module and the constants are shared inputs; the migration gates the release.
