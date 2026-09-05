// Copyright (c) 2026 ahh. All rights reserved.

import Foundation
import Testing
@testable import AudioutPopoverUI
@testable import AudioutCore

/// The phone hand-copies Mac-owned copy, and nothing but this keeps the two in
/// step:
///
/// - `StatusBanners`' sentences. The Mac sends a flag, not the text, so the
///   phone draws its own copy of what `PopoverController` shows.
/// - `DemoMacSession`'s refusal reasons, standing in for the ones
///   `CompanionCommandDispatcher` sends when a real Mac is attached.
///
/// Both drifted once already: this Mac dropped its em dashes and the phone's
/// copies kept them, so one banner read two ways on two screens.
///
/// ``mirroredOnThePhone`` holds what the phone was last told this Mac says.
/// Changing a banner here fails this test, which is the point: the failure is
/// the reminder to change audiout-remote too. audiout-remote carries the
/// mirror-image test over its own copies, so a one-sided edit there fails
/// there. Neither test reads the other repo — the remote test runner syncs
/// this repo alone, so a cross-repo read would simply never run.
@Suite struct CompanionCopyTripwireTests {

    /// Every Mac string the phone keeps its own copy of. Changing copy here is
    /// meant to be a stop: update audiout-remote to match, then update this.
    static let mirroredOnThePhone = [
        "Speakers unreachable. Playing on your Mac. Will resume automatically.",
        "Your Mac's system output is also set to AirPlay. Audio may play twice. Switch it back to avoid an echo.",
    ]

    @Test func mirroredBannersStillSayWhatThePhoneWasToldTheySay() {
        #expect(PopoverController.localFallbackBannerText == Self.mirroredOnThePhone[0], """
            This banner changed. The phone hardcodes its own copy of it in
            StatusBanners, so change audiout-remote to match, then update
            `mirroredOnThePhone` above.
            """)
        #expect(PopoverController.systemAirPlayNoteText == Self.mirroredOnThePhone[1], """
            This banner changed. The phone hardcodes its own copy of it in
            StatusBanners, so change audiout-remote to match, then update
            `mirroredOnThePhone` above.
            """)
    }
}
