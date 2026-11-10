import AppKit

/// The two sidebars beside the panes: the tabs as cards on the left, what
/// they made on the right. Each opens, folds to a rail, or (the left one)
/// gives its place back to the tab bar.
extension TerminalShellViewController {
    private static let windowsSidebarKey = "SatinWindowsSidebar"
    private static let itemsSidebarKey = "SatinItemsSidebar"
    private static let itemsSidebarWidthKey = "SatinItemsSidebarWidth"
    private static let scanInterval: TimeInterval = 1.5

    /// A smoke run sets both sidebars from its environment and saves
    /// nothing; without one there, smokes keep the tab bar they were
    /// written for.
    private static var smokeSidebars: [NativeSidebarMode]? {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["SATIN_NATIVE_SMOKE_SIDEBARS"] {
            let modes = value.split(separator: ",").compactMap {
                NativeSidebarMode(rawValue: String($0))
            }
            return modes.count == 2 ? modes : [.off, .off]
        }
        return environment["SATIN_NATIVE_SMOKE_SCENARIO"] == nil ? nil : [.off, .off]
    }

    var windowsSidebarMode: NativeSidebarMode {
        get {
            if let smoke = Self.smokeSidebars {
                return smokeWindowsSidebar ?? smoke[0]
            }
            return UserDefaults.standard.string(forKey: Self.windowsSidebarKey)
                .flatMap(NativeSidebarMode.init(rawValue:)) ?? .open
        }
        set {
            if Self.smokeSidebars != nil {
                smokeWindowsSidebar = newValue
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.windowsSidebarKey)
            }
        }
    }

    var itemsSidebarMode: NativeSidebarMode {
        get {
            if let smoke = Self.smokeSidebars {
                return smokeItemsSidebar ?? smoke[1]
            }
            return UserDefaults.standard.string(forKey: Self.itemsSidebarKey)
                .flatMap(NativeSidebarMode.init(rawValue:)) ?? .rail
        }
        set {
            if Self.smokeSidebars != nil {
                smokeItemsSidebar = newValue
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.itemsSidebarKey)
            }
        }
    }

    func configureSidebars() {
        installShortcutHints()
        windowsSidebar.onSelect = { [weak self] index in
            self?.selectTab(index)
        }
        windowsSidebar.onRename = { [weak self] index in
            self?.renameTab(at: index)
        }
        windowsSidebar.tabMenu = { [weak self] index in
            self?.tabContextMenu(index: index)
        }
        windowsSidebar.onNewTab = { [weak self] in
            self?.newTab(nil)
        }
        windowsSidebar.onSessions = { [weak self] button in
            self?.showSessionSwitcher(button)
        }
        windowsSidebar.onFold = { [weak self] in
            self?.toggleWindowsSidebar(nil)
        }
        itemsSidebar.onOpenPage = { [weak self] page in
            self?.openPage(page)
        }
        itemsSidebar.onCopy = { [weak self] item, paste in
            self?.copySidebarItem(item, paste: paste)
        }
        itemsSidebar.onOpen = { [weak self] item in
            self?.openSidebarItem(item) ?? false
        }
        itemsSidebar.onScope = { [weak self] allTabs in
            self?.sidebarItemsAllTabs = allTabs
            self?.refreshItemsSidebar()
        }
        itemsSidebar.onFold = { [weak self] in
            self?.toggleItemsSidebar(nil)
        }
        itemsSidebar.onOpenFileInApp = { [weak self] url in
            _ = self?.openLinkOrFile(url)
        }
        itemsSidebar.onResize = { [weak self] width, ended in
            self?.resizeItemsSidebar(to: width, ended: ended)
        }
        itemsSidebar.onResetWidth = { [weak self] in
            self?.resizeItemsSidebar(to: nil, ended: true)
        }
    }

    /// The width the items sidebar takes, open: the one a drag is asking
    /// for or last left, kept within the window.
    var itemsSidebarOpenWidth: CGFloat {
        let saved =
            Self.smokeSidebars == nil
            ? UserDefaults.standard.object(forKey: Self.itemsSidebarWidthKey) as? Double : nil
        let wanted =
            itemsSidebarDragWidth ?? saved.map { CGFloat($0) }
            ?? NativeItemsSidebarView.openWidth
        // Before the window has a size there is nothing to keep within.
        guard view.bounds.width > 0 else {
            return max(NativeItemsSidebarView.minWidth, wanted)
        }
        return nativeItemsSidebarWidth(
            wanted: wanted, room: view.bounds.width - (windowsSidebarWidth?.constant ?? 0))
    }

    /// Follows a drag on the sidebar's inner edge, and keeps the width the
    /// drag ends at. No width gives the sidebar its own back.
    func resizeItemsSidebar(to width: CGFloat?, ended: Bool) {
        guard itemsSidebarMode == .open else {
            return
        }
        itemsSidebarDragWidth = width
        let shown = itemsSidebarOpenWidth
        if ended, Self.smokeSidebars == nil {
            if width == nil {
                UserDefaults.standard.removeObject(forKey: Self.itemsSidebarWidthKey)
            } else {
                UserDefaults.standard.set(Double(shown), forKey: Self.itemsSidebarWidthKey)
            }
            itemsSidebarDragWidth = nil
        }
        itemsSidebarWidth?.constant = shown
        view.needsLayout = true
    }

    /// Narrows the open items sidebar when the window no longer has room
    /// for the width it was left at, and widens it back when it does.
    func fitItemsSidebarWidth() {
        guard itemsSidebarMode == .open, let constraint = itemsSidebarWidth else {
            return
        }
        let width = itemsSidebarOpenWidth
        if abs(constraint.constant - width) > 0.5 {
            constraint.constant = width
        }
    }

    /// Puts both sidebars in their modes, and the tab bar and the two
    /// hands where those leave room for them.
    func applySidebarModes() {
        let left = windowsSidebarMode
        let right = itemsSidebarMode
        windowsSidebar.setMode(left == .rail ? .rail : .open)
        itemsSidebar.setMode(right == .rail ? .rail : .open)
        windowsSidebar.isHidden = left == .off
        itemsSidebar.isHidden = right == .off
        windowsSidebarWidth?.constant = Self.width(
            left, open: NativeWindowsSidebarView.openWidth,
            rail: NativeWindowsSidebarView.railWidth)
        itemsSidebarWidth?.constant = Self.width(
            right, open: itemsSidebarOpenWidth, rail: NativeItemsSidebarView.railWidth)
        tabStripView.isHidden = left != .off
        updateAttentionHandVisibility()
        updatePageHandVisibility()
        updateSidebarScanning()
        refreshSidebars()
        view.needsLayout = true
    }

    private static func width(_ mode: NativeSidebarMode, open: CGFloat, rail: CGFloat) -> CGFloat {
        switch mode {
        case .open: open
        case .rail: rail
        case .off: 0
        }
    }

    /// The hand lies over the panes only while the windows sidebar is not
    /// open: open, its cards are the hand.
    func updateAttentionHandVisibility() {
        setAttentionHandVisible(settings.attentionHand && windowsSidebarMode != .open)
    }

    /// The unread pages fan out over the panes only while the items sidebar
    /// is not open to show them.
    func updatePageHandVisibility() {
        let open = itemsSidebarMode == .open
        pageHandView.isHidden = open
        attentionHandView.rightReserve = open ? 0 : pageHandView.fanWidth
    }

    @objc func toggleWindowsSidebar(_ sender: Any?) {
        windowsSidebarMode = windowsSidebarMode == .open ? .rail : .open
        applySidebarModes()
    }

    @objc func toggleItemsSidebar(_ sender: Any?) {
        itemsSidebarMode = itemsSidebarMode == .open ? .rail : .open
        applySidebarModes()
    }

    /// Gives the windows sidebar's place to the tab bar, or takes it back.
    @objc func toggleTabBar(_ sender: Any?) {
        windowsSidebarMode = windowsSidebarMode == .off ? .open : .off
        applySidebarModes()
    }

    func refreshSidebars() {
        refreshWindowsSidebar()
        refreshItemsSidebar()
    }

    func refreshWindowsSidebar() {
        guard windowsSidebarMode != .off, let snapshot = lastSnapshot else {
            return
        }
        let rows = nativeWindowRows(
            tabs: snapshot.tabs.map(NativeAttentionTab.init),
            activeTabIndex: snapshot.active_tab,
            status: { [paneStatuses] in paneStatuses.status(for: $0) },
            isUnread: { [workAttentionStore] in workAttentionStore.isUnread(paneId: $0) },
            shellBadge: { [weak self] in self?.shellCommandBadge([$0]) },
            screenLine: { [sidebarScreenLines] in sidebarScreenLines[$0] },
            nextPaneId: currentAttentionHand().cards.first?.paneId
        )
        windowsSidebar.update(rows: rows, sessionName: tmuxSession?.sessionName ?? "local")
    }

    func refreshItemsSidebar() {
        guard itemsSidebarMode != .off else {
            return
        }
        let tabs = lastSnapshot?.tabs ?? []
        let active = tabs.first { $0.index == lastSnapshot?.active_tab }
        let panes = sidebarItemsAllTabs ? nil : Set(active?.panes ?? [])
        itemsSidebar.update(
            pages: pageInbox.pages,
            unread: Set(pageInbox.unread.map(\.id)),
            items: sidebarItems.items(panes: panes),
            allTabs: sidebarItemsAllTabs
        )
    }

    /// Reads every pane's screen now and then while the items sidebar is
    /// there to show what turns up.
    func updateSidebarScanning() {
        let scanning = itemsSidebarMode != .off || windowsSidebarMode != .off
        if scanning, sidebarScanTimer == nil {
            let timer = Timer(timeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
                self?.scanSidebarScreens()
            }
            RunLoop.main.add(timer, forMode: .common)
            sidebarScanTimer = timer
            scanSidebarScreens()
        } else if !scanning {
            sidebarScanTimer?.invalidate()
            sidebarScanTimer = nil
        }
    }

    func scanSidebarScreens() {
        let panes = (lastSnapshot?.tabs ?? []).flatMap(\.panes)
        sidebarItems.keep(panes: Set(panes))
        var found = false
        var lines: [Int: String] = [:]
        for paneId in panes {
            guard let runtime = paneStore.runtimes[paneId] else {
                continue
            }
            let screen = runtime.controlScreenText()
            lines[paneId] = nativeHandArtLines(screen, count: 1, width: 120).first
            if itemsSidebarMode != .off,
                sidebarItems.scan(
                    paneId: paneId, screen: screen, columns: paneGridSize(paneId).cols)
            {
                found = true
            }
        }
        sidebarScreenLines = lines
        itemsSidebar.refreshFile()
        refreshWindowsSidebar()
        if found {
            refreshItemsSidebar()
        }
    }

    /// Opens a link in the browser, or a file in its app. A Markdown or
    /// text file is shown in the sidebar itself.
    func openSidebarItem(_ item: NativeSidebarItem) -> Bool {
        guard let url = sidebarItemURL(item) else {
            return false
        }
        if item.kind == .file, let file = NativeSidebarFile(url) {
            itemsSidebar.showFile(file)
            return true
        }
        return openLinkOrFile(url)
    }

    /// Where an item leads: a web link, or a file that is there. A relative
    /// path reads against the folder of a pane that showed it.
    func sidebarItemURL(_ item: NativeSidebarItem) -> URL? {
        switch item.kind {
        case .link:
            guard let url = URL(string: item.text), ["http", "https"].contains(url.scheme ?? "")
            else {
                return nil
            }
            return url
        case .file:
            let folders = sidebarItems.panes(showing: item).map {
                paneWorkingDirectory(paneId: $0, logFailure: false, current: true)
            }
            for folder in folders + [nil] {
                if let url = nativeTerminalFileURL(item.text, cwd: folder) {
                    return url
                }
            }
            return nil
        case .command, .quote:
            return nil
        }
    }

    /// Copies an item; asked to paste, also types it into the focused pane
    /// the way ⌘V would.
    func copySidebarItem(_ item: NativeSidebarItem, paste: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        guard paste else {
            return
        }
        _ = pasteClipboard()
        focusTerminal()
    }
}
