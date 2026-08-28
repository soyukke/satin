import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func waitForTmuxSmokeAgentRunning(
            _ resultPath: String,
            pane: RustTmuxPane,
            start: (x: Int, y: Int),
            tmuxPaneId: UInt32,
            runningTitle: String,
            retries: Int
        ) {
            guard let nativePaneId = tmuxSession?.nativePaneIds[tmuxPaneId] else {
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-native agent-native-pane=no\n")
                return
            }
            let title = paneStore.titles[nativePaneId]
            let status = paneStatuses.status(for: nativePaneId)?.status
            let tabTitle = lastSnapshot?.tabs.first(where: { $0.index == lastSnapshot?.active_tab }
            )?
            .title
            let activity = tabControl.runningActivityReadyForSmoke(
                segment: lastSnapshot?.active_tab ?? -1)
            guard title == runningTitle, status == "running",
                tabTitle == tmuxSmokeStableTabTitle, activity
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.waitForTmuxSmokeAgentRunning(
                            resultPath,
                            pane: pane,
                            start: start,
                            tmuxPaneId: tmuxPaneId,
                            runningTitle: runningTitle,
                            retries: retries - 1
                        )
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-native agent-running title=\(title ?? "nil") "
                            + "tab-title=\(tabTitle ?? "nil") status=\(status ?? "nil") "
                            + "activity=\(activity)\n"
                    )
                }
                return
            }
            let idleTitle = "Satin agent smoke"
            guard
                tmuxSession?.gateway.tmuxCommand(
                    "select-pane -t %\(tmuxPaneId) -T \(tmuxCommandArgument(idleTitle))"
                ) == true
            else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-native agent-title-done-command=no\n")
                return
            }
            waitForTmuxSmokeAgentDone(
                resultPath,
                pane: pane,
                start: start,
                tmuxPaneId: tmuxPaneId,
                idleTitle: idleTitle,
                retries: 30
            )
        }

        func waitForTmuxSmokeAgentDone(
            _ resultPath: String,
            pane: RustTmuxPane,
            start: (x: Int, y: Int),
            tmuxPaneId: UInt32,
            idleTitle: String,
            retries: Int
        ) {
            guard let nativePaneId = tmuxSession?.nativePaneIds[tmuxPaneId] else {
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-native agent-native-pane-done=no\n")
                return
            }
            let title = paneStore.titles[nativePaneId]
            let status = paneStatuses.status(for: nativePaneId)?.status
            let item = nativeWorkItems().first { $0.paneId == nativePaneId }
            let tabTitle = lastSnapshot?.tabs.first(where: { $0.index == lastSnapshot?.active_tab }
            )?
            .title
            let activity = tabControl.runningActivityReadyForSmoke(
                segment: lastSnapshot?.active_tab ?? -1)
            let notified =
                workAttentionStore.isUnread(paneId: nativePaneId)
                && item?.unread == true
                && workSwitcherButton.badgeCountForSmoke() == 1
            guard title == idleTitle, status == "done", notified,
                tabTitle == tmuxSmokeStableTabTitle, !activity
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.waitForTmuxSmokeAgentDone(
                            resultPath,
                            pane: pane,
                            start: start,
                            tmuxPaneId: tmuxPaneId,
                            idleTitle: idleTitle,
                            retries: retries - 1
                        )
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-native agent-done title=\(title ?? "nil") "
                            + "tab-title=\(tabTitle ?? "nil") status=\(status ?? "nil") "
                            + "activity=\(activity) unread=\(item?.unread == true) "
                            + "badge=\(workSwitcherButton.badgeCountForSmoke())\n"
                    )
                }
                return
            }
            markActiveWorkSeen()
            guard !workAttentionStore.isUnread(paneId: nativePaneId),
                workSwitcherButton.badgeCountForSmoke() == 0
            else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-native agent-notification-ack=no\n")
                return
            }
            continueTmuxSmokeAfterAgentStatus(resultPath, pane: pane, start: start)
        }
    }
#endif
