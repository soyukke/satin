import AppKit
import Foundation

/// How panes inside a window are presented: tiled splits or browser-style tabs.
enum NativePaneDisplayMode: String, CaseIterable {
    case split
    case tab

    var title: String {
        switch self {
        case .split: "Split"
        case .tab: "Tab"
        }
    }

    var toggled: Self {
        self == .split ? .tab : .split
    }
}

let nativePaneTabBarHeight: CGFloat = 30

func nativePaneTabContentRect(_ workspaceRect: NSRect) -> NSRect {
    let barHeight = min(nativePaneTabBarHeight, max(0, workspaceRect.height - 1))
    return NSRect(
        x: workspaceRect.minX,
        y: workspaceRect.minY + barHeight,
        width: workspaceRect.width,
        height: max(1, workspaceRect.height - barHeight)
    )
}

/// Short directory name shown on pane tabs (`~` for the user's home directory).
func nativeShortDirectoryName(_ path: String?, home: String = NSHomeDirectory()) -> String {
    guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return ""
    }
    let standardized = URL(fileURLWithPath: raw).standardizedFileURL.path
    let normalizedHome = URL(fileURLWithPath: home).standardizedFileURL.path
    if standardized == normalizedHome {
        return "~"
    }
    if standardized == "/" {
        return "/"
    }
    return URL(fileURLWithPath: standardized).lastPathComponent
}

/// Derives the primary title and short working-directory label for a pane tab.
func nativePaneTabTitle(
    paneTitle: String?,
    currentCommand: String?,
    directory: String?,
    mode: NativePaneMode,
    home: String = NSHomeDirectory()
) -> (title: String, directoryName: String) {
    let directoryName = nativeShortDirectoryName(directory, home: home)
    let cleanedTitle = paneTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let cleanedCommand = currentCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if mode == .neovim {
        return ("Neovim", directoryName)
    }
    if !cleanedTitle.isEmpty {
        return (cleanedTitle, directoryName)
    }
    if !cleanedCommand.isEmpty {
        return (cleanedCommand, directoryName)
    }
    if !directoryName.isEmpty {
        return (directoryName, directoryName)
    }
    return ("Terminal", "")
}

/// One pane entry rendered in the browser-style pane tab bar.
struct NativePaneTabItem: Equatable {
    let paneId: Int
    let index: Int
    let title: String
    let directoryName: String
    let fullDirectory: String
    let worktreeBranch: String?
    let status: NativeTabStatusBadge?
    let isActive: Bool

    var shortcutDigit: Int? {
        (0..<9).contains(index) ? index + 1 : nil
    }

    var secondaryLabel: String? {
        if let worktreeBranch, !worktreeBranch.isEmpty {
            return worktreeBranch
        }
        guard !directoryName.isEmpty,
            !title.localizedCaseInsensitiveContains(directoryName)
        else {
            return nil
        }
        return directoryName
    }
}

/// Browser-style pane tab strip shown across the top of the workspace in Tab
/// pane mode, even when the window holds only a single pane.
final class NativePaneTabBarView: NSView {
    private enum Metrics {
        static let leadingInset: CGFloat = 6
        static let trailingInset: CGFloat = 6
        static let tabGap: CGFloat = 2
        static let minTabWidth: CGFloat = 92
        static let maxTabWidth: CGFloat = 220
        static let tabTopInset: CGFloat = 3
        static let tabCornerRadius: CGFloat = 7
        static let buttonWidth: CGFloat = 24
        static let buttonHeight: CGFloat = 22
        static let buttonSpacing: CGFloat = 2
        static let closeSize: CGFloat = 18
        static let closeGlyphSize: CGFloat = 6.5
    }

    enum HitTarget: Equatable {
        case tab(Int)
        case close(Int)
        case background
    }

    var onSelectPane: ((Int) -> Void)?
    var onClosePane: ((Int) -> Void)?
    var onNewPane: (() -> Void)?
    var onAction: ((NativePaneChromeAction, NSView) -> Void)?
    var onContextMenu: ((Int, NSEvent, NSView) -> Void)?

    private(set) var items: [NativePaneTabItem] = []
    var showsShortcuts = false {
        didSet {
            if showsShortcuts != oldValue {
                needsDisplay = true
            }
        }
    }

    private let newPaneButton = NativeHoverIconButton(symbolName: "plus", title: "New Pane")
    private let newWorktreeButton = NativeHoverIconButton(
        symbolName: NativePaneChromeAction.newWorktree.symbolName,
        title: NativePaneChromeAction.newWorktree.title
    )
    private let openInFinderButton = NativeHoverIconButton(
        symbolName: NativePaneChromeAction.openInFinder.symbolName,
        title: NativePaneChromeAction.openInFinder.title
    )
    private let splitModeButton = NativeHoverIconButton(
        symbolName: NativePaneChromeAction.togglePaneDisplayMode.symbolName,
        title: "Switch to Split Panes"
    )

    private var hoverTrackingArea: NSTrackingArea?
    private var hoveredTabIndex: Int?
    private var hoveredCloseIndex: Int?
    private var pressedTabIndex: Int?
    private var scrollOffset: CGFloat = 0
    private var tabRects: [NSRect] = []
    private var tabsViewportRect = NSRect.zero
    private var activityTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureButtons()
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Pane Tabs")
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        activityTimer?.invalidate()
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateActivityTimer()
    }

    func update(items: [NativePaneTabItem]) {
        guard items != self.items else {
            return
        }
        let previousActive = self.items.first(where: \.isActive)?.paneId
        self.items = items
        if let hoveredTabIndex, hoveredTabIndex >= items.count {
            self.hoveredTabIndex = nil
            self.hoveredCloseIndex = nil
        }
        if let pressedTabIndex, pressedTabIndex >= items.count {
            self.pressedTabIndex = nil
        }
        recomputeLayout()
        if let activeIndex = items.firstIndex(where: \.isActive),
            items[activeIndex].paneId != previousActive
        {
            ensureTabVisible(at: activeIndex)
            recomputeLayout()
        }
        updateActivityTimer()
        updateTooltip(for: hoveredTabIndex)
        needsDisplay = true
    }

    func update(action: NativePaneChromeAction, isEnabled: Bool) {
        switch action {
        case .newWorktree:
            newWorktreeButton.isEnabled = isEnabled
        case .openInFinder:
            openInFinderButton.isEnabled = isEnabled
        default:
            break
        }
    }

    func refreshLook() {
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        recomputeLayout()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredTabIndex = nil
        hoveredCloseIndex = nil
        toolTip = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch hitTarget(at: point) {
        case .close(let index):
            pressedTabIndex = nil
            if items.indices.contains(index) {
                onClosePane?(items[index].paneId)
            }
        case .tab(let index):
            pressedTabIndex = index
            needsDisplay = true
        case .background:
            pressedTabIndex = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            if pressedTabIndex != nil {
                pressedTabIndex = nil
                needsDisplay = true
            }
        }
        guard let pressed = pressedTabIndex else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if case .tab(let index) = hitTarget(at: point),
            index == pressed,
            items.indices.contains(index)
        {
            onSelectPane?(items[index].paneId)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if case .tab(let index) = hitTarget(at: point), items.indices.contains(index) {
            onContextMenu?(items[index].paneId, event, self)
            return
        }
        if let active = items.first(where: \.isActive) {
            onContextMenu?(active.paneId, event, self)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta =
            abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? -event.scrollingDeltaX
            : -event.scrollingDeltaY
        let maxOffset = maximumScrollOffset()
        guard maxOffset > 0, delta != 0 else {
            return
        }
        let next = min(max(scrollOffset + delta, 0), maxOffset)
        if abs(next - scrollOffset) > 0.5 {
            scrollOffset = next
            recomputeLayout()
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBarBackground()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: tabsViewportRect).addClip()
        for (index, item) in items.enumerated() where index < tabRects.count {
            let rect = tabRects[index]
            if rect.maxX < tabsViewportRect.minX || rect.minX > tabsViewportRect.maxX {
                continue
            }
            drawTab(item, at: index, in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        drawBarBaseline()
        drawTrailingSeparator()
    }

    func hitTarget(at point: NSPoint) -> HitTarget {
        guard tabsViewportRect.contains(point) else {
            return .background
        }
        for (index, rect) in tabRects.enumerated() where rect.contains(point) {
            if closeButtonRect(for: rect).contains(point) {
                return .close(index)
            }
            return .tab(index)
        }
        return .background
    }

    func tabRect(at index: Int) -> NSRect? {
        tabRects.indices.contains(index) ? tabRects[index] : nil
    }

    func closeRect(at index: Int) -> NSRect? {
        tabRect(at: index).map(closeButtonRect(for:))
    }

    private func configureButtons() {
        newPaneButton.target = self
        newPaneButton.action = #selector(newPaneClicked)
        newWorktreeButton.target = self
        newWorktreeButton.action = #selector(newWorktreeClicked)
        openInFinderButton.target = self
        openInFinderButton.action = #selector(openInFinderClicked)
        splitModeButton.target = self
        splitModeButton.action = #selector(splitModeClicked)
        splitModeButton.toolTip = "Switch to Split Panes (⌥⌘T)"
        for button in [newPaneButton, newWorktreeButton, openInFinderButton, splitModeButton] {
            addSubview(button)
        }
    }

    @objc private func newPaneClicked() {
        onNewPane?()
    }

    @objc private func newWorktreeClicked() {
        onAction?(.newWorktree, newWorktreeButton)
    }

    @objc private func openInFinderClicked() {
        onAction?(.openInFinder, openInFinderButton)
    }

    @objc private func splitModeClicked() {
        onAction?(.togglePaneDisplayMode, splitModeButton)
    }

    private var trailingButtons: [NativeHoverIconButton] {
        [newWorktreeButton, openInFinderButton, splitModeButton]
    }

    private func recomputeLayout() {
        let buttonY = floor((bounds.height - Metrics.buttonHeight) / 2)
        let trailingCount = CGFloat(trailingButtons.count)
        let trailingButtonsWidth =
            trailingCount * Metrics.buttonWidth
            + max(0, trailingCount - 1) * Metrics.buttonSpacing
        let trailingStartX = max(
            Metrics.leadingInset,
            bounds.width - Metrics.trailingInset - trailingButtonsWidth
        )
        for (idx, button) in trailingButtons.enumerated() {
            button.frame = NSRect(
                x: trailingStartX + CGFloat(idx) * (Metrics.buttonWidth + Metrics.buttonSpacing),
                y: buttonY,
                width: Metrics.buttonWidth,
                height: Metrics.buttonHeight
            )
        }

        let separatorReserve: CGFloat = 10
        let newButtonReserve = Metrics.buttonWidth + 8
        let viewportWidth = max(
            0, trailingStartX - separatorReserve - newButtonReserve - Metrics.leadingInset)
        tabsViewportRect = NSRect(
            x: Metrics.leadingInset,
            y: 0,
            width: viewportWidth,
            height: bounds.height
        )

        let tabWidth = computedTabWidth(in: viewportWidth)
        let totalWidth = totalTabsWidth(tabWidth: tabWidth)
        scrollOffset = min(max(0, scrollOffset), max(0, totalWidth - viewportWidth))

        var rects: [NSRect] = []
        rects.reserveCapacity(items.count)
        let tabHeight = max(1, bounds.height - Metrics.tabTopInset)
        for index in items.indices {
            let x =
                tabsViewportRect.minX + CGFloat(index) * (tabWidth + Metrics.tabGap) - scrollOffset
            rects.append(
                NSRect(x: x, y: Metrics.tabTopInset, width: tabWidth, height: tabHeight)
            )
        }
        tabRects = rects

        let tabsRightEdge = min(
            tabsViewportRect.maxX,
            tabsViewportRect.minX + totalWidth
        )
        let newX = min(
            tabsRightEdge + (items.isEmpty ? 0 : 4),
            trailingStartX - separatorReserve - Metrics.buttonWidth
        )
        newPaneButton.frame = NSRect(
            x: max(Metrics.leadingInset, newX),
            y: buttonY,
            width: Metrics.buttonWidth,
            height: Metrics.buttonHeight
        )
    }

    private func computedTabWidth(in viewportWidth: CGFloat) -> CGFloat {
        guard !items.isEmpty, viewportWidth > 0 else {
            return Metrics.minTabWidth
        }
        let count = CGFloat(items.count)
        let available = viewportWidth - Metrics.tabGap * max(0, count - 1)
        return min(Metrics.maxTabWidth, max(Metrics.minTabWidth, floor(available / count)))
    }

    private func totalTabsWidth(tabWidth: CGFloat) -> CGFloat {
        guard !items.isEmpty else {
            return 0
        }
        return CGFloat(items.count) * tabWidth
            + CGFloat(max(0, items.count - 1)) * Metrics.tabGap
    }

    private func maximumScrollOffset() -> CGFloat {
        let tabWidth = computedTabWidth(in: tabsViewportRect.width)
        return max(0, totalTabsWidth(tabWidth: tabWidth) - tabsViewportRect.width)
    }

    private func ensureTabVisible(at index: Int) {
        guard tabRects.indices.contains(index) else {
            return
        }
        let rect = tabRects[index]
        if rect.minX < tabsViewportRect.minX {
            scrollOffset = max(0, scrollOffset - (tabsViewportRect.minX - rect.minX))
        } else if rect.maxX > tabsViewportRect.maxX {
            scrollOffset = min(
                maximumScrollOffset(), scrollOffset + (rect.maxX - tabsViewportRect.maxX))
        }
    }

    private func closeButtonRect(for tabRect: NSRect) -> NSRect {
        NSRect(
            x: tabRect.maxX - Metrics.closeSize - 4,
            y: floor(tabRect.midY - Metrics.closeSize / 2),
            width: Metrics.closeSize,
            height: Metrics.closeSize
        )
    }

    private func updateHover(at point: NSPoint) {
        let nextTab: Int?
        let nextClose: Int?
        switch hitTarget(at: point) {
        case .tab(let index):
            nextTab = index
            nextClose = nil
        case .close(let index):
            nextTab = index
            nextClose = index
        case .background:
            nextTab = nil
            nextClose = nil
        }
        guard nextTab != hoveredTabIndex || nextClose != hoveredCloseIndex else {
            return
        }
        hoveredTabIndex = nextTab
        hoveredCloseIndex = nextClose
        updateTooltip(for: nextTab)
        needsDisplay = true
    }

    private func updateTooltip(for index: Int?) {
        guard let index, items.indices.contains(index) else {
            toolTip = nil
            return
        }
        let item = items[index]
        var lines = [item.title]
        if !item.fullDirectory.isEmpty {
            lines.append(item.fullDirectory)
        }
        if let branch = item.worktreeBranch, !branch.isEmpty {
            lines.append("Worktree: \(branch)")
        }
        if let status = item.status {
            lines.append("Status: \(status.toolTipDescription)")
        }
        toolTip = lines.joined(separator: "\n")
    }

    private func updateActivityTimer() {
        activityTimer?.invalidate()
        activityTimer = nil
        guard window != nil, items.contains(where: { $0.status == .running }) else {
            return
        }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        activityTimer = timer
    }

    private func drawBarBackground() {
        switch NativePageStyle.mode {
        case .terminal:
            NativePageStyle.rgb(15, 13, 25).setFill()
        case .light:
            NativePageStyle.raised.setFill()
        case .paper:
            NativePageStyle.raised.setFill()
        }
        bounds.fill()
    }

    private func drawBarBaseline() {
        let activeRect = items.firstIndex(where: \.isActive).flatMap { index -> NSRect? in
            guard tabRects.indices.contains(index) else { return nil }
            let clipped = tabRects[index].intersection(tabsViewportRect)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }
        let thickness: CGFloat = NativePageStyle.paper ? 2 : 1
        let y = bounds.maxY - thickness
        let color: NSColor =
            NativePageStyle.paper ? NativePageStyle.text : NativePageStyle.line
        color.setFill()
        if let activeRect {
            if activeRect.minX > bounds.minX {
                NSRect(
                    x: bounds.minX, y: y, width: activeRect.minX - bounds.minX, height: thickness
                )
                .fill()
            }
            if activeRect.maxX < bounds.maxX {
                NSRect(
                    x: activeRect.maxX, y: y, width: bounds.maxX - activeRect.maxX,
                    height: thickness
                ).fill()
            }
        } else {
            NSRect(x: bounds.minX, y: y, width: bounds.width, height: thickness).fill()
        }
    }

    private func drawTrailingSeparator() {
        guard let firstButton = trailingButtons.first else {
            return
        }
        let x = firstButton.frame.minX - 5
        NativePageStyle.line.setFill()
        NSRect(x: x, y: 6, width: 1, height: max(0, bounds.height - 12)).fill()
    }

    private func tabOutlinePath(_ rect: NSRect) -> NSBezierPath {
        let radius = min(Metrics.tabCornerRadius, rect.width / 2, rect.height / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(
            from: NSPoint(x: rect.minX, y: rect.minY),
            to: NSPoint(x: rect.minX + radius, y: rect.minY),
            radius: radius
        )
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(
            from: NSPoint(x: rect.maxX, y: rect.minY),
            to: NSPoint(x: rect.maxX, y: rect.minY + radius),
            radius: radius
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        return path
    }

    private func drawTab(_ item: NativePaneTabItem, at index: Int, in rect: NSRect) {
        let isHovered = hoveredTabIndex == index
        let isPressed = pressedTabIndex == index
        let mode = NativePageStyle.mode
        let shape = tabOutlinePath(rect.insetBy(dx: 0.5, dy: 0))
        let fillPath = shape.copy() as? NSBezierPath ?? shape
        fillPath.close()

        switch mode {
        case .paper:
            let fill = item.isActive ? NativePageStyle.surface : NativePageStyle.rgb(230, 219, 195)
            fill.setFill()
            fillPath.fill()
            if !item.isActive && (isHovered || isPressed) {
                NativePageStyle.text.withAlphaComponent(isPressed ? 0.10 : 0.05).setFill()
                fillPath.fill()
            }
            (item.isActive ? NativePageStyle.text : NativePageStyle.rgb(184, 171, 146)).setStroke()
            shape.lineWidth = item.isActive ? 2 : 1
            shape.stroke()
        case .light:
            if item.isActive {
                NativePageStyle.surface.setFill()
                fillPath.fill()
                NativePageStyle.line.setStroke()
                shape.lineWidth = 1
                shape.stroke()
            } else if isHovered || isPressed {
                NativePageStyle.text.withAlphaComponent(isPressed ? 0.09 : 0.05).setFill()
                fillPath.fill()
            }
        case .terminal:
            if item.isActive {
                NativePageStyle.raised.setFill()
                fillPath.fill()
                NativePageStyle.violet.withAlphaComponent(0.10).setFill()
                fillPath.fill()
                NativePageStyle.violet.withAlphaComponent(0.65).setStroke()
                shape.lineWidth = 1
                shape.stroke()
            } else if isHovered || isPressed {
                NSColor.white.withAlphaComponent(isPressed ? 0.10 : 0.06).setFill()
                fillPath.fill()
            }
        }

        if mode != .paper, !item.isActive, index + 1 < items.count, !items[index + 1].isActive {
            NativePageStyle.line.withAlphaComponent(0.6).setFill()
            NSRect(x: rect.maxX + 0.5, y: rect.minY + 6, width: 1, height: max(0, rect.height - 12))
                .fill()
        }

        var contentLeft = rect.minX + 8
        let closeRect = closeButtonRect(for: rect)
        let showsClose = item.isActive || isHovered || isPressed
        let contentRight = showsClose ? closeRect.minX - 4 : rect.maxX - 8

        if showsShortcuts, let digit = item.shortcutDigit {
            let pillWidth: CGFloat = 17
            let pillHeight: CGFloat = 16
            let pillRect = NSRect(
                x: contentLeft,
                y: floor(rect.midY - pillHeight / 2),
                width: pillWidth,
                height: pillHeight
            )
            let pillFill: NSColor =
                mode == .terminal ? .white : NativePageStyle.violet
            let pillText: NSColor =
                mode == .terminal ? .black : .white
            pillFill.setFill()
            NSBezierPath(
                roundedRect: pillRect, xRadius: mode == .paper ? 3 : 4,
                yRadius: mode == .paper ? 3 : 4
            ).fill()
            NativeSidebarLook.text(
                "\(digit)",
                font: NativePageStyle.mono(10.5, .bold),
                color: pillText,
                alignment: .center
            ).draw(in: pillRect.offsetBy(dx: 0, dy: 1))
            contentLeft = pillRect.maxX + 6
        } else if let badge = item.status {
            NativeTabStatusBadgeRenderer.draw(
                badge,
                center: NSPoint(x: contentLeft + 5, y: rect.midY),
                selected: item.isActive
            )
            contentLeft += 15
        }

        let availableWidth = max(0, contentRight - contentLeft)
        if availableWidth > 8 {
            drawTabLabels(item, x: contentLeft, width: availableWidth, midY: rect.midY)
        }
        if showsClose {
            drawCloseButton(
                in: closeRect, active: item.isActive, hovered: hoveredCloseIndex == index)
        }
    }

    private func drawTabLabels(_ item: NativePaneTabItem, x: CGFloat, width: CGFloat, midY: CGFloat)
    {
        let titleColor: NSColor =
            item.isActive
            ? NativePageStyle.text
            : (hoveredTabIndex == item.index
                ? NativePageStyle.text.withAlphaComponent(0.85) : NativePageStyle.muted)
        let titleFont = NativePageStyle.sans(11.5, item.isActive ? .semibold : .medium)
        let titleString = NativeSidebarLook.text(item.title, font: titleFont, color: titleColor)
        let titleSize = titleString.size()

        if let secondary = item.secondaryLabel, width >= 112 {
            let isWorktree = item.worktreeBranch != nil
            let secondaryPrefix = isWorktree ? "⎇ " : "· "
            let secondaryColor =
                isWorktree ? NativePageStyle.teal : NativePageStyle.muted.withAlphaComponent(0.85)
            let secondaryFont = NativePageStyle.sans(10.5, isWorktree ? .medium : .regular)
            let secondaryText = NativeSidebarLook.text(
                secondaryPrefix + secondary, font: secondaryFont, color: secondaryColor)
            let secondaryWidth = min(ceil(secondaryText.size().width), width * 0.42)
            let titleWidth = min(ceil(titleSize.width), max(24, width - secondaryWidth - 5))
            titleString.draw(
                in: NSRect(
                    x: x, y: floor(midY - titleSize.height / 2), width: titleWidth,
                    height: ceil(titleSize.height)))
            let secSize = secondaryText.size()
            secondaryText.draw(
                in: NSRect(
                    x: x + titleWidth + 5, y: floor(midY - secSize.height / 2),
                    width: max(0, width - titleWidth - 5), height: ceil(secSize.height)))
        } else {
            titleString.draw(
                in: NSRect(
                    x: x, y: floor(midY - titleSize.height / 2), width: width,
                    height: ceil(titleSize.height)))
        }
    }

    private func drawCloseButton(in rect: NSRect, active: Bool, hovered: Bool) {
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        let half = Metrics.closeGlyphSize / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x - half, y: center.y - half))
        path.line(to: NSPoint(x: center.x + half, y: center.y + half))
        path.move(to: NSPoint(x: center.x - half, y: center.y + half))
        path.line(to: NSPoint(x: center.x + half, y: center.y - half))
        path.lineWidth = 1.35
        path.lineCapStyle = .round
        let baseColor = active ? NativePageStyle.text : NativePageStyle.muted
        baseColor.withAlphaComponent(hovered ? 0.95 : (active ? 0.72 : 0.58)).setStroke()
        path.stroke()
    }
}

/// Transition produced by the double-tap-hold `⌘` pane-tab shortcut guide.
enum NativeCommandDoubleTapTransition: Equatable {
    case none
    case showPaneShortcuts
    case hidePaneShortcuts
    case selectPaneShortcut(Int)
}

/// Detects tapping `⌘` once and immediately pressing and holding `⌘` a second
/// time. While held, digits `1`...`9` switch pane tabs without disturbing normal
/// `⌘1`...`⌘9` outer-window switching.
struct NativeCommandDoubleTapState: Equatable {
    static let maxTapDuration: TimeInterval = 0.35
    static let maxDoubleTapGap: TimeInterval = 0.40

    enum Phase: Equatable {
        case idle
        case firstCommandDown(at: TimeInterval)
        case awaitingSecondCommand(releasedAt: TimeInterval)
        case secondCommandHeld
    }

    private(set) var phase: Phase = .idle

    var isPaneShortcutGuideActive: Bool {
        phase == .secondCommandHeld
    }

    mutating func reset() -> NativeCommandDoubleTapTransition {
        let wasActive = isPaneShortcutGuideActive
        phase = .idle
        return wasActive ? .hidePaneShortcuts : .none
    }

    mutating func handleFlagsChanged(
        flags: NSEvent.ModifierFlags,
        now: TimeInterval,
        enabled: Bool
    ) -> NativeCommandDoubleTapTransition {
        let relevant = flags.intersection([.command, .shift, .option, .control])
        let onlyCommand = relevant == .command
        let noModifiers = relevant.isEmpty

        switch phase {
        case .idle:
            if enabled, onlyCommand {
                phase = .firstCommandDown(at: now)
            }
            return .none

        case .firstCommandDown(let startedAt):
            if onlyCommand {
                return .none
            }
            if enabled, noModifiers, now - startedAt <= Self.maxTapDuration {
                phase = .awaitingSecondCommand(releasedAt: now)
            } else {
                phase = .idle
            }
            return .none

        case .awaitingSecondCommand(let releasedAt):
            if noModifiers {
                return .none
            }
            guard enabled, onlyCommand else {
                phase = .idle
                return .none
            }
            if now - releasedAt <= Self.maxDoubleTapGap {
                phase = .secondCommandHeld
                return .showPaneShortcuts
            }
            phase = .firstCommandDown(at: now)
            return .none

        case .secondCommandHeld:
            if enabled, onlyCommand {
                return .none
            }
            phase = .idle
            return .hidePaneShortcuts
        }
    }

    mutating func handleKeyDown(
        flags: NSEvent.ModifierFlags,
        digit: Int?,
        isEscape: Bool,
        enabled: Bool
    ) -> NativeCommandDoubleTapTransition {
        let onlyCommand = nativeHoldsOnlyCommand(flags)
        switch phase {
        case .idle:
            return .none
        case .firstCommandDown, .awaitingSecondCommand:
            phase = .idle
            return .none
        case .secondCommandHeld:
            guard enabled else {
                phase = .idle
                return .hidePaneShortcuts
            }
            if isEscape {
                phase = .idle
                return .hidePaneShortcuts
            }
            if onlyCommand, let digit, (1...9).contains(digit) {
                return .selectPaneShortcut(digit)
            }
            phase = .idle
            return .hidePaneShortcuts
        }
    }
}

/// Extracts digit `1`...`9` from a key event regardless of keyboard layout.
func nativePaneShortcutDigit(for event: NSEvent) -> Int? {
    if let chars = event.charactersIgnoringModifiers, chars.count == 1,
        let scalar = chars.unicodeScalars.first,
        (49...57).contains(scalar.value)
    {
        return Int(scalar.value - 48)
    }
    let keyCodeMap: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]
    return keyCodeMap[event.keyCode]
}

/// Snapshot of a tmux window's zoom state for Tab-mode synchronization.
struct NativeTmuxTabModeWindowState: Equatable {
    let windowId: UInt32
    let activePaneId: UInt32
    let paneCount: Int
    let zoomed: Bool
}

/// Coordinates tmux `resize-pane -Z` / `select-pane -Z` so Tab pane mode keeps
/// the active tmux pane at the exact full-window client grid without scaling,
/// cropping, or duplicate toggle storms.
struct NativeTmuxTabModeZoomTracker: Equatable {
    var tabModeZoomedWindows: Set<UInt32> = []
    var pendingZoom: [UInt32: Bool] = [:]

    mutating func reset() {
        tabModeZoomedWindows.removeAll()
        pendingZoom.removeAll()
    }

    mutating func markWindowZoomedByTabMode(_ windowId: UInt32) {
        tabModeZoomedWindows.insert(windowId)
        pendingZoom[windowId] = true
    }

    mutating func reconcile(
        windows: [NativeTmuxTabModeWindowState],
        activeWindowId: UInt32,
        mode: NativePaneDisplayMode
    ) -> [String] {
        let knownIds = Set(windows.map(\.windowId))
        tabModeZoomedWindows.formIntersection(knownIds)
        pendingZoom = pendingZoom.filter { knownIds.contains($0.key) }

        for window in windows {
            if window.paneCount <= 1 {
                if mode == .split || pendingZoom[window.windowId] != true {
                    tabModeZoomedWindows.remove(window.windowId)
                    pendingZoom.removeValue(forKey: window.windowId)
                }
                continue
            }
            if pendingZoom[window.windowId] == window.zoomed {
                pendingZoom.removeValue(forKey: window.windowId)
            }
            if !window.zoomed, pendingZoom[window.windowId] != true {
                tabModeZoomedWindows.remove(window.windowId)
            }
        }

        switch mode {
        case .tab:
            guard let active = windows.first(where: { $0.windowId == activeWindowId }),
                active.paneCount > 1,
                !active.zoomed,
                pendingZoom[active.windowId] != true
            else {
                return []
            }
            tabModeZoomedWindows.insert(active.windowId)
            pendingZoom[active.windowId] = true
            return ["resize-pane -Z -t %\(active.activePaneId)"]

        case .split:
            var commands: [String] = []
            for window in windows
            where tabModeZoomedWindows.contains(window.windowId)
                && window.paneCount > 1
                && window.zoomed
                && pendingZoom[window.windowId] != false
            {
                pendingZoom[window.windowId] = false
                commands.append("resize-pane -Z -t @\(window.windowId)")
            }
            return commands
        }
    }

    mutating func selectPaneCommands(
        window: NativeTmuxTabModeWindowState,
        targetPaneId: UInt32,
        mode: NativePaneDisplayMode
    ) -> [String] {
        guard mode == .tab, window.paneCount > 1 else {
            return ["select-pane -t %\(targetPaneId)"]
        }
        tabModeZoomedWindows.insert(window.windowId)
        if window.zoomed {
            return ["select-pane -Z -t %\(targetPaneId)"]
        }
        pendingZoom[window.windowId] = true
        return [
            "select-pane -t %\(targetPaneId)",
            "resize-pane -Z -t %\(targetPaneId)",
        ]
    }
}

func runNativePaneTabModeSelfTests() -> Bool {
    guard NativePaneDisplayMode.split.toggled == .tab,
        NativePaneDisplayMode.tab.toggled == .split,
        NativePaneDisplayMode(rawValue: "tab") == .tab,
        NativePaneDisplayMode(rawValue: "split") == .split
    else {
        return false
    }

    let titled = nativePaneTabTitle(
        paneTitle: "claude",
        currentCommand: "node",
        directory: "/Volumes/Dev/work/app/satin",
        mode: .terminal,
        home: "/Users/tester"
    )
    let homeDir = nativePaneTabTitle(
        paneTitle: "",
        currentCommand: "",
        directory: "/Users/tester",
        mode: .terminal,
        home: "/Users/tester"
    )
    let neovimTitle = nativePaneTabTitle(
        paneTitle: "README.md",
        currentCommand: "nvim",
        directory: "/Users/tester/project",
        mode: .neovim,
        home: "/Users/tester"
    )
    guard titled.title == "claude", titled.directoryName == "satin",
        homeDir.title == "~", homeDir.directoryName == "~",
        neovimTitle.title == "Neovim", neovimTitle.directoryName == "project"
    else {
        return false
    }

    // Tab bar shows cleanly even with 1 pane and hit-tests tab body vs close button.
    let bar = NativePaneTabBarView(
        frame: NSRect(x: 0, y: 0, width: 640, height: nativePaneTabBarHeight))
    let singleItem = NativePaneTabItem(
        paneId: 10,
        index: 0,
        title: "zsh",
        directoryName: "satin",
        fullDirectory: "/Volumes/Dev/work/app/satin",
        worktreeBranch: "feat-tabs",
        status: .running,
        isActive: true
    )
    bar.update(items: [singleItem])
    bar.layoutSubtreeIfNeeded()
    guard let firstTab = bar.tabRect(at: 0),
        let firstClose = bar.closeRect(at: 0),
        singleItem.shortcutDigit == 1,
        singleItem.secondaryLabel == "feat-tabs",
        bar.hitTarget(at: NSPoint(x: firstTab.minX + 12, y: firstTab.midY)) == .tab(0),
        bar.hitTarget(at: NSPoint(x: firstClose.midX, y: firstClose.midY)) == .close(0)
    else {
        return false
    }

    // Overflowing 10 pane tabs: digits 1..9 are assigned, 10th has nil, and active tab stays visible.
    let tenItems = (0..<10).map { idx in
        NativePaneTabItem(
            paneId: 100 + idx,
            index: idx,
            title: "pane-\(idx + 1)",
            directoryName: "satin",
            fullDirectory: "/Volumes/Dev/work/app/satin",
            worktreeBranch: nil,
            status: nil,
            isActive: idx == 9
        )
    }
    bar.update(items: tenItems)
    bar.showsShortcuts = true
    bar.layoutSubtreeIfNeeded()
    guard tenItems[0].shortcutDigit == 1,
        tenItems[8].shortcutDigit == 9,
        tenItems[9].shortcutDigit == nil,
        bar.showsShortcuts,
        let tenthRect = bar.tabRect(at: 9),
        tenthRect.maxX <= bar.bounds.maxX
    else {
        return false
    }

    // TerminalTextView hides workspace pane chrome in Tab mode while keeping artifact sidebar chrome.
    let textView = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let paneRect = NSRect(x: 0, y: 0, width: 600, height: 600)
    let artifactRect = NSRect(x: 600, y: 0, width: 200, height: 600)
    textView.updatePaneFrames(
        [
            1: nativePaneContentFrame(paneRect),
            nativeArtifactSidebarPaneId: nativePaneContentFrame(artifactRect),
        ],
        paneBounds: [1: paneRect, nativeArtifactSidebarPaneId: artifactRect],
        activePaneId: 1
    )
    guard textView.paneChromeViews.keys.contains(1),
        textView.paneChromeViews.keys.contains(nativeArtifactSidebarPaneId),
        textView.paneTabBarView.isHidden
    else {
        return false
    }
    textView.paneDisplayMode = .tab
    textView.updatePaneTabBar(
        items: [singleItem],
        frame: NSRect(x: 0, y: 0, width: 600, height: nativePaneTabBarHeight),
        visible: true,
        activePaneId: 1
    )
    guard !textView.paneChromeViews.keys.contains(1),
        textView.paneChromeViews.keys.contains(nativeArtifactSidebarPaneId),
        !textView.paneTabBarView.isHidden,
        textView.paneTabBarView.items.count == 1
    else {
        return false
    }
    textView.paneDisplayMode = .split
    textView.updatePaneTabBar(items: [], frame: .zero, visible: false, activePaneId: 1)
    guard textView.paneChromeViews.keys.contains(1),
        textView.paneTabBarView.isHidden
    else {
        return false
    }

    // Double-tap-hold ⌘ state machine.
    var gesture = NativeCommandDoubleTapState()
    // 1) Normal ⌘1 does not activate pane guide.
    guard gesture.handleFlagsChanged(flags: .command, now: 1.0, enabled: true) == .none,
        gesture.handleKeyDown(flags: .command, digit: 1, isEscape: false, enabled: true) == .none,
        gesture.phase == .idle,
        gesture.handleFlagsChanged(flags: [], now: 1.1, enabled: true) == .none
    else {
        return false
    }
    // 2) Long single hold of ⌘ does not arm double-tap on release.
    guard gesture.handleFlagsChanged(flags: .command, now: 2.0, enabled: true) == .none,
        gesture.handleFlagsChanged(flags: [], now: 2.6, enabled: true) == .none,
        gesture.phase == .idle
    else {
        return false
    }
    // 3) Quick ⌘ tap followed by 2nd ⌘ hold shows guide, switches panes on 1..9, closes on release.
    guard gesture.handleFlagsChanged(flags: .command, now: 3.0, enabled: true) == .none,
        gesture.handleFlagsChanged(flags: [], now: 3.12, enabled: true) == .none,
        gesture.handleFlagsChanged(flags: .command, now: 3.25, enabled: true) == .showPaneShortcuts,
        gesture.isPaneShortcutGuideActive,
        gesture.handleKeyDown(flags: .command, digit: 2, isEscape: false, enabled: true)
            == .selectPaneShortcut(2),
        gesture.isPaneShortcutGuideActive,
        gesture.handleKeyDown(flags: .command, digit: 4, isEscape: false, enabled: true)
            == .selectPaneShortcut(4),
        gesture.handleFlagsChanged(flags: [], now: 3.7, enabled: true) == .hidePaneShortcuts,
        !gesture.isPaneShortcutGuideActive
    else {
        return false
    }
    // 4) Disabled in Split mode: double-tap never activates guide.
    guard gesture.handleFlagsChanged(flags: .command, now: 4.0, enabled: false) == .none,
        gesture.handleFlagsChanged(flags: [], now: 4.1, enabled: false) == .none,
        gesture.handleFlagsChanged(flags: .command, now: 4.2, enabled: false) == .none,
        !gesture.isPaneShortcutGuideActive
    else {
        return false
    }
    // 5) Escape closes active guide.
    guard gesture.handleFlagsChanged(flags: .command, now: 5.0, enabled: true) == .none,
        gesture.handleFlagsChanged(flags: [], now: 5.1, enabled: true) == .none,
        gesture.handleFlagsChanged(flags: .command, now: 5.2, enabled: true) == .showPaneShortcuts,
        gesture.handleKeyDown(flags: .command, digit: nil, isEscape: true, enabled: true)
            == .hidePaneShortcuts,
        !gesture.isPaneShortcutGuideActive
    else {
        return false
    }

    // tmux Tab-mode zoom tracker: deduplicates in-flight zooms, switches atomically, restores only Tab-mode zooms.
    var tracker = NativeTmuxTabModeZoomTracker()
    let splitWindow = NativeTmuxTabModeWindowState(
        windowId: 1, activePaneId: 10, paneCount: 2, zoomed: false)
    let manualZoomed = NativeTmuxTabModeWindowState(
        windowId: 2, activePaneId: 20, paneCount: 2, zoomed: true)
    // Split mode never touches manually zoomed windows.
    guard
        tracker.reconcile(windows: [splitWindow, manualZoomed], activeWindowId: 1, mode: .split)
            .isEmpty
    else {
        return false
    }
    // Entering Tab mode zooms the multi-pane active window once, and dedups duplicate snapshots.
    guard
        tracker.reconcile(windows: [splitWindow, manualZoomed], activeWindowId: 1, mode: .tab)
            == ["resize-pane -Z -t %10"],
        tracker.reconcile(windows: [splitWindow, manualZoomed], activeWindowId: 1, mode: .tab)
            .isEmpty
    else {
        return false
    }
    let zoomedWindow = NativeTmuxTabModeWindowState(
        windowId: 1, activePaneId: 10, paneCount: 2, zoomed: true)
    guard
        tracker.reconcile(windows: [zoomedWindow, manualZoomed], activeWindowId: 1, mode: .tab)
            .isEmpty,
        tracker.selectPaneCommands(window: zoomedWindow, targetPaneId: 11, mode: .tab)
            == ["select-pane -Z -t %11"]
    else {
        return false
    }
    // Returning to Split mode unzooms window 1 (zoomed by Tab mode), leaving manually zoomed window 2 untouched.
    guard
        tracker.reconcile(windows: [zoomedWindow, manualZoomed], activeWindowId: 1, mode: .split)
            == ["resize-pane -Z -t @1"],
        tracker.reconcile(windows: [zoomedWindow, manualZoomed], activeWindowId: 1, mode: .split)
            .isEmpty
    else {
        return false
    }
    // Splitting a 1-pane tmux window in Tab mode preserves Tab-mode ownership across intermediate snapshots.
    let singlePaneWindow = NativeTmuxTabModeWindowState(
        windowId: 3, activePaneId: 30, paneCount: 1, zoomed: false)
    let splitZoomedWindow = NativeTmuxTabModeWindowState(
        windowId: 3, activePaneId: 31, paneCount: 2, zoomed: true)
    tracker.markWindowZoomedByTabMode(3)
    guard tracker.reconcile(windows: [singlePaneWindow], activeWindowId: 3, mode: .tab).isEmpty,
        tracker.reconcile(windows: [splitZoomedWindow], activeWindowId: 3, mode: .tab).isEmpty,
        tracker.reconcile(windows: [splitZoomedWindow], activeWindowId: 3, mode: .split)
            == ["resize-pane -Z -t @3"]
    else {
        return false
    }

    // Tab mode workspace grid invariant: single-leaf content below tab bar matches exact capacity.
    let workspace = NSRect(x: 0, y: 0, width: 840, height: 540)
    let content = nativePaneTabContentRect(workspace)
    let cell = NSSize(width: 8.4, height: 17)
    let singleLeaf = PaneLayoutSnapshot(kind: "leaf", paneId: 1)
    let tabCapacity = tmuxClientGridCapacity(
        layout: singleLeaf,
        size: content.size,
        cellSize: cell,
        paneChromeHeight: 0
    )
    let directCols = Int(floor(content.width / cell.width + 0.000_1))
    let directRows = Int(floor(content.height / cell.height + 0.000_1))
    return tabCapacity == NativePaneGridCapacity(rows: directRows, cols: directCols)
        && content.height == workspace.height - nativePaneTabBarHeight
}
