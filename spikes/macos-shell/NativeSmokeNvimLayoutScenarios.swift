import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func moveNvimSmokeToBottomThenJump(_ resultPath: String, attempts: Int) {
            clearSmokeScrollShift()
            metalView.resetSkiaFrameCount()
            runNvimCommandOrWrite("normal! G", fallback: Data("\u{1b}G".utf8))

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.finishNvimSmokeBottomMove(resultPath, attempts: attempts)
            }
        }

        func waitForNvimSmokeContentThenJump(_ resultPath: String, retries: Int) {
            let contentRows = terminalTextView.rendererContentRowCount()
            let hasReadyMarker = terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker])
            let contentReady = hasReadyMarker
            guard contentReady else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.waitForNvimSmokeContentThenJump(resultPath, retries: retries - 1)
                    }
                    return
                }
                writeNvimJumpContentNotReadyResult(
                    resultPath,
                    contentRows: contentRows,
                    hasReadyMarker: hasReadyMarker
                )
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + nvimJumpBaselineDelay) { [weak self] in
                self?.moveNvimSmokeToBottomThenJump(resultPath, attempts: 4)
            }
        }

        func waitForNvimLayoutRedrawReady(_ resultPath: String, retries: Int) {
            guard terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker]),
                let nvimPaneId = activePaneId
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.waitForNvimLayoutRedrawReady(resultPath, retries: retries - 1)
                    }
                    return
                }
                writeNvimLayoutRedrawFailure(resultPath, phase: "ready")
                return
            }

            pendingPaneMode = .terminal
            pendingPaneWorkingDirectory = nativeWorkingDirectory()
            guard let disposablePaneId = core.splitActive(axis: ffiSplitVertical) else {
                writeNvimLayoutRedrawFailure(resultPath, phase: "split")
                return
            }
            syncFromCore()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.closeNvimLayoutSmokeSplit(
                    resultPath,
                    nvimPaneId: nvimPaneId,
                    disposablePaneId: disposablePaneId
                )
            }
        }

        func closeNvimLayoutSmokeSplit(
            _ resultPath: String,
            nvimPaneId: Int,
            disposablePaneId: Int
        ) {
            metalView.resetSkiaFrameCount()
            guard core.closePane(disposablePaneId) else {
                writeNvimLayoutRedrawFailure(resultPath, phase: "close")
                return
            }
            discardPaneState(disposablePaneId)
            guard let snapshot = core.snapshot(), !snapshot.tabs.isEmpty else {
                writeNvimLayoutRedrawFailure(resultPath, phase: "close-snapshot")
                return
            }
            lastSnapshot = snapshot
            syncTabs(snapshot)
            syncPaneLayout(snapshot)
            syncActivePane(snapshot)
            waitForNvimLayoutCloseRedraw(resultPath, nvimPaneId: nvimPaneId, retries: 16)
        }

        func waitForNvimLayoutCloseRedraw(
            _ resultPath: String,
            nvimPaneId: Int,
            retries: Int
        ) {
            drainTerminalPanes()
            let expected = paneGridSize(nvimPaneId)
            let actual = terminalTextView.rendererRootGridSize()
            let ready =
                activePaneId == nvimPaneId
                && terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker])
                && actual?.cols == expected.cols
                && actual?.rows == expected.rows
                && nvimSmokeGridFitsPane(nvimPaneId, grid: expected)
                && metalView.skiaFrames() > 0
                && !metalView.hasPendingFrameRequest()
                && metalView.drawableSizesMatchView()
            guard ready else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.waitForNvimLayoutCloseRedraw(
                            resultPath,
                            nvimPaneId: nvimPaneId,
                            retries: retries - 1
                        )
                    }
                    return
                }
                writeNvimLayoutRedrawFailure(resultPath, phase: "close-redraw")
                return
            }

            let closeSummary = nvimLayoutRedrawSummary(expected: expected, actual: actual)
            metalView.resetSkiaFrameCount()
            guard adjustTerminalZoom(by: -1) else {
                writeNvimLayoutRedrawFailure(resultPath, phase: "zoom-out")
                return
            }
            waitForNvimZoomRedraw(
                resultPath,
                nvimPaneId: nvimPaneId,
                baseline: expected,
                closeSummary: closeSummary,
                retries: 16
            )
        }

        func waitForNvimZoomRedraw(
            _ resultPath: String,
            nvimPaneId: Int,
            baseline: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
            closeSummary: String,
            retries: Int
        ) {
            drainTerminalPanes()
            let expected = paneGridSize(nvimPaneId)
            let actual = terminalTextView.rendererRootGridSize()
            let gridExpanded = expected.cols > baseline.cols && expected.rows > baseline.rows
            let ready =
                gridExpanded
                && terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker])
                && actual?.cols == expected.cols
                && actual?.rows == expected.rows
                && nvimSmokeGridFitsPane(nvimPaneId, grid: expected)
                && metalView.skiaFrames() > 0
                && !metalView.hasPendingFrameRequest()
                && metalView.drawableSizesMatchView()
            if !ready, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.waitForNvimZoomRedraw(
                        resultPath,
                        nvimPaneId: nvimPaneId,
                        baseline: baseline,
                        closeSummary: closeSummary,
                        retries: retries - 1
                    )
                }
                return
            }
            guard ready else {
                writeNvimLayoutRedrawFailure(resultPath, phase: "zoom-redraw")
                return
            }

            let zoomSummary = nvimLayoutRedrawSummary(expected: expected, actual: actual)
            guard let window = view.window else {
                writeNvimLayoutRedrawFailure(resultPath, phase: "resize-window")
                return
            }
            metalView.resetSkiaFrameCount()
            let size = window.contentLayoutRect.size
            window.setContentSize(NSSize(width: size.width + 120, height: size.height + 80))
            view.layoutSubtreeIfNeeded()
            resizeTerminalPanesToGrid()
            waitForNvimWindowResizeRedraw(
                resultPath,
                nvimPaneId: nvimPaneId,
                closeSummary: closeSummary,
                zoomSummary: zoomSummary,
                retries: 16
            )
        }

        func waitForNvimWindowResizeRedraw(
            _ resultPath: String,
            nvimPaneId: Int,
            closeSummary: String,
            zoomSummary: String,
            retries: Int
        ) {
            drainTerminalPanes()
            let expected = paneGridSize(nvimPaneId)
            let actual = terminalTextView.rendererRootGridSize()
            let ready =
                terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker])
                && actual?.cols == expected.cols
                && actual?.rows == expected.rows
                && nvimSmokeGridFitsPane(nvimPaneId, grid: expected)
                && metalView.skiaFrames() > 0
                && !metalView.hasPendingFrameRequest()
                && metalView.drawableSizesMatchView()
            if !ready, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.waitForNvimWindowResizeRedraw(
                        resultPath,
                        nvimPaneId: nvimPaneId,
                        closeSummary: closeSummary,
                        zoomSummary: zoomSummary,
                        retries: retries - 1
                    )
                }
                return
            }

            let resizeSummary = nvimLayoutRedrawSummary(expected: expected, actual: actual)
            let status = ready ? "ok" : "failed"
            let geometry = terminalTextView.skiaGeometrySummary()
            let viewport = terminalTextView.skiaViewportSummary()
            let marker = terminalTextView.rendererModelTextStartSummary(
                label: "marker",
                text: nvimSmokeReadyMarker
            )
            let result =
                "\(status) nvim-layout-redraw matrix=local-nvim grid-fit=yes "
                + "close={\(closeSummary)} "
                + "zoom={\(zoomSummary)} resize={\(resizeSummary)} "
                + "geometry=\(geometry) viewport=\(viewport) "
                + "marker=\(marker)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func nvimLayoutRedrawSummary(
            expected: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
            actual: (cols: Int, rows: Int)?
        ) -> String {
            let actualSize = actual.map { "\($0.cols)x\($0.rows)" } ?? "none"
            return "expected=\(expected.cols)x\(expected.rows) actual=\(actualSize) "
                + "skia=\(metalView.skiaFrames()) \(metalView.frameRequestDiagnosticsSummary()) "
                + metalView.resizeDiagnosticsSummary()
        }

        func nvimSmokeGridFitsPane(
            _ paneId: Int,
            grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int)
        ) -> Bool {
            guard let frame = paneStore.visibleFrames[paneId] else {
                return false
            }
            let cell = terminalTextView.terminalCellSize()
            return CGFloat(grid.cols) * cell.width <= frame.width + 1.5
                && CGFloat(grid.rows) * cell.height <= frame.height + 1.5
        }

        func writeNvimLayoutRedrawFailure(_ resultPath: String, phase: String) {
            let result =
                "failed nvim-layout-redraw phase=\(phase) "
                + "\(metalView.frameRequestDiagnosticsSummary()) "
                + "model=\(terminalTextView.rendererModelWindowTextSummary())\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func writeNvimJumpContentNotReadyResult(
            _ resultPath: String,
            contentRows: Int,
            hasReadyMarker: Bool
        ) {
            let rendererSummary =
                "model-frames=\(terminalTextView.hasRendererModelFrames() ? "yes" : "no") "
                + "skia-frames=\(metalView.skiaFrames() > 0 ? "yes" : "no") count=\(metalView.skiaFrames())"
            let markerSummary = hasReadyMarker ? "yes" : "no"
            let result =
                "failed jump-content-not-ready rows=\(contentRows) "
                + "marker=\(markerSummary) \(rendererSummary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func finishNvimSmokeBottomMove(_ resultPath: String, attempts: Int) {
            let moved =
                consumeSmokeScrollShift()
                .map { abs($0.rows) > maxOutputScrollAnimationRows } ?? false
            if !moved, attempts > 0 {
                moveNvimSmokeToBottomThenJump(resultPath, attempts: attempts - 1)
                return
            }

            clearSmokeScrollShift()
            metalView.resetSkiaFrameCount()
            runNvimCommandOrWrite("normal! gg", fallback: Data("\u{1b}gg".utf8))

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.writeNvimAnimationSmokeResult(resultPath, retries: 8)
            }
        }

        func writeNvimAnimationSmokeResult(
            _ resultPath: String,
            retries: Int,
            requiresRetainedScroll: Bool = false
        ) {
            let shift = peekSmokeScrollShift()
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            let retainedScroll = terminalTextView.rendererMaxScrollPosition()
            let retainedScrollOk = !requiresRetainedScroll || retainedScroll > 0
            let ok =
                hasModelFrames && skiaFrames >= 2 && retainedScrollOk
                && (shift.map { abs($0.rows) > maxOutputScrollAnimationRows } ?? false)
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.writeNvimAnimationSmokeResult(
                        resultPath,
                        retries: retries - 1,
                        requiresRetainedScroll: requiresRetainedScroll
                    )
                }
                return
            }

            let summary = nvimAnimationSmokeSummary(
                shift,
                hasModelFrames: hasModelFrames,
                skiaFrames: skiaFrames
            )
            let retainedSummary =
                requiresRetainedScroll ? " retained-scroll=\(retainedScroll)" : ""
            clearSmokeScrollShift()
            let result =
                ok
                ? "ok \(summary)\(retainedSummary)\n"
                : "failed \(summary)\(retainedSummary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func writeNativeSmokeResult(_ resultPath: String, retries: Int) {
            let skiaFrames = metalView.skiaFrames()
            let ok = skiaFrames > 0
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.writeNativeSmokeResult(resultPath, retries: retries - 1)
                }
                return
            }

            let result =
                ok
                ? "ok native-smoke skia-frames=yes count=\(skiaFrames)\n"
                : "failed native-smoke skia-frames=no count=\(skiaFrames)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        }

        func waitForTerminalAfterNvimQuit(_ resultPath: String, retries: Int) {
            drainTerminalPanes()
            if activePaneMode() != .terminal, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTerminalAfterNvimQuit(resultPath, retries: retries - 1)
                }
                return
            }

            metalView.resetSkiaFrameCount()
            writeToActivePane(Data("printf 'AFTERQA\\n'\r".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.writeTerminalNvimQuitSmokeResult(resultPath, retries: 8)
            }
        }

        func writeTerminalNvimQuitSmokeResult(_ resultPath: String, retries: Int) {
            let modeOk = activePaneMode() == .terminal
            let skiaFrames = metalView.skiaFrames()
            let ok = modeOk && skiaFrames > 0
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.writeTerminalNvimQuitSmokeResult(resultPath, retries: retries - 1)
                }
                return
            }

            let result =
                ok
                ? "ok terminal-nvim-quit mode=terminal skia-frames=\(skiaFrames)\n"
                : "failed terminal-nvim-quit mode=\(activePaneMode()) skia-frames=\(skiaFrames)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func writeTerminalNvimHandoffSmokeResult(_ resultPath: String, retries: Int) {
            let modeOk = activePaneMode() == .neovim
            let modelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            let textOk = terminalTextView.rendererModelContainsTexts(["HANDOFFNVIM"])
            let ok = modeOk && modelFrames && skiaFrames > 0 && textOk
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.writeTerminalNvimHandoffSmokeResult(resultPath, retries: retries - 1)
                }
                return
            }

            let result =
                ok
                ? "ok terminal-nvim-handoff mode=neovim model-frames=yes "
                    + "skia-frames=\(skiaFrames) text=yes\n"
                : "failed terminal-nvim-handoff mode=\(activePaneMode()) "
                    + "model-frames=\(modelFrames ? "yes" : "no") "
                    + "skia-frames=\(skiaFrames) text=\(textOk ? "yes" : "no")\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func writeTerminalExitClosesTabSmokeResult(_ resultPath: String, retries: Int) {
            drainTerminalPanes()
            let snapshot = core.snapshot()
            let tabs = snapshot?.tabs.count ?? 0
            let activeTab = snapshot?.active_tab ?? -1
            let ok = tabs == 1 && activeTab == 0 && activePaneMode() == .terminal
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.writeTerminalExitClosesTabSmokeResult(resultPath, retries: retries - 1)
                }
                return
            }

            let result =
                ok
                ? "ok terminal-exit-closes-tab tabs=1 active=0\n"
                : "failed terminal-exit-closes-tab tabs=\(tabs) active=\(activeTab) "
                    + "mode=\(activePaneMode())\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func writeTerminalNvimCwdSmokeResult(
            _ resultPath: String,
            expected: String,
            actualFile: String,
            retries: Int
        ) {
            let actual = (try? String(contentsOfFile: actualFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = activePaneMode() == .neovim && actual == expected
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.writeTerminalNvimCwdSmokeResult(
                        resultPath,
                        expected: expected,
                        actualFile: actualFile,
                        retries: retries - 1
                    )
                }
                return
            }

            let result =
                ok
                ? "ok terminal-nvim-cwd cwd=\(expected)\n"
                : "failed terminal-nvim-cwd expected=\(expected) actual=\(actual ?? "nil") "
                    + "mode=\(activePaneMode())\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func waitForTerminalBottomInputIdleThenType(_ resultPath: String, retries: Int) {
            let scrollPosition = abs(activePaneRendererScrollPosition())
            if scrollPosition > maxTerminalBottomInputSmokePosition, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.waitForTerminalBottomInputIdleThenType(resultPath, retries: retries - 1)
                }
                return
            }

            metalView.resetSkiaFrameCount()
            writeToActivePane(Data("abc".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.writeTerminalBottomInputSmokeResult(
                    resultPath,
                    retries: 12,
                    maxScrollPosition: 0
                )
            }
        }

        func writeTerminalBottomInputSmokeResult(
            _ resultPath: String,
            retries: Int,
            maxScrollPosition: Double
        ) {
            let skiaFrames = metalView.skiaFrames()
            let scrollPosition = abs(activePaneRendererScrollPosition())
            let observedScrollPosition = max(maxScrollPosition, scrollPosition)
            let ok = skiaFrames > 0 && observedScrollPosition <= maxTerminalBottomInputSmokePosition
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.writeTerminalBottomInputSmokeResult(
                        resultPath,
                        retries: retries - 1,
                        maxScrollPosition: observedScrollPosition
                    )
                }
                return
            }
            guard ok else {
                let formattedPosition = String(format: "%.2f", observedScrollPosition)
                let result =
                    "failed terminal-bottom-input unexpected-scroll skia-frames=\(skiaFrames) "
                    + "scroll-position=\(formattedPosition)\n"
                try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            beginTerminalReturnRepeatSmoke(
                resultPath,
                initialMaxScrollPosition: observedScrollPosition
            )
        }

        func beginTerminalReturnRepeatSmoke(
            _ resultPath: String,
            initialMaxScrollPosition: Double
        ) {
            guard let pane = activePaneId.flatMap({ paneStore.runtimes[$0] as? RustTerminalPane }),
                !(pane is RustTmuxPane)
            else {
                writeTerminalReturnRepeatFailure(
                    resultPath,
                    detail: "pane=missing"
                )
                return
            }
            pane.write(Data([21]))
            let setup =
                "function _satin_repeat_delay { command sleep 0.06; }; "
                + "precmd_functions=(_satin_repeat_delay _satin_prepare_prompt); "
                + "PS1=$'LOCAL_REPEAT> \\e]133;B\\a'\r"
            pane.write(Data(setup.utf8))
            waitForTerminalReturnRepeatPrompt(
                resultPath,
                pane: pane,
                marker: "LOCAL_REPEAT>",
                semanticPromptExpected: true,
                retries: 30,
                maxScrollPosition: initialMaxScrollPosition
            )
        }

        func waitForTerminalReturnRepeatPrompt(
            _ resultPath: String,
            pane: RustTerminalPane,
            marker: String,
            semanticPromptExpected: Bool,
            retries: Int,
            maxScrollPosition: Double
        ) {
            drainTerminalPanes()
            let foregroundShell = satinRuntimeInteractiveShellOwnsForeground(pane.handle) != 0
            let promptReady =
                pane.controlScreenText()
                .split(separator: "\n")
                .last?
                .trimmingCharacters(in: .whitespaces) == marker
            guard foregroundShell, promptReady else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.waitForTerminalReturnRepeatPrompt(
                            resultPath,
                            pane: pane,
                            marker: marker,
                            semanticPromptExpected: semanticPromptExpected,
                            retries: retries - 1,
                            maxScrollPosition: maxScrollPosition
                        )
                    }
                } else {
                    writeTerminalReturnRepeatFailure(
                        resultPath,
                        detail: "prompt=\(promptReady) foreground-shell=\(foregroundShell)"
                    )
                }
                return
            }
            if !semanticPromptExpected {
                _ = satinRuntimeTmuxResetPromptTracking(pane.handle)
                pane.resetRepeatedReturnBackpressure()
            }
            let semanticPromptSeen = satinRuntimeTmuxSemanticPromptSeen(pane.handle) != 0
            guard semanticPromptSeen == semanticPromptExpected else {
                writeTerminalReturnRepeatFailure(
                    resultPath,
                    detail: "marker=\(marker) semantic=\(semanticPromptSeen)"
                )
                return
            }
            metalView.resetSkiaFrameCount()
            sendTerminalReturnRepeat(
                resultPath,
                pane: pane,
                marker: marker,
                semanticPromptExpected: semanticPromptExpected,
                remaining: 65,
                foregroundTransitionObserved: false,
                maxScrollPosition: maxScrollPosition
            )
        }

        func sendTerminalReturnRepeat(
            _ resultPath: String,
            pane: RustTerminalPane,
            marker: String,
            semanticPromptExpected: Bool,
            remaining: Int,
            foregroundTransitionObserved: Bool,
            maxScrollPosition: Double
        ) {
            let foregroundShell = satinRuntimeInteractiveShellOwnsForeground(pane.handle) != 0
            let observedForegroundTransition =
                foregroundTransitionObserved || !foregroundShell
            let observedScrollPosition = max(
                maxScrollPosition,
                abs(pane.rendererScrollPosition())
            )
            guard remaining > 0 else {
                if let event = terminalReturnRepeatSmokeEvent(repeated: false, released: true) {
                    terminalTextView.keyUp(with: event)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak pane] in
                    guard let pane else {
                        return
                    }
                    self?.validateTerminalReturnRepeat(
                        resultPath,
                        pane: pane,
                        marker: marker,
                        semanticPromptExpected: semanticPromptExpected,
                        foregroundTransitionObserved: observedForegroundTransition,
                        retries: 12,
                        maxScrollPosition: observedScrollPosition
                    )
                }
                return
            }
            let isRepeatedEvent = remaining < 65
            guard
                let event = terminalReturnRepeatSmokeEvent(
                    repeated: isRepeatedEvent,
                    released: false
                )
            else {
                writeTerminalReturnRepeatFailure(resultPath, detail: "input=no")
                return
            }
            terminalTextView.keyDown(with: event)
            guard terminalTextView.terminalKeysDown.contains(event.keyCode) else {
                writeTerminalReturnRepeatFailure(resultPath, detail: "view-input=no")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak pane] in
                guard let pane else {
                    return
                }
                self?.sendTerminalReturnRepeat(
                    resultPath,
                    pane: pane,
                    marker: marker,
                    semanticPromptExpected: semanticPromptExpected,
                    remaining: remaining - 1,
                    foregroundTransitionObserved: observedForegroundTransition,
                    maxScrollPosition: observedScrollPosition
                )
            }
        }

        func validateTerminalReturnRepeat(
            _ resultPath: String,
            pane: RustTerminalPane,
            marker: String,
            semanticPromptExpected: Bool,
            foregroundTransitionObserved: Bool,
            retries: Int,
            maxScrollPosition: Double
        ) {
            drainTerminalPanes()
            let observedScrollPosition = max(
                maxScrollPosition,
                abs(pane.rendererScrollPosition())
            )
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
            let responsive = observedScrollPosition <= 1.1
            let semanticPromptSeen = satinRuntimeTmuxSemanticPromptSeen(pane.handle) != 0
            let semanticPromptMatches = semanticPromptSeen == semanticPromptExpected
            let foregroundTransitionMatches =
                marker != "LOCAL_REPEAT>" || foregroundTransitionObserved
            guard continuous, responsive, semanticPromptMatches, foregroundTransitionMatches else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.validateTerminalReturnRepeat(
                            resultPath,
                            pane: pane,
                            marker: marker,
                            semanticPromptExpected: semanticPromptExpected,
                            foregroundTransitionObserved: foregroundTransitionObserved,
                            retries: retries - 1,
                            maxScrollPosition: observedScrollPosition
                        )
                    }
                } else {
                    writeTerminalReturnRepeatFailure(
                        resultPath,
                        detail: "marker=\(marker) continuous=\(continuous) "
                            + "semantic=\(semanticPromptSeen) rows=\(markerRows.count) "
                            + "foreground-transition=\(foregroundTransitionObserved) "
                            + "scroll=\(String(format: "%.2f", observedScrollPosition))"
                    )
                }
                return
            }
            if semanticPromptExpected {
                pane.write(Data([21]))
                pane.write(Data("precmd_functions=(); PS1='LOCAL_FALLBACK> '\r".utf8))
                waitForTerminalReturnRepeatPrompt(
                    resultPath,
                    pane: pane,
                    marker: "LOCAL_FALLBACK>",
                    semanticPromptExpected: false,
                    retries: 30,
                    maxScrollPosition: observedScrollPosition
                )
                return
            }
            let result =
                "ok terminal-bottom-input no-scroll return-repeat=yes duplicate-prompt-ready=yes "
                + "foreground-transition=yes fallback-prompt=yes foreground-shell=yes "
                + "rows=\(markerRows.count) skia-frames=\(metalView.skiaFrames()) "
                + "scroll-position=\(String(format: "%.2f", observedScrollPosition))\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func terminalReturnRepeatSmokeEvent(repeated: Bool, released: Bool) -> NSEvent? {
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

        func writeTerminalReturnRepeatFailure(_ resultPath: String, detail: String) {
            let result = "failed terminal-bottom-input return-repeat \(detail)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func writeNvimSidePaneSmokeResult(_ resultPath: String, retries: Int) {
            let shift = peekSmokeScrollShift()
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            let cursorGrid = terminalTextView.rendererCursorParentGridID()
            let positions = terminalTextView.rendererVisibleWindowScrollPositions()
            let activePosition = positions.first { $0.gridID == cursorGrid }?.position ?? 0
            let unexpected = positions.filter {
                $0.gridID != cursorGrid && $0.position > maxNvimCursorMoveSmokeGrowth
            }
            let animationObserved = activePosition > maxNvimCursorMoveSmokeGrowth
            let ok =
                hasModelFrames && skiaFrames >= 2 && animationObserved && unexpected.isEmpty
                && (shift.map { shift in
                    abs(shift.rows) > maxOutputScrollAnimationRows && (shift.startCol ?? 0) > 0
                } ?? false)
            if !ok, unexpected.isEmpty, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    self?.writeNvimSidePaneSmokeResult(resultPath, retries: retries - 1)
                }
                return
            }

            let summary = nvimAnimationSmokeSummary(
                shift,
                hasModelFrames: hasModelFrames,
                skiaFrames: skiaFrames
            )
            let positionSummary = positions.map {
                "\($0.gridID)@\($0.left):\(String(format: "%.3f", $0.position))"
            }.joined(separator: ",")
            clearSmokeScrollShift()
            let result =
                ok
                ? "ok \(summary) cursor-grid=\(cursorGrid.map(String.init) ?? "none") "
                    + "scrolls=\(positionSummary)\n"
                : "failed \(summary) cursor-grid=\(cursorGrid.map(String.init) ?? "none") "
                    + "scrolls=\(positionSummary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func writeNvimNoScrollSmokeResult(_ resultPath: String, label: String) {
            let shift = consumeSmokeScrollShift()
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            let hasSkiaFrames = skiaFrames > 0
            let commandLineCount = terminalTextView.rendererModelTextOccurrences(":qa")
            let commandLineOk = label != "commandline" || commandLineCount == 1
            let summary = nvimAnimationSmokeSummary(
                shift,
                hasModelFrames: hasModelFrames,
                skiaFrames: skiaFrames
            )
            let commandSummary = label == "commandline" ? " cmdline=\(commandLineCount)" : ""
            let result =
                shift == nil && hasModelFrames && hasSkiaFrames && commandLineOk
                ? "ok \(label) no-scroll model-frames=yes skia-frames=yes\(commandSummary)\n"
                : "failed \(label) \(summary)\(commandSummary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

    }
#endif
