// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// Tab 1: which Mac is connected, every speaker as its own fader, and the
/// floating Main Out deck. This view owns no local state at all — every value
/// it renders comes straight from `session.snapshot`. The in-drag echoes live
/// one level down, in ``MainOutRow`` and ``DeviceRowView``, and the screen's
/// presentation state (which sections are collapsed) lives in
/// ``SpeakerConsole``, which only exists while a snapshot does — so each dies
/// with the list it belongs to.
struct SpeakersView: View {
    let session: any MacSessionProtocol

    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 26
    @ScaledMetric(relativeTo: .caption) private var pillTextSize: CGFloat = 12

    var body: some View {
        ZStack {
            WarmSignal.canvasGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                StatusBanners(snapshot: session.snapshot)

                if let snapshot = session.snapshot {
                    SpeakerConsole(snapshot: snapshot, session: session)
                } else {
                    Spacer()
                    ContentUnavailableView(
                        "No Speakers",
                        systemImage: "speaker.wave.2",
                        description: Text("Connect to a Mac to see its speakers here.")
                    )
                    Spacer()
                }
            }
        }
        .toastOverlay(session.toasts)
    }

    // MARK: Header

    /// doc:55-65. The design draws its own header, so there's no
    /// `NavigationStack` or navigation title here.
    private var header: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrowText)
                    .microLabel()
                    .foregroundStyle(WarmSignal.label2)
                    .lineLimit(1)
                Text("Speakers")
                    .font(.system(size: titleSize, weight: .bold))
                    .tracking(-0.7)
                    .foregroundStyle(WarmSignal.label)
            }

            Spacer(minLength: 8)

            statusPill
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isLive ? WarmSignal.gold : WarmSignal.label3)
                .frame(width: 6, height: 6)

            Text(pillText)
                .font(.system(size: pillTextSize, weight: .medium))
                .foregroundStyle(WarmSignal.label2)
                .lineLimit(1)
        }
        // No lozenge, and no glass. Frosted material at a capsule radius is
        // what the Main Out deck and every button on this screen are made of,
        // so wearing it here promises a press that does nothing — and the
        // press a reader would expect (jump to the Connection tab) is a real
        // screen this view has no route to. A lit dot and a word in the
        // header's secondary ink says the same thing and promises nothing.
        //
        // razor: it stays a badge. Making it a real shortcut needs a tab
        // binding threaded down from RootView; do that and it can take an
        // affordance back.
        .accessibilityElement(children: .combine)
    }

    private var isLive: Bool { session.connectionStatus == .live }

    /// Whose speakers these are — the one thing the title can't say. With no
    /// Mac there is no name to give, so it says what the connection is doing.
    private var eyebrowText: String {
        guard let name = namedMac else { return statusText }
        return "Connected to \(name)"
    }

    /// The Mac the eyebrow can name, or nil when there isn't one to name.
    private var namedMac: String? {
        guard isLive, let name = session.snapshot?.serverName, !name.isEmpty else { return nil }
        return name
    }

    /// The pill is the glanceable state; the eyebrow is the identity. So once
    /// the eyebrow has said "Connected to Demo Mac", the pill saying
    /// "Connected · Demo" is the same two facts a second time, three words
    /// wider. It drops to the one thing the eyebrow doesn't carry — that the
    /// link is up right now — and the lit dot beside it says the rest.
    private var pillText: String {
        if namedMac != nil { return "Live" }
        return session.isDemo ? statusText + " · Demo" : statusText
    }

    private var statusText: String {
        switch session.connectionStatus {
        case .idle: return "Not Connected"
        case .connecting, .handshaking: return "Connecting…"
        case .awaitingApproval: return "Waiting for Approval…"
        case .live: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }
}

// MARK: - The console

private struct SpeakerSectionSpec: Identifiable {
    let id: String
    let title: String
    let tint: Color
    let devices: [DeviceState]
}

/// Which section of the list a speaker belongs in. The screen is one list of
/// every speaker, cut by the only thing a reader is scanning for — what this
/// speaker is doing right now — so a device's state IS its address, and there
/// is exactly one row per speaker anywhere on the screen.
///
/// A `"failed"` speaker sits in Ready rather than Playing even while the Mac
/// still has it selected: it is making no sound, and its row is a failure card
/// asking to be retried, which is a thing to do rather than a thing playing.
///
/// Playing is ``DeviceRowView/isSounding(_:)``, NOT `isSelected` — which is why
/// activating a group puts its members here rather than leaving them in Ready
/// while the room they're in plays.
enum SpeakerSection {
    case playing, ready, unavailable

    /// `@MainActor` only because ``DeviceRowView/showsFailureCard(_:)`` is —
    /// `View` conformance infers it, and the failure rule has exactly one
    /// definition on purpose.
    @MainActor
    static func of(_ device: DeviceState) -> SpeakerSection {
        if !device.isAvailable { return .unavailable }
        if DeviceRowView.isSounding(device) && !DeviceRowView.showsFailureCard(device) { return .playing }
        return .ready
    }
}

/// Which way a finger committed. ``DeviceRowView`` declares its own, because
/// the only symbol these two gestures deliberately share is
/// `WarmSignal.faderValue`.
private enum DragAxis { case horizontal, vertical }

/// The sections and the floating Main Out deck. Split out of ``SpeakersView``
/// so this screen's presentation state has a legal home: it is only ever
/// constructed when a snapshot exists, so its state dies with the snapshot
/// exactly the way ``MainOutRow``'s echo does.
private struct SpeakerConsole: View {
    let snapshot: Snapshot
    let session: any MacSessionProtocol

    // razor: collapse state is in-memory only. The design wants it remembered per Mac (doc:1046), but the phone may not persist routing state (Model/MacSessionProtocol.swift:21-23); revisit if that rule changes.
    @State private var collapsed: Set<String> = []   // the `= []` is required: State<Set<String>>
                                                     // has no init(), so without it `collapsed`
                                                     // becomes a memberwise-init parameter and
                                                     // SpeakerConsole(snapshot:session:) won't compile

    /// The deck's shadow is the one elevation in the screen, and it differs
    /// between the two grounds — 0.4 black over paper is a smudge, not height.
    @Environment(\.colorScheme) private var colorScheme

    /// The row that moves between sections is the one thing on this screen
    /// that travels. With Reduce Motion on it crossfades in place instead —
    /// same state change, no slide, no spring overshoot.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One namespace for the row that moves between Ready and Playing: the
    /// two `ForEach`es render the same device id, so the row can travel
    /// between them instead of vanishing from one and appearing in the other.
    @Namespace private var rowMove

    /// Has the user found tap-to-play and drag-to-set-level yet. Written by
    /// ``DeviceRowView`` as each gesture happens; see ``SpeakerCoach``.
    @AppStorage(SpeakerCoach.Gesture.tap.rawValue) private var learnedTap = false
    @AppStorage(SpeakerCoach.Gesture.drag.rawValue) private var learnedDrag = false

    /// The room the list leaves at the bottom for the deck it scrolls under —
    /// measured, not assumed. The deck's interior is all Dynamic Type, so at
    /// accessibility sizes it grows well past any constant and buries the last
    /// section it is supposed to float over.
    @State private var deckHeight: CGFloat = initialDeckHeight

    /// What the list clears before the deck has been laid out once. The deck's
    /// height at the default text size, so the first frame is already right for
    /// most readers and the measurement only corrects the rest.
    private static let initialDeckHeight: CGFloat = 116

    // MARK: Derived

    private var playingDevices: [DeviceState] { devices(in: .playing) }
    private var master: Int { snapshot.mainOutMasterVolume }

    private func devices(in section: SpeakerSection) -> [DeviceState] {
        snapshot.devices.filter { SpeakerSection.of($0) == section }
    }

    /// Ready, with anything that failed at the top of it. A failure card is
    /// the one row in the section that is asking for something, and it is also
    /// the tallest, so burying it under three idle speakers hides both the ask
    /// and the reason. Two passes rather than a `sorted` predicate, because
    /// this has to be stable: the Mac's own device order is what the rest of
    /// the list is in.
    private var readyDevices: [DeviceState] {
        let ready = devices(in: .ready)
        return ready.filter(DeviceRowView.showsFailureCard)
             + ready.filter { !DeviceRowView.showsFailureCard($0) }
    }

    /// One motion for the whole screen: a row's move between sections and a
    /// section's collapse run on the same curve for the same length, so the
    /// surface has a single tempo rather than one per animated thing.
    /// `spring(duration:)` is bounce-free by default — this is deceleration,
    /// not overshoot.
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.25)
    }

    /// What the row move animates against. The membership of Playing is the
    /// state change the move explains, and it changes only when the Mac says
    /// so — never under a finger, so the drag latch is never animated.
    private var playingIDs: [String] { playingDevices.map(\.id) }

    /// Where the one-time coach line hangs: under the first row a user can
    /// actually see, so the sentence sits next to the thing it describes.
    /// Collapsing that section moves the coach along with it rather than
    /// taking it away.
    private var coachAnchorID: String? {
        guard SpeakerCoach.isVisible(learnedTap: learnedTap, learnedDrag: learnedDrag) else { return nil }
        return sections.first { !collapsed.contains($0.id) && !$0.devices.isEmpty }?.devices.first?.id
    }

    /// Three sections, one per state (``SpeakerSection``), always all three —
    /// an empty heading is the honest answer to "nothing is playing", and a
    /// section that comes and goes moves the two below it every time.
    ///
    /// Not the design's own list (doc:2000-2006): PINNED is gone because
    /// nothing in the protocol carries a pin, and BLUETOOTH is gone because a
    /// Bluetooth output arrives as an ordinary speaker whose icon says what it
    /// is — a heading of its own was a permanently empty section promising a
    /// feature (roadmap 004), and it cut the list by transport where the
    /// reader is scanning by state.
    private var sections: [SpeakerSectionSpec] {
        [
            SpeakerSectionSpec(id: "live", title: "Playing", tint: WarmSignal.goldText,
                               devices: playingDevices),
            SpeakerSectionSpec(id: "ready", title: "Ready", tint: WarmSignal.label2,
                               devices: readyDevices),
            SpeakerSectionSpec(id: "unavailable", title: "Unavailable", tint: WarmSignal.label2,
                               devices: devices(in: .unavailable)),
        ]
    }

    // MARK: Body

    var body: some View {
        // ScrollView + LazyVStack, not List: every row is fully custom-drawn,
        // and List's cell chrome, separators and swipe handling would fight
        // both the wash and DeviceRowView's horizontal drag. The
        // `.simultaneousGesture` arbitration there is specified against this
        // container.
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, deckHeight + 16)
            // Starting a speaker re-sorts the row out of Ready and into
            // Playing. Without this the row teleports and the user has to find
            // it again; with it the row is the same object in a new place,
            // which is the truth.
            .animation(motion, value: playingIDs)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) { deck }
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionView(_ section: SpeakerSectionSpec) -> some View {
        VStack(spacing: 0) {
            sectionHeader(section)

            if !collapsed.contains(section.id) {
                ForEach(section.devices, id: \.id) { device in
                    DeviceRowView(device: device, session: session)
                        // The row leaves one section and enters another as two
                        // separate views; this is what makes them one row.
                        .modifier(TravelsBetweenSections(id: device.id,
                                                         namespace: rowMove,
                                                         travels: !reduceMotion))
                        // Reduce Motion's version of the same move: the row
                        // crossfades where it lands instead of flying there.
                        .transition(.opacity)

                    if device.id == coachAnchorID { gestureCoach }
                }
            }
        }
        .padding(.bottom, 4)
    }

    /// doc:70-75 — chevron, title, count, then a hairline rule to the edge.
    private func sectionHeader(_ section: SpeakerSectionSpec) -> some View {
        HStack(spacing: 8) {
            warmChevron(collapsed.contains(section.id) ? 135 : -45)
                .padding(.leading, 4)

            Text(section.title)
                .microLabel()
                .foregroundStyle(section.tint)

            Text(String(section.devices.count))
                .microLabel()
                .foregroundStyle(WarmSignal.label3)

            Rectangle()
                .fill(WarmSignal.hairline)
                .frame(height: 1)
        }
        // A full-width row, so the 44 pt floor is a height floor — a square
        // target would only shrink the strip a finger already has.
        .frame(height: WarmSignal.hitTarget)
        .contentShape(Rectangle())
        // On the screen's one curve, like the travelling row — it was the
        // last state change here that simply cut. `motion` is already the
        // Reduce Motion branch, so this needs no gate of its own.
        .onTapGesture {
            withAnimation(motion) {
                if collapsed.contains(section.id) { collapsed.remove(section.id) }
                else { collapsed.insert(section.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        // State, not instructions: the button trait already tells VoiceOver a
        // double tap does something, so a hint saying so is read on every
        // header for nothing. What it CAN'T infer is which way this one is
        // pointing — the chevron is the only cue, and it is decorative.
        .accessibilityValue(collapsed.contains(section.id) ? "Collapsed" : "Expanded")
    }

    // MARK: The one-time coach

    /// The screen's two core gestures, said once, under the first row. Inline
    /// and skippable rather than a modal or a spotlight tour: nothing here
    /// needs protecting from the user, and a first tap that starts music in
    /// another room is a thing to warn about, not to interrupt for.
    ///
    /// It leaves for good once both gestures have been used (or on Got it) —
    /// see ``SpeakerCoach``.
    private var gestureCoach: some View {
        HStack(spacing: 0) {
            Text("Tap to play · Drag to set level")
                .microLabel()
                .foregroundStyle(WarmSignal.label2)
                // Spoken, the middle dot is noise, so VoiceOver gets the
                // sentence instead.
                .accessibilityLabel("Tap a speaker to play it. Drag across a speaker to set its level.")

            Spacer(minLength: 8)

            Text("Got it")
                .microLabel()
                .foregroundStyle(WarmSignal.goldText)
                .padding(.horizontal, 10)
                .frame(height: WarmSignal.hitTarget)
                .contentShape(Rectangle())
                .onTapGesture { SpeakerCoach.dismiss() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Got it")
                .accessibilityHint("Hides this tip")
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
    }

    // MARK: Main Out deck

    /// doc:121-142. Floats over the list — `.overlay`, never `.safeAreaInset`,
    /// so content keeps passing under the frosted glass instead of stopping
    /// above it.
    private var deck: some View {
        let elevation = WarmSignal.deckShadow(colorScheme)
        return VStack(spacing: 11) {
            deckHeader

            MainOutRow(masterVolume: master,
                       isMuted: snapshot.mainOutMuted,
                       session: session,
                       onToggleMute: { session.setMainOutMuted(!snapshot.mainOutMuted) })
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 14, trailing: 15))
        // One edge, drawn by `glassPanel` itself. The second `glassHi` stroke
        // that used to sit over it was a highlight on top of an edge, and at
        // this radius the two read as a single thick, slightly muddy border.
        .glassPanel(cornerRadius: WarmSignal.Radius.panel, fill: WarmSignal.deckFill)
        .shadow(color: elevation.color, radius: elevation.radius, y: elevation.y)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        // Measured at the end of the chain, so the number is everything the
        // deck occupies — its own bottom padding included — and the list's
        // bottom inset clears all of it. Nothing the list does changes this
        // height, so there is no loop.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { deckHeight = $0 }
    }

    /// The deck's one line of chrome, and exactly two things: what this panel
    /// is, and where it is pointed. A count of what's playing belongs to the
    /// Playing section's own heading, which is on the same screen — carried
    /// here as well it is a duplicate, and one that costs the title its width.
    ///
    /// Truncation has exactly one loser, and it is the picker: `Main Out` is
    /// two fixed words that name the panel, and `.fixedSize()` is what
    /// guarantees the header can never spend them on a long group name.
    private var deckHeader: some View {
        HStack(spacing: 10) {
            Text("Main Out")
                .microLabel()
                .foregroundStyle(WarmSignal.goldText)
                .fixedSize()

            Spacer(minLength: 8)

            MainOutPicker(snapshot: snapshot, session: session)
        }
        .lineLimit(1)
    }
}

/// Gives a device row one identity across the two sections it can be rendered
/// in, so arming it moves the row rather than replacing it. Applied
/// conditionally because Reduce Motion asks for no travel at all, and the way
/// to have none is not to match the geometry in the first place — the row then
/// falls back to the plain crossfade its transition already specifies.
private struct TravelsBetweenSections: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let travels: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if travels {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// doc:70-75, doc:129 — the design's chevron is a 9×9 box with two 1.8 pt
/// borders, rotated. `-45°` points it down, `135°` points it right.
private func warmChevron(_ degrees: Double) -> some View {
    Path { path in
        path.move(to: CGPoint(x: 0.9, y: 0))
        path.addLine(to: CGPoint(x: 0.9, y: 8.1))
        path.addLine(to: CGPoint(x: 9, y: 8.1))
    }
    .stroke(WarmSignal.label2, style: StrokeStyle(lineWidth: 1.8, lineCap: .butt, lineJoin: .miter))
    .frame(width: 9, height: 9)
    .rotationEffect(.degrees(degrees))
}

// MARK: - Main Out master row

/// Main Out's mute + master volume. A leaf view for the same reason
/// ``DeviceRowView`` is one: the in-drag echo (`localVolume`) has to be scoped
/// to the row so it dies with the list whenever the snapshot goes away
/// (backgrounding, a keepalive drop, a reconnect). Held on `SpeakersView` —
/// which lives as long as the app does — a drag whose release callback never
/// arrived left the echo set forever, and the thumb then ignored every later
/// snapshot the Mac sent.
///
/// The echo now outlives the RELEASE too — that's what keeps the thumb off the
/// ~50ms rubber-band back to the pre-release value — which is only safe
/// because it stays bounded: the next Main Out snapshot clears it, and a
/// disconnect or a tab change takes the whole list, and this view with it. The
/// other three sliders still clear on release; this is the one that was
/// reported.
///
/// The fader is drawn (doc:130-141) and runs under the same axis latch
/// ``DeviceRowView`` uses, which is what sets `isDragging`.
struct MainOutRow: View {
    let masterVolume: Int
    let isMuted: Bool
    let session: any MacSessionProtocol
    var onToggleMute: () -> Void = {}   // defaulted → the 3-arg init still compiles

    @State private var localVolume: Double?
    /// True from the drag's first tick to its release. While it's true the
    /// Mac's echoes must NOT clear `localVolume` — they arrive ~50ms behind
    /// the finger and would drag the thumb backwards under it.
    @State private var isDragging = false
    @State private var trackWidth: CGFloat = 0
    @State private var axis: DragAxis?
    @State private var dragStartVolume: Int?
    @State private var detents = WarmSignal.FaderDetents()  // the fader's clicks

    @ScaledMetric(relativeTo: .subheadline) private var muteIconSize: CGFloat = 15

    /// What the thumb shows: the finger while a drag is in flight (and the
    /// value it was released at until the Mac echoes it back), the Mac's
    /// value whenever neither applies.
    static func thumbValue(local: Double?, server: Int) -> Double {
        local ?? Double(server)
    }

    private var value: Int { Int(Self.thumbValue(local: localVolume, server: masterVolume).rounded()) }
    private var fraction: CGFloat { CGFloat(value) / 100 }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: muteIconSize))
                    .foregroundStyle(WarmSignal.label2)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: WarmSignal.Radius.control, style: .continuous)
                        .fill(WarmSignal.well))
                    .overlay(RoundedRectangle(cornerRadius: WarmSignal.Radius.control, style: .continuous)
                        .strokeBorder(WarmSignal.rim, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .hittable(drawn: 38)
            .accessibilityLabel(isMuted ? "Unmute Main Out" : "Mute Main Out")

            fader

            Text(String(value))
                .readout(16)
                .foregroundStyle(WarmSignal.goldText)
                .frame(width: 26, alignment: .trailing)
        }
        .onChange(of: masterVolume) {
            // The bound on the hold: any snapshot that moves Main Out ends
            // it, so a released — or stranded — echo can never outlive one
            // round trip, and the thumb goes back to following the Mac.
            guard !isDragging else { return }
            localVolume = nil
        }
        // Mute is confirmed rather than optimistic here — the icon flips when
        // the Mac says it did — so the tick rides the confirmation, which is
        // the moment the thing actually happened.
        .sensoryFeedback(.impact(weight: .light), trigger: isMuted)
        .sensoryFeedback(trigger: WarmSignal.faderRail(value, dragging: isDragging)) { _, new in
            new == nil ? nil : .impact(weight: .light)
        }
        // The detents the fader travels through, at a fraction of the rails'
        // strength — the same rule and the same click the row's dial gives,
        // because they are the same control at two scopes.
        .sensoryFeedback(.impact(weight: .light, intensity: WarmSignal.FaderDetents.intensity),
                         trigger: detents.ticks)
    }

    /// The track's rim, and so also the inset its fill has to keep.
    private static let rimWidth: CGFloat = 1

    /// Narrow on purpose: the cap's width is the precision of the value it
    /// marks, and the 44 pt hit slab around it is what the finger actually gets.
    private static let capWidth: CGFloat = 22

    /// doc:130-141 — a 44 pt hit slab (doc:1036) around an 18 pt track.
    private var fader: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(WarmSignal.well)
                .frame(height: 18)
                .overlay(Capsule().strokeBorder(WarmSignal.rim, lineWidth: Self.rimWidth).frame(height: 18))

            // Inset by the rim at both ends. Sharing x = 0 with the track put
            // the fill's rounded cap exactly on top of the rim's leading arc,
            // so the track's own edge was hidden at every value including 0.
            Capsule()
                .fill(WarmSignal.gold)
                .frame(width: max(0, fraction * (trackWidth - 2 * Self.rimWidth)), height: 16)
                .offset(x: Self.rimWidth)

            // A fader cap, not a button. Narrow across the travel so the value
            // it marks is precise, tall across the track so it reads as an
            // instrument, and carrying a gold index bar down its centre — the
            // signal continuing through the cap, and the exact point the value
            // sits at. A capsule rather than a scale radius, for the same
            // reason the status pill is one: the shape is the point.
            //
            // Depth is the rim and the silhouette, never a fill treatment. The
            // document's brass gradient (doc:138, doc:366) measures 1.07:1
            // against the fill it sits on, where a control needs 3:1.
            ZStack {
                Capsule()
                    .fill(WarmSignal.raised)
                    .overlay(Capsule().strokeBorder(WarmSignal.rim, lineWidth: 1))
                Capsule()
                    .fill(WarmSignal.gold)
                    .frame(width: 3, height: 16)
            }
            .frame(width: Self.capWidth, height: 34)
            .offset(x: max(0, min(trackWidth - Self.capWidth,
                                  fraction * trackWidth - Self.capWidth / 2)))
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = $0 }
        .gesture(dragGesture)
        .accessibilityElement()
        .accessibilityLabel("Main Out volume")
        .accessibilityValue("\(Int(Self.thumbValue(local: localVolume, server: masterVolume))) percent")
        .accessibilityAdjustableAction { direction in
            let next = min(100, max(0, value + (direction == .increment ? 5 : -5)))
            session.setMainOutMasterVolume(next, isFinal: true)
        }
    }

    /// doc:1730-1749 — the same axis latch ``DeviceRowView`` uses. A press
    /// that never commits does nothing: a master fader is not a button, and
    /// the one thing a stray tap on it must never do is move the level.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gestureValue in
                let w = gestureValue.translation.width, h = gestureValue.translation.height
                if axis == nil {
                    guard max(abs(w), abs(h)) >= 5 else { return }
                    axis = abs(w) > abs(h) ? .horizontal : .vertical
                    if axis == .horizontal {
                        dragStartVolume = value
                        detents.begin(at: value)
                        // The only writer of `isDragging`. Without it the echo
                        // below clears mid-drag and the thumb rubber-bands
                        // under the finger.
                        isDragging = true
                    }
                }
                guard axis == .horizontal, let start = dragStartVolume else { return }
                let v = WarmSignal.faderValue(start: start, translationWidth: w, trackWidth: trackWidth)
                localVolume = Double(v)
                detents.advance(to: v)
                session.setMainOutMasterVolume(v, isFinal: false)
            }
            .onEnded { _ in
                defer { axis = nil; dragStartVolume = nil; isDragging = false }
                switch axis {
                case .horizontal:
                    session.setMainOutMasterVolume(value, isFinal: true)
                    // The echo is ~50ms behind, so clearing it HERE (as the
                    // other rows still do) rubber-bands the thumb to the
                    // pre-release value for that beat. Hold it instead and let
                    // the snapshot above clear it.
                case .vertical, nil:
                    return
                }
            }
    }
}

// MARK: - Previews

/// Preview-only stand-in for the banner/offline scenarios `DemoMacSession`
/// has no public seam to produce (it hardcodes `localFallbackActive: false`,
/// `takeoverStatus: nil` by design — those are real-Mac-only conditions).
/// Never used outside `#Preview`.
@MainActor
private final class PreviewSession: MacSessionProtocol {
    var snapshot: Snapshot?
    var connectionStatus: MacConnectionState
    let isDemo: Bool
    let toasts = ToastCenter()

    init(snapshot: Snapshot?, connectionStatus: MacConnectionState, isDemo: Bool = false) {
        self.snapshot = snapshot
        self.connectionStatus = connectionStatus
        self.isDemo = isDemo
    }

    func setDeviceSelected(id: String, selected: Bool) {}
    func retryConnection(id: String) {}
    func setMainOut(_ state: MainOutState) {}
    func setDeviceVolume(id: String, volume: Int, isFinal: Bool) {}
    func setDeviceMuted(id: String, muted: Bool) {}
    func setMainOutMasterVolume(_ volume: Int, isFinal: Bool) {}
    func setMainOutMuted(_ muted: Bool) {}
    func createGroup(name: String, memberIDs: [String], iconSymbolName: String?) {}
    func updateGroup(_ group: GroupState) {}
    func deleteGroup(id: String) {}
    func setGroupMuted(id: String, muted: Bool) {}
    func addAppRoute(bundleID: String, displayName: String) {}
    func removeAppRoute(bundleID: String) {}
    func setAppDestination(bundleID: String, kind: String, deviceID: String?) {}
    func setAppVolume(bundleID: String, volume: Int, isFinal: Bool) {}
    func setConnectVolume(_ volume: Int, isFinal: Bool) {}
    func setStartBufferMs(_ ms: Int) {}
}

#Preview("Healthy — Demo") {
    SpeakersView(session: DemoMacSession())
}

/// Main Out pointed at a group: its members are Playing and adjustable, and
/// the Mac — still ticked in the dormant Selected Devices set — is Ready.
#Preview("Group is Main Out") {
    let demo = DemoMacSession()
    demo.setMainOut(MainOutState(kind: "group", groupID: "demo-living-room"))
    return SpeakersView(session: demo)
}

#Preview("Failed device + banners") {
    let base = DemoMacSession().snapshot!
    let bannered = Snapshot(
        serverName: base.serverName,
        devices: base.devices,
        mainOut: base.mainOut,
        mainOutMasterVolume: base.mainOutMasterVolume,
        mainOutMuted: base.mainOutMuted,
        groups: base.groups,
        activeGroupID: base.activeGroupID,
        appRoutes: base.appRoutes,
        liveRoutedAppNames: base.liveRoutedAppNames,
        addableApps: base.addableApps,
        localFallbackActive: true,
        takeoverStatus: "Waiting for you to allow AirPlay timing in Login Items & Extensions…",
        systemDefaultIsAirPlayActive: true,
        settings: base.settings
    )
    return SpeakersView(session: PreviewSession(snapshot: bannered, connectionStatus: .live))
}

#Preview("Offline") {
    SpeakersView(session: PreviewSession(snapshot: nil, connectionStatus: .disconnected(.keepaliveTimeout)))
}
