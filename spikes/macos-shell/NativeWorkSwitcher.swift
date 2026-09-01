import AppKit
import Foundation

struct NativeWorkItem: Equatable {
    let tabId: Int
    let tabIndex: Int
    let paneId: Int
    let paneOrdinal: Int
    let tabTitle: String
    let paneTitle: String
    let workingDirectory: String
    let sessionLabel: String
    let status: NativePaneControlStatus?
    let unread: Bool
    let active: Bool
    private let normalizedSearchText: String

    init(
        tabId: Int,
        tabIndex: Int,
        paneId: Int,
        paneOrdinal: Int,
        tabTitle: String,
        paneTitle: String,
        workingDirectory: String,
        sessionLabel: String,
        status: NativePaneControlStatus?,
        unread: Bool,
        active: Bool
    ) {
        self.tabId = tabId
        self.tabIndex = tabIndex
        self.paneId = paneId
        self.paneOrdinal = paneOrdinal
        self.tabTitle = tabTitle
        self.paneTitle = paneTitle
        self.workingDirectory = workingDirectory
        self.sessionLabel = sessionLabel
        self.status = status
        self.unread = unread
        self.active = active
        self.normalizedSearchText = nativeNormalizedWorkSearch(
            [
                tabTitle,
                paneTitle,
                workingDirectory,
                sessionLabel,
                status?.status ?? "",
                nativeWorkSingleLine(status?.summary ?? "", limit: 512),
            ].joined(separator: " ")
        )
    }

    var headline: String {
        let tabTitle = nativeWorkSingleLine(self.tabTitle, limit: 160)
        let paneTitle = nativeWorkSingleLine(self.paneTitle, limit: 160)
        guard !paneTitle.isEmpty, paneTitle != tabTitle else {
            return tabTitle
        }
        return "\(tabTitle) · \(paneTitle)"
    }

    var detail: String {
        var values: [String] = []
        if let summary = status?.summary, !summary.isEmpty {
            values.append(nativeWorkSingleLine(summary, limit: 200))
        }
        values.append(nativeWorkSingleLine(sessionLabel, limit: 120))
        if !workingDirectory.isEmpty {
            values.append(
                nativeWorkSingleLine(
                    (workingDirectory as NSString).abbreviatingWithTildeInPath,
                    limit: 240
                ))
        }
        return values.joined(separator: " · ")
    }

    var statusTitle: String {
        switch status?.status {
        case "running": "Running"
        case "waiting": "Waiting"
        case "blocked": "Blocked"
        case "done": "Done"
        case "failed": "Failed"
        case "idle": "Idle"
        default: active ? "Current" : ""
        }
    }

    var statusSymbolName: String {
        switch status?.status {
        case "running": "circle.fill"
        case "waiting": "pause.circle.fill"
        case "blocked": "exclamationmark.triangle.fill"
        case "done": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        default: active ? "chevron.right.circle.fill" : "terminal"
        }
    }

    func matches(_ query: String) -> Bool {
        matches(tokens: nativeWorkSearchTokens(query))
    }

    fileprivate func matches(tokens: [Substring]) -> Bool {
        guard !tokens.isEmpty else {
            return true
        }
        return tokens.allSatisfy { normalizedSearchText.contains($0) }
    }
}

final class NativeWorkAttentionStore {
    private static let attentionStatuses = Set(["waiting", "blocked", "done", "failed"])
    private var unreadPaneIds = Set<Int>()

    func observe(paneId: Int, status: NativePaneControlStatus, isVisible: Bool) {
        if Self.attentionStatuses.contains(status.status), !isVisible {
            unreadPaneIds.insert(paneId)
        } else {
            unreadPaneIds.remove(paneId)
        }
    }

    func markSeen(paneId: Int) {
        unreadPaneIds.remove(paneId)
    }

    func remove(paneId: Int) {
        unreadPaneIds.remove(paneId)
    }

    func isUnread(paneId: Int) -> Bool {
        unreadPaneIds.contains(paneId)
    }

    var unreadCount: Int {
        unreadPaneIds.count
    }
}

private enum NativeWorkSection: Int, CaseIterable {
    case attention
    case running
    case other

    var title: String {
        switch self {
        case .attention: "Needs Attention"
        case .running: "Running"
        case .other: "Other"
        }
    }
}

private enum NativeWorkDisplayRow {
    case section(NativeWorkSection, count: Int)
    case item(NativeWorkItem)

    var item: NativeWorkItem? {
        guard case .item(let item) = self else {
            return nil
        }
        return item
    }
}

private final class NativeWorkSwitcherSectionView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(section: NativeWorkSection, count: Int) {
        label.stringValue = "\(section.title)  \(count)"
        setAccessibilityLabel("\(section.title), \(count) panes")
    }
}

private final class NativeWorkSwitcherRowView: NSTableCellView {
    private let statusImage = NSImageView(frame: .zero)
    private let headlineLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        statusImage.translatesAutoresizingMaskIntoConstraints = false
        statusImage.imageScaling = .scaleProportionallyDown
        headlineLabel.translatesAutoresizingMaskIntoConstraints = false
        headlineLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headlineLabel.lineBreakMode = .byTruncatingTail
        headlineLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        snippetLabel.translatesAutoresizingMaskIntoConstraints = false
        snippetLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        snippetLabel.textColor = .tertiaryLabelColor
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(statusImage)
        addSubview(headlineLabel)
        addSubview(detailLabel)
        addSubview(snippetLabel)
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 16),
            statusImage.heightAnchor.constraint(equalToConstant: 16),
            headlineLabel.leadingAnchor.constraint(
                equalTo: statusImage.trailingAnchor, constant: 9),
            headlineLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            headlineLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: statusLabel.leadingAnchor,
                constant: -10
            ),
            detailLabel.leadingAnchor.constraint(equalTo: headlineLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: headlineLabel.bottomAnchor, constant: 3),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            snippetLabel.leadingAnchor.constraint(equalTo: headlineLabel.leadingAnchor),
            snippetLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 4),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            snippetLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusLabel.firstBaselineAnchor.constraint(equalTo: headlineLabel.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(_ item: NativeWorkItem, snippet: String?, previewPending: Bool) {
        headlineLabel.stringValue = item.headline
        detailLabel.stringValue = item.detail
        let previewDescription = previewPending ? "Loading preview…" : snippet ?? "No visible text"
        snippetLabel.stringValue = previewDescription
        snippetLabel.textColor = snippet == nil ? .quaternaryLabelColor : .tertiaryLabelColor
        statusLabel.stringValue = item.statusTitle
        let color = nativeWorkStatusColor(item)
        statusLabel.textColor = color
        statusImage.contentTintColor = color
        statusImage.image = NSImage(
            systemSymbolName: item.statusSymbolName,
            accessibilityDescription: item.statusTitle.isEmpty ? "Terminal pane" : item.statusTitle
        )
        setAccessibilityLabel(
            [item.headline, item.statusTitle, item.detail, previewDescription]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
    }
}

private enum NativeWorkPreviewLookup: Equatable {
    case missing
    case ready(String?)
}

private final class NativeWorkPreviewCache {
    private var values: [Int: NativeWorkPreviewLookup] = [:]
    private var queue: [Int] = []
    private var queuedPaneIds = Set<Int>()

    func lookup(paneId: Int) -> NativeWorkPreviewLookup {
        values[paneId] ?? .missing
    }

    @discardableResult
    func enqueue(paneId: Int, priority: Bool) -> Bool {
        guard values[paneId] == nil else {
            return false
        }
        if queuedPaneIds.contains(paneId) {
            guard priority, queue.first != paneId else {
                return false
            }
            queue.removeAll { $0 == paneId }
        } else {
            queuedPaneIds.insert(paneId)
        }
        if priority {
            queue.insert(paneId, at: 0)
        } else {
            queue.append(paneId)
        }
        return true
    }

    func dequeue() -> Int? {
        guard !queue.isEmpty else {
            return nil
        }
        let paneId = queue.removeFirst()
        queuedPaneIds.remove(paneId)
        return paneId
    }

    func store(_ value: String?, paneId: Int) {
        values[paneId] = .ready(value)
    }

    func invalidate(paneId: Int) {
        values.removeValue(forKey: paneId)
    }

    func retain(paneIds: Set<Int>) {
        values = values.filter { paneIds.contains($0.key) }
        queue.removeAll { !paneIds.contains($0) }
        queuedPaneIds.formIntersection(paneIds)
    }
}

final class NativeWorkSwitcherViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate
{
    var onSelect: ((NativeWorkItem) -> Void)?
    var onCancel: (() -> Void)?

    private var items: [NativeWorkItem]
    private var filteredItems: [NativeWorkItem] = []
    private var displayRows: [NativeWorkDisplayRow] = []
    private let previewCache = NativeWorkPreviewCache()
    private var previewCaptureScheduled = false
    private let initiallyActivePaneId: Int?
    private let previewProvider: (NativeWorkItem) -> String?
    private let searchField = NSSearchField(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let previewView = NativeWorkSwitcherPreviewView(frame: .zero)

    init(
        items: [NativeWorkItem],
        activePaneId: Int?,
        previewProvider: @escaping (NativeWorkItem) -> String?
    ) {
        self.items = items
        self.initiallyActivePaneId = activePaneId
        self.previewProvider = previewProvider
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let width: CGFloat = 820
        let height: CGFloat = 410
        let listWidth: CGFloat = 340
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let heading = NSTextField(labelWithString: "Work Switcher")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.frame = NSRect(x: 16, y: height - 31, width: 220, height: 18)
        container.addSubview(heading)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.frame = NSRect(x: width - 250, y: height - 30, width: 234, height: 16)
        container.addSubview(countLabel)

        searchField.placeholderString = "Tabs, panes, directories, or status"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.frame = NSRect(x: 14, y: height - 70, width: listWidth, height: 28)
        searchField.setAccessibilityLabel("Search work")
        container.addSubview(searchField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("work"))
        column.width = listWidth
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 76
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(confirmClickedRow)
        tableView.setAccessibilityLabel("Open panes")

        let scrollView = NSScrollView(
            frame: NSRect(x: 14, y: 34, width: listWidth, height: height - 112)
        )
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        container.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: 30, y: height / 2 - 10, width: listWidth - 32, height: 20)
        container.addSubview(emptyLabel)

        let divider = NSBox(
            frame: NSRect(x: 367, y: 34, width: 1, height: height - 76)
        )
        divider.boxType = .separator
        container.addSubview(divider)

        previewView.frame = NSRect(x: 381, y: 34, width: width - 395, height: height - 76)
        container.addSubview(previewView)

        let hint = NSTextField(
            labelWithString: "↩ or double-click Focus    ↑↓ Preview    esc Close"
        )
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 14, y: 9, width: listWidth, height: 14)
        container.addSubview(hint)

        view = container
        applyFilter(selecting: initiallyActivePaneId)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func update(items: [NativeWorkItem]) {
        guard items != self.items else {
            return
        }
        let selectedPaneId = selectedItem()?.paneId
        let previousStatusRevisions = Dictionary(
            uniqueKeysWithValues: self.items.map { ($0.paneId, $0.status?.revision ?? 0) }
        )
        for item in items
        where previousStatusRevisions[item.paneId] != (item.status?.revision ?? 0) {
            previewCache.invalidate(paneId: item.paneId)
        }
        self.items = items
        previewCache.retain(paneIds: Set(items.map(\.paneId)))
        guard isViewLoaded else {
            return
        }
        applyFilter(selecting: selectedPaneId)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayRows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard displayRows.indices.contains(row) else {
            return nil
        }
        switch displayRows[row] {
        case .section(let section, let count):
            let identifier = NSUserInterfaceItemIdentifier("work-section")
            let sectionView =
                tableView.makeView(withIdentifier: identifier, owner: self)
                as? NativeWorkSwitcherSectionView
                ?? NativeWorkSwitcherSectionView(frame: .zero)
            sectionView.identifier = identifier
            sectionView.update(section: section, count: count)
            return sectionView
        case .item(let item):
            let identifier = NSUserInterfaceItemIdentifier("work-row")
            let rowView =
                tableView.makeView(withIdentifier: identifier, owner: self)
                as? NativeWorkSwitcherRowView
                ?? NativeWorkSwitcherRowView(frame: .zero)
            rowView.identifier = identifier
            let preview = previewLookup(for: item, priority: false)
            let snippet: String?
            let previewPending: Bool
            switch preview {
            case .ready(let boundedText):
                snippet = boundedText.flatMap(nativeWorkPreviewSnippetFromBounded)
                previewPending = false
            case .missing:
                snippet = nil
                previewPending = true
            }
            rowView.update(item, snippet: snippet, previewPending: previewPending)
            return rowView
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard displayRows.indices.contains(row) else {
            return false
        }
        if case .section = displayRows[row] {
            return true
        }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard displayRows.indices.contains(row) else {
            return 76
        }
        if case .section = displayRows[row] {
            return 25
        }
        return 76
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        displayRows.indices.contains(row) && displayRows[row].item != nil
    }

    func controlTextDidChange(_ notification: Notification) {
        applyFilter(selecting: nil)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            confirmSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            return false
        }
        return true
    }

    @objc private func confirmSelection() {
        guard let item = selectedItem() else {
            return
        }
        onSelect?(item)
    }

    @objc private func confirmClickedRow() {
        guard let item = item(at: tableView.clickedRow) else {
            return
        }
        onSelect?(item)
    }

    private func selectedItem() -> NativeWorkItem? {
        item(at: tableView.selectedRow)
    }

    private func item(at row: Int) -> NativeWorkItem? {
        guard displayRows.indices.contains(row) else {
            return nil
        }
        return displayRows[row].item
    }

    private func moveSelection(by delta: Int) {
        let itemRows = displayRows.indices.filter { displayRows[$0].item != nil }
        guard !itemRows.isEmpty else {
            updatePreview()
            return
        }
        let currentIndex =
            itemRows.firstIndex(of: tableView.selectedRow)
            ?? (delta > 0 ? -1 : itemRows.count)
        let nextIndex = min(max(currentIndex + delta, 0), itemRows.count - 1)
        let nextRow = itemRows[nextIndex]
        tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(nextRow)
    }

    private func applyFilter(selecting requestedPaneId: Int?) {
        let tokens = nativeWorkSearchTokens(searchField.stringValue)
        filteredItems = nativeSortedWorkItems(items.filter { $0.matches(tokens: tokens) })
        displayRows = nativeWorkDisplayRows(filteredItems)
        tableView.reloadData()
        let attentionCount = items.filter(\.unread).count
        countLabel.stringValue =
            attentionCount == 0
            ? "\(items.count) panes"
            : "\(items.count) panes · \(attentionCount) need attention"
        emptyLabel.stringValue = items.isEmpty ? "No panes yet" : "No matching panes"
        emptyLabel.isHidden = !filteredItems.isEmpty
        guard !filteredItems.isEmpty else {
            updatePreview()
            return
        }
        let preferredPaneId =
            requestedPaneId
            ?? (searchField.stringValue.isEmpty
                ? filteredItems.first(where: \.unread)?.paneId ?? initiallyActivePaneId
                : nil)
        let row =
            preferredPaneId.flatMap { paneId in
                displayRows.firstIndex(where: { $0.item?.paneId == paneId })
            } ?? displayRows.firstIndex(where: { $0.item != nil }) ?? 0
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        updatePreview()
    }

    private func updatePreview() {
        guard let item = selectedItem() else {
            previewView.update(item: nil, boundedText: nil)
            return
        }
        switch previewLookup(for: item, priority: true) {
        case .ready(let preview):
            previewView.update(item: item, boundedText: preview)
        case .missing:
            previewView.update(item: item, boundedText: nil, loading: true)
        }
    }

    private func previewLookup(
        for item: NativeWorkItem,
        priority: Bool
    ) -> NativeWorkPreviewLookup {
        let lookup = previewCache.lookup(paneId: item.paneId)
        switch lookup {
        case .ready:
            return lookup
        case .missing:
            _ = previewCache.enqueue(paneId: item.paneId, priority: priority)
            schedulePreviewCapture()
            return .missing
        }
    }

    private func schedulePreviewCapture() {
        guard !previewCaptureScheduled else {
            return
        }
        previewCaptureScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            guard let self else {
                return
            }
            self.previewCaptureScheduled = false
            self.captureNextPreview()
        }
    }

    private func captureNextPreview() {
        guard let paneId = previewCache.dequeue() else {
            return
        }
        if let item = items.first(where: { $0.paneId == paneId }) {
            let preview = nativeBoundedWorkPreview(previewProvider(item))
            previewCache.store(preview, paneId: paneId)
            reloadPreview(paneId: paneId)
        }
        schedulePreviewCapture()
    }

    private func reloadPreview(paneId: Int) {
        if let row = displayRows.firstIndex(where: { $0.item?.paneId == paneId }) {
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integer: 0)
            )
        }
        if selectedItem()?.paneId == paneId {
            updatePreview()
        }
    }
}

func runNativeWorkSwitcherSelfTests() -> Bool {
    let attention = NativeWorkAttentionStore()
    let done = NativePaneControlStatus(
        status: "done",
        summary: "tests passed",
        revision: 1,
        updatedAt: Date()
    )
    let running = NativePaneControlStatus(
        status: "running",
        summary: "running tests",
        revision: 2,
        updatedAt: Date()
    )
    let waiting = NativePaneControlStatus(
        status: "waiting",
        summary: "needs input",
        revision: 3,
        updatedAt: Date()
    )
    attention.observe(paneId: 7, status: done, isVisible: false)
    guard attention.isUnread(paneId: 7) else {
        return false
    }
    attention.observe(paneId: 7, status: running, isVisible: false)
    guard !attention.isUnread(paneId: 7) else {
        return false
    }
    attention.observe(paneId: 8, status: done, isVisible: true)
    guard !attention.isUnread(paneId: 8) else {
        return false
    }
    attention.observe(paneId: 9, status: done, isVisible: false)
    attention.markSeen(paneId: 9)
    guard !attention.isUnread(paneId: 9) else {
        return false
    }
    attention.observe(paneId: 12, status: waiting, isVisible: false)
    guard attention.isUnread(paneId: 12), attention.unreadCount == 1 else {
        return false
    }
    guard nativeTabStatusBadge(for: [(status: "idle", unread: false)]) == nil,
        nativeTabStatusBadge(for: [(status: "done", unread: false)]) == nil,
        nativeTabStatusBadge(for: [(status: "done", unread: true)]) == .done,
        nativeTabStatusBadge(for: [
            (status: "done", unread: true),
            (status: "running", unread: false),
        ]) == .running,
        nativeTabStatusBadge(for: [
            (status: "running", unread: false),
            (status: "blocked", unread: false),
        ]) == .failed,
        nativeTabStatusBadge(for: [
            (status: "failed", unread: false),
            (status: "waiting", unread: false),
        ]) == .waiting
    else {
        return false
    }
    let previewCache = NativeWorkPreviewCache()
    guard previewCache.lookup(paneId: 20) == .missing,
        previewCache.enqueue(paneId: 20, priority: false),
        previewCache.enqueue(paneId: 21, priority: false),
        previewCache.enqueue(paneId: 21, priority: true),
        previewCache.dequeue() == 21
    else {
        return false
    }
    previewCache.store(nil, paneId: 21)
    guard previewCache.lookup(paneId: 21) == .ready(nil),
        !previewCache.enqueue(paneId: 21, priority: true)
    else {
        return false
    }
    previewCache.invalidate(paneId: 21)
    guard previewCache.lookup(paneId: 21) == .missing else {
        return false
    }
    previewCache.store(nil, paneId: 21)
    previewCache.retain(paneIds: Set([20]))
    guard previewCache.lookup(paneId: 21) == .missing,
        previewCache.dequeue() == 20
    else {
        return false
    }
    let previewSource = (0..<70).map { "line \($0)" }.joined(separator: "\n")
    guard let preview = nativeBoundedWorkPreview(previewSource),
        !preview.contains("line 5\n"),
        preview.hasPrefix("line 6\n"),
        preview.hasSuffix("line 69")
    else {
        return false
    }
    guard nativeWorkPreviewSnippet("first\n\nsecond\nthird") == "second\nthird" else {
        return false
    }

    let ordinary = NativeWorkItem(
        tabId: 1,
        tabIndex: 0,
        paneId: 10,
        paneOrdinal: 0,
        tabTitle: "api",
        paneTitle: "nvim",
        workingDirectory: "/tmp/project",
        sessionLabel: "Local",
        status: running,
        unread: false,
        active: true
    )
    let needsAttention = NativeWorkItem(
        tabId: 2,
        tabIndex: 1,
        paneId: 11,
        paneOrdinal: 0,
        tabTitle: "satin",
        paneTitle: "Codex",
        workingDirectory: "/tmp/satin",
        sessionLabel: "tmux · dev",
        status: done,
        unread: true,
        active: false
    )
    var previewCaptures = 0
    let lazyPreviewController = NativeWorkSwitcherViewController(
        items: [ordinary],
        activePaneId: ordinary.paneId,
        previewProvider: { _ in
            previewCaptures += 1
            return "preview"
        }
    )
    _ = lazyPreviewController.view
    lazyPreviewController.update(items: [ordinary])
    guard previewCaptures == 0 else {
        return false
    }
    let sorted = nativeSortedWorkItems([ordinary, needsAttention])
    guard
        ordinary.matches("api project")
            && !ordinary.matches("blocked")
            && needsAttention.matches("codex tests")
            && nativeWorkSection(for: ordinary) == .running
            && nativeWorkSection(for: needsAttention) == .attention
            && nativeWorkSection(status: "waiting", unread: false) == .attention
            && nativeWorkSection(status: "done", unread: false) == .other
            && nativeWorkDisplayRows(sorted).count == 4
            && sorted.first?.paneId == needsAttention.paneId
    else {
        return false
    }

    let badge = NativeHoverIconButton(
        symbolName: "rectangle.stack",
        title: "Work",
        supportsBadge: true
    )
    badge.setBadgeCount(12)
    guard let label = badge.subviews.compactMap({ $0 as? NSTextField }).first,
        badge.badgeCountForSmoke() == 12,
        label.stringValue == "9+",
        !label.isHidden,
        badge.toolTip == "Work — 12 need attention"
    else {
        return false
    }
    badge.setBadgeCount(0)
    return badge.badgeCountForSmoke() == 0
        && label.isHidden
        && badge.toolTip == "Work"
}

private func nativeNormalizedWorkSearch(_ value: String) -> String {
    value.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: .current
    ).lowercased()
}

private func nativeWorkSearchTokens(_ value: String) -> [Substring] {
    nativeNormalizedWorkSearch(value).split(whereSeparator: \.isWhitespace)
}

private func nativeWorkSingleLine(_ value: String, limit: Int) -> String {
    let collapsed =
        value
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return String(collapsed.prefix(limit))
}

private func nativeSortedWorkItems(_ items: [NativeWorkItem]) -> [NativeWorkItem] {
    items.sorted { lhs, rhs in
        let leftSection = nativeWorkSection(for: lhs)
        let rightSection = nativeWorkSection(for: rhs)
        if leftSection != rightSection {
            return leftSection.rawValue < rightSection.rawValue
        }
        if lhs.unread != rhs.unread {
            return lhs.unread
        }
        let leftPriority = nativeWorkStatusPriority(lhs.status?.status)
        let rightPriority = nativeWorkStatusPriority(rhs.status?.status)
        if leftPriority != rightPriority, lhs.unread {
            return leftPriority < rightPriority
        }
        if lhs.tabIndex != rhs.tabIndex {
            return lhs.tabIndex < rhs.tabIndex
        }
        return lhs.paneOrdinal < rhs.paneOrdinal
    }
}

private func nativeWorkDisplayRows(_ items: [NativeWorkItem]) -> [NativeWorkDisplayRow] {
    var itemsBySection = Array(
        repeating: [NativeWorkItem](), count: NativeWorkSection.allCases.count)
    for item in items {
        itemsBySection[nativeWorkSection(for: item).rawValue].append(item)
    }
    return NativeWorkSection.allCases.flatMap { section -> [NativeWorkDisplayRow] in
        let sectionItems = itemsBySection[section.rawValue]
        guard !sectionItems.isEmpty else {
            return []
        }
        return [.section(section, count: sectionItems.count)]
            + sectionItems.map {
                .item($0)
            }
    }
}

private func nativeWorkSection(for item: NativeWorkItem) -> NativeWorkSection {
    nativeWorkSection(status: item.status?.status, unread: item.unread)
}

private func nativeWorkSection(status: String?, unread: Bool) -> NativeWorkSection {
    switch status {
    case "waiting", "blocked", "failed": .attention
    case "done": unread ? .attention : .other
    case "running": .running
    default: .other
    }
}

private func nativeWorkStatusPriority(_ status: String?) -> Int {
    switch status {
    case "blocked": 0
    case "failed": 1
    case "waiting": 2
    case "done": 3
    case "running": 4
    default: 5
    }
}

private func nativeWorkStatusColor(_ item: NativeWorkItem) -> NSColor {
    switch item.status?.status {
    case "blocked": .systemOrange
    case "failed": .systemRed
    case "done": item.unread ? .systemGreen : .secondaryLabelColor
    case "running": .systemBlue
    case "waiting": .systemYellow
    default: item.active ? .controlAccentColor : .secondaryLabelColor
    }
}
