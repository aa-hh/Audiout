// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// UI-agnostic model backing the hidden-speakers list (the Output Speakers
/// card's footer "−" / "+" menu), persisted independently via its own
/// ``HiddenSpeakersStore``. Mirrors `ExcludedAppsController`'s shape: add,
/// remove, and membership queries over stable device ids. It intentionally
/// knows nothing about selection — the "a selected speaker still renders"
/// precedence is enforced by the rendering layer (`PopoverController` keeps a
/// hidden-but-selected row visible), so hiding can never silence or orphan a
/// playing speaker.
public final class HiddenSpeakersController {

    private let store: HiddenSpeakersStore

    /// Hidden device ids in stable insertion order.
    private(set) public var hiddenDeviceIDs: [String]

    /// - Parameters:
    ///   - store: persistence for the hidden list. Defaults to the on-disk
    ///     store; tests inject one pointed at a temp directory.
    ///   - loadPersisted: load saved ids immediately. Tests that don't care
    ///     about persistence can skip the disk hit.
    public init(store: HiddenSpeakersStore = HiddenSpeakersStore(), loadPersisted: Bool = true) {
        self.store = store
        self.hiddenDeviceIDs = loadPersisted ? ((try? store.load()) ?? []) : []
    }

    /// Fired AFTER any mutation that actually changes the list (hide / show),
    /// immediately after the change is persisted. No-op mutations don't fire it.
    public var onChange: (() -> Void)?

    private func persist() {
        do { try store.save(hiddenDeviceIDs) } catch { StoreRecovery.noteWriteFailure(error) }
        onChange?()
    }

    // MARK: Queries

    /// Whether `deviceID` is hidden.
    public func isHidden(_ deviceID: String) -> Bool {
        hiddenDeviceIDs.contains(deviceID)
    }

    // MARK: Mutations

    /// Hide `deviceID`. No-op (no persist, no state change) if already hidden.
    public func hide(deviceID: String) {
        guard !isHidden(deviceID) else { return }
        hiddenDeviceIDs.append(deviceID)
        persist()
    }

    /// Show `deviceID` again. No-op if it isn't hidden.
    public func show(deviceID: String) {
        guard let i = hiddenDeviceIDs.firstIndex(of: deviceID) else { return }
        hiddenDeviceIDs.remove(at: i)
        persist()
    }
}
