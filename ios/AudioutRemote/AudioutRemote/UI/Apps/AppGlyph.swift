// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One app's visual identity in a list row. Prefers a real app icon from the
/// icon store (fetched from the Mac); falls back to a recognised app's fitting
/// SF Symbol; ultimately falls back to the app's first letter in the screen's
/// micro voice. The symbol and initial both sit on the same `raised` tile —
/// Warm Signal's palette is gold plus neutrals plus fail/caution, nothing else,
/// so there is no hue left to spend on a per-app identity color; only the
/// content and its tint vary. Real icons display edge-to-edge with rounded
/// corners, bypassing tile and tint.
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
    /// Whether the app this glyph identifies is currently making sound — the
    /// same signal `AppRouteRowView`'s name and readout dim on. Defaulted
    /// `true` so a call site with no running/not-running notion of its own
    /// (`AddAppSheet`'s addable-app rows, this file's own `#Preview`) keeps
    /// the brighter tint rather than reading as silenced.
    var running: Bool = true

    /// Icon store lookup. Must be optional: the non-optional form traps at
    /// runtime when nothing is injected, which every `#Preview` in this file,
    /// AddAppSheet's previews, AppRouteRowView's previews, and any test render
    /// would hit. SwiftUI's @Environment doesn't gracefully handle injection
    /// in preview/test contexts, so we accept nil and render the fallback.
    @Environment(AppIconStore.self) private var iconStore: AppIconStore?

    private var contentTint: Color { running ? WarmSignal.label2 : WarmSignal.label3 }

    var body: some View {
        if let img = iconStore?.image(for: bundleID) {
            Image(uiImage: img)
                .resizable()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: WarmSignal.Radius.control, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(displayName)
        } else {
            RoundedRectangle(cornerRadius: WarmSignal.Radius.control, style: .continuous)
                .fill(WarmSignal.raised)
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: WarmSignal.Radius.control, style: .continuous)
                        .strokeBorder(WarmSignal.hairline, lineWidth: 0.5)
                }
                .overlay { glyphContent }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(displayName)
        }
    }

    @ViewBuilder
    private var glyphContent: some View {
        if let symbol = Self.symbolName(bundleID: bundleID, displayName: displayName) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(contentTint)
        } else {
            Text(Self.initial(for: displayName))
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(contentTint)
        }
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

    // nonisolated, like AppRouteRowView's statics: pure helpers the tests
    // call from Swift Testing's background threads.
    nonisolated static func symbolName(bundleID: String, displayName: String) -> String? {
        let id = bundleID.lowercased()
        if let hit = symbolTable.first(where: { id.contains($0.match) }) { return hit.symbol }
        let name = displayName.lowercased()
        if let hit = symbolTable.first(where: { name.contains($0.match) }) { return hit.symbol }
        return nil
    }

    // MARK: - Fallback initial

    nonisolated static func initial(for displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

#Preview {
    HStack(spacing: 12) {
        AppGlyph(bundleID: "com.apple.Music", displayName: "Music")
        AppGlyph(bundleID: "com.apple.Safari", displayName: "Safari")
        AppGlyph(bundleID: "us.zoom.xos", displayName: "Zoom")
        AppGlyph(bundleID: "org.videolan.vlc", displayName: "VLC")
        AppGlyph(bundleID: "com.example.mystery", displayName: "Mystery Radio")
        AppGlyph(bundleID: "com.example.other", displayName: "Another App", running: false)
    }
    .padding()
    .background(WarmSignal.canvasGradient)
}
