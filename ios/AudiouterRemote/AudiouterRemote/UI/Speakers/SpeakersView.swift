// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// Tab 1: which Mac is connected, every speaker as its own fader, and the
/// floating Main Out deck. This view owns no local state at all — every value
/// it renders comes straight from `session.snapshot`. The in-drag echoes live
/// one level down, in ``MainOutRow`` and ``DeviceRowView``, and the screen's
/// presentation state (which sections are collapsed, whether the drawer is up)
/// lives in ``SpeakerConsole``, which only exists while a snapshot does — so
/// each dies with the list it belongs to.
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
        guard isLive, let name = session.snapshot?.serverName, !name.isEmpty else { return statusText }
        return "Connected to \(name)"
    }

    /// The connection's own words, and Demo when this is the demo Mac. Naming
    /// the Mac is the eyebrow's job, so the pill never repeats it.
    private var pillText: String {
        session.isDemo ? statusText + " · Demo" : statusText
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

/// One section of the speaker list. `devices` is what renders; `placeholder`
/// is the honest empty state for the one section that is structurally always
/// empty, and is never anything a user could mistake for a real speaker.
private struct SpeakerSectionSpec: Identifiable {
    let id: String
    let title: String
    let tint: Color
    let devices: [DeviceState]
    let placeholder: String?
}

/// Which way a finger committed. Shared by the deck fader and the drawer rows;
/// ``DeviceRowView`` declares its own, because the only symbol these three
/// gestures deliberately share is `WarmSignal.faderValue`.
private enum DragAxis { case horizontal, vertical }

/// The sections, the floating Main Out deck and its drawer. Split out of
/// ``SpeakersView`` so this screen's presentation state has a legal home: it is
/// only ever constructed when a snapshot exists, so its state dies with the
/// snapshot exactly the way ``MainOutRow``'s echo does.
private struct SpeakerConsole: View {
    let snapshot: Snapshot
    let session: any MacSessionProtocol

    // razor: collapse state is in-memory only. The design wants it remembered per Mac (doc:1046), but the phone may not persist routing state (Model/MacSessionProtocol.swift:21-23); revisit if that rule changes.
    @State private var collapsed: Set<String> = []   // the `= []` is required: State<Set<String>>
    @State private var drawerOpen = false            // has no init(), so without it `collapsed`
                                                     // becomes a memberwise-init parameter and
                                                     // SpeakerConsole(snapshot:session:) won't compile

    /// The deck's shadow is the one elevation in the screen, and it differs
    /// between the two grounds — 0.4 black over paper is a smudge, not height.
    @Environment(\.colorScheme) private var colorScheme

    /// The drawer and the row that moves between sections are the two things
    /// on this screen that travel. With Reduce Motion on they crossfade in
    /// place instead — same state change, no slide, no spring overshoot.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One namespace for the row that moves between AIRPLAY and PLAYING: the
    /// two `ForEach`es render the same device id, so the row can travel
    /// between them instead of vanishing from one and appearing in the other.
    @Namespace private var rowMove

    /// Has the user found tap-to-play and drag-to-set-level yet. Written by
    /// ``DeviceRowView`` as each gesture happens; see ``SpeakerCoach``.
    @AppStorage(SpeakerCoach.Gesture.tap.rawValue) private var learnedTap = false
    @AppStorage(SpeakerCoach.Gesture.drag.rawValue) private var learnedDrag = false

    /// The room the list leaves at the bottom for the deck it scrolls under.
    private static let deckHeight: CGFloat = 116

    // MARK: Derived

    private var playingDevices: [DeviceState] { snapshot.devices.filter { $0.isSelected && $0.isAvailable } }
    private var playingCount: Int { playingDevices.count }
    private var master: Int { snapshot.mainOutMasterVolume }

    /// One motion for the whole screen: the drawer's rise and a row's move
    /// between sections run on the same curve for the same length, so the
    /// surface has a single tempo rather than one per animated thing.
    /// `spring(duration:)` is bounce-free by default — this is deceleration,
    /// not overshoot.
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.25)
    }

    /// What the row move animates against. The membership of PLAYING is the
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

    /// doc:2000-2006 minus PINNED: nothing in the protocol carries a pin, so
    /// that section could only ever draw its own "no pinned speakers" — an
    /// empty heading first on the screen, above the speakers themselves. The
    /// remaining four, always all four, in this order.
    private var sections: [SpeakerSectionSpec] {
        [
            SpeakerSectionSpec(id: "live", title: "PLAYING", tint: WarmSignal.goldText,
                               devices: playingDevices, placeholder: nil),
            SpeakerSectionSpec(id: "airplay", title: "AIRPLAY", tint: WarmSignal.label2,
                               devices: snapshot.devices.filter { !$0.isSelected && $0.isAvailable },
                               placeholder: nil),
            // razor: structural placeholder only. Nothing on the wire ever reports a Bluetooth output — DeviceState.kind is a free-form String (AudiouterProtocol CompanionSnapshot.swift:42) and the Mac never sends one. Tracked as roadmap 004.
            SpeakerSectionSpec(id: "bluetooth", title: "BLUETOOTH", tint: WarmSignal.label2,
                               devices: [], placeholder: "BLUETOOTH OUTPUT NOT AVAILABLE YET"),
            SpeakerSectionSpec(id: "unavailable", title: "UNAVAILABLE", tint: WarmSignal.label2,
                               devices: snapshot.devices.filter { !$0.isAvailable },
                               placeholder: nil),
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
            .padding(.bottom, Self.deckHeight + 16)
            // Arming re-sorts the row out of AIRPLAY and into PLAYING. Without
            // this the row teleports and the user has to find it again; with
            // it the row is the same object in a new place, which is the truth.
            .animation(motion, value: playingIDs)
        }
        .scrollIndicators(.hidden)
        // The scrim takes every touch that lands on the list, so VoiceOver must
        // not keep offering the rows underneath it — a double tap there would
        // arm a speaker no finger can reach. The deck stays live either way:
        // it draws OVER the scrim and is not dimmed by it.
        .accessibilityHidden(drawerOpen)
        .overlay { if drawerOpen { scrim } }
        .overlay(alignment: .bottom) { deck }
        .overlay(alignment: .bottom) {
            if drawerOpen {
                drawer
                    .padding(.bottom, Self.deckHeight)
                    .transition(reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(motion, value: drawerOpen)
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

                if let placeholder = section.placeholder {
                    Text(placeholder)
                        .microLabel()
                        .foregroundStyle(WarmSignal.label3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
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
        .onTapGesture {
            if collapsed.contains(section.id) { collapsed.remove(section.id) }
            else { collapsed.insert(section.id) }
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
    /// It leaves for good once both gestures have been used (or on GOT IT) —
    /// see ``SpeakerCoach``.
    private var gestureCoach: some View {
        HStack(spacing: 0) {
            Text("TAP TO PLAY · DRAG TO SET LEVEL")
                .microLabel()
                .foregroundStyle(WarmSignal.label2)
                // On screen it is the same micro voice as the drawer's own
                // "DRAG TO ADJUST"; spoken, capitals and a middle dot are
                // noise, so VoiceOver gets the sentence instead.
                .accessibilityLabel("Tap a speaker to play it. Drag across a speaker to set its level.")

            Spacer(minLength: 8)

            Text("GOT IT")
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
                       onToggleMute: { session.setMainOutMuted(!snapshot.mainOutMuted) },
                       onIdlePress: { drawerOpen.toggle() })
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 14, trailing: 15))
        // One edge, drawn by `glassPanel` itself. The second `glassHi` stroke
        // that used to sit over it was a highlight on top of an edge, and at
        // this radius the two read as a single thick, slightly muddy border.
        .glassPanel(cornerRadius: WarmSignal.Radius.panel, fill: WarmSignal.deckFill)
        .shadow(color: elevation.color, radius: elevation.radius, y: elevation.y)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var deckHeader: some View {
        HStack(spacing: 10) {
            Text("MAIN OUT")
                .microLabel()
                .foregroundStyle(WarmSignal.goldText)

            // A menu picker's label is drawn by UIKit and ignores `.lineLimit`,
            // so the only way to stop it wrapping is to let it take its ideal
            // width. Without this the deck header grows to four lines and the
            // deck buries the last section (doc:123-128 is one line).
            MainOutPicker(snapshot: snapshot, session: session)
                .fixedSize()

            Text("\(playingCount) PLAYING")
                .microLabel()
                .foregroundStyle(WarmSignal.label2)
                .fixedSize()

            Spacer(minLength: 0)

            warmChevron(drawerOpen ? 135 : -45)
                .hittable(drawn: 9)
                .onTapGesture { drawerOpen.toggle() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(drawerOpen ? "Hide playing speakers" : "Show playing speakers")
        }
        .lineLimit(1)
        .contentShape(Rectangle())
        // The whole strip opens the drawer, not the 9 pt chevron alone: the
        // label, the count and the gap between them sit over a control the
        // chevron only points at, and 9 pt is not where a thumb aims.
        //
        // `.onTapGesture` on the container, deliberately — a gesture on a
        // child outranks one on its ancestor, so the picker's UIKit menu keeps
        // every tap that lands on the picker (including the 12 pt its
        // `.hittable` claims past its glyph) and this takes the rest. A
        // `.simultaneousGesture` would fire both and open a menu into a moving
        // drawer.
        .onTapGesture { drawerOpen.toggle() }
    }

    // MARK: Drawer

    private var scrim: some View {
        WarmSignal.scrim
            .ignoresSafeArea()
            .onTapGesture { drawerOpen = false }
            .transition(.opacity)
            .accessibilityLabel("Hide playing speakers")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { drawerOpen = false }
    }

    /// doc:188-217 — every armed device's own level, and the per-device mute
    /// the row gave up.
    private var drawer: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(WarmSignal.label3)
                .frame(width: 38, height: 4)
                .padding(.bottom, 14)

            HStack(spacing: 8) {
                Text("PLAYING")
                    .microLabel()
                    .foregroundStyle(WarmSignal.goldText)
                Spacer(minLength: 8)
                Text("DRAG TO ADJUST")
                    .microLabel()
                    .foregroundStyle(WarmSignal.label2)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)

            VStack(spacing: 4) {
                // The design's own drawer list is its pinned device plus the
                // playing ones (doc:2007); there is no PINNED section here, so
                // that reduces to the playing ones.
                ForEach(playingDevices, id: \.id) { device in
                    MainOutDrawerRow(device: device, session: session)
                }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 14, bottom: 12, trailing: 14))
        .glassPanel(cornerRadius: WarmSignal.Radius.panel, fill: WarmSignal.panel)
        .padding(.horizontal, 10)
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
    var onIdlePress: () -> Void = {}    // a press with no movement — raises the drawer

    @State private var localVolume: Double?
    /// True from the drag's first tick to its release. While it's true the
    /// Mac's echoes must NOT clear `localVolume` — they arrive ~50ms behind
    /// the finger and would drag the thumb backwards under it.
    @State private var isDragging = false
    @State private var trackWidth: CGFloat = 0
    @State private var axis: DragAxis?
    @State private var dragStartVolume: Int?

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
    /// that never commits raises the drawer instead of moving anything.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gestureValue in
                let w = gestureValue.translation.width, h = gestureValue.translation.height
                if axis == nil {
                    guard max(abs(w), abs(h)) >= 5 else { return }
                    axis = abs(w) > abs(h) ? .horizontal : .vertical
                    if axis == .horizontal {
                        dragStartVolume = value
                        // The only writer of `isDragging`. Without it the echo
                        // below clears mid-drag and the thumb rubber-bands
                        // under the finger.
                        isDragging = true
                    }
                }
                guard axis == .horizontal, let start = dragStartVolume else { return }
                let v = WarmSignal.faderValue(start: start, translationWidth: w, trackWidth: trackWidth)
                localVolume = Double(v)
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
                case .vertical:
                    return
                case nil:
                    onIdlePress()
                }
            }
    }
}

// MARK: - Drawer row

/// One armed device inside the Main Out drawer (doc:200-215): its own level,
/// dragged the same way, plus the mute button ``DeviceRowView`` gave up — so
/// mute stays two taps away and that row's `MUTED` sub-label stays actionable.
private struct MainOutDrawerRow: View {
    let device: DeviceState
    let session: any MacSessionProtocol

    @State private var axis: DragAxis?
    @State private var dragStartVolume: Int?
    @State private var localVolume: Double?
    @State private var rowWidth: CGFloat = 0

    @ScaledMetric(relativeTo: .caption) private var muteIconSize: CGFloat = 12
    @ScaledMetric(relativeTo: .subheadline) private var nameSize: CGFloat = 14.5

    private var displayVolume: Int { Int((localVolume ?? Double(device.volume)).rounded()) }
    private var dragging: Bool { axis == .horizontal }
    private var controlsEnabled: Bool {
        DeviceRowView.isControllable(device, appRoutes: session.snapshot?.appRoutes ?? [])
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                session.setDeviceMuted(id: device.id, muted: !device.isMuted)
            } label: {
                Image(systemName: device.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: muteIconSize))
                    .foregroundStyle(device.isMuted ? WarmSignal.gold : WarmSignal.label2)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: WarmSignal.Radius.control, style: .continuous)
                        .fill(WarmSignal.well))
                    .overlay(RoundedRectangle(cornerRadius: WarmSignal.Radius.control, style: .continuous)
                        .strokeBorder(WarmSignal.rim, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .hittable(drawn: 28)
            .accessibilityLabel(device.isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")

            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(WarmSignal.ring, lineWidth: 2)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                Text(device.name)
                    .font(.system(size: nameSize, weight: .medium))
                    .foregroundStyle(WarmSignal.label)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(String(displayVolume))
                    .readout(14)
                    .foregroundStyle(WarmSignal.goldText)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(device.name)
            .accessibilityValue("\(displayVolume) percent")
            .accessibilityAdjustableAction { direction in
                guard controlsEnabled else { return }
                session.setDeviceVolume(
                    id: device.id,
                    volume: min(100, max(0, device.volume + (direction == .increment ? 5 : -5))),
                    isFinal: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(alignment: .leading) {
            Rectangle()
                .fill(LinearGradient(colors: [WarmSignal.ember, WarmSignal.gold],
                                     startPoint: .leading, endPoint: .trailing))
                // The same step down ``DeviceRowView/washOpacity`` takes, so a
                // muted speaker reads as muted in both places it is drawn. The
                // edge line and the readout keep the level.
                .opacity(device.isMuted ? 0.09 : 0.30)
                .frame(width: max(0, CGFloat(displayVolume) / 100 * rowWidth))
        }
        .overlay(alignment: .leading) {
            // razor: at rest this measures 1.36:1 light / 2.14:1 dark, under
            // the 3:1 non-text floor ``DeviceRowView/edgeLine`` is held to.
            // It is not the sole carrier of the level here — the drawer row
            // also states it as a number — and this row's wash is 0.30 against
            // that row's 0.14, so no single opacity clears both sides of the
            // line. Fixing it means restyling the drawer row's wash.
            Rectangle()
                .fill(WarmSignal.glow)
                .frame(width: 2.5)
                .opacity(dragging ? 1 : 0.4)
                .offset(x: max(0, CGFloat(displayVolume) / 100 * rowWidth - 1.25))
        }
        .background(WarmSignal.well)
        .clipShape(RoundedRectangle(cornerRadius: WarmSignal.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WarmSignal.Radius.row, style: .continuous)
            .strokeBorder(WarmSignal.rim, lineWidth: 0.5))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .sensoryFeedback(.impact(weight: .light), trigger: device.isMuted)
        .sensoryFeedback(trigger: WarmSignal.faderRail(displayVolume, dragging: dragging)) { _, new in
            new == nil ? nil : .impact(weight: .light)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gestureValue in
                let w = gestureValue.translation.width, h = gestureValue.translation.height
                if axis == nil {
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
                defer { axis = nil; dragStartVolume = nil }
                guard axis == .horizontal, controlsEnabled else { return }
                session.setDeviceVolume(id: device.id,
                                        volume: Int((localVolume ?? Double(device.volume)).rounded()),
                                        isFinal: true)
                localVolume = nil
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
