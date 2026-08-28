// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The one place the persistence layer reports trouble it cannot fix itself:
/// a settings file that would not decode, and a save that failed.
///
/// Both are otherwise invisible. A store's `load()` throws on a corrupt file,
/// its caller catches that with `try?` and falls back to empty, and the next
/// `save` atomically overwrites the file — so without ``quarantine(_:)`` the
/// evidence is gone before anyone can look at it. A save that fails is
/// swallowed the same way, leaving the user's change live in memory and absent
/// from disk with nothing said about it.
///
/// This type is a seam, not a policy: it sets the corrupt file aside and
/// records what happened, and the app layer decides how (or whether) to tell
/// the user. The core library has no UI to tell them with.
public enum StoreRecovery {

    private static let lock = NSLock()
    private static var quarantined: [String] = []
    private static var writeFailureHandler: ((Error) -> Void)?

    /// The names of the files (e.g. `"groups.json"`) set aside by
    /// ``quarantine(_:)`` during this process's lifetime. Accumulates — it is
    /// never cleared — so a reader wanting "did file X have trouble" should
    /// ask `contains`, not compare the whole list.
    public static var quarantinedFileNames: [String] {
        lock.withLock { quarantined }
    }

    /// Where swallowed save failures go. The app installs one sink at launch;
    /// with none installed, ``noteWriteFailure(_:)`` is a no-op, which is what
    /// tests and the offline harnesses want.
    ///
    /// **May be invoked on any thread** — the write sites are spread across the
    /// main thread and the backend's own queues — so a handler that touches UI
    /// must hop to the main queue itself.
    public static var onWriteFailure: ((Error) -> Void)? {
        get { lock.withLock { writeFailureHandler } }
        set { lock.withLock { writeFailureHandler = newValue } }
    }

    /// Report a save that failed and was otherwise swallowed. The caller has
    /// already decided to carry on with the in-memory change; this only makes
    /// the loss visible.
    public static func noteWriteFailure(_ error: Error) {
        let handler = lock.withLock { writeFailureHandler }
        handler?(error)
    }

    /// Move a corrupt store file aside so the next save cannot overwrite the
    /// evidence. Called by a store's `load()` when the decode throws, just
    /// before it rethrows.
    ///
    /// `<base>.json` becomes `<base>.corrupt-<unix-seconds>.json` beside it.
    /// A move that fails for any reason is dropped silently: the caller is
    /// already on its way to reporting a corrupt file, and a second failure
    /// there has nothing better to offer than the first.
    public static func quarantine(_ fileURL: URL) {
        let base = fileURL.deletingPathExtension().lastPathComponent
        let destination = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(base).corrupt-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
        } catch {
            return
        }
        lock.withLock { quarantined.append(fileURL.lastPathComponent) }
    }
}
