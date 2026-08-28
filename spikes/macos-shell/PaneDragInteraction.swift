import AppKit

struct NativePaneDropTarget: Equatable {
    let paneId: Int
    let position: NativePaneDropPosition
    let indicatorRect: NSRect
}

func nativePaneAlreadyOccupiesDropSide(
    sourceRect: NSRect,
    targetRect: NSRect,
    position: NativePaneDropPosition
) -> Bool {
    guard sourceRect.width > 0, sourceRect.height > 0,
        targetRect.width > 0, targetRect.height > 0
    else {
        return false
    }
    let tolerance: CGFloat = 1
    let sameVerticalSpan =
        abs(sourceRect.minY - targetRect.minY) <= tolerance
        && abs(sourceRect.maxY - targetRect.maxY) <= tolerance
    let sameHorizontalSpan =
        abs(sourceRect.minX - targetRect.minX) <= tolerance
        && abs(sourceRect.maxX - targetRect.maxX) <= tolerance
    switch position {
    case .center:
        return false
    case .left:
        return sameVerticalSpan && abs(sourceRect.maxX - targetRect.minX) <= tolerance
    case .right:
        return sameVerticalSpan && abs(sourceRect.minX - targetRect.maxX) <= tolerance
    case .top:
        return sameHorizontalSpan && abs(sourceRect.maxY - targetRect.minY) <= tolerance
    case .bottom:
        return sameHorizontalSpan && abs(sourceRect.minY - targetRect.maxY) <= tolerance
    }
}

func nativePaneDropTarget(
    sourcePaneId: Int,
    point: NSPoint,
    paneBounds: [Int: NSRect]
) -> NativePaneDropTarget? {
    guard
        let candidate = paneBounds.sorted(by: { $0.key < $1.key }).first(where: {
            $0.key != sourcePaneId
                && $0.key != nativeArtifactSidebarPaneId
                && $0.value.contains(point)
        })
    else {
        return nil
    }
    let rect = candidate.value
    guard rect.width > 0, rect.height > 0 else {
        return nil
    }
    let center = rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.28)
    if center.contains(point) {
        return NativePaneDropTarget(
            paneId: candidate.key,
            position: .center,
            indicatorRect: nativePaneDropIndicatorRect(rect.insetBy(dx: 6, dy: 6))
        )
    }

    let distances: [(NativePaneDropPosition, CGFloat)] = [
        (.left, (point.x - rect.minX) / rect.width),
        (.right, (rect.maxX - point.x) / rect.width),
        (.top, (point.y - rect.minY) / rect.height),
        (.bottom, (rect.maxY - point.y) / rect.height),
    ]
    guard let position = distances.min(by: { $0.1 < $1.1 })?.0 else {
        return nil
    }
    let region =
        switch position {
        case .center:
            rect
        case .left:
            NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right:
            NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top:
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom:
            NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    return NativePaneDropTarget(
        paneId: candidate.key,
        position: position,
        indicatorRect: nativePaneDropIndicatorRect(region)
    )
}

final class NativePaneDragInteraction {
    weak var view: TerminalTextView?

    private(set) var sourcePaneId: Int?
    private(set) var dropTarget: NativePaneDropTarget?
    private var isNoChangeTarget = false
    private var sourceRect = NSRect.zero
    private var pointerGoal = NSPoint.zero
    private var proxyPoint = NSPoint.zero
    private var indicatorRect = NSRect.zero
    private var indicatorGoal = NSRect.zero
    private var opacity: CGFloat = 0
    private var settling = false
    private var accepted = false
    private var animationTimer: Timer?

    deinit {
        invalidate()
    }

    func begin(sourcePaneId: Int, point: NSPoint) -> Bool {
        guard let view,
            sourcePaneId != nativeArtifactSidebarPaneId,
            view.onPaneDropChangesLayout != nil,
            view.onPaneMoveRequested != nil,
            let sourceRect = view.paneBounds[sourcePaneId],
            view.paneBounds.keys.contains(where: {
                $0 != sourcePaneId && $0 != nativeArtifactSidebarPaneId
            })
        else {
            return false
        }
        self.sourcePaneId = sourcePaneId
        self.sourceRect = sourceRect
        pointerGoal = point
        proxyPoint = NSPoint(
            x: min(max(point.x, sourceRect.minX + 42), sourceRect.maxX - 42),
            y: sourceRect.minY + min(nativePaneChromeHeight, sourceRect.height) / 2
        )
        indicatorRect = nativePaneHeaderRect(sourceRect).insetBy(dx: 4, dy: 2)
        indicatorGoal = indicatorRect
        dropTarget = nil
        isNoChangeTarget = false
        opacity = 1
        settling = false
        accepted = false
        startAnimationTimer()
        view.needsDisplay = true
        return true
    }

    func update(point: NSPoint) {
        guard let view, let sourcePaneId, !settling else {
            return
        }
        pointerGoal = point
        let candidate = nativePaneDropTarget(
            sourcePaneId: sourcePaneId,
            point: point,
            paneBounds: view.paneBounds
        )
        let nextTarget: NativePaneDropTarget? = candidate.flatMap { candidate in
            guard let targetRect = view.paneBounds[candidate.paneId],
                !nativePaneAlreadyOccupiesDropSide(
                    sourceRect: sourceRect,
                    targetRect: targetRect,
                    position: candidate.position
                )
            else {
                return nil
            }
            let changesLayout =
                view.onPaneDropChangesLayout?(
                    sourcePaneId,
                    candidate.paneId,
                    candidate.position
                ) == true
            return changesLayout ? candidate : nil
        }
        let nextIsNoChangeTarget = nextTarget == nil && candidate != nil
        if nextTarget != dropTarget || nextIsNoChangeTarget != isNoChangeTarget {
            dropTarget = nextTarget
            isNoChangeTarget = nextIsNoChangeTarget
            indicatorGoal =
                nextTarget?.indicatorRect
                ?? nativePaneHeaderRect(sourceRect).insetBy(dx: 4, dy: 2)
        }
        view.needsDisplay = true
    }

    @discardableResult
    func finish(point: NSPoint) -> Bool {
        guard let view, let sourcePaneId, !settling else {
            cancel()
            return false
        }
        update(point: point)
        let target = dropTarget
        accepted =
            target.map {
                view.onPaneMoveRequested?(sourcePaneId, $0.paneId, $0.position) ?? false
            } ?? false
        settling = true
        pointerGoal = accepted ? indicatorGoal.center : nativePaneHeaderRect(sourceRect).center
        view.needsDisplay = true
        return accepted
    }

    func cancel() {
        guard sourcePaneId != nil else {
            return
        }
        accepted = false
        settling = true
        pointerGoal = nativePaneHeaderRect(sourceRect).center
        view?.needsDisplay = true
    }

    func invalidate() {
        animationTimer?.invalidate()
        animationTimer = nil
        sourcePaneId = nil
        dropTarget = nil
        isNoChangeTarget = false
        opacity = 0
        settling = false
    }

    func draw() {
        guard sourcePaneId != nil, opacity > 0.01 else {
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let suppressingNoChangePreview = isNoChangeTarget
        let accent =
            suppressingNoChangePreview
            ? NSColor.secondaryLabelColor
            : accepted || !settling ? NSColor.controlAccentColor : NSColor.systemOrange
        if !suppressingNoChangePreview {
            accent.withAlphaComponent(0.055 * opacity).setFill()
            NSBezierPath(
                roundedRect: sourceRect.insetBy(dx: 2, dy: 2),
                xRadius: 7,
                yRadius: 7
            ).fill()
        }

        if dropTarget != nil {
            accent.withAlphaComponent(0.2 * opacity).setFill()
            accent.withAlphaComponent(0.9 * opacity).setStroke()
            let path = NSBezierPath(roundedRect: indicatorRect, xRadius: 9, yRadius: 9)
            path.lineWidth = 2
            path.fill()
            path.stroke()
            drawDropSymbol()
        }
        drawProxy(
            accent: accent,
            label: suppressingNoChangePreview ? "Already there" : "Move pane"
        )
    }

    #if SATIN_SMOKE_SCENARIOS
        func animatedDropPreviewReadyForSmoke() -> Bool {
            dropTarget != nil && animationTimer?.isValid == true
        }

        func noChangePreviewSuppressedForSmoke() -> Bool {
            isNoChangeTarget && dropTarget == nil && animationTimer?.isValid == true
        }

        func settledForSmoke() -> Bool {
            sourcePaneId == nil && animationTimer == nil
        }
    #endif

    private func startAnimationTimer() {
        animationTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func tick() {
        proxyPoint = proxyPoint.interpolated(toward: pointerGoal, amount: settling ? 0.24 : 0.34)
        indicatorRect = indicatorRect.interpolated(toward: indicatorGoal, amount: 0.26)
        if settling {
            opacity *= 0.78
            if opacity < 0.025 {
                invalidate()
            }
        }
        view?.needsDisplay = true
    }

    private func drawProxy(accent: NSColor, label: String) {
        let width = min(210, max(96, sourceRect.width * 0.42))
        let rect = NSRect(
            x: proxyPoint.x - width / 2,
            y: proxyPoint.y - 11,
            width: width,
            height: 22
        )
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: 3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3 * opacity)
        shadow.set()
        NSColor.windowBackgroundColor.withAlphaComponent(0.94 * opacity).setFill()
        accent.withAlphaComponent(0.95 * opacity).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        path.lineWidth = 1.5
        path.fill()
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.9 * opacity),
        ]
        NSAttributedString(string: label, attributes: attributes).draw(
            at: NSPoint(x: rect.minX + 24, y: rect.minY + 4)
        )
        accent.withAlphaComponent(0.9 * opacity).setFill()
        for row in 0..<3 {
            for column in 0..<2 {
                NSBezierPath(
                    ovalIn: NSRect(
                        x: rect.minX + 10 + CGFloat(column) * 4,
                        y: rect.minY + 6 + CGFloat(row) * 4,
                        width: 2,
                        height: 2
                    )
                ).fill()
            }
        }
    }

    private func drawDropSymbol() {
        guard let position = dropTarget?.position,
            let image = NSImage(
                systemSymbolName: position.symbolName,
                accessibilityDescription: position.accessibilityLabel
            )
        else {
            return
        }
        let size = NSSize(width: 16, height: 16)
        let rect = NSRect(
            x: indicatorRect.midX - size.width / 2,
            y: indicatorRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
    }
}

extension TerminalTextView {
    func handlePaneChromePress(paneId: Int) {
        if paneId != activePaneId {
            setActivePaneId(paneId)
            onPaneSelected?(paneId)
        }
        window?.makeFirstResponder(self)
    }

    func handlePaneChromeDrag(
        phase: NativePaneChromeDragPhase,
        paneId: Int,
        locationInWindow: NSPoint
    ) -> Bool {
        switch phase {
        case .cancelled:
            paneDragInteraction.cancel()
            return true
        case .began:
            let point = convert(locationInWindow, from: nil)
            return paneDragInteraction.begin(sourcePaneId: paneId, point: point)
        case .changed:
            let point = convert(locationInWindow, from: nil)
            paneDragInteraction.update(point: point)
            return paneDragInteraction.sourcePaneId == paneId
        case .ended:
            let point = convert(locationInWindow, from: nil)
            return paneDragInteraction.finish(point: point)
        }
    }

    #if SATIN_SMOKE_SCENARIOS
        @discardableResult
        func simulatePaneDragForSmoke(
            sourcePaneId: Int,
            targetPaneId: Int,
            position: NativePaneDropPosition
        ) -> Bool {
            guard let sourceRect = paneBounds[sourcePaneId],
                let targetRect = paneBounds[targetPaneId],
                paneChromeViews[sourcePaneId]?.dragHandleReadyForSmoke() == true
            else {
                return false
            }
            let start = nativePaneHeaderRect(sourceRect).center
            let targetPoint = position.smokePoint(in: targetRect)
            let startInWindow = convert(start, to: nil)
            let targetInWindow = convert(targetPoint, to: nil)
            var previewWasAnimated = false
            let committed =
                paneChromeViews[sourcePaneId]?.simulateDragForSmoke(
                    from: startInWindow,
                    to: targetInWindow,
                    verifyPreview: { [weak self] in
                        previewWasAnimated =
                            self?.paneDragInteraction.animatedDropPreviewReadyForSmoke() == true
                        return previewWasAnimated
                    }
                ) == true
            return committed && previewWasAnimated
        }

        func simulatePaneDragCancellationForSmoke(sourcePaneId: Int) -> Bool {
            guard let sourceRect = paneBounds[sourcePaneId],
                let chrome = paneChromeViews[sourcePaneId],
                chrome.dragHandleReadyForSmoke()
            else {
                return false
            }
            let start = convert(nativePaneHeaderRect(sourceRect).center, to: nil)
            let outside = convert(
                NSPoint(x: bounds.maxX + 80, y: bounds.maxY + 80),
                to: nil
            )
            let committed = chrome.simulateDragForSmoke(from: start, to: outside)
            return !committed && paneDragInteraction.sourcePaneId == sourcePaneId
        }

        func simulatePaneNoChangeDragForSmoke(
            sourcePaneId: Int,
            targetPaneId: Int,
            position: NativePaneDropPosition
        ) -> Bool {
            guard let sourceRect = paneBounds[sourcePaneId],
                let targetRect = paneBounds[targetPaneId],
                let chrome = paneChromeViews[sourcePaneId],
                chrome.dragHandleReadyForSmoke()
            else {
                return false
            }
            let start = convert(nativePaneHeaderRect(sourceRect).center, to: nil)
            let target = convert(position.smokePoint(in: targetRect), to: nil)
            var previewWasSuppressed = false
            let committed = chrome.simulateDragForSmoke(
                from: start,
                to: target,
                verifyPreview: { [weak self] in
                    previewWasSuppressed =
                        self?.paneDragInteraction.noChangePreviewSuppressedForSmoke() == true
                    return previewWasSuppressed
                }
            )
            return !committed && previewWasSuppressed
        }
    #endif
}

func runNativePaneDragGeometrySelfTests() -> Bool {
    let panes = [
        1: NSRect(x: 0, y: 0, width: 200, height: 160),
        2: NSRect(x: 200, y: 0, width: 200, height: 160),
        nativeArtifactSidebarPaneId: NSRect(x: 400, y: 0, width: 80, height: 160),
    ]
    guard let targetRect = panes[2] else {
        return false
    }
    let leftRect = panes[1] ?? .zero
    let middleRect = targetRect
    let rightRect = NSRect(x: 400, y: 0, width: 200, height: 160)
    let partialHeightRect = NSRect(x: 0, y: 0, width: 200, height: 80)
    return NativePaneDropPosition.allCases.allSatisfy { position in
        let point = position.smokePoint(in: targetRect)
        let target = nativePaneDropTarget(sourcePaneId: 1, point: point, paneBounds: panes)
        return target?.paneId == 2
            && target?.position == position
            && target?.indicatorRect.isEmpty == false
    }
        && nativePaneDropTarget(
            sourcePaneId: 1,
            point: NSPoint(x: 440, y: 80),
            paneBounds: panes
        ) == nil
        && nativePaneAlreadyOccupiesDropSide(
            sourceRect: middleRect,
            targetRect: rightRect,
            position: .left
        )
        && nativePaneAlreadyOccupiesDropSide(
            sourceRect: middleRect,
            targetRect: leftRect,
            position: .right
        )
        && !nativePaneAlreadyOccupiesDropSide(
            sourceRect: middleRect,
            targetRect: leftRect,
            position: .left
        )
        && !nativePaneAlreadyOccupiesDropSide(
            sourceRect: partialHeightRect,
            targetRect: middleRect,
            position: .left
        )
}

private func nativePaneHeaderRect(_ paneRect: NSRect) -> NSRect {
    NSRect(
        x: paneRect.minX,
        y: paneRect.minY,
        width: paneRect.width,
        height: min(nativePaneChromeHeight, paneRect.height)
    )
}

private func nativePaneDropIndicatorRect(_ rect: NSRect) -> NSRect {
    rect.insetBy(dx: min(4, rect.width * 0.08), dy: min(4, rect.height * 0.08))
}

extension NativePaneDropPosition {
    fileprivate var symbolName: String {
        switch self {
        case .center: "arrow.left.arrow.right"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .top: "arrow.up"
        case .bottom: "arrow.down"
        }
    }

    fileprivate var accessibilityLabel: String {
        switch self {
        case .center: "Swap panes"
        case .left: "Move pane left"
        case .right: "Move pane right"
        case .top: "Move pane above"
        case .bottom: "Move pane below"
        }
    }

    fileprivate func smokePoint(in rect: NSRect) -> NSPoint {
        switch self {
        case .center: rect.center
        case .left: NSPoint(x: rect.minX + rect.width * 0.2, y: rect.midY)
        case .right: NSPoint(x: rect.maxX - rect.width * 0.2, y: rect.midY)
        case .top: NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.2)
        case .bottom: NSPoint(x: rect.midX, y: rect.maxY - rect.height * 0.2)
        }
    }
}

extension NSPoint {
    fileprivate func interpolated(toward target: NSPoint, amount: CGFloat) -> NSPoint {
        NSPoint(
            x: x + (target.x - x) * amount,
            y: y + (target.y - y) * amount
        )
    }
}

extension NSRect {
    fileprivate var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }

    fileprivate func interpolated(toward target: NSRect, amount: CGFloat) -> NSRect {
        NSRect(
            x: origin.x + (target.origin.x - origin.x) * amount,
            y: origin.y + (target.origin.y - origin.y) * amount,
            width: width + (target.width - width) * amount,
            height: height + (target.height - height) * amount
        )
    }
}
