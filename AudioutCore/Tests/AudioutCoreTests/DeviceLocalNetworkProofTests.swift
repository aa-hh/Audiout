import Foundation
import Testing
@testable import AudioutCore

/// `Device.Kind.isDiscoveredOverLocalNetwork` — the predicate that lets a
/// speaker already on screen stand in for the Local Network permission check.
///
/// Local Network is the one permission with no silent read: browsing IS the
/// request, so a fresh `SetupModel` opens at `.unknown` and cannot resolve it
/// by looking. `AppDelegate.presentSetup()` uses this predicate to record the
/// proof the app's own discovery has already produced, which is what stops a
/// re-opened Setup screen asking for access it is visibly already using.
@Suite struct DeviceLocalNetworkProofTests {

    /// Everything found over Bonjour proves the grant — including Cast, which
    /// browses the same way AirPlay does even though it is a separate routing
    /// partition.
    @Test func bonjourDiscoveredKindsProveTheGrant() {
        for kind in [Device.Kind.homePod, .appleTV, .airportExpress, .sonos, .generic, .cast] {
            #expect(kind.isDiscoveredOverLocalNetwork,
                    "Device.Kind.\(kind) is found by browsing, so it proves Local Network access")
        }
    }

    /// The two that reach us without touching the network must never stand in
    /// for the grant: this Mac is local hardware, and Bluetooth comes from Core
    /// Audio plus the paired list. Treating either as proof would mark the
    /// permission granted on a machine that had never been allowed it.
    @Test func localKindsProveNothing() {
        #expect(!Device.Kind.localMac.isDiscoveredOverLocalNetwork)
        #expect(!Device.Kind.bluetooth.isDiscoveredOverLocalNetwork)
    }

    /// Every kind is classified. `allCases` split cleanly in two means a kind
    /// added later cannot quietly default to "proves the grant" — the
    /// exhaustive switch makes it a decision.
    @Test func everyKindIsClassified() {
        let proving = Device.Kind.allCases.filter(\.isDiscoveredOverLocalNetwork)
        let notProving = Device.Kind.allCases.filter { !$0.isDiscoveredOverLocalNetwork }
        #expect(proving.count + notProving.count == Device.Kind.allCases.count)
        #expect(notProving.count == 2, "only localMac and bluetooth reach us off-network")
    }
}
