import AppKit
import QuartzCore

/// The unread pages, held in a small fan at the lower right over the panes,
/// beside the hand of attention cards. A page arrives from the Pages button,
/// rises under the pointer, and opens in the reader when pressed.
final class NativePageHandView: NSView {
    /// How much of a page at rest shows above the window's edge.
    private static let restShowing: CGFloat = 96
    private static let peekLift: CGFloat = 52
    private static let maxShown = 6
    private static let margin: CGFloat = 28
    private static let step: CGFloat = 54

    var onOpen: ((NativeArtifactListItem) -> Void)?
    /// Where pages fly in from: the Pages button, in this view's coordinates.
    var arrivalPoint: (() -> NSPoint?)?

    private var cards: [NativePageCardView] = []
    private var hovered: NativePageCardView?
    private var trackingArea: NSTrackingArea?
    private(set) var sunk = false

    /// The room the fan takes at the right, margin included; none when empty.
    var fanWidth: CGFloat {
        cards.isEmpty
            ? 0
            : NativePageBinderView.cardSize.width + Self.step * CGFloat(cards.count - 1)
                + Self.margin * 2
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    /// Only the cards take the pointer; the panes keep the rest.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !sunk else {
            return nil
        }
        let local = superview.map { convert(point, from: $0) } ?? point
        return card(at: local)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(sunk ? nil : card(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    /// Shows the unread pages, newest on top. Pages not shown before fly in.
    func show(unread: [NativeArtifactListItem]) {
        let pages = Array(unread.prefix(Self.maxShown).reversed())
        let keys = pages.map { "\($0.id)@\($0.version)" }
        guard keys != cards.map({ "\($0.page.id)@\($0.page.version)" }) else {
            return
        }
        var previous = Dictionary(
            cards.map { ("\($0.page.id)@\($0.page.version)", $0) }, uniquingKeysWith: { a, _ in a })
        var arrived: [NativePageCardView] = []
        cards = zip(pages, keys).map { page, key in
            if let card = previous.removeValue(forKey: key) {
                return card
            }
            let card = NativePageCardView(page: page)
            card.onClick = { [weak self] in
                self?.onOpen?(page)
            }
            arrived.append(card)
            return card
        }
        for card in previous.values {
            card.removeFromSuperview()
        }
        for card in cards {
            addSubview(card, positioned: .above, relativeTo: nil)
        }
        if hovered.map({ !cards.contains($0) }) == true {
            hovered = nil
        }
        let from = arrivalPoint?()
        for card in arrived {
            guard let from, window != nil, !NativeHandEffects.reducesMotion else {
                continue
            }
            card.frame = NSRect(
                origin: NSPoint(x: from.x - card.frame.width / 2, y: from.y - card.frame.height),
                size: card.frame.size)
            card.alphaValue = 0
        }
        setAccessibilityLabel("Unread pages, \(unread.count)")
        place(animated: true)
    }

    /// Lowers the fan out of sight while a page or the binder is open.
    func setSunk(_ sunk: Bool) {
        guard sunk != self.sunk else {
            return
        }
        self.sunk = sunk
        if sunk {
            hovered = nil
        }
        place(animated: true)
    }

    func refreshLook() {
        for card in cards {
            card.needsDisplay = true
        }
    }

    private func setHovered(_ card: NativePageCardView?) {
        guard card !== hovered else {
            return
        }
        hovered = card
        place(animated: true)
    }

    private func card(at point: NSPoint) -> NativePageCardView? {
        if let hovered, hovered.frame.insetBy(dx: 0, dy: -Self.peekLift).contains(point) {
            return hovered
        }
        return cards.last { $0.frame.contains(point) }
    }

    private func place(animated: Bool) {
        let size = NativePageBinderView.cardSize
        let count = cards.count
        let step = Self.step
        let width = size.width + step * CGFloat(max(0, count - 1))
        let left = bounds.maxX - Self.margin - width
        let moves = cards.enumerated().map { index, card -> (NativePageCardView, NSRect, CGFloat) in
            let offset = CGFloat(index) - CGFloat(count - 1) / 2
            let lifted = card === hovered
            var y = Self.restShowing - size.height - offset * offset * 4
            if lifted {
                y += Self.peekLift
            }
            if sunk {
                y = -size.height - 30
            }
            let frame = NSRect(
                origin: NSPoint(x: left + CGFloat(index) * step, y: y), size: size)
            return (card, frame, lifted ? 0 : -offset * 4)
        }
        guard animated, window != nil, !NativeHandEffects.reducesMotion else {
            for (card, frame, rotation) in moves {
                card.frameCenterRotation = 0
                card.frame = frame
                card.frameCenterRotation = rotation
                card.alphaValue = 1
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (card, frame, rotation) in moves {
                card.frameCenterRotation = 0
                card.animator().frame = frame
                card.animator().frameCenterRotation = rotation
                card.animator().alphaValue = 1
            }
        }
    }
}

func runNativePageHandSelfTests() -> Bool {
    func page(_ id: String) -> NativeArtifactListItem {
        NativeArtifactListItem(
            id: id, title: id, kind: "markdown", version: 1, updatedAtMs: 0, preview: "")
    }
    let view = NativePageHandView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    var opened: String?
    view.onOpen = { opened = $0.id }
    view.show(unread: [page("new"), page("old")])
    let cards = view.subviews.compactMap { $0 as? NativePageCardView }
    // The newest page lies on top, at the right.
    guard cards.map(\.page.id) == ["old", "new"], let top = cards.last else {
        return false
    }
    guard view.hitTest(NSPoint(x: top.frame.midX, y: top.frame.maxY - 8)) === top,
        view.hitTest(NSPoint(x: 20, y: 300)) == nil
    else {
        return false
    }
    top.onClick?()
    view.setSunk(true)
    return opened == "new" && view.hitTest(NSPoint(x: top.frame.midX, y: 4)) == nil
}
