import AppKit

extension TerminalShellViewController {
    @objc func showWorkSwitcher(_ sender: Any?) {
        if workSwitcherPopover?.isShown == true {
            dismissWorkSwitcher()
            return
        }
        pendingWorkSwitcherRefresh?.cancel()
        pendingWorkSwitcherRefresh = nil
        let controller = NativeWorkSwitcherViewController(
            items: nativeWorkItems(),
            activePaneId: activePaneId,
            previewProvider: { [weak self] item in
                self?.workPreviewText(paneId: item.paneId)
            }
        )
        controller.onSelect = { [weak self] item in
            self?.selectWorkItem(item)
        }
        controller.onCancel = { [weak self] in
            self?.dismissWorkSwitcher()
            self?.focusTerminal()
        }
        let popover = NSPopover()
        #if SATIN_SMOKE_SCENARIOS
            popover.behavior =
                ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_SCENARIO"]
                    == "readme-demo"
                ? .applicationDefined
                : .transient
        #else
            popover.behavior = .transient
        #endif
        popover.animates = true
        popover.contentViewController = controller
        workSwitcherPopover = popover
        workSwitcherController = controller
        let anchor = workSwitcherButton.superview == nil ? view : workSwitcherButton
        let anchorRect =
            anchor === workSwitcherButton
            ? workSwitcherButton.bounds
            : NSRect(x: view.bounds.midX, y: view.bounds.maxY, width: 1, height: 1)
        popover.show(relativeTo: anchorRect, of: anchor, preferredEdge: .maxY)
    }

    func dismissWorkSwitcher() {
        pendingWorkSwitcherRefresh?.cancel()
        pendingWorkSwitcherRefresh = nil
        workSwitcherPopover?.performClose(nil)
        workSwitcherPopover = nil
        workSwitcherController = nil
    }

    func paneStatusDidChange(paneId: Int, status: NativePaneControlStatus?) {
        if let status {
            workAttentionStore.observe(
                paneId: paneId,
                status: status,
                isVisible: paneIsVisibleForAttention(paneId)
            )
        } else {
            workAttentionStore.remove(paneId: paneId)
        }
        refreshWorkSwitcherPresentation()
    }

    func dismissAgentWaitingOnEscape(paneId: Int) {
        guard paneStatuses.status(for: paneId)?.status == "waiting",
            let title = paneStore.titles[paneId],
            title.hasPrefix("✳") || title.hasPrefix("[ ! ] Action Required |")
        else {
            return
        }
        paneStatuses.update(
            paneId: paneId,
            status: "idle",
            summary: "Agent request dismissed"
        )
    }

    func markActiveWorkSeen() {
        guard let activePaneId else {
            return
        }
        workAttentionStore.markSeen(paneId: activePaneId)
        refreshWorkSwitcherPresentation()
    }

    func refreshWorkSwitcherPresentation() {
        workSwitcherButton.setBadgeCount(workAttentionStore.unreadCount)
        guard workSwitcherPopover?.isShown == true else {
            pendingWorkSwitcherRefresh?.cancel()
            pendingWorkSwitcherRefresh = nil
            return
        }
        guard pendingWorkSwitcherRefresh == nil else {
            return
        }
        let refresh = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.pendingWorkSwitcherRefresh = nil
            guard self.workSwitcherPopover?.isShown == true else {
                return
            }
            self.workSwitcherController?.update(items: self.nativeWorkItems())
        }
        pendingWorkSwitcherRefresh = refresh
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(16),
            execute: refresh
        )
    }

    func nativeWorkItems() -> [NativeWorkItem] {
        guard let snapshot = lastSnapshot ?? core.snapshot() else {
            return []
        }
        return snapshot.tabs.flatMap { tab in
            tab.panes.enumerated().map { paneOrdinal, paneId in
                let mode =
                    paneStore.runtimes[paneId]?.kind
                    ?? paneStore.modes[paneId]
                    ?? .terminal
                return NativeWorkItem(
                    tabId: tab.id,
                    tabIndex: tab.index,
                    paneId: paneId,
                    paneOrdinal: paneOrdinal,
                    tabTitle: tab.title,
                    paneTitle: workPaneTitle(paneId: paneId, mode: mode),
                    workingDirectory: paneStore.workingDirectories[paneId] ?? "",
                    sessionLabel: tmuxSession.map { "tmux · \($0.sessionName)" } ?? "Local",
                    status: paneStatuses.status(for: paneId),
                    unread: workAttentionStore.isUnread(paneId: paneId),
                    active: tab.index == snapshot.active_tab && paneId == activePaneId
                )
            }
        }
    }

    private func workPaneTitle(paneId: Int, mode: NativePaneMode) -> String {
        if let session = tmuxSession,
            let tmuxPaneId = session.tmuxPaneIds[paneId],
            let command = session.latestPanes[tmuxPaneId]?.current_command,
            !command.isEmpty
        {
            return command
        }
        if let title = paneStore.titles[paneId], !title.isEmpty {
            return title
        }
        return mode == .neovim ? "Neovim" : "Terminal"
    }

    private func paneIsVisibleForAttention(_ paneId: Int) -> Bool {
        paneId == activePaneId
            && NSApp.isActive
            && view.window?.firstResponder === terminalTextView
    }

    private func workPreviewText(paneId: Int) -> String? {
        guard let pane = paneStore.runtimes[paneId] else {
            return nil
        }
        return pane.controlScreenText()
    }

    private func selectWorkItem(_ item: NativeWorkItem) {
        guard let snapshot = lastSnapshot,
            let tab = snapshot.tabs.first(where: { $0.id == item.tabId }),
            tab.panes.contains(item.paneId)
        else {
            NSSound.beep()
            refreshWorkSwitcherPresentation()
            return
        }
        if let session = tmuxSession {
            guard let windowId = session.tmuxWindowIds[item.tabId],
                let tmuxPaneId = session.tmuxPaneIds[item.paneId],
                session.gateway.tmuxCommand("select-window -t @\(windowId)"),
                session.gateway.tmuxCommand("select-pane -t %\(tmuxPaneId)")
            else {
                NSSound.beep()
                return
            }
        } else {
            guard core.selectTab(tab.index), core.selectPane(item.paneId) else {
                NSSound.beep()
                return
            }
            syncFromCore()
        }
        workAttentionStore.markSeen(paneId: item.paneId)
        dismissWorkSwitcher()
        refreshWorkSwitcherPresentation()
        focusTerminal()
    }
}
