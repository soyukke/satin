import AppKit

final class RenameTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onCommit?()
            return true
        }
        return false
    }
}

final class NativeRenamePanel {
    private enum Metrics {
        static let width: CGFloat = 360
        static let contentHeight: CGFloat = 94
        static let horizontalInset: CGFloat = 20
        static let verticalInset: CGFloat = 16
        static let buttonWidth: CGFloat = 88
    }

    private let panel: NSPanel
    private let input = RenameTextField(frame: .zero)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)

    init(title: String, value: String) {
        panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Metrics.width,
                height: Metrics.contentHeight
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView(frame: .zero)
        panel.contentView = content

        input.translatesAutoresizingMaskIntoConstraints = false
        input.stringValue = value
        input.isEditable = true
        input.isSelectable = true
        input.setAccessibilityLabel("Tab name")

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded

        renameButton.target = self
        renameButton.action = #selector(accept)
        renameButton.translatesAutoresizingMaskIntoConstraints = false
        renameButton.keyEquivalent = "\r"
        renameButton.bezelStyle = .rounded

        content.addSubview(input)
        content.addSubview(cancelButton)
        content.addSubview(renameButton)
        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.verticalInset),
            input.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: Metrics.horizontalInset
            ),
            input.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -Metrics.horizontalInset
            ),
            renameButton.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 14),
            cancelButton.centerYAnchor.constraint(equalTo: renameButton.centerYAnchor),
            cancelButton.heightAnchor.constraint(equalTo: renameButton.heightAnchor),
            cancelButton.trailingAnchor.constraint(
                equalTo: renameButton.leadingAnchor, constant: -8),
            cancelButton.widthAnchor.constraint(equalToConstant: Metrics.buttonWidth),
            renameButton.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -Metrics.horizontalInset
            ),
            renameButton.widthAnchor.constraint(equalToConstant: Metrics.buttonWidth),
            renameButton.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                constant: -Metrics.verticalInset
            ),
        ])
        panel.defaultButtonCell = renameButton.cell as? NSButtonCell
        panel.initialFirstResponder = input
        input.onCommit = { [weak renameButton] in
            renameButton?.performClick(nil)
        }
    }

    func runModal(relativeTo parent: NSWindow?) -> String? {
        if let parent {
            panel.setFrameOrigin(
                NSPoint(
                    x: parent.frame.midX - panel.frame.width / 2,
                    y: parent.frame.midY - panel.frame.height / 2
                )
            )
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        input.selectText(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        parent?.makeKey()
        guard response == .OK else {
            return nil
        }
        return input.stringValue
    }

    func usesCompactIconFreeLayoutForSmoke() -> Bool {
        panel.contentLayoutRect.height <= 100
            && panel.frame.width <= 400
            && !containsImageView(panel.contentView)
            && buttonsAlignedForSmoke()
    }

    private func buttonsAlignedForSmoke() -> Bool {
        panel.contentView?.layoutSubtreeIfNeeded()
        return cancelButton.bezelStyle == renameButton.bezelStyle
            && cancelButton.frame.minY == renameButton.frame.minY
            && cancelButton.frame.height == renameButton.frame.height
    }

    static func smokeLayoutReady() -> Bool {
        NativeRenamePanel(title: "Rename Tab", value: "smoke")
            .usesCompactIconFreeLayoutForSmoke()
    }

    @objc private func accept() {
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancel() {
        NSApp.stopModal(withCode: .cancel)
    }

    private func containsImageView(_ view: NSView?) -> Bool {
        guard let view else {
            return false
        }
        return view is NSImageView || view.subviews.contains(where: containsImageView)
    }
}
