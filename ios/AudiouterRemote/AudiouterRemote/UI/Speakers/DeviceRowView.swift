// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SwiftUI
import AudiouterProtocol

/// One speaker, drawn as its own fader (doc:84-105, doc:1823-1866): tapping
/// the row starts or stops it, dragging horizontally sets its volume, and the
/// level reads as a gold arc around the speaker's own halo (``LevelDial``),
/// over a flat gold wash that says only that the row is live. Put a finger on
/// it and the row admits what it is: the row tints its own remainder, so the
/// whole row becomes a partial fill, and the tint goes again on release — the
/// instrument is the row itself, never a second object. A playing row also
/// carries its own mute button (``muteControl``) — a departure from the
/// design document, which moved mute to a Main Out drawer:
/// sound is live in another room while this screen is used, and the one
/// control that stops it may not be behind a chevron a first-timer has no
/// reason to open. The row is the only place it lives.
///
/// Volume policy: while dragging, the wash and the readout track `localVolume`
/// (set on every tick) rather than `device.volume` from the snapshot, because
/// device-volume effects come back through the ~50ms coalescer and would
/// otherwise fight the user's finger. `localVolume` clears on release, so the
/// row reconciles from the next snapshot — and rubber-bands to the pre-release
/// value for that one beat, which ``MainOutRow`` deliberately does not.
///
/// The drag is enabled for a speaker that is sounding or is an app's redirect
/// target (see ``isControllable``); the tap starts and stops one, except while
/// Main Out is pointed at a group and the membership is what plays (see
/// ``playRefusal(mainOut:)``). `isAvailable == false` means the
/// device is gone from the network entirely (distinct from `connection.state`,
/// which can be "failed"/"off" while still `isAvailable`) — inert, and drawn
/// recessive by its own tints, with the opacity dim reaching the halo and
/// nothing else (see ``identityDim``). A row the rule can't adjust says WHY
/// when VoiceOver reads it, on the row's own hint (see
/// ``disabledReason(for:controllable:)``).
struct DeviceRowView: View {
    let device: DeviceState
    let session: any MacSessionProtocol

    /// doc:1826 — the row only reads as "dragging" once the finger has
    /// committed horizontally (``HorizontalDragGesture``).
    @State private var dragging = false
    @State private var dragStartVolume: Int?  // captured at commit — doc:1755-1765
    @State private var localVolume: Double?   // in-drag echo
    @State private var detents = WarmSignal.FaderDetents()  // the dial's clicks
    @State private var showFailureDetail = false
    @State private var rowWidth: CGFloat = 0  // the fader track
    @State private var fingerDown = false     // touch-down, before the latch

    /// The tap's own echo: what the row shows between the finger and the Mac's
    /// answer. Bounded exactly the way ``MainOutRow``'s `localVolume` is — the
    /// next snapshot that moves `isSelected` clears it, and if none ever comes
    /// (the Mac refused the write, and said so in a toast) the two-second
    /// timeout below clears it instead, so the row falls back to the truth
    /// rather than sitting on a state nobody granted.
    @State private var pendingSelection: Bool?

    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 16.5
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 17
    @ScaledMetric(relativeTo: .footnote) private var diagnoseSize: CGFloat = 12.5
    @ScaledMetric(relativeTo: .caption) private var muteIconSize: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// D9's failure card takes the whole control slot: a `"failed"` device
    /// gets headline / details / Try Again INSTEAD of volume + mute. This is
    /// where the phone's row deliberately parts from the Mac's, which keeps a
    /// failed row's controls and only desaturates them.
    static func showsFailureCard(_ device: DeviceState) -> Bool {
        device.connection.state == "failed"
    }

    /// Whether the Mac is sending sound to this speaker right now — the row's
    /// whole Playing/Ready notion, and the one thing `isSelected` cannot
    /// answer.
    ///
    /// Main Out points at EITHER the Selected Devices set or a saved group, and
    /// `DeviceState.isSelected` is only ever the first of those
    /// (`GroupController.isSpeakerSelected`, which reads `selectedDeviceIDs`
    /// alone). `isMainOutMember` is the Mac's own answer to "is this device in
    /// whatever Main Out currently points at" — identical to `isSelected` under
    /// a Selected Devices target, and the group's members under a group one. So
    /// it is the field, and `isSelected` is never read for this: an OR of the
    /// two would light up a speaker stranded in the dormant Selected set while
    /// an AirPlay group plays, which is the exact confusion
    /// `GroupController.isMainOutMember(_:)` documents.
    static func isSounding(_ device: DeviceState) -> Bool {
        device.isMainOutMember
    }

    /// Why a tap can neither start nor stop this speaker, or `nil` when it can.
    ///
    /// While Main Out points at a group, what plays IS the group's membership.
    /// The row's tap writes the Selected Devices set (`setDeviceSelected`),
    /// which the Mac holds dormant until Main Out points back at it — so the
    /// write would be accepted, change nothing audible, and leave the row
    /// echoing a state for two seconds before snapping back. The screen does
    /// not lie for two seconds; it says why instead.
    static func playRefusal(mainOut: MainOutState) -> String? {
        guard mainOut.kind == "group" else { return nil }
        return "A group is playing. Switch Main Out to Selected Speakers to start or stop one speaker."
    }

    /// Whether a bare tap on the row toggles play. A failure card's row must
    /// not: Diagnose and Try Again sit inside the same gesture subtree, so the
    /// tap that presses them ALSO lands here — and a `"failed"` device can
    /// still be `isAvailable`, so the old availability guard let a Diagnose
    /// press silently start or stop the speaker. VoiceOver already can't
    /// toggle a failed row (``combined(_:)`` gives it no action); this makes
    /// touch agree.
    static func tapTogglesPlay(_ device: DeviceState, mainOut: MainOutState) -> Bool {
        device.isAvailable && !showsFailureCard(device) && playRefusal(mainOut: mainOut) == nil
    }

    /// The Mac's rule for the volume slider and the mute button
    /// (AudiouterSharedUI/DeviceRowView: `device.isAvailable && controllable`,
    /// where `PopoverController` passes `controllable` =
    /// `isSpeakerSelected(id) || isRedirectTarget(id)`, and a redirect target
    /// is any app route pointed at this device) — with `isSpeakerSelected`
    /// replaced by ``isSounding(_:)``, which is the same answer under a
    /// Selected Devices target and the right one under a group.
    ///
    /// The rule is "you can set the level of a speaker you can hear". A group
    /// member is sounding, so its level is adjustable — the server takes the
    /// write (`CompanionCommandDispatcher.deviceWriteRefusal` gates on
    /// connection state alone, and `GroupController.setMemberVolume` is the
    /// same path the Mac's Groups window uses for a member). A device left in
    /// the dormant Selected set while a group plays is silent, so it isn't.
    /// The Mac's own popover row still keys off `isSpeakerSelected` and so
    /// greys a playing group member's slider — a Mac-side gap, not mirrored
    /// here on purpose.
    ///
    /// Connection state is deliberately absent, because it's absent from the
    /// Mac's rule too — there it only dims the controls. So an available but
    /// not-yet-connected device stays draggable and the server's refusal
    /// (`CompanionCommandDispatcher.deviceWriteRefusal`, which gates on
    /// connection state ALONE) surfaces as a toast (`ToastCenter`). A
    /// `"failed"` device is this side's exception: the row swaps both
    /// controls for the failure card (``showsFailureCard(_:)``), so the
    /// rule's answer for it never reaches a control at all.
    ///
    /// Two known gaps against the Mac, both judged harmless:
    /// - TRANSIENT: excluding an app filters its route off the wire
    ///   immediately (`CompanionSnapshotBuilder`), while the Mac's own row
    ///   keeps counting that route until the coordinating layer prunes it —
    ///   so for that beat the phone greys a slider the Mac still has live.
    ///   Self-corrects on the next snapshot.
    /// - BY DESIGN: this rule is STRICTER than the server's refusal gate. A
    ///   connected-but-unselected device's write would be ACCEPTED, so the
    ///   greyed control has no refusal behind it to toast. It follows the
    ///   Mac's row rather than the server's — and the row's own Select switch
    ///   sits directly above it, with the spoken reason below covering
    ///   VoiceOver, so the control is never dead-and-silent.
    static func isControllable(_ device: DeviceState, appRoutes: [AppRouteState]) -> Bool {
        guard device.isAvailable else { return false }
        return isSounding(device) || appRoutes.contains {
            $0.destinationKind == "device" && $0.deviceID == device.id
        }
    }

    /// Why volume and mute are disabled, or `nil` while they're live. The Mac
    /// composes this reason into its row's own label (the membership clause in
    /// `AudiouterSharedUI/DeviceRowView.configureAccessibility`); the phone has
    /// no row-level label — each control is its own element — so the clause
    /// rides on the row's hint instead, and on the toast a dead drag raises
    /// (``refuseAdjustment()``) — the same sentence to the finger. Worded in
    /// the one vocabulary the screen shows — Playing / Ready / Unavailable,
    /// never "armed" or "selected".
    static func disabledReason(for device: DeviceState, controllable: Bool) -> String? {
        if controllable { return nil }
        return device.isAvailable
            ? "Its level can be set once it's playing."
            : "This speaker isn't on the network."
    }

    /// What the row SHOWS as its playing state: the tap the finger just made,
    /// until the Mac confirms it or the echo times out; the Mac's own answer
    /// whenever no tap is in flight. Same shape as
    /// ``MainOutRow/thumbValue(local:server:)``, for the same reason.
    static func selectionEcho(pending: Bool?, server: Bool) -> Bool {
        pending ?? server
    }

    /// What VoiceOver reads as the row's value. Playing state first — spoken
    /// as the same word the row's own sub-label shows, in the same branch
    /// order (``subLabel``) — and a speaker that
    /// is still connecting says so at all. Then the two states the row
    /// otherwise carries in colour alone: the `Muted` sub-label and
    /// ``routedDot``, an 11 pt disc on a hidden halo. Comma-separated: the row
    /// is one element, so it gets one value.
    ///
    /// The one place it says MORE than the sub-label does: mute and the route
    /// are appended rather than substituted, because a value has room for
    /// three clauses and a 40 pt strip of text does not.
    ///
    /// `isSelected` is passed rather than read off `device`, because the row
    /// may be showing a tap the Mac hasn't answered yet
    /// (``selectionEcho(pending:server:)``) — and what the screen shows and
    /// what VoiceOver says have to be the same thing.
    static func spokenValue(for device: DeviceState, isSelected: Bool, isRouted: Bool) -> String {
        var parts = [playingWord(for: device, isSelected: isSelected)]
        if device.isMuted { parts.append("Muted") }
        if isRouted { parts.append("App audio routed here") }
        return parts.joined(separator: ", ")
    }

    private static func playingWord(for device: DeviceState, isSelected: Bool) -> String {
        if !device.isAvailable { return "Unavailable" }
        if device.connection.state == "connecting" { return "Connecting" }
        // A link that dropped and is coming back is not the same news as one
        // that never came up, and it is specifically not Playing: the room is
        // silent while this lasts, so the word cannot say otherwise.
        if device.connection.state == "reconnecting" { return "Reconnecting" }
        return isSelected ? "Playing" : "Ready"
    }

    // MARK: - Derived state

    /// This row's answer to that rule. No snapshot yet means no known routes,
    /// so the redirect half is false — never assume controllable, that would
    /// be inventing state.
    private var controlsEnabled: Bool {
        Self.isControllable(device, appRoutes: session.snapshot?.appRoutes ?? [])
    }

    private var isFailed: Bool { Self.showsFailureCard(device) }

    private var isConnecting: Bool { device.connection.state == "connecting" }

    private var isReconnecting: Bool { device.connection.state == "reconnecting" }

    /// The link isn't up yet, whether this is the first attempt or a recovery.
    /// The two share everything the row draws — the dashed ring, the sub-label
    /// tint, and being kept out of Playing — and differ only in the word.
    private var isPending: Bool { isConnecting || isReconnecting }

    /// The playing state the row draws and speaks — the Mac's, or the tap that
    /// is still on its way there.
    private var selected: Bool {
        Self.selectionEcho(pending: pendingSelection, server: Self.isSounding(device))
    }

    /// Where Main Out is pointed, for the one rule that needs it
    /// (``playRefusal(mainOut:)``). No snapshot yet means no group can be the
    /// target, which is also the state in which nothing is playing.
    private var mainOut: MainOutState {
        session.snapshot?.mainOut ?? MainOutState(kind: "selected")
    }

    /// doc:1828 — playing, present, and nothing in the way.
    private var isLive: Bool {
        selected && device.isAvailable && !isFailed && !isPending
    }

    /// Touch-down, before the gesture has decided what it is. It ends the
    /// moment the finger commits — a horizontal drag has its own tint, and a
    /// vertical one belongs to the ScrollView, not to this row. Never on a
    /// row a tap can't act on: a flash is a promise.
    private var pressed: Bool { fingerDown && !dragging && device.isAvailable }

    /// The unavailable row's dim, and the one thing it may touch: the halo.
    ///
    /// Nothing interactive, ever. A `failed` device can also be unavailable,
    /// and then the failure card's Diagnose and Try Again are the row's only
    /// live controls — 0.45 puts Diagnose at 1.88:1, and a control you can
    /// press has to be a control you can read.
    ///
    /// No text either. `nameTint`, `glyphTint` and `subTint` all already
    /// answer unavailability by dropping to `WarmSignal.label3`, which is the
    /// dim; multiplying 0.45 on top of it lands the name and `Unavailable` at
    /// 1.98:1 against 6.09:1 for the tint alone. That leaves the halo, which
    /// is a graphic, carries no text, and is the strongest of the three
    /// signals anyway.
    private var identityDim: Double { device.isAvailable ? 1 : 0.45 }

    private var displayVolume: Int { Int((localVolume ?? Double(device.volume)).rounded()) }

    /// The rail the finger is currently pinned against, for the boundary tick.
    private var rail: Int? { WarmSignal.faderRail(displayVolume, dragging: dragging) }

    /// doc:1852 — a row that isn't playing shows no level at all, so the wash
    /// is the playing signal as much as the volume one.
    private var volumeFraction: CGFloat { isLive ? CGFloat(displayVolume) / 100 : 0 }

    private var isRouted: Bool {
        session.snapshot?.appRoutes.contains {
            $0.destinationKind == "device" && $0.deviceID == device.id
        } == true
    }

    // MARK: - Body

    var body: some View {
        content
    }

    /// The row as one VoiceOver element — everything except the mute button,
    /// which is a control of its own and stays reachable as the row's sibling
    /// (see ``muteControl``).
    ///
    /// A failed row is the exception and gets nothing: collapsing it would
    /// swallow Diagnose and Try Again, and it has no volume to adjust anyway.
    @ViewBuilder
    private func combined(_ row: some View) -> some View {
        if isFailed {
            row
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(device.name)
                .accessibilityValue(Self.spokenValue(for: device, isSelected: selected, isRouted: isRouted))
                .accessibilityHint(hint)
                .accessibilityAction { tapped() }
                .accessibilityAdjustableAction { direction in
                    guard controlsEnabled else { return refuseAdjustment() }
                    session.setDeviceVolume(
                        id: device.id,
                        volume: min(100, max(0, device.volume + (direction == .increment ? 5 : -5))),
                        isFinal: true)
                }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            faderRow
            if isFailed { failureControls }
        }
        .padding(.bottom, 2)
        // The bound on the echo: any snapshot that moves this device's playing
        // state ends it, whichever way it moved. Watched on the same value the
        // row draws (``isSounding(_:)``), or activating a group would strand
        // every member's echo for the full two seconds.
        .onChange(of: Self.isSounding(device)) { pendingSelection = nil }
        // And the other bound, for the write that never lands: a refusal
        // changes nothing on the wire, so nothing above would ever fire.
        .task(id: pendingSelection) {
            guard pendingSelection != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            pendingSelection = nil
        }
    }

    // MARK: - The row itself

    private var faderRow: some View {
        combined(
            HStack(spacing: 12) {
                halo.opacity(identityDim)

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.system(size: nameSize, weight: selected ? .semibold : .regular))
                        .tracking(-0.2)
                        .lineLimit(1)
                        .foregroundStyle(nameTint)

                    Text(subLabel)
                        .microLabel()
                        .foregroundStyle(subTint)

                }

                Spacer(minLength: 8)

                trailingSlot

                // The room the mute button occupies. The button itself is an
                // overlay (see below), which reserves nothing, so the readout
                // would slide under it without this.
                if showsMute { Color.clear.frame(width: Self.muteSize, height: Self.muteSize) }
            }
            .padding(.horizontal, WarmSignal.rowGutter)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        )
        .background(alignment: .leading) { level }
        // EVERY TINT IS A BACKGROUND, and this one is the lowest layer of all.
        // A level is what the row's words sit ON; it never sits on them. As an
        // `.overlay` this band lies across the halo and the first letters of
        // the name for the whole drag — the row's own content, washed out by
        // the thing that is only describing it.
        .background { instrument }
        .background(touchTint)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
        // The reveal, and its whole implementation: the instrument arrives
        // over 0.18s and leaves over 0.14s — out faster than in, so the
        // arrival is the authored half and the dismissal gets out of the way.
        // Under Reduce Motion the track edge is simply there or not, which is
        // the same information without the movement.
        .animation(reduceMotion ? nil : .easeOut(duration: dragging ? 0.18 : 0.14), value: dragging)
        .clipShape(RoundedRectangle(cornerRadius: WarmSignal.Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .gesture(HorizontalDragGesture { handle($0) })
        // The tap's tick, fired off the local echo so it lands with the finger
        // rather than a round trip later — and only on the echo being SET,
        // never on the snapshot clearing it. Then the rails, so the end of the
        // travel is felt rather than looked for.
        .sensoryFeedback(trigger: pendingSelection) { _, new in new == nil ? nil : .selection }
        .sensoryFeedback(trigger: rail) { _, new in new == nil ? nil : .impact(weight: .light) }
        // And the dial's detents (``WarmSignal/FaderDetents``): the same family
        // as the rail's tick and deliberately a fraction of its strength.
        // Passing a notch and running out of track are both news, but they are
        // not the same news, so they cannot be the same click.
        .sensoryFeedback(.impact(weight: .light, intensity: WarmSignal.FaderDetents.intensity),
                         trigger: detents.ticks)
        // Mute is confirmed rather than optimistic, exactly as Main Out's is,
        // so the tick rides the Mac's answer.
        .sensoryFeedback(.impact(weight: .light), trigger: device.isMuted)
        // An OVERLAY, and applied after the gesture on purpose: a `Button`
        // inside `faderRow` would sit in the drag recognizer's own view
        // subtree, which means both fire — every mute tap would also stop the
        // speaker. Out here the button is not in that subtree, so it takes its
        // own taps and nothing else sees them. It is also outside ``combined``,
        // which is what keeps it reachable as its own VoiceOver element.
        .overlay(alignment: .trailing) { muteControl }
    }

    /// The whole vertical budget: 12 pt of air, the 44 pt halo, and 12 pt of
    /// air under it.
    private static let rowHeight: CGFloat = 68

    /// Only on a row that is actually making sound: a mute button on a silent
    /// speaker is a control with nothing to stop.
    private var showsMute: Bool { isLive }

    /// What the button paints; the ``hittable(drawn:)`` floor is 44 either way.
    private static let muteSize: CGFloat = 28

    /// Mute, on the row that is making the sound: same well, same rim and the
    /// same glyph pair the deck's Main Out mute uses, so the gesture that
    /// silences one speaker and the one that silences everything are visibly
    /// the same control at two scopes.
    @ViewBuilder
    private var muteControl: some View {
        if showsMute {
            Button {
                session.setDeviceMuted(id: device.id, muted: !device.isMuted)
            } label: {
                Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: muteIconSize))
                    .foregroundStyle(device.isMuted ? WarmSignal.gold : WarmSignal.label2)
                    .frame(width: Self.muteSize, height: Self.muteSize)
                    .background(RoundedRectangle(cornerRadius: WarmSignal.Radius.control, style: .continuous)
                        .fill(WarmSignal.well))
                    .overlay(RoundedRectangle(cornerRadius: WarmSignal.Radius.control, style: .continuous)
                        .strokeBorder(WarmSignal.rim, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .hittable(drawn: Self.muteSize)
            .padding(.trailing, 12)
            .accessibilityLabel(device.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")
        }
    }

    /// doc:1851's drag tint, and under it the touch-down flash that answers
    /// the finger before anything else can: the arm write round-trips to the
    /// Mac, and the drag needs 5 pt before it means anything, so without this
    /// the row's first response to being touched is nothing at all. Same gold
    /// as the wash it is about to raise — the acknowledgment and the result
    /// are one material.
    private var touchTint: Color {
        if dragging { return WarmSignal.gold.opacity(0.06) }
        return pressed ? WarmSignal.gold.opacity(0.10) : .clear
    }

    /// doc:1853's wash, and the one job it has left: this row is live. The
    /// value itself is ``LevelDial``'s arc, so the wash is flat and has no
    /// edge anywhere in the row that could be read as a level.
    ///
    /// 0.05 is a text budget, not a taste: the row's words sit ON this, and a
    /// playing row's gold `Playing` sub-label measures 4.72:1 here — over the
    /// 4.5:1 floor. The design document's 0.14 puts it at 4.36–4.46:1.
    @ViewBuilder
    private var level: some View {
        if isLive {
            Rectangle().fill(WarmSignal.gold.opacity(0.05))
        }
    }

    /// The instrument, and only under a finger: the row tints the part of
    /// itself the value has NOT reached, which turns the whole row into a
    /// partial fill of a visible container — the denominator the dial's arc
    /// gives at the halo, restated at the scale the finger is working at.
    /// Nothing NEW appears; the row's own width simply divides in two.
    ///
    /// Never on a row that isn't playing: its drag is refused
    /// (``refuseAdjustment()``), and a track is an invitation to a gesture
    /// this row declines.
    @ViewBuilder
    private var instrument: some View {
        if isLive && dragging {
            // The remainder, tinted inside the shape the row already has, so
            // the row reads as a partial fill of a visible whole. `pill` is
            // the one token that separates from the untinted side by the same
            // amount in both grounds (1.35:1); it is context rather than the
            // level itself, which the dial and the readout carry.
            HStack(spacing: 0) {
                Color.clear.frame(width: max(0, volumeFraction * rowWidth))
                WarmSignal.pill.opacity(0.5)
            }
            .transition(.opacity)
        }
    }

    private var halo: some View {
        ZStack {
            Circle().fill(WarmSignal.raised)
            ring
            Image(systemName: device.iconSymbolName)
                .font(.system(size: glyphSize))
                .foregroundStyle(glyphTint)
        }
        .frame(width: 44, height: 44)
        .overlay(alignment: .bottomTrailing) { routedDot }
        .accessibilityHidden(true)
    }

    /// doc:1829-1832.
    @ViewBuilder
    private var ring: some View {
        if isFailed {
            Circle().strokeBorder(WarmSignal.fail, lineWidth: 2.8)
        } else if isPending {
            Circle().strokeBorder(WarmSignal.ring, style: StrokeStyle(lineWidth: 2.5, dash: [4, 3]))
        } else if isLive {
            LevelDial(fraction: volumeFraction, muted: device.isMuted, dragging: dragging)
        } else {
            // An idle halo is the one surface on this screen whose fill alone
            // used to hold it: `raised` over `canvas`. Neither ground separates
            // it now (1.00:1 light, 1.07:1 dark), so its own edge is the whole
            // boundary — which is exactly what `containerEdge` is the weight
            // for. 1.76:1 light / 1.43:1 dark against the fill it outlines, and
            // a 1 pt neutral resting rim the three state rings above overrule
            // by both colour and width.
            Circle().strokeBorder(WarmSignal.containerEdge, lineWidth: 1)
        }
    }

    /// doc:92, doc:1849-1850 — lit when an app route points here. The gold fill
    /// against the unlit `socket` colour IS the signal; the document's glow was
    /// a zero-offset coloured halo, which is decoration rather than depth.
    ///
    /// WHERE THIS SITS IS LOAD-BEARING: ``LevelDial`` cuts its knob gap around
    /// this dot, at the angle these numbers put it (``LevelDial/gapCenter``).
    /// Move the dot and the gap has to move with it, or the two gold shapes
    /// merge again.
    private var routedDot: some View {
        Circle()
            .fill(isRouted ? WarmSignal.gold : WarmSignal.socket)
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(WarmSignal.canvas, lineWidth: 1.5))
            // Pulled UP, not down: hanging the dot below the halo leaves
            // ``instrument`` about 1.5 pt of air under it, and at that
            // distance the dot and the strip read as touching.
            .offset(x: 1, y: -2)
    }

    /// doc:1861-1863, and the failure affordance that replaces the number.
    @ViewBuilder
    private var trailingSlot: some View {
        if isFailed {
            if device.connection.failureSuggestion != nil {
                Button("Diagnose") { showFailureDetail.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: diagnoseSize, weight: .semibold))
                    .foregroundStyle(WarmSignal.goldText)
                    .hittable(drawn: 20)
            }
        } else if isLive {
            // A number with no strip behind it is a quantity of nothing, so
            // the readout follows the same rule `volumeFraction` does
            // (doc:1852): both appear together, or neither does.
            //
            // 16 at rest: the size the deck states Main Out at
            // (`MainOutRow`), because this is the same kind of number and the
            // screen should say it one way.
            Text(String(displayVolume))
                .readout(dragging ? 22 : 16)
                .foregroundStyle(WarmSignal.goldText)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dragging)
        }
    }

    private var failureControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showFailureDetail, let suggestion = device.connection.failureSuggestion {
                Text(suggestion)
                    .font(.footnote)
                    .foregroundStyle(WarmSignal.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Try Again") {
                session.retryConnection(id: device.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .hittable(drawn: 28)
            .accessibilityHint("Retry connecting to \(device.name)")
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Text

    /// doc:1833-1837, plus the muted case at doc:1897. Order matters: the
    /// first true branch is what the row says.
    ///
    /// The failure branch is the one that is not a state word: it is the Mac's
    /// own sentence, and it keeps its own tint (see ``subTint``).
    private var subLabel: String {
        if isFailed { return device.connection.failureHeadline ?? "Connection failed" }
        if !device.isAvailable { return "Unavailable" }
        if isConnecting { return "Connecting…" }
        if isReconnecting { return "Reconnecting…" }
        if device.isMuted { return "Muted" }
        // One word for the state everywhere it appears: the section this row
        // sits in and the deck's count both say Playing too. Ready rather than
        // IDLE for its opposite — the speaker is fine, it just isn't getting
        // the Mac's sound.
        if selected { return "Playing" }
        return "Ready"
    }

    private var subTint: Color {
        // ONE thing on this card is red, and it is the ring. Red on the
        // headline too puts the alarm colour on the card's widest element, and
        // a failure card at the top of Ready then reads as the app being
        // broken rather than one speaker. `label2` is the row's ordinary
        // secondary ink — 5.07:1 on paper, 6.19:1 on the dark ground, and
        // brighter there than the `label3` a healthy Ready row's word takes.
        // The state stays legible; the alarm stays on the ring, next to the
        // two things that can act on it.
        if isFailed { return WarmSignal.label2 }
        if !device.isAvailable { return WarmSignal.label3 }
        if isPending { return WarmSignal.ring }
        if device.isMuted { return WarmSignal.label2 }
        if selected { return WarmSignal.goldText }
        return WarmSignal.label3
    }

    /// doc:1858.
    private var nameTint: Color {
        guard device.isAvailable else { return WarmSignal.label3 }
        return isLive ? WarmSignal.label : WarmSignal.label2
    }

    /// doc:1848.
    private var glyphTint: Color {
        guard device.isAvailable else { return WarmSignal.label3 }
        return isLive ? WarmSignal.label : WarmSignal.label2
    }

    /// A row the rule won't let you adjust must say why — so the reason rides
    /// on the hint. The volume gesture does NOT: VoiceOver announces an
    /// adjustable element's own swipe, and the touch path this row offers a
    /// sighted user is horizontal (``HorizontalDragGesture``), so any wording
    /// here is either a duplicate or a lie to one of the two audiences.
    private var hint: String {
        // A hint that promises an action the tap will refuse is worse than no
        // hint, so under a group target it carries the reason instead.
        let base = Self.playRefusal(mainOut: mainOut)
            ?? "Double tap to \(selected ? "stop" : "play")."
        guard controlsEnabled else {
            return [base, Self.disabledReason(for: device, controllable: false)]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return base
    }

    // MARK: - Gesture

    /// One phase of ``HorizontalDragGesture``: the row's whole touch path.
    /// The gesture has already decided that a vertical pan belongs to the
    /// enclosing `ScrollView` — anything arriving here is either the fader,
    /// the tap, or the finger going away again.
    private func handle(_ phase: HorizontalDragGesture.Phase) {
        switch phase {
        case .down:
            // The pressed flash, before anything else can answer: the arm
            // write round-trips to the Mac and the drag needs 5 pt before it
            // means anything, so without this the row's first response to
            // being touched is nothing at all.
            fingerDown = true

        case .began(let width):
            dragging = true
            dragStartVolume = device.volume
            detents.begin(at: device.volume)
            // The coach promised this gesture, so a row that can't answer it
            // has to say why rather than swallow it. At the latch, which is
            // the moment the drag became a volume drag — once per gesture,
            // and before the finger has travelled far enough to expect a
            // number to move.
            if !controlsEnabled { refuseAdjustment() }
            track(width)

        case .changed(let width):
            track(width)

        case .ended:
            defer { reset() }
            guard controlsEnabled else { return }
            session.setDeviceVolume(id: device.id,
                                    volume: Int((localVolume ?? Double(device.volume)).rounded()),
                                    isFinal: true)
            localVolume = nil                    // clear on release, unlike MainOutRow
            SpeakerCoach.learned(.drag)          // a drag that actually set a level

        case .tapped:
            reset()
            tapped()                             // doc:1792

        case .cancelled:
            // The ScrollView has it now — or the system took the touch
            // mid-drag, in which case the echo is a level nobody confirmed.
            localVolume = nil
            reset()
        }
    }

    /// One tick of the fader — doc:1755-1765.
    private func track(_ width: CGFloat) {
        guard controlsEnabled, let start = dragStartVolume else { return }
        let v = WarmSignal.faderValue(start: start, translationWidth: width, trackWidth: rowWidth)
        localVolume = Double(v)
        detents.advance(to: v)
        session.setDeviceVolume(id: device.id, volume: v, isFinal: false)
    }

    private func reset() {
        dragging = false
        dragStartVolume = nil
        fingerDown = false
    }

    /// What the row says when the level gesture lands somewhere it can't act.
    /// The same sentence the disabled control already speaks
    /// (``disabledReason(for:controllable:)``), through the same channel the
    /// Mac's own refusals come back on (``ToastCenter``) — so a refused write
    /// and a write that never left look and sound alike, which is what they
    /// are from the finger's side.
    private func refuseAdjustment() {
        guard let reason = Self.disabledReason(for: device, controllable: false) else { return }
        session.toasts.show(.refusal(reason: reason))
    }

    /// The row's tap, from either audience: it starts or stops the speaker, or
    /// says why it can't (``playRefusal(mainOut:)``) on the same channel a
    /// dead drag answers on. A row with neither — a failure card, or one off
    /// the network — swallows the tap: the card's own buttons are what that
    /// row is for, and an absent speaker has nothing to say back.
    private func tapped() {
        guard Self.tapTogglesPlay(device, mainOut: mainOut) else {
            if let refusal = Self.playRefusal(mainOut: mainOut) {
                session.toasts.show(.refusal(reason: refusal))
            }
            return
        }
        toggleSelected()
    }

    /// The one place a tap starts or stops a speaker — the touch path and
    /// VoiceOver's action both come through here, so the echo, the write and
    /// the coach's memory can never disagree about what a tap did.
    private func toggleSelected() {
        let next = !selected
        pendingSelection = next
        session.setDeviceSelected(id: device.id, selected: next)
        SpeakerCoach.learned(.tap)
    }
}

// MARK: - The one-time gesture coach

/// What the phone knows about whether its two invisible gestures have been
/// found yet. Both of the screen's core interactions — tap a row to play it,
/// drag across it to set its level — are unlabelled by design (the row IS the
/// fader), so the screen owes a first-timer one line of coaching and owes a
/// returning user silence.
///
/// The two flags are UI preference, not routing state, so `@AppStorage` is
/// allowed here (Model/MacSessionProtocol.swift:21-23 covers the latter). They
/// are written from the row that performs the gesture and read by
/// ``SpeakersView``'s console, which is why they live in neither.
enum SpeakerCoach {
    /// One of the two gestures the coach line teaches.
    enum Gesture: String {
        case tap = "speakers.coach.learnedTap"
        case drag = "speakers.coach.learnedDrag"
    }

    /// The coach's whole rule: it goes away for good once the user has done
    /// both things it describes — one of them is no evidence for the other.
    static func isVisible(learnedTap: Bool, learnedDrag: Bool) -> Bool {
        !(learnedTap && learnedDrag)
    }

    static func learned(_ gesture: Gesture, in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: gesture.rawValue)
    }

    /// The explicit dismiss: whoever taps it is telling us they know both.
    static func dismiss(in defaults: UserDefaults = .standard) {
        learned(.tap, in: defaults)
        learned(.drag, in: defaults)
    }
}

#Preview("Healthy") {
    let demo = DemoMacSession()
    return ScrollView {
        LazyVStack(spacing: 0) {
            ForEach(demo.snapshot!.devices, id: \.id) { device in
                DeviceRowView(device: device, session: demo)
            }
        }
        .padding(.horizontal, 14)
    }
    .background(WarmSignal.canvasGradient)
}

#Preview("Failed device") {
    let failed = DeviceState(
        id: "demo-office", name: "Office Speaker", kind: "generic",
        iconSymbolName: "hifispeaker.fill", isAvailable: false, supportsAirPlay2: true,
        isLocalDevice: false, volume: 50, isMuted: false, isSelected: false, isMainOutMember: false,
        connection: DeviceState.ConnectionInfo(
            state: "failed",
            failureHeadline: "Not on the network",
            failureSuggestion: "The speaker is no longer visible on the network. Check that it's powered on and on the same Wi-Fi, then try again."
        )
    )
    return DeviceRowView(device: failed, session: DemoMacSession())
        .padding(.horizontal, 14)
        .background(WarmSignal.canvasGradient)
}
