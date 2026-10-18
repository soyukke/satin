import AppKit

final class NativeTabControl: NSSegmentedControl {
    private enum Metrics {
        static let labelReservedWidth: CGFloat = 66
        static let overlayInset: CGFloat = 2
        static let selectedVerticalInset: CGFloat = 1.5
        static let outerHorizontalInset: CGFloat = 2.5
        static let tabCornerRadius: CGFloat = 6
        static let badgeTitleLeadingInset: CGFloat = 28
        static let badgeCenterInset: CGFloat = 15
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
    private var statusBadges = [Int: NativeTabStatusBadge]()
    /// Whether tabs waiting for the user burn a fuse round their edge.
    var showsFuses = false {
        didSet {
            updateFuses()
        }
    }
    private(set) lazy var fuseView: NativeTabFuseView = {
        let view = NativeTabFuseView(frame: bounds)
        view.segmentRect = { [weak self] in self?.segmentFrameForNavigation($0) }
        addSubview(view)
        return view
    }()
    private(set) lazy var signalView: NativeTabSignalView = {
        let view = NativeTabSignalView(frame: bounds)
        view.segmentRect = { [weak self] in self?.segmentFrameForNavigation($0) }
        view.badgeCenter = { [weak self] segment in
            self?.segmentRect(for: segment).map {
                NSPoint(x: $0.minX + Metrics.badgeCenterInset, y: $0.midY)
            }
        }
        addSubview(view)
        return view
    }()
    private var activityTimer: Timer?
    /// The tab the selection is moving away from, while it moves.
    private var selectionFrom: Int?
    private var selectionProgress: CGFloat = 1
    private let selectionMotion = NativeTween()

    /// A new choice moves the terminal look's frame across from the old tab,
    /// and pops paper's chosen tab up out of the line.
    override var selectedSegment: Int {
        didSet {
            guard oldValue != selectedSegment, oldValue >= 0, oldValue < segmentCount,
                window != nil
            else {
                return
            }
            selectionFrom = oldValue
            selectionMotion.run(duration: 0.32) { [weak self] progress in
                guard let self else { return }
                self.selectionProgress = progress
                if progress >= 1 {
                    self.selectionFrom = nil
                }
                self.needsDisplay = true
            }
        }
    }

    deinit {
        selectionMotion.stop()
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
            guard var segmentRect = segmentRect(for: segment), segmentRect.intersects(clipRect)
            else {
                continue
            }
            if NativePageStyle.paper, segment == selectedSegment, selectionFrom != nil {
                // Rises from the line and settles with a small bounce.
                let sink = (1 - NativeEase.back(selectionProgress, overshoot: 2.2)) * 7
                segmentRect = segmentRect.offsetBy(dx: 0, dy: isFlipped ? sink : -sink)
            }
            if NativePageStyle.paper {
                drawPaperTab(forSegment: segment, in: segmentRect)
            } else {
                drawSelectedSurfaceIfNeeded(forSegment: segment, in: segmentRect)
            }
            drawInteractionOverlay(forSegment: segment, in: segmentRect)
            drawTitle(forSegment: segment, in: segmentRect)
            if closeGlyphVisible(forSegment: segment) {
                drawCloseGlyph(forSegment: segment)
            }
            drawDragIndicatorIfNeeded(forSegment: segment, in: segmentRect)
        }
        if NativePageStyle.paper {
            drawPaperBaseline()
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

    func setStatusBadges(_ badges: [Int: NativeTabStatusBadge]) {
        let next = badges.filter { segment, _ in
            segment >= 0 && segment < segmentCount
        }
        guard next != statusBadges else {
            return
        }
        statusBadges = next
        updateActivityTimer()
        updateFuses()
        signalView.update(running: Set(statusBadges.filter { $0.value == .running }.keys))
        needsDisplay = true
    }

    private func updateFuses() {
        var colors = [Int: NSColor]()
        if showsFuses {
            for (segment, badge) in statusBadges {
                switch badge {
                case .waiting: colors[segment] = .systemOrange
                case .failed: colors[segment] = .systemRed
                case .running, .done: break
                }
            }
        }
        fuseView.update(colors)
    }

    func runningActivityReadyForSmoke(segment: Int) -> Bool {
        statusBadges[segment] == .running && activityTimer?.isValid == true
    }

    func statusBadgeForSmoke(segment: Int) -> NativeTabStatusBadge? {
        statusBadges[segment]
    }

    func contextMenuReadyForSmoke(segment: Int) -> Bool {
        let menu = contextMenuForSmoke(segment: segment)
        return contextMenuMonitorReadyForSmoke()
            && menu?.items.map(\.title) == ["Rename Tab…", "", "Close Tab"]
            && menu?.items.first?.representedObject as? Int == segment
            && menu?.items.last?.representedObject as? Int == segment
    }

    /// Plays the end of a tab's work over the tab.
    func signalFinish(segment: Int, failed: Bool) {
        guard segment >= 0, segment < segmentCount else {
            return
        }
        signalView.finish(segment: segment, failed: failed)
    }

    func finishSnapshotSync(previousFrame: NSRect) {
        fuseView.needsLayout = true
        signalView.needsLayout = true
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

    /// The terminal look marks the chosen tab as a datasheet does a field: a
    /// square violet frame over a faint violet wash.
    private func drawSelectedSurfaceIfNeeded(forSegment segment: Int, in segmentRect: NSRect) {
        guard segment == selectedSegment else {
            return
        }
        var rect = nativeTerminalTabFrame(segmentRect)
        if let from = selectionFrom.flatMap({ self.segmentRect(for: $0) }) {
            rect = NativeEase.mix(
                nativeTerminalTabFrame(from), rect,
                NativeEase.back(selectionProgress, overshoot: 1.2))
        }
        guard rect.width > 0, rect.height > 0 else {
            return
        }
        let path = NSBezierPath(rect: rect)
        let violet = NativePageStyle.violet
        violet.withAlphaComponent(window?.isKeyWindow == true ? 0.08 : 0.04).setFill()
        path.fill()
        violet.withAlphaComponent(window?.isKeyWindow == true ? 0.7 : 0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawPaperTab(forSegment segment: Int, in segmentRect: NSRect) {
        NativePaperTab.draw(
            in: NativePaperTab.rect(segmentRect, flipped: isFlipped),
            selected: segment == selectedSegment, flipped: isFlipped)
    }

    /// The ink line the tabs stand on, broken under the chosen one.
    private func drawPaperBaseline() {
        guard let first = segmentRect(for: 0) else {
            return
        }
        let tab = NativePaperTab.rect(first, flipped: isFlipped)
        let foot = isFlipped ? tab.maxY : tab.minY
        let chosen = segmentRect(for: selectedSegment).map {
            NativePaperTab.rect($0, flipped: isFlipped)
        }
        let line = NSBezierPath()
        line.move(to: NSPoint(x: bounds.minX, y: foot))
        if let chosen {
            line.line(to: NSPoint(x: chosen.minX, y: foot))
            line.move(to: NSPoint(x: chosen.maxX, y: foot))
        }
        line.line(to: NSPoint(x: bounds.maxX, y: foot))
        NativePageStyle.text.setStroke()
        line.lineWidth = 2
        line.stroke()
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
        if NativePageStyle.paper {
            color = selected ? NativePageStyle.text : NativePageStyle.muted
        } else if selected {
            color = NativePageStyle.text
        } else if hovered {
            color = NativePageStyle.text.withAlphaComponent(0.8)
        } else {
            color = NativePageStyle.muted
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        // The terminal look numbers its tabs in a datasheet's mono type.
        let terminal = !NativePageStyle.paper
        let attributes: [NSAttributedString.Key: Any] = [
            .font: terminal
                ? NSFont.monospacedSystemFont(ofSize: 12, weight: selected ? .semibold : .regular)
                : NSFont.systemFont(ofSize: 13, weight: selected ? .bold : .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let shown = terminal ? String(format: "%02d %@", segment + 1, label) : label
        let attributed = NSAttributedString(string: shown, attributes: attributes)
        let height = ceil(attributed.size().height)
        if let badge = statusBadges[segment] {
            NativeTabStatusBadgeRenderer.draw(
                badge,
                center: NSPoint(
                    x: segmentRect.minX + Metrics.badgeCenterInset,
                    y: segmentRect.midY
                ),
                selected: selected
            )
        }
        let leading = segmentRect.minX + Metrics.badgeTitleLeadingInset
        let trailing = closeRect.minX - Metrics.titleTrailingSpacing
        let titleRect = NSRect(
            x: leading,
            y: floor(segmentRect.midY - height / 2),
            width: max(0, trailing - leading),
            height: height
        )
        attributed.draw(in: titleRect)
    }

    /// Only the tabs with a turning mark change between two ticks.
    private func redrawRunningSegments() {
        for (segment, badge) in statusBadges where badge == .running {
            if let rect = segmentRect(for: segment) {
                setNeedsDisplay(rect)
            }
        }
    }

    private func updateActivityTimer() {
        activityTimer?.invalidate()
        activityTimer = nil
        guard window != nil, statusBadges.values.contains(.running) else {
            return
        }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.redrawRunningSegments()
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
