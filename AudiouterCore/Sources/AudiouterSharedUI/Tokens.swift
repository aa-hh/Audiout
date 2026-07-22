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
/// **At this module's creation, `Tokens` held ZERO custom values.** Every
/// case aliased an existing stock `NSColor`/`NSFont`/`NSVisualEffectView.Material`
/// already in use, and `Tokens.Layout` re-exported `PopoverColumnGrid` (which
/// remains the geometry authority — nothing moved). That zero-custom-value
/// state was the SEAM, not a permanent constraint: **warm-signal-v2** (the
/// popover canvas + card de-nest, `dev/notes/warm-signal-v3.md` §1/§5.1) is
/// the first wave to actually populate `Tokens.Color` with real custom
/// values — the warm surface ladder + hairline (`canvas`, `canvasHi`,
/// `panel`, `raised`, `well`, `hairline`; see the "Warm Signal custom
/// palette" section below). `Tokens.Font`/`Tokens.Layout`/`Tokens.Material`
/// remain pure forwarding aliases (plus `Font.microLabel`, the spec-named
/// §2 micro-label voice added by S3's MUTED sublabel token); only
/// `Tokens.Color` gains custom cases, and only ones a real call site
/// consumes in the same wave: the S-chain has since added `ringConnected`/
/// `failure` (S1), `gold`/`ember` (S-BUS), and `caution`/`glow`/`dotSocket`
/// (S2+S3, the meter gradient + route-armed dot). `link` remains unadded
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
    public static var accentStyle: AccentStyle = .fullGold

    // MARK: - Color

    /// Semantic color aliases. Every case forwards to the exact `NSColor`
    /// class-property the codebase already calls directly (verified via
    /// `git grep -n "NSColor\." AudiouterCore/Sources/{AudiouterOnboardingUI,
    /// AudiouterSharedUI,AudiouterPopoverUI,AudiouterWindowUI,
    /// AudiouterSettingsUI}`). No custom RGB/hex value lives here — only
    /// forwarding. When the warm palette lands in a later wave, it replaces
    /// the right-hand side of these aliases; call sites that already route
    /// through `Tokens.Color` won't need to change.
    public enum Color {
        /// Primary label text. Alias of `NSColor.labelColor`.
        public static var label: NSColor { .labelColor }
        /// Secondary/subordinate label text (subtitles, hints). Alias of
        /// `NSColor.secondaryLabelColor`.
        public static var secondaryLabel: NSColor { .secondaryLabelColor }
        /// De-emphasized label text (sublabels, dimmed inline detail). Alias
        /// of `NSColor.tertiaryLabelColor`.
        public static var tertiaryLabel: NSColor { .tertiaryLabelColor }
        /// The system accent color, used for selection washes and active-state
        /// fills. Alias of `NSColor.controlAccentColor`.
        public static var accent: NSColor { .controlAccentColor }
        /// Hairline/divider strokes. Alias of `NSColor.separatorColor`.
        public static var separator: NSColor { .separatorColor }
        /// Opaque window chrome background (onboarding, Settings). Alias of
        /// `NSColor.windowBackgroundColor`. (Its former consumer, the
        /// control-panel backing bubble, repointed to the warm `canvas` token
        /// in W8, spec §5.4.)
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
        /// Opaque shadow color for card/panel drop shadows (`CardView`). Alias
        /// of `NSColor.black`.
        public static var shadow: NSColor { .black }
        /// Fully transparent fill, used to make a layer's background see
        /// through to a view behind it (`ControlPanelWindowController`). Alias
        /// of `NSColor.clear`.
        public static var clear: NSColor { .clear }

        // MARK: Warm Signal custom palette (V2, spec §1)
        //
        // The ONE place a custom (non-semantic) RGB value may live, per root
        // AGENTS.md's governance rule ("Every `Tokens.Color` case ships
        // light + dark + Increase Contrast variants with a documented
        // contrast rationale"). V2 (the popover canvas + card de-nest) is
        // the first consumer: the warm surface ladder + hairline from spec
        // §1.1 (dark) / §1.2 (light). `panel`/`raised`/`well` are defined
        // here per the spec's full palette table but are NOT YET painted
        // anywhere — V2's de-nest removes the card's own panel fill rather
        // than adding one; they're reserved for a later wave (ring contrast
        // reference, slider track/well, mute-pill fill). Every case below
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
        /// so no separate Increase Contrast value.
        public static var canvas: NSColor {
            warmDynamic(name: "canvas", dark: 0x16130F, light: 0xF4EFE7)
        }
        /// Canvas gradient top (§1.1/§1.2), paired with `canvas` by
        /// `WarmCanvasView`'s vertical gradient. No stated contrast floor.
        public static var canvasHi: NSColor {
            warmDynamic(name: "canvasHi", dark: 0x1B1712, light: 0xF7F3EC)
        }
        /// Card/panel fill — "the reference canvas a ring sits on" (§1). Not
        /// yet painted by any call site in V2 (cards stop drawing their own
        /// fill when de-nested onto the canvas, §5.1); reserved for a later
        /// wave. No stated contrast floor.
        public static var panel: NSColor {
            warmDynamic(name: "panel", dark: 0x1D1915, light: 0xFBF8F2)
        }
        /// Raised well fill (icon well, blocked-checkbox fill, §1). Not yet
        /// painted by any call site in V2 — reserved for a later wave. No
        /// stated contrast floor.
        public static var raised: NSColor {
            warmDynamic(name: "raised", dark: 0x241F1A, light: 0xFFFFFF)
        }
        /// Inset well fill (slider track trough, dropdown fill, §1). Not yet
        /// painted by any call site in V2 — reserved for a later wave. No
        /// stated contrast floor.
        public static var well: NSColor {
            warmDynamic(name: "well", dark: 0x2B2620, light: 0xECE5D8)
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
        /// regardless, so a symmetrical darkened warm-tan (`#9B8768`,
        /// ≈3.25:1 vs light `panel` `#FBF8F2`) is used there too — the
        /// quietest reasonable choice, not a spec requirement.
        public static var hairline: NSColor {
            warmDynamic(name: "hairline", dark: 0x3A332B, darkHighContrast: 0x786B5A,
                       light: 0xE2DACC, lightHighContrast: 0x9B8768)
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
        // relative luminance): dark `gold` `#E8B84B` ≈ 8.9:1 vs `panel` `#1D1915`;
        // light `gold` `#A97F1E` ≈ 3.6:1 vs `panel` `#FBF8F2` (the deepened
        // paper-gold, spec §1.2's stated floor pick). `ember` is dimmer by design
        // (it's the connecting line, not the node): dark `#8A6A2F` ≈ 3.5:1 vs
        // `panel`; light `#C2A05A` ≈ 2.0:1 vs `panel` — BELOW the 3:1 instrument
        // floor as a hairline, but `ember` here is a 2 pt LINE paired with the
        // high-contrast `gold` nodes it connects, and spec §1.2 lists `ember` at
        // exactly this hex; per the spec's escape valve the Increase-Contrast
        // variant is brightened/deepened to clear the floor (light IC `#9A7A2E`
        // ≈ 3.4:1) while the base stays the spec hex (Wave-5 sweep owns any base
        // re-tune). IC variants (my picks, flagged for the Wave-5 sweep like
        // `ringConnected`): dark `gold` `#F2C75E`, dark `ember` `#A5824A`, light
        // `gold` `#8A6614`, light `ember` `#9A7A2E`.

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
                          full: WarmVariants(dark: 0xE8B84B, darkHighContrast: 0xF2C75E,
                                             light: 0xA97F1E, lightHighContrast: 0x8A6614),
                          subtle: WarmVariants(dark: 0xB99B53, darkHighContrast: 0xCBAF6A,
                                               light: 0x8F7B4A, lightHighContrast: 0x6F5E33),
                          systemAccentScale: 1.0)
        }

        /// Gold's dim companion — the bus LINE ink (spec §4.1), the filled node's
        /// rim (§4.2), and the meter low end (§1). Dimmer than `gold` by design.
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
                          full: WarmVariants(dark: 0x8A6A2F, darkHighContrast: 0xA5824A,
                                             light: 0xC2A05A, lightHighContrast: 0x9A7A2E),
                          subtle: WarmVariants(dark: 0x6D5B34, darkHighContrast: 0x877146,
                                               light: 0xAE9668, lightHighContrast: 0x8A744C),
                          systemAccentScale: 0.55)
        }

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
    }

    // MARK: - Layout

    /// Layout aliases. `PopoverColumnGrid` remains the geometry authority —
    /// it is not moved, renamed, or duplicated. These are forwarding
    /// properties only, so code that wants "the app's layout tokens" has one
    /// import (`Tokens.Layout`) without new call sites needing to know that
    /// the underlying constants still live in `PopoverColumnGrid`.
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
    }

    // MARK: - Material

    /// `NSVisualEffectView.Material` aliases for the vibrancy materials the
    /// codebase already applies. No custom material or blending mode lives
    /// here — only forwarding.
    public enum Material {
        /// The system menu-surface material. Alias of
        /// `NSVisualEffectView.Material.menu`. UNCONSUMED as of V2: `CardView`
        /// and `PopoverPanelViewController` both used `.menu` directly (not
        /// through this alias) before the warm-signal-v2 de-nest, which
        /// replaced both call sites with the custom-painted warm canvas
        /// (`WarmCanvasView`, spec §5.1) — neither draws any
        /// `NSVisualEffectView` material anymore. Kept as a forwarding alias
        /// per the governance rule's spirit (it still names a real, applied-
        /// elsewhere-in-AppKit system material) but has no current call site;
        /// do not add a NEW consumer without checking this comment is still
        /// accurate.
        public static var popover: NSVisualEffectView.Material { .menu }
        /// Opaque window-chrome material (onboarding background, Settings
        /// window background, About panel). Alias of
        /// `NSVisualEffectView.Material.windowBackground`.
        public static var windowBackground: NSVisualEffectView.Material { .windowBackground }
        /// The source-list sidebar material, applied implicitly by
        /// `NSTabViewItem.sidebar(withViewController:)` in
        /// `SidebarViewController`/`MixerWindowController`. Alias of
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
