import AppKit

private final class NativeBadgeLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

let nativePaneChromeHeight: CGFloat = 24

func nativePaneContentFrame(_ paneFrame: NSRect) -> NSRect {
    let chromeHeight = min(nativePaneChromeHeight, max(0, paneFrame.height - 1))
    return NSRect(
        x: paneFrame.minX,
        y: paneFrame.minY + chromeHeight,
        width: paneFrame.width,
        height: max(1, paneFrame.height - chromeHeight)
    )
}

enum NativePaneChromeAction: Int {
    case close
    case splitVertical
    case splitHorizontal
    case openInFinder

    static let standardActions: [Self] = [
        .splitVertical,
        .splitHorizontal,
        .openInFinder,
        .close,
    ]

    var title: String {
        switch self {
        case .close: "Close Pane"
        case .splitVertical: "Split Left and Right"
        case .splitHorizontal: "Split Top and Bottom"
        case .openInFinder: "Open Pane Directory in Finder"
        }
    }

    var symbolName: String {
        switch self {
        case .close: "xmark"
        case .splitVertical: "rectangle.split.2x1"
        case .splitHorizontal: "rectangle.split.1x2"
        case .openInFinder: "folder"
        }
    }
}

final class NativeHoverIconButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var hovering = false
    private var pressing = false
    private var emphasized = true
    private var badgeCount = 0
    private var baseTitle = ""
    private var supportsBadge = false
    private var badgeLabel: NativeBadgeLabel?

    init(symbolName: String, title: String, supportsBadge: Bool = false) {
        self.supportsBadge = supportsBadge
        super.init(frame: .zero)
        configure(symbolName: symbolName, title: title)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isEnabled: Bool {
        didSet {
            updateHoverAppearance()
        }
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        guard supportsBadge else {
            return size
        }
        return NSSize(width: max(size.width, 26), height: max(size.height, 22))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        hoverTrackingArea = next
    }

    override func draw(_ dirtyRect: NSRect) {
        if let hoverColor {
            hoverColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                xRadius: 5,
                yRadius: 5
            ).fill()
        }
        super.draw(dirtyRect)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateHoverAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateHoverAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        updateHoverAppearance()
        super.mouseDown(with: event)
        pressing = false
        updateHoverAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverAppearance()
    }

    func setEmphasized(_ emphasized: Bool) {
        guard self.emphasized != emphasized else {
            return
        }
        self.emphasized = emphasized
        updateHoverAppearance()
    }

    func setBadgeCount(_ count: Int) {
        let count = max(0, count)
        guard badgeCount != count else {
            return
        }
        badgeCount = count
        badgeLabel?.stringValue = count > 9 ? "9+" : String(count)
        badgeLabel?.isHidden = count == 0
        toolTip = count == 0 ? baseTitle : "\(baseTitle) — \(count) need attention"
        setAccessibilityValue(
            count == 0 ? "No items need attention" : "\(count) items need attention"
        )
        needsDisplay = true
    }

    func badgeCountForSmoke() -> Int {
        badgeCount
    }

    private func configure(symbolName: String, title: String) {
        baseTitle = title
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        wantsLayer = true
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: title
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
        self.image = image
        contentTintColor = .secondaryLabelColor
        toolTip = title
        setAccessibilityLabel(title)
        guard supportsBadge else {
            return
        }
        let label = NativeBadgeLabel(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 8, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.systemRed.cgColor
        label.layer?.cornerRadius = 6
        label.layer?.masksToBounds = true
        label.isHidden = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
            label.heightAnchor.constraint(equalToConstant: 12),
        ])
        badgeLabel = label
    }

    private var hoverColor: NSColor? {
        if pressing {
            return NSColor.controlAccentColor.withAlphaComponent(0.3)
        }
        if hovering {
            return NSColor.labelColor.withAlphaComponent(0.18)
        }
        return nil
    }

    private func updateHoverAppearance() {
        if !isEnabled {
            contentTintColor = .quaternaryLabelColor
        } else if pressing {
            contentTintColor = .controlAccentColor
        } else if hovering {
            contentTintColor = .labelColor
        } else if emphasized {
            contentTintColor = .secondaryLabelColor
        } else {
            contentTintColor = .tertiaryLabelColor
        }
        needsDisplay = true
    }
}

enum NativePaneChromeDragPhase {
    case began
    case changed
    case ended
    case cancelled
}

final class NativePaneChromeView: NSView {
    static let buttonWidth: CGFloat = 22
    static let buttonSpacing: CGFloat = 1
    static let controlHeight: CGFloat = 22
    static let dragThreshold: CGFloat = 4
    let paneId: Int
    var onAction: ((NativePaneChromeAction, Int, NSView) -> Void)?
    var onPress: ((Int) -> Void)?
    var onDrag: ((NativePaneChromeDragPhase, Int, NSPoint) -> Bool)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?
    var onAvailabilityRefresh: ((Int) -> Void)?

    private let actions: [NativePaneChromeAction]
    private var buttons: [NativePaneChromeAction: NativeHoverIconButton] = [:]
    private var active = true
    private var draggable = false
    private var hoverTrackingArea: NSTrackingArea?
    private var hoveringHandle = false
    private var mouseDownLocation: NSPoint?
    private var dragging = false

    init(
        paneId: Int,
        actions: [NativePaneChromeAction] = NativePaneChromeAction.standardActions
    ) {
        self.paneId = paneId
        self.actions = actions
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        let count = CGFloat(actions.count)
        let spacingWidth = Self.buttonSpacing * max(0, count - 1)
        let actionWidth = min(preferredWidth, bounds.width)
        let buttonWidth = max(1, (actionWidth - spacingWidth) / count)
        let actionOrigin = bounds.maxX - actionWidth
        for (index, action) in actions.enumerated() {
            buttons[action]?.frame = NSRect(
                x: actionOrigin + CGFloat(index) * (buttonWidth + Self.buttonSpacing),
                y: 0,
                width: buttonWidth,
                height: bounds.height
            )
        }
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard draggable, dragHandleRect.width >= 18 else {
            return
        }
        if hoveringHandle || dragging {
            let color = dragging ? NSColor.controlAccentColor : NSColor.labelColor
            color.withAlphaComponent(dragging ? 0.18 : 0.08).setFill()
            NSBezierPath(
                roundedRect: dragHandleRect.insetBy(dx: 1, dy: 1),
                xRadius: 5,
                yRadius: 5
            ).fill()
        }
        drawGrip()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        hoverTrackingArea = next
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if draggable, !dragHandleRect.isEmpty {
            addCursorRect(dragHandleRect, cursor: dragging ? .closedHand : .openHand)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onAvailabilityRefresh?(paneId)
        updateHandleHover(event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHandleHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard !dragging else {
            return
        }
        hoveringHandle = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard dragHandleRect.contains(point) else {
            super.mouseDown(with: event)
            return
        }
        onPress?(paneId)
        guard draggable else {
            return
        }
        mouseDownLocation = event.locationInWindow
        dragging = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownLocation else {
            return
        }
        let point = event.locationInWindow
        let distance = hypot(point.x - mouseDownLocation.x, point.y - mouseDownLocation.y)
        guard dragging || distance >= Self.dragThreshold else {
            return
        }
        if !dragging {
            dragging = true
            guard onDrag?(.began, paneId, mouseDownLocation) == true else {
                resetDragState()
                return
            }
        }
        NSCursor.closedHand.set()
        _ = onDrag?(.changed, paneId, point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            _ = onDrag?(.ended, paneId, event.locationInWindow)
        }
        resetDragState()
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event, self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, dragging {
            _ = onDrag?(.cancelled, paneId, .zero)
            resetDragState()
        }
    }

    func update(isActive: Bool) {
        guard active != isActive else {
            return
        }
        active = isActive
        for button in buttons.values {
            button.setEmphasized(isActive)
        }
    }

    func update(isDraggable: Bool) {
        guard draggable != isDraggable else {
            return
        }
        draggable = isDraggable
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func actionsReady() -> Bool {
        buttons.count == actions.count
            && actions.allSatisfy {
                buttons[$0]?.image != nil && buttons[$0]?.isBordered == false
            }
    }

    func update(action: NativePaneChromeAction, isEnabled: Bool) {
        buttons[action]?.isEnabled = isEnabled
    }

    var preferredWidth: CGFloat {
        Self.buttonWidth * CGFloat(actions.count)
            + Self.buttonSpacing * CGFloat(max(0, actions.count - 1))
    }

    func performForSmoke(_ action: NativePaneChromeAction) {
        onAction?(action, paneId, buttons[action] ?? self)
    }

    #if SATIN_SMOKE_SCENARIOS
        func actionEnabledForSmoke(_ action: NativePaneChromeAction) -> Bool {
            buttons[action]?.isEnabled == true
        }

        func finderPresentationReadyForSmoke() -> Bool {
            guard let button = buttons[.openInFinder] else {
                return false
            }
            let originalActive = active
            update(isActive: false)
            let inactiveReady =
                !button.isHidden
                && button.contentTintColor?.isEqual(
                    buttons[.splitVertical]?.contentTintColor
                ) == true
            update(isActive: true)
            let activeReady =
                !button.isHidden
                && button.contentTintColor?.isEqual(
                    buttons[.splitVertical]?.contentTintColor
                ) == true
            update(isActive: originalActive)
            return inactiveReady && activeReady
                && button.toolTip == NativePaneChromeAction.openInFinder.title
        }

        func dragHandleReadyForSmoke() -> Bool {
            draggable && dragHandleRect.width >= 18 && onDrag != nil && onPress != nil
        }

        @discardableResult
        func simulateDragForSmoke(
            from start: NSPoint,
            to end: NSPoint,
            verifyPreview: (() -> Bool)? = nil
        ) -> Bool {
            guard dragHandleReadyForSmoke() else {
                return false
            }
            onPress?(paneId)
            guard onDrag?(.began, paneId, start) == true else {
                return false
            }
            _ = onDrag?(.changed, paneId, end)
            guard verifyPreview?() ?? true else {
                _ = onDrag?(.cancelled, paneId, end)
                return false
            }
            return onDrag?(.ended, paneId, end) == true
        }
    #endif

    private func configure() {
        for action in actions {
            let button = NativeHoverIconButton(
                symbolName: action.symbolName,
                title: action.title
            )
            button.tag = action.rawValue
            button.target = self
            button.action = #selector(actionClicked(_:))
            buttons[action] = button
            addSubview(button)
        }
        update(isActive: false)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pane \(paneId) header")
        setAccessibilityHelp(
            "Drag the header to move this pane, or use its split, Finder, and close actions."
        )
    }

    @objc private func actionClicked(_ sender: NativeHoverIconButton) {
        guard let action = NativePaneChromeAction(rawValue: sender.tag) else {
            return
        }
        onAction?(action, paneId, sender)
    }

    private var dragHandleRect: NSRect {
        let width = max(0, bounds.width - min(preferredWidth, bounds.width) - 4)
        return NSRect(x: 0, y: 0, width: width, height: bounds.height)
    }

    private func drawGrip() {
        let gripColor = active ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        gripColor.withAlphaComponent(hoveringHandle || dragging ? 0.95 : 0.72).setFill()
        let origin = NSPoint(x: 8, y: bounds.midY - 4)
        for row in 0..<3 {
            for column in 0..<2 {
                NSBezierPath(
                    ovalIn: NSRect(
                        x: origin.x + CGFloat(column) * 4,
                        y: origin.y + CGFloat(row) * 4,
                        width: 2,
                        height: 2
                    )
                ).fill()
            }
        }
    }

    private func updateHandleHover(_ event: NSEvent) {
        let next = draggable && dragHandleRect.contains(convert(event.locationInWindow, from: nil))
        guard next != hoveringHandle else {
            return
        }
        hoveringHandle = next
        needsDisplay = true
    }

    private func resetDragState() {
        mouseDownLocation = nil
        dragging = false
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
}
