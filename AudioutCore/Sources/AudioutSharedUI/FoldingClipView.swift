// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// A layer-clipped container that folds its one content view open and shut on
/// `FoldAnimator`'s clock: the two "Advanced" disclosures (Equalizer, Settings
/// Audio).
///
/// A REQUIRED height == constant constraint is the one animated value; the
/// content's bottom pin is `.defaultHigh`, so the clip always wins without a
/// conflict. `isHidden` or a visibility priority on a stack child that has
/// been shown does NOT work: the stack keeps demanding the expanded height.
///
/// Expand un-hides before travel and hands the rest height back to the
/// content's bottom pin on arrival. Collapse seeds the constraint from the
/// LIVE clip height, so a first-ever or retargeted fold travels instead of
/// snapping, and hides the content only on arrival. `animated == false`
/// applies the end state and calls `completion` in the caller's own turn.
///
/// Not used by `CardView` or the panel's row clips: those carry a generation
/// or closing guard the rail reads, which this view does not model.
public final class FoldingClipView: NSView {

    public let content: NSView
    private let topInset: CGFloat
    private lazy var collapsedHeight = heightAnchor.constraint(equalToConstant: 0)

    /// `topInset` is the gap between the clip's top and the content; it is
    /// part of the expanded height.
    public init(content: NSView, topInset: CGFloat = 0) {
        self.content = content
        self.topInset = topInset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let bottomPin = content.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomPin.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            bottomPin,
        ])
        collapsedHeight.isActive = true
        content.isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `follower` lays itself out from every tick, as with `FoldAnimator`.
    public func setExpanded(_ expanded: Bool, animated: Bool,
                            follower: (any FoldFollowing)?,
                            completion: (() -> Void)? = nil) {
        if expanded {
            content.isHidden = false
            guard animated else {
                collapsedHeight.isActive = false
                completion?()
                return
            }
            content.layoutSubtreeIfNeeded()
            let target = content.fittingSize.height + topInset
            collapsedHeight.isActive = true
            FoldAnimator.shared.animate(collapsedHeight, to: target, follower: follower) { [weak self] in
                self?.collapsedHeight.isActive = false
                completion?()
            }
        } else {
            guard animated else {
                collapsedHeight.constant = 0
                collapsedHeight.isActive = true
                content.isHidden = true
                completion?()
                return
            }
            if !collapsedHeight.isActive {
                collapsedHeight.constant = frame.height
                collapsedHeight.isActive = true
                (window?.contentView ?? superview)?.layoutSubtreeIfNeeded()
            }
            FoldAnimator.shared.animate(collapsedHeight, to: 0, follower: follower) { [weak self] in
                self?.content.isHidden = true
                completion?()
            }
        }
    }
}
