// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
import AudioutCore
@testable import AudioutSharedUI

/// C2 — the Warm Signal accessibility sweep of the NEW signals (spec §8's
/// resolved instruments: halo ring, route-armed dot, mute channel, bus
/// membership) plus the LIVE accessibility-display reconcile:
///
/// 1. **One composed row announcement.** VoiceOver hears ring state, armed
///    dot, mute, and bus membership as ONE coherent announcement — each
///    channel spoken exactly once (label carries identity + membership +
///    volume + connection; value carries the live signal equivalents), with
///    no duplicated or conflicting fragments, and the spoken state always
///    mirroring the pixels.
/// 2. **Mid-session display-options toggles reconcile live.** A Reduce
///    Motion flip in System Settings posts
///    `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`; the
///    ring's breathing pulse and the dot's arm bloom must reconcile off that
///    notification without waiting for the next `apply`. Tests post the same
///    notification on the same (workspace) center the OS uses, with the
///    `test_reduceMotionOverride` seam standing in for the un-flippable real
///    setting.
/// 3. **Increase Contrast / Reduce Transparency paths.** The warm canvas
///    flattens to the opaque `canvas` base (no gradient, no grain) and
///    repaints live; ring/meter token colors re-stamp off the notification.
@MainActor
@Suite final class AccessibilitySignalSweepTests: IsolatedSuite {

    private func makeDevice(connectionState: ConnectionState = .connected,
                            isMuted: Bool = false,
                            isAvailable: Bool = true) -> Device {
        Device(id: "dev-ax", name: "Sweep Speaker", kind: .homePod,
               isAvailable: isAvailable, isMuted: isMuted,
               connectionState: connectionState)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func postDisplayOptionsChanged() {
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared)
    }

    // MARK: 1 — one composed row announcement, no duplicate/conflicting fragments

    @Test func composedAnnouncementSpeaksEveryChannelExactlyOnce() {
        let row = DeviceRowView(device: makeDevice(), showsBus: true)
        row.apply(makeDevice(), selected: true, controllable: true)

        // Label: identity + bus membership + volume + ring (connection) state.
        let label = row.test_accessibilityLabel ?? ""
        #expect(label.hasPrefix("Sweep Speaker, "), "identity leads the announcement")
        #expect(label.contains(", in main audio"), "bus membership rides the one row label")
        // v4.1 item 3: the FEED clause ("playing System") now trails the ring's
        // connection-state clause — one more channel in the same composed
        // announcement, not a replacement for it.
        #expect(label.hasSuffix(", connected, playing System"), "the ring's state leads, the FEED clause trails, in the same announcement")
        #expect(label.components(separatedBy: "connected").count - 1 == 1, "the connection state is spoken exactly once")

        // Value: the live-signal channels (dot/mute) — and ONLY there, so the
        // label and value never repeat or contradict each other.
        #expect(row.test_accessibilityValue == "armed")
        #expect(!(label.contains("armed")), "the dot's word lives in the VALUE, never also the label")
        #expect(!(label.contains("muted")), "no phantom mute fragment on an unmuted row")
    }

    @Test func busRowMembershipVocabularyMatchesItsCheckbox() {
        // Coherence (spec §4.8 + C2): the bus row's checkbox says "Include …
        // in main audio", so the row-level membership clause speaks the SAME
        // concept — one vocabulary inside one announcement.
        let member = DeviceRowView(device: makeDevice(), showsBus: true)
        member.apply(makeDevice(), selected: true)
        #expect((member.test_accessibilityLabel ?? "").contains(", in main audio"))
        #expect(member.test_membershipAXLabel == "Include Sweep Speaker in main audio")

        let nonMember = DeviceRowView(device: makeDevice(), showsBus: true)
        nonMember.apply(makeDevice(), selected: false)
        #expect((nonMember.test_accessibilityLabel ?? "").contains(", not in main audio"))
        #expect(!((nonMember.test_accessibilityLabel ?? "").contains("not selected")), "a bus row never mixes the checkbox-column vocabulary into the same announcement")
    }

    @Test func nonBusRowKeepsTheSelectedVocabulary() {
        // Mixer-window/group hosts still draw a plain "Selected" checkbox —
        // their announcement keeps the matching phrasing, unchanged.
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true)
        #expect((row.test_accessibilityLabel ?? "").contains(", selected"))
        #expect(!((row.test_accessibilityLabel ?? "").contains("main audio")))
    }

    @Test func mutedAnnouncementNeverConflictsWithArmed() {
        // The dot's predicate includes the unmuted term, so "muted" and
        // "armed" are mutually exclusive on the main-mix branch — the spoken
        // value mirrors the (dark) dot instead of contradicting the mute.
        let muted = makeDevice(isMuted: true)
        let row = DeviceRowView(device: muted, showsBus: true)
        row.apply(muted, selected: true, controllable: true)
        #expect(row.test_accessibilityValue == "muted")
        #expect(!(row.test_routeArmed), "the pixels agree: mute darkens the dot")
        #expect(!((row.test_accessibilityLabel ?? "").contains("muted")), "muted is spoken once (value), not twice")
    }

    @Test func failedRowNeverSpeaksArmed() {
        // Ring failure + a dark dot: the announcement carries the failure
        // clause and NO armed fragment — failure and confirmation never share
        // one announcement (emphasis ladder, spec §3.1).
        let failed = makeDevice(connectionState: .failed(.init(cause: .notResponding)))
        let row = DeviceRowView(device: failed, showsBus: true)
        row.apply(failed, selected: true, controllable: true)
        #expect((row.test_accessibilityLabel ?? "").hasSuffix(", couldn't connect"))
        // Since 2026-09-04 the value also carries the failure's own headline —
        // the FEED pill stopped printing it. The intent here is unchanged: no
        // armed fragment shares an announcement with a failure.
        #expect(!(row.test_accessibilityValue ?? "").contains("armed"),
                "a failed route is never spoken as armed")
        #expect(row.test_accessibilityValue == "Didn't respond",
                "the headline the pill no longer prints is spoken here instead")
        #expect(!(row.test_routeArmed))
    }

    @Test func spokenValueMirrorsTheDotExactly() {
        // "playing here" iff the gold dot is lit by a confirmed live feed —
        // the spoken channel can never drift from the drawn one.
        let row = DeviceRowView(device: makeDevice(), showsBus: true)
        row.apply(makeDevice(), selected: false, liveAppNames: ["Spotify"])
        #expect(row.test_routeArmed)
        #expect(row.test_accessibilityValue == "playing here")

        row.apply(makeDevice(), selected: false, liveAppNames: [])
        #expect(!(row.test_routeArmed))
        #expect(row.test_accessibilityValue == "")
    }

    // MARK: 2 — mid-session Reduce Motion toggles reconcile LIVE

    @Test func connectingRingGoesStaticWhenReduceMotionArrivesMidSession() {
        let ring = HaloRingView()
        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(ring)
        ring.test_reduceMotionOverride = false
        ring.apply(.connecting)
        #expect(ring.test_isBreathing, "motion allowed: the connecting ring breathes")

        ring.test_reduceMotionOverride = true
        postDisplayOptionsChanged()
        #expect(!(ring.test_isBreathing), "the toggle reconciles off the notification — no waiting for the next apply")
        #expect(ring.test_isDashed, "the dashed FORM survives, static (spec §3.2)")
        #expect(ring.test_form == .connecting)
    }

    @Test func connectingRingResumesBreathingWhenReduceMotionLifts() {
        let ring = HaloRingView()
        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(ring)
        ring.test_reduceMotionOverride = true
        ring.apply(.connecting)
        #expect(!(ring.test_isBreathing), "Reduce Motion on: static dashed ring")

        ring.test_reduceMotionOverride = false
        postDisplayOptionsChanged()
        #expect(ring.test_isBreathing, "lifting Reduce Motion resumes the pulse live")
    }

    @Test func displayOptionsChangeLeavesANonConnectingRingAlone() {
        let ring = HaloRingView()
        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(ring)
        ring.test_reduceMotionOverride = false
        ring.apply(.connected)
        postDisplayOptionsChanged()
        #expect(!(ring.test_isBreathing), "connected never breathes, before or after the toggle")
        #expect(!(ring.test_isDashed))
        #expect(ring.test_form == .connected)
    }

    @Test func armBloomCancelsWhenReduceMotionArrivesMidFlight() {
        let dot = RouteArmedDotView()
        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(dot)
        dot.test_reduceMotionOverride = false
        dot.apply(armed: false)           // settled dark (first apply — no bloom)
        dot.apply(armed: true)            // transition INTO armed, on screen
        #expect(dot.test_isBlooming, "motion allowed: the ember→gold bloom is in flight")

        dot.test_reduceMotionOverride = true
        postDisplayOptionsChanged()
        #expect(!(dot.test_isBlooming), "Reduce Motion strips the in-flight bloom immediately")
        #expect(dot.test_isLit, "the model layer was already settled — still lit gold")
    }

    @Test func noBloomFiresAtAllUnderReduceMotion() {
        let dot = RouteArmedDotView()
        let window = makeWindow()
        defer { window.close() }
        window.contentView?.addSubview(dot)
        dot.test_reduceMotionOverride = true
        dot.apply(armed: false)
        dot.apply(armed: true)
        #expect(!(dot.test_isBlooming), "Reduce Motion: the arm swap is instant, never animated")
        #expect(dot.test_isLit)
    }

    // MARK: 3 — Increase Contrast / Reduce Transparency paths

    @Test func warmCanvasRepaintsOnDisplayOptionsChange() {
        // Reduce Transparency doesn't change the effective appearance, so the
        // ONLY live path to the §D flatten branch is the workspace
        // notification → needsDisplay.
        // Window-free on purpose: posting this notification in-process also
        // wakes AppKit's own observers, whose window-display reaction can
        // clear the dirty flag again before the assertion runs. Windowless,
        // a layer-backed view's `needsDisplay` GETTER reads false even after
        // a set (verified empirically) — but the setter still marks the
        // BACKING LAYER dirty, and that layer flag is what actually schedules
        // the redraw, so it's the honest thing to assert here.
        let canvas = WarmCanvasView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        canvas.layoutSubtreeIfNeeded()
        canvas.layer?.displayIfNeeded()
        #expect(canvas.layer?.needsDisplay() == false, "settled before the toggle")

        postDisplayOptionsChanged()
        #expect(canvas.layer?.needsDisplay() == true, "a mid-session IC/RT toggle repaints the canvas")
    }

    @Test func flattenedCanvasIsTheFlatOpaqueBaseColor() {
        // §D: under Reduce Transparency / Increase Contrast the canvas is the
        // FLAT `canvas` color — one value top to bottom, no grain. The canvas
        // is flat in BOTH appearances now, so flattening is asserted by COLOUR
        // (the flat pixel IS `canvas`) rather than by the absence of a
        // gradient. Dark carries the check because it is the appearance whose
        // draw path still adds grain the flatten branch has to remove.
        let size = NSRect(x: 0, y: 0, width: 32, height: 32)
        let canvas = WarmCanvasView(frame: size)
        canvas.appearance = NSAppearance(named: .darkAqua)

        canvas.test_flattenOverride = true
        guard let flat = bitmap(of: canvas) else {
            Issue.record("no bitmap")
            return
        }
        let flatTop = flat.colorAt(x: 16, y: 1)?.usingColorSpace(.sRGB)
        let flatBottom = flat.colorAt(x: 16, y: 30)?.usingColorSpace(.sRGB)
        #expect(flatTop != nil)
        #expect(abs((flatTop?.redComponent ?? -1) - (flatBottom?.redComponent ?? 1)) <= 1.0 / 255, "flattened: one flat color top to bottom")
        #expect(abs((flatTop?.greenComponent ?? -1) - (flatBottom?.greenComponent ?? 1)) <= 1.0 / 255)
        #expect(abs((flatTop?.blueComponent ?? -1) - (flatBottom?.blueComponent ?? 1)) <= 1.0 / 255)

        var darkCanvas = Tokens.Color.canvas
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            darkCanvas = Tokens.Color.canvas.usingColorSpace(.sRGB) ?? darkCanvas
        }
        #expect(abs((flatTop?.redComponent ?? -1) - darkCanvas.redComponent) <= 1.0 / 255,
                "the flat pixel is Tokens.Color.canvas itself")
        #expect(abs((flatTop?.greenComponent ?? -1) - darkCanvas.greenComponent) <= 1.0 / 255)
        #expect(abs((flatTop?.blueComponent ?? -1) - darkCanvas.blueComponent) <= 1.0 / 255)
    }

    @Test func ringRestampsItsTokenColorOnDisplayOptionsChange() {
        // The handler re-resolves `ringConnected`/`failure` (whose Increase-
        // Contrast variants read the LIVE workspace flag). Headless, the flag
        // can't flip — assert the re-stamp path runs and lands back on the
        // correctly-resolved token, i.e. the notification never corrupts state.
        let ring = HaloRingView()
        ring.apply(.failed(.init(cause: .notResponding)))
        postDisplayOptionsChanged()
        #expect(ring.test_form == .failed)
        guard let stroke = ring.test_strokeColor?.usingColorSpace(.sRGB),
              let failure = Tokens.Color.failure.usingColorSpace(.sRGB) else {
            Issue.record("colors did not resolve")
            return
        }
        #expect(abs(stroke.redComponent - failure.redComponent) <= 0.01)
        #expect(abs(stroke.greenComponent - failure.greenComponent) <= 0.01)
        #expect(abs(stroke.blueComponent - failure.blueComponent) <= 0.01)
    }

    @Test func meterGradientSurvivesDisplayOptionsChange() {
        // Same shape for the meter: the notification re-stamps the warm ramp
        // (ember → gold) — two stops, and never failure red
        // (house rule 8), before and after.
        let meter = LevelMeterView()
        postDisplayOptionsChanged()
        let colors = meter.test_gradientColors
        #expect(colors.count == 2, "the warm ramp survives the re-stamp intact")
        guard let failure = Tokens.Color.failure.usingColorSpace(.sRGB) else {
            Issue.record("failure token did not resolve")
            return
        }
        for color in colors {
            guard let c = color.usingColorSpace(.sRGB) else { continue }
            let distance = abs(c.redComponent - failure.redComponent)
                + abs(c.greenComponent - failure.greenComponent)
                + abs(c.blueComponent - failure.blueComponent)
            #expect(distance > 0.1, "no re-stamped meter stop may be the failure red")
        }
    }

    // MARK: Helpers

    /// Renders `view` into an offscreen bitmap via the deterministic
    /// `cacheDisplay` path (the same path the snapshot harness uses).
    private func bitmap(of view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
