// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// FIX-B2 finding 2a: the per-client token bucket `AppDelegate` puts in front
/// of `CompanionCommandDispatcher.execute`. Deterministic — the clock is a
/// plain `now` argument, no real time involved.
///
/// NOTE: `allowCommand` is `mutating`, and Swift Testing's `#expect` macro
/// rewrites a direct method call into an immutable-capture closure — so every
/// call below lands in a `let` first, and `#expect` checks the result.
@Suite struct CompanionCommandRateLimiterTests {

    private let client = UUID()
    private let otherClient = UUID()

    @Test func burstIsAllowedThenSustainedRateApplies() {
        var limiter = CompanionCommandRateLimiter(sustainedPerSecond: 20, burst: 40)
        // A fresh client gets the full burst in one instant…
        for i in 0..<40 {
            let allowed = limiter.allowCommand(from: client, now: 0)
            #expect(allowed, "burst command \(i) refused")
        }
        // …and the 41st at the same instant is refused.
        let overBurst = limiter.allowCommand(from: client, now: 0)
        #expect(!overBurst)
        // 50 ms later exactly one token has refilled (20/sec): one allowed, next refused.
        let refilled = limiter.allowCommand(from: client, now: 0.05)
        #expect(refilled)
        let secondAtSameInstant = limiter.allowCommand(from: client, now: 0.05)
        #expect(!secondAtSameInstant)
    }

    @Test func legitimateSliderCadenceIsNeverRefused() {
        var limiter = CompanionCommandRateLimiter()
        // The phone's own drag policy: 20 Hz sustained for 10 s straight.
        for tick in 0..<200 {
            let allowed = limiter.allowCommand(from: client, now: Double(tick) * 0.05)
            #expect(allowed, "20 Hz command \(tick) refused")
        }
    }

    @Test func clientsAreLimitedIndependently() {
        var limiter = CompanionCommandRateLimiter(sustainedPerSecond: 20, burst: 2)
        _ = limiter.allowCommand(from: client, now: 0)
        _ = limiter.allowCommand(from: client, now: 0)
        let exhausted = limiter.allowCommand(from: client, now: 0)
        #expect(!exhausted, "client exhausted")
        // The other client's bucket is untouched by the first one's flood.
        let otherAllowed = limiter.allowCommand(from: otherClient, now: 0)
        #expect(otherAllowed)
    }

    @Test func refusalConsumesNothingAndBudgetRecovers() {
        var limiter = CompanionCommandRateLimiter(sustainedPerSecond: 20, burst: 1)
        let first = limiter.allowCommand(from: client, now: 0)
        #expect(first)
        // Hammering while empty stays refused but doesn't dig a deeper hole…
        for _ in 0..<100 { _ = limiter.allowCommand(from: client, now: 0.01) }
        // …so after one token's worth of quiet the client is served again.
        let recovered = limiter.allowCommand(from: client, now: 0.07)
        #expect(recovered)
    }

    @Test func tokensCapAtBurstAfterLongIdle() {
        var limiter = CompanionCommandRateLimiter(sustainedPerSecond: 20, burst: 2)
        _ = limiter.allowCommand(from: client, now: 0)
        // An hour idle must refill to the burst cap, not an hour's worth.
        let firstAfterIdle = limiter.allowCommand(from: client, now: 3600)
        #expect(firstAfterIdle)
        let secondAfterIdle = limiter.allowCommand(from: client, now: 3600)
        #expect(secondAfterIdle)
        let thirdAfterIdle = limiter.allowCommand(from: client, now: 3600)
        #expect(!thirdAfterIdle)
    }

    @Test func forgetClientResetsToAFreshBurst() {
        var limiter = CompanionCommandRateLimiter(sustainedPerSecond: 20, burst: 1)
        _ = limiter.allowCommand(from: client, now: 0)
        let exhausted = limiter.allowCommand(from: client, now: 0)
        #expect(!exhausted)
        limiter.forgetClient(client)
        // A reconnecting client (new session, same UUID) starts fresh.
        let fresh = limiter.allowCommand(from: client, now: 0)
        #expect(fresh)
    }

    @Test func backwardsClockNeverMintsTokens() {
        var limiter = CompanionCommandRateLimiter(sustainedPerSecond: 20, burst: 1)
        let first = limiter.allowCommand(from: client, now: 100)
        #expect(first)
        // A (theoretical) clock step backwards must not refill the bucket.
        let afterStepBack = limiter.allowCommand(from: client, now: 50)
        #expect(!afterStepBack)
    }
}
