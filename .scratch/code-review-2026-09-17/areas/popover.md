# UI — popover and shared UI — review

## Verdict
Careful, well-documented AppKit: observer hygiene is deliberate and explained, timers and display links are gated on window membership, token discipline is close to total (one raw colour literal in ~34k lines), and the folder AGENTS.md files pre-answer most of what looks wrong. The damage is concentrated in size: `PopoverController` is 5992 lines with ~200 methods and `DeviceRowView` is 3625 lines of which about a third is test scaffolding compiled into the shipping binary. Two real defects survive — a slider drag flag in `AppRowView` that wedges permanently on any keyboard or VoiceOver volume change (marked STABILITY(D4), already fixed two different ways in the two sibling row views), and `LevelMeterView` being the only animated view that never stops its display link when it leaves a window, so every `rebuild()` strands a running one. Highest-impact change: split `PopoverController` along its own MARK: seams and move the ~1400 lines of `test_*` hooks out with them.

## Counts
BUG: 2 · SUBSTANCE: 14 · COSMETIC: 1 · files read: 28 / 56 (all 56 grepped)

## Findings

### 1. [BUG] `AppRowView`'s slider drag flag never clears after a keyboard or VoiceOver volume change; the row stops tracking the model for the session
- Where: `AudioutSharedUI/AppRowView.swift:718`, `:269`
- Evidence: `isDraggingSlider = true; if event?.type == .leftMouseUp { isDraggingSlider = false }` — carries a `STABILITY(D4)` comment naming the defect. `MainOutRowView.swift:689` already fixes it (clears on anything not a mouse drag); `DeviceRowView.swift:2261` installs a scoped mouse-up monitor.
- Fix: copy `MainOutRowView.masterChanged`'s switch into `AppRowView.volumeChanged`, delete the marker.
- Confidence: high

### 2. [BUG] `LevelMeterView` never stops its display link when it leaves a window; every `rebuild()` strands one
- Where: `AudioutSharedUI/LevelMeterView.swift:284`, `:302`, `:143`; `PopoverController.swift:1638`
- Evidence: link stops only when level eases to rest in `tick()`; no `viewDidMoveToWindow` override, while `MembershipBusView:218`, `HaloRingView:374`, `AlignmentStageView:1690` all have one. `rebuild()` discards rows; CADisplayLink retains its target so orphaned meters tick forever and `deinit` never runs.
- Fix: `override func viewDidMoveToWindow() { super…; if window == nil { reset() } }`.
- Confidence: high

### 3. [SUBSTANCE] `PopoverController` is 5992 lines and ~200 methods — unreadable cold
- Where: `PopoverController.swift:146`. 374 stored properties, 79 `func test_*`; MARK: sections already name the seams. `rebuild()` 278 lines (:1638), `startBTAlignmentWizard` 190 (:5138), `update(devices:)` 188 (:900), `applySelectionState` 107 (:2953).
- Fix: lift the BT wizard funnel (:4980–:5558), the sync drawer (:3106–:3310), and the Applications card (:3828–:4336) into collaborators, each keeping its `test_*` hooks.
- Confidence: high

### 4. [SUBSTANCE] `SilenceFallbackBannerView` is a line-for-line copy of `SystemAirPlayNoteBannerView(severity: .warning)`
- Where: `SilenceFallbackBannerView.swift:1-146`; `SystemAirPlayNoteBannerView.swift:1-195`. The copy already `typealias Action = SystemAirPlayNoteBannerView.Action` and hardcodes what `.warning` resolves to; the original's doc says it exists to avoid "forking a second banner class". Copy is missing `test_actionButtonAccessibilityLabel`.
- Fix: delete `SilenceFallbackBannerView`; construct the original with `severity: .warning`.
- Confidence: high

### 5. [SUBSTANCE] About a third of `DeviceRowView` is test scaffolding compiled into the shipping binary, including a per-pixel image scanner
- Where: `DeviceRowView.swift:2344` onward (file ends 3625); `drawnInks(of:)` at :2624 walks every pixel of a cached bitmap. 23 `func test_*`. `PopoverController` same: nine test MARK blocks, ~1400 lines.
- Fix: move read-only introspection (`drawnInks`, `inkFrame`, `inkCoverage`, `matchesSymbol`, dependent `test_*` properties) into an extension in a separate file; keep delegate-driving hooks.
- Confidence: high

### 6. [SUBSTANCE] "Resolve a token under an appearance and stamp it into a layer" is hand-rolled 26 times across 17 files, in two incompatible refresh shapes
- Where: `performAsCurrentDrawingAppearance` — `BusRailOverlayView.swift:181,670,778`, `HaloRingView.swift:279,416`, `AlignmentStageView.swift:1573,1593,1600`, `SilenceFallbackBannerView.swift:128`, …. Refresh hook is either `wantsUpdateLayer`+`updateLayer` or `viewDidChangeEffectiveAppearance`, three views carry both; `SilenceFallbackBannerView.swift:113` records one that shipped broken.
- Fix: one `NSView` extension `stampLayerColor(_:alpha:)` + `Tokens.Color.resolved(_:in:)`.
- Confidence: high

### 7. [SUBSTANCE] `Tokens.Layout`'s nine spacing forwarders have no consumers anywhere in the repo
- Where: `Tokens.swift:1406-1424`. Repo-wide `Tokens.Layout.` = 34 hits, all Radius. Contradicts AGENTS.md "row geometry lives in `PopoverColumnGrid`".
- Fix: delete the nine.
- Confidence: high

### 8. [SUBSTANCE] Five dead tokens, three of them deprecated aliases the migration was supposed to retire
- Where: `Tokens.swift:1234` (`inkSecondary`), `:1236` (`tertiaryLabel`), `:1242` (`partySignalDeep`), `:1195` (`party`), `:1269` (`bodyBold`) — 0 uses each outside Tokens.swift.
- Fix: delete those five. `secondaryLabel` (11), `inkTertiary` (3), `accent` (2), `partyRampDeep` (2) still have consumers.
- Confidence: high

### 9. [SUBSTANCE] A selection refusal the user just triggered is written to raw stderr, and the comment claims something reads it
- Where: `PopoverController.swift:4375-4381` — `FileHandle.standardError.write(Data("[Audiout] \(reason)\n".utf8))` with comment "we log it so the app layer can show it". Only raw stderr write in either folder; `Telemetry.fail` used twice in the same file (:2695, :2703).
- Fix: `Telemetry.fail(.ui, "mixer:selection_refused", …)`; fix the comment.
- Confidence: high

### 10. [SUBSTANCE] 152 bare ticket codes in comments, colliding namespaces, no document named
- Where: both folders; `PopoverController.swift:169` (T4), `:186` (T-7), `:812` (T-5), `:1097` (T7). `(T6)` ×10, `(T4)` ×9, `(D2)` ×7, `(T11)` ×6. `T7` and `T-7` are different plans.
- Fix: when touching one, append the document as `STABILITY(D4)` at `AppRowView.swift:718` does; no sweep.
- Confidence: high

### 11. [SUBSTANCE] Both banner views set a body font and label colour by hand instead of from `Tokens`
- Where: `SilenceFallbackBannerView.swift:54-55`; `SystemAirPlayNoteBannerView.swift:96-97` — `.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)`, `.labelColor`. Only two `.labelColor` in either folder; 13pt/medium is off the DESIGN.md scale.
- Fix: `Tokens.Font.body`, `Tokens.Color.label`, or add medium to the scale deliberately.
- Confidence: high

### 12. [SUBSTANCE] Six methods past 180 lines, each doing several unrelated things
- Where: `DeviceRowView.swift:1510` (`buildSubviews`, 401), `:516` (`apply`, 285), `PopoverController.swift:1638` (`rebuild`, 278), `PopoverPanelViewController.swift:699` (`beginCard`, 247, 14 params), `MainOutRowView.swift:362` (`buildSubviews`, 248), `BTAlignmentWizardView.swift:722` (`render`, 209).
- Fix: `rebuild()` splits at its own numbered comments; `beginCard` params collapse into the `HeaderAccessory`-style struct the file already uses.
- Confidence: high

### 13. [SUBSTANCE] `FoldAnimator` drops a tween whose constraint has been deallocated without ever firing its completion
- Where: `FoldAnimator.swift:172-174` — `guard let constraint = tween.constraint else { continue }` skips `tween.completion()` at :191. Completions are not height-only: `PopoverPanelViewController.swift:1333` passes `detach`; `AppSurfaceController.swift:681` restores `layer?.opacity = 1`.
- Fix: run the completion on the drop path, or document that fold completions must not hold cleanup.
- Confidence: medium

### 14. [SUBSTANCE] The package is not in Swift 6 strict-concurrency mode, so `nonisolated(unsafe)` and mutable-static markers are unchecked
- Where: `AudioutCore/Package.swift:1` (`swift-tools-version:5.10`), `:79` (no `swiftLanguageMode`, no StrictConcurrency); `RowAccessorySymbol.swift:105` (`nonisolated(unsafe) public static var test_catalogueBundle`, no lock); `AppIconCache.swift:26`, `:42`.
- Fix: enable strict concurrency for these targets and fix what it reports, or drop the annotation and say main-thread-only.
- Confidence: high

### 15. [SUBSTANCE] A guard condition in the wizard's microphone probe is provably always true
- Where: `PopoverController.swift:5329-5337` — `btWizardMicProbe = nil` two lines above `guard … btWizardMicProbe == nil`.
- Fix: delete the clause.
- Confidence: high

### 16. [SUBSTANCE] A raw colour literal sets the surface panel's background
- Where: `ControlPanelWindowController.swift:373` — `NSColor.black.withAlphaComponent(0.02)`; the 2% wash is justified (zero-alpha click-through on macOS 26) but lives outside Tokens and the sanctioned-literal list.
- Fix: name it in `Tokens.Color` or add the site to the sanctioned list.
- Confidence: medium

### 17. [COSMETIC] Force unwrap on a stack's last arranged subview in the wizard's intro screen
- Where: `BTAlignmentWizardView.swift:759` — `after: contentStack.arrangedSubviews.last!`.
- Fix: `if let last = …`.
- Confidence: high

## Also noted
- `AppIconCache.swift:90` — `chunk(size: 8)` is a hand-kept copy of `AudioutProtocol.CompanionAppIcons.pageSize`; no test pins the two; `AppIconCacheTests.swift:85` asserts the literal.
- `AppIconCache.swift:156-157` — `try?` on createDirectory and write swallow cache failures; `DeviceIcon.swift:155` routes the same through `StoreRecovery.noteWriteFailure`.
- `PopoverController.swift:922` — `_ = controller.setDeviceSelected(...)` discards `SelectionResult`; harmless because `handleSelection` ignores the flag too (:4361).
- `AppRowView.swift:718` is the only `STABILITY(id)` marker left, yet four AGENTS/AGENTS-HISTORY files describe the scheme as if several remain.
- `VolumePercent.swift:40` — localized digits with hardcoded English " percent"; VoiceOver speaks half-translated in non-English locales.
- `AudioutPopoverUI/AGENTS-HISTORY.md:55` is a single ~4500-word paragraph; the authority on the wizard and unsearchable.
