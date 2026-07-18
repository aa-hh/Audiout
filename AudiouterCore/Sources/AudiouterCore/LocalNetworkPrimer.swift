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
/// takes longer than `browseSeconds` to answer resolves `false` this pass — but
/// ``SetupModel/refreshStatuses()`` re-probes on the next window focus and picks
/// up the grant, so the slow-answer case self-heals. When the grant already
/// exists (Alec's case), the browse reaches `.ready`/results immediately and
/// reports `true` with no prompt.
public final class LocalNetworkPrimer: LocalNetworkPriming, @unchecked Sendable {

    /// Serial queue confining `browser` and the single-resume bookkeeping —
    /// `probe()` may be called from the main actor while NWBrowser's own callbacks
    /// arrive on this queue.
    private let queue = DispatchQueue(label: "com.audiouter.localnetwork.primer")
    private var browser: NWBrowser?
    private let browseSeconds: TimeInterval

    public init(browseSeconds: TimeInterval = 3.0) {
        self.browseSeconds = browseSeconds
    }

    public func probe() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: false); return }
                // A probe is already in flight (double-tap) — don't stack a second
                // browser; report not-yet-known and let the running one settle.
                guard self.browser == nil else { continuation.resume(returning: false); return }

                var resumed = false
                // All callbacks + the timeout run on `queue` (serial), so this
                // single-resume guard needs no extra locking.
                func finish(_ reachable: Bool) {
                    guard !resumed else { return }
                    resumed = true
                    self.browser?.cancel()
                    self.browser = nil
                    continuation.resume(returning: reachable)
                }

                let parameters = NWParameters()
                parameters.includePeerToPeer = true
                let browser = NWBrowser(
                    for: .bonjour(type: "_airplay._tcp", domain: nil), using: parameters)
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)     // permission active, network reachable
                    case .failed: finish(false)   // hard failure
                    default: break                // `.waiting` (incl. LN-denied) → let the timeout decide
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    if !results.isEmpty { finish(true) }   // saw a real speaker ⇒ granted
                }
                self.browser = browser
                browser.start(queue: self.queue)

                // Timeout: stop and report whatever we've seen (default = not reachable).
                self.queue.asyncAfter(deadline: .now() + self.browseSeconds) {
                    finish(false)
                }
            }
        }
    }
}

#endif
