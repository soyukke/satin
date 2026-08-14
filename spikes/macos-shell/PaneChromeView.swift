import AppKit

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

enum NativePaneChromeAction: Int, CaseIterable {
    case close
    case splitVertical
    case splitHorizontal

    var title: String {
        switch self {
        case .close: "Close Pane"
        case .splitVertical: "Split Left and Right"
        case .splitHorizontal: "Split Top and Bottom"
        }
    }

    var symbolName: String {
        switch self {
        case .close: "xmark"
        case .splitVertical: "rectangle.split.2x1"
        case .splitHorizontal: "rectangle.split.1x2"
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

    init(symbolName: String, title: String, supportsBadge: Bool = false) {
        self.supportsBadge = supportsBadge
        super.init(frame: .zero)
        configure(symbolName: symbolName, title: title)
    }

    required init?(coder: NSCoder) {
        nil
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
        drawBadge()
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
    }

    private func drawBadge() {
        guard badgeCount > 0 else {
            return
        }
        let value = badgeCount > 9 ? "9+" : String(badgeCount)
        let font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (value as NSString).size(withAttributes: attributes)
        let height: CGFloat = 11
        let width = max(height, ceil(textSize.width) + 5)
        let inset: CGFloat = 1
        let badgeRect = NSRect(
            x: bounds.maxX - width - inset,
            y: isFlipped ? bounds.minY + inset : bounds.maxY - height - inset,
            width: width,
            height: height
        )
        NSColor.systemRed.setFill()
        NSBezierPath(
            roundedRect: badgeRect,
            xRadius: height / 2,
            yRadius: height / 2
        ).fill()
        (value as NSString).draw(
            at: NSPoint(
                x: badgeRect.midX - textSize.width / 2,
                y: badgeRect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
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
        if pressing {
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

final class NativePaneChromeView: NSView {
    static let buttonWidth: CGFloat = 22
    static let buttonSpacing: CGFloat = 1
    static let controlHeight: CGFloat = 22
    let paneId: Int
    var onAction: ((NativePaneChromeAction, Int, NSView) -> Void)?

    private let actions: [NativePaneChromeAction]
    private var buttons: [NativePaneChromeAction: NativeHoverIconButton] = [:]
    private var active = true

    init(paneId: Int, actions: [NativePaneChromeAction] = NativePaneChromeAction.allCases) {
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
        let buttonWidth = max(1, (bounds.width - spacingWidth) / count)
        for (index, action) in actions.enumerated() {
            buttons[action]?.frame = NSRect(
                x: CGFloat(index) * (buttonWidth + Self.buttonSpacing),
                y: 0,
                width: buttonWidth,
                height: bounds.height
            )
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

    func actionsReady() -> Bool {
        buttons.count == actions.count
            && actions.allSatisfy {
                buttons[$0]?.image != nil && buttons[$0]?.isBordered == false
            }
    }

    var preferredWidth: CGFloat {
        Self.buttonWidth * CGFloat(actions.count)
            + Self.buttonSpacing * CGFloat(max(0, actions.count - 1))
    }

    func performForSmoke(_ action: NativePaneChromeAction) {
        onAction?(action, paneId, buttons[action] ?? self)
    }

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
    }

    @objc private func actionClicked(_ sender: NativeHoverIconButton) {
        guard let action = NativePaneChromeAction(rawValue: sender.tag) else {
            return
        }
        onAction?(action, paneId, sender)
    }
}
