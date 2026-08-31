import AppKit
import Foundation

enum NativeTabMoveFailure: Error {
    case invalidTarget
    case destinationMissing
    case tmuxCommandFailed
}

let nativeTmuxCurrentPaneDirectoryArgument = "'#{pane_current_path}'"

func nativeTmuxSplitCommand(horizontal: Bool, targetPaneId: UInt32) -> String {
    let flag = horizontal ? "-h" : "-v"
    return "split-window \(flag) -c \(nativeTmuxCurrentPaneDirectoryArgument) -t %\(targetPaneId)"
}

func nativeTmuxNewWindowCommand() -> String {
    "new-window -c \(nativeTmuxCurrentPaneDirectoryArgument)"
}

func runNativeTmuxCreationCommandSelfTests() -> Bool {
    nativeTmuxNewWindowCommand() == "new-window -c '#{pane_current_path}'"
        && nativeTmuxSplitCommand(horizontal: true, targetPaneId: 7)
            == "split-window -h -c '#{pane_current_path}' -t %7"
        && nativeTmuxSplitCommand(horizontal: false, targetPaneId: 42)
            == "split-window -v -c '#{pane_current_path}' -t %42"
}

extension TerminalShellViewController {
    @objc func tabControlChanged(_ sender: NSSegmentedControl) {
        guard !syncingTabs, sender.selectedSegment >= 0 else {
            return
        }

        selectTab(sender.selectedSegment)
    }

    func moveTab(from sourceIndex: Int, to targetIndex: Int) -> Bool {
        guard let snapshot = lastSnapshot,
            let source = snapshot.tabs.first(where: { $0.index == sourceIndex })
        else {
            return false
        }
        switch requestTabMove(id: source.id, to: targetIndex) {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    func requestTabMove(
        id tabId: Int,
        to targetIndex: Int
    ) -> Result<Void, NativeTabMoveFailure> {
        guard let snapshot = lastSnapshot,
            let source = snapshot.tabs.first(where: { $0.id == tabId }),
            targetIndex >= 0,
            targetIndex < snapshot.tabs.count
        else {
            return .failure(.invalidTarget)
        }
        if source.index == targetIndex {
            return .success(())
        }
        if let session = tmuxSession {
            guard let sourceWindow = session.tmuxWindowIds[source.id] else {
                return .failure(.invalidTarget)
            }
            let remaining = snapshot.tabs.filter { $0.id != tabId }
            let positionFlag: String
            let targetTab: TerminalCoreTabSnapshot
            if targetIndex == 0 {
                positionFlag = "-b"
                targetTab = remaining[0]
            } else {
                positionFlag = "-a"
                targetTab = remaining[min(targetIndex - 1, remaining.count - 1)]
            }
            guard let targetWindow = session.tmuxWindowIds[targetTab.id] else {
                return .failure(.destinationMissing)
            }
            guard
                session.gateway.tmuxCommand(
                    "move-window -s @\(sourceWindow) \(positionFlag) -t @\(targetWindow)"
                )
            else {
                return .failure(.tmuxCommandFailed)
            }
            return .success(())
        }
        guard core.moveTab(tabId, to: targetIndex) else {
            return .failure(.invalidTarget)
        }
        syncFromCore()
        saveSessionState()
        return .success(())
    }

    @objc func newTab(_ sender: Any?) {
        if let session = tmuxSession {
            guard session.gateway.tmuxCommand(nativeTmuxNewWindowCommand()) else {
                presentTmuxSessionError("Satin could not create a tmux window.")
                return
            }
            focusTerminal()
            return
        }
        guard let cwd = inheritedPaneWorkingDirectory() else {
            presentPaneWorkingDirectoryError(title: "Could Not Open New Tab")
            return
        }
        pendingPaneWorkingDirectory = cwd
        core.newTab()
        syncFromCore()
        focusTerminal()
    }

    @objc func splitVertical(_ sender: Any?) {
        splitPane(activePaneId, axis: ffiSplitVertical)
    }

    @objc func splitHorizontal(_ sender: Any?) {
        splitPane(activePaneId, axis: ffiSplitHorizontal)
    }

    func resizeSplit(
        firstPaneId: Int,
        secondPaneId: Int,
        axis: NativePaneDividerAxis,
        ratio: CGFloat,
        cellDelta: Int
    ) {
        if let session = tmuxSession {
            guard cellDelta != 0,
                let tmuxPaneId = session.tmuxPaneIds[firstPaneId]
            else {
                return
            }
            let direction =
                switch (axis, cellDelta > 0) {
                case (.vertical, true): "-R"
                case (.vertical, false): "-L"
                case (.horizontal, true): "-D"
                case (.horizontal, false): "-U"
                }
            _ = session.gateway.tmuxCommand(
                "resize-pane -t %\(tmuxPaneId) \(direction) \(abs(cellDelta))"
            )
            return
        }
        guard
            core.resizeSplit(
                firstPaneId: firstPaneId,
                secondPaneId: secondPaneId,
                ratio: Double(ratio)
            )
        else {
            return
        }
        guard let snapshot = core.snapshot() else {
            return
        }
        lastSnapshot = snapshot
        syncPaneLayout(snapshot)
        updateActiveFrame()
    }

    @objc func openNativeNeovim(_ sender: Any?) {
        guard let paneId = activePaneId else {
            return
        }
        guard switchTerminalPaneToNeovim(paneId: paneId) else {
            presentNativeNeovimLaunchError()
            return
        }
    }

    func presentNativeNeovimLaunchError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Open Neovim"
        alert.informativeText =
            "The selected pane's working directory is unavailable. "
            + "Return the shell to an existing directory and try again."
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func presentPaneWorkingDirectoryError(title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText =
            "The selected pane's working directory is unavailable. "
            + "Return the shell to an existing directory and try again."
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func presentPaneDirectoryOpenError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Open Finder"
        alert.informativeText = "Finder could not open the selected pane's working directory."
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc func closeActivePane(_ sender: Any?) {
        closePane(activePaneId)
    }

    func performPaneChromeAction(
        _ action: NativePaneChromeAction,
        paneId: Int,
        sourceView _: NSView
    ) {
        switch action {
        case .close:
            closePane(paneId)
        case .splitVertical:
            splitPane(paneId, axis: ffiSplitVertical)
        case .splitHorizontal:
            splitPane(paneId, axis: ffiSplitHorizontal)
        case .openInFinder:
            _ = openPaneDirectoryInFinder(paneId: paneId)
        }
        focusTerminal()
    }

    @discardableResult
    func openPaneDirectoryInFinder(paneId: Int) -> Bool {
        guard let directory = paneWorkingDirectory(paneId: paneId, logFailure: true) else {
            presentPaneWorkingDirectoryError(title: "Could Not Open Finder")
            return false
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        guard paneDirectoryOpener(url) else {
            NativeLog.runtimeError("pane_finder_open_failed pane=\(paneId) path=\(directory)")
            presentPaneDirectoryOpenError()
            return false
        }
        return true
    }

    private func splitPane(_ paneId: Int?, axis: UInt32) {
        guard let paneId else {
            return
        }
        if let session = tmuxSession {
            guard let tmuxPaneId = session.tmuxPaneIds[paneId] else {
                presentTmuxSessionError("Satin could not resolve the tmux pane to split.")
                return
            }
            guard
                session.gateway.tmuxCommand(
                    nativeTmuxSplitCommand(
                        horizontal: axis == ffiSplitVertical,
                        targetPaneId: tmuxPaneId
                    ))
            else {
                presentTmuxSessionError("Satin could not split the tmux pane.")
                return
            }
            return
        }
        guard let cwd = inheritedPaneWorkingDirectory(paneId: paneId) else {
            presentPaneWorkingDirectoryError(title: "Could Not Split Pane")
            return
        }
        let previousPaneId = activePaneId
        guard selectPaneForChromeAction(paneId) else {
            return
        }
        pendingPaneWorkingDirectory = cwd
        guard core.splitActive(axis: axis) != nil else {
            pendingPaneWorkingDirectory = nil
            if let previousPaneId {
                _ = core.selectPane(previousPaneId)
            }
            syncFromCore()
            NativeLog.runtimeError("pane_split_failed pane=\(paneId)")
            return
        }
        syncFromCore()
    }

    private func closePane(_ paneId: Int?) {
        guard let paneId else {
            return
        }
        if paneId == nativeArtifactSidebarPaneId {
            _ = closeArtifactSidebar()
            focusTerminal()
            return
        }
        if let session = tmuxSession,
            let tmuxPaneId = session.tmuxPaneIds[paneId]
        {
            _ = session.gateway.tmuxCommand("kill-pane -t %\(tmuxPaneId)")
            return
        }
        guard core.closePane(paneId) else {
            return
        }
        discardPaneState(paneId)
        guard let snapshot = core.snapshot(), !snapshot.tabs.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        syncFromCore()
    }

    @discardableResult
    private func selectPaneForChromeAction(_ paneId: Int) -> Bool {
        if let session = tmuxSession, let tmuxPaneId = session.tmuxPaneIds[paneId] {
            guard session.gateway.tmuxCommand("select-pane -t %\(tmuxPaneId)") else {
                return false
            }
            activePaneId = paneId
            terminalTextView.setActivePaneId(paneId)
            updateActiveFrame()
            return true
        }
        guard core.selectPane(paneId) else {
            return false
        }
        syncFromCore()
        return true
    }

    @objc func focusPaneLeft(_ sender: Any?) {
        focusPane(.left)
    }

    @objc func focusPaneDown(_ sender: Any?) {
        focusPane(.down)
    }

    @objc func focusPaneUp(_ sender: Any?) {
        focusPane(.up)
    }

    @objc func focusPaneRight(_ sender: Any?) {
        focusPane(.right)
    }

    private func focusPane(_ direction: NativePaneDirection) {
        guard let paneId = core.paneInDirection(direction) else {
            focusTerminal()
            return
        }
        selectPane(paneId)
    }

    @objc func toggleOptionAsAlt(_ sender: Any?) {
        optionAsAltEnabled.toggle()
        UserDefaults.standard.set(optionAsAltEnabled, forKey: NativePreferenceKey.optionAsAlt)
        for pane in paneStore.runtimes.values {
            (pane as? RustTerminalPane)?.setOptionAsAlt(optionAsAltEnabled)
        }
    }

    @objc func toggleNotifications(_ sender: Any?) {
        notificationsEnabled.toggle()
        UserDefaults.standard.set(notificationsEnabled, forKey: NativePreferenceKey.notifications)
    }

    @objc func toggleSessionRestore(_ sender: Any?) {
        let enabled = !preferredBool(NativePreferenceKey.sessionRestore, defaultValue: true)
        UserDefaults.standard.set(enabled, forKey: NativePreferenceKey.sessionRestore)
        if !enabled {
            UserDefaults.standard.removeObject(forKey: NativePreferenceKey.sessionState)
        }
    }

    func saveSessionState() {
        guard preferredBool(NativePreferenceKey.sessionRestore, defaultValue: true),
            let state = currentSessionState()
        else {
            return
        }
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: NativePreferenceKey.sessionState)
        } catch {
            NativeLog.sessionWarning("session_encode_failed error=\(error)")
        }
    }

    func currentSessionState() -> NativeSessionState? {
        guard let snapshot = tmuxSession?.savedWorkspace ?? lastSnapshot else {
            return nil
        }
        let tabs = snapshot.tabs.compactMap { tab in
            savedSessionPane(tab.layout, activePane: tab.active_pane).map { layout in
                NativeSessionTab(
                    title: tab.title,
                    theme: tab.theme,
                    layout: layout
                )
            }
        }
        let tmuxAttachment =
            tmuxSession.flatMap { session in
                guard
                    isLocalTmuxEndpoint(
                        socketPath: session.socketPath,
                        serverPid: session.serverPid
                    )
                else {
                    return nil
                }
                return validatedTmuxAttachment(
                    NativeTmuxAttachment(
                        sessionName: session.sessionName,
                        socketPath: session.socketPath,
                        executablePath: session.executablePath.isEmpty
                            ? resolvedTmuxExecutable?.path
                            : session.executablePath
                    )
                )
            } ?? pendingTmuxReattach.flatMap(validatedTmuxAttachment)
        return NativeSessionState(
            schemaVersion: currentSessionSchemaVersion,
            activeTab: snapshot.active_tab,
            tabs: tabs,
            tmuxAttachment: tmuxAttachment
        )
    }

    func validatedTmuxAttachment(
        _ attachment: NativeTmuxAttachment
    ) -> NativeTmuxAttachment? {
        let name = attachment.sessionName
        let socket = attachment.socketPath
        let executable = attachment.executablePath ?? ""
        guard !name.isEmpty,
            name.utf8.count <= 256,
            socket.utf8.count <= 1_024,
            executable.utf8.count <= 1_024,
            (socket as NSString).isAbsolutePath,
            executable.isEmpty || (executable as NSString).isAbsolutePath,
            name.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }),
            socket.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }),
            executable.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            return nil
        }
        return attachment
    }

    func savedSessionPane(
        _ layout: PaneLayoutSnapshot,
        activePane: Int
    ) -> NativeSessionPane? {
        if layout.kind == "leaf", let paneId = layout.pane_id {
            let cwd =
                (paneStore.runtimes[paneId] as? RustTerminalPane)?
                .currentWorkingDirectory()
                ?? paneStore.workingDirectories[paneId]
                ?? nativeWorkingDirectory()
            let mode =
                paneStore.runtimes[paneId]?.kind ?? paneStore.modes[paneId] ?? defaultPaneMode
            return NativeSessionPane(
                kind: "leaf",
                paneMode: mode.sessionValue,
                cwd: cwd,
                active: paneId == activePane
            )
        }
        guard layout.kind == "split",
            let axis = layout.axis,
            let first = layout.first.flatMap({
                savedSessionPane($0, activePane: activePane)
            }),
            let second = layout.second.flatMap({
                savedSessionPane($0, activePane: activePane)
            })
        else {
            return nil
        }
        return NativeSessionPane(
            kind: "split",
            axis: axis,
            ratio: layout.ratio,
            first: first,
            second: second
        )
    }

    @objc func renameActiveTab(_ sender: Any?) {
        guard let index = lastSnapshot?.active_tab else {
            return
        }
        renameTab(at: index)
    }

    func renameTab(at index: Int) {
        guard let tab = lastSnapshot?.tabs.first(where: { $0.index == index })
        else {
            return
        }

        let prompt = NativeRenamePanel(title: "Rename Tab", value: tab.title)
        guard let value = prompt.runModal(relativeTo: view.window) else {
            return
        }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return
        }
        if let session = tmuxSession,
            let windowId = session.tmuxWindowIds[tab.id]
        {
            _ = session.gateway.tmuxCommand(
                "rename-window -t @\(windowId) \(tmuxCommandArgument(title))"
            )
            return
        }
        core.renameTab(tab.index, title: title)
        syncFromCore()
    }

    func tabContextMenu(index: Int) -> NSMenu {
        let menu = NSMenu()
        let renameItem = menuItem("Rename Tab…", #selector(renameTabFromContextMenu(_:)))
        renameItem.representedObject = index
        menu.addItem(renameItem)
        menu.addItem(NSMenuItem.separator())
        let closeItem = menuItem("Close Tab", #selector(closeTabFromContextMenu(_:)))
        closeItem.representedObject = index
        menu.addItem(closeItem)
        return menu
    }

    func tabOverflowMenu() -> NSMenu {
        let menu = NSMenu(title: "All Tabs")
        for tab in lastSnapshot?.tabs ?? [] {
            let item = menuItem(tab.title, #selector(selectTabFromOverflowMenu(_:)))
            item.representedObject = tab.index
            item.state = tab.index == lastSnapshot?.active_tab ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc func selectTabFromOverflowMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else {
            return
        }
        selectTab(index)
    }

    #if SATIN_SMOKE_SCENARIOS
        func tabOverflowMenuReadyForSmoke(expectedCount: Int) -> Bool {
            guard let snapshot = lastSnapshot else {
                return false
            }
            let items = tabOverflowMenu().items
            return snapshot.tabs.count == expectedCount
                && items.count == snapshot.tabs.count
                && zip(items, snapshot.tabs).allSatisfy { item, tab in
                    item.title == tab.title
                        && item.representedObject as? Int == tab.index
                        && item.state == (tab.index == snapshot.active_tab ? .on : .off)
                }
        }
    #endif

    @objc func renameTabFromContextMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else {
            return
        }
        renameTab(at: index)
    }

    @objc func closeTabFromContextMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else {
            return
        }
        closeTab(at: index)
    }

    @objc func openPaneDirectoryFromContextMenu(_ sender: NSMenuItem) {
        guard let paneId = sender.representedObject as? Int else {
            return
        }
        _ = openPaneDirectoryInFinder(paneId: paneId)
        focusTerminal()
    }

    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard let snapshot = lastSnapshot,
            let tab = snapshot.tabs.first(where: { $0.index == index })
        else {
            return false
        }
        if let session = tmuxSession {
            guard let windowId = session.tmuxWindowIds[tab.id],
                session.gateway.tmuxCommand("kill-window -t @\(windowId)")
            else {
                return false
            }
            focusTerminal()
            return true
        }

        for paneId in tab.panes {
            guard core.closePane(paneId) else {
                return false
            }
            discardPaneState(paneId)
        }
        guard let updated = core.snapshot(), !updated.tabs.isEmpty else {
            NSApp.terminate(nil)
            return true
        }
        syncFromCore()
        focusTerminal()
        return true
    }

    @objc func toggleTmuxPaneZoom(_ sender: Any?) {
        guard let session = tmuxSession,
            let paneId = activePaneId,
            let tmuxPaneId = session.tmuxPaneIds[paneId]
        else {
            return
        }
        _ = session.gateway.tmuxCommand("resize-pane -Z -t %\(tmuxPaneId)")
        focusTerminal()
    }

    @objc func closeTmuxWindow(_ sender: Any?) {
        guard let session = tmuxSession,
            let snapshot = lastSnapshot,
            let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab }),
            let windowId = session.tmuxWindowIds[tab.id]
        else {
            return
        }
        _ = session.gateway.tmuxCommand("kill-window -t @\(windowId)")
    }

    @objc func zoomIn(_ sender: Any?) {
        _ = adjustTerminalZoom(by: 1)
        focusTerminal()
    }

    @objc func zoomOut(_ sender: Any?) {
        _ = adjustTerminalZoom(by: -1)
        focusTerminal()
    }

    @objc func resetZoom(_ sender: Any?) {
        _ = resetTerminalZoom()
        focusTerminal()
    }

    func selectTabFromShortcut(_ shortcutNumber: Int) {
        guard let snapshot = lastSnapshot,
            !snapshot.tabs.isEmpty,
            (1...9).contains(shortcutNumber)
        else {
            return
        }

        let index = shortcutNumber == 9 ? snapshot.tabs.count - 1 : shortcutNumber - 1
        guard index >= 0, index < snapshot.tabs.count else {
            return
        }
        selectTab(index)
    }

    @objc func setThemeFromMenu(_ sender: NSMenuItem) {
        guard let snapshot = lastSnapshot,
            let theme = sender.representedObject as? String
        else {
            return
        }
        core.setTheme(theme, tab: snapshot.active_tab)
        syncFromCore()
    }

    func terminalContextMenu(tabIndex: Int?) -> NSMenu {
        if let tabIndex {
            selectTabForContextMenu(tabIndex)
        }

        return terminalContextMenu(paneId: activePaneId)
    }

    func terminalContextMenu(paneId requestedPaneId: Int?) -> NSMenu {
        let paneId = requestedPaneId ?? activePaneId
        let menu = NSMenu()
        menu.addItem(menuItem("Rename Session", #selector(renameActiveTab(_:))))
        if let paneId, paneId != nativeArtifactSidebarPaneId {
            let finderItem = menuItem(
                "Open Pane Directory in Finder",
                #selector(openPaneDirectoryFromContextMenu(_:))
            )
            finderItem.representedObject = paneId
            finderItem.isEnabled = paneWorkingDirectory(paneId: paneId, logFailure: false) != nil
            menu.addItem(finderItem)
        }
        if tmuxSession != nil {
            let zoomTitle =
                tmuxSession?.activeWindowZoomed == true
                ? "Restore tmux Panes"
                : "Zoom tmux Pane"
            menu.addItem(menuItem(zoomTitle, #selector(toggleTmuxPaneZoom(_:))))
            menu.addItem(menuItem("Close tmux Window", #selector(closeTmuxWindow(_:))))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(themeMenuItem())
        return menu
    }

}
