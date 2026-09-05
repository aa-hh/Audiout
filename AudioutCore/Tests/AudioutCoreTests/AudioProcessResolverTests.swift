import Testing
@testable import AudioutCore

#if canImport(CoreAudio)
import CoreAudio
#endif

/// Hermetic tests for ``AudioProcessResolver``'s pure resolution logic (T1).
/// Every input is plain data — a `RawAudioProcess` array, a scripted parent-pid
/// map, and a scripted `bundleIDForPID` closure — so the "given raw process
/// data, compute the resolved set" logic runs with no live Core Audio and no
/// `NSRunningApplication`. The HAL-backed `CoreAudioProcessEnumerator` is not
/// exercised here (it needs live Core Audio); the seam exists precisely so this
/// logic is testable without it.
@Suite struct AudioProcessResolverTests {

    private let firefox = "org.mozilla.firefox"
    private let mainPID: pid_t = 100
    private let childPID: pid_t = 200

    /// Convenience over the pure static entry point. Every new-layer seam
    /// (responsibility, executable path, bundle path) defaults to "no answer",
    /// so the pre-existing cases below still exercise exactly the own-bundle and
    /// parent-walk layers they were written for.
    private func resolve(
        bundleID: String,
        processes: [RawAudioProcess],
        parents: [pid_t: pid_t] = [:],
        bundleIDForPID: [pid_t: String] = [:],
        responsible: [pid_t: pid_t] = [:],
        executablePaths: [pid_t: String] = [:],
        bundlePaths: [String: String] = [:],
        maxParentHops: Int = 5
    ) -> Set<AudioProcess> {
        AudioProcessResolver.resolve(
            bundleID: bundleID,
            processes: processes,
            parentPID: { parents[$0] },
            bundleIDForPID: { bundleIDForPID[$0] },
            responsiblePID: { responsible[$0] },
            executablePath: { executablePaths[$0] },
            bundlePathForBundleID: { bundlePaths[$0] },
            maxParentHops: maxParentHops)
    }

    // A bundle's main process alone (it reports its own bundle id).
    @Test func mainProcessOnly() {
        let processes = [
            RawAudioProcess(objectID: 1, pid: mainPID, bundleID: firefox)
        ]
        let resolved = resolve(bundleID: firefox, processes: processes)
        #expect(resolved == [AudioProcess(objectID: 1, pid: mainPID)])
    }

    // Main process + a nil-bundle-id child whose parent chain resolves to the
    // target (the Firefox media/RDD child case). Both must be returned.
    @Test func nilBundleChildAttributedToParent() {
        let processes = [
            RawAudioProcess(objectID: 1, pid: mainPID, bundleID: firefox),
            RawAudioProcess(objectID: 2, pid: childPID, bundleID: nil)
        ]
        let resolved = resolve(
            bundleID: firefox,
            processes: processes,
            parents: [childPID: mainPID])
        #expect(resolved == [
            AudioProcess(objectID: 1, pid: mainPID),
            AudioProcess(objectID: 2, pid: childPID)
        ])
    }

    // The Firefox-shaped case the primitive exists for: ONLY the silent child
    // has a Core Audio process object (the main process never opened an audio
    // stream, so it isn't in the list). The child's own bundle id is nil, and
    // its parent is attributed via the injected AppKit closure — NOT via a
    // sibling process object. The child must still be returned.
    @Test func childResolvedViaInjectedBundleIDForPID() {
        let processes = [
            RawAudioProcess(objectID: 2, pid: childPID, bundleID: nil)
        ]
        let resolved = resolve(
            bundleID: firefox,
            processes: processes,
            parents: [childPID: mainPID],
            bundleIDForPID: [mainPID: firefox])
        #expect(resolved == [AudioProcess(objectID: 2, pid: childPID)])
    }

    // Nothing matches: a running, audible, unrelated app and no target process
    // at all yields an empty set (the "not running / not yet audible" signal),
    // never an error.
    @Test func emptyWhenNothingMatches() {
        let processes = [
            RawAudioProcess(objectID: 9, pid: 900, bundleID: "com.apple.Music")
        ]
        let resolved = resolve(bundleID: firefox, processes: processes)
        #expect(resolved.isEmpty)
    }

    // A nil-bundle-id process whose parent chain does NOT resolve to the target
    // (it belongs to a different app) is correctly EXCLUDED — resolution never
    // falls back to guessing.
    @Test func nilBundleChildOfDifferentAppExcluded() {
        let otherMain: pid_t = 300
        let otherChild: pid_t = 400
        let processes = [
            RawAudioProcess(objectID: 1, pid: mainPID, bundleID: firefox),
            RawAudioProcess(objectID: 4, pid: otherChild, bundleID: nil)
        ]
        let resolved = resolve(
            bundleID: firefox,
            processes: processes,
            parents: [otherChild: otherMain],
            bundleIDForPID: [otherMain: "com.google.Chrome"])
        // Only Firefox's own main process; the Chrome child is not attributed to Firefox.
        #expect(resolved == [AudioProcess(objectID: 1, pid: mainPID)])
    }

    // The parent walk climbs more than one hop (helper -> intermediate -> main)
    // and still attributes to the target.
    @Test func multiHopParentWalk() {
        let intermediate: pid_t = 150
        let processes = [
            RawAudioProcess(objectID: 1, pid: mainPID, bundleID: firefox),
            RawAudioProcess(objectID: 2, pid: childPID, bundleID: nil)
        ]
        let resolved = resolve(
            bundleID: firefox,
            processes: processes,
            parents: [childPID: intermediate, intermediate: mainPID])
        #expect(resolved == [
            AudioProcess(objectID: 1, pid: mainPID),
            AudioProcess(objectID: 2, pid: childPID)
        ])
    }

    // The walk is capped: a chain longer than maxParentHops does not resolve
    // (and cannot loop forever on a cyclic/pathological parent map).
    @Test func parentWalkRespectsHopCap() {
        let processes = [
            RawAudioProcess(objectID: 2, pid: childPID, bundleID: nil)
        ]
        // childPID -> 1 more hop reaches mainPID, but cap of 1 stops before the
        // second hop that would read bundleIDForPID[mainPID].
        let resolved = resolve(
            bundleID: firefox,
            processes: processes,
            parents: [childPID: 999, 999: mainPID],
            bundleIDForPID: [mainPID: firefox],
            maxParentHops: 1)
        #expect(resolved.isEmpty)
    }

    // MARK: - Catch-all attribution (Spotify/Firefox multi-process exception leak)

    private let spotify = "com.spotify.client"
    private let spotifyHelper = "com.spotify.client.helper"

    // THE live regression, reproduced exactly (2026-07-26, the owner's machine):
    // pid 953 "Spotify Helper", ppid 1 (macOS reparented it to launchd, so the
    // parent walk is dead) and reporting a bundle id OF ITS OWN that is not the
    // target — the two conditions that together let the helper's audio escape
    // every exception. Its responsible pid (739, Spotify) is the one signal
    // left. This case fails on the pre-catch-all resolver.
    @Test func reparentedHelperAttributedViaResponsibility() {
        let helper: pid_t = 953
        let spotifyMain: pid_t = 739
        let processes = [
            RawAudioProcess(objectID: 1, pid: spotifyMain, bundleID: spotify),
            RawAudioProcess(objectID: 2, pid: helper, bundleID: spotifyHelper)
        ]
        let resolved = resolve(
            bundleID: spotify,
            processes: processes,
            parents: [helper: 1],                 // reparented to launchd — walk dies
            responsible: [helper: spotifyMain])
        #expect(resolved == [
            AudioProcess(objectID: 1, pid: spotifyMain),
            AudioProcess(objectID: 2, pid: helper)
        ])
    }

    // ANY-of semantics, isolated: the helper's own (different) bundle id must
    // not short-circuit the match to "no", even when the responsible process
    // has NO audio process object of its own and is only reachable through the
    // injected AppKit closure. First-non-nil-wins attribution fails this.
    @Test func ownBundleIDDoesNotMaskResponsibilityLayer() {
        let helper: pid_t = 1029
        let spotifyMain: pid_t = 739
        let processes = [
            RawAudioProcess(objectID: 2, pid: helper, bundleID: spotifyHelper)
        ]
        let resolved = resolve(
            bundleID: spotify,
            processes: processes,
            bundleIDForPID: [spotifyMain: spotify],
            responsible: [helper: spotifyMain])
        #expect(resolved == [AudioProcess(objectID: 2, pid: helper)])
    }

    // A responsible pid that is the process ITSELF (what an ordinary
    // single-process app reports — live: Music pid 737 → 737) carries no
    // attribution information and must not match an unrelated target.
    @Test func selfResponsiblePIDContributesNothing() {
        let music: pid_t = 737
        let processes = [
            RawAudioProcess(objectID: 7, pid: music, bundleID: "com.apple.Music")
        ]
        let resolved = resolve(
            bundleID: spotify,
            processes: processes,
            responsible: [music: music])
        #expect(resolved.isEmpty)
    }

    // Layer 3 standing alone: responsibility unavailable (the symbol didn't
    // resolve, or the OS declined), but the helper's executable lives inside the
    // target app's bundle — the public-API fallback catches the same class.
    @Test func helperAttributedViaBundlePathWhenResponsibilityUnavailable() {
        let helper: pid_t = 953
        let processes = [
            RawAudioProcess(objectID: 2, pid: helper, bundleID: spotifyHelper)
        ]
        let resolved = resolve(
            bundleID: spotify,
            processes: processes,
            parents: [helper: 1],
            executablePaths: [helper: "/Applications/Spotify.app/Contents/Frameworks/"
                              + "Spotify Helper.app/Contents/MacOS/Spotify Helper"],
            bundlePaths: [spotify: "/Applications/Spotify.app"])
        #expect(resolved == [AudioProcess(objectID: 2, pid: helper)])
    }

    // The path layer compares whole path COMPONENTS: a second copy of the app
    // ("Spotify.app 2", a routine Finder/download leftover) shares a naive
    // string prefix with the target bundle but is a different app, and must not
    // be attributed to it.
    @Test func bundlePathPrefixIsComponentSafe() {
        let strangerPID: pid_t = 1500
        let processes = [
            RawAudioProcess(objectID: 3, pid: strangerPID, bundleID: nil)
        ]
        let resolved = resolve(
            bundleID: spotify,
            processes: processes,
            executablePaths: [strangerPID: "/Applications/Spotify.app 2/Contents/MacOS/Spotify"],
            bundlePaths: [spotify: "/Applications/Spotify.app"])
        #expect(resolved.isEmpty)
    }

    // No false positives: an unrelated process that fails every one of the four
    // layers (own id differs, responsible pid is a stranger, executable lives
    // elsewhere, parent chain unrelated) stays out of the set.
    @Test func unrelatedProcessMatchesNoLayer() {
        let stranger: pid_t = 2000
        let strangerParent: pid_t = 2001
        let processes = [
            RawAudioProcess(objectID: 8, pid: stranger, bundleID: "com.apple.WindowServer")
        ]
        let resolved = resolve(
            bundleID: spotify,
            processes: processes,
            parents: [stranger: strangerParent],
            bundleIDForPID: [strangerParent: "com.apple.loginwindow"],
            responsible: [stranger: strangerParent],
            executablePaths: [stranger: "/System/Library/PrivateFrameworks/x.framework/WindowServer"],
            bundlePaths: [spotify: "/Applications/Spotify.app"])
        #expect(resolved.isEmpty)
    }

    // MARK: - T2: attribution-layer reporting (Telemetry diagnosability)

    /// Convenience over the pure static attributed entry point — mirrors
    /// `resolve(...)` above exactly, but returns the `AttributedProcess` set so
    /// a test can assert WHICH layer matched, not just which processes did.
    private func resolveWithAttribution(
        bundleID: String,
        processes: [RawAudioProcess],
        parents: [pid_t: pid_t] = [:],
        bundleIDForPID: [pid_t: String] = [:],
        responsible: [pid_t: pid_t] = [:],
        executablePaths: [pid_t: String] = [:],
        bundlePaths: [String: String] = [:],
        maxParentHops: Int = 5
    ) -> Set<AttributedProcess> {
        AudioProcessResolver.resolveWithAttribution(
            bundleID: bundleID,
            processes: processes,
            parentPID: { parents[$0] },
            bundleIDForPID: { bundleIDForPID[$0] },
            responsiblePID: { responsible[$0] },
            executablePath: { executablePaths[$0] },
            bundlePathForBundleID: { bundlePaths[$0] },
            maxParentHops: maxParentHops)
    }

    // Layer 1: a process reporting the target's own bundle id is reported as `.own`.
    @Test func attributionReportsOwnLayer() {
        let processes = [
            RawAudioProcess(objectID: 1, pid: mainPID, bundleID: firefox)
        ]
        let resolved = resolveWithAttribution(bundleID: firefox, processes: processes)
        #expect(resolved == [AttributedProcess(process: AudioProcess(objectID: 1, pid: mainPID), layer: .own)])
    }

    // Layer 2: the reparented-Spotify-Helper case (see
    // `reparentedHelperAttributedViaResponsibility` above) is reported as `.responsible`.
    @Test func attributionReportsResponsibleLayer() {
        let helper: pid_t = 953
        let spotifyMain: pid_t = 739
        let processes = [
            RawAudioProcess(objectID: 1, pid: spotifyMain, bundleID: spotify),
            RawAudioProcess(objectID: 2, pid: helper, bundleID: spotifyHelper)
        ]
        let resolved = resolveWithAttribution(
            bundleID: spotify,
            processes: processes,
            parents: [helper: 1],
            responsible: [helper: spotifyMain])
        #expect(resolved == [
            AttributedProcess(process: AudioProcess(objectID: 1, pid: spotifyMain), layer: .own),
            AttributedProcess(process: AudioProcess(objectID: 2, pid: helper), layer: .responsible)
        ])
    }

    // Layer 3: bundle-path containment (see
    // `helperAttributedViaBundlePathWhenResponsibilityUnavailable` above) is reported as `.bundlePath`.
    @Test func attributionReportsBundlePathLayer() {
        let helper: pid_t = 953
        let processes = [
            RawAudioProcess(objectID: 2, pid: helper, bundleID: spotifyHelper)
        ]
        let resolved = resolveWithAttribution(
            bundleID: spotify,
            processes: processes,
            parents: [helper: 1],
            executablePaths: [helper: "/Applications/Spotify.app/Contents/Frameworks/"
                              + "Spotify Helper.app/Contents/MacOS/Spotify Helper"],
            bundlePaths: [spotify: "/Applications/Spotify.app"])
        #expect(resolved == [AttributedProcess(process: AudioProcess(objectID: 2, pid: helper), layer: .bundlePath)])
    }

    // Layer 4: the nil-bundle-id parent walk (see `nilBundleChildAttributedToParent`
    // above) is reported as `.parentWalk`.
    @Test func attributionReportsParentWalkLayer() {
        let processes = [
            RawAudioProcess(objectID: 1, pid: mainPID, bundleID: firefox),
            RawAudioProcess(objectID: 2, pid: childPID, bundleID: nil)
        ]
        let resolved = resolveWithAttribution(
            bundleID: firefox,
            processes: processes,
            parents: [childPID: mainPID])
        #expect(resolved == [
            AttributedProcess(process: AudioProcess(objectID: 1, pid: mainPID), layer: .own),
            AttributedProcess(process: AudioProcess(objectID: 2, pid: childPID), layer: .parentWalk)
        ])
    }

    // `resolve(bundleID:)` and `resolveWithAttribution(bundleID:)` must never
    // disagree on WHICH processes match — the latter is the former plus detail,
    // never a different decision (guards against the two entry points drifting
    // apart under future edits).
    @Test func attributedAndPlainResolveAgreeOnMembership() {
        let helper: pid_t = 953
        let spotifyMain: pid_t = 739
        let processes = [
            RawAudioProcess(objectID: 1, pid: spotifyMain, bundleID: spotify),
            RawAudioProcess(objectID: 2, pid: helper, bundleID: spotifyHelper)
        ]
        let plain = resolve(
            bundleID: spotify,
            processes: processes,
            parents: [helper: 1],
            responsible: [helper: spotifyMain])
        let attributed = resolveWithAttribution(
            bundleID: spotify,
            processes: processes,
            parents: [helper: 1],
            responsible: [helper: spotifyMain])
        #expect(plain == Set(attributed.map(\.process)))
    }
}
