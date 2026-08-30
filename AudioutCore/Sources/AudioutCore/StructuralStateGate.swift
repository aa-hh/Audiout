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
/// Selection, groups and the Main Out TARGET are what those surfaces draw that
/// can change WITHOUT a `BackendEvent` behind them (a phone toggling a speaker
/// while a group carries Main Out; any phone-driven group edit; a phone
/// activating a group) — so nothing else would ever repaint them, and a gate
/// is the cheap way to catch exactly those without repainting for everything
/// else.
///
/// The target earns its place: `setMainOut` moves `mainOut`/`activeGroupID`
/// and NEITHER of the other two, yet it changes the membership rail's extent
/// and the dormant dimming derived from the active target — so a group
/// activated from the phone lit its speakers while the rail stayed unpainted.
public struct StructuralStateGate {

    private var lastSelection: Set<String>?
    private var lastGroups: [Group]?
    private var lastTarget: MainOutTarget?

    public init() {}

    /// Whether the drawn state differs from the last call's, recording it as
    /// the new baseline either way. The FIRST call always reports `true`:
    /// nothing has been painted from this state yet.
    public mutating func shouldRepaint(selection: Set<String>,
                                       groups: [Group],
                                       target: MainOutTarget) -> Bool {
        defer {
            lastSelection = selection
            lastGroups = groups
            lastTarget = target
        }
        return selection != lastSelection || groups != lastGroups || target != lastTarget
    }
}
