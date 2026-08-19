import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    struct TmuxSmokePaneSize: Equatable {
        let cols: Int
        let rows: Int
    }

    struct TmuxSmokeGridFitState {
        let valid: Bool
        let summary: String
    }

    extension TerminalShellViewController {
        func tmuxReportedClientGrid() -> NativePaneGridCapacity? {
            guard let session = tmuxSession,
                let snapshot = lastSnapshot,
                let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab })
            else {
                return nil
            }
            let leafCapacities = session.tmuxPaneIds.reduce(
                into: [Int: NativePaneGridCapacity]()
            ) { capacities, entry in
                guard let pane = session.latestPanes[entry.value] else {
                    return
                }
                capacities[entry.key] = NativePaneGridCapacity(
                    rows: Int(pane.rows),
                    cols: Int(pane.cols)
                )
            }
            return tmuxClientGridCapacity(layout: tab.layout, leafCapacities: leafCapacities)
        }

        func verifyTmuxSmokeFontZoom(
            baselineGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int)
        ) -> Bool {
            guard let session = tmuxSession,
                session.nativePaneIds.count == 2,
                let zoomedPaneId = activePaneId,
                let zoomInEvent = tmuxSmokeZoomEvent(increment: true),
                let zoomOutEvent = tmuxSmokeZoomEvent(increment: false)
            else {
                return false
            }
            let paneIds = Array(session.nativePaneIds.values)
            guard paneIds.contains(zoomedPaneId) else {
                return false
            }
            let baselineSize = terminalTextView.terminalFontSize
            guard terminalTextView.handleCommandKey(zoomInEvent)
            else {
                return false
            }
            let zoomedGrid = tmuxClientGrid()
            guard
                abs(terminalTextView.terminalFontSize - baselineSize - 1) < 0.01,
                zoomedGrid.cols <= baselineGrid.cols,
                zoomedGrid.rows <= baselineGrid.rows,
                zoomedGrid.cols != baselineGrid.cols || zoomedGrid.rows != baselineGrid.rows,
                session.requestedClientGrid?.cols == zoomedGrid.cols,
                session.requestedClientGrid?.rows == zoomedGrid.rows,
                terminalTextView.handleCommandKey(zoomOutEvent)
            else {
                return false
            }
            let restoredGrid = tmuxClientGrid()
            guard abs(terminalTextView.terminalFontSize - baselineSize) < 0.01,
                restoredGrid.cols == baselineGrid.cols,
                restoredGrid.rows == baselineGrid.rows,
                session.requestedClientGrid?.cols == restoredGrid.cols,
                session.requestedClientGrid?.rows == restoredGrid.rows,
                terminalTextView.handleCommandKey(zoomOutEvent)
            else {
                return false
            }
            let zoomedOutGrid = tmuxClientGrid()
            guard abs(terminalTextView.terminalFontSize - baselineSize + 1) < 0.01,
                zoomedOutGrid.cols >= baselineGrid.cols,
                zoomedOutGrid.rows >= baselineGrid.rows,
                zoomedOutGrid.cols != baselineGrid.cols
                    || zoomedOutGrid.rows != baselineGrid.rows,
                session.requestedClientGrid?.cols == zoomedOutGrid.cols,
                session.requestedClientGrid?.rows == zoomedOutGrid.rows,
                terminalTextView.handleCommandKey(zoomInEvent)
            else {
                return false
            }
            let finalGrid = tmuxClientGrid()
            return abs(terminalTextView.terminalFontSize - baselineSize) < 0.01
                && finalGrid.cols == baselineGrid.cols
                && finalGrid.rows == baselineGrid.rows
                && session.requestedClientGrid?.cols == finalGrid.cols
                && session.requestedClientGrid?.rows == finalGrid.rows
        }

        func tmuxSmokeZoomEvent(increment: Bool) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: increment ? [.command, .shift] : .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                characters: increment ? "+" : "-",
                charactersIgnoringModifiers: increment ? "=" : "-",
                isARepeat: false,
                keyCode: increment ? 24 : 27
            )
        }

        func tmuxZoomResizeSmokeOnly() -> Bool {
            ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_TMUX_SCOPE"]
                == "zoom-resize"
        }

        func beginTmuxGridMatrixSplit(_ resultPath: String) {
            guard let previousPaneId = activePaneId,
                runTmuxSmokeControl([
                    "command": "split",
                    "pane": previousPaneId,
                    "axis": "horizontal",
                ])
            else {
                failTmuxZoomResizeSmoke(resultPath, reason: "horizontal-split")
                return
            }
            waitForTmuxGridMatrixSplit(
                resultPath, previousPaneId: previousPaneId, retries: 40)
        }

        func waitForTmuxGridMatrixSplit(
            _ resultPath: String,
            previousPaneId: Int,
            retries: Int
        ) {
            drainTerminalPanes()
            let expected = tmuxClientGrid()
            let requested = tmuxSession?.requestedClientGrid
            let reported = tmuxReportedClientGrid()
            let paneIds =
                lastSnapshot?.tabs.first?.panes.filter {
                    tmuxSession?.tmuxPaneIds[$0] != nil
                } ?? []
            let gridFit = tmuxSmokeGridFitState(paneIds)
            let ready =
                paneIds.count == 3
                && activePaneId != previousPaneId
                && requested
                    == NativePaneGridCapacity(
                        rows: expected.rows,
                        cols: expected.cols
                    )
                && reported == requested
                && gridFit.valid
            guard ready else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxGridMatrixSplit(
                            resultPath,
                            previousPaneId: previousPaneId,
                            retries: retries - 1
                        )
                    }
                } else {
                    failTmuxZoomResizeSmoke(
                        resultPath,
                        reason: "horizontal-split-settle",
                        details: "expected=\(expected.cols)x\(expected.rows) "
                            + "requested=\(requested?.cols ?? -1)x\(requested?.rows ?? -1) "
                            + "reported=\(reported?.cols ?? -1)x\(reported?.rows ?? -1) "
                            + "fit=\(gridFit.summary)"
                    )
                }
                return
            }
            beginTmuxSharedZoomSmoke(resultPath, baselineGrid: expected)
        }

        func beginTmuxSharedZoomSmoke(
            _ resultPath: String,
            baselineGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int)
        ) {
            guard let session = tmuxSession,
                let snapshot = lastSnapshot,
                let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab }),
                let zoomedPaneId = activePaneId
            else {
                failTmuxZoomResizeSmoke(resultPath, reason: "zoom-setup")
                return
            }
            let nativePaneIds = tab.panes.filter { session.tmuxPaneIds[$0] != nil }
            let siblingPaneIds = nativePaneIds.filter { $0 != zoomedPaneId }
            let tmuxPaneIds = nativePaneIds.compactMap { session.tmuxPaneIds[$0] }
            let baselinePaneSizes = tmuxSmokePaneSizes(tmuxPaneIds)
            let baselineFontSize = terminalTextView.terminalFontSize
            let baselineFit = tmuxSmokeGridFitState(nativePaneIds)
            guard nativePaneIds.count == 3,
                nativePaneIds.contains(zoomedPaneId),
                baselinePaneSizes.count == tmuxPaneIds.count,
                baselineFit.valid
            else {
                failTmuxZoomResizeSmoke(
                    resultPath,
                    reason: "terminal-grid-fit",
                    details: baselineFit.summary
                )
                return
            }
            writeToActivePane(Data("nvim -u NONE -n\r".utf8))
            waitForTmuxNvimBeforeZoom(
                resultPath,
                zoomedPaneId: zoomedPaneId,
                siblingPaneIds: siblingPaneIds,
                tmuxPaneIds: tmuxPaneIds,
                baselineFontSize: baselineFontSize,
                baselineGrid: baselineGrid,
                baselinePaneSizes: baselinePaneSizes,
                baselineFit: baselineFit.summary,
                retries: 40
            )
        }

        func waitForTmuxNvimBeforeZoom(
            _ resultPath: String,
            zoomedPaneId: Int,
            siblingPaneIds: [Int],
            tmuxPaneIds: [UInt32],
            baselineFontSize: CGFloat,
            baselineGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
            baselinePaneSizes: [UInt32: TmuxSmokePaneSize],
            baselineFit: String,
            retries: Int
        ) {
            drainTerminalPanes()
            guard tmuxSmokePaneRunsNvim(zoomedPaneId) else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxNvimBeforeZoom(
                            resultPath,
                            zoomedPaneId: zoomedPaneId,
                            siblingPaneIds: siblingPaneIds,
                            tmuxPaneIds: tmuxPaneIds,
                            baselineFontSize: baselineFontSize,
                            baselineGrid: baselineGrid,
                            baselinePaneSizes: baselinePaneSizes,
                            baselineFit: baselineFit,
                            retries: retries - 1
                        )
                    }
                } else {
                    failTmuxZoomResizeSmoke(resultPath, reason: "nvim-start")
                }
                return
            }
            guard let zoomOutEvent = tmuxSmokeZoomEvent(increment: false) else {
                failTmuxZoomResizeSmoke(resultPath, reason: "zoom-start")
                return
            }
            for _ in 0..<4 {
                guard terminalTextView.handleCommandKey(zoomOutEvent) else {
                    failTmuxZoomResizeSmoke(resultPath, reason: "zoom-step")
                    return
                }
            }
            waitForTmuxSharedZoom(
                resultPath,
                zoomedPaneId: zoomedPaneId,
                siblingPaneIds: siblingPaneIds,
                tmuxPaneIds: tmuxPaneIds,
                baselineFontSize: baselineFontSize,
                baselineGrid: baselineGrid,
                baselinePaneSizes: baselinePaneSizes,
                baselineFit: baselineFit,
                retries: 40
            )
        }

        func waitForTmuxSharedZoom(
            _ resultPath: String,
            zoomedPaneId: Int,
            siblingPaneIds: [Int],
            tmuxPaneIds: [UInt32],
            baselineFontSize: CGFloat,
            baselineGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
            baselinePaneSizes: [UInt32: TmuxSmokePaneSize],
            baselineFit: String,
            retries: Int
        ) {
            drainTerminalPanes()
            let zoomedGrid = tmuxClientGrid()
            let zoomedPaneSizes = tmuxSmokePaneSizes(tmuxPaneIds)
            let zoomIsShared =
                abs(terminalTextView.terminalFontSize - baselineFontSize + 4) < 0.01
            let clientGridExpanded =
                zoomedGrid.cols >= baselineGrid.cols
                && zoomedGrid.rows >= baselineGrid.rows
                && (zoomedGrid.cols != baselineGrid.cols || zoomedGrid.rows != baselineGrid.rows)
            let paneGridsExpanded = tmuxPaneSizesExpanded(
                from: baselinePaneSizes,
                to: zoomedPaneSizes,
                paneIds: tmuxPaneIds
            )
            let gridFit = tmuxSmokeGridFitState([zoomedPaneId] + siblingPaneIds)
            let settled =
                zoomIsShared
                && clientGridExpanded
                && paneGridsExpanded
                && gridFit.valid
                && tmuxSmokePaneRunsNvim(zoomedPaneId)
                && tmuxSession?.requestedClientGrid?.cols == zoomedGrid.cols
                && tmuxSession?.requestedClientGrid?.rows == zoomedGrid.rows
            guard settled else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxSharedZoom(
                            resultPath,
                            zoomedPaneId: zoomedPaneId,
                            siblingPaneIds: siblingPaneIds,
                            tmuxPaneIds: tmuxPaneIds,
                            baselineFontSize: baselineFontSize,
                            baselineGrid: baselineGrid,
                            baselinePaneSizes: baselinePaneSizes,
                            baselineFit: baselineFit,
                            retries: retries - 1
                        )
                    }
                } else {
                    failTmuxZoomResizeSmoke(
                        resultPath,
                        reason: "shared-nvim-reflow",
                        details: "font=\(terminalTextView.terminalFontSize)"
                            + "/\(baselineFontSize - 4) shared=\(zoomIsShared) "
                            + "client-expanded=\(clientGridExpanded) "
                            + "panes-expanded=\(paneGridsExpanded) "
                            + "nvim=\(tmuxSmokePaneRunsNvim(zoomedPaneId)) "
                            + "client=\(zoomedGrid.cols)x\(zoomedGrid.rows) "
                            + "panes=\(tmuxSmokePaneSizesSummary(zoomedPaneSizes)) "
                            + "fit=\(gridFit.summary)"
                    )
                }
                return
            }
            let diagnostics =
                "terminal-fit={\(baselineFit)} "
                + "zoom-client=\(baselineGrid.cols)x\(baselineGrid.rows)"
                + "->\(zoomedGrid.cols)x\(zoomedGrid.rows) "
                + "zoom-panes=\(tmuxSmokePaneSizesSummary(baselinePaneSizes))"
                + "->\(tmuxSmokePaneSizesSummary(zoomedPaneSizes)) "
                + "nvim-fit={\(gridFit.summary)}"
            startTmuxNvimZoomProbe(
                resultPath,
                zoomedPaneId: zoomedPaneId,
                siblingPaneIds: siblingPaneIds,
                baselineFontSize: baselineFontSize,
                diagnostics: diagnostics,
                retries: 40
            )
        }

        func startTmuxNvimZoomProbe(
            _ resultPath: String,
            zoomedPaneId: Int,
            siblingPaneIds: [Int],
            baselineFontSize: CGFloat,
            diagnostics: String,
            retries: Int
        ) {
            guard let expected = tmuxSmokePaneSize(zoomedPaneId) else {
                failTmuxZoomResizeSmoke(resultPath, reason: "nvim-probe-size")
                return
            }
            writeTmuxNvimGridProbe()
            waitForTmuxNvimZoomProbe(
                resultPath,
                zoomedPaneId: zoomedPaneId,
                siblingPaneIds: siblingPaneIds,
                baselineFontSize: baselineFontSize,
                expected: expected,
                diagnostics: diagnostics,
                retries: retries
            )
        }

        func waitForTmuxNvimZoomProbe(
            _ resultPath: String,
            zoomedPaneId: Int,
            siblingPaneIds: [Int],
            baselineFontSize: CGFloat,
            expected: TmuxSmokePaneSize,
            diagnostics: String,
            retries: Int
        ) {
            drainTerminalPanes()
            guard tmuxSmokePaneSize(zoomedPaneId) == expected else {
                if retries > 0 {
                    startTmuxNvimZoomProbe(
                        resultPath,
                        zoomedPaneId: zoomedPaneId,
                        siblingPaneIds: siblingPaneIds,
                        baselineFontSize: baselineFontSize,
                        diagnostics: diagnostics,
                        retries: retries - 1
                    )
                } else {
                    failTmuxZoomResizeSmoke(resultPath, reason: "nvim-probe-unstable")
                }
                return
            }
            let marker = tmuxNvimGridMarker(expected)
            let markerVisible =
                projectedTmuxPane(zoomedPaneId)?
                .controlScreenText().contains(marker) == true
            let fit = tmuxSmokeGridFitState([zoomedPaneId] + siblingPaneIds)
            guard markerVisible, fit.valid else {
                if retries > 0 {
                    if retries.isMultiple(of: 4) {
                        writeTmuxNvimGridProbe()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxNvimZoomProbe(
                            resultPath,
                            zoomedPaneId: zoomedPaneId,
                            siblingPaneIds: siblingPaneIds,
                            baselineFontSize: baselineFontSize,
                            expected: expected,
                            diagnostics: diagnostics,
                            retries: retries - 1
                        )
                    }
                } else {
                    let screen =
                        projectedTmuxPane(zoomedPaneId)?.controlScreenText()
                        .suffix(600).replacingOccurrences(of: "\n", with: "|") ?? "missing"
                    failTmuxZoomResizeSmoke(
                        resultPath,
                        reason: "nvim-grid-report",
                        details: "expected=\(marker) fit=\(fit.summary) screen=\(screen)"
                    )
                }
                return
            }
            beginTmuxZoomResizeSmoke(
                resultPath,
                zoomedPaneId: zoomedPaneId,
                siblingPaneIds: siblingPaneIds,
                baselineFontSize: baselineFontSize,
                diagnostics: diagnostics + " nvim-reported=\(marker)"
            )
        }

        func tmuxSmokePaneRunsNvim(_ nativePaneId: Int) -> Bool {
            guard let tmuxPaneId = tmuxSession?.tmuxPaneIds[nativePaneId],
                let command = tmuxSession?.latestPanes[tmuxPaneId]?.current_command
            else {
                return false
            }
            return command.lowercased().contains("nvim")
        }

        func tmuxSmokePaneSize(_ nativePaneId: Int) -> TmuxSmokePaneSize? {
            guard let tmuxPaneId = tmuxSession?.tmuxPaneIds[nativePaneId],
                let pane = tmuxSession?.latestPanes[tmuxPaneId]
            else {
                return nil
            }
            return TmuxSmokePaneSize(cols: Int(pane.cols), rows: Int(pane.rows))
        }

        func writeTmuxNvimGridProbe() {
            guard let session = tmuxSession,
                let nativePaneId = activePaneId,
                let tmuxPaneId = session.tmuxPaneIds[nativePaneId]
            else {
                return
            }
            let command = ":put='SATIN_GRID_'.&columns.'x'.&lines|redraw!"
            _ = session.gateway.tmuxCommand("send-keys -t %\(tmuxPaneId) Escape")
            _ = session.gateway.tmuxCommand(
                "send-keys -t %\(tmuxPaneId) -l \(shellQuote(command))")
            _ = session.gateway.tmuxCommand("send-keys -t %\(tmuxPaneId) Enter")
        }

        func tmuxNvimGridMarker(_ size: TmuxSmokePaneSize) -> String {
            "SATIN_GRID_\(size.cols)x\(size.rows)"
        }

        func tmuxPaneSizesExpanded(
            from baseline: [UInt32: TmuxSmokePaneSize],
            to zoomed: [UInt32: TmuxSmokePaneSize],
            paneIds: [UInt32]
        ) -> Bool {
            zoomed.count == baseline.count
                && zoomed != baseline
                && paneIds.allSatisfy { paneId in
                    guard let before = baseline[paneId], let after = zoomed[paneId] else {
                        return false
                    }
                    return after.cols >= before.cols && after.rows >= before.rows
                }
        }

        func tmuxSmokePaneSizes(_ paneIds: [UInt32]) -> [UInt32: TmuxSmokePaneSize] {
            guard let session = tmuxSession else {
                return [:]
            }
            return Dictionary(
                uniqueKeysWithValues: paneIds.compactMap { paneId in
                    session.latestPanes[paneId].map {
                        (paneId, TmuxSmokePaneSize(cols: Int($0.cols), rows: Int($0.rows)))
                    }
                }
            )
        }

        func tmuxSmokePaneSizesSummary(_ sizes: [UInt32: TmuxSmokePaneSize]) -> String {
            sizes.sorted { $0.key < $1.key }.map {
                "%\($0.key):\($0.value.cols)x\($0.value.rows)"
            }.joined(separator: ",")
        }

        func tmuxSmokeGridFitState(_ paneIds: [Int]) -> TmuxSmokeGridFitState {
            guard let session = tmuxSession else {
                return TmuxSmokeGridFitState(valid: false, summary: "no-session")
            }
            var valid = true
            let summaries = paneIds.map { paneId -> String in
                guard let tmuxPaneId = session.tmuxPaneIds[paneId],
                    let snapshot = session.latestPanes[tmuxPaneId],
                    let frame = paneStore.visibleFrames[paneId]
                else {
                    valid = false
                    return "native:\(paneId):missing"
                }
                let cursor =
                    projectedTmuxPane(paneId)?.cursorPosition()
                    ?? (x: Int(snapshot.cursor_x), y: Int(snapshot.cursor_y))
                let cell = terminalTextView.terminalCellSize()
                let usedWidth = CGFloat(snapshot.cols) * cell.width
                let usedHeight = CGFloat(snapshot.rows) * cell.height
                let tolerance: CGFloat = 1.5
                let fits =
                    usedWidth <= frame.width + tolerance
                    && usedHeight <= frame.height + tolerance
                let unusedWidth = max(0, frame.width - usedWidth)
                let unusedHeight = max(0, frame.height - usedHeight)
                let verticalHeaderBudget =
                    nativePaneChromeHeight * CGFloat(max(0, paneIds.count - 1))
                let slackBounded =
                    unusedWidth < cell.width + tolerance
                    && unusedHeight < verticalHeaderBudget + cell.height + tolerance
                let cursorInside =
                    cursor.x >= 0 && cursor.x < Int(snapshot.cols)
                    && cursor.y >= 0 && cursor.y < Int(snapshot.rows)
                    && CGFloat(cursor.x + 1) * cell.width <= frame.width + tolerance
                    && CGFloat(cursor.y + 1) * cell.height <= frame.height + tolerance
                let inputAligned: Bool
                if paneId == activePaneId {
                    let cursorCenter = NSPoint(
                        x: frame.minX + (CGFloat(cursor.x) + 0.5) * cell.width,
                        y: frame.minY + (CGFloat(cursor.y) + 0.5) * cell.height
                    )
                    let mapped = terminalTextView.mouseGridPosition(cursorCenter)
                    let expectedIme = NSPoint(
                        x: min(
                            frame.minX + CGFloat(cursor.x) * cell.width,
                            frame.maxX - cell.width
                        ),
                        y: min(
                            frame.minY + CGFloat(cursor.y) * cell.height,
                            frame.maxY - cell.height
                        )
                    )
                    let ime = terminalTextView.markedTextOriginForSmoke()
                    inputAligned =
                        mapped?.row == cursor.y && mapped?.col == cursor.x
                        && abs(ime.x - expectedIme.x) < 0.5
                        && abs(ime.y - expectedIme.y) < 0.5
                } else {
                    inputAligned = true
                }
                valid = valid && fits && slackBounded && cursorInside && inputAligned
                return "%\(tmuxPaneId):\(snapshot.cols)x\(snapshot.rows)"
                    + ":used=\(Int(usedWidth.rounded()))x\(Int(usedHeight.rounded()))"
                    + ":frame=\(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
                    + ":fit=\(fits ? "yes" : "no")"
                    + ":slack=\(Int(unusedWidth.rounded()))x\(Int(unusedHeight.rounded()))"
                    + ":bounded=\(slackBounded ? "yes" : "no")"
                    + ":cursor=\(cursorInside ? "yes" : "no")"
                    + ":input=\(inputAligned ? "yes" : "no")"
            }
            return TmuxSmokeGridFitState(
                valid: valid && summaries.count == paneIds.count,
                summary: summaries.joined(separator: ",")
            )
        }

        func failTmuxZoomResizeSmoke(
            _ resultPath: String,
            reason: String,
            details: String = ""
        ) {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            let suffix = details.isEmpty ? "" : " \(details)"
            writeSessionSmokeResult(
                resultPath, result: "failed tmux-zoom-resize reason=\(reason)\(suffix)\n")
        }

        func beginTmuxZoomResizeSmoke(
            _ resultPath: String,
            zoomedPaneId: Int,
            siblingPaneIds: [Int],
            baselineFontSize: CGFloat,
            diagnostics: String
        ) {
            guard let window = view.window else {
                failTmuxZoomResizeSmoke(resultPath, reason: "no-window")
                return
            }
            metalView.resetResizeDiagnostics()
            resetGeometryResizeDiagnostics()
            tmuxSession?.clientResizeRequestCount = 0
            let growth = (0...60).map { step in
                let progress = CGFloat(step) / 60
                return NSSize(
                    width: 780 + 340 * progress,
                    height: 480 + 280 * progress
                )
            }
            let sizes = growth + growth.dropLast().reversed()
            applyTerminalResizeSmokeSizes(sizes, to: window) { [weak self] in
                self?.waitForTmuxZoomResizeSmoke(
                    resultPath,
                    zoomedPaneId: zoomedPaneId,
                    siblingPaneIds: siblingPaneIds,
                    baselineFontSize: baselineFontSize,
                    diagnostics: diagnostics,
                    retries: 160
                )
            }
        }

        func waitForTmuxZoomResizeSmoke(
            _ resultPath: String,
            zoomedPaneId: Int,
            siblingPaneIds: [Int],
            baselineFontSize: CGFloat,
            diagnostics: String,
            retries: Int
        ) {
            drainTerminalPanes()
            let expected = tmuxClientGrid()
            let geometry = geometryResizeDiagnostics()
            let clientResizeRequests = tmuxSession?.clientResizeRequestCount ?? 0
            let zoomRemainsShared =
                abs(terminalTextView.terminalFontSize - baselineFontSize + 4) < 0.01
            let gridFit = tmuxSmokeGridFitState([zoomedPaneId] + siblingPaneIds)
            let settled =
                lastSnapshot?.tabs.first?.panes.count == siblingPaneIds.count + 1
                && zoomRemainsShared
                && gridFit.valid
                && tmuxSmokePaneRunsNvim(zoomedPaneId)
                && tmuxSession?.requestedClientGrid?.cols == expected.cols
                && tmuxSession?.requestedClientGrid?.rows == expected.rows
                && clientResizeRequests > 0
                && clientResizeRequests < geometry.applications
                && geometry.requests > 1
                && geometry.applications < geometry.requests
            guard settled else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxZoomResizeSmoke(
                            resultPath,
                            zoomedPaneId: zoomedPaneId,
                            siblingPaneIds: siblingPaneIds,
                            baselineFontSize: baselineFontSize,
                            diagnostics: diagnostics,
                            retries: retries - 1
                        )
                    }
                } else {
                    let requested = tmuxSession?.requestedClientGrid
                    let reported = tmuxReportedClientGrid()
                    failTmuxZoomResizeSmoke(
                        resultPath,
                        reason: "resize-settle",
                        details: "client=\(expected.cols)x\(expected.rows) "
                            + "requested=\(requested?.cols ?? -1)x\(requested?.rows ?? -1) "
                            + "reported=\(reported?.cols ?? -1)x\(reported?.rows ?? -1) "
                            + "tmux-resizes=\(clientResizeRequests) "
                            + "geometry=\(geometry.applications)/\(geometry.requests) "
                            + "fit=\(gridFit.summary) "
                            + metalView.resizeDiagnosticsSummary()
                    )
                }
                return
            }
            startTmuxNvimResizeProbe(
                resultPath,
                zoomedPaneId: zoomedPaneId,
                siblingPaneIds: siblingPaneIds,
                diagnostics: diagnostics + " resized-fit={\(gridFit.summary)} "
                    + "tmux-resizes=\(clientResizeRequests) "
                    + "geometry=\(geometry.applications)/\(geometry.requests) "
                    + metalView.resizeDiagnosticsSummary(),
                retries: 40
            )
        }

        func startTmuxNvimResizeProbe(
            _ resultPath: String,
            zoomedPaneId: Int,
            siblingPaneIds: [Int],
            diagnostics: String,
            retries: Int
        ) {
            guard let expected = tmuxSmokePaneSize(zoomedPaneId) else {
                failTmuxZoomResizeSmoke(resultPath, reason: "resize-probe-size")
                return
            }
            writeTmuxNvimGridProbe()
            waitForTmuxNvimResizeProbe(
                resultPath,
                zoomedPaneId: zoomedPaneId,
                siblingPaneIds: siblingPaneIds,
                expected: expected,
                diagnostics: diagnostics,
                retries: retries
            )
        }

        func waitForTmuxNvimResizeProbe(
            _ resultPath: String,
            zoomedPaneId: Int,
            siblingPaneIds: [Int],
            expected: TmuxSmokePaneSize,
            diagnostics: String,
            retries: Int
        ) {
            drainTerminalPanes()
            guard tmuxSmokePaneSize(zoomedPaneId) == expected else {
                if retries > 0 {
                    startTmuxNvimResizeProbe(
                        resultPath,
                        zoomedPaneId: zoomedPaneId,
                        siblingPaneIds: siblingPaneIds,
                        diagnostics: diagnostics,
                        retries: retries - 1
                    )
                } else {
                    failTmuxZoomResizeSmoke(resultPath, reason: "resize-probe-unstable")
                }
                return
            }
            let marker = tmuxNvimGridMarker(expected)
            let markerVisible =
                projectedTmuxPane(zoomedPaneId)?
                .controlScreenText().contains(marker) == true
            let gridFit = tmuxSmokeGridFitState([zoomedPaneId] + siblingPaneIds)
            guard markerVisible, gridFit.valid else {
                if retries > 0 {
                    if retries.isMultiple(of: 4) {
                        writeTmuxNvimGridProbe()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxNvimResizeProbe(
                            resultPath,
                            zoomedPaneId: zoomedPaneId,
                            siblingPaneIds: siblingPaneIds,
                            expected: expected,
                            diagnostics: diagnostics,
                            retries: retries - 1
                        )
                    }
                } else {
                    let screen =
                        projectedTmuxPane(zoomedPaneId)?.controlScreenText()
                        .suffix(600).replacingOccurrences(of: "\n", with: "|") ?? "missing"
                    failTmuxZoomResizeSmoke(
                        resultPath,
                        reason: "resize-nvim-grid-report",
                        details: "expected=\(marker) fit=\(gridFit.summary) screen=\(screen)"
                    )
                }
                return
            }
            tmuxSession?.gateway.tmuxCommand("kill-session")
            waitForTmuxZoomResizeSmokeExit(
                resultPath,
                diagnostics: diagnostics + " resized-nvim-reported=\(marker)",
                retries: 30
            )
        }

        func waitForTmuxZoomResizeSmokeExit(
            _ resultPath: String,
            diagnostics: String,
            retries: Int
        ) {
            guard tmuxSession == nil else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxZoomResizeSmokeExit(
                            resultPath,
                            diagnostics: diagnostics,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-zoom-resize exit-timeout\n")
                }
                return
            }
            writeSessionSmokeResult(
                resultPath,
                result: "ok tmux-zoom-resize matrix=tmux-terminal+nvim "
                    + "font-zoom=shared grid=aligned resize=responsive "
                    + "\(diagnostics)\n"
            )
        }
    }
#endif
