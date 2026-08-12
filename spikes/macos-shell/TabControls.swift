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

final class NativeTabControl: NSSegmentedControl {
    private enum Metrics {
        static let closeHitWidth: CGFloat = 26
        static let closeGlyphSize: CGFloat = 7
        static let closeTrailingInset: CGFloat = 4
    }

    var onRenameRequested: ((Int) -> Void)?
    var onCloseRequested: ((Int) -> Void)?
    var onContextMenuRequested: ((Int, NSEvent, NSView) -> Void)?

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

    func simulateCloseForSmoke(segment: Int) {
        guard let target = closeButtonRect(forSegment: segment) else {
            return
        }
        _ = handleClose(at: NSPoint(x: target.midX, y: target.midY))
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
        onCloseRequested?(segment)
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let segment = segmentIndex(at: point) else {
            super.rightMouseDown(with: event)
            return
        }
        selectedSegment = segment
        onContextMenuRequested?(segment, event, self)
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
