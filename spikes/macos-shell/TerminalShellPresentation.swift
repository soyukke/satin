import AppKit
import Foundation

extension TerminalShellViewController {
    func syncFromCore() {
        guard let snapshot = core.snapshot() else {
            return
        }

        lastSnapshot = snapshot
        syncTabs(snapshot)
        syncPaneLayout(snapshot)
        syncActivePane(snapshot)
        view.window?.title = windowTitle(snapshot)
    }

    func selectTab(_ index: Int) {
        if let session = tmuxSession,
            let tab = lastSnapshot?.tabs.first(where: { $0.index == index }),
            let windowId = session.tmuxWindowIds[tab.id]
        {
            _ = session.gateway.tmuxCommand("select-window -t @\(windowId)")
            focusTerminal()
            return
        }
        _ = core.selectTab(index)
        syncFromCore()
        focusTerminal()
    }

    func selectPane(_ paneId: Int) {
        if let session = tmuxSession, let tmuxPaneId = session.tmuxPaneIds[paneId] {
            guard session.gateway.tmuxCommand("select-pane -t %\(tmuxPaneId)") else {
                return
            }
            activePaneId = paneId
            updateActiveFrame()
            focusTerminal()
            return
        }
        guard core.selectPane(paneId) else {
            return
        }
        syncFromCore()
        focusTerminal()
    }

    func selectTabForContextMenu(_ index: Int) {
        if let session = tmuxSession,
            let tab = lastSnapshot?.tabs.first(where: { $0.index == index }),
            let windowId = session.tmuxWindowIds[tab.id]
        {
            _ = session.gateway.tmuxCommand("select-window -t @\(windowId)")
            return
        }
        guard core.selectTab(index) else {
            return
        }
        syncFromCore()
    }

    func syncTabs(_ snapshot: TerminalCoreSnapshot) {
        let previousFrame = tabControl.frame
        syncingTabs = true
        tabControl.segmentCount = snapshot.tabs.count
        for (idx, tab) in snapshot.tabs.enumerated() {
            tabControl.setLabel(tab.title, forSegment: idx)
            tabControl.setWidth(tabWidth(for: tab.title), forSegment: idx)
            tabControl.setToolTip(
                "Click to select; use × to close; double-click or right-click for tab actions",
                forSegment: idx
            )
        }
        if snapshot.active_tab < tabControl.segmentCount {
            tabControl.selectedSegment = snapshot.active_tab
        }
        tabControl.finishSnapshotSync(previousFrame: previousFrame)
        tabStripView.contentSizeDidChange()
        let activeTheme = snapshot.tabs.first {
            $0.index == snapshot.active_tab
        }?.theme
        backdropView.updateAccentColor(themeAccentColor(activeTheme))
        updateSessionControl()
        syncingTabs = false
    }

    func syncPaneLayout(_ snapshot: TerminalCoreSnapshot) {
        guard let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab }) else {
            paneStore.visibleFrames = [:]
            terminalTextView.updatePaneFrames([:], paneBounds: [:], activePaneId: nil)
            return
        }
        var paneBounds: [Int: NSRect] = [:]
        var dividers: [NativePaneDivider] = []
        collectPaneFrames(
            tab.layout,
            rect: terminalTextView.terminalContentRect(),
            frames: &paneBounds,
            dividers: &dividers
        )
        let frames = paneBounds.mapValues(nativePaneContentFrame)
        paneStore.visibleFrames = frames
        terminalTextView.updatePaneFrames(
            frames,
            paneBounds: paneBounds,
            activePaneId: tab.active_pane,
            dividers: dividers
        )
        for (paneId, frame) in frames {
            let pane = terminalPane(for: paneId)
            if !(pane is RustTmuxPane) {
                pane?.resize(
                    grid: terminalTextView.terminalGridSize(for: frame, paneId: paneId)
                )
            }
        }
        syncTmuxClientSize()
    }

    func syncTmuxClientSize() {
        guard let session = tmuxSession else {
            return
        }
        let grid = tmuxClientGrid()
        if session.lastClientGrid?.cols == grid.cols,
            session.lastClientGrid?.rows == grid.rows
        {
            return
        }
        guard session.gateway.tmuxCommand("refresh-client -C \(grid.cols),\(grid.rows)") else {
            return
        }
        session.lastClientGrid = (grid.cols, grid.rows)
    }

    func tmuxClientGrid() -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        terminalTextView.terminalGridSize(
            for: nativePaneContentFrame(terminalTextView.terminalContentRect()),
            paneId: nil
        )
    }

    func collectPaneFrames(
        _ layout: PaneLayoutSnapshot,
        rect: NSRect,
        frames: inout [Int: NSRect],
        dividers: inout [NativePaneDivider]
    ) {
        if layout.kind == "leaf", let paneId = layout.pane_id {
            frames[paneId] = rect.insetBy(dx: 1, dy: 1)
            return
        }
        guard let axis = layout.axis, let first = layout.first, let second = layout.second else {
            return
        }
        let ratio = CGFloat(min(max(layout.ratio ?? 0.5, 0.05), 0.95))
        if let dividerAxis = NativePaneDividerAxis(rawValue: axis),
            let firstMarker = paneId(
                at: dividerAxis == .vertical ? .trailing : .bottom,
                in: first
            ),
            let secondMarker = paneId(
                at: dividerAxis == .vertical ? .leading : .top,
                in: second
            )
        {
            dividers.append(
                NativePaneDivider(
                    axis: dividerAxis,
                    containerRect: rect,
                    firstPaneId: firstMarker,
                    secondPaneId: secondMarker,
                    ratio: ratio
                ))
        }
        if axis == "vertical" {
            let firstWidth = floor(rect.width * ratio)
            collectPaneFrames(
                first,
                rect: NSRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                frames: &frames,
                dividers: &dividers
            )
            collectPaneFrames(
                second,
                rect: NSRect(
                    x: rect.minX + firstWidth,
                    y: rect.minY,
                    width: rect.width - firstWidth,
                    height: rect.height
                ),
                frames: &frames,
                dividers: &dividers
            )
        } else {
            let firstHeight = floor(rect.height * ratio)
            collectPaneFrames(
                first,
                rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight),
                frames: &frames,
                dividers: &dividers
            )
            collectPaneFrames(
                second,
                rect: NSRect(
                    x: rect.minX,
                    y: rect.minY + firstHeight,
                    width: rect.width,
                    height: rect.height - firstHeight
                ),
                frames: &frames,
                dividers: &dividers
            )
        }
    }

    func firstPaneId(in layout: PaneLayoutSnapshot) -> Int? {
        if layout.kind == "leaf" {
            return layout.pane_id
        }
        return layout.first.flatMap(firstPaneId) ?? layout.second.flatMap(firstPaneId)
    }

    enum PaneBoundaryEdge {
        case leading
        case trailing
        case top
        case bottom
    }

    func paneId(
        at edge: PaneBoundaryEdge,
        in layout: PaneLayoutSnapshot
    ) -> Int? {
        if layout.kind == "leaf" {
            return layout.pane_id
        }
        guard let axis = layout.axis,
            let first = layout.first,
            let second = layout.second
        else {
            return nil
        }
        let boundaryChild =
            switch (axis, edge) {
            case ("vertical", .trailing), ("horizontal", .bottom): second
            default: first
            }
        return paneId(at: edge, in: boundaryChild)
    }

    func themeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Color Theme", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for theme in nativeThemeNames {
            let themeItem = menuItem(theme, #selector(setThemeFromMenu(_:)))
            themeItem.representedObject = theme
            themeItem.image = colorSwatchImage(themeAccentColor(theme))
            themeItem.state = theme == activeTheme() ? .on : .off
            submenu.addItem(themeItem)
        }
        item.submenu = submenu
        return item
    }

    func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func activeTheme() -> String? {
        guard let snapshot = lastSnapshot else {
            return nil
        }
        return snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.theme
    }

    func windowTitle(_ snapshot: TerminalCoreSnapshot) -> String {
        let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab })
        if let session = tmuxSession {
            return "\(tab?.title ?? session.sessionName) — tmux · \(session.sessionName) — "
                + nativeApplicationName
        }
        return "\(tab?.title ?? nativeApplicationName) — \(nativeApplicationName)"
    }

    func configureTabControl() {
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        NativePlatformAppearance.configureTabControl(tabControl)
        tabControl.trackingMode = .selectOne
        tabControl.target = self
        tabControl.action = #selector(tabControlChanged(_:))
        tabControl.onRenameRequested = { [weak self] index in
            self?.renameTab(at: index)
        }
        tabControl.onCloseRequested = { [weak self] index in
            self?.closeTab(at: index) ?? false
        }
        tabControl.contextMenuProvider = { [weak self] index in
            self?.tabContextMenu(index: index)
        }
        tabControl.setAccessibilityLabel("Terminal Tabs")
        tabControl.setAccessibilityHelp(
            "Click a tab to select it, use its close button to close it, "
                + "or double-click or right-click for tab actions."
        )
        newTabButton.target = self
        newTabButton.action = #selector(newTab(_:))
    }

    func configureToolbarControls() {
        sessionControlButton.title = "Local"
        sessionControlButton.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Local Terminal"
        )
        sessionControlButton.imagePosition = .imageLeading
        sessionControlButton.imageHugsTitle = true
        sessionControlButton.cell?.wraps = false
        sessionControlButton.cell?.lineBreakMode = .byTruncatingTail
        sessionControlButton.target = self
        sessionControlButton.action = #selector(showSessionSwitcher(_:))
        sessionControlButton.toolTip = "Switch between the local terminal and tmux sessions"
        sessionControlButton.setAccessibilityLabel("Terminal Session")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            SatinToolbarItemIdentifier.tabs,
            .flexibleSpace,
            SatinToolbarItemIdentifier.controls,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case SatinToolbarItemIdentifier.tabs:
            item.label = "Tabs"
            item.paletteLabel = "Terminal Tabs"
            item.view = tabStripView
            item.visibilityPriority = .standard
        case SatinToolbarItemIdentifier.controls:
            item.label = "Session"
            item.paletteLabel = "Terminal Session"
            item.view = sessionControlButton
            item.visibilityPriority = .high
        default:
            return nil
        }
        return item
    }

    @objc func showSessionSwitcher(_ sender: Any?) {
        if sessionPopover?.isShown == true {
            dismissSessionPopover()
            return
        }
        let controller = TmuxSessionPopoverController(
            currentSessionName: tmuxSession?.sessionName
        )
        controller.onSelectLocal = { [weak self] in
            self?.dismissSessionPopover()
            self?.detachTmuxSession()
        }
        controller.onSelectSession = { [weak self] descriptor in
            self?.dismissSessionPopover()
            self?.attachTmuxSession(descriptor)
        }
        controller.onCreateSession = { [weak self] name in
            self?.dismissSessionPopover()
            self?.createTmuxSession(named: name)
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        sessionPopover = popover
        popover.show(
            relativeTo: sessionControlButton.bounds,
            of: sessionControlButton,
            preferredEdge: .maxY
        )
        loadTmuxSessions(into: controller)
    }

    func loadTmuxSessions(into controller: TmuxSessionPopoverController) {
        if let session = tmuxSession {
            guard session.gateway.tmuxCommand(nativeTmuxSessionListCommand) else {
                controller.update(
                    sessions: currentTmuxSessionAdded(to: []),
                    status: "Satin could not query the attached tmux server.",
                    canCreate: false,
                    isError: true
                )
                return
            }
            return
        }
        NativeTmuxExecutableResolver.shared.resolve(
            configuredPath: settings.tmuxExecutablePath,
            shellPath: settings.shellPath
        ) { [weak self, weak controller] resolution in
            guard let self, let controller,
                self.sessionPopover?.contentViewController === controller
            else {
                return
            }
            switch resolution {
            case .available(let executable):
                self.resolvedTmuxExecutable = executable
                NativeTmuxSessionDiscovery.discover(
                    executable: executable,
                    socketPath: self.preferredTmuxSocketPath()
                ) { [weak self, weak controller] result in
                    guard let self, let controller,
                        self.sessionPopover?.contentViewController === controller
                    else {
                        return
                    }
                    switch result {
                    case .sessions(let sessions):
                        controller.update(
                            sessions: self.currentTmuxSessionAdded(to: sessions),
                            status: sessions.isEmpty ? "No tmux sessions" : nil,
                            canCreate: true
                        )
                    case .unavailable(let message):
                        controller.update(
                            sessions: self.currentTmuxSessionAdded(to: []),
                            status: message,
                            canCreate: false,
                            isError: true
                        )
                    }
                }
            case .unavailable(let message):
                controller.update(
                    sessions: self.currentTmuxSessionAdded(to: []),
                    status: message,
                    canCreate: false,
                    isError: true
                )
            }
        }
    }

    func currentTmuxSessionAdded(
        to descriptors: [NativeTmuxSessionDescriptor]
    ) -> [NativeTmuxSessionDescriptor] {
        var descriptors = descriptors
        if let session = tmuxSession,
            !descriptors.contains(where: {
                $0.name == session.sessionName && $0.socketPath == session.socketPath
            })
        {
            descriptors.append(
                NativeTmuxSessionDescriptor(
                    name: session.sessionName,
                    windowCount: lastSnapshot?.tabs.count ?? 1,
                    socketPath: session.socketPath
                )
            )
        }
        return descriptors.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func preferredTmuxSocketPath() -> String? {
        if let activeSocketPath = tmuxSession?.socketPath, !activeSocketPath.isEmpty {
            return activeSocketPath
        }
        return lastTmuxSocketPath
    }

    func dismissSessionPopover() {
        sessionPopover?.performClose(nil)
        sessionPopover = nil
    }

    func detachTmuxSession() {
        guard let session = tmuxSession else {
            focusTerminal()
            return
        }
        if !session.gateway.tmuxCommand("detach-client") {
            presentTmuxSessionError("Satin could not detach from the current tmux session.")
        }
    }

    func attachTmuxSession(_ descriptor: NativeTmuxSessionDescriptor) {
        if let session = tmuxSession {
            guard descriptor.socketPath == session.socketPath else {
                presentTmuxSessionError(
                    "Detach to Local Terminal before connecting to a different tmux server."
                )
                return
            }
            guard descriptor.name != session.sessionName else {
                focusTerminal()
                return
            }
            if !session.gateway.tmuxCommand(
                "switch-client -t \(tmuxCommandArgument(descriptor.name))"
            ) {
                presentTmuxSessionError("Satin could not switch to that tmux session.")
            }
            return
        }
        guard let executable = resolvedTmuxExecutable else {
            presentTmuxSessionError("Satin could not resolve the tmux executable.")
            return
        }
        pendingTmuxExecutable = executable
        runTmuxCommandInActiveShell(
            "\(shellQuote(executable.path)) -S \(shellQuote(descriptor.socketPath)) "
                + "-CC attach-session "
                + "-t \(shellQuote(descriptor.name))"
        )
    }

    func createTmuxSession(named name: String) {
        if let session = tmuxSession {
            let argument = tmuxCommandArgument(name)
            guard session.gateway.tmuxCommand("new-session -d -s \(argument)"),
                session.gateway.tmuxCommand("switch-client -t \(argument)")
            else {
                presentTmuxSessionError("Satin could not create that tmux session.")
                return
            }
            return
        }
        let socketArgument =
            preferredTmuxSocketPath().map {
                "-S \(shellQuote($0)) "
            } ?? ""
        guard let executable = resolvedTmuxExecutable else {
            presentTmuxSessionError("Satin could not resolve the tmux executable.")
            return
        }
        pendingTmuxExecutable = executable
        runTmuxCommandInActiveShell(
            "\(shellQuote(executable.path)) \(socketArgument)-CC new-session "
                + "-s \(shellQuote(name))"
        )
    }

    func runTmuxCommandInActiveShell(_ command: String) {
        guard let paneId = activePaneId,
            paneStore.runtimes[paneId] is RustTerminalPane
        else {
            presentTmuxSessionError("Select a terminal pane before connecting to tmux.")
            return
        }
        var input = Data([21])
        input.append(Data("\(command)\r".utf8))
        writeToActivePane(input)
    }

    func presentTmuxSessionError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "tmux Session"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func updateSessionControl() {
        let title: String
        let symbol: String
        if let session = tmuxSession {
            title =
                "tmux · \(session.sessionName)"
                + (session.activeWindowZoomed ? " · Zoom" : "")
            symbol = "rectangle.stack"
        } else {
            title = "Local"
            symbol = "terminal"
        }
        sessionControlButton.title = title
        sessionControlButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )
        sessionControlButton.setAccessibilityValue(title)
        sessionControlButton.sizeToFit()
        sessionControlButton.invalidateIntrinsicContentSize()
        sessionControlButton.superview?.needsLayout = true
    }

    func sessionControlTitle() -> String {
        sessionControlButton.title
    }

    func tabWidth(for title: String) -> CGFloat {
        let measured = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ])
        return min(max(measured.width + 58, 112), 214)
    }

}
