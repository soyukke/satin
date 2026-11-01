import AppKit
import QuartzCore

/// The tabs as cards down the left side: the attention hand stood on end,
/// with the tabs that need nothing at the table too. Folded, it is a rail of
/// gems.
final class NativeWindowsSidebarView: NSView {
    static let openWidth: CGFloat = 264
    static let railWidth: CGFloat = 52
    private static let header: CGFloat = 40
    private static let footer: CGFloat = 36

    var onSelect: ((Int) -> Void)?
    var onRename: ((Int) -> Void)?
    var tabMenu: ((Int) -> NSMenu?)?
    var onNewTab: (() -> Void)?
    var onFold: (() -> Void)?

    private(set) var mode: NativeSidebarMode = .open
    private(set) var rows: [NativeWindowRow] = []
    private var sessionName = ""
    private let document = NativeSidebarDocumentView(frame: .zero)
    private lazy var scroll = nativeSidebarScrollView(document: document)
    private let newTabButton = NativeHoverIconButton(symbolName: "plus", title: "New Tab")
    private let foldButton = NativeHoverIconButton(
        symbolName: "sidebar.left", title: "Fold the Windows Sidebar (⌘B)")
    private var cards: [NativeWindowCardView] = []
    private var gems: [NativeWindowGemView] = []
    private var clock: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(scroll)
        for button in [newTabButton, foldButton] {
            button.target = self
            addSubview(button)
        }
        newTabButton.action = #selector(newTab)
        foldButton.action = #selector(fold)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Windows")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateClock()
    }

    func setMode(_ mode: NativeSidebarMode) {
        guard mode != self.mode else {
            return
        }
        self.mode = mode
        foldButton.toolTip =
            mode == .open ? "Fold the Windows Sidebar (⌘B)" : "Open the Windows Sidebar (⌘B)"
        foldButton.setAccessibilityLabel(foldButton.toolTip)
        rebuild()
    }

    func update(rows: [NativeWindowRow], sessionName: String) {
        let shapeChanged = rows.map(\.tabId) != self.rows.map(\.tabId)
        self.rows = rows
        self.sessionName = sessionName
        if shapeChanged {
            rebuild()
        } else {
            for (card, row) in zip(cards, rows) {
                card.row = row
            }
            for (gem, row) in zip(gems, rows) {
                gem.row = row
            }
        }
        updateClock()
        needsDisplay = true
    }

    /// Redraws every card in the current look.
    func refreshLook() {
        needsDisplay = true
        for card in cards {
            card.refresh()
        }
        for gem in gems {
            gem.refresh()
        }
    }

    private func rebuild() {
        for view in (cards as [NSView]) + (gems as [NSView]) {
            view.removeFromSuperview()
        }
        cards = []
        gems = []
        if mode == .open {
            cards = rows.map { row in
                let card = NativeWindowCardView(row: row)
                card.onPress = { [weak self] in self?.onSelect?($0) }
                card.onRename = { [weak self] in self?.onRename?($0) }
                card.tabMenu = { [weak self] in self?.tabMenu?($0) }
                document.addSubview(card)
                return card
            }
        } else {
            gems = rows.map { row in
                let gem = NativeWindowGemView(row: row)
                gem.onPress = { [weak self] in self?.onSelect?($0) }
                gem.tabMenu = { [weak self] in self?.tabMenu?($0) }
                document.addSubview(gem)
                return gem
            }
        }
        newTabButton.isHidden = mode != .open
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        if mode == .open {
            newTabButton.frame = NSRect(x: width - 36, y: 9, width: 24, height: 24)
            foldButton.frame = NSRect(
                x: 10, y: bounds.height - Self.footer + 6, width: 24, height: 24)
            scroll.frame = NSRect(
                x: 0, y: Self.header, width: width,
                height: max(0, bounds.height - Self.header - Self.footer))
            var y: CGFloat = 4
            for card in cards {
                card.frame = NSRect(
                    x: 10, y: y, width: width - 20, height: NativeWindowCardView.height)
                y += NativeWindowCardView.height + 8
            }
            document.frame = NSRect(x: 0, y: 0, width: width, height: y + 8)
        } else {
            foldButton.frame = NSRect(x: (width - 24) / 2, y: 9, width: 24, height: 24)
            scroll.frame = NSRect(
                x: 0, y: Self.header, width: width,
                height: max(0, bounds.height - Self.header))
            var y: CGFloat = 4
            for gem in gems {
                gem.frame = NSRect(x: 0, y: y, width: width, height: NativeWindowGemView.height)
                y += NativeWindowGemView.height
            }
            document.frame = NSRect(x: 0, y: 0, width: width, height: y + 8)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NativeSidebarLook.drawPanel(bounds, ruleAtMaxX: true)
        guard mode == .open else {
            return
        }
        let heading = NativeSidebarLook.heading("WINDOWS", color: NativePageStyle.violet)
        let size = heading.size()
        heading.draw(at: NSPoint(x: 14, y: 21 - size.height / 2))
        let name = NativeSidebarLook.text(
            sessionName, font: NativePageStyle.sans(11, .bold), color: NativePageStyle.muted,
            alignment: .right)
        let nameWidth = min(110, ceil(name.size().width))
        name.draw(
            in: NSRect(
                x: bounds.width - 44 - nameWidth, y: 21 - size.height / 2 - 1,
                width: nameWidth, height: size.height + 2))
        let ruleStart = 14 + ceil(size.width) + 8
        let ruleEnd = bounds.width - 44 - nameWidth - 8
        if ruleEnd > ruleStart {
            NativePageStyle.line.setFill()
            NSRect(x: ruleStart, y: 21, width: ruleEnd - ruleStart, height: 1).fill()
        }
        let hint = NativeSidebarLook.text(
            "⌘J plays the foil card", font: NativePageStyle.mono(10, .regular),
            color: NativePageStyle.muted, alignment: .right)
        hint.draw(
            in: NSRect(
                x: 40, y: bounds.height - Self.footer + 11, width: bounds.width - 54, height: 14))
    }

    /// Ticks once a second while a card shows how long it has waited.
    private func updateClock() {
        let timed = window != nil && rows.contains { $0.since != nil }
        if timed, clock == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        } else if !timed {
            clock?.invalidate()
            clock = nil
        }
    }

    private func tick() {
        let now = Date()
        for card in cards {
            card.refresh(now: now)
        }
        for gem in gems {
            gem.refresh(now: now)
        }
    }

    @objc private func newTab() {
        onNewTab?()
    }

    @objc private func fold() {
        onFold?()
    }

    func cardFramesForSmoke() -> [NSRect] {
        (mode == .open ? cards as [NSView] : gems as [NSView]).map {
            $0.convert($0.bounds, to: self)
        }
    }
}

/// One tab as a card: its gem, title and state, the line it last printed,
/// and a gauge for how long it has waited.
final class NativeWindowCardView: NSView {
    static let height: CGFloat = 64
    private static let radius: CGFloat = 9

    var onPress: ((Int) -> Void)?
    var onRename: ((Int) -> Void)?
    var tabMenu: ((Int) -> NSMenu?)?
    var row: NativeWindowRow {
        didSet {
            if row != oldValue {
                refresh()
            }
        }
    }

    private var now = Date()
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    private let glow = CALayer()
    private let foil = CAGradientLayer()
    private let comet = NativeSidebarComet()

    init(row: NativeWindowRow) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        glow.cornerRadius = Self.radius
        glow.borderWidth = 2
        glow.shadowOpacity = 0.9
        glow.shadowRadius = 8
        glow.shadowOffset = .zero
        foil.cornerRadius = Self.radius
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
        foil.locations = [0, 0.23, 0.35, 0.47, 1]
        layer?.addSublayer(comet.track)
        layer?.addSublayer(foil)
        layer?.addSublayer(glow)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    /// The card's face without the room its paper print takes.
    private var face: NSRect {
        NativePageStyle.paper
            ? NSRect(x: 1, y: 1, width: bounds.width - 6, height: bounds.height - 6)
            : bounds.insetBy(dx: 1, dy: 1)
    }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh(now: Date = Date()) {
        self.now = now
        let color = NativeSidebarLook.color(row.state)
        let paper = NativePageStyle.paper
        let hot =
            (row.state == .waiting || row.state == .failed)
            && row.since.map { NativeHandWait.isHot(since: $0, now: now) } == true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = face
        glow.cornerRadius = paper ? 4 : Self.radius
        glow.borderColor = color.cgColor
        glow.shadowColor = color.cgColor
        glow.isHidden = paper || !hot
        foil.frame = face
        foil.isHidden = paper || !row.isNext
        CATransaction.commit()
        NativeHandEffects.setPulse(glow, active: hot && !paper, minimumOpacity: 0.2, duration: 0.65)
        comet.layout(
            NSRect(x: face.minX + 10, y: face.maxY - 9, width: face.width - 20, height: 3),
            running: row.state == .running)
        let elapsed = row.since.map { nativeElapsedText(since: $0, now: now) } ?? ""
        setAccessibilityLabel(
            "\(row.title), \(row.state.title.lowercased())"
                + (row.isCurrent ? ", current" : "") + (elapsed.isEmpty ? "" : ", \(elapsed)"))
        setAccessibilityHelp(row.line.isEmpty ? nil : row.line)
        toolTip = row.line.isEmpty ? row.title : "\(row.title)\n\(row.line)"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let paper = NativePageStyle.paper
        let color = NativeSidebarLook.color(row.state)
        let face = self.face
        let outline = NSBezierPath(
            roundedRect: face, xRadius: paper ? 4 : Self.radius, yRadius: paper ? 4 : Self.radius)
        if paper {
            let print = (row.isCurrent ? NativePageStyle.violet : NativePageStyle.teal)
                .withAlphaComponent(0.8)
            print.setFill()
            NSBezierPath(roundedRect: face.offsetBy(dx: 4, dy: 4), xRadius: 4, yRadius: 4).fill()
            NativePageStyle.surface.setFill()
            outline.fill()
            NativePageStyle.text.setStroke()
            outline.lineWidth = 2
            outline.stroke()
        } else {
            let tint =
                row.state == .idle
                ? NativeSidebarLook.cardPanel
                : NativeSidebarLook.cardPanel.blended(withFraction: 0.38, of: color)
                    ?? NativeSidebarLook.cardPanel
            NSGradient(colors: [tint, NativeSidebarLook.cardPanel, NativeSidebarLook.stock])?
                .draw(in: outline, angle: -65)
            if row.isCurrent {
                NativePageStyle.violet.setStroke()
                outline.lineWidth = 2
            } else {
                color.withAlphaComponent(row.state == .idle ? 0.45 : 0.85).setStroke()
                outline.lineWidth = 1
            }
            outline.stroke()
        }
        if hovering {
            (paper ? NativePageStyle.text : NSColor.white).withAlphaComponent(0.06).setFill()
            outline.fill()
        }

        NativeSidebarLook.drawGem(
            row.state, center: NSPoint(x: face.minX + 20, y: face.minY + 22), half: 9)

        let elapsed = row.since.map { nativeElapsedText(since: $0, now: now) } ?? ""
        let clock = NativeSidebarLook.text(
            elapsed, font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            color: paper ? NativePageStyle.muted : color, alignment: .right)
        clock.draw(in: NSRect(x: face.maxX - 52, y: face.minY + 9, width: 43, height: 14))
        let titleRight = face.maxX - (elapsed.isEmpty ? 10 : 56)
        NativeSidebarLook.text(
            row.title, font: NativePageStyle.sans(13, .heavy), color: NativeSidebarLook.cardText
        ).draw(
            in: NSRect(
                x: face.minX + 38, y: face.minY + 7, width: titleRight - face.minX - 38,
                height: 18))

        var lineX = face.minX + 38
        let kindY = face.minY + 30
        if paper {
            let word = row.state.title as NSString
            let font = NativePageStyle.sans(8, .heavy)
            let width = word.size(withAttributes: [.font: font, .kern: 1.1]).width
            NativePageStyle.drawStamp(
                row.state.title, center: NSPoint(x: lineX + width / 2 + 8, y: kindY + 7),
                color: color, angle: -5, size: 8)
            lineX += width + 22
        } else {
            let kind = NativeSidebarLook.text(
                row.state.title, font: NativePageStyle.sans(8, .bold), color: color, kern: 1.2)
            kind.draw(at: NSPoint(x: lineX, y: kindY + 2))
            lineX += ceil(kind.size().width) + 8
        }
        let lineColor =
            row.state == .idle || paper
            ? NativePageStyle.muted : NSColor.white.withAlphaComponent(0.78)
        NativeSidebarLook.text(row.line, font: NativePageStyle.mono(10, .regular), color: lineColor)
            .draw(
                in: NSRect(x: lineX, y: kindY + 1, width: face.maxX - 10 - lineX, height: 14))

        guard row.state != .idle, row.state != .running else {
            return
        }
        let track = NSRect(x: face.minX + 10, y: face.maxY - 9, width: face.width - 20, height: 3)
        (paper ? NativePageStyle.line : NSColor.white.withAlphaComponent(0.12)).setFill()
        track.fill()
        var fill = track
        fill.size.width *=
            row.state == .clear
            ? 1 : CGFloat(row.since.map { NativeHandWait.fraction(since: $0, now: now) } ?? 0)
        color.setFill()
        fill.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        if event.clickCount == 2 {
            onRename?(row.index)
        } else if event.clickCount == 1 {
            onPress?(row.index)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        tabMenu?(row.index)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(row.index)
        return true
    }
}

/// A tab on the folded rail: its gem alone, ringed when it is the current
/// tab and glowing while it has waited too long.
final class NativeWindowGemView: NSView {
    static let height: CGFloat = 40

    var onPress: ((Int) -> Void)?
    var tabMenu: ((Int) -> NSMenu?)?
    var row: NativeWindowRow {
        didSet {
            if row != oldValue {
                refresh()
            }
        }
    }

    private let glow = CALayer()

    init(row: NativeWindowRow) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        glow.shadowOpacity = 0.9
        glow.shadowRadius = 7
        glow.shadowOffset = .zero
        layer?.addSublayer(glow)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh(now: Date = Date()) {
        let color = NativeSidebarLook.color(row.state)
        let hot =
            !NativePageStyle.paper
            && (row.state == .waiting || row.state == .failed)
            && row.since.map { NativeHandWait.isHot(since: $0, now: now) } == true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
        glow.cornerRadius = 9
        glow.backgroundColor = color.withAlphaComponent(0.35).cgColor
        glow.shadowColor = color.cgColor
        glow.isHidden = !hot
        CATransaction.commit()
        NativeHandEffects.setPulse(glow, active: hot, minimumOpacity: 0.2, duration: 0.65)
        toolTip = row.line.isEmpty ? row.title : "\(row.title) — \(row.state.title)\n\(row.line)"
        setAccessibilityLabel(
            "\(row.title), \(row.state.title.lowercased())" + (row.isCurrent ? ", current" : ""))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if row.isCurrent {
            let ring = NSBezierPath(
                roundedRect: NSRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32),
                xRadius: 8, yRadius: 8)
            ring.lineWidth = 2
            NativePageStyle.violet.setStroke()
            ring.stroke()
        }
        NativeSidebarLook.drawGem(row.state, center: center, half: 9)
        if NativePageStyle.paper {
            let dot = NSBezierPath(
                ovalIn: NSRect(x: center.x - 7.3, y: center.y - 7.3, width: 14.6, height: 14.6))
            dot.lineWidth = 2
            NativePageStyle.text.setStroke()
            dot.stroke()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onPress?(row.index)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        tabMenu?(row.index)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(row.index)
        return true
    }
}
