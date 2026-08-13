import AppKit
import Foundation

func nativeTmuxSplitCommand(horizontal: Bool, targetPaneId: UInt32) -> String {
    let flag = horizontal ? "-h" : "-v"
    return "split-window \(flag) -c '#{pane_current_path}' -t %\(targetPaneId)"
}

func runNativeTmuxSplitCommandSelfTests() -> Bool {
    nativeTmuxSplitCommand(horizontal: true, targetPaneId: 7)
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

    @objc func newTab(_ sender: Any?) {
        if let session = tmuxSession {
            _ = session.gateway.tmuxCommand("new-window")
            return
        }
        pendingPaneWorkingDirectory = newPaneWorkingDirectory()
        core.newTab()
        syncFromCore()
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
        _ = switchTerminalPaneToNeovim(paneId: paneId)
    }

    @objc func closeActivePane(_ sender: Any?) {
        closePane(activePaneId)
    }

    func performPaneChromeAction(
        _ action: NativePaneChromeAction,
        paneId: Int,
        sourceView: NSView
    ) {
        switch action {
        case .close:
            closePane(paneId)
        case .splitVertical:
            splitPane(paneId, axis: ffiSplitVertical)
        case .splitHorizontal:
            splitPane(paneId, axis: ffiSplitHorizontal)
        case .artifacts:
            guard selectPaneForChromeAction(paneId) else {
                return
            }
            showArtifactsPopover(relativeTo: sourceView, paneId: paneId)
            return
        }
        focusTerminal()
    }

    private func splitPane(_ paneId: Int?, axis: UInt32) {
        guard let paneId else {
            return
        }
        guard selectPaneForChromeAction(paneId) else {
            return
        }
        if routeTmuxSplit(horizontal: axis == ffiSplitVertical) {
            return
        }
        pendingPaneWorkingDirectory = newPaneWorkingDirectory()
        _ = core.splitActive(axis: axis)
        syncFromCore()
    }

    private func closePane(_ paneId: Int?) {
        guard let paneId else {
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

    func routeTmuxSplit(horizontal: Bool) -> Bool {
        guard let session = tmuxSession,
            let paneId = activePaneId,
            let tmuxPaneId = session.tmuxPaneIds[paneId]
        else {
            return false
        }
        return session.gateway.tmuxCommand(
            nativeTmuxSplitCommand(horizontal: horizontal, targetPaneId: tmuxPaneId)
        )
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
                NativeSessionTab(title: tab.title, theme: tab.theme, layout: layout)
            }
        }
        return NativeSessionState(
            schemaVersion: currentSessionSchemaVersion,
            activeTab: snapshot.active_tab,
            tabs: tabs,
            tmuxAttachment: tmuxSession.flatMap { session in
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
            }
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
        guard activePaneSupportsLocalZoom() else {
            focusTerminal()
            return
        }
        _ = terminalTextView.zoomIn()
        focusTerminal()
    }

    @objc func zoomOut(_ sender: Any?) {
        guard activePaneSupportsLocalZoom() else {
            focusTerminal()
            return
        }
        _ = terminalTextView.zoomOut()
        focusTerminal()
    }

    @objc func resetZoom(_ sender: Any?) {
        guard activePaneSupportsLocalZoom() else {
            focusTerminal()
            return
        }
        _ = terminalTextView.resetZoom()
        focusTerminal()
    }

    private func activePaneSupportsLocalZoom() -> Bool {
        guard let paneId = activePaneId else {
            return false
        }
        return projectedTmuxPane(paneId) == nil
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

        let menu = NSMenu()
        menu.addItem(menuItem("Rename Session", #selector(renameActiveTab(_:))))
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
