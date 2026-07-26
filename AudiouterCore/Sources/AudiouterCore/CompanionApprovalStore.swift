// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One phone the Mac's user has answered an approval prompt for
/// (PLAN-COMPANION-APP T24 / D2 REVISED). Keyed by the phone's self-generated
/// `clientID` (a UUID string, validated by `CompanionServer` before it ever
/// reaches here). Denials are remembered on purpose — a denied phone must not
/// re-prompt on every reconnect — and are revocable from Settings › General
/// exactly like approvals.
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
    ///   to the same `Application Support/Audiouter/` directory as the other
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
    public func load() throws -> [CompanionApproval]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }
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
///   through ``handleRequest(clientID:clientName:decide:)`` (via the app
///   layer's main-thread hop): a remembered phone resolves instantly with no
///   UI; an unknown phone gets held (`decide(.pending)`) while ONE prompt per
///   clientID is shown — reconnects during an open prompt join its waiter
///   list instead of stacking alerts, and the user's single answer resolves
///   them all.
/// - The app layer supplies ``presentPrompt`` (the actual `NSAlert` — this
///   type is UI-free so it can be tested headlessly) and ``dropClient``
///   (revoking an approval must also disconnect that phone if it's live).
/// - Settings › General reads ``approvals`` and calls ``revoke(clientID:)``.
@MainActor
public final class CompanionApprovalController {

    private let store: CompanionApprovalStore
    public private(set) var approvals: [CompanionApproval]

    /// Deciders held while this clientID's prompt is open — every connection
    /// that helloed with that ID while the user hadn't answered yet.
    private var pendingDeciders: [String: [(CompanionServer.ApprovalDecision) -> Void]] = [:]

    /// Show the user "Allow \(clientName) to control…?" and call back with
    /// their answer, exactly once. Assigned by the app layer (`AppDelegate`);
    /// nil (unwired, e.g. a headless test that never expects a prompt) leaves
    /// the connection held until the server's own approval deadline closes it
    /// — never a silent approval.
    public var presentPrompt: ((_ clientName: String, _ respond: @escaping (Bool) -> Void) -> Void)?

    /// Disconnect any live client with this clientID — fired on
    /// ``revoke(clientID:)`` (the app layer wires it to
    /// `CompanionServer.dropClient(clientID:)`).
    public var dropClient: ((String) -> Void)?

    /// The remembered list changed (decision recorded, name/lastSeen
    /// refreshed, or an entry revoked) — the Settings pane repaints from this.
    public var onChange: (() -> Void)?

    /// - Parameter now: injectable clock so tests assert first/last-seen
    ///   deterministically.
    public init(store: CompanionApprovalStore = CompanionApprovalStore(),
                now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        // Unreadable/missing/newer-schema all land on []: every phone is
        // unknown and re-prompts — the safe failure direction for trust state.
        self.approvals = ((try? store.load()) ?? nil) ?? []
    }

    private let now: () -> Date

    /// One helloed connection asking to be let in. `decide` is
    /// `CompanionServer`'s continuation for that specific connection: called
    /// with `.approved`/`.denied` to settle it, or `.pending` first to hold
    /// it (the server then sends `awaitingApproval` so the phone shows
    /// "check your Mac").
    public func handleRequest(clientID: String,
                              clientName: String,
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

        decide(.pending)
        if pendingDeciders[clientID] != nil {
            // A prompt for this phone is already open (it reconnected while
            // the user walks to the Mac) — join its waiters, no second alert.
            pendingDeciders[clientID]?.append(decide)
            return
        }
        pendingDeciders[clientID] = [decide]
        presentPrompt?(clientName) { [weak self] allowed in
            self?.resolvePrompt(clientID: clientID, clientName: clientName, allowed: allowed)
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
        persist()
        let waiters = pendingDeciders.removeValue(forKey: clientID) ?? []
        for decide in waiters {
            decide(allowed ? .approved : .denied)
        }
    }

    /// Forget a phone entirely (approval OR denial — a revoked denial simply
    /// re-prompts on its next connect) and drop it if it's live right now.
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
            FileHandle.standardError.write(
                Data("[Audiouter] companion approvals failed to save: \(error)\n".utf8))
        }
        onChange?()
    }
}
