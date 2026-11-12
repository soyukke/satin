import AppKit

/// What the tabs made, down the right side: pages as slips, and the
/// commands, quotes, links and files their screens showed. A click opens a
/// link or a file and copies the rest. Folded, it is a rail of counts.
final class NativeItemsSidebarView: NSView {
    static let openWidth: CGFloat = 300
    /// The narrowest a drag leaves it.
    static let minWidth: CGFloat = 220
    static let railWidth: CGFloat = 48
    private static let header: CGFloat = 40
    private static let footer: CGFloat = 36
    private static let shown: [NativeItemsSection: Int] = [
        .pages: 6, .commands: 8, .links: 6, .files: 8,
    ]

    var onOpenPage: ((NativeArtifactListItem) -> Void)?
    /// Copies an item, or pastes it into the focused pane when asked.
    var onCopy: ((NativeSidebarItem, Bool) -> Void)?
    /// Opens a link or a file; says whether it could.
    var onOpen: ((NativeSidebarItem) -> Bool)?
    var onScope: ((Bool) -> Void)?
    var onFold: (() -> Void)?
    /// Hands the file on show to its app.
    var onOpenFileInApp: ((URL) -> Void)?
    /// A drag on the inner edge: the width asked for, and whether the drag
    /// has ended.
    var onResize: ((CGFloat, Bool) -> Void)?
    var onResetWidth: (() -> Void)?

    private(set) var mode: NativeSidebarMode = .open
    private var pages: [NativeArtifactListItem] = []
    private var unread = Set<String>()
    private var items: [NativeItemsSection: [NativeSidebarItem]] = [:]
    private(set) var allTabs = false
    private let document = NativeSidebarDocumentView(frame: .zero)
    private lazy var scroll = nativeSidebarScrollView(document: document)
    private let scopeChip = NativeSidebarChipView(title: "this tab")
    private let foldButton = NativeHoverIconButton(
        symbolName: "sidebar.right", title: "Fold the Items Sidebar (⌥⌘B)")
    private var content: [NSView] = []
    private var headings: [(NativeItemsSection, CGFloat)] = []
    /// The Markdown or text file shown in place of the lists.
    private(set) var file: NativeSidebarFile?
    private var fileView: NativePageDocumentView?
    private let backButton = NativeHoverIconButton(
        symbolName: "chevron.left", title: "Back to the Items")
    private let appButton = NativeHoverIconButton(
        symbolName: "arrow.up.forward.square", title: "Open in Its App")
    private let grip = NativeSidebarResizeGrip(onLeft: false, label: "Resize the Items Sidebar")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(scroll)
        addSubview(scopeChip)
        foldButton.target = self
        foldButton.action = #selector(fold)
        addSubview(foldButton)
        scopeChip.onPress = { [weak self] in
            guard let self else { return }
            self.onScope?(!self.allTabs)
        }
        backButton.target = self
        backButton.action = #selector(closeFile)
        backButton.isHidden = true
        addSubview(backButton)
        appButton.target = self
        appButton.action = #selector(openFileInApp)
        appButton.isHidden = true
        addSubview(appButton)
        grip.onDrag = { [weak self] width, ended in self?.onResize?(width, ended) }
        grip.onReset = { [weak self] in self?.onResetWidth?() }
        addSubview(grip)
        document.drawing = { [weak self] in
            self?.drawHeadings()
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Items")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    func setMode(_ mode: NativeSidebarMode) {
        guard mode != self.mode else {
            return
        }
        self.mode = mode
        foldButton.toolTip =
            mode == .open ? "Fold the Items Sidebar (⌥⌘B)" : "Open the Items Sidebar (⌥⌘B)"
        foldButton.setAccessibilityLabel(foldButton.toolTip)
        rebuild()
    }

    func update(
        pages: [NativeArtifactListItem],
        unread: Set<String>,
        items: [NativeSidebarItemKind: [NativeSidebarItemStore.Entry]],
        allTabs: Bool
    ) {
        let commands = ((items[.command] ?? []) + (items[.quote] ?? []))
            .sorted { $0.order > $1.order }.map(\.item)
        let next: [NativeItemsSection: [NativeSidebarItem]] = [
            .commands: commands,
            .links: (items[.link] ?? []).map(\.item),
            .files: (items[.file] ?? []).map(\.item),
        ]
        let pageKey = pages.map { "\($0.id)@\($0.version)" }
        let changed =
            next != self.items || pageKey != self.pages.map { "\($0.id)@\($0.version)" }
            || unread != self.unread || allTabs != self.allTabs
        self.pages = pages
        self.unread = unread
        self.items = next
        self.allTabs = allTabs
        scopeChip.title = allTabs ? "all tabs" : "this tab"
        if changed {
            rebuild()
        }
    }

    /// Shows a file where the lists are, until the back button brings them
    /// back.
    func showFile(_ file: NativeSidebarFile) {
        let again = self.file?.url == file.url
        self.file = file
        let view = fileView ?? NativePageDocumentView(frame: .zero)
        if fileView == nil {
            addSubview(view, positioned: .below, relativeTo: grip)
            fileView = view
        }
        view.show(
            folder: file.url.deletingLastPathComponent(), document: file.url.lastPathComponent,
            language: "", key: file.key, form: file.form, keepsScroll: again)
        syncFileChrome()
    }

    /// Draws the file on show again once it has been written since.
    func refreshFile() {
        guard let file, file.changed, let now = NativeSidebarFile(file.url), now != file else {
            return
        }
        showFile(now)
    }

    @objc func closeFile() {
        guard file != nil else {
            return
        }
        file = nil
        fileView?.clear()
        syncFileChrome()
    }

    @objc private func openFileInApp() {
        if let file {
            onOpenFileInApp?(file.url)
        }
    }

    /// Puts the lists or the file's page in the sidebar's body.
    private func syncFileChrome() {
        let reading = file != nil && mode == .open
        fileView?.isHidden = !reading
        backButton.isHidden = !reading
        appButton.isHidden = !reading
        scroll.isHidden = reading
        scopeChip.isHidden = reading || mode != .open
        setAccessibilityLabel(file.map { "Items, showing \($0.url.lastPathComponent)" } ?? "Items")
        needsLayout = true
        needsDisplay = true
    }

    func refreshLook() {
        needsDisplay = true
        fileView?.refreshLook()
        scopeChip.needsDisplay = true
        for view in content {
            view.needsDisplay = true
        }
    }

    func count(_ section: NativeItemsSection) -> Int {
        section == .pages ? pages.count : items[section]?.count ?? 0
    }

    private func rebuild() {
        for view in content {
            view.removeFromSuperview()
        }
        content = []
        if mode == .open {
            let ordered = pages.sorted {
                (unread.contains($0.id) ? 0 : 1, -Int64($0.updatedAtMs))
                    < (unread.contains($1.id) ? 0 : 1, -Int64($1.updatedAtMs))
            }
            for page in ordered.prefix(Self.shown[.pages] ?? 0) {
                let slip = NativePageSlipView(page: page, unread: unread.contains(page.id))
                slip.onPress = { [weak self] in self?.onOpenPage?($0) }
                content.append(slip)
            }
            for section in [NativeItemsSection.commands, .links, .files] {
                for item in (items[section] ?? []).prefix(Self.shown[section] ?? 0) {
                    let row = NativeItemRowView(item: item)
                    row.onCopy = { [weak self] item, paste in self?.onCopy?(item, paste) }
                    row.onOpen = { [weak self] in self?.onOpen?($0) ?? false }
                    content.append(row)
                }
            }
        } else {
            for section in NativeItemsSection.allCases {
                let button = NativeItemsRailButton(section: section, count: count(section))
                button.onPress = { [weak self] in self?.onFold?() }
                content.append(button)
            }
        }
        for view in content {
            document.addSubview(view)
        }
        syncFileChrome()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        headings = []
        grip.frame = NSRect(x: 0, y: 0, width: NativeSidebarResizeGrip.width, height: bounds.height)
        // Open or folded, the button stays where the pointer left it.
        foldButton.frame = NSRect(
            x: width - (Self.railWidth + 24) / 2, y: bounds.height - Self.footer + 6,
            width: 24, height: 24)
        guard mode == .open else {
            scroll.frame = NSRect(
                x: 0, y: 0, width: width, height: max(0, bounds.height - Self.footer))
            var y: CGFloat = 8
            for view in content {
                view.frame = NSRect(x: 0, y: y, width: width, height: NativeItemsRailButton.height)
                y += NativeItemsRailButton.height
            }
            document.frame = NSRect(x: 0, y: 0, width: width, height: y)
            return
        }
        scopeChip.frame = NSRect(x: width - 12 - 74, y: 11, width: 74, height: 20)
        scroll.frame = NSRect(
            x: 0, y: Self.header, width: width,
            height: max(0, bounds.height - Self.header - Self.footer))
        backButton.frame = NSRect(x: 8, y: 9, width: 24, height: 24)
        appButton.frame = NSRect(x: width - 34, y: 9, width: 24, height: 24)
        // The page starts past the rule along the sidebar's inner edge.
        fileView?.frame = NSRect(
            x: 1, y: Self.header, width: max(0, width - 1),
            height: max(0, bounds.height - Self.header - Self.footer))

        let inner = width - 24
        var y: CGFloat = 4
        let slips = content.compactMap { $0 as? NativePageSlipView }
        if !slips.isEmpty {
            headings.append((.pages, y))
            y += 20
            let slipWidth = (inner - 12) / 2
            for (index, slip) in slips.enumerated() {
                let column = CGFloat(index % 2)
                let rowY = y + CGFloat(index / 2) * (NativePageSlipView.height + 12)
                slip.frame = NSRect(
                    x: 12 + column * (slipWidth + 12), y: rowY, width: slipWidth,
                    height: NativePageSlipView.height)
            }
            y += CGFloat((slips.count + 1) / 2) * (NativePageSlipView.height + 12) + 6
        }
        let rows = content.compactMap { $0 as? NativeItemRowView }
        for section in [NativeItemsSection.commands, .links, .files] {
            let sectionRows = rows.filter { NativeItemsSection($0.item.kind) == section }
            guard !sectionRows.isEmpty else {
                continue
            }
            headings.append((section, y))
            y += 20
            for row in sectionRows {
                row.frame = NSRect(x: 12, y: y, width: inner, height: NativeItemRowView.height)
                y += NativeItemRowView.height + 3
            }
            y += 10
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.frame.height))
        document.needsDisplay = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NativeSidebarLook.drawPanel(bounds, ruleAtMaxX: false)
        guard mode == .open else {
            return
        }
        if let file {
            drawFileChrome(file)
            return
        }
        let heading = NativeSidebarLook.heading("ITEMS", color: NativePageStyle.violet)
        let size = heading.size()
        heading.draw(at: NSPoint(x: 14, y: 21 - size.height / 2))
        NativePageStyle.line.setFill()
        let ruleStart = 14 + ceil(size.width) + 8
        NSRect(x: ruleStart, y: 21, width: max(0, scopeChip.frame.minX - 8 - ruleStart), height: 1)
            .fill()
        let hint = NativeSidebarLook.text(
            "click opens · ⧉ copies · ⌥ pastes", font: NativePageStyle.sans(10),
            color: NativePageStyle.muted)
        hint.draw(
            in: NSRect(
                x: 14, y: bounds.height - Self.footer + 11, width: bounds.width - 54, height: 14))
        if content.isEmpty {
            let empty = NativeSidebarLook.text(
                "Pages, and the commands, quotes, links and files this tab shows, gather here.",
                font: NativePageStyle.sans(11), color: NativePageStyle.muted,
                breaking: .byWordWrapping)
            empty.draw(
                with: NSRect(x: 14, y: Self.header + 8, width: bounds.width - 28, height: 60),
                options: [.usesLineFragmentOrigin])
        }
    }

    /// The file's name between its two buttons, a rule under them, and
    /// where the file is along the foot.
    private func drawFileChrome(_ file: NativeSidebarFile) {
        NativeSidebarLook.text(
            file.url.lastPathComponent, font: NativePageStyle.sans(12, .semibold),
            color: NativePageStyle.text, breaking: .byTruncatingMiddle
        ).draw(in: NSRect(x: 38, y: 13, width: max(0, bounds.width - 38 - 40), height: 16))
        NativePageStyle.line.setFill()
        NSRect(x: 0, y: Self.header - 1, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - Self.footer, width: bounds.width, height: 1).fill()
        NativeSidebarLook.text(
            file.shortPath, font: NativePageStyle.mono(10, .regular), color: NativePageStyle.muted,
            breaking: .byTruncatingHead
        ).draw(
            in: NSRect(
                x: 14, y: bounds.height - Self.footer + 11, width: bounds.width - 54, height: 14))
    }

    private func drawHeadings() {
        for (section, y) in headings {
            NativeSidebarLook.heading(
                "\(section.title) · \(count(section))", color: NativePageStyle.muted
            ).draw(at: NSPoint(x: 14, y: y + 2))
        }
    }

    @objc private func fold() {
        onFold?()
    }

    func rowsForSmoke() -> [NativeSidebarItem] {
        content.compactMap { ($0 as? NativeItemRowView)?.item }
    }

    /// Presses the first row of a kind as a click would, pasting when asked.
    func pressFirstRowForSmoke(_ kind: NativeSidebarItemKind, paste: Bool) {
        content.lazy.compactMap { $0 as? NativeItemRowView }
            .first { $0.item.kind == kind }?
            .pressForSmoke(paste: paste)
    }

    /// Presses the row of the file whose path ends in `name`, or of the
    /// first file when none does.
    func pressFileRowForSmoke(named name: String, _ action: NativeItemRowAction) {
        let files = content.compactMap { $0 as? NativeItemRowView }.filter {
            $0.item.kind == .file
        }
        (files.first { $0.item.text.hasSuffix(name) } ?? files.first)?.pressForSmoke(action)
    }
}

/// The groups the items sidebar shows.
enum NativeItemsSection: Int, CaseIterable {
    case pages
    case commands
    case links
    case files

    init(_ kind: NativeSidebarItemKind) {
        switch kind {
        case .command, .quote: self = .commands
        case .link: self = .links
        case .file: self = .files
        }
    }

    var title: String {
        switch self {
        case .pages: "PAGES"
        case .commands: "COMMANDS · QUOTES"
        case .links: "LINKS"
        case .files: "FILES"
        }
    }

    var glyph: String {
        switch self {
        case .pages: "▤"
        case .commands: "!"
        case .links: "↗"
        case .files: "±"
        }
    }

    var color: NSColor {
        switch self {
        case .pages: NativePageStyle.teal
        case .commands: NativeSidebarLook.color(.command)
        case .links: NativeSidebarLook.color(.link)
        case .files: NativeSidebarLook.color(.file)
        }
    }
}

/// A square with a section's glyph: filled in the terminal look, stamped
/// in ink on paper.
private func nativeDrawItemBadge(_ glyph: String, color: NSColor, in rect: NSRect) {
    let box = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
    let ink: NSColor
    if NativePageStyle.paper {
        NativePageStyle.surface.setFill()
        box.fill()
        box.lineWidth = 2
        NativePageStyle.text.setStroke()
        box.stroke()
        ink = color
    } else {
        color.setFill()
        box.fill()
        ink = NativeSidebarLook.stock
    }
    let text = NativeSidebarLook.text(
        glyph, font: NativePageStyle.mono(rect.height * 0.6, .heavy), color: ink,
        alignment: .center)
    let height = text.size().height
    text.draw(
        in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
}

/// What a press on a row does.
enum NativeItemRowAction: Equatable {
    case open
    case copy
    case paste
}

/// One thing to open or copy: its badge, its text, and where it came from.
/// A link or a file opens on a click and copies from the button at its
/// end; the rest copy on a click. It says so for a moment after.
final class NativeItemRowView: NSView {
    static let height: CGFloat = 26
    /// The copy button's width at the row's end.
    static let copyWidth: CGFloat = 32

    let item: NativeSidebarItem
    var onCopy: ((NativeSidebarItem, Bool) -> Void)?
    var onOpen: ((NativeSidebarItem) -> Bool)?
    private var hovering = false
    private var overCopy = false
    private var note: (text: String, color: NSColor, at: Date)?
    private var hoverArea: NSTrackingArea?

    /// A click on a row `width` wide at `x`: ⌥ pastes, the copy button
    /// copies, and the rest of a link or a file opens it.
    static func action(
        kind: NativeSidebarItemKind, x: CGFloat, width: CGFloat, option: Bool
    ) -> NativeItemRowAction {
        if option {
            return .paste
        }
        guard kind == .link || kind == .file else {
            return .copy
        }
        return x >= width - copyWidth ? .copy : .open
    }

    private var opens: Bool {
        item.kind == .link || item.kind == .file
    }

    init(item: NativeSidebarItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "\(item.text)\n\(item.detail)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel((opens ? "Open " : "Copy ") + item.text)
        setAccessibilityHelp(item.detail)
        if opens {
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Copy") { [weak self] in
                    self?.press(.copy)
                    return true
                }
            ])
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let paper = NativePageStyle.paper
        let box = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NativePageStyle.raised.withAlphaComponent(paper ? 0.6 : 1).setFill()
        box.fill()
        (hovering ? NativeSidebarLook.color(item.kind) : NativePageStyle.line).setStroke()
        box.lineWidth = 1
        box.stroke()

        nativeDrawItemBadge(
            item.kind.glyph, color: NativeSidebarLook.color(item.kind),
            in: NSRect(x: 7, y: (bounds.height - 16) / 2, width: 16, height: 16))

        // One line: the item, and for a moment after a click what the
        // click did. Where it came from is in the tooltip.
        var textRight = bounds.width - (hovering ? 34 : 8)
        if let noted = note.flatMap({ Date().timeIntervalSince($0.at) < 1.2 ? $0 : nil }) {
            let word = NativeSidebarLook.text(
                noted.text, font: NativePageStyle.sans(10, .bold), color: noted.color,
                alignment: .right)
            let width = ceil(word.size().width)
            word.draw(
                in: NSRect(
                    x: textRight - width, y: (bounds.height - 14) / 2, width: width, height: 14))
            textRight -= width + 6
        }
        let middle = item.kind == .link || item.kind == .file
        NativeSidebarLook.text(
            item.text.replacingOccurrences(of: "\n", with: " "),
            font: NativePageStyle.mono(11, .regular), color: NativePageStyle.text,
            breaking: middle ? .byTruncatingMiddle : .byTruncatingTail
        ).draw(
            in: NSRect(
                x: 30, y: (bounds.height - 15) / 2, width: max(0, textRight - 30), height: 15))

        guard hovering,
            let icon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        else {
            return
        }
        if opens, overCopy {
            NativePageStyle.line.setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: bounds.width - 31, y: (bounds.height - 24) / 2, width: 24, height: 24),
                xRadius: 5, yRadius: 5
            ).fill()
        }
        let tint = opens && overCopy ? NativePageStyle.text : NativePageStyle.muted
        let tinted = NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(
            in: NSRect(
                x: bounds.width - 26, y: (bounds.height - icon.size.height) / 2,
                width: icon.size.width, height: icon.size.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let over = convert(event.locationInWindow, from: nil).x >= bounds.width - Self.copyWidth
        if over != overCopy {
            overCopy = over
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        overCopy = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        press(
            Self.action(
                kind: item.kind, x: point.x, width: bounds.width, option: flags.contains(.option)))
    }

    override func accessibilityPerformPress() -> Bool {
        press(opens ? .open : .copy)
        return true
    }

    /// Shows the pointer over the row while it presses it.
    func pressForSmoke(paste: Bool) {
        pressForSmoke(paste ? .paste : .copy)
    }

    func pressForSmoke(_ action: NativeItemRowAction) {
        hovering = true
        press(action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.hovering = false
            self?.needsDisplay = true
        }
    }

    private func press(_ action: NativeItemRowAction) {
        let color: NSColor
        switch action {
        case .open:
            let opened = onOpen?(item) == true
            color = opened ? NativeSidebarLook.color(item.kind) : NativePageStyle.muted
            note = (opened ? "Opened" : "Not found", color, Date())
            if !opened {
                NSSound.beep()
            }
        case .copy, .paste:
            onCopy?(item, action == .paste)
            color = NativePageStyle.teal
            note = ("Copied", color, Date())
        }
        NativeHandEffects.flash(layer, color: color)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            self?.needsDisplay = true
        }
    }
}

/// A page as a slip: a strip with its version, its title, and a mark while
/// it is unread. On paper it is taped down.
final class NativePageSlipView: NSView {
    static let height: CGFloat = 84

    let page: NativeArtifactListItem
    let unread: Bool
    var onPress: ((NativeArtifactListItem) -> Void)?
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    init(page: NativeArtifactListItem, unread: Bool) {
        self.page = page
        self.unread = unread
        super.init(frame: .zero)
        toolTip = page.title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open page \(page.title)" + (unread ? ", unread" : ""))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let paper = NativePageStyle.paper
        let sheet =
            paper
            ? NSRect(x: 0, y: 6, width: bounds.width - 5, height: bounds.height - 11)
            : bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: sheet, xRadius: paper ? 4 : 6, yRadius: paper ? 4 : 6)
        let strip = NSRect(x: sheet.minX, y: sheet.minY, width: sheet.width, height: 17)
        let version = "@\(page.version)"
        if paper {
            NativePageStyle.teal.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: sheet.offsetBy(dx: 5, dy: 5), xRadius: 4, yRadius: 4).fill()
            NativePageStyle.surface.setFill()
            shape.fill()
            shape.lineWidth = 2
            NativePageStyle.text.setStroke()
            shape.stroke()
            NativePageStyle.line.setFill()
            NSRect(x: sheet.minX + 2, y: strip.maxY, width: sheet.width - 4, height: 1).fill()
        } else {
            NativePageStyle.raised.setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NativePageStyle.teal.setFill()
            strip.fill()
            NSGraphicsContext.restoreGraphicsState()
            NativePageStyle.violet.withAlphaComponent(hovering ? 0.9 : 0.5).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        let stripInk = paper ? NativePageStyle.teal : NativePageStyle.ink
        NativeSidebarLook.text(
            "PAGE", font: NativePageStyle.mono(9, .bold), color: stripInk, kern: 1
        ).draw(at: NSPoint(x: sheet.minX + 7, y: strip.minY + 3))
        NativeSidebarLook.text(
            version, font: NativePageStyle.mono(9, .bold), color: stripInk, alignment: .right
        ).draw(in: NSRect(x: sheet.minX, y: strip.minY + 3, width: sheet.width - 7, height: 12))

        let titleFont = paper ? NativePageStyle.serif(12) : NativePageStyle.sans(12, .heavy)
        NativeSidebarLook.text(
            page.title, font: titleFont, color: paper ? NativePageStyle.text : .white,
            breaking: .byWordWrapping
        ).draw(
            with: NSRect(
                x: sheet.minX + 7, y: strip.maxY + 5, width: sheet.width - 14, height: 32),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NativePageStyle.line.setFill()
        NSRect(x: sheet.minX + 7, y: sheet.maxY - 12, width: (sheet.width - 14) * 0.9, height: 2)
            .fill()
        NSRect(x: sheet.minX + 7, y: sheet.maxY - 7, width: (sheet.width - 14) * 0.65, height: 2)
            .fill()

        if unread {
            let dot = NSRect(x: sheet.maxX - 12, y: strip.maxY + 6, width: 7, height: 7)
            NativePageStyle.amber.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        if paper {
            NativePageStyle.violet.withAlphaComponent(0.45).setFill()
            let tape = NSBezierPath(rect: NSRect(x: -20, y: -6, width: 40, height: 12))
            var transform = AffineTransform(translationByX: sheet.midX, byY: sheet.minY)
            transform.rotate(byDegrees: -4)
            tape.transform(using: transform)
            tape.fill()
        }
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onPress?(page)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(page)
        return true
    }
}

/// A section on the folded rail: its badge and how many it holds.
final class NativeItemsRailButton: NSView {
    static let height: CGFloat = 46

    let section: NativeItemsSection
    let count: Int
    var onPress: (() -> Void)?

    init(section: NativeItemsSection, count: Int) {
        self.section = section
        self.count = count
        super.init(frame: .zero)
        toolTip = "\(section.title.capitalized): \(count)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(section.title.capitalized), \(count)")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let badge = NSRect(x: bounds.midX - 14, y: 8, width: 28, height: 28)
        nativeDrawItemBadge(section.glyph, color: section.color, in: badge)
        guard count > 0 else {
            return
        }
        let label = NativeSidebarLook.text(
            count > 99 ? "99+" : String(count), font: NativePageStyle.sans(9, .bold),
            color: NativePageStyle.paper ? NativePageStyle.surface : NativePageStyle.ink,
            alignment: .center)
        let width = max(16, ceil(label.size().width) + 6)
        let bubble = NSRect(x: badge.maxX - width + 6, y: badge.minY - 6, width: width, height: 16)
        NativePageStyle.violet.setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 8, yRadius: 8).fill()
        label.draw(in: bubble.offsetBy(dx: 0, dy: 2))
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onPress?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// A small outlined word that does one thing when pressed.
final class NativeSidebarChipView: NSView {
    var title: String {
        didSet {
            if title != oldValue {
                setAccessibilityLabel("Show items of \(title)")
                needsDisplay = true
            }
        }
    }

    var onPress: (() -> Void)?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show items of \(title)")
        toolTip = "Show the items of this tab or of every tab"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NativePageStyle.line.setStroke()
        box.lineWidth = 1
        box.stroke()
        let label = NativeSidebarLook.text(
            "\(title) ▾", font: NativePageStyle.sans(10, .medium), color: NativePageStyle.muted,
            alignment: .center)
        label.draw(in: bounds.insetBy(dx: 4, dy: 3))
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onPress?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
