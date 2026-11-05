import AppKit
import QuartzCore

/// The sidebars' colors and type: the attention hand's card stock in the
/// terminal look, paper's ink and stamps on paper.
enum NativeSidebarLook {
    static let stock = NSColor(srgbRed: 0.05, green: 0.07, blue: 0.14, alpha: 1)
    static let cardPanel = NSColor(srgbRed: 0.10, green: 0.13, blue: 0.25, alpha: 1)

    static func color(_ state: NativeWindowState) -> NSColor {
        if let kind = state.handKind {
            return nativeHandColor(kind)
        }
        return state == .running ? NativePageStyle.teal : NativePageStyle.muted
    }

    static func color(_ kind: NativeSidebarItemKind) -> NSColor {
        switch kind {
        case .command, .quote: NativePageStyle.violet
        case .link: NativePageStyle.teal
        case .file: nativeHandColor(.done)
        }
    }

    /// What the title of a card is written in.
    static var cardText: NSColor {
        NativePageStyle.paper ? NativePageStyle.text : .white
    }

    /// A tab's shortcut, drawn at its corner while ⌘ is held.
    static func drawShortcut(_ digit: Int, center: NSPoint) {
        let paper = NativePageStyle.paper
        let pill = NSRect(x: center.x - 13, y: center.y - 9, width: 26, height: 18)
        (paper ? NativePageStyle.text : NSColor.white).setFill()
        NSBezierPath(roundedRect: pill, xRadius: paper ? 3 : 6, yRadius: paper ? 3 : 6).fill()
        text(
            "⌘\(digit)", font: NativePageStyle.mono(11, .bold),
            color: paper ? NativePageStyle.surface : .black, alignment: .center
        ).draw(in: pill.insetBy(dx: 0, dy: 2))
    }

    static func text(
        _ string: String,
        font: NSFont,
        color: NSColor,
        kern: CGFloat = 0,
        alignment: NSTextAlignment = .left,
        breaking: NSLineBreakMode = .byTruncatingTail
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = breaking
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        if kern != 0 {
            attributes[.kern] = kern
        }
        return NSAttributedString(string: string, attributes: attributes)
    }

    /// A section's name: small, heavy and spaced, like a card's kind.
    static func heading(_ string: String, color: NSColor) -> NSAttributedString {
        text(string, font: NativePageStyle.sans(10, .heavy), color: color, kern: 1.6)
    }

    /// The gem a card wears in the terminal look; a dot on paper.
    static func drawGem(_ state: NativeWindowState, center: NSPoint, half: CGFloat) {
        let color = color(state)
        if NativePageStyle.paper {
            let dot = NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - half * 0.7, y: center.y - half * 0.7,
                    width: half * 1.4, height: half * 1.4))
            color.setFill()
            dot.fill()
            return
        }
        let gem = NSBezierPath()
        gem.move(to: NSPoint(x: center.x, y: center.y - half))
        gem.line(to: NSPoint(x: center.x + half, y: center.y))
        gem.line(to: NSPoint(x: center.x, y: center.y + half))
        gem.line(to: NSPoint(x: center.x - half, y: center.y))
        gem.close()
        color.setFill()
        gem.fill()
        let glyph = text(
            state.glyph, font: NativePageStyle.sans(half * 1.05, .heavy), color: stock,
            alignment: .center)
        let height = glyph.size().height
        glyph.draw(
            in: NSRect(
                x: center.x - half, y: center.y - height / 2, width: half * 2, height: height))
    }

    /// The panel a sidebar lies on, with a rule on the side facing the panes.
    static func drawPanel(_ bounds: NSRect, ruleAtMaxX: Bool) {
        NativePageStyle.surface.setFill()
        bounds.fill()
        NativePageStyle.line.setFill()
        NSRect(
            x: ruleAtMaxX ? bounds.maxX - 1 : bounds.minX, y: bounds.minY, width: 1,
            height: bounds.height
        ).fill()
    }
}

/// A sidebar's scrolling column: rows are laid out from the top.
final class NativeSidebarDocumentView: NSView {
    /// Draws what lies between the rows, such as section headings.
    var drawing: (() -> Void)?

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawing?()
    }
}

/// A scroll view for a sidebar's column: no chrome, nothing drawn behind.
func nativeSidebarScrollView(document: NSView) -> NSScrollView {
    let scroll = NSScrollView(frame: .zero)
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.borderType = .noBorder
    scroll.automaticallyAdjustsContentInsets = false
    scroll.documentView = document
    return scroll
}

/// A comet running along a card's foot while its tab works, as the tab
/// strip's signal does. With reduced motion it stands still.
final class NativeSidebarComet {
    private static let key = "satin.sidebar.comet"
    let track = CALayer()
    private let comet = CAGradientLayer()

    init() {
        track.masksToBounds = true
        comet.startPoint = CGPoint(x: 0, y: 0.5)
        comet.endPoint = CGPoint(x: 1, y: 0.5)
        track.addSublayer(comet)
    }

    func layout(_ frame: NSRect, running: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = frame
        track.isHidden = !running
        let color = NativePageStyle.teal
        comet.colors = [
            color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.55).cgColor,
        ]
        let width = frame.width * 0.35
        comet.bounds = CGRect(x: 0, y: 0, width: width, height: frame.height)
        comet.position = CGPoint(x: frame.width * 0.62, y: frame.height / 2)
        CATransaction.commit()
        guard running, !NativeHandEffects.reducesMotion else {
            comet.removeAnimation(forKey: Self.key)
            return
        }
        guard comet.animation(forKey: Self.key) == nil else {
            return
        }
        // A slow drift with a rest after each pass, so a column of running
        // cards reads as calm.
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -width / 2
        sweep.toValue = frame.width + width / 2
        sweep.duration = 4.2
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let pass = CAAnimationGroup()
        pass.animations = [sweep]
        pass.duration = 6
        pass.repeatCount = .infinity
        pass.preferredFrameRateRange = NativeHandEffects.ambientFrameRate
        comet.add(pass, forKey: Self.key)
    }
}
