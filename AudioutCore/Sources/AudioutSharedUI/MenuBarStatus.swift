import AudioutCore

/// Pure decision logic for the menu-bar status item's idle-vs-streaming
/// distinction. AppKit-free by design (no `NSImage`/`NSColor`/`NSStatusItem`)
/// so it's unit-testable without a real status bar. `StatusItemIcon.make`
/// (same target) turns `symbolName` into the actual `NSImage` — always a
/// template image, per the macOS menu-bar-status-item convention —
/// and `AudioutApp.StatusItemController` is the only caller of that.
///
/// "Actively streaming" means ANY audio is currently leaving the Mac by ANY
/// mechanism — err on the side of "anything counts," not just the main
/// output set (a resolved design question): either the main Audio Out
/// (Selected Devices / Main Out) has at least one device actually
/// `.connected`, OR at least one per-app route currently has a live/bound
/// stream (`BackendEvent.routedApps`'s CONFIRMED map — see
/// `PopoverController.applyRoutedApps`'s doc for why this is the live signal,
/// distinct from routing *intent*).
public enum MenuBarStatus {

    /// `true` iff at least one device is actually `.connected` (the main
    /// Audio Out / Main Out signal) or at least one entry in
    /// `liveRoutedAppNames` is non-empty (the per-app redirect signal).
    /// `liveRoutedAppNames` is keyed by device id, mirroring
    /// `BackendEvent.routedApps(deviceID:appNames:)` / `PopoverController`'s
    /// own `liveRoutedAppNames` map — an empty `appNames` for a device means
    /// nothing is confirmed streaming there, so entries with an empty array
    /// (if any survive into the caller's map) don't count.
    public static func isStreaming(
        devices: [Device],
        liveRoutedAppNames: [String: [String]]
    ) -> Bool {
        if devices.contains(where: { $0.connectionState == .connected }) {
            return true
        }
        return liveRoutedAppNames.values.contains { !$0.isEmpty }
    }

    /// The base SF Symbol name for the given streaming state: the OUTLINE
    /// variant while idle/passthrough (`speaker.wave.3`), the FILLED variant
    /// while actively streaming (`speaker.wave.3.fill`). Callers layer their
    /// own `variableValue`/color/template-vs-palette rendering on top.
    public static func symbolName(isStreaming: Bool) -> String {
        isStreaming ? "speaker.wave.3.fill" : "speaker.wave.3"
    }
}
