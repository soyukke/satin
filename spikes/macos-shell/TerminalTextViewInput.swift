import AppKit
import Foundation

extension TerminalTextView {
    func handleCommandKey(_ event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers ?? event.characters else {
            return false
        }

        switch key {
        case "c":
            return onCopyRequested?() ?? false
        case "v":
            return onPasteRequested?() ?? false
        case "a":
            return onSelectAllRequested?() ?? false
        case "f":
            return onFindRequested?() ?? false
        case "=", "+":
            onZoomIn?()
            return true
        case "-":
            onZoomOut?()
            return true
        case "0":
            onResetZoom?()
            return true
        default:
            return false
        }
    }

    func drawMarkedText() {
        guard markedText.length > 0 else {
            return
        }
        let textRect = terminalTextRect()
        let cell = terminalCellSize()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: fontForPane(activePaneId),
            .foregroundColor: NSColor.textColor,
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let value = NSAttributedString(string: markedText.string, attributes: attributes)
        let origin = compositionOrigin()
        value.draw(
            in: NSRect(
                x: origin.x,
                y: origin.y,
                width: max(cell.width, textRect.maxX - origin.x),
                height: cell.height
            )
        )
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let wasComposing = hasMarkedText()
        unmarkText()
        guard !value.isEmpty else {
            return
        }
        if !wasComposing, let event = interpretingKeyEvent,
            routeKeyEvent(event, released: false)
        {
            return
        }
        onTextInput?(value)
    }

    override func doCommand(by selector: Selector) {
        guard let event = interpretingKeyEvent else {
            return
        }
        if !routeKeyEvent(event, released: false), let data = terminalInputData(for: event) {
            onInput?(data)
        }
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else {
            markedText = NSMutableAttributedString(string: string as? String ?? "")
        }
        markedSelection = clampedRange(selectedRange, length: markedText.length)
        needsDisplay = true
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        needsDisplay = true
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        hasMarkedText()
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .foregroundColor, .backgroundColor]
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard hasMarkedText() else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        let available = NSRange(location: 0, length: markedText.length)
        let intersection = NSIntersectionRange(range, available)
        guard intersection.location != NSNotFound, intersection.length > 0 else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        actualRange?.pointee = intersection
        return markedText.attributedSubstring(from: intersection)
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard hasMarkedText() else {
            return 0
        }
        let local = convert(point, from: nil)
        let origin = compositionOrigin()
        let index = Int(((local.x - origin.x) / terminalCellSize().width).rounded(.down))
        return min(max(index, 0), markedText.length)
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        let origin = compositionOrigin()
        actualRange?.pointee = clampedRange(range, length: max(markedText.length, 1))
        let local = NSRect(
            x: origin.x,
            y: origin.y,
            width: terminalCellSize().width,
            height: terminalCellSize().height
        )
        return window?.convertToScreen(convert(local, to: nil)) ?? local
    }

    func compositionOrigin() -> NSPoint {
        let textRect = terminalTextRect()
        let cell = terminalCellSize()
        let cursor: (x: Int, y: Int)? =
            if let rendererCursor = rendererModelSnapshot?.cursor {
                (Int(rendererCursor.x), Int(rendererCursor.y))
            } else {
                terminalCursor
            }
        guard let cursor else {
            return NSPoint(x: textRect.minX, y: textRect.maxY - cell.height)
        }
        return NSPoint(
            x: min(
                textRect.minX + CGFloat(cursor.x) * cell.width,
                textRect.maxX - cell.width
            ),
            y: min(
                textRect.minY + CGFloat(cursor.y) * cell.height,
                textRect.maxY - cell.height
            )
        )
    }

    func invalidateInputCoordinates() {
        inputContext?.invalidateCharacterCoordinates()
    }

    func routeKeyEvent(_ event: NSEvent, released: Bool) -> Bool {
        let handled = onKeyEvent?(event, released) ?? false
        if handled, !released {
            terminalKeysDown.insert(event.keyCode)
        }
        return handled
    }

    func clampedRange(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    func terminalTextRect() -> NSRect {
        if let activePaneId, let frame = paneFrames[activePaneId] {
            return frame
        }
        return terminalContentRect()
    }

    func terminalContentRect() -> NSRect {
        NSRect(
            x: terminalHorizontalInset,
            y: 0,
            width: max(1, bounds.width - terminalHorizontalInset * 2),
            height: max(1, bounds.height - terminalTextBottomInset)
        )
    }

    func terminalCellSize() -> NSSize {
        terminalCellSize(for: activePaneId)
    }

    func terminalCellSize(for paneId: Int?) -> NSSize {
        let font = fontForPane(paneId)
        let measured = ("M" as NSString).size(withAttributes: [.font: font])
        let lineHeight = font.ascender - font.descender + font.leading
        return NSSize(width: max(1, measured.width), height: max(1, lineHeight))
    }

    func scrollRows(for event: NSEvent) -> CGFloat {
        if event.hasPreciseScrollingDeltas {
            return -event.scrollingDeltaY / terminalCellSize().height
        }
        return -event.scrollingDeltaY * 3.0
    }

    func mouseInput(
        button: String,
        action: String,
        event: NSEvent,
        point: NSPoint,
        clampToGrid: Bool = false
    ) -> NativeMouseInput? {
        guard let position = mouseGridPosition(point, clampToGrid: clampToGrid) else {
            return nil
        }
        let textRect = terminalTextRect()
        let cellSize = terminalCellSize()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return NativeMouseInput(
            button: button,
            action: action,
            modifier: mouseModifierString(for: event),
            grid: 0,
            row: Int64(position.row),
            col: Int64(position.col),
            surfaceX: Float((point.x - textRect.minX) * scale),
            surfaceY: Float((point.y - textRect.minY) * scale),
            cellWidth: UInt32(max(1, Int((cellSize.width * scale).rounded()))),
            cellHeight: UInt32(max(1, Int((cellSize.height * scale).rounded())))
        )
    }

    func handleMouseInput(_ input: NativeMouseInput) -> Bool {
        let handling = onMouseInput?(input) ?? .unhandled
        if handling == .messageSelection {
            messageSelectionActive = input.action != "release"
        } else if input.button == "left" && (input.action == "press" || input.action == "release") {
            messageSelectionActive = false
        }
        return handling != .unhandled
    }

    func sendWheelMouseInput(for event: NSEvent, at point: NSPoint) -> Bool {
        let rows = scrollRows(for: event)
        guard rows != 0 else {
            return false
        }
        let action = rows > 0 ? "down" : "up"
        guard let input = mouseInput(button: "wheel", action: action, event: event, point: point)
        else {
            return false
        }
        guard handleMouseInput(input) else {
            return false
        }
        let repeats = min(6, max(1, Int(abs(rows).rounded(.up))))
        if repeats > 1 {
            for _ in 1..<repeats {
                _ = handleMouseInput(input)
            }
        }
        return true
    }

    func mouseGridPosition(
        _ point: NSPoint,
        clampToGrid: Bool = false
    ) -> (row: Int, col: Int)? {
        let textRect = terminalTextRect()
        guard clampToGrid || textRect.contains(point) else {
            return nil
        }
        let cellSize = terminalCellSize()
        let grid = terminalGridSize()
        let col = Int((point.x - textRect.minX) / cellSize.width)
        let row = Int((point.y - textRect.minY) / cellSize.height)
        return (
            row: min(max(row, 0), grid.rows - 1),
            col: min(max(col, 0), grid.cols - 1)
        )
    }

    func mouseModifierString(for event: NSEvent) -> String {
        var modifier = ""
        if event.modifierFlags.contains(.shift) {
            modifier.append("S")
        }
        if event.modifierFlags.contains(.control) {
            modifier.append("C")
        }
        if event.modifierFlags.contains(.option) {
            modifier.append("A")
        }
        if event.modifierFlags.contains(.command) {
            modifier.append("D")
        }
        return modifier
    }

}
