import AppKit
import Foundation
import Testing
@testable import AudioutCore

/// Roadmap 006 Phase (i): the `.cast` `Device.Kind` — symbol validity on this
/// AppKit, the `isCast` helper, and the two Cast `ConnectionFailure.Cause`
/// cases' user-facing copy (the model half; the popover section is covered in
/// `PopoverDeviceVisibilityTests`).
@Suite final class DeviceCastKindTests: IsolatedSuite {

    /// The Cast glyph must resolve on this AppKit and must not collide with any
    /// other kind's, or two device families would read as one in the rows.
    @Test func castSymbolResolvesAndIsDistinct() {
        let symbol = Device.Kind.cast.symbolName
        #expect(symbol == "tv.and.hifispeaker.fill")
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "Device.Kind.cast symbol '\(symbol)' must resolve on this AppKit")
        for other in Device.Kind.allCases where other != .cast {
            #expect(symbol != other.symbolName,
                    "Cast glyph collides with Device.Kind.\(other)")
        }
    }

    /// `isCast` is the exclusion predicate every engine-only path must use —
    /// never `supportsAirPlay2`, which AP1 receivers share yet ARE engine-driven.
    @Test func isCastIsTrueForExactlyTheCastKind() {
        for kind in Device.Kind.allCases {
            let device = Device(id: "x", name: "X", kind: kind)
            #expect(device.isCast == (kind == .cast))
        }
        #expect(!Device(id: "x", name: "X", kind: .cast).isBluetooth,
                "Cast is its own partition, not a flavour of Bluetooth")
    }

    /// The copy lives on `ConnectionFailure` so the row sublabel, the diagnosis
    /// panel and "Copy details" all read one source.
    @Test func castFailureCopyIsPresentable() {
        let unavailable = ConnectionFailure(cause: .castAppUnavailable)
        let unreachable = ConnectionFailure(cause: .castConnectionFailed)
        #expect(unavailable.headline == "Cast app unavailable")
        #expect(unreachable.headline == "Couldn't reach receiver")
        for failure in [unavailable, unreachable] {
            #expect(!failure.suggestion.isEmpty)
            #expect(failure.suggestion.hasSuffix("."),
                    "a suggestion is one sentence and ends with a period")
        }
    }

    /// A Cast receiver told to load but not yet reporting PLAYING counts as still
    /// connecting, though Cast devices never carry `isSelected`. Turns red if the
    /// check is narrowed to selected devices, which drops Cast entirely.
    @Test func castStillLoadingCountsAsStillConnecting() {
        let loading = Device(id: "c", name: "C", kind: .cast, connectionState: .connecting)
        #expect([loading].hasDeviceStillConnecting)
        #expect(!loading.isSelected)
    }

    /// Once every device has confirmed or stopped, nothing is waiting. Turns red
    /// if a playing, idle or failed device is mistaken for one still starting.
    @Test func confirmedIdleAndFailedDevicesAreNotStillConnecting() {
        let devices = [
            Device(id: "a", name: "A", kind: .cast, connectionState: .connected),
            Device(id: "b", name: "B", kind: .cast, connectionState: .off),
            Device(id: "c", name: "C", kind: .cast,
                   connectionState: .failed(ConnectionFailure(cause: .timedOut))),
        ]
        #expect(!devices.hasDeviceStillConnecting)
    }
}
