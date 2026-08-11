// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

#if canImport(Network)
import Network
import dnssd
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

/// Triggers AND checks the macOS **Local Network** permission, proving BOTH
/// answers.
///
/// macOS exposes no status API for this permission (Apple TN3179: it is a packet
/// filter in the network stack, not TCC), so both signals are behavioural:
///
/// - **Granted**, by SELF-DISCOVERY: the app publishes its own Bonjour service
///   (``selfServiceType``, under a per-prime unique instance name) with an
///   `NWListener` and browses for that same type. Seeing our OWN service come
///   back proves the browse reached the network — on an EMPTY network, with no
///   speaker switched on, which is what the plain `_airplay._tcp` browse could
///   never do. Seeing a real `_airplay._tcp` service proves it just as well, so
///   either sighting resolves granted.
/// - **Denied**, by policy error: once the user clicks Don't Allow, an active
///   `NWBrowser` goes `.waiting(.dns(kDNSServiceErr_PolicyDenied))` (−65570).
///   That error IS the refusal, so it resolves immediately.
/// - Neither within the caller's window ⇒ **undecided** — the permission dialog
///   is presumably still up, unanswered.
///
/// The same browse ALSO surfaces the system prompt the first time it touches the
/// network while the permission is undetermined, so priming doubles as the ask.
public final class LocalNetworkPrimer: LocalNetworkPriming, @unchecked Sendable {

    /// The Bonjour type this app publishes purely to browse for itself. It must
    /// also be listed in the bundle's `NSBonjourServices` (`scripts/make-app.sh`)
    /// — an unlisted type is silently unbrowsable, and the self-discovery would
    /// then never resolve granted.
    public static let selfServiceType = "_audiouter-preflight._tcp"

    /// Serial queue confining the endpoints and the single-resume bookkeeping —
    /// `prime()` may be called from the main actor while the Network framework's
    /// own callbacks arrive on this queue.
    private let queue = DispatchQueue(label: "com.audiouter.localnetwork.primer")
    private var browser: NWBrowser?
    private var selfBrowser: NWBrowser?
    private var listener: NWListener?
    /// The window a caller that doesn't name one gets — also the grace a prime
    /// that has already seen something allows for the speaker count to fill in.
    private let defaultBrowseSeconds: TimeInterval

    public init(browseSeconds: TimeInterval = 3.0) {
        self.defaultBrowseSeconds = browseSeconds
    }

    public func probe() async -> Bool { await probeFoundSpeakers() > 0 }

    public func probeFoundSpeakers() async -> Int {
        await probeFoundSpeakers(browseSeconds: defaultBrowseSeconds)
    }

    public func probeFoundSpeakers(browseSeconds: TimeInterval) async -> Int {
        guard case .granted(let found) = await prime(browseSeconds: browseSeconds,
                                                     onReachable: {}) else { return 0 }
        return found
    }

    /// Run one prime and report which of the three answers it earned.
    ///
    /// A positive sighting doesn't finish the prime on the spot: mDNS answers
    /// trickle in, and "Found 1 speaker" when three are on the network would be
    /// a worse lie than a three-second spinner — so the first sighting starts a
    /// short settle (``defaultBrowseSeconds``) for the count to fill in, and
    /// only `browseSeconds` (the ceiling, waiting on a human at a dialog) runs
    /// long. A denial needs no settle: it is already the whole answer.
    public func prime(browseSeconds: TimeInterval,
                      onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: .undecided); return }
                // A prime is already in flight (double-tap) — don't stack a
                // second set of endpoints; report not-yet-known and let the
                // running one settle.
                guard self.browser == nil else { continuation.resume(returning: .undecided); return }

                // All callbacks + the timers run on `queue` (serial), so this
                // bookkeeping needs no extra locking.
                var resumed = false
                var found = 0
                var sawOurOwnService = false
                var didScheduleSettle = false

                func currentOutcome() -> LocalNetworkOutcome {
                    (sawOurOwnService || found > 0) ? .granted(foundSpeakers: found) : .undecided
                }

                func finish(_ outcome: LocalNetworkOutcome) {
                    guard !resumed else { return }
                    resumed = true
                    self.browser?.cancel()
                    self.browser = nil
                    self.selfBrowser?.cancel()
                    self.selfBrowser = nil
                    self.listener?.cancel()
                    self.listener = nil
                    continuation.resume(returning: outcome)
                }

                /// First positive sighting: give the count a short grace, then
                /// answer — a Mac that already has the grant must never wait
                /// out the long ceiling.
                func settleSoon() {
                    guard !didScheduleSettle else { return }
                    didScheduleSettle = true
                    // The wait stops being "answer the dialog" here and becomes
                    // "counting speakers" — the card's two captions.
                    onReachable()
                    let grace = min(browseSeconds, self.defaultBrowseSeconds)
                    self.queue.asyncAfter(deadline: .now() + grace) { finish(currentOutcome()) }
                }

                /// The one signal that proves a REFUSAL (see the type's doc).
                func finishIfPolicyDenied(_ state: NWBrowser.State) {
                    guard case .waiting(let error) = state, Self.isPolicyDenied(error) else { return }
                    finish(.denied)
                }

                // 1. Publish our own service, and browse for it. Publishing is
                //    not gated by this permission; BROWSING is — which is what
                //    makes finding ourselves proof of the grant.
                let instanceName = "audiouter-preflight-\(UUID().uuidString)"
                if let listener = try? NWListener(using: NWParameters.tcp) {
                    listener.service = NWListener.Service(name: instanceName,
                                                          type: Self.selfServiceType)
                    // Nothing ever connects to this; a stray connection is
                    // dropped rather than left half-open.
                    listener.newConnectionHandler = { $0.cancel() }
                    self.listener = listener
                    listener.start(queue: self.queue)
                }

                let selfBrowser = NWBrowser(
                    for: .bonjour(type: Self.selfServiceType, domain: nil), using: NWParameters())
                selfBrowser.stateUpdateHandler = { finishIfPolicyDenied($0) }
                selfBrowser.browseResultsChangedHandler = { results, _ in
                    // Only OUR instance counts: another Mac running Audiouter
                    // would publish the same type, and finding it proves the
                    // network is reachable too — but the unique name keeps the
                    // proof to something we know exists.
                    let isOurs = results.contains { result in
                        guard case .service(let name, _, _, _) = result.endpoint else { return false }
                        return name == instanceName
                    }
                    guard isOurs else { return }
                    sawOurOwnService = true
                    settleSoon()
                }
                self.selfBrowser = selfBrowser
                selfBrowser.start(queue: self.queue)

                // 2. The real discovery browse — it produces the speaker COUNT
                //    the card shows, and a speaker sighting proves the grant
                //    just as well as our own service does.
                let parameters = NWParameters()
                parameters.includePeerToPeer = true
                let browser = NWBrowser(
                    for: .bonjour(type: "_airplay._tcp", domain: nil), using: parameters)
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .failed: finish(currentOutcome())   // hard failure
                    default: finishIfPolicyDenied(state)
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    // Peak, not last: a speaker that drops out mid-browse was
                    // still found.
                    found = max(found, results.count)
                    if found > 0 { settleSoon() }
                }
                self.browser = browser
                browser.start(queue: self.queue)

                // Window closed: answer with whatever the prime proved.
                self.queue.asyncAfter(deadline: .now() + browseSeconds) {
                    finish(currentOutcome())
                }
            }
        }
    }

    /// `kDNSServiceErr_PolicyDenied` (−65570) — what the mDNS responder answers
    /// an app whose Local Network access the user refused.
    private static func isPolicyDenied(_ error: NWError) -> Bool {
        guard case .dns(let code) = error else { return false }
        return code == kDNSServiceErr_PolicyDenied
    }
}

#endif
