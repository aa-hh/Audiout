// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Locale-aware volume percent formatting (hardening P3) — the row/slider `%`
/// readouts and their spoken VoiceOver equivalents used to interpolate a bare
/// `Int` with a hardcoded `%`/`" percent"`, which never localizes digit
/// rendering. Mirrors `AudioSettingsViewController`'s cached-`NumberFormatter`
/// pattern (reference only — that file is untouched).
public enum VolumePercent {
    /// Formatter for the visual `%` readout: `.percent` style with
    /// `multiplier = 1` so `64` renders as "64%" (with locale digit
    /// substitution and percent placement), not `6400%`.
    private static let displayFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.multiplier = 1
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// Formatter for the spoken VoiceOver value's digits — plain decimal, the
    /// word "percent" is appended separately (the spoken word stays English;
    /// this fixes digit rendering only).
    private static let spokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// The visual `%` readout for `value` (e.g. "64%"), locale-aware.
    public static func label(_ value: Int) -> String {
        displayFormatter.string(from: NSNumber(value: value)) ?? "\(value)%"
    }

    /// The spoken VoiceOver value for `value` (e.g. "64 percent"), locale-aware
    /// digits with the English word "percent".
    public static func spoken(_ value: Int) -> String {
        "\(spokenFormatter.string(from: NSNumber(value: value)) ?? "\(value)") percent"
    }
}
