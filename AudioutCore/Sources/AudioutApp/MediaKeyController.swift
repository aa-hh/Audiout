// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

/// Turns a transport command a user pressed ON A SPEAKER (surfaced by
/// ``NativeBackend`` as `BackendEvent.remoteTransport`) into a Mac system media
/// key, so the frontmost player — Music, Spotify, a browser tab, anything that
/// listens for the hardware media keys — responds. That is the whole point of
/// the speaker's transport buttons: pause on the Sonos pauses the actual song.
///
/// WHY MEDIA KEYS (not AppleScript / a private framework): the app streams the
/// Mac's *whole* system audio and has no track of its own to pause. Synthesizing
/// the standard aux media keys is the one app-agnostic way to reach whichever
/// player is currently making sound, and it is exactly what a hardware keyboard's
/// play/next/prev keys do.
///
/// PERMISSION: posting an event into the HID stream so it reaches other apps
/// requires this app to be trusted for **Accessibility** (System Settings ›
/// Privacy & Security › Accessibility). Until it is, `post` silently no-ops; the
/// first time we need it we ask, once, with the system's standard prompt.
@MainActor
final class MediaKeyController {

    /// True once we've shown the Accessibility prompt this launch, so a burst of
    /// speaker presses can't stack system dialogs.
    private var didRequestAccessibility = false

    /// The Accessibility read/prompt seam. The same ``RemoteControlPriming`` the
    /// onboarding flow uses — injected (not a direct `AXIsProcessTrusted()` call)
    /// so `AIRPLAY_PERMISSIONS=granted|denied` reaches this path too: a simulated
    /// seam never springs a real system dialog during an automated run. Defaults
    /// to the production primer, so the ordinary launch is unchanged.
    private let remoteControl: RemoteControlPriming

    init(remoteControl: RemoteControlPriming = RemoteControlPrimerFactory.makeDefault()) {
        self.remoteControl = remoteControl
    }

    /// Handle one transport command from a speaker: fire the media key, and if we
    /// aren't trusted yet, ask for Accessibility (once).
    func handle(_ command: RemoteTransportCommand) {
        command.auxKey.post()

        // Posting reaches other apps only when we're trusted; if we aren't, the
        // press just now did nothing — surface the one-time prompt so the NEXT
        // press works. `isTrusted()` (AXIsProcessTrusted) never prompts.
        if !remoteControl.isTrusted() {
            requestAccessibilityOnce()
        }
    }

    // MARK: - Accessibility permission

    /// Ask the OS for Accessibility access — once per launch. `…WithOptions`
    /// with the prompt key both registers this app in the Accessibility list and
    /// shows the standard "…would like to control this computer" dialog whose
    /// button deep-links to the right Settings pane; the user flips the switch
    /// there. We add a plain log line so a gated test can see it happen.
    private func requestAccessibilityOnce() {
        guard !didRequestAccessibility else { return }
        didRequestAccessibility = true

        // `prime()` is the `AXIsProcessTrustedWithOptions([prompt:true])` call —
        // through the seam so a simulated primer stays silent.
        remoteControl.prime()

        let message = "[Audiout] Speaker transport keys need Accessibility access — prompted. "
            + "Grant it in System Settings › Privacy & Security › Accessibility, then "
            + "the speaker's play/pause/next/previous will drive your Mac's playback.\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private extension RemoteTransportCommand {
    var auxKey: SystemAuxKey {
        switch self {
        case .playPause: return .playPause
        case .next:      return .next
        case .previous:  return .previous
        }
    }
}
