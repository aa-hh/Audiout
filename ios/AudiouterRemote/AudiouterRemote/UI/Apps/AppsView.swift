// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// Tab 2: per-app routing, drawn in the same row-as-fader grammar Speakers
/// uses — each row is its own volume drag, and the destination pill is the
/// row's one tap target (``AppRouteRowView``). This view owns no routing
/// state of its own, same as ``SpeakersView``: every value it renders comes
/// straight from `session.snapshot`, and the sheet that adds a route
/// (``AddAppSheet``) is the only other surface this tab presents.
///
/// Renders a "connecting" placeholder before the first snapshot arrives —
/// this view never invents state the Mac hasn't sent yet.
struct AppsView: View {
    let session: any MacSessionProtocol
    @State private var isPresentingAddSheet = false

    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 26
    @ScaledMetric(relativeTo: .subheadline) private var addIconSize: CGFloat = 15

    /// A route that starts or stops re-sorts (``AppRouteRowView/sortedForDisplay(_:)``)
    /// and the row travels rather than teleporting — the one thing this
    /// screen animates, off the same tempo Speakers drives its own row
    /// travel and section collapse from, so the app has a single motion
    /// rather than one per screen.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WarmSignal.canvasGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if session.snapshot != nil { followNote }
                content
            }
        }
        .toastOverlay(session.toasts)
        .sheet(isPresented: $isPresentingAddSheet) {
            AddAppSheet(session: session)
        }
    }

    // MARK: Header

    /// Mirrors `SpeakersView.header`: the screen draws its own header, so
    /// there's no `NavigationStack` or navigation title here — the sheet
    /// presents fine without one.
    private var header: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Text("Apps")
                .font(.system(size: titleSize, weight: .bold))
                .tracking(-0.7)
                .foregroundStyle(WarmSignal.label)

            Spacer(minLength: 8)

            addButton
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var canAddApp: Bool { !(session.snapshot?.addableApps.isEmpty ?? true) }

    /// A disc in the deck's own glass recipe. ``GlassPanel`` only ever draws
    /// a `RoundedRectangle`, so the fill/material/edge stack is repeated here
    /// by hand for a `Circle` instead — circular because the control is a
    /// disc, and a disc is in the world's shape set alongside the capsule.
    private var addButton: some View {
        Button {
            isPresentingAddSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: addIconSize, weight: .semibold))
                .foregroundStyle(canAddApp ? WarmSignal.goldText : WarmSignal.label3)
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(WarmSignal.glass)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .overlay(Circle().strokeBorder(WarmSignal.glassEdge, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .hittable(drawn: 34)
        .disabled(!canAddApp)
        .accessibilityLabel("Add App")
    }

    // MARK: Follow note

    /// Where an unrouted app's audio actually goes — the one line of context
    /// the list itself can't carry (a row with no redirect says "No
    /// Redirect", never "Main Out"). A dot and words, no container: a glass
    /// pill here would promise a press that does nothing, the same reasoning
    /// `SpeakersView.statusPill` is built on.
    private var followNote: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(WarmSignal.gold)
                .frame(width: 6, height: 6)

            (Text("Apps without a route follow ").foregroundStyle(WarmSignal.label2)
                + Text("Main Out").foregroundStyle(WarmSignal.label))
                .font(.footnote)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let snapshot = session.snapshot {
            if snapshot.appRoutes.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No Routed Apps",
                    systemImage: "square.grid.2x2",
                    description: Text("Add an app to send its audio to a specific speaker.")
                )
                Spacer()
            } else {
                // Running first, silent to the bottom (`sortedForDisplay`).
                // Starting or stopping an app moves its row between the two
                // halves, so the value the `ForEach` animates against is the
                // sorted order itself — the row travels rather than
                // teleporting to its new spot.
                let sorted = AppRouteRowView.sortedForDisplay(snapshot.appRoutes)
                ScrollView {
                    // LazyVStack, not List: every row draws its own
                    // horizontal drag, which List's cell chrome and swipe
                    // handling would fight — the same reasoning
                    // SpeakerConsole is built on.
                    LazyVStack(spacing: 2) {
                        ForEach(sorted, id: \.bundleID) { route in
                            AppRouteRowView(route: route,
                                            availableDevices: redirectableDevices(in: snapshot),
                                            session: session)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                    .animation(motion, value: sorted.map(\.bundleID))
                }
                .scrollIndicators(.hidden)
            }
        } else {
            Spacer()
            ContentUnavailableView(
                "Apps",
                systemImage: "square.grid.2x2",
                description: Text("Connecting…")
            )
            Spacer()
        }
    }

    /// The one screen tempo — same constants `SpeakerConsole.motion` uses,
    /// so a row's travel here and a device row's travel on the other tab
    /// read as the same app rather than two.
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.25)
    }

    /// Speakers offerable as a redirect target: available, AirPlay-capable,
    /// non-local, and not carrying the Main Out — the popover applies the
    /// same one-role-per-speaker skip on top of
    /// `PopoverController.availableAirPlayDestinations` (a Main Out member is
    /// never offered as a redirect target), so the phone never offers a
    /// destination the Mac itself wouldn't. The Mac's dispatcher also refuses
    /// it server-side; this filter keeps the refusal from ever being needed.
    private func redirectableDevices(in snapshot: Snapshot) -> [DeviceState] {
        snapshot.devices.filter {
            !$0.isLocalDevice && $0.isAvailable && $0.supportsAirPlay2 && !$0.isMainOutMember
        }
    }
}

#Preview("Routed apps") {
    AppsView(session: DemoMacSession())
}

// razor: no not-running-app preview. `DemoMacSession.addAppRoute` and its
// seeded fixtures both always land on `isRunning: true` (no public seam
// makes a stopped route reachable), so per the spec's own "if reachable"
// condition this preview is skipped rather than adding a session stand-in
// here to force it.
