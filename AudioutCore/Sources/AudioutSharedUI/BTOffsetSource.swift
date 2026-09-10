// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Where the offset a Bluetooth speaker is playing with came from, and the
/// words the Mac says about it (`shape-mac-invites.md` §3.3, ADR 0001).
///
/// The four cases mirror `AudioutProtocol.AlignmentSource`, the wire's own
/// vocabulary — ``wireValue`` is the string it publishes, and
/// `BTOffsetSourceWireTests` pins the two together so a rename in the shared
/// package cannot pass silently. The enum lives here rather than the wire
/// type because this is a UI target: it renders words, and the app layer maps
/// the string to a case on its way in.
public enum BTOffsetSource: String, CaseIterable, Sendable {
    /// A measurement taken after the Mac called the speaker settled.
    case measured
    /// A measurement taken before it settled: applied at once, re-checked
    /// when the clock reads steady.
    case firstPass
    /// The offset this speaker had when last measured, applied again on
    /// reconnect.
    case fromLastTime
    /// Found through the Mac's own paired-click wizard, no microphone.
    case byEar

    /// The wire string `DeviceState.AlignmentState.source` carries.
    public var wireValue: String { rawValue }

    public init?(wireValue: String) { self.init(rawValue: wireValue) }

    /// The sentence appended to the SYNC chip's tooltip and spoken value, so
    /// hover and VoiceOver say where the number came from.
    public var chipSentence: String {
        switch self {
        case .measured: return "Measured with your iPhone."
        case .firstPass: return "First pass. Your iPhone checks again once the speaker has settled."
        case .fromLastTime: return "Timing from last time, applied again when the speaker reconnected."
        case .byEar: return "Aligned by ear on this Mac."
        }
    }

    /// The drawer's caption line — the same sentence cut to its first clause,
    /// except the first pass, whose whole point is the re-check it promises.
    public var drawerCaption: String {
        switch self {
        case .measured: return "Measured with your iPhone"
        case .firstPass: return "First pass. Your iPhone checks again once the speaker has settled."
        case .fromLastTime: return "Timing from last time"
        case .byEar: return "Aligned by ear on this Mac"
        }
    }

    /// What the Mac says when a re-measurement replaced a stored offset that
    /// was out by more than the ADR's tell-the-user line. Session state: it
    /// stands on the drawer's caption line in place of the source until the
    /// drawer next closes, and nothing is written down.
    ///
    /// A note, never a failure — `Tokens.Color.failure` is never a sentence.
    public static func movedNotice(byMs deltaMs: Double) -> String {
        let whole = Int(abs(deltaMs).rounded())
        return "Moved \(whole) ms since last time. That’s more than a reconnect "
            + "usually shifts; measure again if it still sounds off."
    }
}
