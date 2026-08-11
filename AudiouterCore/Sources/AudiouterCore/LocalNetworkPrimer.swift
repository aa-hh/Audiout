// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

#if canImport(Network)
import Network
#endif

/// Constructs the production ``LocalNetworkPriming``. On any platform with the
/// Network framework (all supported macOS) this is ``LocalNetworkPrimer``; the
/// `#else` exists only so the type compiles where Network is absent.
public enum LocalNetworkPrimerFactory {
    public static func makeDefault() -> LocalNetworkPriming {
        #if canImport(Network)
        return LocalNetworkPrimer()
        #else
        return NoopLocalNetworkPrimer()
        #endif
    }
}

/// No-op fallback (non-Network platforms only) — never reachable.
public struct NoopLocalNetworkPrimer: LocalNetworkPriming {
    public init() {}
    public func probe() async -> Bool { false }
}

#if canImport(Network)

/// Triggers AND functionally checks the macOS **Local Network** permission with a
/// short Bonjour browse for `_airplay._tcp` — the same service the real discovery
/// (`NativeDiscovery`) uses, so this exercises exactly the access the app needs.
///
/// macOS exposes no status API (TN3179), so the browse IS the check: `probe()`
/// returns `true` if the browser reached `.ready` or saw a service (the network is
/// demonstrably reachable ⇒ granted-and-working), `false` otherwise. The same
/// browse ALSO surfaces the system prompt the first time it touches the network
/// while the permission is undetermined, so probing doubles as the ask.
///
/// On a still-undetermined first run the prompt blocks the browse, so a user who
/// takes longer than the caller's window to answer resolves `false` this pass — but
/// ``SetupModel/refreshStatuses()`` re-probes on the next window focus and picks
/// up the grant, so the slow-answer case self-heals. When the grant already
/// exists (ahh's case), the browse reaches `.ready`/results immediately and
/// reports `true` with no prompt.
public final class LocalNetworkPrimer: LocalNetworkPriming, @unchecked Sendable {

    /// Serial queue confining `browser` and the single-resume bookkeeping —
    /// `probe()` may be called from the main actor while NWBrowser's own callbacks
    /// arrive on this queue.
    private let queue = DispatchQueue(label: "com.audiouter.localnetwork.primer")
    private var browser: NWBrowser?
    /// The window a caller that doesn't name one gets — also the point at which
    /// a longer browse that has already found something settles.
    private let defaultBrowseSeconds: TimeInterval

    public init(browseSeconds: TimeInterval = 3.0) {
        self.defaultBrowseSeconds = browseSeconds
    }

    public func probe() async -> Bool { await probeFoundSpeakers() > 0 }

    public func probeFoundSpeakers() async -> Int {
        await probeFoundSpeakers(browseSeconds: defaultBrowseSeconds)
    }

    /// Browse for `browseSeconds` and report the most speakers seen at once.
    ///
    /// It keeps browsing after the first result rather than finishing on it:
    /// mDNS answers trickle in, and "Found 1 speaker" when three are on the
    /// network would be a worse lie than a three-second spinner. A window
    /// longer than `defaultBrowseSeconds` is a first ask waiting on a person
    /// and a permission dialog, so it settles at that shorter mark once it has
    /// actually seen something. `.failed` still short-circuits.
    /// A `.ready` browser with no results is deliberately NOT reported as
    /// reachable-and-done — with no OS status API, "the browse worked but found
    /// nothing" and "denied" are the same observation, and setup's Local Network
    /// card is the one place that difference matters (it asks the user to power
    /// a speaker on rather than claiming a denial).
    public func probeFoundSpeakers(browseSeconds: TimeInterval) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: 0); return }
                // A probe is already in flight (double-tap) — don't stack a second
                // browser; report not-yet-known and let the running one settle.
                guard self.browser == nil else { continuation.resume(returning: 0); return }

                var resumed = false
                var found = 0
                // All callbacks + the timeout run on `queue` (serial), so this
                // single-resume guard needs no extra locking.
                func finish(_ count: Int) {
                    guard !resumed else { return }
                    resumed = true
                    self.browser?.cancel()
                    self.browser = nil
                    continuation.resume(returning: count)
                }

                let parameters = NWParameters()
                parameters.includePeerToPeer = true
                let browser = NWBrowser(
                    for: .bonjour(type: "_airplay._tcp", domain: nil), using: parameters)
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .failed: finish(0)   // hard failure
                    default: break            // `.ready`/`.waiting` → let the results + timeout decide
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    // Peak, not last: a speaker that drops out mid-browse was
                    // still found.
                    found = max(found, results.count)
                }
                self.browser = browser
                browser.start(queue: self.queue)

                // A browse that has already seen a speaker has its answer, so it
                // settles here rather than making someone whose permission was
                // already granted watch a long first-ask window run out. Only
                // the EMPTY wait runs long — that's the one waiting on a human
                // and a dialog.
                let settle = min(browseSeconds, self.defaultBrowseSeconds)
                self.queue.asyncAfter(deadline: .now() + settle) {
                    if found > 0 { finish(found) }
                }
                // Window closed: report whatever the browse saw (default = none).
                self.queue.asyncAfter(deadline: .now() + browseSeconds) {
                    finish(found)
                }
            }
        }
    }
}

#endif
