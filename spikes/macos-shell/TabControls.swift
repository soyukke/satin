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
        static let labelReservedWidth: CGFloat = 66
        static let overlayInset: CGFloat = 2
        static let selectedVerticalInset: CGFloat = 1.5
        static let outerHorizontalInset: CGFloat = 2.5
        static let tabCornerRadius: CGFloat = 6
        static let titleLeadingInset: CGFloat = 12
        static let activityTitleLeadingInset: CGFloat = 28
        static let activityCenterInset: CGFloat = 15
        static let activityRadius: CGFloat = 5
        static let titleTrailingSpacing: CGFloat = 3
        static let closeHitWidth: CGFloat = 26
        static let closeGlyphSize: CGFloat = 7
        static let closeTrailingInset: CGFloat = 4
        static let dragThreshold: CGFloat = 4
    }

    var onRenameRequested: ((Int) -> Void)?
    var onCloseRequested: ((Int) -> Bool)?
    var onMoveRequested: ((Int, Int) -> Bool)?
    var contextMenuProvider: ((Int) -> NSMenu?)?
    private var contextEventMonitor: Any?
    private var hoverTrackingArea: NSTrackingArea?
    private var hoveredSegment: Int?
    private var hoverPoint: NSPoint?
    private var mouseDownPoint: NSPoint?
    private var pressedSegment: Int?
    private var dragTargetSegment: Int?
    private var draggingTab = false
    private var runningSegments = Set<Int>()
    private var activityTimer: Timer?

    deinit {
        activityTimer?.invalidate()
        removeContextEventMonitor()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if handleClose(at: point) {
            return
        }
        guard let segment = segmentIndex(at: point) else {
            resetPointerInteraction()
            return
        }
        mouseDownPoint = point
        pressedSegment = segment
        dragTargetSegment = segment
        draggingTab = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let source = pressedSegment, let mouseDownPoint else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
        guard draggingTab || distance >= Metrics.dragThreshold else {
            return
        }
        draggingTab = true
        dragTargetSegment = dragTargetIndex(source: source, pointX: point.x)
        hoverPoint = point
        hoveredSegment = segmentIndex(at: point)
        NSCursor.closedHand.set()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let source = pressedSegment else {
            resetPointerInteraction()
            return
        }
        let target = dragTargetSegment
        let wasDragging = draggingTab
        let clickCount = event.clickCount
        resetPointerInteraction()
        if wasDragging, let target, target != source {
            _ = onMoveRequested?(source, target)
            return
        }
        selectedSegment = source
        _ = sendAction(action, to: self.target)
        handleCompletedClick(clickCount: clickCount, segment: source)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let clipRect = drawingClipRect(for: dirtyRect) else {
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clipRect).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        for segment in 0..<segmentCount {
            guard let segmentRect = segmentRect(for: segment), segmentRect.intersects(clipRect)
            else {
                continue
            }
            drawSelectedSurfaceIfNeeded(forSegment: segment, in: segmentRect)
            drawInteractionOverlay(forSegment: segment, in: segmentRect)
            drawTitle(forSegment: segment, in: segmentRect)
            if closeGlyphVisible(forSegment: segment) {
                drawCloseGlyph(forSegment: segment)
            }
            drawDragIndicatorIfNeeded(forSegment: segment, in: segmentRect)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        hoverTrackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard !draggingTab else {
            return
        }
        hoveredSegment = nil
        hoverPoint = nil
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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

    func segmentFrameForNavigation(_ segment: Int) -> NSRect? {
        segmentRect(for: segment)
    }

    func drawingClipReadyForSmoke() -> Bool {
        let outside = NSRect(
            x: bounds.maxX + 1,
            y: bounds.minY,
            width: max(1, bounds.width),
            height: max(1, bounds.height)
        )
        return drawingClipRect(for: bounds) != nil
            && drawingClipRect(for: outside) == nil
    }

    @discardableResult
    func simulateMoveForSmoke(from source: Int, to target: Int) -> Bool {
        guard source >= 0, source < segmentCount, target >= 0, target < segmentCount else {
            return false
        }
        return onMoveRequested?(source, target) ?? false
    }

    func displayTitle(_ title: String, segmentWidth: CGFloat) -> String {
        let maximumWidth = max(1, segmentWidth - Metrics.labelReservedWidth)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        if (title as NSString).size(withAttributes: attributes).width <= maximumWidth {
            return title
        }
        let ellipsis = "…"
        var lowerBound = 0
        var upperBound = title.count
        while lowerBound < upperBound {
            let candidateCount = (lowerBound + upperBound + 1) / 2
            let candidate = String(title.prefix(candidateCount)) + ellipsis
            if (candidate as NSString).size(withAttributes: attributes).width <= maximumWidth {
                lowerBound = candidateCount
            } else {
                upperBound = candidateCount - 1
            }
        }
        return String(title.prefix(lowerBound)) + ellipsis
    }

    func visualGeometryReadyForSmoke(segment: Int) -> Bool {
        guard let closeRect = closeButtonRect(forSegment: segment),
            let visualSegmentRect = segmentRect(for: segment),
            let label = label(forSegment: segment)
        else {
            return false
        }
        let previousSegment = hoveredSegment
        let previousPoint = hoverPoint
        hoveredSegment = segment
        hoverPoint = NSPoint(x: closeRect.midX, y: closeRect.midY)
        let hoverReady = closeGlyphVisible(forSegment: segment)
        hoveredSegment = previousSegment
        hoverPoint = previousPoint
        let longTitle = String(repeating: "Long tab title ", count: 8)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        let labelWidth = (label as NSString).size(withAttributes: attributes).width
        let labelRightEdge = visualSegmentRect.midX + labelWidth / 2
        let truncatedLongTitle = displayTitle(longTitle, segmentWidth: visualSegmentRect.width)
        let dragTargetsReady: Bool
        if let firstRect = segmentRect(for: 0),
            let lastRect = segmentRect(for: segmentCount - 1),
            segmentCount > 1
        {
            dragTargetsReady =
                dragTargetIndex(source: segmentCount - 1, pointX: firstRect.minX) == 0
                && dragTargetIndex(source: 0, pointX: lastRect.maxX) == segmentCount - 1
        } else {
            dragTargetsReady = segmentCount == 1
        }
        return hoverTrackingArea != nil
            && truncatedLongTitle.hasSuffix("…")
            && truncatedLongTitle != longTitle
            && labelRightEdge + Metrics.overlayInset <= closeRect.minX
            && closeRect.maxX <= visualSegmentRect.maxX
            && hoverReady
            && dragTargetsReady
            && tabCornerPolicyReadyForSmoke()
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

    func setRunningSegments(_ segments: Set<Int>) {
        let next = Set(segments.filter { $0 >= 0 && $0 < segmentCount })
        guard next != runningSegments else {
            return
        }
        runningSegments = next
        updateActivityTimer()
        needsDisplay = true
    }

    func runningActivityReadyForSmoke(segment: Int) -> Bool {
        runningSegments.contains(segment) && activityTimer?.isValid == true
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
        updateActivityTimer()
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

    private func drawingClipRect(for dirtyRect: NSRect) -> NSRect? {
        let clipRect = dirtyRect.intersection(bounds)
        return clipRect.isNull || clipRect.isEmpty ? nil : clipRect
    }

    private func drawInteractionOverlay(forSegment segment: Int, in segmentRect: NSRect) {
        let isHovered = segment == hoveredSegment && segment != selectedSegment
        let isPressed = segment == pressedSegment && !draggingTab
        let isDragSource = segment == pressedSegment && draggingTab
        guard isHovered || isPressed || isDragSource else {
            return
        }
        let path = tabSurfacePath(
            forSegment: segment,
            in: tabSurfaceRect(
                forSegment: segment,
                in: segmentRect,
                verticalInset: Metrics.overlayInset
            )
        )
        NSColor.labelColor.withAlphaComponent(isPressed || isDragSource ? 0.10 : 0.06).setFill()
        path.fill()
    }

    private func drawSelectedSurfaceIfNeeded(forSegment segment: Int, in segmentRect: NSRect) {
        guard segment == selectedSegment else {
            return
        }
        let rect = tabSurfaceRect(
            forSegment: segment,
            in: segmentRect,
            verticalInset: Metrics.selectedVerticalInset
        )
        guard rect.width > 0, rect.height > 0 else {
            return
        }
        let path = tabSurfacePath(forSegment: segment, in: rect)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(
            window?.isKeyWindow == true ? 0.24 : 0.12
        )
        shadow.set()
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawTitle(forSegment segment: Int, in segmentRect: NSRect) {
        guard let label = label(forSegment: segment),
            let closeRect = closeButtonRect(forSegment: segment)
        else {
            return
        }
        let selected = segment == selectedSegment
        let hovered = segment == hoveredSegment
        let color: NSColor
        if selected {
            color = .labelColor
        } else if hovered {
            color = .labelColor.withAlphaComponent(0.72)
        } else {
            color = .secondaryLabelColor
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: label, attributes: attributes)
        let height = ceil(attributed.size().height)
        let showsActivity = runningSegments.contains(segment)
        if showsActivity {
            drawActivityIndicator(
                center: NSPoint(
                    x: segmentRect.minX + Metrics.activityCenterInset,
                    y: segmentRect.midY
                ),
                selected: selected
            )
        }
        let leading =
            segmentRect.minX
            + (showsActivity ? Metrics.activityTitleLeadingInset : Metrics.titleLeadingInset)
        let trailing = closeRect.minX - Metrics.titleTrailingSpacing
        let titleRect = NSRect(
            x: leading,
            y: floor(segmentRect.midY - height / 2),
            width: max(0, trailing - leading),
            height: height
        )
        attributed.draw(in: titleRect)
    }

    private func drawActivityIndicator(center: NSPoint, selected: Bool) {
        let phase = ProcessInfo.processInfo.systemUptime * 5.2
        let color = selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        for index in 0..<8 {
            let progress = Double(index) / 8
            let angle = phase + progress * Double.pi * 2
            let inner = Metrics.activityRadius * 0.48
            let alpha = 0.2 + progress * 0.72
            let path = NSBezierPath()
            path.move(
                to: NSPoint(
                    x: center.x + CGFloat(cos(angle)) * inner,
                    y: center.y + CGFloat(sin(angle)) * inner
                ))
            path.line(
                to: NSPoint(
                    x: center.x + CGFloat(cos(angle)) * Metrics.activityRadius,
                    y: center.y + CGFloat(sin(angle)) * Metrics.activityRadius
                ))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            color.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
    }

    private func updateActivityTimer() {
        activityTimer?.invalidate()
        activityTimer = nil
        guard window != nil, !runningSegments.isEmpty else {
            return
        }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        activityTimer = timer
    }

    private func drawCloseGlyph(forSegment segment: Int) {
        guard let hitRect = closeButtonRect(forSegment: segment) else {
            return
        }
        if hoverPoint.map(hitRect.contains) == true {
            NSColor.labelColor.withAlphaComponent(0.13).setFill()
            NSBezierPath(
                roundedRect: hitRect.insetBy(dx: 4, dy: 3),
                xRadius: 4,
                yRadius: 4
            ).fill()
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
        NSColor.labelColor.withAlphaComponent(segment == selectedSegment ? 0.86 : 0.68).setStroke()
        path.stroke()
    }

    private func drawDragIndicatorIfNeeded(forSegment segment: Int, in rect: NSRect) {
        guard draggingTab,
            let source = pressedSegment,
            let target = dragTargetSegment,
            source != target,
            segment == target
        else {
            return
        }
        let x = target < source ? rect.minX : rect.maxX
        let indicator = NSBezierPath()
        indicator.move(to: NSPoint(x: x, y: rect.minY + 3))
        indicator.line(to: NSPoint(x: x, y: rect.maxY - 3))
        indicator.lineWidth = 3
        indicator.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        indicator.stroke()
    }

    private func closeGlyphVisible(forSegment segment: Int) -> Bool {
        segment == selectedSegment || segment == hoveredSegment || segment == pressedSegment
    }

    private func updateHover(with event: NSEvent) {
        guard !draggingTab else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let segment = segmentIndex(at: point)
        guard hoveredSegment != segment || hoverPoint != point else {
            return
        }
        hoveredSegment = segment
        hoverPoint = point
        needsDisplay = true
    }

    private func resetPointerInteraction() {
        mouseDownPoint = nil
        pressedSegment = nil
        dragTargetSegment = nil
        draggingTab = false
        NSCursor.arrow.set()
        needsDisplay = true
    }

    private func dragTargetIndex(source: Int, pointX: CGFloat) -> Int? {
        guard source >= 0, source < segmentCount, segmentCount > 0 else {
            return nil
        }
        let insertion = (0..<segmentCount).reduce(into: 0) { count, segment in
            if let rect = segmentRect(for: segment), pointX >= rect.midX {
                count += 1
            }
        }
        let adjusted = insertion - (source < insertion ? 1 : 0)
        return min(max(adjusted, 0), segmentCount - 1)
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

    private func tabSurfaceRect(
        forSegment segment: Int,
        in segmentRect: NSRect,
        verticalInset: CGFloat
    ) -> NSRect {
        let corners = tabSurfaceCorners(forSegment: segment, segmentCount: segmentCount)
        let leftInset = corners.roundLeft ? Metrics.outerHorizontalInset : 0
        let rightInset = corners.roundRight ? Metrics.outerHorizontalInset : 0
        return NSRect(
            x: segmentRect.minX + leftInset,
            y: segmentRect.minY + verticalInset,
            width: segmentRect.width - leftInset - rightInset,
            height: segmentRect.height - verticalInset * 2
        )
    }

    private func tabSurfacePath(forSegment segment: Int, in rect: NSRect) -> NSBezierPath {
        let corners = tabSurfaceCorners(forSegment: segment, segmentCount: segmentCount)
        let radius = min(Metrics.tabCornerRadius, rect.height / 2, rect.width / 2)
        let leftRadius = corners.roundLeft ? radius : 0
        let rightRadius = corners.roundRight ? radius : 0
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + leftRadius, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - rightRadius, y: rect.minY))
        if rightRadius > 0 {
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - rightRadius, y: rect.minY + rightRadius),
                radius: rightRadius,
                startAngle: -90,
                endAngle: 0
            )
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - rightRadius))
        if rightRadius > 0 {
            path.appendArc(
                withCenter: NSPoint(x: rect.maxX - rightRadius, y: rect.maxY - rightRadius),
                radius: rightRadius,
                startAngle: 0,
                endAngle: 90
            )
        }
        path.line(to: NSPoint(x: rect.minX + leftRadius, y: rect.maxY))
        if leftRadius > 0 {
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + leftRadius, y: rect.maxY - leftRadius),
                radius: leftRadius,
                startAngle: 90,
                endAngle: 180
            )
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + leftRadius))
        if leftRadius > 0 {
            path.appendArc(
                withCenter: NSPoint(x: rect.minX + leftRadius, y: rect.minY + leftRadius),
                radius: leftRadius,
                startAngle: 180,
                endAngle: 270
            )
        }
        path.close()
        return path
    }

    private func tabSurfaceCorners(
        forSegment segment: Int,
        segmentCount: Int
    ) -> (roundLeft: Bool, roundRight: Bool) {
        (roundLeft: segment == 0, roundRight: segment == segmentCount - 1)
    }

    private func tabCornerPolicyReadyForSmoke() -> Bool {
        let only = tabSurfaceCorners(forSegment: 0, segmentCount: 1)
        let first = tabSurfaceCorners(forSegment: 0, segmentCount: 3)
        let middle = tabSurfaceCorners(forSegment: 1, segmentCount: 3)
        let last = tabSurfaceCorners(forSegment: 2, segmentCount: 3)
        return only.roundLeft && only.roundRight
            && first.roundLeft && !first.roundRight
            && !middle.roundLeft && !middle.roundRight
            && !last.roundLeft && last.roundRight
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
