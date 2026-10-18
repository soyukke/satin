import AppKit

/// A shell's own commands mark their tab as an agent's work does: running
/// while one runs, and done or failed once it ends unwatched.
extension TerminalShellViewController {
    func observeShellCommand(_ pane: TerminalPane, paneId: Int) {
        let marks = pane.shellCommandMarks()
        let result = shellCommands.observe(
            paneId: paneId, started: marks.started, finished: marks.finished,
            lastExit: marks.lastExit, fullScreen: marks.fullScreen,
            visible: paneIsVisibleForAttention(paneId))
        if let finish = result.finish, !agentReported(paneId: paneId),
            let segment = lastSnapshot?.tabs.first(where: { $0.panes.contains(finish.paneId) })?
                .index
        {
            tabControl.signalFinish(segment: segment, failed: finish.failed)
        }
        guard result.changed else {
            return
        }
        if let snapshot = lastSnapshot {
            syncTabStatusBadges(snapshot)
        }
        scheduleShellBadgeRefresh()
    }

    /// The strongest badge the shells of a tab's panes earn. A pane an agent
    /// reported from during its command shows the agent's status instead.
    func shellCommandBadge(_ panes: [Int]) -> NativeTabStatusBadge? {
        panes.compactMap { paneId in
            agentReported(paneId: paneId) ? nil : shellCommands.badge(for: paneId)
        }.max { $0.rawValue < $1.rawValue }
    }

    /// Whether an agent spoke for the pane since its command started: the
    /// command is the agent itself, and its status says more.
    private func agentReported(paneId: Int) -> Bool {
        guard let agent = paneStatuses.status(for: paneId) else {
            return false
        }
        guard let command = shellCommands.status(for: paneId) else {
            return true
        }
        return agent.updatedAt >= command.startedAt
    }

    /// Redraws the badges when a running command has run long enough to show.
    private func scheduleShellBadgeRefresh() {
        pendingShellBadgeRefresh?.cancel()
        guard let due = shellCommands.nextBadgeChange() else {
            return
        }
        let refresh = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShellBadgeRefresh = nil
            if let snapshot = self.lastSnapshot {
                self.syncTabStatusBadges(snapshot)
            }
            self.scheduleShellBadgeRefresh()
        }
        pendingShellBadgeRefresh = refresh
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.05, due.timeIntervalSinceNow), execute: refresh)
    }
}
