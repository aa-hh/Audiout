// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import ApplicationServices
import AudiouterCore

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

    /// A macOS aux-control ("NX") key code. Values from `IOKit/hidsystem/ev_keymap.h`
    /// (`NX_KEYTYPE_*`). Only the transport subset we drive is modeled. `fileprivate`
    /// so the `RemoteTransportCommand` mapping below (same file) can name it.
    fileprivate enum AuxKey: Int32 {
        case playPause = 16 // NX_KEYTYPE_PLAY
        case next = 17      // NX_KEYTYPE_NEXT
        case previous = 18  // NX_KEYTYPE_PREVIOUS
    }

    /// True once we've shown the Accessibility prompt this launch, so a burst of
    /// speaker presses can't stack system dialogs.
    private var didRequestAccessibility = false

    /// Handle one transport command from a speaker: fire the media key, and if we
    /// aren't trusted yet, ask for Accessibility (once).
    func handle(_ command: RemoteTransportCommand) {
        post(command.auxKey)

        // Posting reaches other apps only when we're trusted; if we aren't, the
        // press just now did nothing — surface the one-time prompt so the NEXT
        // press works. `AXIsProcessTrusted()` never prompts (safe to poll here).
        if !AXIsProcessTrusted() {
            requestAccessibilityOnce()
        }
    }

    // MARK: - Posting

    /// Synthesize a press (down+up) of an aux media key and post it to the HID
    /// event tap, the same path a hardware media key travels. No-ops harmlessly
    /// (the OS drops it) when we lack Accessibility trust.
    private func post(_ key: AuxKey) {
        postAux(key.rawValue, keyDown: true)
        postAux(key.rawValue, keyDown: false)
    }

    private func postAux(_ keyCode: Int32, keyDown: Bool) {
        // A systemDefined/NSEvent with subtype 8 (NX_SUBTYPE_AUX_CONTROL_BUTTONS)
        // is how the media keys are represented: the key code sits in the high 16
        // bits of data1 and the key state (0xA down / 0xB up) in the next byte, and
        // the same state is mirrored in the modifier flags. This is the long-
        // established recipe for driving Now Playing from a menu-bar app.
        let state = keyDown ? 0xA : 0xB
        let data1 = Int((keyCode << 16) | Int32(state << 8))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(state << 8)) // 0xA00 / 0xB00

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }

        event.cgEvent?.post(tap: .cghidEventTap)
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

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        let message = "[Audiouter] Speaker transport keys need Accessibility access — prompted. "
            + "Grant it in System Settings › Privacy & Security › Accessibility, then "
            + "the speaker's play/pause/next/previous will drive your Mac's playback.\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private extension RemoteTransportCommand {
    var auxKey: MediaKeyController.AuxKey {
        switch self {
        case .playPause: return .playPause
        case .next:      return .next
        case .previous:  return .previous
        }
    }
}
