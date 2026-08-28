import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    let tmuxSmokeStableTabTitle = "tmux manual smoke title"

    extension TerminalShellViewController {
        func applyTmuxNativeSmokeScenario(resultPath: String) {
            waitForTmuxSmokeLayout(resultPath, previousGrid: nil, retries: 10)
        }

        func waitForTmuxSmokeLayout(
            _ resultPath: String,
            previousGrid: (rows: Int, cols: Int)?,
            retries: Int
        ) {
            view.layoutSubtreeIfNeeded()
            resizeTerminalPanesToGrid()
            let grid = tmuxClientGrid()
            if previousGrid?.rows != grid.rows || previousGrid?.cols != grid.cols {
                guard retries > 0 else {
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-native layout-unstable\n")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokeLayout(
                        resultPath,
                        previousGrid: (rows: grid.rows, cols: grid.cols),
                        retries: retries - 1
                    )
                }
                return
            }

            let socket = "satin-native-smoke-\(ProcessInfo.processInfo.processIdentifier)"
            let command =
                "tmux -L \(socket) new-session -d -s satin-native-smoke && "
                + "tmux -L \(socket) send-keys -t satin-native-smoke "
                + "\"printf 'TMUX_HISTORY_MARKER\\n'; seq 1 120\" Enter && sleep 0.2 && "
                + "tmux -L \(socket) -CC attach -t satin-native-smoke"
            writeToActivePane(Data("\(command)\r".utf8))
            waitForTmuxSmokeEntry(resultPath, retries: 40)
        }

        func waitForTmuxSmokeEntry(_ resultPath: String, retries: Int) {
            guard retries > 0 else {
                let live =
                    activePaneId
                    .flatMap { paneStore.runtimes[$0] as? RustTmuxPane }?
                    .cursorPosition()
                let projected = tmuxSession?.latestPanes.values.first(where: { $0.active })
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-native entry-timeout "
                        + "live-cursor=\(live?.x ?? -1),\(live?.y ?? -1) "
                        + "tmux-cursor=\(projected.map { Int($0.cursor_x) } ?? -1),"
                        + "\(projected.map { Int($0.cursor_y) } ?? -1)\n"
                )
                return
            }
            guard tmuxSession != nil,
                lastSnapshot?.tabs.count == 1,
                lastSnapshot?.tabs.first?.panes.count == 1,
                sessionControlTitle().hasPrefix("tmux · "),
                view.window?.title.contains("tmux · ") == true
            else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokeEntry(resultPath, retries: retries - 1)
                }
                return
            }
            guard let tmuxPane = activePaneId.flatMap({ paneStore.runtimes[$0] as? RustTmuxPane })
            else {
                writeSessionSmokeResult(resultPath, result: "failed tmux-native missing-pane\n")
                return
            }
            let projectedPane = tmuxSession?.latestPanes.values.first { $0.active }
            let currentGrid = tmuxClientGrid()
            let projectedGridIsSettled =
                projectedPane.map {
                    Int($0.cols) == currentGrid.cols && Int($0.rows) == currentGrid.rows
                } ?? false
            let gridIsSettled =
                tmuxSession?.requestedClientGrid?.cols == currentGrid.cols
                && tmuxSession?.requestedClientGrid?.rows == currentGrid.rows
                && projectedGridIsSettled
            // The projection cursor belongs to the last topology snapshot and can lag
            // live %output. The retained terminal cursor is the rendering/input source
            // of truth, so do not turn normal control-protocol ordering into a timeout.
            guard let tmuxCursor = tmuxPane.cursorPosition(),
                tmuxCursor.x > 0,
                let projectedPane,
                gridIsSettled
            else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTmuxSmokeEntry(resultPath, retries: retries - 1)
                }
                return
            }
            if tmuxZoomResizeSmokeOnly() {
                continueTmuxSmokeSplit(resultPath)
                return
            }
            let runningTitle = "⠹ Satin agent smoke"
            guard
                tmuxSession?.gateway.tmuxCommand(
                    "rename-window \(tmuxCommandArgument(tmuxSmokeStableTabTitle))"
                ) == true,
                tmuxSession?.gateway.tmuxCommand(
                    "select-pane -t %\(projectedPane.pane_id) "
                        + "-T \(tmuxCommandArgument(runningTitle))"
                ) == true
            else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-native agent-title-running-command=no\n")
                return
            }
            waitForTmuxSmokeAgentRunning(
                resultPath,
                pane: tmuxPane,
                start: tmuxCursor,
                tmuxPaneId: projectedPane.pane_id,
                runningTitle: runningTitle,
                retries: 30
            )
        }

        func continueTmuxSmokeAfterAgentStatus(
            _ resultPath: String,
            pane tmuxPane: RustTmuxPane,
            start tmuxCursor: (x: Int, y: Int)
        ) {
            tabControl.verifyAsyncCloseForSmoke(
                open: { [weak self] in
                    self?.tmuxSession?.gateway.tmuxCommand(
                        "new-window -n satin-tab-close-smoke"
                    ) == true
                },
                modelState: { [weak self] in
                    self?.lastSnapshot.map { ($0.tabs.count, $0.active_tab) }
                },
                completion: { [weak self, weak tmuxPane] failure in
                    guard let self, let tmuxPane else {
                        return
                    }
                    guard failure == nil else {
                        self.tmuxSession?.gateway.tmuxCommand("kill-session")
                        self.writeSessionSmokeResult(
                            resultPath,
                            result: "failed tmux-native \(failure ?? "tab-close=unknown")\n"
                        )
                        return
                    }
                    let marker = "TMUX_CURSOR_ADVANCE"
                    guard tmuxPane.writeThroughTmux(Data(marker.utf8)) else {
                        self.tmuxSession?.gateway.tmuxCommand("kill-session")
                        self.writeSessionSmokeResult(
                            resultPath,
                            result: "failed tmux-native cursor-input=no\n"
                        )
                        return
                    }
                    self.waitForTmuxSmokeLiveCursor(
                        resultPath,
                        pane: tmuxPane,
                        start: tmuxCursor,
                        marker: marker,
                        retries: 20
                    )
                }
            )
        }

        func waitForTmuxSmokeLiveCursor(
            _ resultPath: String,
            pane: RustTmuxPane,
            start: (x: Int, y: Int),
            marker: String,
            retries: Int
        ) {
            let cursor = pane.cursorPosition()
            let cursorAdvanced =
                cursor?.y == start.y
                && (cursor?.x ?? -1) >= start.x + marker.count
            let inputVisible = pane.controlScreenText().contains(marker)
            guard cursorAdvanced, inputVisible else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSmokeLiveCursor(
                            resultPath,
                            pane: pane,
                            start: start,
                            marker: marker,
                            retries: retries - 1
                        )
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-native live-cursor=no "
                            + "start=\(start.x),\(start.y) "
                            + "observed=\(cursor?.x ?? -1),\(cursor?.y ?? -1)\n"
                    )
                }
                return
            }
            guard pane.writeThroughTmux(Data([3])) else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native cursor-clear=no\n")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.continueTmuxSmokeIME(resultPath, pane: pane, retries: 30)
            }
        }

        func continueTmuxSmokeIME(
            _ resultPath: String,
            pane tmuxPane: RustTmuxPane,
            retries: Int
        ) {
            terminalTextView.setMarkedText(
                "TMUX_IME_PREEDIT",
                selectedRange: NSRange(location: 16, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            let imeOrigin = terminalTextView.markedTextOriginForSmoke()
            guard let paneId = activePaneId,
                let paneFrame = paneStore.visibleFrames[paneId],
                paneFrame.contains(imeOrigin),
                imeOrigin.x > paneFrame.minX + 1
            else {
                terminalTextView.unmarkText()
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        [weak self, weak tmuxPane] in
                        guard let tmuxPane else {
                            return
                        }
                        self?.continueTmuxSmokeIME(
                            resultPath,
                            pane: tmuxPane,
                            retries: retries - 1
                        )
                    }
                    return
                }
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native ime-anchor=no\n")
                return
            }
            terminalTextView.insertText(
                "printf 'TMUX_IME_%s\\n' COMMITTED\r",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            _ = tmuxPane.scroll(rows: -10_000)
            let historyVisible = tmuxPane.controlScreenText().contains("TMUX_HISTORY_MARKER")
            _ = tmuxPane.scroll(rows: 10_000)
            guard historyVisible else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native history=no\n")
                return
            }
            let shellCheck =
                "test \"$SHELL\" = \"$SATIN_SHELL_EXECUTABLE\" "
                + "&& printf 'TMUX_NATIVE_%s SHELL_MATCH=%s\\n' OUTPUT yes "
                + "|| printf 'TMUX_NATIVE_%s SHELL_MATCH=%s SHELL=%s SELECTED=%s\\n' "
                + "OUTPUT no \"$SHELL\" \"$SATIN_SHELL_EXECUTABLE\""
            writeTextToActivePane("\(shellCheck)\r")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.waitForTmuxSmokeOutput(resultPath, retries: 20)
            }
        }

        func waitForTmuxSmokeOutput(_ resultPath: String, retries: Int) {
            let screenText =
                activePaneId
                .flatMap { paneStore.runtimes[$0] as? RustTmuxPane }?
                .controlScreenText() ?? ""
            if screenText.contains("TMUX_NATIVE_OUTPUT SHELL_MATCH=no") {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                let detail =
                    screenText
                    .split(separator: "\n")
                    .last(where: { $0.contains("TMUX_NATIVE_OUTPUT SHELL_MATCH=no") })
                    .map(String.init) ?? "missing"
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-native shell-env=no detail=\(detail)\n"
                )
                return
            }
            let outputVisible = screenText.contains("TMUX_NATIVE_OUTPUT SHELL_MATCH=yes")
            let imeInputVisible = screenText.contains("TMUX_IME_COMMITTED")
            guard outputVisible, imeInputVisible else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSmokeOutput(resultPath, retries: retries - 1)
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-native output-timeout\n")
                }
                return
            }
            beginTmuxSmokeKitty(resultPath)
        }

        func beginTmuxSmokeKitty(_ resultPath: String) {
            guard let pane = activePaneId.flatMap({ paneStore.runtimes[$0] as? RustTmuxPane })
            else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native kitty-pane=no\n")
                return
            }
            let command =
                "printf '\\033Ptmux;\\033\\033_G"
                + "a=T,f=24,s=1,v=1,i=4242,c=8,r=4,q=2;/wAA"
                + "\\033\\033\\\\\\033\\\\'"
            guard pane.pasteThroughTmux(command), pane.writeThroughTmux(Data([13])) else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native kitty-input=no\n")
                return
            }
            waitForTmuxSmokeKitty(resultPath, pane: pane, retries: 30)
        }

        func waitForTmuxSmokeKitty(
            _ resultPath: String,
            pane: RustTmuxPane,
            retries: Int
        ) {
            guard pane.controlImageCount() == 1 else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.waitForTmuxSmokeKitty(
                            resultPath,
                            pane: pane,
                            retries: retries - 1
                        )
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-native kitty-image=no\n")
                }
                return
            }
            let clear =
                "printf '\\033Ptmux;\\033\\033_Ga=d,d=I,i=4242,q=2"
                + "\\033\\033\\\\\\033\\\\'"
            guard pane.pasteThroughTmux(clear), pane.writeThroughTmux(Data([13])) else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native kitty-clear=no\n")
                return
            }
            beginTmuxSmokeReturnRepeat(resultPath)
        }

        func beginTmuxSmokeReturnRepeat(_ resultPath: String) {
            guard let pane = activePaneId.flatMap({ paneStore.runtimes[$0] as? RustTmuxPane }),
                pane.writeThroughTmux(Data("PS1='TMUX_REPEAT> '\r".utf8))
            else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native repeat-setup=no\n")
                return
            }
            waitForTmuxSmokeReturnPrompt(resultPath, pane: pane, retries: 20)
        }

        func waitForTmuxSmokeReturnPrompt(
            _ resultPath: String,
            pane: RustTmuxPane,
            retries: Int
        ) {
            let marker = "TMUX_REPEAT>"
            let lastLine = pane.controlScreenText()
                .split(separator: "\n")
                .last
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard lastLine == marker else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.waitForTmuxSmokeReturnPrompt(
                            resultPath,
                            pane: pane,
                            retries: retries - 1
                        )
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-native repeat-prompt=no\n")
                }
                return
            }
            sendTmuxSmokeReturnRepeat(resultPath, pane: pane, remaining: 65)
        }

        func sendTmuxSmokeReturnRepeat(
            _ resultPath: String,
            pane: RustTmuxPane,
            remaining: Int
        ) {
            guard remaining > 0 else {
                if let event = tmuxSmokeReturnEvent(repeated: false, released: true) {
                    _ = pane.key(event, released: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak pane] in
                    guard let pane else {
                        return
                    }
                    self?.validateTmuxSmokeReturnRepeat(resultPath, pane: pane, retries: 10)
                }
                return
            }
            guard let event = tmuxSmokeReturnEvent(repeated: true, released: false),
                pane.key(event, released: false)
            else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native repeat-input=no\n")
                return
            }
            if remaining == 65, !pane.isAwaitingRepeatedReturnPrompt {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-native repeat-gate=inactive\n"
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak pane] in
                guard let pane else {
                    return
                }
                self?.sendTmuxSmokeReturnRepeat(
                    resultPath,
                    pane: pane,
                    remaining: remaining - 1
                )
            }
        }

        func validateTmuxSmokeReturnRepeat(
            _ resultPath: String,
            pane: RustTmuxPane,
            retries: Int
        ) {
            let marker = "TMUX_REPEAT>"
            let lines = pane.controlScreenText().components(separatedBy: .newlines)
            let markerRows = lines.indices.filter {
                lines[$0].trimmingCharacters(in: .whitespaces) == marker
            }
            let continuous =
                markerRows.count >= 10
                && markerRows.first.flatMap { first in
                    markerRows.last.map { last in
                        lines[first...last].allSatisfy {
                            $0.trimmingCharacters(in: .whitespaces) == marker
                        }
                    }
                } == true
            guard continuous else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.validateTmuxSmokeReturnRepeat(
                            resultPath,
                            pane: pane,
                            retries: retries - 1
                        )
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-native repeat-gap=yes rows=\(markerRows.count)\n"
                    )
                }
                return
            }
            continueTmuxSmokeSplit(resultPath)
        }

        func tmuxSmokeReturnEvent(repeated: Bool, released: Bool) -> NSEvent? {
            NSEvent.keyEvent(
                with: released ? .keyUp : .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: repeated,
                keyCode: 36
            )
        }

        func continueTmuxSmokeSplit(_ resultPath: String) {
            guard let paneId = activePaneId,
                runTmuxSmokeControl([
                    "command": "split",
                    "pane": paneId,
                    "axis": "vertical",
                ])
            else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native cli-split=no\n")
                return
            }
            waitForTmuxSmokeSplit(resultPath, previousPaneId: paneId, retries: 30)
        }

        func waitForTmuxSmokeSplit(
            _ resultPath: String,
            previousPaneId: Int,
            retries: Int
        ) {
            guard lastSnapshot?.tabs.first?.panes.count == 2,
                activePaneId != previousPaneId
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSmokeSplit(
                            resultPath,
                            previousPaneId: previousPaneId,
                            retries: retries - 1
                        )
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-native split-timeout\n")
                }
                return
            }
            let expected = tmuxClientGrid()
            guard tmuxSession?.requestedClientGrid?.cols == expected.cols,
                tmuxSession?.requestedClientGrid?.rows == expected.rows
            else {
                let observed = tmuxSession?.requestedClientGrid
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath,
                    result:
                        "failed tmux-native client-grid expected=\(expected.cols)x\(expected.rows) "
                        + "observed=\(observed?.cols ?? -1)x\(observed?.rows ?? -1)\n"
                )
                return
            }
            if tmuxZoomResizeSmokeOnly() {
                beginTmuxGridMatrixSplit(resultPath)
                return
            }
            guard verifyTmuxSmokeFontZoom(baselineGrid: expected) else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-native font-zoom=no\n")
                return
            }
            guard let initialRatio = lastSnapshot?.tabs.first?.layout.ratio,
                terminalTextView.splitDividerCount(for: .vertical) == 1,
                terminalTextView.splitDividerUsesResizeCursor(for: .vertical),
                terminalTextView.resizeFirstDividerForSmoke(
                    axis: .vertical,
                    ratio: initialRatio > 0.4 ? initialRatio - 0.1 : initialRatio + 0.1
                )
            else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-native split-divider=no\n"
                )
                return
            }
            waitForTmuxSmokeDividerResize(
                resultPath,
                initialRatio: initialRatio,
                retries: 30
            )
        }

        func waitForTmuxSmokeDividerResize(
            _ resultPath: String,
            initialRatio: Double,
            retries: Int
        ) {
            let observedRatio = lastSnapshot?.tabs.first?.layout.ratio
            guard observedRatio.map({ abs($0 - initialRatio) > 0.02 }) == true else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSmokeDividerResize(
                            resultPath,
                            initialRatio: initialRatio,
                            retries: retries - 1
                        )
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-native split-divider-resize=no\n"
                    )
                }
                return
            }
            beginTmuxSmokePaneDrag(resultPath)
        }

        func continueTmuxSmokeAfterDividerResize(_ resultPath: String) {
            guard let tab = lastSnapshot?.tabs.first,
                let currentPaneId = activePaneId,
                let targetPaneId = tab.panes.first(where: { $0 != currentPaneId })
            else {
                writeSessionSmokeResult(resultPath, result: "failed tmux-native action-context\n")
                return
            }
            selectPane(targetPaneId)
            terminalTextView.insertText(
                "printf 'TMUX_FOCUS_%s\\n' COMMITTED\r",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            waitForTmuxSmokeFocusInput(resultPath, paneId: targetPaneId, retries: 30)
        }

        func waitForTmuxSmokeFocusInput(
            _ resultPath: String,
            paneId: Int,
            retries: Int
        ) {
            let focusedInputVisible =
                (paneStore.runtimes[paneId] as? RustTmuxPane)?
                .controlScreenText()
                .contains("TMUX_FOCUS_COMMITTED") == true
            guard focusedInputVisible, activePaneId == paneId else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSmokeFocusInput(
                            resultPath,
                            paneId: paneId,
                            retries: retries - 1
                        )
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-native focus-input=no\n")
                }
                return
            }
            continueTmuxSmokeActions(resultPath, paneId: paneId)
        }

        func continueTmuxSmokeActions(_ resultPath: String, paneId: Int) {
            guard let session = tmuxSession,
                let tab = lastSnapshot?.tabs.first,
                let pane = paneStore.runtimes[paneId] as? RustTmuxPane
            else {
                writeSessionSmokeResult(resultPath, result: "failed tmux-native action-context\n")
                return
            }
            guard
                runTmuxSmokeControl([
                    "command": "rename-tab",
                    "tab": tab.id,
                    "title": "tmux renamed",
                ])
            else {
                session.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native cli-rename=no\n")
                return
            }
            let pasteAccepted = pane.pasteThroughTmux("printf 'TMUX_PASTE_OK\\n'")
            let enterAccepted = pane.writeThroughTmux(Data([13]))
            guard pasteAccepted, enterAccepted else {
                session.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-native input-rejected "
                        + "paste=\(pasteAccepted ? "yes" : "no") "
                        + "enter=\(enterAccepted ? "yes" : "no")\n"
                )
                return
            }
            waitForTmuxSmokePaste(resultPath, retries: 30)
        }

        func waitForTmuxSmokePaste(_ resultPath: String, retries: Int) {
            let pasted = paneStore.runtimes.values.contains { pane in
                (pane as? RustTmuxPane)?.controlScreenText().contains("TMUX_PASTE_OK") == true
            }
            guard pasted else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSmokePaste(resultPath, retries: retries - 1)
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-native paste-timeout\n")
                }
                return
            }
            toggleTmuxPaneZoom(nil)
            waitForTmuxSmokeZoom(resultPath, retries: 30)
        }

        func waitForTmuxSmokeZoom(_ resultPath: String, retries: Int) {
            guard lastSnapshot?.tabs.first?.panes.count == 1,
                tmuxSession?.activeWindowZoomed == true,
                sessionControlTitle().contains("· Zoom")
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSmokeZoom(resultPath, retries: retries - 1)
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(resultPath, result: "failed tmux-native zoom-timeout\n")
                }
                return
            }
            toggleTmuxPaneZoom(nil)
            waitForTmuxSmokeUnzoom(resultPath, retries: 30)
        }

        func waitForTmuxSmokeUnzoom(_ resultPath: String, retries: Int) {
            let paneTexts = paneStore.runtimes.values.compactMap { pane in
                (pane as? RustTmuxPane)?.controlScreenText()
            }
            let screenText = paneTexts.joined(separator: "\n")
            let titleCorrect = lastSnapshot?.tabs.first?.title == "tmux renamed"
            guard lastSnapshot?.tabs.first?.panes.count == 2,
                tmuxSession?.activeWindowZoomed == false,
                screenText.contains("TMUX_PASTE_OK"),
                titleCorrect
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSmokeUnzoom(resultPath, retries: retries - 1)
                    }
                } else {
                    let paneCount = lastSnapshot?.tabs.first?.panes.count ?? -1
                    let zoomed = tmuxSession?.activeWindowZoomed == true
                    let pasted = screenText.contains("TMUX_PASTE_OK")
                    let detail =
                        paneTexts
                        .map { $0.suffix(300).replacingOccurrences(of: "\n", with: "|") }
                        .joined(separator: " <PANE> ")
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-native unzoom-or-paste "
                            + "panes=\(paneCount) zoomed=\(zoomed ? "yes" : "no") "
                            + "paste=\(pasted ? "yes" : "no") "
                            + "title=\(titleCorrect ? "yes" : "no") detail=\(detail)\n"
                    )
                }
                return
            }
            guard
                runTmuxSmokeControl([
                    "command": "new-tab",
                    "title": "tmux cli tab",
                    "background": false,
                ])
            else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(resultPath, result: "failed tmux-native cli-new-tab=no\n")
                return
            }
            waitForTmuxSmokeTab(resultPath, retries: 30)
        }

        func waitForTmuxSmokeTab(_ resultPath: String, retries: Int) {
            guard lastSnapshot?.tabs.count == 2 else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSmokeTab(resultPath, retries: retries - 1)
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(resultPath, result: "failed tmux-native tab-timeout\n")
                }
                return
            }
            guard let session = tmuxSession else {
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-native session-end-context\n")
                return
            }
            let descriptor = NativeTmuxSessionDescriptor(
                sessionID: session.sessionID,
                name: session.sessionName,
                windowCount: lastSnapshot?.tabs.count ?? 0,
                socketPath: session.socketPath,
                serverPID: session.serverPid
            )
            let picker = TmuxSessionPopoverController(currentSessionName: session.sessionName)
            picker.update(sessions: [descriptor], status: nil, canCreate: true)
            picker.onRequestEndSession = { [weak self] requested in
                self?.endTmuxSession(requested)
            }
            guard picker.requestEndSessionForSmoke(descriptor) else {
                session.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-native session-end-x=no\n")
                return
            }
            waitForTmuxSmokeExit(resultPath, retries: 30)
        }

        func waitForTmuxSmokeExit(_ resultPath: String, retries: Int) {
            guard tmuxSession == nil else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxSmokeExit(resultPath, retries: retries - 1)
                    }
                } else {
                    writeSessionSmokeResult(resultPath, result: "failed tmux-native exit-timeout\n")
                }
                return
            }
            let restored =
                lastSnapshot?.tabs.contains { $0.panes.contains(activePaneId ?? -1) } == true
            let attachmentCleared = currentSessionState()?.tmuxAttachment == nil
            let result =
                restored && attachmentCleared
                ? "ok tmux-native indicator=yes output=yes history=yes paste=yes zoom=yes "
                    + "font-zoom=yes "
                    + "agent-status=yes agent-title=stable activity=separate notification=yes "
                    + "rename=yes split=2 divider-resize=yes pane-dnd=noop+center+edge "
                    + "no-change-highlight=none client-grid=full "
                    + "tabs=2 tab-close=x-redrawn cli=yes live-cursor=yes "
                    + "session-end=x-targeted "
                    + "ime=yes focus-input=yes return-repeat=yes kitty=yes "
                    + "shell-env=yes "
                    + "shell-restored=yes detach-clears=yes\n"
                : "failed tmux-native shell-restored=\(restored ? "yes" : "no") "
                    + "detach-clears=\(attachmentCleared ? "yes" : "no")\n"
            writeSessionSmokeResult(resultPath, result: result)
        }

        func runTmuxSmokeControl(_ payload: [String: Any]) -> Bool {
            var object = payload
            object["id"] = 1
            object["version"] = 1
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                let request = try? JSONDecoder().decode(NativeControlRequest.self, from: data)
            else {
                return false
            }
            var succeeded = false
            handleControlRequest(request) { result in
                if case .success = result {
                    succeeded = true
                }
            }
            return succeeded
        }

    }
#endif
