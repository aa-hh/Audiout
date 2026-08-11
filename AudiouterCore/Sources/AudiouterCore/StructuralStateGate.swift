// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Answers "has the membership-bearing state moved since the surfaces were
/// last painted from it?"
///
/// It exists because `GroupController.onStateDidChange` announces EVERY model
/// change — a volume-key hold's per-tick master move included — while the
/// repaints it can trigger are full sweeps: the popover's device-row pass
/// re-runs the energize reconcile and the rail extents, and the Groups screen
/// reloads its outline view and re-renders the content pane. Riding those on
/// every announcement puts that cost on every tick of a held key, which is
/// exactly what `PopoverController.refreshMainOutMaster` refuses to do and
/// documents at length.
///
/// Selection and groups are the two things those surfaces draw that can change
/// WITHOUT a `BackendEvent` behind them (a phone toggling a speaker while a
/// group carries Main Out; any phone-driven group edit) — so nothing else
/// would ever repaint them, and a gate is the cheap way to catch exactly those
/// without repainting for everything else.
public struct StructuralStateGate {

    private var lastSelection: Set<String>?
    private var lastGroups: [Group]?

    public init() {}

    /// Whether `selection`/`groups` differ from the last call's, recording them
    /// as the new baseline either way. The FIRST call always reports `true`:
    /// nothing has been painted from this state yet.
    public mutating func shouldRepaint(selection: Set<String>, groups: [Group]) -> Bool {
        defer {
            lastSelection = selection
            lastGroups = groups
        }
        return selection != lastSelection || groups != lastGroups
    }
}
