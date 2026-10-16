import AppKit
import QuartzCore

/// The hand of attention cards, held in a fan at the window's lower edge over
/// the panes. It takes no room of its own, so a card coming or going never
/// resizes a terminal; the cards show their name, screen and state, and rise
/// when dealt or pointed at.
final class NativeAttentionHandView: NSView {
    /// The room the hand keeps below the panes: none, the cards lie over them.
    static let stripHeight: CGFloat = 0
    /// How much of a card at rest shows above the window's edge.
    private static let restShowing: CGFloat = 104
    static let reach: CGFloat = 268
    private static let hoverGrace: TimeInterval = 0.35
    private static let peekLift: CGFloat = 84
    /// How far the chosen card rises past the others, in the fan at most.
    private static let chosenLift: CGFloat = 46
    private static let dealtRaise: TimeInterval = 2.2
    private static let playedRaise: TimeInterval = 1.2
    private static let allClearDuration: TimeInterval = 1.6

    var onSelect: ((NativeHandCard) -> Void)?
    /// The middle of a tab in the tab strip, in this view's x coordinates.
    /// Cards are dealt from under their tab and return there when played.
    var tabMidX: ((Int) -> CGFloat?)?
    /// The screen of a pane, shown beside its card while the card is chosen.
    var previewText: ((Int) -> String?)?
    var onSelectionChange: ((NativeHandCard?) -> Void)?

    private let handLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    /// Holds the cards, so a card in flight can lie over all of them.
    private let cardHost = NSView(frame: .zero)
    /// The threads from each card to its tab lie under the cards; comets and
    /// sparks fly over them.
    private let tetherHost = NSView(frame: .zero)
    private let effectsHost = NSView(frame: .zero)
    private let previewView = NativeHandPreviewView(frame: .zero)
    private var tethers = [Int: CAShapeLayer]()
    private(set) var selectedPaneId: Int?
    /// Set while ⌘J holds the hand open to choose a card with the keyboard.
    private var selectionOpen = false
    private var slots: [NativeHandSlotView] = []
    private var hand = NativeAttentionHand.empty
    private var run = NativeHandRun()
    private var raised = false
    /// Raised all the way into a fan, as a deal, a play and ⌘J do. The
    /// pointer only lifts the cards where they stand, so they stay under it.
    private var fanned = false
    private var hovering = false
    private var lowerWorkItem: DispatchWorkItem?
    private var allClearUntil: Date?
    private var refreshTimer: Timer?
    private var hoverArea: NSTrackingArea?
    private weak var foiledCard: NativeHandCardView?
    /// Lowered out of sight while a page or the binder is open.
    private var sunk = false
    /// The room at the right the unread pages' fan takes; the hand centers
    /// itself in what is left.
    var rightReserve: CGFloat = 0 {
        didSet {
            if rightReserve != oldValue {
                place(animated: true)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isHidden: Bool {
        didSet {
            updateRefreshTimer()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRefreshTimer()
    }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Only the strip and the cards take the pointer; the panes keep the rest.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !sunk else {
            return nil
        }
        let local = superview.map { convert(point, from: $0) } ?? point
        return local.y <= Self.stripHeight || slot(at: local) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let slot = slot(at: convert(event.locationInWindow, from: nil)) else {
            return
        }
        onSelect?(slot.cardView.card)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let overCard = slot(at: point)
        setHovering(
            !slots.isEmpty
                && (point.y <= Self.stripHeight || overCard != nil || fanZone.contains(point)))
        if let overCard {
            setSelected(overCard.cardView.card.paneId)
        } else if !selectionOpen {
            setSelected(nil)
        }
        let card = overCard?.cardView
        if foiledCard !== card {
            foiledCard?.setFoil(at: nil)
            foiledCard = card
        }
        if let overCard {
            let local = overCard.convert(point, from: self)
            overCard.cardView.setFoil(at: local.x / max(1, overCard.bounds.width))
        }
    }

    override func mouseExited(with event: NSEvent) {
        foiledCard?.setFoil(at: nil)
        foiledCard = nil
        if !selectionOpen {
            setSelected(nil)
        }
        setHovering(false)
    }

    var selectedCard: NativeHandCard? {
        slots.first { $0.cardView.card.paneId == selectedPaneId }?.cardView.card
    }

    /// Holds the hand open with one card chosen, as ⌘J does until ⌘ is let go.
    func openSelection(paneId: Int) {
        selectionOpen = true
        lowerWorkItem?.cancel()
        lowerWorkItem = nil
        raised = true
        fanned = true
        if selectedPaneId == paneId {
            place(animated: true)
        } else {
            setSelected(paneId)
        }
    }

    func closeSelection() {
        guard selectionOpen else {
            return
        }
        selectionOpen = false
        raised = hovering
        fanned = false
        setSelected(nil)
        place(animated: true)
    }

    private func setSelected(_ paneId: Int?) {
        guard paneId != selectedPaneId else {
            return
        }
        selectedPaneId = paneId
        place(animated: true)
        onSelectionChange?(selectedCard)
    }

    /// Shows the hand. A card whose pane is `playedPaneId` leaves as a played
    /// card; any other card that is gone was answered elsewhere.
    func update(
        hand: NativeAttentionHand,
        art: [Int: [String]],
        run: NativeHandRun,
        playedPaneId: Int? = nil
    ) {
        guard hand != self.hand || run != self.run || playedPaneId != nil else {
            return
        }
        let hadCards = !slots.isEmpty
        self.hand = hand
        self.run = run
        var previous = Dictionary(uniqueKeysWithValues: slots.map { ($0.cardView.card.paneId, $0) })
        var dealt: [NativeHandSlotView] = []
        slots = hand.cards.map { card in
            if let slot = previous.removeValue(forKey: card.paneId) {
                slot.cardView.update(card, art: art[card.paneId] ?? [])
                return slot
            }
            let slot = makeSlot(card, art: art[card.paneId] ?? [])
            dealt.append(slot)
            return slot
        }
        for slot in previous.values {
            dismiss(slot, played: slot.cardView.card.paneId == playedPaneId)
        }
        // Each card lies over the one before it, as a hand is held, so every
        // card keeps its name and mark showing at its upper left.
        for slot in slots {
            cardHost.addSubview(slot, positioned: .above, relativeTo: nil)
            slot.cardView.isFirst = slot === slots.first
        }
        if playedPaneId != nil, hadCards, slots.isEmpty {
            allClearUntil = Date().addingTimeInterval(Self.allClearDuration)
        }
        if !dealt.isEmpty {
            fanned = true
            raise(for: Self.dealtRaise)
        } else if playedPaneId != nil {
            fanned = true
            raise(for: Self.playedRaise)
        }
        place(animated: true)
        for slot in dealt {
            dealFromTab(slot)
        }
        refreshLabels(now: Date())
        updateRefreshTimer()
    }

    /// Sends a ball of fire from the card's tab to its place in the hand,
    /// where it becomes the card, so it is seen where the card came from.
    private func dealFromTab(_ slot: NativeHandSlotView) {
        guard !NativeHandEffects.reducesMotion, window != nil,
            let host = effectsHost.layer,
            let x = tabMidX?(slot.cardView.card.tabId)
        else {
            return
        }
        let size = NativeHandCardView.size
        slot.alphaValue = 0
        slot.setFrameOrigin(slot.restOrigin)
        slot.cardView.frameCenterRotation = slot.restRotation
        NativeHandComet.fly(
            in: host,
            from: CGPoint(x: x, y: bounds.maxY),
            to: CGPoint(
                x: slot.restOrigin.x + size.width / 2,
                y: slot.restOrigin.y + size.height * 0.72),
            color: slot.cardView.color
        ) { [weak self, weak slot] in
            slot?.alphaValue = 1
            self?.updateTethers()
        }
    }

    /// Carries the card for `paneId` out of the hand and over the panes.
    /// `arrive` runs while the card covers them: it switches to the card's
    /// pane and answers where that pane now is, in this view's coordinates.
    func play(paneId: Int, arrive: @escaping () -> NSRect?) {
        guard let slot = slots.first(where: { $0.cardView.card.paneId == paneId }),
            !NativeHandEffects.reducesMotion, window != nil
        else {
            _ = arrive()
            return
        }
        let color = slot.cardView.color
        let tabX = tabMidX?(slot.cardView.card.tabId)
        let flyer = NativeHandFlyerView(
            frame: slot.frame, color: color, face: slot.cardView.snapshot())
        addSubview(flyer)
        slot.alphaValue = 0
        let cover = NSRect(
            x: 0, y: Self.stripHeight, width: bounds.width,
            height: bounds.height - Self.stripHeight)
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                flyer.animator().frame = cover
                flyer.fadeFace()
            },
            completionHandler: { [weak self] in
                let target = arrive() ?? cover
                if let self, let tabX, let host = self.effectsHost.layer {
                    NativeHandComet.burst(
                        in: host, at: CGPoint(x: tabX, y: self.bounds.maxY - 2), color: color)
                }
                NSAnimationContext.runAnimationGroup(
                    { context in
                        context.duration = 0.3
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        flyer.animator().frame = target.insetBy(dx: 1, dy: 1)
                        flyer.fadeFill()
                    },
                    completionHandler: {
                        // The outline stays on the pane that took the focus.
                        NSAnimationContext.runAnimationGroup(
                            { context in
                                context.duration = 0.9
                                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                                flyer.animator().alphaValue = 0
                            },
                            completionHandler: {
                                flyer.removeFromSuperview()
                            }
                        )
                    }
                )
            }
        )
    }

    /// Puts the strip and the cards in the current mode's look.
    func applyLook() {
        for slot in slots {
            slot.applyLook()
        }
        needsLayout = true
    }

    /// Puts the hand away, or brings it back, each card whole: it shrinks
    /// toward its head before it drops, rather than slide past the window's
    /// edge cut in half.
    func setSunk(_ sunk: Bool) {
        guard sunk != self.sunk else {
            return
        }
        self.sunk = sunk
        if sunk {
            NativeHandEffects.tuck(slots.map(\.cardView), in: self, away: true)
            place(animated: false)
            return
        }
        // The stand-ins are taken from the cards in place before they hide.
        place(animated: false)
        let shown = slots
        NativeHandEffects.tuck(shown.map(\.cardView), in: self, away: false) {
            for slot in shown {
                slot.alphaValue = 1
            }
        }
        for slot in shown {
            slot.alphaValue = 0
        }
    }

    func setRaised(_ raised: Bool, animated: Bool) {
        guard raised != self.raised || raised != fanned else {
            return
        }
        self.raised = raised
        fanned = raised
        place(animated: animated)
    }

    private func makeSlot(_ card: NativeHandCard, art: [String]) -> NativeHandSlotView {
        let cardView = NativeHandCardView(card: card, art: art)
        cardView.onPress = { [weak self] in
            self?.onSelect?($0)
        }
        let slot = NativeHandSlotView(cardView: cardView)
        // Cards are dealt from the lower right corner.
        slot.setFrameOrigin(
            NSPoint(x: bounds.maxX - 40, y: -NativeHandCardView.size.height))
        return slot
    }

    private func dismiss(_ slot: NativeHandSlotView, played: Bool) {
        guard !NativeHandEffects.reducesMotion, window != nil else {
            slot.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = played ? 0.32 : 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                slot.animator().alphaValue = 0
                if played {
                    var origin = slot.frame.origin
                    origin.y += 110
                    slot.animator().setFrameOrigin(origin)
                    slot.cardView.animator().frameCenterRotation = 0
                }
            },
            completionHandler: {
                slot.removeFromSuperview()
            }
        )
    }

    private func raise(for duration: TimeInterval) {
        lowerWorkItem?.cancel()
        raised = true
        let lower = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.lowerWorkItem = nil
            if !self.hovering, !self.selectionOpen {
                self.setRaised(false, animated: true)
            } else if !self.selectionOpen, self.fanned {
                // The pointer is still on the hand: settle to its height.
                self.fanned = false
                self.place(animated: true)
            }
        }
        lowerWorkItem = lower
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: lower)
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != self.hovering else {
            return
        }
        self.hovering = hovering
        if hovering {
            if !raised {
                raised = true
                fanned = false
                place(animated: true)
            }
        } else if lowerWorkItem == nil, !selectionOpen {
            // The fan closes toward the middle as it rises, so the pointer
            // gets a moment to follow the card it was under.
            raise(for: Self.hoverGrace)
        }
    }

    /// Where the pointer keeps a raised hand up: the fan and a margin around it.
    private var fanZone: NSRect {
        guard raised else {
            return .zero
        }
        return slots.reduce(NSRect.null) { $0.union($1.frame) }.insetBy(dx: -40, dy: -40)
    }

    private func slot(at point: NSPoint) -> NativeHandSlotView? {
        // The chosen card stands clear of the fan; otherwise the card on top
        // wins. The chosen card also keeps the place it rose from, or the
        // pointer that chose it near its foot would drop it, choose it again
        // when it settled, and so on.
        if let chosen = slots.first(where: { $0.cardView.isChosen }) {
            let risen = chosen.frame
            let kept = NSRect(
                x: risen.minX, y: risen.minY - Self.chosenLift,
                width: risen.width, height: risen.height + Self.chosenLift)
            if kept.contains(point) {
                return chosen
            }
        }
        return slots.last { $0.frame.contains(point) }
    }

    /// The pane of the card the pointer at point would be on.
    func cardPaneId(at point: NSPoint) -> Int? {
        slot(at: point)?.cardView.card.paneId
    }

    private func place(animated: Bool) {
        let size = NativeHandCardView.size
        let count = CGFloat(slots.count)
        let width = max(size.width + 48, bounds.width - rightReserve)
        let room = slots.count > 1 ? max(36, (width - size.width - 48) / (count - 1)) : 0
        // The cards are always held in a fan. At rest it sinks below the
        // window's edge with each card's head showing; under the pointer it
        // rises far enough to read; dealt, played or ⌘J, it stands up whole.
        let fan = raised && fanned
        let step = min(size.width * 0.62, room)
        let chosenIndex =
            raised ? slots.firstIndex { $0.cardView.card.paneId == selectedPaneId } : nil
        let moves = slots.enumerated().map {
            index, slot -> (NativeHandSlotView, NSPoint, CGFloat) in
            let offset = CGFloat(index) - (count - 1) / 2
            let first = index == 0
            let chosen = index == chosenIndex
            // The neighbors of a chosen card draw aside to show all of it.
            let aside: CGFloat = chosenIndex.map { index < $0 ? -34 : (index > $0 ? 34 : 0) } ?? 0
            let lift: CGFloat = chosen ? Self.chosenLift : (first && chosenIndex == nil ? 12 : 0)
            let restY = Self.restShowing - size.height - offset * offset * 5 + (first ? 6 : 0)
            var y: CGFloat
            if fan {
                y = 20 - offset * offset * 7 + lift
            } else if raised {
                y = restY + Self.peekLift + (chosen ? 30 : 0)
            } else {
                y = restY
            }
            if sunk {
                y = -size.height - 40
            }
            let origin = NSPoint(
                x: bounds.minX + width / 2 + offset * step + aside - size.width / 2, y: y)
            slot.cardView.isChosen = chosen
            slot.layer?.zPosition = chosen ? 50 : 0
            slot.restOrigin = origin
            slot.restRotation = chosen ? 0 : -offset * (fan ? 7 : 5)
            return (slot, origin, slot.restRotation)
        }
        updateTethers()
        updatePreview()
        guard animated, !NativeHandEffects.reducesMotion, window != nil else {
            for (slot, origin, rotation) in moves {
                slot.setFrameOrigin(origin)
                slot.cardView.frameCenterRotation = rotation
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (slot, origin, rotation) in moves {
                slot.animator().setFrameOrigin(origin)
                slot.cardView.animator().frameCenterRotation = rotation
            }
        }
    }

    /// Hangs a thread from each raised card to the tab its pane is in.
    private func updateTethers() {
        var live = Set<Int>()
        let size = NativeHandCardView.size
        for slot in slots {
            let card = slot.cardView.card
            guard raised, !sunk, slot.alphaValue > 0, let x = tabMidX?(card.tabId) else {
                continue
            }
            live.insert(card.paneId)
            let thread = tethers[card.paneId] ?? CAShapeLayer()
            if tethers[card.paneId] == nil {
                thread.fillColor = nil
                thread.lineCap = .round
                tetherHost.layer?.addSublayer(thread)
                tethers[card.paneId] = thread
            }
            let chosen = card.paneId == selectedPaneId
            thread.path = NativeHandComet.path(
                from: CGPoint(
                    x: slot.restOrigin.x + size.width / 2,
                    y: slot.restOrigin.y + size.height - 6),
                to: CGPoint(x: x, y: bounds.maxY))
            thread.strokeColor =
                slot.cardView.color.withAlphaComponent(chosen ? 0.95 : 0.32).cgColor
            thread.lineWidth = chosen ? 2 : 1
            thread.shadowColor = slot.cardView.color.cgColor
            thread.shadowOpacity = chosen ? 0.9 : 0
            thread.shadowRadius = 5
            thread.shadowOffset = .zero
        }
        for (paneId, thread) in tethers where !live.contains(paneId) {
            thread.removeFromSuperlayer()
            tethers.removeValue(forKey: paneId)
        }
    }

    private func updatePreview() {
        guard raised,
            let slot = slots.first(where: { $0.cardView.card.paneId == selectedPaneId })
        else {
            previewView.isHidden = true
            return
        }
        let card = slot.cardView.card
        previewView.show(
            card: card, screen: previewText?(card.paneId) ?? "", color: slot.cardView.color)
        let cardSize = NativeHandCardView.size
        var size = previewView.fittingSize
        size.width = min(max(size.width, 220), max(220, bounds.width - 16))
        let x = min(
            max(8, slot.restOrigin.x + cardSize.width / 2 - size.width / 2),
            max(8, bounds.width - size.width - 8))
        let y = min(
            slot.restOrigin.y + cardSize.height + 12, max(0, bounds.maxY - size.height - 8))
        previewView.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        previewView.isHidden = false
    }

    private func refreshLabels(now: Date) {
        if let until = allClearUntil, now < until, slots.isEmpty {
            handLabel.stringValue = "ALL CLEAR"
            handLabel.textColor = .systemGreen
        } else {
            allClearUntil = nil
            let deck = hand.deckCount > 0 ? "  +\(hand.deckCount)" : ""
            let running = hand.runningCount > 0 ? "  ·  RUNNING \(hand.runningCount)" : ""
            handLabel.stringValue = "HAND \(hand.cards.count)\(deck)\(running)"
            handLabel.textColor = .secondaryLabelColor
        }
        let combo = run.combo(now: now)
        if combo > 1 {
            statsLabel.stringValue = "×\(combo)"
            statsLabel.textColor = .systemOrange
        } else {
            statsLabel.stringValue =
                run.played == 0
                ? "⌘J plays the first card"
                : "PLAYED \(run.played) · BEST ×\(run.bestCombo)"
            statsLabel.textColor = .secondaryLabelColor
        }
        setAccessibilityLabel("Attention hand, \(hand.cards.count + hand.deckCount) cards")
    }

    private func configure() {
        // The counts are kept for VoiceOver; on screen the fan says it all,
        // and a line of text would lie over the panes' last row.
        for label in [handLabel, statsLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.isHidden = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        for host in [tetherHost, cardHost, effectsHost] {
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            host.wantsLayer = true
        }
        previewView.isHidden = true
        addSubview(handLabel)
        addSubview(statsLabel)
        addSubview(tetherHost)
        addSubview(cardHost)
        addSubview(effectsHost)
        addSubview(previewView)
        NSLayoutConstraint.activate([
            handLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            handLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            statsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            statsLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        refreshLabels(now: Date())
    }

    private func updateRefreshTimer() {
        let needsTimer = window != nil && !isHidden && (!slots.isEmpty || run.played > 0)
        guard needsTimer != (refreshTimer != nil) else {
            return
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard needsTimer else {
            return
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }
            let now = Date()
            for slot in self.slots {
                slot.cardView.refresh(now: now)
            }
            self.refreshLabels(now: now)
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }
}

func runNativeAttentionHandViewSelfTests() -> Bool {
    let base = Date()
    func card(_ paneId: Int, _ kind: NativeHandCardKind, _ title: String) -> NativeHandCard {
        NativeHandCard(
            tabId: paneId / 10, paneId: paneId, title: title, kind: kind,
            summary: "Run the migration?", since: base.addingTimeInterval(-150),
            revision: UInt64(paneId))
    }
    let view = NativeAttentionHandView(
        frame: NSRect(x: 0, y: 0, width: 900, height: NativeAttentionHandView.reach))
    var selected: NativeHandCard?
    view.onSelect = { selected = $0 }
    let cards = [card(11, .waiting, "api"), card(21, .failed, "web"), card(31, .done, "docs")]
    let art = [11: ["plan: 2 tables", "apply? (y/n)"]]
    var run = NativeHandRun()
    view.update(
        hand: NativeAttentionHand(cards: cards, deckCount: 2, runningCount: 1), art: art, run: run)
    view.layoutSubtreeIfNeeded()
    func slots() -> [NativeHandSlotView] {
        view.subviews.flatMap(\.subviews).compactMap { $0 as? NativeHandSlotView }
    }
    func labels() -> [String] {
        view.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
    }
    guard slots().map(\.cardView.card.paneId) == [11, 21, 31],
        labels() == ["HAND 3  +2  ·  RUNNING 1", "⌘J plays the first card"],
        slots()[0].cardView.accessibilityPerformPress(),
        selected?.paneId == 11,
        // Only the cards take the pointer: the middle one, not the panes beside it.
        view.hitTest(NSPoint(x: 450, y: 40)) === view,
        view.hitTest(NSPoint(x: 40, y: 10)) == nil,
        view.hitTest(NSPoint(x: 450, y: NativeAttentionHandView.reach - 2)) == nil
    else {
        return false
    }
    // The chosen card keeps the place it rose from under the pointer.
    view.openSelection(paneId: 21)
    let chosen = slots().first { $0.cardView.card.paneId == 21 }
    guard let risen = chosen?.frame,
        view.cardPaneId(at: NSPoint(x: risen.midX, y: risen.minY + 4)) == 21,
        view.cardPaneId(at: NSPoint(x: risen.midX, y: risen.minY - 30)) == 21
    else {
        return false
    }
    view.closeSelection()
    #if SATIN_SMOKE_SCENARIOS
        if let path = ProcessInfo.processInfo.environment["SATIN_HAND_SNAPSHOT"] {
            view.setRaised(true, animated: false)
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
            }
        }
    #endif
    run.play(now: Date())
    view.update(
        hand: NativeAttentionHand(cards: Array(cards.dropFirst()), deckCount: 0, runningCount: 0),
        art: [:],
        run: run, playedPaneId: 11)
    guard labels() == ["HAND 2", "PLAYED 1 · BEST ×1"] else {
        return false
    }
    run.play(now: Date())
    view.update(hand: .empty, art: [:], run: run, playedPaneId: 21)
    return labels() == ["ALL CLEAR", "×2"]
}
