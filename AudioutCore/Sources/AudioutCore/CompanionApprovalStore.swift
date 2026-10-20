// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One phone the Mac's user allowed (PLAN-COMPANION-APP T24). Keyed by
/// `clientID`, the uppercase hex SHA-256 of the phone's public key
/// (`CompanionPairing.clientID`), which `CompanionServer` only passes on after
/// the phone's signature proved it holds that key. It stays allowed until the
/// user removes it in Settings › Audiout Remote. Answers of "Don't Allow" are
/// never stored.
public struct CompanionApproval: Codable, Equatable, Sendable {
    /// Always `.approved` for a record this build writes. `.denied` is still
    /// decoded because older builds stored denials; ``CompanionApprovalController``
    /// drops those on load.
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

    public init(clientID: String, lastKnownName: String, decision: Decision = .approved,
                firstSeen: Date, lastSeen: Date) {
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
///   the app layer's main-thread hop): an allowed phone resolves instantly
///   with no prompt; any other phone is held (`decide(.pending)`) while its
///   prompt waits its turn, or turned away with `.paused` while the Mac is
///   ignoring new phones (``pauseAfterDenials`` "Don't Allow"s within
///   ``pauseDenialWindow`` start a ``pauseDuration`` pause, kept in memory
///   only). One prompt is on screen at a time, the next one no sooner than
///   ``promptCooldown`` after the last was answered or withdrawn, so a
///   stream of strangers can neither stack alerts nor slip one under a click
///   aimed at the previous one. Reconnects of a phone whose prompt is open or
///   queued join its waiter list, and the user's single answer resolves them
///   all.
/// - The app layer supplies ``presentPrompt`` (the actual `NSAlert` — this
///   type is UI-free so it can be tested headlessly) and ``withdrawPrompt``
///   (close a prompt whose connection died before the user answered), plus
///   ``dropClient`` (removing a phone must also disconnect it if it's live).
/// - Settings › Audiout Remote reads ``approvals`` and calls
///   ``revoke(clientID:)``.
@MainActor
public final class CompanionApprovalController {

    /// The quiet gap between one prompt closing and the next one opening.
    public static let promptCooldown: TimeInterval = 10

    /// This many "Don't Allow"s (any phones) within ``pauseDenialWindow``
    /// start a pause. A prompt that times out unanswered does not count.
    public static let pauseAfterDenials = 3
    public static let pauseDenialWindow: TimeInterval = 10 * 60
    /// How long the Mac turns new phones away once paused. Allowed phones
    /// are never paused.
    public static let pauseDuration: TimeInterval = 15 * 60

    private let store: CompanionApprovalStore

    /// The allowed phones. Settings, the Setup card and the wizard's phone
    /// name all read this.
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
    /// When each "Don't Allow" inside the current ``pauseDenialWindow`` was
    /// clicked.
    private var recentDenials: [Date] = []
    /// New phones are turned away until this moment.
    private var pausedUntil: Date?

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

    /// The allowed list changed (a phone allowed, its name/lastSeen
    /// refreshed, or one removed) — the Settings pane repaints from this.
    public var onChange: (() -> Void)?

    /// - Parameters:
    ///   - now: injectable clock so tests assert first/last-seen, the prompt
    ///     cooldown and the pause deterministically.
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
        let loaded = ((try? store.load()) ?? nil) ?? []
        // Denials an older build stored are dropped, and so is a protocol-v1
        // approval: it is keyed by a UUID no current phone can present.
        self.approvals = loaded.filter { $0.decision == .approved && Self.isPhoneKeyID($0.clientID) }
        if approvals.count != loaded.count { persist() }
    }

    /// Whether `clientID` has the shape `CompanionPairing.clientID` gives:
    /// 64 uppercase hex digits.
    private static func isPhoneKeyID(_ clientID: String) -> Bool {
        clientID.utf8.count == 64
            && clientID.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains($0) }
    }

    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// One helloed connection asking to be let in. `decide` is
    /// `CompanionServer`'s continuation for that specific connection: called
    /// with `.approved`/`.denied`/`.paused` to settle it, or `.pending` first
    /// to hold it (the server then sends `awaitingApproval` so the phone
    /// shows its code and "click Allow").
    public func handleRequest(clientID: String,
                              clientName: String,
                              pairingCode: String,
                              decide: @escaping (CompanionServer.ApprovalDecision) -> Void) {
        if let index = approvals.firstIndex(where: { $0.clientID == clientID }) {
            // Allowed — refresh the display name + lastSeen, never prompt.
            approvals[index].lastKnownName = clientName
            approvals[index].lastSeen = now()
            persist()
            decide(.approved)
            return
        }
        if let seconds = pauseSecondsLeft() {
            decide(.paused(seconds: seconds))
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

    /// Whole seconds until the pause ends, rounded up, or nil when there is
    /// no pause. Never more than ``pauseDuration``, so a clock set back
    /// cannot stretch it.
    private func pauseSecondsLeft() -> Int? {
        guard let pausedUntil else { return nil }
        let left = pausedUntil.timeIntervalSince(now())
        guard left > 0 else {
            self.pausedUntil = nil
            return nil
        }
        return Int(min(left, Self.pauseDuration).rounded(.up))
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
        if allowed {
            let timestamp = now()
            approvals.append(CompanionApproval(
                clientID: clientID, lastKnownName: clientName, firstSeen: timestamp, lastSeen: timestamp))
            persist()
        }
        let waiters = pendingDeciders.removeValue(forKey: clientID)
        for decide in waiters ?? [] {
            decide(allowed ? .approved : .denied)
        }
        // A pause this denial starts empties the queue before the cooldown
        // wake is scheduled, so no queued phone slips a prompt in.
        if !allowed { noteDenial() }
        // A late answer to a prompt that was already withdrawn must not end
        // the cooldown of whichever prompt followed it.
        if activePromptClientID == clientID { finishActivePrompt() }
    }

    /// Counts one "Don't Allow"; the one that reaches ``pauseAfterDenials``
    /// inside ``pauseDenialWindow`` starts the pause and turns away every
    /// phone still queued for a prompt, since the pause shows none.
    private func noteDenial() {
        let timestamp = now()
        recentDenials = recentDenials.filter { abs(timestamp.timeIntervalSince($0)) < Self.pauseDenialWindow }
        recentDenials.append(timestamp)
        guard recentDenials.count >= Self.pauseAfterDenials else { return }
        recentDenials.removeAll()
        pausedUntil = timestamp.addingTimeInterval(Self.pauseDuration)
        let seconds = Int(Self.pauseDuration)
        for queued in promptQueue {
            for decide in pendingDeciders.removeValue(forKey: queued.clientID) ?? [] {
                decide(.paused(seconds: seconds))
            }
        }
        promptQueue.removeAll()
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

    /// Forget an allowed phone (its next connect prompts again) and drop it
    /// if it's live right now.
    public func revoke(clientID: String) {
        guard approvals.contains(where: { $0.clientID == clientID }) else { return }
        approvals.removeAll { $0.clientID == clientID }
        persist()
        dropClient?(clientID)
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

/// The Mac's Allow prompt copy, here rather than in the app target so tests
/// can read it.
public enum CompanionApprovalPrompt {
    public static let messageText = "Allow an iPhone to control Audiout on this Mac?"

    /// The prompt's body. The phone's self-reported name is quoted only when
    /// it says more than "iPhone", which is all iOS reports without the
    /// device-name entitlement.
    public static func informativeText(clientName: String) -> String {
        let name = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGeneric = name.isEmpty || name.caseInsensitiveCompare("iPhone") == .orderedSame
        let calls = isGeneric ? "" : " It calls itself \"\(name)\"."
        return "Allow only if the iPhone shows the same code.\(calls)\n\n"
            + "It will see and control what's playing on this Mac's speakers, including which apps are playing. "
            + "You can remove it later in Settings › Audiout Remote."
    }

    /// "482913" → "482 913".
    public static func formattedCode(_ pairingCode: String) -> String {
        "\(pairingCode.prefix(3)) \(pairingCode.dropFirst(3))"
    }

    /// "482913" → "Pairing code 4 8 2 9 1 3", so VoiceOver reads digits,
    /// not two numbers.
    public static func accessibilityLabel(code pairingCode: String) -> String {
        "Pairing code " + pairingCode.map(String.init).joined(separator: " ")
    }
}
