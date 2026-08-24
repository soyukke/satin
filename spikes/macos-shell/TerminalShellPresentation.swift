import AppKit
import Foundation

private let tmuxClientResizeThrottle: DispatchTimeInterval = .milliseconds(50)

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
        refreshWorkSwitcherPresentation()
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
        if paneId == nativeArtifactSidebarPaneId,
            paneStore.runtimes[paneId] != nil
        {
            activePaneId = paneId
            terminalTextView.setActivePaneId(paneId)
            updateActiveFrame()
            focusTerminal()
            return
        }
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
            let width = tabWidth(for: tab.title)
            tabControl.setWidth(width, forSegment: idx)
            tabControl.setLabel(
                tabControl.displayTitle(tab.title, segmentWidth: width),
                forSegment: idx
            )
            tabControl.setToolTip(
                "\(tab.title)\nDrag to reorder; use × to close; double-click or right-click for actions",
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

    func syncPaneLayout(
        _ snapshot: TerminalCoreSnapshot,
        tmuxClientResizeImmediately: Bool = false
    ) {
        guard let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab }) else {
            paneStore.visibleFrames = [:]
            terminalTextView.updatePaneFrames([:], paneBounds: [:], activePaneId: nil)
            return
        }
        var paneBounds: [Int: NSRect] = [:]
        var dividers: [NativePaneDivider] = []
        let contentRect = terminalTextView.terminalContentRect()
        let minimumFrameRequirements = tmuxPaneFrameRequirements(for: tab.layout)
        collectPaneFrames(
            tab.layout,
            rect: workspaceContentRect(),
            frames: &paneBounds,
            dividers: &dividers,
            minimumFrameRequirements: minimumFrameRequirements
        )
        if paneStore.runtimes[nativeArtifactSidebarPaneId] != nil {
            paneBounds[nativeArtifactSidebarPaneId] = artifactSidebarFrames(in: contentRect).sidebar
        }
        let frames = paneBounds.mapValues(nativePaneContentFrame)
        paneStore.visibleFrames = frames
        let presentedActivePaneId =
            activePaneId == nativeArtifactSidebarPaneId
            ? nativeArtifactSidebarPaneId : tab.active_pane
        terminalTextView.updatePaneFrames(
            frames,
            paneBounds: paneBounds,
            activePaneId: presentedActivePaneId,
            dividers: dividers
        )
        for (paneId, frame) in frames {
            let pane = terminalPane(for: paneId)
            if !(pane is RustTmuxPane) {
                pane?.resize(
                    grid: terminalTextView.terminalGridSize(for: frame)
                )
            }
        }
        syncTmuxClientSize(immediately: tmuxClientResizeImmediately)
    }

    func syncTmuxClientSize(immediately: Bool = false) {
        guard let session = tmuxSession else {
            return
        }
        session.clientResizeThrottleWorkItem?.cancel()
        session.clientResizeThrottleWorkItem = nil
        if immediately || session.requestedClientGrid == nil {
            _ = requestTmuxClientSizeIfNeeded(session)
            return
        }
        // Debounce host-window geometry instead of sending every intermediate
        // grid. Each tmux resize can trigger a topology snapshot and pane
        // rehydration, so a resize-command backlog can otherwise apply a stale
        // peak size after the native window has already returned to its final
        // dimensions.
        let workItem = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, tmuxSession === session else {
                return
            }
            session.clientResizeThrottleWorkItem = nil
            _ = requestTmuxClientSizeIfNeeded(session)
        }
        session.clientResizeThrottleWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + tmuxClientResizeThrottle,
            execute: workItem
        )
    }

    func requestTmuxClientSizeIfNeeded(_ session: NativeTmuxSession) -> Bool {
        let grid = tmuxClientGrid()
        let desired = NativePaneGridCapacity(rows: grid.rows, cols: grid.cols)
        // The trailing throttle pass recomputes the current grid. Comparing
        // requests (not delayed tmux reports) sends each distinct size once.
        if session.requestedClientGrid == desired {
            return false
        }
        guard session.gateway.tmuxCommand("refresh-client -C \(grid.cols),\(grid.rows)") else {
            return false
        }
        session.requestedClientGrid = desired
        #if SATIN_SMOKE_SCENARIOS
            session.clientResizeRequestCount += 1
        #endif
        return true
    }

    func tmuxClientGrid() -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        // A tmux control client owns one grid for the whole window. Every pane
        // uses the same cell size, so compose the real leaf capacities without
        // introducing pane-specific zoom state.
        let projectedPaneIds = paneStore.visibleFrames.keys.filter { paneId in
            tmuxSession?.tmuxPaneIds[paneId] != nil
        }
        let cellSize = terminalTextView.terminalCellSize()
        let fallback = terminalTextView.terminalGridSize(
            for: nativePaneContentFrame(workspaceContentRect()))
        guard let snapshot = lastSnapshot,
            let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab })
        else {
            return fallback
        }
        let leafCapacities = Dictionary(
            uniqueKeysWithValues: projectedPaneIds.compactMap { paneId in
                paneStore.visibleFrames[paneId].map { frame in
                    let grid = terminalTextView.terminalGridSize(for: frame)
                    return (
                        paneId,
                        NativePaneGridCapacity(rows: grid.rows, cols: grid.cols)
                    )
                }
            }
        )
        guard
            let capacity = tmuxClientGridCapacity(
                layout: tab.layout, leafCapacities: leafCapacities)
        else {
            return fallback
        }
        let scale =
            terminalTextView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 1
        return (
            max(1, capacity.rows),
            max(1, capacity.cols),
            max(1, Int(CGFloat(capacity.cols) * cellSize.width * scale)),
            max(1, Int(CGFloat(capacity.rows) * cellSize.height * scale))
        )
    }

    func collectPaneFrames(
        _ layout: PaneLayoutSnapshot,
        rect: NSRect,
        frames: inout [Int: NSRect],
        dividers: inout [NativePaneDivider],
        minimumFrameRequirements: [ObjectIdentifier: NSSize]
    ) {
        if layout.kind == "leaf", let paneId = layout.pane_id {
            frames[paneId] = rect
            return
        }
        guard let axis = layout.axis, let first = layout.first, let second = layout.second else {
            return
        }
        let ratio = paneSplitRatio(
            layoutRatio: layout.ratio,
            axis: axis,
            available: axis == "vertical" ? rect.width : rect.height,
            firstRequirement: minimumFrameRequirements[ObjectIdentifier(first)],
            secondRequirement: minimumFrameRequirements[ObjectIdentifier(second)]
        )
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
                dividers: &dividers,
                minimumFrameRequirements: minimumFrameRequirements
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
                dividers: &dividers,
                minimumFrameRequirements: minimumFrameRequirements
            )
        } else {
            let firstHeight = floor(rect.height * ratio)
            collectPaneFrames(
                first,
                rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight),
                frames: &frames,
                dividers: &dividers,
                minimumFrameRequirements: minimumFrameRequirements
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
                dividers: &dividers,
                minimumFrameRequirements: minimumFrameRequirements
            )
        }
    }

    func tmuxPaneFrameRequirements(
        for layout: PaneLayoutSnapshot
    ) -> [ObjectIdentifier: NSSize] {
        guard let session = tmuxSession else {
            return [:]
        }
        let cell = terminalTextView.terminalCellSize()
        let leafRequirements = session.tmuxPaneIds.reduce(into: [Int: NSSize]()) {
            requirements, entry in
            guard let pane = session.latestPanes[entry.value] else {
                return
            }
            requirements[entry.key] = NSSize(
                width: CGFloat(pane.cols) * cell.width,
                height: CGFloat(pane.rows) * cell.height + nativePaneChromeHeight
            )
        }
        return paneFrameRequirements(layout: layout, leafRequirements: leafRequirements)
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
        tabControl.onMoveRequested = { [weak self] source, target in
            self?.moveTab(from: source, to: target) ?? false
        }
        tabControl.contextMenuProvider = { [weak self] index in
            self?.tabContextMenu(index: index)
        }
        tabStripView.allTabsMenuProvider = { [weak self] in
            self?.tabOverflowMenu()
        }
        tabControl.setAccessibilityLabel("Terminal Tabs")
        tabControl.setAccessibilityHelp(
            "Click a tab to select it, drag it to reorder, use its close button to close it, "
                + "or double-click or right-click for tab actions."
        )
        newTabButton.target = self
        newTabButton.action = #selector(newTab(_:))
    }

    func configureToolbarControls() {
        artifactButton.target = self
        artifactButton.action = #selector(showArtifacts(_:))
        workSwitcherButton.target = self
        workSwitcherButton.action = #selector(showWorkSwitcher(_:))
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
            SatinToolbarItemIdentifier.artifacts,
            SatinToolbarItemIdentifier.workSwitcher,
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
        case SatinToolbarItemIdentifier.artifacts:
            item.label = "Artifacts"
            item.paletteLabel = "Recent Artifacts"
            item.view = artifactButton
            item.visibilityPriority = .high
        case SatinToolbarItemIdentifier.workSwitcher:
            item.label = "Work"
            item.paletteLabel = "Work Switcher"
            item.view = workSwitcherButton
            item.visibilityPriority = .high
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
        controller.onRequestEndSession = { [weak self] descriptor in
            self?.dismissSessionPopover()
            self?.confirmEndingTmuxSession(descriptor)
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
        if let executable = resolvedTmuxExecutable {
            discoverTmuxSessions(executable: executable, into: controller)
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
                self.discoverTmuxSessions(executable: executable, into: controller)
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

    private func discoverTmuxSessions(
        executable: NativeTmuxExecutable,
        into controller: TmuxSessionPopoverController
    ) {
        NativeTmuxSessionDiscovery.discover(
            executable: executable,
            socketPath: preferredTmuxSocketPath()
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
                    sessionID: session.sessionID,
                    name: session.sessionName,
                    windowCount: lastSnapshot?.tabs.count ?? 1,
                    socketPath: session.socketPath,
                    serverPID: session.serverPid
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
        focusTerminal()
    }

    @discardableResult
    func beginTmuxConnectionAttempt(clearPendingReattach: Bool) -> Int {
        invalidateTmuxConnectionCallbacks()
        _ = takePendingTmuxLease()
        if clearPendingReattach, pendingTmuxReattach != nil {
            pendingTmuxReattach = nil
            tmuxReattachInFlight = false
            tmuxReattachDeferred = false
            consumePersistedTmuxAttachment()
            saveSessionState()
        }
        return tmuxAdmissionSequence
    }

    func invalidateTmuxConnectionCallbacks() {
        tmuxAdmissionSequence &+= 1
        pendingTmuxConnectionWorkItem?.cancel()
        pendingTmuxConnectionWorkItem = nil
        tmuxConnectionCommandSequence = nil
    }

    func detachTmuxSession() {
        _ = beginTmuxConnectionAttempt(clearPendingReattach: true)
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
            guard let executable = resolvedTmuxExecutable else {
                presentTmuxSessionError("Satin could not resolve the tmux executable.")
                return
            }
            let sequence = beginTmuxConnectionAttempt(clearPendingReattach: false)
            requestTmuxProjectionAdmission(
                executable: executable,
                descriptor: descriptor,
                sequence: sequence
            ) { [weak self, weak session] lease in
                guard let self, let session, self.tmuxSession === session,
                    self.tmuxAdmissionSequence == sequence
                else {
                    return
                }
                self.stageTmuxLease(lease)
                guard
                    session.gateway.tmuxCommand(
                        "switch-client -t \(tmuxCommandArgument(descriptor.name))"
                    )
                else {
                    _ = self.takePendingTmuxLease()
                    self.presentTmuxSessionError(
                        "Satin could not switch to that tmux session."
                    )
                    return
                }
            }
            return
        }
        guard let executable = resolvedTmuxExecutable else {
            presentTmuxSessionError("Satin could not resolve the tmux executable.")
            return
        }
        let sequence = beginTmuxConnectionAttempt(clearPendingReattach: true)
        requestTmuxProjectionAdmission(
            executable: executable,
            descriptor: descriptor,
            sequence: sequence
        ) { [weak self] lease in
            guard let self, self.tmuxSession == nil,
                self.tmuxAdmissionSequence == sequence
            else {
                return
            }
            self.stageTmuxLease(lease)
            self.pendingTmuxExecutable = executable
            self.scheduleTmuxCommandInActiveShell(
                "\(shellQuote(executable.path)) "
                    + "-S \(shellQuote(descriptor.socketPath)) "
                    + "-CC attach-session -t \(shellQuote(descriptor.name))",
                sequence: sequence
            )
        }
    }

    func requestTmuxProjectionAdmission(
        executable: NativeTmuxExecutable,
        descriptor: NativeTmuxSessionDescriptor,
        sequence: Int,
        completion: @escaping (NativeTmuxSessionLease) -> Void
    ) {
        NativeTmuxProjectionAdmission.request(
            executable: executable,
            descriptor: descriptor
        ) { [weak self] result in
            guard let self, self.tmuxAdmissionSequence == sequence else {
                return
            }
            switch result {
            case .admitted(let lease):
                completion(lease)
            case .busy:
                self.presentTmuxSessionError(
                    "That tmux session is already open in another Satin window. "
                        + "Close or detach it there before trying again."
                )
            case .unavailable(let message):
                self.presentTmuxSessionError(message)
            }
        }
    }

    func createTmuxSession(named name: String) {
        if let session = tmuxSession {
            _ = beginTmuxConnectionAttempt(clearPendingReattach: false)
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
        let sequence = beginTmuxConnectionAttempt(clearPendingReattach: true)
        pendingTmuxExecutable = executable
        scheduleTmuxCommandInActiveShell(
            "\(shellQuote(executable.path)) \(socketArgument)-CC new-session "
                + "-s \(shellQuote(name))",
            sequence: sequence
        )
    }

    func confirmEndingTmuxSession(_ descriptor: NativeTmuxSessionDescriptor) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "End tmux session “\(descriptor.name)”?"
        alert.informativeText =
            "All windows and running programs in this session will be terminated. This cannot be undone."
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard NativeTmuxSessionTermination.confirmed(response) else {
                    return
                }
                self?.endTmuxSession(descriptor)
            }
        } else if NativeTmuxSessionTermination.confirmed(alert.runModal()) {
            endTmuxSession(descriptor)
        }
    }

    func endTmuxSession(_ descriptor: NativeTmuxSessionDescriptor) {
        if let session = tmuxSession {
            let target = tmuxCommandArgument("=\(descriptor.name)")
            guard descriptor.socketPath == session.socketPath,
                session.gateway.tmuxCommand("kill-session -t \(target)")
            else {
                presentTmuxSessionError("Satin could not end that tmux session.")
                return
            }
            return
        }
        guard let executable = resolvedTmuxExecutable else {
            presentTmuxSessionError("Satin could not resolve the tmux executable.")
            return
        }
        NativeTmuxSessionTermination.end(
            executablePath: executable.path,
            descriptor: descriptor
        ) { [weak self] result in
            switch result {
            case .ended:
                break
            case .unavailable(let message):
                self?.presentTmuxSessionError(message)
            }
        }
    }

    func runTmuxCommandInActiveShell(_ command: String, sequence: Int) {
        guard tmuxAdmissionSequence == sequence,
            tmuxConnectionCommandSequence != sequence
        else {
            return
        }
        guard let paneId = activePaneId,
            let gateway = tmuxConnectionGateway(paneId: paneId)
        else {
            presentTmuxSessionError("Select a terminal pane before connecting to tmux.")
            return
        }
        tmuxConnectionCommandSequence = sequence
        #if SATIN_SMOKE_SCENARIOS
            tmuxConnectionCommandHistory.append(command)
        #endif
        var input = Data([21])
        input.append(Data("\(command)\r".utf8))
        gateway.write(input)
        if paneStore.runtimes[paneId] === gateway {
            drainTerminalPanes()
        } else {
            drainSuspendedTerminalPane(paneId)
        }
    }

    func scheduleTmuxCommandInActiveShell(_ command: String, sequence: Int) {
        pendingTmuxConnectionWorkItem?.cancel()
        focusTerminal()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.tmuxAdmissionSequence == sequence else {
                return
            }
            self.pendingTmuxConnectionWorkItem = nil
            self.runTmuxCommandInActiveShell(command, sequence: sequence)
        }
        pendingTmuxConnectionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    func tmuxConnectionGateway(paneId: Int) -> RustTerminalPane? {
        (paneStore.runtimes[paneId] as? RustTerminalPane)
            ?? paneStore.suspendedSessions[paneId]?.pane
    }

    func presentTmuxSessionError(_ message: String) {
        #if SATIN_SMOKE_SCENARIOS
            tmuxSessionErrorHistory.append(message)
        #endif
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
        return min(max(measured.width + 66, 112), 214)
    }

}
