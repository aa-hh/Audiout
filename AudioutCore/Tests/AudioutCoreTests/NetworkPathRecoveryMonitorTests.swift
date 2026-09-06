// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing
@testable import AudioutCore

private extension NetworkPathRecoveryMonitor.PathSnapshot {
    static func up(_ interfaces: String...) -> Self {
        Self(satisfied: true, interfaces: Set(interfaces))
    }

    static let down = Self(satisfied: false, interfaces: [])
}

/// One row of the recovery rule: the previous reading, the new one, and whether
/// the pair counts as the path coming back.
private struct RecoveryCase: Sendable {
    let previous: NetworkPathRecoveryMonitor.PathSnapshot?
    let current: NetworkPathRecoveryMonitor.PathSnapshot
    let expected: Bool
    let why: String

    init(
        _ previous: NetworkPathRecoveryMonitor.PathSnapshot?,
        _ current: NetworkPathRecoveryMonitor.PathSnapshot,
        _ expected: Bool,
        _ why: String
    ) {
        self.previous = previous
        self.current = current
        self.expected = expected
        self.why = why
    }
}

/// The rule that decides when a parked speaker gets another attempt.
///
/// Defect these catch: a monitor that treats its first report as a recovery
/// would re-kick every parked speaker at every launch; one that ignores an
/// interface appearing misses a Wi-Fi toggle on a Mac with Ethernet; one that
/// counts an interface LEAVING spends an attempt on the outage itself, at the
/// moment the speaker is least reachable.
@Suite struct NetworkPathRecoveryMonitorTests {

    @Test(arguments: [
        RecoveryCase(nil, .up("en0"), false, "the first report on start is not a recovery"),
        RecoveryCase(.down, .up("en0"), true, "down to up"),
        RecoveryCase(.up("en0"), .up("en0"), false, "an identical re-report is not a recovery"),
        RecoveryCase(.up("en0", "en1"), .up("en1"), false, "an interface leaving is the outage, not the recovery"),
        RecoveryCase(.up("en1"), .up("en0", "en1"), true, "an interface came back while still satisfied"),
        RecoveryCase(.up("en0"), .up("en1"), true, "one interface replaced by another is a new one appearing"),
        RecoveryCase(.up("en0"), .down, false, "going down is not a recovery"),
    ])
    fileprivate func recoveryRule(row: RecoveryCase) {
        let actual = NetworkPathRecoveryMonitor.isRecovery(previous: row.previous, current: row.current)
        #expect(actual == row.expected, "\(row.why)")
    }
}
