// SPDX-License-Identifier: MIT

/// Bonjour + protocol-version constants shared by the Mac's `CompanionServer`
/// and the iOS app's discovery/connection code. Kept in one place so both
/// sides can never drift on the service type or TXT record keys.
public enum CompanionProto {
    /// Bonjour service type the Mac advertises and the phone browses for.
    public static let serviceType = "_audiout._tcp"

    /// Wire protocol version. Bump only when message/command *semantics*
    /// change in a way an older peer couldn't handle — adding a new command
    /// or message case does not require a bump (an older peer will treat the
    /// unrecognized name as unknown; see `CompanionMessage`'s `.unknown`
    /// case). Changing the *encoding* of an existing case is a protocol
    /// break and must not happen silently — see AudioutProtocol/AGENTS.md.
    public static let version = 1

    /// Bonjour TXT record keys.
    public enum TXTKey {
        /// This peer's `CompanionProto.version`, as a decimal string.
        public static let proto = "proto"
        /// The Mac's display name (`Snapshot.serverName`), shown before connecting.
        public static let name = "name"
    }

    /// Refuse-forward check (mirrors `AppRouteStore.swift`'s
    /// `envelope.schemaVersion <= currentSchemaVersion` guard): a peer
    /// advertising a protocol version newer than ours is incompatible — we
    /// don't know what it means, so refuse rather than guess. A peer on an
    /// OLDER or EQUAL version is fine to talk to.
    public static func isIncompatible(peerVersion: Int) -> Bool {
        peerVersion > version
    }
}
