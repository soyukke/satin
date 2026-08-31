import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    private let tmuxSessionSwitchFirstReady = "SATIN_TMUX_SWITCH_FIRST_READY"
    private let tmuxSessionSwitchFirstHistory = "SATIN_TMUX_SWITCH_FIRST_HISTORY"
    private let tmuxSessionSwitchSecondReady = "SATIN_TMUX_SWITCH_SECOND_READY"
    private let tmuxSessionSwitchNewTabReady = "SATIN_TMUX_SWITCH_NEW_TAB_READY"

    extension TerminalShellViewController {
        func applyTmuxSessionSwitchSmokeScenario(
            resultPath: String,
            firstSessionName: String,
            secondSessionName: String,
            socketPath: String,
            executablePath: String
        ) {
            let executable = NativeTmuxExecutable(
                path: executablePath,
                version: "smoke",
                source: .configured
            )
            resolvedTmuxExecutable = executable
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.discoverTmuxSessionSwitchSmoke(
                    resultPath,
                    firstSessionName: firstSessionName,
                    secondSessionName: secondSessionName,
                    socketPath: socketPath,
                    executable: executable
                )
            }
        }

        private func discoverTmuxSessionSwitchSmoke(
            _ resultPath: String,
            firstSessionName: String,
            secondSessionName: String,
            socketPath: String,
            executable: NativeTmuxExecutable
        ) {
            NativeTmuxSessionDiscovery.discover(
                executable: executable,
                socketPath: socketPath
            ) { [weak self] result in
                guard let self else {
                    return
                }
                guard case .sessions(let sessions) = result,
                    let first = sessions.first(where: { $0.name == firstSessionName }),
                    let second = sessions.first(where: { $0.name == secondSessionName })
                else {
                    self.writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "discovery",
                        detail: "sessions=missing"
                    )
                    return
                }
                self.beginTmuxSessionSwitchSmoke(
                    resultPath,
                    executable: executable,
                    first: first,
                    second: second
                )
            }
        }

        private func beginTmuxSessionSwitchSmoke(
            _ resultPath: String,
            executable: NativeTmuxExecutable,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor
        ) {
            guard
                let attachment = validatedTmuxAttachment(
                    NativeTmuxAttachment(
                        sessionName: first.name,
                        socketPath: first.socketPath,
                        executablePath: executable.path
                    )
                )
            else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "attachment",
                    detail: "invalid=yes"
                )
                return
            }

            lastTmuxSocketPath = first.socketPath
            showSessionSwitcher(nil)
            waitForTmuxSessionSwitchFirstPicker(
                resultPath,
                attachment: attachment,
                first: first,
                second: second,
                retries: 40
            )
        }

        private func waitForTmuxSessionSwitchFirstPicker(
            _ resultPath: String,
            attachment: NativeTmuxAttachment,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            retries: Int
        ) {
            guard
                let picker = sessionPopover?.contentViewController
                    as? TmuxSessionPopoverController,
                tmuxSessionPickerContainsExpectedRows(
                    picker,
                    first: first,
                    second: second
                )
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSessionSwitchFirstPicker(
                            resultPath,
                            attachment: attachment,
                            first: first,
                            second: second,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "first-picker-list",
                        detail: "rows=missing"
                    )
                }
                return
            }

            // Reproduce the startup race only after the actual popover has
            // finished discovery: automatic restore and the explicit row click
            // now compete for the same session.
            pendingTmuxReattach = attachment
            schedulePendingTmuxReattach()
            guard picker.selectSessionForSmoke(first) else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "first-picker",
                    detail: "click=no"
                )
                return
            }
            waitForTmuxSessionSwitchFirstEntry(
                resultPath,
                first: first,
                second: second,
                retries: 60
            )
        }

        private func tmuxSessionPickerContainsExpectedRows(
            _ picker: TmuxSessionPopoverController,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor
        ) -> Bool {
            let titles = picker.sessionRowTitlesForSmoke()
            return titles.contains("Local Terminal")
                && titles.contains(where: { $0.hasPrefix("\(first.name)  ·  ") })
                && titles.contains(where: { $0.hasPrefix("\(second.name)  ·  ") })
        }

        private func waitForTmuxSessionSwitchFirstEntry(
            _ resultPath: String,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            retries: Int
        ) {
            drainTerminalPanes()
            let pane = activePaneId.flatMap { paneStore.runtimes[$0] as? RustTmuxPane }
            let commandCount = tmuxConnectionCommandHistory.count
            let ready =
                tmuxSession?.sessionName == first.name
                && pane?.controlScreenText().contains(tmuxSessionSwitchFirstReady) == true
                && commandCount == 1
                && pendingTmuxReattach == nil
                && !tmuxReattachInFlight
            guard ready else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSessionSwitchFirstEntry(
                            resultPath,
                            first: first,
                            second: second,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "first-entry",
                        detail: "session=\(tmuxSession?.sessionName ?? "none") "
                            + "commands=\(commandCount) pending=\(pendingTmuxReattach != nil)"
                    )
                }
                return
            }
            let expectedCommand =
                "\(shellQuote(resolvedTmuxExecutable?.path ?? "")) "
                + "-S \(shellQuote(first.socketPath)) "
                + "-CC attach-session -t \(shellQuote(first.name))"
            guard tmuxConnectionCommandHistory == [expectedCommand], let pane else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "single-command",
                    detail: "commands=\(commandCount)"
                )
                return
            }

            showSessionSwitcher(nil)
            waitForAttachedTmuxSessionPicker(
                resultPath,
                pane: pane,
                first: first,
                second: second,
                retries: 40
            )
        }

        private func waitForAttachedTmuxSessionPicker(
            _ resultPath: String,
            pane: RustTmuxPane,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            retries: Int
        ) {
            guard
                let picker = sessionPopover?.contentViewController
                    as? TmuxSessionPopoverController,
                tmuxSessionPickerContainsExpectedRows(
                    picker,
                    first: first,
                    second: second
                )
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.waitForAttachedTmuxSessionPicker(
                            resultPath,
                            pane: pane,
                            first: first,
                            second: second,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "attached-picker-list",
                        detail: "rows=missing"
                    )
                }
                return
            }
            dismissSessionPopover()
            view.layoutSubtreeIfNeeded()
            let sessionFrame = sessionControlButton.convert(sessionControlButton.bounds, to: nil)
            let workFrame = workSwitcherButton.convert(workSwitcherButton.bounds, to: nil)
            let contentFrame = view.convert(view.bounds, to: nil)
            guard workFrame.minX < sessionFrame.minX,
                sessionFrame.maxX >= contentFrame.maxX - 32
            else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "attached-toolbar",
                    detail: "work=\(Int(workFrame.minX)) session=\(Int(sessionFrame.minX))/"
                        + "\(Int(sessionFrame.maxX)) content=\(Int(contentFrame.maxX))"
                )
                return
            }
            guard let menuItem = mainMenuItem(in: NSApp.mainMenu, command: .newTab),
                menuItem.keyEquivalent == "t"
            else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "command-t-menu",
                    detail: "item=missing"
                )
                return
            }
            let initialTabCount = lastSnapshot?.tabs.count ?? 0
            guard let activePaneId,
                let activeTmuxPaneId = tmuxSession?.tmuxPaneIds[activePaneId],
                let expectedCwd = tmuxSession?.latestPanes[activeTmuxPaneId]?.current_path
            else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "command-t-cwd",
                    detail: "source=missing"
                )
                return
            }
            guard let action = menuItem.action,
                NSApp.sendAction(action, to: menuItem.target, from: menuItem)
            else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "command-t-menu",
                    detail: "action=no"
                )
                return
            }
            waitForTmuxCommandTTab(
                resultPath,
                pane: pane,
                first: first,
                second: second,
                initialTabCount: initialTabCount,
                expectedCwd: expectedCwd,
                retries: 40
            )
        }

        private func waitForTmuxCommandTTab(
            _ resultPath: String,
            pane: RustTmuxPane,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            initialTabCount: Int,
            expectedCwd: String,
            retries: Int
        ) {
            drainTerminalPanes()
            guard lastSnapshot?.tabs.count == initialTabCount + 1,
                let newPaneId = activePaneId,
                let newPane = paneStore.runtimes[newPaneId] as? RustTmuxPane,
                let newTmuxPaneId = tmuxSession?.tmuxPaneIds[newPaneId],
                tmuxSession?.latestPanes[newTmuxPaneId]?.current_path == expectedCwd,
                paneStore.workingDirectories[newPaneId] == expectedCwd
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.waitForTmuxCommandTTab(
                            resultPath,
                            pane: pane,
                            first: first,
                            second: second,
                            initialTabCount: initialTabCount,
                            expectedCwd: expectedCwd,
                            retries: retries - 1
                        )
                    }
                } else {
                    let newPaneId = activePaneId
                    let newTmuxPaneId = newPaneId.flatMap { tmuxSession?.tmuxPaneIds[$0] }
                    let projectedCwd = newTmuxPaneId.flatMap {
                        tmuxSession?.latestPanes[$0]?.current_path
                    }
                    let storedCwd = newPaneId.flatMap { paneStore.workingDirectories[$0] }
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "command-t-tab",
                        detail: "tabs=\(lastSnapshot?.tabs.count ?? -1) "
                            + "expected=\(expectedCwd) projected=\(projectedCwd ?? "nil") "
                            + "stored=\(storedCwd ?? "nil")"
                    )
                }
                return
            }
            guard newPane.pasteThroughTmux("printf '\(tmuxSessionSwitchNewTabReady)\\n'"),
                newPane.writeThroughTmux(Data([13]))
            else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "command-t-input",
                    detail: "sent=no"
                )
                return
            }
            waitForTmuxCommandTContent(
                resultPath,
                originalPane: pane,
                newPane: newPane,
                first: first,
                second: second,
                initialTabCount: initialTabCount,
                retries: 30
            )
        }

        private func waitForTmuxCommandTContent(
            _ resultPath: String,
            originalPane: RustTmuxPane,
            newPane: RustTmuxPane,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            initialTabCount: Int,
            retries: Int
        ) {
            drainTerminalPanes()
            guard newPane.controlScreenText().contains(tmuxSessionSwitchNewTabReady) else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        [weak self, weak originalPane, weak newPane] in
                        guard let originalPane, let newPane else {
                            return
                        }
                        self?.waitForTmuxCommandTContent(
                            resultPath,
                            originalPane: originalPane,
                            newPane: newPane,
                            first: first,
                            second: second,
                            initialTabCount: initialTabCount,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "command-t-content",
                        detail: "visible=no"
                    )
                }
                return
            }
            guard tmuxSession?.gateway.tmuxCommand("kill-window") == true else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "command-t-cleanup",
                    detail: "kill=no"
                )
                return
            }
            waitForTmuxCommandTCleanup(
                resultPath,
                pane: originalPane,
                first: first,
                second: second,
                initialTabCount: initialTabCount,
                retries: 30
            )
        }

        private func waitForTmuxCommandTCleanup(
            _ resultPath: String,
            pane: RustTmuxPane,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            initialTabCount: Int,
            retries: Int
        ) {
            drainTerminalPanes()
            guard lastSnapshot?.tabs.count == initialTabCount else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.waitForTmuxCommandTCleanup(
                            resultPath,
                            pane: pane,
                            first: first,
                            second: second,
                            initialTabCount: initialTabCount,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "command-t-cleanup",
                        detail: "tabs=\(lastSnapshot?.tabs.count ?? -1)"
                    )
                }
                return
            }
            waitForTmuxSessionSwitchScrollback(
                resultPath,
                pane: pane,
                first: first,
                second: second,
                retries: 60
            )
        }

        private func waitForTmuxSessionSwitchScrollback(
            _ resultPath: String,
            pane: RustTmuxPane,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            retries: Int
        ) {
            let probeRows = pane.scroll(rows: -1)
            guard probeRows != 0 else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxSessionSwitchScrollback(
                            resultPath,
                            pane: pane,
                            first: first,
                            second: second,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "scrollback-hydration",
                        detail: "ready=no"
                    )
                }
                return
            }
            _ = pane.scroll(rows: -probeRows)
            let historyInitiallyHidden =
                !pane.controlScreenText().contains(tmuxSessionSwitchFirstHistory)
            let wheelSent = (0..<14).allSatisfy { _ in
                terminalTextView.scrollWheelForSmoke(deltaY: 6)
            }
            let historyVisible =
                pane.controlScreenText().contains(tmuxSessionSwitchFirstHistory)
            for _ in 0..<14 {
                _ = terminalTextView.scrollWheelForSmoke(deltaY: -6)
            }
            guard historyInitiallyHidden, wheelSent, historyVisible else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "wheel-scrollback",
                    detail: "initial=\(historyInitiallyHidden) sent=\(wheelSent) "
                        + "history=\(historyVisible)"
                )
                return
            }
            selectSecondTmuxSessionForSmoke(
                resultPath,
                first: first,
                second: second
            )
        }

        private func selectSecondTmuxSessionForSmoke(
            _ resultPath: String,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor
        ) {
            showSessionSwitcher(nil)
            waitForSecondTmuxSessionPicker(
                resultPath,
                first: first,
                second: second,
                retries: 40
            )
        }

        private func waitForSecondTmuxSessionPicker(
            _ resultPath: String,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            retries: Int
        ) {
            guard
                let picker = sessionPopover?.contentViewController
                    as? TmuxSessionPopoverController,
                tmuxSessionPickerContainsExpectedRows(
                    picker,
                    first: first,
                    second: second
                )
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForSecondTmuxSessionPicker(
                            resultPath,
                            first: first,
                            second: second,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "second-picker-list",
                        detail: "rows=missing"
                    )
                }
                return
            }
            guard picker.selectSessionForSmoke(second) else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "second-picker",
                    detail: "click=no"
                )
                return
            }
            waitForSecondTmuxSession(
                resultPath,
                first: first,
                second: second,
                retries: 60
            )
        }

        private func waitForSecondTmuxSession(
            _ resultPath: String,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            retries: Int
        ) {
            drainTerminalPanes()
            let secondVisible =
                activePaneId
                .flatMap { paneStore.runtimes[$0] as? RustTmuxPane }?
                .controlScreenText()
                .contains(tmuxSessionSwitchSecondReady) == true
            let switched =
                tmuxSession?.sessionName == second.name
                && secondVisible
                && tmuxConnectionCommandHistory.count == 1
            guard switched else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForSecondTmuxSession(
                            resultPath,
                            first: first,
                            second: second,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "switch",
                        detail: "session=\(tmuxSession?.sessionName ?? "none") "
                            + "visible=\(secondVisible) "
                            + "commands=\(tmuxConnectionCommandHistory.count)"
                    )
                }
                return
            }
            showSessionSwitcher(nil)
            waitForLocalTmuxSessionPicker(
                resultPath,
                first: first,
                second: second,
                shouldReattach: true,
                retries: 40
            )
        }

        private func waitForLocalTmuxSessionPicker(
            _ resultPath: String,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            shouldReattach: Bool,
            retries: Int
        ) {
            guard
                let picker = sessionPopover?.contentViewController
                    as? TmuxSessionPopoverController,
                tmuxSessionPickerContainsExpectedRows(
                    picker,
                    first: first,
                    second: second
                )
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForLocalTmuxSessionPicker(
                            resultPath,
                            first: first,
                            second: second,
                            shouldReattach: shouldReattach,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "local-picker-list",
                        detail: "rows=missing"
                    )
                }
                return
            }
            guard picker.selectLocalForSmoke() else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "local-picker",
                    detail: "click=no"
                )
                return
            }
            waitForTmuxSessionSwitchDetach(
                resultPath,
                first: first,
                second: second,
                shouldReattach: shouldReattach,
                retries: 30
            )
        }

        private func waitForTmuxSessionSwitchDetach(
            _ resultPath: String,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            shouldReattach: Bool,
            retries: Int
        ) {
            guard tmuxSession == nil else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSessionSwitchDetach(
                            resultPath,
                            first: first,
                            second: second,
                            shouldReattach: shouldReattach,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "detach",
                        detail: "session=still-attached"
                    )
                }
                return
            }
            if shouldReattach {
                showSessionSwitcher(nil)
                waitForReattachTmuxSessionPicker(
                    resultPath,
                    first: first,
                    second: second,
                    retries: 40
                )
                return
            }
            writeSessionSmokeResult(
                resultPath,
                result: "ok tmux-session-switch picker=actual-popover lists=local+tmux "
                    + "attach-command=deduplicated command-t=yes command-t-cwd=inherited "
                    + "toolbar=trailing "
                    + "reattach-race=cancelled wheel-scrollback=yes switch-client=yes "
                    + "detach-reattach=yes shell-command-count=2 detach=yes\n"
            )
        }

        private func waitForReattachTmuxSessionPicker(
            _ resultPath: String,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            retries: Int
        ) {
            guard
                let picker = sessionPopover?.contentViewController
                    as? TmuxSessionPopoverController,
                tmuxSessionPickerContainsExpectedRows(
                    picker,
                    first: first,
                    second: second
                )
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForReattachTmuxSessionPicker(
                            resultPath,
                            first: first,
                            second: second,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "reattach-picker-list",
                        detail: "rows=missing"
                    )
                }
                return
            }
            guard picker.selectSessionForSmoke(second) else {
                writeTmuxSessionSwitchFailure(
                    resultPath,
                    phase: "reattach-picker",
                    detail: "click=no"
                )
                return
            }
            waitForReattachedTmuxSession(
                resultPath,
                first: first,
                second: second,
                retries: 60
            )
        }

        private func waitForReattachedTmuxSession(
            _ resultPath: String,
            first: NativeTmuxSessionDescriptor,
            second: NativeTmuxSessionDescriptor,
            retries: Int
        ) {
            drainTerminalPanes()
            let secondVisible =
                activePaneId
                .flatMap { paneStore.runtimes[$0] as? RustTmuxPane }?
                .controlScreenText()
                .contains(tmuxSessionSwitchSecondReady) == true
            let reattached =
                tmuxSession?.sessionName == second.name
                && secondVisible
                && tmuxConnectionCommandHistory.count == 2
            guard reattached else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForReattachedTmuxSession(
                            resultPath,
                            first: first,
                            second: second,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeTmuxSessionSwitchFailure(
                        resultPath,
                        phase: "reattach",
                        detail: "session=\(tmuxSession?.sessionName ?? "none") "
                            + "visible=\(secondVisible) "
                            + "commands=\(tmuxConnectionCommandHistory.count)"
                    )
                }
                return
            }
            showSessionSwitcher(nil)
            waitForLocalTmuxSessionPicker(
                resultPath,
                first: first,
                second: second,
                shouldReattach: false,
                retries: 40
            )
        }

        private func writeTmuxSessionSwitchFailure(
            _ resultPath: String,
            phase: String,
            detail: String
        ) {
            _ = tmuxSession?.gateway.tmuxCommand("detach-client")
            let screen =
                activePaneId
                .flatMap { paneStore.runtimes[$0] as? RustTerminalPane }?
                .controlScreenText()
                .suffix(400)
                .replacingOccurrences(of: "\n", with: "|") ?? "none"
            writeSessionSmokeResult(
                resultPath,
                result: "failed tmux-session-switch phase=\(phase) \(detail) "
                    + "screen=\(screen)\n"
            )
        }
    }
#endif
