import AppKit
import QuartzCore

/// The tabs as cards down the left side, under headings by state: the
/// attention hand stood on end, with the tabs that need nothing at the
/// table too. Folded, it is a rail of gems with a rule between the states.
final class NativeWindowsSidebarView: NSView {
    static let openWidth: CGFloat = 264
    /// The narrowest a drag leaves it.
    static let minWidth: CGFloat = 200
    static let railWidth: CGFloat = 52
    private static let header: CGFloat = 40
    private static let footer: CGFloat = 36

    var onSelect: ((Int) -> Void)?
    var onRename: ((Int) -> Void)?
    var tabMenu: ((Int) -> NSMenu?)?
    var onNewTab: (() -> Void)?
    var onFold: (() -> Void)?
    /// A drag on the inner edge: the width asked for, and whether the drag
    /// has ended.
    var onResize: ((CGFloat, Bool) -> Void)?
    var onResetWidth: (() -> Void)?
    /// Asked for the sessions, with the button to show them under.
    var onSessions: ((NSView) -> Void)?

    private(set) var mode: NativeSidebarMode = .open
    private(set) var rows: [NativeWindowRow] = []
    private let document = NativeSidebarDocumentView(frame: .zero)
    private lazy var scroll = nativeSidebarScrollView(document: document)
    private let newTabButton = NativeHoverIconButton(symbolName: "plus", title: "New Tab")
    private let foldButton = NativeHoverIconButton(
        symbolName: "sidebar.left", title: "Fold the Windows Sidebar (⌘B)")
    private let sessionButton = NativeSessionChip()
    private var groups: [(NativeWindowGroup, [NativeWindowRow])] = []
    private var headings: [(String, CGFloat)] = []
    private var rules: [CGFloat] = []
    private var cards: [NativeWindowCardView] = []
    private var gems: [NativeWindowGemView] = []
    private var clock: Timer?
    private let grip = NativeSidebarResizeGrip(onLeft: true, label: "Resize the Windows Sidebar")
    /// Whether each tab shows its ⌘ digit. The cards keep their order by
    /// state, so the digits, which go by tab, are not their places.
    var showsShortcuts = false {
        didSet {
            guard showsShortcuts != oldValue else {
                return
            }
            for card in cards {
                card.showsShortcut = showsShortcuts
            }
            for gem in gems {
                gem.showsShortcut = showsShortcuts
            }
        }
    }

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
        sessionButton.onPress = { [weak self] in
            guard let self else { return }
            self.onSessions?(self.sessionButton)
        }
        addSubview(sessionButton)
        grip.onDrag = { [weak self] width, ended in self?.onResize?(width, ended) }
        grip.onReset = { [weak self] in self?.onResetWidth?() }
        addSubview(grip)
        document.drawing = { [weak self] in
            self?.drawGroups()
        }
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
        let groups = nativeWindowGroups(rows)
        let shapeChanged = Self.shape(groups) != Self.shape(self.groups)
        self.rows = rows
        self.groups = groups
        sessionButton.sessionName = sessionName
        if shapeChanged {
            rebuild()
        } else {
            let ordered = groups.flatMap(\.1)
            for (card, row) in zip(cards, ordered) {
                card.row = row
            }
            for (gem, row) in zip(gems, ordered) {
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
        sessionButton.needsDisplay = true
    }

    /// Which tab sits under which heading, in order: a change moves cards.
    private static func shape(_ groups: [(NativeWindowGroup, [NativeWindowRow])]) -> [[Int]] {
        groups.map { group, rows in [group.rawValue] + rows.map(\.tabId) }
    }

    /// A tab's gem on the rail, in this view's coordinates; nil while the
    /// cards show instead, or when the tab has no gem.
    func gemFrame(tabId: Int) -> NSRect? {
        layoutSubtreeIfNeeded()
        return gems.first { $0.row.tabId == tabId }.map { convert($0.bounds, from: $0) }
    }

    private func rebuild() {
        for view in (cards as [NSView]) + (gems as [NSView]) {
            view.removeFromSuperview()
        }
        cards = []
        gems = []
        let ordered = groups.flatMap(\.1)
        if mode == .open {
            cards = ordered.map { row in
                let card = NativeWindowCardView(row: row)
                card.onPress = { [weak self] in self?.onSelect?($0) }
                card.onRename = { [weak self] in self?.onRename?($0) }
                card.tabMenu = { [weak self] in self?.tabMenu?($0) }
                card.showsShortcut = showsShortcuts
                document.addSubview(card)
                return card
            }
        } else {
            gems = ordered.map { row in
                let gem = NativeWindowGemView(row: row)
                gem.onPress = { [weak self] in self?.onSelect?($0) }
                gem.tabMenu = { [weak self] in self?.tabMenu?($0) }
                gem.showsShortcut = showsShortcuts
                document.addSubview(gem)
                return gem
            }
        }
        newTabButton.isHidden = mode != .open
        sessionButton.isHidden = mode != .open
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        grip.frame = NSRect(
            x: width - NativeSidebarResizeGrip.width, y: 0, width: NativeSidebarResizeGrip.width,
            height: bounds.height)
        // Open or folded, the button stays where the pointer left it.
        foldButton.frame = NSRect(
            x: (Self.railWidth - 24) / 2, y: bounds.height - Self.footer + 6, width: 24,
            height: 24)
        if mode == .open {
            newTabButton.frame = NSRect(x: width - 36, y: 9, width: 24, height: 24)
            // Narrower than its own width, the sidebar keeps the chip off
            // the heading.
            let chipWidth = min(130, sessionButton.fittingWidth, max(48, width - 134))
            sessionButton.frame = NSRect(
                x: width - 42 - chipWidth, y: 9, width: chipWidth, height: 24)
            scroll.frame = NSRect(
                x: 0, y: Self.header, width: width,
                height: max(0, bounds.height - Self.header - Self.footer))
            var y: CGFloat = 2
            var next = cards.makeIterator()
            headings = []
            for (group, members) in groups {
                headings.append(("\(group.title) · \(members.count)", y))
                y += 22
                for _ in members {
                    next.next()?.frame = NSRect(
                        x: 10, y: y, width: width - 20, height: NativeWindowCardView.height)
                    y += NativeWindowCardView.height + NativeWindowCardView.gap
                }
                y += 6
            }
            document.frame = NSRect(x: 0, y: 0, width: width, height: y)
            document.needsDisplay = true
        } else {
            scroll.frame = NSRect(
                x: 0, y: 0, width: width, height: max(0, bounds.height - Self.footer))
            var y: CGFloat = 4
            var next = gems.makeIterator()
            rules = []
            for (offset, (_, members)) in groups.enumerated() {
                if offset > 0 {
                    rules.append(y + 4)
                    y += 9
                }
                for _ in members {
                    next.next()?.frame = NSRect(
                        x: 0, y: y, width: width, height: NativeWindowGemView.height)
                    y += NativeWindowGemView.height
                }
            }
            document.frame = NSRect(x: 0, y: 0, width: width, height: y + 8)
            document.needsDisplay = true
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
        let ruleStart = 14 + ceil(size.width) + 8
        let ruleEnd = sessionButton.frame.minX - 6
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

    /// The headings over the cards, or the rules between the rail's states.
    private func drawGroups() {
        if mode == .open {
            for (title, y) in headings {
                NativeSidebarLook.heading(title, color: NativePageStyle.muted)
                    .draw(at: NSPoint(x: 14, y: y + 4))
            }
        } else {
            NativePageStyle.line.setFill()
            for y in rules {
                NSRect(x: 14, y: y, width: bounds.width - 28, height: 1).fill()
            }
        }
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

    func pressSessionsForSmoke() {
        sessionButton.onPress?()
    }

    func cardFramesForSmoke() -> [NSRect] {
        (mode == .open ? cards as [NSView] : gems as [NSView]).map {
            $0.convert($0.bounds, to: self)
        }
    }
}

/// The session the windows belong to, local or a tmux session's name, as a
/// button that shows the sessions to switch to.
final class NativeSessionChip: NSView {
    var onPress: (() -> Void)?
    var sessionName = "" {
        didSet {
            guard sessionName != oldValue else { return }
            toolTip = "Switch Sessions (\(sessionName))"
            setAccessibilityLabel("Session \(sessionName)")
            superview?.needsLayout = true
            needsDisplay = true
        }
    }

    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    private var isLocal: Bool {
        sessionName == "local"
    }

    private func label() -> NSAttributedString {
        NativeSidebarLook.text(
            sessionName, font: NativePageStyle.sans(11, .bold),
            color: hovering ? NativePageStyle.text : NativePageStyle.muted)
    }

    /// The width that shows the whole name with its icon and chevron.
    var fittingWidth: CGFloat {
        ceil(label().size().width) + 40
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
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

    // Taking the press keeps the release here.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onPress?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 2.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        let accent = isLocal ? NativePageStyle.muted : NativePageStyle.teal
        accent.withAlphaComponent(hovering ? 0.22 : 0.1).setFill()
        path.fill()
        accent.withAlphaComponent(hovering ? 0.6 : 0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
        let tint = hovering ? NativePageStyle.text : accent
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        if let icon = NSImage(
            systemSymbolName: isLocal ? "terminal" : "rectangle.stack",
            accessibilityDescription: nil)?.withSymbolConfiguration(iconConfig)
        {
            drawSymbol(icon, at: NSPoint(x: 8, y: bounds.midY), tint: tint)
        }
        let text = label()
        let size = text.size()
        text.draw(
            in: NSRect(
                x: 22, y: bounds.midY - size.height / 2, width: bounds.width - 40,
                height: size.height))
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        if let chevron = NSImage(
            systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronConfig)
        {
            drawSymbol(chevron, at: NSPoint(x: bounds.width - 15, y: bounds.midY), tint: tint)
        }
    }

    /// Draws a symbol tinted, its left edge at x and centered on y.
    private func drawSymbol(_ image: NSImage, at point: NSPoint, tint: NSColor) {
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(
            in: NSRect(
                x: point.x, y: point.y - image.size.height / 2, width: image.size.width,
                height: image.size.height))
    }
}

/// One tab as a row: its gem, title and age, and under them a hairline
/// gauge for how long it has waited. The line it last printed is in its
/// tooltip.
final class NativeWindowCardView: NSView {
    static let height: CGFloat = 26
    /// The room between two rows.
    static let gap: CGFloat = 2
    private static let radius: CGFloat = 6

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

    var showsShortcut = false {
        didSet { needsDisplay = true }
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
        glow.borderWidth = 1
        glow.shadowOpacity = 0.55
        glow.shadowRadius = 4
        glow.shadowOffset = .zero
        foil.cornerRadius = Self.radius
        foil.masksToBounds = true
        foil.startPoint = CGPoint(x: 0, y: 0)
        foil.endPoint = CGPoint(x: 1, y: 1)
        foil.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.12).cgColor,
            NSColor.systemTeal.withAlphaComponent(0.08).cgColor,
            NSColor.systemPink.withAlphaComponent(0.07).cgColor,
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

    private var face: NSRect {
        bounds.insetBy(dx: 1, dy: 0.5)
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
        // A slow breath, not an alarm: the sidebar sits beside the work.
        NativeHandEffects.setPulse(glow, active: hot && !paper, minimumOpacity: 0.25, duration: 2.4)
        comet.layout(
            NSRect(x: face.minX + 26, y: face.maxY - 3, width: face.width - 34, height: 1.5),
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
            roundedRect: face, xRadius: paper ? 3 : Self.radius, yRadius: paper ? 3 : Self.radius)
        // A plain row; only the current tab and the one under the pointer
        // are filled.
        if row.isCurrent {
            NativePageStyle.violet.withAlphaComponent(paper ? 0.16 : 0.22).setFill()
            outline.fill()
            NativePageStyle.violet.withAlphaComponent(paper ? 0.9 : 0.7).setStroke()
            outline.lineWidth = 1
            outline.stroke()
        } else if hovering {
            (paper ? NativePageStyle.text : NSColor.white).withAlphaComponent(0.07).setFill()
            outline.fill()
        }

        NativeSidebarLook.drawGem(
            row.state, center: NSPoint(x: face.minX + 13, y: face.midY), half: 6)

        // While ⌘ is held, the tab's digit takes the place of its age.
        let digit = showsShortcut ? row.shortcut : nil
        let age =
            digit != nil ? "" : row.since.map { nativeSidebarAgeText(since: $0, now: now) } ?? ""
        let clock = NativeSidebarLook.text(
            age, font: NativePageStyle.mono(10, .semibold),
            color: paper ? NativePageStyle.muted : color.withAlphaComponent(0.85),
            alignment: .right)
        clock.draw(in: NSRect(x: face.maxX - 46, y: face.midY - 7, width: 40, height: 14))
        if let digit {
            NativeSidebarLook.drawShortcut(
                digit, center: NSPoint(x: face.maxX - 18, y: face.midY))
        }
        let left = face.minX + 26
        let right = face.maxX - (digit != nil ? 36 : age.isEmpty ? 8 : 48)
        let title = NativeSidebarLook.text(
            row.title, font: NativePageStyle.sans(12, .semibold),
            color: NativeSidebarLook.cardText)
        // Under NEEDS YOU the word tells waiting from failed; elsewhere the
        // heading already says it.
        let showsWord = NativeWindowGroup(row.state) == .needsYou
        let wordFont = NativePageStyle.sans(8, .bold)
        let wordWidth =
            showsWord
            ? ceil(
                (row.state.title as NSString).size(withAttributes: [.font: wordFont, .kern: 1.2])
                    .width) : 0
        let titleWidth = min(ceil(title.size().width), max(0, right - left - wordWidth - 6))
        title.draw(in: NSRect(x: left, y: face.midY - 8, width: titleWidth, height: 16))
        let wordX = left + titleWidth + 6
        if showsWord, wordX + wordWidth <= right {
            NativeSidebarLook.text(
                row.state.title, font: wordFont, color: color.withAlphaComponent(0.9), kern: 1.2
            ).draw(at: NSPoint(x: wordX, y: face.midY - 5))
        }

        guard row.state != .idle, row.state != .running else {
            return
        }
        let track = NSRect(x: left, y: face.maxY - 3, width: face.maxX - 8 - left, height: 1.5)
        (paper ? NativePageStyle.line : NSColor.white.withAlphaComponent(0.08)).setFill()
        track.fill()
        var fill = track
        fill.size.width *=
            row.state == .clear
            ? 1 : CGFloat(row.since.map { NativeHandWait.fraction(since: $0, now: now) } ?? 0)
        color.withAlphaComponent(paper ? 1 : 0.75).setFill()
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

    var showsShortcut = false {
        didSet { needsDisplay = true }
    }
    private let glow = CALayer()

    init(row: NativeWindowRow) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        glow.shadowOpacity = 0.6
        glow.shadowRadius = 6
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
        glow.backgroundColor = color.withAlphaComponent(0.25).cgColor
        glow.shadowColor = color.cgColor
        glow.isHidden = !hot
        CATransaction.commit()
        NativeHandEffects.setPulse(glow, active: hot, minimumOpacity: 0.25, duration: 2.4)
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
        if showsShortcut, let digit = row.shortcut {
            NativeSidebarLook.drawShortcut(
                digit, center: NSPoint(x: bounds.maxX - 14, y: bounds.minY + 10))
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
