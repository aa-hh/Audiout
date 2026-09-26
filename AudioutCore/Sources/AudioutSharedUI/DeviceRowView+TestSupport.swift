// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

extension DeviceRowView {

    /// The slider's live behavior configuration (continuous / range / type) —
    /// asserts the WarmFaderCell swap left NSSlider behavior stock.
    public var test_sliderConfiguration:
        (isContinuous: Bool, min: Double, max: Double, type: NSSlider.SliderType) {
        (slider.isContinuous, slider.minValue, slider.maxValue, slider.sliderType)
    }

    /// The value the slider is actually SHOWING — read from the control, not from
    /// the model that was handed to `apply`. That distinction is the point: it
    /// catches a row whose displayed level has drifted from what was painted.
    public var test_sliderValue: Int { slider.integerValue }

    /// The volume slider itself, for pixel-truth rendering in tests.
    public var test_slider: NSSlider { slider }

    /// Which connection ring the row is currently showing — derived from
    /// `device.connectionState` (the single source the ring renders from), so it
    /// can never drift from what's actually on screen. (Named `statusKind` for
    /// back-compat; it now reports the halo-ring form.)
    public var test_statusKind: StatusKind {
        switch device.connectionState {
        case .off:                        return .none
        case .connecting, .reconnecting:  return .connecting
        case .connected:                  return .connected
        case .failed:                     return .failed
        }
    }

    /// The halo ring's ACTUAL rendered form, read from the ring view (not
    /// re-derived from `connectionState`) — proves the ring is wired to the
    /// state, catching a drive-path regression `test_statusKind` can't.
    public var test_ringForm: StatusKind {
        switch haloRingView.test_form {
        case .none:        return .none
        case .connecting:  return .connecting
        case .connected:   return .connected
        case .failed:      return .failed
        // `.resting` (ring-resting-state task) is Main Audio-only — a device
        // row's `haloRingView.apply(_:)` call never passes `restingArmed`, so
        // this case is unreachable here; mapped defensively to `.none` (the
        // form `.off` would render without that bit) rather than widening
        // `StatusKind` for a form this view can never actually produce.
        case .resting:     return .none
        }
    }

    /// The halo ring's current stroke color (resolved against the effective
    /// appearance) — asserts connected (`rim`) vs failed (`failure`)
    /// use distinct hues.
    public var test_ringStrokeColor: NSColor? { haloRingView.test_strokeColor }

    /// The halo ring's current stroke width — asserts the failed ring's heavier
    /// weight (`haloRingFailedStroke`) vs the connected ring.
    public var test_ringLineWidth: CGFloat { haloRingView.test_lineWidth }

    /// Whether the halo ring is currently DASHED — the connecting/reconnecting
    /// "incomplete" form, which survives (static) under Reduce Motion.
    public var test_ringIsDashed: Bool { haloRingView.test_isDashed }

    /// The row's current VoiceOver label — lets tests assert every connection
    /// state has a spoken equivalent (the ring's accessible counterpart, spec
    /// §4.8; absorbs A11Y-DEVICEROW for connection state).
    public var test_accessibilityLabel: String? { accessibilityLabel() }

    /// The current sublabel's text, or `nil` when hidden. Reports whichever of the
    /// three sublabel kinds is showing (failed "Couldn't connect" / "Unavailable"
    /// / the routing line), since all three flow through the single `statusLabel`.
    public var test_statusText: String? {
        statusLabel.isHidden ? nil : statusLabel.stringValue
    }

    /// The sublabel's current text color, or `nil` when hidden — asserts the
    /// failed sublabel uses the failure-exclusive red (R8), paired with the
    /// failed ring.
    public var test_statusColor: NSColor? {
        statusLabel.isHidden ? nil : statusLabel.textColor
    }

    /// The composed routing sublabel string ("System …" joined by " · "), or
    /// `nil` when the routing set is empty — for asserting the routing line in
    /// isolation from the failed/unavailable precedence. `liveAppNames`
    /// defaults to empty so existing intent-only callers are unaffected; pass it
    /// to assert the T9 live-precedence-over-intent behavior. Test hook.
    public func test_sourceText(routedAppNames: [String], liveAppNames: [String] = []) -> String? {
        routingLine(routedAppNames: routedAppNames, liveAppNames: liveAppNames)
    }

    // MARK: FEED column test hooks

    /// Every `FeedPillView` CURRENTLY arranged in `feedStack`, in left-to-
    /// right order, or `[]` when there's nothing to show / this row hosts no
    /// FEED column at all (a non-bus host).
    private var feedPills: [FeedPillView] {
        guard busActive, !feedStack.isHidden else { return [] }
        return feedStack.arrangedSubviews.compactMap { $0 as? FeedPillView }
    }

    /// The FEED column's current plain-text content, or `nil` when it has
    /// nothing to show. Joins each pill's own text with the same
    /// " · " a test already reads between values — including a trailing
    /// "+N" pill when present — so a test can assert the rendered WORDS
    /// across the whole
    /// pill row without parsing per-pill color runs itself.
    public var test_feedText: String? {
        let pills = feedPills
        guard !pills.isEmpty else { return nil }
        let text = pills.map(\.test_text).joined(separator: Self.feedSegmentSeparator)
        return text.isEmpty ? nil : text
    }

    /// Whether the FEED column is CURRENTLY rendering an error override
    /// (`.failed` or unavailable, spec item 3) — reads the (single) pill's
    /// mounted triangle glyph (P2-6), which is the whole of what either
    /// override draws since both lost their words on 2026-09-04.
    public var test_feedErrorPillHasGlyph: Bool {
        feedPills.first?.test_hasErrorGlyph ?? false
    }

    /// Whether that glyph is CURRENTLY painted in the failure tone — the
    /// colour half of the error signal, which lives on the glyph rather than
    /// on a text run now that neither override carries words.
    public var test_feedErrorGlyphIsFailureColored: Bool {
        feedPills.first?.test_errorGlyphIsFailureColored ?? false
    }

    /// The FEED column's leading pill's CURRENTLY-painted foreground color
    /// (the main-mix pill; an error override has no text run at all):
    /// `label3` while ``controlsMuted``, `goldText` while the main mix is
    /// sounding here, `label2` otherwise. Reads what's actually painted.
    public var test_feedNeutralColor: NSColor? {
        feedPills.first?.test_leadingRunColor
    }

    /// Whether the row is CURRENTLY rendering the muted-unconnected treatment
    /// (v4 §Call-1 + v4.1 item 8) — the same flag ``faderCell.isMutedControl``
    /// and the FEED dim above both read.
    public var test_controlsMuted: Bool { controlsMuted }

    /// Whether the item-8 connect-edge brighten CROSS-FADE is currently
    /// mid-flight — present on the layer the instant it's added (same idiom
    /// as `RouteArmedDotView.test_isBlooming`: no run loop needed to assert
    /// it fired).
    public var test_isBrightening: Bool {
        layer?.animation(forKey: Self.brightenTransitionKey) != nil
    }

    /// Whether the FEED column is currently showing the static "+N" overflow
    /// suffix (spec item 3 "locked" — capped visible segments, no interactive
    /// reveal).
    public var test_feedHasOverflow: Bool {
        guard let text = test_feedText else { return false }
        return text.range(of: #"\+\d+$"#, options: .regularExpression) != nil
    }

    /// The FEED stack's tooltip — the uncapped "Playing …" line, `nil` when
    /// the column has nothing to show (P1-5).
    public var test_feedTooltip: String? { feedStack.toolTip }

    /// The trailing slot's two occupants, in this row's own coordinates, after
    /// a layout pass. Exposed so a test can pin the column ORDER (pills left
    /// under "Source", chip right under "Offset") and the two shared anchors —
    /// never an absolute width, since AppKit's rounding grid varies per run.
    public var test_trailingSlotFrames: (feed: NSRect, syncChip: NSRect) {
        (feedStack.frame, syncChipButton.frame)
    }

    /// Whether the connecting/reconnecting ring's breathing pulse is installed
    /// (on screen + Reduce Motion off). Lets tests assert the animation hook.
    public var test_ringIsBreathing: Bool { haloRingView.test_isBreathing }

    /// The primary ON/OFF checkbox's current state (for structural assertions).
    public var test_isEnabledOn: Bool { enableCheckbox.state == .on }

    /// Whether the primary membership toggle is shown. Group-member rows hide it
    /// (task C); Selected-Devices rows show it.
    public var test_showsToggle: Bool { !enableCheckbox.isHidden }

    /// The last level pushed to the leading VU meter via ``setLevel(_:)`` — `0`
    /// when the row has no meter (`showsMeter == false`) or after a reset
    /// (``apply(_:selected:controllable:routedAppNames:)``
    /// resets it whenever the row isn't a playing output).
    public func test_meterLevel() -> Float { lastMeterLevel }

    /// The row's icon tint. Always `label2` (the
    /// icon is neutral identity-only; selection reads from the switch, status
    /// from the on-icon dot). Retained for the T-U8 reset test.
    public var test_iconTint: NSColor? { iconView.contentTintColor }

    /// The inks the MUTE button actually paints, most-used first — the button
    /// rendered to a bitmap and the pixels its mark covers bucketed by 8-bit
    /// sRGB value. Engaged that is the enclosing square's fill alone —
    /// the marks are holes, and a hole has no ink. At rest, one neutral ink.
    ///
    /// Colours the drawing code applied are no evidence on their own: the ink
    /// is baked into the image and the button re-tints nothing, so a symbol
    /// that renders as a blank square still reports the colour it was asked
    /// for. This reads pixels.
    public var test_muteDrawnInks: [NSColor] { drawnInks(of: muteButton) }

    /// The same, for the Equalizer door.
    public var test_eqDrawnInks: [NSColor] { drawnInks(of: eqButton) }

    /// Every fully opaque colour `button` paints, most-used first, dropping
    /// anything under 2% of the inked pixels — which is where a symbol's
    /// antialiased edges land.
    private func drawnInks(of button: NSButton) -> [NSColor] {
        layoutSubtreeIfNeeded()
        guard button.bounds.width > 0, button.bounds.height > 0,
              let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds)
        else { return [] }
        button.cacheDisplay(in: button.bounds, to: rep)
        var counts: [Int: Int] = [:]
        var opaque = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                // 0.75, not 1: the mark is an unscaled image centred in a
                // narrower button, so it lands on a fractional offset and
                // every edge is antialiased — an outline square's thin stroke
                // has almost no fully opaque pixel in it. `colorAt`
                // un-premultiplies, so a partly covered pixel still reports
                // the ink itself and the reading stays exact.
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.alphaComponent >= 0.75 else { continue }
                opaque += 1
                let key = (Int(c.redComponent * 255 + 0.5) << 16)
                    | (Int(c.greenComponent * 255 + 0.5) << 8)
                    | Int(c.blueComponent * 255 + 0.5)
                counts[key, default: 0] += 1
            }
        }
        guard opaque > 0 else { return [] }
        return counts
            .filter { CGFloat($0.value) / CGFloat(opaque) >= 0.02 }
            .sorted { $0.value > $1.value }
            .map {
                NSColor(srgbRed: CGFloat(($0.key >> 16) & 0xFF) / 255,
                        green: CGFloat(($0.key >> 8) & 0xFF) / 255,
                        blue: CGFloat($0.key & 0xFF) / 255, alpha: 1)
            }
    }

    /// Whether this row mounted the Equalizer door at all.
    public var test_hasEQButton: Bool { eqButton.superview != nil }
    public var test_eqButtonFrame: NSRect { eqButton.frame }
    public var test_eqButtonHasTitle: Bool { !eqButton.title.isEmpty }
    /// Whether the door CURRENTLY draws its ENGAGED symbol — the filled
    /// square: a ``Tokens/Color/equalizer`` enclosure with the marks
    /// punched out of it.
    /// A pixel comparison against the same symbol built from the same ink,
    /// so the hook reads the drawn image rather than a flag.
    public var test_eqDrawsEngagedSymbol: Bool {
        matchesSymbol(eqButton.image, RowAccessorySymbol.equalizerRest,
                      ink: Self.engagedInk(fill: Tokens.Color.equalizer,
                                           in: effectiveAppearance))
    }

    /// Whether the door CURRENTLY draws its AT-REST symbol — the outline
    /// square in one neutral ink.
    public var test_eqDrawsRestSymbol: Bool {
        matchesSymbol(eqButton.image, RowAccessorySymbol.equalizerRest,
                      ink: Self.restInk(in: effectiveAppearance))
    }

    /// The door glyph's frame in the row's own coordinates, after a layout
    /// pass. The symbol IS the mark now, so the button's frame is what the
    /// "same size, 6 pt apart" assertions measure.
    public var test_eqSeatFrame: NSRect {
        layoutSubtreeIfNeeded()
        return eqButton.frame
    }

    /// The door symbol's DRAWN ink, in the row's own coordinates. The image
    /// box is no substitute — a symbol image carries transparent margin around
    /// its ink, so measuring the box says nothing about how big the enclosing
    /// square actually lands in the row's 24 pt column.
    public var test_eqGlyphInkFrame: NSRect? { inkFrame(of: eqButton) }

    /// The same, for the mute button — what proves the two controls draw one
    /// square at one size, and that the square holds still across a toggle.
    public var test_muteMarkInkFrame: NSRect? { inkFrame(of: muteButton) }

    /// How much of the Equalizer door's slot its mark actually INKS, 0-1 —
    /// the measure that separates a filled square from an outline one without
    /// reading a colour, which is what makes the engaged state legible to
    /// someone who cannot tell the two hues apart.
    public var test_eqInkCoverage: CGFloat { inkCoverage(of: eqButton) }

    /// The same, for the mute button.
    public var test_muteInkCoverage: CGFloat { inkCoverage(of: muteButton) }

    /// The fraction of `button`'s rendered pixels carrying any ink at all.
    private func inkCoverage(of button: NSButton) -> CGFloat {
        layoutSubtreeIfNeeded()
        guard button.bounds.width > 0, button.bounds.height > 0,
              let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds)
        else { return 0 }
        button.cacheDisplay(in: button.bounds, to: rep)
        var inked = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                inked += 1
            }
        }
        return CGFloat(inked) / CGFloat(rep.pixelsWide * rep.pixelsHigh)
    }

    /// `button` rendered to a bitmap, with its non-transparent pixels bounded
    /// and mapped back into the row's own coordinates. `nil` only when the
    /// render itself fails; a caller must FAIL on that rather than skip, or
    /// the check silently stops covering anything.
    private func inkFrame(of button: NSButton) -> NSRect? {
        layoutSubtreeIfNeeded()
        guard button.bounds.width > 0, button.bounds.height > 0,
              let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds)
        else { return nil }
        button.cacheDisplay(in: button.bounds, to: rep)
        let scaleX = button.bounds.width / CGFloat(rep.pixelsWide)
        let scaleY = button.bounds.height / CGFloat(rep.pixelsHigh)
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // `colorAt` counts rows from the TOP; the row's coordinates are
        // bottom-up, so the bitmap's last inked row is the ink's bottom edge.
        return NSRect(
            x: button.frame.minX + CGFloat(minX) * scaleX,
            y: button.frame.minY + button.bounds.height - CGFloat(maxY + 1) * scaleY,
            width: CGFloat(maxX - minX + 1) * scaleX,
            height: CGFloat(maxY - minY + 1) * scaleY)
    }
    public var test_muteButtonFrame: NSRect { muteButton.frame }
    public var test_identityStackFrame: NSRect { identityStack.frame }
    /// The mute mark's frame — the button, which is the mark now. It has to
    /// hold still across a toggle and match the Equalizer door's.
    public var test_muteSeatFrame: NSRect {
        layoutSubtreeIfNeeded()
        return muteButton.frame
    }

    /// Whether the mute button is currently drawing its ENGAGED symbol — the
    /// slashed outline square in ``Tokens/Color/muted``.
    public var test_isMutePillEngaged: Bool {
        muteButton.state == .on && test_mutePillIsMutedHue
    }

    /// Whether the drawn mute image IS the engaged symbol built from the
    /// ``Tokens/Color/muted`` ink resolved in this row's own appearance —
    /// a raster comparison, so the test reads pixels rather than intent.
    public var test_mutePillIsMutedHue: Bool {
        matchesSymbol(muteButton.image, RowAccessorySymbol.muteEngaged,
                      ink: Self.engagedInk(fill: Tokens.Color.muted,
                                           in: effectiveAppearance))
    }

    /// Whether the mute button is drawing its AT-REST symbol.
    public var test_muteDrawsRestSymbol: Bool {
        matchesSymbol(muteButton.image, RowAccessorySymbol.muteRest,
                      ink: Self.restInk(in: effectiveAppearance))
    }

    /// Whether `drawn` rasterises identically to `name` built with `ink`.
    /// A pixel comparison rather than a name lookup: an `NSImage` reconfigured
    /// with a `SymbolConfiguration` reports no name to read back, and
    /// comparing rasters pins the ink, the point size and the weight in one
    /// assertion.
    private func matchesSymbol(_ drawn: NSImage?, _ name: String, ink: NSColor) -> Bool {
        guard let drawn = drawn?.tiffRepresentation,
              let reference = RowAccessorySymbol.image(named: name, ink: ink)?
                  .tiffRepresentation
        else { return false }
        return drawn == reference
    }

    // MARK: Route-armed dot (spec §3.3) test hooks

    /// Whether the gold route-armed corner dot is currently LIT — reads the
    /// dot view's rendered state (the §3.3 predicate's outcome), so it can't
    /// drift from the pixels.
    public var test_routeArmed: Bool { armedDotView.test_isLit }

    /// The dot's current fill color (resolved) — gold when armed, the
    /// dark/empty `socket` otherwise.
    public var test_dotFillColor: NSColor? { armedDotView.test_fillColor }

    /// Whether the one-shot arm bloom is currently mid-flight (fires only on a
    /// transition INTO armed after the first apply, on screen, Reduce Motion
    /// off — spec §6).
    public var test_dotIsBlooming: Bool { armedDotView.test_isBlooming }

    /// The row's current VoiceOver VALUE ("muted" / "armed" / "playing here"
    /// composition) — the spoken equivalent of the dot + mute channels.
    public var test_accessibilityValue: String? { accessibilityValue() as? String }

    /// The row's current VoiceOver HINT (`accessibilityHelp`) — carries the
    /// local-mix refusal reason on a BLOCKED row (spec §4.6, S4), `nil` elsewhere.
    public var test_accessibilityHint: String? { accessibilityHelp() }

    /// Whether the under-name meter is on screen — the armed predicate's other
    /// instrument, and the half `test_meterLevel()` can't see (a pushed level
    /// on a hidden meter is invisible).
    public var test_meterVisible: Bool { showsMeter && !meterView.isHidden }

    /// The meter's current ballistics TARGET — with ``test_meterDisplayed``,
    /// distinguishes the S3 mute DRAIN (target 0, displayed still easing down)
    /// from a hard reset (both 0 instantly).
    public var test_meterTarget: CGFloat { meterView.test_targetLevel }

    /// The meter's currently DRAWN level.
    public var test_meterDisplayed: CGFloat { meterView.test_displayedLevel }

    /// The `%` readout's current text colour (D6) — `goldText` while the row is
    /// sounding, `emberText` while it holds an idle level, and `labelCool2`
    /// while the slider is disabled or the row is not adjustable.
    public var test_readoutColor: NSColor? { readoutLabel.textColor }

    /// Whether the Warm fader would render its ENGAGED (gold-gradient) fill —
    /// route-armed ∧ slider enabled, read from the cell's own gate so the test
    /// can't drift from the pixels. Must track `test_routeArmed` whenever the
    /// slider is enabled (one armed truth, two instruments).
    public var test_isFaderEngaged: Bool { faderCell.test_isEngagedFill }
    public var test_isFaderPending: Bool { faderCell.test_isPendingFill }

    /// Whether the slider is wearing the Warm fader skin (the drawing-only
    /// `WarmFaderCell` swap) — structural assertion that the skin is installed.
    public var test_hasWarmFaderSkin: Bool { slider.cell is WarmFaderCell }

    /// Whether the volume slider is currently enabled (A5) — stays enabled while
    /// the device is muted (mute ≠ frozen volume); only availability/
    /// controllability/unsupported-ness gate it.
    public var test_isSliderEnabled: Bool { slider.isEnabled }

    /// Whether the "Selected Speakers" membership is currently rendered dimmed (A1
    /// / §4.7) — a visual de-emphasis that does NOT disable the control. For a
    /// non-bus row this is the checkbox alpha (~0.4); for a BUS row it's the node
    /// TINT (`busNodeDimmed`), since the bus dims via tint with the checkbox held
    /// at full alpha (§4.7). Pair with `test_isEnabledOn`/clicking to confirm it's
    /// still interactive.
    public var test_isSelectionDimmed: Bool {
        busNodeDimmed || enableCheckbox.alphaValue < 1.0
    }

    // MARK: Membership bus (spec §4) test hooks

    /// The bus node currently drawn (spec §4) — `nil` when this row has no bus
    /// (non-bus host, or a `showsToggle == false` group-member row, which keeps
    /// NO bus node). Reads the same `MembershipBusView` state the drawing reads,
    /// so it can't drift from the pixels.
    public var test_busNode: MembershipBusView.Node? { busActive ? busView.test_node : nil }

    /// Whether the bus node's FILL is the de-emphasis tint — reads the drawn
    /// value (dormant tint, unavailable tint, and the failed-member never-dim
    /// exemption included), unlike `test_isSelectionDimmed` which reports the
    /// host-driven dormancy input. The rim is never tinted, so on a hollow
    /// node the flag is carried but draws nothing. `nil` when the row has no bus.
    public var test_busNodeDimmed: Bool? { busActive ? busView.test_dimmed : nil }

    // MARK: Bluetooth SYNC chip (T6) test hooks

    /// Whether this row mounts the SYNC chip at all.
    public var test_showsSyncControls: Bool { showsSyncControls }

    /// The chip's CURRENTLY displayed text ("22.4 ms" / "Not set"), or `nil`
    /// on a non-sync row.
    public var test_syncChipTitle: String? {
        showsSyncControls ? syncChipButton.attributedTitle.string : nil
    }

    /// The colour the chip's label is actually drawn in — the de-emphasis an
    /// untuned chip and the accent an engaged one must both show.
    /// What the chip's glyph and title actually need, so a longer title than
    /// ``PopoverColumnGrid/syncChipWidth`` fails a test instead of truncating
    /// on someone's row.
    public var test_syncChipFittingWidth: CGFloat {
        syncChipButton.intrinsicContentSize.width
    }

    public var test_syncChipTitleColor: NSColor? {
        guard showsSyncControls, syncChipButton.attributedTitle.length > 0 else { return nil }
        return syncChipButton.attributedTitle
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    /// Which chevron the chip resolved: `chevron.right` collapsed,
    /// `chevron.down` while its drawer is open — the disclosure convention
    /// (pointing AT the closed thing, rotating down to reveal it), not an
    /// up/down toggle. `nil` on a non-sync row.
    public var test_syncChipChevronSymbolName: String? {
        showsSyncControls ? syncChipChevronName : nil
    }

    /// Whether the chip draws the UNTUNED dashed border (D10).
    public var test_syncChipIsDashed: Bool { showsSyncControls && syncChipCell.isUntuned }

    /// Whether the chip wears the ENGAGED treatment (drawer open) — pair with
    /// `test_syncChipFill` to pin that it is the translucent-accent recipe,
    /// never a solid gold fill.
    public var test_syncChipIsEngaged: Bool { showsSyncControls && syncChipCell.isEngaged }

    /// The chip's drawn background fill, or `nil` when it draws none (every
    /// state but engaged) — read off the cell that paints it, so the hook
    /// can't drift from the pixels.
    public var test_syncChipFill: NSColor? {
        showsSyncControls ? syncChipCell.fillColor : nil
    }

    /// The chip's drawn border colour.
    public var test_syncChipBorderColor: NSColor? {
        showsSyncControls ? syncChipCell.borderColor : nil
    }

    /// Whether the chip can be pressed (false = the disconnected row's
    /// read-only saved value — there is nothing to tune while the speaker is
    /// away).
    public var test_syncChipEnabled: Bool {
        showsSyncControls && syncChipButton.isEnabled
    }

    /// The row's context menu exactly as `menu(for:)` builds it — `nil` when
    /// the row offers nothing (This Mac). Tests dispatch items via
    /// `performActionForItem(at:)` (real AppKit menu dispatch), never the
    /// delegate shortcut.
    public func test_contextMenu() -> NSMenu? {
        buildContextMenu()
    }

    /// Whether the icon is currently armed as a menu door.
    public var test_iconIsMenuTrigger: Bool { iconView.onPress != nil }

    /// The icon's spoken identity while it is a button.
    public var test_iconAXLabel: String? { iconView.accessibilityLabel() }

    /// The chip's spoken identity/value/expanded state and its hover tooltip.
    public var test_syncChipAXLabel: String? { syncChipButton.accessibilityLabel() }
    public var test_syncChipAXValue: String? { syncChipButton.accessibilityValue() as? String }
    public var test_syncChipAXExpanded: Bool { syncChipButton.isAccessibilityExpanded() }
    public var test_syncChipTooltip: String? {
        showsSyncControls ? syncChipButton.toolTip : nil
    }

    /// Whether the host has raised the energize "press-play" pending beat on this
    /// row (item 9) — the drawing-only input, distinct from `test_busNode` which
    /// reads the RESOLVED node (the beat only becomes a `.connecting` node while the
    /// device is `.off` AND Reduce Motion is off).
    public var test_energizePending: Bool { energizePending }

    /// The x-position (in this row's coordinates) of the bus node's center, after
    /// layout — used to prove the node NEVER moves when membership toggles (spec
    /// §4.1 / R7 "zero layout shift"). `nil` when the row has no bus.
    public func test_busNodeCenterX() -> CGFloat? {
        guard busActive else { return nil }
        layoutSubtreeIfNeeded()
        return busView.frame.midX
    }

    /// Whether the transient live-removal offer is currently mounted, and the
    /// Undo button's spoken label (structural hooks — the same state the
    /// drawing reads).
    public var test_removalUndoOffered: Bool { removalUndoOffered && !removalUndoStack.isHidden }
    public var test_removalUndoAXLabel: String? { removalUndoButton.accessibilityLabel() }

    /// The membership checkbox's HIT rect in this row's coordinates (the
    /// expanded gutter target), after layout — asserts the click target really
    /// covers the drawn socket. `nil` when the row has no bus.
    public func test_membershipHitRect() -> NSRect? {
        guard busActive else { return nil }
        layoutSubtreeIfNeeded()
        return enableCheckbox.frame
    }

    /// The drawn node's outer rect at the WIDEST any node ever reaches — the
    /// selected size, which a hovered non-member grows into — in this row's
    /// coordinates; what the hit rect above has to contain.
    public func test_nodeRect() -> NSRect? {
        guard busActive else { return nil }
        layoutSubtreeIfNeeded()
        let r = PopoverColumnGrid.busNodeDiameterSelected / 2
        return NSRect(x: busView.frame.midX - r, y: busView.frame.midY - r,
                      width: 2 * r, height: 2 * r)
    }
    /// Whether the node is previewing its post-click size (grown or shrunk).
    public var test_nodePreviewsClick: Bool { busActive && busView.test_nodePreviewsClick }
    /// The radius the node is settling on — resting, or its post-click size.
    /// `nil` when the row has no bus.
    public var test_nodeTargetRadius: CGFloat? {
        busActive ? busView.test_nodeTargetRadius : nil
    }

    /// The membership control's (the node-skinned checkbox's) current VoiceOver
    /// label — asserts the bus node speaks as the SAME real checkbox (spec §4.8:
    /// the node IS the checkbox to VoiceOver; the checked/unchecked value comes
    /// from the un-subclassed `NSButton` state machinery for free).
    public var test_membershipAXLabel: String? { enableCheckbox.accessibilityLabel() }

    /// The membership checkbox's tooltip — "Add/Remove <name> to/from the mix"
    /// on a bus row with its toggle shown, `nil` otherwise (P1-2).
    public var test_membershipTooltip: String? { enableCheckbox.toolTip }
    /// The name label's click-to-add tooltip (unselected bus rows only).
    public var test_nameTooltip: String? { nameLabel.toolTip }

    /// The device name label's current colour (``rowTextColor``) — asserts the
    /// ordinary available/selected states. `apply` already stamps this, so no
    /// `draw(_:)` call is needed to read it.
    public var test_nameColor: NSColor? { nameLabel.textColor }
}
