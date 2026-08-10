// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SwiftUI
import AudiouterProtocol

/// One speaker, drawn as its own fader (doc:84-105, doc:1823-1866): tapping
/// the row arms or disarms it, dragging horizontally sets its volume, and the
/// gold wash behind the content IS the level. Per-device mute lives in the
/// Main Out drawer (``SpeakersView``), which is what the `MUTED` sub-label
/// below points at.
///
/// Volume policy: while dragging, the wash and the readout track `localVolume`
/// (set on every tick) rather than `device.volume` from the snapshot, because
/// device-volume effects come back through the ~50ms coalescer and would
/// otherwise fight the user's finger. `localVolume` clears on release, so the
/// row reconciles from the next snapshot — and rubber-bands to the pre-release
/// value for that one beat, which ``MainOutRow`` deliberately does not.
///
/// The drag is enabled by the same rule the Mac's own row uses (see
/// ``isControllable``); arming is enabled by the Mac's separate, weaker
/// checkbox rule (availability alone). `isAvailable == false` means the device
/// is gone from the network entirely (distinct from `connection.state`, which
/// can be "failed"/"off" while still `isAvailable`) — dimmed AND inert, since
/// there's nothing on the other end to apply anything to. A row the rule can't
/// adjust says WHY when VoiceOver reads it, on the row's own hint (see
/// ``disabledReason(for:controllable:)``).
struct DeviceRowView: View {
    let device: DeviceState
    let session: any MacSessionProtocol

    /// Which way the finger committed. SwiftUI has no equivalent of the
    /// design's CSS `touch-action: pan-y` (doc:79), and a plain drag gesture
    /// on a row inside a `ScrollView` wins arbitration outright and kills
    /// vertical scrolling. Latching to one axis after 5 pt of slop, and
    /// leaving vertical inert, gives the scroll view its pan back.
    private enum DragAxis { case horizontal, vertical }

    @State private var axis: DragAxis?        // nil until the gesture commits
    @State private var dragStartVolume: Int?  // captured at commit — doc:1755-1765
    @State private var localVolume: Double?   // in-drag echo
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// D9's failure card takes the whole control slot: a `"failed"` device
    /// gets headline / details / Try Again INSTEAD of volume + mute. This is
    /// where the phone's row deliberately parts from the Mac's, which keeps a
    /// failed row's controls and only desaturates them.
    static func showsFailureCard(_ device: DeviceState) -> Bool {
        device.connection.state == "failed"
    }

    /// The Mac's rule for the volume slider and the mute button, mirrored
    /// exactly (AudiouterSharedUI/DeviceRowView: `device.isAvailable &&
    /// controllable`, where `PopoverController` passes `controllable` =
    /// `isSpeakerSelected(id) || isRedirectTarget(id)`, and a redirect target
    /// is any app route pointed at this device).
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
        return device.isSelected || appRoutes.contains {
            $0.destinationKind == "device" && $0.deviceID == device.id
        }
    }

    /// Why volume and mute are disabled, or `nil` while they're live. The Mac
    /// composes this reason into its row's own label (the membership clause in
    /// `AudiouterSharedUI/DeviceRowView.configureAccessibility`); the phone has
    /// no row-level label — each control is its own element — so the clause
    /// rides on the two controls the rule disables instead. Worded in the
    /// phone's own vocabulary ("Select", "Main Out" — what its visible
    /// controls say), and spoken exactly once, never duplicated onto a hint.
    static func disabledReason(for device: DeviceState, controllable: Bool) -> String? {
        if controllable { return nil }
        return device.isAvailable ? "not selected for Main Out" : "unavailable"
    }

    /// What the row SHOWS as its armed state: the tap the finger just made,
    /// until the Mac confirms it or the echo times out; the Mac's own answer
    /// whenever no tap is in flight. Same shape as
    /// ``MainOutRow/thumbValue(local:server:)``, for the same reason.
    static func selectionEcho(pending: Bool?, server: Bool) -> Bool {
        pending ?? server
    }

    /// What VoiceOver reads as the row's value. Armed state first, then the two
    /// states the row otherwise carries in colour alone — the `MUTED` sub-label
    /// and ``routedDot``, an 11 pt disc on a hidden halo. Comma-separated:
    /// the row is one element, so it gets one value.
    ///
    /// `isSelected` is passed rather than read off `device`, because the row
    /// may be showing a tap the Mac hasn't answered yet
    /// (``selectionEcho(pending:server:)``) — and what the screen shows and
    /// what VoiceOver says have to be the same thing.
    static func spokenValue(for device: DeviceState, isSelected: Bool, isRouted: Bool) -> String {
        var parts = [isSelected ? "Armed" : "Not armed"]
        if device.isMuted { parts.append("Muted") }
        if isRouted { parts.append("App audio routed here") }
        return parts.joined(separator: ", ")
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

    /// The armed state the row draws and speaks — the Mac's, or the tap that
    /// is still on its way there.
    private var selected: Bool {
        Self.selectionEcho(pending: pendingSelection, server: device.isSelected)
    }

    /// doc:1828 — armed, present, and nothing in the way.
    private var isLive: Bool {
        selected && device.isAvailable && !isFailed && !isConnecting
    }

    /// doc:1826 — the row only reads as "dragging" once the finger has
    /// committed horizontally.
    private var dragging: Bool { axis == .horizontal }

    /// Touch-down, before the gesture has decided what it is. It ends the
    /// moment the finger commits — a horizontal drag has its own tint, and a
    /// vertical one belongs to the ScrollView, not to this row. Never on a
    /// row a tap can't act on: a flash is a promise.
    private var pressed: Bool { fingerDown && axis == nil && device.isAvailable }

    private var displayVolume: Int { Int((localVolume ?? Double(device.volume)).rounded()) }

    /// doc:1852 — an unarmed row shows no level at all, so the wash is the
    /// arming signal as much as the volume one.
    private var volumeFraction: CGFloat { isLive ? CGFloat(displayVolume) / 100 : 0 }

    private var isRouted: Bool {
        session.snapshot?.appRoutes.contains {
            $0.destinationKind == "device" && $0.deviceID == device.id
        } == true
    }

    // MARK: - Body

    @ViewBuilder
    var body: some View {
        if isFailed {
            // A failed row keeps its children as ordinary elements: collapsing
            // it would swallow Diagnose and Try Again, and it has no volume to
            // adjust anyway.
            content
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(device.name)
                .accessibilityValue(Self.spokenValue(for: device, isSelected: selected, isRouted: isRouted))
                .accessibilityHint(hint)
                .accessibilityAction { toggleSelected() }
                .accessibilityAdjustableAction { direction in
                    guard controlsEnabled else { return }
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
        .opacity(device.isAvailable ? 1 : 0.45)
        // The bound on the echo: any snapshot that moves this device's armed
        // state ends it, whichever way it moved.
        .onChange(of: device.isSelected) { pendingSelection = nil }
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
        HStack(spacing: 12) {
            halo

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
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(alignment: .leading) { wash }
        .overlay(alignment: .leading) { edgeLine }
        .background(touchTint)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
        .clipShape(RoundedRectangle(cornerRadius: WarmSignal.Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .simultaneousGesture(dragGesture)
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

    /// doc:1853 — the level, drawn as light rather than as a control.
    @ViewBuilder
    private var wash: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [WarmSignal.gold.opacity(dragging ? 0.30 : 0.14),
                         WarmSignal.gold.opacity(dragging ? 0.17 : 0.06)],
                startPoint: .leading,
                endPoint: .trailing))
            .frame(width: max(0, volumeFraction * rowWidth))
    }

    /// doc:1854-1856 — the bright leading edge of the wash, only where there
    /// is a level to show.
    @ViewBuilder
    private var edgeLine: some View {
        if isLive {
            Rectangle()
                .fill(WarmSignal.gold)
                .frame(width: 2)
                .opacity(dragging ? 1 : 0.4)
                .offset(x: max(0, volumeFraction * rowWidth - 1))
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
        } else if isConnecting {
            Circle().strokeBorder(WarmSignal.ring, style: StrokeStyle(lineWidth: 2.5, dash: [4, 3]))
        } else if isLive {
            Circle().strokeBorder(WarmSignal.ring, lineWidth: 2.5)
        }
    }

    /// doc:92, doc:1849-1850 — lit when an app route points here. The gold fill
    /// against the unlit `socket` colour IS the signal; the document's glow was
    /// a zero-offset coloured halo, which is decoration rather than depth.
    private var routedDot: some View {
        Circle()
            .fill(isRouted ? WarmSignal.gold : WarmSignal.socket)
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(WarmSignal.canvas, lineWidth: 1.5))
            .offset(x: 1, y: 1)
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
            // A number with no wash behind it is a quantity of nothing, so the
            // readout follows the same rule `volumeFraction` does (doc:1852):
            // both appear together, or neither does.
            Text(String(displayVolume))
                .readout(dragging ? 22 : 13)
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
    private var subLabel: String {
        if isFailed { return device.connection.failureHeadline ?? "CONNECTION FAILED" }
        if !device.isAvailable { return "UNAVAILABLE" }
        if isConnecting { return "CONNECTING…" }
        if device.isMuted { return "MUTED" }
        // One word for the state everywhere it appears: the section this row
        // sits in, the deck's count and the drawer all say PLAYING too. READY
        // rather than IDLE for its opposite — the speaker is fine, it just
        // isn't getting the Mac's sound.
        if selected { return "PLAYING" }
        return "READY"
    }

    private var subTint: Color {
        if isFailed { return WarmSignal.fail }
        if !device.isAvailable { return WarmSignal.label3 }
        if isConnecting { return WarmSignal.ring }
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
    /// sighted user is horizontal (``dragGesture``), so any wording here is
    /// either a duplicate or a lie to one of the two audiences.
    private var hint: String {
        let base = "Double tap to \(selected ? "disarm" : "arm")."
        guard controlsEnabled else {
            return [base, Self.disabledReason(for: device, controllable: false)]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return base
    }

    // MARK: - Gesture

    /// doc:1730-1794. `.simultaneousGesture` plus the axis latch, so the
    /// enclosing `ScrollView` keeps its own pan and this row only takes over
    /// once the finger has committed horizontally.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Touch-down. `minimumDistance: 0` means this first tick
                // arrives with no translation at all, which is exactly the
                // moment the pressed state is for — and taking it from the
                // gesture that is already here leaves the arbitration with
                // the ScrollView untouched. Assigned once rather than on
                // every tick: `@State` invalidates on assignment, not on
                // change, and the ticks keep coming for the whole scroll.
                if !fingerDown { fingerDown = true }
                let w = value.translation.width, h = value.translation.height
                if axis == nil {
                    // 5 pt slop (doc:1739, doc:1773), then commit to one axis for
                    // the rest of the gesture. Vertical commits are inert so the
                    // enclosing ScrollView keeps the pan.
                    guard max(abs(w), abs(h)) >= 5 else { return }
                    axis = abs(w) > abs(h) ? .horizontal : .vertical
                    if axis == .horizontal { dragStartVolume = device.volume }
                }
                guard axis == .horizontal, controlsEnabled, let start = dragStartVolume else { return }
                let v = WarmSignal.faderValue(start: start, translationWidth: w, trackWidth: rowWidth)
                localVolume = Double(v)
                session.setDeviceVolume(id: device.id, volume: v, isFinal: false)
            }
            .onEnded { _ in
                defer { axis = nil; dragStartVolume = nil; fingerDown = false }
                switch axis {
                case .horizontal:
                    guard controlsEnabled else { return }
                    session.setDeviceVolume(id: device.id,
                                            volume: Int((localVolume ?? Double(device.volume)).rounded()),
                                            isFinal: true)
                    localVolume = nil                    // clear on release, unlike MainOutRow
                    SpeakerCoach.learned(.drag)          // a drag that actually set a level
                case .vertical:
                    return                               // the ScrollView handled it
                case nil:
                    guard device.isAvailable else { return }
                    toggleSelected()                     // doc:1792
                }
            }
    }

    /// The one place a tap arms or disarms — the touch path and VoiceOver's
    /// action both come through here, so the echo, the write and the coach's
    /// memory can never disagree about what a tap did.
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
