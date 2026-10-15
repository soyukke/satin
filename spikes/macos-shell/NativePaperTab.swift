import AppKit

/// Paper's tabs are folder tabs standing on an ink line: the chosen one cream
/// with an ink outline, open at the foot so it joins the page below; the
/// others a shade darker and fainter.
enum NativePaperTab {
    /// The tab's footprint in its segment. Its foot stands a little above the
    /// segment's, which the tab strip's scroller clips.
    static func rect(_ segmentRect: NSRect, flipped: Bool) -> NSRect {
        let inset = segmentRect.insetBy(dx: 2, dy: 0)
        return NSRect(
            x: inset.minX, y: flipped ? inset.minY + 1 : inset.minY + 4,
            width: inset.width, height: inset.height - 5)
    }

    static func draw(in rect: NSRect, selected: Bool, flipped: Bool) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }
        let outline = self.outline(rect, flipped: flipped)
        let fill = outline.copy() as? NSBezierPath ?? outline
        fill.close()
        (selected ? NativePageStyle.surface : NativePageStyle.rgb(230, 219, 195)).setFill()
        fill.fill()
        (selected ? NativePageStyle.text : NativePageStyle.rgb(184, 171, 146)).setStroke()
        outline.lineWidth = selected ? 2 : 1
        outline.stroke()
    }

    /// The tab's sides and top, rounded at the top corners; the foot is open.
    static func outline(_ rect: NSRect, flipped: Bool) -> NSBezierPath {
        let radius = min(7, rect.width / 2)
        let foot = flipped ? rect.maxY : rect.minY
        let top = flipped ? rect.minY : rect.maxY
        let inward: CGFloat = flipped ? radius : -radius
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: foot))
        path.line(to: NSPoint(x: rect.minX, y: top + inward))
        path.appendArc(
            from: NSPoint(x: rect.minX, y: top), to: NSPoint(x: rect.minX + radius, y: top),
            radius: radius)
        path.line(to: NSPoint(x: rect.maxX - radius, y: top))
        path.appendArc(
            from: NSPoint(x: rect.maxX, y: top), to: NSPoint(x: rect.maxX, y: top + inward),
            radius: radius)
        path.line(to: NSPoint(x: rect.maxX, y: foot))
        return path
    }

    /// The length round the tab with its foot closed, so a dash pattern
    /// meets itself at the corner it started from.
    static func perimeter(_ rect: NSRect) -> CGFloat {
        let radius = min(7, rect.width / 2)
        return 2 * (rect.width + rect.height) - (4 - .pi) * radius
    }
}

/// The terminal look's square frame round a tab, shared by the chosen tab's
/// frame and the fuse that runs round a waiting one. Its foot stays clear of
/// the segment's, which the tab strip's scroller clips. The tab strip is
/// flipped, so the foot is at the larger y.
func nativeTerminalTabFrame(_ segmentRect: NSRect) -> NSRect {
    NSRect(
        x: segmentRect.minX + 3, y: segmentRect.minY + 2.5,
        width: segmentRect.width - 6, height: segmentRect.height - 7)
}
