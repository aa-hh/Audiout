// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One app's visual identity in a list row. Real macOS app icons aren't
/// reachable from iOS, so the glyph story is: a recognised app gets a fitting
/// SF Symbol on a neutral tile; anything unrecognised falls back to a
/// coloured rounded tile carrying its first letter.
///
/// razor: `symbolTable` is a short, flat category table (one entry per
/// well-known app or family), not a per-app icon database — extend it when a
/// specific app deserves its own line; every other app already works via the
/// initial-tile fallback, so there is no ceiling on which apps are usable,
/// only on which ones get a nicer glyph.
struct AppGlyph: View {
    let bundleID: String
    let displayName: String
    var size: CGFloat = 36

    private var cornerRadius: CGFloat { size * 0.28 }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fillStyle)
            .frame(width: size, height: size)
            .overlay { glyphContent }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displayName)
    }

    @ViewBuilder
    private var glyphContent: some View {
        if let symbol = Self.symbolName(bundleID: bundleID, displayName: displayName) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            Text(Self.initial(for: displayName))
                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var fillStyle: AnyShapeStyle {
        Self.symbolName(bundleID: bundleID, displayName: displayName) == nil
            ? AnyShapeStyle(Self.tileColor(for: displayName))
            : AnyShapeStyle(Color(.secondarySystemBackground))
    }

    // MARK: - Symbol mapping

    /// `(substring to match, SF Symbol)` — checked case-insensitively against
    /// `bundleID` first (stable identity), then `displayName` (a user-visible
    /// name a person could rename, but still useful for apps this table
    /// doesn't know by bundle id). First match wins.
    private static let symbolTable: [(match: String, symbol: String)] = [
        // Music
        ("music", "music.note"),
        ("spotify", "music.note"),
        ("tidal", "music.note"),
        ("soundcloud", "music.note"),
        // Browsers
        ("safari", "globe"),
        ("chrome", "globe"),
        ("firefox", "globe"),
        ("arc", "globe"),
        ("edge", "globe"),
        // Video calls
        ("zoom", "video"),
        ("facetime", "video"),
        ("teams", "video"),
        ("meet", "video"),
        ("webex", "video"),
        // Media players
        ("vlc", "play.rectangle"),
        ("quicktime", "play.rectangle"),
        ("iina", "play.rectangle"),
        // Games
        ("steam", "gamecontroller"),
        ("game", "gamecontroller"),
        // Terminals / dev
        ("terminal", "terminal"),
        ("iterm", "terminal"),
        ("xcode", "terminal"),
    ]

    static func symbolName(bundleID: String, displayName: String) -> String? {
        let id = bundleID.lowercased()
        if let hit = symbolTable.first(where: { id.contains($0.match) }) { return hit.symbol }
        let name = displayName.lowercased()
        if let hit = symbolTable.first(where: { name.contains($0.match) }) { return hit.symbol }
        return nil
    }

    // MARK: - Fallback tile

    static func initial(for displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    /// Deterministic across launches — hashed from the name, not random or
    /// clock-based, so the same app always lands on the same hue and two
    /// different names usually land on distinguishably different ones.
    static func tileColor(for displayName: String) -> Color {
        var hash: UInt64 = 5381
        for scalar in displayName.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }
}

#Preview {
    HStack(spacing: 12) {
        AppGlyph(bundleID: "com.apple.Music", displayName: "Music")
        AppGlyph(bundleID: "com.apple.Safari", displayName: "Safari")
        AppGlyph(bundleID: "us.zoom.xos", displayName: "Zoom")
        AppGlyph(bundleID: "org.videolan.vlc", displayName: "VLC")
        AppGlyph(bundleID: "com.example.mystery", displayName: "Mystery Radio")
        AppGlyph(bundleID: "com.example.other", displayName: "Another App")
    }
    .padding()
}
