import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    private let tabTitleCwdSmokeManualTitle = "manual smoke title"
    private let tabTitleCwdSmokeRunningTitle = "⠹ Satin activity smoke"
    private let tabTitleCwdSmokeIdleTitle = "Satin activity smoke"

    extension TerminalShellViewController {
        func applyTabTitleCwdSmokeScenario(resultPath: String, expectedCwd: String) {
            waitForTabTitleCwdSmokeStart(
                resultPath: resultPath,
                expectedCwd: expectedCwd,
                retries: 40
            )
        }

        private func waitForTabTitleCwdSmokeStart(
            resultPath: String,
            expectedCwd: String,
            retries: Int
        ) {
            drainTerminalPanes()
            guard let snapshot = lastSnapshot,
                let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab }),
                let pane = paneStore.runtimes[tab.active_pane] as? RustTerminalPane
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTabTitleCwdSmokeStart(
                            resultPath: resultPath,
                            expectedCwd: expectedCwd,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTabTitleCwdSmokeFailure(resultPath, phase: "startup")
                }
                return
            }

            core.renameTab(tab.index, title: tabTitleCwdSmokeManualTitle)
            syncFromCore()
            let command =
                "builtin cd -- \(shellQuote(expectedCwd)); "
                + "printf '\\033]0;\(tabTitleCwdSmokeRunningTitle)\\007'; "
                + "command sleep 2; "
                + "printf '\\033]0;\(tabTitleCwdSmokeIdleTitle)\\007'"
            pane.write(Data("\(command)\r".utf8))
            waitForTabTitleCwdSmokeRunning(
                resultPath: resultPath,
                expectedCwd: expectedCwd,
                originalTabId: tab.id,
                originalPaneId: tab.active_pane,
                retries: 40
            )
        }

        private func waitForTabTitleCwdSmokeRunning(
            resultPath: String,
            expectedCwd: String,
            originalTabId: Int,
            originalPaneId: Int,
            retries: Int
        ) {
            drainTerminalPanes()
            let title = lastSnapshot?.tabs.first(where: { $0.id == originalTabId })?.title
            let cwd = (paneStore.runtimes[originalPaneId] as? RustTerminalPane)?
                .currentWorkingDirectory()
            let running =
                paneStore.titles[originalPaneId] == tabTitleCwdSmokeRunningTitle
                && paneStatuses.status(for: originalPaneId)?.status == "running"
                && tabControl.runningActivityReadyForSmoke(segment: 0)
            guard title == tabTitleCwdSmokeManualTitle,
                tabControl.label(forSegment: 0) == tabTitleCwdSmokeManualTitle,
                cwd == expectedCwd,
                running
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTabTitleCwdSmokeRunning(
                            resultPath: resultPath,
                            expectedCwd: expectedCwd,
                            originalTabId: originalTabId,
                            originalPaneId: originalPaneId,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTabTitleCwdSmokeFailure(
                        resultPath,
                        phase: "running",
                        detail: "title=\(title ?? "nil") cwd=\(cwd ?? "nil") "
                            + "status=\(paneStatuses.status(for: originalPaneId)?.status ?? "nil")"
                    )
                }
                return
            }

            guard let menuItem = mainMenuItem(in: NSApp.mainMenu, command: .newTab),
                menuItem.keyEquivalent == "t",
                let action = menuItem.action,
                NSApp.sendAction(action, to: menuItem.target, from: menuItem)
            else {
                writeTabTitleCwdSmokeFailure(resultPath, phase: "command-t")
                return
            }
            waitForTabTitleCwdSmokeNewTab(
                resultPath: resultPath,
                expectedCwd: expectedCwd,
                originalTabId: originalTabId,
                originalPaneId: originalPaneId,
                retries: 40
            )
        }

        private func waitForTabTitleCwdSmokeNewTab(
            resultPath: String,
            expectedCwd: String,
            originalTabId: Int,
            originalPaneId: Int,
            retries: Int
        ) {
            drainTerminalPanes()
            guard let snapshot = lastSnapshot,
                snapshot.tabs.count == 2,
                let activeTab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab }),
                activeTab.id != originalTabId,
                let newPane = paneStore.runtimes[activeTab.active_pane] as? RustTerminalPane,
                newPane.currentWorkingDirectory() == expectedCwd,
                paneStore.workingDirectories[activeTab.active_pane] == expectedCwd,
                snapshot.tabs.first(where: { $0.id == originalTabId })?.title
                    == tabTitleCwdSmokeManualTitle
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTabTitleCwdSmokeNewTab(
                            resultPath: resultPath,
                            expectedCwd: expectedCwd,
                            originalTabId: originalTabId,
                            originalPaneId: originalPaneId,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTabTitleCwdSmokeFailure(resultPath, phase: "new-tab")
                }
                return
            }
            waitForTabTitleCwdSmokeDone(
                resultPath: resultPath,
                expectedCwd: expectedCwd,
                originalTabId: originalTabId,
                originalPaneId: originalPaneId,
                retries: 50
            )
        }

        private func waitForTabTitleCwdSmokeDone(
            resultPath: String,
            expectedCwd: String,
            originalTabId: Int,
            originalPaneId: Int,
            retries: Int
        ) {
            drainTerminalPanes()
            let title = lastSnapshot?.tabs.first(where: { $0.id == originalTabId })?.title
            let done = paneStatuses.status(for: originalPaneId)?.status == "done"
            let activityStopped = !tabControl.runningActivityReadyForSmoke(segment: 0)
            guard title == tabTitleCwdSmokeManualTitle,
                paneStore.titles[originalPaneId] == tabTitleCwdSmokeIdleTitle,
                done,
                activityStopped
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTabTitleCwdSmokeDone(
                            resultPath: resultPath,
                            expectedCwd: expectedCwd,
                            originalTabId: originalTabId,
                            originalPaneId: originalPaneId,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTabTitleCwdSmokeFailure(
                        resultPath,
                        phase: "done",
                        detail: "title=\(title ?? "nil") "
                            + "pane-title=\(paneStore.titles[originalPaneId] ?? "nil") "
                            + "status=\(paneStatuses.status(for: originalPaneId)?.status ?? "nil")"
                    )
                }
                return
            }
            writeSessionSmokeResult(
                resultPath,
                result: "ok tab-title-cwd title=stable activity=separate cwd=inherited "
                    + "fallback=none expected=\(expectedCwd)\n"
            )
        }

        private func writeTabTitleCwdSmokeFailure(
            _ resultPath: String,
            phase: String,
            detail: String = ""
        ) {
            writeSessionSmokeResult(
                resultPath,
                result: "failed tab-title-cwd phase=\(phase) \(detail)\n"
            )
        }
    }
#endif
