# 23 — Split PopoverController along its MARK seams and move test hooks out

Status: ready-for-agent
Wave: 5
Pipeline model: fable (normal mode)
Source: [REVIEW.md](../REVIEW.md), findings popover #3, popover #5, popover #12, popover #4

5,992 lines, ~200 methods, ~1,400 lines of `test_*`; `DeviceRowView` carries ~1,280 lines of test scaffolding including a pixel scanner; `SilenceFallbackBannerView` duplicates `SystemAirPlayNoteBannerView(.warning)`.

## Done when

The Bluetooth wizard funnel, the sync drawer and the Applications card are collaborators the controller holds; read-only test introspection lives in `+TestSupport` files; `SilenceFallbackBannerView` is deleted; full suite green with test edits limited to renames.

## Test seam

full suite, unchanged

## Verification

```bash
AUDIOUT_FULL_SUITE=1 bash scripts/run-tests.sh
```

## Findings (verbatim from the area reports)

### 3. [SUBSTANCE] `PopoverController` is 5992 lines and ~200 methods — unreadable cold
- Where: `PopoverController.swift:146`. 374 stored properties, 79 `func test_*`; MARK: sections already name the seams. `rebuild()` 278 lines (:1638), `startBTAlignmentWizard` 190 (:5138), `update(devices:)` 188 (:900), `applySelectionState` 107 (:2953).
- Fix: lift the BT wizard funnel (:4980–:5558), the sync drawer (:3106–:3310), and the Applications card (:3828–:4336) into collaborators, each keeping its `test_*` hooks.
- Confidence: high

### 5. [SUBSTANCE] About a third of `DeviceRowView` is test scaffolding compiled into the shipping binary, including a per-pixel image scanner
- Where: `DeviceRowView.swift:2344` onward (file ends 3625); `drawnInks(of:)` at :2624 walks every pixel of a cached bitmap. 23 `func test_*`. `PopoverController` same: nine test MARK blocks, ~1400 lines.
- Fix: move read-only introspection (`drawnInks`, `inkFrame`, `inkCoverage`, `matchesSymbol`, dependent `test_*` properties) into an extension in a separate file; keep delegate-driving hooks.
- Confidence: high

### 12. [SUBSTANCE] Six methods past 180 lines, each doing several unrelated things
- Where: `DeviceRowView.swift:1510` (`buildSubviews`, 401), `:516` (`apply`, 285), `PopoverController.swift:1638` (`rebuild`, 278), `PopoverPanelViewController.swift:699` (`beginCard`, 247, 14 params), `MainOutRowView.swift:362` (`buildSubviews`, 248), `BTAlignmentWizardView.swift:722` (`render`, 209).
- Fix: `rebuild()` splits at its own numbered comments; `beginCard` params collapse into the `HeaderAccessory`-style struct the file already uses.
- Confidence: high

### 4. [SUBSTANCE] `SilenceFallbackBannerView` is a line-for-line copy of `SystemAirPlayNoteBannerView(severity: .warning)`
- Where: `SilenceFallbackBannerView.swift:1-146`; `SystemAirPlayNoteBannerView.swift:1-195`. The copy already `typealias Action = SystemAirPlayNoteBannerView.Action` and hardcodes what `.warning` resolves to; the original's doc says it exists to avoid "forking a second banner class". Copy is missing `test_actionButtonAccessibilityLabel`.
- Fix: delete `SilenceFallbackBannerView`; construct the original with `severity: .warning`.
- Confidence: high
