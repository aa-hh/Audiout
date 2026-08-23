// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Bundle-sourced app identity for the About/Credits surface (Settings ›
/// General › "About Audiout…"): name + version + build. Read live from
/// `CFBundleShortVersionString`/`CFBundleVersion` — NEVER hardcoded, so it
/// always matches whatever `scripts/make-app.sh` stamped into the shipped
/// `.app`'s Info.plist. A loose `swift build`/`swift run` binary (dev, tests,
/// the `settings-snapshot` tool) has no such Info.plist, hence the fallback
/// strings below rather than a crash or an invented-looking number.
public struct AboutInfo: Equatable {
    public let appName: String
    public let version: String
    public let build: String

    public init(appName: String, version: String, build: String) {
        self.appName = appName
        self.version = version
        self.build = build
    }

    /// Reads `bundle`'s Info.plist (`Bundle.main` by default). The `bundle`
    /// parameter exists so a test can point this at a throwaway fake bundle
    /// and prove the values are genuinely read, not hardcoded.
    public static func current(bundle: Bundle = .main) -> AboutInfo {
        let info = bundle.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "Audiout"
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info?["CFBundleVersion"] as? String) ?? "—"
        return AboutInfo(appName: name, version: version, build: build)
    }

    /// "Version 1.2 (Build 34)" — the line rendered under the app name.
    public var versionLine: String { "Version \(version) (Build \(build))" }
}

/// External links/contacts the About surface offers. Both are placeholders —
/// see the TODO on each — so nothing invented ships as if it were real.
enum AboutLinks {
    /// GPL-2.0-or-later requires making the corresponding source available;
    /// this stands in for the real repository location until Alec publishes
    /// one. `example.com` is the IANA-reserved documentation/placeholder
    /// domain (RFC 2606) — inert, never a real destination.
    /// TODO(Alec): replace with the real public source-code URL before
    /// charging money for the app (GPL-2.0-or-later source-availability
    /// obligation).
    static let sourceCodePlaceholderURL = URL(string: "https://example.com/TODO-audiout-source")!

    /// TODO(Alec): replace with a real support email or contact URL.
    static let supportContactPlaceholder = "TODO(Alec): add a support email or contact link"
}

/// Third-party attribution shown in the About/Credits surface. Mirrors the
/// per-component breakdown in the repo-root `NOTICE` file — kept in sync by
/// hand; this is a UI string baked into the binary, not a parse of `NOTICE` at
/// runtime (the shipped `.app` has no access to the repo's `NOTICE` file on
/// disk, and SPM resource-bundling it would be a heavier lift than a compiled
/// string that already can't drift from what actually ships).
enum AboutCredits {
    static let thirdPartyNoticesText = """
    Audiout is licensed under the GNU General Public License, version 2 or \
    later (GPL-2.0-or-later). See the LICENSE file distributed with the \
    source for the full text.

    The AirPlayEngine sender is derived in part from OwnTone \
    (github.com/owntone/owntone-server) and bundles code under three \
    licenses, all compatible with GPL-2.0-or-later:

    GPL-2.0-or-later — airplay.c, airplay_events.c, rtp_common.c/.h. \
    Derived from OwnTone Server. Copyright (C) 2019- Espen Jürgensen and the \
    OwnTone Project.

    BSD-2-Clause — rtsp.c, evrtsp.h, log.h, rtsp-internal.h (evrtsp). Based \
    on libevent's evhttp. Copyright (C) 2010 Julien BLACHE; Copyright (c) \
    2000-2006 Niels Provos.

    MIT — pair.c, pair.h, pair_fruit.c, pair_homekit.c, pair-internal.h, \
    pair-tlv.c/.h (pair_ap), and airptp.h plus everything under libairptp. \
    Includes adaptations of Tom Cocagne's csrp (SRP6a) and maximkulkin's \
    esp-homekit (TLV encoding). libairptp is Copyright (c) 2026 OwnTone and \
    is separately redistributable under MIT alone.

    Bundled runtime libraries: libevent (BSD-3-Clause), libsodium (ISC), \
    libgcrypt and libgpg-error (LGPL-2.1-or-later), libplist \
    (LGPL-2.1-or-later), and ffmpeg (LGPL-2.1-or-later or GPL-2.0-or-later \
    depending on build configuration).

    MIT — Sparkle, the in-app update framework \
    (github.com/sparkle-project/Sparkle). Copyright (c) Sparkle Project \
    contributors.

    All third-party files retain their original copyright notices and \
    license headers in source. The repository's NOTICE file is the \
    authoritative, complete per-file breakdown.
    """
}

/// The About/Credits surface content: app identity/version, GPL license +
/// source-code link, scrollable third-party credits, and a support-contact
/// placeholder. A standalone pane — not folded into the Settings window's
/// General tab — because its full required content (per-component license
/// breakdown) would roughly double that pane's height, breaking the short,
/// scannable per-tab Settings design (`AudioutSettingsUI/AGENTS.md`).
/// `AboutWindowController` hosts this in its own small window instead;
/// `GeneralSettingsViewController` only adds one button row to reach it,
/// exactly like its existing "Setup" row.
@MainActor
public final class AboutViewController: NSViewController {

    /// About is its OWN window and keeps the width it shipped with — it is
    /// not inside the fixed surface frame, so it does not read
    /// `SettingsForm.contentWidth`.
    private static let windowWidth: CGFloat = 460

    private let info: AboutInfo
    private let openURL: (URL) -> Void
    private let sourceCodeButton = NSButton()
    private let creditsTextView = NSTextView()
    /// The background's Reduce Transparency cover (nil before `loadView`).
    /// Public only for its `test_` seams.
    public private(set) var backgroundFallback: ReduceTransparencyFallbackView?

    public init(info: AboutInfo, openURL: @escaping (URL) -> Void) {
        self.info = info
        self.openURL = openURL
        super.init(nibName: nil, bundle: nil)
        title = "About"
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        var rows: [NSView] = []

        // Identity lockup (Warm Signal §5.2 — Settings stays chrome-adjacent:
        // stock material, semantic colors, NO warm canvas, NO gold): icon on
        // the leading edge with name + version stacked beside it, reading as
        // one quiet unit rather than a form row with the icon exiled to the
        // trailing control slot. Display voice = `Tokens.Font.heading` (the
        // app's existing +3pt semibold display step — no new token; the spec
        // names none for About).
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        // `NSApplication.shared` (not the bare `NSApp` global) so this is safe
        // even the very first time any AppKit code runs in this process — the
        // bare global stays nil until `.shared` has been accessed once.
        icon.image = NSApplication.shared.applicationIconImage
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
        ])

        let nameLabel = SettingsForm.label(info.appName)
        nameLabel.font = Tokens.Font.heading
        nameLabel.textColor = Tokens.Color.label

        let versionLabel = SettingsForm.label(info.versionLine)
        versionLabel.font = Tokens.Font.caption
        versionLabel.textColor = Tokens.Color.secondaryLabel

        let identityText = NSStackView(views: [nameLabel, versionLabel])
        identityText.orientation = .vertical
        identityText.alignment = .leading
        identityText.spacing = 0

        let lockup = NSStackView(views: [icon, identityText])
        lockup.orientation = .horizontal
        lockup.alignment = .centerY
        lockup.spacing = 12
        lockup.translatesAutoresizingMaskIntoConstraints = false
        rows.append(lockup)

        sourceCodeButton.title = "View Source Code…"
        sourceCodeButton.bezelStyle = .rounded
        sourceCodeButton.target = self
        sourceCodeButton.action = #selector(viewSourceCodeTapped)
        sourceCodeButton.setAccessibilityLabel("View source code")
        rows.append(SettingsForm.row(
            title: "License",
            subtitle: "GPL-2.0-or-later — see Third-Party Notices below.",
            control: sourceCodeButton))

        let creditsLabel = SettingsForm.label("Third-Party Notices")
        creditsLabel.font = Tokens.Font.captionEmphasized
        creditsLabel.textColor = Tokens.Color.secondaryLabel
        rows.append(creditsLabel)
        rows.append(makeCreditsScrollView())

        // Same quiet-header voice as "Third-Party Notices" above, so the two
        // minor sections read as one system.
        let supportLabel = SettingsForm.label("Support")
        supportLabel.font = Tokens.Font.captionEmphasized
        supportLabel.textColor = Tokens.Color.secondaryLabel
        rows.append(supportLabel)

        let supportBody = SettingsForm.label(AboutLinks.supportContactPlaceholder)
        supportBody.font = Tokens.Font.caption
        supportBody.textColor = Tokens.Color.secondaryLabel
        supportBody.lineBreakMode = .byWordWrapping
        supportBody.maximumNumberOfLines = 0
        rows.append(supportBody)

        // An explicit opaque, appearance-adaptive background — matching
        // `SettingsRootViewController`'s own convention (this window is
        // otherwise borderless-content by default). Without it, dark mode
        // resolves dark-adapted (light) label/text-view colors drawn over
        // whatever happens to sit behind the window — illegible; confirmed by
        // rendering this offscreen in dark mode.
        let background = NSVisualEffectView()
        background.material = Tokens.Material.windowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false
        // A1: opaque stand-in while Reduce Transparency is on, live-updating.
        backgroundFallback = ReduceTransparencyFallbackView.install(in: background)
        let content = SettingsForm.paneView(rows: rows, width: Self.windowWidth)
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        view = background
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.windowWidth, height: view.fittingSize.height)
    }

    /// A bordered, scrollable, non-editable text area — the same "long text
    /// needs a bounded box" idiom as the Settings Audio pane's excluded-apps
    /// list — so the full per-component license breakdown doesn't force this
    /// small window to grow without bound.
    private func makeCreditsScrollView() -> NSScrollView {
        creditsTextView.isEditable = false
        creditsTextView.isSelectable = true
        creditsTextView.isRichText = false
        creditsTextView.drawsBackground = false
        creditsTextView.font = Tokens.Font.caption
        creditsTextView.textColor = Tokens.Color.secondaryLabel
        creditsTextView.textContainerInset = NSSize(width: 8, height: 8)  // 4pt grid
        creditsTextView.string = AboutCredits.thirdPartyNoticesText
        creditsTextView.isVerticallyResizable = true
        creditsTextView.isHorizontallyResizable = false
        creditsTextView.autoresizingMask = [.width]
        creditsTextView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.documentView = creditsTextView
        scrollView.heightAnchor.constraint(equalToConstant: 200).isActive = true
        return scrollView
    }

    @objc private func viewSourceCodeTapped() { openURL(AboutLinks.sourceCodePlaceholderURL) }

    // MARK: Test-support hooks

    public var test_versionLine: String { info.versionLine }

    /// The live third-party-credits text view's content (not a re-derivation
    /// of the constant — proves the view is actually populated).
    public var test_thirdPartyNoticesText: String {
        _ = view
        return creditsTextView.string
    }

    public var test_supportContactText: String { AboutLinks.supportContactPlaceholder }

    public var test_sourceCodeButtonTitle: String {
        _ = view
        return sourceCodeButton.title
    }

    /// Invoke "View Source Code…" as a click would — routes through the
    /// injected `openURL` seam, so this never launches a real browser in a test.
    public func test_tapViewSourceCode() {
        _ = view
        viewSourceCodeTapped()
    }

    /// The laid-out content view, for offscreen snapshot rendering (mirrors
    /// `SettingsRootViewController.paneView(at:)`).
    public var test_rootView: NSView {
        view.layoutSubtreeIfNeeded()
        return view
    }
}

/// The About window (Settings › General › "About Audiout…") — the one
/// deliberate standalone-window exception in the one-surface app (owner call,
/// PLAN-ONE-SURFACE-032.md). Lazy-create-then-reuse lifecycle at the
/// `GeneralSettingsViewController` call site, a no-arg `show()`, and `test_`
/// structure hooks (the window isn't visible to a headless harness).
@MainActor
public final class AboutWindowController: NSWindowController {

    private let aboutVC: AboutViewController

    /// - Parameters:
    ///   - info: the bundle-sourced identity; defaults to the live app bundle.
    ///   - openURL: opens the "View Source Code…" link; defaults to
    ///     `NSWorkspace`, injected as a recording closure in tests.
    public init(info: AboutInfo = .current(),
                openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        aboutVC = AboutViewController(info: info, openURL: openURL)
        let window = NSWindow(contentViewController: aboutVC)
        window.styleMask = [.titled, .closable]
        window.title = "About Audiout"
        super.init(window: window)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Open/focus the window:
    /// sizing always runs headlessly too, but the actual on-screen presentation
    /// is gated behind `HeadlessRuntime.isActive` so `swift test`/a headless
    /// tool never flashes a real window on the developer's screen.
    public func show() {
        aboutVC.view.layoutSubtreeIfNeeded()
        window?.setContentSize(aboutVC.view.fittingSize)
        guard !HeadlessRuntime.isActive else { return }
        NSApp?.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Test-support hooks

    public var test_aboutViewController: AboutViewController { aboutVC }

    public var test_contentFittingSize: NSSize {
        aboutVC.view.layoutSubtreeIfNeeded()
        return aboutVC.view.fittingSize
    }

    public var test_rootView: NSView { aboutVC.test_rootView }
}
