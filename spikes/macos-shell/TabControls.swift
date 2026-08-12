import AppKit

final class NativeTabStripView: NSView {
    private enum Metrics {
        static let spacing: CGFloat = 4
        static let buttonSize = NSSize(width: 22, height: 22)
    }

    let tabControl: NativeTabControl
    let newTabButton: NativeHoverIconButton

    init(tabControl: NativeTabControl, newTabButton: NativeHoverIconButton) {
        self.tabControl = tabControl
        self.newTabButton = newTabButton
        super.init(frame: .zero)
        addSubview(tabControl)
        addSubview(newTabButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let tabs = tabControl.intrinsicContentSize
        return NSSize(
            width: tabs.width + Metrics.spacing + Metrics.buttonSize.width,
            height: max(tabs.height, Metrics.buttonSize.height)
        )
    }

    override func layout() {
        super.layout()
        let tabs = tabControl.intrinsicContentSize
        tabControl.frame = NSRect(
            x: 0,
            y: floor((bounds.height - tabs.height) / 2),
            width: tabs.width,
            height: tabs.height
        )
        newTabButton.frame = NSRect(
            x: tabControl.frame.maxX + Metrics.spacing,
            y: floor((bounds.height - Metrics.buttonSize.height) / 2),
            width: Metrics.buttonSize.width,
            height: Metrics.buttonSize.height
        )
    }

    func contentSizeDidChange() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    func actionsReady() -> Bool {
        newTabButton.superview === self
            && newTabButton.image != nil
            && !newTabButton.isBordered
    }
}

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

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"

        let renameButton = NSButton(title: "Rename", target: self, action: #selector(accept))
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
            cancelButton.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 14),
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

final class NativeTabControl: NSSegmentedControl {
    private enum Metrics {
        static let closeHitWidth: CGFloat = 26
        static let closeGlyphSize: CGFloat = 7
        static let closeTrailingInset: CGFloat = 4
    }

    var onRenameRequested: ((Int) -> Void)?
    var onCloseRequested: ((Int) -> Bool)?
    var contextMenuProvider: ((Int) -> NSMenu?)?
    private var contextEventMonitor: Any?

    deinit {
        removeContextEventMonitor()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if handleClose(at: point) {
            return
        }
        super.mouseDown(with: event)
        handleCompletedClick(clickCount: event.clickCount, segment: selectedSegment)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for segment in 0..<segmentCount {
            drawCloseGlyph(forSegment: segment)
        }
    }

    func simulateDoubleClickForSmoke(segment: Int) {
        handleCompletedClick(clickCount: 2, segment: segment)
    }

    @discardableResult
    func simulateCloseForSmoke(segment: Int) -> Bool {
        guard let target = closeButtonRect(forSegment: segment) else {
            return false
        }
        return handleClose(at: NSPoint(x: target.midX, y: target.midY))
    }

    func verifyAsyncCloseForSmoke(
        open: () -> Bool,
        modelState: @escaping () -> (count: Int, active: Int)?,
        completion: @escaping (String?) -> Void
    ) {
        guard open() else {
            completion("tab-open=no")
            return
        }
        waitForOpenForSmoke(
            modelState: modelState,
            retries: 30,
            completion: completion
        )
    }

    private func waitForOpenForSmoke(
        modelState: @escaping () -> (count: Int, active: Int)?,
        retries: Int,
        completion: @escaping (String?) -> Void
    ) {
        guard let state = modelState(), state.count == 2, segmentCount == 2 else {
            guard retries > 0 else {
                completion("tab-open-timeout")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForOpenForSmoke(
                    modelState: modelState,
                    retries: retries - 1,
                    completion: completion
                )
            }
            return
        }
        let widthBeforeClose = frame.width
        guard simulateCloseForSmoke(segment: state.active) else {
            completion("tab-close-request=no")
            return
        }
        waitForCloseForSmoke(
            modelState: modelState,
            widthBeforeClose: widthBeforeClose,
            retries: 30,
            completion: completion
        )
    }

    private func waitForCloseForSmoke(
        modelState: @escaping () -> (count: Int, active: Int)?,
        widthBeforeClose: CGFloat,
        retries: Int,
        completion: @escaping (String?) -> Void
    ) {
        if modelState()?.count == 1,
            segmentCount == 1,
            frame.width < widthBeforeClose
        {
            completion(nil)
            return
        }
        guard retries > 0 else {
            completion("tab-close-redraw=no")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForCloseForSmoke(
                modelState: modelState,
                widthBeforeClose: widthBeforeClose,
                retries: retries - 1,
                completion: completion
            )
        }
    }

    func closeButtonHitTargetForSmoke(segment: Int) -> NSRect? {
        closeButtonRect(forSegment: segment)
    }

    private func handleCompletedClick(clickCount: Int, segment: Int) {
        guard clickCount == 2, segment >= 0, segment < segmentCount else {
            return
        }
        onRenameRequested?(segment)
    }

    private func handleClose(at point: NSPoint) -> Bool {
        guard let segment = segmentIndex(at: point),
            closeButtonRect(forSegment: segment)?.contains(point) == true
        else {
            return false
        }
        return onCloseRequested?(segment) ?? false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let segment = segmentIndex(at: point) else {
            return super.menu(for: event)
        }
        return contextMenuProvider?(segment)
    }

    func contextMenuForSmoke(segment: Int) -> NSMenu? {
        guard segment >= 0, segment < segmentCount else {
            return nil
        }
        return contextMenuProvider?(segment)
    }

    func contextMenuMonitorReadyForSmoke() -> Bool {
        contextEventMonitor != nil
    }

    func contextMenuReadyForSmoke(segment: Int) -> Bool {
        let menu = contextMenuForSmoke(segment: segment)
        return contextMenuMonitorReadyForSmoke()
            && menu?.items.map(\.title) == ["Rename Tab…", "", "Close Tab"]
            && menu?.items.first?.representedObject as? Int == segment
            && menu?.items.last?.representedObject as? Int == segment
    }

    func finishSnapshotSync(previousFrame: NSRect) {
        sizeToFit()
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
        if let container = superview {
            container.needsLayout = true
            container.setNeedsDisplay(previousFrame.union(frame))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeContextEventMonitor()
        guard window != nil else {
            return
        }
        contextEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
            [weak self] event in
            self?.handleContextEvent(event) ?? event
        }
    }

    private func handleContextEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else {
            return event
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let segment = segmentIndex(at: point),
            let menu = contextMenuProvider?(segment)
        else {
            return event
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return nil
    }

    private func removeContextEventMonitor() {
        guard let contextEventMonitor else {
            return
        }
        NSEvent.removeMonitor(contextEventMonitor)
        self.contextEventMonitor = nil
    }

    private func drawCloseGlyph(forSegment segment: Int) {
        guard let hitRect = closeButtonRect(forSegment: segment) else {
            return
        }
        let half = Metrics.closeGlyphSize / 2
        let center = NSPoint(x: hitRect.midX, y: hitRect.midY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x - half, y: center.y - half))
        path.line(to: NSPoint(x: center.x + half, y: center.y + half))
        path.move(to: NSPoint(x: center.x - half, y: center.y + half))
        path.line(to: NSPoint(x: center.x + half, y: center.y - half))
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        NSColor.labelColor.withAlphaComponent(segment == selectedSegment ? 0.82 : 0.58).setStroke()
        path.stroke()
    }

    private func closeButtonRect(forSegment segment: Int) -> NSRect? {
        guard let segmentRect = segmentRect(for: segment) else {
            return nil
        }
        return NSRect(
            x: segmentRect.maxX - Metrics.closeHitWidth - Metrics.closeTrailingInset,
            y: segmentRect.minY,
            width: Metrics.closeHitWidth,
            height: segmentRect.height
        )
    }

    private func segmentRect(for target: Int) -> NSRect? {
        guard target >= 0, target < segmentCount else {
            return nil
        }
        let widths = (0..<segmentCount).map { width(forSegment: $0) }
        let contentWidth = widths.reduce(0, +)
        let leadingInset = max(0, (bounds.width - contentWidth) / 2)
        let leadingWidth = widths.prefix(target).reduce(0, +)
        return NSRect(
            x: bounds.minX + leadingInset + leadingWidth,
            y: bounds.minY,
            width: widths[target],
            height: bounds.height
        )
    }

    private func segmentIndex(at point: NSPoint) -> Int? {
        guard bounds.contains(point), segmentCount > 0 else {
            return nil
        }
        return (0..<segmentCount).first {
            segmentRect(for: $0)?.contains(point) == true
        }
    }
}
