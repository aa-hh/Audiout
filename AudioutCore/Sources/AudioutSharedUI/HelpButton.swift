// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

public final class HelpButton: NSButton, NSPopoverDelegate {
    private static weak var openButton: HelpButton?
    private let helpController = HelpTextViewController()
    private var popover: NSPopover?

    public var text: String {
        didSet { updateText() }
    }

    public init(subject: String, text: String) {
        self.text = text
        super.init(frame: .zero)
        bezelStyle = .helpButton
        controlSize = .small
        title = ""
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel("Help for \(subject)")
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        target = self
        action = #selector(toggleHelp(_:))
        helpController.onDismiss = { [weak self] in self?.closeHelp(restoreFocus: true) }
        updateText()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateText() {
        toolTip = text
        setAccessibilityHelp(text)
        helpController.text = text
        popover?.contentSize = helpController.view.frame.size
    }

    @objc private func toggleHelp(_ sender: Any?) {
        if popover != nil {
            closeHelp(restoreFocus: true)
            return
        }
        Self.openButton?.dismissHelp()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = helpController
        popover.contentSize = helpController.view.frame.size
        self.popover = popover
        Self.openButton = self
        if isEnabled, !isHiddenOrHasHiddenAncestor {
            window?.makeFirstResponder(self)
        }
        guard !HeadlessRuntime.isActive, let window, window.isVisible,
              !isHiddenOrHasHiddenAncestor else { return }
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        helpController.view.window?.makeFirstResponder(helpController.view)
    }

    public func dismissHelp() { closeHelp(restoreFocus: false) }

    private func closeHelp(restoreFocus: Bool) {
        let wasShown = popover?.isShown == true
        popover?.close()
        popover = nil
        if Self.openButton === self { Self.openButton = nil }
        if restoreFocus, wasShown, isEnabled, let window, window.isVisible, !isHiddenOrHasHiddenAncestor {
            window.makeFirstResponder(self)
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil
        if Self.openButton === self { Self.openButton = nil }
    }

    public override func cancelOperation(_ sender: Any?) {
        if popover != nil { closeHelp(restoreFocus: true) }
        else { nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender) }
    }

    public override func viewDidHide() {
        super.viewDidHide()
        dismissHelp()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { dismissHelp() }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { dismissHelp() }
    }

    var test_helpLabel: NSTextField { helpController.label }
    var test_hasPopover: Bool { popover != nil }
    var test_isPopoverShown: Bool { popover?.isShown == true }
}

private final class HelpTextView: NSView {
    var onDismiss: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }
}

private final class HelpTextViewController: NSViewController {
    let label = NSTextField(wrappingLabelWithString: "")
    var onDismiss: (() -> Void)?
    private static let textWidth: CGFloat = 276
    private static let inset: CGFloat = 12

    var text = "" {
        didSet {
            loadViewIfNeeded()
            label.stringValue = text
            let measured = label.cell?.cellSize(forBounds: NSRect(
                x: 0, y: 0, width: Self.textWidth, height: .greatestFiniteMagnitude)) ?? .zero
            view.setFrameSize(NSSize(width: Self.textWidth + 2 * Self.inset,
                                     height: ceil(measured.height) + 2 * Self.inset))
            view.layoutSubtreeIfNeeded()
        }
    }

    override func loadView() {
        let content = HelpTextView()
        content.onDismiss = { [weak self] in self?.onDismiss?() }
        view = content
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = false
        label.preferredMaxLayoutWidth = Self.textWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.inset),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.inset),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.inset),
        ])
    }
}
