// SPDX-License-Identifier: GPL-2.0-or-later
//
// component-catalog — a window that lists the app's shared AppKit components
// and its screens, and shows the real one for whichever is picked, over the
// mock speaker fleet. Every view on screen is the shipping class; the only
// fakes sit at the seams the views already inject (MockBackend, temp stores,
// a scratch defaults suite, permission probes that never ask the system).
//
//   AUDIOUT_RUN_PRODUCT=component-catalog bash scripts/run-app.sh ["Entry name"]
//
// The optional argument opens on that entry instead of the first;
// `-appearance light` or `-appearance dark` after it presets the appearance.
//
// To add a component: append an `Entry` to `components` below. To add a state
// of one already listed: add a row to its `page`.

import AppKit
import AudioutCore
import AudioutOnboardingUI
import AudioutPopoverUI
import AudioutSettingsUI
import AudioutSharedUI
import AudioutWindowUI

// MARK: - Fixtures

/// A suite of its own, wiped on every launch, so the catalog never reads or
/// writes the real app's settings.
let defaults: UserDefaults = {
    let suite = "com.audiout.component-catalog"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite) ?? .standard
}()

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("component-catalog-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

final class CatalogLoginItem: LoginItemManaging {
    var isEnabled: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
}

struct CatalogAudioProbe: AudioCapturePermissionProbing {
    func probe() async -> PermissionStatus { .granted }
    func currentStatusSilently() -> PermissionStatus? { .granted }
}

struct CatalogLocalNetwork: LocalNetworkPriming {
    func probe() async -> Bool { true }
    func probeFoundSpeakers() async -> Int { 3 }
}

struct CatalogRemoteControl: RemoteControlPriming {
    func prime() {}
    func isTrusted() -> Bool { false }
}

struct CatalogPTPHelper: PTPHelperManaging {
    var status: PTPHelperStatus { .requiresApproval }
    func register() throws {}
    func openSystemSettingsLoginItems() {}
    func unregister() async throws {}
}

@MainActor
func makeSettings() -> AppSettings {
    // Both URLs set, or the Licence section never renders. The secret store
    // is the scratch suite: left nil, a non-headless run would use the real
    // app's keychain items, and Register or Remove would overwrite them.
    AppSettings(defaults: defaults,
                licenseServerURL: URL(string: "https://license.catalog.invalid"),
                buyURL: URL(string: "https://audiout.app/buy"),
                secrets: DefaultsSecretStore(defaults))
}

/// Same sections, order and symbols as the app's own Settings.
@MainActor
func makeSettingsRoot(settings: AppSettings) -> SettingsRootViewController {
    let excluded = ExcludedAppsController(store: ExcludedAppsStore(directory: tempDir()), loadPersisted: false)
    excluded.exclude(bundleID: "us.zoom.xos", displayName: "Zoom")
    let latency = LatencySettingModel(optionsMs: AppSettings.startBufferOptionsMs,
                                      initialMs: AppSettings.defaultStartBufferMs,
                                      envOverrideMs: nil, isStreaming: { false }, apply: { _ in (0, 0) })
    var sections: [SettingsRootViewController.Section] = [
        .init(title: "General", symbolName: "gearshape",
              viewController: GeneralSettingsViewController(loginItem: CatalogLoginItem(), settings: settings)),
    ]
    let remote = RemoteSettingsViewController(settings: settings)
    if remote.isOffered {
        sections.append(.init(title: "Audiout Remote", symbolName: "iphone", viewController: remote))
    }
    sections += [
        .init(title: "Appearance", symbolName: "paintpalette",
              viewController: AppearanceSettingsViewController(settings: settings)),
        .init(title: "Audio", symbolName: "speaker.wave.2",
              viewController: AudioSettingsViewController(excluded: excluded, runningAppsProvider: { [] },
                                                          latency: latency)),
        .init(title: "Licence", symbolName: "key",
              viewController: LicenseSettingsViewController(settings: settings)),
    ]
    return SettingsRootViewController(sections: sections)
}

@MainActor
func makeOnboarding() -> OnboardingViewController {
    let bluetooth = SimulatedBluetoothPermission(status: .unknown)
    let model = SetupModel(audioProbe: CatalogAudioProbe(),
                           localNetwork: CatalogLocalNetwork(),
                           remoteControl: CatalogRemoteControl(),
                           ptpHelper: CatalogPTPHelper(),
                           bluetoothReader: bluetooth,
                           bluetoothPrimer: bluetooth,
                           settings: makeSettings(),
                           usageStatsAvailable: true)
    let controller = OnboardingViewController(model: model, onOpenSettings: { _ in }, onDone: {})
    controller.presentUsageStatsConsent = { deliver in deliver(true) }
    return controller
}

// MARK: - Component pages

func caption(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = .secondaryLabelColor
    return label
}

/// One labelled view per state, stacked. `width` pins views that fill their
/// host's width (rows, faders) to something readable.
@MainActor
func page(_ items: [(String, NSView)], width: CGFloat? = nil) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    for (label, view) in items {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let width { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        stack.addArrangedSubview(caption(label))
        stack.addArrangedSubview(view)
        stack.setCustomSpacing(20, after: view)
    }
    return stack
}

@MainActor
func row(_ device: Device, showsMeter: Bool = false) -> NSView {
    let view = DeviceRowView(device: device, showsMeter: showsMeter)
    view.heightAnchor.constraint(equalToConstant: DeviceRowView.rowHeight).isActive = true
    return view
}

@MainActor
func fader(value: Int, configure: (RowVolumeFader) -> Void = { _ in }) -> NSView {
    let view = RowVolumeFader()
    view.value = value
    configure(view)
    view.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return view
}

@MainActor
func symbol(_ name: String) -> NSImageView {
    NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
}

@MainActor
func iconWell(_ symbolName: String, active: Bool) -> NSView {
    let view = DeviceIconWellView()
    view.iconImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    view.isActiveGroup = active
    view.widthAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
    view.heightAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
    return view
}

/// A grouped section wrapped around `rows`, laid out the way Settings panes
/// build theirs.
@MainActor
func section(_ style: GroupedSectionView.Style, rows: [NSView]) -> NSView {
    let container = NSView()
    let box = GroupedSectionView()
    box.translatesAutoresizingMaskIntoConstraints = false
    box.style = style
    box.radiusOverride = Tokens.Layout.Radius.row
    box.contentLeadingInset = ListRowView.leadingInset
    box.contentTrailingInset = ListRowView.trailingInset
    container.addSubview(box)
    let stack = NSStackView(views: rows)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        box.topAnchor.constraint(equalTo: container.topAnchor),
        box.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        box.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        box.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        stack.topAnchor.constraint(equalTo: box.topAnchor, constant: GroupedSectionView.verticalPadding),
        stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -GroupedSectionView.verticalPadding),
    ])
    for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    box.rows = rows
    return container
}

@MainActor
func listRows() -> [NSView] {
    [ListRowView(title: "Launch at login", accessory: NSSwitch()),
     ListRowView(glyph: symbol("speaker.wave.2"), title: "Audio buffer", caption: "Longer survives busy Wi-Fi"),
     ListRowView(title: "Version", accessory: NSTextField(labelWithString: "1.0"))]
}

let speaker = Device(id: "office", name: "Office", kind: .generic, volume: 50)

@MainActor
func withState(_ state: ConnectionState, selected: Bool = true) -> Device {
    var device = speaker
    device.connectionState = state
    device.isSelected = selected
    return device
}

// MARK: - Entries

struct Entry {
    let section: String
    let name: String
    /// Builds a fresh view controller each time the entry is picked, so
    /// state from a previous visit never leaks into the next.
    let make: @MainActor () -> NSViewController
}

@MainActor
func wrap(_ view: NSView) -> NSViewController {
    let vc = NSViewController()
    vc.view = view
    return vc
}

func component(_ name: String, _ build: @escaping @MainActor () -> NSView) -> Entry {
    Entry(section: "Components", name: name, make: { wrap(build()) })
}

let components: [Entry] = [
    component("Speaker row") {
        var muted = withState(.connected); muted.isMuted = true
        var unavailable = withState(.off, selected: false); unavailable.isAvailable = false
        return page([
            ("Off, not selected", row(withState(.off, selected: false))),
            ("Connecting", row(withState(.connecting))),
            ("Connected, with meter", row(withState(.connected), showsMeter: true)),
            ("Reconnecting", row(withState(.reconnecting))),
            ("Waiting for password", row(withState(.awaitingPassword))),
            ("Failed: not responding", row(withState(.failed(ConnectionFailure(cause: .notResponding))))),
            ("Failed: password needed", row(withState(.failed(ConnectionFailure(cause: .authRequired))))),
            ("Muted", row(muted)),
            ("Unavailable", row(unavailable)),
        ], width: 653)
    },
    component("Row fader") {
        page([
            ("Default", fader(value: 50)),
            ("Route armed", fader(value: 70) { $0.isRouteArmed = true }),
            ("Muted", fader(value: 40) { $0.isMutedControl = true }),
            ("Waiting to apply", fader(value: 60) { $0.isPendingApply = true }),
            ("Not adjustable", fader(value: 30) { $0.isAdjustable = false }),
        ], width: 240)
    },
    component("Buttons") {
        page([
            ("Prominent (gold only while this window is active)", ProminentButton(title: "Start Free Trial", target: nil, action: nil)),
            ("Call to action, primary", {
                let button = CTAButton(title: "Buy Audiout", style: .primary, target: nil, action: nil)
                button.keyEquivalent = "\r"
                return button
            }()),
            ("Call to action, secondary", CTAButton(title: "Try free for 14 days", style: .secondary,
                                                    target: nil, action: nil)),
            ("Text action", TextActionButton(title: "Manage Speakers…")),
        ])
    },
    component("List row") {
        page(zip(["Switch accessory", "Glyph and caption", "Value accessory"], listRows()).map { ($0, $1) },
             width: 420)
    },
    component("Grouped section") {
        page([("Card", section(.card, rows: listRows())),
              ("Well", section(.well, rows: listRows())),
              ("Bare", section(.bare, rows: listRows()))], width: 420)
    },
    component("Page header") {
        let title = NSTextField(labelWithString: "Speakers")
        title.font = Tokens.Font.body
        return page([
            ("Icon and title", PageHeaderView(icon: symbol("hifispeaker.2"), title: title)),
            ("With caption", PageHeaderView(icon: symbol("hifispeaker.2"),
                                            title: NSTextField(labelWithString: "Speakers"),
                                            caption: caption("7 on this network"))),
        ], width: 420)
    },
    component("Device icon well") {
        page([("Idle", iconWell("hifispeaker.fill", active: false)),
              ("Active scene", iconWell("homepod.fill", active: true))])
    },
    component("Rolling count") {
        let label = RollingCountLabel(labelWithString: "3")
        label.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        let button = NSButton(title: "Roll", target: nil, action: nil)
        var count = 3
        let roller = ClosureTarget { count += 1; label.roll(to: "\(count)") }
        button.target = roller
        button.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(button, "catalog.roller", roller, .OBJC_ASSOCIATION_RETAIN)
        return page([("Count (press Roll)", label), ("", button)])
    },
    component("Companion invitation") {
        page([("Invitation tile", RemoteInviteView(tileSide: 140))])
    },
    component("Panel backing") {
        let view = ControlPanelBackingView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
        view.heightAnchor.constraint(equalToConstant: 160).isActive = true
        return page([("Panel bubble", view)], width: 360)
    },
]

final class ClosureTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

// MARK: - Screens

/// The real one-surface window (Mixer, Scenes, Speakers, Settings) over the
/// mock fleet. It is its own window in the app, so it opens as one here too.
@MainActor
final class MainSurface {
    private var keepAlive: [AnyObject] = []
    private var surface: AppSurfaceController?
    private var events: Task<Void, Never>?

    nonisolated init() {}

    /// Builds the window once; later calls bring the same one back.
    func open() {
        if let surface {
            surface.show(anchorRect: nil)
            return
        }
        let settings = makeSettings()
        let dir = tempDir()
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: true, simulatesDropouts: false)
        let groups = GroupController(backend: backend, store: GroupStore(directory: dir),
                                     routingStore: RoutingStore(directory: dir),
                                     settings: settings, loadPersisted: false)
        let routes = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        let library = SpeakerLibraryController(store: SpeakerLibraryStore(directory: dir),
                                               legacyHiddenStore: HiddenSpeakersStore(directory: dir),
                                               loadPersisted: false)
        let icons = DeviceIconController(store: DeviceIconStore(directory: dir), loadPersisted: false)
        backend.start()
        let deadline = Date().addingTimeInterval(3)
        while backend.devices.count < [Device].demoFleet.count && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let devices = backend.devices
        groups.updateDevices(devices)
        groups.ensureDefaultSelection()
        library.update(liveDevices: devices, groups: groups.groups,
                       currentUse: SpeakerCurrentUse(mainAudioMemberIDs: groups.selectedDeviceIDs))

        let window = MixerWindowController(groupController: groups, deviceIconController: icons,
                                           appRouting: routes,
                                           btHardwareVolumeStore: BTHardwareVolumeStore(directory: dir),
                                           settings: settings, speakerLibrary: library)
        let popover = PopoverController(appRouting: routes, runningAppsProvider: { [] }, speakerLibrary: library)
        popover.deviceIconController = icons
        popover.configure(groupController: groups)
        popover.update(devices: devices)
        window.update(devices: devices)
        library.onChange = { [weak popover, weak window] in
            popover?.refreshSpeakerPresentation()
            window?.refreshSpeakerPresentation()
        }
        let surface = AppSurfaceController(popoverController: popover, settings: settings,
                                           groupsContent: { window.scenesContentController },
                                           speakersContent: { window.speakersContentController },
                                           settingsContent: { makeSettingsRoot(settings: settings) },
                                           frameAutosaveName: "ComponentCatalogSurface")
        popover.onManageSpeakers = {
            surface.select(.speakers)
            window.select(.speakersOverview)
        }
        surface.setPinned(true)
        surface.show(anchorRect: nil)
        self.surface = surface
        keepAlive = [backend, groups, routes, library, icons, window, popover]

        // Toggles, volume and meters come back as backend events; fold them
        // into the fleet and push it to the views, as the app delegate does.
        var fleet = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        var order = devices.map(\.id)
        let stream = backend.makeEventStream()
        events = Task { @MainActor in
            for await event in stream {
                switch event {
                case .deviceAdded(let device), .deviceUpdated(let device):
                    if fleet[device.id] == nil { order.append(device.id) }
                    fleet[device.id] = device
                case .deviceRemoved(let id): fleet[id]?.isAvailable = false
                default: continue
                }
                let devices = order.compactMap { fleet[$0] }
                groups.updateDevices(devices)
                popover.update(devices: devices)
                window.update(devices: devices)
            }
        }
    }
}

let mainSurface = MainSurface()

let screens: [Entry] = [
    Entry(section: "Screens", name: "Main window", make: {
        mainSurface.open()
        let note = NSTextField(wrappingLabelWithString:
            "The main window (Mixer, Scenes, Speakers, Settings) is its own window in the app, "
            + "so it opens beside this one, over the mock speakers.")
        let again = NSButton(title: "Open It Again", target: nil, action: nil)
        let reopen = ClosureTarget { mainSurface.open() }
        again.target = reopen
        again.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(again, "catalog.reopen", reopen, .OBJC_ASSOCIATION_RETAIN)
        return wrap(page([("", note), ("", again)], width: 420))
    }),
    Entry(section: "Screens", name: "Settings", make: {
        // The root has no size of its own; the main window gives it one.
        let root = makeSettingsRoot(settings: makeSettings())
        root.view.widthAnchor.constraint(equalToConstant: SurfaceLayout.width).isActive = true
        root.view.heightAnchor.constraint(equalToConstant: 600).isActive = true
        return root
    }),
    Entry(section: "Screens", name: "Setup window", make: { makeOnboarding() }),
]

// MARK: - Catalog window

/// Sidebar rows: a section header, or an entry to show.
enum SidebarRow {
    case header(String)
    case entry(Entry)
}

@MainActor
final class CatalogController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let rows: [SidebarRow]
    private let table = NSTableView()
    private let detail = BackdropView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var current: NSViewController?

    init(entries: [Entry]) {
        var rows: [SidebarRow] = []
        var lastSection: String?
        for entry in entries {
            if entry.section != lastSection {
                rows.append(.header(entry.section))
                lastSection = entry.section
            }
            rows.append(.entry(entry))
        }
        self.rows = rows
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        let sidebar = NSScrollView()
        sidebar.documentView = table
        sidebar.hasVerticalScroller = true
        sidebar.autohidesScrollers = true
        sidebar.drawsBackground = false

        let appearance = NSSegmentedControl(labels: ["System", "Light", "Dark"], trackingMode: .selectOne,
                                            target: self, action: #selector(appearanceChanged(_:)))
        // `-appearance light|dark` on the command line presets the switch.
        appearance.selectedSegment = ["light": 1, "dark": 2][UserDefaults.standard.string(forKey: "appearance") ?? ""] ?? 0
        appearanceChanged(appearance)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let header = NSStackView(views: [titleLabel, NSView(), appearance])
        header.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 12, right: 16)

        let content = NSStackView(views: [header, detail])
        content.orientation = .vertical
        content.spacing = 0
        header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        detail.wantsLayer = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(content)
        sidebar.widthAnchor.constraint(equalToConstant: 200).isActive = true
        view = split
        view.frame = NSRect(x: 0, y: 0, width: 1040, height: 760)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard table.selectedRow < 0 else { return }
        let wanted = CommandLine.arguments.dropFirst().first
        let index = rows.firstIndex {
            if case .entry(let entry) = $0 { return wanted == nil || entry.name == wanted }
            return false
        } ?? 1
        table.selectRowIndexes([index], byExtendingSelection: false)
    }

    @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
        // App-level, not window-level: system-drawn pieces (segmented controls,
        // selection pills) resolve against the app's appearance.
        NSApp.appearance = [nil, NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)][sender.selectedSegment]
    }

    private func show(_ entry: Entry) {
        current?.view.removeFromSuperview()
        let vc = entry.make()
        current = vc
        titleLabel.stringValue = entry.name

        let shown = vc.view
        shown.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(shown)
        scroll.documentView = document
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scroll)
        detail.subviews.forEach { $0.removeFromSuperview() }
        detail.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: detail.topAnchor),
            host.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            shown.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            shown.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            shown.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -24),
            shown.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        detail.layoutSubtreeIfNeeded()
        document.scroll(.zero)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title): return NSTextField(labelWithString: title)
        case .entry(let entry): return NSTextField(labelWithString: entry.name)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, case .entry(let entry) = rows[table.selectedRow] else { return }
        show(entry)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Fills with the app's window background. `updateLayer` runs again on every
/// appearance change, so the Light/Dark switch recolours it.
final class BackdropView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Tokens.Color.windowBackground.cgColor
        }
    }
}

@MainActor
final class CatalogDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let controller = CatalogController(entries: components + screens)
        let window = NSWindow(contentViewController: controller)
        window.title = "Audiout Component Catalog"
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 1040, height: 760))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// `main.swift`'s top level is nonisolated but runs on the main thread, which
// `assumeIsolated` asserts. `run()` never returns.
let catalogDelegate = MainActor.assumeIsolated { CatalogDelegate() }
MainActor.assumeIsolated {
    NSApplication.shared.delegate = catalogDelegate
    NSApplication.shared.run()
}
