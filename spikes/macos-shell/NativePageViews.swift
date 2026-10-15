import AppKit

/// The colors pages are drawn in: a datasheet on the backdrop's own violet
/// and teal.
enum NativePageStyle {
    /// Whether pages are printed on paper rather than lit as datasheets.
    static var paper = false

    static var surface: NSColor {
        paper ? rgb(251, 245, 231) : NSColor(srgbRed: 0.055, green: 0.047, blue: 0.094, alpha: 1)
    }
    static var raised: NSColor {
        paper ? rgb(241, 232, 212) : NSColor(srgbRed: 0.082, green: 0.071, blue: 0.165, alpha: 1)
    }
    static var text: NSColor {
        paper ? rgb(43, 34, 51) : NSColor(srgbRed: 0.925, green: 0.910, blue: 0.969, alpha: 1)
    }
    static var muted: NSColor {
        paper ? rgb(110, 98, 79) : NSColor(srgbRed: 0.608, green: 0.580, blue: 0.702, alpha: 1)
    }
    static var teal: NSColor {
        paper ? rgb(31, 138, 138) : NSColor(srgbRed: 0.310, green: 0.820, blue: 0.773, alpha: 1)
    }
    static var violet: NSColor {
        paper ? rgb(91, 63, 184) : NSColor(srgbRed: 0.663, green: 0.545, blue: 1, alpha: 1)
    }
    static var amber: NSColor {
        paper ? rgb(184, 95, 14) : NSColor(srgbRed: 0.949, green: 0.639, blue: 0.227, alpha: 1)
    }
    static var rose: NSColor {
        paper ? rgb(194, 54, 79) : NSColor(srgbRed: 0.937, green: 0.353, blue: 0.435, alpha: 1)
    }
    /// What is printed over a colored strip.
    static var ink: NSColor {
        paper ? rgb(251, 245, 231) : NSColor(srgbRed: 0.027, green: 0.024, blue: 0.051, alpha: 1)
    }
    static var line: NSColor {
        paper
            ? rgb(43, 34, 51).withAlphaComponent(0.35)
            : NSColor(srgbRed: 0.663, green: 0.545, blue: 1, alpha: 0.28)
    }
    /// The dim over the work around a page.
    static var dim: NSColor {
        paper ? rgb(43, 34, 51).withAlphaComponent(0.32) : NSColor.black.withAlphaComponent(0.58)
    }

    static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255,
            alpha: 1)
    }

    /// Paper's frame: a solid ink outline over a teal print offset below
    /// and right of it, and two strips of violet tape at the top.
    static func drawPaperFrame(_ rect: NSRect, offset: CGFloat = 9, tape: Bool = true) {
        teal.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: rect.offsetBy(dx: offset, dy: offset), xRadius: 4, yRadius: 4)
            .fill()
        let sheet = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        surface.setFill()
        sheet.fill()
        text.setStroke()
        sheet.lineWidth = 2
        sheet.stroke()
        guard tape else { return }
        violet.withAlphaComponent(0.45).setFill()
        for (x, angle) in [(rect.minX + 110, -4.0), (rect.maxX - 180, 3.0)] {
            let piece = NSBezierPath(rect: NSRect(x: -35, y: -11, width: 70, height: 22))
            var transform = AffineTransform(translationByX: x + 35, byY: rect.minY)
            transform.rotate(byDegrees: angle)
            piece.transform(using: transform)
            piece.fill()
        }
    }

    /// A rubber stamp: a word in a rough box, tilted.
    static func drawStamp(
        _ word: String, center: NSPoint, color: NSColor, angle: CGFloat = -8, size: CGFloat = 12
    ) {
        let font = NativePageStyle.sans(size, .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .kern: size * 0.14,
        ]
        let textSize = (word as NSString).size(withAttributes: attributes)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle * .pi / 180)
        let box = NSRect(
            x: -textSize.width / 2 - 8, y: -textSize.height / 2 - 3, width: textSize.width + 16,
            height: textSize.height + 6)
        color.setStroke()
        let border = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        border.lineWidth = 2.5
        border.stroke()
        (word as NSString).draw(
            at: NSPoint(x: -textSize.width / 2, y: -textSize.height / 2), withAttributes: attributes
        )
        context.restoreGState()
    }

    static let strip: CGFloat = 30
    static let footer: CGFloat = 28

    /// Fonts are made once and kept. Pages redraw often, and a font let go
    /// as soon as it was drawn can be freed by CoreText's shaping thread
    /// while the next draw is still applying it.
    private static var fonts = [String: NSFont]()

    private static func cached(_ key: String, _ make: () -> NSFont) -> NSFont {
        if let font = fonts[key] {
            return font
        }
        let font = make()
        fonts[key] = font
        return font
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        cached("mono \(size) \(weight.rawValue)") {
            .monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        cached("sans \(size) \(weight.rawValue)") { .systemFont(ofSize: size, weight: weight) }
    }

    /// The heavy serif paper sets titles in.
    static func serif(_ size: CGFloat) -> NSFont {
        cached("serif \(size)") {
            NativePageStyle.sans(size, .heavy).fontDescriptor.withDesign(.serif)
                .flatMap { NSFont(descriptor: $0, size: size) }
                ?? NativePageStyle.sans(size, .heavy)
        }
    }

    /// A page's edge color, by its kind.
    static func edge(for kind: String) -> NSColor {
        switch kind {
        case "markdown", "text": teal
        case "image", "chart": violet
        case "diff", "code": amber
        default: rose
        }
    }

    /// A short, stable id to print on a page: its last hex digits.
    static func shortId(_ id: String) -> String {
        let tail = id.split(separator: "-").last.map(String.init) ?? id
        return String(tail.suffix(6)).uppercased()
    }

    static func age(_ milliseconds: UInt64, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince1970 - Double(milliseconds) / 1000)
        switch seconds {
        case ..<60: return "\(Int(seconds))s"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }

    static func draw(_ string: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (string as NSString).draw(
            at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    static func draw(_ string: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(
            with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    /// The panel's outline: a rectangle with its top right corner cut.
    static func panelPath(_ rect: NSRect, cut: CGFloat = 22) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - cut, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + cut))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }
}

/// Where the reader sits in the terminal's content: a panel in the middle,
/// and the page's own pane inside it under the strip.
func nativePageReaderFrames(in content: NSRect) -> (panel: NSRect, pane: NSRect) {
    let width = min(content.width - 48, max(560, (content.width * 0.8).rounded()))
    let height = max(240, content.height - 56)
    let panel = NSRect(
        x: (content.midX - width / 2).rounded(), y: (content.midY - height / 2).rounded(),
        width: width, height: height)
    let pane = NSRect(
        x: panel.minX + 16, y: panel.minY + NativePageStyle.strip + 10,
        width: panel.width - 32,
        height: panel.height - NativePageStyle.strip - NativePageStyle.footer - 14)
    return (panel, pane)
}

/// Dims the work around the reader and frames the page as a datasheet: a
/// strip with its title and version above, the keys below. Clicks inside
/// the page reach the page; clicks outside close it.
final class NativePageReaderChrome: NSView {
    var panel = NSRect.zero { didSet { needsDisplay = true } }
    var pane = NSRect.zero { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true } }
    var version: UInt32 = 1 { didSet { needsDisplay = true } }
    var latest: UInt32 = 1 { didSet { needsDisplay = true } }
    var pageId = "" { didSet { needsDisplay = true } }
    var onClose: (() -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return pane.contains(local) ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !panel.contains(point) {
            onClose?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if NativePageStyle.paper {
            drawPaper()
            return
        }
        let dim = NSBezierPath(rect: bounds)
        dim.append(NativePageStyle.panelPath(panel))
        dim.windingRule = .evenOdd
        NativePageStyle.dim.setFill()
        dim.fill()

        // The page itself is drawn under this view, so the frame paints
        // everything of the panel but the pane.
        let outline = NativePageStyle.panelPath(panel)
        let frame = NativePageStyle.panelPath(panel)
        // The pane's header strip is left for the pane chrome to draw on,
        // so only the content the page paints itself is left open.
        frame.append(NSBezierPath(rect: nativePaneContentFrame(pane)))
        frame.windingRule = .evenOdd
        NativePageStyle.surface.setFill()
        frame.fill()

        let strip = NSRect(
            x: panel.minX, y: panel.minY, width: panel.width, height: NativePageStyle.strip)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NativePageStyle.teal.setFill()
        strip.fill()
        NSGraphicsContext.restoreGraphicsState()
        let head =
            "PAGE  //  \(NativePageStyle.shortId(pageId))  //  v\(version)"
            + (latest > 1 ? " OF \(latest)" : "")
        NativePageStyle.draw(
            head, at: NSPoint(x: strip.minX + 14, y: strip.minY + 8),
            font: NativePageStyle.mono(11, .bold), color: NativePageStyle.ink)
        let titleFont = NativePageStyle.sans(13, .semibold)
        let headWidth = (head as NSString).size(withAttributes: [
            .font: NativePageStyle.mono(11, .bold)
        ]).width
        NativePageStyle.draw(
            title,
            in: NSRect(
                x: strip.minX + 32 + headWidth, y: strip.minY + 6,
                width: max(0, strip.width - headWidth - 80), height: 18),
            font: titleFont, color: NativePageStyle.ink)

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NativePageStyle.teal.withAlphaComponent(0.6)
        glow.shadowBlurRadius = 18
        glow.set()
        NativePageStyle.teal.withAlphaComponent(0.85).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let footerTop = panel.maxY - NativePageStyle.footer
        NativePageStyle.line.setFill()
        NSRect(x: panel.minX, y: footerTop, width: panel.width, height: 1).fill()
        var keys = ["ESC  CLOSE"]
        if latest > 1 {
            keys.insert("← →  VERSION", at: 0)
        }
        NativePageStyle.draw(
            keys.joined(separator: "     "),
            at: NSPoint(x: panel.minX + 14, y: footerTop + 8),
            font: NativePageStyle.mono(10.5), color: NativePageStyle.muted)
    }

    /// Paper: a printed sheet taped over the work, its title set like a
    /// booklet's, on a teal print a little off register.
    private func drawPaper() {
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: panel))
        dim.windingRule = .evenOdd
        NativePageStyle.dim.setFill()
        dim.fill()
        let print = NSBezierPath(
            roundedRect: panel.offsetBy(dx: 9, dy: 9), xRadius: 4, yRadius: 4)
        print.append(NSBezierPath(rect: panel))
        print.windingRule = .evenOdd
        NativePageStyle.teal.withAlphaComponent(0.8).setFill()
        print.fill()
        let sheet = NSBezierPath(rect: panel)
        sheet.append(NSBezierPath(rect: nativePaneContentFrame(pane)))
        sheet.windingRule = .evenOdd
        NativePageStyle.raised.setFill()
        sheet.fill()
        let edge = NSBezierPath(roundedRect: panel, xRadius: 4, yRadius: 4)
        NativePageStyle.text.setStroke()
        edge.lineWidth = 2
        edge.stroke()
        NativePageStyle.violet.withAlphaComponent(0.45).setFill()
        for (x, angle) in [(panel.minX + 110, -4.0), (panel.maxX - 180, 3.0)] {
            let piece = NSBezierPath(rect: NSRect(x: -35, y: -11, width: 70, height: 22))
            var transform = AffineTransform(translationByX: x + 35, byY: panel.minY)
            transform.rotate(byDegrees: angle)
            piece.transform(using: transform)
            piece.fill()
        }

        let meta =
            "PAGE NO. \(NativePageStyle.shortId(pageId))  ·  v\(version)"
            + (latest > 1 ? " OF \(latest)" : "")
        let metaFont = NativePageStyle.mono(10.5, .bold)
        let metaWidth = (meta as NSString).size(withAttributes: [.font: metaFont]).width
        NativePageStyle.draw(
            meta, at: NSPoint(x: panel.maxX - 18 - metaWidth, y: panel.minY + 10),
            font: metaFont, color: NativePageStyle.violet)
        let serif =
            NativePageStyle.serif(17)
        let titleRect = NSRect(
            x: panel.minX + 18, y: panel.minY + 6, width: panel.width - metaWidth - 60, height: 22)
        NativePageStyle.draw(
            title, in: titleRect.offsetBy(dx: 2, dy: 1), font: serif,
            color: NativePageStyle.teal.withAlphaComponent(0.5))
        NativePageStyle.draw(title, in: titleRect, font: serif, color: NativePageStyle.text)
        NativePageStyle.text.setFill()
        NSRect(
            x: panel.minX + 1, y: panel.minY + NativePageStyle.strip, width: panel.width - 2,
            height: 2
        )
        .fill()

        let footerTop = panel.maxY - NativePageStyle.footer
        NativePageStyle.text.setFill()
        NSRect(x: panel.minX + 1, y: footerTop, width: panel.width - 2, height: 2).fill()
        var keys = ["Esc  close"]
        if latest > 1 {
            keys.insert("← →  versions", at: 0)
        }
        NativePageStyle.draw(
            keys.joined(separator: "     "),
            at: NSPoint(x: panel.minX + 18, y: footerTop + 8),
            font: NativePageStyle.sans(11, .medium), color: NativePageStyle.muted)
    }
}
