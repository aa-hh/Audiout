import AudioToolbox
import Foundation
import Testing
@testable import AudioutCore

/// BT-ENUM (PLAN-UNIVERSAL-SYNC): hermetic tests for ``BTDeviceEnumerator`` —
/// the transport/output filter, the Core Audio ⟷ IOBluetooth paired-list merge,
/// derived-UID identity stability across disconnect/rejoin, and the
/// authorization gate (an ungranted IOBluetooth touch KILLS the process on
/// macOS 27, so the gate degrading to Core-Audio-only is load-bearing, not
/// cosmetic). No HAL, no IOBluetooth, no Bluetooth TCC anywhere in this file —
/// all three seams are injected closures.
@Suite final class BTDeviceEnumeratorTests: IsolatedSuite {

    // MARK: Fixtures

    private let sonosUID = "C4-38-75-0E-BF-4A:output"

    private func btOutput(
        uid: String = "C4-38-75-0E-BF-4A:output", name: String = "Sonos Move 2",
        transport: UInt32 = kAudioDeviceTransportTypeBluetooth, hasOutput: Bool = true
    ) -> BTCoreAudioOutput {
        BTCoreAudioOutput(uid: uid, name: name, transportType: transport, hasOutputStreams: hasOutput)
    }

    private func paired(
        name: String? = "JBL Flip 5", address: String? = "70-99-1c-51-8f-a8",
        isAudioCapable: Bool = true, lastUsed: Date? = nil, deviceClassMinor: UInt32? = nil
    ) -> BTPairedRecord {
        BTPairedRecord(name: name, address: address, isAudioCapable: isAudioCapable,
                       lastUsed: lastUsed, deviceClassMinor: deviceClassMinor)
    }

    // MARK: Transport / output filter

    /// Only genuine Bluetooth-transport output devices pass; aggregates,
    /// virtual devices, other transports, and BT input-only devices all fall
    /// out. The aggregate case is the spike's named trap: an aggregate can pass
    /// a "has output streams" check while never carrying real BT audio.
    @Test func filterKeepsOnlyBluetoothOutputs() {
        let outputs = [
            btOutput(),                                                              // kept
            btOutput(uid: "AGG-1", name: "Aggregate", transport: kAudioDeviceTransportTypeAggregate),
            btOutput(uid: "VIRT-1", name: "Loopback", transport: kAudioDeviceTransportTypeVirtual),
            btOutput(uid: "USB-1", name: "USB DAC", transport: kAudioDeviceTransportTypeUSB),
            btOutput(uid: "BLI-1", name: "Built-in", transport: kAudioDeviceTransportTypeBuiltIn),
            btOutput(uid: "AA-BB-CC-DD-EE-99:input", name: "BT mic", hasOutput: false),
        ]
        let merged = BTDeviceEnumerator.merge(outputs: outputs, paired: [])
        #expect(merged.map(\.id) == [sonosUID])
        #expect(merged.first?.isConnected == true)
    }

    // MARK: Merge

    /// A connected speaker with a matching paired record is ONE row: the real
    /// Core Audio UID as id, connected, carrying the pairing's recency.
    @Test func connectedDeviceMergesWithItsPairedRecord() {
        let used = Date(timeIntervalSince1970: 1_780_000_000)
        let merged = BTDeviceEnumerator.merge(
            outputs: [btOutput()],
            // IOBluetooth reports the address lowercase/dashed; the UID is
            // uppercase with an `:output` suffix — matching must normalize.
            paired: [paired(name: "Sonos Move 2", address: "c4:38:75:0e:bf:4a", lastUsed: used)])
        #expect(merged.count == 1)
        #expect(merged.first?.id == sonosUID)
        #expect(merged.first?.isConnected == true)
        #expect(merged.first?.lastUsed == used)
    }

    /// A paired-but-disconnected audio device still exists, disconnected, under
    /// the DERIVED UID — the row macOS's pairing memory owes the user.
    @Test func pairedButDisconnectedSurfacesUnderDerivedUID() {
        let merged = BTDeviceEnumerator.merge(outputs: [], paired: [paired()])
        #expect(merged.count == 1)
        #expect(merged.first?.id == "70-99-1C-51-8F-A8:output")
        #expect(merged.first?.name == "JBL Flip 5")
        #expect(merged.first?.isConnected == false)
    }

    /// The whole point of deriving the UID: the id a speaker carries while
    /// DISCONNECTED (from its paired address) equals the id it carries while
    /// CONNECTED (Core Audio's real UID) — so disconnect/rejoin never splits
    /// one speaker into two identities and saved groups keep their member.
    @Test func identityIsStableAcrossDisconnectAndRejoin() {
        let record = paired(name: "Sonos Move 2", address: "c4-38-75-0e-bf-4a")
        let whileConnected = BTDeviceEnumerator.merge(outputs: [btOutput()], paired: [record])
        let whileDisconnected = BTDeviceEnumerator.merge(outputs: [], paired: [record])
        #expect(whileConnected.map(\.id) == whileDisconnected.map(\.id))
        #expect(whileConnected.first?.isConnected == true)
        #expect(whileDisconnected.first?.isConnected == false)
    }

    /// The pairing's minor device class rides the merge on BOTH paths — it is
    /// what tells a headset from a speaker cabinet downstream
    /// (`Device.symbolName`), and a connected speaker reaches it only through
    /// its paired record, since Core Audio never reports a Class of Device.
    @Test func deviceClassRidesBothMergePaths() {
        let headphones = paired(name: "Sonos Move 2", address: "c4-38-75-0e-bf-4a",
                                deviceClassMinor: 0x06)
        let whileConnected = BTDeviceEnumerator.merge(outputs: [btOutput()], paired: [headphones])
        let whileDisconnected = BTDeviceEnumerator.merge(outputs: [], paired: [headphones])
        #expect(whileConnected.first?.deviceClassMinor == 0x06)
        #expect(whileDisconnected.first?.deviceClassMinor == 0x06)
    }

    /// A connected output no paired record claims — the paired list is empty
    /// without the Bluetooth grant — keeps its row with NO class, which is what
    /// makes the glyph fall back rather than guess.
    @Test func connectedOutputWithNoPairedRecordCarriesNoDeviceClass() {
        let merged = BTDeviceEnumerator.merge(outputs: [btOutput()], paired: [])
        #expect(merged.first?.deviceClassMinor == nil)
    }

    /// Keyboards, mice, and phones are paired too — only audio-capable records
    /// (A2DP SDP record or audio Class-of-Device, resolved by the seam) merge.
    @Test func nonAudioPairedDevicesAreExcluded() {
        let merged = BTDeviceEnumerator.merge(
            outputs: [],
            paired: [
                paired(name: "Magic Keyboard", address: "11-22-33-44-55-66", isAudioCapable: false),
                paired(),
            ])
        #expect(merged.map(\.name) == ["JBL Flip 5"])
    }

    /// A paired record with no derivable identity is skipped rather than
    /// invented; a connected output whose UID isn't MAC-shaped keeps its row
    /// (Core Audio is the truth for connected devices) but merges with nothing.
    @Test func recordsWithoutStableIdentityDegradeSafely() {
        let merged = BTDeviceEnumerator.merge(
            outputs: [btOutput(uid: "weird-vendor-uid", name: "Odd Speaker")],
            paired: [paired(name: "Ghost", address: nil)])
        #expect(merged.map(\.id) == ["weird-vendor-uid"])
    }

    /// One physical speaker, two Core Audio outputs with the same MAC (seen as
    /// transient duplicates during connect): one row, first output wins.
    @Test func duplicateOutputsForOneMACCollapseToOneRow() {
        let merged = BTDeviceEnumerator.merge(
            outputs: [btOutput(), btOutput(uid: "c4:38:75:0e:bf:4a:output", name: "Sonos Move 2 (dup)")],
            paired: [])
        #expect(merged.count == 1)
        #expect(merged.first?.id == sonosUID)
    }

    // MARK: Authorization gate

    /// Ungranted, the paired-list seam must NEVER be invoked (the real one is
    /// an IOBluetooth call — a process kill, not an error, on macOS 27) and
    /// enumeration degrades to Core-Audio-only: connected speakers surface,
    /// paired-but-disconnected ones don't.
    @Test func missingBluetoothGrantDegradesToCoreAudioOnly() {
        let pairedTouched = LockedFlag()
        let received = SnapshotBox()
        let output = btOutput()
        let record = paired()
        let enumerator = BTDeviceEnumerator(
            listOutputs: { [output] },
            listPaired: { pairedTouched.set(); return [record] },
            isBluetoothAuthorized: { false })
        enumerator.onSnapshot = { received.append($0) }
        enumerator.refresh()
        #expect(!pairedTouched.isSet, "IOBluetooth must not be touched without the Bluetooth grant")
        #expect(received.all.last?.map(\.id) == [sonosUID], "Core-Audio-only enumeration still surfaces connected speakers")
    }

    @Test func grantedEnumerationMergesPairedList() {
        let received = SnapshotBox()
        let output = btOutput()
        let record = paired()
        let enumerator = BTDeviceEnumerator(
            listOutputs: { [output] },
            listPaired: { [record] },
            isBluetoothAuthorized: { true })
        enumerator.onSnapshot = { received.append($0) }
        enumerator.refresh()
        #expect(received.all.last?.count == 2)
    }

    /// Emission is edge-triggered: an unchanged re-enumeration (the device-list
    /// listener fires for plenty of non-BT reasons) emits nothing.
    @Test func unchangedRefreshDoesNotReEmit() {
        let received = SnapshotBox()
        let output = btOutput()
        let enumerator = BTDeviceEnumerator(
            listOutputs: { [output] },
            listPaired: { [] },
            isBluetoothAuthorized: { false })
        enumerator.onSnapshot = { received.append($0) }
        enumerator.refresh()
        enumerator.refresh()
        #expect(received.all.count == 1)
    }

    // MARK: The authorization ASK (the prompt seam)

    /// Scriptable stand-in for the CoreBluetooth ask: records how often the
    /// request fired, holds the decision callback, and plays the OS's
    /// authorization state.
    private final class AuthScript: @unchecked Sendable {
        private let lock = NSLock()
        private var _authorized = false
        private var _undetermined = true
        private var _requests = 0
        private var _onDecided: (@Sendable () -> Void)?
        var authorized: Bool {
            get { lock.withLock { _authorized } }
            set { lock.withLock { _authorized = newValue } }
        }
        var undetermined: Bool {
            get { lock.withLock { _undetermined } }
            set { lock.withLock { _undetermined = newValue } }
        }
        var requestCount: Int { lock.withLock { _requests } }
        func makeRequest(_ onDecided: @escaping @Sendable () -> Void) -> AnyObject? {
            lock.withLock { _requests += 1; _onDecided = onDecided }
            return self
        }
        /// The user answered the prompt — plays the delegate decision callback.
        func decide() { lock.withLock { _onDecided }?() }
    }

    private func makeAskingEnumerator(
        _ script: AuthScript,
        asksAuthorizationOnEnumeration: Bool = true,
        listPaired: @escaping @Sendable () -> [BTPairedRecord]
    ) -> BTDeviceEnumerator {
        let output = btOutput()
        return BTDeviceEnumerator(
            listOutputs: { [output] },
            listPaired: listPaired,
            isBluetoothAuthorized: { script.authorized },
            isBluetoothUndetermined: { script.undetermined },
            makeAuthorizationRequest: { script.makeRequest($0) },
            asksAuthorizationOnEnumeration: asksAuthorizationOnEnumeration)
    }

    private func waitFor(timeout: TimeInterval? = nil,
                     sourceLocation: SourceLocation = #_sourceLocation,
                     _ cond: @escaping () -> Bool) {
        SuiteWait.untilOnRunLoop(timeout: timeout, sourceLocation: sourceLocation, cond)
    }

    /// The live root cause this seam exists for: `.notDetermined` never
    /// resolves on its own, so the first enumeration must ASK — once — and a
    /// grant must land the merged paired list with no relaunch (the decision
    /// callback re-enumerates).
    @Test func undeterminedFiresOneRequestAndGrantRefreshesTheMergedList() {
        let script = AuthScript()
        let received = SnapshotBox()
        let record = paired()
        let enumerator = makeAskingEnumerator(script) { [record] }
        enumerator.onSnapshot = { received.append($0) }

        enumerator.refresh()
        #expect(script.requestCount == 1, "the undetermined status fires the ask")
        #expect(received.all.last?.count == 1, "pre-decision enumeration is Core-Audio-only")

        enumerator.refresh()
        #expect(script.requestCount == 1, "the ask fires ONCE, not per refresh")

        // The user grants: the decision callback re-enumerates on its own —
        // the paired list (the ghost/disconnected rows) lands immediately.
        script.authorized = true
        script.undetermined = false
        script.decide()
        waitFor { received.all.last?.count == 2 }
        #expect(received.all.last?.count == 2, "a grant refreshes without a relaunch")
    }

    /// A denial ends the wait the same way but changes nothing: the gate keeps
    /// IOBluetooth untouched forever and enumeration stays Core-Audio-only.
    @Test func denialStaysDegradedAndNeverTouchesIOBluetooth() {
        let script = AuthScript()
        let pairedTouched = LockedFlag()
        let received = SnapshotBox()
        let record = paired()
        let enumerator = makeAskingEnumerator(script) { pairedTouched.set(); return [record] }
        enumerator.onSnapshot = { received.append($0) }

        enumerator.refresh()
        script.undetermined = false   // the user denied; authorized stays false
        script.decide()
        SuiteWait.settle(0.3)
        enumerator.refresh()
        #expect(!pairedTouched.isSet, "denied ⇒ IOBluetooth is never touched")
        #expect(received.all.last?.map(\.id) == [sonosUID], "still Core-Audio-only")
        #expect(script.requestCount == 1, "no re-ask after a denial either")
    }

    /// An already-decided status (granted or denied at launch) never
    /// constructs the request at all.
    @Test func decidedStatusNeverAsks() {
        let script = AuthScript()
        script.undetermined = false
        script.authorized = true
        let record = paired()
        let enumerator = makeAskingEnumerator(script) { [record] }
        enumerator.onSnapshot = { _ in }
        enumerator.refresh()
        #expect(script.requestCount == 0)
    }

    // MARK: The DEFERRED ask policy (what the app wires)

    /// The jarring prompt this policy exists to kill: the backend starting is
    /// not a reason to ask. Neither `start()` nor any re-enumeration may fire it
    /// — enumeration still degrades to Core-Audio-only, silently.
    @Test func deferredPolicyNeverAsksFromEnumeration() {
        let script = AuthScript()
        let received = SnapshotBox()
        let record = paired()
        let enumerator = makeAskingEnumerator(script, asksAuthorizationOnEnumeration: false) { [record] }
        enumerator.onSnapshot = { received.append($0) }

        enumerator.start()
        defer { enumerator.stop() }
        // `refresh()` is synchronous on the enumerator's queue, so it also acts
        // as the barrier proving `start()`'s enqueued enumeration has run.
        enumerator.refresh()

        #expect(script.requestCount == 0, "backend startup must never spring the prompt")
        #expect(received.all.last?.map(\.id) == [sonosUID], "still enumerates, Core-Audio-only")
    }

    /// …and the user's own first Bluetooth gesture is what asks instead: once,
    /// however often it is repeated, and the grant lands the paired list with no
    /// relaunch.
    @Test func deferredPolicyAsksOnUserAction() {
        let script = AuthScript()
        let received = SnapshotBox()
        let record = paired()
        let enumerator = makeAskingEnumerator(script, asksAuthorizationOnEnumeration: false) { [record] }
        enumerator.onSnapshot = { received.append($0) }
        enumerator.refresh()

        enumerator.requestAuthorizationForUserAction()
        waitFor { script.requestCount == 1 }
        #expect(script.requestCount == 1)

        enumerator.requestAuthorizationForUserAction()
        SuiteWait.settle(0.2)
        #expect(script.requestCount == 1, "one prompt per process, however often the user taps")

        script.authorized = true
        script.undetermined = false
        script.decide()
        waitFor { received.all.last?.count == 2 }
        #expect(received.all.last?.count == 2, "the grant lands the paired list without a relaunch")
    }

    /// A decided status is never re-asked, user gesture or not.
    @Test func userActionNeverReAsksOnceDecided() {
        let script = AuthScript()
        script.undetermined = false
        script.authorized = false   // the user denied at some earlier point
        let record = paired()
        let enumerator = makeAskingEnumerator(script, asksAuthorizationOnEnumeration: false) { [record] }
        enumerator.onSnapshot = { _ in }

        enumerator.requestAuthorizationForUserAction()
        SuiteWait.settle(0.2)
        #expect(script.requestCount == 0)
    }

    // MARK: Thread-safe test boxes

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [[BTDeviceSnapshot]] = []
        func append(_ s: [BTDeviceSnapshot]) { lock.withLock { snapshots.append(s) } }
        var all: [[BTDeviceSnapshot]] { lock.withLock { snapshots } }
    }
}
