// SPDX-License-Identifier: GPL-2.0-or-later
//
// wizard-snapshot — offscreen PNG renderer for the alignment wizard's sheet
// ("Two Voices, on the Plate", wizard-stage v2). The live sheet isn't visible
// to an agent shell, so this assembles the REAL
// `AlignmentWizardViewController` + `BTAlignmentWizardView` over a scripted
// `BTAlignmentWizardSession`, drives the session through its screens with a
// deterministic simulated listener (the posterior has no RNG), and renders the
// controller's view at its fitted size via
// `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay`. Nothing is ever
// presented or ordered on screen.
//
// Runs HEADLESS (`AIRPLAY_HEADLESS=1`, set below before AppKit loads): every
// transition lands its settled values synchronously, so the lock's 1.44 s
// settle — and with it the `· kept` readout — is in the frame that is
// captured, and no render depends on a runloop drain racing a CAAnimation.
//
// Run: `swift run wizard-snapshot [output-dir]` (default: ./wizard-snapshots).
// Dark renders are primary (the stage plate is appearance-fixed); the light
// set verifies the themed chassis around it.

import Foundation
setenv("AIRPLAY_HEADLESS", "1", 1)

import AppKit
import AudiouterCore
import AudiouterPopoverUI
import AudiouterSharedUI

/// The simulated listener's true latency — the number the kept screen ends
/// on, as the spec's own example (`247 ms · kept`).
let trueOffsetMs = 247.0
/// The listener's fusion window: inside it the clicks "sound together".
let jndMs = 4.0

@MainActor
func render(_ controller: AlignmentWizardViewController, to url: URL,
            appearance name: NSAppearance.Name) {
    let content = controller.view
    let appearance = NSAppearance(named: name)
    NSApp.appearance = appearance
    content.appearance = appearance
    controller.fitToContent()
    content.layoutSubtreeIfNeeded()
    // One runloop drain so deferred layout/appearance passes settle.
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
        fputs("no bitmap rep for \(url.lastPathComponent)\n", stderr)
        exit(1)
    }
    content.cacheDisplay(in: content.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("png encode failed\n", stderr)
        exit(1)
    }
    try? png.write(to: url)
    print("wrote \(url.path)")
}

/// One scripted Bluetooth (latency-measuring) run with a simulated listener
/// whose ear sits at `trueOffsetMs`.
@MainActor
final class Run {
    let session: BTAlignmentWizardSession
    let view: BTAlignmentWizardView
    let controller: AlignmentWizardViewController
    /// The level the session is previewing — what the listener "hears".
    private final class Level { var ms = 0.0 }
    private let level = Level()
    private let trueOffsetMs: Double

    init(referenceOptions: [BTAlignmentWizardView.ReferenceOption],
         trueOffsetMs: Double = wizard_snapshot.trueOffsetMs) {
        self.trueOffsetMs = trueOffsetMs
        let level = self.level
        session = BTAlignmentWizardSession(
            deviceID: "kitchen",
            targetName: "Kitchen HomePod",
            reference: referenceOptions.first.map { .init(id: $0.id, name: $0.name) },
            baseValueMs: 0,
            invertsEstimate: true,
            applyPreviewTrim: { ms, _ in level.ms = ms },
            endPreview: { _ in },
            setTick: { _ in })
        view = BTAlignmentWizardView(session: session)
        view.referenceOptions = referenceOptions
        controller = AlignmentWizardViewController(wizardView: view)
        // Laid out BEFORE the run is driven, as the live sheet is: the stage
        // applies geometry only once it has a width, and the dormant screen
        // keeps the ruler gearing the run left it with.
        controller.fitToContent()
    }

    /// One listener answer at the current level — the test suite's own
    /// driver logic: a LATENCY level below the truth leaves the target still
    /// late, so the reference is heard first.
    func answer() {
        let ms = level.ms
        if abs(ms - trueOffsetMs) < jndMs {
            session.answer(.together)
        } else {
            session.answer(ms < trueOffsetMs ? .reference : .target)
        }
    }

    /// Answer until the interval's half-width drops to `halfWidthMs` or the
    /// run leaves the question screen.
    func answer(untilHalfWidth halfWidthMs: Double) {
        var guardCount = 0
        while case .question(_, let interval, _) = session.screen, guardCount < 60 {
            if (interval.upperBound - interval.lowerBound) / 2 <= halfWidthMs { return }
            answer()
            guardCount += 1
        }
    }

    func answerUntilProposal() {
        var guardCount = 0
        while case .question = session.screen, guardCount < 80 {
            answer()
            guardCount += 1
        }
    }
}

@MainActor
func run() -> Int32 {
    let arguments = ProcessInfo.processInfo.arguments
    let outputDir = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "wizard-snapshots",
                        isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

    _ = NSApplication.shared   // AppKit up, no run loop, nothing ordered in.

    let twoOptions: [BTAlignmentWizardView.ReferenceOption] = [
        .init(id: "office", name: "Office Sonos One"),
        .init(id: "mac", name: "This Mac"),
    ]
    func shoot(_ run: Run, _ name: String, light: Bool = false) {
        render(run.controller, to: outputDir.appendingPathComponent("\(name)-dark.png"),
               appearance: .darkAqua)
        if light {
            render(run.controller, to: outputDir.appendingPathComponent("\(name)-light.png"),
                   appearance: .aqua)
        }
    }

    // MARK: The scripted run

    let main = Run(referenceOptions: twoOptions)

    // 1 · intro (armed stage, reference row, Start).
    shoot(main, "1-intro", light: true)

    // 2 · first question — wide open.
    main.session.start()
    shoot(main, "2-question-open")

    // 3 · the mid rungs.
    main.answer(untilHalfWidth: 250)
    shoot(main, "3-question-closing", light: true)
    main.answer(untilHalfWidth: 60)
    shoot(main, "3b-question-near")

    // 4 · nearly there.
    main.answer(untilHalfWidth: 12)
    shoot(main, "4-question-tight")

    // 4b · the pressed state — the together bar held down.
    // Titled from the constant, not a copy of it: a retitled plate would
    // otherwise leave this shooting an unpressed screen in silence.
    main.view.test_setPlatePressed(titled: BTAlignmentWizardView.togetherTitle, true)
    shoot(main, "4b-question-pressed")
    main.view.test_setPlatePressed(titled: BTAlignmentWizardView.togetherTitle, false)

    // 5 · proposal (fused, listening).
    main.answerUntilProposal()
    if case .proposal = main.session.screen {
        shoot(main, "5-proposal", light: true)
        // 6 · kept (locked).
        main.session.acceptProposal()
        shoot(main, "6-kept", light: true)
    } else {
        fputs("run never proposed (screen: \(main.session.screen))\n", stderr)
    }

    // 7 · unsettled (dormant stage) — a fresh run rejected until it gives up.
    let unsettled = Run(referenceOptions: twoOptions)
    unsettled.session.start()
    var guard3 = 0
    while guard3 < 200 {
        guard3 += 1
        if case .question = unsettled.session.screen {
            unsettled.answer()
        } else if case .proposal = unsettled.session.screen {
            unsettled.session.rejectProposal()
        } else {
            break
        }
    }
    if case .unsettled = unsettled.session.screen {
        shoot(unsettled, "7-unsettled", light: true)
    } else {
        fputs("second run never unsettled (screen: \(unsettled.session.screen))\n", stderr)
    }

    // 8 · unreachable: a listener who always hears the reference first drives
    // the latency off the top of the range, rejecting every proposal.
    let unreachable = Run(referenceOptions: twoOptions)
    unreachable.session.start()
    var guard4 = 0
    while guard4 < 200 {
        guard4 += 1
        if case .question = unreachable.session.screen {
            unreachable.session.answer(.reference)
        } else if case .proposal = unreachable.session.screen {
            unreachable.session.rejectProposal()
        } else {
            break
        }
    }
    if case .unreachable = unreachable.session.screen {
        shoot(unreachable, "8-unreachable", light: true)
    } else {
        fputs("third run never unreachable (screen: \(unreachable.session.screen))\n", stderr)
    }

    // 9 · macIsLate: a listener whose truth is NEGATIVE latency.
    let late = Run(referenceOptions: twoOptions, trueOffsetMs: -60)
    late.session.start()
    late.answerUntilProposal()
    if case .macIsLate = late.session.screen {
        shoot(late, "9-mac-is-late", light: true)
    } else {
        fputs("fourth run never macIsLate (screen: \(late.session.screen))\n", stderr)
    }

    // 9b · the FOURTH bow-out, the only one no session state can reach: the
    // host drives it when the target vanishes under a live sheet.
    let lost = Run(referenceOptions: twoOptions)
    lost.session.start()
    lost.answer(untilHalfWidth: 250)
    lost.view.showTargetLost()
    shoot(lost, "9b-target-lost", light: true)

    // 10 · the intro's reference-row branches: one candidate (plain text), none.
    shoot(Run(referenceOptions: [twoOptions[0]]), "10-intro-one-option")
    shoot(Run(referenceOptions: []), "11-intro-no-option")

    print("done")
    return 0
}

exit(MainActor.assumeIsolated { run() })

