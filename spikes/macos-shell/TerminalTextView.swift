import AppKit
import Foundation

final class TerminalTextView: NSView, NSTextInputClient {
    var onInput: ((Data) -> Void)?
    var onKeyEvent: ((NSEvent, Bool) -> Bool)?
    var onTextInput: ((String) -> Void)?
    var onMouseInput: ((NativeMouseInput) -> NativeMouseHandling)?
    var onMouseTrackingRequested: (() -> Bool)?
    var onSelectionEvent: ((NativeTerminalSelectionEvent) -> Bool)?
    var onHyperlinkRequested: (((row: Int, col: Int)) -> Bool)?
    var onCopyRequested: (() -> Bool)?
    var onPasteRequested: (() -> Bool)?
    var onSelectAllRequested: (() -> Bool)?
    var onFindRequested: (() -> Bool)?
    var onScroll: ((CGFloat) -> Void)?
    var onPaneSelected: ((Int) -> Void)?
    var onPaneChromeAction: ((NativePaneChromeAction, Int, NSView) -> Void)?
    var onSplitResize: ((Int, Int, NativePaneDividerAxis, CGFloat, Int) -> Void)?
    var onSelectionClearRequested: ((Int) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onContextMenuRequested: ((Int?, NSEvent, NSView) -> Void)?
    var onGeometryChanged: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onResetZoom: (() -> Void)?
    var onMarkedTextChanged: (() -> Void)?

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        selectionAutoscrollTimer?.invalidate()
    }

    var rendererModelSnapshot: NeovideRendererModelSnapshot?
    var terminalCursor: (x: Int, y: Int)?
    var rendererModelFrameCount = 0
    var activePaneId: Int?
    var paneFrames: [Int: NSRect] = [:]
    var paneBounds: [Int: NSRect] = [:]
    var paneDividers: [NativePaneDivider] = []
    var paneChromeViews: [Int: NativePaneChromeView] = [:]
    var activeDividerDrag: NativePaneDivider?
    var activeDividerCommandRatio: CGFloat?
    var terminalFontSize = defaultTerminalFontSize
    var terminalFont = NSFont.monospacedSystemFont(
        ofSize: defaultTerminalFontSize, weight: .regular)
    var terminalFontFamily = ""
    var paneFontSizeOffsets: [Int: CGFloat] = [:]
    var paneFonts: [Int: NSFont] = [:]
    var markedText = NSMutableAttributedString()
    var markedSelection = NSRange(location: 0, length: 0)
    var interpretingKeyEvent: NSEvent?
    var selectionInProgress = false
    var selectionAutoscrollInput: NativeMouseInput?
    var selectionAutoscrollRectangular = false
    var selectionAutoscrollTimer: Timer?
    var messageSelectionActive = false
    var wheelMouseRemainder: CGFloat = 0
    var terminalKeysDown = Set<UInt16>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        drawPaneChromeBackgrounds()
        drawPaneBorders()
        drawSplitDividerFeedback()
        drawScrollbar()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for divider in paneDividers {
            let rect = divider.hitRect.intersection(bounds)
            if !rect.isNull, !rect.isEmpty {
                addCursorRect(rect, cursor: divider.axis.cursor)
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            terminalFocusDidChange(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            terminalFocusDidChange(false)
        }
        return accepted
    }

    func terminalFocusDidChange(_ focused: Bool) {
        if !focused {
            releaseTerminalSelection(for: activePaneId)
        }
        onFocusChanged?(focused)
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityLabel() -> String? {
        "Terminal"
    }

    override func accessibilityHelp() -> String? {
        "Interactive terminal. Each pane header contains close and split actions. "
            + "Recent artifacts open from the window toolbar. Drag split borders to resize panes, "
            + "Command-click links, use "
            + "Control-Command-H/J/K/L to move between panes, and Command-F to search scrollback."
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed {
            invalidateInputCoordinates()
            onGeometryChanged?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if handleCommandKey(event) {
                return
            }
            super.keyDown(with: event)
            return
        }
        interpretingKeyEvent = event
        let handled = inputContext?.handleEvent(event) ?? false
        if !handled, !routeKeyEvent(event, released: false),
            let data = terminalInputData(for: event)
        {
            onInput?(data)
        }
        interpretingKeyEvent = nil
    }

    override func keyUp(with event: NSEvent) {
        guard terminalKeysDown.remove(event.keyCode) != nil else {
            super.keyUp(with: event)
            return
        }
        _ = routeKeyEvent(event, released: true)
    }

    override func mouseDown(with event: NSEvent) {
        cancelTerminalSelectionGesture()
        let point = convert(event.locationInWindow, from: nil)
        if let divider = divider(at: point) {
            activeDividerDrag = divider
            activeDividerCommandRatio = divider.ratio
            divider.axis.cursor.set()
            needsDisplay = true
            return
        }
        if let paneId = paneBounds.first(where: { $0.value.contains(point) })?.key {
            if paneId != activePaneId {
                setActivePaneId(paneId)
                onPaneSelected?(paneId)
            }
            if paneFrames[paneId]?.contains(point) != true {
                window?.makeFirstResponder(self)
                return
            }
        }
        if event.modifierFlags.contains(.command),
            let position = mouseGridPosition(point),
            onHyperlinkRequested?(position) == true
        {
            return
        }

        window?.makeFirstResponder(self)
        guard let input = mouseInput(button: "left", action: "press", event: event, point: point)
        else {
            return
        }
        if handleMouseInput(input) {
            return
        }
        selectionInProgress = onSelectionEvent?(.press(input)) ?? false
    }

    override func mouseUp(with event: NSEvent) {
        stopSelectionAutoscroll()
        if activeDividerDrag != nil {
            activeDividerDrag = nil
            activeDividerCommandRatio = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard
            let input = mouseInput(
                button: "left",
                action: "release",
                event: event,
                point: point,
                clampToGrid: messageSelectionActive || selectionInProgress
            )
        else {
            cancelTerminalSelectionGesture()
            return
        }
        if handleMouseInput(input) {
            cancelTerminalSelectionGesture()
            return
        }
        if selectionInProgress {
            _ = onSelectionEvent?(.release(input))
        }
        finishTerminalSelectionGesture()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if var divider = activeDividerDrag {
            let nextRatio = divider.ratio(at: point)
            let previousCommandRatio = activeDividerCommandRatio ?? divider.ratio
            let cellSize = terminalCellSize()
            let cellDelta = divider.cellDelta(
                from: previousCommandRatio,
                to: nextRatio,
                cellSize: cellSize
            )
            if cellDelta != 0 {
                activeDividerCommandRatio = divider.ratio(
                    afterCellDelta: cellDelta,
                    from: previousCommandRatio,
                    cellSize: cellSize
                )
            }
            divider.ratio = nextRatio
            activeDividerDrag = divider
            divider.axis.cursor.set()
            onSplitResize?(
                divider.firstPaneId,
                divider.secondPaneId,
                divider.axis,
                divider.ratio,
                cellDelta
            )
            needsDisplay = true
            return
        }
        guard
            let input = mouseInput(
                button: "left",
                action: "drag",
                event: event,
                point: point,
                clampToGrid: messageSelectionActive || selectionInProgress
            )
        else {
            return
        }
        if handleMouseInput(input) {
            cancelTerminalSelectionGesture()
            return
        }
        guard selectionInProgress else {
            return
        }
        let rectangular = event.modifierFlags.contains(.option)
        guard onSelectionEvent?(.drag(input, rectangular: rectangular)) == true else {
            cancelTerminalSelectionGesture()
            return
        }
        updateSelectionAutoscroll(at: point, input: input, rectangular: rectangular)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let input = mouseInput(button: "right", action: "press", event: event, point: point),
            handleMouseInput(input)
        {
            return
        }
        onContextMenuRequested?(nil, event, self)
    }

    override func rightMouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard
            let input = mouseInput(
                button: "right",
                action: "release",
                event: event,
                point: point
            )
        else {
            return
        }
        _ = handleMouseInput(input)
    }

    override func otherMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard
            let input = mouseInput(
                button: "middle",
                action: "press",
                event: event,
                point: point
            )
        else {
            return
        }
        _ = handleMouseInput(input)
    }

    override func otherMouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard
            let input = mouseInput(
                button: "middle",
                action: "release",
                event: event,
                point: point
            )
        else {
            return
        }
        _ = handleMouseInput(input)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard terminalTextRect().contains(point) else {
            super.scrollWheel(with: event)
            return
        }

        if sendWheelMouseInput(for: event, at: point) {
            return
        }

        let rows = scrollRows(for: event)
        guard rows != 0 else {
            return
        }
        onScroll?(rows)
    }

    @objc func copy(_ sender: Any?) {
        _ = onCopyRequested?()
    }

    @objc func paste(_ sender: Any?) {
        _ = onPasteRequested?()
    }

    @objc override func selectAll(_ sender: Any?) {
        _ = onSelectAllRequested?()
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        _ = onFindRequested?()
    }

    func setRendererModel(_ model: NeovideRendererModelSnapshot?) {
        rendererModelSnapshot = model
        if model != nil {
            rendererModelFrameCount += 1
        }
        needsDisplay = true
    }

    func setTerminalCursor(_ cursor: (x: Int, y: Int)?) {
        terminalCursor = cursor
        invalidateInputCoordinates()
        if hasMarkedText() {
            needsDisplay = true
        }
    }

    func updatePaneFrames(
        _ frames: [Int: NSRect],
        paneBounds: [Int: NSRect],
        activePaneId: Int?,
        dividers: [NativePaneDivider] = []
    ) {
        paneFrames = frames
        self.paneBounds = paneBounds
        paneDividers = dividers
        updatePaneChromeViews()
        setActivePaneId(activePaneId)
        invalidateInputCoordinates()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func paneChromeView(for paneId: Int) -> NativePaneChromeView? {
        paneChromeViews[paneId]
    }

    func paneChromeViewsReady(expectedCount: Int) -> Bool {
        paneChromeViews.count == expectedCount
            && paneChromeViews.values.allSatisfy {
                $0.superview === self && !$0.isHidden && $0.actionsReady()
            }
    }

    func setActivePaneId(_ paneId: Int?) {
        if activePaneId != paneId {
            wheelMouseRemainder = 0
            releaseTerminalSelection(for: activePaneId)
        }
        activePaneId = paneId
        for (candidateId, chrome) in paneChromeViews {
            chrome.update(isActive: candidateId == paneId)
        }
        needsDisplay = true
    }

    private func releaseTerminalSelection(for paneId: Int?) {
        cancelTerminalSelectionGesture()
        guard let paneId else {
            return
        }
        onSelectionClearRequested?(paneId)
    }

    func splitDividerCount(for axis: NativePaneDividerAxis) -> Int {
        paneDividers.count { $0.axis == axis }
    }

    func splitDividerUsesResizeCursor(for axis: NativePaneDividerAxis) -> Bool {
        guard let divider = paneDividers.first(where: { $0.axis == axis }) else {
            return false
        }
        let expected = axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown
        return divider.axis.cursor === expected
    }

    func resizeFirstDividerForSmoke(
        axis: NativePaneDividerAxis,
        ratio: CGFloat
    ) -> Bool {
        guard var divider = paneDividers.first(where: { $0.axis == axis }) else {
            return false
        }
        let point =
            axis == .vertical
            ? NSPoint(
                x: divider.containerRect.minX + divider.containerRect.width * ratio,
                y: divider.containerRect.midY
            )
            : NSPoint(
                x: divider.containerRect.midX,
                y: divider.containerRect.minY + divider.containerRect.height * ratio
            )
        let previousRatio = divider.ratio
        divider.ratio = divider.ratio(at: point)
        let cellDelta = divider.cellDelta(
            from: previousRatio,
            to: divider.ratio,
            cellSize: terminalCellSize()
        )
        onSplitResize?(
            divider.firstPaneId,
            divider.secondPaneId,
            divider.axis,
            divider.ratio,
            cellDelta
        )
        return true
    }

    @discardableResult
    func setTerminalFont(family: String, size: CGFloat) -> Bool {
        let clampedSize = min(max(size, minTerminalFontSize), maxTerminalFontSize)
        let normalizedFamily = family.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed =
            normalizedFamily != terminalFontFamily
            || abs(clampedSize - terminalFontSize) > 0.01
        guard changed else {
            return false
        }
        terminalFontFamily = normalizedFamily
        terminalFontSize = clampedSize
        terminalFont = configuredTerminalFont(family: normalizedFamily, size: clampedSize)
        paneFonts = Dictionary(
            uniqueKeysWithValues: paneFontSizeOffsets.keys.map { paneId in
                (paneId, configuredTerminalFont(family: normalizedFamily, size: fontSize(paneId)))
            }
        )
        needsDisplay = true
        onGeometryChanged?()
        return true
    }

    func adjustZoom(by delta: CGFloat, for paneIds: [Int]) -> Bool {
        guard let referencePaneId = paneIds.first else {
            return false
        }
        let previousSize = fontSize(referencePaneId)
        let nextSize = min(
            max(previousSize + delta, minTerminalFontSize),
            maxTerminalFontSize
        )
        guard abs(nextSize - previousSize) > 0.01 else {
            return false
        }
        return setZoomOffset(nextSize - terminalFontSize, for: paneIds)
    }

    func resetZoom(for paneIds: [Int]) -> Bool {
        setZoomOffset(0, for: paneIds)
    }

    @discardableResult
    func setZoomOffset(_ offset: CGFloat, for paneIds: [Int]) -> Bool {
        let boundedSize = min(
            max(terminalFontSize + offset, minTerminalFontSize),
            maxTerminalFontSize
        )
        let boundedOffset = boundedSize - terminalFontSize
        var changed = false
        for paneId in paneIds {
            let previousOffset = paneFontSizeOffsets[paneId] ?? 0
            guard abs(previousOffset - boundedOffset) > 0.01 else {
                continue
            }
            changed = true
            if abs(boundedOffset) <= 0.01 {
                paneFontSizeOffsets.removeValue(forKey: paneId)
                paneFonts.removeValue(forKey: paneId)
            } else {
                paneFontSizeOffsets[paneId] = boundedOffset
                paneFonts[paneId] = configuredTerminalFont(
                    family: terminalFontFamily,
                    size: boundedSize
                )
            }
        }
        guard changed else {
            return false
        }
        invalidateInputCoordinates()
        needsDisplay = true
        return true
    }

    func discardPaneZoom(_ paneId: Int) {
        paneFontSizeOffsets.removeValue(forKey: paneId)
        paneFonts.removeValue(forKey: paneId)
    }

    func fontSize(_ paneId: Int?) -> CGFloat {
        guard let paneId else {
            return terminalFontSize
        }
        return min(
            max(
                terminalFontSize + (paneFontSizeOffsets[paneId] ?? 0),
                minTerminalFontSize
            ),
            maxTerminalFontSize
        )
    }

    func fontForPane(_ paneId: Int?) -> NSFont {
        guard let paneId else {
            return terminalFont
        }
        return paneFonts[paneId] ?? terminalFont
    }

    func terminalGridSize() -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        terminalGridSize(for: terminalTextRect(), paneId: activePaneId)
    }

    func terminalGridSize(
        for textRect: NSRect
    ) -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        terminalGridSize(for: textRect, paneId: activePaneId)
    }

    func terminalGridSize(
        for textRect: NSRect,
        paneId: Int?
    ) -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        let cellSize = terminalCellSize(for: paneId)
        let cols = max(1, Int(textRect.width / cellSize.width))
        let rows = max(1, Int(textRect.height / cellSize.height))
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let widthPixels = max(1, Int(textRect.width * scale))
        let heightPixels = max(1, Int(textRect.height * scale))
        return (rows, cols, widthPixels, heightPixels)
    }

    func skiaRenderGeometry() -> SkiaRenderGeometry {
        skiaRenderGeometry(for: terminalTextRect(), paneId: activePaneId)
    }

    func skiaRenderGeometry(for textRect: NSRect) -> SkiaRenderGeometry {
        skiaRenderGeometry(for: textRect, paneId: activePaneId)
    }

    func skiaRenderGeometry(for textRect: NSRect, paneId: Int?) -> SkiaRenderGeometry {
        let cellSize = terminalCellSize(for: paneId)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return SkiaRenderGeometry(
            originX: Float(textRect.minX * scale),
            originY: Float(textRect.minY * scale),
            contentWidth: Float(textRect.width * scale),
            contentHeight: Float(textRect.height * scale),
            cellWidth: Float(cellSize.width * scale),
            cellHeight: Float(cellSize.height * scale)
        )
    }

    func drawPaneBorders() {
        guard paneBounds.count > 1 else {
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let lineWidth = 1 / max(1, scale)
        for (paneId, rect) in paneBounds {
            let path = NSBezierPath(
                rect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            )
            path.lineWidth = lineWidth
            (paneId == activePaneId
                ? NSColor.systemBlue.withAlphaComponent(0.55)
                : NSColor.separatorColor.withAlphaComponent(0.24)).setStroke()
            path.stroke()
        }
    }

    func drawPaneChromeBackgrounds() {
        for (paneId, paneRect) in paneBounds {
            let height = min(nativePaneChromeHeight, paneRect.height)
            let headerRect = NSRect(
                x: paneRect.minX,
                y: paneRect.minY,
                width: paneRect.width,
                height: height
            )
            NSColor.black.withAlphaComponent(paneId == activePaneId ? 0.2 : 0.12).setFill()
            headerRect.fill()
            NSColor.separatorColor.withAlphaComponent(0.28).setFill()
            NSRect(x: headerRect.minX, y: headerRect.maxY - 1, width: headerRect.width, height: 1)
                .fill()
        }
    }

    private func updatePaneChromeViews() {
        let visiblePaneIds = Set(paneBounds.keys)
        let stalePaneIds = paneChromeViews.keys.filter { !visiblePaneIds.contains($0) }
        for paneId in stalePaneIds {
            paneChromeViews[paneId]?.removeFromSuperview()
            paneChromeViews.removeValue(forKey: paneId)
        }
        for (paneId, paneRect) in paneBounds {
            let chrome: NativePaneChromeView
            if let existing = paneChromeViews[paneId] {
                chrome = existing
            } else {
                let actions: [NativePaneChromeAction] =
                    paneId == nativeArtifactSidebarPaneId
                    ? [.close] : NativePaneChromeAction.allCases
                chrome = NativePaneChromeView(paneId: paneId, actions: actions)
                chrome.onAction = { [weak self] action, paneId, sourceView in
                    self?.onPaneChromeAction?(action, paneId, sourceView)
                }
                paneChromeViews[paneId] = chrome
                addSubview(chrome)
            }
            let availableWidth = max(1, paneRect.width - 8)
            let width = min(chrome.preferredWidth, availableWidth)
            let headerHeight = min(nativePaneChromeHeight, paneRect.height)
            let height = min(NativePaneChromeView.controlHeight, headerHeight)
            chrome.frame = NSRect(
                x: paneRect.maxX - width - 4,
                y: paneRect.minY + floor((headerHeight - height) / 2),
                width: width,
                height: height
            )
            chrome.isHidden = paneRect.width < 40 || paneRect.height < 12
            chrome.update(isActive: paneId == activePaneId)
        }
    }

    func drawSplitDividerFeedback() {
        guard let activeDividerDrag else {
            return
        }
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        activeDividerDrag.indicatorRect.fill()
    }

    func divider(at point: NSPoint) -> NativePaneDivider? {
        paneDividers.reversed().first { $0.hitRect.contains(point) }
    }

    func drawScrollbar() {
        guard let scrollbar = rendererModelSnapshot?.scrollbar,
            scrollbar.total > scrollbar.visible,
            scrollbar.total > 0
        else {
            return
        }
        let textRect = terminalTextRect()
        let track = NSRect(
            x: textRect.maxX - 5, y: textRect.minY, width: 4, height: textRect.height)
        let visibleFraction = CGFloat(scrollbar.visible) / CGFloat(scrollbar.total)
        let thumbHeight = max(18, track.height * visibleFraction)
        let maxTop = scrollbar.total - scrollbar.visible
        let historyOffset = maxTop == 0 ? 0 : CGFloat(scrollbar.top) / CGFloat(maxTop)
        let thumbY = track.minY + (track.height - thumbHeight) * (1 - historyOffset)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.75).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: track.minX, y: thumbY, width: track.width, height: thumbHeight),
            xRadius: 2,
            yRadius: 2
        ).fill()
    }

    func rendererModelRows(_ model: NeovideRendererModelSnapshot)
        -> [[TerminalCellSnapshot]]
    {
        let mainWindow = model.windows.first { $0.grid_id == 1 }
        let grid = terminalGridSize()
        let rowCount = max(1, mainWindow?.height ?? grid.rows)
        let colCount = max(1, mainWindow?.width ?? grid.cols)
        var rows = Array(
            repeating: rendererModelBlankRow(cols: colCount),
            count: rowCount
        )

        for window in sortedRendererWindows(model.windows) where !window.hidden {
            overlayRendererWindow(window, into: &rows)
        }
        return rows
    }

    func rendererModelBlankRow(cols: Int) -> [TerminalCellSnapshot] {
        Array(
            repeating: TerminalCellSnapshot(
                text: " ",
                bg: nil,
                blend: 0
            ),
            count: cols
        )
    }

    func sortedRendererWindows(
        _ windows: [NeovideRenderedWindowSnapshot]
    ) -> [NeovideRenderedWindowSnapshot] {
        windows.sorted {
            ($0.zindex, $0.compindex, $0.grid_id) < ($1.zindex, $1.compindex, $1.grid_id)
        }
    }

    func overlayRendererWindow(
        _ window: NeovideRenderedWindowSnapshot,
        into rows: inout [[TerminalCellSnapshot]]
    ) {
        let maxRow = min(window.height, window.lines.count)
        for sourceRow in 0..<maxRow {
            let targetRow = window.top + sourceRow
            guard rows.indices.contains(targetRow),
                let line = window.lines[sourceRow]
            else {
                continue
            }
            overlayRendererLine(
                line,
                targetRow: targetRow,
                left: window.left,
                width: window.width,
                rows: &rows
            )
        }
    }

    func overlayRendererLine(
        _ line: NeovideLineSnapshot,
        targetRow: Int,
        left: Int,
        width: Int,
        rows: inout [[TerminalCellSnapshot]]
    ) {
        let targetWidth = min(width, line.cells.count)
        guard targetWidth > 0 else {
            return
        }

        var row = rows[targetRow]
        if row.count < left + targetWidth {
            row.append(contentsOf: rendererModelBlankRow(cols: left + targetWidth - row.count))
        }
        for sourceCol in 0..<targetWidth {
            row[left + sourceCol] = line.cells[sourceCol]
        }
        rows[targetRow] = row
    }

    func rowPlainText(_ row: [TerminalCellSnapshot]) -> String {
        row.map(\.text).joined()
    }

    func contentRowCount(_ rows: [[TerminalCellSnapshot]]) -> Int {
        rows.filter { !rowPlainText($0).trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
}
