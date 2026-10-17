import AppKit

/// One unread page in the binder's inbox, drawn as a datasheet card.
final class NativePageCardView: NSView {
    let page: NativeArtifactListItem
    var onClick: (() -> Void)?

    init(page: NativeArtifactListItem) {
        self.page = page
        super.init(
            frame: NSRect(
                x: 0, y: 0, width: NativePageBinderView.cardSize.width,
                height: NativePageBinderView.cardSize.height))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.6
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -10)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Read \(page.title), version \(page.version)")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        if NativePageStyle.paper {
            drawPaper()
            return
        }
        let edge = NativePageStyle.edge(for: page.kind)
        let card = NativePageStyle.panelPath(bounds.insetBy(dx: 0.5, dy: 0.5), cut: 18)
        NativePageStyle.surface.setFill()
        card.fill()
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        edge.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 24).fill()
        NSGraphicsContext.restoreGraphicsState()
        edge.setStroke()
        card.lineWidth = 1
        card.stroke()
        NativePageStyle.draw(
            NativePageStyle.shortId(page.id), at: NSPoint(x: 10, y: 6),
            font: NativePageStyle.mono(10, .bold), color: NativePageStyle.ink)
        NativePageStyle.draw(
            "v\(page.version)", at: NSPoint(x: bounds.width - 46, y: 6),
            font: NativePageStyle.mono(10, .bold), color: NativePageStyle.ink)
        NativePageStyle.draw(
            page.title, in: NSRect(x: 12, y: 34, width: bounds.width - 24, height: 48),
            font: NativePageStyle.sans(16, .semibold), color: NativePageStyle.text)
        NativePageStyle.draw(
            "\(page.kind.uppercased()) · \(NativePageStyle.age(page.updatedAtMs)) AGO",
            at: NSPoint(x: 12, y: 88),
            font: NativePageStyle.mono(10), color: NativePageStyle.muted)
        NativePageStyle.draw(
            page.preview, in: NSRect(x: 12, y: 108, width: bounds.width - 24, height: 34),
            font: NativePageStyle.sans(11), color: NativePageStyle.muted)
        edge.setFill()
        var x: CGFloat = 12
        for width in [3, 1, 2, 4, 1, 2, 1, 3] as [CGFloat] {
            NSRect(x: x, y: bounds.height - 22, width: width, height: 12).fill()
            x += width + 2
        }
    }
}

extension NativePageCardView {
    /// Paper: a printed slip on a teal print, with a halftone patch and a
    /// red NEW stamp.
    fileprivate func drawPaper() {
        let sheet = NSRect(x: 0, y: 0, width: bounds.width - 6, height: bounds.height - 6)
        NativePageStyle.teal.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: sheet.offsetBy(dx: 5, dy: 5), xRadius: 3, yRadius: 3).fill()
        let slip = NSBezierPath(roundedRect: sheet.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        NativePageStyle.surface.setFill()
        slip.fill()
        NativePageStyle.text.setStroke()
        slip.lineWidth = 2
        slip.stroke()
        NativePageStyle.draw(
            "NO. \(NativePageStyle.shortId(page.id))", at: NSPoint(x: 12, y: 10),
            font: NativePageStyle.mono(10, .bold), color: NativePageStyle.violet)
        NativePageStyle.draw(
            "v\(page.version)", at: NSPoint(x: sheet.width - 34, y: 10),
            font: NativePageStyle.mono(10, .bold), color: NativePageStyle.violet)
        let serif =
            NativePageStyle.serif(17)
        let titleRect = NSRect(x: 12, y: 28, width: sheet.width - 24, height: 44)
        NativePageStyle.draw(
            page.title, in: titleRect.offsetBy(dx: 2, dy: 1), font: serif,
            color: NativePageStyle.teal.withAlphaComponent(0.5))
        NativePageStyle.draw(page.title, in: titleRect, font: serif, color: NativePageStyle.text)
        NativePageStyle.draw(
            "\(page.kind) · \(NativePageStyle.age(page.updatedAtMs)) ago",
            at: NSPoint(x: 12, y: 80), font: NativePageStyle.sans(11), color: NativePageStyle.muted)
        NativePageStyle.violet.withAlphaComponent(0.45).setFill()
        var y: CGFloat = 104
        while y < sheet.height - 18 {
            var x: CGFloat = 12
            while x < sheet.width - 80 {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2.6, height: 2.6)).fill()
                x += 6
            }
            y += 6
        }
        NativePageStyle.drawStamp(
            "NEW", center: NSPoint(x: sheet.width - 40, y: sheet.height - 30),
            color: NativePageStyle.rose, angle: -10, size: 11)
    }
}

/// The binder: every page agents saved. Unread ones wait in a stack at the
/// top and are dealt out with a click; the rest are a table under it.
final class NativePageBinderView: NSView {
    static let cardSize = NSSize(width: 214, height: 160)
    static let rowHeight: CGFloat = 40
    static let inboxHeight: CGFloat = 214

    var panel = NSRect.zero { didSet { layoutContent() } }
    var onOpen: ((NativeArtifactListItem) -> Void)?
    var onClose: (() -> Void)?

    private var pages: [NativeArtifactListItem] = []
    private var unreadIds = Set<String>()
    private var cards: [NativePageCardView] = []
    private(set) var dealt = false
    /// The row the pointer or the arrow keys rest on; Return opens it.
    private(set) var focusedRow: Int?
    private var cursorRect: NSRect?
    private let cursorMotion = NativeTween()
    private var hoveredCard: NativePageCardView?
    private var stackHovered = false
    /// Seconds into the rows' entrance, nil once they have all landed.
    private var revealTime: CGFloat?
    private let revealMotion = NativeTween()
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    func show(pages: [NativeArtifactListItem], unread: [NativeArtifactListItem]) {
        self.pages = pages
        unreadIds = Set(unread.map(\.id))
        for card in cards {
            card.removeFromSuperview()
        }
        cards = unread.prefix(6).map { page in
            let card = NativePageCardView(page: page)
            card.onClick = { [weak self] in
                self?.cardClicked(page)
            }
            addSubview(card)
            return card
        }
        if cards.isEmpty {
            dealt = false
        }
        hoveredCard = nil
        stackHovered = false
        layoutContent()
        needsDisplay = true
    }

    /// Spreads the stack into a row, or gathers it back, a card at a time.
    func toggleDeal() {
        guard !cards.isEmpty else {
            return
        }
        dealt.toggle()
        hoveredCard = nil
        stackHovered = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, card) in cards.enumerated() {
            let order = dealt ? index : cards.count - 1 - index
            let delay = reduceMotion ? 0 : Double(order) * 0.07
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak card] in
                guard let self, let card else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduceMotion ? 0 : 0.42
                    context.timingFunction = CAMediaTimingFunction(
                        controlPoints: 0.2, 0.9, 0.25, 1.1)
                    context.allowsImplicitAnimation = true
                    self.place(card, index: index)
                }
            }
        }
        needsDisplay = true
    }

    private func cardClicked(_ page: NativeArtifactListItem) {
        if dealt {
            onOpen?(page)
        } else {
            toggleDeal()
        }
    }

    private var inboxRect: NSRect {
        NSRect(
            x: panel.minX + 20, y: panel.minY + NativePageStyle.strip + 16,
            width: panel.width - 40, height: Self.inboxHeight)
    }

    private func place(_ card: NativePageCardView, index: Int) {
        let inbox = inboxRect
        let size = Self.cardSize
        let origin: NSPoint
        let angle: CGFloat
        if dealt {
            let room = inbox.width - 32 - size.width
            let step = min(size.width + 16, room / CGFloat(max(1, cards.count - 1)))
            let lift: CGFloat = card === hoveredCard ? 14 : 0
            origin = NSPoint(
                x: inbox.minX + 16 + CGFloat(index) * step, y: inbox.minY + 36 - lift)
            angle = card === hoveredCard ? 1.5 : 0
        } else {
            // Under the pointer the stack fans a little, asking to be dealt.
            let spread: CGFloat = stackHovered ? 18 : 7
            origin = NSPoint(
                x: inbox.minX + 24 + CGFloat(index) * spread,
                y: inbox.minY + 48 - CGFloat(index) * 4 - (stackHovered ? 6 : 0))
            angle = CGFloat(index - 1) * (stackHovered ? -5 : -2.5)
        }
        // A rotated view's frame is its rotated bounds: place it upright.
        card.frameCenterRotation = 0
        card.frame = NSRect(origin: origin, size: size)
        card.frameCenterRotation = angle
    }

    private func layoutContent() {
        restack()
        for (index, card) in cards.enumerated() {
            place(card, index: index)
        }
        if let row = focusedRow {
            if row < visibleRowCount {
                cursorMotion.stop()
                cursorRect = rowRect(row)
            } else {
                focusedRow = nil
                cursorRect = nil
            }
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// The top card of the stack is the newest, drawn last.
    private func restack() {
        for card in cards.reversed() {
            addSubview(card, positioned: .above, relativeTo: nil)
        }
    }

    private var readPages: [NativeArtifactListItem] {
        pages.filter { !unreadIds.contains($0.id) }
    }

    private func rowRect(_ index: Int) -> NSRect {
        let top = inboxRect.maxY + 18 + 30
        return NSRect(
            x: panel.minX + 20, y: top + CGFloat(index) * Self.rowHeight,
            width: panel.width - 40, height: Self.rowHeight)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard panel.contains(point) else {
            onClose?()
            return
        }
        if inboxRect.contains(point), !cards.isEmpty, dealt {
            return
        }
        if let row = row(at: point) {
            onOpen?(readPages[row])
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose?()
        case 49: toggleDeal()
        case 125, 126:
            let count = visibleRowCount
            guard count > 0 else { return }
            let step = event.keyCode == 125 ? 1 : -1
            focus(row: focusedRow.map { min(max($0 + step, 0), count - 1) } ?? 0)
        case 36, 76:
            if let row = focusedRow, row < readPages.count {
                onOpen?(readPages[row])
            }
        default: super.keyDown(with: event)
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        pointerMoved(to: nil)
    }

    override func resetCursorRects() {
        for index in 0..<visibleRowCount {
            addCursorRect(rowRect(index), cursor: .pointingHand)
        }
    }

    /// The pointer lifts the card under it, fans the stack, or moves the
    /// row highlight; the highlight stays where it was left.
    func pointerMoved(to point: NSPoint?) {
        let card = point.flatMap { point in cards.first { $0.frame.contains(point) } }
        if dealt {
            setHoveredCard(card)
        } else {
            setStackHovered(card != nil)
        }
        if card == nil, let point, let row = row(at: point) {
            focus(row: row)
        }
    }

    private func setHoveredCard(_ card: NativePageCardView?) {
        guard card !== hoveredCard else { return }
        let previous = hoveredCard
        hoveredCard = card
        if let card {
            addSubview(card, positioned: .above, relativeTo: nil)
        } else if previous != nil {
            restack()
        }
        animatePlacement([previous, card].compactMap { $0 })
    }

    private func setStackHovered(_ hovered: Bool) {
        guard hovered != stackHovered else { return }
        stackHovered = hovered
        animatePlacement(cards)
    }

    private func animatePlacement(_ moved: [NativePageCardView]) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.26
            context.timingFunction = NativeEase.landing
            context.allowsImplicitAnimation = true
            for card in moved {
                guard let index = cards.firstIndex(where: { $0 === card }) else { continue }
                place(card, index: index)
                card.layer?.shadowRadius = card === hoveredCard ? 22 : 14
                card.layer?.shadowOffset = CGSize(
                    width: 0, height: card === hoveredCard ? -18 : -10)
            }
        }
    }

    // MARK: Rows

    private var visibleRowCount: Int {
        let bottom = panel.maxY - NativePageStyle.footer
        var count = 0
        while count < readPages.count, rowRect(count).maxY < bottom {
            count += 1
        }
        return count
    }

    private func row(at point: NSPoint) -> Int? {
        (0..<visibleRowCount).first { rowRect($0).contains(point) }
    }

    /// Slides the highlight to a row. The first one grows in from its left.
    func focus(row: Int, animated: Bool = true) {
        guard row != focusedRow || cursorRect == nil else { return }
        focusedRow = row
        let target = rowRect(row)
        let from =
            cursorRect ?? NSRect(x: target.minX, y: target.minY, width: 0, height: target.height)
        guard animated else {
            cursorMotion.stop()
            cursorRect = target
            needsDisplay = true
            return
        }
        cursorMotion.run(duration: 0.24) { [weak self] progress in
            self?.cursorRect = NativeEase.mix(
                from, target, NativeEase.back(progress, overshoot: 1.1))
            self?.needsDisplay = true
        }
    }

    /// Highlights a page's row, for coming back to the binder from it.
    func focus(pageId: String) {
        if let row = readPages.firstIndex(where: { $0.id == pageId }), row < visibleRowCount {
            focus(row: row, animated: false)
        }
    }

    /// Where a page is shown in the binder: its card or its row.
    func rect(for pageId: String) -> NSRect? {
        if let card = cards.first(where: { $0.page.id == pageId }) {
            return card.frame
        }
        return readPages.firstIndex { $0.id == pageId }
            .flatMap { $0 < visibleRowCount ? rowRect($0) : nil }
    }

    // MARK: Entrance

    /// Fades the binder in, raises the inbox's cards and drops the rows in
    /// one after another.
    func appear() {
        guard !NativeHandEffects.reducesMotion else { return }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        let rows = CGFloat(min(visibleRowCount, 12))
        let total = 0.26 + rows * 0.03
        revealTime = 0
        revealMotion.run(duration: Double(total)) { [weak self] progress in
            self?.revealTime = progress >= 1 ? nil : progress * total
            self?.needsDisplay = true
        }
        for (index, card) in cards.enumerated() {
            let resting = card.frame
            card.alphaValue = 0
            card.setFrameOrigin(NSPoint(x: resting.minX, y: resting.minY + 40))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 + Double(index) * 0.05) {
                [weak self, weak card] in
                guard let self, let card else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.38
                    context.timingFunction = NativeEase.landing
                    context.allowsImplicitAnimation = true
                    card.alphaValue = 1
                    self.place(card, index: index)
                }
            }
        }
    }

    /// How far a row has come in, from 0 to 1.
    private func revealed(_ row: Int) -> CGFloat {
        guard let time = revealTime else { return 1 }
        return NativeEase.out((time - CGFloat(row) * 0.03) / 0.26)
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        dim.append(NativePageStyle.panelPath(panel))
        dim.windingRule = .evenOdd
        NativePageStyle.dim.setFill()
        dim.fill()
        if NativePageStyle.paper {
            NativePageStyle.drawPaperFrame(panel)
            let serif =
                NativePageStyle.serif(18)
            NativePageStyle.draw(
                "Binder", at: NSPoint(x: panel.minX + 20, y: panel.minY + 6), font: serif,
                color: NativePageStyle.teal.withAlphaComponent(0.5))
            NativePageStyle.draw(
                "Binder", at: NSPoint(x: panel.minX + 18, y: panel.minY + 5), font: serif,
                color: NativePageStyle.text)
            NativePageStyle.draw(
                "\(pages.count) pages · \(unreadIds.count) new",
                at: NSPoint(x: panel.minX + 100, y: panel.minY + 11),
                font: NativePageStyle.sans(12), color: NativePageStyle.muted)
            NativePageStyle.text.setFill()
            NSRect(
                x: panel.minX + 1, y: panel.minY + NativePageStyle.strip, width: panel.width - 2,
                height: 2
            )
            .fill()
        } else {
            let outline = NativePageStyle.panelPath(panel)
            NativePageStyle.surface.withAlphaComponent(0.97).setFill()
            outline.fill()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            NativePageStyle.violet.setFill()
            NSRect(x: panel.minX, y: panel.minY, width: panel.width, height: NativePageStyle.strip)
                .fill()
            NSGraphicsContext.restoreGraphicsState()
            NativePageStyle.violet.withAlphaComponent(0.6).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            NativePageStyle.draw(
                "BINDER  //  \(String(format: "%02d", pages.count)) SHEETS  //  "
                    + "\(String(format: "%02d", unreadIds.count)) UNREAD",
                at: NSPoint(x: panel.minX + 14, y: panel.minY + 9),
                font: NativePageStyle.mono(11, .bold), color: NativePageStyle.ink)
        }

        let inbox = inboxRect
        let dash = NSBezierPath(rect: inbox)
        dash.setLineDash([4, 4], count: 2, phase: 0)
        NativePageStyle.teal.withAlphaComponent(0.35).setStroke()
        dash.stroke()
        let hint =
            cards.isEmpty
            ? "ALL CAUGHT UP"
            : dealt ? "CLICK A SHEET TO READ IT" : "CLICK THE STACK OR PRESS SPACE TO DEAL"
        NativePageStyle.draw(
            "// INBOX   \(hint)", at: NSPoint(x: inbox.minX + 12, y: inbox.minY + 10),
            font: NativePageStyle.mono(10.5, .bold), color: NativePageStyle.teal)

        let headerY = inbox.maxY + 18
        let columns: [(String, CGFloat)] = [
            ("ID", 0), ("TITLE", 100), ("KIND", 0.66), ("UPDATED", 0.8), ("VER", 0.92),
        ]
        let width = panel.width - 40
        func columnX(_ value: CGFloat) -> CGFloat {
            panel.minX + 32 + (value > 1 ? value : value * width)
        }
        for (name, x) in columns {
            NativePageStyle.draw(
                name, at: NSPoint(x: columnX(x), y: headerY + 8),
                font: NativePageStyle.mono(10.5, .bold), color: NativePageStyle.muted)
        }
        NativePageStyle.line.setFill()
        NSRect(x: panel.minX + 20, y: headerY + 29, width: width, height: 1).fill()
        let bottom = panel.maxY - NativePageStyle.footer
        if readPages.isEmpty {
            NativePageStyle.draw(
                "NOTHING FILED YET", at: NSPoint(x: columnX(0), y: rowRect(0).minY + 12),
                font: NativePageStyle.mono(11), color: NativePageStyle.muted)
        }
        if let cursor = cursorRect, focusedRow != nil {
            drawCursor(cursor)
        }
        for (index, page) in readPages.enumerated() {
            let row = rowRect(index)
            guard row.maxY < bottom else { break }
            let shown = revealed(index)
            guard shown > 0 else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(shown)
            NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: (1 - shown) * -12)
            drawRow(page, in: row, focused: index == focusedRow, width: width, x: columnX)
            NSGraphicsContext.restoreGraphicsState()
        }
        let keys = "↑↓  CHOOSE     RETURN  OPEN     SPACE  DEAL     ESC  CLOSE"
        NativePageStyle.draw(
            keys,
            at: NSPoint(x: panel.minX + 14, y: bottom + 8),
            font: NativePageStyle.mono(10.5), color: NativePageStyle.muted)
    }
}

extension NativePageBinderView {
    /// The highlight under the chosen row: a wash with a bar at its left.
    fileprivate func drawCursor(_ cursor: NSRect) {
        let accent = NativePageStyle.paper ? NativePageStyle.teal : NativePageStyle.violet
        let band = NSBezierPath(roundedRect: cursor.insetBy(dx: 0, dy: 3), xRadius: 4, yRadius: 4)
        accent.withAlphaComponent(NativePageStyle.paper ? 0.14 : 0.18).setFill()
        band.fill()
        (NativePageStyle.paper ? NativePageStyle.text : accent).setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: cursor.minX, y: cursor.minY + 9, width: 3, height: max(0, cursor.height - 18)),
            xRadius: 1.5, yRadius: 1.5
        ).fill()
    }

    fileprivate func drawRow(
        _ page: NativeArtifactListItem, in row: NSRect, focused: Bool, width: CGFloat,
        x columnX: (CGFloat) -> CGFloat
    ) {
        let y = row.minY + 12
        // The chosen row's title steps right, out of the bar's way.
        let nudge: CGFloat = focused ? 6 : 0
        NativePageStyle.draw(
            NativePageStyle.shortId(page.id), at: NSPoint(x: columnX(0) + nudge, y: y),
            font: NativePageStyle.mono(12), color: NativePageStyle.teal)
        NativePageStyle.draw(
            page.title,
            in: NSRect(x: columnX(100) + nudge, y: y - 1, width: width * 0.66 - 110, height: 18),
            font: NativePageStyle.sans(13.5, focused ? .semibold : .medium),
            color: NativePageStyle.text)
        NativePageStyle.draw(
            page.kind, at: NSPoint(x: columnX(0.66), y: y),
            font: NativePageStyle.mono(12), color: NativePageStyle.muted)
        NativePageStyle.draw(
            NativePageStyle.age(page.updatedAtMs), at: NSPoint(x: columnX(0.8), y: y),
            font: NativePageStyle.mono(12), color: NativePageStyle.muted)
        NativePageStyle.draw(
            "v\(page.version)", at: NSPoint(x: columnX(0.92), y: y),
            font: NativePageStyle.mono(12, .bold), color: NativePageStyle.violet)
        NativePageStyle.line.withAlphaComponent(0.14).setFill()
        NSRect(x: row.minX, y: row.maxY - 1, width: row.width, height: 1).fill()
    }
}
