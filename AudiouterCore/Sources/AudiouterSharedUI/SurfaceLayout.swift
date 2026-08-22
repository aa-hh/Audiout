// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The one-surface window's fixed width, and the sidebar numbers the Groups
/// and Settings screens' source-list sidebars both hold to. `AppSurfaceController`
/// pins every screen to `width`; the two arrangement screens read
/// `sidebarWidth`/`contentPaneWidth` and the shared cell geometry from here so
/// neither can drift from the frame or from each other. Every consumer reads
/// these, never a literal.
public enum SurfaceLayout {
    /// The one fixed surface frame's width (window content width, every screen).
    public static let width: CGFloat = 623

    /// Pinned min == max sidebar thickness shared by the Groups and Settings
    /// source-list sidebars.
    public static let sidebarWidth: CGFloat = 210

    /// What's left of `width` for a screen's content pane once the sidebar is
    /// spent.
    public static var contentPaneWidth: CGFloat { width - sidebarWidth }

    /// Sidebar row icon side length, shared by both source-list sidebars.
    public static let sidebarIconSize: CGFloat = 22

    /// Gap from a sidebar row's icon to its label, shared by both source-list
    /// sidebars.
    public static let sidebarIconToLabelGap: CGFloat = 8
}
