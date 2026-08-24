import AppKit
import QuartzCore

final class NativeTabStripView: NSView {
    private enum Metrics {
        static let spacing: CGFloat = 4
        static let buttonSize = NSSize(width: 22, height: 22)
        static let edgeFadeWidth: CGFloat = 30
        static let edgeTolerance: CGFloat = 1
        static let scrollPageFraction: CGFloat = 0.78
        static let minimumScrollPage: CGFloat = 72
        static let minimumTabViewportWidth: CGFloat = 44
        // Keep permanent trailing toolbar actions available at all tab counts.
        static let maximumToolbarWidth: CGFloat = 720
    }

    let tabControl: NativeTabControl
    let newTabButton: NativeHoverIconButton
    var allTabsMenuProvider: (() -> NSMenu?)?

    private let tabScrollView = NSScrollView(frame: .zero)
    private let overflowButton = NativeHoverIconButton(
        symbolName: "chevron.down",
        title: "All Tabs"
    )
    private let previousTabsButton = NativeHoverIconButton(
        symbolName: "chevron.left",
        title: "Earlier Tabs"
    )
    private let nextTabsButton = NativeHoverIconButton(
        symbolName: "chevron.right",
        title: "Later Tabs"
    )
    private let overflowMaskLayer = CAGradientLayer()
    private var revealSelectedTabAfterLayout = true
    private var continuationControlsVisible = false

    init(tabControl: NativeTabControl, newTabButton: NativeHoverIconButton) {
        self.tabControl = tabControl
        self.newTabButton = newTabButton
        super.init(frame: .zero)
        configureScrollView()
        overflowButton.target = self
        overflowButton.action = #selector(showAllTabs(_:))
        overflowButton.isHidden = true
        configureContinuationButton(
            previousTabsButton,
            action: #selector(scrollToEarlierTabs(_:)),
            help: "More tabs are hidden to the left. Click to scroll toward them."
        )
        configureContinuationButton(
            nextTabsButton,
            action: #selector(scrollToLaterTabs(_:)),
            help: "More tabs are hidden to the right. Click to scroll toward them."
        )
        addSubview(tabScrollView)
        addSubview(previousTabsButton)
        addSubview(nextTabsButton)
        addSubview(overflowButton)
        addSubview(newTabButton)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let tabs = tabControl.intrinsicContentSize
        let primaryControlsWidth = Metrics.spacing + Metrics.buttonSize.width
        let overflowWidth =
            tabs.width + primaryControlsWidth > Metrics.maximumToolbarWidth
            ? Metrics.spacing + Metrics.buttonSize.width
            : 0
        return NSSize(
            width: min(
                tabs.width + primaryControlsWidth + overflowWidth,
                Metrics.maximumToolbarWidth
            ),
            height: max(tabs.height, Metrics.buttonSize.height)
        )
    }

    override func layout() {
        super.layout()
        let tabs = tabControl.intrinsicContentSize
        let buttonY = floor((bounds.height - Metrics.buttonSize.height) / 2)
        let newTabX = max(0, bounds.width - Metrics.buttonSize.width)
        let widthWithoutOverflow = max(0, newTabX - Metrics.spacing)
        let overflows = tabs.width > widthWithoutOverflow + 0.5
        overflowButton.isHidden = !overflows

        let overflowX = max(
            0,
            newTabX - (overflows ? Metrics.spacing + Metrics.buttonSize.width : 0)
        )
        let continuationMinimumWidth =
            Metrics.buttonSize.width * 2
            + Metrics.spacing * 3
            + Metrics.minimumTabViewportWidth
        continuationControlsVisible = overflows && overflowX >= continuationMinimumWidth
        let viewportX =
            continuationControlsVisible
            ? Metrics.buttonSize.width + Metrics.spacing : 0
        let nextTabsX =
            continuationControlsVisible
            ? overflowX - Metrics.spacing - Metrics.buttonSize.width : overflowX
        let viewportMaxX =
            continuationControlsVisible
            ? nextTabsX - Metrics.spacing : overflowX - Metrics.spacing
        let viewportWidth = max(0, viewportMaxX - viewportX)
        tabScrollView.frame = NSRect(
            x: viewportX,
            y: floor((bounds.height - tabs.height) / 2),
            width: viewportWidth,
            height: tabs.height
        )
        tabControl.frame = NSRect(
            x: 0,
            y: 0,
            width: max(1, tabs.width),
            height: tabs.height
        )
        overflowButton.frame = NSRect(
            x: overflowX,
            y: buttonY,
            width: Metrics.buttonSize.width,
            height: Metrics.buttonSize.height
        )
        previousTabsButton.frame = NSRect(
            x: 0,
            y: buttonY,
            width: Metrics.buttonSize.width,
            height: Metrics.buttonSize.height
        )
        nextTabsButton.frame = NSRect(
            x: nextTabsX,
            y: buttonY,
            width: Metrics.buttonSize.width,
            height: Metrics.buttonSize.height
        )
        newTabButton.frame = NSRect(
            x: newTabX,
            y: buttonY,
            width: Metrics.buttonSize.width,
            height: Metrics.buttonSize.height
        )
        if revealSelectedTabAfterLayout {
            revealSelectedTabAfterLayout = false
            revealSelectedTab()
        }
        updateContinuationAffordances()
    }

    func contentSizeDidChange() {
        revealSelectedTabAfterLayout = true
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    func actionsReady() -> Bool {
        newTabButton.superview === self
            && overflowButton.superview === self
            && previousTabsButton.superview === self
            && nextTabsButton.superview === self
            && newTabButton.image != nil
            && overflowButton.image != nil
            && previousTabsButton.image != nil
            && nextTabsButton.image != nil
            && !newTabButton.isBordered
            && !overflowButton.isBordered
            && !previousTabsButton.isBordered
            && !nextTabsButton.isBordered
            && allTabsMenuProvider != nil
    }

    func overflowLayoutReadyForSmoke(expectedSegments: Int) -> Bool {
        layoutSubtreeIfNeeded()
        guard expectedSegments == tabControl.segmentCount,
            !overflowButton.isHidden,
            tabScrollView.documentView === tabControl,
            let selectedFrame = tabControl.segmentFrameForNavigation(
                tabControl.selectedSegment
            )
        else {
            return false
        }
        let visible = tabControl.visibleRect
        return tabControl.bounds.width > tabScrollView.contentSize.width
            && selectedFrame.minX >= visible.minX - 0.5
            && selectedFrame.maxX <= visible.maxX + 0.5
            && tabScrollView.frame.maxX + Metrics.spacing <= overflowButton.frame.minX + 0.5
            && overflowButton.frame.maxX + Metrics.spacing <= newTabButton.frame.minX + 0.5
            && tabControl.drawingClipReadyForSmoke()
    }

    func visibleTabViewportFrameForSmoke() -> NSRect {
        tabScrollView.contentView.convert(tabScrollView.contentView.bounds, to: nil)
    }

    func continuationAffordancesReadyForSmoke() -> Bool {
        layoutSubtreeIfNeeded()
        let clipView = tabScrollView.contentView
        let maximumX = maximumScrollX
        guard maximumX > Metrics.edgeTolerance else {
            return false
        }
        let originalOrigin = clipView.bounds.origin
        defer {
            setScrollX(originalOrigin.x)
        }

        setScrollX(0)
        let startReady =
            !previousTabsButton.isHidden
            && !nextTabsButton.isHidden
            && !previousTabsButton.isEnabled
            && nextTabsButton.isEnabled

        setScrollX(maximumX / 2)
        let middleReady =
            !previousTabsButton.isHidden
            && !nextTabsButton.isHidden
            && previousTabsButton.isEnabled
            && nextTabsButton.isEnabled

        setScrollX(maximumX)
        let endReady =
            !previousTabsButton.isHidden
            && !nextTabsButton.isHidden
            && previousTabsButton.isEnabled
            && !nextTabsButton.isEnabled

        nextTabsButton.performClick(nil)
        let nextAtEndStaysBounded = abs(clipView.bounds.minX - maximumX) <= 0.5
        previousTabsButton.performClick(nil)
        let previousActionMoved = clipView.bounds.minX < maximumX - Metrics.edgeTolerance

        return startReady
            && middleReady
            && endReady
            && nextAtEndStaysBounded
            && previousActionMoved
            && tabScrollView.layer?.mask === overflowMaskLayer
            && previousTabsButton.frame.maxX + Metrics.spacing
                <= tabScrollView.frame.minX + 0.5
            && tabScrollView.frame.maxX + Metrics.spacing
                <= nextTabsButton.frame.minX + 0.5
            && nextTabsButton.frame.maxX + Metrics.spacing
                <= overflowButton.frame.minX + 0.5
    }

    func prepareContinuationCaptureForSmoke(position: String?) {
        layoutSubtreeIfNeeded()
        revealSelectedTabAfterLayout = false
        switch position {
        case "start":
            setScrollX(0)
        case "end":
            setScrollX(maximumScrollX)
        default:
            setScrollX(maximumScrollX / 2)
        }
    }

    private func configureScrollView() {
        tabControl.translatesAutoresizingMaskIntoConstraints = true
        tabControl.autoresizingMask = []
        tabScrollView.documentView = tabControl
        tabScrollView.borderType = .noBorder
        tabScrollView.drawsBackground = false
        tabScrollView.contentView.drawsBackground = false
        tabScrollView.hasHorizontalScroller = false
        tabScrollView.hasVerticalScroller = false
        tabScrollView.horizontalScrollElasticity = .automatic
        tabScrollView.verticalScrollElasticity = .none
        tabScrollView.wantsLayer = true
        tabScrollView.layer?.masksToBounds = true
        tabScrollView.contentView.wantsLayer = true
        tabScrollView.contentView.layer?.masksToBounds = true
        tabScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolledTabBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: tabScrollView.contentView
        )
        overflowMaskLayer.startPoint = CGPoint(x: 0, y: 0.5)
        overflowMaskLayer.endPoint = CGPoint(x: 1, y: 0.5)
        tabScrollView.layer?.mask = overflowMaskLayer
    }

    private func revealSelectedTab() {
        guard
            let selectedFrame = tabControl.segmentFrameForNavigation(
                tabControl.selectedSegment
            )
        else {
            return
        }
        let clipView = tabScrollView.contentView
        let visibleWidth = clipView.bounds.width
        guard visibleWidth > 0 else {
            return
        }
        var targetX = clipView.bounds.minX
        if selectedFrame.minX < clipView.bounds.minX {
            targetX = selectedFrame.minX - Metrics.spacing
        } else if selectedFrame.maxX > clipView.bounds.maxX {
            targetX = selectedFrame.maxX - visibleWidth + Metrics.spacing
        }
        let maximumX = max(0, tabControl.bounds.width - visibleWidth)
        targetX = min(max(0, targetX), maximumX)
        clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.minY))
        tabScrollView.reflectScrolledClipView(clipView)
    }

    private var maximumScrollX: CGFloat {
        max(0, tabControl.bounds.width - tabScrollView.contentView.bounds.width)
    }

    private func configureContinuationButton(
        _ button: NativeHoverIconButton,
        action: Selector,
        help: String
    ) {
        button.target = self
        button.action = action
        button.isHidden = true
        button.setAccessibilityHelp(help)
    }

    private func setScrollX(_ proposedX: CGFloat) {
        let clipView = tabScrollView.contentView
        let targetX = min(max(0, proposedX), maximumScrollX)
        clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.minY))
        tabScrollView.reflectScrolledClipView(clipView)
        updateContinuationAffordances()
    }

    private func scrollTabs(direction: CGFloat) {
        let visibleWidth = tabScrollView.contentView.bounds.width
        let page = max(
            Metrics.minimumScrollPage,
            visibleWidth * Metrics.scrollPageFraction
        )
        setScrollX(tabScrollView.contentView.bounds.minX + direction * page)
    }

    private func updateContinuationAffordances() {
        let maximumX = maximumScrollX
        let currentX = min(max(0, tabScrollView.contentView.bounds.minX), maximumX)
        let canScrollEarlier =
            maximumX > Metrics.edgeTolerance && currentX > Metrics.edgeTolerance
        let canScrollLater =
            maximumX > Metrics.edgeTolerance
            && currentX < maximumX - Metrics.edgeTolerance
        let showsControls =
            continuationControlsVisible && maximumX > Metrics.edgeTolerance
        previousTabsButton.isHidden = !showsControls
        nextTabsButton.isHidden = !showsControls
        previousTabsButton.isEnabled = canScrollEarlier
        nextTabsButton.isEnabled = canScrollLater
        previousTabsButton.alphaValue = canScrollEarlier ? 1 : 0.22
        nextTabsButton.alphaValue = canScrollLater ? 1 : 0.22
        previousTabsButton.setEmphasized(canScrollEarlier)
        nextTabsButton.setEmphasized(canScrollLater)
        previousTabsButton.setAccessibilityValue(
            canScrollEarlier ? "More tabs to the left" : "At the first tab"
        )
        nextTabsButton.setAccessibilityValue(
            canScrollLater ? "More tabs to the right" : "At the last tab"
        )
        updateOverflowMask(
            fadesLeadingEdge: canScrollEarlier,
            fadesTrailingEdge: canScrollLater
        )
    }

    private func updateOverflowMask(
        fadesLeadingEdge: Bool,
        fadesTrailingEdge: Bool
    ) {
        let width = max(1, tabScrollView.bounds.width)
        let fadeStop = min(0.45, Metrics.edgeFadeWidth / width)
        let transparent = NSColor.black.withAlphaComponent(0).cgColor
        let opaque = NSColor.black.cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overflowMaskLayer.frame = tabScrollView.bounds
        switch (fadesLeadingEdge, fadesTrailingEdge) {
        case (true, true):
            overflowMaskLayer.colors = [transparent, opaque, opaque, transparent]
            overflowMaskLayer.locations = [
                0,
                NSNumber(value: fadeStop),
                NSNumber(value: 1 - fadeStop),
                1,
            ]
        case (true, false):
            overflowMaskLayer.colors = [transparent, opaque, opaque]
            overflowMaskLayer.locations = [0, NSNumber(value: fadeStop), 1]
        case (false, true):
            overflowMaskLayer.colors = [opaque, opaque, transparent]
            overflowMaskLayer.locations = [0, NSNumber(value: 1 - fadeStop), 1]
        case (false, false):
            overflowMaskLayer.colors = [opaque, opaque]
            overflowMaskLayer.locations = [0, 1]
        }
        CATransaction.commit()
    }

    @objc private func scrolledTabBoundsDidChange(_ notification: Notification) {
        updateContinuationAffordances()
    }

    @objc private func scrollToEarlierTabs(_ sender: NSButton) {
        scrollTabs(direction: -1)
    }

    @objc private func scrollToLaterTabs(_ sender: NSButton) {
        scrollTabs(direction: 1)
    }

    @objc private func showAllTabs(_ sender: NSButton) {
        guard let menu = allTabsMenuProvider?(), !menu.items.isEmpty else {
            return
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY - Metrics.spacing),
            in: sender
        )
    }
}
