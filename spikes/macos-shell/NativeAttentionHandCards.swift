import AppKit
import QuartzCore

func nativeHandColor(_ kind: NativeHandCardKind) -> NSColor {
    switch kind {
    case .waiting: NativePageStyle.paper ? NativePageStyle.amber : .systemOrange
    case .failed: NativePageStyle.paper ? NativePageStyle.rose : .systemRed
    case .done: NativePageStyle.paper ? NativePageStyle.rgb(31, 122, 82) : .systemGreen
    }
}

/// One card. In the terminal look it draws on its own dark stock, the way a
/// playing card keeps its face on any table; on paper it is a slip of card
/// stock with its state stamped on it.
final class NativeHandCardView: NSView {
    static let size = NSSize(width: 150, height: 208)
    private static let cornerRadius: CGFloat = 9
    private static let stock = NSColor(srgbRed: 0.05, green: 0.07, blue: 0.14, alpha: 1)
    private static let panel = NSColor(srgbRed: 0.10, green: 0.13, blue: 0.25, alpha: 1)

    var onPress: ((NativeHandCard) -> Void)?
    private(set) var card: NativeHandCard
    private var art: [String]
    private var now = Date()
    private let glow = CALayer()
    private let foil = CAGradientLayer()

    init(card: NativeHandCard, art: [String]) {
        self.card = card
        self.art = art
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        glow.cornerRadius = Self.cornerRadius
        glow.borderWidth = 2
        glow.shadowOpacity = 0.9
        glow.shadowRadius = 8
        glow.shadowOffset = .zero
        glow.isHidden = true
        foil.cornerRadius = Self.cornerRadius
        foil.masksToBounds = true
        foil.startPoint = CGPoint(x: 0, y: 0)
        foil.endPoint = CGPoint(x: 1, y: 1)
        foil.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.20).cgColor,
            NSColor.systemTeal.withAlphaComponent(0.14).cgColor,
            NSColor.systemPink.withAlphaComponent(0.12).cgColor,
            NSColor.clear.cgColor,
        ]
        foil.opacity = 0
        layer?.addSublayer(foil)
        layer?.addSublayer(glow)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        applyState()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        glow.frame = bounds
        foil.frame = bounds
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(card)
        return true
    }

    func update(_ card: NativeHandCard, art: [String]) {
        guard card != self.card || art != self.art else {
            return
        }
        self.card = card
        self.art = art
        applyState()
    }

    func refresh(now: Date) {
        self.now = now
        applyState()
    }

    /// The card's face as an image, for the copy that flies out of the hand.
    func snapshot() -> NSImage? {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    var color: NSColor {
        nativeHandColor(card.kind)
    }

    /// Whether the user has this card chosen. It glows steadily.
    var isChosen = false {
        didSet {
            if isChosen != oldValue {
                applyState()
            }
        }
    }

    /// Whether this is the card ⌘J plays. It keeps a still foil.
    var isFirst = false {
        didSet {
            if isFirst != oldValue {
                setFoil(at: nil)
            }
        }
    }

    /// Shows the foil with its band under the pointer, or puts it back at rest.
    func setFoil(at pointer: CGFloat?) {
        let fraction = pointer ?? (isFirst ? 0.35 : nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let fraction {
            let center = min(0.85, max(0.15, fraction))
            foil.locations = [
                0, NSNumber(value: center - 0.12), NSNumber(value: center),
                NSNumber(value: center + 0.12), 1,
            ]
        }
        CATransaction.commit()
        foil.opacity = fraction == nil ? 0 : 1
    }

    private func applyState() {
        let color = nativeHandColor(card.kind)
        let hot = card.kind != .done && NativeHandWait.isHot(since: card.since, now: now)
        glow.borderColor = color.cgColor
        glow.shadowColor = color.cgColor
        glow.isHidden = !(hot || isChosen)
        NativeHandEffects.setPulse(
            glow, active: hot && !isChosen, minimumOpacity: 0.2, duration: 0.65)
        setAccessibilityLabel("\(card.title), \(card.kind.title.lowercased())")
        setAccessibilityHelp(card.summary.isEmpty ? nil : card.summary)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if NativePageStyle.paper {
            drawPaper()
            return
        }
        let color = nativeHandColor(card.kind)
        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        let tint = Self.panel.blended(withFraction: 0.38, of: color) ?? Self.panel
        NSGradient(colors: [tint, Self.panel, Self.stock])?.draw(in: outline, angle: 65)
        color.withAlphaComponent(0.85).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        let inner = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 6, yRadius: 6)
        color.withAlphaComponent(0.3).setStroke()
        inner.stroke()

        drawGem(color: color)
        let elapsed = nativeElapsedText(since: card.since, now: now)
        let elapsedText = text(
            elapsed, font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            color: color, alignment: .right)
        elapsedText.draw(in: NSRect(x: bounds.maxX - 52, y: 11, width: 43, height: 14))
        text(card.title, font: NativePageStyle.sans(13, .heavy), color: .white)
            .draw(in: NSRect(x: 33, y: 8, width: bounds.width - 33 - 54, height: 18))

        let artRect = NSRect(x: 9, y: 34, width: bounds.width - 18, height: 54)
        Self.stock.withAlphaComponent(0.9).setFill()
        artRect.fill()
        color.withAlphaComponent(0.35).setStroke()
        NSBezierPath(rect: artRect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let artFont = NativePageStyle.mono(8, .regular)
        for (index, line) in art.enumerated() {
            let last = index == art.count - 1
            text(line, font: artFont, color: last ? color : NSColor.white.withAlphaComponent(0.5))
                .draw(
                    in: NSRect(
                        x: artRect.minX + 5, y: artRect.minY + 4 + CGFloat(index) * 11.5,
                        width: artRect.width - 10, height: 11))
        }

        let kind = NSMutableAttributedString(
            attributedString: text(
                card.kind.title, font: NativePageStyle.sans(9, .bold), color: color))
        kind.addAttribute(.kern, value: 1.2, range: NSRange(location: 0, length: kind.length))
        kind.draw(in: NSRect(x: 10, y: 94, width: bounds.width - 20, height: 12))

        let summary = card.summary.isEmpty ? "Needs a look" : card.summary
        text(
            summary, font: NativePageStyle.sans(11),
            color: NSColor.white.withAlphaComponent(0.92), wraps: true
        ).draw(
            with: NSRect(x: 10, y: 109, width: bounds.width - 20, height: bounds.height - 109 - 20),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        let track = NSRect(x: 10, y: bounds.maxY - 14, width: bounds.width - 20, height: 4)
        NSColor.white.withAlphaComponent(0.12).setFill()
        track.fill()
        var fill = track
        fill.size.width *= CGFloat(NativeHandWait.fraction(since: card.since, now: now))
        color.setFill()
        fill.fill()
    }

    /// The paper face: the same places as the dark one, in ink, with the
    /// card's state as a rubber stamp where the dark face prints its kind.
    private func drawPaper() {
        let style = NativePageStyle.self
        let color = nativeHandColor(card.kind)
        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        style.surface.setFill()
        outline.fill()
        style.text.setStroke()
        outline.lineWidth = 2
        outline.stroke()

        let dot = NSBezierPath(ovalIn: NSRect(x: 11, y: 10, width: 13, height: 13))
        color.setFill()
        dot.fill()
        text(
            nativeElapsedText(since: card.since, now: now),
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            color: style.muted, alignment: .right
        ).draw(in: NSRect(x: bounds.maxX - 52, y: 11, width: 43, height: 14))
        text(card.title, font: NativePageStyle.sans(13, .heavy), color: style.text)
            .draw(in: NSRect(x: 31, y: 8, width: bounds.width - 31 - 54, height: 18))

        let artRect = NSRect(x: 9, y: 31, width: bounds.width - 18, height: 48)
        style.raised.setFill()
        artRect.fill()
        style.line.setStroke()
        NSBezierPath(rect: artRect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let artFont = NativePageStyle.mono(8, .regular)
        for (index, line) in art.enumerated() {
            let last = index == art.count - 1
            text(line, font: artFont, color: last ? style.text : style.muted)
                .draw(
                    in: NSRect(
                        x: artRect.minX + 5, y: artRect.minY + 2 + CGFloat(index) * 11.5,
                        width: artRect.width - 10, height: 11))
        }

        style.drawStamp(
            card.kind.title, center: NSPoint(x: 50, y: 91), color: color,
            angle: card.kind == .failed ? 7 : 5, size: 11)

        let summary = card.summary.isEmpty ? "Needs a look" : card.summary
        text(summary, font: NativePageStyle.sans(11), color: style.text, wraps: true)
            .draw(
                with: NSRect(
                    x: 10, y: 114, width: bounds.width - 20, height: bounds.height - 114 - 20),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        let track = NSRect(x: 10, y: bounds.maxY - 14, width: bounds.width - 20, height: 4)
        style.line.setFill()
        track.fill()
        var fill = track
        fill.size.width *= CGFloat(NativeHandWait.fraction(since: card.since, now: now))
        color.setFill()
        fill.fill()
    }

    private func drawGem(color: NSColor) {
        let center = NSPoint(x: 19, y: 17)
        let half: CGFloat = 10
        let gem = NSBezierPath()
        gem.move(to: NSPoint(x: center.x, y: center.y - half))
        gem.line(to: NSPoint(x: center.x + half, y: center.y))
        gem.line(to: NSPoint(x: center.x, y: center.y + half))
        gem.line(to: NSPoint(x: center.x - half, y: center.y))
        gem.close()
        color.setFill()
        gem.fill()
        text(
            card.kind.glyph, font: NativePageStyle.sans(11, .heavy), color: Self.stock,
            alignment: .center
        ).draw(in: NSRect(x: center.x - half, y: center.y - 7.5, width: half * 2, height: 14))
    }

    private func text(
        _ string: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        wraps: Bool = false
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        return NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

/// The place a card stands in the fan. The slot moves; the card turns in it.
final class NativeHandSlotView: NSView {
    let cardView: NativeHandCardView
    /// Where the fan last placed this card.
    var restOrigin = NSPoint.zero
    var restRotation: CGFloat = 0

    init(cardView: NativeHandCardView) {
        self.cardView = cardView
        super.init(frame: NSRect(origin: .zero, size: NativeHandCardView.size))
        wantsLayer = true
        applyLook()
        addSubview(cardView)
    }

    /// Each card throws a shadow on the one under it, which is what makes the
    /// fan read as a stack and not a row. On paper it is a hard ink print.
    func applyLook() {
        let depth = NSShadow()
        if NativePageStyle.paper {
            depth.shadowColor = NativePageStyle.rgb(43, 34, 51)
            depth.shadowBlurRadius = 0
            depth.shadowOffset = NSSize(width: 4, height: -5)
        } else {
            depth.shadowColor = NSColor.black.withAlphaComponent(0.7)
            depth.shadowBlurRadius = 12
            depth.shadowOffset = NSSize(width: -5, height: -3)
        }
        shadow = depth
        cardView.needsDisplay = true
    }

    required init?(coder: NSCoder) {
        nil
    }
}

/// A played card on its way to its pane. It grows from the card's place in the
/// hand until it covers the panes, so the switch to another tab happens under
/// it, then settles onto the pane it was played for and fades.
final class NativeHandFlyerView: NSView {
    private let face = NSImageView(frame: .zero)
    private let fill = NSView(frame: .zero)

    init(frame: NSRect, color: NSColor, face image: NSImage?) {
        super.init(frame: frame)
        wantsLayer = true
        let stock = NSColor(srgbRed: 0.05, green: 0.07, blue: 0.14, alpha: 1)
        fill.frame = bounds
        fill.autoresizingMask = [.width, .height]
        fill.wantsLayer = true
        fill.layer?.backgroundColor =
            (stock.blended(withFraction: 0.1, of: color) ?? stock).cgColor
        fill.layer?.cornerRadius = 10
        addSubview(fill)
        layer?.borderColor = color.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 10
        face.image = image
        face.imageScaling = .scaleNone
        face.frame = NSRect(
            x: (frame.width - NativeHandCardView.size.width) / 2,
            y: (frame.height - NativeHandCardView.size.height) / 2,
            width: NativeHandCardView.size.width,
            height: NativeHandCardView.size.height)
        face.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(face)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func fadeFace() {
        face.animator().alphaValue = 0
    }

    /// Leaves only the outline, which stays on the pane a moment longer.
    func fadeFill() {
        fill.animator().alphaValue = 0
    }
}
