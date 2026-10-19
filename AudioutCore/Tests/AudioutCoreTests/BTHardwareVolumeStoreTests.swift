// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `BTHardwareVolumeStore` — the per-speaker "Control speaker volume"
/// opt-out. Mirrors `BTTrimStoreTests`' shape: throwaway temp directory,
/// never the real Application Support.
@Suite final class BTHardwareVolumeStoreTests: IsolatedSuite {

    private func store() -> BTHardwareVolumeStore {
        BTHardwareVolumeStore(directory: scratchDir)
    }

    /// The whole point of the default: a speaker nobody has ever touched must
    /// read as ENABLED. Persisting nothing and answering `false` would leave
    /// every Bluetooth speaker silently opted out.
    @Test func unknownUIDIsEnabled() {
        #expect(store().isEnabled(uid: "C4-38-75-0E-BF-4A:output"))
    }

    /// A choice that does not survive a relaunch is not a setting. Both
    /// directions round-trip through a second store on the same directory.
    @Test func offSurvivesAReload() {
        let uid = "C4-38-75-0E-BF-4A:output"
        store().setEnabled(false, uid: uid)
        #expect(store().isEnabled(uid: uid) == false)

        store().setEnabled(true, uid: uid)
        #expect(store().isEnabled(uid: uid))
    }

    /// One speaker's opt-out must not answer for another's — the file is
    /// keyed per UID, not a global switch.
    @Test func optsOutOnlyTheNamedUID() {
        let store = store()
        store.setEnabled(false, uid: "a:output")
        #expect(store.isEnabled(uid: "a:output") == false)
        #expect(store.isEnabled(uid: "b:output"))
    }

    /// Default-on means the file exists only for people who turned something
    /// OFF: reading a speaker's state, and setting one to the default, must
    /// both leave nothing on disk.
    @Test func onlyOffUIDsAreWritten() throws {
        let fileURL = scratchDir.appendingPathComponent(BTHardwareVolumeStore.fileName)
        let store = store()
        _ = store.isEnabled(uid: "a:output")
        store.setEnabled(true, uid: "a:output")
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)

        store.setEnabled(false, uid: "a:output")
        let envelope = try JSONDecoder().decode(BTHardwareVolumeStore.Envelope.self,
                                                from: Data(contentsOf: fileURL))
        #expect(envelope.disabledUIDs == ["a:output"])
    }

    /// The backend hangs off this: without a change notification it keeps
    /// driving hardware volume on a speaker the user just opted out.
    @Test func onChangeFiresOnceWithTheNewState() {
        let store = store()
        var seen: [(String, Bool)] = []
        store.onChange = { seen.append(($0, $1)) }

        store.setEnabled(false, uid: "a:output")
        store.setEnabled(false, uid: "a:output")   // no change, no event
        store.setEnabled(true, uid: "a:output")

        #expect(seen.map(\.0) == ["a:output", "a:output"])
        #expect(seen.map(\.1) == [false, true])
    }
}
