// Copyright (c) 2026 ahh. All rights reserved.

import SwiftUI
import AudioutProtocol

/// One per-app route, drawn as its own fader — the same row-as-fader grammar
/// as ``DeviceRowView``, expressed on a row with no play/mute concept: the
/// protocol carries no app mute, and this row has no tap action at all, so
/// there is no touch-down pressed flash (a flash is a promise; here the
/// promise would be a lie — see ``DeviceRowView/pressed`` for the reasoning
/// this row deliberately does NOT copy).
///
/// The destination pill is the row's one tap target — a `Menu` with a drawn
/// label, ``MainOutPicker``'s pattern. Everything else is either display
/// (name, state word, readout) or the drag: a horizontal drag anywhere on the
/// row sets `route.volume`, and it is always live — the Mac accepts a volume
/// write regardless of `isRunning` (a not-running app's level is a stored
/// preset, not a refusal), so unlike ``DeviceRowView`` this drag has no
/// disabled branch to gate or refuse.
///
/// Volume policy, identical to ``DeviceRowView``: `localVolume` is the
/// in-drag echo, read in place of `route.volume` while a horizontal drag is
/// live so the ~50ms coalescer's echo can't fight the finger, and cleared on
/// release (not held, the way `MainOutRow` holds its own) so the row
/// reconciles from the next snapshot.
struct AppRouteRowView: View {
    let route: AppRouteState
    /// Devices this row may redirect to — already filtered to available
    /// AirPlay-capable, non-local devices (mirrors `PopoverController`
    /// `.availableAirPlayDestinations` on the Mac side).
    let availableDevices: [DeviceState]
    let session: any MacSessionProtocol

    /// Committed horizontally — ``HorizontalDragGesture`` has already handed
    /// a vertical pan back to the enclosing `ScrollView` by then.
    @State private var dragging = false
    @State private var dragStartVolume: Int?
    @State private var localVolume: Double?
    @State private var detents = WarmSignal.FaderDetents()
    @State private var rowWidth: CGFloat = 0

    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 16.5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Pinned statics
    //
    // All `nonisolated`: pure value-type helpers, and the tests call them from
    // Swift Testing's background threads — left implicitly @MainActor (inherited
    // from View), the closures' runtime isolation checks SIGTRAP there.

    /// Running first, silent to the bottom; stable within each half — two
    /// filter passes, like `SpeakerConsole.readyDevices`, so the Mac's own
    /// order is what each half stays in rather than a `sorted` predicate
    /// re-ordering ties.
    nonisolated static func sortedForDisplay(_ routes: [AppRouteState]) -> [AppRouteState] {
        routes.filter(\.isRunning) + routes.filter { !$0.isRunning }
    }

    /// What the pill says it is pointed at, and the wording `spokenValue`
    /// borrows its device-name and fallback branches from.
    nonisolated static func destinationTitle(for route: AppRouteState, devices: [DeviceState]) -> String {
        switch route.destinationKind {
        case "noRedirect": return "No Redirect"
        case "currentDevice": return "This Mac"
        case "device":
            return devices.first(where: { $0.id == route.deviceID })?.name ?? "Unavailable Device"
        default: return route.destinationKind
        }
    }

    /// `kind == "device"` — drives the pill's gold: an active redirect is
    /// signal, the same gold thread as `DeviceRowView.routedDot`.
    nonisolated static func isRedirectedToDevice(_ route: AppRouteState) -> Bool {
        route.destinationKind == "device"
    }

    /// What VoiceOver reads as the row's value — comma-clauses, like
    /// `DeviceRowView.spokenValue`. `displayVolume` is passed rather than
    /// read off `route`, because the row may be showing an in-drag echo the
    /// Mac hasn't confirmed yet, and what the screen shows and what
    /// VoiceOver says have to be the same number.
    nonisolated static func spokenValue(for route: AppRouteState, displayVolume: Int, devices: [DeviceState]) -> String {
        var parts = ["\(displayVolume) percent"]
        switch route.destinationKind {
        case "noRedirect": parts.append("no redirect")
        case "currentDevice": parts.append("this Mac")
        default: parts.append(destinationTitle(for: route, devices: devices))
        }
        if !route.isRunning { parts.append("not running") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Derived state

    private var displayVolume: Int { Int((localVolume ?? Double(route.volume)).rounded()) }
    private var volumeFraction: CGFloat { CGFloat(displayVolume) / 100 }

    /// The rail the finger is currently pinned against, for the boundary
    /// tick — `DeviceRowView`'s rule, unchanged.
    private var rail: Int? { WarmSignal.faderRail(displayVolume, dragging: dragging) }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            AppGlyph(bundleID: route.bundleID, displayName: route.displayName,
                     size: 44, running: route.isRunning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(route.displayName)
                    .font(.system(size: nameSize, weight: route.isRunning ? .semibold : .regular))
                    .tracking(-0.2)
                    .lineLimit(1)
                    .foregroundStyle(route.isRunning ? WarmSignal.label : WarmSignal.label2)

                HStack(spacing: 8) {
                    destinationPill
                    if !route.isRunning {
                        Text("Not running")
                            .microLabel()
                            .foregroundStyle(WarmSignal.label3)
                    }
                }
            }

            Spacer(minLength: 8)

            readout
        }
        .padding(.horizontal, WarmSignal.rowGutter)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        // EVERY TINT IS A BACKGROUND, bottom-up: wash closest to content (the
        // row's words sit ON it), instrument in the middle, drag tint
        // furthest back — the same order and the same discipline
        // `DeviceRowView.faderRow` uses for its own three layers.
        .background(alignment: .leading) { wash }
        .background { instrument }
        .background(dragTint)
        // The reveal: instrument arrives over 0.18s, leaves over 0.14s — out
        // faster than in, `DeviceRowView`'s timing verbatim. Reduce Motion
        // drops straight to the end state.
        .animation(reduceMotion ? nil : .easeOut(duration: dragging ? 0.18 : 0.14), value: dragging)
        .clipShape(RoundedRectangle(cornerRadius: WarmSignal.Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .gesture(HorizontalDragGesture { handle($0) })
        .sensoryFeedback(trigger: rail) { _, new in new == nil ? nil : .impact(weight: .light) }
        // The dial's detents, at a fraction of the rails' strength — same
        // family, same rule as `DeviceRowView`'s. No selection tick: this
        // row has no tap to confirm.
        .sensoryFeedback(.impact(weight: .light, intensity: WarmSignal.FaderDetents.intensity),
                         trigger: detents.ticks)
        // ONE element. The `Menu` above sits inside this ignored subtree —
        // VoiceOver never reaches it directly, so the named actions below
        // ARE its spoken surface. Don't "fix" the menu into a second
        // element: a sighted tap and a VoiceOver action already reach the
        // same three calls (`setAppDestination` ×3, `removeAppRoute`).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(route.displayName)
        .accessibilityValue(Self.spokenValue(for: route, displayVolume: displayVolume, devices: availableDevices))
        .accessibilityAdjustableAction { direction in
            let next = min(100, max(0, displayVolume + (direction == .increment ? 5 : -5)))
            session.setAppVolume(bundleID: route.bundleID, volume: next, isFinal: true)
        }
        .accessibilityActions {
            Button("No Redirect") {
                session.setAppDestination(bundleID: route.bundleID, kind: "noRedirect", deviceID: nil)
            }
            Button("This Mac") {
                session.setAppDestination(bundleID: route.bundleID, kind: "currentDevice", deviceID: nil)
            }
            ForEach(availableDevices, id: \.id) { device in
                Button(device.name) {
                    session.setAppDestination(bundleID: route.bundleID, kind: "device", deviceID: device.id)
                }
            }
            Button("Stop Routing", role: .destructive) {
                session.removeAppRoute(bundleID: route.bundleID)
            }
        }
    }

    /// 74, not Speakers' 68: the glyph is the same 44pt, but this row's
    /// two-line text stack (name + destination sub-line) needs more air than
    /// a device row's single sub-label does.
    private static let rowHeight: CGFloat = 74

    // MARK: - Backgrounds

    /// No touch-down flash (see the type doc comment) — only the drag tint,
    /// and only once the finger has actually committed horizontally.
    private var dragTint: Color {
        dragging ? WarmSignal.gold.opacity(0.06) : .clear
    }

    /// Mid-drag, on a running app: the row tints its own untouched
    /// remainder, `DeviceRowView.instrument`'s trick verbatim — nothing new
    /// appears, the row's own width divides in two. Never on a not-running
    /// row: the drag still moves the readout, but the row doesn't pretend to
    /// be live.
    @ViewBuilder
    private var instrument: some View {
        if route.isRunning && dragging {
            HStack(spacing: 0) {
                Color.clear.frame(width: max(0, volumeFraction * rowWidth))
                WarmSignal.pill.opacity(0.5)
            }
            .transition(.opacity)
        }
    }

    /// The live signal, flat — `DeviceRowView.level`'s rule verbatim: never a
    /// partial fill, because the readout already carries the value and a
    /// second graded fill would say it twice, one of them wrong mid-drag.
    @ViewBuilder
    private var wash: some View {
        if route.isRunning {
            Rectangle().fill(WarmSignal.gold.opacity(0.05))
        }
    }

    // MARK: - Destination pill

    /// The row's one tap target: a `Menu` with a drawn label, the same shape
    /// `MainOutPicker` uses — never `Picker(.menu)`, whose UIKit-drawn label
    /// ignores `.lineLimit` and would take its width from the state word
    /// beside it instead of truncating itself.
    private var destinationPill: some View {
        Menu {
            Button {
                session.setAppDestination(bundleID: route.bundleID, kind: "noRedirect", deviceID: nil)
            } label: {
                destinationEntry("No Redirect", isCurrent: route.destinationKind == "noRedirect")
            }
            Button {
                session.setAppDestination(bundleID: route.bundleID, kind: "currentDevice", deviceID: nil)
            } label: {
                destinationEntry("This Mac", isCurrent: route.destinationKind == "currentDevice")
            }
            if !availableDevices.isEmpty {
                Divider()
                ForEach(availableDevices, id: \.id) { device in
                    Button {
                        session.setAppDestination(bundleID: route.bundleID, kind: "device", deviceID: device.id)
                    } label: {
                        destinationEntry(device.name,
                                         isCurrent: route.destinationKind == "device" && route.deviceID == device.id)
                    }
                }
            }
            Divider()
            // Replaces the incumbent row's List swipe-to-delete: horizontal
            // swipes are the fader now, so removal moves here.
            Button(role: .destructive) {
                session.removeAppRoute(bundleID: route.bundleID)
            } label: {
                Label("Stop Routing", systemImage: "xmark.circle")
            }
        } label: {
            HStack(spacing: 4) {
                Text(Self.destinationTitle(for: route, devices: availableDevices))
                    .microLabel()
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(WarmSignal.label3)
            }
            .foregroundStyle(Self.isRedirectedToDevice(route) ? WarmSignal.goldText : WarmSignal.label2)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // `well` + `rim`, the recessed-control recipe the mute button and
            // both fader tracks already wear — NOT `pill`, which was never a
            // text backdrop anywhere in the app and fails as one: `label2` on
            // light `pill` measures 3.57:1 and `goldText` 3.71:1, both under
            // the 4.5:1 text floor. On `well` the same inks measure 4.54:1 /
            // 6.22:1 and 4.72:1 / 10.51:1 (light / dark) — `well` is
            // goldText's documented tightest surface, and it clears.
            .background(Capsule().fill(WarmSignal.well))
            .overlay(Capsule().strokeBorder(WarmSignal.rim, lineWidth: 0.5))
        }
        .hittable(drawn: 20)
    }

    /// A menu row: the current destination carries the checkmark a menu of
    /// choices owes the reader — `MainOutPicker.entry`'s pattern.
    @ViewBuilder
    private func destinationEntry(_ title: String, isCurrent: Bool) -> some View {
        if isCurrent {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - Readout

    /// Always visible, running or not: the level is the one value this row
    /// controls, and it applies whenever the app plays — a not-running row's
    /// number is a stored preset, true but not live, so it dims to `label3`
    /// rather than disappearing.
    private var readout: some View {
        Text(String(displayVolume))
            .readout(dragging ? 22 : 16)
            .foregroundStyle(route.isRunning ? WarmSignal.goldText : WarmSignal.label3)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dragging)
    }

    // MARK: - Gesture

    /// ``DeviceRowView/handle(_:)``'s shape, minus its tap, its pressed
    /// flash and its disabled/refusal branch: this row has no tap action at
    /// all, and a volume write here is accepted regardless of `isRunning`, so
    /// this drag has nothing to gate.
    private func handle(_ phase: HorizontalDragGesture.Phase) {
        switch phase {
        case .down, .tapped:
            break
        case .began(let width):
            dragging = true
            dragStartVolume = route.volume
            detents.begin(at: route.volume)
            track(width)
        case .changed(let width):
            track(width)
        case .ended:
            defer { reset() }
            session.setAppVolume(bundleID: route.bundleID,
                                 volume: Int((localVolume ?? Double(route.volume)).rounded()),
                                 isFinal: true)
            localVolume = nil   // clear on release — DeviceRowView's policy, not MainOutRow's hold
        case .cancelled:
            // The ScrollView has it now — or the system took the touch
            // mid-drag, in which case the echo is a level nobody confirmed.
            localVolume = nil
            reset()
        }
    }

    private func track(_ width: CGFloat) {
        guard let start = dragStartVolume else { return }
        let v = WarmSignal.faderValue(start: start, translationWidth: width, trackWidth: rowWidth)
        localVolume = Double(v)
        detents.advance(to: v)
        session.setAppVolume(bundleID: route.bundleID, volume: v, isFinal: false)
    }

    private func reset() {
        dragging = false
        dragStartVolume = nil
    }
}

#Preview("Routed, running") {
    ScrollView {
        LazyVStack(spacing: 2) {
            AppRouteRowView(
                route: AppRouteState(bundleID: "com.demo.music", displayName: "Demo Music",
                                      destinationKind: "device", deviceID: "demo-homepod",
                                      volume: 72, isRunning: true),
                availableDevices: [
                    DeviceState(id: "demo-homepod", name: "Kitchen HomePod", kind: "homePod",
                                iconSymbolName: "homepod.fill", isAvailable: true, supportsAirPlay2: true,
                                isLocalDevice: false, volume: 40, isMuted: false, isSelected: true,
                                isMainOutMember: true, connection: .init(state: "connected")),
                ],
                session: DemoMacSession()
            )
        }
        .padding(.horizontal, 14)
    }
    .background(WarmSignal.canvasGradient)
}

#Preview("Not running") {
    ScrollView {
        LazyVStack(spacing: 2) {
            AppRouteRowView(
                route: AppRouteState(bundleID: "com.demo.browser", displayName: "Demo Browser",
                                      destinationKind: "noRedirect", volume: 100, isRunning: false),
                availableDevices: [],
                session: DemoMacSession()
            )
        }
        .padding(.horizontal, 14)
    }
    .background(WarmSignal.canvasGradient)
}
