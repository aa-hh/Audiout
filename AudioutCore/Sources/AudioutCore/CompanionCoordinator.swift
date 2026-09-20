// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import AudioutProtocol

/// The AppKit touch points the companion wiring cannot do for itself. Every
/// member here is something `AudioutCore` must not reach: an `NSAlert`, an
/// `NSWorkspace` enumeration, an app icon, a popover repaint, the app's
/// termination flag, or the app's stderr log.
///
/// `AppDelegate` is the only production conformer; the test suite supplies its
/// own (see `CompanionWiringTests`), which is the whole point of the split —
/// this wiring used to live in a target the suite cannot see.
@MainActor
public protocol CompanionCoordinatorHost: AnyObject {
    /// Ask the user whether this phone may control the Mac, and report the
    /// answer exactly once. Never called for a remembered phone.
    func presentApprovalPrompt(clientID: String, clientName: String,
                               respond: @escaping (Bool) -> Void)
    /// Close the prompt for `clientID` — its connection died unanswered.
    func withdrawApprovalPrompt(clientID: String)
    /// The `.regular` running apps, newest read (the coordinator caches it).
    func runningApplications() -> [(bundleID: String, displayName: String)]
    /// Answer a phone's `requestAppIcons` — reading an icon is AppKit work.
    func serveAppIconPages(_ requested: [String], to clientID: UUID)
    /// The live device fleet, unsorted.
    func devices() -> [Device]
    /// The row symbol for `device`, honouring the user's icon overrides.
    func symbolName(for device: Device) -> String
    /// Which routed apps are live on each device, for the snapshot.
    func routedAppNames() -> [String: [String]]
    /// A phone arrived or left: the Setup card and the wizard's iPhone panel
    /// both turn on this.
    func clientCountDidChange(_ count: Int)
    /// A phone staged a run on `deviceID`, so a by-ear sheet open on the same
    /// speaker has been superseded.
    func alignmentRunStarted(deviceID: String)
    /// A measurement moved this speaker's stored latency by `byMs`.
    func alignmentMoved(deviceID: String, byMs: Double)
    /// The app is quitting; every deferred main-queue hop checks this.
    var isTerminating: Bool { get }
    func log(_ message: String)
}

/// Everything that makes the iPhone companion work on the Mac side
/// (PLAN-COMPANION-APP T7): the server's lifecycle, the command path, the
/// per-phone approval gate, the coalesced snapshot broadcast, and the eight
/// sync-calibration actuators the dispatcher calls.
///
/// This lived inline in `AppDelegate` until the 2026-09-17 review (ticket 24).
/// It is here rather than there for one reason: `AudioutApp` is invisible to
/// the test suite, so every rule decided in it was untestable by construction.
/// What stayed behind is the AppKit half, reached through
/// ``CompanionCoordinatorHost``.
@MainActor
public final class CompanionCoordinator {

    // MARK: Collaborators

    private let backend: OutputBackend
    private let groupController: GroupController
    private let appRouting: AppRoutingController
    private let settings: AppSettings
    private let excludedBundleIDs: () -> Set<String>

    /// One name for both the Bonjour advertisement (`start(name:)`) and
    /// `Snapshot.serverName` — the server's `welcome` reads the latter, so the
    /// two must agree (one source of truth, `CompanionServer.sendWelcome`).
    public let serverName: String

    /// The iPhone-companion link: a Bonjour-advertised WebSocket server the
    /// phone connects to. Created once; started/stopped only by
    /// ``updateServerState()`` (launch + the Settings › General checkbox, both
    /// funneled through `AppSettings.resolvedAllowRemoteControl` so the
    /// `AUDIOUT_COMPANION` env override wins). ON when the setting is unset, so
    /// a fresh install advertises without being asked twice — the Local Network
    /// grant is already the user's consent to this.
    public let server: CompanionServer

    /// The per-phone approval model (T24): remembers each phone's allow/deny
    /// answer, funnels unknown phones into ONE prompt per clientID, and backs
    /// the Settings › General "Remembered iPhones" list.
    public let approvals: CompanionApprovalController

    private weak var host: (any CompanionCoordinatorHost)?

    public init(backend: OutputBackend,
                groupController: GroupController,
                appRouting: AppRoutingController,
                settings: AppSettings,
                excludedBundleIDs: @escaping () -> Set<String>,
                serverName: String,
                server: CompanionServer = CompanionServer(),
                // Optional rather than defaulted: a default argument is evaluated
                // in a nonisolated context, and this type's init is `@MainActor`.
                approvals: CompanionApprovalController? = nil,
                host: any CompanionCoordinatorHost) {
        self.backend = backend
        self.groupController = groupController
        self.appRouting = appRouting
        self.settings = settings
        self.excludedBundleIDs = excludedBundleIDs
        self.serverName = serverName
        self.server = server
        self.approvals = approvals ?? CompanionApprovalController()
        self.host = host
    }

    // MARK: State

    /// The last token pushed to connected phones (`applyLicenseState()`), so
    /// the many callers of that method don't resend an unchanged one.
    private var pushedCompanionToken: String?

    /// Mirrors whether `server` is currently running, so the many broadcast
    /// triggers can no-op cheaply while the feature is off (the default) and
    /// ``updateServerState()`` only acts on a real edge.
    private var isActive = false

    /// Executes phone commands against the exact controllers the popover
    /// drives. Built in ``wire()`` once those controllers exist.
    private var dispatcher: CompanionCommandDispatcher!

    /// The pending coalesced broadcast (~50 ms): every snapshot-affecting
    /// trigger funnels through ``scheduleBroadcast()``, which arms ONE work
    /// item per window instead of rebuilding per event — a device burst at
    /// connect would otherwise build dozens of near-identical snapshots.
    private var broadcastWork: DispatchWorkItem?

    /// Snapshot inputs that exist only as transient backend events
    /// (`.localFallbackActive` / `.takeoverStatus` /
    /// `.systemDefaultIsAirPlayActive`) — cached from the app's event handler
    /// so the coalescer can rebuild the FULL snapshot at any later moment.
    private var localFallbackActive = false
    private var takeoverStatus: TakeoverStatus?
    private var systemDefaultIsAirPlayActive = false

    /// Last-known display name per `Device.id`, accumulated from
    /// `deviceAdded`/`deviceUpdated` and NEVER pruned on `deviceRemoved`
    /// (FIX-B2 finding 7b) — so `GroupState.memberNames` can still label a
    /// group member that went offline mid-session. Session-scoped only.
    private var knownDeviceNamesByID: [String: String] = [:]

    /// Per-client token bucket over inbound companion commands (FIX-B2
    /// finding 2a): every command costs main-thread work (dispatcher +
    /// snapshot rebuild; `setMainOut` adds a `stateQueue.sync` + disk write),
    /// so a peer looping a tiny command frame could starve the Mac's UI.
    /// 20/sec sustained (the phone's own slider send policy) + a 40 burst.
    private var rateLimiter = CompanionCommandRateLimiter()

    /// Which phone owns each speaker's calibration, what KIND of work it is,
    /// and which request made it. One map for the probe, the by-ear metronome,
    /// the A/B receipt and the audition — but every rule keyed on all three,
    /// so a refused legacy request cannot orphan a live audition and a reply
    /// from a replaced request cannot stop its successor.
    private let alignmentOwners = CompanionAlignmentOwnership()

    /// Cached `.regular` running-app list backing `addableApps`/`isRunning` in
    /// the snapshot (FIX-B2 finding 2b). The host's app-lifecycle observers
    /// invalidate it (``invalidateRunningAppsCache()``) on the only edges that
    /// change it, and ``broadcastSnapshotNow()`` rebuilds lazily.
    private var runningAppsCache: [(bundleID: String, displayName: String)]?

    /// How many phones are connected right now, mirrored off
    /// `CompanionServer.onClientCountChanged` — the server exposes the edge,
    /// not a count anyone can read back.
    public private(set) var clientCount = 0

    /// The phone name the alignment wizard's iPhone panel shows, per
    /// `shape-mac-invites.md` §2.2. The name is the approval's own — the only
    /// phone identity this Mac ever shows — and it is given only when there is
    /// exactly one phone connected and exactly one on file, so the Mac never
    /// guesses which one is in the room.
    public var invitePhoneName: String? {
        let approved = approvals.approvals.filter { $0.decision == .approved }
        guard clientCount == 1, approved.count == 1 else { return nil }
        return approved[0].lastKnownName
    }

    private var isTerminating: Bool { host?.isTerminating ?? true }

    // MARK: Wiring

    /// Attach every companion trigger + the command/disconnect callbacks, then
    /// start the server if setting/env allow. Called once, at the END of
    /// `applicationDidFinishLaunching` (see the call site's ordering comment).
    /// `appRouting.onRoutesDidChange`, `groupController.onStateDidChange`,
    /// `excludedApps.onChange`, the icon-controller chain-wrap and the two
    /// `NSWorkspace` app-lifecycle observers are the exceptions — they are
    /// single-assignment closures the launch path already owns, so the
    /// companion tail rides inside them at their original sites rather than
    /// being reassigned here.
    public func wire() {
        dispatcher = CompanionCommandDispatcher(
            groupController: groupController,
            appRouting: appRouting,
            settings: settings,
            isExcluded: { [excludedBundleIDs] bundleID in excludedBundleIDs().contains(bundleID) },
            // Mirrors `popoverController.onSetLocalPlaybackVolume`: a
            // `.currentDevice` route's local stream moves immediately; no-ops
            // on backends without per-app local playback.
            setLocalPlaybackVolume: { [weak self] volume, bundleID in
                (self?.backend as? AppRouteConfiguring)?.setLocalPlaybackVolume(
                    volume: volume, bundleID: bundleID)
            },
            // Mirrors `makeLatencySettingModel()`'s apply closure: persist
            // FIRST, then reconnect — a partial reconnect failure must not
            // lose the chosen setting for the next launch.
            applyStartBuffer: { [weak self] ms in
                guard let self else { return }
                self.settings.startBufferMs = ms
                if let configurable = self.backend as? LatencyConfigurable {
                    await configurable.applyStartBuffer(ms: ms)
                }
                // FIX-B2 finding 1: this closure runs AFTER the command
                // turn's reply (it's fired from a Task), so nothing else
                // broadcasts the new buffer value — without this the phone
                // got applied:true and no state frame, and its picker
                // snapped back. Mirrors the Mac pane's own ordering, where
                // `onSettingChanged` fires after `await latency.apply`.
                await self.scheduleBroadcast()
            },
            alignmentActions: makeAlignmentActions())

        // A reconnect (or an alignment landing) changes what the phone's
        // speaker row says, and nothing else broadcasts for it — the timing
        // store is the only thing that saw the edge.
        (backend as? BTOutputControlling)?.onBTAlignmentChanged = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.isTerminating else { return }
                self.scheduleBroadcast()
            }
        }

        // Command path: server queue → main (ASYNC — a sync hop can deadlock
        // against `stop()`) → dispatcher → reply → immediate uncoalesced
        // broadcast for commands whose model effect is synchronous, so the
        // phone that acted sees the result state without waiting out the
        // coalescer window (async-echo commands ride the coalescer instead).
        server.onCommand = { [weak self] _, command, clientID, reply in
            DispatchQueue.main.async {
                // FIX-B2 finding 4: `weak self` alone was a dead guard
                // (main.swift retains the delegate for the process lifetime);
                // `isTerminating` is the real shutdown signal. A command
                // decoded just as the user quits must not reach `execute` →
                // `applyRouting` → a STOPPED backend, racing `stopAndWait`.
                guard let self, !self.isTerminating else {
                    reply(CompanionServer.CommandResult(applied: false, refusalReason: "Audiout is shutting down."))
                    return
                }
                // FIX-B2 finding 2a: per-client token bucket, refused before
                // any main-thread work is spent. A refusal costs the client
                // nothing once it slows down; the phone's own send policy
                // (≤20 Hz sliders) never hits it.
                guard self.rateLimiter.allowCommand(
                    from: clientID, now: ProcessInfo.processInfo.systemUptime) else {
                    reply(CompanionServer.CommandResult(
                        applied: false,
                        refusalReason: "Too many commands. Slow down and try again."))
                    return
                }
                // Icon requests are answered by the HOST, not in the
                // dispatcher: addressing the icon frames needs the client
                // identity and reading an icon needs AppKit, neither of which
                // that AppKit-free, client-agnostic type has
                // (CompanionCommandDispatcher.swift:219). Rate-limited like
                // every other command by the guard above.
                if case .requestAppIcons(let requested) = command {
                    reply(CompanionServer.CommandResult(applied: true))
                    self.host?.serveAppIconPages(requested, to: clientID)
                    return  // no snapshot broadcast — icons are not snapshot state
                }
                if case .setAlignmentTick(let targetID, let active) = command {
                    self.handleAlignmentTick(targetID: targetID, active: active,
                                             clientID: clientID, reply: reply)
                    return
                }
                let result = self.dispatcher.execute(command, clientID: clientID)
                reply(CompanionServer.CommandResult(
                    applied: result.applied,
                    refusalReason: result.refusalReason,
                    autoSwappedCurrentDevice: result.autoSwappedCurrentDevice))
                // FIX-B2 finding 6: the immediate broadcast is only honest for
                // commands whose full snapshot effect landed synchronously in
                // the controllers (selection, Main Out target, group CRUD,
                // app routes, connect volume). Volume/mute effects echo
                // asynchronously (backend `stateQueue` → `deviceUpdated`), so
                // their immediate snapshot is GUARANTEED to carry pre-command
                // device volumes (e.g. `isMuted: true, volume: 60`), and a
                // snapshot-bound phone slider would fight the finger mid-drag
                // — those ride the coalescer, which the backend echo (and
                // `onStateDidChange` for mutes) re-arms with settled values.
                // `setMainOutMasterVolume` is in the SYNCHRONOUS set since the
                // volume decoupling: Main is `GroupController`'s own stored
                // value, written before `execute` returns, and moving it
                // rewrites no device level — the immediate snapshot is exact.
                // `setStartBufferMs` is async too; finding 1's post-apply
                // schedule carries it.
                // The alignment family is asynchronous for the same reason:
                // what a run or a commit changes in the snapshot lands through
                // the backend's own queues and the timing store's callback,
                // so an immediate rebuild is guaranteed to carry the state
                // from before the command.
                let effectIsAsynchronous: Bool
                switch command {
                case .setDeviceVolume, .setDeviceMuted,
                     .setMainOutMuted, .setGroupMuted, .setStartBufferMs,
                     .startAlignmentProbe, .cancelAlignmentProbe,
                     .reportAlignmentMeasurement, .setAlignmentTick,
                     .nudgeAlignmentTrim, .revertAlignmentNudge,
                     .clearAlignmentTuning, .playAlignmentDemo:
                    effectIsAsynchronous = true
                default:
                    effectIsAsynchronous = false
                }
                if effectIsAsynchronous {
                    self.scheduleBroadcast()
                } else {
                    self.broadcastSnapshotNow()
                }
            }
        }

        // A vanished client only needs its rate-limiter bucket dropped —
        // there is no per-client server-side state left to strand (the Main
        // Out drag bracket this used to close is gone with the volume
        // decoupling; Main is a stateless set now). FIX-B2 finding 4: gated
        // on `isTerminating` like the command path.
        // The Setup card and the wizard's iPhone panel both read "is a phone
        // here right now", and this callback is the only place that knows.
        // Hops to the main actor — the server fires on its own queue.
        server.onClientCountChanged = { [weak self] count in
            DispatchQueue.main.async { self?.noteClientCount(count) }
        }
        server.onClientDisconnected = { [weak self] clientID in
            DispatchQueue.main.async {
                guard let self, !self.isTerminating else { return }
                self.rateLimiter.forgetClient(clientID)
                // A run, a fine-tune session and an A/B receipt are all
                // per-client state, and a phone that walks out of range would
                // otherwise leave the room holding a sweep feed with every
                // other speaker silent, or a metronome nobody can stop. The
                // backend's cancel is what each of them means when the client
                // goes: a run is abandoned and its suspended nudge restored, a
                // receipt is put back, and a fine-tune session ENDS — writing
                // down what the user had already nudged, rather
                // than throwing it away.
                // An audition is stood down at once but stays OWNED while its
                // cleanup drains, so nothing else starts over a room still
                // being put back; its lifetime signal retires it.
                self.alignmentOwners.disconnect(
                    clientID: clientID,
                    stopAudition: { [weak self] id in self?.stopAudition(targetID: id) },
                    cancelLegacy: { [weak self] id in
                        (self?.backend as? BTOutputControlling)?
                            .cancelCompanionAlignmentProbe(targetID: id)
                    })
            }
        }

        // Per-phone approval gate (T24). The server holds every helloed
        // connection until `approvals` answers — from the store for a
        // remembered phone (instant, no UI), via the one-per-clientID prompt
        // for an unknown one. Server queue → main ASYNC, the same discipline
        // as onCommand; if we're terminating, don't answer — the server
        // teardown closes the held connection, and no decision gets persisted
        // on the way out.
        // Read per welcome, not captured once: a licence check-in that lands
        // after the server started still reaches the next phone to connect.
        server.companionToken = { [settings] in settings.companionToken }
        server.serverID = { [settings] in settings.companionServerID }
        server.onApprovalRequest = { [weak self] clientID, clientName, decide in
            DispatchQueue.main.async {
                guard let self, !self.isTerminating else { return }
                self.approvals.handleRequest(
                    clientID: clientID, clientName: clientName, decide: decide)
            }
        }
        // The last connection carrying this phone identity died before the
        // user answered — withdraw its prompt rather than leave it stranded.
        server.onApprovalAbandoned = { [weak self] clientID in
            DispatchQueue.main.async {
                guard let self, !self.isTerminating else { return }
                self.approvals.abandonRequest(clientID: clientID)
            }
        }
        approvals.presentPrompt = { [weak self] clientID, clientName, respond in
            self?.host?.presentApprovalPrompt(clientID: clientID, clientName: clientName,
                                              respond: respond)
        }
        approvals.withdrawPrompt = { [weak self] clientID in
            self?.host?.withdrawApprovalPrompt(clientID: clientID)
        }
        // Revoking a phone in Settings must also disconnect it if it's live.
        approvals.dropClient = { [weak self] clientID in
            self?.server.dropClient(clientID: clientID)
        }

        updateServerState()
    }

    /// Start or stop the companion server to match
    /// `AppSettings.resolvedAllowRemoteControl` (env override → persisted
    /// checkbox). Called at launch and from the Settings › General checkbox
    /// callback; a no-op when nothing changed. On start, broadcasts an initial
    /// snapshot IMMEDIATELY — the server defers a helloed client's `welcome`
    /// until the first broadcast, so an early client would otherwise hang.
    public func updateServerState() {
        let shouldRun = AppSettings.resolvedAllowRemoteControl(settings: settings)
        guard shouldRun != isActive else { return }
        isActive = shouldRun
        if shouldRun {
            server.start(name: serverName)
            broadcastSnapshotNow()
            host?.log("companion server started (\(serverName))")
        } else {
            broadcastWork?.cancel()
            broadcastWork = nil
            // `disabled`, not the `shutdown` default: the phone settles
            // quietly and waits for the Mac to re-advertise instead of
            // treating the close as a transport error and redialing. The
            // terminate path (``shutDown()``) keeps `shutdown`.
            server.stop(reason: CompanionGoodbyeReason.disabled)
            host?.log("companion server stopped")
        }
    }

    /// Stop the server alongside the backend on quit, so connected phones see
    /// a clean close instead of a dead socket. `stop()` is a cheap synchronous
    /// cancel (see its doc comment) — safe inline on the terminate path.
    public func shutDown() {
        broadcastWork?.cancel()
        broadcastWork = nil
        isActive = false
        server.stop()
    }

    /// A licence that lands while phones are connected: push the token their
    /// welcome would have carried, once per distinct token.
    public func pushCompanionToken(_ token: String) {
        guard token != pushedCompanionToken else { return }
        pushedCompanionToken = token
        server.sendCompanionToken(token)
    }

    // MARK: Snapshot inputs owned by the app's event handler

    /// A phone arrived or left.
    public func noteClientCount(_ count: Int) {
        clientCount = count
        host?.clientCountDidChange(count)
    }

    /// Remember a name past a later `deviceRemoved`, so a saved group can
    /// still label an offline member in `GroupState.memberNames`.
    public func noteDeviceName(id: String, name: String) {
        knownDeviceNamesByID[id] = name
    }

    public func noteLocalFallbackActive(_ active: Bool) {
        localFallbackActive = active
    }

    public func noteSystemDefaultIsAirPlayActive(_ active: Bool) {
        systemDefaultIsAirPlayActive = active
    }

    public func noteTakeoverStatus(_ status: TakeoverStatus?) {
        takeoverStatus = status
    }

    /// An app launched or quit: the cached running-app list is stale.
    public func invalidateRunningAppsCache() {
        runningAppsCache = nil
    }

    // MARK: Broadcast

    /// Coalesce every snapshot-affecting trigger into one build ~50 ms out.
    /// Trailing edge only: the first trigger arms the work item, further
    /// triggers inside the window ride it for free. The server additionally
    /// suppresses identical snapshots, so a spurious trigger costs one build,
    /// never a network frame.
    public func scheduleBroadcast() {
        guard isActive, broadcastWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.broadcastWork = nil
            self.broadcastSnapshotNow()
        }
        broadcastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Build the full snapshot from the live controllers and hand it to the
    /// server (which owns encoding + identical-snapshot suppression).
    public func broadcastSnapshotNow() {
        guard isActive, let host else { return }
        let running = runningApps()
        let routedIDs = Set(appRouting.appRoutes.map(\.bundleID))
        let addable = addableApps()
        let snapshot = CompanionSnapshotBuilder.build(
            // Sorted for a deterministic wire order: the host's fleet is a
            // dictionary's values, and an order flap would defeat the server's
            // identical-snapshot suppression.
            devices: alignmentDevices,
            groupController: groupController,
            appRouting: appRouting,
            excludedBundleIDs: excludedBundleIDs(),
            iconFor: { device in host.symbolName(for: device) },
            addableApps: addable,
            runningRouted: routedIDs.intersection(running.map(\.bundleID)),
            liveRoutedAppNames: host.routedAppNames(),
            localFallbackActive: localFallbackActive,
            takeoverStatus: takeoverStatus.map(Self.takeoverText),
            systemDefaultIsAirPlayActive: systemDefaultIsAirPlayActive,
            knownDeviceNames: knownDeviceNamesByID,
            serverName: serverName,
            connectVolume: settings.connectVolume,
            connectVolumeMin: AppSettings.minConnectVolume,
            connectVolumeMax: AppSettings.maxConnectVolume,
            startBufferMs: settings.startBufferMs,
            startBufferOptionsMs: AppSettings.startBufferOptionsMs,
            // Bluetooth rows only, and only under a backend that keeps the
            // store and watches the link edges — everything else reports no
            // alignment at all, which the phone reads as "not reported".
            alignmentFor: { [weak self] device in
                (self?.backend as? BTOutputControlling)?.btAlignmentReport(forDevice: device.id)
            })
        server.broadcast(snapshot)
    }

    /// The cached-or-rebuilt `.regular` running-app list (FIX-B2 finding 2b).
    /// The enumeration was the dominant per-broadcast cost, so the host's
    /// launch/terminate observers invalidate this on exactly the edges that
    /// change it.
    private func runningApps() -> [(bundleID: String, displayName: String)] {
        if let cached = runningAppsCache { return cached }
        let rebuilt = host?.runningApplications() ?? []
        runningAppsCache = rebuilt
        return rebuilt
    }

    /// The apps the phone may still add a route for: running `.regular` apps,
    /// minus already-routed, minus excluded — the popover picker's own recipe
    /// (`PopoverController.availableAppsForPicker`). ONE definition, read by
    /// both the snapshot broadcast and the icon-request allow-set, so what the
    /// phone can see and what it may ask an icon for can never drift apart.
    public func addableApps() -> [(bundleID: String, displayName: String)] {
        let routedIDs = Set(appRouting.appRoutes.map(\.bundleID))
        let excluded = excludedBundleIDs()
        return runningApps()
            .filter { !routedIDs.contains($0.bundleID) && !excluded.contains($0.bundleID) }
    }

    /// The live device list in a stable order, for the two Core-level
    /// alignment rules that read the whole room.
    private var alignmentDevices: [Device] {
        (host?.devices() ?? []).sorted { $0.id < $1.id }
    }

    /// The wire copy for `Snapshot.takeoverStatus` — the same plain language
    /// as the popover's takeover strip. Duplicated because
    /// `PopoverController.takeoverStatusText(for:)` is internal to
    /// `AudioutPopoverUI`; keep the two in sync (follow-up: make that helper
    /// public and delete this copy).
    private nonisolated static func takeoverText(_ status: TakeoverStatus) -> String {
        switch status {
        case .needsApproval:
            return "Speaker Sync needs permission to run. Open Login Items to approve it."
        case .helperMissing:
            return "Speaker Sync is missing from this copy of Audiout. Reinstall Audiout to fix it."
        case .takingOver:
            return "Taking audio back from macOS…"
        case .timedOut:
            return "Another app is using AirPlay's timing right now, so this connection couldn't complete. Try again in a moment."
        }
    }

    // MARK: Speaker clicks (the audition)

    private func handleAlignmentTick(
        targetID: String, active: Bool, clientID: UUID,
        reply: @escaping @Sendable (CompanionServer.CommandResult) -> Void
    ) {
        if let reason = CompanionCommandDispatcher.alignmentTargetIDRefusal(targetID) {
            reply(.init(applied: false, refusalReason: reason))
            return
        }
        guard let bt = backend as? BTOutputControlling else {
            reply(.init(applied: false, refusalReason: "This Mac can't measure speaker timing right now."))
            return
        }
        guard active else {
            if let entry = alignmentOwners.current(targetID: targetID),
               entry.clientID != clientID {
                reply(.init(applied: false,
                            refusalReason: "A different speaker click session is running."))
                return
            }
            // A stop ALWAYS reaches the backend, repeat or not — and with
            // nothing running it is the no-op it has always been. Each command
            // gets its own one-shot reply from the cleanup it joins, and
            // ownership stays until the backend says its reservation is gone.
            _ = alignmentOwners.markExplicitAuditionStop(targetID: targetID, clientID: clientID)
            bt.endCompanionAlignmentAudition(targetID: targetID) { [weak self] reason in
                DispatchQueue.main.async {
                    reply(.init(applied: reason == nil, refusalReason: reason))
                    self?.scheduleBroadcast()
                }
            }
            return
        }
        let referenceID: String
        switch CompanionAlignmentPreconditions.evaluate(
            targetID: targetID, among: alignmentDevices,
            isAudible: groupController.isMainOutMember
        ) {
        case .refused(let reason):
            reply(.init(applied: false, refusalReason: reason))
            return
        case .ready(let id): referenceID = id
        }
        let entry: CompanionAlignmentOwnership.Entry
        let isFreshClaim: Bool
        switch alignmentOwners.claim(targetID: targetID, clientID: clientID, kind: .audition,
                                     referenceID: referenceID,
                                     leaseDeadline: Date().addingTimeInterval(600)) {
        case .refused(let reason):
            reply(.init(applied: false, refusalReason: reason))
            return
        case .fresh(let fresh):
            entry = fresh
            isFreshClaim = true
            // Armed once, off the ORIGINAL lease. Repeated starts join the
            // same entry and arm nothing, so the budget cannot be renewed.
            monitorAuditionLease(targetID: targetID, requestID: fresh.requestID,
                                 deadline: fresh.leaseDeadline ?? Date())
        case .existing(let existing):
            entry = existing
            isFreshClaim = false
        }
        let requestID = entry.requestID
        // The one ordinary retirement signal. Nothing here polls or guesses
        // when the cleanup ended: the backend fires this after its reservation
        // is actually gone, and a refused start fires it behind its refusal.
        let onReleased: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.alignmentOwners.release(targetID: targetID, kind: .audition,
                                                requestID: requestID) {
                    self.scheduleBroadcast()
                }
            }
        }
        bt.startCompanionAlignmentAudition(
            targetID: targetID, referenceID: referenceID, onReleased: onReleased
        ) { [weak self] reason in
            DispatchQueue.main.async {
                guard let self else {
                    reply(.init(applied: false, refusalReason: "Audiout is shutting down."))
                    return
                }
                if let reason {
                    reply(.init(applied: false, refusalReason: reason))
                    self.scheduleBroadcast()
                    return
                }
                let samePair: Bool
                switch CompanionAlignmentPreconditions.evaluate(
                    targetID: targetID, among: self.alignmentDevices,
                    isAudible: self.groupController.isMainOutMember
                ) {
                case .ready(let currentReference): samePair = currentReference == referenceID
                case .refused: samePair = false
                }
                guard samePair, !self.isTerminating else {
                    // Token-checked like every other cleanup trigger, so this
                    // completion cannot stand down a request that replaced it.
                    self.alignmentOwners.requestAuditionCleanup(
                        targetID: targetID, requestID: requestID,
                        stop: { [weak self] id in self?.stopAudition(targetID: id) })
                    reply(.init(applied: false,
                        refusalReason: "The speaker pair changed before clicks could start."))
                    self.scheduleBroadcast()
                    return
                }
                reply(.init(applied: true))
                self.scheduleBroadcast()
                // One monitor per audition, not per start: it rearms itself
                // every 0.25 s for the audition's life, so arming it again on
                // each reopen would leave a stack of them running.
                if isFreshClaim {
                    self.monitorAuditionOwner(targetID: targetID,
                                              referenceID: referenceID, requestID: requestID)
                }
            }
        }
    }

    /// The one backend call every autonomous cleanup trigger makes. Its own
    /// completion is ignored on purpose: this is not a phone's command, so
    /// there is nobody to answer — the lifetime signal retires the owner.
    private func stopAudition(targetID: String) {
        (backend as? BTOutputControlling)?.endCompanionAlignmentAudition(
            targetID: targetID, completion: { _ in })
    }

    private func monitorAuditionLease(targetID: String, requestID: UUID, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) {
            [weak self] in
            guard let self else { return }
            self.alignmentOwners.expireAudition(
                targetID: targetID, requestID: requestID,
                stopAudition: { [weak self] id in self?.stopAudition(targetID: id) })
        }
    }

    private func monitorAuditionOwner(targetID: String, referenceID: String, requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.isTerminating,
                  let entry = self.alignmentOwners.current(targetID: targetID),
                  entry.kind == .audition, entry.requestID == requestID,
                  !entry.cleanupRequested else { return }
            let samePair: Bool
            switch CompanionAlignmentPreconditions.evaluate(
                targetID: targetID, among: self.alignmentDevices,
                isAudible: self.groupController.isMainOutMember
            ) {
            case .ready(let currentReference): samePair = currentReference == referenceID
            case .refused: samePair = false
            }
            if samePair {
                self.monitorAuditionOwner(targetID: targetID,
                                          referenceID: referenceID, requestID: requestID)
            } else {
                self.alignmentOwners.requestAuditionCleanup(
                    targetID: targetID, requestID: requestID,
                    stop: { [weak self] id in self?.stopAudition(targetID: id) })
                self.scheduleBroadcast()
            }
        }
    }

    // MARK: The eight sync-calibration actuators

    /// The eight sync-calibration actuators the companion dispatcher calls.
    ///
    /// Decision 5's preconditions and the sentences they refuse with live in
    /// `CompanionAlignmentPreconditions`, not here. What remains here is
    /// wiring — which backend, which live device list, and which phone asked.
    /// The backend answers only what it alone knows: whether the target has a
    /// live delay line, and whether anything else is already running.
    private func makeAlignmentActions() -> CompanionAlignmentActions {
        CompanionAlignmentActions(
            startProbe: { [weak self] targetID, clientID in
                guard let self, let bt = self.backend as? BTOutputControlling else {
                    return "This Mac can't measure speaker timing."
                }
                if let busy = self.legacyAlignmentRefusal(targetID: targetID) { return busy }
                let referenceID: String
                switch CompanionAlignmentPreconditions.evaluate(
                    targetID: targetID,
                    among: self.alignmentDevices,
                    isAudible: self.groupController.isMainOutMember
                ) {
                case .refused(let reason):
                    return reason
                case .ready(let id):
                    referenceID = id
                }
                // Claimed BEFORE the backend call, so a second phone is refused
                // rather than racing it, and given back if the run never staged
                // — but ONLY if this call is what created it. A repeat request
                // joins the run already going, and giving THAT back would erase
                // the owner the first run's events are addressed to.
                var claim: CompanionAlignmentOwnership.Claim?
                if let clientID {
                    let attempt = self.alignmentOwners.claim(
                        targetID: targetID, clientID: clientID, kind: .probe,
                        referenceID: referenceID, leaseDeadline: nil)
                    if case .refused(let reason) = attempt { return reason }
                    claim = attempt
                }
                let refusal = bt.startCompanionAlignmentProbe(
                    targetID: targetID, referenceID: referenceID,
                    onStarted: { [weak self] in
                        self?.sendProbeEvent(targetID: targetID, started: true)
                    },
                    onFinished: { [weak self] in
                        self?.sendProbeEvent(targetID: targetID, started: false)
                    })
                if refusal != nil, let claim {
                    self.alignmentOwners.releaseFresh(claim, targetID: targetID)
                }
                return refusal
            },
            cancelProbe: { [weak self] targetID, clientID in
                guard let self else { return nil }
                // Cancel is the legacy family's exit, never the audition's:
                // that one is stopped by its own tick command.
                if let busy = self.legacyAlignmentRefusal(targetID: targetID) { return busy }
                // And it is the OWNER's exit. Another phone's cancel neither
                // erases this owner nor reaches the backend to stop its run —
                // erasing it would also disarm the disconnect that is supposed
                // to put the room back, leaving a metronome nobody can stop.
                if self.alignmentOwners.current(targetID: targetID) != nil {
                    guard let clientID,
                          self.alignmentOwners.releaseOwned(targetID: targetID,
                                                            clientID: clientID) != nil else {
                        return "Another phone is using these speaker clicks."
                    }
                }
                (self.backend as? BTOutputControlling)?
                    .cancelCompanionAlignmentProbe(targetID: targetID)
                return nil
            },
            reportMeasurement: { [weak self] targetID, offsetMs, confidence in
                // `confidence` rides the wire for the PHONE's own gate — it
                // decides whether a recording was clean enough to report at
                // all. A measurement that arrives has already passed that, and
                // the Mac has nothing better to judge it with, so it does not
                // gate on it — it only records it, for the measurement log.
                guard let self, let bt = self.backend as? BTOutputControlling else {
                    return "This Mac can't measure speaker timing."
                }
                if let busy = self.legacyAlignmentRefusal(targetID: targetID) { return busy }
                let clientID = self.alignmentOwners.takeProbeForReport(targetID: targetID)
                switch bt.applyCompanionAlignmentMeasurement(
                    targetID: targetID, offsetMs: offsetMs, confidence: confidence) {
                case .refused(let reason):
                    return reason
                case .applied(let measuredMs, let correctedMs):
                    // Enqueued on the server queue before this command's own
                    // reply is, so it reaches the phone first — but the phone
                    // does not lean on that order.
                    if let clientID {
                        // Read back rather than returned: the row's source is
                        // the timing module's to decide, and reading it here
                        // is what keeps this message and the snapshot that
                        // follows it saying the same thing.
                        self.server.sendAlignmentApplied(
                            deviceID: targetID, measuredMs: measuredMs,
                            correctedMs: correctedMs,
                            source: bt.btAlignmentReport(forDevice: targetID)?.source?.rawValue,
                            to: clientID)
                    }
                    // T16: `correctedMs` already carries how far this
                    // measurement moved the stored latency — 0 when it left
                    // it unchanged — so its size is the same fact
                    // `recordMeasurement`'s replace/keep decision turns on,
                    // without asking the backend a second question. Fires
                    // whether or not a phone is still attached to read it.
                    if abs(correctedMs) >= AlignmentThresholds.tellUserMs {
                        self.host?.alignmentMoved(deviceID: targetID, byMs: correctedMs)
                    }
                    return nil
                }
            },
            setTick: { [weak self] targetID, active, clientID in
                guard let self, let bt = self.backend as? BTOutputControlling else {
                    return "This Mac can't measure speaker timing."
                }
                if let busy = self.legacyAlignmentRefusal(targetID: targetID) { return busy }
                // A fine-tune session is per-client state exactly as a run is,
                // and it is the half that leaves a metronome in the room and
                // the user's nudges unwritten if the phone vanishes.
                if active {
                    var claim: CompanionAlignmentOwnership.Claim?
                    if let clientID {
                        let attempt = self.alignmentOwners.claim(
                            targetID: targetID, clientID: clientID, kind: .legacyTick,
                            referenceID: nil, leaseDeadline: nil)
                        if case .refused(let reason) = attempt { return reason }
                        claim = attempt
                    }
                    let refusal = bt.setCompanionAlignmentTick(targetID: targetID, active: true)
                    // Only a claim this call created; a repeat joins the session
                    // already running and has nothing of its own to give back.
                    if refusal != nil, let claim {
                        self.alignmentOwners.releaseFresh(claim, targetID: targetID)
                    }
                    return refusal
                }
                // Switching the metronome off is the owner's exit, like Cancel:
                // checked BEFORE the backend, so another phone neither ends this
                // session nor stops the ticks it is still listening to.
                if self.alignmentOwners.current(targetID: targetID)?.kind == .legacyTick {
                    guard let clientID,
                          self.alignmentOwners.releaseOwned(targetID: targetID,
                                                            clientID: clientID) != nil else {
                        return "Another phone is using these speaker clicks."
                    }
                }
                return bt.setCompanionAlignmentTick(targetID: targetID, active: false)
            },
            nudgeTrim: { [weak self] targetID, deltaMs in
                guard let bt = self?.backend as? BTOutputControlling else {
                    return "This Mac can't measure speaker timing."
                }
                return bt.nudgeCompanionAlignmentTrim(targetID: targetID, deltaMs: deltaMs)
            },
            revertNudge: { [weak self] targetID in
                guard let bt = self?.backend as? BTOutputControlling else {
                    return "This Mac can't measure speaker timing."
                }
                return bt.revertCompanionAlignmentNudge(targetID: targetID)
            },
            clearTuning: { [weak self] targetID in
                guard let self, let bt = self.backend as? BTOutputControlling else {
                    return "This Mac can't measure speaker timing."
                }
                // The phone's own Clear is ordered AFTER its stop is
                // acknowledged; one arriving while the clicks still own the
                // speaker is the legacy path, and it waits.
                if let busy = self.legacyAlignmentRefusal(targetID: targetID) { return busy }
                bt.clearCompanionAlignmentTuning(targetID: targetID)
                return nil
            },
            playDemo: { [weak self] targetID, clientID in
                guard let self, let bt = self.backend as? BTOutputControlling else {
                    return "This Mac can't measure speaker timing."
                }
                if let busy = self.legacyAlignmentRefusal(targetID: targetID) { return busy }
                var claim: CompanionAlignmentOwnership.Claim?
                if let clientID {
                    let attempt = self.alignmentOwners.claim(
                        targetID: targetID, clientID: clientID, kind: .demo,
                        referenceID: nil, leaseDeadline: nil)
                    if case .refused(let reason) = attempt { return reason }
                    claim = attempt
                }
                let refusal = bt.playCompanionAlignmentDemo(
                    targetID: targetID,
                    referenceID: self.alignmentReferenceID(forTarget: targetID))
                guard let claim else { return refusal }
                if refusal != nil {
                    self.alignmentOwners.releaseFresh(claim, targetID: targetID)
                    return refusal
                }
                let entry: CompanionAlignmentOwnership.Entry
                switch claim {
                case .fresh(let created): entry = created
                case .existing(let joined): entry = joined
                case .refused: return refusal
                }
                // Four seconds of held-silent speakers is short, but a phone
                // that drops inside it must still put the room back — and the
                // backend ends a receipt on its own clock and reports nothing,
                // so the owner retires on the same clock. A SECOND receipt
                // started inside that window is a new run with its own four
                // seconds, so the release quotes the run it belongs to and the
                // earlier one's timer finds a newer run and does nothing.
                let requestID = entry.requestID
                let run = self.alignmentOwners.noteDemoStarted(targetID: targetID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { [weak self] in
                    self?.alignmentOwners.releaseDemoRun(targetID: targetID,
                                                         requestID: requestID, run: run)
                }
                return refusal
            })
    }

    /// The speaker a run for `targetID` would be measured against — the SAME
    /// rule, over the same inputs, that puts `referenceID` in every snapshot.
    /// One function, so the phone's CTA and what a run actually plays can
    /// never be two different speakers.
    ///
    /// `isMainOutMember` is the audible read, never `isSpeakerSelected`: under
    /// a saved-group Main Out target the latter is wrong in both directions,
    /// so it would hide every group member from the run's candidates and
    /// publish no reference at all for a room that is plainly playing.
    private func alignmentReferenceID(forTarget targetID: String) -> String? {
        CompanionSnapshotBuilder.alignmentReferenceID(
            forTarget: targetID,
            among: alignmentDevices,
            isAudible: groupController.isMainOutMember)
    }

    /// The sentence every legacy alignment action is refused with while the
    /// speaker clicks own the speaker, and `nil` when they do not. None of
    /// those paths may reach a backend method that would stand an audition
    /// down: the phone's own stop command is the only thing that ends it.
    private func legacyAlignmentRefusal(targetID: String) -> String? {
        guard alignmentOwners.current(targetID: targetID)?.kind == .audition else { return nil }
        return "This Mac is already playing or restoring speaker clicks. Finish that first."
    }

    /// Address one of the run's two moments back to the phone that staged it,
    /// and to nobody else. Fired from the pacer's own thread, so it hops.
    private nonisolated func sendProbeEvent(targetID: String, started: Bool) {
        DispatchQueue.main.async { [weak self] in
            // A probe event goes only to a CURRENT probe owner: an audition or
            // a later job on the same speaker is not this run's audience.
            guard let self, !self.isTerminating,
                  let entry = self.alignmentOwners.current(targetID: targetID),
                  entry.kind == .probe else { return }
            let clientID = entry.clientID
            if started {
                // The Mac runs one alignment at a time, so a by-ear sheet
                // open on this same speaker has been superseded.
                self.host?.alignmentRunStarted(deviceID: targetID)
                self.server.sendAlignmentProbeStarted(deviceID: targetID, to: clientID)
            } else {
                self.server.sendAlignmentProbeFinished(deviceID: targetID, to: clientID)
            }
        }
    }
}
