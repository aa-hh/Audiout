// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One phone the Mac's user has answered an approval prompt for
/// (PLAN-COMPANION-APP T24 / D2 REVISED). Keyed by `clientID`, the uppercase
/// hex SHA-256 of the phone's public key (`CompanionPairing.clientID`), which
/// `CompanionServer` only passes on after the phone's signature proved it
/// holds that key. Denials are remembered on purpose — a denied phone must
/// not re-prompt on every reconnect — and are revocable from Settings ›
/// Audiout Remote exactly like approvals; at most
/// `CompanionApprovalController.maxRememberedDenials` are kept.
public struct CompanionApproval: Codable, Equatable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case approved, denied
    }

    public var clientID: String
    /// The phone's `hello.clientName` as of its last connect — display only,
    /// already truncated by the server; the identity is `clientID`.
    public var lastKnownName: String
    public var decision: Decision
    public var firstSeen: Date
    public var lastSeen: Date

    public init(clientID: String, lastKnownName: String, decision: Decision, firstSeen: Date, lastSeen: Date) {
        self.clientID = clientID
        self.lastKnownName = lastKnownName
        self.decision = decision
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// Codable, versioned JSON persistence for per-phone approvals — a sibling of
/// `ExcludedAppsStore`/`GroupStore`/`RoutingStore`: same Application Support
/// directory, its own file, same `{schemaVersion, payload}` envelope with the
/// same refuse-forward guard. The directory is injectable so tests never touch
/// the real `~/Library/Application Support`.
public struct CompanionApprovalStore: Sendable {

    struct Envelope: Codable {
        var schemaVersion: Int
        var approvals: [CompanionApproval]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where `companion-approvals.json` lives. Defaults
    ///   to the same `Application Support/Audiout/` directory as the other
    ///   stores; tests pass a throwaway temp directory.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("companion-approvals.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Load the saved approvals. Missing file → `nil` (first run — no phone
    /// has ever asked). A file from a newer schema is treated as missing
    /// rather than crashing an older build (refuse-forward). Note the failure
    /// direction for a TRUST store: an unreadable file means unknown phones,
    /// which re-prompt — never silent approval.
    /// The file is moved aside first (`StoreRecovery.quarantine`) so the next save cannot overwrite a file this build cannot read.
    public func load() throws -> [CompanionApproval]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            StoreRecovery.quarantine(fileURL)
            throw error
        }
        guard envelope.schemaVersion <= Self.currentSchemaVersion else {
            StoreRecovery.quarantine(fileURL)
            return nil
        }
        return envelope.approvals
    }

    /// Overwrite the saved approvals, creating the directory/file if needed.
    public func save(_ approvals: [CompanionApproval]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, approvals: approvals)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// The in-memory model over `CompanionApprovalStore` — the ONE place the
/// three approval consumers meet (mirrors `ExcludedAppsController`'s
/// store-plus-model split, kept in this file because the pair only makes
/// sense together):
///
/// - `CompanionServer.onApprovalRequest` funnels every helloed connection
///   through ``handleRequest(clientID:clientName:pairingCode:decide:)`` (via
///   the app layer's main-thread hop): a remembered phone resolves instantly
///   with no UI; an unknown phone is refused with `.pairingClosed` unless
///   ``isPairingOpen`` says the user opened a pairing window, and is otherwise
///   held (`decide(.pending)`) while its prompt waits its turn. One prompt is
///   on screen at a time, the next one no sooner than ``promptCooldown``
///   after the last was answered or withdrawn, so a stream of strangers can
///   neither stack alerts nor slip one under a click aimed at the previous
///   one. Reconnects of a phone whose prompt is open or queued join its
///   waiter list, and the user's single answer resolves them all.
/// - The app layer supplies ``presentPrompt`` (the actual `NSAlert` — this
///   type is UI-free so it can be tested headlessly) and ``withdrawPrompt``
///   (close a prompt whose connection died before the user answered), plus
///   ``dropClient`` (revoking an approval must also disconnect that phone if
///   it's live).
/// - Settings › Audiout Remote reads ``approvals`` and calls
///   ``revoke(clientID:)``.
@MainActor
public final class CompanionApprovalController {

    /// The quiet gap between one prompt closing and the next one opening.
    public static let promptCooldown: TimeInterval = 10

    /// Denials are kept so a refused phone stays quiet, but no more than
    /// this many: the oldest go first, and a phone whose denial was dropped
    /// simply asks again inside a pairing window.
    public static let maxRememberedDenials = 8

    private let store: CompanionApprovalStore
    public private(set) var approvals: [CompanionApproval]

    /// Deciders held while this clientID's prompt is open or queued — every
    /// connection that helloed with that ID while the user hadn't answered
    /// yet.
    private var pendingDeciders: [String: [(CompanionServer.ApprovalDecision) -> Void]] = [:]

    /// Unknown phones waiting for their prompt, oldest first.
    private var promptQueue: [(clientID: String, clientName: String, code: String)] = []
    /// The phone whose prompt is on screen, if any.
    private var activePromptClientID: String?
    /// No prompt opens before this moment.
    private var cooldownUntil: Date?

    /// Show the user "Allow an iPhone…?" with the six-digit `pairingCode` the
    /// phone is also showing, and call back with their answer, exactly once.
    /// Assigned by the app layer (`AppDelegate`); nil (unwired, e.g. a
    /// headless test that never expects a prompt) leaves the connection held
    /// until the server's own approval deadline closes it — never a silent
    /// approval.
    public var presentPrompt: ((_ clientID: String, _ clientName: String, _ pairingCode: String, _ respond: @escaping (Bool) -> Void) -> Void)?

    /// Close the prompt shown for this clientID — its connections are gone
    /// (dropped, or reaped by the server's approval deadline). Wired by the
    /// app layer; nil (unwired) leaves any on-screen alert as is.
    public var withdrawPrompt: ((_ clientID: String) -> Void)?

    /// Disconnect any live client with this clientID — fired on
    /// ``revoke(clientID:)`` (the app layer wires it to
    /// `CompanionServer.dropClient(clientID:)`).
    public var dropClient: ((String) -> Void)?

    /// The remembered list changed (decision recorded, name/lastSeen
    /// refreshed, or an entry revoked) — the Settings pane repaints from this.
    public var onChange: (() -> Void)?

    /// Whether the user has a pairing window open, read for every unknown
    /// phone. Fails closed: unwired, no unknown phone is ever prompted for.
    /// `CompanionCoordinator` wires it.
    public var isPairingOpen: () -> Bool = { false }

    /// Fired after a prompt records an approval and after ``revoke(clientID:)``
    /// removes one — whether any phone is approved decides whether the
    /// server runs outside a pairing window.
    public var onApprovedSetChanged: (() -> Void)?

    /// - Parameters:
    ///   - now: injectable clock so tests assert first/last-seen and the
    ///     prompt cooldown deterministically.
    ///   - schedule: runs a job after a delay on the main actor; it wakes the
    ///     prompt queue when a cooldown ends. Tests pass a recorder they fire
    ///     by hand.
    public init(store: CompanionApprovalStore = CompanionApprovalStore(),
                now: @escaping () -> Date = Date.init,
                schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, job in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { job() } }
                }) {
        self.store = store
        self.now = now
        self.schedule = schedule
        // Unreadable/missing/newer-schema all land on []: every phone is
        // unknown and re-prompts — the safe failure direction for trust state.
        self.approvals = ((try? store.load()) ?? nil) ?? []
    }

    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// One helloed connection asking to be let in. `decide` is
    /// `CompanionServer`'s continuation for that specific connection: called
    /// with `.approved`/`.denied`/`.pairingClosed` to settle it, or
    /// `.pending` first to hold it (the server then sends `awaitingApproval`
    /// so the phone shows its code and "check your Mac").
    public func handleRequest(clientID: String,
                              clientName: String,
                              pairingCode: String,
                              decide: @escaping (CompanionServer.ApprovalDecision) -> Void) {
        if let index = approvals.firstIndex(where: { $0.clientID == clientID }) {
            // Remembered — refresh the display name + lastSeen, answer from
            // the record, never prompt.
            approvals[index].lastKnownName = clientName
            approvals[index].lastSeen = now()
            persist()
            decide(approvals[index].decision == .approved ? .approved : .denied)
            return
        }
        guard isPairingOpen() else {
            // A stranger outside a window the user opened: refused without a
            // prompt and without a record.
            decide(.pairingClosed)
            return
        }

        decide(.pending)
        if pendingDeciders[clientID] != nil {
            // A prompt for this phone is already open or queued (it
            // reconnected while the user walks to the Mac) — join its
            // waiters, no second alert.
            pendingDeciders[clientID]?.append(decide)
            return
        }
        pendingDeciders[clientID] = [decide]
        promptQueue.append((clientID, clientName, pairingCode))
        showNextPromptIfIdle()
    }

    /// Opens the oldest queued prompt when none is on screen and the
    /// cooldown has passed. State is set before ``presentPrompt`` runs,
    /// because a prompt may answer synchronously.
    private func showNextPromptIfIdle() {
        guard activePromptClientID == nil, !promptQueue.isEmpty else { return }
        if let cooldownUntil, now() < cooldownUntil { return }
        let next = promptQueue.removeFirst()
        activePromptClientID = next.clientID
        presentPrompt?(next.clientID, next.clientName, next.code) { [weak self] allowed in
            self?.resolvePrompt(clientID: next.clientID, clientName: next.clientName, allowed: allowed)
        }
    }

    /// The on-screen prompt closed (answered or withdrawn): start the
    /// cooldown and wake the queue when it ends. The wake clears the
    /// cooldown itself, so a wall clock that lags the scheduler cannot
    /// strand a queued phone.
    private func finishActivePrompt() {
        activePromptClientID = nil
        cooldownUntil = now().addingTimeInterval(Self.promptCooldown)
        schedule(Self.promptCooldown) { [weak self] in
            self?.cooldownUntil = nil
            self?.showNextPromptIfIdle()
        }
    }

    private func resolvePrompt(clientID: String, clientName: String, allowed: Bool) {
        let timestamp = now()
        approvals.append(CompanionApproval(
            clientID: clientID,
            lastKnownName: clientName,
            decision: allowed ? .approved : .denied,
            firstSeen: timestamp,
            lastSeen: timestamp))
        if !allowed {
            let denials = approvals.filter { $0.decision == .denied }
                .sorted { $0.firstSeen < $1.firstSeen }
            let excess = Set(denials.prefix(max(0, denials.count - Self.maxRememberedDenials)).map(\.clientID))
            approvals.removeAll { $0.decision == .denied && excess.contains($0.clientID) }
        }
        persist()
        let waiters = pendingDeciders.removeValue(forKey: clientID) ?? []
        for decide in waiters {
            decide(allowed ? .approved : .denied)
        }
        if allowed { onApprovedSetChanged?() }
        // A late answer to a prompt that was already withdrawn must not end
        // the cooldown of whichever prompt followed it.
        if activePromptClientID == clientID { finishActivePrompt() }
    }

    /// The last connection awaiting this clientID's prompt died before the
    /// user answered (`CompanionServer.onApprovalAbandoned`). Drops the held
    /// deciders without calling them — their connections are already gone,
    /// so `resolveApproval` would no-op anyway. A prompt on screen is
    /// withdrawn and starts the cooldown; a prompt still queued is simply
    /// dropped. A clientID with neither (already resolved, or never
    /// prompted) is a no-op.
    public func abandonRequest(clientID: String) {
        guard pendingDeciders.removeValue(forKey: clientID) != nil else { return }
        if activePromptClientID == clientID {
            withdrawPrompt?(clientID)
            finishActivePrompt()
        } else {
            promptQueue.removeAll { $0.clientID == clientID }
        }
    }

    /// Forget a phone entirely (approval OR denial — a revoked denial simply
    /// re-prompts on its next connect inside a pairing window) and drop it
    /// if it's live right now.
    public func revoke(clientID: String) {
        guard approvals.contains(where: { $0.clientID == clientID }) else { return }
        let wasApproved = approvals.contains { $0.clientID == clientID && $0.decision == .approved }
        approvals.removeAll { $0.clientID == clientID }
        persist()
        dropClient?(clientID)
        if wasApproved { onApprovedSetChanged?() }
    }

    private func persist() {
        do {
            try store.save(approvals)
        } catch {
            StoreRecovery.noteWriteFailure(error)
        }
        onChange?()
    }
}
