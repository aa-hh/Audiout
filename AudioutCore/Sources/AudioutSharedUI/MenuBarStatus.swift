import AudioutCore

/// Pure decision logic for the menu-bar status item's THREE-state glance:
/// idle, streaming, failure. AppKit-free by design (no
/// `NSImage`/`NSColor`/`NSStatusItem`) so it's unit-testable without a real
/// status bar. `StatusItemIcon.make` (same target) turns `symbolName(for:)`
/// into the actual `NSImage` — always a template image, per the macOS
/// menu-bar-status-item convention — and `AudioutApp.StatusItemController`
/// is the only caller of that.
///
/// The three states, and the glance rule behind each:
/// - **failure** — a device the user has SELECTED is `.failed`. A broken
///   speaker must never look like a paused one, so failure outranks
///   streaming and renders its own badge symbol. Deselecting a broken
///   speaker clears it: an unselected failed device is no longer something
///   the user asked for, so it carries no badge.
/// - **streaming** — ANY audio is currently leaving the Mac by ANY
///   mechanism; err on the side of "anything counts," not just the main
///   output set (a resolved design question): either the main Audio Out
///   (Selected Devices / Main Out) has at least one device actually
///   `.connected`, OR at least one per-app route currently has a live/bound
///   stream (`BackendEvent.routedApps`'s CONFIRMED map — see
///   `PopoverController.applyRoutedApps`'s doc for why this is the live
///   signal, distinct from routing *intent*).
/// - **idle** — everything else (passthrough).
///
/// Mute is NOT a state here: it drains the volume arc (via
/// `PopoverController.statusMasterVolume`) and is spoken by
/// `accessibilityDescription(state:masterVolumePercent:isMuted:)`, which is
/// what keeps the closed-panel glance honest without a fourth symbol.
public enum MenuBarStatus {

    /// What the menu-bar glyph is saying right now. Failure outranks
    /// streaming outranks idle — see the type doc for each rule.
    public enum State: Equatable {
        case idle
        case streaming
        case failure
    }

    /// The three-state glance decision. `.failure` iff at least one device
    /// the user has SELECTED is in `.failed` (a broken speaker must not read
    /// as a paused one, and deselecting it clears the badge); otherwise
    /// `.streaming` iff ``isStreaming(devices:liveRoutedAppNames:)``;
    /// otherwise `.idle`.
    public static func state(
        devices: [Device],
        liveRoutedAppNames: [String: [String]]
    ) -> State {
        let hasSelectedFailure = devices.contains { device in
            guard device.isSelected else { return false }
            if case .failed = device.connectionState { return true }
            return false
        }
        if hasSelectedFailure { return .failure }
        return isStreaming(devices: devices, liveRoutedAppNames: liveRoutedAppNames) ? .streaming : .idle
    }

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

    /// The base SF Symbol name for the given state: the OUTLINE variant while
    /// idle/passthrough (`speaker.wave.3`), the FILLED variant while actively
    /// streaming (`speaker.wave.3.fill`), and the BADGED variant when a
    /// selected speaker has failed (`speaker.badge.exclamationmark`). Callers
    /// layer their own `variableValue`/template rendering on top.
    public static func symbolName(for state: State) -> String {
        switch state {
        case .idle: return "speaker.wave.3"
        case .streaming: return "speaker.wave.3.fill"
        case .failure: return "speaker.badge.exclamationmark"
        }
    }

    /// What VoiceOver reads for the status glyph. The symbol shape carries
    /// state and the arc carries level, and neither is spoken by itself — so
    /// this composes the same facts in words: the failure, or the level plus
    /// mute plus whether audio is actually leaving the Mac.
    ///
    /// A failure is the whole message (level and mute are beside the point
    /// when the speaker the user picked isn't working).
    public static func accessibilityDescription(
        state: State,
        masterVolumePercent: Int,
        isMuted: Bool
    ) -> String {
        if state == .failure { return "Audiout — speaker connection failed" }
        if isMuted {
            return state == .streaming ? "Audiout — muted, streaming" : "Audiout — muted"
        }
        return state == .streaming
            ? "Audiout — \(masterVolumePercent)%, streaming"
            : "Audiout — \(masterVolumePercent)%"
    }
}
