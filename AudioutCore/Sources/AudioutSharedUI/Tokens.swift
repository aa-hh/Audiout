// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import CoreText

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
    /// `AudioutCore.AccentStyle`). The dial has TWO positions, Full gold and
    /// Subtle, and remaps ONLY ``Color/gold``, ``Color/ember``,
    /// ``Color/glow``, ``Color/goldText`` and ``Color/emberText``;
    /// `failure`/`rim`/`ring` and every text token are never remapped (spec
    /// §1.3: red stays red in every mode).
    ///
    /// Defaults to `.fullGold` (the flagship look — and the one the checked-in
    /// popover goldens render, so a process that never touches this sees
    /// identical output). The app layer seeds it from `AppSettings.accentStyle`
    /// at launch; the Appearance pane writes it on every dial change. The
    /// switch lives INSIDE those tokens' dynamic providers, so even an
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
        Notification.Name("Audiout.Tokens.accentStyleDidChange")

    /// Test-only override for the live `NSWorkspace` Increase-Contrast flag —
    /// `nil` means "use the live value" (same seam idea as the views'
    /// `test_reduceMotionOverride`). A test that sets this to a non-`nil`
    /// value MUST restore it to `nil` when done, so no other test in the
    /// process inherits a forced Increase-Contrast reading. Internal (not
    /// `public`): only this module's own token providers and its test target
    /// need it.
    static var test_increaseContrastOverride: Bool?

    // MARK: - Color

    /// Semantic color aliases plus the Warm Signal custom palette. The
    /// alias cases forward to stock `NSColor` class-properties; the
    /// custom warm/instrument cases below each carry a documented
    /// contrast rationale (the governance rule above).
    public enum Color {
        /// Primary label text. Alias of `NSColor.labelColor`.
        public static var label: NSColor { .labelColor }
        /// The SECOND ink rung — subtitles, hints, and every subordinate line
        /// that still has to be read comfortably. Authored warm in both
        /// appearances (the iPhone companion's ink ladder), not a system
        /// alias: the stock `secondaryLabelColor` sits under the body floor on
        /// the light ground.
        ///
        /// `static let`, not a computed var: call sites and several tests
        /// compare this token by INSTANCE IDENTITY — two independently
        /// created dynamic `NSColor`s are not reliably `==`
        /// (`OnboardingPermissionColorTests.swift:81-96`) — so this must be
        /// the one shared instance every consumer reads.
        ///
        /// CONTRAST RATIONALE (WCAG relative luminance, measured; floor 4.5:1
        /// on `canvas`/`panel`/`raised`/`well` in both appearances): dark
        /// `#B7AC95` = 8.81 canvas / 7.99 panel / 7.02 raised / 9.07 well, and
        /// 6.71 on `liveRow`; dark Increase Contrast `#C9C1AF` = 8.81 on
        /// raised. Light `#6B5F4E` = 5.97 on the flat ground / 5.17 on well;
        /// light Increase Contrast `#554C3E` = 8.09 / 7.01.
        public static let label2: NSColor = warmDynamic(
            name: "label2", dark: 0xB7AC95, darkHighContrast: 0xC9C1AF,
            light: 0x6B5F4E, lightHighContrast: 0x554C3E)
        /// The THIRD ink rung — de-emphasized state-bearing text ("Unavailable",
        /// "Not set", subsection headers, empty-state placeholders). Held to the
        /// same body floor as ``label2``, one step quieter; hierarchy between
        /// the two is carried by size and weight as much as by ink.
        ///
        /// `static let` for the same instance-identity reason as ``label2``.
        ///
        /// CONTRAST RATIONALE (measured; floor 4.5:1 on
        /// `canvas`/`panel`/`raised`/`well`, both appearances): dark `#9E947F`
        /// = 6.59 canvas / 5.98 panel / 5.25 raised / 6.78 well, dark Increase
        /// Contrast `#B4AD9C` = 7.06 on raised. Light `#6B6459` = 5.60 on the
        /// flat ground / 4.86 on well; light Increase Contrast `#524C44` =
        /// 8.13 / 7.05.
        public static let label3: NSColor = warmDynamic(
            name: "label3", dark: 0x9E947F, darkHighContrast: 0xB4AD9C,
            light: 0x6B6459, lightHighContrast: 0x524C44)

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
        /// dynamic, so it lifts the tone on the cool near-black ground and on
        /// the flat near-white one without introducing a hue to either.
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
        /// Opaque shadow color for card/panel drop shadows (`CardView`). Alias
        /// of `NSColor.black`.
        public static var shadow: NSColor { .black }
        /// Fully transparent fill, used to make a layer's background see
        /// through to a view behind it (`ControlPanelWindowController`). Alias
        /// of `NSColor.clear`.
        public static var clear: NSColor { .clear }

        // MARK: Warm Signal custom palette
        //
        // THE LADDER IS THE IPHONE COMPANION'S (Alec, 2026-08-30 /
        // 2026-09-03): the surface, edge and ink hexes below are the same
        // values `audiout-remote`'s `AudioutRemote/UI/Shared/WarmSignal.swift`
        // authors, so the two apps read as one product. BOTH APPEARANCES ARE
        // COOL-NEUTRAL now — dark is a near-black cool ladder, light is ONE
        // flat near-white ground (`canvas` = `panel` = `raised` = `#FAFAFB`)
        // where separation is carried entirely by edge weight, not by fill
        // steps. The gold family stays warm: it is the accent, not the paper.
        //
        // The ONE place a custom (non-semantic) RGB value may live, per root
        // AGENTS.md's governance rule ("Every `Tokens.Color` case ships
        // light + dark + Increase Contrast variants with a documented
        // contrast rationale") — four variants per token, house rule 3. Every
        // case below resolves LIVE via `NSColor(name:dynamicProvider:)`
        // against both the color's `NSAppearance` argument (light/dark) and
        // the CURRENT
        // `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`
        // value every time AppKit asks for the resolved color — exactly
        // like `NSColor.labelColor` above already behaves for Dark Mode.
        // Never cache a `.cgColor`/`.set()` result outside a live draw or
        // `viewDidChangeEffectiveAppearance` refresh (see `WarmCanvasView`
        // in this target and `CardView`/its hairline sibling in
        // `AudioutPopoverUI` for the pattern).

        /// The popover/content canvas — the darkest rung, and the
        /// control-panel shell's bubble+beak fill (`ControlPanelBackingView.draw`)
        /// so shell chrome and hosted transparent content read as one shape.
        /// No stated contrast floor (it's a background, not a foreground
        /// instrument), so grounds carry no separate Increase Contrast value.
        /// Light is the one flat ground `#FAFAFB` that `panel` and `raised`
        /// also resolve to.
        public static var canvas: NSColor {
            warmDynamic(name: "canvas", dark: 0x0A0A0C, light: 0xFAFAFB)
        }
        /// Card/panel fill — "the reference canvas a ring sits on". No stated
        /// contrast floor. Measured separation: dark `#15171A` is 1.101:1 on
        /// `canvas`; light is the flat ground, so 1.000:1 — in light a panel's
        /// only boundary pixel is its ``containerEdge``.
        public static var panel: NSColor {
            warmDynamic(name: "panel", dark: 0x15171A, light: 0xFAFAFB)
        }
        /// Raised fill — the rung a card lifts to above `panel`. No stated
        /// contrast floor. Measured separation: dark `#1F232A` is 1.139:1 on
        /// `panel`, 1.255:1 on `canvas`, 1.292:1 on `well`; light is the flat
        /// ground (1.000:1 on `canvas`/`panel`), edged rather than filled.
        public static var raised: NSColor {
            warmDynamic(name: "raised", dark: 0x1F232A, light: 0xFAFAFB)
        }
        /// Inset well fill — the recess a trough, dropdown or grouped section
        /// sinks to. No stated contrast floor (backgrounds carry no IC
        /// variant; the fills and rims drawn on the well brighten under IC
        /// instead). Measured separation: dark `#050507` is 1.134:1 on
        /// `panel` and only 1.029:1 on `canvas` — in dark the well is read by
        /// its edge, not by its fill; light `#E9EAEC` is 1.154:1 on the flat
        /// ground.
        public static var well: NSColor {
            warmDynamic(name: "well", dark: 0x050507, light: 0xE9EAEC)
        }
        /// The ground a row carrying audio sits on — the one warm surface in
        /// the ladder, so "this is live" is legible before any instrument is
        /// read. Light has no separate live ground: it stays the flat
        /// `#FAFAFB` and liveness is carried by the row's instruments alone.
        /// No contrast floor (a background); the IC parameters carry the base
        /// hex, the same precedent `canvas`/`panel`/`raised`/`well` set.
        /// Measured separation: dark 1.313:1 on `canvas`, 1.192:1 on `panel`,
        /// 1.352:1 on `well`. BARS `labelCool2` (4.38:1) and `emberText`
        /// (4.31:1), both under the body floor; `labelCool` is barred by
        /// temperature rather than measurement.
        public static var liveRow: NSColor {
            warmDynamic(name: "liveRow", dark: 0x2E2518, darkHighContrast: 0x2E2518,
                        light: 0xFAFAFB, lightHighContrast: 0xFAFAFB)
        }
        /// ``liveRow``'s raised companion — a live row's lifted interior.
        /// Same background rules and the same ink bars. Measured separation:
        /// dark 1.292:1 on `canvas` and only 1.016:1 on `liveRow` itself; the
        /// `well` ring that divides the two carries 1.330:1, which is what
        /// makes the pair readable.
        public static var liveRaised: NSColor {
            warmDynamic(name: "liveRaised", dark: 0x2B241C, darkHighContrast: 0x2B241C,
                        light: 0xFAFAFB, lightHighContrast: 0xFAFAFB)
        }
        /// The 1px divider BETWEEN rows inside a container — the lighter of
        /// the two edge weights (``containerEdge`` is the container's own
        /// outer stroke, one rank up).
        ///
        /// NEVER DRAWN ON `raised`: dark measures 1.154:1 there, under the
        /// 1.25:1 edge floor, so an in-card divider uses ``containerEdge``
        /// instead. The ban is measured, not asserted —
        /// `MembershipWellContrastTests` fails if a re-tune ever lifts the
        /// pair over the floor.
        ///
        /// CONTRAST RATIONALE (measured, WCAG relative luminance): dark
        /// `#2A2E33` = 1.45:1 vs `canvas`, 1.31:1 vs `panel`, 1.49:1 vs
        /// `well`; dark Increase Contrast `#616467` = 3.02:1 vs `panel`,
        /// 3.32:1 vs `canvas`. Light `#CBCED4` = 1.51:1 vs the flat ground,
        /// 1.31:1 vs `well`; light Increase Contrast `#727377` = 4.54:1 /
        /// 3.93:1.
        public static var hairline: NSColor {
            warmDynamic(name: "hairline", dark: 0x2A2E33, darkHighContrast: 0x616467,
                       light: 0xCBCED4, lightHighContrast: 0x727377)
        }

        /// A container's OWN outer edge — the stroke around a grouped section
        /// or an inset seat. ``hairline`` above is its sibling one rank down:
        /// the dividers BETWEEN rows INSIDE such a container. Two weights of
        /// one mechanism, and the mechanism is free, because nothing in this
        /// app is ever drawn ON an edge — each is only ever a stroke or a
        /// divider fill — so ranking them spends no text and no instrument
        /// contrast.
        ///
        /// It is also the ONLY edge allowed on `raised`: `hairline` measures
        /// 1.154:1 there in dark, under the 1.25:1 edge floor.
        ///
        /// CONTRAST RATIONALE (measured, WCAG relative luminance; each ratio is
        /// against the surface that edge actually borders): dark `#3D4247` =
        /// 1.95:1 vs `canvas`, 1.77:1 vs `panel`, 1.55:1 vs `raised`, 1.48:1 vs
        /// `liveRow`; dark Increase Contrast `#6A6E72` = 3.49:1 vs `panel`,
        /// 3.07:1 vs `raised`, and 1.159× the `hairline` IC ratio. Light
        /// `#AEB3BB` = 2.02:1 vs the flat ground, 1.75:1 vs `well`; light
        /// Increase Contrast `#67696E` = 5.27:1 / 4.56:1, and 1.160× the
        /// `hairline` IC ratio — so the container-vs-divider rank survives the
        /// mode whose users most depend on structure.
        public static var containerEdge: NSColor {
            warmDynamic(name: "containerEdge", dark: 0x3D4247, darkHighContrast: 0x6A6E72,
                       light: 0xAEB3BB, lightHighContrast: 0x67696E)
        }

        /// A CONTROL's edge — the third and heaviest weight in the edge
        /// family, held to a real 3:1 floor because it outlines something the
        /// pointer acts on (a fader trough, a plate, a ring) rather than
        /// merely bounding a surface.
        ///
        /// CONTRAST RATIONALE (measured; floor 3:1): dark `#6B767D` = 4.38:1
        /// vs `well`, 4.25:1 vs `canvas`, 3.86:1 vs `panel`, 3.39:1 vs
        /// `raised`; dark Increase Contrast `#818B90` = 4.53:1 vs `raised`,
        /// 5.85:1 vs `well`. Light `#66717A` = 4.78:1 vs the flat ground,
        /// 4.15:1 vs `well`; light Increase Contrast `#586269` = 5.98:1 /
        /// 5.18:1.
        public static var rim: NSColor {
            warmDynamic(name: "rim", dark: 0x6B767D, darkHighContrast: 0x818B90,
                       light: 0x66717A, lightHighContrast: 0x586269)
        }

        /// The under-name level meter's EMPTY-track fill (`LevelMeterView`'s
        /// `trackLayer`). A meter reads a RATIO, so its full length (the
        /// denominator) must be visible at every level, including 0 — but it is
        /// a RECESS, deliberately quiet, so the gold/ember fill drawn over it
        /// still wins. No contrast floor of its own.
        /// CONTRAST RATIONALE (measured, WCAG relative luminance): dark
        /// `#464C55` = 2.28:1 vs `canvas` (Increase Contrast `#545B66` =
        /// 2.89:1), with `ember` sitting 1.72:1 over it and `gold` 4.70:1 —
        /// enough for the fill boundary to be legible at either end. Light
        /// `#C6C9CE` = 1.59:1 vs the flat ground (Increase Contrast `#B4B8BF`
        /// = 1.91:1), with `ember` 3.65:1 over it (Subtle 3.64:1).
        public static var meter: NSColor {
            warmDynamic(name: "meter", dark: 0x464C55, darkHighContrast: 0x545B66,
                       light: 0xC6C9CE, lightHighContrast: 0xB4B8BF)
        }

        /// The **FAILURE-EXCLUSIVE** hue (house rule 8): the failed connection
        /// ring, the failed row's sublabel, and the diagnosis panel — never a
        /// meter (a loud party can never impersonate a failure) and never
        /// remapped by the accent dial (red stays red in every mode).
        ///
        /// NEVER BODY TEXT: it measures 4.04:1 on dark `raised`, under the
        /// 4.5:1 body floor. It is a graphical-object hue held to 3:1.
        ///
        /// CONTRAST RATIONALE (measured; floor 3:1 vs `panel` and `raised`):
        /// dark `#D9564A` = 4.60:1 vs `panel` / 4.04:1 vs `raised`, dark
        /// Increase Contrast `#F26B5C` = 5.28:1 vs `raised`. Light `#B03327` =
        /// 6.01:1 vs the flat ground / 5.21:1 vs `well`; light Increase
        /// Contrast `#962C21` = 7.51:1 / 6.51:1.
        public static var failure: NSColor {
            warmDynamic(name: "failure", dark: 0xD9564A, darkHighContrast: 0xF26B5C,
                       light: 0xB03327, lightHighContrast: 0x962C21)
        }

        /// The informational steel-blue instrument — note banners and any
        /// other "here is a fact about the system" mark. A graphical hue, not
        /// an ink; never remapped by the accent dial.
        ///
        /// CONTRAST RATIONALE (measured; floor 3:1 on
        /// `canvas`/`panel`/`raised`): dark `#7FB4C4` = 8.69:1 / 7.89:1 /
        /// 6.93:1, and 8.95:1 on `well`; dark Increase Contrast `#9FC7D3` =
        /// 8.70:1 on raised, 10.91:1 on canvas. Light `#2C6E86` = 5.47:1 on
        /// the flat ground / 4.74:1 on `well`; light Increase Contrast
        /// `#265E73` = 6.87:1 / 5.95:1.
        public static var ring: NSColor {
            warmDynamic(name: "ring", dark: 0x7FB4C4, darkHighContrast: 0x9FC7D3,
                       light: 0x2C6E86, lightHighContrast: 0x265E73)
        }

        /// The COOL body ink — the same second-rung job as ``label2`` on a
        /// surface that carries no warmth of its own. Barred from `liveRow`
        /// and `liveRaised`: it measures 7.07:1 there and would pass, but a
        /// cool ink on the live row's warm ground is a temperature clash, not
        /// a contrast one.
        ///
        /// `static let` for the same instance-identity reason as ``label2``.
        ///
        /// CONTRAST RATIONALE (measured; floor 4.5:1 on
        /// `canvas`/`panel`/`raised`/`well`, both appearances): dark `#A9B3BB`
        /// = 9.28 canvas / 8.43 panel / 7.40 raised / 9.55 well, dark Increase
        /// Contrast `#C0C8CD` = 9.30 on raised. Light `#4E5A63` = 6.79 on the
        /// flat ground / 5.88 on well; light Increase Contrast `#414B53` =
        /// 8.54 / 7.40.
        public static let labelCool: NSColor = warmDynamic(
            name: "labelCool", dark: 0xA9B3BB, darkHighContrast: 0xC0C8CD,
            light: 0x4E5A63, lightHighContrast: 0x414B53)

        /// ``labelCool``'s quieter companion — the cool third rung. BARRED
        /// from `liveRow`/`liveRaised` by measurement as well as by
        /// temperature: 4.38:1 on `liveRow`, under the body floor.
        ///
        /// `static let` for the same instance-identity reason as ``label2``.
        ///
        /// CONTRAST RATIONALE (measured; floor 4.5:1 on
        /// `canvas`/`panel`/`raised`/`well`, both appearances): dark `#818C94`
        /// = 5.76 canvas / 5.23 panel / 4.59 raised / 5.93 well, dark Increase
        /// Contrast `#A6AEB3` = 7.00 on raised. Light `#5F6A73` = 5.30 on the
        /// flat ground / 4.60 on well; light Increase Contrast `#464E55` =
        /// 8.11 / 7.03.
        public static let labelCool2: NSColor = warmDynamic(
            name: "labelCool2", dark: 0x818C94, darkHighContrast: 0xA6AEB3,
            light: 0x5F6A73, lightHighContrast: 0x464E55)

        /// The membership rail's ONE dormancy tone (§4.7 — dormancy is one
        /// flag, one tone): one cool chrome grey — the same values as ``rim``,
        /// so a dormant wire, an idle connected ring and an unarmed fader fill
        /// read as one tone. `static let` for the same instance-identity reason
        /// as ``label2``. A graphical object held to a 3:1 floor, not a 4.5:1
        /// text floor.
        ///
        /// CONTRAST RATIONALE (>=3:1 vs canvas/panel/raised, both
        /// appearances; measured): dark `#6B767D` = 4.25:1 vs canvas / 3.86:1
        /// vs panel / 3.39:1 vs raised (IC raised 4.53, well 5.85); light
        /// `#66717A` = 4.78:1 vs the flat ground / 4.15:1 vs well (IC well
        /// 5.18, ground 5.98).
        public static let railDormant: NSColor = warmDynamic(
            name: "railDormant", dark: 0x6B767D, darkHighContrast: 0x818B90,
            light: 0x66717A, lightHighContrast: 0x586269)

        // MARK: Gold accent instruments (spec §1, S-BUS)
        //
        // THE accent (spec §1.1/§1.2): `gold` is the bus-node fill / route-armed
        // dot / meter hot end; `ember` is gold's dim companion (bus LINE ink /
        // meter low end). S-BUS (the membership bus, spec §4) is their FIRST
        // consumer — the filled node is a `gold` disc with an `ember` rim, and the
        // bus line is drawn in `ember` (spec §4.1/§4.2). `glow` (the bloom/halo,
        // §3.3) lives in the S2+S3 block below with its consumer, the
        // route-armed dot. Per the accent dial (spec §1.3) these three and
        // their text companions `goldText`/`emberText` are the ONLY tokens the
        // Full-gold/Subtle remap touches.
        //
        // CONTRAST RATIONALE (≥3:1 non-text floor on every surface the bus
        // draws over; each token's own doc carries the full grid). Dark `gold`
        // `#E8B84B` measures 10.73:1 vs `canvas` / 9.74:1 vs `panel` / 8.55:1
        // vs `raised` / 11.04:1 vs `well` (Increase Contrast `#F2C75E` 12.35 /
        // 11.21 / 9.84 / 12.71). `ember` is dimmer by design — it is the
        // connecting line, not the node — at 3.94 / 3.58 / 3.14 / 4.06.
        //
        // BOTH LIGHT INSTRUMENTS ARE MEASURED AGAINST `well`, NOT ONLY THE FLAT
        // GROUND: the Groups editor's sections are filled with `well`, so the
        // rail and its nodes run over the darker of the two surfaces. Light
        // `gold` `#A67C1E` measures 3.64:1 on the flat ground / 3.16:1 on
        // `well` (Increase Contrast `#8A6614` 5.04 / 4.37); Subtle light
        // `#8F7B4A` 3.95 / 3.42 (IC `#6F5E33` 6.06 / 5.25). Subtle dark `gold`
        // clears `raised` at 5.91:1 (IC 7.42:1).
        //
        // NOTE the consequence, deliberately accepted: in LIGHT mode the two
        // inks sit close in luminance, so ember's "dimmer" reads as LESS
        // CHROMATIC rather than lighter — saturation 0.656 against gold's
        // 0.819 at the same ~41° hue, a muted brown beside a saturated gold.
        // Dark keeps the luminance hierarchy unchanged. `MembershipWellContrastTests`
        // pins the pair's separation: a 1.595:1 gap, inside its 1.40–1.60 band.
        //
        // Neither `gold` nor `ember` may set TEXT — a fill held to 3:1 is not
        // an ink. `goldText`/`emberText` are the 4.5:1 companions for that.

        /// THE gold accent — the bus-node fill (spec §4.2), route-armed dot, and
        /// meter hot end (spec §1). Remapped ONLY by the accent dial
        /// (``Tokens/accentStyle``, spec §1.3 — W1); never by anything else.
        /// CONTRAST RATIONALE (measured; ≥3:1 non-text floor). FULL column:
        /// dark `#E8B84B` = 10.73:1 vs `canvas` / 9.74:1 vs `panel` / 8.55:1
        /// vs `raised` / 11.04:1 vs `well`, dark Increase Contrast `#F2C75E` =
        /// 12.35 / 11.21 / 9.84 / 12.71; light `#A67C1E` = 3.64:1 vs the flat
        /// ground / 3.16:1 vs `well`, light Increase Contrast `#8A6614` =
        /// 5.04:1 / 4.37:1. SUBTLE column: dark `#B99B53` = 5.91:1 vs `raised`
        /// (IC `#CBAF6A` 7.42:1); light `#8F7B4A` = 3.95:1 vs the flat ground
        /// / 3.42:1 vs `well` (IC `#6F5E33` 6.06:1 / 5.25:1).
        ///
        /// This is a FILL and a graphical mark, not an ink: text set in the
        /// gold family uses ``goldText``, which carries the 4.5:1 floor.
        public static var gold: NSColor {
            accentDynamic(name: "gold",
                          full: WarmVariants(dark: 0xE8B84B, darkHighContrast: 0xF2C75E,
                                             light: 0xA67C1E, lightHighContrast: 0x8A6614),
                          subtle: WarmVariants(dark: 0xB99B53, darkHighContrast: 0xCBAF6A,
                                               light: 0x8F7B4A, lightHighContrast: 0x6F5E33))
        }

        /// ``gold`` as an INK — the same accent voice held to the 4.5:1 body
        /// floor instead of the 3:1 graphical one. Dark reuses `gold`'s own
        /// hexes (they already clear the text floor); light deepens, because
        /// `gold`'s light value is a fill on paper and reads at 3.64:1.
        ///
        /// CONTRAST RATIONALE (measured; floor 4.5:1). FULL: dark `#E8B84B` =
        /// 8.55:1 vs `raised` (the tightest ground); light `#825E0F` = 5.66:1
        /// vs the flat ground / 4.90:1 vs `well`, light Increase Contrast
        /// `#64480C` = 8.14:1 / 7.05:1. SUBTLE: dark `#B99B53` = 5.91:1 vs
        /// `raised` (IC `#CBAF6A` 7.42:1); light `#79683F` = 5.21:1 vs the
        /// flat ground / 4.51:1 vs `well` (IC `#584C2E` 7.01:1 on well).
        public static var goldText: NSColor {
            accentDynamic(name: "goldText",
                          full: WarmVariants(dark: 0xE8B84B, darkHighContrast: 0xF2C75E,
                                             light: 0x825E0F, lightHighContrast: 0x64480C),
                          subtle: WarmVariants(dark: 0xB99B53, darkHighContrast: 0xCBAF6A,
                                               light: 0x79683F, lightHighContrast: 0x584C2E))
        }

        /// Gold's dim companion — the bus LINE ink (spec §4.1), the filled node's
        /// rim (§4.2), and the meter low end (§1). Dimmer than `gold` by design
        /// — by luminance in dark, by CHROMA in light (see the block above, and
        /// `MembershipWellContrastTests` for the pinned light floor).
        /// CONTRAST RATIONALE (measured; ≥3:1 non-text floor). FULL column:
        /// dark `#8A6A2F` = 3.94:1 vs `canvas` / 3.58:1 vs `panel` / 3.14:1 vs
        /// `raised` / 4.06:1 vs `well`, dark Increase Contrast `#A5824A` =
        /// 5.55 / 5.04 / 4.42 / 5.71; light `#7A5E2A` = 5.82:1 vs the flat
        /// ground / 5.04:1 vs `well`, light Increase Contrast `#5E4922` =
        /// 8.21:1 / 7.11:1. SUBTLE column: dark `#6D5B34` = 3.01:1 vs
        /// `canvas` / 2.73:1 vs `panel` / 2.40:1 vs `raised` / 3.10:1 vs
        /// `well` — a documented under-floor case, because `ember` is a 2 pt
        /// line paired with high-contrast `gold` nodes and the IC variant is
        /// the escape valve (dark IC `#877146` = 4.22 / 3.83 / 3.36 / 4.34);
        /// light `#71613B` = 5.79:1 vs the flat ground / 5.02:1 vs `well` (IC
        /// `#5C5030` 7.61:1 / 6.59:1).
        public static var ember: NSColor {
            accentDynamic(name: "ember",
                          // LIGHT IS DEEP ENOUGH TO BE TELLABLE FROM GOLD, and
                          // that is a harder constraint than its own floor.
                          // Pinning both inks just over the 3:1 non-text floor
                          // on the same ground leaves them ~1.03:1 apart — a 3%
                          // luminance difference on a 2 pt line, which no one
                          // reads. ``spineTone(armed:)`` would then resolve to
                          // one visible colour in light and the rail could not
                          // report liveness at all, which is the one thing gold
                          // exists to say. Dark's own pair sits at 2.72:1; light
                          // has to buy a comparable gap, and depth is the only
                          // axis available once both are floor-bound.
                          //
                          // The gap has a floor AND a ceiling: under ~1.40:1
                          // the two inks merge on a 2 pt line; much past 1.55:1
                          // ember stops reading as a dimmer brass and turns
                          // into a brown that muddies the whole rail. Depth is
                          // bought with value, never with chroma — dropping
                          // saturation on the way down is what makes a brown.
                          //
                          // Full light `#7A5E2A`: a 1.595:1 luminance gap from
                          // light gold `#A67C1E`, hue 39.0° against gold's
                          // 41.5° (same family), saturation 0.656 against
                          // gold's 0.819 — a 0.164 gap, so ember stays the
                          // duller ink by chroma AND the darker one by
                          // luminance, which is exactly the relationship dark
                          // has. Subtle light `#71613B` separates by luminance
                          // rather than chroma (1.468:1 from Subtle gold): the
                          // muted column is meant to be muted, and value is the
                          // only axis that does not re-saturate it. IC variants
                          // stay strictly darker than their bases.
                          full: WarmVariants(dark: 0x8A6A2F, darkHighContrast: 0xA5824A,
                                             light: 0x7A5E2A, lightHighContrast: 0x5E4922),
                          subtle: WarmVariants(dark: 0x6D5B34, darkHighContrast: 0x877146,
                                               light: 0x71613B, lightHighContrast: 0x5C5030))
        }

        /// ``ember`` as an INK — the dim accent voice held to the 4.5:1 body
        /// floor. BARRED from `liveRow`/`liveRaised`: 4.31:1 on `liveRow`,
        /// under the floor.
        ///
        /// CONTRAST RATIONALE (measured; floor 4.5:1). FULL: dark `#A98341` =
        /// 5.66:1 vs `canvas` / 5.14:1 vs `panel` / 4.51:1 vs `raised` /
        /// 5.83:1 vs `well`, dark Increase Contrast `#C4AA7C` = 7.05:1 on
        /// raised; light `#7A5A22` = 6.08:1 vs the flat ground / 5.27:1 vs
        /// `well`, light Increase Contrast `#62491B` = 8.09:1 / 7.01:1.
        /// SUBTLE: dark `#95886B` = 5.66 / 5.14 / 4.51 / 5.83 (IC `#B6AC98`
        /// 7.01:1 on raised); light `#71613B` = 5.79:1 vs the flat ground /
        /// 5.02:1 vs `well` (IC `#584C2E` 7.01:1 on well — the same hex
        /// ``goldText``'s Subtle light-IC column derives to, recorded and
        /// accepted).
        public static var emberText: NSColor {
            accentDynamic(name: "emberText",
                          full: WarmVariants(dark: 0xA98341, darkHighContrast: 0xC4AA7C,
                                             light: 0x7A5A22, lightHighContrast: 0x62491B),
                          subtle: WarmVariants(dark: 0x95886B, darkHighContrast: 0xB6AC98,
                                               light: 0x71613B, lightHighContrast: 0x584C2E))
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

        // MARK: Glow + socket (accent halo and the routed dot's seat)

        /// The gold bloom/halo hue — the rail bead, the ring's arrival pulse
        /// and the header-dot bloom: transient strokes and fills, never a
        /// shadow (the armed dot carries no halo). CONTRAST RATIONALE: NO floor
        /// (transient/halo only — it never carries meaning alone; the ≥3:1
        /// `gold` disc under it does). Measured for the record: dark `#FFD97A`
        /// = 13.22:1 vs `panel`; light `#E8B84B` = 1.77:1 vs the flat ground
        /// (a soft paper halo — acceptable because floor-exempt). House rule 3
        /// still requires IC variants: both reuse the base hexes (a halo needs
        /// no extra IC contrast; the disc's IC variant carries that).
        /// Accent-dial columns: Subtle = **none** ("no glow shadow" — resolves
        /// fully `clear`, so every halo/bloom call site goes quiet with zero
        /// call-site changes).
        public static var glow: NSColor {
            accentDynamic(name: "glow",
                          full: WarmVariants(dark: 0xFFD97A, darkHighContrast: 0xFFD97A,
                                             light: 0xE8B84B, lightHighContrast: 0xE8B84B),
                          subtle: nil)
        }

        /// The ink a BRIGHT-gold or bright-instrument fill carries — the
        /// alignment wizard's primary plates and every other control filled
        /// with ``gold``'s own value. Deliberately NOT ``shadow``: that token
        /// means "the colour a drop shadow is painted in", and a title is not
        /// a shadow. Deliberately NOT ``label``, which is dynamic and would go
        /// near-white on the dark appearance — over a bright fill the ink has
        /// to be pinned as tightly as the fill is.
        ///
        /// ONE dark hex in three of the four variants, and WHITE in light
        /// Increase Contrast. That flip is forced, not stylistic: light-IC
        /// `gold` `#8A6614` gives `#171104` only 3.57:1 and even pure black
        /// 3.99:1 — no dark ink clears 4.5:1 on it — while white gives 5.26:1
        /// (6.32:1 on Subtle light-IC `#6F5E33`). The flip is authored into
        /// the token, so `ProminentButton` measures nothing at runtime.
        ///
        /// CONTRAST RATIONALE (measured, on `gold`): Full dark 10.18:1, dark
        /// Increase Contrast 11.72:1, light 4.94:1, light Increase Contrast
        /// (white) 5.26:1; Subtle dark 7.04:1, dark Increase Contrast 8.83:1,
        /// light 4.56:1, light Increase Contrast (white) 6.32:1. On the
        /// ``wireCore`` family `#21D477` it measures 9.61:1.
        public static var inkOnFill: NSColor {
            warmDynamic(name: "inkOnFill", dark: 0x171104, darkHighContrast: 0x171104,
                       light: 0x171104, lightHighContrast: 0xFFFFFF)
        }

        /// The **dark/empty socket** an unlit instrument rests in. Two
        /// consumers, same meaning: the route-armed dot when nothing is armed
        /// (spec §3.3), and the membership node's disc when the row is dimmed
        /// (`MembershipBusView`'s `dimmed`) — in both, the seat stays and the
        /// gold is lifted out of it. Because it is always ringed, it is
        /// measured against the tone that rings it rather than the ground
        /// behind it.
        ///
        /// CONTRAST RATIONALE: deliberately QUIET against its GROUND — it must
        /// not compete with the lit instrument it stands in for, so it carries
        /// no ground floor (dark `#2A2E33` = 1.31:1 vs `panel`, Increase
        /// Contrast `#3D4247` = 1.77:1; light `#DFE1E4` = 1.26:1 vs the flat
        /// ground, Increase Contrast `#CBCED4` = 1.51:1). The floor it DOES
        /// carry is against the RING: ≥1.4:1 from both `ember` and `gold`, in
        /// both appearances, on both dial columns, with Increase Contrast
        /// applied to the socket and the ring together — sixteen cells, of
        /// which the tightest is Subtle dark `ember` at 2.08:1 (dark IC-off
        /// gold 7.41, Subtle gold 5.12; dark IC-on ember 2.85 / gold 6.34,
        /// Subtle 2.17 / 4.78; light IC-off ember 4.63 / gold 2.90, Subtle
        /// 4.61 / 3.14; light IC-on ember 5.43 / gold 3.34, Subtle 5.03 /
        /// 4.01).
        public static var socket: NSColor {
            warmDynamic(name: "socket", dark: 0x2A2E33, darkHighContrast: 0x3D4247,
                       light: 0xDFE1E4, lightHighContrast: 0xCBCED4)
        }

        // MARK: Scope instrument (EQ response curve)
        //
        // The EQ response curve (`EQResponseCurveView`) is a SCOPE: a dark
        // screen with a lit trace, the way a hardware analyser looks. Its
        // three hexes are identical in both appearances on purpose —
        // instruments never theme (dev/notes/eq-design-board). The view draws
        // itself under `NSAppearance(named: .darkAqua)`, so these tokens still
        // resolve live (Increase Contrast reaches them); it is only the
        // light/dark axis that is deliberately fixed.
        //
        // CONTRAST RATIONALE for the whole block — everything that carries
        // meaning is measured against `scopeGround`, not against `panel`,
        // because the ground is what it is drawn on: dark `gold` ≈ 10.2:1,
        // subtle-dial `gold` ≈ 7.1:1, `scopeFlatLine` ≈ 6.0:1,
        // `scopeBypassLine` ≈ 4.7:1 — all clear the ≥3:1 non-text floor.
        // The grid is a GRIDLINE (pure reference, never the state), so the
        // floor does not apply to it; the dotted zero line reuses
        // `scopeFlatLine`.

        /// The scope's ground — the near-black screen the trace is drawn on.
        public static var scopeGround: NSColor {
            warmDynamic(name: "scopeGround", dark: 0x14110C, darkHighContrast: 0x0E0C08,
                       light: 0x14110C, lightHighContrast: 0x0E0C08)
        }

        /// The FLAT trace: a neutral hairline at the zero line. Deliberately
        /// not gold — gold means signal, and flat is the absence of shaping.
        public static var scopeFlatLine: NSColor {
            warmDynamic(name: "scopeFlatLine", dark: 0x9C9077, darkHighContrast: 0xB3A78C,
                       light: 0x9C9077, lightHighContrast: 0xB3A78C)
        }

        /// The BYPASSED trace: the shape is still drawn, dashed and dimmer
        /// than flat, so the eye reads "these settings exist but are not
        /// reaching the air".
        public static var scopeBypassLine: NSColor {
            warmDynamic(name: "scopeBypassLine", dark: 0x8A7E68, darkHighContrast: 0xA2957D,
                       light: 0x8A7E68, lightHighContrast: 0xA2957D)
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
        // Onboarding's four permission rows (`SetupCardView`: System Audio,
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
        // DIAL RESOLUTION (Q5) deliberately does NOT reuse `accentDynamic`
        // (see `permissionDynamic` below for the concrete reason): that
        // resolver's `subtle: nil -> .clear` fallback is a halo-only escape
        // hatch, and these five are opaque glyph fills that must always render
        // something — `.clear` here would be an invisible icon, not a muted
        // one. `permissionDynamic` resolves `.fullGold` to the authored FULL
        // column and `.subtle` to the authored SUBTLE column (the dial
        // genuinely mutes these five).
        //
        // RESERVED BANDS: every hue below clears the gold/amber
        // window `[28°,68°)` — landing in it would misread an ungranted row as
        // already "granted" — and the failure-red window
        // `[0°,12°) ∪ [350°,360°)`. Measured hues (own-theme Full column,
        // stable within a few degrees across every dial column/appearance/
        // Increase-Contrast variant since mostly saturation/brightness shift):
        // `permissionSystemAudio` ~207-210° (blue, already clear of both
        // bands), `permissionLocalNetwork` ~265-272° (indigo warmed toward
        // magenta), `permissionRemoteControl` ~319-325° (purple warmed toward
        // pink), `permissionSpeakerSync` ~23-26° — strictly BELOW the gold
        // band's 28° floor, in the terracotta corridor just short of gold.
        // That keeps all four ≥45° apart (measured minimum 47°) from
        // each other and from both reserved bands in every one of the 32
        // authored hexes (mutual-distinguishability check, Q1 criterion 4).
        //
        // CONTRAST (WCAG 2.x relative luminance): every one
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
        // First consumer: `SetupCardView`'s `IconTileView` per-row resting
        // glyph tint, one call site per row (T2 of this wave, landing
        // immediately after this case addition).

        /// Warmed & deepened from `.systemBlue` (System Audio's retired tile
        /// colour) — a blue "warm slate," the row's PERMANENT identity glyph
        /// tint (granting never recolours it — the status chip carries state).
        /// Hue ~207-210° in every column/appearance — its own family, already
        /// clear of both reserved bands (gold/amber `[28°,68°)`, failure-red
        /// `[0°,12°)∪[350°,360°)`). CONTRAST RATIONALE (>=3:1 vs BOTH `panel`
        /// and `raised`, both themes, both dial columns; measured): Full dark
        /// `#5B93C4` = 6.04:1 vs `canvas` / 5.49:1 vs `panel` / 4.82:1 vs
        /// `raised`; Full light `#3A79AE` = 4.45:1 vs the flat ground / 3.85:1
        /// vs `well`. Subtle (authored, not derived — the dial's mute stays
        /// muted): dark `#6C7680` = 4.28 / 3.88 / 3.41; light `#737D86` =
        /// 4.02:1 / 3.48:1. IC variants push further from every surface: Full
        /// dark `#8FB6DC` = 9.32 / 8.46 / 7.43, Full light `#2A5C89` = 6.73:1
        /// / 5.83:1; Subtle dark `#8C98A3` = 6.72 / 6.10 / 5.36, Subtle light
        /// `#4B535B` = 7.49:1 / 6.49:1.
        /// Mutually distinguishable from the other three permission
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
        /// RATIONALE (measured): Full dark `#9A6BC6` = 4.99:1 vs `canvas` /
        /// 4.53:1 vs `panel` / 3.97:1 vs `raised`; Full light `#7749B5` =
        /// 5.91:1 vs the flat ground / 5.12:1 vs `well`. Subtle (authored):
        /// dark `#776882` = 3.85 / 3.49 / 3.07; light `#7A6E82` = 4.60:1 /
        /// 3.98:1. IC variants: Full dark `#BE9BDD` = 8.40 / 7.63 / 6.70, Full
        /// light `#5B3690` = 8.48:1 / 7.34:1; Subtle dark `#9988A6` = 6.05 /
        /// 5.50 / 4.82, Subtle light `#4F4557` = 8.67:1 / 7.52:1.
        /// Mutually distinguishable from the other three permission
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
        /// RATIONALE (measured): Full dark `#C066A2` = 5.33:1 vs `canvas` /
        /// 4.84:1 vs `panel` / 4.25:1 vs `raised`; Full light `#AF3E7F` =
        /// 5.27:1 vs the flat ground / 4.57:1 vs `well`. Subtle (authored):
        /// dark `#806977` = 3.96 / 3.60 / 3.16; light `#86737F` = 4.22:1 /
        /// 3.66:1. IC variants: Full dark `#D494C0` = 8.29 / 7.52 / 6.60, Full
        /// light `#852B66` = 7.94:1 / 6.88:1; Subtle dark `#A3899A` = 6.22 /
        /// 5.65 / 4.96, Subtle light `#5B4A55` = 7.88:1 / 6.83:1.
        /// Mutually distinguishable from the other three permission
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
        /// 28° floor (the terracotta corridor just short of gold), so the
        /// row reads as warm/golden-
        /// adjacent WITHOUT impersonating the accent `gold` (~42°) the app's
        /// armed instruments wear — also clear of the failure-red band.
        /// CONTRAST RATIONALE (measured): Full dark `#B86F41` = 5.08:1 vs
        /// `canvas` / 4.61:1 vs `panel` / 4.04:1 vs `raised`; Full light
        /// `#A55B22` = 4.89:1 vs the flat ground / 4.23:1 vs `well`. Subtle
        /// (authored): dark `#876A59` = 3.99 / 3.62 / 3.18; light `#796356` =
        /// 5.39:1 / 4.67:1. IC variants: Full dark `#D4996E` = 8.08 / 7.34 /
        /// 6.44, Full light `#7E4116` = 7.58:1 / 6.57:1; Subtle dark
        /// `#A88672` = 5.95 / 5.40 / 4.74, Subtle light `#524036` = 9.38:1 /
        /// 8.13:1. Mutually distinguishable from the other three
        /// permission hues (~208°/~271°/~320°) by >=47° in every column.
        public static var permissionSpeakerSync: NSColor {
            permissionDynamic(name: "permissionSpeakerSync",
                              full: WarmVariants(dark: 0xB86F41, darkHighContrast: 0xD4996E,
                                                 light: 0xA55B22, lightHighContrast: 0x7E4116),
                              subtle: WarmVariants(dark: 0x876A59, darkHighContrast: 0xA88672,
                                                   light: 0x796356, lightHighContrast: 0x524036))
        }

        /// Usage Statistics' hue — a deep "verdigris," the FIFTH member of the
        /// family and the only one that isn't a macOS permission at all (the
        /// answer is Audiout's own, kept in `AppSettings.telemetryOptIn`). It
        /// still wears a family hue rather than a neutral grey: a colourless
        /// tile among five would read as disabled, and the setup row IS asking
        /// for a grant, just ours. Hue ~160° in every column/appearance —
        /// clear of both reserved bands (gold/amber `[28°,68°)`, failure-red
        /// `[0°,12°)∪[350°,360°)`) and ≥47° from the other four (~208°/~271°/
        /// ~320°/~23°; the nearest is System Audio at 48°). CONTRAST RATIONALE
        /// (measured): Full dark `#3F977A` = 5.58:1 vs `canvas` / 5.06:1 vs
        /// `panel` / 4.44:1 vs `raised`; Full light `#167656` = 5.35:1 vs the
        /// flat ground / 4.64:1 vs `well`. Subtle (authored): dark `#557C6F` =
        /// 4.24 / 3.85 / 3.38; light `#5A6A65` = 5.46:1 / 4.74:1. IC variants:
        /// Full dark `#7BBEA8` = 9.21 / 8.36 / 7.34, Full light `#0F573F` =
        /// 8.20:1 / 7.10:1; Subtle dark `#889893` = 6.56 / 5.95 / 5.22, Subtle
        /// light `#314E45` = 8.73:1 / 7.56:1.
        public static var permissionUsageStats: NSColor {
            permissionDynamic(name: "permissionUsageStats",
                              full: WarmVariants(dark: 0x3F977A, darkHighContrast: 0x7BBEA8,
                                                 light: 0x167656, lightHighContrast: 0x0F573F),
                              subtle: WarmVariants(dark: 0x557C6F, darkHighContrast: 0x889893,
                                                   light: 0x5A6A65, lightHighContrast: 0x314E45))
        }

        /// Bluetooth SIG brand blue `#0082FC` — the Bluetooth setup row's
        /// glyph tint (Alec, 2026-08-23: the rune wears its official colour).
        /// A BRAND MARK, so one fixed hex in every appearance/contrast
        /// variant, deliberately outside the warmed `permission*` family and
        /// its dial-aware resolver. CONTRAST RATIONALE (measured, same WCAG
        /// relative-luminance formula as the `permission*` hues above): dark
        /// 4.20:1 vs `raised` / 4.79:1 vs `panel`; light 3.60:1 vs the flat
        /// ground / 3.12:1 vs `well` — clearing the same >=3:1 glyph bar those
        /// five hold, in every appearance (it has no Increase-Contrast
        /// variants to match).
        public static var bluetoothBrand: NSColor {
            NSColor(srgbRed: 0x00 / 255, green: 0x82 / 255, blue: 0xFC / 255, alpha: 1)
        }

        // MARK: Alignment-wizard stage instruments (wizard-stage v2 spec §2.1)
        //
        // Tokens for the BT-alignment wizard's stage plate — a FIXED
        // dark instrument ground that never themes with the window (owner
        // ruling 2026-08-23 #1). The "instrument" tokens below
        // (`stagePlate` through `fuseWhite`) pass the SAME hex for dark and
        // light on purpose: the plate is a physical gauge face, not themed
        // chrome, so it reads identically in both appearances (spec's "dark
        // screen set into a light chassis" framing). `syncSignalDeep` is the
        // opposite case — a themed chrome companion that DOES vary by
        // appearance, used only where the target's identity hue must sit on
        // the THEMED window ground (plate rim/keycap tint in light mode)
        // rather than the fixed plate itself. The wizard's REFERENCE light
        // and rim are `ring` — pinned to its dark hex on the stage, themed on
        // the plates — so `ring` needs no Deep companion of its own.
        // `party`/`partyRampDeep` are group identity (C1) and are not drawn
        // on this sheet. None of these are accent-dial remapped (spec §2.2):
        // the stage no longer borrows `gold`/`glow`, so the dial's remap
        // cannot collide with "which speaker" identity.

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
        public static var wireCore: NSColor {
            warmDynamic(name: "wireCore", dark: 0x2BFF8F, darkHighContrast: 0x2BFF8F,
                       light: 0x2BFF8F, lightHighContrast: 0x2BFF8F)
        }

        /// `wireCore`'s THEMED CHROME companion — the target's plate
        /// rim/keycap tint on the themed window ground in light mode, where
        /// electric green measures only ≈1.3:1 on near-white (invisible).
        /// Dark reuses the electric value at FULL strength (owner ruling
        /// 2026-08-23, superseding spec §2.2's "dark = electric value at
        /// 0.45 alpha over `raised`" — at 0.45 the rims measured olive and
        /// mauve, 45% of the lights' chroma). CONTRAST
        /// RATIONALE: light `#0B7A45` measures 5.18:1 vs the flat ground /
        /// 4.49:1 vs `well`, clearing the spec's required ≥3:1 floor on both
        /// light grounds; IC `#086237` deepens further.
        public static var syncSignalDeep: NSColor {
            warmDynamic(name: "syncSignalDeep", dark: 0x2BFF8F, darkHighContrast: 0x2BFF8F,
                       light: 0x0B7A45, lightHighContrast: 0x086237)
        }

        /// The website's Party Magenta — group identity, consumed by the
        /// popover and Groups. Fixed in both appearances. CONTRAST
        /// RATIONALE: measured 9.71:1 vs `stagePlate`.
        public static var party: NSColor {
            warmDynamic(name: "party", dark: 0xFF90E9, darkHighContrast: 0xFF90E9,
                       light: 0xFF90E9, lightHighContrast: 0xFF90E9)
        }

        /// `party`'s themed chrome companion — "the magenta ramp's own
        /// dark end" (spec §2.1), for the popover/Groups grounds that theme.
        /// Dark keeps the electric value at FULL strength (owner ruling
        /// 2026-08-23), the same way `syncSignalDeep` does.
        /// CONTRAST RATIONALE: light `#752C68` measures 8.69:1 vs the flat
        /// ground / 7.53:1 vs `well`, clearing the spec's required ≥3:1 floor;
        /// IC `#5E2354` deepens further.
        public static var partyRampDeep: NSColor {
            warmDynamic(name: "partyRampDeep", dark: 0xFF90E9, darkHighContrast: 0xFF90E9,
                       light: 0x752C68, lightHighContrast: 0x5E2354)
        }

        /// The fused/locked hue — additive-fusion climax color, transient +
        /// locked ring (spec §2.1/§2.2). CONTRAST RATIONALE: measured
        /// 17.98:1 vs `stagePlate` (spec's "~18:1"). Fixed both appearances.
        public static var fuseWhite: NSColor {
            warmDynamic(name: "fuseWhite", dark: 0xFFF4E2, darkHighContrast: 0xFFF4E2,
                       light: 0xFFF4E2, lightHighContrast: 0xFFF4E2)
        }

        // MARK: Deprecated aliases (removed by the surface PRs)
        //
        // Every retired or renamed token forwards here so no surface changed
        // in the commit that re-valued the palette. Each surface PR deletes
        // the aliases it is the last consumer of — grep `Tokens.Color.<old>`
        // across Sources AND Tests before removing one. An enum cannot alias a
        // case, but `Tokens.Color` has no cases (its members are static
        // properties), so a forwarding static property is the alias; because
        // `label2`/`label3` are `static let`, identity comparisons still hold
        // through them.

        @available(*, deprecated, renamed: "label2")
        public static var secondaryLabel: NSColor { label2 }
        @available(*, deprecated, renamed: "label2")
        public static var inkSecondary: NSColor { label2 }
        @available(*, deprecated, renamed: "label3")
        public static var tertiaryLabel: NSColor { label3 }
        @available(*, deprecated, renamed: "label3")
        public static var inkTertiary: NSColor { label3 }
        @available(*, deprecated, renamed: "canvas")
        public static var canvasHi: NSColor { canvas }
        @available(*, deprecated, renamed: "raised")
        public static var iconSeatFill: NSColor { raised }
        @available(*, deprecated, renamed: "panel")
        public static var sidebarWarmTint: NSColor { panel }
        @available(*, deprecated, renamed: "gold")
        public static var accent: NSColor { gold }
        @available(*, deprecated, renamed: "failure")
        public static var warning: NSColor { failure }
        @available(*, deprecated, renamed: "ring")
        public static var info: NSColor { ring }
    }

    // MARK: - Type

    /// Typography aliases. Every case forwards to the exact
    /// `NSFont.systemFont`/`.boldSystemFont`/`.menuFont` call and size the
    /// codebase already used at the exact-duplicate sites migrated in this
    /// pass (design-token audit P1-4) — the aliases mirror shipped usage as
    /// of this pass, not a claim that every call site in the five UI
    /// packages has been swept; the remaining off-scale sizes this pass left
    /// alone are ledgered in their owning folders' `AGENTS.md` rather than
    /// tokenised without a type-scale decision. Two spec-named custom
    /// exceptions: ``microLabel`` (the Warm Signal §2 micro-label voice) and
    /// ``detail``/``display`` (P1-4's two newly-promoted sizes).
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
        /// The row `%` readout (iOS Readout: bold, tabular digits) at the
        /// caption size so it keeps fitting the 40 pt readout column; semibold
        /// is the system face's cut nearest iOS's 700. `goldText` while
        /// sounding, `emberText` while idle, `labelCool2` while not adjustable.
        public static var readout: NSFont {
            .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        }
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
        /// The **micro-label voice** (One Case rule, 2026-08-23): the plain
        /// system face, semibold, sentence case as authored — the state
        /// vocabulary ("Muted") and inline tags ("AP1"). Replaces the old
        /// SF Mono bold UPPERCASE + kern treatment; a token now stands out
        /// from the body text sharing its line by weight alone. 10 pt matches
        /// the sublabel line it rides in, so the line's height cannot change
        /// (§3.5 no-reflow rule).
        public static var microLabel: NSFont {
            .systemFont(ofSize: 10, weight: .semibold)
        }
        /// The BT sync drawer's click-to-edit value field. Monospaced digits
        /// so the number keeps its width as it steps. Sized to sit with the
        /// row's own controls, not to shout — two live findings cut it down in
        /// turn (a 26 pt version dwarfed everything around it and clipped
        /// "−410" to "−41"; a 15 pt one still overhung the small buttons it now
        /// shares a band with). One point over ``caption``, medium weight, is
        /// enough for the editable number to read as the focal control.
        /// Semibold is the system face's cut nearest the iOS Readout's 700
        /// (``readout``'s precedent); the size stays 12 pt for the two live
        /// findings above.
        public static var syncReadout: NSFont {
            .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .semibold)
        }
        /// The alignment-wizard plate keycap glyph voice ("←"/"→"/"SPACE"/"⏎"
        /// chips on `AlignmentPlateButton`): the plain system face at the
        /// micro-label weight. Not monospaced — the chip draws the WORD
        /// "SPACE" and iOS's One Case rule has no monospaced design; measured
        /// 36.58 pt in the 44 pt wide chip.
        public static var keycap: NSFont {
            .systemFont(ofSize: 11, weight: .semibold)
        }
        /// The wizard's two ANSWER plates' title (owner ruling 2026-08-23:
        /// 236×88 hero plates with a 15 pt semibold title). Neither
        /// ``bodyEmphasized`` (13) nor ``heading`` (16) is that size; only
        /// `BTAlignmentWizardView` consumes it.
        public static var plateTitle: NSFont { .systemFont(ofSize: 15, weight: .semibold) }
        /// The compact explanatory voice (design-token audit P1-4): the
        /// alignment prompt copy and the card note line — an 11 pt regular size
        /// two call sites already used independently.
        public static var detail: NSFont { .systemFont(ofSize: 11) }
        /// The Setup window's display headline voice (design-token audit
        /// P1-4): a 20 pt bold size two exact-duplicate call sites already
        /// used independently.
        public static var display: NSFont { .systemFont(ofSize: 20, weight: .bold) }
        /// One step above ``display``, for a window whose headline is the
        /// whole reason it opened rather than the title of a step: the
        /// first-open licence gate's "Welcome to Audiout"
        /// (`LicenseGateViewController`, its only consumer). 20 pt read small
        /// on that window's 560 × 440 stage, where the headline has no
        /// sibling chrome to be measured against.
        public static var displayLarge: NSFont { .systemFont(ofSize: 24, weight: .bold) }

        /// The WORDMARK face — Clash Display Semibold, for the product name
        /// and nothing else (the iPhone companion's "Name Only Rule": a
        /// wordmark sets "Audiout", never a heading, a button, or body copy).
        ///
        /// The `.otf` is in NEITHER git NOR the SwiftPM resource bundle: the
        /// ITF Free Font License permits embedding the face in a desktop app
        /// but forbids redistributing the file through a public repository, so
        /// `scripts/make-app.sh` fetches it at assembly into
        /// `Contents/Resources` and `Bundle.main` finds it there. Under
        /// `swift run`, `swift test` and the snapshot tools there is no `.app`,
        /// so the system bold face is the NORMAL path, not an error.
        ///
        /// `NSFont(name:)` is never called without a successful registration
        /// from the bundle, so a Clash Display copy installed in the user's
        /// Font Book can never make a non-`.app` process render differently
        /// from a test.
        public static func wordmark(size: CGFloat) -> NSFont {
            guard wordmarkRegistered else { return .boldSystemFont(ofSize: size) }
            return NSFont(name: "ClashDisplay-Semibold", size: size)
                ?? .boldSystemFont(ofSize: size)
        }

        private static let wordmarkRegistered: Bool = {
            guard let url = Bundle.main.url(forResource: "ClashDisplay-Semibold",
                                            withExtension: "otf") else { return false }
            return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }()
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

        /// The iPhone companion's three corner radii (`WarmSignal.Radius` in
        /// `audiout-remote`), carried across so the two apps round the same
        /// shapes by the same amounts. NO consumer is re-pointed at them in
        /// the commit that adds them — each surface PR adopts the rung it
        /// needs. Distinct from ``panelCornerRadius`` above, which is the
        /// control-panel shell's bubble and stays 12.
        public enum Radius {
            /// A control's own corner — buttons, chips, fields.
            public static let control: CGFloat = 10
            /// A row's corner inside a list.
            public static let row: CGFloat = 16
            /// A panel or card's outer corner.
            public static let panel: CGFloat = 26
        }
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
        /// indicator (`AudioutApp.QuittingIndicatorPanel`) — the app's one
        /// floating HUD surface; every other chrome surface paints the
        /// custom warm canvas (`WarmCanvasView`, spec §5.1) and draws no
        /// material.
        public static var popover: NSVisualEffectView.Material { .menu }
        /// Opaque window-chrome material (onboarding background, Settings
        /// window background, About panel). Alias of
        /// `NSVisualEffectView.Material.windowBackground`.
        public static var windowBackground: NSVisualEffectView.Material { .windowBackground }
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
        let increaseContrast = Tokens.test_increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
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
        let increaseContrast = Tokens.test_increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
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

/// The accent-dial-aware sibling of `warmDynamic`, for the only tokens the
/// dial remaps: `gold`, `goldText`, `ember`, `emberText`, `glow`. The dial
/// switch lives INSIDE the dynamic provider, so a stored `NSColor` re-resolves
/// against the CURRENT `Tokens.accentStyle` on its next resolution — the
/// live-remap seam.
///
/// - `full`/`subtle`: the authored hex columns. `subtle: nil` means the token
///   has NO Subtle rendering (`glow` — "no glow shadow") and resolves `.clear`.
private func accentDynamic(name: String,
                           full: WarmVariants,
                           subtle: WarmVariants?) -> NSColor {
    NSColor(name: NSColor.Name("WarmSignal.\(name)")) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let increaseContrast = Tokens.test_increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        switch Tokens.accentStyle {
        case .fullGold:
            return NSColor(warmSignalHex: full.hex(isDark: isDark, increaseContrast: increaseContrast))
        case .subtle:
            guard let subtle else { return .clear }
            return NSColor(warmSignalHex: subtle.hex(isDark: isDark, increaseContrast: increaseContrast))
        }
    }
}

/// The accent-dial-aware resolver for the five permission-row identity hues
/// (`permissionSystemAudio`/`permissionLocalNetwork`/`permissionRemoteControl`/
/// `permissionSpeakerSync`/`permissionUsageStats`) — a SIBLING of
/// `accentDynamic`, not a caller of it, for one concrete reason:
/// `accentDynamic`'s `subtle: WarmVariants?` models a token that can have NO
/// Subtle rendering at all (`glow`'s `subtle: nil -> .clear`, because a halo
/// is allowed to vanish). These five are opaque SF Symbol glyph fills, always
/// rendering something — `.clear` here would be an invisible icon, not a muted
/// one, so `subtle` below is a non-optional `WarmVariants` and the Subtle case
/// always resolves a real colour.
///
/// Resolution: `.fullGold` resolves the authored FULL column, `.subtle` the
/// authored SUBTLE column (the dial genuinely mutes these five, unlike
/// `failure`/`rim`/`ring` which it never touches at all).
private func permissionDynamic(name: String,
                               full: WarmVariants,
                               subtle: WarmVariants) -> NSColor {
    NSColor(name: NSColor.Name("WarmSignal.\(name)")) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let increaseContrast = Tokens.test_increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        switch Tokens.accentStyle {
        case .fullGold:
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
