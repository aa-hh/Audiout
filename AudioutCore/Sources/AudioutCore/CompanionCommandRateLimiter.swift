// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Per-client token bucket for inbound companion commands (FIX-B2 finding 2a).
///
/// Every phone command triggers main-thread work on the Mac (dispatcher
/// execute, a snapshot rebuild, for `setMainOut` a `stateQueue.sync` + a disk
/// write) — a peer looping a 60-byte command would otherwise grow the main
/// queue faster than it drains and starve the Mac's own UI. The phone's own
/// slider policy sends at most ~20 commands/sec, so a sustained rate of
/// 20/sec with a small burst never touches a legitimate client.
///
/// Pure value type with the clock passed in (`now` as a monotonic
/// `TimeInterval`, e.g. `ProcessInfo.processInfo.systemUptime`) so it is
/// deterministic under test. Not thread-safe by design: the owner
/// (`AppDelegate`) only ever touches it from the main thread, inside the
/// command/disconnect hops.
public struct CompanionCommandRateLimiter {

    private struct Bucket {
        var tokens: Double
        var lastRefill: TimeInterval
    }

    /// Tokens replenished per second (sustained command rate).
    public let sustainedPerSecond: Double
    /// Bucket capacity — how many commands a briefly-idle client may send
    /// back-to-back before the sustained rate applies.
    public let burst: Double

    private var buckets: [UUID: Bucket] = [:]

    public init(sustainedPerSecond: Double = 20, burst: Double = 40) {
        self.sustainedPerSecond = sustainedPerSecond
        self.burst = burst
    }

    /// True if `clientID` may execute a command at `now`; consumes one token.
    /// A refused command consumes nothing (the client's budget is unchanged —
    /// it recovers as soon as it slows down).
    public mutating func allowCommand(from clientID: UUID, now: TimeInterval) -> Bool {
        var bucket = buckets[clientID] ?? Bucket(tokens: burst, lastRefill: now)
        // `max(0, …)` guards a caller handing a clock that stepped backwards;
        // monotonic clocks never do, but a negative delta must not mint tokens.
        let elapsed = max(0, now - bucket.lastRefill)
        bucket.tokens = min(burst, bucket.tokens + elapsed * sustainedPerSecond)
        bucket.lastRefill = now
        let allowed = bucket.tokens >= 1
        if allowed { bucket.tokens -= 1 }
        buckets[clientID] = bucket
        return allowed
    }

    /// Drop `clientID`'s bucket — call on disconnect so state never outlives
    /// the client (a reconnecting client starts with a fresh burst allowance).
    public mutating func forgetClient(_ clientID: UUID) {
        buckets.removeValue(forKey: clientID)
    }
}
