# AudioutOnboardingUI

## Purpose

The first-run Setup window (pure AppKit): a two-pane screen that asks for the five
permissions one at a time — LEFT, the SPINE (fixed 288 pt column: header over six compact
status rows); RIGHT, the HERO (head block → preview frame holding a native-drawn miniature
of the surface this ask raises → ribbon status/recovery region → bottom bar with the gold
primary and a borderless Skip on skippable steps). It reframes the OS's "recording"
language before any TCC prompt fires, and is re-shown later if a required permission is
revoked. All permission logic lives in Core — `SetupModel` owns statuses and probes,
`SetupFlowModel` owns the sequence, skip set, Done gate and Allow decision table; this
folder only renders them and forwards taps.

## Rules

- Five setup steps use four different status APIs: System Audio and Local Network are real
  `PermissionStatus` TCC probes, Bluetooth's `CBManager.authorization` is the only
  fully-honest one, Remote Control primes an Accessibility prompt ahead of an unshipped
  feature, and Speaker Sync is `PTPHelperStatus` (Login Items via `SMAppService`) — not TCC at
  all, so it has no denied state and registers with no prompt.
- Done stays absent from the view hierarchy (never disabled/hidden) until
  `SetupFlowModel.isDoneAvailable` — the gate opens only once `runFinalCheck()` passes, the
  same silent audit `verifyForDone()` uses, because a click-time re-verify alone previously
  swallowed clicks during its own ~2s check. The verification is single-flight: `SetupModel`
  coalesces concurrent Local Network probes onto one running prime, because a colliding prime
  is answered `.undecided` and gets misread as a real denial. The gate's CTA persists as the
  ribbon's primary during a browse (`ribbonContent(active:)`/`ribbonPrimaryTapped()` ignore
  `browseStep`) — gating it on "no browse" would leave a dead button on screen.
- The final-check row (`SetupCheckRowView`) is a status row, not a card — no Allow/Skip, exact
  copy for its three states ("One last check" / "Making sure everything's ready…" /
  "Everything's ready"), and its gold tint (not a permission hue) is permanent, pinned by
  `OnboardingPermissionColorTests`.
- The hero pane is driven by exactly two variables: `SetupFlowModel.activeStep` (the live row)
  and `OnboardingViewController.browseStep` (a read-only look at a decided row, owned by the
  VC alone). A browse must never touch the sequence, skip set, or gate — only a real flow
  change (a new grant) clears it.
- Every row-state blend must go through `dynamicBlend(_:fraction:of:)` — blending a dynamic
  `NSColor` directly flattens it to whichever appearance was current when drawn, not the live
  one (`test_rowEdgeBarFill` pins it).
- The live row, every prominent Allow, and the CTA override `acceptsFirstMouse` — returning
  from System Settings often leaves the app inactive, and a stock control would spend the
  first click on reactivation instead of the action.
- Local Network's earned title is a found count, not a checkmark, and it's an `Int?`: `nil`
  means no browse ran (macOS 14, ungated), `0` means a real browse found nothing — never
  collapse these to the same UI state.
- Row titles live in two places that must be hand-kept in sync: `SetupCardContent.title(for:)`
  (ribbon) and `spineTitle(for:)` (288pt column, short form) — same earned/imperative grammar.
  Hero headline/why/button copy (`SetupCardContent.heroHeadline`/`whyLine`) is owner-verbatim;
  don't reword it.
- Which statuses trigger the "Open Settings…" fallback (`offersSettingsFallback(_:)`) must
  stay in lockstep with `SetupFlowModel.allow(_:)`'s own preflight, or the button promises a
  prompt the model won't fire. Remote Control's retry deep-links straight to Settings rather
  than re-priming (re-priming can't reliably highlight the app's row). Bluetooth's
  spinner/wait is model-owned (`isPrimingBluetooth`) because its answer arrives on a callback
  the click can't await, and times out at 10s so a dead callback can't latch the ask shut.
- A proved Local Network grant is sticky: only an mDNS `kDNSServiceErr_PolicyDenied` revokes
  it — a rescan that proves nothing (empty browse, in-flight `.undecided`) must never take
  `.granted` back. The "requested/unanswered" state must never claim "no speakers found" —
  that copy means the OS dialog itself went unanswered, not that a browse came up empty.
- An in-flight wait must never latch: an undecided prime always returns the step to its
  actionable state. Local Network's post-grant "Checking your network…" phase is driven by the
  primer's own reachability callback, never a timer.
- The Setup window stays `.floating` except while it opens System Settings (any privacy pane,
  or Speaker Sync's Login Items) — `window.level` drops to `.normal` first via the
  `onWillOpenSystemSettings` seam, restored on `appDidBecomeActive`. Remote Control's
  Accessibility alert is ordinary NORMAL-level window chrome (unlike TCC dialogs, which draw
  above floating windows) and needs the same yield, fired before `await
  flow.allow(.remoteControl)` so the alert is already up when the call returns.
  `appDidBecomeActive` must only restore `.floating` after an actual resign-then-become-active
  pair (`isYieldingToSettings` armed on yield, disarmed on resign) — otherwise the app's own
  activation click re-floats the window on top of Settings before it finishes coming forward.
  Don't call `returnToFront()` for Remote Control without `remoteControlStatus == .granted` —
  the dialog just opened, it didn't just close.
- While a prompt is unresolved (`isPromptInFlight`, plus `SetupModel.isPrimingBluetooth`), the
  reactivate hook and force-activate-on-click go quiet (click still delivered, just not the
  activation) so a system dialog that lost focus doesn't get buried again — this only affects
  focus/activation, never window level, since every dialog it covers already draws above a
  floating window. Local Network's `allowInFlight` outlives its own dialog by design
  (`promptInFlightStep` returns nil once `.verifying`) because the prime keeps running after
  the answer to settle the speaker count, and that tail has no dialog to stay quiet for.
- After `stuckPromptDelay` (20s) unanswered, the row adds a hint + demoted "Open Settings…"
  via the shared `SetupFlowModel.settingsDestination(for:)` table — UI only, it never re-asks.
- `present()` sizes/centers only on first call — a re-present must not recenter a window the
  user moved. Content size is fixed (820×560), nothing resizes per step. Both on-screen paths
  are gated on `HeadlessRuntime` — ungated, a `.floating` window parks itself un-clickably on
  top of the developer's real screen for the whole test run.
- Derive text-wrap width from a fixed constant (`SetupRibbonView.textWidth`), never from a
  resolved frame in `layout()` — doing the latter made a state's rendered height depend on
  AutoLayout timing and broke snapshot determinism.
- `refreshStatuses()` at load time is not optional — `bluetoothStatus` starts `.unknown`, so
  skipping it paints the Bluetooth row as undetermined even when already granted.
- `SetupFlowModel` is built in the VC's `init`, fixing the start step at construction time —
  building it later reads as a re-entry and opens on the wrong card.
- Which header message shows is tracked as an enum kind
  (`.firstRun`/`.permissionLost`/`.resume`), never a string-compare against welcome copy. The
  welcome subtitle holds in every state including complete — the payoff line belongs to the
  demo pane's finale, never the header.
- Done and ✕ are NOT equivalent: both call `dismiss()` exactly once (single-fire guard) and
  both fire `onFinished`, but only Done calls `SetupModel.complete()`. Closing with ✕ leaves
  setup incomplete so the flow reappears next launch.
- `DemoPaneView`'s mocks are the one approved custom-drawn exception to stock-AppKit; mock
  content itself paints in semantic system colors, not `Tokens`, so it reads as real macOS
  chrome. `DemoSystemColor` is a documented exception to colors-live-only-in-`Tokens` for the
  same reason — measured recordings of another app's chrome, not app palette.
- Build a gradient-masked icon in its own `NSImage` and knock out alpha with `.destinationIn`
  — compositing `.sourceAtop` straight into `draw(_:)` doesn't clip to the symbol and renders
  a solid rectangle.
- Own a mock switch's knob as a `CALayer`, not an `NSView` positioned by constraint +
  `layer.transform` — AppKit rewrites a layer-backed view's layer geometry on every layout
  pass and silently resets the transform.
- A nested mock (stage-two of a multi-stage demo) needs
  `translatesAutoresizingMaskIntoConstraints = false` set explicitly — left on, it renders as
  nothing but its drawn pointer.
- Un-electing the mock's container alone is not enough to hide it from VoiceOver — an ignored
  container hoists its children, so every descendant must be un-elected individually
  (`installAccessibilityOptOut`) or its real `NSTextField`s stay reachable.
- Bluetooth reuses Remote Control's `Tokens.Color.permission*` hue rather than minting a fifth
  token (the two rows are never adjacent). Upgrade path: add `permissionBluetooth` if that
  changes.
- `ProminentButton` exists to fix a real AppKit bug: a `bezelColor` fill drops to plain bezel
  on resigning key without recoloring its forced-white title, going white-on-white — exactly
  when a Settings trip resigns the window. Any button built via the `onboardingActionButton`
  factory or constructed directly must set `translatesAutoresizingMaskIntoConstraints = false`
  itself — left on outside an `NSStackView`, AutoLayout synthesizes a zero frame and the
  button renders as nothing.
- Per-row tile tint is permanent — only alpha (locked/skipped dimming) changes state, never
  the hue — and must never route through `accentDynamic`, which would collapse the five
  distinct hues into one accent.
- `DemoPaneView` and `SetupRibbonView` use several deliberately off-token point sizes for the
  mock/ribbon type. Don't fold them into `Tokens.Font` without a type-scale decision.

## Map

| Type | What it is |
|---|---|
| `OnboardingWindowController` | Owns the window: lifecycle, Done-vs-✕ dismissal, floating level + yield-to-Settings. |
| `OnboardingViewController` | Assembles spine + hero; row states, ribbon content, press dispatch, Done gate. |
| `OnboardingReason` | `.firstRun` vs `.permissionLost([RequiredPermission])` — drives the header message. |
| `SetupSpineRowView` / `SetupCardContent` / `SetupCardState` | One spine row: status strip, trailing marker, live/broken/browsed treatment, press target. |
| `SetupHeroHeadView` | Hero's top block: headline over the why line, nothing else. |
| `SetupPreviewFrameView` | Labelled well the rehearsal plays inside; flexible, clips to what's left. |
| `SetupRibbonView` / `RibbonContent` | Hero's lower half: status line, recovery paragraph, bottom bar, primary/skip/quiet link. |
| `SetupCheckRowView` | Sixth row: the automatic final check's pending/running/passed status strip. |
| `DemoPaneView` / `DemoMode` | Hero stage: mock swap, browse/settled rest rules, motion policy, Replay. |
| `DemoMockView` | Timeline base class: restartable score, settled-state hook, multi-stage seams. |
| `DemoPromptMockView` / `DemoSettingsMockView` / `DemoSettledMockView` | Privacy-dialog miniature, Settings-pane miniature, completion finale with one-shot ripple. |
| `DemoSystemAlertMockView` / `DemoLockIconView` | Classic macOS alert panel Remote Control's demo opens on; its gradient-filled padlock. |
| `DemoSettingsHandoffMockView` / `DemoStage` | Remote Control's two-stage first ask: alert handing off to the Settings pane. |
| `DemoWindowSurfaceView` / `DemoPushButtonView` / `DemoButtonEmphasis` / `DemoSwitchView` / `DemoSidebarView` / `DemoSettingsRowView` / `DemoGreekBarView` / `DemoPillView` / `DemoDotView` / `DemoCursorView` | Drawn mock parts: window body, buttons, switch, sidebar, list row, greeked label, pointer. |
| `SystemSettingsOpener` | `NSWorkspace` seam for opening a `SystemSettingsPane`, with a fallback root. |
| `ProminentButton` | Fill-tinted CTA button; key-window-aware title ink (forced white, or measured). |
| `IconTileView` / `RoundedContainerView` | Shared adaptive chrome: icon chip, grouped-inset card — no stock equivalent. |
