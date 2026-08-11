// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

#if canImport(Network)
import Network
import dnssd
#endif

/// The REAL ``LocalNetworkPrimer`` — the one part of the permission flow whose
/// correctness lives in Bonjour rather than in our own state machine.
///
/// Most of what matters here is hermetic (the service name, the refusal
/// signal). The two tests that publish and browse for real are gated the same
/// way the Core Audio hardware tests are: they touch the machine's network
/// stack, and on macOS 15+ a browse from the test binary can raise the system's
/// own Local Network dialog — which must never happen in a routine
/// `run-tests.sh`.
@Suite struct LocalNetworkPrimerTests {

    /// Opt-in gate for the tests that start real endpoints. Sibling of
    /// ``AudioHardwareTestGate`` (`AIRPLAY_AUDIO_HARDWARE_TESTS`), same
    /// `AIRPLAY_`-prefixed convention and the same strict "only `1` means on".
    enum LiveNetworkTestGate {
        static let environmentVariableName = "AIRPLAY_LOCAL_NETWORK_TESTS"
        static var isEnabled: Bool {
            ProcessInfo.processInfo.environment[environmentVariableName] == "1"
        }
        static let skipReason =
            "Real Bonjour test. Set \(environmentVariableName)=1 to run (publishes "
            + "and browses on the live network, and can raise the system's Local "
            + "Network dialog for the test binary)."
        static var trait: ConditionTrait {
            .enabled(if: isEnabled, Comment(rawValue: skipReason))
        }
    }

    #if canImport(Network)

    /// THE bug this file was opened for. A Bonjour service name is capped at 15
    /// characters (RFC 6335 / `dns_sd.h`); an over-long one isn't truncated,
    /// it's REJECTED with `BadParam`, so both the listener and the self-browse
    /// die on the spot and the grant becomes unprovable — silently, because
    /// nothing in the Swift API surfaces the rejection. The first version of
    /// this name was `audiouter-preflight` (19), which meant the self-discovery
    /// that proves a grant on a speaker-free network had never once run.
    @Test func theSelfServiceNameFitsBonjoursFifteenCharacterLimit() {
        #expect(LocalNetworkPrimer.selfServiceName.count <= 15)
        #expect(!LocalNetworkPrimer.selfServiceName.isEmpty)
        #expect(LocalNetworkPrimer.selfServiceType == "_audiouter-pf._tcp")
        // The bundle's `NSBonjourServices` (scripts/make-app.sh) has to list
        // this exact string, or the browse is blocked whatever its length.
        #expect(LocalNetworkPrimer.selfServiceType.hasSuffix("._tcp"))
    }

    /// The refusal is one specific mDNS code, and it can reach us on EITHER a
    /// `.waiting` or a `.failed` browse state — reading only one of the two is
    /// how a delivered refusal turned into a full-window wait.
    @Test func onlyThePolicyDeniedDNSErrorReadsAsARefusal() {
        #expect(LocalNetworkPrimer.isPolicyDenied(
            .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        #expect(!LocalNetworkPrimer.isPolicyDenied(
            .dns(DNSServiceErrorType(kDNSServiceErr_Timeout))))
        #expect(!LocalNetworkPrimer.isPolicyDenied(.posix(.ECONNREFUSED)))
    }

    /// The tests that put real endpoints on the network.
    @Suite(LiveNetworkTestGate.trait)
    struct LiveNetwork {

        /// Self-discovery is the whole point: publishing our own service and
        /// finding it proves the browse reached the network, with no speaker
        /// switched on anywhere.
        @Test func findingItsOwnServiceProvesTheGrant() async {
            let primer = LocalNetworkPrimer()
            let outcome = await primer.prime(browseSeconds: 15, selfDiscovery: true,
                                             onReachable: {})
            guard case .granted = outcome else {
                Issue.record("expected .granted from self-discovery, got \(outcome)")
                return
            }
        }

        /// The window closing mid-ask must tear the endpoints down and let the
        /// caller go — otherwise a 60-second first ask keeps a listener and two
        /// browsers alive long after the window it belonged to.
        @Test func cancelEndsAPrimeInFlight() async {
            let primer = LocalNetworkPrimer()
            let started = Date()
            let priming = Task { await primer.prime(browseSeconds: 60, selfDiscovery: true,
                                                    onReachable: {}) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            primer.cancel()
            let outcome = await priming.value

            #expect(outcome == .undecided, "an interrupted prime proved nothing")
            #expect(Date().timeIntervalSince(started) < 30, "it must not sit out the ceiling")
        }

        /// A prime that proves nothing still ANSWERS, at its ceiling — a wait
        /// that never resolves would latch the card's spinner forever.
        @Test func aPrimeAlwaysAnswersWithinItsWindow() async {
            let primer = LocalNetworkPrimer()
            let started = Date()
            _ = await primer.prime(browseSeconds: 2, selfDiscovery: false, onReachable: {})
            #expect(Date().timeIntervalSince(started) < 20)
        }
    }

    #endif
}
