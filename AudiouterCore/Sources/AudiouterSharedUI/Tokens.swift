// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// **Warm Signal token module — the design-system entry point.**
///
/// GOVERNANCE RULE (locked, design-system-redesign Decision stream): this file
/// is the **only** place a custom (non-semantic) palette value may ever live
/// in this codebase. Every other call site — views, controllers, drawing
/// code across all five UI packages — must reach color, type, layout, and
/// material through `Tokens`, never through a raw literal `NSColor`,
/// `NSFont`, or magic number of its own.
///
/// `Tokens.Font`/`Tokens.Layout`/`Tokens.Material` are pure forwarding
/// aliases over stock values (`Font.microLabel`, the spec-named §2
/// micro-label voice, is the one custom Font case); `Tokens.Layout`
/// re-exports `PopoverColumnGrid`, which remains the geometry authority.
/// Only `Tokens.Color` holds real custom palette values — the warm surface
/// ladder + hairline and the signal/accent/permission instruments below,
/// each added together with its first consumer. `link` remains unadded
/// (its call site — the reference page — doesn't exist yet).
///
/// Do not add a case here for a color/font/material combination that isn't
/// already used (or, for the warm palette, consumed by the very same commit)
/// in the codebase — this module documents and centralizes what exists, it
/// does not speculate ahead of real usage.
public enum Tokens {

    // MARK: - Accent dial (spec §1.3, W1)

    /// The LIVE accent-dial position (Settings › Appearance › Accent —
    /// `AudiouterCore.AccentStyle`). The dial remaps ONLY ``Color/gold``,
    /// ``Color/ember``, and ``Color/glow``; `failure`/`caution`/`ringConnected`
    /// and all text tokens are never remapped (spec §1.3: red stays red,
    /// caution stays caution, in every mode).
    ///
    /// Defaults to `.fullGold` (the flagship look — and the one the checked-in
    /// popover goldens render, so a process that never touches this sees
    /// identical output). The app layer seeds it from `AppSettings.accentStyle`
    /// at launch; the Appearance pane writes it on every dial change. The
    /// switch lives INSIDE the three tokens' dynamic providers, so even an
    /// already-handed-out `NSColor` re-resolves against the CURRENT dial the
    /// next time AppKit asks — surfaces pick the new accent up on their next
    /// draw/rebuild with no color re-fetch needed. Main-thread-only by
    /// convention (same as every other AppKit token access here).
    ///
    /// Setting it BROADCASTS ``accentStyleDidChangeNotification`` — see there
    /// for why a re-resolving `NSColor` is not enough for every instrument.
    public static var accentStyle: AccentStyle = .fullGold {
        didSet {
            guard oldValue != accentStyle else { return }
            NotificationCenter.default.post(name: Tokens.accentStyleDidChangeNotification,
                                            object: nil)
        }
    }

    /// Posted (on `NotificationCenter.default`) whenever ``accentStyle``
    /// actually changes, from the property's own `didSet` — so a dial call
    /// site cannot forget to announce it.
    ///
    /// A `draw(_:)`-based instrument needs nothing but an invalidation: it
    /// re-reads its tokens every pass. A **layer-color** instrument does not —
    /// it stamps a resolved `CGColor` onto a `CALayer` and keeps showing it
    /// until something re-stamps. `viewDidChangeEffectiveAppearance` covers
    /// light/dark and `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`
    /// covers Increase Contrast, but the accent dial is neither — it is an
    /// app-internal setting, so it needs its own broadcast (the live bug: the
    /// Main Audio ring kept the old gold while the rail it joins had already
    /// re-tinted). An instrument that stamps `gold`/`ember`/`glow` into a
    /// layer must observe this the same way it observes the a11y notification.
    public static let accentStyleDidChangeNotification =
        Notification.Name("Audiouter.Tokens.accentStyleDidChange")

    // MARK: - Color

    /// Semantic color aliases plus the Warm Signal custom palette. The
    /// alias cases forward to stock `NSColor` class-properties; the
    /// custom warm/instrument cases below each carry a documented
    /// contrast rationale (the governance rule above).
    public enum Color {
        /// Primary label text. Alias of `NSColor.labelColor`.
        public static var label: NSColor { .labelColor }
        /// Secondary/subordinate label text (subtitles, hints). Alias of
        /// `NSColor.secondaryLabelColor`.
        public static var secondaryLabel: NSColor { .secondaryLabelColor }
        /// De-emphasized label text (sublabels, dimmed inline detail). Alias
        /// of `NSColor.tertiaryLabelColor`.
        public static var tertiaryLabel: NSColor { .tertiaryLabelColor }
        /// The system accent color. Alias of `NSColor.controlAccentColor`.
        ///
        /// NOT for the mixer's engaged-control chrome — use ``engagedChrome``.
        /// `controlAccentColor` follows the user's macOS accent setting, so on a
        /// default system it paints `#007AFF` onto a surface whose entire
        /// vocabulary is warm; and the states it was carrying there (muted, sync
        /// drawer open, row hovered, row selected) are meanings, which §Brand
        /// says never theme.
        public static var accent: NSColor { .controlAccentColor }

        /// **Engaged-control chrome**: the one tone every "this control is
        /// engaged / this row is picked out" surface on the mixer draws in — the
        /// mute pill and its glyph, the SYNC chip's engaged fill and border, and
        /// the row hover and selection washes. Strength, not hue, separates
        /// them: each site applies its own alpha
        /// (`PopoverColumnGrid.rowHoverWashAlpha` < `rowSelectionWashAlpha` <
        /// `mutePillFillAlpha` < full for a glyph or border).
        ///
        /// Deliberately NEUTRAL, and deliberately not the gold family. Gold
        /// means signal — in the mix, carrying audio — so painting MUTE gold
        /// states the opposite of what mute does, and a gold hover wash claims
        /// membership the pointer has not granted (spec §4.8: hover is a neutral
        /// wash, "never gold, never on the node"). `label` is what
        /// `DeviceIconWellView` and `WarmNameFieldCell` already wash with; it is
        /// dynamic, so it lifts the tone on the warm near-black ground and on
        /// the flat Circuit light one without introducing a hue to either.
        public static var engagedChrome: NSColor { label }
        /// Hairline/divider strokes. Alias of `NSColor.separatorColor`.
        public static var separator: NSColor { .separatorColor }
        /// Opaque window chrome background. Alias of
        /// `NSColor.windowBackgroundColor`. Consumed by
        /// `ReduceTransparencyFallbackView`'s default fill (A1) — the opaque
        /// stand-in for the system chrome MATERIALS
        /// (`Tokens.Material.windowBackground`/`popover`) while Reduce
        /// Transparency is on.
        public static var windowBackground: NSColor { .windowBackgroundColor }
        /// The color a decorative punch-out border is drawn in so a corner badge
        /// reads as separate from what's behind it. Alias of
        /// `NSColor.underPageBackgroundColor`. (Its former consumer, the corner
        /// connection dot `StatusDotView`, was retired for the halo ring in S1;
        /// the gold route-armed corner dot in a later task, spec §3.3, re-adopts
        /// this punch-out border.)
        public static var underPageBackground: NSColor { .underPageBackgroundColor }
        /// Hover/selection wash background for list rows (`GroupRowView`,
        /// `AppRowView`, `DeviceRowView`). Alias of
        /// `NSColor.selectedContentBackgroundColor`.
        public static var selectedContentBackground: NSColor { .selectedContentBackgroundColor }
        /// Faint recessed track fill behind a meter/indicator (`LevelMeterView`'s
        /// track layer). Alias of `NSColor.tertiarySystemFill`.
        public static var tertiarySystemFill: NSColor { .tertiarySystemFill }
        /// Destructive/error inline text (e.g. AppRowView's removed-app
        /// strikethrough label). Alias of `NSColor.systemRed`.
        public static var destructive: NSColor { .systemRed }
        /// Warning/failure sublabel and card tint (connection-diagnosis,
        /// onboarding failure card). Alias of `NSColor.systemOrange`.
        public static var warning: NSColor { .systemOrange }
        /// Informational note/banner tint (`SystemAirPlayNoteBannerView`'s
        /// `.info` tier — the system-double-path note, the takeover status
        /// strip's default state). Alias of `NSColor.systemBlue`. Declared as
        /// a plain semantic alias, matching how ``warning``/``destructive``
        /// are declared immediately above — a system dynamic color already
        /// resolves light/dark and a reasonable Increase Contrast response on
        /// its own, so it needs no `warmDynamic` trio or authored contrast
        /// rationale; that requirement (root AGENTS.md's "every case ships
        /// light + dark + Increase Contrast variants with a documented
        /// rationale") targets the CUSTOM warm-palette hex literals below,
        /// per this file's own governing comment ("the custom warm/instrument
        /// cases below each carry a documented contrast rationale") — not the
        /// semantic aliases in this section, none of which carry one either.
        public static var info: NSColor { .systemBlue }
        /// Opaque shadow color for card/panel drop shadows (`CardView`). Alias
        /// of `NSColor.black`.
        public static var shadow: NSColor { .black }
        /// Fully transparent fill, used to make a layer's background see
        /// through to a view behind it (`ControlPanelWindowController`). Alias
        /// of `NSColor.clear`.
        public static var clear: NSColor { .clear }

        // MARK: Warm Signal custom palette (V2, spec §1)
        //
        // LIGHT MODE = CIRCUIT (decision, Alec 2026-08-07 — see
        // docs/FIGMA-DESIGN-SYSTEM.md "Light mode = Circuit theme"): the
        // SCAFFOLDING tokens' light/lightHC values below are the resolved
        // hexes of the `Theme · Circuit` collection (`@sumup-oss/design-tokens`
        // light theme), pulled across from the Figma proposal. Instruments
        // (gold family, `failure`, `caution`, rings, meters incl. `meterTrack`,
        // fader hardware, permission hues) are NEVER Circuit-mapped in any
        // mode — they keep their authored Warm Signal values. Dark modes stay
        // pure Warm Signal. NOTE ON OLDER LIGHT RATIOS: rationales below that
        // measured a light instrument against the warm-paper grounds
        // (`#F4EFE7` canvas / `#FBF8F2` panel / `#ECE5D8` well) predate this
        // mapping; the Circuit grounds are LIGHTER, so every such
        // dark-instrument-on-light-ground ratio only improves (re-measured
        // values: docs/FIGMA-DESIGN-SYSTEM.md "Contrast, measured
        // 2026-08-07").
        //
        // The ONE place a custom (non-semantic) RGB value may live, per root
        // AGENTS.md's governance rule ("Every `Tokens.Color` case ships
        // light + dark + Increase Contrast variants with a documented
        // contrast rationale"). V2 (the popover canvas + card de-nest) is
        // the first consumer: the warm surface ladder + hairline from spec
        // §1.1 (dark) / §1.2 (light). Every case below
        // resolves LIVE via `NSColor(name:dynamicProvider:)` against both
        // the color's `NSAppearance` argument (light/dark) and the CURRENT
        // `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`
        // value every time AppKit asks for the resolved color — exactly
        // like `NSColor.labelColor` above already behaves for Dark Mode.
        // Never cache a `.cgColor`/`.set()` result outside a live draw or
        // `viewDidChangeEffectiveAppearance` refresh (see `WarmCanvasView`
        // in this target and `CardView`/its hairline sibling in
        // `AudiouterPopoverUI` for the pattern).

        /// The popover/content canvas — darkest rung, gradient base
        /// (§1.1/§1.2). Also the control-panel shell's bubble+beak fill
        /// (`ControlPanelBackingView.draw`, §5.4 — W8) so shell chrome and
        /// hosted transparent content read as one warm shape. No stated
        /// contrast floor (it's a background, not a foreground instrument),
        /// so no separate Increase Contrast value. Light = Circuit
        /// `bg/normal` `#FBFBF9`.
        public static var canvas: NSColor {
            warmDynamic(name: "canvas", dark: 0x16130F, light: 0xFBFBF9)
        }
        /// Canvas gradient top (§1.1/§1.2), paired with `canvas` by
        /// `WarmCanvasView`'s vertical gradient. No stated contrast floor.
        /// Light = Circuit `bg/normal`, SAME as `canvas` — the gradient
        /// deliberately collapses flat in light mode (Circuit decision).
        public static var canvasHi: NSColor {
            warmDynamic(name: "canvasHi", dark: 0x1B1712, light: 0xFBFBF9)
        }
        /// Card/panel fill — "the reference canvas a ring sits on" (§1).
        /// No stated contrast floor. Light = Circuit `bg/normal` (surface
        /// separation in light comes from hairlines, not fill steps).
        public static var panel: NSColor {
            warmDynamic(name: "panel", dark: 0x1D1915, light: 0xFBFBF9)
        }
        /// Raised well fill (icon well, blocked-checkbox fill, §1). No
        /// stated contrast floor. Light is `#F2F0EA` (Direction 04's authored
        /// light active fill, rehearsal-led Setup rebuild) — this REPLACES the
        /// earlier `#FBFBF9`, which was identical to `canvas`/`panel` and left
        /// light mode with no one-rung surface ladder at all (critique P1);
        /// `#F2F0EA` gives light a real raised step the way dark already has
        /// one. `WarmNameFieldCell` and `DeviceIconWellView` also draw with
        /// `raised`, so they pick up a faint warm well in light too —
        /// intended, not a side effect to chase out.
        public static var raised: NSColor {
            warmDynamic(name: "raised", dark: 0x241F1A, light: 0xF2F0EA)
        }
        /// Inset well fill (slider track trough, dropdown fill, §1). First
        /// consumer: `WarmFaderCell`'s recessed trough. CONTRAST RATIONALE
        /// (fader-legibility pass, 2026-07-22): the spec's dark hex
        /// (`#2B2620`) sat LIGHTER than `canvas` `#16130F`, so the "recess"
        /// read as a faintly raised strip and everything drawn in it (thumb
        /// 1.09:1, rim 1.21:1) sank; dark is re-tuned to `#100D0A` — darker
        /// than `canvas` (1.05:1, a true recess whose edge the `faderRim`
        /// carries) — which lifts every fill drawn on it (measured, WCAG
        /// relative luminance: `ringConnected` 4.82:1, `faderThumb` 4.44:1,
        /// `ember` 3.86:1, `gold` 10.51:1). Light was Circuit `bg/highlight`
        /// `#E8E6DC` rather than `bg/subtle` (Alec's call on the Circuit
        /// pull): `bg/subtle` measured 1.06:1 vs the flat Circuit `panel`,
        /// under the membership checklist's locked 1.10:1 surface-separation
        /// floor (`MembershipWellContrastTests`). Re-tuned to `#E2DFD3` —
        /// one step deeper, off the Circuit sheet — because Direction 04's
        /// light `raised` `#F2F0EA` measured 1.098:1 against `#E8E6DC`,
        /// under `MembershipWellContrastTests`' locked 1.15:1
        /// control-on-section floor. Measured against the new value: well
        /// vs panel 1.289:1 (floor 1.10), raised vs well 1.172:1 (floor
        /// 1.15), light `faderThumb` 3.12:1 (IC 4.56:1). Awaits Alec's
        /// palette sign-off alongside the other Direction-04 authored
        /// values. Backgrounds carry no IC variant (same precedent as
        /// `canvas`/`panel`/`raised`); the fills and rim drawn on the well
        /// brighten under IC instead.
        public static var well: NSColor {
            warmDynamic(name: "well", dark: 0x100D0A, light: 0xE2DFD3)
        }
        /// 1px section-divider hairline (§5.1 — the ONLY visual separation
        /// between de-nested cards now that they no longer draw their own
        /// material/shadow/rim). CONTRAST RATIONALE: dark carries a
        /// NORMATIVE floor in §1.1 ("≥3:1 vs `panel` only where
        /// load-bearing"). The spec's own literal hex (`#3A332B` on
        /// `panel` `#1D1915`) measures ≈1.40:1 by the WCAG relative-
        /// luminance formula — under floor. Per the spec's own escape valve
        /// ("any token below floor is brightened until it passes", §1) the
        /// Increase Contrast variant is a brightened warm-grey (`#786B5A`,
        /// ≈3.3:1 vs `panel`) rather than the literal spec hex; the BASE
        /// (non-IC) value stays exactly the spec'd hex since re-tuning base
        /// tokens for everyday legibility is the Wave-5 accessibility
        /// sweep's job, not V2's — V2 only has to make Increase Contrast
        /// itself clear the floor. Light's table entry states NO floor
        /// ("—"), but house rule 3 requires every case to ship an IC variant
        /// regardless. Light base is Circuit `border/normal` `#D0CDC3`
        /// rather than `border/divider` (Alec's call on the Circuit pull:
        /// `border/divider` measured 1.21:1 vs the flat Circuit `panel`,
        /// under the checklist's locked 1.25:1 separator floor —
        /// `border/normal` holds it at 1.53:1, still a Circuit-family hex);
        /// light IC is Circuit `fg/placeholder` `#76716B` (≈4.7:1 vs
        /// `bg/normal` `#FBFBF9`) — a hue-consistent Circuit greige, since a
        /// warm-tan divider would read off-family on the neutral Circuit
        /// ground.
        public static var hairline: NSColor {
            warmDynamic(name: "hairline", dark: 0x3A332B, darkHighContrast: 0x786B5A,
                       light: 0xD0CDC3, lightHighContrast: 0x76716B)
        }

        /// The under-name level meter's EMPTY-track fill (`LevelMeterView`'s
        /// `trackLayer`). Added in the UX spacing/contrast pass (2026-07-23,
        /// owner live-build feedback): the track was `NSColor.tertiarySystemFill`,
        /// a translucent grey that all but vanished on the warm `canvas` — "the
        /// empty part just disappears; you only ever see the moving fill." A
        /// meter reads a RATIO, so its full length (the denominator) must be
        /// visible at every level, including 0. This is a dedicated warm recess
        /// with a measured floor — visibly present but quiet, deliberately below
        /// the gold/ember fill drawn over it so the fill still wins.
        /// CONTRAST RATIONALE (WCAG relative luminance): dark `#4E463A` ≈ 2.0:1
        /// vs `canvas` `#16130F` (the empty channel reads as a recess), and the
        /// dimmest fill end `ember` `#8A6A2F` sits ≈ 1.9:1 OVER it so the fill
        /// boundary is legible; light `#CBBEA1` ≈ 1.6:1 vs `canvas` `#F4EFE7`
        /// (kept quiet so a full-length empty track never competes with the
        /// name). IC variants deepen the recess for definition (dark `#5A5245`,
        /// light `#BEAF90`) without turning the track into a signal.
        public static var meterTrack: NSColor {
            warmDynamic(name: "meterTrack", dark: 0x4E463A, darkHighContrast: 0x5A5245,
                       light: 0xCBBEA1, lightHighContrast: 0xBEAF90)
        }

        /// The Groups window sidebar's warm surface (T7, Q4-b): on macOS 26+,
        /// drawn as a PARTIAL-ALPHA wash (`SidebarViewController`'s
        /// `SidebarWarmSurfaceView` applies `.withAlphaComponent`, ~0.30, a
        /// taste dial) sitting between Apple's automatic Liquid Glass
        /// sidebar material and the outline view — there is no public API to
        /// tint the automatic glass itself, so this rides on top of it
        /// instead. Below macOS 26 (no glass to tint) the SAME color is drawn
        /// fully opaque as the sidebar's whole backing, standing in for the
        /// system `.sidebar` material. One case serves both roles because
        /// they're the same hue at two alpha levels, never two competing
        /// custom colors. CONTRAST RATIONALE: this is a background surface,
        /// not a foreground instrument (no stated floor, same precedent as
        /// `canvas`/`panel`/`raised`) — the values are chosen to sit near the
        /// existing warm surface ladder rather than against a measured floor.
        /// Measured for the record (WCAG relative luminance, opaque/fallback
        /// use): dark `#1F1A15` is 1.07:1 vs `canvas` `#16130F` / 1.01:1 vs
        /// `panel` `#1D1915` (a near-invisible step, deliberately — the
        /// sidebar should read as part of the same warm surface family, not a
        /// clashing plane); light `#F2EBDC` is 1.04:1 vs `canvas` `#F4EFE7` /
        /// 1.12:1 vs `panel` `#FBF8F2`, and 1.04:1 against today's neutral
        /// sidebar grey `#F0F0F0` it replaces — enough of a warm hue shift to
        /// read visibly warmer while staying a quiet background. Row text
        /// (`Tokens.Color.label`/`secondaryLabel`) is unaffected — those are
        /// system dynamic colors already proven legible over the warm
        /// canvas/panel ladder elsewhere, and the 26+ overlay's low alpha
        /// makes any shift negligible. IC variants (my picks, flagged for a
        /// future accessibility sweep like `ringConnected`'s) deepen/lighten
        /// for a slightly more distinct plane under Increase Contrast: dark
        /// `#2A241C` (1.21:1 vs `canvas`), light `#E9DFC9` (1.25:1 vs
        /// `panel`).
        public static var sidebarWarmTint: NSColor {
            warmDynamic(name: "sidebarWarmTint", dark: 0x1F1A15, darkHighContrast: 0x2A241C,
                       light: 0xF5F4ED, lightHighContrast: 0xE8E6DC)
        }

        // MARK: Connection-ring instruments (spec §3.2, S1)
        //
        // The two hues the halo connection ring (``HaloRingView``) needs. Teal
        // is RETIRED everywhere (spec §0 decision c / §3.1) — the ring is driven
        // by `Device.connectionState` ALONE, so there is no routing/teal ring
        // token. `connecting` reuses `ringConnected` (dashed form, not a new
        // color, per spec §3.2's "zero new colors" Reduce-Motion resolution).
        // These are the FIRST signal-color instruments to populate `Tokens.Color`
        // with real custom values; the gold/ember/glow accent instruments remain
        // the later S-chain's job (their call sites don't exist yet).

        /// The **connected** solid ring hue — a hue-neutral warm-grey (gold is
        /// reserved for the route-armed dot/meter). Also the color of the
        /// **connecting** dashed ring (form, not color, carries pending — §3.2).
        /// CONTRAST RATIONALE: spec §1.1/§1.2 set a NORMATIVE ≥3:1 floor tested
        /// at the 21 px ring circle, dark vs BOTH `panel` and `raised`, light vs
        /// `panel`. Measured (WCAG relative luminance): dark `#8D7D5E` = 4.35:1
        /// vs `panel` / 4.07:1 vs `raised`; light `#A08C66` = 3.08:1 vs `panel`
        /// (passes, tight — spec §10 flagged the exact hex for the Wave-5 sweep).
        /// Both clear the floor as-is, so the spec hexes stand (no escape-valve
        /// brightening needed). Increase-Contrast variants push further from
        /// `panel` for headroom (dark `#A99A78` = 6.31:1; light `#8A7550` =
        /// 4.18:1), per house rule 3 (every case ships an IC variant).
        public static var ringConnected: NSColor {
            warmDynamic(name: "ringConnected", dark: 0x8D7D5E, darkHighContrast: 0xA99A78,
                       light: 0xA08C66, lightHighContrast: 0x8A7550)
        }

        /// The **FAILURE-EXCLUSIVE** hue (house rule 8): the failed connection
        /// ring, the failed row's sublabel, and the diagnosis panel — never a
        /// meter (meters top out at `caution`, not here) and never remapped by
        /// the accent dial (spec §1.3: red stays red in every mode). CONTRAST
        /// RATIONALE: spec ≥3:1 floor vs `panel`. Measured: dark `#D9564A` =
        /// 4.48:1 vs `panel` / 4.18:1 vs `raised`; light `#BB3A2F` = 5.27:1 vs
        /// `panel` — both clear the floor as spec'd. IC variants raise contrast
        /// further while keeping the hue red (dark `#F26B5C` = 5.85:1; light
        /// `#A62A20` = 6.66:1).
        public static var failure: NSColor {
            warmDynamic(name: "failure", dark: 0xD9564A, darkHighContrast: 0xF26B5C,
                       light: 0xBB3A2F, lightHighContrast: 0xA62A20)
        }

        /// Warm warning **text** — the onboarding header's permission-lost
        /// message and the rehearsal-led Setup ribbon's status line (Direction
        /// 04). Distinct from ``warning``, which stays the bare `.systemOrange`
        /// alias other consumers keep using: that alias measures 2.24:1 vs
        /// `panel` in light, under the 4.5:1 text floor, so a text consumer
        /// needs an authored replacement rather than a re-tuned shared token.
        /// CONTRAST RATIONALE (>=4.5:1 vs both `canvas` and `panel`, both
        /// appearances; measured, WCAG relative luminance): dark `#D08A45` =
        /// 6.3:1 vs `panel` (`#16130F`); light `#A55B22` = 4.9:1 vs `panel`
        /// (`#FBFBF9`).
        public static var warningText: NSColor {
            warmDynamic(name: "warningText", dark: 0xD08A45, light: 0xA55B22)
        }

        /// Authored secondary text for onboarding surfaces that commit to the
        /// 4.5:1 text floor — the rehearsal-led Setup spine/ribbon's secondary
        /// copy (Direction 04). Distinct from ``secondaryLabel``, whose system
        /// `NSColor.secondaryLabelColor` alias measures 3.95:1 vs `panel` in
        /// light, under floor for body text. CONTRAST RATIONALE (>=4.5:1 vs
        /// `canvas`/`panel`/`raised`, both appearances; measured): dark
        /// `#B4ADA0` = 7.3:1 vs `panel`; light `#5C574C` = 7.1:1 vs `panel`
        /// (`#FBFBF9`).
        public static var inkSecondary: NSColor {
            warmDynamic(name: "inkSecondary", dark: 0xB4ADA0, light: 0x5C574C)
        }

        /// The earned-checkmark green — the rehearsal-led Setup spine/ribbon's
        /// granted-state glyph (Direction 04). No existing green token: the
        /// checkmarks it replaces used the bare `.systemGreen` alias, which
        /// measures 2.14:1 vs `panel` in light, under the 3:1 UI floor.
        /// CONTRAST RATIONALE (>=3:1 vs `panel`/`raised`, both appearances;
        /// measured): dark `#5FC27E` = clears floor vs `panel` (`#1D1915`);
        /// light `#2C7A46` = 5.2:1 vs `panel` (`#FBFBF9`).
        public static var success: NSColor {
            warmDynamic(name: "success", dark: 0x5FC27E, light: 0x2C7A46)
        }

        // MARK: Gold accent instruments (spec §1, S-BUS)
        //
        // THE accent (spec §1.1/§1.2): `gold` is the bus-node fill / route-armed
        // dot / meter hot end; `ember` is gold's dim companion (bus LINE ink /
        // meter low end). S-BUS (the membership bus, spec §4) is their FIRST
        // consumer — the filled node is a `gold` disc with an `ember` rim, and the
        // bus line is drawn in `ember` (spec §4.1/§4.2). `glow` (the bloom/halo,
        // §3.3) lives in the S2+S3 block below with its consumer, the
        // route-armed dot. Per the accent dial (spec §1.3) these three are the
        // ONLY tokens the Full-gold/Subtle/Follow-accent remap touches — that remap
        // is a later task; today they are the Full-gold defaults.
        //
        // CONTRAST RATIONALE (spec §1 "instruments clear ≥3:1 vs every surface"):
        // the bus draws on the warm `canvas`/`panel` surfaces. Measured (WCAG
        // relative luminance): dark `gold` `#E8B84B` ≈ 9.5:1 vs `panel` `#1D1915`.
        // `ember` is dimmer by design (it's the connecting line, not the node):
        // dark `#8A6A2F` ≈ 3.5:1 vs `panel`.
        //
        // BOTH LIGHT INSTRUMENTS ARE MEASURED AGAINST `well`, NOT ONLY `panel`
        // (2026-08-12): the Groups editor's sections are filled with `well`, so
        // the rail and its nodes run over the darker of the two surfaces. Light
        // ember's previous `#AC8C46` measured 3.07:1 on `panel` but only 2.55:1
        // on `well` `#E8E6DC`; light gold's previous `#A97F1E` measured 3.53:1
        // on `panel` but only 2.92:1 on `well` — both under the ≥3:1 non-text
        // floor on the ground they are actually drawn on. Retuned: light
        // `ember` `#9C7E3C` (3.71:1 panel / 3.07:1 well), light `gold`
        // `#A67C1E` (3.67:1 panel / 3.04:1 well) — gold darkened by a whisker
        // at its own ~41.5° hue, a re-tune, not a new accent.
        //
        // NOTE the consequence, deliberately accepted: with BOTH inks pinned
        // just over 3:1 on the same ground, their luminances are necessarily
        // close (gold 0.226 vs ember 0.223), so in LIGHT mode ember's "dimmer"
        // reads as LESS CHROMATIC rather than lighter — saturation 0.62 against
        // gold's 0.82 at the same ~41° hue, a muted brown beside a saturated
        // gold. Dark mode keeps the luminance hierarchy unchanged. Under
        // Increase Contrast the light pair BOTH deepen and the ordering flips
        // to gold-is-darker (light IC `gold` `#8A6614` 5.08:1 panel / 4.21:1
        // well vs light IC `ember` `#9A7A2E` 3.90:1 / 3.23:1) — gold still
        // reads as MORE, by ink weight and by chroma (0.86 vs 0.70). IC
        // variants are my picks, flagged for the Wave-5 sweep like
        // `ringConnected`'s: dark `gold` `#F2C75E`, dark `ember` `#A5824A`.

        /// THE gold accent — the bus-node fill (spec §4.2), route-armed dot, and
        /// meter hot end (spec §1). Remapped ONLY by the accent dial
        /// (``Tokens/accentStyle``, spec §1.3 — W1); never by anything else.
        /// Full-gold column = the spec §1.1/§1.2 hexes + the S-BUS IC picks.
        /// Subtle column: dark `#B99B53` is the spec §1.3 hex (measured 6.55:1
        /// vs dark `panel` — clears the ≥3:1 instrument floor); the spec names
        /// no light value and its hex measures 2.52:1 on paper `panel`, under
        /// floor, so light is a symmetrical desaturated-DEEPENED pick
        /// `#8F7B4A` (3.88:1 — same deepen-for-paper move §1.2's own gold
        /// makes). IC variants (dark `#CBAF6A` 8.22:1, light `#6F5E33`
        /// 5.96:1) are my picks, flagged for the Wave-5 sweep like
        /// `ringConnected`'s. Follow-system resolves `controlAccentColor`
        /// under the drawing appearance (no fixed hex to rationalize; the OS
        /// owns its contrast behavior).
        public static var gold: NSColor {
            accentDynamic(name: "gold",
                          // Light re-tuned #A67C1E → #9E761D when Direction 04
                          // deepened light `well` to #E2DFD3: measured 3.11:1 on
                          // well / 4.00:1 on panel (≥3.0 non-text floor, pinned
                          // in MembershipWellContrastTests).
                          full: WarmVariants(dark: 0xE8B84B, darkHighContrast: 0xF2C75E,
                                             light: 0x9E761D, lightHighContrast: 0x8A6614),
                          subtle: WarmVariants(dark: 0xB99B53, darkHighContrast: 0xCBAF6A,
                                               light: 0x8F7B4A, lightHighContrast: 0x6F5E33),
                          systemAccentScale: 1.0)
        }

        /// Gold's dim companion — the bus LINE ink (spec §4.1), the filled node's
        /// rim (§4.2), and the meter low end (§1). Dimmer than `gold` by design
        /// — by luminance in dark, by CHROMA in light (see the block above, and
        /// `MembershipWellContrastTests` for the pinned light floor).
        /// Accent-dial columns (§1.3 — W1): Subtle dark `#6D5B34` is the spec
        /// hex (2.66:1 vs dark `panel` — below the instrument floor exactly
        /// like Full-gold light ember already is: `ember` is a 2 pt line
        /// paired with high-contrast `gold` nodes, and the IC variant is the
        /// spec's escape valve — dark IC `#877146` 3.73:1). Subtle light
        /// `#AE9668` (2.69:1, IC `#8A744C` 4.23:1) is my symmetrical pick,
        /// flagged for the Wave-5 sweep. Follow-system = accent × 0.55
        /// luminance (spec's own formula; component-scaled sRGB).
        public static var ember: NSColor {
            accentDynamic(name: "ember",
                          // Light re-tuned #9C7E3C → #947637 (IC #9A7A2E →
                          // #8F702F, kept strictly darker than base) for the
                          // same well deepening: measured 3.21:1 on well /
                          // 4.13:1 on panel, still gold's dimmer, duller
                          // companion (sat gap 0.19, same hue family).
                          full: WarmVariants(dark: 0x8A6A2F, darkHighContrast: 0xA5824A,
                                             light: 0x947637, lightHighContrast: 0x8F702F),
                          subtle: WarmVariants(dark: 0x6D5B34, darkHighContrast: 0x877146,
                                               light: 0xAE9668, lightHighContrast: 0x8A744C),
                          systemAccentScale: 0.55)
        }

        /// **The membership rail's SPINE TONE** — `gold` while the spine is
        /// armed, its `ember` companion otherwise (Warm Signal v4 §Call-1
        /// rail-segment tone).
        ///
        /// It exists so the rail's line/hook/terminus (`BusRailOverlayView`)
        /// and the Main Audio ring the hook LANDS ON (`HaloRingView`'s
        /// connected stroke) resolve their tone from ONE place: the two are
        /// required to read as a single continuous line, and while each picked
        /// `gold`/`ember` for itself that agreement was pure convention — the
        /// accent dial moved one and not the other. Nothing else may consume
        /// this; a non-rail instrument wanting gold asks for ``gold``.
        public static func spineTone(armed: Bool) -> NSColor { armed ? gold : ember }

        // MARK: Signal-dot + meter instruments (spec §3.3 / §1, S2+S3)
        //
        // The remaining instrument hues the route-armed corner dot and the
        // warm meter gradient need. `caution` is the meter's CEILING (house
        // rule 8: FAILURE RED NEVER APPEARS IN A METER — a loud party can
        // never impersonate a failure); `glow` is the armed dot's bloom/halo;
        // `dotSocket` is the dot's dark "empty socket" resting state. Like
        // gold/ember, `caution` is never remapped by anything except… nothing:
        // spec §1.3 exempts it from the accent dial entirely (caution stays
        // caution in every mode).

        /// The meter caution/hot-zone CEILING (spec §1.1/§1.2 `caution`) — the
        /// warm meter gradient tops out HERE, never at `failure` red (house
        /// rule 8). CONTRAST RATIONALE: spec ≥3:1 floor vs `panel`. Measured
        /// (WCAG relative luminance): dark `#E29A3D` = 7.42:1 vs `panel`
        /// `#1D1915` (6.94:1 vs `raised`); light `#B3701C` = 3.77:1 vs `panel`
        /// `#FBF8F2` — both clear the floor as spec'd, so the spec hexes
        /// stand. IC variants push further from `panel` for headroom (my
        /// picks, flagged for the Wave-5 sweep like `ringConnected`): dark
        /// `#F2AC4F` = 8.98:1; light `#8F5A12` = 5.44:1.
        public static var caution: NSColor {
            warmDynamic(name: "caution", dark: 0xE29A3D, darkHighContrast: 0xF2AC4F,
                       light: 0xB3701C, lightHighContrast: 0x8F5A12)
        }

        /// The gold bloom/halo hue (spec §1.1/§1.2 `glow`) — the route-armed
        /// dot's static halo and its arm-transition bloom (§3.3). CONTRAST
        /// RATIONALE: the spec's table states NO floor for `glow` ("—",
        /// transient/halo only — it never carries meaning alone; the ≥3:1
        /// `gold` disc under it does). Measured for the record: dark `#FFD97A`
        /// = 12.86:1 vs `panel`; light `#E8B84B` = 1.74:1 vs `panel` (a soft
        /// paper halo — acceptable because floor-exempt). House rule 3 still
        /// requires IC variants: both reuse the base hexes (a halo needs no
        /// extra IC contrast; the disc's IC variant carries that).
        /// Accent-dial columns (§1.3 — W1): Subtle = **none** (the spec's "no
        /// glow shadow" — resolves fully `clear`, so every halo/bloom call
        /// site goes quiet with zero call-site changes); Follow-system =
        /// accent × 1.25, clamped.
        public static var glow: NSColor {
            accentDynamic(name: "glow",
                          full: WarmVariants(dark: 0xFFD97A, darkHighContrast: 0xFFD97A,
                                             light: 0xE8B84B, lightHighContrast: 0xE8B84B),
                          subtle: nil,
                          systemAccentScale: 1.25)
        }

        /// The Setup finale CTA's fill (`OnboardingViewController`'s "Start
        /// listening" button) — the gold family deepened until WHITE ink wins
        /// decisively. The flagship ``gold`` cannot fill a text-bearing
        /// control: its light hex `#A67C1E` gives white only 3.80:1 (under the
        /// 4.5:1 body floor) and black 5.52:1, and that mid-gold-plus-black
        /// pairing is what the owner rejected live (2026-08-11).
        /// CONTRAST RATIONALE (WCAG relative luminance; ink is white in every
        /// variant, and the fill must ALSO clear ≥3:1 vs ``canvas``, the Setup
        /// window's true background): light `#775913` = 6.52:1 white / 6.29:1
        /// vs canvas `#FBFBF9`; light IC `#7F5D10` = 6.04:1 / 5.83:1; dark
        /// `#815E0E` = 5.93:1 white / 3.12:1 vs canvas `#16130F`; dark IC
        /// `#866209` = 5.58:1 / 3.32:1. STRUCTURAL CEILING: the near-black
        /// dark canvas caps how deep the dark fill can go — pushing white ink
        /// to ≥6:1 in dark drops fill-vs-canvas under the 3:1 floor, so dark
        /// tops out ~5.9:1 (comfortably over the 4.5 minimum) and the dark IC
        /// variant spends its step on CANVAS separation, not ink (the canvas
        /// floor holds in every variant, per the project's measured-contrast
        /// commitment). All four hexes sit at
        /// ~42°, the flagship gold's own hue. NOT remapped by the accent dial:
        /// this fill is contrast-governed on both sides, and resolving it to
        /// the live accent would reintroduce exactly the unmeasured-ink
        /// problem it exists to close.
        public static var goldCTA: NSColor {
            warmDynamic(name: "goldCTA", dark: 0x815E0E, darkHighContrast: 0x866209,
                       light: 0x775913, lightHighContrast: 0x7F5D10)
        }

        // MARK: Fader instruments (spec §5 slider skin, fader-legibility pass)
        //
        // The two hues `WarmFaderCell` needs beyond the surface ladder — the
        // grabbable thumb and the trough's rim. Added with their consumer
        // (2026-07-22) after the owner's live feedback that the fader sank
        // into the warm-dark canvas: `raised` (the old thumb fill) measured
        // 1.09:1 vs the trough and `hairline` (the old rim) 1.21:1 —
        // invisible. `raised`/`hairline` keep their quiet surface roles
        // elsewhere (icon well, section dividers); the fader gets dedicated
        // instrument-grade values with measured floors.

        /// The fader THUMB fill (`WarmFaderCell.drawKnob`) — the daily-primary
        /// grab handle, held to an instrument floor: **≥3:1 vs BOTH `canvas`
        /// and `well`** in both themes. Measured (WCAG relative luminance):
        /// dark `#857762` = 4.44:1 vs `well` `#100D0A` / 4.24:1 vs `canvas`
        /// `#16130F`; light `#8A7A62` (a warm mid-brown knob on paper —
        /// `raised`'s pure white measured 1.25:1, unusable) = 3.12:1 vs
        /// `well` `#E2DFD3` / 3.64:1 vs `canvas` `#F4EFE7`. IC variants push
        /// further (dark `#9A8C74` = 5.88:1 / 5.62:1; light `#6E6050` =
        /// 4.86:1 / 5.31:1).
        public static var faderThumb: NSColor {
            warmDynamic(name: "faderThumb", dark: 0x857762, darkHighContrast: 0x9A8C74,
                       light: 0x8A7A62, lightHighContrast: 0x6E6050)
        }

        /// The fader trough's 1 px RIM (`WarmFaderCell.drawBar`) — load-bearing
        /// for the recess where no fill covers it (dark `well` sits 1.05:1 off
        /// `canvas`; the rim IS the trough's edge), so it gets a real floor
        /// where `hairline` (1.21:1 dark / 1.11:1 light vs `well`) has none.
        /// Measured: dark `#6B5F4E` = 3.11:1 vs `well` / 2.97:1 vs `canvas`;
        /// light `#9E8D6B` = 2.59:1 vs `well` / 2.83:1 vs `canvas` — kept
        /// just under strict 3:1 in light so a 1 px ring reads as a rim, not
        /// a stripe, on paper. IC variants clear 3:1 outright (dark `#786B5A`
        /// = 3.74:1 vs `well`; light `#8A7550` = 3.54:1 vs `well`).
        public static var faderRim: NSColor {
            warmDynamic(name: "faderRim", dark: 0x6B5F4E, darkHighContrast: 0x786B5A,
                       light: 0x9E8D6B, lightHighContrast: 0x8A7550)
        }

        /// The route-armed dot's **dark/empty socket** resting fill (spec §3.3
        /// "dark/empty socket (`#34302A` dark) when not armed"). CONTRAST
        /// RATIONALE: deliberately QUIET — the socket is the "nothing armed"
        /// state, spec'd with no floor (it must not compete with the lit gold
        /// dot; measured dark `#34302A` = 1.33:1 vs `panel`, a subtle recess).
        /// The spec names only the dark hex; light `#E0D8C6` (= 1.34:1 vs
        /// light `panel`, the symmetrical quiet recess) is my pick, flagged
        /// for the Wave-5 sweep like `ringConnected`'s hexes. IC variants
        /// deepen the recess for definition without making it a signal (dark
        /// `#4A443B` = 1.81:1; light `#C4B89E` = 1.85:1).
        public static var dotSocket: NSColor {
            warmDynamic(name: "dotSocket", dark: 0x34302A, darkHighContrast: 0x4A443B,
                       light: 0xE0D8C6, lightHighContrast: 0xC4B89E)
        }

        // MARK: Icon-well badge instrument (V6, raw-color elimination pass)
        //
        // `DeviceIconWellView`'s corner edit badge: a dark disc + light rim
        // sitting over the device/group icon GLYPH, whose color is arbitrary
        // (an SF Symbol tint, a user-picked icon) — not the app's own
        // light/dark surface. Like `shadow`, the hue is deliberately the SAME
        // in both themes (a theme-adaptive hue here would force the badge to
        // flip to a light disc in dark mode, which would in turn force the
        // pencil glyph it hosts to flip too — rejected: the badge's whole job
        // is to read the same "dark scrim, light rim" regardless of what it
        // sits over). Unlike `shadow`, it needs a real Increase Contrast
        // response, so it is NOT a plain alias: `scrimDynamic` steps the
        // ALPHA up under Increase Contrast — the only axis left once the hue
        // is already the endpoint (pure black / pure white) — while the base
        // hex stays fixed. First consumer: `DeviceIconWellView`'s badge fill/
        // border, previously two frozen `NSColor(white:alpha:)` literals
        // stamped into a `CALayer` once at init and never re-stamped, so they
        // sat outside Increase Contrast entirely and could never react to a
        // live appearance/a11y change.

        /// The corner edit badge's FILL (`DeviceIconWellView`) — a dark scrim,
        /// alpha 0.55 normally. CONTRAST RATIONALE: content-agnostic overlay,
        /// no stated floor (same precedent as `canvas`/`panel`/`raised` —
        /// it's a backdrop for the pencil glyph, not itself a foreground
        /// instrument). Increase Contrast steps alpha to 0.85 for real
        /// headroom against whatever it sits over.
        public static var iconWellBadge: NSColor {
            scrimDynamic(name: "iconWellBadge", hex: 0x000000, alpha: 0.55, highContrastAlpha: 0.85)
        }

        /// The rim paired with ``iconWellBadge`` — same reasoning, pure
        /// white, alpha 0.25 normally, stepping to 0.55 under Increase
        /// Contrast.
        public static var iconWellBadgeBorder: NSColor {
            scrimDynamic(name: "iconWellBadgeBorder", hex: 0xFFFFFF, alpha: 0.25, highContrastAlpha: 0.55)
        }

        // MARK: Permission-row instruments (colour-return pass, decisions Q1-Q6/NEW-1)
        //
        // Onboarding's four permission rows (`PermissionRowView`: System Audio,
        // Local Network, Remote Control, Speaker Sync) went to a single neutral
        // grey glyph in the warm pass (`85c2052`, which retired the old
        // `.systemBlue`/`.systemIndigo`/`.systemPurple`/`.systemTeal` tile
        // colours outright). This wave brings a DISTINCT hue back per row —
        // warmed and deepened off each permission's ORIGINAL macOS colour
        // family (Q1) — rather than one shared neutral: `.systemBlue` ->
        // `permissionSystemAudio` ("warm slate"), `.systemIndigo` ->
        // `permissionLocalNetwork` ("dusty plum"), `.systemPurple` ->
        // `permissionRemoteControl` ("muted mauve"). Speaker Sync (previously
        // `.systemTeal`) does NOT get a warmed teal — Q1 moves it into the
        // GOLD family instead (`permissionSpeakerSync`, a deepened brass), the
        // one gold-adjacent row.
        // Per Q3 the colour lands on the SF SYMBOL GLYPH ONLY — `IconTileView`
        // keeps its neutral `Tokens.Color.raised` fill and hairline rim
        // untouched, exactly like every other tile. Q2 (grant crossfades the
        // glyph to gold) is REVERSED (Alec, 2026-08-11): the identity hue is
        // PERMANENT in every status — the row's "Allowed" status chip alone
        // carries the granted state. Because the hue is a standing identity
        // rather than a resting state, the Full columns carry real saturation
        // (46-79 depending on family); the Subtle column stays muted, since
        // muting is that dial position's whole job.
        //
        // DIAL RESOLUTION (Q5/NEW-1) deliberately does NOT reuse `accentDynamic`
        // (see `permissionDynamic` below for the two concrete reasons, verified
        // by reading `accentDynamic`/`systemAccentColor` above): routing four
        // distinct identity hues through `accentDynamic`'s `.systemAccent`
        // branch would resolve all of them to the SAME `controlAccentColor`-
        // scaled value, erasing the very distinction this wave adds back; and
        // its `subtle: nil -> .clear` fallback is a halo-only escape hatch that
        // would render an invisible glyph here instead of a muted one.
        // `permissionDynamic` resolves `.subtle` to the authored SUBTLE column
        // (Q5 — the dial genuinely mutes these four) and BOTH `.fullGold` and
        // `.systemAccent` to the authored FULL column (NEW-1 — Follow-System
        // does not collapse these onto the live accent).
        //
        // RESERVED BANDS (`AppTetherColor.ReservedBand` applies the identical
        // reasoning to derived tether hues; the bands themselves are declared
        // there, not duplicated here): every hue below clears the gold/amber
        // window `[28°,68°)` — landing in it would misread an ungranted row as
        // already "granted" — and the failure-red window
        // `[0°,12°) ∪ [350°,360°)`. Measured hues (own-theme Full column,
        // stable within a few degrees across every dial column/appearance/
        // Increase-Contrast variant since mostly saturation/brightness shift):
        // `permissionSystemAudio` ~207-210° (blue, already clear of both
        // bands), `permissionLocalNetwork` ~265-272° (indigo warmed toward
        // magenta), `permissionRemoteControl` ~319-325° (purple warmed toward
        // pink), `permissionSpeakerSync` ~23-26° — strictly BELOW the gold
        // band's 28° floor, the same terracotta corridor
        // `AppTetherColor.steer` escapes a raw hue into when it steers off
        // gold. That keeps all four ≥45° apart (measured minimum 47°) from
        // each other and from both reserved bands in every one of the 32
        // authored hexes (mutual-distinguishability check, Q1 criterion 4).
        //
        // CONTRAST (WCAG 2.x relative luminance — same formula as
        // `AppTetherColorTests.relativeLuminance`/`contrastRatio`): every one
        // of the 32 hexes below (4 tokens x {Full,Subtle} x {dark,
        // darkHighContrast,light,lightHighContrast}) measures >=3:1 against
        // BOTH `Tokens.Color.panel` and `Tokens.Color.raised` in its own theme
        // — see each case's own measured numbers. The Subtle column is
        // AUTHORED by hand, not derived by a desaturation formula, matching
        // the `gold`/`ember` precedent: a mechanically-desaturated Subtle for
        // `permissionSpeakerSync`'s Full dark hue undershot the floor
        // (~2.8:1) before being hand-raised back above it — exactly the
        // silent under-floor failure this rule exists to catch.
        //
        // First consumer: `PermissionRowView`'s `IconTileView` per-row resting
        // glyph tint, one call site per row (T2 of this wave, landing
        // immediately after this case addition).

        /// Warmed & deepened from `.systemBlue` (System Audio's retired tile
        /// colour) — a blue "warm slate," the row's PERMANENT identity glyph
        /// tint (granting never recolours it — the status chip carries state).
        /// Hue ~207-210° in every column/appearance — its own family, already
        /// clear of both reserved bands (gold/amber `[28°,68°)`, failure-red
        /// `[0°,12°)∪[350°,360°)`). CONTRAST RATIONALE (>=3:1 vs BOTH `panel`
        /// and `raised`, both themes, both dial columns; measured): Full dark
        /// `#5B93C4` = 5.34:1 vs `panel` / 4.99:1 vs `raised`; Full light
        /// `#3A79AE` = 4.48:1 vs `panel`. Subtle
        /// (authored, not derived — the dial's mute stays muted): dark
        /// `#6C7680` = 3.78:1 vs `panel` / 3.53:1 vs `raised`; light
        /// `#737D86` = 3.96:1 vs `panel` / 4.19:1 vs `raised`. IC variants
        /// push further from both surfaces: Full dark `#8FB6DC` = 8.23:1 vs
        /// `panel`, Full light `#2A5C89` = 6.78:1 vs `panel`; Subtle dark
        /// `#8C98A3` = 5.94:1 vs `panel`, Subtle light `#4B535B` = 7.37:1 vs
        /// `panel`. Mutually distinguishable from the other three permission
        /// hues (~271°/~320°/~23°) by >=47° in every column.
        public static var permissionSystemAudio: NSColor {
            permissionDynamic(name: "permissionSystemAudio",
                              full: WarmVariants(dark: 0x5B93C4, darkHighContrast: 0x8FB6DC,
                                                 light: 0x3A79AE, lightHighContrast: 0x2A5C89),
                              subtle: WarmVariants(dark: 0x6C7680, darkHighContrast: 0x8C98A3,
                                                   light: 0x737D86, lightHighContrast: 0x4B535B))
        }

        /// Warmed & deepened from `.systemIndigo` (Local Network's retired tile
        /// colour) — a "dusty plum," warmed toward magenta off indigo's cooler
        /// blue-purple; the row's PERMANENT identity tint (see
        /// ``permissionSystemAudio``). Hue ~265-272° in every
        /// column/appearance, clear of both reserved bands. CONTRAST
        /// RATIONALE (measured): Full dark `#9A6BC6` = 4.40:1 vs `panel` /
        /// 4.12:1 vs `raised`; Full light `#7749B5` = 5.95:1 vs `panel`.
        /// Subtle (authored): dark `#776882` = 3.40:1 vs
        /// `panel` / 3.18:1 vs `raised`; light `#7A6E82` = 4.52:1 vs `panel` /
        /// 4.79:1 vs `raised`. IC variants: Full dark `#BE9BDD` = 7.42:1 vs
        /// `panel`, Full light `#5B3690` = 8.53:1 vs `panel`; Subtle dark
        /// `#9988A6` = 5.35:1 vs `panel`, Subtle light `#4F4557` = 8.53:1 vs
        /// `panel`. Mutually distinguishable from the other three permission
        /// hues (~208°/~320°/~23°) by >=47° in every column.
        public static var permissionLocalNetwork: NSColor {
            permissionDynamic(name: "permissionLocalNetwork",
                              full: WarmVariants(dark: 0x9A6BC6, darkHighContrast: 0xBE9BDD,
                                                 light: 0x7749B5, lightHighContrast: 0x5B3690),
                              subtle: WarmVariants(dark: 0x776882, darkHighContrast: 0x9988A6,
                                                   light: 0x7A6E82, lightHighContrast: 0x4F4557))
        }

        /// Warmed & deepened from `.systemPurple` (Remote Control's retired
        /// tile colour) — a "muted mauve," warmed toward pink off purple's
        /// cooler violet; the row's PERMANENT identity tint (see
        /// ``permissionSystemAudio``). Hue ~319-325° in every
        /// column/appearance, clear of both reserved bands. CONTRAST
        /// RATIONALE (measured): Full dark `#C066A2` = 4.71:1 vs `panel` /
        /// 4.40:1 vs `raised`; Full light `#AF3E7F` = 5.31:1 vs `panel`.
        /// Subtle (authored): dark `#806977` = 3.50:1 vs
        /// `panel` / 3.27:1 vs `raised`; light `#86737F` = 4.15:1 vs `panel` /
        /// 4.40:1 vs `raised`. IC variants: Full dark `#D494C0` = 7.32:1 vs
        /// `panel`, Full light `#852B66` = 8.00:1 vs `panel`; Subtle dark
        /// `#A3899A` = 5.49:1 vs `panel`, Subtle light `#5B4A55` = 7.75:1 vs
        /// `panel`. Mutually distinguishable from the other three permission
        /// hues (~208°/~271°/~23°) by >=47° in every column.
        public static var permissionRemoteControl: NSColor {
            permissionDynamic(name: "permissionRemoteControl",
                              full: WarmVariants(dark: 0xC066A2, darkHighContrast: 0xD494C0,
                                                 light: 0xAF3E7F, lightHighContrast: 0x852B66),
                              subtle: WarmVariants(dark: 0x806977, darkHighContrast: 0xA3899A,
                                                   light: 0x86737F, lightHighContrast: 0x5B4A55))
        }

        /// Speaker Sync's retired tile colour was `.systemTeal`, but per Q1 it
        /// does NOT get a warmed teal — it moves INTO the gold family instead,
        /// a deepened "brass"; the row's PERMANENT identity tint (see
        /// ``permissionSystemAudio``). Hue ~23-25° in every
        /// column/appearance: strictly BELOW the gold/amber reserved band's
        /// 28° floor (the same terracotta corridor `AppTetherColor.steer`
        /// escapes a raw hue into off gold), so the row reads as warm/golden-
        /// adjacent WITHOUT impersonating the accent `gold` (~42°) the app's
        /// armed instruments wear — also clear of the failure-red band.
        /// CONTRAST RATIONALE (measured): Full dark `#B86F41` = 4.48:1 vs
        /// `panel` / 4.19:1 vs `raised`; Full light `#A55B22` = 4.92:1 vs
        /// `panel`. Subtle (authored): dark `#876A59` =
        /// 3.52:1 vs `panel` / 3.29:1 vs `raised`; light `#796356` = 5.31:1
        /// vs `panel` / 5.63:1 vs `raised`. IC variants: Full dark `#D4996E`
        /// = 7.14:1 vs `panel`, Full light `#7E4116` = 7.63:1 vs `panel`;
        /// Subtle dark `#A88672` = 5.26:1 vs `panel`, Subtle light `#524036`
        /// = 9.23:1 vs `panel`. Mutually distinguishable from the other three
        /// permission hues (~208°/~271°/~320°) by >=47° in every column.
        public static var permissionSpeakerSync: NSColor {
            permissionDynamic(name: "permissionSpeakerSync",
                              full: WarmVariants(dark: 0xB86F41, darkHighContrast: 0xD4996E,
                                                 light: 0xA55B22, lightHighContrast: 0x7E4116),
                              subtle: WarmVariants(dark: 0x876A59, darkHighContrast: 0xA88672,
                                                   light: 0x796356, lightHighContrast: 0x524036))
        }

        // MARK: FEED-pill instruments (Circuit light pass, 2026-08-07 decision)
        //
        // The two tokens `FeedPillView` needs now that the pill reads by FILL
        // ALONE (its border measured 1.14:1 dark / 1.00:1 light vs its own
        // fill — decorative in both modes, so it was removed rather than
        // tuned). First consumer: `FeedPillView` (fill) + `DeviceRowView`'s
        // segment composition (text), replacing the stock
        // `NSColor.quaternaryLabelColor` wash that measured a near-invisible
        // 1.31:1 dark / 1.21:1 light vs `canvas`.

        /// The FEED pill's fill (`FeedPillView`'s background) — a quiet but
        /// PRESENT wash so a short value like "System" reads as a small
        /// object. CONTRAST RATIONALE (measured for the 2026-08-07 decision):
        /// dark `#38322B` = 1.46:1 vs `canvas` `#16130F` (was 1.31 on the
        /// quaternary wash); light = Circuit `border/normal` `#D0CDC3` =
        /// 1.54:1 vs `bg/normal` `#FBFBF9` (was 1.21). No instrument floor —
        /// the pill's TEXT carries the signal; the failure-red error text
        /// measures 3.24:1 on the dark fill and 3.50:1 on the light fill, so
        /// an error still clears the graphical-object bar on the fill itself.
        /// IC variants deepen the wash for definition (dark `#423B33`; light
        /// = Circuit `bg/neutral-strong` `#C7C3B3`).
        public static var feedPillFill: NSColor {
            warmDynamic(name: "feedPillFill", dark: 0x38322B, darkHighContrast: 0x423B33,
                       light: 0xD0CDC3, lightHighContrast: 0xC7C3B3)
        }

        /// The FEED pill's NEUTRAL text tone — mode-aware rather than a
        /// forked component (design-system rule: "when one token cannot serve
        /// both grounds, make it mode-aware"): resolves ``secondaryLabel`` in
        /// dark but ``label`` in light, because secondary text on the light
        /// `feedPillFill` measured 4.54:1 (barely body-passing) while `label`
        /// lifts it to 10.66:1. Dark keeps the quieter secondary voice, which
        /// already clears body contrast on the dark fill. App-tinted segments
        /// keep their tether colors; this covers the neutral main-mix word,
        /// the "+N" overflow pill, and the AP1 micro-tag.
        public static var feedPillText: NSColor {
            NSColor(name: NSColor.Name("WarmSignal.feedPillText")) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark ? .secondaryLabelColor : .labelColor
            }
        }

        // MARK: Alignment-wizard stage instruments (wizard-stage v2 spec §2.1)
        //
        // Eight tokens for the BT-alignment wizard's stage plate — a FIXED
        // dark instrument ground that never themes with the window (owner
        // ruling 2026-08-23 #1). The six "instrument" tokens below
        // (`stagePlate` through `fuseWhite`) pass the SAME hex for dark and
        // light on purpose: the plate is a physical gauge face, not themed
        // chrome, so it reads identically in both appearances (spec's "dark
        // screen set into a light chassis" framing). `syncSignalDeep`/
        // `partySignalDeep` are the opposite case — themed chrome companions
        // that DO vary by appearance, used only where the identity hue must
        // sit on the THEMED window ground (plate rim/keycap tint in light
        // mode) rather than the fixed plate itself. None of these eight are
        // accent-dial remapped (spec §2.2): the stage no longer borrows
        // `gold`/`glow`, so the dial's remap cannot collide with "which
        // speaker" identity.

        /// The stage's instrument ground — the plate itself (spec §2.1).
        /// Background token, no contrast floor (canvas precedent: an
        /// instrument face is a surface, not a foreground object). Fixed
        /// both appearances; in light mode this is deliberately a dark
        /// screen set into a light chassis, per the spec's framing.
        public static var stagePlate: NSColor {
            warmDynamic(name: "stagePlate", dark: 0x100B07, darkHighContrast: 0x080604,
                       light: 0x100B07, lightHighContrast: 0x080604)
        }

        /// Wire + ticks + dormant-state color on the plate (spec §2.1).
        /// CONTRAST RATIONALE: measured 3.14:1 vs `stagePlate` (WCAG
        /// relative luminance), clearing the spec's 3:1 non-text floor.
        /// Fixed both appearances.
        public static var stageRule: NSColor {
            warmDynamic(name: "stageRule", dark: 0x6A5F50, darkHighContrast: 0x7A6E5C,
                       light: 0x6A5F50, lightHighContrast: 0x7A6E5C)
        }

        /// The value stamp on the plate (spec §2.1). CONTRAST RATIONALE:
        /// measured 16.19:1 vs `stagePlate`, clearing the spec's ≥16:1
        /// floor. Fixed both appearances.
        public static var stageInk: NSColor {
            warmDynamic(name: "stageInk", dark: 0xEFE9DD, darkHighContrast: 0xFFFFFF,
                       light: 0xEFE9DD, lightHighContrast: 0xFFFFFF)
        }

        /// Target light — the speaker being aligned (spec §2.1/§0 ruling 1:
        /// the website's Sync Green, one owner-decided value in both
        /// themes, 2026-08-12). Instrument (fixed): names WHICH speaker,
        /// never state — "is it live" stays gold everywhere else in the
        /// app. CONTRAST RATIONALE: measured 14.73:1 vs `stagePlate` (spec's
        /// "~14:1"). Fixed both appearances.
        public static var syncSignal: NSColor {
            warmDynamic(name: "syncSignal", dark: 0x2BFF8F, darkHighContrast: 0x2BFF8F,
                       light: 0x2BFF8F, lightHighContrast: 0x2BFF8F)
        }

        /// `syncSignal`'s THEMED CHROME companion — the target's plate
        /// rim/keycap tint on the themed window ground in light mode, where
        /// electric green measures only ≈1.3:1 on near-white (invisible).
        /// Dark reuses the electric value at FULL strength (owner ruling
        /// 2026-08-23, superseding spec §2.2's "dark = electric value at
        /// 0.45 alpha over `raised`" — at 0.45 the rims measured olive and
        /// mauve, 45% of the lights' chroma). CONTRAST
        /// RATIONALE: light `#0B7A45` measured 4.74:1 vs `raised` / 5.22:1
        /// vs `canvas`, clearing the spec's required ≥3:1 floor on both
        /// light grounds; IC `#086237` deepens further.
        public static var syncSignalDeep: NSColor {
            warmDynamic(name: "syncSignalDeep", dark: 0x2BFF8F, darkHighContrast: 0x2BFF8F,
                       light: 0x0B7A45, lightHighContrast: 0x086237)
        }

        /// Reference light — the speaker being compared against (spec
        /// §2.1/§0 ruling 1: the website's Party Magenta). Instrument
        /// (fixed): names WHICH speaker, never state. CONTRAST RATIONALE:
        /// measured 9.71:1 vs `stagePlate` (spec's "~9:1"). Fixed both
        /// appearances.
        public static var partySignal: NSColor {
            warmDynamic(name: "partySignal", dark: 0xFF90E9, darkHighContrast: 0xFF90E9,
                       light: 0xFF90E9, lightHighContrast: 0xFF90E9)
        }

        /// `partySignal`'s themed chrome companion — "the magenta ramp's own
        /// dark end" (spec §2.1), used the same way as `syncSignalDeep`.
        /// CONTRAST RATIONALE: light `#752C68` measured 7.95:1 vs `raised` /
        /// 8.75:1 vs `canvas`, clearing the spec's required ≥3:1 floor; IC
        /// `#5E2354` deepens further.
        public static var partySignalDeep: NSColor {
            warmDynamic(name: "partySignalDeep", dark: 0xFF90E9, darkHighContrast: 0xFF90E9,
                       light: 0x752C68, lightHighContrast: 0x5E2354)
        }

        /// The fused/locked hue — additive-fusion climax color, transient +
        /// locked ring (spec §2.1/§2.2). CONTRAST RATIONALE: measured
        /// 17.98:1 vs `stagePlate` (spec's "~18:1"). Fixed both appearances.
        public static var fuseWhite: NSColor {
            warmDynamic(name: "fuseWhite", dark: 0xFFF4E2, darkHighContrast: 0xFFF4E2,
                       light: 0xFFF4E2, lightHighContrast: 0xFFF4E2)
        }

        /// Neutral plate / together-bar rim (spec §2.1) — fixes layout
        /// finding F1 (`faderRim` measured 2.62:1 vs `raised`, under floor).
        /// REQUIRED ≥3:1 vs BOTH `raised` and `canvas`, both appearances.
        /// CONTRAST RATIONALE (measured, WCAG relative luminance): dark
        /// `#7E7160` = 3.44:1 vs `raised` / 3.90:1 vs `canvas`; light
        /// `#857868` = 3.77:1 vs `raised` / 4.15:1 vs `canvas` — the spec's
        /// approximate hexes already clear the floor on both sides, so kept
        /// verbatim (decision: tune the hex only on a miss, never lower a
        /// floor). IC deepens further: dark `#8F8271` = 4.35:1 / 4.94:1;
        /// light `#685C4C` = 5.72:1 / 6.29:1. Arbiter:
        /// `AlignmentTokenContrastTests`.
        public static var plateRim: NSColor {
            warmDynamic(name: "plateRim", dark: 0x7E7160, darkHighContrast: 0x8F8271,
                       light: 0x857868, lightHighContrast: 0x685C4C)
        }
    }

    // MARK: - Type

    /// Typography aliases. Every case forwards to the exact
    /// `NSFont.systemFont`/`.boldSystemFont`/`.menuFont` call and size the
    /// codebase already uses (verified via `git grep -n "NSFont\."` across
    /// the same five UI packages) — with ONE spec-named custom exception,
    /// ``microLabel`` (the Warm Signal §2 micro-label voice, added with its
    /// first consumer, S3's MUTED sublabel token).
    public enum Font {
        /// Standard body text at the system's default control size — the most
        /// common label font in the app (row names, headings, form labels).
        /// Alias of `NSFont.systemFont(ofSize: NSFont.systemFontSize)`.
        public static var body: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }
        /// Body text, semibold weight — emphasized headings/titles at the
        /// standard size (e.g. permission-row titles, form section titles).
        public static var bodyEmphasized: NSFont {
            .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        }
        /// Body text, bold — used for an active/selected row name
        /// (`GroupRowView`). Alias of `NSFont.boldSystemFont(ofSize:)`.
        public static var bodyBold: NSFont { .boldSystemFont(ofSize: NSFont.systemFontSize) }
        /// A heading one step up from body (e.g. device-detail/group-editor
        /// name fields, +3pt semibold). Alias of
        /// `NSFont.systemFont(ofSize: NSFont.systemFontSize + 3, weight: .semibold)`.
        public static var heading: NSFont {
            .systemFont(ofSize: NSFont.systemFontSize + 3, weight: .semibold)
        }
        /// A large message title (mixer-window empty state, +2pt regular).
        /// Alias of `NSFont.systemFont(ofSize: NSFont.systemFontSize + 2)`.
        public static var titleLarge: NSFont {
            .systemFont(ofSize: NSFont.systemFontSize + 2)
        }
        /// A message subtitle paired with `titleLarge` (mixer-window empty
        /// state, −1pt regular). Alias of
        /// `NSFont.systemFont(ofSize: NSFont.systemFontSize - 1)`.
        public static var subtitleLarge: NSFont {
            .systemFont(ofSize: NSFont.systemFontSize - 1)
        }
        /// The small system font size — the app's secondary/detail text size
        /// (sublabels, readouts, hints, footers). Alias of
        /// `NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)`.
        public static var caption: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize) }
        /// Caption text, medium weight (appearance-tile labels, section
        /// sub-headers in the popover header row).
        public static var captionMedium: NSFont {
            .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        }
        /// Caption text, semibold weight (row titles set at the small size —
        /// PTP helper row, credits label, advanced-section labels, sidebar
        /// add-group field).
        public static var captionEmphasized: NSFont {
            .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        }
        /// The stock menu-item font, used where inline attributed text must
        /// match a real `NSMenuItem`'s rendering (`AppRowView`). Alias of
        /// `NSFont.menuFont(ofSize: 0)`.
        public static var menuItem: NSFont { .menuFont(ofSize: 0) }
        /// The **micro-label voice** (Warm Signal v3 §2): SF Mono, ~8.5–11 pt,
        /// weight 700, UPPERCASE, tracked +0.09–0.11 em — the small-caps state
        /// vocabulary (`LIVE`/`MUTED`/`IDLE`) and section captions. 8.5 pt is
        /// the bottom of the spec's band, sized to ride as a leading token
        /// INSIDE the existing 10 pt sublabel line without changing its height
        /// (§3.5 no-reflow rule). The +0.09 em tracking rides alongside as
        /// ``microLabelKern`` (an `NSAttributedString.Key.kern` value, since
        /// tracking isn't a font attribute in AppKit). The first spec-named
        /// custom `Tokens.Font` case (system monospaced ≈ SF Mono).
        public static var microLabel: NSFont {
            .monospacedSystemFont(ofSize: 8.5, weight: .bold)
        }
        /// The `.kern` value (in points) realizing the micro-label voice's
        /// +0.09 em tracking at ``microLabel``'s 8.5 pt size (0.09 × 8.5).
        public static var microLabelKern: CGFloat { 0.765 }
        /// The BT sync drawer's click-to-edit value field. Monospaced digits
        /// so the number keeps its width as it steps. Sized to sit with the
        /// row's own controls, not to shout — two live findings cut it down in
        /// turn (a 26 pt version dwarfed everything around it and clipped
        /// "−410" to "−41"; a 15 pt one still overhung the small buttons it now
        /// shares a band with). One point over ``caption``, medium weight, is
        /// enough for the editable number to read as the focal control.
        public static var syncReadout: NSFont {
            .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .medium)
        }
        /// The alignment-wizard plate keycap glyph voice (wizard-stage v2
        /// spec §3: "←"/"→"/"SPACE"/"⏎" chips on `AlignmentPlateButton`).
        public static var keycap: NSFont {
            .monospacedSystemFont(ofSize: 11, weight: .medium)
        }
    }

    // MARK: - Layout

    /// Layout tokens. Most of these are forwarding aliases over
    /// `PopoverColumnGrid`, which remains the geometry authority for row/card
    /// layout — it is not moved, renamed, or duplicated; code that wants "the
    /// app's layout tokens" has one import (`Tokens.Layout`) without new call
    /// sites needing to know the underlying constants still live there.
    ///
    /// The three corner-radius constants below are the exception: each
    /// consolidates a value that used to be typed out independently at two or
    /// more call sites in different UI packages (V10 cleanup) — this file is
    /// their one real declaration, not a forwarding alias over anything else.
    public enum Layout {
        /// Alias of `PopoverColumnGrid.leadingInset`.
        public static var leadingInset: CGFloat { PopoverColumnGrid.leadingInset }
        /// Alias of `PopoverColumnGrid.indentedLeadingInset`.
        public static var indentedLeadingInset: CGFloat { PopoverColumnGrid.indentedLeadingInset }
        /// Alias of `PopoverColumnGrid.trailingInset`.
        public static var trailingInset: CGFloat { PopoverColumnGrid.trailingInset }
        /// Alias of `PopoverColumnGrid.iconWidth`.
        public static var iconWidth: CGFloat { PopoverColumnGrid.iconWidth }
        /// Alias of `PopoverColumnGrid.sliderWidth`.
        public static var sliderWidth: CGFloat { PopoverColumnGrid.sliderWidth }
        /// Alias of `PopoverColumnGrid.readoutWidth`.
        public static var readoutWidth: CGFloat { PopoverColumnGrid.readoutWidth }
        /// Alias of `PopoverColumnGrid.muteWidth`.
        public static var muteWidth: CGFloat { PopoverColumnGrid.muteWidth }
        /// Alias of `PopoverColumnGrid.trailingControlWidth`.
        public static var trailingControlWidth: CGFloat { PopoverColumnGrid.trailingControlWidth }
        /// Alias of `PopoverColumnGrid.bodyRowHeight`.
        public static var bodyRowHeight: CGFloat { PopoverColumnGrid.bodyRowHeight }

        /// The standard rounded-panel corner radius: the control-panel
        /// shell's bubble body (`ControlPanelBackingView`) and the
        /// quit-in-progress HUD (`AppDelegate.QuittingIndicatorPanel`) both
        /// draw at this radius — previously two independent `12` literals.
        public static let panelCornerRadius: CGFloat = 12
        /// The inset warning/note banner corner radius shared by
        /// `SilenceFallbackBannerView` and `SystemAirPlayNoteBannerView` —
        /// previously two independent `11` literals.
        public static let bannerCornerRadius: CGFloat = 11
        /// The System Settings "grouped inset-list" card corner radius,
        /// shared by onboarding's `RoundedContainerView` (the permission
        /// card) and the Groups window's `GroupedSectionView` — both
        /// explicitly modeled on the same macOS grouped-list idiom;
        /// previously two independent `10` literals.
        public static let groupedSectionCornerRadius: CGFloat = 10
    }

    // MARK: - Motion

    /// Motion durations shared across surfaces (spec §6, "one motion
    /// language"). Only values a SECOND surface would otherwise re-declare
    /// belong here — a duration used in exactly one place stays where it is
    /// used.
    public enum Motion {
        /// How long ANY collapsible element in the app takes to unfold into —
        /// or fold out of — its host, on one curve (`.easeInEaseOut`): the
        /// popover's inserted rows, device-type subsections and card bodies
        /// (`CardView.setBodyCollapsed`). The Setup window's permission cards
        /// were replaced by the non-collapsing spine (Direction 04), so it is no
        /// longer one of them. ONE value, so an expand is the exact
        /// mirror of its collapse and every clip in the app reads as the same
        /// gesture — a second constant kept in step by hand silently drifts
        /// (live report 2026-08-10: the cards' own 0.2 s "don't follow the
        /// same system"). 0.15 s is Alec's live call on the previous 0.22 s
        /// ("it's also not that snappy") — short enough to feel immediate,
        /// long enough that neighbouring content still reads as being PUSHED
        /// rather than jumping.
        public static let collapseRevealDuration: TimeInterval = 0.15
    }

    // MARK: - Material

    /// `NSVisualEffectView.Material` aliases for the vibrancy materials the
    /// codebase already applies. No custom material or blending mode lives
    /// here — only forwarding.
    public enum Material {
        /// The system menu-surface material. Alias of
        /// `NSVisualEffectView.Material.menu`. Consumed by the quit
        /// indicator (`AudiouterApp.QuittingIndicatorPanel`) — the app's one
        /// floating HUD surface; every other chrome surface paints the
        /// custom warm canvas (`WarmCanvasView`, spec §5.1) and draws no
        /// material.
        public static var popover: NSVisualEffectView.Material { .menu }
        /// Opaque window-chrome material (onboarding background, Settings
        /// window background, About panel). Alias of
        /// `NSVisualEffectView.Material.windowBackground`.
        public static var windowBackground: NSVisualEffectView.Material { .windowBackground }
        /// The source-list sidebar material, applied via
        /// `NSSplitViewItem(sidebarWithViewController:)` in
        /// `MixerWindowController`. Alias of
        /// `NSVisualEffectView.Material.sidebar`.
        public static var sidebar: NSVisualEffectView.Material { .sidebar }
    }
}

// MARK: - Warm Signal palette internals (private to this file, per the
// governance rule: this is the ONE place a hex/RGB literal is permitted)

/// Builds an appearance- and Increase-Contrast-resolving `NSColor` for a
/// `Tokens.Color` warm-palette case. `name` becomes the `NSColor.Name` (so
/// repeated calls describe the same logical color, matching how
/// `NSColor.labelColor` etc. behave). The returned color re-evaluates the
/// closure every time AppKit resolves it against a drawing context's
/// appearance — never a frozen snapshot — exactly like the semantic aliases
/// above.
private func warmDynamic(name: String,
                          dark: UInt32, darkHighContrast: UInt32? = nil,
                          light: UInt32, lightHighContrast: UInt32? = nil) -> NSColor {
    NSColor(name: NSColor.Name("WarmSignal.\(name)")) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let hex: UInt32
        if isDark {
            hex = increaseContrast ? (darkHighContrast ?? dark) : dark
        } else {
            hex = increaseContrast ? (lightHighContrast ?? light) : light
        }
        return NSColor(warmSignalHex: hex)
    }
}

/// Builds a translucent, theme-INDEPENDENT "scrim" `NSColor` — same `hex` in
/// both appearances (an overlay meant to read consistently over arbitrary
/// content, not the app's own light/dark surface), but the ALPHA steps to
/// `highContrastAlpha` under Increase Contrast for real headroom, resolved
/// live on every access exactly like `warmDynamic`. `warmDynamic` itself
/// can't express this: its hex-only branching always resolves to an OPAQUE
/// color (`NSColor(warmSignalHex:)` hardcodes `alpha: 1`), so a case that
/// needs a non-1 base alpha AND an Increase-Contrast-only response needs its
/// own constructor.
private func scrimDynamic(name: String, hex: UInt32, alpha: CGFloat, highContrastAlpha: CGFloat) -> NSColor {
    NSColor(name: NSColor.Name("WarmSignal.\(name)")) { _ in
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return NSColor(warmSignalHex: hex).withAlphaComponent(increaseContrast ? highContrastAlpha : alpha)
    }
}

/// One accent instrument's four authored hexes (light/dark × base/Increase
/// Contrast) for a single dial position — the value shape `warmDynamic` takes
/// as loose parameters, named so `accentDynamic` can carry two columns of them.
private struct WarmVariants {
    let dark: UInt32
    let darkHighContrast: UInt32
    let light: UInt32
    let lightHighContrast: UInt32

    func hex(isDark: Bool, increaseContrast: Bool) -> UInt32 {
        if isDark { return increaseContrast ? darkHighContrast : dark }
        return increaseContrast ? lightHighContrast : light
    }
}

/// The accent-dial-aware sibling of `warmDynamic`, for the ONLY three tokens
/// the dial remaps (spec §1.3): `gold`, `ember`, `glow`. The dial switch lives
/// INSIDE the dynamic provider, so a stored `NSColor` re-resolves against the
/// CURRENT `Tokens.accentStyle` on its next resolution — the live-remap seam.
///
/// - `full`/`subtle`: the authored hex columns. `subtle: nil` means the token
///   has NO Subtle rendering (`glow` — "no glow shadow") and resolves `.clear`.
/// - `systemAccentScale`: Follow-system multiplies the resolved
///   `controlAccentColor`'s sRGB components by this (§1.3: gold ×1, ember
///   ×0.55, glow ×1.25), clamped to `0...1`.
private func accentDynamic(name: String,
                           full: WarmVariants,
                           subtle: WarmVariants?,
                           systemAccentScale: CGFloat) -> NSColor {
    NSColor(name: NSColor.Name("WarmSignal.\(name)")) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        switch Tokens.accentStyle {
        case .fullGold:
            return NSColor(warmSignalHex: full.hex(isDark: isDark, increaseContrast: increaseContrast))
        case .subtle:
            guard let subtle else { return .clear }
            return NSColor(warmSignalHex: subtle.hex(isDark: isDark, increaseContrast: increaseContrast))
        case .systemAccent:
            return systemAccentColor(in: appearance, scale: systemAccentScale)
        }
    }
}

/// Resolve `NSColor.controlAccentColor` under `appearance` to concrete sRGB
/// components and scale them (the §1.3 "accent × N luminance" formula,
/// realized as component scaling), clamped to the displayable range. Returns
/// a component color, not the dynamic accent itself, so a provider closure
/// hands AppKit a fully-resolved value.
private func systemAccentColor(in appearance: NSAppearance, scale: CGFloat) -> NSColor {
    var resolved = NSColor.controlAccentColor
    appearance.performAsCurrentDrawingAppearance {
        resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? resolved
    }
    guard let srgb = resolved.usingColorSpace(.sRGB) else { return resolved }
    func scaled(_ component: CGFloat) -> CGFloat { min(max(component * scale, 0), 1) }
    return NSColor(srgbRed: scaled(srgb.redComponent),
                   green: scaled(srgb.greenComponent),
                   blue: scaled(srgb.blueComponent),
                   alpha: 1)
}

/// The accent-dial-aware resolver for the four permission-row identity hues
/// (`permissionSystemAudio`/`permissionLocalNetwork`/`permissionRemoteControl`/
/// `permissionSpeakerSync`, Q1-Q6/NEW-1) — a SIBLING of `accentDynamic`, not a
/// caller of it. Two concrete reasons, each verified by reading the code
/// above before writing this function, not assumed:
///
/// 1. `accentDynamic`'s `.systemAccent` case calls `systemAccentColor(in:
///    scale:)`, which returns `controlAccentColor` scaled by a constant —
///    a value that depends on the LIVE SYSTEM ACCENT, not on which token
///    asked for it. `gold`/`ember`/`glow` sharing that is correct (they are
///    ONE accent instrument by design). These four are the opposite: their
///    entire purpose is to stay FOUR DIFFERENT hues. Routing them through
///    `accentDynamic` would make every one of them resolve to the same
///    `controlAccentColor`-derived value under Follow-System, silently
///    collapsing the whole point of this wave the moment a user picks that
///    dial position.
/// 2. `accentDynamic`'s `subtle: WarmVariants?` models a token that can have
///    NO Subtle rendering at all (`glow`'s `subtle: nil -> .clear`, because a
///    halo is allowed to vanish). These four are opaque SF Symbol glyph
///    fills, always rendering something — `.clear` here would be an
///    invisible icon, not a muted one, so `subtle` below is a non-optional
///    `WarmVariants` and the Subtle case always resolves a real colour.
///
/// Resolution (NEW-1/Q5): `.fullGold` AND `.systemAccent` both resolve the
/// authored FULL column (these hues do not remap to the live accent);
/// `.subtle` resolves the authored SUBTLE column (the dial genuinely mutes
/// these four, unlike `failure`/`caution`/`ringConnected` which the dial
/// never touches at all).
private func permissionDynamic(name: String,
                               full: WarmVariants,
                               subtle: WarmVariants) -> NSColor {
    NSColor(name: NSColor.Name("WarmSignal.\(name)")) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        switch Tokens.accentStyle {
        case .fullGold, .systemAccent:
            return NSColor(warmSignalHex: full.hex(isDark: isDark, increaseContrast: increaseContrast))
        case .subtle:
            return NSColor(warmSignalHex: subtle.hex(isDark: isDark, increaseContrast: increaseContrast))
        }
    }
}

private extension NSColor {
    /// A literal `0xRRGGBB` → opaque `NSColor`. The only place in the
    /// codebase a hex literal is permitted to become a color.
    convenience init(warmSignalHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
